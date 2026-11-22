-- Baggler log: persistent, deduplicated logging, safe-call wrappers, a circuit
-- breaker against error spam, diagnostics, and a copy-friendly report window.
--
-- Everything is kept in BagglerDB.log (saved between sessions) so a problem can be
-- diagnosed after the fact: /baggler report, or read the SavedVariables file.
local ADDON, CB = ...

local MAX_LOG = 200          -- entries kept
local FORWARD_EVERY = 30     -- seconds between forwarding the same error to the global handler
local BREAKER_COUNT = 8      -- errors from one context ...
local BREAKER_WINDOW = 10    -- ... within this many seconds trips the breaker
local BREAKER_COOLDOWN = 20  -- seconds a tripped context stays muted

local LEVELS = { E = 1, W = 2, I = 3, D = 4 }
local COLORS = { E = "ff6a6a", W = "ffb84a", I = "9ecbff", D = "8a8a96" }

CB.debugMode = false
CB.errorCount = 0
local sessionStart = (GetTime and GetTime()) or 0
local recent = {}            -- ctx -> { n, t0, mutedUntil }
local forwarded = {}         -- key -> last forward time

local function now() return (GetTime and GetTime()) or 0 end
local function stamp()
  if date then return date("%Y-%m-%d %H:%M:%S") end
  return tostring(time and time() or 0)
end

local function store()
  if not CB.db then return nil end
  CB.db.log = CB.db.log or {}
  return CB.db.log
end

-- Entries logged before the DB exists (very early errors) wait here.
local early = {}

