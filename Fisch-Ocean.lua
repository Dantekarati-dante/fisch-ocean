-- A shared UILib whose loop has stopped (the run that owned it died) stays in memory, and
-- every later load would reuse it: a menu on screen that ignores every click. The library
-- stamps _now each frame. Checked first, before anything slow: the offset and library
-- downloads below block the VM, and while they do even a healthy library cannot stamp.
local UI_STALE = (function()
    local prev = rawget(_G, "UILib")
    local beat = type(prev) == "table" and tonumber(rawget(prev, "_now"))
    return type(beat) == "number" and (tick() - beat) > 3
end)()

local function svc(n) return game:GetService(n) or game[n] end
local Players     = svc("Players")
local RunService  = svc("RunService")
local HttpService = svc("HttpService")
local Workspace   = svc("Workspace") or workspace
local function getLP() return Players and Players.LocalPlayer end

do
    local prev = _G.FischMacro
    _G.FischMacro = nil
    if prev and prev.unload then pcall(prev.unload) end
end
local FM = { conns = {}, drawings = {}, dead = false }
_G.FischMacro = FM
function FM.track(c) FM.conns[#FM.conns + 1] = c; return c end
function FM.draw(kind)
    local d = Drawing.new(kind)
    FM.drawings[#FM.drawings + 1] = d
    return d
end
function FM.unload()
    FM.dead = true
    local conns, draws = FM.conns, FM.drawings
    FM.conns, FM.drawings = {}, {}
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    for _, d in ipairs(draws) do pcall(function() d:Remove() end) end
    pcall(function() if _G.FischAppraiser then _G.FischAppraiser.unload() end end)  -- merged appraiser tab

    local lib = FM.lib
    FM.lib = nil                      -- drop the handle first (stale Drawing calls kill the chunk)
    if lib then
        pcall(function()
            if lib.Destroy then lib:Destroy() elseif lib.Unload then lib:Unload() end
        end)
    end
    pcall(function() mouse1release() end)
    if FM.releaseKeys then pcall(FM.releaseKeys) end   -- never leave a key held
end

if type(setrobloxinput) == "function" then setrobloxinput(true) end
pcall(function() mouse1release() end)   -- release anything stuck from a crash
pcall(function() mouse2release() end)

if type(memory_read) ~= "function" then
    notify("Enable Unsafe LuaU in Matcha settings.", "", 6)
end

local WEBHOOK_URL_FILE = "webhook_url.txt"
local function loadWebhookUrl()
    local url = ""
    pcall(function()
        if isfile(WEBHOOK_URL_FILE) then
            local s = tostring(readfile(WEBHOOK_URL_FILE) or ""):gsub("%s", "")
            if s ~= "" then url = s end
        else
            writefile(WEBHOOK_URL_FILE, "")   -- template, so the file is easy to find
        end
    end)
    return url
end

local CONFIG = {
    macro_tick_hz        = 60,
    macro_max_catchup    = 3,       -- fixed steps per frame ceiling (stall guard)

    -- instant reel (applygc patch — blatant, off by default)
    instant_reel_speed   = 50,      -- progressefficiency; 50 finishes a reel, turn it
                                    -- down for fish that want a slow reel (dumbo octopus)
    instant_reel_loss    = 0,       -- progressLossMultiplier; 0 = progress never drops.
                                    -- Negative values can lock the bar up, so leave it at 0.

    -- waypoint ESP
    wp_show_on_load      = false,
    wp_include_fishing   = false,
    wp_square_size       = 8,
    wp_text_size         = 14,
    wp_show_distance     = true,
    wp_max_distance      = 0,       -- studs; 0 = show all on-screen
    wp_rescan_ms         = 15000,   -- zone markers are map data; a rescan reads ~100 parts

    -- treasure chest ESP (chests spawn/despawn -> re-scanned on a timer)
    chest_show_on_load   = false,
    chest_square_size    = 10,
    chest_text_size      = 14,
    chest_show_distance  = true,
    chest_max_distance   = 0,
    chest_rescan_ms      = 1500,

    -- webhook (OPT-IN: nothing sends unless enabled AND a URL is set)
    webhook_enabled      = false,
    webhook_url          = loadWebhookUrl(),
    webhook_on_start     = true,
    webhook_stats        = true,
    webhook_interval_s   = 300,

    -- offsets
    offsets_auto         = true,
    offsets_url          = "https://offsets.imtheo.lol/offsets.hpp",

    autostart            = false,
}

-- ============================================================================
-- OFFSETS  (auto-fetched, hardcoded fallback, optional fisch_offsets.json override)
-- ============================================================================
local OFFSETS = {
    Name                       = 0x98,
    ClassDescriptor            = 0x18,
    ClassDescriptorToClassName = 0x8,
    Children                   = 0x70,
    Parent                     = 0x68,
    StringLength               = 0x10,
    TextLabelVisible           = 0x59d,
    FrameVisible               = 0x59d,
    ScreenGuiEnabled           = 0x4b4,
    FramePositionX             = 0x500,
    FrameSizeX                 = 0x520,
    GuiObjectRotation          = 0x178,
    TextLabelText              = 0xda0,
}

local function parseOffsetsHpp(body)
    if type(body) ~= "string" or body == "" then return nil end
    local map = {
        ["GuiObject.Position"]          = { "FramePositionX" },
        ["GuiObject.Size"]              = { "FrameSizeX" },
        ["GuiObject.Visible"]           = { "FrameVisible", "TextLabelVisible" },
        ["GuiObject.Rotation"]          = { "GuiObjectRotation" },
        ["GuiObject.ScreenGui_Enabled"] = { "ScreenGuiEnabled" },
        ["ScreenGui.Enabled"]           = { "ScreenGuiEnabled" },
        ["TextLabel.Text"]              = { "TextLabelText" },
        ["Instance.Name"]               = { "Name" },
        ["Instance.ChildrenStart"]      = { "Children" },
        ["Instance.Parent"]             = { "Parent" },
    }
    local current, n = nil, 0
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        local ns = line:match("namespace%s+([%w_]+)%s*{")
        if ns then current = ns end
        local member, hex = line:match("uintptr_t%s+([%w_]+)%s*=%s*(0x[0-9a-fA-F]+)")
        if member and hex then
            local keys = map[(current or "") .. "." .. member]
            local val = keys and tonumber(hex)
            if val then for _, k in ipairs(keys) do OFFSETS[k] = val; n = n + 1 end end
        end
    end
    return n
end

-- Kept so the transplanted engine can parse the same body instead of fetching
-- the identical URL a second time (both loaders block on HTTP at load).
local OFFSETS_BODY = nil

if CONFIG.offsets_auto and type(httpget) == "function" then
    local ok, body = pcall(httpget, CONFIG.offsets_url)
    if ok and type(body) == "string" and #body > 0 then OFFSETS_BODY = body end
    local n = OFFSETS_BODY and parseOffsetsHpp(OFFSETS_BODY) or nil
    if not (n and n > 0) then warn("Offset fetch/parse failed, using defaults") end
end

pcall(function()
    if isfile("fisch_offsets.json") then
        local parsed = HttpService:JSONDecode(readfile("fisch_offsets.json"))
        for k, v in pairs(parsed) do
            if OFFSETS[k] ~= nil and type(v) == "number" then OFFSETS[k] = v end
        end
        print("Offsets overridden from fisch_offsets.json")
    end
end)

-- ============================================================================
-- Memory read helpers
-- ============================================================================
-- memory_read can hand back an error STRING on a bad read (pcall still
-- succeeds) — tonumber() everything so a string can never leak into arithmetic.
local function readPtr(addr)
    if not addr or addr <= 4096 then return nil end
    local ok, v = pcall(memory_read, "uintptr_t", addr)
    v = ok and tonumber(v) or nil
    return (v and v > 4096) and v or nil
end
local function readFloat(addr)
    if not addr or addr <= 4096 then return 0.0 end
    local ok, v = pcall(memory_read, "float", addr)
    return (ok and tonumber(v)) or 0.0
end
local function readInt(addr)
    if not addr or addr <= 4096 then return 0 end
    local ok, v = pcall(memory_read, "int32", addr)
    if not ok then ok, v = pcall(memory_read, "int", addr) end
    return (ok and tonumber(v)) or 0
end
local function readByte(addr)
    if not addr or addr <= 4096 then return 0 end
    local ok, v = pcall(memory_read, "byte", addr)
    return (ok and tonumber(v)) or 0
end
local function instAddr(inst)
    if not inst then return nil end
    local ok, a = pcall(function() return inst.Address end)
    a = (ok and a) and tonumber(a) or nil
    return (a and a > 4096) and a or nil
end

-- GuiObject Position/Size UDim2 straight from memory. NOTE: the anchored reel
-- playerbar's Position.X.Scale is its CENTER, so the controller uses
-- readFramePos(playerbar) as-is (no half-width correction).
local function readFramePos(frame)
    local a = instAddr(frame); if not a then return 0, 0, 0, 0 end
    local base = a + OFFSETS.FramePositionX
    return readFloat(base + 0x0), readInt(base + 0x4), readFloat(base + 0x8), readInt(base + 0xC)
end
local function readFrameSize(frame)
    local a = instAddr(frame); if not a then return 0, 0, 0, 0 end
    local base = a + OFFSETS.FrameSizeX
    return readFloat(base + 0x0), readInt(base + 0x4), readFloat(base + 0x8), readInt(base + 0xC)
end

local function isScreenGuiEnabled(gui)
    if not gui then return false end
    local ok, v = pcall(function() return gui.Enabled end)
    if ok and type(v) == "boolean" then return v end
    local a = instAddr(gui); if not a then return true end
    return readByte(a + OFFSETS.ScreenGuiEnabled) ~= 0
end

local function readMemString(strAddr)
    if not strAddr then return "" end
    local len = readInt(strAddr + OFFSETS.StringLength)
    if len <= 0 or len > 1000 then return "" end
    local dataAddr = strAddr
    if len > 15 then dataAddr = readPtr(strAddr) end   -- long strings are heap pointers
    if not dataAddr then return "" end
    local ok, s = pcall(memory_read, "string", dataAddr)
    return (ok and type(s) == "string") and s or ""
end

local function readGuiText(inst)
    if not inst then return "" end
    local ok, v = pcall(function() return inst.Text end)
    if ok and type(v) == "string" and v ~= "" then return v end
    local a = instAddr(inst)
    return a and readMemString(a + OFFSETS.TextLabelText) or ""
end

local function finite(v, lo, hi)
    if type(v) ~= "number" then return false end
    if v ~= v or v == math.huge or v == -math.huge then return false end
    if lo and v < lo then return false end
    if hi and v > hi then return false end
    return true
end

-- ============================================================================
-- Instance helpers
-- ============================================================================
local function findChild(parent, name)
    if not parent then return nil end
    local ok, v = pcall(parent.FindFirstChild, parent, name)
    return ok and v or nil
end
local function getChildren(inst)
    if not inst then return {} end
    local ok, v = pcall(inst.GetChildren, inst)
    return (ok and v) or {}
end
local function getPlayerGui()
    local lp = getLP(); if not lp then return nil end
    return lp:FindFirstChildOfClass("PlayerGui") or findChild(lp, "PlayerGui")
end

-- A stale character model can share the player's name after a respawn, so
-- return every candidate and let callers search them all.
local function getCharacterModels()
    local lp = getLP(); if not lp then return {} end
    local out, seen = {}, {}
    local function add(m) if m and not seen[m] then seen[m] = true; out[#out + 1] = m end end
    add(lp.Character)
    add(findChild(Workspace, lp.Name))
    return out
end

local function getHRP()
    local lp = getLP()
    local char = lp and (lp.Character or findChild(Workspace, lp.Name))
    return char and findChild(char, "HumanoidRootPart")
end

local function selfPos()
    local hrp = getHRP()
    local ok, pos = pcall(function() return hrp and hrp.Position end)
    return ok and pos or nil
end

local function robloxActive()
    if type(isrbxactive) ~= "function" then return true end
    local ok, v = pcall(isrbxactive)
    return (not ok) or (v ~= false)
end

-- ============================================================================
-- ============================================================================
-- AUTOFISH ENGINE - transplanted from JustAutofish.lua (2026-09-05).
--
-- This is JustAutofish's engine essentially verbatim: the hybrid ReelController
-- (time-constant velocity filtering + delta-sigma duty, so the loop rate cannot
-- change the tuning), dual-button reeling, reel-slot discovery with liveAddr
-- dangling-pointer guards, the CASTING/CASTED/SHAKE/FISHING/DONE phase machine,
-- and the nuke, spear and gun modes.
--
-- It lives in a do-block for the REGISTER BUDGET: it declares ~148 locals of its
-- own and this chunk already had ~31 live at this point (179 of Luau's 200). The
-- block frees them again at `end`, and the closures keep what they need as
-- upvalues, so the rest of the file below still has room. Do not hoist any of
-- these locals to the top level.
--
-- Only two changes were made to the transplanted source: its own bootstrap, UI
-- panel and RunService loops were dropped (this file supplies all three), and
-- superviseStuck now bumps STATE.recoveries so the menu status line can show
-- restarts.
-- Style inside the block is JustAutofish's (tabs, semicolons) - left alone so it
-- can still be diffed against the original.
-- ============================================================================
local function getLocalPlayer() return Players and Players.LocalPlayer end

local ENG = {}
do
    pcall(mouse1release); -- clear a left button a previous run may have left down

    if type(memory_read) ~= "function" then -- every GUI read below depends on this
    	-- the host script already warns about this at load, so no second popup
    end;

    local CONFIG = { -- every user-tunable knob in the script
    		mode = "rod", -- which mode the dropdown starts on
    		castPower = 3.0, -- release the cast at this power percentage
    		castTimeoutMs = 5000, -- give up on a charge that never completes
    		castLandTimeoutMs = 5000, -- give up waiting for the shake prompt after a cast
    		castRepressMs = 180, -- re-arm the cast click if the power bar has not shown up by now
    		castRepressGapMs = 30, -- how long the button stays up between those re-arms
    		postCastDelayMs = 10, -- settle time after releasing the cast
    		postCatchDelayMs = 10, -- settle time after a successful catch
    		postLostDelayMs = 10, -- settle time after a lost fish
    		castOnTimeout = true, -- recast instead of stopping when a cycle times out
    		shakeIntervalMs = 15, -- gap between Enter taps during the shake prompt
    		completionThreshold = 99.0, -- progress percent that counts as caught
    		reelStallMs = 4000, -- a live reel that stops moving for this long gets rediscovered
    		reelTimeoutMs = 0, -- 0 = no time limit; a reel ends only when the GUI closes. Set to 180000 to restore the backstop
    		shakeTimeoutMs = 20000, -- cap on a shake prompt that never turns into a reel
    		stuckTimeoutMs = 75000, -- last-resort reset when one phase never ends
    		equipKey = "T", -- hotbar slot the rod lives in
    		equipVerifyMs = 250, -- wait this long before checking whether the press landed
    		equipAttempts = 4, -- how many times to press before giving up
    		equipSettleMs = 5000, -- absolute deadline for confirming the rod
    		reequipOnDeadCast = true, -- re-press T when the first cast of a run produces no bar
    		dualReel = true, -- drive a second minigame with right click
    		swapReelButtons = false, -- flip which on-screen reel gets which mouse button
    		nukeDeadzoneFrac = .08, -- fraction of the range treated as centred
    		nukeTapIntervalMs = 55, -- base gap between correction taps
    		nukeTapHoldMs = 30, -- how long each Q/E tap is held
    		nukePrediction = 10, -- how far ahead velocity is extrapolated
    		nukeTimeoutMs = 45000, -- abandon the nuke GUI after this long
    		nukeLockTimeoutMs = 10000, -- nothing moving by now means this GUI is not a nuke
    		stabGuiName = "stab", -- PlayerGui child that marks the spear minigame
    		stabIntervalMs = 0, -- gap between stab clicks
    		stabHoldMs = 0, -- how long each stab click is held
    		stabStartRight = false, -- start the alternation on right click
    		stabTimeoutMs = 60000, -- abandon a stab GUI that never closes
    		gunGuiName = "harpoonMinigame", -- PlayerGui child that holds the harpoon popups
    		gunDelayMs = 0, -- slider: shortest gap from one click to the next, 0 for as fast as it can
    		gunSettleMs = 45, -- wait after aiming before clicking
    		gunHoldMs = 40, -- how long the click is held
    		gunRearmMs = 150, -- ignore the just-clicked popup for this long
    		gunMaxFixes = 3, -- cursor calibration attempts per popup
    	};


    local MODES = { "rod", "spear", "gun" }; -- dropdown order and valid CONFIG.mode values

    local function modeLabel(id) -- turns a mode id into a capitalised display name
    	id = tostring(id or "");
    	return id:sub(1, 1):upper() .. id:sub(2);
    end;

    local REFRESH = { -- shortest gap, in ms, between one lookup or pass and the next
    		playerGui = 5000,
    		reel = 250,
    		shake = 400,
    		power = 250,
    		nuke = 200,
    		nukeDeep = 1000,
    		nukeNestedPer = 2, -- ScreenGuis whose children the fuzzy nuke search opens per pass (~10/s)
    		stab = 200,
    		gun = 60,
    		step = 8, stepAt = 0, -- the mode's phase logic; RenderStepped alone is far too fast for it
    		steer = 3, steerAt = 0, -- reel steering, the one pass that wants every frame it can get
    		book = 12, bookAt = 0, -- reel discovery, progress and the stall watchdog
    		cross = 50, crossAt = 0, -- the nuke-versus-reel arbitration, which nothing needs promptly
    	};

    local OFFSETS_URL = "https://offsets.imtheo.lol/offsets.hpp"; -- community-maintained offset dump

    local OFFSETS = { -- struct offsets used by every memory read, with working defaults
    		FramePositionX = 0x500,
    		FrameSizeX = 0x520,
    		ScreenGuiEnabled = 0x4b4,
    		FrameVisible = 0x59d,
    		FrameRotation = 376,
    		AbsolutePositionX = 0xfc,
    		AbsolutePositionY = 0x100,
    		AbsoluteSizeX = 0x104,
    		AbsoluteSizeY = 0x108,
    	};

    local function parseOffset(source, namespace, field) -- pulls one number out of the offsets header
    	local block = source:match("namespace%s+" .. namespace .. "%s*{(.-)\n%s*}"); -- isolate the namespace body
    	if not block then
    		return nil;
    	end;
    	local value = block:match(field .. "%s*=%s*(0x%x+)") or block:match(field .. "%s*=%s*(%d+)"); -- hex or decimal
    	return value and tonumber(value) or nil;
    end;

    local function loadOffsets() -- refreshes OFFSETS from the web dump when possible
    	-- MODIFIED for the transplant: reuse the body the host script already
    	-- fetched from this same URL, and only go to the network if it has none.
    	local body = OFFSETS_BODY;
    	if type(body) ~= "string" or #body == 0 then
    		if type(game.HttpGet) ~= "function" then
    			return;
    		end;
    		local ok, fetched = pcall(function()
    				return game:HttpGet(OFFSETS_URL);
    			end);
    		if not ok or type(fetched) ~= "string" or #fetched == 0 then -- network failure keeps the defaults
    			return;
    		end;
    		body = fetched;
    	end;

    	local parsed = { -- scalar GuiObject fields map one-to-one
    			FramePositionX = parseOffset(body, "GuiObject", "Position"),
    			FrameSizeX = parseOffset(body, "GuiObject", "Size"),
    			ScreenGuiEnabled = parseOffset(body, "GuiObject", "ScreenGui_Enabled"),
    			FrameVisible = parseOffset(body, "GuiObject", "Visible"),
    			FrameRotation = parseOffset(body, "GuiObject", "Rotation"),
    		};

    	local absPos = parseOffset(body, "GuiBase2D", "AbsolutePosition"); -- Vector2 published as one offset
    	if absPos then
    		parsed.AbsolutePositionX, parsed.AbsolutePositionY = absPos, absPos + 4; -- Y sits one float later
    	end;
    	local absSize = parseOffset(body, "GuiBase2D", "AbsoluteSize"); -- same deal for the size vector
    	if absSize then
    		parsed.AbsoluteSizeX, parsed.AbsoluteSizeY = absSize, absSize + 4;
    	end;

    	local count = 0;
    	for key, value in pairs(parsed) do -- only overwrite the fields that actually parsed
    		if value and value >= 0x40 then -- the dump has shipped 0x0 placeholders (AbsoluteSize, 2026-09-10); nothing real sits in the instance header
    			OFFSETS[key] = value;
    			count = count + 1;
    		end;
    	end;
    end;
    pcall(loadOffsets); -- optional step, so a failure here must not stop the script

    local function isFinite(n) -- rejects nil, NaN and both infinities
    	return type(n) == "number" and n == n and (n ~= math.huge and n ~= -math.huge);
    end;

    local function clampn(v, lo, hi) -- clamps a number into an inclusive range
    	if v < lo then
    		return lo;
    	elseif v > hi then
    		return hi;
    	end;
    	return v;
    end;

    local function memReader(kind, fallback) -- builds a typed memory reader that never throws
    	return function(addr)
    		if not addr or addr <= 4096 then -- anything in the null page is not a real object
    			return fallback;
    		end;
    		local ok, value = pcall(memory_read, kind, addr);
    		return (ok and tonumber(value)) or fallback;
    	end;
    end;

    local readFloat = memReader("float", .0); -- positions, sizes and rotations
    local readByte = memReader("byte", 0); -- boolean GUI flags
    local readInt = memReader("int", 0); -- pixel offsets

    local function readProp(inst, key) -- indexes an instance so callers can pcall it
    	return inst[key];
    end;

    local function getAddress(inst) -- the instance's process address, or nil if unusable
    	if not inst then
    		return nil;
    	end;
    	local ok, addr = pcall(readProp, inst, "Address");
    	addr = (ok and addr) and tonumber(addr) or nil;
    	return (addr and addr > 4096) and addr or nil;
    end;

    local function isAlive(inst) -- an instance the engine destroyed reports no parent
    	if not inst then
    		return false;
    	end;
    	local ok, parent = pcall(readProp, inst, "Parent");
    	return ok and parent ~= nil;
    end;

    local function liveAddr(inst, cached) -- the pointer that is safe to dereference THIS frame, or nil if there is none
    	if not inst then
    		return nil;
    	end;
    	local ok, parent = pcall(readProp, inst, "Parent");
    	if not ok or parent == nil then -- destroyed, so any pointer to it is dangling
    		return nil;
    	end;
    	local okAddr, addr = pcall(readProp, inst, "Address");
    	addr = (okAddr and addr) and tonumber(addr) or nil;
    	if not addr or addr <= 4096 then
    		return nil;
    	end;
    	return addr; -- a live frame that MOVED is followed, never abandoned; `cached` is advisory only
    end;


    local function guiFlag(inst, addr, prop, offset) -- reads a GUI boolean, preferring the property
    	-- Liveness first: a destroyed GUI is off, and nothing more is read through it, because
    	-- Roblox frees it soon after and a read of freed memory can take Matcha down. This used
    	-- to read the property first, and then reported a destroyed GUI as showing.
    	if not isAlive(inst) then
    		return false;
    	end;
    	local ok, value = pcall(readProp, inst, prop);
    	if ok and type(value) == "boolean" then
    		return value;
    	end;
    	addr = getAddress(inst); -- its parent was checked just above, so this frame's pointer is safe
    	if not addr then
    		return true; -- unknown state is assumed live rather than skipped
    	end;
    	return readByte(addr + offset) ~= 0;
    end;

    local function isEnabled(gui, addr) -- ScreenGui.Enabled
    	return guiFlag(gui, addr, "Enabled", OFFSETS.ScreenGuiEnabled);
    end;

    local function isVisible(gui, addr) -- GuiObject.Visible
    	return guiFlag(gui, addr, "Visible", OFFSETS.FrameVisible);
    end;

    local function findChild(parent, name) -- FindFirstChild that returns nil instead of throwing
    	if not parent then
    		return nil;
    	end;
    	local ok, child = pcall(parent.FindFirstChild, parent, name);
    	return ok and child or nil;
    end;

    local function getChildren(inst) -- GetChildren that always returns a table
    	if not inst then
    		return {};
    	end;
    	local ok, kids = pcall(inst.GetChildren, inst);
    	return (ok and kids) or {};
    end;

    local function findFrameNamed(root, name) -- breadth-first search for a Frame with this name
    	if not root then
    		return nil;
    	end;
    	local queue, index = { root }, 1;
    	while index <= #queue do
    		local node = queue[index];
    		index = index + 1;
    		for _, child in ipairs(getChildren(node)) do
    			if child.Name == name and child.ClassName == "Frame" then
    				return child;
    			end;
    			queue[#queue + 1] = child;
    		end;

    		if index > 8192 then -- hard cap so a huge tree cannot stall the frame
    			return nil;
    		end;
    	end;
    	return nil;
    end;

    local UI = { -- cached PlayerGui, shake and power references plus their timestamps
    		playerGui = nil, playerGuiAt = 0,
    		shakeGui = nil, shakeAddr = nil,
    		safezone = nil, safezoneAddr = nil,
    		button = nil, buttonAddr = nil,
    		shakeAt = 0,
    		powerBar = nil, powerAddr = nil, powerAt = 0,
    	};

    local function getPlayerGui(now) -- cached PlayerGui lookup, refreshed every few seconds
    	if UI.playerGui and (now - UI.playerGuiAt) < REFRESH.playerGui then
    		return UI.playerGui;
    	end;
    	local player = getLocalPlayer();
    	local pg = nil;
    	if player then
    		local ok, found = pcall(player.FindFirstChildOfClass, player, "PlayerGui");
    		pg = (ok and found) or findChild(player, "PlayerGui"); -- class lookup first, name second
    	end;
    	UI.playerGui = pg;
    	UI.playerGuiAt = now;
    	return pg;
    end;

    local REEL = { -- the reel minigame bars currently on screen
    		slots = {},
    		driven = {}, -- button index -> the slot it steers, republished by updateFishing
    		at = 0,
    		ignored = {}, -- barAddr -> true for bars that froze; cleared once they leave the screen
    	};

    local function nameLooksReel(name) -- loose match for GUIs that might hold a reel bar
    	return type(name) == "string" and string.find(string.lower(name), "reel", 1, true) ~= nil;
    end;


    local function readReelSlot(gui, guiAddr, bar) -- turns a candidate frame into a reel slot record
    	local fish = findChild(bar, "fish"); -- the target marker
    	local playerbar = findChild(bar, "playerbar"); -- the bar the player steers
    	if not (fish and playerbar) then -- both are required for this to be a reel
    		return nil;
    	end;
    	local barAddr = getAddress(bar);
    	local fishAddr = getAddress(fish);
    	local playerbarAddr = getAddress(playerbar);
    	if not (barAddr and fishAddr and playerbarAddr) then
    		return nil;
    	end;
    	local progress = findChild(bar, "progress"); -- optional catch-progress meter
    	local progressBar = progress and findChild(progress, "bar");
    	return {
    			gui = gui, guiAddr = guiAddr,
    			bar = bar, barAddr = barAddr, name = tostring(bar.Name),
    			fish = fish, fishAddr = fishAddr,
    			playerbar = playerbar, playerbarAddr = playerbarAddr,
    			progressBar = progressBar, progressAddr = getAddress(progressBar),
    		};
    end;

    local function collectReelSlots(gui, out, seen) -- walks a GUI collecting every reel slot in it
    	if not gui then
    		return;
    	end;
    	local guiAddr = getAddress(gui);
    	local queue, index = { gui }, 1;
    	while index <= #queue and index <= 24 do -- shallow walk; reels sit near the top
    		local node = queue[index];
    		index = index + 1;
    		for _, child in ipairs(getChildren(node)) do
    			local slot = readReelSlot(gui, guiAddr, child);
    			if slot then
    				if not seen[slot.barAddr] then -- dedupe by bar address
    					seen[slot.barAddr] = true;
    					out[#out + 1] = slot;
    				end;
    			elseif #queue < 24 then
    				queue[#queue + 1] = child; -- not a reel, so descend into it
    			end;
    		end;
    	end;
    end;


    local function reelSlotOrder(a, b) -- stable left-to-right ordering for button assignment
    	local ax, bx = a.screenX or .0, b.screenX or .0;
    	if math.abs(ax - bx) > .01 then
    		if CONFIG.swapReelButtons then
    			return ax > bx;
    		end;
    		return ax < bx;
    	end;
    	if a.name ~= b.name then -- same X, so fall back to name
    		return a.name < b.name;
    	end;
    	return a.barAddr < b.barAddr; -- final tiebreak, guaranteed unique
    end;

    local function slotLive(slot) -- true while this minigame is actually on screen
    	if not isAlive(slot.bar) then -- a destroyed bar must never be dereferenced
    		return false;
    	end;
    	return isEnabled(slot.gui, slot.guiAddr) and isVisible(slot.bar, slot.barAddr);
    end;

    local function refreshReelRefs(now, force) -- rediscovers the reel bars, rate-limited unless forced
    	if not force and (now - REEL.at) < REFRESH.reel then
    		return;
    	end;
    	REEL.at = now;
    	local pg = getPlayerGui(now);
    	local slots, seen = {}, {};

    	collectReelSlots(pg and findChild(pg, "reel"), slots, seen); -- the known GUI name first

    	if pg and (force or #slots > 0) then -- widen the search for extra reel GUIs
    		for _, child in ipairs(getChildren(pg)) do
    			if nameLooksReel(child.Name) then
    				collectReelSlots(child, slots, seen);
    			end;
    		end;
    	end;


    	local present, kept = {}, {}; -- drop bars the watchdog gave up on until they disappear
    	for _, slot in ipairs(slots) do
    		present[slot.barAddr] = true;
    		if not REEL.ignored[slot.barAddr] then
    			kept[#kept + 1] = slot;
    		end;
    	end;
    	for addr in pairs(REEL.ignored) do -- a bar that is gone gets a clean slate next time
    		if not present[addr] then
    			REEL.ignored[addr] = nil;
    		end;
    	end;
    	slots = kept;

    	for _, slot in ipairs(slots) do
    		local barAddr = liveAddr(slot.bar, slot.barAddr); -- discovery and this loop are not the same instant
    		slot.screenX = barAddr and readFloat(barAddr + OFFSETS.FramePositionX) or .0; -- used only for ordering
    	end;
    	table.sort(slots, reelSlotOrder);

    	while #slots > 4 do -- cap the list; only two are ever driven
    		table.remove(slots);
    	end;

    	REEL.slots = slots;
    end;

    local function reelActive(now) -- true when any reel minigame is up
    	refreshReelRefs(now);
    	for _, slot in ipairs(REEL.slots) do
    		if slotLive(slot) then
    			return true;
    		end;
    	end;
    	return false;
    end;

    local function findShakeButton(safezone) -- locates the clickable inside the shake prompt
    	if not safezone then
    		return nil;
    	end;
    	local button = findChild(safezone, "default") or findChild(safezone, "button"); -- known names
    	if button then
    		return button;
    	end;
    	for _, child in ipairs(getChildren(safezone)) do -- otherwise take the first button child
    		local class = child.ClassName;
    		if class == "ImageButton" or class == "TextButton" then
    			return child;
    		end;
    	end;
    	return nil;
    end;

    local function refreshShakeRefs(now, force) -- recaches shakeui, its safezone and its button
    	if not force and (now - UI.shakeAt) < REFRESH.shake then
    		return;
    	end;
    	local pg = getPlayerGui(now);
    	local gui = pg and findChild(pg, "shakeui");
    	local safezone = gui and findChild(gui, "safezone");
    	local button = findShakeButton(safezone);
    	UI.shakeGui, UI.safezone, UI.button = gui, safezone, button;
    	UI.shakeAddr = getAddress(gui);
    	UI.safezoneAddr = getAddress(safezone);
    	UI.buttonAddr = getAddress(button);
    	UI.shakeAt = now;
    end;

    local function shakeUp(now) -- true while the shake prompt is showing
    	refreshShakeRefs(now);
    	-- Fisch replaces the shake button on every shake: a cached part that has gone is
    	-- looked up again now, rather than read (or waited out) until the next refresh.
    	if UI.button and not (isAlive(UI.button) and isAlive(UI.safezone) and isAlive(UI.shakeGui)) then
    		refreshShakeRefs(now, true);
    	end;
    	if not (UI.shakeGui and UI.safezone and UI.button) then
    		return false;
    	end;
    	return isEnabled(UI.shakeGui, UI.shakeAddr) -- all three layers must be live
    		and isVisible(UI.safezone, UI.safezoneAddr)
    		and isVisible(UI.button, UI.buttonAddr);
    end;

    local KEYS = { Enter = 13, F1 = 112, End = 35, Q = 81, E = 69 }; -- virtual-key codes used below

    local pendingReleases = {}; -- vk -> timestamp its keyrelease is due
    local keyBusyUntil = {}; -- vk -> timestamp it may be pressed again
    local TAP_GAP_MS = 20; -- enforced gap so the game never misses a key transition

    local function processKeyReleases(now) -- sends any key-ups that have come due
    	for vk, at in pairs(pendingReleases) do
    		if now >= at then
    			pendingReleases[vk] = nil; -- clear first so a throwing release cannot loop
    			keyrelease(vk);
    		end;
    	end;
    end;

    local function flushKeys() -- releases every held key immediately
    	processKeyReleases(math.huge);
    end;

    local function tapKey(vk, holdMs, now) -- presses a key and schedules its release
    	now = now or (tick() * 1000);
    	if pendingReleases[vk] then -- still held from the last tap
    		return false;
    	end;
    	local busyUntil = keyBusyUntil[vk];
    	if busyUntil and now < busyUntil then -- still inside the cooldown gap
    		return false;
    	end;
    	holdMs = holdMs or 25;
    	keypress(vk);
    	pendingReleases[vk] = now + holdMs;
    	keyBusyUntil[vk] = now + holdMs + TAP_GAP_MS;
    	return true;
    end;

    local function tapEnter() -- the shake-prompt keypress
    	return tapKey(KEYS.Enter, 30);
    end;

    local function slotToVk(slot) -- converts a hotbar slot like "T" or "3" into a key code
    	local text = tostring(slot or "");
    	local num = tonumber(text);
    	if num and (num >= 0 and num <= 9) then
    		return 48 + num;
    	end;
    	if #text == 1 then
    		local byte = text:upper():byte();
    		if byte >= 65 and byte <= 90 then
    			return byte;
    		end;
    	end;
    	return nil;
    end;

    local function pressSlot(slot) -- taps the hotbar key for a slot, if it maps to one
    	local vk = slotToVk(slot);
    	if not vk then
    		return;
    	end;
    	tapKey(vk, 25);
    end;

    local hasIsKeyPressed = type(iskeypressed) == "function"; -- required for the hotkeys
    local hasIsRbxActive = type(isrbxactive) == "function"; -- lets us pause while alt-tabbed
    local hasIsMouse1Pressed = type(ismouse1pressed) == "function"; -- lets the panel see real clicks

    if not hasIsKeyPressed then -- without it the panel can never be toggled on
    	notify("iskeypressed() unavailable - hotkeys cannot work.", "", 6);
    end;

    local function isRobloxActive() -- false only when we can tell the game is unfocused
    	if not hasIsRbxActive then
    		return true;
    	end;
    	return isrbxactive() ~= false;
    end;

    local hasMouse2 = type(mouse2press) == "function" and type(mouse2release) == "function"; -- dual reel needs both

    local mouseHeld = false; -- our belief about the left button
    local mouse2Held = false; -- our belief about the right button


    local mousePressOk = true; -- false when the last press call failed and needs retrying
    local mouse2PressOk = true;
    local lastMouseAt = tick() * 1000; -- when a button last actually went down or up

    local function holdMouse() -- presses left click once, idempotently
    	if mouseHeld and mousePressOk then
    		return;
    	end;
    	mouseHeld = true; -- flag first, so a throwing press still leaves a release owed
    	lastMouseAt = tick() * 1000;
    	mousePressOk = pcall(mouse1press) and true or false; -- a failed press is retried next frame
    end;

    local function releaseMouse() -- releases left click if we believe it is down
    	if not mouseHeld then
    		return;
    	end;
    	mouseHeld = false;
    	mousePressOk = true;
    	lastMouseAt = tick() * 1000;
    	pcall(mouse1release);
    end;

    local function holdMouse2() -- presses right click, no-op when unsupported
    	if not hasMouse2 or (mouse2Held and mouse2PressOk) then
    		return;
    	end;
    	mouse2Held = true;
    	lastMouseAt = tick() * 1000;
    	mouse2PressOk = pcall(mouse2press) and true or false;
    end;

    local function releaseMouse2() -- releases right click if we believe it is down
    	if not mouse2Held then
    		return;
    	end;
    	mouse2Held = false;
    	mouse2PressOk = true;
    	lastMouseAt = tick() * 1000;
    	pcall(mouse2release);
    end;

    local function releaseAllMouse() -- the catch-all used by every reset path
    	releaseMouse();
    	releaseMouse2();
    end;

    local hasMouseMove = type(mousemoveabs) == "function"; -- gun mode cannot aim without it

    local function moveMouse(x, y) -- moves the cursor to absolute screen pixels
    	if not hasMouseMove then
    		return false;
    	end;
    	return (pcall(mousemoveabs, math.floor(x + .5), math.floor(y + .5)));
    end;

    local function getCharacter() -- the local character model, however it is reachable
    	local player = getLocalPlayer();
    	if not player then
    		return nil;
    	end;
    	return player.Character or (workspace and findChild(workspace, player.Name));
    end;

    local function equipRod() -- taps the configured hotbar key
    	if CONFIG.equipKey then
    		pressSlot(CONFIG.equipKey);
    	end;
    end;

    local function heldToolState() -- true/false if a tool is held, nil when unreadable
    	local character = getCharacter();
    	if not character then
    		return nil;
    	end;
    	local kids = getChildren(character);
    	if #kids == 0 then -- an empty read means the character is not loaded yet
    		return nil;
    	end;
    	for _, child in ipairs(kids) do
    		if child.ClassName == "Tool" then
    			return true;
    		end;
    	end;
    	return false;
    end;

    local function holdingRod() -- true only when the tool already in hand looks like a rod
    	local character = getCharacter();
    	if not character then
    		return false;
    	end;
    	for _, child in ipairs(getChildren(character)) do
    		if child.ClassName == "Tool" and tostring(child.Name):lower():find("rod", 1, true) then
    			return true;
    		end;
    	end;
    	return false;
    end;

    local EQUIP = { done = true, startedAt = 0, pressedAt = 0, attempts = 0 }; -- rod-equip progress

    local function beginEquip(now) -- arms the equip sequence
    	EQUIP.done = false;
    	EQUIP.startedAt = now;
    	EQUIP.pressedAt = 0;
    	EQUIP.attempts = 0;
    end;


    local function equipStep(now) -- drives the equip retry loop, returns true once settled
    	if EQUIP.done then
    		return true;
    	end;

    	if EQUIP.attempts == 0 then -- first frame: send the press
    		if holdingRod() then -- already out; pressing the slot key again would just unequip it
    			EQUIP.done = true;
    			return true;
    		end;
    		equipRod();
    		EQUIP.attempts = 1;
    		EQUIP.pressedAt = now;
    		return false;
    	end;

    	if (now - EQUIP.startedAt) >= CONFIG.equipSettleMs then -- absolute deadline
    		EQUIP.done = true;
    		return true;
    	end;

    	if (now - EQUIP.pressedAt) < CONFIG.equipVerifyMs then -- a press needs time to land
    		return false;
    	end;

    	local held = heldToolState();
    	if held == true then -- rod confirmed in hand
    		EQUIP.done = true;
    		return true;
    	end;
    	if held == nil then -- unreadable, so wait rather than press again
    		return false;
    	end;

    	if EQUIP.attempts >= CONFIG.equipAttempts then -- out of retries
    		EQUIP.done = true;
    		return true;
    	end;

    	equipRod(); -- nothing in hand, so press again
    	EQUIP.attempts = EQUIP.attempts + 1;
    	EQUIP.pressedAt = now;
    	return false;
    end;

    local function readScalePercent(addr, axisOffset) -- reads a UDim2 scale component as 0-100
    	if not addr then
    		return nil;
    	end;
    	local scale = readFloat(addr + OFFSETS.FrameSizeX + axisOffset);
    	if not isFinite(scale) or scale < -0.05 or scale > 1.5 then -- outside this band the read missed
    		return nil;
    	end;
    	return clampn(scale * 100.0, .0, 100.0);
    end;

    local function readFillPercent(addr) -- reel progress lives in the X scale
    	return readScalePercent(addr, 0);
    end;

    local function getPowerAddr(now) -- cached address of the cast power bar above the character
    	-- The billboard dies with every cast, so the cache is never trusted - and one kept from
    	-- an earlier cast is not even asked for its parent: it may be freed by then, and that
    	-- one read per cast is the same pattern as the old crash after hundreds of catches.
    	if UI.powerBar and (now - UI.powerAt) < REFRESH.power then
    		local live = liveAddr(UI.powerBar, UI.powerAddr);
    		if live then
    			return live;
    		end;
    	end;
    	local character = getCharacter();
    	local hrp = character and findChild(character, "HumanoidRootPart");
    	local power = hrp and findChild(hrp, "power"); -- the billboard GUI
    	UI.powerBar = power and findFrameNamed(power, "bar") or nil; -- keep the instance so liveness stays checkable
    	UI.powerAddr = getAddress(UI.powerBar);
    	UI.powerAt = now;
    	return UI.powerAddr;
    end;

    local function readPowerPercent(addr) -- the power bar fills on the Y scale
    	return readScalePercent(addr, 8);
    end;

    local function getCastThreshold() -- sanitised cast power from CONFIG
    	return clampn(CONFIG.castPower, 1.0, 100.0);
    end;

    local HYBRID_TUNING = { -- constants for the reel controller's tracking law
    		EdgeBoundary = .1, -- how close to a travel limit still counts as pinned against it
    		StaleTickS = .12, -- a true safety net: longer than any plausible game frame
    		MinDwellS = .033, -- shortest press or release the game is guaranteed to notice; 0 disables
    		WarmupS = .12, -- crude deadzone tracking until the velocity estimates mean something
    		MaxVelocity = 3.0, -- sanity clamp on a measured velocity, in track widths per second
    		BarVelTauS = .015, FishVelTauS = .015, -- smoothing time constants for the two velocity estimates
    		Kp = 200.0, Ki = 1.0, Kd = 2.0, -- on the braked error; Kp is high enough to go bang-bang off target
    		IntegralClamp = .2, -- the integral trims the duty directly, so this bound is a duty too
    		HoldAccel = .3, DropAccel = .15, -- assumed bar acceleration held and released, per second squared;
    	};                                 -- deliberately under-stated, which makes the brake curve cautious

    local ReelController = {}; -- one instance drives one minigame's mouse button
    ReelController.__index = ReelController;

    function ReelController.new(hold, release) -- bound to the press/release pair it owns
    	local self = setmetatable({}, ReelController);
    	self.hold = hold;
    	self.release = release;
    	self:Reset();
    	return self;
    end;

    function ReelController.Reset(self) -- clears all history so a new fish starts clean
    	local now = tick();
    	self.samples = 0;
    	self.lastTickAt = now;
    	self.warmUntil = now + HYBRID_TUNING.WarmupS;
    	self.prevFish = .0;
    	self.prevBar = .0;
    	self.lastFishRaw = nil;
    	self.lastBarRaw = nil;
    	self.fishVel = .0;
    	self.barVel = .0;
    	self.errInt = .0;
    	self.duty = .5;
    	self.sigma = .0;
    	self.slotAt = .0;
    	self.pressed = false;
    	self.lastHalfWidth = nil;
    end;

    function ReelController._Plan(self, target, barCenter, dt, s) -- the duty this game frame deserves
    	local rawFish = (target - self.prevFish) / dt;
    	local rawBar = (barCenter - self.prevBar) / dt;
    	self.prevFish, self.prevBar = target, barCenter;

    	local aF = 1.0 - math.exp(-dt / s.FishVelTauS); -- time-based, so the loop rate cannot change the filtering
    	local aB = 1.0 - math.exp(-dt / s.BarVelTauS);
    	self.fishVel = self.fishVel + (aF * (clampn(rawFish, -s.MaxVelocity, s.MaxVelocity) - self.fishVel));
    	self.barVel = self.barVel + (aB * (clampn(rawBar, -s.MaxVelocity, s.MaxVelocity) - self.barVel));

    	local relVel = self.barVel - self.fishVel; -- the closing speed that still has to be bled off
    	local decel = (relVel > .0) and s.DropAccel or s.HoldAccel;
    	local brake = (relVel * math.abs(relVel)) / (2.0 * decel); -- how far the bar coasts before it matches the fish
    	local slack = (target - barCenter) - brake; -- the ground left over once that coast is spent

    	self.errInt = clampn(self.errInt + ((s.Ki * slack) * dt), -s.IntegralClamp, s.IntegralClamp);
    	local span = s.HoldAccel + s.DropAccel; -- holding accelerates by HoldAccel, letting go by -DropAccel,
    	self.duty = clampn(((((s.Kp * slack) - (s.Kd * relVel)) + s.DropAccel) / span) + self.errInt, .0, 1.0); -- so this is the fraction of frames to hold
    end;

    function ReelController.UpdateHybrid(self, fishCenter, barCenter, barWidth01) -- one frame of steering
    	local s = HYBRID_TUNING;
    	local now = tick();
    	local halfWidth = (barWidth01 >= .01) and math.min(.5, barWidth01 * .5) or s.EdgeBoundary;
    	local minCenter, maxCenter = halfWidth, 1.0 - halfWidth; -- travel limits of the bar's centre
    	local edge = math.min(s.EdgeBoundary, math.max(.004, halfWidth * .5));
    	local target = clampn(fishCenter, minCenter, maxCenter); -- never chase past where the bar can go

    	if self.lastHalfWidth == nil then -- first frame, just record the width
    		self.lastHalfWidth = halfWidth;
    	elseif math.abs(halfWidth - self.lastHalfWidth) > .004 then -- the bar resized mid-fight
    		self.lastHalfWidth = halfWidth;
    		self.errInt = .0; -- windup describes geometry that no longer exists
    	end;

    	local err = target - barCenter;

    	if (barCenter < (minCenter + edge) and err > 0) -- pinned to the left edge, pull right
    		or (barCenter > (maxCenter - edge) and err < 0) then -- pinned to the right edge, let go
    		if barCenter ~= self.lastBarRaw then -- only a real sample may carry the estimator forward
    			self.lastFishRaw, self.lastBarRaw = fishCenter, barCenter;
    			self.lastTickAt = now;
    			self.prevFish, self.prevBar = target, barCenter; -- warm for the frame it comes off the edge
    		end;
    		self.slotAt = now - s.MinDwellS; -- a bar coming off the edge answers on the next frame
    		self.pressed = err > 0;
    		if self.pressed then
    			self.hold();
    		else
    			self.release();
    		end;
    		return;
    	end;

    	-- The bar only moves when the game advances the minigame, so a reading that repeats is
    	-- the same frame seen twice and its velocity is a fake zero. A fixed stale timer shorter
    	-- than a frame fires twice per frame below 50 fps and empties the estimate, so the gate
    	-- keys off the bar itself and the timer is only a freeze backstop.
    	local dt = now - self.lastTickAt;
    	if barCenter == self.lastBarRaw then
    		if dt < s.StaleTickS then
    			return; -- mid game-frame: the button keeps the state this frame was handed
    		end;
    		self.lastFishRaw, self.lastBarRaw = fishCenter, barCenter; -- genuinely frozen, not mid-frame
    		self.lastTickAt = now;
    		self.prevFish, self.prevBar = target, barCenter;
    		if err > 0 then
    			self.hold();
    		else
    			self.release();
    		end;
    		return;
    	end;
    	self.lastFishRaw, self.lastBarRaw = fishCenter, barCenter;
    	self.lastTickAt = now;
    	dt = clampn(dt, .001, .1);

    	self.samples = self.samples + 1;
    	if self.samples <= 2 or now < self.warmUntil then -- no usable velocity yet, so track by deadzone
    		self.prevFish, self.prevBar = target, barCenter;
    		if err > math.max(.015, barWidth01 * .04) then
    			self.hold();
    		else
    			self.release();
    		end;
    		return;
    	end;

    	self:_Plan(target, barCenter, dt, s);

    	-- The game samples the mouse once a frame, so a press shorter than a frame can be missed
    	-- outright. Switch on a slot no shorter than a frame and let delta-sigma spread the duty
    	-- across slots, which keeps the average exact without ever asking for a press too short
    	-- to register.
    	if (now - self.slotAt) >= s.MinDwellS then
    		self.slotAt = now;
    		self.sigma = self.sigma + self.duty;
    		self.pressed = self.sigma >= 1.0;
    		if self.pressed then
    			self.sigma = self.sigma - 1.0;
    		end;
    	end;
    	if self.pressed then
    		self.hold();
    	else
    		self.release();
    	end;
    end;

    function ReelController.Update(self, fishPos, playerbarPos, barWidth) -- validates the reads then steers
    	if not (isFinite(fishPos) and isFinite(playerbarPos)) then -- a bad read must not move the bar
    		self.release();
    		return;
    	end;
    	if not isFinite(barWidth) or barWidth < .001 then
    		barWidth = .001;
    	elseif barWidth > 2.0 then
    		barWidth = 2.0;
    	end;
    	return self:UpdateHybrid(fishPos, playerbarPos, barWidth);
    end;

    local reelCtrl = ReelController.new(holdMouse, releaseMouse); -- left click, the single-catch path
    local reelCtrl2 = ReelController.new(holdMouse2, releaseMouse2); -- right click, only for a second minigame

    local REEL_BUTTONS = { -- indexed 1 and 2 to match reelBind below
    		{ ctrl = reelCtrl, release = releaseMouse },
    		{ ctrl = reelCtrl2, release = releaseMouse2 },
    	};

    local reelBind = { nil, nil }; -- barAddr each button owns; sticky for the life of the minigame

    local function unbindReelButton(index) -- frees a button and wipes its controller history
    	reelBind[index] = nil;
    	REEL.driven[index] = nil; -- the fast steering pass reads this, so it goes first
    	REEL_BUTTONS[index].ctrl:Reset();
    	REEL_BUTTONS[index].release();
    end;

    local function unbindAllReelButtons() -- the reset used by every phase change
    	for index = 1, #REEL_BUTTONS do
    		unbindReelButton(index);
    	end;
    end;

    local warnedNoMouse2 = false; -- so the missing-mouse2 notice fires once

    local function warnMissingMouse2() -- tells the user why only one fish is being reeled
    	if warnedNoMouse2 then
    		return;
    	end;
    	warnedNoMouse2 = true;
    	notify("Second reel found but mouse2press() is missing - only the left-click fish will be reeled.", "", 6);
    end;

    local function reelBindIndexFor(barAddr) -- which button already owns this bar, if any
    	if not barAddr then
    		return nil;
    	end;
    	for index = 1, #REEL_BUTTONS do
    		if reelBind[index] == barAddr then
    			return index;
    		end;
    	end;
    	return nil;
    end;

    local STATE = { -- the fishing cycle's phase and per-cycle bookkeeping
    		phase = "OFF",
    		castStartedAt = 0,
    		castPressAt = 0,
    		castReleasedAt = 0,
    		castBarSeen = false,
    		castArmed = false,
    		reelDownSeen = false,
    		castThreshold = 90.0,
    		castWaitTimeoutMs = 15000,
    		castChargeLastPct = nil,
    		castChargeMotionAt = 0,
    		shakeStartedAt = 0,
    		reelClosedAt = 0,
    		lastReelCaught = false,
    		lastShakedAt = 0,
    		shakeCount = 0,
    		shakingIntervalMs = 25,
    		shakeSeen = false,
    		shakeUnstickAt = 0,
    		maxProgress = 0,
    		reelStartedAt = 0,
    		reelMotionAt = 0,
    		reelSignature = nil,
    		reelRecovered = false,
    		castEverSeen = false,
    		reelDone = {},
    		reelDoneCount = 0,
    		doneAt = 0,
    		caught = 0,
    		lost = 0,
    		timeouts = 0,
    		nukes = 0,
    		stabs = 0,
    	};

    local NUKE_NAME_HINTS = { "nuke", "bomb", "defuse" }; -- fuzzy names the nuke GUI might use

    local NUKE_GUI_CLASSES = { -- classes that could be the moving indicator
    		Frame = true, ImageLabel = true, ImageButton = true,
    		TextLabel = true, TextButton = true, ScrollingFrame = true, CanvasGroup = true,
    	};

    local function boundedFloat(value, limit) -- nil unless the read landed in a plausible range
    	return (isFinite(value) and math.abs(value) <= limit) and value or nil;
    end;

    local NUKE_AXES = { -- the three ways the bar could be animated, each with its own read
    		{ unit = "scale", move = "scaleMove", first = "scale0", last = "lastScale",
    		  read = function(addr)
    				if not addr then -- the candidate was freed, so there is nothing safe to dereference
    					return nil;
    				end;
    				return boundedFloat(readFloat(addr + OFFSETS.FramePositionX), 2.0); -- UDim2 X scale
    			end },
    		{ unit = "offset", move = "offMove", first = "off0", last = "lastOff",
    		  read = function(addr)
    				if not addr then
    					return nil;
    				end;
    				local offset = readInt(addr + OFFSETS.FramePositionX + 4); -- UDim2 X offset in pixels
    				return (math.abs(offset) <= 4000) and offset or nil;
    			end },
    		{ unit = "rot", move = "rotMove", first = "rot0", last = "lastRot",
    		  read = function(addr)
    				if not addr then
    					return nil;
    				end;
    				return boundedFloat(readFloat(addr + OFFSETS.FrameRotation), 360.0); -- a dial instead of a bar
    			end },
    	};

    local NUKE_AXIS = {}; -- unit name -> axis entry, for lookups after locking
    for _, axis in ipairs(NUKE_AXES) do
    	NUKE_AXIS[axis.unit] = axis;
    end;

    local NUKE = { -- cached nuke GUI reference and its refresh timestamps
    		gui = nil, guiAddr = nil, guiClass = nil, at = 0,
    		deepAt = 0,
    		kids = nil, nestIdx = 0, -- PlayerGui's children from the last name pass, and where the nested pass is up to
    		ignoredAddr = nil, -- set after a timeout so one bad GUI is skipped
    	};

    local function nameMatchesNuke(name) -- loose match against the hint list
    	local lower = tostring(name or ""):lower();
    	for _, hint in ipairs(NUKE_NAME_HINTS) do
    		if lower:find(hint, 1, true) then
    			return true;
    		end;
    	end;
    	return false;
    end;

    local function refreshNukeRefs(now, force) -- finds the nuke GUI, cheaply first then thoroughly
    	if not force and (now - NUKE.at) < REFRESH.nuke then
    		return;
    	end;
    	if NUKE.gui and (now - NUKE.at) > 1000 then -- unwatched for a while (macro paused): drop it unread
    		NUKE.gui, NUKE.guiAddr, NUKE.guiClass = nil, nil, nil;
    	end;
    	NUKE.at = now;
    	local pg = getPlayerGui(now);
    	if not pg then
    		NUKE.gui, NUKE.guiAddr, NUKE.guiClass = nil, nil, nil;
    		return;
    	end;

    	local found = findChild(pg, "NukeMinigame"); -- the known name, one cheap lookup

    	if not found and NUKE.gui then -- a fuzzy match stays valid while still parented
    		local ok, parent = pcall(readProp, NUKE.gui, "Parent");
    		if ok and parent then
    			found = NUKE.gui;
    		end;
    	end;

    	if not found and (force or (now - NUKE.deepAt) >= REFRESH.nukeDeep) then -- slower fuzzy sweep
    		NUKE.deepAt = now;
    		NUKE.kids = getChildren(pg);
    		for _, child in ipairs(NUKE.kids) do
    			if nameMatchesNuke(child.Name) then
    				found = child;
    				break
    			end;
    		end;
    	end;
    
    	-- One level down as well. Opening a ScreenGui is a GetChildren call, and doing all of them
    	-- at once stalled a frame every second, so a few are opened per pass, round-robin. The
    	-- listing itself is taken fresh each pass: PlayerGui holds GUIs Fisch destroys every
    	-- cycle (the reel, the shake prompt), and opening one from a listing kept since an
    	-- earlier pass walked the children of a GUI that could already be freed.
    	local kids = nil;
    	if not found then
    		kids = (NUKE.deepAt == now and NUKE.kids) or getChildren(pg);
    	end;
    	if not found and kids and #kids > 0 then
    		for _ = 1, math.min(REFRESH.nukeNestedPer, #kids) do
    			NUKE.nestIdx = (NUKE.nestIdx % #kids) + 1;
    			for _, sub in ipairs(getChildren(kids[NUKE.nestIdx])) do
    				if nameMatchesNuke(sub.Name) then
    					found = sub;
    					break
    				end;
    			end;
    			if found then
    				break
    			end;
    		end;
    	end;

    	if found then
    		local addr = getAddress(found);
    		if NUKE.ignoredAddr and addr == NUKE.ignoredAddr then -- previously timed out, stay away
    			NUKE.gui, NUKE.guiAddr, NUKE.guiClass = nil, nil, nil;
    			return;
    		end;
    		NUKE.gui, NUKE.guiAddr, NUKE.guiClass = found, addr, found.ClassName;
    	else
    		NUKE.gui, NUKE.guiAddr, NUKE.guiClass = nil, nil, nil;
    		NUKE.ignoredAddr = nil; -- the GUI is gone, so the next one gets a fresh chance
    	end;
    end;

    local function nukeActive(now) -- true while the nuke minigame is on screen
    	refreshNukeRefs(now);
    	if not NUKE.gui then
    		return false;
    	end;
    	if NUKE.guiClass == "ScreenGui" then
    		return isEnabled(NUKE.gui, NUKE.guiAddr);
    	end;
    	return isVisible(NUKE.gui, NUKE.guiAddr);
    end;

    local function collectNukeCandidates(gui) -- every frame in the GUI that could be the mover
    	local list = {};
    	local rootAddr = getAddress(gui);
    	local queue, index = { { inst = gui, addr = rootAddr } }, 1;
    	while index <= #queue and (#list < 48 and index <= 128) do -- bounded walk
    		local node = queue[index];
    		index = index + 1;
    		for _, child in ipairs(getChildren(node.inst)) do
    			local class = child.ClassName;
    			local addr = getAddress(child);
    			if addr then
    				if NUKE_GUI_CLASSES[class] then
    					local candidate = { inst = child, addr = addr, parent = node.inst, parentAddr = node.addr }; -- instances let the addresses be revalidated
    					for _, axis in ipairs(NUKE_AXES) do
    						candidate[axis.move] = .0; -- zero the travel accumulators
    					end;
    					list[#list + 1] = candidate;
    				end;
    				queue[#queue + 1] = { inst = child, addr = addr };
    			end;
    		end;
    	end;
    	return list;
    end;

    local NLOG = { lines = {}, startAt = tick() * 1000, lastWriteAt = 0 }; -- nuke debug log buffer

    local function nlog(msg) -- appends a timestamped line, capped at 800
    	local t = (tick() * 1000 - NLOG.startAt) / 1000.0;
    	NLOG.lines[#NLOG.lines + 1] = string.format("%9.2fs  %s", t, msg);
    	while #NLOG.lines > 800 do
    		table.remove(NLOG.lines, 1);
    	end;
    end;

    local function writeNukeLog() -- flushes the buffer to disk when file I/O exists
    	if type(writefile) ~= "function" then
    		return;
    	end;
    	pcall(writefile, "nuke_log.txt", table.concat(NLOG.lines, "\n"));
    end;

    local nukeCtrl = { -- state for balancing the nuke bar with Q and E
    		gui = nil, candidates = {}, locked = nil, unit = "scale",
    		target = .0, halfRange = .5, deadzone = .05,
    		beganAt = 0, sampleStart = 0, lastTapAt = 0, lastPos = nil,
    		lastMoveAt = 0, warned = false, invalids = 0, taps = 0,
    		marker = nil, markerAddr = nil, lastStatusAt = 0,
    	};

    function nukeCtrl.Begin(self, gui, now) -- (re)starts detection for a nuke GUI
    	self.gui = gui;
    	self.locked = nil;
    	self.beganAt = now;
    	self.sampleStart = now;
    	self.lastTapAt = 0;
    	self.lastPos = nil;
    	self.lastMoveAt = now;
    	self.warned = false;
    	self.invalids = 0;
    	self.taps = 0;
    	self.lastStatusAt = 0;

    	local center = findChild(gui, "Center"); -- expected layout, used only as a scoring hint
    	local marker = center and findChild(center, "Marker");
    	self.marker = marker;
    	self.markerAddr = getAddress(marker);

    	self.candidates = collectNukeCandidates(gui);
    	nlog(string.format("begin: candidates=%d markerAddr=%s", #self.candidates, tostring(self.markerAddr)));
    end;

    function nukeCtrl.Sample(self) -- accumulates how far each candidate has travelled on each axis
    	for _, c in ipairs(self.candidates) do
    		for _, axis in ipairs(NUKE_AXES) do
    			local value = axis.read(liveAddr(c.inst, c.addr)); -- the frame may have been freed since the scan
    			if value then
    				local last = c[axis.last];
    				if last ~= nil then
    					c[axis.move] = c[axis.move] + math.abs(value - last);
    				end;
    				if c[axis.first] == nil then
    					c[axis.first] = value; -- the resting value, used as the target
    				end;
    				c[axis.last] = value;
    			end;
    		end;
    	end;
    end;

    function nukeCtrl.TryLock(self, now) -- picks the candidate that actually moves and how it moves
    	if (now - self.sampleStart) < 250 then -- need a sampling window first
    		return;
    	end;
    	local best, bestScore, bestUnit = nil, .0, nil;
    	local markerAddr = liveAddr(self.marker, self.markerAddr); -- a stale marker pointer can collide with a recycled candidate
    	for _, c in ipairs(self.candidates) do
    		local parentAddr = liveAddr(c.parent, c.parentAddr);
    		local parentW = parentAddr and math.abs(readInt(parentAddr + OFFSETS.FrameSizeX + 4)) or 0;
    		local offScore = (c.offMove > 1) and (c.offMove / math.max(80, parentW)) or .0; -- normalise pixels
    		local rotScore = c.rotMove / 90.0; -- normalise degrees
    		local unit, score = "scale", c.scaleMove;
    		if offScore > score then
    			unit, score = "offset", offScore;
    		end;
    		if rotScore > score then
    			unit, score = "rot", rotScore;
    		end;
    		if markerAddr and c.addr == markerAddr then
    			score = score * 2.0; -- prefer the expected node when it also moves
    		end;
    		if score > bestScore then
    			best, bestScore, bestUnit = c, score, unit;
    		end;
    	end;
    	if not best or bestScore < .004 then -- nothing moved enough to be the bar
    		return;
    	end;
    	self.locked = best;
    	self.unit = bestUnit;
    	if bestUnit == "scale" then
    		self.target = (markerAddr and best.addr == markerAddr) and .5 or (best.scale0 or .5); -- centre of the track
    		self.halfRange = .5;
    	elseif bestUnit == "offset" then
    		local bestParent = liveAddr(best.parent, best.parentAddr);
    		local parentW = bestParent and math.abs(readInt(bestParent + OFFSETS.FrameSizeX + 4)) or 0;
    		self.target = best.off0 or .0;
    		self.halfRange = (parentW > 40) and (parentW / 2) or 200;
    	else
    		self.target = best.rot0 or .0;
    		self.halfRange = 30.0;
    	end;
    	self.deadzone = CONFIG.nukeDeadzoneFrac * self.halfRange;
    	self.lastPos = nil;
    	self.lastMoveAt = now;
    	nlog(string.format("lock: unit=%s marker=%s target=%.3f range=%.1f score=%.4f",
    		self.unit, tostring(markerAddr ~= nil and best.addr == markerAddr), self.target, self.halfRange, bestScore));
    end;

    function nukeCtrl.ReadPos(self) -- current position of the locked element on its axis
    	return NUKE_AXIS[self.unit].read(liveAddr(self.locked.inst, self.locked.addr)); -- the locked frame can be freed mid-minigame
    end;

    function nukeCtrl.Update(self, now) -- one frame of nuke balancing
    	if (now - NLOG.lastWriteAt) >= 2000 then -- flush the log every couple of seconds
    		NLOG.lastWriteAt = now;
    		writeNukeLog();
    	end;

    	if not self.locked then -- still working out what to watch
    		self:Sample();
    		self:TryLock(now);
    		if not self.locked and (not self.warned and (now - self.beganAt) > 4000) then
    			self.warned = true;
    			nlog("no mover found after 4s");
    		end;
    		return;
    	end;

    	local pos = self:ReadPos();
    	if pos == nil then -- the read stopped landing
    		self.invalids = self.invalids + 1;
    		if self.invalids > 30 and self.gui then
    			nlog("locked read went invalid, rescanning");
    			self:Begin(self.gui, now);
    		end;
    		return;
    	end;
    	self.invalids = 0;

    	local err = pos - self.target;
    	local vel = (self.lastPos ~= nil) and (pos - self.lastPos) or .0;
    	self.lastPos = pos;
    	if math.abs(vel) > (self.halfRange * .0005) then -- ignore jitter when timing staleness
    		self.lastMoveAt = now;
    	end;

    	if (now - self.lastMoveAt) > 1500 then -- locked onto something static, try again
    		nlog("locked element static for 1.5s, rescanning");
    		self.locked = nil;
    		self.candidates = collectNukeCandidates(self.gui);
    		self.sampleStart = now;
    		return;
    	end;

    	if (now - self.lastStatusAt) >= 400 then -- periodic status line for the log
    		self.lastStatusAt = now;
    		nlog(string.format("pos=%.3f err=%.3f vel=%.4f taps=%d", pos, err, vel, self.taps));
    	end;

    	local predErr = err + (vel * CONFIG.nukePrediction); -- where it will be, not where it is
    	if math.abs(predErr) <= self.deadzone then -- close enough, do nothing
    		return;
    	end;

    	if (err * vel) < 0 and (math.abs(vel) * CONFIG.nukePrediction) >= math.abs(err) then -- already coming back
    		return;
    	end;

    	local pressLeft = predErr > 0;
    	local urgency = math.min(1.0, math.abs(predErr) / self.halfRange);
    	local interval = math.max(25, CONFIG.nukeTapIntervalMs * (1.35 - urgency)); -- tap faster the further off it is
    	if (now - self.lastTapAt) < interval then
    		return;
    	end;
    	if tapKey(pressLeft and KEYS.Q or KEYS.E, CONFIG.nukeTapHoldMs, now) then
    		self.lastTapAt = now;
    		self.taps = self.taps + 1;
    		nlog(string.format("tap %s err=%.3f pred=%.3f vel=%.4f", pressLeft and "Q" or "E", err, predErr, vel));
    	end;
    end;

    local function finishNuke(success) -- leaves the nuke phase and hands back to the fishing loop
    	unbindAllReelButtons();
    	releaseAllMouse();
    	flushKeys();
    	nlog(string.format("EXIT success=%s taps=%d after=%.1fs", tostring(success), nukeCtrl.taps, (tick() * 1000 - nukeCtrl.beganAt) / 1000.0));
    	writeNukeLog();
    	if success then
    		STATE.nukes = STATE.nukes + 1;
    		print("Nuke survived (" .. STATE.nukes .. " total)");
    	end;

    	STATE.lastReelCaught = false;
    	STATE.doneAt = 0;
    	STATE.phase = "DONE";
    end;

    local function updateNuke(now) -- the NUKE phase handler
    	releaseAllMouse(); -- nothing here uses the mouse
    	if not nukeActive(now) then -- the GUI closed, so we survived it
    		finishNuke(true);
    		return;
    	end;
    	if (now - nukeCtrl.beganAt) > CONFIG.nukeTimeoutMs then -- stuck, so blacklist this GUI
    		NUKE.ignoredAddr = NUKE.guiAddr;
    		finishNuke(false);
    		return;
    	end;
    	if not nukeCtrl.locked and (now - nukeCtrl.beganAt) > CONFIG.nukeLockTimeoutMs then -- nothing in it moves
    		nlog("no mover found, treating this GUI as a false positive");
    		NUKE.ignoredAddr = NUKE.guiAddr;
    		finishNuke(false);
    		return;
    	end;
    	nukeCtrl:Update(now);
    end;

    local STAB = { -- spear minigame state; the GUI's existence is the whole detection
    		gui = nil, guiAddr = nil, guiClass = nil, at = 0,
    		ignoredAddr = nil,
    		running = false, startedAt = 0,
    		pending = nil, releaseAt = 0, nextPressAt = 0,
    		right = false, taps = 0,
    	};

    local function refreshStabRefs(now, force) -- recaches PlayerGui.stab, rate-limited
    	if not force and (now - STAB.at) < REFRESH.stab then
    		return;
    	end;
    	STAB.at = now;

    	local pg = getPlayerGui(now);
    	local found = pg and findChild(pg, CONFIG.stabGuiName) or nil;
    	if not found then
    		STAB.gui, STAB.guiAddr, STAB.guiClass = nil, nil, nil;
    		STAB.ignoredAddr = nil; -- the GUI is destroyed between fights, so clear the blacklist
    		return;
    	end;

    	local okClass, class = pcall(readProp, found, "ClassName");
    	STAB.gui, STAB.guiAddr = found, getAddress(found);
    	STAB.guiClass = (okClass and class) or nil;
    end;

    local function stabActive(now) -- true while a stab minigame worth clicking is up
    	refreshStabRefs(now);
    	if not STAB.gui then
    		return false;
    	end;
    	if STAB.ignoredAddr and STAB.guiAddr == STAB.ignoredAddr then -- timed out earlier
    		return false;
    	end;
    	if STAB.guiClass == "ScreenGui" then
    		return isEnabled(STAB.gui, STAB.guiAddr);
    	end;
    	return isVisible(STAB.gui, STAB.guiAddr);
    end;

    local warnedStabMouse2 = false; -- so the left-click-only notice fires once

    local function stabRelease() -- releases whichever button the last tap pressed
    	local pending = STAB.pending;
    	STAB.pending = nil;
    	if pending == 2 then
    		releaseMouse2();
    	elseif pending == 1 then
    		releaseMouse();
    	end;
    end;

    local function stabTick(now) -- alternates left and right clicks while the minigame runs
    	local nextButton = (STAB.right and hasMouse2) and 2 or 1;

    	if STAB.pending then -- a button is currently down
    		if now < STAB.releaseAt then
    			return;
    		end;
    		local released = STAB.pending;
    		stabRelease();
    		if released == nextButton then -- never re-press the same button in the frame it was released
    			return;
    		end;
    	end;

    	if now < STAB.nextPressAt then
    		return;
    	end;

    	local right = nextButton == 2;
    	if STAB.right and not hasMouse2 and not warnedStabMouse2 then
    		warnedStabMouse2 = true;
    	end;

    	if right then -- flag before pressing, so a throwing press still leaves a release owed
    		STAB.pending = 2;
    		holdMouse2();
    	else
    		STAB.pending = 1;
    		holdMouse();
    	end;
    	STAB.taps = STAB.taps + 1;
    	STAB.right = not STAB.right; -- alternate for the next tap
    	STAB.releaseAt = now + CONFIG.stabHoldMs;
    	STAB.nextPressAt = now + CONFIG.stabIntervalMs;
    end;

    local function beginStab(now) -- starts a stab fight
    	STAB.running = true;
    	STAB.startedAt = now;
    	STAB.taps = 0;
    	STAB.pending = nil;
    	STAB.releaseAt = 0;
    	STAB.nextPressAt = 0;
    	STAB.right = CONFIG.stabStartRight and true or false;
    	releaseAllMouse();
    end;

    local function endStab(now, completed) -- stops clicking and reports the result
    	STAB.running = false;
    	STAB.pending = nil;
    	releaseAllMouse();

    	if completed then
    		STATE.stabs = STATE.stabs + 1;
    	end;
    end;

    local function stabStep(now) -- spear mode's whole per-frame step
    	if not isRobloxActive() then -- alt-tabbed, so let go but keep the fight state
    		if STAB.pending then
    			stabRelease();
    		end;
    		return;
    	end;

    	local active = stabActive(now);
    	if active then
    		if not STAB.running then
    			beginStab(now);
    		end;
    	elseif STAB.running then -- the GUI closed, so the fish is landed
    		endStab(now, true);
    		return;
    	else
    		return; -- nothing to do
    	end;

    	if (now - STAB.startedAt) > CONFIG.stabTimeoutMs then -- stuck, so blacklist this GUI
    		STAB.ignoredAddr = STAB.guiAddr;
    		endStab(now, false);
    		return;
    	end;

    	stabTick(now);
    end;

    local function recentReelClose(now) -- true just after a reel closed, while its GUI lingers
    	now = now or (tick() * 1000);
    	return STATE.reelClosedAt > 0 and (now - STATE.reelClosedAt) < 700;
    end;

    local function startCycle() -- resets every per-cycle field and picks the opening phase
    	unbindAllReelButtons();
    	releaseAllMouse();

    	local now = tick() * 1000;
    	STATE.castStartedAt = now;
    	STATE.castPressAt = 0;
    	STATE.castReleasedAt = 0;
    	STATE.castBarSeen = false;
    	STATE.castArmed = false;
    	STATE.reelDownSeen = false;
    	STATE.castChargeLastPct = nil;
    	STATE.castChargeMotionAt = 0;
    	STATE.shakeStartedAt = 0;
    	STATE.lastShakedAt = 0;
    	STATE.shakeCount = 0;
    	STATE.shakeSeen = false;
    	STATE.shakeUnstickAt = 0;
    	STATE.maxProgress = 0;
    	STATE.reelStartedAt = 0;
    	STATE.reelMotionAt = 0;
    	STATE.reelSignature = nil;
    	STATE.reelRecovered = false;
    	STATE.reelDone = {};
    	STATE.reelDoneCount = 0;
    	STATE.doneAt = 0;
    	STATE.castThreshold = getCastThreshold();
    	STATE.castWaitTimeoutMs = math.max(5000, CONFIG.castTimeoutMs);
    	STATE.shakingIntervalMs = CONFIG.shakeIntervalMs;

    	refreshReelRefs(now, true); -- force fresh lookups rather than reuse stale ones
    	refreshShakeRefs(now, true);
    	UI.powerAt = 0;

    	local stale = recentReelClose(now); -- a GUI still up from the last fish is not a new one
    	STATE.phase = (reelActive(now) and not stale) and "FISHING" or ((shakeUp(now) and not stale) and "SHAKE" or "CASTING");
    	STATE.shakeSeen = STATE.phase == "SHAKE";

    	if CONFIG.mode == "rod" and STATE.phase == "CASTING" and heldToolState() == false then -- empty hands before a cast, so tap the hotbar key first
    		beginEquip(now); -- equipStep gates the loop until the rod is confirmed, then casting resumes
    	end;
    end;

    local function resetToPhase(phase) -- drops everything held and parks on a phase
    	unbindAllReelButtons();
    	releaseAllMouse();
    	REEL.slots = {}; -- the bars are about to be destroyed; never carry their pointers into the next cycle
    	REEL.at = 0; -- and force a rediscovery rather than waiting out the refresh interval
    	STATE.phase = phase or "OFF";
    end;

    local function onCastTimeout(now, deadCast) -- decides what to do when a cast never worked out
    	STATE.timeouts = STATE.timeouts + 1;
    	if deadCast and CONFIG.reequipOnDeadCast and not STATE.castEverSeen then -- only before the run's first real cast
    		resetToPhase("OFF"); -- OFF makes equipStep gate the loop until the rod is back
    		beginEquip(now);
    		return;
    	end;
    	if CONFIG.castOnTimeout then
    		startCycle();
    	else
    		resetToPhase("OFF");
    	end;
    end;

    local function updateCasting(now) -- CASTING phase: hold the button until the power bar fills
    	-- The reel GUI outlives its own catch by longer than the recentReelClose grace, so a level
    	-- check here fires on the corpse of the last reel about 705ms after it closed and releases
    	-- the rod mid-charge -- which IS the weak cast. Wait until the reel has actually been seen
    	-- DOWN in this cycle; only then does an up reel mean a fresh bite. A reel that never clears
    	-- is caught by the charge deadline below, which recasts.
    	if not reelActive(now) then
    		STATE.reelDownSeen = true;
    	elseif STATE.reelDownSeen and not recentReelClose(now) then -- a fish bit early
    		releaseMouse();
    		STATE.castEverSeen = true; -- a reel proves the rod is in hand
    		STATE.phase = "FISHING";
    		return;
    	end;

    	if shakeUp(now) and not recentReelClose(now) then -- the cast already landed
    		releaseMouse();
    		STATE.castEverSeen = true; -- so does a landed cast
    		STATE.lastShakedAt = 0;
    		STATE.shakeSeen = true;
    		if STATE.castReleasedAt == 0 then
    			STATE.castReleasedAt = now;
    		end;
    		STATE.phase = "SHAKE";
    		return;
    	end;

    	if STATE.castStartedAt == 0 then
    		STATE.castStartedAt = now;
    	end;

    	-- The rod ignores a press that lands while the catch animation is still playing, and the
    	-- button is already down by then, so no later edge ever reaches it. Cycle the button until
    	-- the power bar shows up, rather than sitting on one dead press until the cast deadline.
    	if not mouseHeld then
    		if (now - STATE.castPressAt) >= CONFIG.castRepressGapMs then -- up long enough for a clean edge
    			holdMouse(); -- charging the cast
    			STATE.castPressAt = now;
    		end;
    	elseif not STATE.castBarSeen and (now - STATE.castPressAt) >= CONFIG.castRepressMs then
    		releaseMouse(); -- swallowed, so drop it and let the branch above press again
    		STATE.castPressAt = now;
    	end;

    	local powerAddr = getPowerAddr(now);

    	if not powerAddr then
    		local elapsed = now - STATE.castStartedAt;
    		if not STATE.castBarSeen and elapsed >= 2000 then -- never appeared, so the rod is likely missing
    			onCastTimeout(now, true);
    			return;
    		end;
    		if elapsed >= STATE.castWaitTimeoutMs then -- a bar that was seen and then vanished
    			onCastTimeout(now);
    		end;
    		return;
    	end;
    	STATE.castBarSeen = true;
    	STATE.castEverSeen = true; -- the rod is confirmed working for the rest of this run
    	local power = readPowerPercent(powerAddr);
    	if power then
    		-- A bar already reading full on the frame it is found was not charged by THIS cast: it is
    		-- the last one's fill, still on screen because the billboard outlives the throw by 2-3s.
    		-- Releasing on it throws at nothing. One sample below the threshold proves the charge
    		-- really restarted; until then the reading is somebody else's. A bar that never comes
    		-- down is dead, and the stall watchdog below recasts rather than waiting forever.
    		if not STATE.castArmed and power < STATE.castThreshold then
    			STATE.castArmed = true;
    		end;
    		if STATE.castArmed and power >= STATE.castThreshold then -- charged enough, let fly
    			releaseMouse();
    			STATE.castReleasedAt = now;
    			STATE.phase = "CASTED";
    			return;
    		end;
    	else
    		UI.powerAt = 0; -- unreadable, so re-resolve the address next frame
    	end;

    	local moving = (power ~= nil) and (STATE.castChargeLastPct == nil or math.abs(power - STATE.castChargeLastPct) >= .5);
    	if moving then
    		STATE.castChargeMotionAt = now;
    	end;
    	STATE.castChargeLastPct = power;
    	if STATE.castChargeMotionAt == 0 then
    		STATE.castChargeMotionAt = now;
    	end;

    	if STATE.castBarSeen and (now - STATE.castChargeMotionAt) >= 1200 then -- the bar stalled
    		onCastTimeout(now);
    		return;
    	end;
    	if (now - STATE.castStartedAt) >= STATE.castWaitTimeoutMs then -- overall charge deadline
    		onCastTimeout(now);
    	end;
    end;

    local function updateCasted(now) -- CASTED phase: brief settle before watching for the shake
    	releaseAllMouse();
    	if STATE.castReleasedAt == 0 then
    		STATE.castReleasedAt = now;
    	end;
    	if (now - STATE.castReleasedAt) < CONFIG.postCastDelayMs then
    		return;
    	end;
    	STATE.lastShakedAt = 0;
    	STATE.phase = "SHAKE";
    end;

    local function updateShake(now) -- SHAKE phase: spam Enter until the reel opens
    	releaseAllMouse();

    	-- The reel GUI flickers live for a single frame as it is rebuilt right after the throw,
    	-- about 20-30ms past the release. A bobber cannot have landed by then -- every real bite
    	-- measured here arrives 1150ms or later -- so a reel this soon after the cast is the old
    	-- one blinking, and taking it drops us into a phantom cycle that wastes a full second.
    	if reelActive(now) and not recentReelClose(now) and (now - STATE.castReleasedAt) >= 400 then
    		STATE.phase = "FISHING";
    		return;
    	end;
    	if STATE.shakeStartedAt == 0 then
    		STATE.shakeStartedAt = now;
    	end;

    	if STATE.shakeUnstickAt == 0 then
    		STATE.shakeUnstickAt = now;
    	elseif (now - STATE.shakeUnstickAt) >= 1500 then -- periodic bare key-up clears a stuck Enter
    		STATE.shakeUnstickAt = now;
    		if not pendingReleases[KEYS.Enter] then
    			keyrelease(KEYS.Enter);
    		end;
    	end;

    	if STATE.lastShakedAt == 0 or (now - STATE.lastShakedAt) >= STATE.shakingIntervalMs then
    		if tapEnter() then
    			STATE.shakeCount = STATE.shakeCount + 1;
    			STATE.lastShakedAt = now;
    		end;
    	end;

    	if not STATE.shakeSeen and shakeUp(now) then -- seeing the prompt disarms the timer for good
    		STATE.shakeSeen = true;
    	end;

    	if not STATE.shakeSeen and (now - STATE.shakeStartedAt) >= CONFIG.castLandTimeoutMs then -- the cast never landed
    		STATE.timeouts = STATE.timeouts + 1;
    		startCycle();
    		return;
    	end;

    	if (now - STATE.shakeStartedAt) >= CONFIG.shakeTimeoutMs then -- backstop: shake seen but the reel never came
    		startCycle();
    	end;
    end;

    local function finishReel(caught) -- closes out a reel and updates the counters
    	unbindAllReelButtons();
    	releaseAllMouse();
    	STATE.reelClosedAt = tick() * 1000;
    	if caught then
    		local fish = math.max(1, STATE.reelDoneCount); -- a self-closing reel reports no per-bar progress
    		STATE.caught = STATE.caught + fish;
    		STATE.lastReelCaught = true;
    		print("Caught " .. ((fish > 1) and (fish .. " at once ") or "") .. "(" .. STATE.caught .. " total)");
    	else
    		STATE.lost = STATE.lost + 1;
    		STATE.lastReelCaught = false;
    	end;
    	resetToPhase("DONE");
    end;

    -- Called two ways: bare from the phase table, which rediscovers, rebinds and runs the
    -- watchdog before steering; and with steerOnly from the fast loop, which goes straight
    -- to the steering. Every path the bookkeeping half bails out of skips the steering too,
    -- because each of them has already let the buttons go.
    local function updateFishing(now, steerOnly) -- FISHING phase: bind buttons to bars and steer them
    	if STATE.reelStartedAt == 0 then -- first frame of this reel, so arm the watchdog
    		STATE.reelStartedAt = now;
    		STATE.reelMotionAt = now;
    	end;

    	if not (steerOnly or ((REEL.driven[1] or REEL.driven[2])
    		and (now - REFRESH.bookAt) < REFRESH.book)) then -- the slow half, on its own clock
    		REFRESH.bookAt = now;

    		refreshReelRefs(now, reelBind[1] == nil and reelBind[2] == nil); -- force discovery while unbound

    		local liveSlots = {};
    		for _, slot in ipairs(REEL.slots) do
    			if slotLive(slot) then
    				liveSlots[#liveSlots + 1] = slot;
    			end;
    		end;

    		if #liveSlots == 0 then -- every minigame closed, so score the cycle
    			finishReel(STATE.maxProgress >= CONFIG.completionThreshold);
    			return;
    		end;

    		local liveAddrs = {}; -- free closed minigames' buttons before handing out new bindings
    		for _, slot in ipairs(liveSlots) do
    			liveAddrs[slot.barAddr] = true;
    		end;
    		for index = 1, #REEL_BUTTONS do
    			local addr = reelBind[index];
    			if addr and not liveAddrs[addr] then
    				unbindReelButton(index);
    			end;
    		end;

    		local maxButtons = CONFIG.dualReel and #REEL_BUTTONS or 1;
    		local bound = {};
    		for _, slot in ipairs(liveSlots) do
    			local index = reelBindIndexFor(slot.barAddr); -- keep an existing binding
    			if not index then
    				for i = 1, maxButtons do
    					if reelBind[i] == nil then -- claim the first free button
    						index = i;
    						reelBind[i] = slot.barAddr;
    						REEL_BUTTONS[i].ctrl:Reset();
    						if i > 1 and not hasMouse2 then
    							warnMissingMouse2();
    						end;
    						break;
    					end;
    				end;
    			end;
    			if index then
    				bound[index] = slot;
    			end;
    		end;

    		local allComplete = true;
    		local signature = ""; -- everything the reel shows this frame, for the stall check below
    		for index = 1, #REEL_BUTTONS do
    			local slot = bound[index];
    			REEL.driven[index] = slot; -- what the steering half below will drive until this runs again
    			if not slot then
    				REEL_BUTTONS[index].release(); -- nothing bound, so hold nothing
    			else
    				local progress = readFillPercent(liveAddr(slot.progressBar, slot.progressAddr));
    				if progress then
    					if progress > STATE.maxProgress then
    						STATE.maxProgress = progress;
    					end;
    					if progress < CONFIG.completionThreshold then
    						allComplete = false;
    					elseif not STATE.reelDone[slot.barAddr] then
    						STATE.reelDone[slot.barAddr] = true; -- latched per bar so a double catch counts twice
    						STATE.reelDoneCount = STATE.reelDoneCount + 1;
    					end;
    				else
    					allComplete = false; -- unreadable progress, so wait for the GUI to close instead
    				end;

    				if (slot.readAt or 0) > 0 then
    					signature = signature .. string.format("|%d,%.4f,%.4f,%.2f", index, slot.readFish, slot.readBar, progress or -1.0);
    				else
    					allComplete = false; -- steering could not read this bar at all
    				end;
    			end;
    		end;

    		if signature ~= STATE.reelSignature then -- something actually moved, so the reel is alive
    			STATE.reelSignature = signature;
    			STATE.reelMotionAt = now;
    		end;

    		if allComplete then -- only exit once every live minigame is full
    			finishReel(true);
    			return;
    		end;

    		if (now - STATE.reelMotionAt) >= CONFIG.reelStallMs then -- frozen: re-discover and rebind, as many times as it takes
    			STATE.reelMotionAt = now;
    			STATE.reelSignature = nil;
    			unbindAllReelButtons();
    			releaseAllMouse();
    			refreshReelRefs(now, true); -- forced, so stale references are thrown away
    			return;
    		end;

    		if CONFIG.reelTimeoutMs > 0 and (now - STATE.reelStartedAt) >= CONFIG.reelTimeoutMs then -- disabled while reelTimeoutMs is 0
    			STATE.timeouts = STATE.timeouts + 1;
    			finishReel(STATE.maxProgress >= CONFIG.completionThreshold);
    			return;
    		end;
    	end;

    	local driven = REEL.driven;
    	for index = 1, #REEL_BUTTONS do
    		local slot = driven[index];
    		if slot then
    			local fishAddr = liveAddr(slot.fish, slot.fishAddr);
    			local pbAddr = liveAddr(slot.playerbar, slot.playerbarAddr);
    			if not (fishAddr and pbAddr) then -- Fisch destroys and recreates these mid-reel
    				slot.fish = findChild(slot.bar, "fish") or slot.fish;
    				slot.playerbar = findChild(slot.bar, "playerbar") or slot.playerbar;
    				fishAddr = liveAddr(slot.fish, slot.fishAddr);
    				pbAddr = liveAddr(slot.playerbar, slot.playerbarAddr);
    			end;
    			if fishAddr and pbAddr then
    				slot.fishAddr, slot.playerbarAddr = fishAddr, pbAddr;
    				local fishCenter = readFloat(fishAddr + OFFSETS.FramePositionX) + (readFloat(fishAddr + OFFSETS.FrameSizeX) * .5); -- position plus half its width
    				local barPos = readFloat(pbAddr + OFFSETS.FramePositionX);
    				local barWidth = readFloat(pbAddr + OFFSETS.FrameSizeX);
    				if isFinite(barWidth) and barWidth >= .001 then -- a bar on screen always has a width
    					slot.readFish, slot.readBar, slot.readAt = fishCenter, barPos, now;
    					REEL_BUTTONS[index].ctrl:Update(fishCenter, barPos, barWidth);
    				else
    					slot.readAt = 0; -- the reads went stale; the watchdog below recovers
    					REEL_BUTTONS[index].release();
    				end;
    			else
    				slot.readAt = 0;
    				REEL_BUTTONS[index].release();
    			end;
    		end;
    	end;
    end;

    local function updateDone(now) -- DONE phase: wait out the post-catch delay, then recast
    	if reelActive(now) and not recentReelClose(now) then -- another fish already bit
    		STATE.doneAt = 0;
    		STATE.phase = "FISHING";
    		return;
    	end;

    	if STATE.doneAt == 0 then
    		STATE.doneAt = now;
    	end;

    	local waitMs = STATE.lastReelCaught and CONFIG.postCatchDelayMs or CONFIG.postLostDelayMs;
    	if (now - STATE.doneAt) < waitMs then
    		return;
    	end;
    	startCycle();
    end;

    local PHASE_HANDLERS = { -- phase name -> handler; a phase with no entry parks the loop
    		CASTING = updateCasting,
    		CASTED = updateCasted,
    		SHAKE = updateShake,
    		FISHING = updateFishing,
    		DONE = updateDone,
    		NUKE = updateNuke,
    	};

    local enabled = false; -- whether the macro is currently running

    local function setEnabled(on) -- toggles the macro and cleans up on the way out
    	on = on and true or false;
    	if on == enabled then
    		return;
    	end;
    	enabled = on;
    	if on then
    		STATE.phase = "OFF";
    		STATE.reelClosedAt = 0; -- a previous run's timestamp must not mask a live reel
    		REEL.ignored = {}; -- a fresh run gets to try every bar again
    		lastMouseAt = tick() * 1000; -- the silence watchdog starts counting from here
    		if type(setrobloxinput) == "function" then -- nothing lands if this got turned off
    			pcall(setrobloxinput, true);
    		end;
    		STATE.castEverSeen = false; -- re-arms the one-shot re-equip in onCastTimeout
    		EQUIP.done = true; -- clears an equip a previous toggle left half-finished
    		if CONFIG.mode == "rod" then -- the other modes just use whatever is held
    			startCycle(); -- reel up -> FISHING, shake up -> SHAKE, nothing up -> CASTING
    			if STATE.phase == "CASTING" then -- no minigame to join, so the rod has to come out first
    				STATE.phase = "OFF"; -- OFF gates the loop until equipStep confirms the rod
    				beginEquip(tick() * 1000);
    			end;
    		end;
    	else
    		unbindAllReelButtons();
    		releaseAllMouse();
    		STATE.phase = "OFF";
    	end;
    	-- the host script notifies on toggle (setRunning); no second popup here
    end;

    local function setMode(index) -- switches mode, turning the macro off first; true when changed
    	local name = MODES[index];
    	if not name or name == CONFIG.mode then
    		return false;
    	end;
    	if enabled then -- never swap modes under a running macro
    		setEnabled(false);
    	end;
    	CONFIG.mode = name;
    	return true;
    end;


    local CURSOR = { inset = 0 }; -- cursor Y correction, shared by the panel and gun mode
    local cachedMouse = nil; -- the Mouse object, re-fetched if it goes bad

    -- Kept here rather than taken from the library: gun mode aims with it, so it
    -- has to keep working on a run where ui.lua never loaded.
    local function readMouse() -- current cursor position in viewport pixels, or nil
    	local mouse = cachedMouse;
    	if not mouse then
    		local player = getLocalPlayer();
    		if not player then
    			return nil;
    		end;
    		local ok, found = pcall(player.GetMouse, player);
    		if not ok or not found then
    			return nil;
    		end;
    		cachedMouse = found;
    		mouse = found;
    	end;
    	local mx, my = mouse.X, mouse.Y;
    	if not (mx and my) then
    		cachedMouse = nil; -- stale object, so drop it and retry next frame
    		return nil;
    	end;
    	return mx, my + CURSOR.inset;
    end;

    local keyWasDown = {}; -- vk -> held last frame, for the no-library fallback below

    local function keyPressedEdge(vk) -- true only on the frame a key goes down
    	local down = iskeypressed(vk) and true or false;
    	local edge = down and not keyWasDown[vk];
    	keyWasDown[vk] = down;
    	return edge;
    end;



    local supervisedPhase = nil; -- phase the supervisor last saw, and when it first saw it
    local supervisedAt = 0;

    local function superviseStuck(now) -- forces a clean restart when a phase simply never ends
    	if STATE.phase ~= supervisedPhase then
    		supervisedPhase = STATE.phase;
    		supervisedAt = now;
    		return;
    	end;
    	if (now - supervisedAt) < CONFIG.stuckTimeoutMs and (now - lastMouseAt) < CONFIG.stuckTimeoutMs then
    		return; -- either a frozen phase or total silence is enough to trip this
    	end;
    	supervisedAt = now;
    	lastMouseAt = now;
    	STATE.recoveries = (STATE.recoveries or 0) + 1; -- ADDED: host status line reads this
    	unbindAllReelButtons();
    	releaseAllMouse();
    	flushKeys();
    	mouseHeld, mouse2Held = false, false; -- forget any belief about a held button
    	mousePressOk, mouse2PressOk = true, true;
    	pcall(mouse1release);
    	if hasMouse2 then
    		pcall(mouse2release);
    	end;
    	if type(setrobloxinput) == "function" then -- re-assert injection in case it was turned off
    		pcall(setrobloxinput, true);
    	end;
    	EQUIP.done = true;
    	REEL.ignored = {};
    	startCycle();
    	supervisedPhase = STATE.phase;
    end;

    local function fishingStep(now) -- rod mode's per-frame step, dispatching to the phase handlers
    	if not isRobloxActive() then -- alt-tabbed, so inject nothing
    		releaseAllMouse();
    		if STATE.reelStartedAt > 0 then -- time spent unfocused must not count as a stalled reel
    			STATE.reelStartedAt = now;
    			STATE.reelMotionAt = now;
    		end;
    		supervisedAt, lastMouseAt = now, now; -- and it must not count as a stuck phase either
    		return;
    	end;

    	superviseStuck(now);

    	if not equipStep(now) then -- nothing runs until the rod is confirmed in hand
    		return;
    	end;

    	if mouse2Held and STATE.phase ~= "FISHING" then -- right click leaked from somewhere; clear it
    		releaseMouse2();
    	end;

    	if STATE.phase == "OFF" then
    		startCycle();
    	end;

    	if STATE.phase ~= "NUKE" and (now - REFRESH.crossAt) >= REFRESH.cross then -- both scans are costly and neither answer goes stale quickly
    		REFRESH.crossAt = now;
    		if not reelActive(now) and nukeActive(now) then -- a live reel outranks it
    			nlog("ENTER from phase=" .. tostring(STATE.phase) .. " guiAddr=" .. tostring(NUKE.guiAddr));
    			unbindAllReelButtons();
    			releaseAllMouse();
    			flushKeys();
    			nukeCtrl:Begin(NUKE.gui, now);
    			STATE.phase = "NUKE";
    		end;
    	end;

    	for _ = 1, 4 do -- a phase that hands straight on should not wait out another pass to run
    		local phase = STATE.phase;
    		local handler = PHASE_HANDLERS[phase];
    		if not handler then
    			break;
    		end;
    		handler(now);
    		if STATE.phase == phase then
    			break; -- it stayed put, so there is nothing waiting behind it
    		end;
    	end;
    end;

    local GUN_CLICK_CLASSES = { ImageButton = true, TextButton = true }; -- only real buttons are clickable
    local GUN_CLICK_NAMES = { pull = true, darkpull = true }; -- an allowlist, since curse must not be clicked
    local GUN_SKIP_NAMES = { buttonTemplates = true }; -- hidden templates share the live clones' names

    local GUN = { -- harpoon aiming state machine
    		stage = "SEEK",
    		actAt = 0,
    		calX = 0, calY = 0, -- screen-space minus viewport-space, learned from the first move
    		fixes = 0,
    		wantAddr = nil, -- the popup being aimed at
    		pressedAt = 0, -- when the last click went down, for the delay slider
    		aimX = 0, aimY = 0, -- what the last move ASKED for, which the calibration measures against
    		lastAddr = nil, lastAt = 0,
    		gui = nil, guiAt = 0,
    		warnedNoMove = false, warnedNoGui = false,
    	};

    local function gunRect(addr) -- rendered rect in viewport pixels, or nil if the read missed
    	if not addr then
    		return nil;
    	end;
    	local sx = readFloat(addr + OFFSETS.AbsoluteSizeX);
    	local sy = readFloat(addr + OFFSETS.AbsoluteSizeY);
    	if not ((sx > 4 and sy > 4) and (sx < 8000 and sy < 8000)) then -- a live button is never zero-sized
    		return nil;
    	end;
    	local px = readFloat(addr + OFFSETS.AbsolutePositionX);
    	local py = readFloat(addr + OFFSETS.AbsolutePositionY);
    	if not (isFinite(px) and isFinite(py)) then
    		return nil;
    	end;
    	return px, py, sx, sy;
    end;

    local function gunFindPopup(gui) -- the live popup's address and its rect this frame
    	local bestAddr, best, bestArea = nil, nil, math.huge;
    	local queue, index = { gui }, 1;
    	while index <= #queue and index <= 64 do -- bounded walk of the harpoon GUI
    		local node = queue[index];
    		index = index + 1;
    		for _, child in ipairs(getChildren(node)) do
    			local name = child.Name;
    			if not GUN_SKIP_NAMES[name] then
    				local addr = getAddress(child);
    				if addr and isVisible(child, addr) then -- a spent popup goes invisible, so never descend into one
    					if GUN_CLICK_NAMES[name] and GUN_CLICK_CLASSES[child.ClassName] then
    						local px, py, sx, sy = gunRect(addr);
    						if px and (sx * sy) < bestArea then -- smallest only breaks ties
    							bestAddr, bestArea = addr, sx * sy;
    							best = { cx = px + (sx * .5), cy = py + (sy * .5), x = px, y = py, w = sx, h = sy };
    						end;
    					end;
    					if #queue < 64 then
    						queue[#queue + 1] = child;
    					end;
    				end;
    			end;
    		end;
    	end;
    	return bestAddr, best;
    end;

    local function gunGui(now) -- cached PlayerGui.harpoonMinigame lookup
    	if GUN.gui and (now - GUN.guiAt) < REFRESH.gun and isAlive(GUN.gui) then -- walked every step, so a closed one must not be
    		return GUN.gui;
    	end;
    	GUN.guiAt = now;
    	local pg = getPlayerGui(now);
    	GUN.gui = pg and findChild(pg, CONFIG.gunGuiName) or nil;
    	return GUN.gui;
    end;

    local function gunAim(rect) -- moves the cursor to the popup's centre plus the learned offset
    	GUN.aimX, GUN.aimY = rect.cx, rect.cy;
    	moveMouse(rect.cx + GUN.calX, rect.cy + GUN.calY);
    end;

    local function gunPress(now) -- clicks and schedules the release
    	GUN.pressedAt = now; -- the slider paces from one press to the next, so the gap is the whole period
    	holdMouse();
    	GUN.stage = "HOLD";
    	GUN.actAt = now + CONFIG.gunHoldMs;
    end;

    local function gunStep(now) -- gun mode's per-frame step: seek, aim, click, repeat
    	if not isRobloxActive() then
    		releaseMouse();
    		GUN.stage = "SEEK";
    		return;
    	end;

    	if not hasMouseMove then -- without cursor control there is nothing this mode can do
    		if not GUN.warnedNoMove then
    			GUN.warnedNoMove = true;
    			notify("mousemoveabs() is missing - Gun mode cannot aim.", "", 6);
    		end;
    		return;
    	end;

    	local gui = gunGui(now);
    	if not gui then
    		if not GUN.warnedNoGui then
    			GUN.warnedNoGui = true;
    		end;
    		releaseMouse();
    		GUN.stage = "SEEK";
    		return;
    	end;
    	GUN.warnedNoGui = false; -- the GUI is back, so re-arm the warning

    	local addr, rect = gunFindPopup(gui);

    	if GUN.stage == "HOLD" then
    		if rect and addr == GUN.wantAddr then -- keep chasing so press and release land on one target
    			gunAim(rect);
    		end;
    		if now >= GUN.actAt then
    			releaseMouse();
    			GUN.lastAddr, GUN.lastAt = GUN.wantAddr, now;
    			GUN.stage = "SEEK";
    		end;
    		return;
    	end;

    	if GUN.stage == "AIM" then
    		if not addr then -- the popup died mid-aim
    			GUN.stage = "SEEK";
    			return;
    		end;
    		GUN.wantAddr = addr;

    		if now >= GUN.actAt then
    			local gx, gy = readMouse();
    			if not (gx and gy) then -- no cursor read to check against, so trust the move
    				gunPress(now);
    				return;
    			end;
    			if (gx >= rect.x and gx <= (rect.x + rect.w)) -- anywhere on the button clicks it
    				and (gy >= rect.y and gy <= (rect.y + rect.h)) then
    				gunPress(now);
    				return;
    			end;
    			if GUN.fixes >= CONFIG.gunMaxFixes then -- out of corrections, click where we are
    				gunPress(now);
    				return;
    			end;
    			GUN.calX = GUN.calX + (GUN.aimX - gx); -- fold the residual into the calibration
    			GUN.calY = GUN.calY + (GUN.aimY - gy);
    			GUN.fixes = GUN.fixes + 1;
    		end;

    		gunAim(rect); -- re-aim at where the button is now, calibrated or not
    		return;
    	end;

    	if not addr then -- SEEK with nothing on screen
    		return;
    	end;

    	if addr == GUN.lastAddr and (now - GUN.lastAt) < CONFIG.gunRearmMs then -- the one just clicked
    		return;
    	end;

    	if GUN.pressedAt > 0 and (now - GUN.pressedAt) < CONFIG.gunDelayMs then -- held back by the delay slider
    		return;
    	end;

    	GUN.wantAddr = addr; -- a new popup, so start aiming at it
    	GUN.fixes = 0;
    	gunAim(rect);
    	GUN.stage = "AIM";
    	GUN.actAt = now + CONFIG.gunSettleMs;
    end;

    local MODE_STEPS = { -- one entry per dropdown mode; a mode with no entry does nothing
    		rod = fishingStep,
    		spear = stabStep,
    		gun = gunStep,
    	};

    local function fastBody() -- the low-latency pass: key timing, steering, and the mode's own step
    	local now = tick() * 1000;

    	processKeyReleases(now); -- send any key-ups that came due

    	if not enabled then
    		return;
    	end;

    	if CONFIG.mode == "rod" and STATE.phase == "FISHING" and (now - REFRESH.steerAt) >= REFRESH.steer then
    		REFRESH.steerAt = now; -- steering keeps its own, tighter clock than the phase logic
    		if not pcall(updateFishing, now, true) then
    			releaseAllMouse();
    		end;
    	end;

    	if (now - REFRESH.stepAt) < REFRESH.step then
    		return;
    	end;
    	REFRESH.stepAt = now;

    	local step = MODE_STEPS[CONFIG.mode];
    	if not step then
    		return;
    	end;
    	if not pcall(step, now) then -- a bad read skips a frame instead of killing the loop
    		releaseAllMouse();
    	end;
    end;
    -- ---- exports: the only surface the rest of this file may touch ----------
    ENG.CONFIG   = CONFIG          -- the engine's own knobs (shadows the host CONFIG in here)
    ENG.TUNING   = HYBRID_TUNING   -- the reel controller's gains, for the Reel tab
    ENG.STATE    = STATE
    ENG.probe    = function() return STATE, mouseHeld end -- read-only window for cast_probe.lua
    ENG.MODES    = MODES
    ENG.REFRESH  = REFRESH
    ENG.setEnabled  = setEnabled
    ENG.setMode     = setMode
    ENG.fastBody    = fastBody     -- one low-latency pass; call it from the frame loop
    ENG.isEnabled   = function() return enabled end
    ENG.modeLabel   = modeLabel
    ENG.flushKeys   = flushKeys
    ENG.tapKey      = tapKey
    ENG.pumpKeys    = processKeyReleases
    ENG.releaseAll  = releaseAllMouse
    ENG.unbindReels = unbindAllReelButtons
    ENG.reelActive  = reelActive
    ENG.shakeUp     = shakeUp
    ENG.castThreshold = getCastThreshold
    ENG.holdingRod  = holdingRod
end

-- ============================================================================
-- Adapter - everything below this line still talks to the OLD engine's names,
-- so they are re-provided here as thin shims over ENG. Keeping the shims means
-- the ESP, teleports, webhook, chest runner, Instant Reel and the menu did
-- not have to be rewritten around the new engine.
-- ============================================================================
local Library, Window, autoToggle      -- menu forward decls (set in the menu section)
local _settingToggle = false           -- guards the toggle<->setRunning feedback loop
local _irApplied  = false              -- instant-reel patch is live for the CURRENT reel
local VK = { Enter = 0x0D, E = 0x45 }

local State = ENG.STATE
FM.probe = ENG.probe -- so cast_probe.lua can reach the engine through _G.FischMacro
-- Fields the host's webhook and status line expect but the engine has no notion
-- of. Seeded here so every reader is nil-safe from the first frame.
State.running    = false
State.rod        = ""
State.recoveries = State.recoveries or 0

local PHASE_LABEL = {
    OFF = "idle", CASTING = "casting", CASTED = "casting", SHAKE = "shaking",
    FISHING = "reeling", DONE = "done", NUKE = "nuke", STAB = "spear",
}

local function releaseMouse() pcall(ENG.releaseAll) end
-- Key taps from this file (the chest runner's E, the anti-AFK F15) go into the
-- engine's own release queue. ENG.fastBody drains that queue before its own
-- enabled-check, so these still get released with Auto Fish switched off.
local function tapKey(vk, holdMs) pcall(ENG.tapKey, vk, holdMs, tick() * 1000) end

-- ---- hotkeys ---------------------------------------------------------------
-- The Auto Fish and Auto Appraise keys are keybinds on their own menu rows.
-- UILib polls them with iskeypressed itself, so any key works (F-keys
-- included), a click rebinds it, right-click switches toggle/hold, and the
-- settings file remembers the choice. Only a console-only run, with no menu to
-- carry a keybind, falls back to the fixed key below.
local HOTKEYS = {
    autofishFallback  = 0x70,   -- VK_F1, only used when the UI failed to load
}

local function keyDown(vk)
    if type(iskeypressed) ~= "function" then return false end
    local ok, down = pcall(iskeypressed, vk)
    return (ok and down) and true or false
end

local _hkWas = {}
local function hotkeyEdge(vk)
    local down = keyDown(vk)
    local edge = down and not _hkWas[vk]
    _hkWas[vk] = down
    return edge
end
FM.hotkeyEdge = hotkeyEdge   -- the appraiser tab polls its fixed key through this

local function hasActiveFishingContext()
    local ok, live = pcall(ENG.reelActive, tick() * 1000)
    return ok and live or false
end

-- Teardown hooks. FM.unload is defined near the top of the file, before the
-- engine exists, so it reaches the engine through these slots.
FM.releaseKeys = function()
    pcall(ENG.setEnabled, false)   -- stop the phase machine before dropping input
    pcall(ENG.unbindReels)
    pcall(ENG.flushKeys)           -- every key-up the engine still owed
    pcall(ENG.releaseAll)          -- both mouse buttons
end

local function setRunning(on)
    on = on and true or false
    if on == State.running then return end
    State.running = on
    pcall(ENG.setEnabled, on)
    if not on then releaseMouse() end
    local msg = on and "Auto Fish on" or ("Auto Fish off (" .. tostring(State.caught or 0) .. " caught)")
    if Library then
        pcall(function() Library:Notify(msg, 2) end)
    else
        notify(msg, "", 2)
    end
    if autoToggle and not _settingToggle then
        _settingToggle = true
        pcall(function() autoToggle:Set(on) end)
        _settingToggle = false
    end
end


-- ==========================================================================
-- Status readout, debug log, anti-AFK
-- ============================================================================
-- The old hand-rolled watchdog is gone: the engine's own superviseStuck does the
-- same job from inside the phase machine (it can see EQUIP/REEL state that this
-- outer layer cannot) and it bumps State.recoveries, which the status line shows.
local function currentStatus()
    local label = State.running and (PHASE_LABEL[State.phase] or tostring(State.phase)) or "idle"
    if label == "casting" then
        return string.format("state(casting) threshold(%.0f%%) seen(%s) armed(%s)",
            State.castThreshold or 0, tostring(State.castBarSeen), tostring(State.castArmed))
    elseif label == "shaking" then
        return string.format("state(shaking) shook=(%d)", State.shakeCount or 0)
    elseif label == "reeling" then
        return string.format("state(reeling) progress(%.1f) bars(%d)",
            State.maxProgress or 0, State.reelDoneCount or 0)
    elseif label == "nuke" then
        return "state(nuke)"
    end
    return "state(" .. label .. ")"
end



-- Anti-AFK (non-toggleable): Roblox kicks after ~20 min idle. Only nudges while
-- the macro is fully idle; F15 has no in-game binding so it can't affect Fisch.
local ANTIAFK_INTERVAL_MS = 9 * 60 * 1000
local _antiAfkAt = tick() * 1000
local function antiAfkTick()
    if State.running then _antiAfkAt = tick() * 1000; return end
    if not robloxActive() then return end
    if (tick() * 1000 - _antiAfkAt) >= ANTIAFK_INTERVAL_MS then
        _antiAfkAt = tick() * 1000
        tapKey(0x7E, 20)   -- VK_F15
    end
end

-- ============================================================================
-- Marker collectors (waypoints from Workspace.zones, chests from world.chests)
-- ============================================================================
local function displayName(part)
    local zn = findChild(part, "zonename")
    if zn then
        local ok, v = pcall(function() return zn.Value end)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return part.Name
end

local function collectLocations(intoList, intoMap)
    local zones = findChild(Workspace, "zones")
    local function grab(groupName)
        for _, part in ipairs(getChildren(findChild(zones, groupName))) do
            -- NOT IsA("BasePart"): Matcha's IsA ignores its argument and returns
            -- true for everything (IsA("ZZZ_NotARealClass") == true, verified
            -- live), so it admitted non-parts and we stored a nil pos -- a
            -- waypoint that teleports nowhere and projects garbage. Test for the
            -- property we actually need instead.
            local okp, pos = pcall(function() return part.Position end)
            if okp and typeof(pos) == "Vector3" then
                local nm = displayName(part)
                if intoMap and intoMap[nm] == nil then intoMap[nm] = pos end
                if intoList then
                    local seen = false
                    for _, e in ipairs(intoList) do if e.name == nm then seen = true; break end end
                    if not seen then intoList[#intoList + 1] = { name = nm, pos = pos } end
                end
            end
        end
    end
    grab("player")
    if CONFIG.wp_include_fishing then grab("fishing") end
    return intoList, intoMap
end

-- Chests live in world.chests AND world.ActiveChestsFolder (probe 2026-07-08);
-- scan both so a container change can't silently blind the chest features.
local function collectChests()
    local list = {}
    local world = findChild(Workspace, "world")
    for _, folder in ipairs({ findChild(world, "chests"), findChild(world, "ActiveChestsFolder") }) do
        for _, ch in ipairs(getChildren(folder)) do
            -- IsA is a no-op here (see collectLocations); the Position read is
            -- the real class test.
            local okp, pos = pcall(function() return ch.Position end)
            if okp and typeof(pos) == "Vector3" then
                list[#list + 1] = { name = ch.Name, pos = pos }
            end
        end
    end
    return list
end

-- ============================================================================
-- ESP factory — every marker overlay is a pool of square+text Drawings updated
-- per Heartbeat via WorldToScreen. Lists re-scan on a timer and size/text/
-- distance settings are read from CONFIG per frame, so the menu sliders apply
-- LIVE (no rebuild). Drawing "Text" font size is `.Size` in this Matcha build,
-- not `.FontSize` — applyTextSize sets whichever the runtime accepts.
-- ============================================================================
local function applyTextSize(tx, n)
    if pcall(function() tx.Size = n end) then return end
    pcall(function() tx.FontSize = n end)
end

-- Where the local character stands, for the distance labels. Both overlays ask on
-- every frame and a FindFirstChild costs ~0.3ms through Matcha, so the root part is
-- kept while it is still parented and looked up again at least once a second (a
-- respawn is picked up even if the old model lingers). One read serves both overlays.
local ESPME = { hrp = nil, at = -1e9, readAt = -1e9, x = nil, y = nil, z = nil }
function ESPME.read(now)
    if now - ESPME.readAt < 5 then return ESPME.x ~= nil end   -- the other overlay just read it
    ESPME.readAt = now
    local hrp = ESPME.hrp
    -- Age first: a root kept from before the overlays were hidden (a respawn since) may
    -- be freed, and even asking it for its Parent would read that memory.
    if hrp and now - ESPME.at >= 1000 then hrp = nil end
    if hrp then
        local ok, parent = pcall(function() return hrp.Parent end)
        if not (ok and parent ~= nil) then hrp = nil end
    end
    if not hrp and now - ESPME.at >= (ESPME.hrp == nil and 250 or 0) then
        hrp = getHRP()
        ESPME.hrp, ESPME.at = hrp, now
    end
    ESPME.x, ESPME.y, ESPME.z = nil, nil, nil
    if hrp then
        local ok, pos = pcall(function() return hrp.Position end)
        if ok and pos then ESPME.x, ESPME.y, ESPME.z = pos.X, pos.Y, pos.Z end
    end
    return ESPME.x ~= nil
end

-- o: color, textColor, CONFIG key names (size/text/dist/maxd[/rescan]), collect()
-- Each object remembers what it last wrote, so a frame only touches what changed:
-- every Drawing property write and Vector2 is a call into Matcha.
local function newEsp(o)
    local E = { objects = {}, conn = nil, shown = false, list = {}, lastScan = 0 }
    local function ensure(n)
        while #E.objects < n do
            local sq = FM.draw("Square")
            sq.Filled = true; sq.Color = o.color; sq.Visible = false
            local tx = FM.draw("Text")
            tx.Color = o.textColor; tx.Center = true; tx.Outline = true; tx.Visible = false
            E.objects[#E.objects + 1] = { sq = sq, tx = tx, vis = false }
        end
    end
    function E.rescan() E.lastScan = 0 end
    function E.hide()
        E.shown = false
        if E.conn then pcall(function() E.conn:Disconnect() end); E.conn = nil end
        for _, ob in ipairs(E.objects) do
            pcall(function() ob.sq.Visible = false; ob.tx.Visible = false end)
            ob.vis = false
        end
    end
    function E.show()
        if E.shown then return end
        E.shown = true; E.lastScan = 0
        E.conn = FM.track(RunService.Heartbeat:Connect(function()
            local now = tick() * 1000
            if E.lastScan == 0 or (now - E.lastScan) >= (o.rescan and CONFIG[o.rescan] or 5000) then
                E.lastScan = now
                E.list = o.collect()
                for _, e in ipairs(E.list) do e.x, e.y, e.z = e.pos.X, e.pos.Y, e.pos.Z end
            end
            ensure(#E.list)
            local hasMe = ESPME.read(now)
            local mx, my, mz = ESPME.x, ESPME.y, ESPME.z
            local size, tsize = CONFIG[o.size], CONFIG[o.text]
            local maxd, showd = CONFIG[o.maxd], CONFIG[o.dist]
            local half = size / 2
            for i, ob in ipairs(E.objects) do
                local e, drawn = E.list[i], false
                if e then
                    local dist
                    if hasMe then
                        local dx, dy, dz = e.x - mx, e.y - my, e.z - mz
                        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                    end
                    if not (maxd > 0 and dist and dist > maxd) then
                        local screen, on = WorldToScreen(e.pos)
                        if on and screen then
                            local sx, sy = screen.X, screen.Y
                            if ob.size ~= size then
                                ob.sq.Size = Vector2.new(size, size)
                                ob.size, ob.sx = size, nil     -- the corner moves with the size
                            end
                            if ob.tsize ~= tsize then
                                applyTextSize(ob.tx, tsize)
                                ob.tsize, ob.sx = tsize, nil   -- and the label with the text size
                            end
                            if ob.sx ~= sx or ob.sy ~= sy then
                                ob.sq.Position = Vector2.new(sx - half, sy - half)
                                ob.tx.Position = Vector2.new(sx, sy - half - tsize - 2)
                                ob.sx, ob.sy = sx, sy
                            end
                            local d = (showd and dist) and math.floor(dist) or nil
                            if ob.name ~= e.name or ob.d ~= d then
                                ob.tx.Text = d and string.format("%s [%d]", e.name, d) or e.name
                                ob.name, ob.d = e.name, d
                            end
                            if not ob.vis then
                                ob.sq.Visible = true; ob.tx.Visible = true
                                ob.vis = true
                            end
                            drawn = true
                        end
                    end
                end
                if not drawn and ob.vis then
                    ob.sq.Visible = false; ob.tx.Visible = false
                    ob.vis = false
                end
            end
        end))
    end
    return E
end

local WP = newEsp({
    color = Color3.fromRGB(255, 0, 0), textColor = Color3.fromRGB(255, 255, 255),
    size = "wp_square_size", text = "wp_text_size",
    dist = "wp_show_distance", maxd = "wp_max_distance", rescan = "wp_rescan_ms",
    collect = function() return (collectLocations({}, nil)) end,
})

local CHEST = newEsp({
    color = Color3.fromRGB(255, 215, 0), textColor = Color3.fromRGB(255, 235, 120),
    size = "chest_square_size", text = "chest_text_size",
    dist = "chest_show_distance", maxd = "chest_max_distance", rescan = "chest_rescan_ms",
    collect = function()
        local l = collectChests()
        for _, c in ipairs(l) do c.name = "Chest" end
        return l
    end,
})

-- ============================================================================
-- Webhook (OPT-IN Discord webhook — sends only to the user's own URL, only
-- while enabled. Silent by design.)
-- ============================================================================
local WEBHOOK = { startedSent = false, lastStatsAt = 0 }

function WEBHOOK.validUrl(u)
    return type(u) == "string" and (u:find("discord.com/api/webhooks/", 1, true)
        or u:find("discordapp.com/api/webhooks/", 1, true)) ~= nil
end

-- Discord needs application/json; try the HttpPost forms Matcha may accept.
function WEBHOOK.post(content)
    if not CONFIG.webhook_enabled then return false end
    local url = CONFIG.webhook_url
    if not WEBHOOK.validUrl(url) then return false end
    local ok, body = pcall(function()
        return HttpService:JSONEncode({ content = content })
    end)
    if not ok then return false end
    local sent = pcall(function() game:HttpPost(url, body, Enum.HttpContentType.ApplicationJson) end)
    if not sent then sent = pcall(function() game:HttpPost(url, body, false, "application/json") end) end
    if not sent then sent = pcall(function() game:HttpPost(url, body) end) end
    return sent
end

function WEBHOOK.sendAsync(content)   -- off the heartbeat so a POST can't stall the macro
    task.spawn(function() pcall(WEBHOOK.post, content) end)
end

function WEBHOOK.leaderstat(names)
    local ls = findChild(getLP(), "leaderstats"); if not ls then return nil end
    for _, nm in ipairs(names) do
        local s = findChild(ls, nm)
        if s then
            local ok, v = pcall(function() return s.Value end)
            if ok and v ~= nil then return v end
        end
    end
    return nil
end

function WEBHOOK.username()
    local lp = getLP(); if not lp then return "?" end
    local nm = lp.Name or "?"
    local ok, dn = pcall(function() return lp.DisplayName end)
    if ok and type(dn) == "string" and dn ~= "" and dn ~= nm then return dn .. " (@" .. nm .. ")" end
    return nm
end

function WEBHOOK.stats()
    local phase = State.running and (PHASE_LABEL[State.phase] or State.phase) or "idle"
    return string.format(
        "**Stats**\nUser: %s\nStage: %s    Rod: %s\nCaught: %d    Lost: %d    Timeouts: %d",
        WEBHOOK.username(), phase, State.rod ~= "" and State.rod or "none",
        State.caught or 0, State.lost or 0, State.timeouts or 0)
end

function WEBHOOK.startup()
    local lvl   = WEBHOOK.leaderstat({ "Level", "Lvl", "level" })
    local money = WEBHOOK.leaderstat({ "Money", "Coins", "Cash", "C$", "Currency" })
    return string.format("**Started**\nUser: %s\nLevel: %s\nMoney: %s",
        WEBHOOK.username(), lvl ~= nil and tostring(lvl) or "?",
        money ~= nil and tostring(money) or "?")
end

function WEBHOOK.maybeStartup()   -- fires once, when enabled with a valid URL
    if WEBHOOK.startedSent then return end
    if not (CONFIG.webhook_enabled and CONFIG.webhook_on_start and WEBHOOK.validUrl(CONFIG.webhook_url)) then return end
    WEBHOOK.startedSent = true
    WEBHOOK.sendAsync(WEBHOOK.startup())
end

function WEBHOOK.statsTick()
    if not (CONFIG.webhook_enabled and CONFIG.webhook_stats and WEBHOOK.validUrl(CONFIG.webhook_url)) then return end
    if (tick() - WEBHOOK.lastStatsAt) < CONFIG.webhook_interval_s then return end
    WEBHOOK.lastStatsAt = tick()
    WEBHOOK.sendAsync(WEBHOOK.stats())
end

-- ============================================================================
-- Teleport (instant CFrame writes DO replicate here — confirmed live).
-- Curated, hand-verified hub destinations only.
-- ============================================================================
local TP = {}
-- Locations = places that appear in the in-game bestiary (a top-level entry or
-- one of the sub-locations in its dropdowns; read from
-- PlayerGui.hud.safezone.bestiaryNEW.Fish.Locations.List on 2026-09-15).
TP.locations = {
    ["Obsidian Pocket"]            = Vector3.new(141.56, -6551.00, 48.81),
    ["Boreal Hollow"]              = Vector3.new(848.32, -2603.62, 1610.78),
    ["Grand Reef"]                 = Vector3.new(-3577.17, 162.33, 503.51),
    ["Desolate Deep"]              = Vector3.new(-1512.57, -234.70, -2862.52),
    ["Glacial Grotto (Summit)"]    = Vector3.new(19990.91, 1142.24, 5550.10),
    ["Atlantis"]                   = Vector3.new(-4343.68, -602.31, 1813.18),
    ["Boreal Pines"]               = Vector3.new(21575.56, 141.52, 4137.94),
    ["Castaway Cliff"]             = Vector3.new(384.89, 207.49, -1818.55),
    ["Everturn Forest"]            = Vector3.new(2426.63, 149.82, -2500.87),
    ["Forsaken Shores"]            = Vector3.new(-2584.73, 167.55, 1608.71),
    ["Lost Jungle"]                = Vector3.new(-2707.33, 158.20, -2060.92),
    ["Moosewood"]                  = Vector3.new(486.56, 157.84, 268.30),
    ["Mushgrove"]                  = Vector3.new(2697.28, 140.33, -756.55),
    ["Roslit Bay"]                 = Vector3.new(-1486.62, 142.08, 704.40),
    ["Scoria Reach"]               = Vector3.new(-5108.09, 145.09, -1456.06),
    ["Snowcap Island"]             = Vector3.new(2687.71, 160.31, 2385.95),
    ["Sunstone Island"]            = Vector3.new(-986.11, 208.64, -1074.15),
    ["Terrapin"]                   = Vector3.new(-132.30, 188.15, 1952.43),
    ["Tidefall"]                   = Vector3.new(3133.05, -1081.10, 788.25),
    ["Treasure Island"]            = Vector3.new(8284, 195, -17093),
    ["Poseidon's Storm of Floods"] = Vector3.new(-8985.58, -3191.38, 780.49),
    ["Abyssal Zenith"]             = Vector3.new(-13541, -11048, 154),
    ["Brine Pool"]                 = Vector3.new(-1795, -142, -3331),
    ["Ancient Archives"]           = Vector3.new(-3162.13, -747.21, 1701.17),
    ["Enchanted Crevice"]          = Vector3.new(681.17, -754.03, -472.44),
    ["Luminescent Cavern"]         = Vector3.new(-1013, -313, -4038),
    ["Cursed Isle"]                = Vector3.new(1860, 135, 1210),
    ["Zeus's Thunder of Chaos"]    = Vector3.new(-8878, -3539, 594),
    ["Living Garden"]              = Vector3.new(-2401, -316, -2771),
    ["Carrot Garden"]              = Vector3.new(3732, -1127, -1080),
    ["Northern Expedition"]        = Vector3.new(19512.69, 132.67, 5303.36),
    ["Above The Clouds"]           = Vector3.new(1489.51, 2601.67, -1718.30),
    ["Ancient Isle"]               = Vector3.new(6069, 224, 262),
    ["Mineshaft"]                  = Vector3.new(-684, -864, -74),
    ["Overgrowth Caves"]           = Vector3.new(20269.78, 273.20, 5557.13),
    ["Cryogenic Canal"]            = Vector3.new(19956.81, 635.28, 5717.43),
    ["Glacial Grotto (Cave)"]      = Vector3.new(20007.97, 1035.20, 5699.71),
    ["Bellona's Frenzy of War"]    = Vector3.new(-8667.92, -2361.67, 757.59),
    ["Apollo's Song of Light"]     = Vector3.new(-8707.94, -2904.53, 731.84),
    ["Hades' Underworld of Indefinite"] = Vector3.new(-8649, -4243, 434),
    ["Olympian Fissure"]           = Vector3.new(-8830, -4243, -147),
    ["Challenger's Deep"]          = Vector3.new(-775, -3283, -675),
    ["Volcanic Vents"]             = Vector3.new(-3390, -2263, 3822),
    ["Calm Zone"]                  = Vector3.new(-4336, -11174, 3704),
    ["Veil of the Forsaken"]       = Vector3.new(-2361, -11184, -7073),
    ["Cultist Lair"]               = Vector3.new(4476, -1997, -4676),
    ["Crystal Cove"]               = Vector3.new(1364, -612, 2472),
    ["Keepers Altar"]              = Vector3.new(1296, -805, -296),
    ["Snowburrow"]                 = Vector3.new(2784, 141, 2557),
    ["Collapsed Ruins"]            = Vector3.new(3136, -1102, 1611),
    ["Crowned Ruins"]              = Vector3.new(3126, -1126, 2039),
    ["Coral Bastion"]              = Vector3.new(2544, -1098, 849),
    ["Sunken Reliquary"]           = Vector3.new(2950, -1102, 443),
    ["Roslit Volcano"]             = Vector3.new(-1893, 173, 314),
    ["Drylands"]                   = Vector3.new(-6455.02, 204.97, -1539.97),
    ["Vertigo"]                    = Vector3.new(-107, -515, 1143),
    ["The Depths"]                 = Vector3.new(608, -712, 1230),
    ["Crimson Cavern"]             = Vector3.new(-1035, -360, -4800),
    ["Toxic Grove"]                = Vector3.new(-2745, -317, -2272),
    ["Poseidons Temple"]           = Vector3.new(-3950, -550, 968),
    ["Nectar Den"]                 = Vector3.new(-2066, -327, -3125),
    ["Sunken Depths"]              = Vector3.new(-4938.35, -595.12, 1840.24),
    ["Ethereal Abyss"]             = Vector3.new(-3792.98, -564.27, 1828.82),
    ["Kraken Lair"]                = Vector3.new(-4380.05, -996.26, 2052.43),
    ["Zeus' Sanctuary"]            = Vector3.new(-4294, -627, 2655),
    ["Astral Observatory"]         = Vector3.new(842.98, -2603.62, 1619.96),
    ["Blue Moon - First Sea"]      = Vector3.new(2685.14, 141.51, 2582.13),
    ["Skycrest"]                   = Vector3.new(2779.58, 1621.31, 830.14),
    ["The Deep"]                   = Vector3.new(385.44, -2238.58, -11910.56),
    ["Outer Deep"]                 = Vector3.new(-436.90, -2367.80, -12685.32),
    ["Gloomy Crevice"]             = Vector3.new(134.63, -2512.30, -11836.59),
    ["Lower Deep"]                 = Vector3.new(1708.02, -2805.78, -11772.06),
    ["Atlantean Storm"]            = Vector3.new(-3866, 154, 445),
    ["Frigid Cavern"]              = Vector3.new(19845.54, 440.16, 5633.05),
}

-- Points of interest: everything that is NOT a bestiary location -- NPCs,
-- appraisers, puzzle buttons, trial rooms, pools, landmarks. Kept as a second
-- table on TP (not new locals -- the main chunk is register-limited) and served
-- by the same functions below through their optional `list` argument.
TP.poi = {
    ["Obsidian Trench"]            = Vector3.new(-1668.61, -12350.83, 62.88),
    ["Appraisal (Tidefall)"]       = Vector3.new(3158, -1099, 771),
    ["Merlin"]                     = Vector3.new(-960, 222, -988),
    ["Toucan"]                     = Vector3.new(-2933, 275, -2156),
    ["Bubble Mermaid"]             = Vector3.new(-3550, 130, 568),
    ["Mermaid Cove"]               = Vector3.new(-3870, -1286, 505),
    ["Rodtp"]                      = Vector3.new(19227.0, 395.9, 6028.3),
    -- islands / landmarks the bestiary doesn't list
    ["Statue of Sovereignty"]      = Vector3.new(17.04, 166.10, -1048.24),
    ["The Arch"]                   = Vector3.new(1005.03, 131.32, -1241.27),
    ["Haddock Rock"]               = Vector3.new(-464.45, 160.01, -454.63),
    ["Earmark Island"]             = Vector3.new(1272.97, 140.10, 542.90),
    ["Birch Cay"]                  = Vector3.new(1747.19, 143.00, -2449.68),
    ["Harvesters Spike"]           = Vector3.new(-1254.81, 137.25, 1556.77),
    ["Heaven"]                     = Vector3.new(1459.48,  8876.25, -1717.73),
    ["Hawaii"]                     = Vector3.new(-1346, 130, -39935),
    ["Meteor"]                     = Vector3.new(5733, 184, 625),
    ["Ghosts Tavern"]              = Vector3.new(268, 800, -6864),
    ["Underground Music Venue"]    = Vector3.new(2037, -644, 2474),
    ["Oscars Locker"]              = Vector3.new(213.22, -394.45, 3534.90),
    ["The Laboratory"]             = Vector3.new(-1934, 224, -449),
    ["Shady Bazaar"]               = Vector3.new(-2941, -1029, 6178),
    ["Forgotten Temple"]           = Vector3.new(-5286, -1759, -10000),
    ["Thalassar's Secret"]         = Vector3.new(2897, -579, 1177),
    ["Detonator's Rest"]           = Vector3.new(-1409, -902, -3493),
    ["Aether"]                     = Vector3.new(-146, -654, 966),
    ["Trident Temple"]             = Vector3.new(-1480, -225, -2242),
    ["Zeus's Rod Room"]            = Vector3.new(-4294, -627, 2655),
    ["Volcanic Depths (Pool)"]     = Vector3.new(-3345, -2026, 4084),
    ["Challangers Deep (Pool)"]    = Vector3.new(747, -3353, -1566),
    ["Mossjaw Rest"]               = Vector3.new(-4928.72, -1792.56, -10168.67),
    ["Forsaken Shores Pond"]       = Vector3.new(-2665.24, 167.50, 1754.01),
    ["Claypans - Drylands"]        = Vector3.new(-5765.58, 137.00, -915.12),
    ["Sunken Reservoir"]           = Vector3.new(-6627.04, 158.68, -1247.25),
    ["Abaia's Chamber - Skycrest"] = Vector3.new(3412.14, 1562.36, 950.12),
    -- puzzle pieces
    ["button1"]                    = Vector3.new(400, 135, 265),
    ["button2"]                    = Vector3.new(5506, 147, -315),
    ["button3"]                    = Vector3.new(2930, 281, 2594),
    ["button4"]                    = Vector3.new(-1715, 149, 737),
    ["button5"]                    = Vector3.new(-2566, 181, 1353),
    ["Blue crystal"]               = Vector3.new(20125, 211, 5449),
    ["Green Crystal"]              = Vector3.new(19873, 448, 5556),
    ["Yellow Crystal"]             = Vector3.new(19488, 335, 5553),
    ["Door"]                       = Vector3.new(19986, 906, 5453),
    -- Atlantis / Cultist Lair / Tidefall interiors
    ["Scoria Mines"]               = Vector3.new(-4544.53, -707.31, -2032.08),
    ["Hall of Whispers"]           = Vector3.new(4346.09, -2234.82, -4679.79),
    ["Passage of Oaths"]           = Vector3.new(4284.83, -2483.02, -4680.36),
    ["The Sanctum"]                = Vector3.new(4373.79, -2710.14, -4673.39),
    ["Inner Tidefall Castle"]      = Vector3.new(4317.50, -1100.92, 919.84),
    -- astral caverns
    ["Snowcap Island - Astral Cavern"]  = Vector3.new(2637.73, -410.04, 2521.67),
    ["Boreal Pines - Astral Cavern"]    = Vector3.new(21878.31, -148.60, 4246.41),
    ["Abyssal Zenith - Astral Cavern"]  = Vector3.new(-13802.84, -11569.70, 122.17),
    ["Everturn Forest - Astral Cavern"] = Vector3.new(2523.82, -126.48, -2498.27),
    ["Cryogenic Canal - Astral Cavern"] = Vector3.new(-1859.83, -262.67, 4012.63),
}

-- `list` picks one table; with none, locations are searched first and points of
-- interest second, so the Rods tab can still name a POI (e.g. tp = "Heaven").
function TP.resolve(name, list)
    if not list then
        return TP.resolve(name, TP.locations) or TP.resolve(name, TP.poi)
    end
    if list[name] then return list[name] end
    local low = string.lower(name or "")
    for k, v in pairs(list) do
        if string.lower(k) == low then return v end
    end
    return nil
end

-- Fuzzy match for the searchable picker: exact -> prefix -> substring.
function TP.matchName(q, list)
    if not q or q == "" then return nil end
    q = string.lower(q)
    local prefix, substr
    for k in pairs(list or TP.locations) do
        local lk = string.lower(k)
        if lk == q then return k end
        if not prefix and lk:sub(1, #q) == q then prefix = k end
        if not substr and lk:find(q, 1, true) then substr = k end
    end
    return prefix or substr
end

function TP.toPos(x, y, z)
    local hrp = getHRP()
    if not hrp then warn("No HumanoidRootPart"); return false end
    pcall(function() hrp.CFrame = CFrame.new(x, y, z) end)
    return true
end

function TP.to(name, list)
    local pos = TP.resolve(name, list)
    if not pos then warn("Unknown location: " .. tostring(name)); return false end
    return TP.toPos(pos.X, pos.Y, pos.Z)
end

function TP.list(list, label)
    local names = {}
    for k in pairs(list or TP.locations) do names[#names + 1] = k end
    table.sort(names)
    print(string.format("%d %s:", #names, label or "locations"))
    for _, n in ipairs(names) do print("   " .. n) end
    return names
end

-- ============================================================================
-- NPC scan (Workspace.world.npcs + workspace.npcs + "NewNpc" tag). One shared
-- snapshot feeds rod live verification. Probe findings (2026-07-08): several
-- top-level entries are CONTAINERS (real NPCs one level down); Matcha's :IsA
-- ("BasePart") is unreliable there, so trust whether .Position actually reads.
-- Streaming means absence = "can't verify from here", never "wrong".
-- ============================================================================
local NPC = { _list = {}, _lastScan = 0 }

function NPC.collect()
    local list, seen = {}, {}
    local function readablePos(inst)
        if not inst then return nil end
        local ok, pos = pcall(function()
            local p = inst.Position
            return (p and p.X ~= nil) and p or nil
        end)
        return ok and pos or nil
    end
    local function add(m)
        local pos = readablePos(findChild(m, "HumanoidRootPart")) or readablePos(findChild(m, "Head"))
        if not pos then
            for _, c in ipairs(getChildren(m)) do
                pos = readablePos(c)
                if pos then break end
            end
        end
        if not pos then return end
        local key = m.Name .. "@" .. math.floor(pos.X) .. "," .. math.floor(pos.Z)
        if not seen[key] then
            seen[key] = true
            list[#list + 1] = { name = m.Name, pos = pos }
        end
    end
    local function scan(container, depth)
        if not container or depth > 3 then return end
        for _, m in ipairs(getChildren(container)) do
            if findChild(m, "Humanoid") or findChild(m, "HumanoidRootPart") then
                add(m)
            elseif #getChildren(m) > 0 then
                scan(m, depth + 1)
            end
        end
    end
    scan(findChild(findChild(Workspace, "world"), "npcs"), 1)
    scan(findChild(Workspace, "npcs"), 1)
    pcall(function()
        for _, m in ipairs(game:GetService("CollectionService"):GetTagged("NewNpc")) do add(m) end
    end)
    return list
end

function NPC.snapshot(maxAgeMs)
    local now = tick() * 1000
    if (now - (NPC._lastScan or 0)) >= (maxAgeMs or 10000) then
        NPC._lastScan = now
        NPC._list = NPC.collect()
    end
    return NPC._list or {}
end

-- ============================================================================
-- ROD LOCATIONS (where every rod is obtained + teleport). Curated from wiki/
-- guides (DRYLANDS era, 2026-07); coordinate frame cross-checked against the
-- hand-verified hubs. Teleport resolves: exact pos -> hub (tp/zone name in
-- TP.locations) -> live zone lookup. Second Sea rods are a different PlaceId
-- (unreachable) and expired event rods aren't listed.
-- ============================================================================
local Rod = {}
Rod.catalog = {
    -- Moosewood -- Done and correct
    { name = "Flimsy Rod",     zone = "Moosewood", pos = Vector3.new(470, 151, 232), how = "Starter rod - you spawn with it" },
    { name = "Training Rod",   zone = "Moosewood", pos = Vector3.new(465, 150, 230), npc = "Marc Merchant", how = "Merchant - 300 C$" },
    { name = "Plastic Rod",    zone = "Moosewood", pos = Vector3.new(463.36, 150.53, 235.97), npc = "Marc Merchant", how = "Merchant - 900 C$" },
    { name = "Carbon Rod",     zone = "Moosewood", pos = Vector3.new(463.36, 150.53, 235.97), npc = "Marc Merchant", how = "Merchant - 2,000 C$" },
    { name = "Fast Rod",       zone = "Moosewood", pos = Vector3.new(463.36, 150.53, 235.97), npc = "Marc Merchant", how = "Merchant - 2,000 C$" },
    { name = "Long Rod",       zone = "Moosewood", pos = Vector3.new(463.36, 150.53, 235.97), npc = "Marc Merchant", how = "Merchant - 4,500 C$" },
    { name = "Lucky Rod",      zone = "Moosewood", pos = Vector3.new(463.36, 150.53, 235.97), npc = "Marc Merchant", how = "Merchant - 5,250 C$" },
    -- Roslit Bay
    { name = "Steady Rod",     zone = "Roslit Bay", pos = Vector3.new(-1499.41, 141.43, 750.98), npc = "Alfredrickus", how = "Blacksmith - 7,000 C$" },
    { name = "Fortune Rod",    zone = "Roslit Bay", pos = Vector3.new(-1499.41, 141.43, 750.98), npc = "Alfredrickus", how = "Blacksmith - 12,750 C$" },
    { name = "Rapid Rod",      zone = "Roslit Bay", pos = Vector3.new(-1499.41, 141.43, 750.98), npc = "Alfredrickus", how = "Merchant - 14,000 C$" },
    { name = "Magma Rod",      zone = "Roslit Bay", pos = Vector3.new(-1850, 165, 160), npc = "Orc", how = "Quest: give the Orc a Pufferfish (teleport lands at the Orc)" },
    -- other First Sea islands
    { name = "Cinder Block Rod", zone = "The Laboratory", pos = Vector3.new(-1970, 260, -530), how = "Hand-marked spot at The Laboratory (added 2026-09-06) - acquisition not catalogued" },
    { name = "Magnet Rod",     zone = "Terrapin Island", pos = Vector3.new(-234.20, 141.85, 1955.30), how = "Shipwright - 15,000 C$" },
    { name = "Reinforced Rod", zone = "Desolate Deep", pos = Vector3.new(-990, -245, -2695), how = "Secret merchant - 20,000 C$" },
    { name = "Trident Rod",    zone = "Desolate Deep", pos = Vector3.new(-1483, -225, -2207), how = "Complete Bestiary + 5 Enchant Relics - 150,000 C$ (the teleport bypasses the Enchant Relic door)" },
    { name = "Nocturnal Rod",  zone = "Vertigo", pos = Vector3.new(-144.04, -515.30, 1144.86), how = "Merchant - 11,000 C$" },
    { name = "Aurora Rod",     zone = "Vertigo", pos = Vector3.new(-144.04, -515.30, 1144.86), how = "Buy Aurora Totem (500k), activate during whirlpool - 90,000 C$" },
    { name = "Fungal Rod",     zone = "Mushgrove Swamp", pos = Vector3.new(2588.54, 132.00, -725.91), npc = "Agaric", how = "Quest: show Agaric an Alligator (catchable at this spot)" },
    { name = "Rod of the Exalted One", zone = "Mushgrove Swamp", pos = Vector3.new(2232.82, -804.18, 1032.22), how = "Place 7 mutated Enchant Relics on the altar" },
    { name = "Kings Rod",      zone = "Keeper's Altar (below the Statue)", pos = Vector3.new(1383.54, -807.31, -303.38), how = "Sold at the Keeper's Altar - ~100,000 C$" },
    { name = "Destiny Rod",    zone = "The Arch", pos = Vector3.new(985.49, 131.32, -1234.51), npc = "Caleia", how = "Caleia - 190,000 C$ (needs 70% Bestiary)" },
    { name = "Sunken Rod",     zone = "Forsaken Shores", pos = Vector3.new(-2494.00, 133.10, 1551.27), how = "Find a treasure map, repair it, dig up the chest" },
    { name = "Scurvy Rod",     zone = "Forsaken Shores", pos = Vector3.new(-2825, 215, 1515), npc = "Jack Marrow", how = "Jack Marrow - 50,000 C$" },
    { name = "Rod of the Depths", zone = "The Depths", pos = Vector3.new(1705.52, -902.53, 1441.27), how = "Place relics on the altars + key - 750,000 C$" },
    { name = "Relic Rod",      zone = "Archaeological Site", tp = "Mineshaft", how = "Cave puzzle at the dig site - 8,000 C$" },
    { name = "Stone Rod",      zone = "Ancient Isle", pos = Vector3.new(5500, 143, -316), how = "Sold on the isle - 3,000 C$" },
    { name = "Phoenix Rod",    zone = "Ancient Isle", pos = Vector3.new(5963.22, 269.62, 851.75), how = "Inside the cave - 40,000 C$" },
    -- no fixed spot
    { name = "Mythical Rod",   zone = "Traveling Merchant (random spawn)", how = "110,000 C$ when the merchant is around" },
    { name = "Midas Rod",      zone = "Traveling Merchant (random spawn)", how = "55,000 C$ when the merchant is around" },
    { name = "No-Life Rod",    zone = "Anywhere", how = "Reach level 500" },
    { name = "Seraphic Rod",   zone = "Anywhere", how = "Reach level 1,000" },
    { name = "Free Spirit Rod", zone = "Mineshaft", pos = Vector3.new(-314, -864, -81), how = "100% Bestiary + 200,000 C$" },
    -- Northern Summit
    { name = "Arctic Rod",       zone = "Northern Summit", pos = Vector3.new(19575, 135, 5310), how = "Base-camp merchant table - 25,000 C$" },
    { name = "Avalanche Rod",    zone = "Northern Summit", pos = Vector3.new(19771, 415, 5415), how = "Camp near Overgrowth Cave - 35,000 C$" },
    { name = "Crystalized Rod",  zone = "Northern Summit", pos = Vector3.new(20296, 272, 5463), how = "35,000 C$ - needs 2 players + a Glass Diamond" },
    { name = "Ice Warpers Rod",  zone = "Glacial Grotto", tp = "Glacial Grotto (Summit)", how = "Unlock the 6 levers - 65,000 C$" },
    { name = "Summit Rod",       zone = "Northern Summit (peak)", pos = Vector3.new(20213.5, 736.7, 5713), how = "Crate at the top - 300,000 C$" },
    { name = "Heaven's Rod",     zone = "Heaven (above the Summit)", tp = "Heaven", how = "Energy Crystals + buttons - 1,750,000 C$" },
    -- Atlantis
    { name = "Champions Rod",       zone = "Atlantis", pos = Vector3.new(-4259.02, -603.21, 1870.90), how = "Left of the Inn Keeper - 1,000,000 C$" },
    { name = "Depthseeker Rod",     zone = "Atlantis", pos = Vector3.new(-4459.58, -605.66, 1866.08), how = "Merchant stall by the east bridge - 125,000 C$" },
    { name = "Tempest Rod",         zone = "Atlantis", pos = Vector3.new(-4931.56, -595.24, 1852.30), how = "Mythological Clock room after the Sunken Trial - 1,850,000 C$" },
    { name = "Abyssal Specter Rod", zone = "Atlantis", pos = Vector3.new(-3802.18, -566.77, 1862.80), how = "Clock room after the Ethereal Abyss Trial - 1,004,269 C$" },
    { name = "Poseidon Rod",        zone = "Poseidon's Temple (Atlantis)", pos = Vector3.new(-4078.50, -558.23, 895.90), how = "After Poseidon's trial - 450,000 C$" },
    { name = "Zeus Rod",            zone = "Zeus's Rod Room (Atlantis)", pos = Vector3.new(-4275.86, -627.11, 2659.67), how = "After Zeus's trial - 500,000 C$" },
    { name = "Kraken Rod",          zone = "Kraken Pool (Atlantis)", pos = Vector3.new(-4404.55, -996.26, 2053.80), how = "All 4 trials + 5 clocks - 950,000 C$" },
    -- Mariana's Veil
    { name = "Volcanic Rod",       zone = "Volcanic Vents (Mariana's Veil)", pos = Vector3.new(-3175, -2030, 4020), how = "300,000 C$" },
    { name = "Challenger's Rod",   zone = "Challenger's Deep (Mariana's Veil)", pos = Vector3.new(740, -3350, -1530), how = "400,000 C$" },
    { name = "Rod of the Zenith",  zone = "Abyssal Zenith", pos = Vector3.new(-13629.56, -11035.21, 349.12), how = "700,000 C$" },
    { name = "Ethereal Prism Rod", zone = "Calm Zone Rainbow Pond (Mariana's Veil)", pos = Vector3.new(-4360, -11170, 3710), how = "3,500,000 C$" },
    { name = "Leviathan's Fang Rod", zone = "Veil of the Forsaken", how = "Defeat the Scylla boss - 1,000,000 C$ (no fixed spot - can't teleport)" },
    -- craftables (vault table at the Ancient Archives)
    { name = "Precision Rod",   zone = "Ancient Vault", tp = "Ancient Archives", how = "Craft - 7,000 C$ + materials" },
    { name = "Resourceful Rod", zone = "Ancient Vault", tp = "Ancient Archives", how = "Craft - 15,000 C$ + materials" },
    { name = "Wisdom Rod",      zone = "Ancient Vault", tp = "Ancient Archives", how = "Craft - 50,000 C$ + materials" },
    { name = "Krampus's Rod",   zone = "Ancient Vault", tp = "Ancient Archives", how = "Craft - 30,000 C$ + materials" },
    { name = "Seasons Rod",     zone = "Ancient Vault", tp = "Ancient Archives", how = "Level 145 - craft, 35,000 C$ + materials" },
    { name = "Riptide Rod",     zone = "Ancient Vault", tp = "Ancient Archives", how = "Level 200 - craft, 40,000 C$ + materials" },
    { name = "Voyager Rod",     zone = "Ancient Vault", tp = "Ancient Archives", how = "Level 400 - craft, 30,000 C$ + materials" },
    { name = "The Lost Rod",    zone = "Ancient Vault", tp = "Ancient Archives", how = "Level 450 - craft, 50,000 C$ + materials" },
    { name = "Celestial Rod",   zone = "Ancient Vault", tp = "Ancient Archives", how = "Level 500 - craft, 100,000 C$ + materials" },
    { name = "Rod of the Eternal King",   zone = "Ancient Vault", tp = "Ancient Archives", how = "Level 650 - craft, 250,000 C$ + materials" },
    { name = "Rod of the Forgotten Fang", zone = "Ancient Vault", tp = "Ancient Archives", how = "Level 750 - craft, 300,000 C$ + materials" },
    { name = "Rod of Time",     zone = "Ancient Vault", tp = "Ancient Archives", how = "Craft - special materials, no C$" },
    -- DRYLANDS update (2026-07)
    { name = "Marrow Rod",       zone = "Drylands", tp = "Ancient Archives", how = "Mysterious Marrow questline in the Drylands, then craft at the Ancient Archives" },
    { name = "Terrotrapper Rod", zone = "Drylands", how = "Obtained in the Drylands (walk there from behind the FischFest castle)" },
    -- Olympian depths
    { name = "Hades' Soul Scythe", zone = "Hades' Underworld of Indefinite", pos = Vector3.new(-7682.7, -4260.6, 363.0), how = "100% Bestiary + 25,000,000 C$" },
}

Rod.SRC_LABEL = {
    exact = "exact spot",
    hub   = "island hub (walk from there)",
    zone  = "zone center (live lookup)",
}

-- Live zone lookup: match a zone name against Workspace.zones zonenames —
-- exact first, then substring. Zone map cached ~5s (a scan walks ~174 parts).
function Rod.zonePos(zoneName)
    if not zoneName or zoneName == "" then return nil end
    if not Rod._zmap or (tick() - (Rod._zmapAt or 0)) > 5 then
        local ok, _, map = pcall(collectLocations, nil, {})
        Rod._zmap = (ok and type(map) == "table") and map or {}
        Rod._zmapAt = tick()
    end
    local q = string.lower(zoneName)
    local sub = nil
    for nm, pos in pairs(Rod._zmap) do
        local ln = string.lower(nm)
        if ln == q then return pos end
        if not sub and (ln:find(q, 1, true) or q:find(ln, 1, true)) then sub = pos end
    end
    return sub
end

-- Resolve where a rod entry teleports to: pos, "exact"|"hub"|"zone", or nil.
function Rod.pos(e)
    if e.pos then return e.pos, "exact" end
    local hub = TP.resolve(e.tp or e.zone)
    if hub then return hub, "hub" end
    local zp = Rod.zonePos(e.zone)
    if zp then return zp, "zone" end
    return nil, nil
end

-- Fuzzy rod search: exact -> prefix -> substring on the name, then zone substring.
function Rod.match(q)
    if not q or q == "" then return nil end
    q = string.lower(q)
    local prefix, substr, zoneHit
    for _, e in ipairs(Rod.catalog) do
        local ln = string.lower(e.name)
        if ln == q then return e end
        if not prefix and ln:sub(1, #q) == q then prefix = e end
        if not substr and ln:find(q, 1, true) then substr = e end
        if not zoneHit and string.lower(e.zone):find(q, 1, true) then zoneHit = e end
    end
    return prefix or substr or zoneHit
end

-- Confirm a catalog coordinate against the streamed NPC list. livePos is
-- non-nil only when the rod's named seller stands within 500 studs of the
-- catalog spot — the teleport then lands exactly on the NPC (self-correcting
-- if the game moves a merchant). Verified live: Marc Merchant, Alfredrickus
-- and the Orc all stand within 14 studs of the shipped coords.
function Rod.liveCheck(e, pos)
    pos = pos or Rod.pos(e)
    if not pos then return nil, nil end
    local want = e.npc and string.lower(e.npc) or nil
    local bestD, bestName, namedPos
    for _, n in ipairs(NPC.snapshot()) do
        local ok, d = pcall(function() return (n.pos - pos).Magnitude end)
        if ok and d then
            if not bestD or d < bestD then bestD, bestName = d, n.name end
            if want and not namedPos and d <= 500 and string.lower(n.name):find(want, 1, true) then
                namedPos = n.pos
            end
        end
    end
    if namedPos then return namedPos, "verified - " .. e.npc .. " on site" end
    if bestD and bestD <= 60 then
        return nil, string.format("likely - %s [%d]", bestName, math.floor(bestD))
    end
    return nil, "unverified (too far)"
end

function Rod.describe(e)
    local _, src = Rod.pos(e)
    local _, live = Rod.liveCheck(e)
    return string.format("%s\nWhere: %s\nHow: %s\nTeleport: %s%s",
        e.name, e.zone, e.how,
        src and Rod.SRC_LABEL[src] or "n/a - no fixed spot",
        live and ("\nLive check: " .. live) or "")
end

function Rod.teleport(e)
    local pos = Rod.pos(e)
    if not pos then
        notify(e.name .. " has no fixed spot (" .. e.zone .. ")", "", 4)
        return false
    end
    local livePos = Rod.liveCheck(e)
    if livePos then pos = livePos end   -- land exactly on the streamed-in seller
    TP.toPos(pos.X, pos.Y, pos.Z)
    return true
end

-- ============================================================================
-- Chest teleports + collect-all run (chests despawn when looted, so both read
-- the live list at click time; +3 on Y lands on top, still in E range).
-- ============================================================================
function CHEST.tpNearest()
    local list = collectChests()
    if #list == 0 then notify("No treasure chests up right now.", "", 3); return false end
    local cp = selfPos()
    local best, bd
    for _, c in ipairs(list) do
        local d = 0
        if cp then
            local ok, m = pcall(function() return (c.pos - cp).Magnitude end)
            d = ok and m or 0
        end
        if not bd or d < bd then best, bd = c, d end
    end
    return best and TP.toPos(best.pos.X, best.pos.Y + 3, best.pos.Z) or false
end

function CHEST.tpNext()
    local list = collectChests()
    if #list == 0 then notify("No treasure chests up right now.", "", 3); return false end
    CHEST._cycle = ((CHEST._cycle or 0) % #list) + 1
    local c = list[CHEST._cycle]
    return TP.toPos(c.pos.X, c.pos.Y + 3, c.pos.Z)
end

-- Heartbeat-driven (a wait()-loop doesn't resume reliably in this Matcha
-- build). Two stages per chest: teleport onto it, settle, tap E, next.
CHEST.run = { active = false, list = {}, i = 1, stage = "tp", nextAt = 0, visited = 0 }

function CHEST.runStart()
    local r = CHEST.run
    r.list = collectChests()
    r.i = 1; r.stage = "tp"; r.nextAt = 0; r.visited = 0
    r.active = #r.list > 0
    notify(r.active and string.format("Chest run: visiting %d chest(s)...", #r.list)
        or "Chest run: no chests found.", "", 3)
end

function CHEST.runStop()
    if not CHEST.run.active then return end
    CHEST.run.active = false
    pcall(keyrelease, VK.E)
    notify(string.format("Chest run stopped (%d visited).", CHEST.run.visited), "", 3)
end

function CHEST.runStep()
    local r = CHEST.run
    if not r.active then return end
    local now = tick() * 1000
    if now < r.nextAt then return end
    if r.i > #r.list then
        r.active = false
        notify(string.format("Chest run done: %d chest(s) visited.", r.visited), "", 3)
        return
    end
    local pos = r.list[r.i].pos
    if r.stage == "tp" then
        TP.toPos(pos.X, pos.Y, pos.Z)
        r.stage = "press"; r.nextAt = now + 150   -- settle so the E prompt is in range
    else
        tapKey(VK.E, 150)
        r.visited = r.visited + 1; r.i = r.i + 1
        r.stage = "tp"; r.nextAt = now + 200
    end
end

-- getgc once, keep only the numeric slots, then applygc onto that subset.
-- applygc writes straight to the cached slot addresses (verified live: ~0s, no
-- rescan, confirmed by an independent rescan), so function/string slots are
-- never touched and there is no per-value setgc scan. The cache is used the
-- instant it is taken -- never hold one across frames, the tables can move.
--
-- Even "the instant it is taken" is seconds old: the scan runs ~2s while the game
-- keeps going, and a slot freed in that window (a table that grew and rehashed)
-- would take the write as heap corruption. So each slot is read back first and
-- only written if it still holds the number the scan saw. Slots that already hold
-- newValue are left alone but still count, so a patch that survived a re-run of
-- the script is recognised instead of retried forever.
local function applygcNumeric(key, newValue)
    local ok, hits = pcall(getgc, key)
    if not ok or type(hits) ~= "table" then return 0 end
    local nums, done = {}, 0
    for i = 1, #hits do
        local e = hits[i]
        local addr = type(e) == "table" and tonumber(e.addr)
        local want = type(e) == "table" and tonumber(e.value)
        if addr and addr > 4096 and want and tostring(e.type) == "number" then
            local okR, cur = pcall(memory_read, "double", addr)
            cur = okR and tonumber(cur) or nil
            if cur and (cur == want or math.abs(cur - want) <= 1e-9 * math.max(1, math.abs(want))) then
                if cur == newValue then done = done + 1 else nums[#nums + 1] = e end
            end
        end
    end
    if #nums == 0 then return done end
    local ok2, n = pcall(applygc, nums, key, newValue)
    return done + ((ok2 and tonumber(n)) or 0)
end

-- Each getgc is a ~2s full heap scan, and scans run back to back are what kill the
-- Matcha process. So a patch is a small job that runs ONE scan per step, at least
-- SCAN_GAP apart; a reel must stay up OPEN_HOLD before it counts as opened (the reel
-- GUI blinks on for ~20-30ms after every cast); and a failed patch waits RETRY_GAP.
local IR = { enabled = false, patched = false, lastLive = false,
             liveSince = nil, openHandled = false, job = nil, nextScanAt = 0, retryAt = 0,
             OPEN_HOLD = 0.25, SCAN_GAP = 1.0, RETRY_GAP = 15 }

-- progressLossMultiplier is written as 0, not -speed: zero means progress simply
-- never falls back, while a negative multiplier turns the loss term into a gain and
-- can leave the bar stuck. With no loss, a modest efficiency already finishes every
-- reel, which is why the speed can be turned down for fish that want a slow reel.
function IR.startPatch()
    local s = tonumber(CONFIG.instant_reel_speed) or 50
    local loss = tonumber(CONFIG.instant_reel_loss) or 0
    IR.job = { i = 1, n = 0, s = s, loss = loss,
               keys = { { "progressefficiency", s }, { "progressLossMultiplier", loss } } }
end

-- Runs at most one scan. A landed patch hits BOTH keys (>= 2 slots in total).
function IR.runJob()
    local job = IR.job
    if not job or tick() < IR.nextScanAt then return end
    local k = job.keys[job.i]
    job.n = job.n + applygcNumeric(k[1], k[2])
    job.i = job.i + 1
    IR.nextScanAt = tick() + IR.SCAN_GAP   -- read the clock after: the scan took seconds
    if job.i <= #job.keys then return end
    IR.job = nil
    if job.n >= 2 then
        IR.patched = true
        IR.appliedSpeed, IR.appliedLoss = job.s, job.loss   -- what the game is actually running
        if IR.lastLive then _irApplied = true end
        notify("Instant reel active.", "", 3)
    else
        IR.retryAt = tick() + IR.RETRY_GAP
    end
end

-- true when the sliders no longer match what was written into the game
function IR.stale()
    return IR.appliedSpeed ~= (tonumber(CONFIG.instant_reel_speed) or 50)
        or IR.appliedLoss ~= (tonumber(CONFIG.instant_reel_loss) or 0)
end

-- Never scans here: this runs inside a menu callback. An already-open reel is
-- picked up by IR.step once it has been up OPEN_HOLD, like any other.
function IR.setEnabled(v)
    IR.enabled = v and true or false
    if not IR.enabled then IR.job = nil; return end   -- stop a half-run patch
    if IR.patched then return end
    if not hasActiveFishingContext() then
        notify("Instant reel arms when your next reel opens.", "", 4)
    end
end

-- Driven every frame in EVERY mode — once patched, reels auto-complete whether
-- or not the toggle stays on, so the suppression/stale-UI stamping must run.
function IR.step()
    -- Neither armed nor patched: there is nothing to apply and no reel to feed, so skip
    -- the reel lookup entirely. nil means "not tracked"; liveSince is dropped too, so a
    -- reel already open when the toggle goes on is timed from that moment.
    if not (IR.enabled or IR.patched) then IR.lastLive = nil; IR.liveSince = nil; return end
    local now = tick()
    local live = hasActiveFishingContext()
    if live then
        if not IR.liveSince then IR.liveSince = now; IR.openHandled = false end
        if not IR.openHandled and now - IR.liveSince >= IR.OPEN_HOLD then
            -- reel has really opened: patch if armed (a scan that misses retries at a
            -- later reel, after RETRY_GAP). A speed changed since the last patch is
            -- written on this reel too - the scan is seconds long, so it happens here
            -- rather than on every slider step.
            IR.openHandled = true
            if IR.enabled and not IR.job and (not IR.patched or IR.stale())
                    and now >= IR.retryAt then
                IR.startPatch()
            end
            if IR.patched then _irApplied = true end   -- patched reel: feed no input
        end
    else
        IR.liveSince = nil
        if IR.lastLive then
            -- The old engine needed a stale-UI lockout stamped here because it read
            -- the reel GUI directly. The new engine tracks its own reel lifecycle
            -- (reelClosedAt / recentReelClose), so only the flag matters now.
            if _irApplied and not (State.running and State.phase == "FISHING") then
                _irApplied = false
            end
        end
    end
    IR.lastLive = live
    if IR.job then IR.runJob() end   -- a started patch finishes even if the reel closes
end



-- ============================================================================
-- Menu (UILib - Drawing-rendered, from GitHub with a workspace cache; console-only
-- fallback). bindToggle/bindSlider wire a control STRAIGHT to its CONFIG key, so
-- every control provably writes a value the runtime reads, and each carries a
-- flag so fisch_macro.json remembers it. The lib publishes itself as the global
-- `UILib`; Matcha drops loadstring's top-level return, so we read that global
-- rather than the (dropped) return value.
-- ============================================================================
do
    -- Embedded Ocean GUI: no remote menu dependency or cache overwrite.
    local src = [====[
-- Ocean GUI edition. Feature callbacks remain in the original Fisch script.
local g = "1.4.0-ocean.2";
local function o()
	local g = rawget(_G, "UILib");
	if type(g) ~= "table" and type(getgenv) == "function" then
		local o = getgenv();
		if type(o) == "table" then
			g = rawget(o, "UILib");
		end;
	end;
	if type(g) == "table" then
		return g;
	end;
	return nil;
end;
do
	local s = o();
	if s and not s._dead then
		if s.Version == g and not rawget(_G, "UI_RELOAD") then
			if rawget(_G, "UILib") ~= s then
				_G.UILib = s;
			end;
			if type(s._rehome) == "function" then
				s:_rehome();
			end;
			return s;
		end;
		if type(s.Unload) == "function" then
			s:Unload();
		end;
	end;
end;
local s = Drawing;
local f = Vector2.new;
local n = Color3.fromRGB;
local W, c, R, k = math.floor, math.max, math.min, math.abs;
local E, Q, d, T = string.format, string.sub, string.upper, string.byte;
local C, h, U = table.sort, table.concat, table.remove;
local V = (type(tick) == "function") and tick or os.clock;
local I = (type(warn) == "function") and warn or print;
local function t(g)
	return W(g + .5);
end;
local function P(g, o, s)
	if g ~= g then
		return o;
	end;
	if g < o then
		return o;
	end;
	if g > s then
		return s;
	end;
	return g;
end;
local function K(g, o, s, f, n, W)
	return g >= s and (o >= f and (g < s + n and o < f + W));
end;
local function B(g, o, s)
	return { g[1] + ((o[1] - g[1])) * s, g[2] + ((o[2] - g[2])) * s, g[3] + ((o[3] - g[3])) * s };
end;
local function l(g)
	return n(P(t(g[1]), 0, 255), P(t(g[2]), 0, 255), P(t(g[3]), 0, 255));
end;
local function L(g, o, s)
	g = ((g % 1)) * 6;
	local f = W(g);
	local n = g - f;
	local c, R, k = s * ((1 - o)), s * ((1 - o * n)), s * ((1 - o * ((1 - n))));
	local E, Q, d;
	if f == 0 then
		E, Q, d = s, k, c;
	elseif f == 1 then
		E, Q, d = R, s, c;
	elseif f == 2 then
		E, Q, d = c, s, k;
	elseif f == 3 then
		E, Q, d = c, R, s;
	elseif f == 4 then
		E, Q, d = k, c, s;
	else
		E, Q, d = s, c, R;
	end;
	return { E * 255, Q * 255, d * 255 };
end;
local function x(g)
	local o, s, f = g[1] / 255, g[2] / 255, g[3] / 255;
	local n, W = c(o, s, f), R(o, s, f);
	local k = n - W;
	local E = 0;
	if k > 0 then
		if n == o then
			E = ((((s - f)) / k)) % 6;
		elseif n == s then
			E = ((f - o)) / k + 2;
		else
			E = ((o - s)) / k + 4;
		end;
		E = E / 6;
	end;
	return E, (n > 0) and (k / n) or 0, n;
end;
local function j(g)
	return E("#%02X%02X%02X", P(t(g[1]), 0, 255), P(t(g[2]), 0, 255), P(t(g[3]), 0, 255));
end;
local function H(g)
	g = (((tostring(g or "")):gsub("^%s*#?", "")):gsub("%s+$", ""));
	if #g == 3 then
		g = (Q(g, 1, 1)):rep(2) .. ((Q(g, 2, 2)):rep(2) .. (Q(g, 3, 3)):rep(2));
	end;
	if #g ~= 6 or g:find("[^%x]") then
		return nil;
	end;
	return { tonumber(Q(g, 1, 2), 16), tonumber(Q(g, 3, 4), 16), tonumber(Q(g, 5, 6), 16) };
end;
local function Y(g)
	if type(g) == "string" then
		return H(g);
	end;
	if type(g) == "table" then
		if type(g[1]) == "number" then
			return { P(g[1], 0, 255), P(tonumber(g[2]) or 0, 0, 255), P(tonumber(g[3]) or 0, 0, 255) };
		end;
		if type(g.r) == "number" then
			return { P(g.r, 0, 255), P(tonumber(g.g) or 0, 0, 255), P(tonumber(g.b) or 0, 0, 255) };
		end;
		if type(g.hex) == "string" then
			return H(g.hex);
		end;
	end;
	if type(typeof) == "function" and typeof(g) == "Color3" then
		local o, s, f = g.R, g.G, g.B;
		if type(o) == "number" and (type(s) == "number" and type(f) == "number") then
			return { o * 255, s * 255, f * 255 };
		end;
	end;
	return nil;
end;
local w;
local function N(g)
	if not w then
		w = {};
		for g = 0, 359, 1 do
			w[g] = l(L(g / 360, .62, 1));
		end;
	end;
	return w[W(g) % 360];
end;
local v, X = {}, {};
local function J(g, o)
	v[g] = o;
	X[o] = g;
end;
for g = 0, 25, 1 do
	J(65 + g, string.char(65 + g));
end;
for g = 0, 9, 1 do
	J(48 + g, tostring(g));
	J(96 + g, "NUM" .. g);
end;
for g = 1, 24, 1 do
	J(111 + g, "F" .. g);
end;
J(2, "MB2");
J(4, "MB3");
J(5, "MB4");
J(6, "MB5");
J(8, "BACK");
J(9, "TAB");
J(13, "ENTER");
J(20, "CAPS");
J(27, "ESC");
J(32, "SPACE");
J(33, "PGUP");
J(34, "PGDN");
J(35, "END");
J(36, "HOME");
J(37, "LEFT");
J(38, "UP");
J(39, "RIGHT");
J(40, "DOWN");
J(45, "INS");
J(46, "DEL");
J(160, "LSHIFT");
J(161, "RSHIFT");
J(162, "LCTRL");
J(163, "RCTRL");
J(164, "LALT");
J(165, "RALT");
J(106, "NUM*");
J(107, "NUM+");
J(109, "NUM-");
J(110, "NUM.");
J(111, "NUM/");
J(186, ";");
J(187, "=");
J(188, ",");
J(189, "-");
J(190, ".");
J(191, "/");
J(192, "`");
J(219, "[");
J(220, "\\");
J(221, "]");
J(222, "\'");
local M = {
		RIGHTSHIFT = "RSHIFT",
		LEFTSHIFT = "LSHIFT",
		RIGHTCONTROL = "RCTRL",
		LEFTCONTROL = "LCTRL",
		RIGHTCTRL = "RCTRL",
		LEFTCTRL = "LCTRL",
		RIGHTALT = "RALT",
		LEFTALT = "LALT",
		INSERT = "INS",
		DELETE = "DEL",
		PAGEUP = "PGUP",
		PAGEDOWN = "PGDN",
		ESCAPE = "ESC",
		RETURN = "ENTER",
		BACKSPACE = "BACK",
		CAPSLOCK = "CAPS",
		MOUSE2 = "MB2",
		MOUSE3 = "MB3",
		MOUSE4 = "MB4",
		MOUSE5 = "MB5",
		MOUSEBUTTON2 = "MB2",
		MOUSEBUTTON3 = "MB3",
		RMB = "MB2",
		MMB = "MB3",
		ZERO = "0",
		ONE = "1",
		TWO = "2",
		THREE = "3",
		FOUR = "4",
		FIVE = "5",
		SIX = "6",
		SEVEN = "7",
		EIGHT = "8",
		NINE = "9",
	};
local function S(g)
	if g == nil or g == false then
		return nil;
	end;
	if type(g) == "number" then
		return v[g] and g or nil;
	end;
	local o = d((((tostring(g)):gsub("^Enum%.KeyCode%.", "")):gsub("%s", "")));
	o = M[o] or o;
	return X[o];
end;
local p = {};
for g in pairs(v) do
	p[#p + 1] = g;
end;
C(p);
local a = {};
for g = 0, 25, 1 do
	a[#a + 1] = { 65 + g, string.char(97 + g), string.char(65 + g) };
end;
do
	local g = ")!@#$%^&*(";
	for o = 0, 9, 1 do
		a[#a + 1] = { 48 + o, tostring(o), Q(g, o + 1, o + 1) };
		a[#a + 1] = { 96 + o, tostring(o), tostring(o) };
	end;
	local o = {
			{ 32, " ", " " },
			{ 186, ";", ":" },
			{ 187, "=", "+" },
			{ 188, ",", "<" },
			{ 189, "-", "_" },
			{ 190, ".", ">" },
			{ 191, "/", "?" },
			{ 192, "`", "~" },
			{ 219, "[", "{" },
			{ 220, "\\", "|" },
			{ 221, "]", "}" },
			{ 222, "\'", "\"" },
			{ 106, "*", "*" },
			{ 107, "+", "+" },
			{ 109, "-", "-" },
			{ 110, ".", "." },
			{ 111, "/", "/" },
		};
	for g, o in ipairs(o) do
		a[#a + 1] = o;
	end;
end;
local u = {
		8,
		46,
		37,
		39,
		36,
		35,
		13,
		27,
		9,
	};
local function D(g)
	return game:GetService(g) or game[g];
end;
local e = D("RunService");
local i = D("Players");
local b = D("HttpService");
local q = {
		key = type(iskeypressed) == "function",
		m1 = type(ismouse1pressed) == "function",
		m2 = type(ismouse2pressed) == "function",
		active = type(isrbxactive) == "function",
		input = type(setrobloxinput) == "function",
		fs = type(writefile) == "function" and (type(readfile) == "function" and type(isfile) == "function"),
		mkdir = type(makefolder) == "function",
		isdir = type(isfolder) == "function",
		list = type(listfiles) == "function",
		del = type(delfile) == "function",
		ping = type(GetPingValue) == "function",
	};
local function O(g)
	if not q.key then
		return false;
	end;
	return iskeypressed(g) and true or false;
end;
local m, r = {}, {};
local z = {
		"UI",
		"System",
		"SystemBold",
		"Minecraft",
		"Monospace",
		"Pixel",
		"Fortnite",
		"ProximaSoftBold",
	};
local y = { Monospace = { mono = .466 }, UI = { sans = 1.16 } };
local Z = { sans = 1.22 };
local A = {};
do
	local g = {
			[" "] = 278,
			["!"] = 278,
			["\""] = 355,
			["#"] = 556,
			["$"] = 556,
			["%"] = 889,
			["&"] = 667,
			["\'"] = 191,
			["("] = 333,
			[")"] = 333,
			["*"] = 389,
			["+"] = 584,
			[","] = 278,
			["-"] = 333,
			["."] = 278,
			["/"] = 278,
			[":"] = 278,
			[";"] = 278,
			["<"] = 584,
			["="] = 584,
			[">"] = 584,
			["?"] = 556,
			["@"] = 1015,
			["["] = 278,
			["\\"] = 278,
			["]"] = 278,
			["^"] = 469,
			_ = 556,
			["`"] = 333,
			["{"] = 334,
			["|"] = 260,
			["}"] = 334,
			["~"] = 584,
		};
	local o = {
			556,
			556,
			500,
			556,
			556,
			278,
			556,
			556,
			222,
			222,
			500,
			222,
			833,
			556,
			556,
			556,
			556,
			333,
			500,
			278,
			556,
			500,
			722,
			500,
			500,
			500,
		};
	local s = {
			667,
			667,
			722,
			722,
			667,
			611,
			778,
			722,
			278,
			500,
			667,
			556,
			833,
			722,
			778,
			667,
			778,
			722,
			667,
			611,
			722,
			667,
			944,
			667,
			667,
			611,
		};
	for f = 1, 26, 1 do
		g[string.char(96 + f)] = o[f];
		g[string.char(64 + f)] = s[f];
	end;
	for o = 0, 9, 1 do
		g[tostring(o)] = 556;
	end;
	for o = 0, 255, 1 do
		A[o] = ((g[string.char(o)] or 600)) / 1000;
	end;
end;
do
	local g = s and s.Fonts;
	if g ~= nil then
		if type(g) == "table" then
			for g, o in pairs(g) do
				r[g] = o;
				m[#m + 1] = g;
			end;
		end;
		if #m == 0 then
			for o, s in ipairs(z) do
				local f = g[s];
				if f ~= nil then
					r[s] = f;
					m[#m + 1] = s;
				end;
			end;
		end;
		C(m, function(g, o)
			local s, f = r[g], r[o];
			if type(s) == "number" and (type(f) == "number" and s ~= f) then
				return s < f;
			end;
			return tostring(g) < tostring(o);
		end);
	end;
end;
local F = {
		"ocean",
		"monochrome",
		"graphite",
		"deep sea",
		"rose noir",
		"terminal",
		"ultraviolet",
		"obsidian",
		"nordic",
		"sakura",
		"amber",
	};
local G = {
        ocean = {
            accent = { 77, 215, 193 },
            background = { 13, 20, 29 },
            group = { 21, 31, 43 },
            topbar = { 16, 25, 36 },
            border = { 36, 50, 65 },
            outline = { 57, 76, 94 },
            text = { 228, 238, 245 },
        },
		monochrome = {
			accent = { 214, 214, 214 },
			background = { 38, 38, 38 },
			group = { 27, 27, 27 },
			topbar = { 31, 31, 31 },
			border = { 62, 62, 62 },
			outline = { 92, 92, 92 },
			text = { 232, 232, 232 },
		},
		graphite = {
			accent = { 150, 178, 206 },
			background = { 34, 36, 40 },
			group = { 24, 26, 30 },
			topbar = { 28, 30, 34 },
			border = { 56, 60, 68 },
			outline = { 88, 94, 106 },
			text = { 226, 230, 236 },
		},
		["deep sea"] = {
			accent = { 82, 182, 222 },
			background = { 18, 28, 38 },
			group = { 12, 20, 28 },
			topbar = { 14, 23, 32 },
			border = { 36, 54, 70 },
			outline = { 60, 88, 110 },
			text = { 214, 232, 244 },
		},
		["rose noir"] = {
			accent = { 228, 98, 130 },
			background = { 34, 26, 30 },
			group = { 24, 18, 21 },
			topbar = { 29, 22, 25 },
			border = { 64, 46, 54 },
			outline = { 102, 72, 84 },
			text = { 240, 226, 230 },
		},
		terminal = {
			accent = { 98, 214, 114 },
			background = { 20, 24, 20 },
			group = { 12, 15, 12 },
			topbar = { 16, 20, 16 },
			border = { 42, 56, 42 },
			outline = { 64, 90, 64 },
			text = { 208, 236, 208 },
		},
		ultraviolet = {
			accent = { 166, 124, 255 },
			background = { 30, 26, 40 },
			group = { 20, 17, 28 },
			topbar = { 25, 21, 34 },
			border = { 56, 48, 76 },
			outline = { 90, 76, 122 },
			text = { 232, 226, 246 },
		},
		obsidian = {
			accent = { 232, 232, 242 },
			background = { 18, 18, 20 },
			group = { 11, 11, 13 },
			topbar = { 14, 14, 16 },
			border = { 38, 38, 42 },
			outline = { 66, 66, 74 },
			text = { 222, 222, 228 },
		},
		nordic = {
			accent = { 136, 192, 208 },
			background = { 46, 52, 64 },
			group = { 36, 41, 51 },
			topbar = { 40, 46, 57 },
			border = { 67, 76, 94 },
			outline = { 94, 105, 126 },
			text = { 229, 233, 240 },
		},
		sakura = {
			accent = { 255, 152, 192 },
			background = { 36, 30, 34 },
			group = { 26, 21, 25 },
			topbar = { 31, 25, 29 },
			border = { 68, 54, 62 },
			outline = { 106, 84, 96 },
			text = { 244, 230, 238 },
		},
		amber = {
			accent = { 255, 178, 66 },
			background = { 34, 30, 24 },
			group = { 24, 21, 16 },
			topbar = { 29, 25, 20 },
			border = { 64, 56, 42 },
			outline = { 102, 88, 64 },
			text = { 240, 232, 218 },
		},
	};
local gM = {
		"accent",
		"background",
		"group",
		"topbar",
		"border",
		"outline",
		"text",
	};
local oM = {
		accent = "accent",
		background = "background",
		group = "group box",
		topbar = "top bar",
		border = "border",
		outline = "outline",
		text = "text",
	};
local sM = {
		Version = g,
		Windows = {},
		Flags = {},
		Settings = {
			fps = 60,
			idleHz = 30,
			captureInput = true,
			tooltipDelay = .35,
			smoothScroll = true,
			fade = false,
			rainbowSpeed = .12,
			inputGuard = nil,
			cursorOffset = { 0, 0 },
			charRatio = nil,
			bindToasts = true,
		},
		TextSize = 14,
		FontName = nil,
		Font = nil,
		Opacity = 1,
		TextOutline = false,
		Bar = {
			rainbow = false,
			direction = 1,
			speed = .1,
			span = .55,
		},
		PresetName = "ocean",
		Theme = {},
		C = {},
		Presets = G,
		PresetOrder = F,
		ThemeRoles = gM,
		Fonts = m,
		KeyNames = v,
		_ov = {},
		_conns = {},
		_binds = {},
		_rainbow = {},
		_pending = {},
		_recent = {},
		_themeWidgets = {},
		_syncToggles = { keybinds = {}, watermark = {} },
		_onUnload = {},
		_frameNo = 0,
		_wheel = 0,
		_mx = -1,
		_my = -1,
		_m1 = false,
		_m2 = false,
		_nextFrame = 0,
		_nextIdle = 0,
		_nextKeys = 0,
		_next30 = 0,
		_nextBar = 0,
		_next1 = 0,
	};
for g, o in pairs(G.ocean) do
	sM.Theme[g] = { o[1], o[2], o[3] };
end;
do
	local g = r.UI ~= nil and "UI" or (r.System ~= nil and "System" or m[1]);
	sM.FontName = g;
	sM.Font = g and r[g] or nil;
end;
local function fM(g, o)
	if g == sM then
		return o;
	end;
	return g;
end;
local nM = type(task) == "table" and task.spawn or nil;
local function WM(g, o, s)
	if type(g) ~= "function" then
		return;
	end;
	if nM then
		nM(function()
			g(o, s);
		end);
	else
		g(o, s);
	end;
end;
local cM = {
		depends = "_askDeps",
		format = "_askFmt",
		inputGuard = "_askGuard",
		captureInput = "_askCap",
	};
local function RM(g, o, s)
	local f = g[o];
	if type(f) ~= "function" then
		return nil;
	end;
	local n = cM[o];
	if g[n] then
		g[n] = nil;
		g[o] = nil;
		I("ui: dropped the " .. (o .. (" function of \'" .. (tostring(g.text or g.title or "settings") .. "\' after it errored"))));
		return nil;
	end;
	g[n] = true;
	local W = f(s);
	g[n] = nil;
	return W;
end;
local kM = { 0, 0, 0 };
local function EM()
	local g = sM.Theme;
	local o = {};
	o.accent = l(g.accent);
	o.bg = l(g.background);
	o.group = l(g.group);
	o.topbar = l(g.topbar);
	o.border = l(g.border);
	o.outline = l(g.outline);
	o.outlineHi = l(B(g.outline, g.text, .22));
	o.text = l(g.text);
	o.textDim = l(B(g.text, g.group, .42));
	o.textOff = l(B(g.text, g.group, .66));
	o.header = l(B(g.text, g.group, .24));
	o.hover = l(B(g.group, g.text, .06));
	local function s(g)
		g = g / 255;
		return g <= .03928 and g / 12.92 or ((((g + .055)) / 1.055)) ^ 2.4;
	end;
	local function f(g)
		return (s(g[1]) * .2126 + s(g[2]) * .7152) + s(g[3]) * .0722;
	end;
	local function W(g, o)
		local s, n = f(g), f(o);
		return ((c(s, n) + .05)) / ((R(s, n) + .05));
	end;
	local function k(g, o)
		if W(o, g) >= 3 then
			return o;
		end;
		return f(g) > .45 and { 18, 18, 20 } or { 236, 236, 240 };
	end;
	local E = k(g.topbar, g.text);
	o.topText = l(E);
	o.topDim = l(B(E, g.topbar, .42));
	o.topAccent = W(g.accent, g.topbar) >= 3 and l(g.accent) or o.topText;
	local Q = B(g.group, kM, f(g.group) > .5 and .14 or .5);
	o.control = l(Q);
	o.controlHi = l(B(g.group, g.text, .1));
	o.press = l(B(g.group, g.accent, .28));
	o.accentDim = l(B(g.accent, g.group, .55));
	o.frameIn = l(B(g.background, kM, .55));
	o.sep = l(B(g.topbar, g.border, .6));
	o.track = l(B(g.background, kM, .25));
	o.black = n(0, 0, 0);
	o.white = n(255, 255, 255);
	local function d(o)
		local s = f(g.group) > .4 and kM or { 255, 255, 255 };
		for f = 0, .8, .1 do
			local n = B(o, s, f);
			if R(W(n, g.group), W(n, Q)) >= 3 then
				return l(n);
			end;
		end;
		return l(B(o, s, .8));
	end;
	o.red = d({ 232, 72, 72 });
	o.orange = d({ 236, 164, 64 });
	o.blue = d({ 74, 164, 236 });
	o.green = d({ 98, 210, 112 });
	sM.C = o;
end;
EM();
local QM = {};
local function dM()
	local g = sM.TextSize;
	local o = y[sM.FontName] or Z;
	if sM.Settings.charRatio then
		o = { mono = sM.Settings.charRatio };
	end;
	QM.metric = o;
	QM.em = g * ((o.sans or 1));
	QM.cw = o.mono and g * o.mono or QM.em * .56;
	QM.th = g;
	QM.twCache, QM.twCount = {}, 0;
	local s = g / 13;
	QM.k = s;
	local function f(g)
		return c(1, W(g * s + .5));
	end;
	QM.R = c(QM.th + 10, f(28));
	QM.ty = W(((QM.R - QM.th)) / 2);
	QM.cb = c(8, W(QM.R * .55 + .5));
	QM.bar = f(7);
	QM.pad = f(18);
	QM.gpad = f(12);
	QM.title = f(48);
	QM.tabs = f(32);
	QM.colGap = f(16);
	QM.gutter = f(7);
	QM.sbw = f(3);
	QM.half = W(QM.th / 2);
	QM.gtop = f(30);
	QM.gbot = f(12);
	QM.ggap = f(16);
	QM.arrowH = f(11);
	QM.dash = f(6);
	QM.titleX = f(10);
end;
dM();
local function TM(g)
	if QM.metric.mono then
		return #g * QM.cw;
	end;
	local o = 0;
	for s = 1, #g, 1 do
		o = o + A[T(g, s)];
	end;
	return o * QM.em;
end;
local function CM(g)
	local o = QM.twCache[g];
	if o then
		return o;
	end;
	o = W(TM(g) + .5);
	if QM.twCount > 4000 then
		QM.twCache, QM.twCount = {}, 0;
	end;
	QM.twCache[g] = o;
	QM.twCount = QM.twCount + 1;
	return o;
end;
local function hM(g, o)
	local s, f = 0, #g;
	while s < f do
		local n = W((((s + f) + 1)) / 2);
		if TM(Q(g, 1, n)) <= o then
			s = n;
		else
			f = n - 1;
		end;
	end;
	return s;
end;
local function UM(g, o)
	if CM(g) <= o then
		return g;
	end;
	local s = hM(g, o - TM(".."));
	if s <= 0 then
		return "";
	end;
	return Q(g, 1, s) .. "..";
end;
local function VM(g, o)
	local s, f = 0, k(o);
	for n = 1, #g, 1 do
		local W = k(TM(Q(g, 1, n)) - o);
		if W < f then
			s, f = n, W;
		end;
	end;
	return s;
end;
local function IM(g, o)
	local s = {};
	for g in ((tostring(g) .. "\n")):gmatch("(.-)\n") do
		local f = "";
		for g in g:gmatch("%S+") do
			if f == "" then
				f = g;
			elseif TM(f .. (" " .. g)) <= o then
				f = f .. (" " .. g);
			else
				s[#s + 1] = f;
				f = g;
			end;
		end;
		s[#s + 1] = f;
	end;
	return s;
end;
local function tM(g, o)
	local s = {};
	for g in ((tostring(g) .. "\n")):gmatch("(.-)\n") do
		local f = "";
		for g in g:gmatch("%S+") do
			if f == "" then
				f = g;
			elseif (#f + 1) + #g <= o then
				f = f .. (" " .. g);
			else
				s[#s + 1] = f;
				f = g;
			end;
		end;
		s[#s + 1] = f;
	end;
	return s;
end;
local PM = 2000;
local KM = {
		frame = PM + 1,
		frameIn = PM + 2,
		bg = PM + 3,
		chrome = PM + 4,
		chromeText = PM + 5,
		gEdge = PM + 6,
		gFill = PM + 7,
		gHead = PM + 8,
		hover = PM + 8,
		ctl = PM + 9,
		ctlIn = PM + 10,
		ctlFill = PM + 11,
		text = PM + 12,
		sbar = PM + 12,
		sthumb = PM + 13,
		mark = PM + 2000,
		markIn = PM + 2001,
		markBg = PM + 2002,
		markText = PM + 2003,
		pop = PM + 2010,
		popIn = PM + 2011,
		popBg = PM + 2012,
		popCtl = PM + 2013,
		popCtlIn = PM + 2014,
		popFill = PM + 2015,
		popOver = PM + 2016,
		popOver2 = PM + 2017,
		popText = PM + 2018,
		popTop = PM + 2019,
		toast = PM + 2020,
		toastIn = PM + 2021,
		toastBg = PM + 2022,
		toastFill = PM + 2023,
		toastText = PM + 2024,
		tip = PM + 2030,
		tipIn = PM + 2031,
		tipText = PM + 2032,
	};
local BM = 20;
local function lM(g, o, f, n)
	if g.dead then
		return {
			dead = true,
			z = f,
			a = 1,
			t = o == "Text" or nil,
		};
	end;
	local W = s.new(o);
	local c = {
			d = W,
			v = false,
			bg = n,
			a = 1,
			z = f,
		};
	g[#g + 1] = c;
	W.Visible = false;
	W.ZIndex = f + ((g.zoff or 0));
	if o == "Text" then
		c.t = true;
		W.Size = sM.TextSize;
		c.fs = sM.TextSize;
		if sM.Font ~= nil then
			W.Font = sM.Font;
			c.f = sM.Font;
		end;
		W.Outline = sM.TextOutline;
		c.o = sM.TextOutline;
		W.Center = false;
	else
		W.Filled = true;
	end;
	if n and sM.Opacity ~= 1 then
		W.Transparency = sM.Opacity;
		c.a = sM.Opacity;
	end;
	return c;
end;
local function LM(g)
	if g.v and not g.dead then
		g.v = false;
		g.d.Visible = false;
	end;
end;
local function xM(g, o, s, n, c, R)
	if g.dead then
		return;
	end;
	o, s, n, c = W(o + .5), W(s + .5), W(n + .5), W(c + .5);
	if n <= 0 or c <= 0 then
		return LM(g);
	end;
	local k = g.d;
	if g.x ~= o or g.y ~= s then
		g.x, g.y = o, s;
		k.Position = f(o, s);
	end;
	if g.w ~= n or g.h ~= c then
		g.w, g.h = n, c;
		k.Size = f(n, c);
	end;
	if g.c ~= R then
		g.c = R;
		k.Color = R;
	end;
	if not g.v then
		g.v = true;
		k.Visible = true;
	end;
end;
local function jM(g, o, s, n, c)
	if g.dead then
		return;
	end;
	if o == "" then
		return LM(g);
	end;
	s, n = W(s + .5), W(n + .5);
	local R = g.d;
	if g.s ~= o then
		g.s = o;
		R.Text = o;
	end;
	if g.x ~= s or g.y ~= n then
		g.x, g.y = s, n;
		R.Position = f(s, n);
	end;
	if g.c ~= c then
		g.c = c;
		R.Color = c;
	end;
	if not g.v then
		g.v = true;
		R.Visible = true;
	end;
end;
local function HM(g, o)
	if g.a ~= o and not g.dead then
		g.a = o;
		g.d.Transparency = o;
	end;
end;
local function YM(g)
	if g.dead or not g.t then
		return;
	end;
	local o = g.d;
	if g.fs ~= sM.TextSize then
		g.fs = sM.TextSize;
		o.Size = sM.TextSize;
	end;
	if sM.Font ~= nil and g.f ~= sM.Font then
		g.f = sM.Font;
		o.Font = sM.Font;
	end;
	if g.o ~= sM.TextOutline then
		g.o = sM.TextOutline;
		o.Outline = sM.TextOutline;
	end;
end;
local function wM(g)
	for o = 1, #g, 1 do
		LM(g[o]);
	end;
end;
local function NM(g)
	for o = 1, #g, 1 do
		g[o].dead = true;
	end;
	for o = 1, #g, 1 do
		local s = g[o].d;
		s.Visible = false;
		s:Remove();
	end;
end;
local vM = {};
function vM.paint(g, o, s, f, n, c, R, k)
	local E = sM.C;
	xM(g, s, f, n, c, k == "hot" and E.hover or E.group);
	local Q = (k == "hot" and E.accent) or (k == "on" and E.text) or E.textOff;
	local d = s + W(n / 2);
	local T = f + W(((c - 4)) / 2);
	for g = 1, 4, 1 do
		local s = R and (g * 2 - 1) or (9 - g * 2);
		xM(o[g], d - W(s / 2), (T + g) - 1, s, 1, Q);
	end;
end;
function vM.hide(g, o)
	LM(g);
	for g = 1, 4, 1 do
		LM(o[g]);
	end;
end;
function vM.state(g, o, s, f, n)
	if not n then
		return "off";
	end;
	local W = sM._arrow;
	if W and (W.kind == g and (W.win == o and (W.c == s and W.dir == f))) then
		return "hot";
	end;
	return "on";
end;
local XM, JM, MM;
local SM, pM, aM;
local uM, DM, eM;
local iM, bM;
local qM;
local OM = { visible = false };
local mM;
local rM = {};
rM.__index = rM;
local function zM()
	local g = setmetatable({}, { __index = rM });
	g.__index = g;
	return g;
end;
local yM = { ["!"] = { text = "[!]", color = "red", title = "risky" }, ["?"] = { text = "[?]", color = "orange", title = "info" }, p = { text = "[p]", color = "blue", title = "permission" } };
local function ZM(g)
	local o = g._badge;
	if not o then
		return sM.C.accent;
	end;
	if type(o.color) == "string" then
		return sM.C[o.color] or sM.C.accent;
	end;
	return o.color or sM.C.accent;
end;
local function AM(g, o)
	g.tooltip = o;
	g._tipTitle, g._tipLines = nil, nil;
	if o == nil or o == false then
		return;
	end;
	local s, f;
	if type(o) == "table" then
		s, f = o.title, o.text;
	else
		f = o;
	end;
	if s == nil and (g._badge and g._badge.title) then
		s = "[" .. (g._badge.title .. "]");
	end;
	g._tipTitle = s and tostring(s) or nil;
	g._tipLines = f and tM(tostring(f), 40) or {};
	if not g._tipTitle and #g._tipLines == 0 then
		g._tipLines = nil;
	end;
end;
local function FM(g, o, s, f)
	local n = lM(g.win.nodes, o, s, f);
	g.nodes[#g.nodes + 1] = n;
	if g.host then
		g.host.nodes[#g.host.nodes + 1] = n;
	end;
	return n;
end;
local function GM(g, o, s, f, n)
	if type(s) ~= "table" then
		s = { text = s };
	end;
	local W = g.win;
	local c = setmetatable({
			kind = o,
			win = W,
			o = s,
			text = tostring(s.text or s.name or s.title or ""),
			flag = s.flag or s.Flag,
			callback = s.callback or s.Callback,
			enabled = s.enabled ~= false and s.disabled ~= true,
			depOk = true,
			visible = s.visible ~= false,
			hideDisabled = s.hideDisabled,
			nodes = {},
			listeners = {},
			host = n,
			inline = n ~= nil,
		}, f);
	if s.badge then
		if type(s.badge) == "table" then
			c._badge = { text = tostring(s.badge.text or "[*]"), color = s.badge.color, title = s.badge.title };
		else
			c._badge = yM[s.badge] or { text = "[" .. (tostring(s.badge) .. "]"), color = "accent" };
		end;
	end;
    local help = sM.Ocean and sM.Ocean.labels[c.text];
    local tip = s.tooltip or s.Tooltip;
    if help then
        c.text = help[1];
        -- Preserve every existing explanatory note, including caution badges.
        if type(tip) == "table" then tip = tip.text; end;
        tip = help[2] .. (tip and ("\n" .. tostring(tip)) or "");
    elseif not tip and o ~= "label" then
        tip = c.text; -- Full caption remains available when a narrow row truncates it.
    end;
    AM(c, tip);
	if n then
		c.group = n.group;
		n.addons[#n.addons + 1] = c;
	else
		c.group = g;
		g.widgets[#g.widgets + 1] = c;
	end;
	W.widgets[#W.widgets + 1] = c;
	if c.flag then
		W:_registerFlag(c);
	end;
	if s.depends ~= nil then
		c.depends = s.depends;
		W.depWidgets[#W.depWidgets + 1] = c;
		W._depsDirty = true;
	end;
	W._dirty = true;
	return c;
end;
function rM._enabled(g)
	if g.host then
		return g.enabled and (g.depOk and g.host:_enabled());
	end;
	return g.enabled and g.depOk;
end;
function rM._shown(g)
	return g.visible and ((g.depOk or not g.hideDisabled));
end;
function rM.hideNodes(g)
	g.placed = false;
	wM(g.nodes);
	if g.addons then
		for o = 1, #g.addons, 1 do
			g.addons[o].placed = false;
		end;
	end;
end;
function rM.Get(g)
	return g.value;
end;
function rM._equal(o, g)
	return g == o.value;
end;
function rM._repaint(g)
	if g.host then
		if g.host.placed then
			g.host:paint();
		end;
	elseif g.placed then
		g:paint();
	end;
end;
function rM._apply(o, g)
	o.value = g;
	o:_repaint();
	o.win:_changed(o);
end;
function rM._fire(g)
	g._pending = nil;
	g._lastFire = V();
	local o = g:_cbValue();
	WM(g.callback, o, g);
	for s = 1, #g.listeners, 1 do
		WM(g.listeners[s], o, g);
	end;
	local s = g.win;
	if #s.depWidgets > 0 and s.alive then
		s:_depsChanged();
	end;
end;
function rM._fireSoon(g)
	g._pending = true;
	sM._pending[g] = true;
end;
function rM._cbValue(g)
	return g.value;
end;
function rM.Set(s, g, o)
	if s._coerce then
		g = s:_coerce(g);
	end;
	if g == nil or s:_equal(g) then
		return s;
	end;
	s:_apply(g);
	if not o then
		s:_fire();
	end;
	return s;
end;
function rM.SetValue(s, g, o)
	return s:Set(g, o);
end;
function rM.GetValue(g)
	return g:Get();
end;
function rM.OnChanged(o, g)
	o.listeners[#o.listeners + 1] = g;
	return o;
end;
function rM.SetText(o, g)
	o.text = tostring(g or "");
	o:_repaint();
	return o;
end;
function rM.SetVisible(o, g)
	g = g and true or false;
	if g ~= o.visible then
		o.visible = g;
		if not g then
			o:hideNodes();
		end;
		o.win._dirty = true;
	end;
	return o;
end;
function rM.SetEnabled(o, g)
	g = g and true or false;
	if g ~= o.enabled then
		o.enabled = g;
		o:_repaint();
	end;
	return o;
end;
function rM.SetTooltip(o, g)
	AM(o, g);
	return o;
end;
function rM.height(g)
	return QM.R;
end;
local function g1(g, o)
	if sM._hover == g and (g:_enabled() and g.placed) then
		xM(g.n.hover, g.px, g.py, g.pw, o, sM.C.hover);
	else
		LM(g.n.hover);
	end;
end;
local function o1(g, o, s)
	local f = g.n.badge;
	if f then
		jM(f, g._badge.text, o, s, g:_enabled() and ZM(g) or sM.C.textOff);
	end;
end;
local function s1(g)
	return g:_enabled() and sM.C.text or sM.C.textOff;
end;
local function f1(g, o, s)
	local f = g.addons;
	if not f then
		return o;
	end;
	for g = #f, 1, -1 do
		local n = f[g];
		if n.visible then
			o = n:paintInline(o, s) - 6;
		else
			n:hideNodes();
		end;
	end;
	return o;
end;
local function n1(g, o)
	local s = g.addons;
	if not s then
		return nil;
	end;
	for g = 1, #s, 1 do
		local f = s[g];
		if f.placed and (f.zx1 and (o >= f.zx1 - 3 and o <= f.zx2 + 3)) then
			return f;
		end;
	end;
	return nil;
end;
local W1 = zM();
function W1._coerce(o, g)
	return g and true or false;
end;
function W1.paint(widget)
    local nodes, colors = widget.n, sM.C;
    local x, y, width = widget.px, widget.py, widget.pw;
    local enabled = widget:_enabled();
    g1(widget, QM.R);
    local h, w = W(14 * QM.k), W(28 * QM.k);
    local sx, sy = x + width - QM.gpad - w, y + W((QM.R - h) / 2);
    local right = f1(widget, sx - 8, y);
    local label = UM(widget.text, right - x - QM.gpad - (widget._badge and 24 or 4));
    jM(nodes.label, label, x + QM.gpad, y + QM.ty, s1(widget));
    o1(widget, x + QM.gpad + CM(label) + W(QM.cw), y + QM.ty);
    xM(nodes.box, sx, sy, w, h, widget.value and colors.accentDim or colors.outline);
    xM(nodes.boxIn, sx + 1, sy + 1, w - 2, h - 2, widget.value and colors.accent or colors.control);
    local thumbX = widget.value and sx + w - h + 2 or sx + 2;
    xM(nodes.fill, thumbX, sy + 2, h - 4, h - 4, enabled and colors.text or colors.textOff);
end;
function W1.press(o, g)
	local s = n1(o, g);
	if s then
		if s:_enabled() then
			s:press(g);
		end;
		return;
	end;
	o:Set(not o.value);
end;
function W1.rpress(o, g)
	local s = n1(o, g);
	if s and s.rpress then
		s:rpress(g);
	end;
end;
local c1 = zM();
function c1._coerce(o, g)
	g = tonumber(g);
	if not g then
		return nil;
	end;
	local s, f, n = o.min, o.max, o.step;
	g = P(g, s, f);
	if n > 0 then
		g = s + W(((g - s)) / n + .5) * n;
		g = P(g, s, f);
	end;
	return tonumber(E("%." .. (o.decimals .. "f"), g));
end;
function c1._display(g)
	if g.format then
		local o = RM(g, "format", g.value);
		if o ~= nil then
			return tostring(o);
		end;
	end;
	return E("%." .. (g.decimals .. "f"), g.value) .. g.suffix;
end;
function c1.height(g)
	return (QM.R + QM.bar) + 4;
end;
function c1.paint(g)
	local o, s = g.n, sM.C;
	local f, n, R = g.px, g.py, g.pw;
	local k = g:_enabled();
	g1(g, g:height());
	local E = f + QM.gpad;
	jM(o.label, g.text, E, n + QM.ty, s1(g));
	o1(g, (E + CM(g.text)) + W(QM.cw), n + QM.ty);
	local d = sM._focus;
	local T = d and d.target == g;
	local C = T and d.buf or g:_display();
	local h = ((f + R) - QM.gpad) - CM(C);
	jM(o.val, C, h, n + QM.ty, T and s.text or (k and s.accent or s.textOff));
    local caption = UM(g.text, h - E - 14 - (g._badge and 24 or 0));
    jM(o.label, caption, E, n + QM.ty, s1(g));
    o1(g, E + CM(caption) + W(QM.cw), n + QM.ty);
	if T and d.caretOn then
		xM(o.caret, h + W(TM(Q(d.buf, 1, d.caret)) + .5), n + QM.ty, 1, QM.th, s.text);
	else
		LM(o.caret);
	end;
	local U = c(CM(C), W(QM.cw * 4));
	g._vx = h;
	g.boxX, g.boxW = (((f + R) - QM.gpad) - U) - W(QM.cw), (U + W(QM.cw)) + QM.gpad;
	g.boxY, g.boxH = n, QM.R - 2;
	local V, I, t, K = f + QM.gpad, (n + QM.R) - 1, R - QM.gpad * 2, QM.bar;
	xM(o.edge, V, I, t, K, T and s.accent or (((sM._hover == g and k)) and s.outlineHi or s.outline));
	xM(o.inner, V + 1, I + 1, t - 2, K - 2, s.control);
	local B = g.max - g.min;
	local l = B > 0 and P(((g.value - g.min)) / B, 0, 1) or 0;
	local L = W(((t - 4)) * l + .5);
	if L > 0 then
		xM(o.fill, V + 2, I + 2, L, K - 4, k and s.accent or s.accentDim);
	else
		LM(o.fill);
	end;
	g.bx, g.bw = V + 2, t - 4;
end;
function c1._dragTo(o, g)
	if not o.bw or o.bw <= 0 then
		return;
	end;
	local s = P(((g - o.bx)) / o.bw, 0, 1);
	local f = o:_coerce(o.min + s * ((o.max - o.min)));
	if f ~= nil and f ~= o.value then
		o:_apply(f);
		o:_fireSoon();
	end;
end;
function c1._edit(g)
	local o = E("%." .. (g.decimals .. "f"), g.value);
	uM({
		target = g,
		buf = o,
		caret = #o,
		fresh = true,
		numeric = true,
		maxLength = 14,
		commit = function(o)
			local s = tonumber(o);
			if s then
				g:Set(s);
			else
				g:_repaint();
			end;
		end,
		preview = function()
 
		end,
		refresh = function()
			if g.placed then
				g:paint();
			end;
		end,
	});
end;
function c1.press(s, g, o)
	local f = sM._focus;
	if f and f.target == s then
		f.caret = R(#f.buf, VM(f.buf, g - ((s._vx or g))));
		f.t0, f.caretOn = V(), true;
		if s.placed then
			s:paint();
		end;
		return;
	end;
	if o and (s.boxY and K(g, o, s.boxX, s.boxY, s.boxW, s.boxH)) then
		s:_edit();
		return;
	end;
	sM._cap = { kind = "slider", wid = s };
	s:_dragTo(g);
end;
function c1.nudge(o, g)
	local s = o.step > 0 and o.step or ((o.max - o.min)) / 100;
	o:Set(o.value + g * s);
end;
local R1 = zM();
function R1._isSelected(o, g)
	if o.multi then
		return o.value[g] == true;
	end;
	return o.value == g;
end;
function R1._has(o, g)
	for s = 1, #o.values, 1 do
		if o.values[s] == g then
			return true;
		end;
	end;
	return false;
end;
function R1._coerce(o, g)
	if o.multi then
		local s = {};
		if type(g) == "table" then
			for g, f in pairs(g) do
				if type(g) == "number" then
					if o:_has(f) then
						s[f] = true;
					end;
				elseif f and o:_has(g) then
					s[g] = true;
				end;
			end;
		elseif g ~= nil and o:_has(g) then
			s[g] = true;
		end;
		return s;
	end;
	if g == nil or g == false then
		return o.allowNone and false or nil;
	end;
	g = tostring(g);
	if o:_has(g) then
		return g;
	end;
	return nil;
end;
function R1._equal(o, g)
	if o.multi then
		for g in pairs(g) do
			if not o.value[g] then
				return false;
			end;
		end;
		for o in pairs(o.value) do
			if not g[o] then
				return false;
			end;
		end;
		return true;
	end;
	return g == o.value;
end;
function R1._cbValue(g)
	if g.value == false then
		return nil;
	end;
	return g.value;
end;
function R1._display(g)
	if g.multi then
		local o = {};
		for s = 1, #g.values, 1 do
			if g.value[g.values[s]] then
				o[#o + 1] = g.values[s];
			end;
		end;
		return #o > 0 and h(o, ", ") or "none";
	end;
	if g.value == nil or g.value == false then
		return "none";
	end;
	return tostring(g.value);
end;
function R1.paint(g)
	local o, s = g.n, sM.C;
	local f, n, R = g.px, g.py, g.pw;
	local k = g:_enabled();
	g1(g, QM.R);
	local E = f + QM.gpad;
	jM(o.label, g.text, E, n + QM.ty, s1(g));
	local Q = (E + CM(g.text)) + W(QM.cw);
	if o.badge then
		o1(g, Q, n + QM.ty);
		Q = (Q + CM(g._badge.text)) + W(QM.cw);
	end;
	local d = sM._drop == g;
	local T = UM(g:_display(), c(0, (((f + R) - QM.gpad) - Q) - QM.cw * 2)) .. ((d and " v" or " >"));
	jM(o.val, T, ((f + R) - QM.gpad) - CM(T), n + QM.ty, k and s.accent or s.textOff);
end;
function R1.press(g)
	if sM._drop == g then
		JM();
	else
		XM(g);
	end;
end;
function R1.rpress(g)
	if g.multi or #g.values == 0 then
		return;
	end;
	local o = 0;
	for s = 1, #g.values, 1 do
		if g.values[s] == g.value then
			o = s;
		end;
	end;
	g:Set(g.values[o % #g.values + 1]);
end;
function R1._pick(o, g)
	if o.multi then
		local s = {};
		for g in pairs(o.value) do
			s[g] = true;
		end;
		s[g] = (not s[g]) or nil;
		o:Set(s);
	elseif o.value == g and o.allowNone then
		o:Set(false);
	else
		o:Set(g);
	end;
end;
function R1.SetValues(o, g)
	o.values = {};
	for s = 1, #((g or {})), 1 do
		o.values[s] = tostring(g[s]);
	end;
	if o.multi then
		local g = {};
		for s in pairs(o.value) do
			if o:_has(s) then
				g[s] = true;
			end;
		end;
		o.value = g;
	elseif o.value and not o:_has(o.value) then
		o.value = o.allowNone and false or o.values[1];
	end;
	if o.placed then
		o:paint();
	end;
	if sM._drop == o then
		MM();
	end;
	return o;
end;
function R1.GetValues(g)
	return g.values;
end;
local k1 = zM();
function k1.height(g)
	return QM.R + 4;
end;
function k1.paint(g)
	local o, s = g.n, sM.C;
	local f, n, c = g.px, g.py, g.pw;
	local R = g:_enabled();
	local k = sM._hover == g and R;
	local E, Q, d, T = f + QM.gpad, n + 2, c - QM.gpad * 2, QM.R;
	xM(o.edge, E, Q, d, T, k and s.accent or s.border);
	xM(o.inner, E + 1, Q + 1, d - 2, T - 2, ((g.held and k)) and s.press or (k and s.controlHi or s.control));
	local C = UM(g.text, d - 20 - (g._badge and 26 or 0));
	local h = s1(g);
	if g._armed then
		C, h = "are you sure?", s.accent;
	end;
	local U = CM(C);
	local V = ((o.badge and not g._armed)) and g._badge.text or nil;
	if V then
		U = (U + W(QM.cw)) + CM(V);
	end;
	local I = E + W(((d - U)) / 2);
	local t = Q + W(((T - QM.th)) / 2);
	jM(o.label, C, I, t, h);
	if V then
		o1(g, (I + CM(C)) + W(QM.cw), t);
	elseif o.badge then
		LM(o.badge);
	end;
end;
function k1.press(g)
	g.held = true;
	sM._cap = { kind = "button", wid = g };
	g:paint();
end;
function k1._click(g)
	if g.confirm and not g._armed then
		g._armed = V() + 2.5;
		sM._armed = g;
		if g.placed then
			g:paint();
		end;
		return;
	end;
	if g._armed then
		g._armed = nil;
		if sM._armed == g then
			sM._armed = nil;
		end;
		if g.placed then
			g:paint();
		end;
	end;
	WM(g.callback, g);
	for o = 1, #g.listeners, 1 do
		WM(g.listeners[o], g);
	end;
end;
function k1.Fire(g)
	WM(g.callback, g);
end;
local E1 = zM();
function E1._coerce(o, g)
	if g == nil then
		return nil;
	end;
	g = tostring(g);
	if o.numeric then
		g = g:gsub("[^%d%.%-]", "");
	end;
	if o.maxLength and #g > o.maxLength then
		g = Q(g, 1, o.maxLength);
	end;
	return g;
end;
function E1._cbValue(g)
	if g.numeric then
		return tonumber(g.value);
	end;
	return g.value;
end;
function E1.height(g)
	return (((g.text ~= "" and QM.R or 0)) + QM.R) + 4;
end;
function E1.paint(g)
	local o, s = g.n, sM.C;
	local f, n, c = g.px, g.py, g.pw;
	local R = g:_enabled();
	local k = n + 2;
	if g.text ~= "" then
		jM(o.label, g.text, f + QM.gpad, n + QM.ty, s1(g));
		o1(g, ((f + QM.gpad) + CM(g.text)) + W(QM.cw), n + QM.ty);
		k = n + QM.R;
	else
		LM(o.label);
	end;
	local E = sM._focus;
	local d = E and E.target == g;
	local T, C, h = f + 4, c - 8, QM.R;
	xM(o.edge, T, k, C, h, d and s.accent or (((sM._hover == g and R)) and s.outlineHi or s.outline));
	xM(o.inner, T + 1, k + 1, C - 2, h - 2, s.control);
	local U = C - 10;
	local V = k + W(((h - QM.th)) / 2);
	if d then
		local f, n = E.buf, E.caret;
		local c = 0;
		while c < n and TM(Q(f, c + 1, n)) > U do
			c = c + 1;
		end;
		local R = Q(f, c + 1);
		jM(o.value, Q(R, 1, hM(R, U)), T + 5, V, s.text);
		g._first = c;
		if E.caretOn then
			xM(o.caret, (T + 5) + W(TM(Q(f, c + 1, n)) + .5), V, 1, QM.th, s.text);
		else
			LM(o.caret);
		end;
	else
		LM(o.caret);
		if g.value == "" then
			jM(o.value, UM(g.placeholder, C - 10), T + 5, V, s.textOff);
		else
			jM(o.value, UM(g.value, C - 10), T + 5, V, R and s.text or s.textOff);
		end;
	end;
	g.boxY, g.boxH = k, h;
end;
function E1.press(o, g)
	local s = #o.value;
	if o.boxY then
		s = VM(o.value, g - ((o.px + 9)));
	end;
	uM({
		target = o,
		buf = o.value,
		caret = R(#o.value, s),
		numeric = o.numeric,
		maxLength = o.maxLength,
		live = o.live,
		commit = function(g)
			o:Set(g);
		end,
		preview = function(g)
			o:Set(g);
		end,
		refresh = function()
			if o.placed then
				o:paint();
			end;
		end,
	});
end;
local Q1 = zM();
function Q1._equal(g)
	return false;
end;
function Q1._setRGB(s, g, o)
	local f, n, W = t(g[1]), t(g[2]), t(g[3]);
	local c = s.rgb;
	if c and (t(c[1]) == f and (t(c[2]) == n and t(c[3]) == W)) then
		return;
	end;
	s.rgb = { f, n, W };
	local R, k, E = x(s.rgb);
	if (k > 0 and E > 0) or s.h == nil then
		s.h = R;
	end;
	s.s, s.v = k, E;
	s:_apply(l(s.rgb));
	if sM._pick == s then
		aM();
	end;
	if not o then
		s:_fire();
	end;
end;
function Q1._setHSV(n, g, o, s, f)
	n.h, n.s, n.v = g % 1, P(o, 0, 1), P(s, 0, 1);
	n.rgb = L(n.h, n.s, n.v);
	n:_apply(l(n.rgb));
	if sM._pick == n then
		aM();
	end;
	if not f then
		n:_fire();
	end;
end;
function Q1.Set(s, g, o)
	local f = Y(g);
	if f then
		s:_setRGB(f, o);
	end;
	return s;
end;
function Q1.GetRGB(g)
	return t(g.rgb[1]), t(g.rgb[2]), t(g.rgb[3]);
end;
function Q1.GetHex(g)
	return j(g.rgb);
end;
function Q1.SetRainbow(o, g)
	g = g and true or false;
	o.rainbow = g;
	sM._rainbow[o] = g or nil;
	if sM._pick == o then
		aM();
	end;
	o.win:_changed(o);
	return o;
end;
function Q1._paintSwatch(s, g, o)
	local f, n = s.n, sM.C;
	local W, c = QM.cb * 2 + 4, QM.cb;
	local R = (sM._pick == s) or (sM._hover == ((s.host or s)) and s:_enabled());
	xM(f.swEdge, g, o, W, c, R and n.text or n.outlineHi);
	xM(f.swRing, g + 1, o + 1, W - 2, c - 2, n.control);
	xM(f.swFill, g + 2, o + 2, W - 4, c - 4, s.value);
	return W;
end;
function Q1.paint(g)
	local o = g.n;
	local s, f, n = g.px, g.py, g.pw;
	g1(g, QM.R);
	local c = s + QM.gpad;
	jM(o.label, g.text, c, f + QM.ty, s1(g));
	o1(g, (c + CM(g.text)) + W(QM.cw), f + QM.ty);
	local R = QM.cb * 2 + 4;
	local k = ((s + n) - QM.gpad) - R;
	g:_paintSwatch(k, f + W(((QM.R - QM.cb)) / 2));
	g.zx1, g.zx2 = k, k + R;
	f1(g, k - 6, f);
end;
function Q1.paintInline(s, g, o)
	local f = s.host;
	s.px, s.py, s.pw = f.px, f.py, f.pw;
	s.placed = true;
	local n = QM.cb * 2 + 4;
	local c = g - n;
	s:_paintSwatch(c, o + W(((QM.R - QM.cb)) / 2));
	s.zx1, s.zx2 = c, g;
	return c;
end;
function Q1.press(o, g)
	if not o.inline then
		local s = n1(o, g);
		if s and s ~= o then
			if s:_enabled() then
				s:press(g);
			end;
			return;
		end;
	end;
	if sM._pick == o then
		pM();
	else
		SM(o);
	end;
end;
function Q1._cbValue(g)
	return g.value;
end;
local d1 = zM();
local T1 = { "toggle", "hold", "always" };
function d1._coerce(o, g)
	if g == nil or g == false or g == "" or g == "NONE" or g == "none" then
		return false;
	end;
	return S(g);
end;
function d1._equal(o, g)
	return ((g or false)) == ((o.vk or false));
end;
function d1._apply(o, g)
	o.vk = g or nil;
	o.value = o.vk and v[o.vk] or nil;
	o.down = o.vk and O(o.vk) or false;
	o:_repaint();
	o.win:_changed(o);
end;
function d1.Set(o, g)
	local s = o:_coerce(g);
	if s == nil or o:_equal(s) then
		return o;
	end;
	o:_apply(s);
	WM(o.o.changed, o.value, o);
	return o;
end;
function d1.Get(g)
	return g.value;
end;
function d1.GetKey(g)
	return g.vk;
end;
function d1.GetState(g)
	if g.mode == "always" then
		return true;
	end;
	if g.host and g.sync then
		return g.host.value;
	end;
	return g.state;
end;
function d1.SetMode(o, g)
	for s, f in ipairs(T1) do
		if f == g then
			o.mode = g;
			o.state = (g == "always");
			o.win:_changed(o);
		end;
	end;
	return o;
end;
function d1.OnClick(o, g)
	o.clicks[#o.clicks + 1] = g;
	return o;
end;
function d1._tag(g)
	if sM._listen == g then
		return "[...]";
	end;
	if g._flash and V() < g._flash then
		return "[" .. (g.mode .. "]");
	end;
	return "[" .. (((g.value or "-")) .. "]");
end;
function d1._cbValue(g)
	return g:GetState();
end;
function d1.paint(g)
	local o, s = g.n, sM.C;
	local f, n, c = g.px, g.py, g.pw;
	local R = g:_enabled();
	g1(g, QM.R);
	local k = f + QM.gpad;
	jM(o.label, g.text, k, n + QM.ty, s1(g));
	o1(g, (k + CM(g.text)) + W(QM.cw), n + QM.ty);
	local E = g:_tag();
	local Q = ((f + c) - QM.gpad) - CM(E);
	jM(o.key, E, Q, n + QM.ty, (sM._listen == g) and s.text or (R and s.accent or s.textOff));
	g.zx1, g.zx2 = Q, (f + c) - QM.gpad;
end;
function d1.paintInline(s, g, o)
	local f, n = s.host, sM.C;
	s.px, s.py, s.pw = f.px, f.py, f.pw;
	s.placed = true;
	local W = s:_tag();
	local c = g - CM(W);
	jM(s.n.key, W, c, o + QM.ty, (sM._listen == s) and n.text or (s:_enabled() and n.accent or n.textOff));
	s.zx1, s.zx2 = c, g;
	return c;
end;
function d1.press(g)
	if sM._listen == g then
		bM(g, nil, true);
	else
		iM(g);
	end;
end;
function d1.rpress(g)
	local o = 1;
	for s, f in ipairs(T1) do
		if f == g.mode then
			o = s;
		end;
	end;
	g:SetMode(T1[o % #T1 + 1]);
	g._flash = V() + .9;
	sM._flashW = g;
	g:_repaint();
end;
function d1._setState(o, g)
	if g == o.state then
		return;
	end;
	o.state = g;
	if OM.visible then
		OM.dirty = true;
	end;
	WM(o.callback, g, o);
	for s = 1, #o.listeners, 1 do
		WM(o.listeners[s], g, o);
	end;
end;
function d1._edge(o, g)
	local s = o.host;
	if o.mode == "hold" then
		if s and o.sync then
			s:Set(g);
		else
			o:_setState(g);
		end;
	elseif o.mode == "toggle" and g then
		if s and o.sync then
			s:Set(not s.value);
			o:_toast(s.value);
		elseif o.callback or #o.listeners > 0 or #o.clicks == 0 then
			o:_setState(not o.state);
			o:_toast(o.state);
		else
			o:_toast(nil);
		end;
	end;
	if g then
		for g = 1, #o.clicks, 1 do
			WM(o.clicks[g], o);
		end;
	end;
end;
function d1._toast(o, g)
	if not sM.Settings.bindToasts or o.o.notify == false then
		return;
	end;
	local s = (o.text ~= "" and o.text) or (o.host and o.host.text) or "keybind";
	sM.Notify({
		text = g == nil and s or (s .. (": " .. ((g and "on" or "off")))),
		duration = 1.6,
		color = g == false and sM.C.textDim or nil,
		key = o,
	});
end;
local C1 = zM();
function C1._split(g)
	local o;
	local s = g.pw and (g.pw - QM.gpad * 2) or 0;
	if g.wrap and s > QM.cw * 4 then
		o = IM(g.text, s);
	else
		o = {};
		for g in ((g.text .. "\n")):gmatch("(.-)\n") do
			o[#o + 1] = g;
		end;
	end;
	g.lines = o;
	g._splitW, g._splitCw = g.pw, QM.cw;
	for o = #g.n.lines + 1, #o, 1 do
		g.n.lines[o] = FM(g, "Text", KM.text);
	end;
end;
function C1.height(g)
	if g._splitW == nil or (g.wrap and ((g._splitW ~= g.pw or g._splitCw ~= QM.cw))) then
		g:_split();
	end;
	return QM.R * c(1, #g.lines);
end;
function C1.paint(g)
	local o = sM.C;
	local s = g.color or (g.dim and o.textDim or o.text);
	if not g:_enabled() then
		s = o.textOff;
	end;
	local f = g.pw - QM.gpad * 2;
	for o, n in ipairs(g.n.lines) do
		if o <= #g.lines then
			jM(n, UM(g.lines[o], f), g.px + QM.gpad, (g.py + ((o - 1)) * QM.R) + QM.ty, s);
		else
			LM(n);
		end;
	end;
	f1(g, (g.px + g.pw) - QM.gpad, g.py);
end;
function C1.SetText(label, value)
    value = tostring(value or "");
    if label.text == value then return label; end;
    label.text = value;
    if not label.placed or not label.win.visible then
        label._splitW = nil;
        if label.group and label.group.tab == label.win:_activeTab() then
            label.win._dirty = true;
        end;
        return label;
    end;
    local oldCount = #label.lines;
    label:_split();
    if #label.lines ~= oldCount then label.win._dirty = true;
    else label:paint(); end;
    return label;
end;
function C1.SetColor(o, g)
	o.color = g;
	if o.placed then
		o:paint();
	end;
	return o;
end;
function C1.press(o, g)
	local s = n1(o, g);
	if s and s:_enabled() then
		s:press(g);
	end;
end;
function C1.rpress(o, g)
	local s = n1(o, g);
	if s and s.rpress then
		s:rpress(g);
	end;
end;
local h1 = zM();
function h1.height(g)
	return 9;
end;
function h1.paint(g)
	xM(g.n.line, g.px + QM.gpad, g.py + 4, g.pw - QM.gpad * 2, 1, sM.C.border);
end;
local U1 = {};
U1.__index = U1;
local function V1(g, o)
	o = type(o) == "table" and o or { default = o };
	local s = GM(g.group, "keybind", o, d1, g);
	s.n = { key = FM(s, "Text", KM.text) };
	s.mode = o.mode or "toggle";
	s.state = s.mode == "always";
	s.sync = (g.kind == "toggle") and (o.sync ~= false);
	s.clicks = {};
	if o.onClick then
		s.clicks[1] = o.onClick;
	end;
	s:_apply(S(o.default or o.key) or false);
	sM._binds[#sM._binds + 1] = s;
	return s;
end;
local function I1(g, o)
	o = type(o) == "table" and o or { default = o };
	local s = GM(g.group, "color", o, Q1, g);
	s.n = { swEdge = FM(s, "Square", KM.ctl), swRing = FM(s, "Square", KM.ctlIn), swFill = FM(s, "Square", KM.ctlFill) };
	s.title = o.title or (g.text ~= "" and g.text or "color");
	s.h = 0;
	s:_setRGB(Y(o.default) or { 255, 255, 255 }, true);
	if o.rainbow then
		s:SetRainbow(true);
	end;
	return s;
end;
W1.AddKeybind = V1;
W1.AddColor = I1;
W1.AddColorPicker = I1;
C1.AddKeybind = V1;
C1.AddColor = I1;
C1.AddColorPicker = I1;
function U1.AddToggle(o, g)
	local s = GM(o, "toggle", g, W1);
	g = s.o;
	s.value = ((g.default or g.Default)) and true or false;
	s.n = {
			hover = FM(s, "Square", KM.hover),
			label = FM(s, "Text", KM.text),
			box = FM(s, "Square", KM.ctl),
			boxIn = FM(s, "Square", KM.ctlIn),
			fill = FM(s, "Square", KM.ctlFill),
		};
	if s._badge then
		s.n.badge = FM(s, "Text", KM.text);
	end;
	s.addons = {};
	return s;
end;
U1.AddCheckbox = U1.AddToggle;
function U1.AddSlider(o, g)
	local s = GM(o, "slider", g, c1);
	g = s.o;
	s.min = tonumber(g.min or g.Min) or 0;
	s.max = tonumber(g.max or g.Max) or 100;
	if s.max < s.min then
		s.min, s.max = s.max, s.min;
	end;
	local f = tonumber(g.decimals or g.rounding);
	s.step = tonumber(g.step or g.increment) or (f and 10 ^ (-W(f))) or 1;
	if not f then
		f = 0;
		if s.step > 0 and s.step < 1 then
			local g = (E("%.6f", s.step)):gsub("0+$", "");
			f = #((g:match("%.(%d*)$") or ""));
		end;
	end;
	s.decimals = P(W(f), 0, 6);
	s.suffix = tostring(g.suffix or "");
	s.format = g.format;
	s.value = s:_coerce(g.default or g.Default or s.min) or s.min;
	s.n = {
			hover = FM(s, "Square", KM.hover),
			label = FM(s, "Text", KM.text),
			val = FM(s, "Text", KM.text),
			edge = FM(s, "Square", KM.ctl),
			inner = FM(s, "Square", KM.ctlIn),
			fill = FM(s, "Square", KM.ctlFill),
			caret = FM(s, "Square", KM.ctlFill),
		};
	if s._badge then
		s.n.badge = FM(s, "Text", KM.text);
	end;
	return s;
end;
function U1.AddDropdown(o, g)
	local s = GM(o, "dropdown", g, R1);
	g = s.o;
	s.multi = g.multi and true or false;
	s.allowNone = g.allowNone or g.AllowNull;
	s.values = {};
	for g, o in ipairs(g.values or g.Values or g.options or {}) do
		s.values[g] = tostring(o);
	end;
	if s.multi then
		s.value = {};
		s.value = s:_coerce(g.default or g.Default or {});
	else
		local o = g.default or g.Default;
		if type(o) == "number" and s.values[o] then
			o = s.values[o];
		end;
		s.value = s:_coerce(o);
		if s.value == nil then
			s.value = s.allowNone and false or s.values[1];
		end;
	end;
	s.n = { hover = FM(s, "Square", KM.hover), label = FM(s, "Text", KM.text), val = FM(s, "Text", KM.text) };
	if s._badge then
		s.n.badge = FM(s, "Text", KM.text);
	end;
	return s;
end;
function U1.AddButton(s, g, o)
	if type(g) == "string" then
		g = { text = g, callback = o };
	end;
	local f = GM(s, "button", g, k1);
	f.confirm = g.confirm or g.DoubleClick;
	f.n = { edge = FM(f, "Square", KM.ctl), inner = FM(f, "Square", KM.ctlIn), label = FM(f, "Text", KM.text) };
	if f._badge then
		f.n.badge = FM(f, "Text", KM.text);
	end;
	return f;
end;
function U1.AddTextbox(o, g)
	local s = GM(o, "textbox", g, E1);
	g = s.o;
	s.numeric = g.numeric;
	s.maxLength = tonumber(g.maxLength or g.MaxLength);
	s.placeholder = tostring(g.placeholder or g.Placeholder or "");
	s.live = g.live;
	s.value = s:_coerce(g.default or g.Default or "") or "";
	s.n = {
			label = FM(s, "Text", KM.text),
			edge = FM(s, "Square", KM.ctl),
			inner = FM(s, "Square", KM.ctlIn),
			value = FM(s, "Text", KM.text),
			caret = FM(s, "Square", KM.ctlFill),
		};
	if s._badge then
		s.n.badge = FM(s, "Text", KM.text);
	end;
	return s;
end;
U1.AddInput = U1.AddTextbox;
function U1.AddColor(o, g)
	local s = GM(o, "color", g, Q1);
	g = s.o;
	s.title = g.title or (s.text ~= "" and s.text or "color");
	s.n = {
			hover = FM(s, "Square", KM.hover),
			label = FM(s, "Text", KM.text),
			swEdge = FM(s, "Square", KM.ctl),
			swRing = FM(s, "Square", KM.ctlIn),
			swFill = FM(s, "Square", KM.ctlFill),
		};
	if s._badge then
		s.n.badge = FM(s, "Text", KM.text);
	end;
	s.addons = {};
	s:_setRGB(Y(g.default or g.Default) or { 255, 255, 255 }, true);
	if g.rainbow then
		s:SetRainbow(true);
	end;
	return s;
end;
U1.AddColorPicker = U1.AddColor;
function U1.AddKeybind(o, g)
	local s = GM(o, "keybind", g, d1);
	g = s.o;
	s.mode = g.mode or "toggle";
	s.state = s.mode == "always";
	s.clicks = {};
	if g.onClick then
		s.clicks[1] = g.onClick;
	end;
	s.n = { hover = FM(s, "Square", KM.hover), label = FM(s, "Text", KM.text), key = FM(s, "Text", KM.text) };
	if s._badge then
		s.n.badge = FM(s, "Text", KM.text);
	end;
	s:_apply(S(g.default or g.key) or false);
	sM._binds[#sM._binds + 1] = s;
	return s;
end;
function U1.AddLabel(o, g)
	local s = GM(o, "label", g, C1);
	g = s.o;
	s.color = g.color;
	s.dim = g.dim;
	s.wrap = g.wrap ~= false;
	s.n = { lines = {} };
	s.addons = {};
	s:_split();
	return s;
end;
function U1.AddDivider(g)
	local o = GM(g, "divider", {}, h1);
	o.n = { line = FM(o, "Square", KM.ctl) };
	return o;
end;
function U1.SetVisible(o, g)
	g = g and true or false;
	if g ~= o.visible then
		o.visible = g;
		if not g then
			o:_hide();
		end;
		o.win._dirty = true;
	end;
	return o;
end;
function U1.SetCollapsed(o, g)
	g = g and true or false;
	if g == o.collapsed or not o.collapsible then
		return o;
	end;
	o.collapsed = g;
	if g then
		for g = 1, #o.widgets, 1 do
			o.widgets[g]:hideNodes();
		end;
	end;
	local s = o.win;
	s._dirty = true;
	sM._hoverDirty = true;
	if s.configFile then
		s._saveAt = V() + .75;
	end;
	return o;
end;
function U1.IsCollapsed(g)
	return g.collapsed;
end;
function U1.Toggle(g)
	return g:SetCollapsed(not g.collapsed);
end;
function U1._key(g)
	return g.tab.name .. ("/" .. g.title);
end;
function U1.SetTitle(o, g)
	o.title = tostring(g or "");
	o.win._dirty = true;
	return o;
end;
function U1._hide(g)
	wM(g.nodes);
	for o = 1, #g.widgets, 1 do
		g.widgets[o]:hideNodes();
	end;
end;
function U1._paintBox(card, x, y, width, bottom, clipTop, clipBottom)
    card._box = { x, y, width, bottom, clipTop, clipBottom };
    local nodes, colors = card.n, sM.C;
    local top = y - QM.half;
    local clippedTop, clippedBottom = c(top, clipTop), R(bottom, clipBottom);
    if clippedBottom > clippedTop then
        xM(nodes.edge, x, clippedTop, width, clippedBottom - clippedTop, colors.border);
        xM(nodes.fill, x + 1, c(top + 1, clipTop), width - 2,
            R(bottom - 1, clipBottom) - c(top + 1, clipTop), colors.group);
    else LM(nodes.edge); LM(nodes.fill); end;
    LM(nodes.patch); LM(nodes.mpatch); LM(nodes.line);
    local titleY = top + 10 * QM.k;
    if card.title ~= "" and titleY >= clipTop and titleY + QM.th <= clipBottom then
        local hovered = sM._hoverGroup == card;
        local mark = card.collapsible and (card.collapsed and "+" or "-") or "";
        jM(nodes.title, UM(sM.Ocean.groups[card.title] or card.title, width - QM.gpad * 2 - 20), x + QM.gpad, titleY,
            hovered and colors.accent or colors.header);
        jM(nodes.mark, mark, x + width - QM.gpad - CM(mark), titleY, colors.textDim);
        xM(nodes.dash, x, titleY, 2, QM.th, colors.accentDim);
    else LM(nodes.title); LM(nodes.mark); LM(nodes.dash); end;
end;
function U1._repaintHeader(g)
	local o = g._box;
	if o and (g.win.alive and g.win._laidOut) then
		g:_paintBox(o[1], o[2], o[3], o[4], o[5], o[6]);
	end;
end;
local t1 = {};
t1.__index = t1;
function t1.AddGroup(f, g, o, s)
	local n = f.win;
	s = type(s) == "table" and s or {};
	local c = o;
	if c == "left" or c == nil then
		c = 1;
	elseif c == "right" then
		c = n.columns;
	elseif c == "middle" or c == "center" then
		c = R(2, n.columns);
	end;
	c = P(W(tonumber(c) or 1), 1, n.columns);
	local k = setmetatable({
			win = n,
			tab = f,
			col = c,
			title = tostring(g or ""),
			widgets = {},
			nodes = {},
			visible = true,
			collapsed = s.collapsed and true or false,
			collapsible = s.collapsible ~= false,
		}, U1);
	local function E(g, o, s)
		local f = lM(n.nodes, g, o, s);
		k.nodes[#k.nodes + 1] = f;
		return f;
	end;
	k.n = {
			edge = E("Square", KM.gEdge, true),
			fill = E("Square", KM.gFill, true),
			dash = E("Square", KM.gHead),
			line = E("Square", KM.gHead),
			title = E("Text", KM.text),
			patch = E("Square", KM.gHead, true),
			mark = E("Text", KM.text),
			mpatch = E("Square", KM.gHead, true),
		};
	local Q = f.cols[c];
	Q[#Q + 1] = k;
	f.groups[#f.groups + 1] = k;
	n._dirty = true;
	return k;
end;
function t1.AddLeftGroup(o, g)
	return o:AddGroup(g, 1);
end;
function t1.AddRightGroup(o, g)
	return o:AddGroup(g, o.win.columns);
end;
t1.AddLeftGroupbox = t1.AddLeftGroup;
t1.AddRightGroupbox = t1.AddRightGroup;
t1.AddGroupbox = t1.AddGroup;
t1.AddSection = t1.AddGroup;
function t1.Select(g)
	g.win:SelectTab(g);
	return g;
end;
function t1.SetVisible(o, g)
	o.visible = g and true or false;
	o.win._dirty = true;
	return o;
end;
function t1._hide(g)
	for o = 1, #g.groups, 1 do
		g.groups[o]:_hide();
	end;
end;
local P1 = {};
P1.__index = P1;
local K1 = 32;
local function B1(g)
	return ((((tostring(g or "")):gsub("[^%w%-_ ]", "")):gsub("^%s+", "")):gsub("%s+$", ""));
end;
function P1._setZ(o, g)
	local s = o.nodes;
	if s.zoff == g then
		return;
	end;
	s.zoff = g;
	for o = 1, #s, 1 do
		local f = s[o];
		if not f.dead then
			f.d.ZIndex = f.z + g;
		end;
	end;
end;
local function l1()
	for g, o in ipairs(sM.Windows) do
		o:_setZ(((g - 1)) * BM);
	end;
end;
function sM.CreateWindow(g, o)
	local s = fM(g, o);
	s = type(s) == "table" and s or { title = s };
	local f = tostring(s.id or s.title or "ui");
	for g = #sM.Windows, 1, -1 do
		if sM.Windows[g].id == f then
			sM.Windows[g]:Destroy();
		end;
	end;
	local n = s.size or {};
	local c, k = mM();
	local E = sM.TextSize / 13;
	local Q = W(((tonumber(n[1] or n.X or s.width) or 500)) * E + .5);
	local d = W(((tonumber(n[2] or n.Y or s.height) or 560)) * E + .5);
	local T = setmetatable({
			id = f,
			title = tostring(s.title or "ui"),
			subtitle = s.subtitle and tostring(s.subtitle) or nil,
			x = tonumber(s.x) or W(((c - Q)) / 2),
			y = tonumber(s.y) or W(((k - d)) / 2),
			w = Q,
			h = d,
			minW = R(W(640 * E), Q),
			minH = R(W(380 * E), d),
			columns = P(W(tonumber(s.columns) or 2), 1, 3),
			resizable = s.resizable ~= false,
			showTabs = s.showTabs,
			visible = s.visible ~= false,
			fadeV = 0,
			alive = true,
			tabs = {},
			nodes = {},
			widgets = {},
			depWidgets = {},
			flags = {},
			flagOrder = {},
			cols = {},
			hits = {},
			ghits = {},
			sbars = {},
			toggleKey = S(s.toggleKey or s.key or "RSHIFT"),
			folder = s.folder or ("UI/" .. ((B1(f) ~= "" and B1(f) or "window"))),
			autoloadEnabled = s.autoload ~= false,
			configFile = s.config,
			inputGuard = s.inputGuard,
			captureInput = s.captureInput,
			onUnload = s.onUnload,
			_dirty = true,
		}, P1);
	T.Flags = T.flags;
	T.nodes.zoff = #sM.Windows * BM;
	local C = {};
	local function h(g, o, s)
		return lM(T.nodes, g, o, s);
	end;
	C.frame = h("Square", KM.frame, true);
	C.frameIn = h("Square", KM.frameIn, true);
	C.bg = h("Square", KM.bg, true);
	C.titleBg = h("Square", KM.chrome, true);
	C.tabBg = h("Square", KM.chrome, true);
	C.sep1 = h("Square", KM.chrome + 1);
	C.sep2 = h("Square", KM.chrome + 1);
	C.title = h("Text", KM.chromeText);
	C.subtitle = h("Text", KM.chromeText);
	C.underline = h("Square", KM.chromeText);
    C.navLabel = h("Text", KM.chromeText);
    C.pageTitle = h("Text", KM.chromeText);
    C.pageHint = h("Text", KM.chromeText);
    C.footer = h("Text", KM.chromeText);
	C.bar = {};
	for g = 1, K1, 1 do
		C.bar[g] = h("Square", KM.chromeText);
	end;
	C.grip = { h("Square", KM.sthumb), h("Square", KM.sthumb), h("Square", KM.sthumb) };
	for g = 1, T.columns, 1 do
		T.sbars[g] = {
				track = h("Square", KM.sbar),
				thumb = h("Square", KM.sthumb),
				upBg = h("Square", KM.sbar),
				up = {
					h("Square", KM.sthumb),
					h("Square", KM.sthumb),
					h("Square", KM.sthumb),
					h("Square", KM.sthumb),
				},
				dnBg = h("Square", KM.sbar),
				dn = {
					h("Square", KM.sthumb),
					h("Square", KM.sthumb),
					h("Square", KM.sthumb),
					h("Square", KM.sthumb),
				},
			};
		T.hits[g] = { n = 0 };
		T.ghits[g] = { n = 0 };
		T.cols[g] = {
				x = 0,
				y = 0,
				w = 0,
				h = 0,
			};
	end;
	T.ch = C;
	sM.Windows[#sM.Windows + 1] = T;
	sM:_wake();
	return T;
end;
function P1.AddTab(o, g)
	local s = setmetatable({
			win = o,
			name = tostring(g or ("tab " .. (#o.tabs + 1))),
			cols = {},
			scroll = {},
			target = {},
			content = {},
			maxScroll = {},
			groups = {},
			visible = true,
		}, t1);
	for g = 1, o.columns, 1 do
		s.cols[g] = {};
		s.scroll[g], s.target[g], s.content[g], s.maxScroll[g] = 0, 0, 0, 0;
	end;
	s.nText = lM(o.nodes, "Text", KM.chromeText);
    s.nBg = lM(o.nodes, "Square", KM.chrome, true);
    s.nIndex = lM(o.nodes, "Text", KM.chromeText);
	o.tabs[#o.tabs + 1] = s;
    if s.name == "Main" then
        s:AddGroup("Quick start", o.columns):AddLabel({text =
            "1. Equip your fishing tool in the game.\n2. Choose your tool type below.\n3. Turn on Auto Fish to start.\nTurn it off to stop. Click its [key] to change the shortcut.", dim = true});
    end;
	if not o.active then
		o.active = s;
	end;
	o._dirty = true;
	return s;
end;
function P1._visibleTabs(g)
	local o = {};
	for g, s in ipairs(g.tabs) do
		if s.visible then
			o[#o + 1] = s;
		end;
	end;
	return o;
end;
function P1._activeTab(g)
	local o = g.active;
	if o and o.visible then
		return o;
	end;
	for g, o in ipairs(g.tabs) do
		if o.visible then
			return o;
		end;
	end;
	return nil;
end;
function P1.SelectTab(o, g)
	local s = g;
	if type(g) == "number" then
		s = o.tabs[g];
	elseif type(g) == "string" then
		for o, f in ipairs(o.tabs) do
			if f.name == g then
				s = f;
			end;
		end;
	end;
	if s and s ~= o.active then
		o.active = s;
		if sM._drop and sM._drop.win == o then
			JM();
		end;
		o._dirty = true;
		sM._hoverDirty = true;
		if o.configFile then
			o._saveAt = V() + .75;
		end;
	end;
	return o;
end;
function P1._registerFlag(o, g)
	o.flags[g.flag] = g;
	o.flagOrder[#o.flagOrder + 1] = g;
	sM.Flags[g.flag] = g;
end;
function P1.GetValue(o, g)
	local s = o.flags[g];
	if s then
		return s:Get();
	end;
	return nil;
end;
function P1.SetValue(s, g, o)
	local f = s.flags[g];
	if f then
		f:Set(o);
	end;
	return s;
end;
function P1._changed(o, g)
	if OM.visible then
		OM.dirty = true;
	end;
	if o.configFile then
		o._saveAt = V() + .75;
	end;
	if #o.depWidgets > 0 then
		o:_depsChanged();
	end;
end;
function P1._depsChanged(g)
	if g._loading then
		g._depsDirty = true;
	else
		g:_evalDeps();
	end;
end;
function P1._evalDeps(g)
	if g._inDeps == sM._frameNo then
		g._depsDirty = true;
		return;
	end;
	g._inDeps = sM._frameNo;
	g._depsDirty = false;
	for o, s in ipairs(g.depWidgets) do
		local f = s.depends;
		local n = true;
		if type(f) == "function" then
			local g = RM(s, "depends");
			n = (s.depends == nil) or (g and true or false);
		elseif type(f) == "table" and f.kind then
			local g = f.value;
			n = ((g ~= nil and g ~= false)) and true or false;
			if f.kind == "dropdown" and f.multi then
				n = next(g) ~= nil;
			end;
		elseif type(f) == "table" then
			local g, o = f[1], f[2];
			n = g ~= nil and g.value == o;
		end;
		if n ~= s.depOk then
			s.depOk = n;
			if s.hideDisabled then
				g._dirty = true;
			else
				s:_repaint();
			end;
		end;
	end;
	g._inDeps = nil;
end;
function P1.SetTitle(s, g, o)
	s.title = tostring(g or "");
	if o ~= nil then
		s.subtitle = tostring(o);
	end;
	s._dirty = true;
	return s;
end;
function P1.IsVisible(g)
	return g.visible;
end;
function P1.SetVisible(o, g)
	g = g and true or false;
	if g == o.visible then
		return o;
	end;
	o.visible = g;
	if not g then
		if sM._drop and sM._drop.win == o then
			JM();
		end;
		if sM._pick and sM._pick.win == o then
			pM();
		end;
		if sM._focus and (sM._focus.target and sM._focus.target.win == o) then
			DM();
		end;
		if sM._listen and sM._listen.win == o then
			bM(sM._listen, nil, true);
		end;
		if sM._cap and ((sM._cap.win == o or (sM._cap.wid and sM._cap.wid.win == o))) then
			sM._cap = nil;
		end;
		if qM then
			qM();
		end;
	end;
	sM:_wake();
	return o;
end;
function P1.Show(g)
	return g:SetVisible(true);
end;
function P1.Hide(g)
	return g:SetVisible(false);
end;
function P1.Toggle(g)
	return g:SetVisible(not g.visible);
end;
function P1._contains(s, g, o)
	return s.fadeV > 0 and K(g, o, s.x, s.y, s.w, s.h);
end;
function P1._hideAll(g)
	wM(g.nodes);
	for g, o in ipairs(g.widgets) do
		o.placed = false;
	end;
	g._laidOut = false;
	g._shownTab = nil;
end;
function P1._applyAlpha(g)
	local o, s = g.fadeV, sM.Opacity;
	local f = g.nodes;
	for g = 1, #f, 1 do
		local n = f[g];
		HM(n, ((n.bg and s or 1)) * o);
	end;
end;
function P1._tabsShown(g)
	if g.showTabs ~= nil then
		return g.showTabs and true or false;
	end;
	return #g:_visibleTabs() > 1;
end;
function P1._tabLayout(f, g, o, s)
	if f._oceanSidebar then
        local index = 0;
        for _, tab in ipairs(f.tabs) do
            tab.hit = nil;
            if tab.visible then
                index = index + 1;
                tab.hit = { g + 10, o + (index - 1) * (QM.tabs + 4), s - 20, QM.tabs };
            end;
        end;
        return index * (QM.tabs + 4);
    end;
    local n, R, k = {}, {}, 0;
	for g, o in ipairs(f.tabs) do
		o.hit = nil;
		if o.visible then
			local g = CM(sM.Ocean.tabs[o.name] or o.name) + 20;
			if #R > 0 and k + g > s then
				n[#n + 1] = R;
				R, k = {}, 0;
			end;
			R[#R + 1] = o;
			o._nw = g;
			k = k + g;
		end;
	end;
	if #R > 0 then
		n[#n + 1] = R;
	end;
	for f, n in ipairs(n) do
		local R = 0;
		for g, o in ipairs(n) do
			R = R + o._nw;
		end;
		local k = c(0, s - R) / #n;
		local E = g;
		for c, R in ipairs(n) do
			local Q = W(E + .5);
			E = (E + R._nw) + k;
			local d = (c == #n) and (g + s) or W(E + .5);
			R.hit = {
					Q,
					o + ((f - 1)) * QM.tabs,
					d - Q,
					QM.tabs,
				};
		end;
	end;
	return c(1, #n) * QM.tabs;
end;
function P1._paintTabs(win)
    local colors, active = sM.C, win:_activeTab();
    win._ulY = nil;
    for index, tab in ipairs(win.tabs) do
        if not win.tabRect then tab.hit = nil; end;
        local rect = tab.hit;
        if tab.visible and rect then
            local selected, hovered = tab == active, win._tabHover == tab;
            if selected or hovered then
                xM(tab.nBg, rect[1] + 3, rect[2] + 2, rect[3] - 6, rect[4] - 4,
                    selected and colors.press or colors.hover);
            else LM(tab.nBg); end;
            local text = UM(sM.Ocean.tabs[tab.name] or tab.name,
                rect[3] - (win._oceanSidebar and 42 or 14));
            local x = win._oceanSidebar and rect[1] + 34 or rect[1] + W((rect[3] - CM(text)) / 2);
            local y = rect[2] + W((rect[4] - QM.th) / 2);
            jM(tab.nText, text, x, y, selected and colors.accent or (hovered and colors.text or colors.textDim));
            if win._oceanSidebar then
                jM(tab.nIndex, string.format("%02d", index), rect[1] + 10, y, selected and colors.accent or colors.textOff);
            else LM(tab.nIndex); end;
            if selected then
                win._ulGoalX, win._ulGoalW, win._ulY = rect[1] + 9, rect[3] - 18, rect[2] + rect[4] - 3;
            end;
        else
            LM(tab.nText); LM(tab.nBg); LM(tab.nIndex);
        end;
    end;
    if not win.tabRect or not win._ulY then LM(win.ch.underline); return; end;
    if not win._ulX or not sM.Settings.smoothScroll or win._ulYWas ~= win._ulY then
        win._ulX, win._ulW, win._ulYWas = win._ulGoalX, win._ulGoalW, win._ulY;
    end;
    xM(win.ch.underline, win._ulX, win._ulY, win._ulW, 2, colors.accent);
end;
function P1._paintBar(o, g)
	local s = o.ch.bar;
	local f, n, c = o.x + 2, o.y + 2, o.w - 4;
	local R = sM.Bar;
	if not R.rainbow then
		xM(s[1], f, n, c, 2, sM.C.accent);
		for g = 2, K1, 1 do
			LM(s[g]);
		end;
		return;
	end;
	local k = (((g * R.speed) * R.direction)) % 1;
	local E = c / K1;
	for g = 1, K1, 1 do
		local o = f + W(((g - 1)) * E);
		local c = f + W(g * E);
		local Q = ((k + (((g - 1)) / K1) * R.span)) % 1;
		xM(s[g], o, n, c - o, 2, N(Q * 360));
	end;
end;
function P1._layoutColumn(f, g, o, s)
	s = s or 0;
	local n = f.cols[o];
	local R = f.hits[o];
	local k = 0;
	local E = QM.arrowH;
	local Q = g.content[o] > n.h;
	local d, T = n.y, n.y + n.h;
	if Q then
		d, T = d + E, T - E;
	end;
	local C, h = n.x, n.w - QM.gutter;
	local U = g.scroll[o];
	local V = d - U;
	local I = g.cols[o];
	local t = sM.C;
	local P = f.ghits[o];
	local K = 0;
	for g = 1, #I, 1 do
		local o = I[g];
		if o.visible then
			local g = V + QM.half;
			local s = g + QM.gtop;
			if o.collapsible and (o.title ~= "" and (g - QM.half >= d and g + QM.gtop <= T)) then
				K = K + 1;
				local s = P[K];
				if not s then
					s = {};
					P[K] = s;
				end;
				s[1], s[2], s[3] = g - QM.half, g + QM.gtop - 2, o;
			end;
			for g = 1, (o.collapsed and 0 or #o.widgets), 1 do
				local f = o.widgets[g];
				if f:_shown() then
					f.px, f.py, f.pw = C + 1, s, h - 2;
					local g = f:height();
					if s >= d and s + g <= T then
						f.placed = true;
						f:paint();
						k = k + 1;
						local o = R[k];
						if not o then
							o = {};
							R[k] = o;
						end;
						o[1], o[2], o[3] = s, s + g, f;
					else
						f:hideNodes();
					end;
					s = s + g;
				else
					f:hideNodes();
				end;
			end;
			if o.collapsed then
				for g = 1, #o.widgets, 1 do
					o.widgets[g]:hideNodes();
				end;
			end;
			local f = o.collapsed and (g + QM.gtop + 2) or (s + QM.gbot);
			o:_paintBox(C, g, h, f, d, T);
			V = f + QM.ggap;
		else
			o:_hide();
		end;
	end;
	R.n = k;
	P.n = K;
	local B = (V - QM.ggap) - ((d - U));
	g.content[o] = B;
	if ((B > n.h)) ~= Q and s < 2 then
		return f:_layoutColumn(g, o, s + 1);
	end;
	local l = T - d;
	local L = c(0, B - l);
	g.maxScroll[o] = L;
	if g.target[o] > L then
		g.target[o] = L;
	end;
	if U > L and s < 2 then
		g.scroll[o] = L;
		return f:_layoutColumn(g, o, s + 1);
	end;
	n.vt, n.vb = d, T;
	local x = f.sbars[o];
	if L > 0 then
		local g = (n.x + n.w) - QM.sbw;
		xM(x.track, g, d, QM.sbw, l, t.track);
		local s = c(18, W((l * l) / B));
		local R = d + W(((l - s)) * ((U / L)) + .5);
		local k = (sM._cap and (sM._cap.kind == "sbar" and (sM._cap.win == f and sM._cap.c == o)));
		xM(x.thumb, g, R, QM.sbw, s, k and t.text or t.accent);
		n.sb = {
				g - 3,
				d,
				QM.sbw + 6,
				l,
				s,
			};
	else
		LM(x.track);
		LM(x.thumb);
		n.sb = nil;
	end;
	if Q then
		n.upR = {
				n.x,
				n.y,
				n.w,
				E - 1,
			};
		n.dnR = {
				n.x,
				T + 1,
				n.w,
				E - 1,
			};
	else
		n.upR, n.dnR = nil, nil;
	end;
	f:_paintArrows(o);
end;
function P1._paintArrows(o, g)
	local s, f = o.cols[g], o.sbars[g];
	if not s.upR then
		vM.hide(f.upBg, f.up);
		vM.hide(f.dnBg, f.dn);
		return;
	end;
	local n = o:_activeTab();
	local W, c = n.scroll[g], n.maxScroll[g];
	local R, k = s.upR, s.dnR;
	vM.paint(f.upBg, f.up, R[1], R[2], R[3], R[4], true, vM.state("col", o, g, -1, W > .5));
	vM.paint(f.dnBg, f.dn, k[1], k[2], k[3], k[4], false, vM.state("col", o, g, 1, W < c - .5));
end;
function P1._layout(g)
	local o = sM.C;
	local s = g.ch;
	local f, n = mM();
	g.w = P(g.w, g.minW, c(g.minW, f));
	g.h = P(g.h, g.minH, c(g.minH, n));
	g.x = P(g.x, 40 - g.w, f - 40);
	g.y = P(g.y, 0, n - 20);
    local R, k, E, Q = g.x, g.y, g.w, g.h;
    xM(s.frame, R, k, E, Q, o.border);
    xM(s.frameIn, R + 1, k + 1, E - 2, Q - 2, o.bg);
    xM(s.bg, R + 2, k + 2, E - 4, Q - 4, o.bg);
    g:_paintBar(sM._now or V());
    local d = k + 4;
    xM(s.titleBg, R + 2, d, E - 4, QM.title, o.topbar);
    local T = d + W((QM.title - QM.th) / 2);
    jM(s.title, UM(g.title, E * .5), R + QM.pad, T, o.text);
    local menuKey = g.flags.__menukey;
    local hint = (g.subtitle or "OCEAN") .. "    /    " .. tostring(menuKey and menuKey.value or g.toggleKey or "P") .. "  hide menu";
    hint = UM(hint, E * .48);
    jM(s.subtitle, hint, R + E - QM.pad - CM(hint), T, o.textDim);
    g.titleRect = { R, k, E, QM.title + 4 };
    local contentY = d + QM.title + 1;
    xM(s.sep1, R + 2, contentY - 1, E - 4, 1, o.border);
    local I = g.columns;
    local t = R + 2 + QM.pad;
    local K = E - 4 - QM.pad * 2;
    local visibleCount = #g:_visibleTabs();
    g._oceanSidebar = g:_tabsShown() and E >= 800 * QM.k
        and Q >= QM.title + 88 * QM.k + visibleCount * (QM.tabs + 4);
    if g:_tabsShown() then
        if g._oceanSidebar then
            local navW = W(174 * QM.k);
            xM(s.tabBg, R + 2, contentY, navW, Q - QM.title - 6, o.topbar);
            jM(s.navLabel, "NAVIGATION", R + QM.pad, contentY + 16 * QM.k, o.textOff);
            local navY = contentY + 44 * QM.k;
            local navH = g:_tabLayout(R + 2, navY, navW);
            g.tabRect = { R + 2, navY, navW, navH };
            xM(s.sep2, R + navW + 2, contentY, 1, Q - QM.title - 6, o.border);
            t = t + navW;
            K = K - navW;
        else
            LM(s.navLabel);
            local tabH = g:_tabLayout(R + 2, contentY, E - 4);
            xM(s.tabBg, R + 2, contentY, E - 4, tabH, o.topbar);
            g.tabRect = { R + 2, contentY, E - 4, tabH };
            contentY = contentY + tabH + 1;
            xM(s.sep2, R + 2, contentY - 1, E - 4, 1, o.border);
        end;
    else
        LM(s.tabBg); LM(s.navLabel); LM(s.sep2); g.tabRect = nil;
    end;
    g:_paintTabs();
    local active = g:_activeTab();
    local pageName = active and active.name or "Overview";
    jM(s.pageTitle, sM.Ocean.tabs[pageName] or pageName, t, contentY + QM.pad, o.accent);
    jM(s.pageHint, UM(sM.Ocean.descriptions[pageName] or "Choose a setting below.", K),
        t, contentY + QM.pad + QM.th + 7, o.textDim);
    local footerY = k + Q - QM.th - 12;
    jM(s.footer, UM("Hover over a setting for help.   1000 ms = 1 second.   Drag the title to move.", K),
        t, footerY, o.textOff);
    local h = contentY + QM.pad + QM.th * 2 + 24;
    local U = footerY - 16;
	local B = W(((K - ((I - 1)) * QM.colGap)) / I);
	for o = 1, I, 1 do
		local s = g.cols[o];
		s.x = t + ((o - 1)) * ((B + QM.colGap));
		s.y = h;
		s.w = (o == I) and ((t + K) - s.x) or B;
		s.h = c(1, U - h);
	end;
	local l = g:_activeTab();
	if g._shownTab ~= l then
		if g._shownTab then
			g._shownTab:_hide();
		end;
		g._shownTab = l;
	end;
	if g._depsDirty then
		g:_evalDeps();
	end;
	if l then
		for o = 1, I, 1 do
			g:_layoutColumn(l, o);
		end;
	end;
	for o = I + 1, #g.sbars, 1 do
		LM(g.sbars[o].track);
		LM(g.sbars[o].thumb);
	end;
	if g.resizable then
		local f, n = (R + E) - 4, (k + Q) - 4;
		xM(s.grip[1], f - 2, n - 2, 2, 2, o.outline);
		xM(s.grip[2], f - 5, n - 2, 2, 2, o.outline);
		xM(s.grip[3], f - 2, n - 5, 2, 2, o.outline);
		g.gripRect = {
				(R + E) - 12,
				(k + Q) - 12,
				12,
				12,
			};
	else
		g.gripRect = nil;
	end;
	g._dirty = false;
	g._laidOut = true;
	if sM._drop and sM._drop.win == g then
		if sM._drop.placed then
			MM();
		else
			JM();
		end;
	end;
	if sM._pick and sM._pick.win == g then
		aM();
	end;
end;
function P1._rowAt(s, g, o)
	local f = s.hits[g];
	for g = 1, f.n, 1 do
		local s = f[g];
		if o >= s[1] and o < s[2] then
			return s[3];
		end;
	end;
	return nil;
end;
function P1._groupAt(s, g, o)
	local f = s.ghits[g];
	for g = 1, f.n or 0, 1 do
		local s = f[g];
		if o >= s[1] and o < s[2] then
			return s[3];
		end;
	end;
	return nil;
end;
function P1._colAt(s, g, o)
	for f = 1, s.columns, 1 do
		local n = s.cols[f];
		if K(g, o, n.x, n.y, n.w, n.h) then
			return f, n;
		end;
	end;
	return nil;
end;
function P1._scrollBy(s, g, o)
	local f = s:_activeTab();
	if not f then
		return;
	end;
	f.target[g] = P(f.target[g] + o, 0, f.maxScroll[g]);
end;
function P1._frame(s, g, o)
	if not s._booted then
		s._booted = true;
		s:_boot();
	end;
	local f = s.visible and 1 or 0;
	if s.fadeV ~= f then
		if sM.Settings.fade then
			local g = o / .12;
			if f > s.fadeV then
				s.fadeV = R(f, s.fadeV + c(g, .05));
			else
				s.fadeV = c(f, s.fadeV - c(g, .05));
			end;
		else
			s.fadeV = f;
		end;
		if s.fadeV <= 0 then
			s:_hideAll();
			return;
		end;
		if s._dirty or not s._laidOut then
			s:_layout();
		end;
		s:_applyAlpha();
	end;
	if s.fadeV <= 0 then
		return;
	end;
	local n = s:_activeTab();
	if n then
		for g = 1, s.columns, 1 do
			local f, W = n.scroll[g], n.target[g];
			if f ~= W then
				local c = W;
				if sM.Settings.smoothScroll then
					c = f + ((W - f)) * R(1, o * 16);
					if k(W - c) < .5 then
						c = W;
					end;
				end;
				n.scroll[g] = c;
				if sM._drop and sM._drop.win == s then
					JM();
				end;
				if not s._dirty then
					s:_layoutColumn(n, g);
				end;
				sM._hoverDirty = true;
			end;
		end;
	end;
	if #s.depWidgets > 0 and ((s._depsDirty or g >= ((s._depsAt or 0)))) then
		s._depsAt = g + .25;
		s:_evalDeps();
	end;
	if s._ulX and (s._ulGoalX and ((s._ulX ~= s._ulGoalX or s._ulW ~= s._ulGoalW))) then
		local g = R(1, o * 18);
		s._ulX = s._ulX + ((s._ulGoalX - s._ulX)) * g;
		s._ulW = s._ulW + ((s._ulGoalW - s._ulW)) * g;
		if k(s._ulX - s._ulGoalX) < .5 and k(s._ulW - s._ulGoalW) < .5 then
			s._ulX, s._ulW = s._ulGoalX, s._ulGoalW;
		end;
		if s.tabRect and (s._ulY and not s._dirty) then
			xM(s.ch.underline, s._ulX, s._ulY, s._ulW, 2, sM.C.accent);
		end;
	end;
	if s._dirty then
		s:_layout();
	end;
end;
function P1._boot(g)
	if not g._settingsLoaded then
		g:LoadSettings();
	end;
	if g.autoloadEnabled then
		local o = g:GetAutoload();
		if o then
			g:LoadConfig(o);
		end;
	end;
end;
function P1.Unload(g)
	if g._unloading then
		return;
	end;
	g._unloading = true;
	WM(g.onUnload, g);
	g:Destroy();
	if #sM.Windows == 0 and not sM._dead then
		sM:Unload();
	end;
end;
function P1.Destroy(g)
	if not g.alive then
		return;
	end;
	g.alive = false;
	g.visible = false;
	for o = #sM.Windows, 1, -1 do
		if sM.Windows[o] == g then
			U(sM.Windows, o);
		end;
	end;
	l1();
	if sM._drop and sM._drop.win == g then
		JM();
	end;
	if sM._pick and sM._pick.win == g then
		pM();
	end;
	if sM._focus and (sM._focus.target and sM._focus.target.win == g) then
		sM._focus = nil;
	end;
	if sM._listen and sM._listen.win == g then
		sM._listen = nil;
	end;
	if sM._hover and sM._hover.win == g then
		sM._hover = nil;
	end;
	if sM._arrow and sM._arrow.win == g then
		sM._arrow = nil;
	end;
	if sM._cap and ((sM._cap.win == g or (sM._cap.wid and sM._cap.wid.win == g))) then
		sM._cap = nil;
	end;
	if qM then
		qM();
	end;
	for o = #sM._binds, 1, -1 do
		if sM._binds[o].win == g then
			U(sM._binds, o);
		end;
	end;
	for o in pairs(sM._rainbow) do
		if o.win == g then
			sM._rainbow[o] = nil;
		end;
	end;
	for o in pairs(sM._pending) do
		if o.win == g then
			sM._pending[o] = nil;
		end;
	end;
	for o, s in pairs(sM.Flags) do
		if s.win == g then
			sM.Flags[o] = nil;
		end;
	end;
	for g, o in ipairs(g.widgets) do
		o.placed = false;
	end;
	local o = g.nodes;
	g.nodes = { dead = true };
	NM(o);
	if OM.visible then
		OM.dirty = true;
	end;
	if sM._hoverGroup and sM._hoverGroup.win == g then
		sM._hoverGroup = nil;
	end;
	if g._saveAt then
		g:SaveSettings();
	end;
end;
mM = function()
		local g = V();
		if not sM._vpAt or g - sM._vpAt > 1 then
			sM._vpAt = g;
			local o = workspace and workspace.CurrentCamera;
			local s = o and o.ViewportSize;
			local f, n = s and s.X, s and s.Y;
			if type(f) == "number" and (type(n) == "number" and f > 0) then
				sM._vpW, sM._vpH = f, n;
			end;
		end;
		return sM._vpW or 1920, sM._vpH or 1080;
	end;
local L1 = {
		rows = {},
		cap = 12,
		searchAt = 8,
		first = 1,
		list = {},
		query = "",
		was = {},
		ah = 0,
		hh = 0,
	};
function L1.filter(g)
	local o = L1.list;
	for g = #o, 1, -1 do
		o[g] = nil;
	end;
	local s = L1.query:lower();
	for f = 1, #g.values, 1 do
		local n = g.values[f];
		if s == "" or (n:lower()):find(s, 1, true) then
			o[#o + 1] = n;
		end;
	end;
	return o;
end;
local function x1()
	if L1.edge then
		return;
	end;
	local g = sM._ov;
	L1.edge = lM(g, "Square", KM.pop);
	L1.bg = lM(g, "Square", KM.popIn);
	for o = 1, L1.cap, 1 do
		L1.rows[o] = { hover = lM(g, "Square", KM.popBg), mark = lM(g, "Square", KM.popCtl), text = lM(g, "Text", KM.popText) };
	end;
	L1.thumb = lM(g, "Square", KM.popFill);
	L1.headBg = lM(g, "Square", KM.popBg);
	L1.head = lM(g, "Text", KM.popText);
	L1.upBg, L1.dnBg = lM(g, "Square", KM.popBg), lM(g, "Square", KM.popBg);
	L1.up, L1.dn = {}, {};
	for o = 1, 4, 1 do
		L1.up[o] = lM(g, "Square", KM.popText);
		L1.dn[o] = lM(g, "Square", KM.popText);
	end;
end;
local function j1(g)
	g(L1.edge);
	g(L1.bg);
	g(L1.thumb);
	g(L1.headBg);
	g(L1.head);
	g(L1.upBg);
	g(L1.dnBg);
	for o = 1, 4, 1 do
		g(L1.up[o]);
		g(L1.dn[o]);
	end;
	for o = 1, L1.cap, 1 do
		local s = L1.rows[o];
		g(s.hover);
		g(s.mark);
		g(s.text);
	end;
end;
MM = function()
		local g = sM._drop;
		if not g or not L1.edge then
			return;
		end;
		local o = sM.C;
		local s = CM("type to search");
		for o = 1, #g.values, 1 do
			s = c(s, CM(g.values[o]));
		end;
		local f = L1.filter(g);
		local n = g.multi and (QM.cb + 6) or 0;
		local k = P(((s + QM.gpad * 2) + n) + 6, 90, c(90, g.pw - QM.gpad * 2));
		local E = QM.R;
		local Q = L1.search and E or 0;
		local d = QM.arrowH;
		local T = #g.values;
		local C, h = mM();
		local function U(g)
			local o = R(T, L1.cap);
			local s = T > o;
			while o > 1 and ((o * E + 2) + Q) + ((s and d * 2 or 0)) > g do
				o = o - 1;
				s = true;
			end;
			o = c(1, o);
			return o, T > o;
		end;
		local V = (h - 4) - ((g.py + QM.R));
		local I, t = U(V);
		local K = g.py + QM.R;
		if I < R(T, L1.cap) and g.py - 4 > V then
			I, t = U(g.py - 4);
			K = g.py - ((((I * E + 2) + Q) + ((t and d * 2 or 0))));
		end;
		local B = t and d or 0;
		local l = ((I * E + 2) + Q) + B * 2;
		local L = ((g.px + g.pw) - QM.gpad) - k;
		L1.x, L1.y, L1.w, L1.h, L1.n, L1.rh, L1.hh, L1.ah = L, K, k, l, I, E, Q, B;
		xM(L1.edge, L, K, k, l, o.outlineHi);
		xM(L1.bg, L + 1, K + 1, k - 2, l - 2, o.group);
		if L1.search then
			xM(L1.headBg, L + 1, K + 1, k - 2, E, o.control);
			local g = L1.query;
			jM(L1.head, UM(g == "" and "type to search" or ("search: " .. g), k - QM.gpad * 2), L + QM.gpad, (K + 1) + QM.ty, g == "" and o.textOff or o.accent);
		else
			LM(L1.headBg);
			LM(L1.head);
		end;
		local x = ((K + 1) + Q) + B;
		local j = #f;
		L1.first = P(L1.first, 1, c(1, (j - I) + 1));
		if t then
			L1.upR = {
					L + 1,
					(K + 1) + Q,
					k - 2,
					B - 1,
				};
			L1.dnR = {
					L + 1,
					x + I * E,
					k - 2,
					B - 1,
				};
			local g, o = L1.upR, L1.dnR;
			vM.paint(L1.upBg, L1.up, g[1], g[2], g[3], g[4], true, vM.state("drop", nil, nil, -1, L1.first > 1));
			vM.paint(L1.dnBg, L1.dn, o[1], o[2], o[3], o[4], false, vM.state("drop", nil, nil, 1, (L1.first + I) - 1 < j));
		else
			L1.upR, L1.dnR = nil, nil;
			vM.hide(L1.upBg, L1.up);
			vM.hide(L1.dnBg, L1.dn);
		end;
		local H = j > I;
		local Y = ((k - QM.gpad * 2) - n) - ((H and 6 or 0));
		for s = 1, L1.cap, 1 do
			local c = L1.rows[s];
			local R = (L1.first + s) - 1;
			if s <= I and R <= j then
				local Q = x + ((s - 1)) * E;
				local d = f[R];
				local T = g:_isSelected(d);
				if L1.hover == s then
					xM(c.hover, L + 1, Q, (k - 2) - ((H and 5 or 0)), E, o.hover);
				else
					LM(c.hover);
				end;
				local C = L + QM.gpad;
				if g.multi then
					local g = QM.cb - 2;
					xM(c.mark, C, Q + W(((E - g)) / 2), g, g, T and o.accent or o.outline);
					C = C + n;
				else
					LM(c.mark);
				end;
				jM(c.text, UM(d, Y), C, Q + QM.ty, T and o.accent or o.text);
			else
				LM(c.hover);
				LM(c.mark);
				LM(c.text);
			end;
		end;
		if H then
			local g = I * E;
			local s = c(10, W((g * I) / j));
			local f = x + W((((g - s)) * ((L1.first - 1))) / ((j - I)) + .5);
			xM(L1.thumb, (L + k) - 5, f, 2, s, o.accent);
		else
			LM(L1.thumb);
		end;
	end;
XM = function(g)
		if sM._drop then
			JM();
		end;
		x1();
		sM._drop = g;
		L1.hover = nil;
		L1.first = 1;
		L1.query = "";
		L1.search = #g.values > L1.searchAt or g.o.search == true;
		if L1.search then
			for g, o in ipairs(a) do
				L1.was[o[1]] = O(o[1]);
			end;
		end;
		if not g.multi then
			for o = 1, #g.values, 1 do
				if g.values[o] == g.value then
					L1.first = o - W(L1.cap / 2);
				end;
			end;
		end;
		MM();
		if g.placed then
			g:paint();
		end;
		sM:_wake();
	end;
JM = function()
		local g = sM._drop;
		sM._drop = nil;
		if sM._arrow and sM._arrow.kind == "drop" then
			sM._arrow = nil;
		end;
		if L1.edge then
			j1(LM);
		end;
		if g and g.placed then
			g:paint();
		end;
	end;
local function H1(g, o)
	return sM._drop and (L1.x and K(g, o, L1.x, L1.y, L1.w, L1.h));
end;
local function Y1(g)
	local o = ((L1.y + 1) + L1.hh) + L1.ah;
	if g < o then
		return nil;
	end;
	local s = W(((g - o)) / L1.rh) + 1;
	if s >= 1 and s <= L1.n then
		return s;
	end;
	return nil;
end;
local function w1(g)
	local o = L1.first;
	L1.first = L1.first + g;
	MM();
	return L1.first ~= o;
end;
local N1 = {};
local v1, X1 = 24, 36;
local J1;
local function M1()
	if N1.frame then
		return;
	end;
	local g = sM._ov;
	local function o(o)
		return lM(g, "Square", o);
	end;
	local function s(o)
		return lM(g, "Text", o);
	end;
	N1.all = {};
	N1.frame = o(KM.pop);
	N1.frameIn = o(KM.popIn);
	N1.bg = o(KM.popBg);
	N1.bar = o(KM.popCtl);
	N1.title = s(KM.popText);
	N1.svEdge = o(KM.popCtl);
	N1.svBase = o(KM.popCtlIn);
	N1.svW, N1.svB = {}, {};
	for g = 1, v1, 1 do
		N1.svW[g] = o(KM.popFill);
		HM(N1.svW[g], 1 - ((g - .5)) / v1);
	end;
	for g = 1, v1, 1 do
		N1.svB[g] = o(KM.popOver);
		HM(N1.svB[g], ((g - .5)) / v1);
	end;
	N1.svCur = o(KM.popOver2);
	N1.svCurIn = o(KM.popText);
	N1.hueEdge = o(KM.popCtl);
	N1.hue = {};
	J1 = {};
	for g = 1, X1, 1 do
		N1.hue[g] = o(KM.popCtlIn);
		J1[g] = l(L(((g - .5)) / X1, 1, 1));
	end;
	N1.hueCur = o(KM.popFill);
	N1.hueCurIn = o(KM.popOver);
	N1.prevEdge = o(KM.popCtl);
	N1.prevFill = o(KM.popCtlIn);
	N1.rgbBox = o(KM.popCtl);
	N1.rgbIn = o(KM.popCtlIn);
	N1.rgbFill = o(KM.popFill);
	N1.rgbText = s(KM.popText);
	N1.doneEdge = o(KM.popCtl);
	N1.doneIn = o(KM.popCtlIn);
	N1.doneText = s(KM.popText);
	N1.hexLabel = s(KM.popText);
	N1.hexEdge = o(KM.popCtl);
	N1.hexIn = o(KM.popCtlIn);
	N1.hexText = s(KM.popText);
	N1.hexCaret = o(KM.popTop);
	N1.recLabel = s(KM.popText);
	N1.rec = {};
	for g = 1, 6, 1 do
		N1.rec[g] = { edge = o(KM.popCtl), fill = o(KM.popCtlIn) };
	end;
end;
local function S1(g)
	for o, s in ipairs({
		"frame",
		"frameIn",
		"bg",
		"bar",
		"title",
		"svEdge",
		"svBase",
		"svCur",
		"svCurIn",
		"hueEdge",
		"hueCur",
		"hueCurIn",
		"prevEdge",
		"prevFill",
		"rgbBox",
		"rgbIn",
		"rgbFill",
		"rgbText",
		"doneEdge",
		"doneIn",
		"doneText",
		"hexLabel",
		"hexEdge",
		"hexIn",
		"hexText",
		"hexCaret",
		"recLabel",
	}) do
		g(N1[s]);
	end;
	for o = 1, v1, 1 do
		g(N1.svW[o]);
		g(N1.svB[o]);
	end;
	for o = 1, X1, 1 do
		g(N1.hue[o]);
	end;
	for o = 1, 6, 1 do
		g(N1.rec[o].edge);
		g(N1.rec[o].fill);
	end;
end;
local function p1()
	local g = N1.g or {};
	N1.g = g;
	g.pad = 8;
	g.svW = c(150, W(QM.cw * 19));
	g.svH = W(g.svW * .75);
	g.hueW = 12;
	g.W = ((g.pad * 2 + g.svW) + 6) + g.hueW;
	g.svY = QM.R + 4;
	g.r2 = (g.svY + g.svH) + 6;
	g.r3 = (g.r2 + QM.R) + 4;
	g.r4 = (g.r3 + QM.R) + 4;
	g.H = ((g.r4 + QM.R) + g.pad) - 2;
	return g;
end;
aM = function()
		local g = sM._pick;
		if not g or not N1.frame then
			return;
		end;
		local o = sM.C;
		local s = p1();
		local f, n = N1.x, N1.y;
		local c, R, k = s.W, s.H, s.pad;
		xM(N1.frame, f, n, c, R, o.border);
		xM(N1.frameIn, f + 1, n + 1, c - 2, R - 2, o.frameIn);
		xM(N1.bg, f + 2, n + 2, c - 4, R - 4, o.group);
		xM(N1.bar, f + 2, n + 2, c - 4, 2, o.accent);
		jM(N1.title, UM(g.title .. " color", c - k * 2), f + k, (n + 4) + W(((QM.R - QM.th)) / 2), o.text);
		local E, d, T, C = f + k, n + s.svY, s.svW, s.svH;
		xM(N1.svEdge, E - 1, d - 1, T + 2, C + 2, o.outline);
		if N1.baseHue ~= g.h or not N1.baseC then
			N1.baseHue = g.h;
			N1.baseC = l(L(g.h, 1, 1));
		end;
		xM(N1.svBase, E, d, T, C, N1.baseC);
		for g = 1, v1, 1 do
			local s, f = E + W((((g - 1)) * T) / v1), E + W((g * T) / v1);
			xM(N1.svW[g], s, d, f - s, C, o.white);
			local n, c = d + W((((g - 1)) * C) / v1), d + W((g * C) / v1);
			xM(N1.svB[g], E, n, T, c - n, o.black);
		end;
		local h, U = E + g.s * T, d + ((1 - g.v)) * C;
		xM(N1.svCur, h - 3, U - 3, 7, 7, o.white);
		xM(N1.svCurIn, h - 2, U - 2, 5, 5, g.value);
		s.sv = {
				E,
				d,
				T,
				C,
			};
		local V = (E + T) + 6;
		xM(N1.hueEdge, V - 1, d - 1, s.hueW + 2, C + 2, o.outline);
		for g = 1, X1, 1 do
			local o, f = d + W((((g - 1)) * C) / X1), d + W((g * C) / X1);
			xM(N1.hue[g], V, o, s.hueW, f - o, J1[g]);
		end;
		local I = d + g.h * C;
		xM(N1.hueCur, V - 2, I - 2, s.hueW + 4, 4, o.white);
		xM(N1.hueCurIn, V - 1, I - 1, s.hueW + 2, 2, o.black);
		s.hue = {
				V - 2,
				d - 2,
				s.hueW + 4,
				C + 4,
			};
		local t = n + s.r2;
		local P = W(s.svW * .38);
		xM(N1.prevEdge, f + k, t, P, QM.R, o.outline);
		xM(N1.prevFill, (f + k) + 1, t + 1, P - 2, QM.R - 2, g.value);
		local K, B = ((f + k) + P) + 8, t + W(((QM.R - QM.cb)) / 2);
		xM(N1.rgbBox, K, B, QM.cb, QM.cb, o.outline);
		xM(N1.rgbIn, K + 1, B + 1, QM.cb - 2, QM.cb - 2, o.control);
		if g.rainbow then
			xM(N1.rgbFill, K + 2, B + 2, QM.cb - 4, QM.cb - 4, o.accent);
		else
			LM(N1.rgbFill);
		end;
		jM(N1.rgbText, "rgb", (K + QM.cb) + 5, t + QM.ty, o.text);
		s.rgb = {
				K - 2,
				t,
				((QM.cb + 5) + CM("rgb")) + 4,
				QM.R,
			};
		local x = CM("done") + 16;
		local j = ((f + c) - k) - x;
		local H = N1.hot == "done";
		xM(N1.doneEdge, j, t, x, QM.R, H and o.text or o.outlineHi);
		xM(N1.doneIn, j + 1, t + 1, x - 2, QM.R - 2, H and o.controlHi or o.control);
		jM(N1.doneText, "done", j + 8, t + QM.ty, o.text);
		s.done = {
				j,
				t,
				x,
				QM.R,
			};
		local Y = n + s.r3;
		local w = ((f + k) + CM("recent")) + 8;
		local N = ((f + c) - k) - w;
		jM(N1.hexLabel, "hex", f + k, Y + QM.ty, o.textDim);
		local v = sM._focus;
		local X = v and v.target == N1;
		xM(N1.hexEdge, w, Y, N, QM.R, X and o.accent or o.outline);
		xM(N1.hexIn, w + 1, Y + 1, N - 2, QM.R - 2, o.control);
		local J = X and v.buf or g:GetHex();
		jM(N1.hexText, J, w + 5, Y + QM.ty, o.text);
		if X and v.caretOn then
			xM(N1.hexCaret, (w + 5) + W(TM(Q(v.buf, 1, v.caret)) + .5), Y + QM.ty, 1, QM.th, o.text);
		else
			LM(N1.hexCaret);
		end;
		s.hex = {
				w,
				Y,
				N,
				QM.R,
			};
		local M = n + s.r4;
		jM(N1.recLabel, "recent", f + k, M + QM.ty, o.textDim);
		local S = QM.cb + 3;
		s.rec = {};
		for g = 1, 6, 1 do
			local f = sM._recent[g];
			local n = w + ((g - 1)) * ((S + 4));
			if f then
				xM(N1.rec[g].edge, n, M + W(((QM.R - S)) / 2), S, S, o.outline);
				if not f.c3 then
					f.c3 = l(f);
				end;
				xM(N1.rec[g].fill, n + 1, (M + W(((QM.R - S)) / 2)) + 1, S - 2, S - 2, f.c3);
				s.rec[g] = {
						n,
						M,
						S,
						QM.R,
					};
			else
				LM(N1.rec[g].edge);
				LM(N1.rec[g].fill);
			end;
		end;
	end;
local function a1(g)
	local o, s, f = t(g[1]), t(g[2]), t(g[3]);
	for g = #sM._recent, 1, -1 do
		local n = sM._recent[g];
		if n[1] == o and (n[2] == s and n[3] == f) then
			U(sM._recent, g);
		end;
	end;
	table.insert(sM._recent, 1, { o, s, f });
	while #sM._recent > 6 do
		U(sM._recent);
	end;
end;
SM = function(g)
		if sM._pick then
			pM();
		end;
		M1();
		sM._pick = g;
		N1.start = { t(g.rgb[1]), t(g.rgb[2]), t(g.rgb[3]) };
		local o = p1();
		local s = g.win;
		local f, n = mM();
		local W = (s.x + s.w) + 6;
		if W + o.W > f - 4 then
			W = (s.x - o.W) - 6;
		end;
		if W < 4 then
			W = P((g.px + g.pw) - o.W, 4, (f - o.W) - 4);
		end;
		N1.x = W;
		N1.y = P(g.py - 8, 4, c(4, (n - o.H) - 4));
		N1.hot = nil;
		aM();
		g:_repaint();
		sM:_wake();
	end;
pM = function()
		local g = sM._pick;
		if not g then
			return;
		end;
		if sM._focus and sM._focus.target == N1 then
			DM();
		end;
		sM._pick = nil;
		local o = N1.start;
		if o and ((t(g.rgb[1]) ~= o[1] or t(g.rgb[2]) ~= o[2] or t(g.rgb[3]) ~= o[3])) then
			a1(g.rgb);
		end;
		if g._pending then
			g:_fire();
			sM._pending[g] = nil;
		end;
		S1(LM);
		g:_repaint();
	end;
local function u1(g, o)
	return sM._pick and (N1.x and (N1.g and K(g, o, N1.x, N1.y, N1.g.W, N1.g.H)));
end;
local function D1(g, o, s)
	local f, n = sM._pick, N1.g;
	if not f then
		return;
	end;
	if g == "sv" then
		local g = n.sv;
		f:_setHSV(f.h, P(((o - g[1])) / g[3], 0, 1), 1 - P(((s - g[2])) / g[4], 0, 1), true);
	else
		local g = n.sv;
		f:_setHSV(P(((s - g[2])) / g[4], 0, .9999), f.s, f.v, true);
	end;
	f:_fireSoon();
end;
local function e1(g, o)
	local s, f = sM._pick, N1.g;
	if K(g, o, f.sv[1], f.sv[2], f.sv[3], f.sv[4]) then
		if s.rainbow then
			s:SetRainbow(false);
		end;
		sM._cap = { kind = "sv", win = s.win };
		D1("sv", g, o);
	elseif K(g, o, f.hue[1], f.hue[2], f.hue[3], f.hue[4]) then
		if s.rainbow then
			s:SetRainbow(false);
		end;
		sM._cap = { kind = "hue", win = s.win };
		D1("hue", g, o);
	elseif K(g, o, f.rgb[1], f.rgb[2], f.rgb[3], f.rgb[4]) then
		s:SetRainbow(not s.rainbow);
	elseif K(g, o, f.done[1], f.done[2], f.done[3], f.done[4]) then
		pM();
	elseif K(g, o, f.hex[1], f.hex[2], f.hex[3], f.hex[4]) then
		uM({
			target = N1,
			buf = s:GetHex(),
			caret = #s:GetHex(),
			maxLength = 7,
			commit = function(g)
				local o = H(g);
				if o and sM._pick == s then
					if s.rainbow then
						s:SetRainbow(false);
					end;
					s:_setRGB(o);
				end;
			end,
			refresh = function()
				aM();
			end,
		});
	else
		for n = 1, 6, 1 do
			local W = f.rec[n];
			if W and (K(g, o, W[1], W[2], W[3], W[4]) and sM._recent[n]) then
				if s.rainbow then
					s:SetRainbow(false);
				end;
				s:_setRGB(sM._recent[n]);
				return;
			end;
		end;
	end;
end;
local i1 = { lines = {} };
local function b1()
	if i1.edge then
		return;
	end;
	local g = sM._ov;
	i1.edge = lM(g, "Square", KM.tip);
	i1.bg = lM(g, "Square", KM.tipIn);
	i1.title = lM(g, "Text", KM.tipText);
	for o = 1, 6, 1 do
		i1.lines[o] = lM(g, "Text", KM.tipText);
	end;
end;
local function q1(g, o, s)
	b1();
	local f = sM.C;
	local n = g._tipLines or {};
	local W = g._tipTitle;
	local k = W and CM(W) or 0;
	for g = 1, R(#n, 6), 1 do
		k = c(k, CM(n[g]));
	end;
	local E = QM.th + 3;
	local Q = (((W and E or 0)) + R(#n, 6) * E) + 8;
	local d = k + 14;
	local T, C = mM();
	local h = P(o + 14, 4, (T - d) - 4);
	local U = s + 18;
	if U + Q > C - 4 then
		U = (s - Q) - 6;
	end;
	local V = g._badge and ZM(g) or f.accent;
	xM(i1.edge, h, U, d, Q, V);
	xM(i1.bg, h + 1, U + 1, d - 2, Q - 2, f.group);
	local I = U + 4;
	if W then
		jM(i1.title, W, h + 7, I, V);
		I = I + E;
	else
		LM(i1.title);
	end;
	for g = 1, 6, 1 do
		if g <= #n then
			jM(i1.lines[g], n[g], h + 7, I, f.text);
			I = I + E;
		else
			LM(i1.lines[g]);
		end;
	end;
	i1.shown = g;
end;
qM = function()
		if i1.shown and i1.edge then
			LM(i1.edge);
			LM(i1.bg);
			LM(i1.title);
			for g = 1, 6, 1 do
				LM(i1.lines[g]);
			end;
		end;
		i1.shown = nil;
	end;
local O1 = 6;
local m1 = { pool = {}, active = {} };
local function r1()
	local g = sM._ov;
	local o = {
			edge = lM(g, "Square", KM.toast),
			bg = lM(g, "Square", KM.toastIn),
			bar = lM(g, "Square", KM.toastFill),
			prog = lM(g, "Square", KM.toastFill),
			lines = {},
		};
	for s = 1, 3, 1 do
		o.lines[s] = lM(g, "Text", KM.toastText);
	end;
	o.all = {
			o.edge,
			o.bg,
			o.bar,
			o.prog,
			o.lines[1],
			o.lines[2],
			o.lines[3],
		};
	return o;
end;
function sM.Notify(g, o, s, f)
	local n, W, c, R;
	if g == sM then
		n, W, c = o, s, f;
	else
		n, W, c = g, o, s;
	end;
	if type(n) == "table" then
		W = n.duration or n.time or W;
		c = n.color or c;
		R = n.key;
		n = ((n.title and (tostring(n.title) .. "\n") or "")) .. tostring(n.text or n.content or "");
	end;
	if sM._dead then
		return;
	end;
	local k = tM(tostring(n or ""), 44);
	while #k > 3 do
		U(k);
	end;
	if R ~= nil then
		for g, o in ipairs(m1.active) do
			if o.key == R then
				o.text, o.color, o.dur = k, c, tonumber(W) or 4;
				o.t0 = ((sM._now or V())) - .2;
				sM:_wake();
				return;
			end;
		end;
	end;
	local E;
	if #m1.pool > 0 then
		E = U(m1.pool);
	elseif #m1.active + #m1.pool < O1 then
		E = r1();
	else
		E = U(m1.active, 1);
		wM(E.all);
	end;
	E.text = k;
	E.key = R;
	E.t0 = sM._now or V();
	E.dur = tonumber(W) or 4;
	E.color = c;
	m1.active[#m1.active + 1] = E;
	sM:_wake();
end;
local function z1(g)
	local o = m1.active;
	if #o == 0 then
		return;
	end;
	local s = sM.C;
	local f, n = mM();
	local k = n - 16;
	local E = QM.th + 3;
	for n = #o, 1, -1 do
		local Q = o[n];
		local d = g - Q.t0;
		if d > Q.dur + .3 then
			wM(Q.all);
			U(o, n);
			m1.pool[#m1.pool + 1] = Q;
		else
			local g = 150;
			for o = 1, #Q.text, 1 do
				g = c(g, CM(Q.text[o]) + 22);
			end;
			local o = #Q.text * E + 12;
			k = k - o;
			local n = R(1, d / .18);
			n = 1 - ((1 - n)) * ((1 - n));
			local T = d > Q.dur and ((d - Q.dur)) / .3 or 0;
			local C = (((f - 16) - g) + W(((1 - n)) * ((g + 24)))) + W((T * T) * ((g + 24)));
			local h = Q.color or s.accent;
			xM(Q.edge, C, k, g, o, s.border);
			xM(Q.bg, C + 1, k + 1, g - 2, o - 2, s.group);
			xM(Q.bar, C + 1, k + 1, 2, o - 2, h);
			local U = 1 - P(d / Q.dur, 0, 1);
			local V = W(((g - 4)) * U);
			if V > 0 then
				xM(Q.prog, C + 3, (k + o) - 2, V, 1, h);
			else
				LM(Q.prog);
			end;
			for g = 1, 3, 1 do
				if g <= #Q.text then
					jM(Q.lines[g], Q.text[g], C + 11, (k + 6) + ((g - 1)) * E, s.text);
				else
					LM(Q.lines[g]);
				end;
			end;
			local I = 1 - P(T, 0, 1);
			for g = 1, #Q.all, 1 do
				HM(Q.all[g], I);
			end;
			k = k - 6;
		end;
	end;
end;
local y1 = { visible = false };
local function Z1()
	if not y1.edge then
		return;
	end;
	if not y1.visible then
		LM(y1.edge);
		LM(y1.inner);
		LM(y1.bg);
		LM(y1.bar);
		LM(y1.text);
		return;
	end;
	local g = sM.C;
	local o = { y1.label or "ui" };
	if q.ping then
		local g = tonumber(GetPingValue());
		if g and (g == g and g < math.huge) then
			o[#o + 1] = W(g) .. "ms";
		end;
	end;
	if os and type(os.date) == "function" then
		local g = os.date("%H:%M:%S");
		if type(g) == "string" then
			o[#o + 1] = g;
		end;
	end;
	local s = h(o, " | ");
	local f, n = CM(s) + 16, QM.R + 4;
	local c = mM();
	local R = y1.x or ((c - f) - 16);
	local k = y1.y or 16;
	y1.rect = {
			R,
			k,
			f,
			n,
		};
	xM(y1.edge, R, k, f, n, g.border);
	xM(y1.inner, R + 1, k + 1, f - 2, n - 2, g.frameIn);
	xM(y1.bg, R + 2, k + 2, f - 4, n - 4, g.group);
	xM(y1.bar, R + 2, k + 2, f - 4, 2, g.accent);
	jM(y1.text, s, R + 8, (k + 2) + W((((n - 2) - QM.th)) / 2), g.text);
end;
OM.rows = {};
local function A1(g)
	local o = OM.rows[g];
	if not o then
		o = { name = lM(sM._ov, "Text", KM.markText), key = lM(sM._ov, "Text", KM.markText) };
		OM.rows[g] = o;
	end;
	return o;
end;
local function F1()
	OM.dirty = false;
	if not OM.edge then
		return;
	end;
	if not OM.visible then
		for g, o in ipairs({
			"edge",
			"inner",
			"bg",
			"bar",
			"title",
			"rule",
		}) do
			LM(OM[o]);
		end;
		for g = 1, #OM.rows, 1 do
			LM(OM.rows[g].name);
			LM(OM.rows[g].key);
		end;
		OM.rect = nil;
		return;
	end;
	local g = sM.C;
	local o = {};
	for g, s in ipairs(sM._binds) do
		if s.vk and (s.win.alive and (s.o.list ~= false and s:_enabled())) then
			local g = (s.text ~= "" and s.text) or (s.host and s.host.text) or "keybind";
			o[#o + 1] = { g, "[" .. (((s.value or "-")) .. "]"), s:GetState() and true or false };
		end;
	end;
	local s = QM.th + 3;
	local f, n = CM("keybinds"), 0;
	for g, o in ipairs(o) do
		f, n = c(f, CM(o[1])), c(n, CM(o[2]));
	end;
	local R = c(150, (f + n) + 30);
	local k = ((QM.R + 6) + #o * s) + 2;
	local E, Q = mM();
	local d = P(OM.x or 16, 0, c(0, E - R));
	local T = P(OM.y or W(Q * .35), 0, c(0, Q - k));
	OM.rect = {
			d,
			T,
			R,
			k,
		};
	xM(OM.edge, d, T, R, k, g.border);
	xM(OM.inner, d + 1, T + 1, R - 2, k - 2, g.frameIn);
	xM(OM.bg, d + 2, T + 2, R - 4, k - 4, g.group);
	xM(OM.bar, d + 2, T + 2, R - 4, 2, g.accent);
	jM(OM.title, "keybinds", d + 8, (T + 4) + W(((QM.R - QM.th)) / 2), g.text);
	xM(OM.rule, d + 6, (T + QM.R) + 3, R - 12, 1, g.border);
	local C = (T + QM.R) + 6;
	for o, f in ipairs(o) do
		local W = A1(o);
		jM(W.name, UM(f[1], (R - n) - 26), d + 8, C, f[3] and g.text or g.textDim);
		jM(W.key, f[2], ((d + R) - 8) - CM(f[2]), C, f[3] and g.accent or g.textDim);
		C = C + s;
	end;
	for g = #o + 1, #OM.rows, 1 do
		LM(OM.rows[g].name);
		LM(OM.rows[g].key);
	end;
end;
function sM.SetKeybindList(g, o)
	local s = fM(g, o);
	if not OM.edge then
		local g = sM._ov;
		OM.edge = lM(g, "Square", KM.mark);
		OM.inner = lM(g, "Square", KM.markIn);
		OM.bg = lM(g, "Square", KM.markBg);
		OM.bar = lM(g, "Square", KM.markText);
		OM.rule = lM(g, "Square", KM.markText);
		OM.title = lM(g, "Text", KM.markText);
	end;
	OM.visible = s and true or false;
	F1();
	for g, o in ipairs(sM._syncToggles.keybinds) do
		if o.win.alive then
			o:Set(OM.visible, true);
		end;
	end;
	return sM;
end;
function sM.SetWatermark(g, o)
	local s = fM(g, o);
	if not y1.edge then
		local g = sM._ov;
		y1.edge = lM(g, "Square", KM.mark);
		y1.inner = lM(g, "Square", KM.markIn);
		y1.bg = lM(g, "Square", KM.markBg);
		y1.bar = lM(g, "Square", KM.markText);
		y1.text = lM(g, "Text", KM.markText);
	end;
	if s == nil or s == false then
		y1.visible = false;
	else
		y1.label = tostring(s);
		y1.visible = true;
	end;
	Z1();
	return sM;
end;
function sM.SetWatermarkVisible(g, o)
	local s = fM(g, o);
	if not y1.edge then
		sM.SetWatermark(y1.label or "ui");
	end;
	y1.visible = s and true or false;
	Z1();
	for g, o in ipairs(sM._syncToggles.watermark) do
		if o.win.alive then
			o:Set(y1.visible, true);
		end;
	end;
	return sM;
end;
uM = function(g)
		if sM._focus then
			DM();
		end;
		g.was = {};
		g.rep = {};
		g.t0 = V();
		g.caretOn = true;
		g.orig = g.buf;
		for o, s in ipairs(a) do
			g.was[s[1]] = O(s[1]);
		end;
		for o, s in ipairs(u) do
			g.was[s] = O(s);
		end;
		sM._focus = g;
		g.refresh();
		sM:_wake();
	end;
DM = function()
		local g = sM._focus;
		if not g then
			return;
		end;
		sM._focus = nil;
		g.commit(g.buf);
		g.refresh();
	end;
eM = function()
		local g = sM._focus;
		if not g then
			return;
		end;
		sM._focus = nil;
		if g.live and (g.preview and g.orig ~= g.buf) then
			g.preview(g.orig);
		end;
		g.refresh();
	end;
local function G1(g, o)
	local s = sM._focus;
	if not s then
		return false;
	end;
	if s.target == N1 then
		local s = N1.g and N1.g.hex;
		return s and K(g, o, s[1], s[2], s[3], s[4]);
	end;
	local f = s.target;
	return f.placed and (f.boxY and K(g, o, f.boxX or f.px, f.boxY, f.boxW or f.pw, f.boxH));
end;
local function gj(g)
	local o = sM._focus;
	local s = O(16);
	local f = O(17);
	local n = false;
	local function W(s)
		local f = O(s);
		local n = o.was[s];
		o.was[s] = f;
		if not f then
			o.rep[s] = nil;
			return false;
		end;
		if not n then
			o.rep[s] = g + .42;
			return true;
		end;
		if o.rep[s] and g >= o.rep[s] then
			o.rep[s] = g + .035;
			return true;
		end;
		return false;
	end;
	for s = 1, #u, 1 do
		local k = u[s];
		if W(k) then
			o.fresh = nil;
			if k == 13 or k == 9 then
				DM();
				return;
			elseif k == 27 then
				eM();
				return;
			elseif k == 8 then
				if o.caret > 0 then
					local g = 1;
					if f then
						local s = Q(o.buf, 1, o.caret);
						local f = s:match("^(.-)%S*%s*$") or "";
						g = #s - #f;
					end;
					o.buf = Q(o.buf, 1, o.caret - g) .. Q(o.buf, o.caret + 1);
					o.caret = o.caret - g;
					n = true;
				end;
			elseif k == 46 then
				if o.caret < #o.buf then
					o.buf = Q(o.buf, 1, o.caret) .. Q(o.buf, o.caret + 2);
					n = true;
				end;
			elseif k == 37 then
				o.caret = c(0, o.caret - 1);
			elseif k == 39 then
				o.caret = R(#o.buf, o.caret + 1);
			elseif k == 36 then
				o.caret = 0;
			elseif k == 35 then
				o.caret = #o.buf;
			end;
			o.t0 = g;
			o.caretOn = true;
			o.refresh();
		end;
	end;
	if f then
		return;
	end;
	for f = 1, #a, 1 do
		local c = a[f];
		if W(c[1]) then
			local f = s and c[3] or c[2];
			local W = true;
			if o.numeric and not f:match("[%d%.%-]") then
				W = false;
			end;
			if o.maxLength and #o.buf >= o.maxLength then
				W = false;
			end;
			if W then
				if o.fresh then
					o.buf, o.caret, o.fresh = "", 0, nil;
				end;
				o.buf = Q(o.buf, 1, o.caret) .. (f .. Q(o.buf, o.caret + 1));
				o.caret = o.caret + 1;
				n = true;
				o.t0 = g;
				o.caretOn = true;
			end;
		end;
	end;
	if n then
		if o.live and o.preview then
			o.preview(o.buf);
		end;
		o.refresh();
	end;
end;
iM = function(g)
		if sM._listen and sM._listen ~= g then
			bM(sM._listen, nil, true);
		end;
		sM._listen = g;
		sM._listenWas = {};
		for g, o in ipairs(p) do
			sM._listenWas[o] = O(o);
		end;
		g:_repaint();
		sM:_wake();
	end;
bM = function(g, o, s)
		if sM._listen ~= g then
			return;
		end;
		sM._listen = nil;
		if not s then
			g:Set(o or false);
		end;
		g:_repaint();
	end;
local function oj()
	local g = sM._listen;
	local o = sM._listenWas;
	for s = 1, #p, 1 do
		local f = p[s];
		local n = O(f);
		if n and not o[f] then
			if f == 27 then
				bM(g, nil, true);
			elseif f == 8 then
				bM(g, false);
			else
				bM(g, f);
			end;
			return;
		end;
		o[f] = n;
	end;
end;
local function sj(g)
	if not q.active then
		return true;
	end;
	if not sM._actAt or g - sM._actAt > .25 then
		sM._actAt = g;
		sM._act = isrbxactive() and true or false;
	end;
	return sM._act;
end;
local function fj(g)
	local o = sM._mouse;
	if not o then
		if sM._mouseRetry and g < sM._mouseRetry then
			return nil;
		end;
		sM._mouseRetry = g + .5;
		i = i or D("Players");
		local s = i and i.LocalPlayer;
		local f = s and s:GetMouse();
		if f then
			o = f;
			sM._mouse = f;
			if not sM._wheelHooked then
				sM._wheelHooked = true;
				local g, o = f.WheelForward, f.WheelBackward;
				if g then
					sM._conns[#sM._conns + 1] = g:Connect(function()
							sM._wheel = sM._wheel - 1;
						end);
				end;
				if o then
					sM._conns[#sM._conns + 1] = o:Connect(function()
							sM._wheel = sM._wheel + 1;
						end);
				end;
			end;
		end;
		if not o then
			return nil;
		end;
	end;
	local s, f = o.X, o.Y;
	if type(s) ~= "number" or type(f) ~= "number" then
		sM._mouse = nil;
		return nil;
	end;
	local n = sM.Settings.cursorOffset;
	return s + ((n[1] or 0)), f + ((n[2] or 0));
end;
local function nj(g, o)
	for s = #sM.Windows, 1, -1 do
		local f = sM.Windows[s];
		if f:_contains(g, o) then
			return f;
		end;
	end;
	return nil;
end;
local function Wj(g, o)
	qM();
	if sM._pick then
		if u1(g, o) then
			e1(g, o);
			return;
		end;
		local s = sM._pick;
		pM();
		local f = s.host or s;
		if f.placed and (K(g, o, f.px, f.py, f.pw, f:height()) and ((s.inline == false or (s.zx1 and (g >= s.zx1 - 3 and g <= s.zx2 + 3))))) then
			return;
		end;
	end;
	if sM._drop then
		if H1(g, o) then
			local s = sM._drop;
			local f, n = L1.upR, L1.dnR;
			if f and K(g, o, f[1], f[2], f[3], f[4]) then
				w1(-L1.n);
			elseif n and K(g, o, n[1], n[2], n[3], n[4]) then
				w1(L1.n);
			elseif g >= (L1.x + L1.w) - 8 and (L1.n < #L1.list and Y1(o)) then
				sM._cap = { kind = "dropbar", win = s.win };
			elseif Y1(o) then
				sM._cap = {
						kind = "droprow",
						win = s.win,
						y0 = o,
						first0 = L1.first,
					};
			end;
			return;
		end;
		local s = sM._drop;
		JM();
		if s.placed and K(g, o, s.px, s.py, s.pw, QM.R) then
			return;
		end;
	end;
	if sM._focus and not G1(g, o) then
		DM();
	end;
	if sM._listen then
		local s = sM._listen;
		bM(s, nil, true);
		local f = s.host or s;
		if f.placed and K(g, o, f.px, f.py, f.pw, QM.R) then
			return;
		end;
	end;
	if y1.visible and (y1.rect and K(g, o, y1.rect[1], y1.rect[2], y1.rect[3], y1.rect[4])) then
		sM._cap = { kind = "mark", dx = g - y1.rect[1], dy = o - y1.rect[2] };
		return;
	end;
	local s = OM.visible and OM.rect;
	if s and K(g, o, s[1], s[2], s[3], s[4]) then
		sM._cap = { kind = "klist", dx = g - s[1], dy = o - s[2] };
		return;
	end;
	local f = nj(g, o);
	if not f then
		return;
	end;
	if f ~= sM.Windows[#sM.Windows] then
		for g = #sM.Windows, 1, -1 do
			if sM.Windows[g] == f then
				U(sM.Windows, g);
			end;
		end;
		sM.Windows[#sM.Windows + 1] = f;
		l1();
	end;
	local n = f.titleRect;
	if n and K(g, o, n[1], n[2], n[3], n[4]) then
		sM._cap = {
				kind = "move",
				win = f,
				dx = g - f.x,
				dy = o - f.y,
			};
		return;
	end;
	if f.tabRect then
		local s = f.tabRect;
		if K(g, o, s[1], s[2], s[3], s[4]) then
			for s, n in ipairs(f.tabs) do
				local W = n.hit;
				if n.visible and (W and K(g, o, W[1], W[2], W[3], W[4])) then
					f:SelectTab(n);
				end;
			end;
			return;
		end;
	end;
	local W = f.gripRect;
	if W and K(g, o, W[1], W[2], W[3], W[4]) then
		sM._cap = {
				kind = "resize",
				win = f,
				dx = (f.x + f.w) - g,
				dy = (f.y + f.h) - o,
			};
		return;
	end;
	local R, k = f:_colAt(g, o);
	if not R then
		return;
	end;
	local E = f:_activeTab();
	local Q, d = k.upR, k.dnR;
	if Q and K(g, o, Q[1], Q[2], Q[3], Q[4]) then
		f:_scrollBy(R, -((k.vb - k.vt)) * .85);
		return;
	elseif d and K(g, o, d[1], d[2], d[3], d[4]) then
		f:_scrollBy(R, ((k.vb - k.vt)) * .85);
		return;
	end;
	local T = k.sb;
	local C = (not ((T and K(g, o, T[1], T[2], T[3], T[4])))) and f:_groupAt(R, o) or nil;
	if C then
		C:Toggle();
		return;
	end;
	if T and (E and K(g, o, T[1], T[2], T[3], T[4])) then
		sM._cap = {
				kind = "sbar",
				win = f,
				c = R,
				tab = E,
			};
		local g = k.vb - k.vt;
		local s = c(1, g - T[5]);
		local n = T[5];
		local W = k.vt + ((g - n)) * ((E.scroll[R] / c(1, E.maxScroll[R])));
		if o >= W and o < W + n then
			sM._cap.grab = o - W;
		else
			sM._cap.grab = n / 2;
		end;
		sM._cap.travel = s;
		f._dirty = true;
		return;
	end;
	local h = f:_rowAt(R, o);
	if h then
		if h:_enabled() and h.press then
			h:press(g, o);
		end;
		return;
	end;
	if E then
		sM._cap = {
				kind = "pan",
				win = f,
				c = R,
				tab = E,
				y0 = o,
				s0 = E.target[R],
			};
	end;
end;
local function cj(g, o)
	local s = sM._cap;
	local f = s.kind;
	if f == "move" then
		local f = s.win;
		local n, W = g - s.dx, o - s.dy;
		if n ~= f.x or W ~= f.y then
			if sM._pick and (sM._pick.win == f and N1.x) then
				N1.x, N1.y = N1.x + ((n - f.x)), N1.y + ((W - f.y));
			end;
			f.x, f.y = n, W;
			f._dirty = true;
		end;
	elseif f == "resize" then
		local f = s.win;
		local n, W = (g + s.dx) - f.x, (o + s.dy) - f.y;
		n, W = c(f.minW, n), c(f.minH, W);
		if n ~= f.w or W ~= f.h then
			f.w, f.h = n, W;
			f._dirty = true;
		end;
	elseif f == "slider" then
		s.wid:_dragTo(g);
	elseif f == "sbar" then
		local g, f, n = s.win, s.c, s.tab;
		local W = g.cols[f];
		local c = P((((o - s.grab) - W.vt)) / s.travel, 0, 1);
		local R = c * n.maxScroll[f];
		n.target[f] = R;
		n.scroll[f] = R;
		g:_layoutColumn(n, f);
	elseif f == "pan" then
		local g = s.tab;
		local f = P(s.s0 - ((o - s.y0)), 0, g.maxScroll[s.c]);
		g.target[s.c], g.scroll[s.c] = f, f;
		s.win:_layoutColumn(g, s.c);
	elseif f == "sv" or f == "hue" then
		D1(f, g, o);
	elseif f == "dropbar" then
		local g = sM._drop;
		if g then
			local g = ((L1.y + 1) + L1.hh) + L1.ah;
			local s = P(((o - g)) / c(1, L1.n * L1.rh), 0, 1);
			local f = 1 + W(s * c(0, #L1.list - L1.n) + .5);
			if f ~= L1.first then
				L1.first = f;
				MM();
			end;
		end;
	elseif f == "mark" then
		y1.x, y1.y = g - s.dx, o - s.dy;
		Z1();
	elseif f == "klist" then
		OM.x, OM.y = g - s.dx, o - s.dy;
		F1();
	elseif f == "droprow" and sM._drop then
		if not s.moved and k(o - s.y0) > 4 then
			s.moved = true;
		end;
		if s.moved then
			local g = s.first0 - W(((o - s.y0)) / L1.rh + .5);
			if g ~= L1.first then
				L1.first = g;
				MM();
			end;
		end;
	end;
end;
local function Rj(g, o)
	local s = sM._cap;
	sM._cap = nil;
	if not s then
		return;
	end;
	local f = s.kind;
	if f == "button" then
		local f = s.wid;
		f.held = false;
		if f.placed and (K(g, o, f.px, f.py, f.pw, f:height()) and f:_enabled()) then
			f:_click();
		end;
		if f.placed then
			f:paint();
		end;
	elseif f == "slider" then
		local g = s.wid;
		if g._pending then
			g:_fire();
			sM._pending[g] = nil;
		end;
	elseif f == "sv" or f == "hue" then
		local g = sM._pick;
		if g and g._pending then
			g:_fire();
			sM._pending[g] = nil;
		end;
	elseif f == "sbar" then
		s.win._dirty = true;
	elseif f == "droprow" then
		local f = sM._drop;
		if f and (not s.moved and H1(g, o)) then
			local g = Y1(o);
			local s = g and L1.list[(L1.first + g) - 1];
			if s then
				f:_pick(s);
				if f.multi then
					MM();
				else
					JM();
				end;
			end;
		end;
	elseif ((f == "move" or f == "resize")) and s.win.configFile then
		s.win._saveAt = V() + .5;
	elseif f == "klist" or f == "mark" then
		for g, o in ipairs(sM.Windows) do
			if o.configFile then
				o._saveAt = V() + .5;
			end;
		end;
	end;
	sM._hoverDirty = true;
end;
local function kj(g, o)
	if sM._drop or sM._pick or sM._listen then
		return;
	end;
	local s = nj(g, o);
	if not s then
		return;
	end;
	local f = s:_colAt(g, o);
	if not f then
		return;
	end;
	local n = s:_rowAt(f, o);
	if n and (n:_enabled() and n.rpress) then
		n:rpress(g, o);
	end;
end;
local function Ej(g)
	if g == sM._hover then
		return;
	end;
	local o = sM._hover;
	sM._hover = g;
	sM._hoverT = sM._now or V();
	qM();
	if o and (o.placed and o.win.alive) then
		o:paint();
	end;
	if g and g.placed then
		g:paint();
	end;
end;
local function Qj(g, o)
	local s, f, n, W, c = nil, nil, nil, nil, nil;
	local R, k = false, nil;
	if sM._pick and u1(g, o) then
		R, k = true, sM._pick.win;
		local s = N1.g;
		local f = ((s.done and K(g, o, s.done[1], s.done[2], s.done[3], s.done[4]))) and "done" or nil;
		if f ~= N1.hot then
			N1.hot = f;
			aM();
		end;
	elseif sM._drop and H1(g, o) then
		R, k = true, sM._drop.win;
		local s, f = L1.upR, L1.dnR;
		if s and K(g, o, s[1], s[2], s[3], s[4]) then
			W = { kind = "drop", dir = -1 };
		elseif f and K(g, o, f[1], f[2], f[3], f[4]) then
			W = { kind = "drop", dir = 1 };
		end;
		local n = (not W) and Y1(o) or nil;
		if n ~= L1.hover then
			L1.hover = n;
			MM();
		end;
	else
		if sM._drop and L1.hover then
			L1.hover = nil;
			MM();
		end;
		if sM._pick and N1.hot then
			N1.hot = nil;
			aM();
		end;
		local E = OM.visible and OM.rect;
		if (y1.visible and (y1.rect and K(g, o, y1.rect[1], y1.rect[2], y1.rect[3], y1.rect[4]))) or (E and K(g, o, E[1], E[2], E[3], E[4])) then
			R = true;
		else
			local E = nj(g, o);
			if E then
				R, k = true, E;
				f = E;
				local Q = E.tabRect;
				if Q and K(g, o, Q[1], Q[2], Q[3], Q[4]) then
					for s, f in ipairs(E.tabs) do
						local W = f.hit;
						if f.visible and (W and K(g, o, W[1], W[2], W[3], W[4])) then
							n = f;
						end;
					end;
				else
					local f, n = E:_colAt(g, o);
					if f then
						local R, k = n.upR, n.dnR;
						if R and K(g, o, R[1], R[2], R[3], R[4]) then
							W = {
									kind = "col",
									win = E,
									c = f,
									dir = -1,
								};
						elseif k and K(g, o, k[1], k[2], k[3], k[4]) then
							W = {
									kind = "col",
									win = E,
									c = f,
									dir = 1,
								};
						else
							c = E:_groupAt(f, o);
							if not c then
								s = E:_rowAt(f, o);
							end;
						end;
					end;
				end;
			end;
		end;
	end;
	local E = sM._cap;
	if E then
		if E.kind == "slider" then
			s = E.wid;
		elseif E.kind == "button" then
			s = (s == E.wid) and s or nil;
		end;
	end;
	Ej(s);
	if c ~= sM._hoverGroup then
		local g = sM._hoverGroup;
		sM._hoverGroup = c;
		if g then
			g:_repaintHeader();
		end;
		if c then
			c:_repaintHeader();
		end;
	end;
	local Q = sM._arrow;
	local d = (Q == nil and W == nil) or (Q and (W and (Q.kind == W.kind and (Q.win == W.win and (Q.c == W.c and Q.dir == W.dir)))));
	if not d then
		sM._arrow = W;
		if W then
			W.t0 = sM._now or V();
		end;
		for g, o in ipairs({ Q or false, W or false }) do
			if o and o.kind == "col" then
				if o.win.alive and (o.win._laidOut and o.win.cols[o.c].upR) then
					o.win:_paintArrows(o.c);
				end;
			elseif o and sM._drop then
				MM();
			end;
		end;
	end;
	for g, o in ipairs(sM.Windows) do
		local s = (o == f) and n or nil;
		if o._tabHover ~= s then
			o._tabHover = s;
			if o._laidOut and not o._dirty then
				o:_paintTabs();
			end;
		end;
	end;
	sM._overUI = R;
	sM._overWin = k;
	sM._hoverWin = f;
end;
local function dj(g)
	if not g then
		return true;
	end;
	local o = g.captureInput;
	if o == nil or o == true then
		return true;
	end;
	if o == false then
		return false;
	end;
	local s = RM(g, "captureInput");
	return g.captureInput == nil or (s and true or false);
end;
local function Tj()
	local g = sM._focus;
	if g then
		local o = g.target;
		return dj(o == N1 and ((sM._pick and sM._pick.win)) or o.win);
	end;
	if sM._listen then
		return dj(sM._listen.win);
	end;
	if sM._drop and L1.search then
		return dj(sM._drop.win);
	end;
	local o = sM._cap;
	if o then
		return dj(o.win or (o.wid and o.wid.win));
	end;
	if sM._overUI then
		return dj(sM._overWin);
	end;
	return false;
end;
local function Cj(g)
	if not q.input then
		return;
	end;
	local o = true;
	if sM.Settings.captureInput and not sM._dead then
		o = not Tj();
	end;
	if g or sM._inputSent ~= o then
		if sM._inputSent == nil and (o and not g) then
			return;
		end;
		sM._inputSent = o;
		setrobloxinput(o);
	end;
end;
local hj, Uj = {}, {};
local function Vj(g, o)
	local s = O(g);
	local f = hj[g];
	hj[g] = s;
	if not s then
		Uj[g] = nil;
		return false;
	end;
	if not f then
		Uj[g] = o + .35;
		return true;
	end;
	if Uj[g] and o >= Uj[g] then
		Uj[g] = o + .05;
		return true;
	end;
	return false;
end;
function L1.type(g)
	local o = sM._drop;
	local s = O(16);
	local f = L1.was;
	local n = false;
	for g = 1, #a, 1 do
		local o = a[g];
		local W = O(o[1]);
		if W and (not f[o[1]] and #L1.query < 24) then
			L1.query = L1.query .. ((s and o[3] or o[2]));
			n = true;
		end;
		f[o[1]] = W;
	end;
	local W, c, R = Vj(8, g), Vj(27, g), Vj(13, g);
	local k, E, d, T = Vj(38, g), Vj(40, g), Vj(33, g), Vj(34, g);
	if c then
		JM();
		return;
	end;
	if W and #L1.query > 0 then
		L1.query = Q(L1.query, 1, -2);
		n = true;
	end;
	if n then
		L1.first = 1;
		L1.hover = nil;
		MM();
	end;
	if R and L1.list[L1.first] then
		o:_pick(L1.list[L1.first]);
		if o.multi then
			MM();
		else
			JM();
			return;
		end;
	end;
	if k or d then
		w1(d and -L1.n or -1);
	elseif E or T then
		w1(T and L1.n or 1);
	end;
end;
local function Ij(g)
	if not q.key then
		return;
	end;
	if sM._listen then
		oj();
		return;
	end;
	if sM._focus then
		gj(g);
		return;
	end;
	if sM._drop and L1.search then
		L1.type(g);
		return;
	end;
	local o = sM._binds;
	for g = 1, #o, 1 do
		local s = o[g];
		local f = s.vk;
		if f and s.win.alive then
			local g = O(f);
			if g ~= s.down then
				s.down = g;
				if s:_enabled() then
					s:_edge(g);
				end;
			end;
		end;
	end;
	for g, o in ipairs(sM.Windows) do
		if o.toggleKey and not o._menuBindOwned then
			local g = O(o.toggleKey);
			if g ~= o._keyWas then
				o._keyWas = g;
				if g then
					o:Toggle();
				end;
			end;
		end;
	end;
	local s = sM._drop and H1(sM._mx, sM._my);
	local f = sM._hoverWin;
	local n = sM._hover and (sM._hover.kind == "slider" and sM._hover) or nil;
	if not ((s or f or n)) then
		return;
	end;
	local W, c = Vj(38, g), Vj(40, g);
	local R, k = Vj(33, g), Vj(34, g);
	local E, Q = Vj(37, g), Vj(39, g);
	if s then
		if W or R then
			w1(R and -L1.n or -1);
		elseif c or k then
			w1(k and L1.n or 1);
		end;
		return;
	end;
	if n and n:_enabled() then
		if E then
			n:nudge(-1);
		elseif Q then
			n:nudge(1);
		end;
	end;
	if f and ((W or c or R or k)) then
		local g, o = f:_colAt(sM._mx, sM._my);
		if g then
			local s = ((R or k)) and o.h * .8 or QM.R * 2;
			f:_scrollBy(g, ((W or R)) and -s or s);
		end;
	end;
end;
local function tj(g)
	if next(sM._rainbow) == nil then
		return;
	end;
	local o = ((g * sM.Settings.rainbowSpeed)) % 1;
	for g in pairs(sM._rainbow) do
		if g.win.alive then
			g:_setHSV(o, g.s > 0 and g.s or 1, g.v > 0 and g.v or 1);
		else
			sM._rainbow[g] = nil;
		end;
	end;
end;
local function Pj(g, o)
	for s in pairs(sM._pending) do
		if not s.win.alive then
			sM._pending[s] = nil;
		elseif s._pending and ((o or g - ((s._lastFire or 0)) >= .033333333333333)) then
			sM._pending[s] = nil;
			s:_fire();
		elseif not s._pending then
			sM._pending[s] = nil;
		end;
	end;
end;
local function Kj(g)
	if g < sM._next1 then
		return;
	end;
	sM._next1 = g + 1;
	if y1.visible then
		Z1();
	end;
	if sM._armed and (sM._armed._armed and g > sM._armed._armed) then
		local g = sM._armed;
		sM._armed = nil;
		g._armed = nil;
		if g.placed then
			g:paint();
		end;
	end;
end;
local function Bj()
	for g, o in ipairs(sM.Windows) do
		if o.visible or o.fadeV > 0 then
			return true;
		end;
	end;
	return sM._pick ~= nil or sM._drop ~= nil or #m1.active > 0 or sM._focus ~= nil or sM._listen ~= nil or sM._cap ~= nil;
end;
local function lj()
	if RM(sM.Settings, "inputGuard") then
		return true;
	end;
	local g = sM.Windows;
	for o = 1, #g, 1 do
		if RM(g[o], "inputGuard") then
			return true;
		end;
	end;
	return false;
end;
local function Lj(g)
	if sM._cap then
		return;
	end;
	local o = sM.Windows;
	for s = 1, #o, 1 do
		local f = o[s];
		if f._saveAt and g >= f._saveAt then
			f:SaveSettings();
		end;
	end;
end;
local function xj(g, o)
	sM._now = g;
	sM._frameNo = sM._frameNo + 1;
	local s = sj(g);
	local f, n = fj(g);
	if not f then
		f, n = sM._mx, sM._my;
	end;
	local W, c = false, false;
	if s and not lj() then
		W = q.m1 and (ismouse1pressed() and true) or false;
		c = q.m2 and (ismouse2pressed() and true) or false;
	end;
	local R = f ~= sM._mx or n ~= sM._my;
	local k, E, Q = W and not sM._m1, sM._m1 and not W, c and not sM._m2;
	sM._mx, sM._my = f, n;
	sM._m1, sM._m2 = W, c;
	if s and g >= sM._nextKeys then
		sM._nextKeys = g + .0083333333333333;
		Ij(g);
	end;
	if k then
		sM._hoverDirty = true;
		Wj(f, n);
	elseif W and sM._cap then
		if R then
			cj(f, n);
		end;
	elseif E then
		Rj(f, n);
	end;
	if Q then
		kj(f, n);
	end;
	if sM._wheel ~= 0 then
		local g = sM._wheel;
		sM._wheel = 0;
		if sM._drop and H1(f, n) then
			w1(g);
		else
			local o = nj(f, n);
			if o then
				local s = o:_colAt(f, n);
				if s then
					o:_scrollBy(s, (g * QM.R) * 3);
				end;
			end;
		end;
	end;
	for s, f in ipairs(sM.Windows) do
		f:_frame(g, o);
	end;
	if R or sM._hoverDirty then
		Qj(f, n);
		sM._hoverDirty = false;
	end;
	local d = sM._arrow;
	if d and (not sM._cap and (s and g - d.t0 > .12)) then
		local s = g - d.t0 > 1;
		if d.kind == "col" then
			if d.win.alive and d.win.fadeV > 0 then
				d.win:_scrollBy(d.c, (d.dir * ((s and 700 or 300))) * o);
			end;
		elseif sM._drop and g >= ((d.next or 0)) then
			d.next = g + ((s and .035 or .08));
			w1(d.dir);
		end;
	end;
	local T = sM._hover;
	if T and (T._tipLines and (not sM._cap and s)) then
		if i1.shown == T then
			if R then
				q1(T, f, n);
			end;
		elseif g - ((sM._hoverT or g)) >= sM.Settings.tooltipDelay then
			q1(T, f, n);
		end;
	elseif i1.shown then
		qM();
	end;
	local C = sM._focus;
	if C then
		local o = (((g - C.t0)) % 1) < .55;
		if o ~= C.caretOn then
			C.caretOn = o;
			C.refresh();
		end;
	end;
	if sM._flashW and (sM._flashW._flash and g > sM._flashW._flash) then
		local g = sM._flashW;
		sM._flashW = nil;
		g._flash = nil;
		g:_repaint();
	end;
	if sM.Bar.rainbow and g >= sM._nextBar then
		sM._nextBar = g + .05;
		for o, s in ipairs(sM.Windows) do
			if s.fadeV > 0 and s._laidOut then
				s:_paintBar(g);
			end;
		end;
	end;
	if g >= sM._next30 then
		sM._next30 = g + .033333333333333;
		tj(g);
	end;
	Pj(g, false);
	z1(g);
	Kj(g);
	Lj(g);
	if OM.dirty then
		F1();
	end;
	Cj(false);
end;
local function jj()
	if sM._dead then
		return;
	end;
	local g = V();
	if g < sM._nextFrame then
		return;
	end;
	sM._nextFrame = g + 1 / sM.Settings.fps;
	local o = g - ((sM._lastFrame or g));
	sM._lastFrame = g;
	if o > .1 then
		o = .1;
	end;
	xj(g, o);
	if not Bj() then
		sM:_sleep();
	end;
end;
local function Hj()
	if sM._dead or sM._rs then
		return;
	end;
	local g = V();
	if g < sM._nextIdle then
		return;
	end;
	sM._nextIdle = g + 1 / sM.Settings.idleHz;
	sM._now = g;
	sM._frameNo = sM._frameNo + 1;
	if sj(g) then
		Ij(g);
	end;
	tj(g);
	Pj(g, true);
	Kj(g);
	Lj(g);
	if OM.dirty then
		F1();
	end;
end;
function sM._wake(g)
	if g._dead or g._rs or g._manual then
		return;
	end;
	local o = e and ((e.RenderStepped or e.Heartbeat));
	if not o then
		return;
	end;
	g._rs = o:Connect(jj);
	g._lastFrame = V();
end;
function sM._sleep(g)
	local o = g._rs;
	g._rs = nil;
	if o then
		o:Disconnect();
	end;
	sM._overUI = false;
	sM._hoverWin = nil;
	sM._hover = nil;
	sM._arrow = nil;
	Cj(false);
end;
function sM._connectIdle(g)
	local o = e and e.Heartbeat;
	if o then
		g._idle = o:Connect(Hj);
	end;
end;
function sM._rehome(g)
	if g._dead then
		return;
	end;
	local o = g._idle;
	g._idle = nil;
	if o then
		o:Disconnect();
	end;
	local s = g._rs;
	g._rs = nil;
	if s then
		s:Disconnect();
	end;
	g._now = V();
	g:_connectIdle();
	if Bj() then
		g:_wake();
	end;
end;
function sM.Step(g)
	local o = V();
	local s = o - ((sM._lastFrame or o));
	sM._lastFrame = o;
	xj(o, R(s, .1));
end;
function sM.SetManual(g, o)
	local s = fM(g, o);
	sM._manual = s and true or false;
	if sM._manual then
		sM:_sleep();
	else
		sM:_wake();
	end;
	return sM;
end;
local function Yj()
	for g, o in ipairs(sM.Windows) do
		o._dirty = true;
	end;
	if sM._drop then
		MM();
	end;
	if sM._pick then
		aM();
	end;
	if y1.visible then
		Z1();
	end;
	OM.dirty = true;
end;
local function wj()
	for g, o in pairs(sM._themeWidgets) do
		if o.win.alive and sM.Theme[g] then
			o:_setRGB(sM.Theme[g], true);
		end;
	end;
end;
function sM.SetTheme(g, o)
	local s = fM(g, o);
	if type(s) == "string" then
		local g = G[s];
		if not g then
			return sM;
		end;
		sM.PresetName = s;
		s = g;
	end;
	if type(s) ~= "table" then
		return sM;
	end;
	for g, o in ipairs(gM) do
		local f = s[o] ~= nil and Y(s[o]) or nil;
		if f then
			sM.Theme[o] = f;
		end;
	end;
	EM();
	wj();
	Yj();
	return sM;
end;
function sM.SetThemeColor(g, o, s)
	local f, n;
	if g == sM then
		f, n = o, s;
	else
		f, n = g, o;
	end;
	local W = Y(n);
	if W and sM.Theme[f] then
		sM.Theme[f] = W;
		EM();
		Yj();
	end;
	return sM;
end;
function sM.GetTheme()
	local g = {};
	for o, s in ipairs(gM) do
		g[s] = j(sM.Theme[s]);
	end;
	return g;
end;
local function Nj()
	local function g(g)
		for o = 1, #g, 1 do
			local s = g[o];
			if s.t then
				YM(s);
			end;
		end;
	end;
	for o, s in ipairs(sM.Windows) do
		g(s.nodes);
	end;
	g(sM._ov);
end;
function sM.SetFont(g, o, s)
	local f, n;
	if g == sM then
		f, n = o, s;
	else
		f, n = g, o;
	end;
	if f ~= nil and r[f] ~= nil then
		sM.FontName = f;
		sM.Font = r[f];
	end;
	if tonumber(n) then
		local g = sM.TextSize;
		sM.TextSize = P(W(tonumber(n)), 8, 32);
		local o = sM.TextSize / g;
		if o ~= 1 then
			for g, s in ipairs(sM.Windows) do
				s.w, s.h = W(s.w * o + .5), W(s.h * o + .5);
				s.minW, s.minH = W(s.minW * o + .5), W(s.minH * o + .5);
			end;
		end;
	end;
	dM();
	Nj();
	Yj();
	sM:_wake();
	return sM;
end;
sM.FontMetrics = y;
function sM.SetCharRatio(g, o)
	local s = tonumber(fM(g, o));
	sM.Settings.charRatio = s and P(s, .2, 1.2) or nil;
	dM();
	Yj();
	return sM;
end;
function sM.SetOpacity(g, o)
	local s = tonumber(fM(g, o)) or 1;
	sM.Opacity = P(s, .1, 1);
	for g, o in ipairs(sM.Windows) do
		if o.fadeV > 0 then
			o:_applyAlpha();
		end;
	end;
	return sM;
end;
function sM.SetTextOutline(g, o)
	local s = fM(g, o);
	sM.TextOutline = s and true or false;
	Nj();
	return sM;
end;
function sM.SetAccentBar(g, o)
	local s = fM(g, o);
	if type(s) == "table" then
		for g, o in pairs(s) do
			sM.Bar[g] = o;
		end;
	elseif type(s) == "boolean" then
		sM.Bar.rainbow = s;
	end;
	for g, o in ipairs(sM.Windows) do
		if o._laidOut then
			o:_paintBar(sM._now or V());
		end;
	end;
	return sM;
end;
function sM.KeyName(g, o)
	return v[fM(g, o)];
end;
function sM.KeyCode(g, o)
	return S(fM(g, o));
end;
function sM.OnUnload(g, o)
	sM._onUnload[#sM._onUnload + 1] = fM(g, o);
	return sM;
end;
function sM.Unload(g)
	if sM._dead then
		return;
	end;
	sM._dead = true;
	if rawget(_G, "UILib") == sM then
		_G.UILib = nil;
	end;
	if type(getgenv) == "function" then
		local g = getgenv();
		if type(g) == "table" and rawget(g, "UILib") == sM then
			g.UILib = nil;
		end;
	end;
	local o = sM._conns;
	sM._conns = {};
	if sM._rs then
		o[#o + 1] = sM._rs;
		sM._rs = nil;
	end;
	if sM._idle then
		o[#o + 1] = sM._idle;
		sM._idle = nil;
	end;
	for g, o in ipairs(o) do
		o:Disconnect();
	end;
	for g, o in ipairs(sM._onUnload) do
		WM(o);
	end;
	for g = #sM.Windows, 1, -1 do
		local o = sM.Windows[g];
		if o and not o._unloading then
			o._unloading = true;
			WM(o.onUnload, o);
		end;
	end;
	for g = #sM.Windows, 1, -1 do
		sM.Windows[g]:Destroy();
	end;
	local s = sM._ov;
	sM._ov = { dead = true };
	NM(s);
	if q.input and sM._inputSent == false then
		setrobloxinput(true);
	end;
	sM._inputSent = nil;
end;
function W1._save(g)
	return g.value;
end;
function c1._save(g)
	return g.value;
end;
function E1._save(g)
	return g.value;
end;
function R1._save(g)
	if g.multi then
		local o = {};
		for s = 1, #g.values, 1 do
			if g.value[g.values[s]] then
				o[#o + 1] = g.values[s];
			end;
		end;
		if #o == 0 then
			return "";
		end;
		return o;
	end;
	return g.value or "";
end;
function R1._load(o, g)
	if g == "" then
		g = o.multi and {} or false;
	end;
	o:Set(g);
end;
function Q1._save(g)
	return { hex = g:GetHex(), rainbow = g.rainbow and true or false };
end;
function Q1._load(o, g)
	if type(g) == "table" then
		if g.hex then
			o:Set(g.hex);
		end;
		o:SetRainbow(g.rainbow and true or false);
	else
		o:Set(g);
	end;
end;
function d1._save(g)
	return { key = g.value or "", mode = g.mode };
end;
function d1._load(o, g)
	if type(g) == "table" then
		o:Set(g.key ~= "" and g.key or false);
		if g.mode then
			o:SetMode(g.mode);
		end;
	else
		o:Set(g);
	end;
end;
function rM._load(o, g)
	o:Set(g);
end;
local function vj(g)
	if not q.mkdir then
		return;
	end;
	local o = "";
	for g in (tostring(g)):gmatch("[^/\\]+") do
		o = (o == "") and g or (o .. ("/" .. g));
		if not ((q.isdir and isfolder(o))) then
			makefolder(o);
		end;
	end;
end;
local function Xj(g)
	local o = false;
	WM(function()
		g();
		o = true;
	end);
	return o;
end;
local Jj = {};
function Jj.read(g)
	if not ((b and q.fs)) then
		return nil, "file access is not available";
	end;
	if not isfile(g) then
		return nil, "config not found";
	end;
	local o = readfile(g);
	if type(o) ~= "string" then
		return nil, "could not read the config";
	end;
	local s;
	Xj(function()
		s = b:JSONDecode(o);
	end);
	if type(s) ~= "table" then
		return nil, "config is damaged";
	end;
	return s;
end;
function Jj.write(g, o)
	if not ((b and q.fs)) then
		return false, "file access is not available";
	end;
	local s = b:JSONEncode(o);
	if type(s) ~= "string" then
		return false, "could not encode the config";
	end;
	if not Xj(function()
		writefile(g, s);
	end) then
		return false, "could not write " .. tostring(g);
	end;
	return true;
end;
function P1._collect(g)
	local o = {};
	for g, s in ipairs(g.flagOrder) do
		if s._save and s.o.save ~= false then
			o[s.flag] = s:_save();
		end;
	end;
	return o;
end;
function P1._applyFlags(o, g)
	o._loading = true;
	for o, s in ipairs(o.flagOrder) do
		local f = g[s.flag];
		if f ~= nil and (s._load and s.o.save ~= false) then
			s:_load(f);
		end;
	end;
	o._loading = nil;
	if #o.depWidgets > 0 then
		o._depsDirty = true;
	end;
end;
function P1.SaveConfig(o, g)
	g = B1(g);
	if g == "" then
		return false, "enter a config name";
	end;
	vj(o.folder);
	return Jj.write(o.folder .. ("/" .. (g .. ".json")), o:_collect());
end;
function P1.LoadConfig(o, g)
	g = B1(g);
	if g == "" then
		return false, "pick a config";
	end;
	local s, f = Jj.read(o.folder .. ("/" .. (g .. ".json")));
	if not s then
		return false, f;
	end;
	o:_applyFlags(s);
	return true;
end;
function P1.LoadSettings(g)
	g._settingsLoaded = true;
	if not g.configFile then
		return false;
	end;
	local o = Jj.read(g.configFile);
	if not o then
		return false;
	end;
    if not o._oceanUI then
        o.__preset, o.__font, o.__fontsize = "ocean", sM.FontName, 14;
        o.__bar_rgb = false;
        for role, rgb in pairs(G.ocean) do o["__c_" .. role] = nil; end;
        o._w, o._h = g.w, g.h;
        o._x, o._y = g.x, g.y;
    end;
    if not o._oceanPerformance then
        o.__fps = math.min(tonumber(o.__fps) or 60, 60);
    end;
	g:_applyFlags(o);
	local s, f = tonumber(o._x), tonumber(o._y);
	if s and f then
		g.x, g.y = s, f;
	end;
	local n, W = tonumber(o._w), tonumber(o._h);
	if n and (W and g.resizable) then
		g.w, g.h = n, W;
	end;
	local c = tonumber(o._tab);
	if c and g.tabs[c] then
		g.active = g.tabs[c];
	end;
	if type(o._collapsed) == "string" then
		local s = {};
		for g in o._collapsed:gmatch("[^|]+") do
			s[g] = true;
		end;
		for g, o in ipairs(g.tabs) do
			for g, o in ipairs(o.groups) do
				if o.collapsible then
					o.collapsed = s[o:_key()] == true;
				end;
			end;
		end;
	end;
	if tonumber(o._klx) and tonumber(o._kly) then
		OM.x, OM.y, OM.dirty = tonumber(o._klx), tonumber(o._kly), true;
	end;
	if tonumber(o._wmx) and tonumber(o._wmy) then
		y1.x, y1.y = tonumber(o._wmx), tonumber(o._wmy);
	end;
	g._dirty = true;
	return true;
end;
function P1.SaveSettings(g)
	g._saveAt = nil;
	if not ((g.configFile and g._settingsLoaded)) then
		return false;
	end;
	local o = g:_collect();
    o._oceanUI = 1;
    o._oceanPerformance = 1;
	o._x, o._y, o._w, o._h = W(g.x), W(g.y), W(g.w), W(g.h);
	local s = {};
	for g, o in ipairs(g.tabs) do
		for g, o in ipairs(o.groups) do
			if o.collapsed then
				s[#s + 1] = o:_key();
			end;
		end;
	end;
	o._collapsed = h(s, "|");
	o._klx, o._kly, o._wmx, o._wmy = OM.x, OM.y, y1.x, y1.y;
	for s, f in ipairs(g.tabs) do
		if f == g.active then
			o._tab = s;
		end;
	end;
	return Jj.write(g.configFile, o);
end;
function P1.DeleteConfig(o, g)
	g = B1(g);
	if g == "" or not ((q.del and q.fs)) then
		return false;
	end;
	local s = o.folder .. ("/" .. (g .. ".json"));
	if not isfile(s) then
		return false;
	end;
	delfile(s);
	return true;
end;
function P1.ListConfigs(g)
	local o = {};
	if not q.list or (q.isdir and not isfolder(g.folder)) then
		return o;
	end;
	local s = listfiles(g.folder);
	if type(s) ~= "table" then
		return o;
	end;
	for g, s in ipairs(s) do
		local f = (tostring(s)):match("([^/\\]+)%.json$");
		if f then
			o[#o + 1] = f;
		end;
	end;
	C(o);
	return o;
end;
function P1.SetAutoload(o, g)
	if not q.fs then
		return false;
	end;
	vj(o.folder);
	local s, f = o.folder .. "/autoload.txt", g and B1(g) or "";
	return Xj(function()
		writefile(s, f);
	end);
end;
function P1.GetAutoload(g)
	if not q.fs then
		return nil;
	end;
	local o = g.folder .. "/autoload.txt";
	if not isfile(o) then
		return nil;
	end;
	local s = readfile(o);
	if type(s) == "string" then
		s = B1(s);
		if s ~= "" then
			return s;
		end;
	end;
	return nil;
end;
function P1.AddSettingsTab(s, g, o)
	local f = s;
	local n = s:AddTab(g or "settings");
	local c = s.columns;
	local R = n:AddGroup("interface", 1);
	R:AddDropdown({
		text = "preset",
		flag = "__preset",
		values = F,
		default = sM.PresetName,
		callback = function(g)
			sM:SetTheme(g);
		end,
	});
	R:AddSlider({
		text = "opacity",
		flag = "__opacity",
		min = 30,
		max = 100,
		default = W(sM.Opacity * 100),
		suffix = "%",
		callback = function(g)
			sM:SetOpacity(g / 100);
		end,
	});
	R:AddToggle({
		text = "text outline",
		flag = "__outline",
		default = sM.TextOutline,
		callback = function(g)
			sM:SetTextOutline(g);
		end,
	});
	if #m > 0 then
		R:AddDropdown({
			text = "font",
			flag = "__font",
			values = m,
			default = sM.FontName,
			callback = function(g)
				sM:SetFont(g);
			end,
		});
	end;
	R:AddSlider({
		text = "font size",
		flag = "__fontsize",
		min = 10,
		max = 20,
		default = sM.TextSize,
		callback = function(g)
			sM:SetFont(nil, g);
		end,
	});
	local k = sM._syncToggles;
	k.watermark[#k.watermark + 1] = R:AddToggle({
			text = "watermark",
			flag = "__watermark",
			default = y1.visible,
			callback = function(g)
				sM:SetWatermarkVisible(g);
			end,
		});
	R:AddToggle({
		text = "keybind alerts",
		flag = "__bindtoasts",
		default = sM.Settings.bindToasts,
		tooltip = "a short notification whenever a keybind turns something on or off",
		callback = function(g)
			sM.Settings.bindToasts = g;
		end,
	});
	k.keybinds[#k.keybinds + 1] = R:AddToggle({
			text = "keybind list",
			flag = "__keybinds",
			default = OM.visible,
			callback = function(g)
				sM:SetKeybindList(g);
			end,
		});
	R:AddToggle({
		text = "block game input",
		flag = "__capture",
		default = sM.Settings.captureInput,
		tooltip = "keeps clicks on the menu from also reaching the game",
		callback = function(g)
			sM.Settings.captureInput = g;
			Cj(true);
		end,
	});
	local E = n:AddGroup("theme colors", 1);
	for g, o in ipairs(gM) do
		sM._themeWidgets[o] = E:AddColor({
				text = oM[o],
				flag = "__c_" .. o,
				default = sM.Theme[o],
				callback = function(g, s)
					sM:SetThemeColor(o, s.rgb);
				end,
			});
	end;
	local Q = n:AddGroup("accent bar", 1);
	Q:AddToggle({
		text = "rgb gradient",
		flag = "__bar_rgb",
		default = sM.Bar.rainbow,
		callback = function(g)
			sM:SetAccentBar({ rainbow = g });
		end,
	});
	Q:AddDropdown({
		text = "direction",
		flag = "__bar_dir",
		values = { "left", "right" },
		default = sM.Bar.direction < 0 and "left" or "right",
		callback = function(g)
			sM:SetAccentBar({ direction = (g == "left") and -1 or 1 });
		end,
	});
	Q:AddSlider({
		text = "speed",
		flag = "__bar_speed",
		min = 0,
		max = 1,
		step = .02,
		default = sM.Bar.speed,
		suffix = "x",
		callback = function(g)
			sM:SetAccentBar({ speed = g });
		end,
	});
	local d = n:AddGroup("configuration", c);
	local T = d:AddTextbox({
			text = "config name",
			default = "default",
			placeholder = "name",
			save = false,
		});
	local C = d:AddDropdown({
			text = "config list",
			values = s:ListConfigs(),
			allowNone = true,
			save = false,
		});
	local h;
	local function U()
		C:SetValues(f:ListConfigs());
		if h then
			h:SetText("autoload: " .. ((f:GetAutoload() or "none")));
		end;
	end;
	d:AddButton({ text = "save", callback = function()
			local g = T.value;
			local o, s = f:SaveConfig(g);
			sM:Notify(o and ("saved config " .. B1(g)) or ("save failed: " .. tostring(s)), 3);
			U();
			if o then
				C:Set(B1(g), true);
			end;
		end });
	d:AddButton({ text = "load", callback = function()
			local g = C.value or "";
			if g == "" or g == false then
				g = T.value;
			end;
			local o, s = f:LoadConfig(g);
			sM:Notify(o and ("loaded config " .. B1(g)) or ("load failed: " .. tostring(s)), 3);
		end });
	d:AddButton({ text = "delete", confirm = true, callback = function()
			local g = C.value;
			if g and g ~= "" then
				f:DeleteConfig(g);
				sM:Notify("deleted config " .. g, 3);
				U();
			end;
		end });
	d:AddButton({ text = "refresh list", callback = U });
	d:AddButton({ text = "set autoload", callback = function()
			local g = C.value;
			if not g or g == "" then
				g = T.value;
			end;
			f:SetAutoload(g);
			U();
		end });
	h = d:AddLabel({ text = "autoload: " .. ((s:GetAutoload() or "none")), dim = true });
	local V = n:AddGroup("menu", c);
	V:AddKeybind({
		text = "menu key",
		flag = "__menukey",
		default = s.toggleKey,
		list = false,
		notify = false,
		onClick = function()
			f:Toggle();
		end,
	});
	s._menuBindOwned = true;
	V:AddSlider({
		text = "refresh rate",
		flag = "__fps",
		min = 30,
		max = 240,
		step = 10,
		default = sM.Settings.fps,
		suffix = " fps",
		callback = function(g)
			sM.Settings.fps = g;
		end,
	});
	V:AddToggle({
		text = "smooth scrolling",
		flag = "__smooth",
		default = sM.Settings.smoothScroll,
		callback = function(g)
			sM.Settings.smoothScroll = g;
		end,
	});
	V:AddButton({ text = "reset theme", callback = function()
			sM:SetTheme("ocean");
			f:SetValue("__preset", "ocean");
		end });
	if not ((type(o) == "table" and o.unload == false)) then
		V:AddButton({ text = "unload", confirm = true, callback = function()
				f:Unload();
			end });
	end;
	return n;
end;
sM.Ocean = {
    tabs = {Main="Start", Cast="Casting", Reel="Reeling", ESP="Map markers",
        ["Value changer"]="Instant reel", Webhook="Notifications", settings="Settings"},
    descriptions = {
        Main="Start or stop fishing and check your session.",
        Cast="Choose cast strength, wait times and your tool key.",
        Reel="Advanced reeling settings. Leave defaults unless you need to tune them.",
        Minigames="Adjust the controls for nuke, spear and gun fishing.",
        ["Value changer"]="Enable instant reel and adjust its speed.",
        ESP="Show location markers and their distance from you.",
        Treasure="Find treasure chests and choose where to travel.",
        Appraise="Choose which fish sizes, qualities and mutations to keep.",
        Teleport="Search for a place, or enter coordinates to travel there.",
        Rods="Search for a rod and travel to its location.",
        Webhook="Choose which updates to send to your Discord webhook.",
        settings="Change the look, menu shortcuts and saved profiles.",
    },
    groups = {Macro="Fishing", Mode="Fishing tool", Casting="Cast and wait times",
        Equip="Tool and hotbar", ["Stall recovery"]="If fishing gets stuck",
        ["Hybrid controller tuning"]="Advanced control", Estimator="Movement prediction",
        Waypoints="Location markers", ["Treasure chest ESP"]="Chest markers",
        interface="Appearance", ["theme colors"]="Colors", ["accent bar"]="Accent animation",
        configuration="Saved profiles", menu="Menu and performance"},
    labels = {
        ["Auto Fish"]={"Auto Fish - start / stop", "Turn automatic fishing on or off. Click the key shown beside this switch to change its shortcut."},
        ["Reset counters"]={"Reset session counts", "Clear the caught, lost, timeout and recovery counts for this session."},
        Mode={"Fishing tool", "Choose the tool you are using: rod, spear or gun."},
        ["Dual reel"]={"Control two reels", "Control a second fishing minigame using the other mouse button."},
        ["Swap which reel gets which button"]={"Swap reel mouse buttons", "Swap the mouse buttons assigned to the two reels."},
        ["Release cast at power %"]={"Cast strength (%)", "Release the cast when the power meter reaches this percentage."},
        ["Cast charge timeout (ms)"]={"Cast charge limit (ms)", "Maximum wait for the cast to charge. 1000 ms equals 1 second."},
        ["Wait for shake prompt (ms)"]={"Wait for shake (ms)", "Maximum wait for the shake prompt after casting. 1000 ms equals 1 second."},
        ["Re-arm cast if no bar by (ms)"]={"Retry missing cast bar (ms)", "How long to wait before trying the cast again if no power bar appears."},
        ["Post-cast delay (ms)"]={"Pause after casting (ms)", "Wait this long after a cast. 1000 ms equals 1 second."},
        ["Post-catch delay (ms)"]={"Pause after a catch (ms)", "Wait this long after catching a fish. 1000 ms equals 1 second."},
        ["Post-lost delay (ms)"]={"Pause after losing a fish (ms)", "Wait this long after a fish is lost. 1000 ms equals 1 second."},
        ["Shake interval (ms)"]={"Time between shakes (ms)", "Delay between shake actions. 1000 ms equals 1 second."},
        ["Give up on shake after (ms)"]={"Shake time limit (ms)", "Stop waiting for shaking after this time."},
        ["Rod hotbar key"]={"Equip tool key", "The keyboard key used to equip your fishing tool from the hotbar."},
        ["Equip attempts"]={"Equip retry count", "How many times to try equipping the tool."},
        ["Verify press after (ms)"]={"Check equipped after (ms)", "Wait this long after pressing the tool key before checking the result."},
        ["Equip deadline (ms)"]={"Equip time limit (ms)", "Maximum time allowed for the tool to equip."},
        ["Re-equip if the first cast produces no bar"]={"Re-equip after a failed cast", "Try equipping the tool again if the first cast does not show a power bar."},
        ["Force a restart after (ms)"]={"Restart if stuck for (ms)", "Restart fishing if it makes no progress for this long."},
        ["Rediscover a frozen reel after (ms)"]={"Check stuck reel after (ms)", "Look for the reel again when its state has stopped updating."},
        ["Kp (proportional)"]={"Correction strength (Kp)", "Advanced: how strongly the controller reacts to the distance from its target."},
        ["Ki (integral)"]={"Drift correction (Ki)", "Advanced: correct a persistent offset over time."},
        ["Kd (derivative)"]={"Motion damping (Kd)", "Advanced: adjust the response to changes in tracking error."},
        ["Show waypoints"]={"Show location markers", "Display markers for known locations in the game world."},
        ["Include fishing spots"]={"Mark fishing spots too", "Include fishing locations in the marker display."},
        ["Square size (px)"]={"Marker size (pixels)", "Change the size of the marker squares."},
        ["Max distance (0 = all)"]={"View distance (0 = unlimited)", "Only show markers within this distance, in studs. Zero shows all distances."},
        ["Click interval"]={"Time between appraisals", "Wait this many seconds between appraisal clicks."},
        ["Press hold"]={"Click hold time", "How long to hold each appraisal click, in seconds."},
        ["Strict Filtering"]={"Wait for a fish to be equipped", "If enabled, do not appraise while no fish is equipped."},
        ["Match: -"]={"Search result: none", "Enter a search term in the field below."},
        ["List all"]={"Print all locations", "Print the available locations in the executor console."},
        ["Instant teleport to match"]={"Travel to search result", "Teleport to the location found by your search."},
        ["Copy My Position"]={"Use my current coordinates", "Put your current position into the coordinates box. This does not copy to the clipboard."},
        ["Teleport to coordinates"]={"Travel to coordinates", "Teleport to the three coordinates entered above."},
        ["Instant teleport to rod"]={"Travel to this rod", "Teleport to the rod found by your search."},
        ["Enable webhook"]={"Send Discord notifications", "Allow the configured Discord webhook to send updates."},
        ["Send periodic stats"]={"Send session updates", "Send fishing statistics at the interval below."},
        ["Stats interval (sec)"]={"Update interval (seconds)", "Time between Discord session updates."},
        ["refresh rate"]={"Menu refresh rate", "Only affects menu updates, not the fishing engine. 60 is the default; try 30 to reduce menu overhead further."},
        ["smooth scrolling"]={"Animate scrolling", "Turn off for immediate scrolling and fewer animation redraws."},
        ["rgb gradient"]={"Animate accent colors", "Moving colors add redraws. Leave off to reduce menu overhead."},
        preset={"Color theme", "Choose a color scheme for the menu."},
        opacity={"Menu opacity", "How solid the menu background appears."},
        ["menu key"]={"Show / hide shortcut", "Click the key to choose a shortcut for opening and hiding the menu."},
        ["block game input"]={"Keep menu clicks in the menu", "Prevent menu clicks from also clicking in the game."},
        ["config name"]={"Profile name", "Choose a name before saving a set of settings."},
        ["config list"]={"Saved profile", "Choose a saved set of settings to load or delete."},
        ["set autoload"]={"Load this profile at startup", "Use the selected profile automatically on future runs."},
    },
};
sM.Widget = rM;
sM._internals = {
		CP = N1,
		DL = L1,
		TT = i1,
		M = QM,
		WM = y1,
		KL = OM,
		paintDrop = MM,
	};
sM.Window = P1;
sM.Tab = t1;
sM.Group = U1;
sM:_connectIdle();
sM._now = V();
_G.UILib = sM;
if type(getgenv) == "function" then
	local g = getgenv();
	if type(g) == "table" then
		g.UILib = sM;
	end;
end;
return sM;

]====]
    local forced = UI_STALE and not rawget(_G, "UI_RELOAD")
    if forced then _G.UI_RELOAD = true end
    if type(src) == "string" then pcall(function() loadstring(src)() end) end
    if forced then _G.UI_RELOAD = nil end
    local function pick(t)
        if type(t) == "table" and not t._dead and t.CreateWindow then Library = t end
    end
    if type(getfenv) == "function" then pcall(function() pick(rawget(getfenv(0), "UILib")) end) end
    if not Library then pcall(function() pick(_G.UILib) end) end
    if not Library and type(getgenv) == "function" then
        pcall(function() pick(getgenv().UILib) end)
    end
    -- The build on GitHub publishes the old name until the renamed build is uploaded there.
    if not Library then warn("UI library failed to load, running console-only") end
end

-- ============================================================================
-- Auto Appraise (merged tab). Wrapped in one function so its locals live in this
-- function's own register scope (adds just +1 to the macro's main-chunk budget)
-- and its guard-returns stay valid. Reuses the macro's UI Library + Window,
-- adding an "Appraise" tab. State/cleanup live under _G.FischAppraiser; FM.unload
-- also tears this down.
--
-- Transplanted from the community "Fisch Macro" build (2026-09-05), replacing the
-- old deep-scan appraiser. What that changes:
--   * It clicks WHEREVER THE CURSOR ALREADY IS. There is no recorded click
--     position and no mousemoveabs -- park the pointer on the game's Appraise
--     button and leave it there. The old tab moved the cursor to a spot you
--     recorded first; that whole picker (and its on-screen crosshair) is gone.
--   * Detection is GUI text only: the ItemName label whose text ends in the held
--     Tool's species name (see fishDisplayName for which slot wins). No
--     attribute/descendant walk, no VFX heuristics, and no auto-learning into
--     appraiser_mutations.json -- a modifier the game rolls that is not in
--     MUTATIONS below is never matched until you add it by hand (Advanced ->
--     Save Mutation, session only).
--
-- 2026-09-19, from the community build's next revision: the dropdown is the
-- only source of mutation filters (a saved custom name used to stay ANDed in
-- forever), Reset filters clears every filter, Petrified is in the list, and
-- the held-slot lookup no longer lets a fancier copy elsewhere in the inventory
-- stand in for the fish in your hand.
--   * Filters are three ANDed categories -- size, quality, mutation -- each
--     ignored when nothing in it is picked. Every picked quality must be present
--     (they stack); any ONE picked mutation satisfies that category.
--
-- Three things kept from this file rather than the source, because the source's
-- versions do not survive here: the held-tool lookup walks the character's
-- children (FindFirstChildOfClass("Tool") returns nil under Matcha), rich-text
-- tags are stripped before matching label text (the game wraps some names in
-- <font>/<b>, which would break a raw suffix compare), and clicking is gated on
-- robloxActive() so an alt-tab cannot fire the auto-clicker into another window.
-- ============================================================================
local function fischAppraiser()
    if not (Library and Window) then return end
    -- Players / RunService / the tree helpers resolve to the macro's top-level
    -- upvalues here; no need to re-resolve them in this block.

    -- ---- re-run hygiene ---------------------------------------------------------
    if _G.FischAppraiser then pcall(function() _G.FischAppraiser.unload() end) end
    local A = {
        dead = false, conns = {},
        enabled = false,
        count = 0,
        delay = 0.35,       -- seconds between clicks
        pressHold = 0.05,   -- how long mouse1 stays down (see the slider tooltip)
        held = false,
        pressedAt = 0,
        nextClick = 0,
        status = "idle",
        strictFilters = false,
        settle = 1.0,       -- seconds after a click to wait for its result before rolling an unchanged name again
        lastRaw = nil,      -- the name read just before the last click
        requireAllQualities = true,   -- no UI row upstream; every picked quality must be on the fish
        filters = { sizes = {}, qualities = {}, mutations = {} },
        filterRows = {},              -- size/quality toggles, for Reset filters
    }
    _G.FischAppraiser = A
    function A.unload()
        A.dead = true; A.enabled = false
        for _, c in ipairs(A.conns) do pcall(function() c:Disconnect() end) end
        if A.held then pcall(mouse1release); A.held = false end
    end

    -- ---- name tables ------------------------------------------------------------
    local SIZES     = { "Giant", "Big", "Small", "Tiny" }
    -- the game's whole quality set (shared.modules.library.attributes): without
    -- Glitched here, "Glitched Mythical Cod" parsed as mutation "glitched mythical"
    -- and a Mythical hit was rolled away
    local QUALITIES = { "Shiny", "Sparkling", "Glitched" }
    local MUTATIONS = {
        "Albino", "Darkened", "Negative", "Glossy", "Bioluminescent", "Lunar",
        "Translucent", "Electric", "Hexed", "Silver", "Entrenched", "Frozen",
        "Mosaic", "Scorched", "Amber", "Abyssal", "Coral", "Decayed", "Poisoned",
        "Fossilized", "Vined", "Crimson", "Honey", "Midas", "Boreal",
        "Fallen", "Greedy", "Spirit", "Mourned", "Mythical", "Shrouded",
        "Beached", "Paradise", "Tanned", "Tropica", "Super-Tanned", "Petrified",
    }
    local SIZE_SET, QUALITY_SET = {}, {}
    for _, n in ipairs(SIZES)     do SIZE_SET[n:lower()]    = true end
    for _, n in ipairs(QUALITIES) do QUALITY_SET[n:lower()] = true end

    -- the game writes a curly apostrophe in some names; fold it so a typed
    -- custom entry with a straight quote still matches
    local function normalise(s)
        return (tostring(s or ""):gsub("\226\128\153", "'"):lower())
    end
    local function trunc(s, n)
        s = tostring(s or "")
        if #s > n then return s:sub(1, n - 2) .. ".." end
        return s
    end

    -- ---- held fish ----------------------------------------------------------------
    -- The source used char:FindFirstChildOfClass("Tool"), which returns nil under
    -- Matcha. Walk the character models this file already resolves instead (same
    -- pattern as refreshRodName).
    local function getCurrentFish()
        for _, char in ipairs(getCharacterModels()) do
            for _, ch in ipairs(getChildren(char)) do
                local ok, cn = pcall(function() return ch.ClassName end)
                if ok and cn == "Tool" then return ch end
            end
        end
        return nil
    end

    -- The game's own "this is in your hand" marker: backpack.objectHelper paints
    -- the slot whose item id equals the held Tool's `link` with a WHITE UIStroke
    -- and every other slot (30,30,30), and repaints the slot when the tool is
    -- equipped and on every appraisal. UIStroke.Color is not a Matcha binding,
    -- so read the Color3 floats off the stroke itself: +208 was the only 30/255
    -- triple on it, checked live 2026-09-19. The address is taken fresh from the
    -- live stroke on each call, never cached (a stale one kills the process).
    local STROKE_COLOR = 208
    local function strokeIsWhite(slot)
        if type(memory_read) ~= "function" then return false end
        local st = findChild(slot, "UIStroke")
        if not st then return false end
        local ok, addr = pcall(function() return st.Parent and st.Address end)
        addr = ok and tonumber(addr) or nil
        if not addr or addr <= 4096 then return false end
        for i = 0, 2 do
            local okr, v = pcall(memory_read, "float", addr + STROKE_COLOR + i * 4)
            v = okr and tonumber(v) or nil
            if not v or v < 0.9 or v > 1.001 then return false end
        end
        return true
    end

    -- Tool.Name is the bare species ("Ancient Depth Serpent"); the decorated name
    -- ("Shiny Big Ancient Depth Serpent") exists only as GUI text, on a hotbar or
    -- inventory slot whose label is the species or ends in " <species>".
    local function slotLabel(slot)
        local lbl = findChild(slot, "ItemName")
        if lbl then return lbl end
        local ok, desc = pcall(function() return slot:GetDescendants() end)
        if ok and type(desc) == "table" then
            for _, d in ipairs(desc) do
                if d.Name == "ItemName" then return d end
            end
        end
        return nil
    end

    -- Which matching slot is the fish in your hand, in order:
    --   1. the one the game marks as held (white stroke), wherever it is;
    --   2. on the hotbar: a bare-species label first, else the longest decorated
    --      one (the community build's hand-only rule);
    --   3. the inventory's match, when it has exactly one.
    -- Anything else returns nil and the caller holds. The old "longest match
    -- across hotbar AND inventory" let a fancier copy you merely own stand in for
    -- the held fish; the community fix (hotbar only) goes blind to any fish not
    -- pinned there, because the hotbar is just the 9 pinned slots (decompiled
    -- client.modules.ui.Backpack), and a blind read rolls forever, re-rolling hits
    -- away. Returns name, match count, and which rule picked it.
    local function fishDisplayName(tool)
        if not tool then return nil, 0 end
        local species; pcall(function() species = tostring(tool.Name) end)
        species = species or ""
        local pg = getPlayerGui()
        local backpack = pg and findChild(pg, "backpack")
        local low  = species:lower()
        local tail = " " .. low
        local held, hotBare, hotBest, hotLen = nil, nil, nil, 0
        local invOnly, invCount, matches = nil, 0, 0
        local function scan(container, onHotbar)
            if not container then return end
            for _, slot in ipairs(getChildren(container)) do
                local lbl = slotLabel(slot)
                local ok, text = pcall(function() return lbl and lbl.Text end)
                if ok and type(text) == "string" and text ~= "" then
                    text = text:gsub("<[^>]+>", "")      -- rich-text tags would break the suffix compare
                    local t = text:lower()
                    local bare = t == low
                    if bare or (#t > #tail and t:sub(-#tail) == tail) then
                        matches = matches + 1
                        if not held and strokeIsWhite(slot) then held = text end
                        if not onHotbar then
                            invCount, invOnly = invCount + 1, text
                        elseif bare then
                            hotBare = hotBare or text
                        elseif #text > hotLen then
                            hotBest, hotLen = text, #text
                        end
                    end
                end
            end
        end
        scan(backpack and findChild(backpack, "hotbar"), true)
        local inv = backpack and findChild(backpack, "inventory")
        scan(inv and findChild(inv, "itemContainer"), false)
        if held then return held, matches, "held" end
        if hotBare or hotBest then return hotBare or hotBest, matches, "hotbar" end
        if invCount == 1 then return invOnly, matches, "inventory" end
        return nil, matches
    end

    -- Everything before the species name is a modifier by definition. Split those
    -- words into the one size word, the set of quality words, and whatever is left
    -- (the mutation, which may be multi-word).
    local function parseFishName(raw, species)
        local normRaw     = normalise(raw)
        local normSpecies = normalise(species or "")
        local prefix = normRaw
        if normSpecies ~= "" then
            if normRaw == normSpecies then
                prefix = ""
            else
                local tail = " " .. normSpecies
                if #normRaw > #tail and normRaw:sub(-#tail) == tail then
                    prefix = normRaw:sub(1, #normRaw - #tail)
                end
            end
        end
        local size, quals, restWords = nil, {}, {}
        for word in prefix:gmatch("%S+") do
            if SIZE_SET[word] then
                size = size or word
            elseif QUALITY_SET[word] then
                quals[word] = true
            else
                restWords[#restWords + 1] = word
            end
        end
        return size, quals, table.concat(restWords, " ")
    end

    -- ---- decision -----------------------------------------------------------------
    local function anySelected(t)
        for _, v in pairs(t) do if v then return true end end
        return false
    end
    -- the mutation must OPEN the leftover prefix, so "tanned" cannot match inside
    -- "super-tanned"
    local function restHasMutation(rest, key)
        return rest == key or rest:sub(1, #key + 1) == key .. " "
    end

    -- returns "click" (roll again), "stop" (keep this fish) or "hold" (do nothing),
    -- plus a human-readable reason for the Status row.
    local function evaluateFish(fish)
        local sizeWanted = anySelected(A.filters.sizes)
        local qualWanted = anySelected(A.filters.qualities)
        local mutWanted  = anySelected(A.filters.mutations)
        if not sizeWanted and not qualWanted and not mutWanted then
            return "click", "no filters selected -- rolling unconditionally"
        end
        if not fish then
            return (A.strictFilters and "hold" or "click"), "no fish equipped -- nothing to parse, " ..
                (A.strictFilters and "strict mode: holding" or "rolling anyway (tick Strict Filtering to hold instead)")
        end

        local raw, matches, via = fishDisplayName(fish)
        local species; pcall(function() species = tostring(fish.Name) end)
        species = species or ""
        if not raw then
            -- rolling a fish whose name we can't see would re-roll any hit away
            return "hold", (matches == 0 and "no slot shows '" .. species .. "'"
                or matches .. " '" .. species .. "' slots, none marked held")
                .. " -- holding; pin the fish to the hotbar"
        end
        local size, quals, rest = parseFishName(raw, species)

        local sizeOk = true
        if sizeWanted then
            sizeOk = size ~= nil and A.filters.sizes[size] == true
        end

        local qualOk = true
        if qualWanted then
            if A.requireAllQualities then
                qualOk = true
                for key, sel in pairs(A.filters.qualities) do
                    if sel and not quals[key] then qualOk = false; break end
                end
            else
                qualOk = false
                for key, sel in pairs(A.filters.qualities) do
                    if sel and quals[key] then qualOk = true; break end
                end
            end
        end

        local mutOk = true
        if mutWanted then
            mutOk = false
            for key, sel in pairs(A.filters.mutations) do
                if sel and restHasMutation(rest, key) then mutOk = true; break end
            end
        end

        local shown = { "'" .. raw .. "'" }
        if matches > 1 and via ~= "held" then
            shown[#shown + 1] = "(!" .. matches .. " slots share this species, read the " .. via .. " one)"
        end
        if sizeWanted then shown[#shown + 1] = "size=" .. tostring(size) end
        if qualWanted then
            local q = {}
            for key in pairs(quals) do q[#q + 1] = key end
            table.sort(q)
            shown[#shown + 1] = "quality=" .. (#q > 0 and table.concat(q, "+") or "nil")
                .. (A.requireAllQualities and " [need all]" or "")
        end
        if mutWanted then shown[#shown + 1] = "rest='" .. rest .. "'" end
        local hit = sizeOk and qualOk and mutOk
        return (hit and "stop" or "click"),
            table.concat(shown, " ") .. (hit and " -> HIT, stopping" or " -> no hit, rolling"), raw
    end

    -- ---- UI (added as a tab on the macro's own window; no separate window) --------
    local Tab = Window:AddTab("Appraise")

    local Setup = Tab:AddGroup("Appraise", 1)
    A.autoToggle = Setup:AddToggle({ text = "Auto Appraise", default = false, callback = function(on)
        if A.dead then return end
        A.enabled = on and true or false
        if A.enabled then A.nextClick = 0 end
    end })
    -- F4, the fixed hotkey this build has always used, is now the row's own
    -- keybind: rebindable, and polled by UILib, so F-keys work.
    A.autoToggle:AddKeybind({ flag = "appraise_key", default = "F4" })
    Setup:AddSlider({ text = "Click interval", flag = "appraise_delay", default = A.delay,
        step = 0.05, min = 0.1, max = 3, suffix = "s", callback = function(v) A.delay = v end })
    Setup:AddSlider({ text = "Press hold", flag = "appraise_hold", default = A.pressHold,
        step = 0.01, min = 0.03, max = 0.3, suffix = "s", callback = function(v) A.pressHold = v end,
        tooltip = "How long the click stays down. Below ~0.04s Roblox tends to drop it -- raise this if clicks stop registering." })

    local StatusSec = Tab:AddGroup("Status", 2)
    A.lblStatus = StatusSec:AddLabel({ text = "Status: idle" })
    A.lblCount  = StatusSec:AddLabel({ text = "Clicks this session: 0" })

    local MutSec = Tab:AddGroup("Mutations", 2)
    -- The dropdown is the ONLY source of mutation filters. It used to OR every
    -- name ever saved with Save Mutation back in on each change, so an old custom
    -- filter stayed live for good and a new fish could roll straight past its hit.
    -- Save Mutation now adds its name to this list and ticks it here instead.
    A.mutDrop = MutSec:AddDropdown({ text = "Mutations", flag = "appraise_mutations", values = MUTATIONS,
        multi = true, default = {}, callback = function(v)
        local picked = {}
        if type(v) == "table" then
            for value, on in pairs(v) do   -- a multi dropdown's value is a set: name -> true
                if on then picked[normalise(value)] = true end
            end
        end
        A.filters.mutations = picked
    end })

    local SizeSec = Tab:AddGroup("Size", 1)
    for _, name in ipairs(SIZES) do
        local key = name:lower()
        A.filterRows[#A.filterRows + 1] = SizeSec:AddToggle({ text = name, flag = "appraise_size_" .. key,
            default = false, callback = function(on) A.filters.sizes[key] = on end })
    end

    local QualSec = Tab:AddGroup("Quality", 2)
    for _, name in ipairs(QUALITIES) do
        local key = name:lower()
        A.filterRows[#A.filterRows + 1] = QualSec:AddToggle({ text = name, flag = "appraise_quality_" .. key,
            default = false, callback = function(on) A.filters.qualities[key] = on end })
    end

    local AdvSec = Tab:AddGroup("Advanced", 1)
    AdvSec:AddToggle({ text = "Strict Filtering", flag = "appraise_strict", default = false,
        callback = function(on) A.strictFilters = on end,
        tooltip = "Only affects the case where no fish is equipped at all. Off = click anyway (default). On = hold until a fish is in hand." })
    A.customBox = AdvSec:AddTextbox({ text = "Custom mutation name", default = "" })
    AdvSec:AddButton({ text = "Save Mutation", callback = function()
        local val = (tostring(A.customBox:Get() or ""):gsub("^%s*(.-)%s*$", "%1"))
        if val == "" then return end
        local key, listed = normalise(val), false
        for _, m in ipairs(MUTATIONS) do
            if normalise(m) == key then val, listed = m, true; break end
        end
        if not listed then
            MUTATIONS[#MUTATIONS + 1] = val
            A.mutDrop:SetValues(MUTATIONS)
        end
        local pick = {}
        for k, on in pairs(A.mutDrop:Get() or {}) do pick[k] = on end
        pick[val] = true
        A.mutDrop:Set(pick)                 -- its callback rebuilds A.filters.mutations
        pcall(function() Library:Notify({ title = "Saved", text = val, duration = 2 }) end)
    end })

    local StopSec = Tab:AddGroup("Stop", 1)
    StopSec:AddButton({ text = "Reset filters", callback = function()
        -- through the widgets, so the rows untick and the settings file forgets them
        for _, row in ipairs(A.filterRows) do pcall(function() row:Set(false) end) end
        pcall(function() A.mutDrop:Set({}) end)
        pcall(function() A.customBox:Set("") end)
        A.filters.sizes, A.filters.qualities, A.filters.mutations = {}, {}, {}
        pcall(function() Library:Notify({ title = "Appraise", text = "Filters cleared.", duration = 2 }) end)
    end })
    StopSec:AddButton({ text = "Stop", callback = function()
        A.enabled = false
        pcall(function() A.autoToggle:Set(false) end)
    end })

    local function setLabel(el, key, txt)
        if A[key] == txt then return end
        A[key] = txt
        pcall(function() el:SetText(txt) end)
    end

    -- ---- driver -------------------------------------------------------------------
    -- Heartbeat, not RenderStepped: every branch here is gated on elapsed time, so
    -- the carrier rate buys nothing, and a slower signal can only ever OVERSHOOT
    -- the press-hold window -- the safe direction, since a too-short click is the
    -- one Roblox drops. A spawned while-loop would be wrong here: those die
    -- unannounced under Matcha, which is why the old tab needed a revive clock.
    A.conns[#A.conns + 1] = RunService.Heartbeat:Connect(function()
        if A.dead then return end
        local now = tick()

        if now - (A._uiAt or 0) >= 0.2 then
            A._uiAt = now
            setLabel(A.lblStatus, "_s1", "Status: " .. trunc(A.status, 44))
            setLabel(A.lblCount,  "_s2", "Clicks this session: " .. A.count)
        end

        -- release leg: always runs, even after the toggle goes off, so the button
        -- can never be left stuck down
        if A.held then
            if now - A.pressedAt >= A.pressHold then
                pcall(mouse1release)
                A.held = false
                A.nextClick = now + A.delay
            end
            return
        end

        if not A.enabled then return end
        if now < A.nextClick then return end
        if not robloxActive() then return end   -- kept from this file: no blind clicks while alt-tabbed

        local ok, err = pcall(function()
            local action, reason, raw = evaluateFish(getCurrentFish())
            -- A roll's result can land late on a laggy server. While the name still
            -- reads what it did before the last click, give that click until
            -- A.settle to show its result, so a late hit is read instead of rolled away.
            if action == "click" and raw and raw == A.lastRaw and now < A.pressedAt + A.settle then
                A.status = reason .. " (waiting for the last roll to show)"
                A.nextClick = now + 0.05
                return
            end
            A.status = reason
            if action == "click" then
                A.lastRaw = raw
                mouse1press()
                A.held = true
                A.pressedAt = now
                A.count = A.count + 1
            elseif action == "stop" then
                A.enabled = false
                A.status = reason .. " (auto appraise off after " .. A.count .. " rolls)"
                print("[Appraise] HIT after " .. A.count .. " rolls -- " .. reason)
                pcall(function() A.autoToggle:Set(false) end)
                pcall(function() Library:Notify({ title = "Got it", text = reason, duration = 8 }) end)
                pcall(function() notify("Got it after " .. A.count .. " appraises.", "", 8) end)
            else
                A.nextClick = now + A.delay
            end
        end)
        if not ok then
            A.status = "error: " .. tostring(err)
            A.enabled = false
            if A.held then pcall(mouse1release); A.held = false end
        end
    end)
end

if Library then
    Window = Library:CreateWindow({
        id = "fisch_macro", title = "FISCH  /  MACRO", subtitle = "OCEAN",
        size = { 960, 630 }, toggleKey = "P",
        config = "fisch_macro.json",
        -- The engine's own clicks must never land on the menu, and while it
        -- fishes its input has to reach the game even under the cursor.
        inputGuard = function() local _, held = ENG.probe(); return held end,
        captureInput = function() return not State.running end,
        onUnload = function()   -- Settings > Unload menu
            pcall(function() setRunning(false) end)
            pcall(function() IR.setEnabled(false) end)
            pcall(function() FM.unload() end)
        end,
    })
    FM.lib = Window   -- so a re-run (or FM.unload) removes this window instead of stacking a second one

    -- Every widget takes one table. Sliders take a STEP, so round -> step
    -- (10^-round). Callbacks write CONFIG the same as before; the flag is the
    -- key the settings file stores the value under.
    local function bindToggle(sec, key, title, fn)
        return sec:AddToggle({ text = title, flag = key, default = CONFIG[key], callback = function(v)
            CONFIG[key] = v; if fn then fn(v) end
        end })
    end
    local function bindSlider(sec, key, title, min, max, round, fn)
        return sec:AddSlider({ text = title, flag = key, default = CONFIG[key],
            step = 10 ^ -(round or 0), min = min, max = max, callback = function(v)
            CONFIG[key] = v; if fn then fn(v) end
        end })
    end

    -- Same two helpers, but writing into the transplanted engine's own config
    -- and tuning tables rather than this file's CONFIG.
    local function engToggle(sec, key, title, fn)
        return sec:AddToggle({ text = title, flag = "eng_" .. key, default = ENG.CONFIG[key], callback = function(v)
            ENG.CONFIG[key] = v; if fn then fn(v) end
        end })
    end
    local function engSlider(sec, key, title, min, max, round, fn)
        return sec:AddSlider({ text = title, flag = "eng_" .. key, default = ENG.CONFIG[key],
            step = 10 ^ -(round or 0), min = min, max = max, callback = function(v)
            ENG.CONFIG[key] = v; if fn then fn(v) end
        end })
    end
    local function tuneSlider(sec, key, title, min, max, round)
        return sec:AddSlider({ text = title, flag = "tune_" .. key, default = ENG.TUNING[key],
            step = 10 ^ -(round or 0), min = min, max = max, callback = function(v)
            ENG.TUNING[key] = v
        end })
    end

    -- ---- Main ----------------------------------------------------------------
    local MainTab = Window:AddTab("Main")
    local Status = MainTab:AddGroup("Status", 1)
    local statusLine = Status:AddLabel({ text = "idle" })

    local Macro = MainTab:AddGroup("Macro", 1)
    autoToggle = Macro:AddToggle({ text = "Auto Fish", default = false, callback = function(v)
        if not _settingToggle then setRunning(v) end
    end })
    -- The row's keybind: UILib polls the key itself (F-keys included) and flips
    -- the row, which runs setRunning through the callback above -- one actor,
    -- whichever key is bound. Right-click it for hold mode.
    autoToggle:AddKeybind({ flag = "autofish_key", default = "F1", notify = false })   -- setRunning announces it
    Macro:AddButton({ text = "Reset counters", callback = function()
        State.caught = 0; State.lost = 0; State.timeouts = 0; State.recoveries = 0
    end })

    -- The manual assists are gone with the old engine. The new one joins whatever
    -- is already on screen when you switch it on, which is what they were for.
    local Mode = MainTab:AddGroup("Mode", 2)
    Mode:AddDropdown({ text = "Mode", flag = "eng_mode", values = { "Rod", "Spear", "Gun" },
        default = ENG.modeLabel(ENG.CONFIG.mode),
        callback = function(v)
            local pick = tostring(v or "Rod"):lower()
            for i, name in ipairs(ENG.MODES) do
                if name == pick then
                    -- setMode turns the macro off first; syncRunState catches the
                    -- toggle up on the next slow tick.
                    pcall(ENG.setMode, i)
                    break
                end
            end
        end })
    engToggle(Mode, "dualReel", "Dual reel")
    engToggle(Mode, "swapReelButtons", "Swap which reel gets which button")

    -- ---- Cast ----------------------------------------------------------------
    local CastTab = Window:AddTab("Cast")
    local C = CastTab:AddGroup("Casting", 1)
    engSlider(C, "castPower", "Release cast at power %", 1, 100, 1)
    engSlider(C, "castTimeoutMs", "Cast charge timeout (ms)", 1000, 30000)
    engSlider(C, "castLandTimeoutMs", "Wait for shake prompt (ms)", 1000, 20000)
    engToggle(C, "castOnTimeout", "Recast on timeout")
    engSlider(C, "castRepressMs", "Re-arm cast if no bar by (ms)", 40, 1000)
    engSlider(C, "postCastDelayMs", "Post-cast delay (ms)", 0, 1000)
    engSlider(C, "postCatchDelayMs", "Post-catch delay (ms)", 0, 5000)
    engSlider(C, "postLostDelayMs", "Post-lost delay (ms)", 0, 3000)
    engSlider(C, "shakeIntervalMs", "Shake interval (ms)", 5, 200)
    engSlider(C, "shakeTimeoutMs", "Give up on shake after (ms)", 3000, 60000)

    local Eq = CastTab:AddGroup("Equip", 2)
    Eq:AddTextbox({ text = "Rod hotbar key", flag = "eng_equipKey", default = tostring(ENG.CONFIG.equipKey),
        maxLength = 1, callback = function(t)
        t = tostring(t or ""):gsub("%s", "")
        if t ~= "" then ENG.CONFIG.equipKey = t:sub(1, 1):upper() end
    end })
    engSlider(Eq, "equipAttempts", "Equip attempts", 1, 10)
    engSlider(Eq, "equipVerifyMs", "Verify press after (ms)", 50, 1000)
    engSlider(Eq, "equipSettleMs", "Equip deadline (ms)", 500, 15000)
    engToggle(Eq, "reequipOnDeadCast", "Re-equip if the first cast produces no bar")

    local Wd = CastTab:AddGroup("Stall recovery", 2)
    engSlider(Wd, "stuckTimeoutMs", "Force a restart after (ms)", 10000, 180000)
    engSlider(Wd, "reelStallMs", "Rediscover a frozen reel after (ms)", 500, 15000)

    -- ---- Reel ----------------------------------------------------------------
    -- These are the hybrid controller's gains, not the old PWM engine's. Kp is
    -- deliberately high: it is meant to saturate into bang-bang off target, with
    -- the delta-sigma slot doing the fine work near it.
    local ReelTab = Window:AddTab("Reel")
    local P = ReelTab:AddGroup("Hybrid controller tuning", 1)
    tuneSlider(P, "Kp", "Kp (proportional)", 0, 400, 0)
    tuneSlider(P, "Ki", "Ki (integral)", 0, 20, 2)
    tuneSlider(P, "Kd", "Kd (derivative)", 0, 20, 2)
    tuneSlider(P, "IntegralClamp", "Integral clamp (duty)", 0, 1, 2)
    tuneSlider(P, "EdgeBoundary", "Edge boundary", 0, 0.3, 3)
    tuneSlider(P, "MinDwellS", "Min press/release (s)", 0, 0.1, 3)
    local Q = ReelTab:AddGroup("Estimator", 2)
    tuneSlider(Q, "BarVelTauS", "Bar velocity tau (s)", 0.002, 0.1, 3)
    tuneSlider(Q, "FishVelTauS", "Fish velocity tau (s)", 0.002, 0.1, 3)
    tuneSlider(Q, "MaxVelocity", "Velocity clamp (tracks/s)", 0.5, 10, 1)
    tuneSlider(Q, "HoldAccel", "Assumed accel held", 0, 2, 2)
    tuneSlider(Q, "DropAccel", "Assumed accel released", 0, 2, 2)
    local Det = ReelTab:AddGroup("Catch detection", 2)
    engSlider(Det, "completionThreshold", "Count as caught at progress % >=", 50, 100, 1)

    -- ---- Minigames -------------------------------------------------------------
    local MGTab = Window:AddTab("Minigames")
    local NK = MGTab:AddGroup("Nuke", 1)
    engSlider(NK, "nukeDeadzoneFrac", "Deadzone (fraction of range)", 0, 0.4, 2)
    engSlider(NK, "nukeTapIntervalMs", "Tap interval (ms)", 10, 300)
    engSlider(NK, "nukeTapHoldMs", "Tap hold (ms)", 5, 200)
    engSlider(NK, "nukePrediction", "Prediction strength", 0, 40, 1)
    engSlider(NK, "nukeTimeoutMs", "Give up after (ms)", 5000, 120000)

    local SP = MGTab:AddGroup("Spear", 2)
    engSlider(SP, "stabIntervalMs", "Click interval (ms)", 0, 300)
    engSlider(SP, "stabHoldMs", "Click hold (ms)", 0, 200)
    engToggle(SP, "stabStartRight", "Start on right click")
    engSlider(SP, "stabTimeoutMs", "Give up after (ms)", 5000, 120000)

    local GN = MGTab:AddGroup("Gun", 2)
    engSlider(GN, "gunDelayMs", "Min gap between clicks (ms)", 0, 500)
    engSlider(GN, "gunSettleMs", "Settle after aiming (ms)", 0, 300)
    engSlider(GN, "gunHoldMs", "Click hold (ms)", 5, 200)
    engSlider(GN, "gunRearmMs", "Ignore a clicked popup for (ms)", 0, 1000)
    engSlider(GN, "gunMaxFixes", "Cursor calibration attempts", 0, 10)

    -- ---- Value changer ---------------------------------------------------------
    local VTab = Window:AddTab("Value changer")
    local IRs = VTab:AddGroup("Instant reel", 1)
    IRs:AddToggle({ text = "Enable instant reel", default = false, badge = "!",
        callback = function(v) IR.setEnabled(v) end })
    bindSlider(IRs, "instant_reel_speed", "Instant reel speed", 1, 500)

    -- ---- ESP -------------------------------------------------------------------
    local ETab = Window:AddTab("ESP")
    local W = ETab:AddGroup("Waypoints", 1)
    W:AddToggle({ text = "Show waypoints", default = CONFIG.wp_show_on_load, callback = function(v)
        if v then WP.show() else WP.hide() end
    end })
    bindToggle(W, "wp_include_fishing", "Include fishing spots", function() WP.rescan() end)
    bindToggle(W, "wp_show_distance", "Show distance")
    bindSlider(W, "wp_square_size", "Square size (px)", 2, 24)
    bindSlider(W, "wp_text_size", "Text size", 8, 28)
    bindSlider(W, "wp_max_distance", "Max distance (0 = all)", 0, 5000)

    -- ---- Treasure --------------------------------------------------------------
    do   -- block-scoped so the registers free at `end` (200-local budget)
        local TRTab = Window:AddTab("Treasure")
        local TC = TRTab:AddGroup("Treasure chest ESP", 1)
        TC:AddToggle({ text = "Show treasure chests", default = CONFIG.chest_show_on_load, callback = function(v)
            if v then CHEST.show() else CHEST.hide() end
        end })
        bindToggle(TC, "chest_show_distance", "Show distance")
        bindSlider(TC, "chest_square_size", "Square size (px)", 2, 24)
        bindSlider(TC, "chest_text_size", "Text size", 8, 28)
        bindSlider(TC, "chest_max_distance", "Max distance (0 = all)", 0, 5000)
        local TT = TRTab:AddGroup("Chest teleport", 2)
        TT:AddButton({ text = "Teleport to nearest chest", callback = function() CHEST.tpNearest() end })
        TT:AddButton({ text = "Teleport to next chest", callback = function() CHEST.tpNext() end })
        TT:AddButton({ text = "Collect all chests", callback = function() CHEST.runStart() end })
        TT:AddButton({ text = "Stop chest run", callback = function() CHEST.runStop() end })
    end

    -- ---- Appraiser tab (auto appraise); built here so it sits above Teleport ----
    pcall(fischAppraiser)

    -- ---- Teleport ------------------------------------------------------------
    do
        local TPTab = Window:AddTab("Teleport")
        local T = TPTab:AddGroup("Go to a location", 1)
        local query = ""
        local matchLine = T:AddLabel({ text = "Match: -" })
        local function refreshMatch()
            local m = TP.matchName(query)
            pcall(function() matchLine:SetText("Match: " .. (m or ("no match for '" .. query .. "'"))) end)
            return m
        end
        T:AddTextbox({ text = "Search location", default = "", live = true,
            callback = function(t) query = t or ""; refreshMatch() end })
        T:AddButton({ text = "Instant teleport to match", callback = function() local m = refreshMatch(); if m then TP.to(m) end end })
        T:AddButton({ text = "List all", callback = function() TP.list() end })

        -- Points of interest: same picker, pointed at TP.poi. Its state lives in
        -- one table so the section costs a single local.
        local POI = { query = "", sec = TPTab:AddGroup("Go to a point of interest", 1) }
        POI.line = POI.sec:AddLabel({ text = "Match: -" })
        function POI.refresh()
            local m = TP.matchName(POI.query, TP.poi)
            pcall(function() POI.line:SetText("Match: " .. (m or ("no match for '" .. POI.query .. "'"))) end)
            return m
        end
        POI.sec:AddTextbox({ text = "Search point of interest", default = "", live = true,
            callback = function(t) POI.query = t or ""; POI.refresh() end })
        POI.sec:AddButton({ text = "Instant teleport to match", callback = function() local m = POI.refresh(); if m then TP.to(m, TP.poi) end end })
        POI.sec:AddButton({ text = "List all", callback = function() TP.list(TP.poi, "points of interest") end })

        -- Coordinates: the textbox can't be pasted into (Matcha has no clipboard
        -- read), so "Copy My Position" writes the current spot back into the box
        -- to read off, and the parser below accepts anything with three numbers
        -- in it ("x: 1, y: 2, z: 3", "1 2 3", "-4360, -11170, 3710").
        local C = TPTab:AddGroup("Coordinates", 2)
        local coordText = ""
        local coordBox = C:AddTextbox({ text = "Coordinates", default = "", live = true,
            callback = function(v) coordText = v or "" end })
        C:AddButton({ text = "Copy My Position", callback = function()
            local pos = selfPos()
            if not pos then warn("No HumanoidRootPart"); return end
            local s = string.format("%.2f, %.2f, %.2f", pos.X, pos.Y, pos.Z)
            coordText = s
            pcall(function() coordBox:Set(s) end)
        end })
        C:AddButton({ text = "Teleport to coordinates", callback = function()
            local txt = tostring(coordText or "")
            txt = txt:gsub("[Xx]:", ""):gsub("[Yy]:", ""):gsub("[Zz]:", ""):gsub(",", " ")
            local nums = {}
            for n in txt:gmatch("%-?%d+%.?%d*") do nums[#nums + 1] = tonumber(n) end
            if #nums < 3 then warn("Bad coords: " .. txt); return end
            TP.toPos(nums[1], nums[2], nums[3])
        end })
    end

    -- ---- Rods ----------------------------------------------------------------
    do
        local RodTab = Window:AddTab("Rods")
        local R = RodTab:AddGroup("Find a rod", 1)
        local rodQuery = ""
        local rodLine = R:AddLabel({ text = "Match: -" })
        local function refreshRod()
            local e = Rod.match(rodQuery)
            pcall(function()
                rodLine:SetText(e and Rod.describe(e) or ("no match for '" .. rodQuery .. "'"))
            end)
            return e
        end
        R:AddTextbox({ text = "Search rod", default = "", live = true,
            callback = function(t) rodQuery = t or ""; refreshRod() end })
        R:AddButton({ text = "Instant teleport to rod", callback = function() local e = refreshRod(); if e then Rod.teleport(e) end end })
    end

    -- ---- Webhook -------------------------------------------------------------
    local WHTab = Window:AddTab("Webhook")
    local WH = WHTab:AddGroup("Discord webhook", 1)
    local urlInput = WH:AddTextbox({ text = "Your webhook URL", default = CONFIG.webhook_url,
        callback = function(t) CONFIG.webhook_url = t or "" end })
    WH:AddButton({ text = "Reload URL from webhook_url.txt", callback = function()
        local u = loadWebhookUrl()
        if u ~= "" then
            pcall(function() urlInput:Set(u) end)   -- fires the callback -> CONFIG
        else
            notify("webhook_url.txt is empty. Paste your webhook URL into it first.", "", 5)
        end
    end })
    bindToggle(WH, "webhook_enabled", "Enable webhook")
    bindToggle(WH, "webhook_on_start", "Send startup message")
    bindToggle(WH, "webhook_stats", "Send periodic stats")
    bindSlider(WH, "webhook_interval_s", "Stats interval (sec)", 30, 3600)
    WH:AddButton({ text = "Send test stats now", callback = function() WEBHOOK.sendAsync(WEBHOOK.stats()) end })

    -- ---- Settings (built-in: theme / fonts / configs / menu key) -------------
    -- Unload runs the window's onUnload above: macro off, instant reel off, then
    -- FM.unload (heartbeat, mouse, drawings, this window).
    local SetTab = Window:AddSettingsTab("settings", { unload = false })
    SetTab:AddGroup("Macro", 2):AddButton({ text = "Unload menu", badge = "!", confirm = true,
        tooltip = "Remove the menu and stop the macro?",
        callback = function() Window:Unload() end })

    -- restore last session's settings, then re-assert the file webhook URL (a
    -- saved value could otherwise replay an empty webhook_url over the file).
    pcall(function() Window:LoadSettings() end)
    do
        local u = loadWebhookUrl()
        if u ~= "" then pcall(function() urlInput:Set(u) end) end
    end

    -- Live status readout. Driven from the frame scheduler rather than a spawned
    -- loop: spawned loops here die silently, and a dead one freezes the panel on
    -- a stale line that reads like the macro itself has hung.
    local _statusAt = 0
    FM.statusTick = function()
        if not Window or FM.dead then return end
        if tick() - _statusAt < 0.1 then return end
        _statusAt = tick()
        pcall(function()
            -- Skip while the menu is closed; the first tick after it opens
            -- catches the line up. And only redraw when the text actually changed.
            if not Window:IsVisible() then return end
            local lbl = State.running and "auto fishing" or "idle"
            local text = string.format(
                "%s | %s\nRod: %s\nCaught: %d   Lost: %d   Timeouts: %d   Recover: %d",
                lbl, currentStatus(), State.rod ~= "" and State.rod or "none",
                State.caught, State.lost, State.timeouts, State.recoveries)
            if text == FM.statusText then return end
            statusLine:SetText(text)
            FM.statusText = text   -- after the call, so a throwing SetText retries next tick
        end)
    end
end

-- ============================================================================
-- Main heartbeat
-- ============================================================================
if CONFIG.wp_show_on_load then pcall(WP.show) end
if CONFIG.chest_show_on_load then pcall(CHEST.show) end
if CONFIG.autostart then setRunning(true) end

-- One fixed-cadence step of the macro. Everything timing-critical lives here and
-- is guaranteed to be called at macro_tick_hz regardless of how fast (or how
-- erratically) the underlying frame signal fires.
-- Host-side periodic work only. The fishing engine is NOT driven from here: it
-- paces itself off the raw carrier (see below), because its steering wants every
-- frame it can get (REFRESH.steer = 3ms) while its phase logic wants 8ms, and
-- those gates are part of its tuning.
local function macroStep(dt)
    -- The Auto Fish key is the menu row's own keybind (UILib polls it). Only a
    -- console-only run, with no row to bind, polls the fixed F1 here, at the 60Hz
    -- step so a quick tap can't fall between two samples.
    if not autoToggle and hotkeyEdge(HOTKEYS.autofishFallback) then
        setRunning(not State.running)
    end
    antiAfkTick()                 -- idle-kick guard (no-op while fishing)
    pcall(IR.step)                -- instant-reel session watcher
    pcall(CHEST.runStep)          -- chest-collection run
end

-- The engine can turn itself off (setMode does, and so does a failed equip), so
-- the host's mirror and the menu toggle follow it rather than the other way up.
local function syncRunState()
    local live = ENG.isEnabled()
    if live == State.running then return end
    State.running = live
    if autoToggle and not _settingToggle then
        _settingToggle = true
        pcall(function() autoToggle:Set(live) end)
        _settingToggle = false
    end
end

-- Rod name for the webhook and status line. The engine only cares whether a rod
-- IS held, not
-- what it is called, so the name is read here.
local function refreshRodName()
    local name = ""
    for _, char in ipairs(getCharacterModels()) do
        for _, ch in ipairs(getChildren(char)) do
            local ok, cn = pcall(function() return ch.ClassName end)
            if ok and cn == "Tool" then name = tostring(ch.Name); break end
        end
        if name ~= "" then break end
    end
    State.rod = name
end

-- Housekeeping: display/network work that must NOT run at the control rate.
local function slowStep()
    syncRunState()
    -- The rod name only feeds the status line and the webhook, and a character walk (a
    -- Workspace lookup plus a ClassName read per child) was costing ~25ms a second here.
    if tick() - (FM.rodAt or 0) >= 1 then
        FM.rodAt = tick()
        pcall(refreshRodName)
    end
    pcall(WEBHOOK.maybeStartup)
    pcall(WEBHOOK.statsTick)
    if FM.statusTick then pcall(FM.statusTick) end            -- menu status line
end

-- RenderStepped is the carrier (measured ~1500/s here, vs Heartbeat's 57/s),
-- but NOTHING runs at the carrier rate: a fixed-step accumulator drives the
-- macro at macro_tick_hz and a plain time gate drives the housekeeping at 20Hz.
-- The catch-up ceiling stops a frame hitch from turning into a burst of steps.
do
    local step      = 1.0 / math.max(1, tonumber(CONFIG.macro_tick_hz) or 60)
    local maxCatch  = math.max(1, tonumber(CONFIG.macro_max_catchup) or 3)
    local acc, last = 0.0, tick()
    local slowAt    = 0.0

    -- Spear and gun fights act wherever the cursor happens to be, and a menu
    -- under the cursor would catch those clicks (INS-ui also cut game input
    -- there; UILib leaves it on while the macro runs). So the menu is hidden
    -- for the fight and reopened after it (unless reopened by hand meanwhile).
    local hidMenuForFight = false
    local function menuFightGuard()
        local mode = ENG.CONFIG.mode
        local fighting = false
        if (mode == "spear" or mode == "gun") and ENG.isEnabled() then
            local pg = getPlayerGui()
            local name = mode == "spear" and ENG.CONFIG.stabGuiName or ENG.CONFIG.gunGuiName
            fighting = pg ~= nil and findChild(pg, name) ~= nil
        end
        if fighting then
            if not hidMenuForFight and Window and Window:IsVisible() then
                Window:SetVisible(false)
                hidMenuForFight = true
            end
        elseif hidMenuForFight then
            hidMenuForFight = false
            if Window and not Window:IsVisible() then Window:SetVisible(true) end
        end
    end

    FM.track(RunService.RenderStepped:Connect(function()
        if FM.dead then return end

        -- The engine first, ungated: fastBody is built to be called from the raw
        -- frame signal and does its own pacing (3ms steering, 8ms phase logic).
        -- Putting it behind this file's 60Hz accumulator would throw away the
        -- steering resolution the hybrid controller is tuned for.
        pcall(ENG.fastBody)

        local now   = tick()
        local frame = now - last
        last = now
        if frame < 0 or frame > 1.0 then frame = step end   -- clock jump / long stall

        acc = acc + frame
        local n = 0
        while acc >= step and n < maxCatch do
            acc = acc - step
            n = n + 1
            macroStep(step)
        end
        if acc > step * maxCatch then acc = 0 end   -- fell too far behind: drop the debt

        if now - slowAt >= 0.05 then
            slowAt = now
            slowStep()
            pcall(menuFightGuard)
        end
    end))
end

notify(Library and "Loaded. F1 toggles Auto Fish."
    or "Loaded, but the UI failed to load (console only).", "", 4)