-- Appends to the saved log. Entries written before the saved variables exist wait in `early`,
-- and an entry identical to the previous one only raises its repeat count.
local function push(entry)
  local log = store()
  if not log then early[#early + 1] = entry; return end
  if #early > 0 then
    for _, e in ipairs(early) do log[#log + 1] = e end
    early = {}
  end
  local last = log[#log]
  if last and last.level == entry.level and last.ctx == entry.ctx and last.msg == entry.msg then
    last.count = (last.count or 1) + 1
    last.last = entry.time
  else
    log[#log + 1] = entry
  end
  while #log > MAX_LOG do table.remove(log, 1) end
end

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------
--- level: "E" error, "W" warning, "I" info, "D" debug (only kept in debug mode)
function CB:Log(level, ctx, msg, stack)
  if level == "D" and not CB.debugMode then return end
  msg = tostring(msg)
  push({ time = stamp(), level = level, ctx = ctx or "?", msg = msg, stack = stack, count = 1,
         session = CB.sessionID })
  if level == "E" then CB.errorCount = CB.errorCount + 1 end
  if CB.debugMode and level ~= "E" then
    print((CB.HEX.brand .. "Baggler|r |cff%s[%s]|r %s: %s"):format(COLORS[level] or "ffffff", level, ctx or "?", msg))
  end
end

function CB:Debug(ctx, ...)
  if not CB.debugMode then return end
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  CB:Log("D", ctx, table.concat(parts, " "))
end
function CB:Warn(ctx, msg) CB:Log("W", ctx, msg) end
function CB:Info(ctx, msg) CB:Log("I", ctx, msg) end

--- A second, small log for the things worth keeping when the ordinary log is flooded by the pad trace
--- (window switches, hand-offs, how the bags were asked to open). /baggler journal prints it; it is saved with the settings.
function CB:Journal(ctx, msg)
  if not CB.db then return end
  local j = CB.db.journal
  if not j then j = {}; CB.db.journal = j end
  j[#j + 1] = ("%s [%s] %s"):format(date and date("%H:%M:%S") or "?", ctx, tostring(msg))
  while #j > 150 do table.remove(j, 1) end
end

--- Like Journal, but only while /baggler debug is on: detail that helps when chasing a problem and is noise otherwise.
function CB:JournalDebug(ctx, msg)
  if CB.debugMode then CB:Journal(ctx, msg) end
end

local function traceback(e)
  local stack
  if debugstack then stack = debugstack(3, 14, 6) end
  return { msg = tostring(e), stack = stack or (debug and debug.traceback and debug.traceback("", 3)) or "" }
end

--- Records an error and (rate-limited) forwards it to the global error handler
--- so BugGrabber/BugSack still sees it.
function CB:Error(ctx, err)
  local info = type(err) == "table" and err.msg and err or traceback(err)
  CB:Log("E", ctx, info.msg, info.stack)
  local key = ctx .. "|" .. info.msg
  local t = now()
  if not forwarded[key] or t - forwarded[key] > FORWARD_EVERY then
    forwarded[key] = t
    local h = geterrorhandler and geterrorhandler()
    if h then pcall(h, ("Baggler [%s]: %s\n%s"):format(ctx, info.msg, info.stack or "")) end
  end
end

---------------------------------------------------------------------------
-- Safe calls
---------------------------------------------------------------------------
local function breakerAllows(ctx)
  local r = recent[ctx]
  local t = now()
  if r and r.mutedUntil and t < r.mutedUntil then return false end
  return true
end

-- Circuit breaker per context: too many errors in a short window mute that context for a
-- cooldown, so one broken feature cannot flood the log.
local function breakerRecord(ctx)
  local t = now()
  local r = recent[ctx]
  if not r or t - r.t0 > BREAKER_WINDOW then
    r = { n = 0, t0 = t }
    recent[ctx] = r
  end
  r.n = r.n + 1
  if r.n >= BREAKER_COUNT then
    r.mutedUntil = t + BREAKER_COOLDOWN
    r.n = 0
    CB:Log("W", ctx, ("too many errors (%d in %ds) - muted for %ds"):format(BREAKER_COUNT, BREAKER_WINDOW, BREAKER_COOLDOWN))
    return true
  end
  return false
end

-- Error handling, one rule per case:
--   * a game call that may not exist or may refuse on this client      -> pcall, then carry on without the feature;
--   * our own event handlers, hooks, timers and window callbacks       -> CB:Safe(ctx, fn, ...), which logs with context;
--   * a whole visit or window build that must clean up after a failure -> pcall around the body, then undo and CB:Error.
-- A bare pcall around our own code that throws the error away is a bug: nobody would ever see it.

--- Runs fn(...) protected. Returns ok, ... like pcall. Errors are logged with context.
function CB:Safe(ctx, fn, ...)
  if not breakerAllows(ctx) then return false end
  local res = { xpcall(fn, traceback, ...) }
  if res[1] then return unpack(res) end
  CB:Error(ctx, res[2])
  breakerRecord(ctx)
  return false, res[2]
end

--- Returns a function that runs fn protected under `ctx` (for script handlers).
function CB:Wrap(ctx, fn)
  return function(...)
    if not breakerAllows(ctx) then return end
    local ok, a, b, c, d = xpcall(fn, traceback, ...)
    if ok then return a, b, c, d end
    CB:Error(ctx, a)
    breakerRecord(ctx)
  end
end

---------------------------------------------------------------------------
-- Frame factory: every script handler set on a Baggler frame is wrapped, so a bug
-- in one handler is logged with context instead of breaking the whole add-on.
-- (Never use this for Blizzard's secure item buttons.)
---------------------------------------------------------------------------
function CB.NewFrame(ftype, name, parent, template)
  local f = CreateFrame(ftype, name, parent, template)
  local rawSet, rawHook = f.SetScript, f.HookScript
  local label = name or ("frame@" .. tostring(ftype))
  f.SetScript = function(self, script, fn)
    if type(fn) == "function" then fn = CB:Wrap(label .. ":" .. script, fn) end
    return rawSet(self, script, fn)
  end
  f.HookScript = function(self, script, fn)
    if type(fn) == "function" then fn = CB:Wrap(label .. ":" .. script, fn) end
    return rawHook(self, script, fn)
  end
  return f
end

-- Uncaught Lua errors are observed through BugGrabber's supported callback
-- below. Never replace the global error handler or hook native callbacks.

---------------------------------------------------------------------------
-- Diagnostics
---------------------------------------------------------------------------
local function has(v) return v ~= nil and "yes" or "NO" end

-- One line per game API Baggler depends on, so a report shows what this client lacks.
function CB:Capabilities()
  local c = {}
  local function add(k, v) c[#c + 1] = k .. "=" .. tostring(v) end
  local version, build, _, toc = GetBuildInfo()
  add("client", tostring(version) .. " (" .. tostring(build) .. ") toc " .. tostring(toc))
  add("forever", CB.isForever)
  add("project", tostring(WOW_PROJECT_ID))
  add("C_Container.GetContainerItemInfo", has(C_Container and C_Container.GetContainerItemInfo))
  add("C_Container.SortBags", has(C_Container and C_Container.SortBags))
  add("C_Container.UseContainerItem", has(C_Container and C_Container.UseContainerItem))
  add("C_Item.GetItemInfoInstant", has(C_Item and C_Item.GetItemInfoInstant))
  add("C_NewItems", has(C_NewItems))
  add("C_GamePad.IsEnabled", has(C_GamePad and C_GamePad.IsEnabled))
  add("gamepadEnabled", C_GamePad and C_GamePad.IsEnabled and tostring(C_GamePad.IsEnabled()) or "?")
  add("MerchantFrame", has(rawget(_G, "MerchantFrame")))
  add("C_MerchantFrame.GetItemInfo", has(C_MerchantFrame and C_MerchantFrame.GetItemInfo))
  add("BankFrame", has(rawget(_G, "BankFrame")))
  add("BankPanel", has(rawget(_G, "BankPanel")))
  add("C_Bank", has(C_Bank))
  add("ContainerFrameCombinedBags", has(_G.ContainerFrameCombinedBags))
  add("ReagentBag slots", C_Container and C_Container.GetContainerNumSlots and Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
      and C_Container.GetContainerNumSlots(Enum.BagIndex.ReagentBag) or "?")
  return c
end

function CB:LogEnvironment()
  CB:Info("env", "Baggler " .. tostring(CB.version) .. " starting")
  for _, line in ipairs(CB:Capabilities()) do CB:Info("env", line) end
  local others = {}
  local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  for _, n in ipairs({ "BetterBags", "Bagnon", "Baganator", "ArkInventory", "AdiBags", "ElvUI", "ConsolePort", "BugSack" }) do
    if loaded and loaded(n) then others[#others + 1] = n end
  end
  CB:Info("env", "other add-ons: " .. (#others > 0 and table.concat(others, ", ") or "none of note"))
end

---------------------------------------------------------------------------
-- Taint / blocked-action watch. If anything (Baggler or not) is blocked from using a protected
-- function, it is logged with a stack so a "can't cast until reload" can be traced afterwards.
---------------------------------------------------------------------------
--- Lists every game variable that Baggler has written to (global names, and fields of the windows and tables Baggler
--- touches). A tainted game variable is the usual reason the game then blocks its own actions, so this names the
--- suspects directly. /baggler taint remains explicit; automatic broad walks are off by default.
function CB:TaintScan()
  local found, n = {}, 0
  local function add(label, by) n = n + 1; if n <= 60 then found[#found + 1] = label .. (by and by ~= "Baggler" and (" (by " .. tostring(by) .. ")") or "") end end
  local function mine(by) return by == "Baggler" or by == ADDON end
  if issecurevariable then
    -- globals
    local seen = 0
    for k in pairs(_G) do
      if type(k) == "string" then
        local ok, secure, by = pcall(issecurevariable, k)
        if ok and secure == false and mine(by) then
          seen = seen + 1
          if not (k:find("^Baggler") or k:find("^SLASH_BAGGLER") or k:find("^BAGGLER")) then add("_G." .. k, by) end
        end
      end
    end
    -- fields of the game's own tables and frames
    local targets = { "UISpecialFrames", "StaticPopupDialogs", "UIPanelWindows", "SlashCmdList", "GameTooltip", "MerchantFrame",
      "BankFrame", "BankPanel", "TradeFrame", "MailFrame", "GuildBankFrame", "LootFrame", "AuctionHouseFrame", "ContainerFrameCombinedBags",
      "UIParent", "ClassTrainerFrame", "GossipFrame", "StaticPopup1" }
    for _, name in ipairs(targets) do
      local t = rawget(_G, name)   -- rawget: reading a not-yet-loaded game window by name would load it from inside Baggler
      if type(t) == "table" then
        for k, v in pairs(t) do
          local ok, secure, by = pcall(issecurevariable, t, k)
          if ok and secure == false and mine(by) then
            local ks = tostring(k)
            if not (ks:find("^Baggler") or ks:find("^baggler") or ks:find("^BAGGLER") or ks:find("^BAGGLER")) then
              add(name .. "." .. ks, by)
            end
          end
        end
      end
    end
  else
    found[1] = "this client has no issecurevariable"
  end
  CB.lastTaintScan = found
  return found
end

--- READ-ONLY provenance for the game's controller input stack. TaintScan above only looks at globals and a fixed list of
--- windows, so it says "none found" even while the game's own radial / interact code is blocked: the tables that code
--- reads (the binding manager's set stack, the frame-focus manager, the radial, the action bar frame) were never
--- inspected. This walks those tables a few levels deep and names every slot that is NOT secure, with the add-on the
--- game recorded as having written it. The slot a blocked call read is the one that carries the add-on's name here.
--- It only uses next / type / issecurevariable: no setter, no call into game code, no hook, nothing written.
-- Most relevant first: the node budget is spent in this order. Paths are resolved with rawget only.
local NATIVE_INPUT_ROOTS = {
  { "GamepadSharedUtility", "InputBindingManager" },
  { "GamepadMode", "FrameControlsManager" },
  { "GamepadRadial" },
  { "GamepadMainActionBarFrame" },
  { "SmartNavigation" },
  { "GamepadSharedUtility" },
  { "GamepadMode" },
}
local NATIVE_DEPTH, NATIVE_NODES, NATIVE_FOUND = 4, 400, 40
local function pathKey(k)
  if type(k) == "string" then return "." .. k end
  if type(k) == "number" then return "[" .. k .. "]" end
  return "[<" .. type(k) .. ">]"
end
function CB:NativeInputScan()
  local found, nodes = {}, 0
  if not issecurevariable then return found end
  local seen = { [_G] = true }
  local function walk(t, label, depth)
    if nodes >= NATIVE_NODES or #found >= NATIVE_FOUND then return end
    nodes = nodes + 1
    local k, v = next(t)
    while k ~= nil do
      local ok, secure, by = pcall(issecurevariable, t, k)
      if ok and secure == false then
        if #found < NATIVE_FOUND then
          found[#found + 1] = label .. pathKey(k) .. (by and (" (by " .. tostring(by) .. ")") or " (by unknown)")
        end
      end
      if depth < NATIVE_DEPTH and type(v) == "table" and not seen[v] then
        seen[v] = true
        walk(v, label .. pathKey(k), depth + 1)
      end
      k, v = next(t, k)
    end
  end
  for _, root in ipairs(NATIVE_INPUT_ROOTS) do
    local t = rawget(_G, root[1])
    for i = 2, #root do
      if type(t) ~= "table" then break end
      t = rawget(t, root[i])
    end
    if type(t) == "table" and not seen[t] then
      seen[t] = true
      walk(t, table.concat(root, "."), 1)
    end
  end
  CB.lastNativeInputScan = found
  return found
end

-- Which transition tainted a game field? A blocked action only says WHAT was written (TaintScan), not WHEN. After each
-- native visit starts/ends, look again and journal only the fields that are newly Baggler-written. Read-only: it never
-- changes a game frame, and it adds no code to the game's call chain (events reach our own frame).
local taintKnown = {}
function CB:TaintWatch(reason)
  -- Legacy broad diagnostics are a development opt-in, never a saved default.
  if CB.autoBroadTaintScans ~= true then return {} end
  local fresh = {}
  for _, label in ipairs(CB:TaintScan()) do
    if not taintKnown[label] then taintKnown[label] = true; fresh[#fresh + 1] = label end
  end
  -- the game's controller input stack: any add-on's name counts, the point is which transition first showed it
  for _, label in ipairs(CB:NativeInputScan()) do
    if not taintKnown[label] then taintKnown[label] = true; fresh[#fresh + 1] = label end
  end
  if #fresh > 0 then CB:Info("taint", "newly Baggler-written after " .. tostring(reason) .. ": " .. table.concat(fresh, ", ")) end
  return fresh
end
-- Targeted before/after probe. The 0.5 s TaintWatch says a slot was tainted by then, not WHICH call did it. This looks at
-- a small fixed list of slots (the ones the saved logs showed first: the paired window's tab, the game's combined bag frame,
-- the controller binding objects) immediately around each place where Baggler touches the game, and keeps a trail of probe
-- labels. The first probe that sees a slot not secure is logged once, with the last probe that still saw it clean: the
-- write happened between those two points. Read-only: rawget / issecurevariable only, nothing is called or written.
local PROBE_SLOTS = {
  { "MerchantFrame", "selectedTab" },
  { "ContainerFrameCombinedBags", "Items" }, { "ContainerFrameCombinedBags", "size" }, { "ContainerFrameCombinedBags", "shownSlots" },
  { "AuctionHouseFrame", "selectedTab" }, { "AuctionHouseFrame", "displayMode" },
  { "GamepadSharedUtility", "InputBindingManager", "currentCoreBindingActive" },
  { "GamepadSharedUtility", "InputBindingManager", "activeBindings", "PAD1" },
  { "GamepadSharedUtility", "InputBindingManager", "activeBindings", "PADLTRIGGER" },
  { "GamepadSharedUtility", "InputBindingManager", "activeBindings", "PADRTRIGGER" },
}
-- Native aura error-flood investigation. Observe provenance, NEVER aura values:
-- secret expirationTime/auraInstanceID must not be compared, formatted or copied.
-- No hooks on native callbacks and no writes into native frames/mixins/tooltips.
local auraStates = setmetatable({}, { __mode = "k" })
local auraFirst, auraFocus, auraEmitted = true, nil, 0
local AURA_EVIDENCE_LIMIT = 48
local function opaque(v) return issecretvalue and issecretvalue(v) end
local function rawTable(t, key)
  local v = rawget(t, key)
  if not opaque(v) and type(v) == "table" then return v end
end
-- Merchant opening provenance: post-hooks observe field ownership, NOT native
-- entry/return execution security. No slot payloads, getters or native calls.
-- Pinned 1.60.1.70938 MerchantFrame.lua:149-154,959-985.
local MERCHANT_OPEN_LIMIT, MERCHANT_CHECKPOINT_LIMIT = 10, 12
local merchantLedger, merchantOpening, merchantPrevious
local merchantHooks, merchantFooterHook = {}, nil
local function merchantStore()
  return merchantLedger
end
local function merchantCheckpoint(phase)
  local db, opening = merchantStore(), merchantOpening
  if not (db and opening) then return end
  db.checkpointSequence = db.checkpointSequence + 1
  local cp = { phase = phase, order = db.checkpointSequence, elapsed = now(), slots = {} }
  local function slots(t, prefix, keys)
    for _, key in ipairs(keys) do
      local result = { status = "unavailable" }
      if t and issecurevariable then
        local ok, secure, owner = pcall(issecurevariable, t, key)
        if ok and not opaque(secure) and type(secure) == "boolean" then
          result.status, result.secure = "observed", secure
          if not opaque(owner) and type(owner) == "string" then result.owner = owner:sub(1, 80) end
        end
      end
      cp.slots[prefix .. key] = result
    end
  end
  local merchant = rawTable(_G, "MerchantFrame")
  local footer = merchant and rawTable(merchant, "footer")
  local utility = rawTable(_G, "GamepadSharedUtility")
  local manager = utility and rawTable(utility, "InputBindingManager")
  slots(merchant, "MerchantFrame.", { "selectedTab", "refundItem", "itemHover", "footer" })
  slots(footer, "MerchantFrame.footer.", { "Refresh", "isShown", "promptedBindingsActive", "bindings" })
  slots(manager, "InputBindingManager.", { "currentCoreBindingActive" })
  slots(manager and rawTable(manager, "activeBindings"), "InputBindingManager.activeBindings.",
    { "PAD1", "PAD3", "PADLTRIGGER", "PADRTRIGGER" })
  slots(_G, "_G.", { "MerchantFrame_UpdateCanRepairAll", "MerchantFrame_UpdateGuildBankRepair" })
  -- Fixed-size metadata only. Pin the first insecure sighting and its actual
  -- predecessor even when repeated nested returns have filled the prefix.
  if not opening.firstTaint or not opening.firstTaint.transition then
    for name, result in pairs(cp.slots) do
      if result.secure == false then
        local prev = merchantPrevious and merchantPrevious.slots[name]
        local transition = prev and prev.secure == true or false
        if transition or not opening.firstTaint then
          opening.firstTaint = { before = merchantPrevious, after = cp, transition = transition }
        end
        if transition then break end
      end
    end
  end
  if #opening.checkpoints < MERCHANT_CHECKPOINT_LIMIT then
    opening.checkpoints[#opening.checkpoints + 1] = cp
  else
    opening.dropped = math.min((opening.dropped or 0) + 1, 1000000000)
  end
  merchantPrevious = cp
end
local function merchantReturn(phase)
  pcall(merchantCheckpoint, phase)
end
local function installMerchantProbe()
  if type(hooksecurefunc) ~= "function" then return end
  local function hook(name, callback)
    local native = rawget(_G, name)
    if merchantHooks[name] or opaque(native) or type(native) ~= "function" then return end
    merchantHooks[name] = pcall(hooksecurefunc, name, callback)
  end
  hook("OpenAllBags", function(frame)
    local merchant = rawTable(_G, "MerchantFrame")
    if opaque(frame) or not merchant or not rawequal(frame, merchant) or not merchantStore() then return end
    -- A duplicate bag request inside the same opening is not another visit.
    if not merchantOpening then
      local db = merchantStore()
      db.sequence = db.sequence + 1
      merchantOpening = { id = db.sequence, checkpoints = {} }
      merchantPrevious = nil
      db.opens[#db.opens + 1] = merchantOpening
      while #db.opens > MERCHANT_OPEN_LIMIT do
        -- Prefer the earliest actual transition; if none was observed, pin
        -- the earliest already-insecure sighting rather than invent ingress.
        local pinned
        for i, old in ipairs(db.opens) do
          if old.firstTaint then
            pinned = pinned or i
            if old.firstTaint.transition then pinned = i; break end
          end
        end
        table.remove(db.opens, pinned == 1 and 2 or 1)
      end
    end
    merchantReturn("OpenAllBags:return")
  end)
  hook("MerchantFrame_UpdateCanRepairAll", function() merchantReturn("UpdateCanRepairAll:return") end)
  hook("MerchantFrame_UpdateGuildBankRepair", function() merchantReturn("UpdateGuildBankRepair:return") end)
  hook("PanelTemplates_SetTab", function(frame)
    if opaque(frame) or not rawequal(frame, rawTable(_G, "MerchantFrame")) then return end
    merchantReturn("PanelTemplates_SetTab:return")
    merchantOpening, merchantPrevious = nil, nil
  end)
  local merchant = rawTable(_G, "MerchantFrame")
  local footer = merchant and rawTable(merchant, "footer")
  local refresh = footer and rawget(footer, "Refresh")
  if footer and not merchantFooterHook and not opaque(refresh) and type(refresh) == "function" then
    if pcall(hooksecurefunc, footer, "Refresh", function(self)
      if not opaque(self) and rawequal(self, footer) then merchantReturn("footer.Refresh:return") end
    end) then merchantFooterHook = footer end
  end
end
CB:On("DB_READY", function()
  if type(CB.db.merchantOpenProbe) ~= "table" then
    CB.db.merchantOpenProbe = { sequence = 0, checkpointSequence = 0, opens = {} }
  end
  merchantLedger = CB.db.merchantOpenProbe
  installMerchantProbe()
end)
CB:RegisterEvent("ADDON_LOADED", function(_, name)
  if name == "Baggler" or name == "Blizzard_UIPanels_Game" then installMerchantProbe() end
end)
CB:On("READY", installMerchantProbe)
CB:RegisterEvent("MERCHANT_CLOSED", function() merchantOpening, merchantPrevious = nil, nil end)
local function merchantReport(lines)
  lines[#lines + 1] = "-- merchant opening provenance (post-hook interval, not native entry execution security) --"
  lines[#lines + 1] = "Bounded: 10 opens (first transition pinned, otherwise first insecure), 12 prefix checkpoints/open plus first interval; no slot payloads."
  local function checkpoint(cp, prefix)
    if not cp then return end
    lines[#lines + 1] = ("%s#%d %s elapsed=%s"):format(prefix, cp.order, cp.phase, tostring(cp.elapsed))
    local names = {}; for name in pairs(cp.slots) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local result = cp.slots[name]
      lines[#lines + 1] = "    " .. name .. "=" .. (result.status == "unavailable" and "unavailable" or
        (result.secure and "secure" or ("insecure by " .. (result.owner or "unknown"))))
    end
  end
  for _, opening in ipairs(merchantLedger and merchantLedger.opens or {}) do
    lines[#lines + 1] = "merchant open " .. opening.id .. " dropped=" .. (opening.dropped or 0)
    for _, cp in ipairs(opening.checkpoints) do checkpoint(cp, "  ") end
    local first = opening.firstTaint
    if first then
      lines[#lines + 1] = first.transition and "  first observed clean-to-insecure interval:" or "  first insecure sighting (not a proven clean-to-insecure transition):"
      checkpoint(first.before, "  before "); checkpoint(first.after, "  after ")
    end
  end
end

-- Flight recorder is independent of debug mode and the ordinary floodable log.
-- Read only fixed metadata slots; never auction payloads, item data or locals.
local INCIDENT_LIMIT, CONTEXT_LIMIT, SESSION_LIMIT = 20, 16, 20
local flightSession, flightEarly, flightPending = nil, {}, {}
local ahOpen = false
local gossipOpen, taxiOpen = false, false
local observationOrder, interactionPending = 0, false
local slotPrevious = {} -- fixed allowlist only; identity and predecessors never restored
local firstInteractionTransition
local observeInteraction
local COMBAT_LIMIT, POST_COMBAT_GRACE = 20, 30
local combatActive, combatSequence, combatEpisode = false, 0, nil
local flightCombats = {} -- current session only; never restore active state from saves
local function combatState()
  local episode = combatEpisode
  local contextual = episode and (combatActive or
    (episode.endElapsed and now() - episode.endElapsed <= POST_COMBAT_GRACE))
  local scope = combatActive and "combat" or (contextual and "post-combat" or "world")
  if ahOpen then scope = scope == "world" and "auction" or ("auction+" .. scope) end
  if taxiOpen then scope = scope == "world" and "taxi" or ("taxi+" .. scope) end
  if gossipOpen then scope = scope == "world" and "gossip" or ("gossip+" .. scope) end
  return { combat = combatActive, combatEncounter = contextual and episode.id or nil,
    combatStart = contextual and episode.startTime or nil,
    combatEnd = contextual and episode.endTime or nil, scope = scope }
end
local function flightText(value, limit)
  if opaque(value) or type(value) ~= "string" then return "unknown" end
  return value:sub(1, limit or 120):gsub("[%c|]", "?")
end
-- Keep only source locations from stacks: no argument dumps, locals, quoted
-- messages or arbitrary user paths. This intentionally sacrifices message detail.
local function sourceLocation(text)
  if opaque(text) or type(text) ~= "string" then return "unknown" end
  local path, line = text:match("(Interface[/\\]AddOns[/\\][!%w_/%-%.\\]+%.lua)%]?:(%d+)")
  if not path then return "unknown" end
  return flightText(path:gsub("\\", "/") .. ":" .. line, 200)
end
local function flightStack(text)
  if opaque(text) or type(text) ~= "string" then return "" end
  local lines = {}
  for line in text:sub(1, 8192):gmatch("[^\r\n]+") do
    local location = sourceLocation(line)
    if location ~= "unknown" then lines[#lines + 1] = location end
    if #lines >= 20 then break end
  end
  return table.concat(lines, "\n"):sub(1, 4096)
end
local function flightStore()
  return CB.db and CB.db.incidents
end
local function flightFocus()
  local mode = rawTable(_G, "GamepadMode")
  local manager = mode and rawTable(mode, "FrameControlsManager")
  local f = manager and rawget(manager, "focusedFrame")
  if opaque(f) then return "opaque" end
  if f == nil then return "none" end
  for _, pair in ipairs({ { "AuctionHouseFrame", "auction" }, { "MerchantFrame", "merchant" },
      { "BankFrame", "bank" }, { "MailFrame", "mail" }, { "TradeFrame", "trade" },
      { "GossipFrame", "gossip" }, { "TaxiFrame", "taxi" }, { "FlightMapFrame", "taxi" } }) do
    if rawequal(f, rawget(_G, pair[1])) then return pair[2] end
  end
  return "other" -- never GetName/Describe on unknown native payloads
end
local function flightState()
  local pad = CB.Pad
  local state = combatState()
  state.ah, state.gossip, state.taxi, state.flightmasterConfirmed = ahOpen, gossipOpen, taxiOpen, taxiOpen
  local window = CB.Window
  local ok, opened = false, nil
  if window and type(window.IsOpen) == "function" then ok, opened = pcall(window.IsOpen, window) end
  state.bags = ok and not opaque(opened) and opened == true or false
  state.owner = pad and pad.holdGame and "native" or (pad and pad.bound and "baggler" or "none")
  state.nativeFocus = flightFocus()
  return state
end
-- Independent per-slot monitor: absent/API-failed/replaced parents break the
-- predecessor chain. No target slot payload is read, even when absent/secret.
local function flightSnapshotUnsafe(phase)
  local state = flightState()
  observationOrder = observationOrder + 1
  state.order, state.elapsed, state.time, state.phase = observationOrder, now(), stamp(), phase or "snapshot"
  state.writers, state.slots = {}, {}
  local function slot(t, key, label)
    local result = { status = "unavailable" }
    state.slots[label] = result
    local ok, secure, writer
    if t and type(issecurevariable) == "function" then ok, secure, writer = pcall(issecurevariable, t, key) end
    if ok and not opaque(secure) and type(secure) == "boolean" then
      result.status, result.secure = "observed", secure
      if not opaque(writer) and type(writer) == "string" then result.owner = flightText(writer, 80) end
      if not secure and #state.writers < 16 then
        state.writers[#state.writers + 1] = label .. " by " .. (result.owner or "unknown")
      end
      local previous = slotPrevious[label]
      if not firstInteractionTransition and (gossipOpen or taxiOpen or interactionPending) and secure == false and
          previous and rawequal(previous.parent, t) and previous.result.secure == true then
        firstInteractionTransition = { slot = label, before = previous.checkpoint, after = state }
        if flightSession then flightSession.firstInteractionTransition = firstInteractionTransition end
      end
      slotPrevious[label] = { parent = t, result = result, checkpoint = state }
    else
      slotPrevious[label] = nil
    end
  end
  -- Reuse the existing targeted probe allowlist, not TaintScan's global walk
  -- or NativeInputScan's recursive tree. Slot payloads are NEVER evaluated.
  for _, path in ipairs(PROBE_SLOTS) do
    local t = rawTable(_G, path[1])
    for i = 2, #path - 1 do t = t and rawTable(t, path[i]) end
    slot(t, path[#path], table.concat(path, "."))
  end
  local utility = rawTable(_G, "GamepadSharedUtility")
  local binding = utility and rawTable(utility, "InputBindingManager")
  slot(binding and rawTable(binding, "activeBindings"), "PAD3", "GamepadSharedUtility.InputBindingManager.activeBindings.PAD3")
  local mode = rawTable(_G, "GamepadMode")
  local manager = mode and rawTable(mode, "FrameControlsManager")
  for _, key in ipairs({ "focusedFrame", "isUIFocused", "topSuspendedFrame", "fallThroughCatcherActive" }) do
    slot(manager, key, "GamepadMode.FrameControlsManager." .. key)
  end
  return state
end
local function flightSnapshot(phase)
  local ok, state = pcall(flightSnapshotUnsafe, phase)
  if ok then return state end
  local fallback = combatState()
  fallback.unavailable, fallback.ah = true, ahOpen
  fallback.owner, fallback.nativeFocus, fallback.writers = "unknown", "unknown", {}
  return fallback
end
local function breadcrumb(kind, action, route, snapshot)
  local ring = flightSession and flightSession.context or flightEarly
  ring[#ring + 1] = { time = stamp(), elapsed = now(), kind = kind, action = action, route = route, ah = ahOpen,
    state = flightState(), snapshot = snapshot }
  while #ring > CONTEXT_LIMIT do table.remove(ring, 1) end
end
observeInteraction = function(kind, phase)
  breadcrumb(kind, nil, nil, flightSnapshot(phase))
end
-- Pinned 1.60.1.70938 GossipInfo/TaxiMap generated event contracts.
-- These are own listeners, not native entry hooks; discard every payload.
for _, event in ipairs({ "GOSSIP_SHOW", "GOSSIP_CLOSED", "TAXIMAP_OPENED", "TAXIMAP_CLOSED" }) do
  CB:RegisterEvent(event, function()
    if event == "GOSSIP_SHOW" then gossipOpen = true
    elseif event == "GOSSIP_CLOSED" then gossipOpen = false
    elseif event == "TAXIMAP_OPENED" then taxiOpen = true
    else taxiOpen = false end
    -- Include close-edge transitions even when both contexts have just ended.
    local pending = interactionPending
    interactionPending = true
    observeInteraction(event, event .. ":event")
    if not pending then
      local timer = rawTable(_G, "C_Timer")
      local after = timer and rawget(timer, "After")
      if not opaque(after) and type(after) == "function" then
        local ok = pcall(after, 0, function()
          observeInteraction("interaction:next-tick", "interaction:next-tick")
          interactionPending = false
        end)
        if not ok then interactionPending = false end
      else interactionPending = false end
    end
  end)
end
local function copyPrelude()
  local out = {}
  for _, entry in ipairs(flightSession and flightSession.context or flightEarly) do
    local copy = {}; for k, v in pairs(entry) do copy[k] = v end
    out[#out + 1] = copy
  end
  return out
end
local function incident(event, addon, func, stack)
  local db = flightStore()
  local errors = db and db.errors or flightPending
  local session = flightSession or { id = 0, build = "startup", version = flightText(CB.version) }
  addon, func = flightText(addon), flightText(func, 240)
  local key = event .. "|" .. addon .. "|" .. (event == "LUA_ERROR" and func or func:gsub("%d+", "#"))
  for _, entry in ipairs(errors) do
    if entry.key == key then
      -- Keep original incident immutable, but a repeated error during a new
      -- interaction can supply this session's first genuine per-slot interval.
      if not firstInteractionTransition and (gossipOpen or taxiOpen or interactionPending) then flightSnapshot("error") end
      entry.count = math.min((entry.count or 1) + 1, 1000000000)
      entry.last = stamp(); entry.lastSession = session.id
      return
    end
  end
  local snapshot = flightSnapshot("error")
  errors[#errors + 1] = { key = key, event = event, addon = addon, func = func,
    time = stamp(), last = stamp(), session = session.id, lastSession = session.id,
    build = session.build, version = session.version, count = 1,
    context = copyPrelude(), stack = flightStack(stack), snapshot = snapshot,
    interactionTransition = firstInteractionTransition }
  -- Pin the earliest distinct incident; retain the latest distinct remainder.
  while #errors > INCIDENT_LIMIT do table.remove(errors, 2) end
end
local flightCallbackOwner = {}
local flightCallbackInstalled = false
local function installFlightCallbacks()
  if flightCallbackInstalled then return end
  local registry = rawTable(_G, "EventRegistry")
  if not (registry and type(registry.RegisterCallback) == "function") then return end
  -- Verified installed !BugGrabber/BugGrabber.lua:422,455: callback carries
  -- tableID; resolve only that exact error through GetErrorByID, never GetDB.
  local ok = pcall(registry.RegisterCallback, registry, "BugGrabber.BugGrabbed", function(_, id)
    if opaque(id) or type(id) ~= "string" then return end
    local grabber = rawTable(_G, "BugGrabber")
    if not (grabber and type(grabber.GetErrorByID) == "function") then return end
    local got, err = pcall(grabber.GetErrorByID, grabber, id)
    if not got or opaque(err) or type(err) ~= "table" then return end
    local message = rawget(err, "message")
    if opaque(message) or type(message) ~= "string" then return end
    -- Roaming/native errors matter too: same bounded recorder in every scope.
    local category = "Lua error (detail omitted)"
    for _, known in ipairs({ "attempt to index", "attempt to call", "secret", "arithmetic", "division by zero", "stack overflow" }) do
      if message:find(known, 1, true) then category = known; break end
    end
    -- BugGrabber also emits protected-action reports, whose messages have no
    -- Lua source location. Retain only fixed category tags and sanitized stack
    -- locations, never the message's addon/function payload or error locals.
    for _, known in ipairs({ "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED" }) do
      if message:sub(1, #known + 2) == "[" .. known .. "]" then category = known; break end
    end
    local stack = rawget(err, "stack")
    local location = sourceLocation(message)
    if location == "unknown" then location = sourceLocation(stack) end
    pcall(incident, "LUA_ERROR", "BugGrabber", location .. " " .. category, stack)
  end, flightCallbackOwner)
  flightCallbackInstalled = ok
end
installFlightCallbacks()
CB:RegisterEvent("ADDON_LOADED", installFlightCallbacks)
CB:On("READY", installFlightCallbacks)

CB:On("DB_READY", function()
  if type(CB.db.incidents) ~= "table" then CB.db.incidents = {} end
  local db = CB.db.incidents
  db.errors, db.sessions = db.errors or {}, db.sessions or {}
  db.sequence = (db.sequence or 0) + 1
  local _, build, _, toc = GetBuildInfo()
  flightSession = { id = db.sequence, time = stamp(), build = flightText(build),
    toc = toc, version = flightText(CB.version), context = flightEarly, combats = flightCombats,
    firstInteractionTransition = firstInteractionTransition }
  -- Allocate pre-DB observations above the saved high-water mark as well.
  local offset = db.combatSequence or 0
  for _, episode in ipairs(flightCombats) do episode.id = episode.id + offset end
  local rebased = {}
  local function rebase(state)
    if state and not rebased[state] then
      rebased[state] = true
      if state.combatEncounter then state.combatEncounter = state.combatEncounter + offset end
    end
  end
  local function rebaseTransition(interval)
    if interval then rebase(interval.before); rebase(interval.after) end
  end
  rebaseTransition(firstInteractionTransition)
  for _, b in ipairs(flightEarly) do rebase(b.state); rebase(b.snapshot) end
  for _, e in ipairs(flightPending) do
    rebase(e.snapshot)
    -- Prelude copies can share immutable state even after ring eviction.
    for _, b in ipairs(e.context) do rebase(b.state); rebase(b.snapshot) end
    rebaseTransition(e.interactionTransition)
  end
  combatSequence = combatSequence + offset
  db.combatSequence = combatSequence
  flightEarly = {}
  for _, entry in ipairs(flightPending) do
    entry.session, entry.lastSession, entry.build = flightSession.id, flightSession.id, flightSession.build
    local existing
    for _, old in ipairs(db.errors) do if old.key == entry.key then existing = old; break end end
    if existing then
      existing.count = math.min((existing.count or 1) + entry.count, 1000000000)
      existing.last, existing.lastSession = entry.last, flightSession.id
    else
      db.errors[#db.errors + 1] = entry
    end
  end
  flightPending = {}
  db.sessions[#db.sessions + 1] = flightSession
  while #db.sessions > SESSION_LIMIT do table.remove(db.sessions, 1) end
  while #db.errors > INCIDENT_LIMIT do table.remove(db.errors, 2) end
  breadcrumb("session")
end)
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "LOOT_OPENED", "LOOT_CLOSED" }) do
  CB:RegisterEvent(event, function() breadcrumb(event) end) -- intentionally ignore all payloads
end
for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
  CB:RegisterEvent(event, function()
    ahOpen = event == "AUCTION_HOUSE_SHOW"
    breadcrumb(event)
  end)
end

local ownedActions = { up = true, down = true, left = true, right = true, use = true, close = true,
  pickup = true, menu = true, prevSection = true, nextSection = true, collapse = true, filter = true,
  sort = true, favorite = true, options = true, switchWindow = true, quickMove = true }
local ownedRoutes = { event = true, binding = true, poll = true, dispatch = true }
CB:On("READY", function()
  local host = CB.Pad and CB.Pad.input and CB.Pad.input.host
  if not host or host.bagglerIncidentObserved then return end
  local dispatch = host.dispatch
  if type(dispatch) ~= "function" then return end
  -- Only our own injected host callback, not a native frame/function/hook.
  host.dispatch = function(context, action, meta)
    if not opaque(action) and type(action) == "string" and ownedActions[action] then
      local source = type(meta) == "table" and rawget(meta, "source")
      local route = not opaque(source) and type(source) == "string" and ownedRoutes[source] and source or "unknown"
      pcall(breadcrumb, "action", action, route)
    end
    return dispatch(context, action, meta)
  end
  host.bagglerIncidentObserved = true
end)
for _, name in ipairs({ "WINDOW_SHOWN", "WINDOW_HIDDEN", "PAD_STATE" }) do
  CB:On(name, function(window)
    if name == "PAD_STATE" or window == CB.Window then
      if name == "PAD_STATE" then breadcrumb(name)
      else observeInteraction(name, name .. ":own-callback") end
    end
  end)
end
for _, name in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
  CB:RegisterEvent(name, function()
    if name == "PLAYER_REGEN_DISABLED" then
      if not combatActive then
        combatSequence = combatSequence + 1
        local db = flightStore()
        if db then db.combatSequence = combatSequence end
        combatEpisode = { id = combatSequence, startTime = stamp(), startElapsed = now() }
        flightCombats[#flightCombats + 1] = combatEpisode
        while #flightCombats > COMBAT_LIMIT do table.remove(flightCombats, 1) end
        combatActive = true
      end
    elseif combatActive then
      combatActive = false
      combatEpisode.endTime, combatEpisode.endElapsed = stamp(), now()
    end
    breadcrumb(name)
  end)
end

-- Explicit chat output only; never creates a window or takes input focus.
function CB:BuildIncidentReport()
  local db = flightStore() or { errors = {}, sessions = {} }
  local grabber = rawTable(_G, "BugGrabber")
  local available = flightCallbackInstalled and grabber and type(grabber.GetErrorByID) == "function"
  local lines = { "== Baggler incidents ==", "BugGrabber: " .. (available and "callback active" or "unavailable; protected-action events still recorded"),
    "SavedVariables reach disk on reload/logout; hard crashes can lose this session.",
    "Scopes: world, combat, post-combat (30s after observed regen); gossip/taxi/auction can overlap combat.",
    "Combat encounters are observed regen episodes, not boss IDs; reload starts inactive (no inferred combat).",
    "Bounded: 20 sessions, 20 encounters/session, 20 distinct errors (first pinned), 16 breadcrumbs each; stacks are source locations only." }
  local function checkpoint(cp, prefix)
    if not cp or not cp.order then return end
    lines[#lines + 1] = prefix .. "#" .. cp.order .. " " .. cp.phase .. " elapsed=" .. cp.elapsed .. " scope=" .. cp.scope
    local names = {}; for name in pairs(cp.slots or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local result = cp.slots[name]
      lines[#lines + 1] = "    " .. name .. "=" .. (result.status == "unavailable" and "unavailable" or
        (result.secure and "secure" or ("insecure by " .. (result.owner or "unknown"))))
    end
  end
  local function transition(interval)
    if not interval then return end
    lines[#lines + 1] = "  first interaction clean-to-insecure interval: " .. interval.slot
    checkpoint(interval.before, "  before "); checkpoint(interval.after, "  after ")
  end
  lines[#lines + 1] = "Gossip is dialogue context only; TAXIMAP_OPENED confirms flight-map context, not earlier gossip identity. Own event/next-tick observations are not native entry or writer-origin proof."
  for _, s in ipairs(db.sessions or {}) do
    lines[#lines + 1] = "session " .. s.id .. " " .. s.time .. " build=" .. s.build .. " version=" .. s.version
    transition(s.firstInteractionTransition)
    for _, c in ipairs(s.combats or {}) do
      lines[#lines + 1] = "  combat encounter=" .. c.id .. " start=" .. c.startTime ..
        " end=" .. (c.endTime or "not observed (may cross reload)")
    end
  end
  for _, e in ipairs(db.errors or {}) do
    lines[#lines + 1] = ("%s session=%s %s %s %s x%d; last=%s session=%s"):format(
      e.time, e.session, e.event, e.addon, e.func, e.count, e.last, e.lastSession)
    local s = e.snapshot
    if s then
      lines[#lines + 1] = "  scope=" .. (s.scope or "legacy/unknown") .. " encounter=" .. (s.combatEncounter or "none") ..
        " start=" .. (s.combatStart or "none") .. " end=" .. (s.combatEnd or "not observed at incident")
      if s.unavailable then lines[#lines + 1] = "  snapshot unavailable (observation failed)" end
      lines[#lines + 1] = ("  AH=%s bags=%s combat=%s owner=%s nativeFocus=%s"):format(
        tostring(s.ah), tostring(s.bags), tostring(s.combat), s.owner, s.nativeFocus)
      for _, writer in ipairs(s.writers or {}) do lines[#lines + 1] = "  writer: " .. writer end
    end
    transition(e.interactionTransition)
    checkpoint(s, "  snapshot ")
    for _, b in ipairs(e.context or {}) do
      lines[#lines + 1] = "  before " .. b.time .. " " .. b.kind .. " " .. (b.action or "") .. " " .. (b.route or "")
      checkpoint(b.snapshot, "  observed ")
    end
    if e.stack ~= "" then lines[#lines + 1] = "  first stack locations:\n" .. e.stack end
  end
  merchantReport(lines)
  return table.concat(lines, "\n")
end
function CB:PrintIncidents()
  for line in CB:BuildIncidentReport():gmatch("[^\n]+") do CB:Print(line) end
end

local function auraEvidence(text)
  if auraEmitted >= AURA_EVIDENCE_LIMIT or not CB.db then return end
  auraEmitted = auraEmitted + 1
  -- Separate from the ordinary log: a pad/error flood must not evict first evidence.
  local evidence = CB.db.auraWatch
  if type(evidence) ~= "table" then evidence = {}; CB.db.auraWatch = evidence end
  if #evidence < AURA_EVIDENCE_LIMIT then evidence[#evidence + 1] = stamp() .. " " .. text end
  CB:Info("aura-probe", text)
end
function CB:AuraProbe(label)
  if not (issecurevariable and CB.db) then return end
  local changes, checked, changed = {}, 0, 0
  local function slots(t, path, keys)
    if type(t) ~= "table" then return end
    local states = auraStates[t]
    if not states then states = {}; auraStates[t] = states end
    for _, key in ipairs(keys) do
      checked = checked + 1
      -- Check even absent keys (notably mouse-focus auraType); never evaluate them.
      local ok, secure, by = pcall(issecurevariable, t, key)
      if ok and not opaque(secure) and type(secure) == "boolean" then
        local writer = not opaque(by) and type(by) == "string" and by or "unknown"
        local status = secure and "secure" or ("insecure by " .. writer)
        local prev = states[key]
        if (prev and prev.status ~= status) or (not prev and not secure) then
          changed = changed + 1
          if #changes < 8 then
            changes[#changes + 1] = path .. "." .. key .. "=" .. status ..
              " (previous observation: " .. (prev and (prev.label .. "=" .. prev.status) or "none") .. ")"
          end
        end
        states[key] = { status = status, label = label }
      end
    end
  end
  local frameKeys = { "auraFrames", "auraTooltipQueue", "auraTooltipTimer", "Update", "OnUpdate",
    "ShouldProcessTooltipQueue", "ShowNextAuraForTooltip", "AddAuraForTooltip" }
  local buttonKeys = { "auraType", "buttonInfo", "timeLeft", "Update", "OnUpdate", "OnEnter",
    "CalculateTimeLeft", "UpdateExpirationTime" }
  for _, name in ipairs({ "BuffFrame", "DebuffFrame", "ExternalDefensivesFrame" }) do
    local f = rawTable(_G, name)
    if f then
      slots(f, name, frameKeys)
      local frames = rawTable(f, "auraFrames")
      if frames then
        for i = 1, 64 do
          local b = rawTable(frames, i)
          if b then
            local path = name .. ".auraFrames[" .. i .. "]"
            slots(b, path, buttonKeys)
            slots(rawTable(b, "buttonInfo"), path .. ".buttonInfo", { "expirationTime", "auraInstanceID", "timeMod", "auraType" })
          end
        end
      end
    end
  end
  slots(rawTable(_G, "BuffFrameMixin"), "BuffFrameMixin", frameKeys)
  slots(rawTable(_G, "AuraButtonMixin"), "AuraButtonMixin", buttonKeys)
  for _, name in ipairs({ "GameTooltip", "BuffFrameTooltip" }) do
    local t = rawTable(_G, name)
    if t then
      slots(t, name, { "infoList", "processingInfo", "UpdateTooltip", "ProcessInfo", "OnUpdate" })
      local list = rawTable(t, "infoList")
      local info = rawTable(t, "processingInfo") or (list and rawTable(list, 1))
      if info then
        slots(info, name .. ".info", { "tooltipData", "getterName", "getterArgs", "tooltipPostCall" })
        slots(rawTable(info, "tooltipData"), name .. ".info.tooltipData", { "id", "type", "dataInstanceID" })
      end
    end
  end
  local focus = {}
  if GetMouseFoci then
    local ok, frames = pcall(GetMouseFoci)
    if ok and not opaque(frames) and type(frames) == "table" then
      for i = 1, 4 do
        local f = rawTable(frames, i)
        if f then
          -- GetName is a widget metadata getter, never an aura/native Lua callback.
          local name = "anonymous"
          local getter = UIParent and UIParent.GetName
          if type(getter) == "function" then
            local got, n = pcall(getter, f)
            if got and not opaque(n) and type(n) == "string" then name = n end
          end
          local mt = getmetatable(f)
          local index = not opaque(mt) and type(mt) == "table" and rawget(mt, "__index")
          local value = rawget(f, "auraType")
          local kind = opaque(value) and "opaque" or type(value)
          focus[#focus + 1] = name .. " rawAuraType=" .. kind .. " metatableIndex=" .. (opaque(index) and "opaque" or type(index))
          slots(f, "mouse[" .. i .. "]:" .. name, { "auraType" })
        end
      end
    end
  end
  local context = table.concat(focus, "; ")
  if auraFirst or #changes > 0 or context ~= auraFocus or label:find("PLAYER_REGEN", 1, true) then
    auraEvidence(label .. " checked=" .. checked .. " mouse={" .. context .. "} " ..
      (#changes > 0 and table.concat(changes, "; ") or "no provenance transition observed") ..
      (changed > #changes and ("; additional transitions not listed=" .. (changed - #changes)) or ""))
  end
  auraFirst, auraFocus = false, context
end
local auraPending, lastAuraEvent = false, -math.huge
for _, ev in ipairs({ "UNIT_AURA", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
  CB:RegisterEvent(ev, function(_, unit)
    if ev == "UNIT_AURA" then
      if opaque(unit) or unit ~= "player" or now() - lastAuraEvent < 1 then return end
      lastAuraEvent = now()
    end
    CB:AuraProbe("event " .. ev)
    -- Event delivery order is not guaranteed. Observe again next tick without
    -- inserting ourselves into BuffFrame's callback chain; one pending timer max.
    if not auraPending and C_Timer and C_Timer.After then
      auraPending = true
      C_Timer.After(0, function()
        auraPending = false
        CB:AuraProbe("after event " .. ev)
      end)
    end
  end)
end

local probeKnown, probeTrail = {}, {}
function CB:SlotProbe(label)
  CB:AuraProbe(label)
  if not issecurevariable then return end
  local fresh = {}
  for _, path in ipairs(PROBE_SLOTS) do
    local t = rawget(_G, path[1])
    for i = 2, #path - 1 do
      if type(t) ~= "table" then break end
      t = rawget(t, path[i])
    end
    local key = path[#path]
    local name = table.concat(path, ".")
    if type(t) == "table" and not probeKnown[name] and rawget(t, key) ~= nil then
      local ok, secure, by = pcall(issecurevariable, t, key)
      if ok and secure == false then
        probeKnown[name] = true
        fresh[#fresh + 1] = name .. " (by " .. tostring(by) .. ")"
      end
    end
  end
  if #fresh > 0 then
    CB:Info("taint", ("probe: first not secure at '%s' (last probe before it, still clean: '%s'): %s | recent probes: %s"):format(
      tostring(label), tostring(probeTrail[#probeTrail] or "none"), table.concat(fresh, ", "), table.concat(probeTrail, " > ")))
  end
  if probeTrail[#probeTrail] ~= label then
    probeTrail[#probeTrail + 1] = label
    if #probeTrail > 8 then table.remove(probeTrail, 1) end
  end
end

for _, ev in ipairs({ "MERCHANT_SHOW", "MERCHANT_CLOSED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
  CB:RegisterEvent(ev, function()
    CB:SlotProbe("event " .. ev)
    C_Timer.After(0.5, function() CB:Safe("taintwatch", function() CB:TaintWatch(ev) end) end)
  end)
end

CB.blockedCount = 0
local blockedSeen = {}
-- Handler for the game's blocked-action (taint) events. Logs one line per distinct add-on and
-- function with a repeat count.
local function onBlocked(event, addonName, func)
  if opaque(addonName) or type(addonName) ~= "string" or opaque(func) or type(func) ~= "string" then return end
  -- Snapshot before the existing recovery policy runs. This adds no recovery
  -- action and does not change any binding/transaction/native callback.
  pcall(incident, event, addonName, func, debugstack and debugstack(2, 12, 2))
  CB.blockedCount = CB.blockedCount + 1
  local mine = tostring(addonName) == "Baggler" or tostring(addonName) == ADDON
  -- One line per distinct (add-on, function) with a repeat count. A flood of identical blocks
  -- (a different button number each time) used to push every useful line out of the log.
  local key = tostring(event) .. "|" .. tostring(addonName) .. "|" .. tostring(func):gsub("%d+", "#")
  local seenEntry = blockedSeen[key]
  if seenEntry then
    seenEntry.count = (seenEntry.count or 1) + 1
    seenEntry.last = stamp()
  else
    CB:Log(mine and "E" or "W", "taint",
      ("%s: %s tried to call protected function %s"):format(event, tostring(addonName), tostring(func)),
      debugstack and debugstack(2, 12, 2) or nil)
    local l = store()
    blockedSeen[key] = l and l[#l] or nil
    if CB.autoBroadTaintScans == true then pcall(function()
      local scan = CB:TaintScan()
      CB:Info("taint", "game variables Baggler has written to: " .. (#scan > 0 and table.concat(scan, ", ") or "none found"))
    end)
    -- the controller input stack the blocked call read: which slot is not secure, and who wrote it
    pcall(function()
      local native = CB:NativeInputScan()
      CB:Info("taint", "game controller input stack, slots not secure: " .. (#native > 0 and table.concat(native, ", ") or "none found"))
    end)
    end -- explicit legacy broad-scan opt-in
    -- what was going on at that moment: who held the controller and which game windows were open
    pcall(function()
      local Pad = CB.Pad
      local open = {}
      for _, g in ipairs((Pad and Pad.GAME_WINDOWS) or {}) do
        local f = g.frame()
        if f and f.IsVisible and f:IsVisible() then open[#open + 1] = g.name end
      end
      CB:Info("taint", ("context: %s | holdGame=%s | game windows open: %s | Baggler windows: bags=%s bank=%s guildbank=%s trade=%s mail=%s loot=%s"):format(
        Pad and Pad:Describe():sub(1, 200) or "?", tostring(Pad and Pad.holdName), #open > 0 and table.concat(open, ", ") or "none",
        tostring(CB.Window and CB.Window:IsOpen()), tostring(CB.Bank and CB.Bank.active), tostring(CB.GuildBank and CB.GuildBank.active),
        tostring(CB.Trade and CB.Trade.active), tostring(CB.Mail and CB.Mail.active), tostring(CB.Loot and CB.Loot.active)))
    end)
  end
  -- Keep the open window. Dropping its context here is what left the bags up and the
  -- controller dead until they were closed with the mouse and opened again.
  if mine then CB:EmergencyReset("blocked action") end
end
CB:RegisterEvent("ADDON_ACTION_BLOCKED", onBlocked)
CB:RegisterEvent("ADDON_ACTION_FORBIDDEN", onBlocked)

---------------------------------------------------------------------------
-- Emergency reset: releases everything Baggler can hold on to (controller bindings, the click
-- catcher, a held item) without a reload. /baggler fix. Also runs by itself if Baggler is ever
-- blocked from a protected action.
---------------------------------------------------------------------------
function CB:EmergencyReset(reason)
  local did = {}
  if reason == "blocked action" and CB.Pad and #CB.Pad.stack > 0 then
    CB.Pad:HandOff("blocked action")
    did[#did + 1] = "controller lent to the game; the open window stays"
  else
    local dropped = CB.Pad and CB.Pad:Reset() or 0
    did[#did + 1] = ("controller bindings released (%d context%s)"):format(dropped, dropped == 1 and "" or "s")
  end
  if CB.Menu and CB.Menu.Close then CB.Menu:Close(); did[#did + 1] = "menu and click catcher cleared" end
  if CB.heldByUs and CursorHasItem and CursorHasItem() then
    ClearCursor(); did[#did + 1] = "item put down"
  end
  CB.heldByUs = nil
  CB:Log("W", "reset", "emergency reset (" .. tostring(reason or "manual") .. "): " .. table.concat(did, ", "))
  return did
end

---------------------------------------------------------------------------
-- Report window and chat output
---------------------------------------------------------------------------
-- Reports are local text until the player copies/shares them. Logs can contain
-- item links, character-related context and error stacks; this is not a redactor.
-- Do not add automatic transmission to this diagnostics path.
function CB:BuildReport(maxEntries)
  local lines = { "== Baggler report ==", "version " .. tostring(CB.version) .. "   " .. stamp(),
                  "errors this session: " .. CB.errorCount, "" }
  lines[#lines + 1] = "-- environment --"
  for _, l in ipairs(CB:Capabilities()) do lines[#lines + 1] = l end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- live state --"
  local Pad = CB.Pad
  if Pad then
    lines[#lines + 1] = ("controller: enabled=%s bound=%s contexts=%d suspended=%s applies=%d pruned=%d resets=%d last=%s"):format(
      tostring(Pad:Enabled()), tostring(Pad.bound), #Pad.stack, tostring(Pad.suspended),
      Pad.stats.applies, Pad.stats.pruned, Pad.stats.resets, tostring(Pad.stats.lastReason))
  end
  local function shown(f) return f and f:IsShown() and "open" or "closed" end
  lines[#lines + 1] = ("windows: bags=%s bank=%s vendor=%s options=%s menu=%s"):format(
    shown(CB.Window and CB.Window.frame), shown(CB.Bank and CB.Bank.window.frame), shown(CB.Vendor and CB.Vendor.frame),
    shown(CB.Options and CB.Options.frame), shown(_G.BagglerMenu))
  lines[#lines + 1] = ("click catcher: %s | cursor item: %s (ours=%s) | combat: %s | animations running: %d | blocked actions: %d"):format(
    shown(_G.BagglerMenuCatcher), tostring(CursorHasItem and CursorHasItem()), tostring(CB.heldByUs),
    tostring(InCombatLockdown()), CB.UI and CB.UI:Running() or 0, CB.blockedCount)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- settings (non-default) --"
  if CB.db then
    for k, v in pairs(CB.db) do
      local d = CB.defaults[k]
      if type(v) ~= "table" and v ~= d and k ~= "log" then lines[#lines + 1] = k .. " = " .. tostring(v) end
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = CB:BuildIncidentReport()
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- native aura provenance (first observations, preserved across sessions) --"
  for _, line in ipairs(CB.db and CB.db.auraWatch or {}) do lines[#lines + 1] = line end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- log (newest last) --"
  local log = store() or {}
  local from = math.max(1, #log - (maxEntries or 60) + 1)
  for i = from, #log do
    local e = log[i]
    lines[#lines + 1] = ("%s [%s] %s: %s%s"):format(e.time or "?", e.level, e.ctx, e.msg,
      (e.count and e.count > 1) and (" (x" .. e.count .. ")") or "")
    if e.stack and e.level == "E" and e.stack ~= "" then
      for line in tostring(e.stack):gmatch("[^\n]+") do lines[#lines + 1] = "      " .. line end
    end
  end
  return table.concat(lines, "\n")
end

local reportFrame
-- Shows the copyable report window, building it on first use.
function CB:ShowReport()
  if not reportFrame then
    local UI = CB.UI
    UI:MakeFonts()
    local f = CB.NewFrame("Frame", "BagglerReport", UIParent, "BackdropTemplate")
    reportFrame = f
    f:SetSize(640, 460)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    UI:Backdrop(f, UI.bg, UI.border, 0.98)
    UI:Shadow(f)
    local title = f:CreateFontString(nil, "OVERLAY", "BagglerFont")
    title:SetPoint("TOPLEFT", 14, -14)
    title:SetText("Baggler report   " .. CB.HEX.dim .. "select all (Ctrl+A), copy (Ctrl+C), share with your bug report|r")
    local close = UI:Button(f, "Close", 70, 22, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -12, -10)
    local clear = UI:Button(f, "Clear log", 80, 22, function()
      if CB.db then CB.db.log = {} end
      CB.errorCount = 0
      CB:ShowReport()
    end)
    clear:SetPoint("RIGHT", close, "LEFT", -6, 0)
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -44)
    scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("BagglerFontSmall")
    edit:SetWidth(580)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    scroll:SetScrollChild(edit)
    f.edit = edit
    CB.UI:EscapeClose(_G["BagglerReport"])
  end
  reportFrame.edit:SetText(CB:BuildReport(80))
  reportFrame:Show()
  reportFrame.edit:SetFocus()
  reportFrame.edit:HighlightText()
end

function CB:PrintLog(n)
  local log = store() or {}
  n = math.max(1, math.min(tonumber(n) or 15, 60))
  local from = math.max(1, #log - n + 1)
  if #log == 0 then CB:Print("log is empty.") return end
  for i = from, #log do
    local e = log[i]
    print(("|cff%s%s [%s]|r %s: %s%s"):format(COLORS[e.level] or "ffffff", (e.time or ""):sub(12), e.level, e.ctx, e.msg,
      (e.count and e.count > 1) and (" (x" .. e.count .. ")") or ""))
  end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
CB:On("DB_READY", function()
  -- Preserve the original first-observation evidence across reloads. The
  -- separate incident sessions keep recent AH context; never erase old proof.
  if type(CB.db.auraWatch) ~= "table" then CB.db.auraWatch = {} end
  auraEmitted, auraFirst, auraFocus = 0, true, nil
  auraStates = setmetatable({}, { __mode = "k" })
  CB.sessionID = tostring(time and time() or 0)
  CB.debugMode = CB.db.debug and true or false
  -- one-time upgrade of an old log shape
  if type(CB.db.log) ~= "table" then CB.db.log = {} end
  CB:Log("I", "session", "loaded " .. tostring(CB.version))
  CB:AuraProbe("DB_READY baseline")
end)

CB:On("READY", function()
  if CB.autoBroadTaintScans == true then C_Timer.After(8, function()
    CB:Safe("taintscan", function()
      local scan = CB:TaintScan()
      CB:Info("taint", "at login, game variables Baggler has written to: " .. (#scan > 0 and table.concat(scan, ", ") or "none found"))
      local native = CB:NativeInputScan()
      CB:Info("taint", "at login, game controller input stack, slots not secure: " .. (#native > 0 and table.concat(native, ", ") or "none found"))
      for _, label in ipairs(native) do taintKnown[label] = true end   -- login state is the baseline, not a transition
    end)
  end) end
  installFlightCallbacks()
  CB:LogEnvironment()
end)
