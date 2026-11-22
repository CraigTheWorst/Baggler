-- Baggler gamepad: while one of our windows is open, controller buttons are
-- temporarily rebound to drive the window, and released the moment it closes
-- or the moment combat starts, via a secure state driver.
-- Bindings are applied with SecureHandler Execute. SetOverrideBindingClick from
-- addon code taints the gamepad binding manager, and the next gossip or map
-- panel then dies in SetPreferredGamepadInteractTarget.
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local Pad = {}
CB.Pad = Pad

Pad.stack = {}        -- contexts, topmost last
Pad.suspended = false -- true while in combat (bindings are cleared securely)
Pad.bound = false     -- true while our override bindings are applied
Pad.stats = { applies = 0, pruned = 0, resets = 0, lastReason = "-" }

--- The one combat signal for every insecure writer (bindings, macros, receivers, attributes).
--- The journal shows PLAYER_REGEN_DISABLED arriving with InCombatLockdown()==false and
--- UnitAffectingCombat()==true, and the secure state driver only resolves on the next OnUpdate, so
--- lockdown alone is too late: an add-on timer in that gap can rewrite the whole override set after the
--- secure clear (which fires once per change). Either flag means combat. The driver's own attribute is
--- deliberately NOT used when UnitAffectingCombat exists: it still reads 1 at PLAYER_REGEN_ENABLED
--- (journal), and trusting it would keep the add-on out of the world for a frame or more after combat.
function Pad.InCombat()
  if InCombatLockdown() then return true end
  if UnitAffectingCombat then
    local ok, affecting = pcall(UnitAffectingCombat, "player")
    if ok then return affecting == true end
  end
  local owner = rawget(_G, "BagglerPadOwner")
  local state = owner and owner.GetAttribute and owner:GetAttribute("state-combat")
  return state == 1 or state == "1"
end

Pad.ACTIONS = { "use", "close", "pickup", "menu", "prevSection", "nextSection",
                "collapse", "filter", "sort", "favorite", "options", "sellJunk", "switchWindow", "quickMove" }
Pad.ACTION_LABEL = {
  use = "Use / confirm", close = "Close / back", pickup = "Pick up / place", menu = "Item menu",
  prevSection = "Previous section", nextSection = "Next section", collapse = "Fold section",
  filter = "Cycle section filter", sort = "Clean up (sort)", favorite = "Toggle favorite",
  options = "Settings", sellJunk = "Sell junk (at a vendor)", switchWindow = "Switch window (vendor / bank / bags)",
  quickMove = "Send to bank / guild bank / trade",
}
Pad.MAPPABLE = { "PAD1", "PAD2", "PAD3", "PAD4", "PADLSHOULDER", "PADRSHOULDER",
                 "PADLTRIGGER", "PADRTRIGGER", "PADLSTICK", "PADRSTICK", "PADBACK", "PADFORWARD" }

local DPAD = { PADDUP = "up", PADDDOWN = "down", PADDLEFT = "left", PADDRIGHT = "right" }
local STICK = { PADLSTICKUP = "up", PADLSTICKDOWN = "down", PADLSTICKLEFT = "left", PADLSTICKRIGHT = "right" }

---------------------------------------------------------------------------
-- Secure owner: clears our override bindings the instant combat begins.
---------------------------------------------------------------------------
local owner = CreateFrame("Frame", "BagglerPadOwner", UIParent, "SecureHandlerStateTemplate")
-- Combat close: add-on code cannot bind anything once lockdown starts, so the keys B (close) is mapped to are
-- written on the owner as "combatclose" while Baggler holds the controller out of combat. When combat begins the
-- restricted snippet drops every Baggler override and binds only those keys to a secure click button. Its own
-- restricted click releases the keys again (the game gets B straight back), and an observe-only hook then
-- closes the bags (hiding our unprotected window is allowed in combat).
local combatClose = CreateFrame("Button", "BagglerPadCombatClose", UIParent, "SecureHandlerClickTemplate")
combatClose:RegisterForClicks("AnyDown", "AnyUp")
combatClose:SetFrameRef("owner", owner)
combatClose:SetAttribute("_onclick", [[
  local o = self:GetFrameRef("owner")
  if o and o:GetAttribute("combatbound") then
    o:ClearBindings()
    o:SetAttribute("combatbound", nil)
  end
]])
owner:SetAttribute("_onstate-combat", [[
  -- The state driver hands the snippet tonumber("1") == 1 (SecureStateDriver resolveDriver), never the string.
  -- Comparing with "1" alone never matched, so nothing was released at combat start. Accept both.
  if newstate == 1 or newstate == "1" then
    self:ClearBindings()
    self:SetAttribute("combatbound", nil)
    local keys = self:GetAttribute("combatclose")
    if keys and keys ~= "" then
      for key in gmatch(keys, "[%w]+") do self:SetBindingClick(true, key, "BagglerPadCombatClose", "LeftButton") end
      self:SetAttribute("combatbound", keys)
    end
  end
]])
pcall(RegisterStateDriver, owner, "combat", "[combat] 1; 0")
Pad.combatCloseButton = combatClose

-- Shared with CXP. Whichever addon loaded first owns the table.
-- A repeat claim does not take a new turn. The newest window still wins.
local function EnsureBroker()
  if _G.BagglerPadBroker then return _G.BagglerPadBroker end
  local Broker = { claims = {}, serial = 0, hardware = nil, applied = nil, appliedClear = nil }
  function Broker:Has(id)
    return self.claims[id] ~= nil
  end
  function Broker:Winner()
    return self.applied
  end
  function Broker:ClearApplied()
    local clear = self.appliedClear
    self.applied = nil
    self.appliedClear = nil
    if clear then pcall(clear) end
  end
  function Broker:Resolve(force)
    if self.resolving then return end
    self.resolving = true
    if self.hardware == false then
      self:ClearApplied()
      self.resolving = false
      return
    end
    local bestId, bestSerial, bestRank
    for id, claim in pairs(self.claims) do
      local rank = claim.rank or 1
      if bestId == nil or rank > bestRank or (rank == bestRank and claim.serial > bestSerial) then
        bestId, bestSerial, bestRank = id, claim.serial, rank
      end
    end
    if self.applied and self.applied ~= bestId then
      self:ClearApplied()
    end
    if bestId and (force or self.applied ~= bestId) then
      local claim = self.claims[bestId]
      self.applied = bestId
      self.appliedClear = claim.clear
      if claim.apply then pcall(claim.apply) end
    elseif not bestId then
      self:ClearApplied()
    end
    self.resolving = false
  end
  function Broker:Claim(id, apply, clear, rank)
    if rank == nil then rank = 1 end
    local existing = self.claims[id]
    if existing then
      existing.apply = apply
      existing.clear = clear
      existing.rank = rank
    else
      self.serial = self.serial + 1
      self.claims[id] = { apply = apply, clear = clear, serial = self.serial, rank = rank }
    end
    self:Resolve(true)
  end
  function Broker:Release(id)
    if not self.claims[id] then return end
    local was = self.applied == id
    self.claims[id] = nil
    if was then self:Resolve(true) end
  end
  function Broker:NoteHardware(on)
    if on == nil then return end
    on = on and true or false
    if self.hardware == on then return end
    self.hardware = on
    self:Resolve(false)
  end
  _G.BagglerPadBroker = Broker
  return Broker
end

-- InputSession/host adapter loaded next supplies ownership and action dispatch.

---------------------------------------------------------------------------
-- Bindings
---------------------------------------------------------------------------
-- Builds a restricted snippet in ordinary Lua, then executes it on the secure
-- owner out of combat. Only the snippet's body runs in that restricted context;
-- the surrounding helper and action callbacks remain insecure. Validate tokens
-- before embedding them, and never call SetOverrideBinding* as a substitute.
local function secureBindings(pairs_)
  if Pad.InCombat() then return false end
  if type(owner.Execute) ~= "function" then return false end
  local lines = { "self:ClearBindings()", "self:SetAttribute(\"combatbound\", nil)" }
  for i = 1, #pairs_ do
    local key, name = pairs_[i][1], pairs_[i][2]
    if type(key) == "string" and type(name) == "string"
      and key:match("^[%w]+$") and name:match("^[%w_]+$") then
      if pairs_[i][3] then
        -- a game binding command (the key then does exactly what the game's own key does)
        lines[#lines + 1] = string.format("self:SetBinding(true, %q, %q)", key, name)
      else
        lines[#lines + 1] = string.format("self:SetBindingClick(true, %q, %q, %q)", key, name, "LeftButton")
      end
    end
  end
  local ok, err = pcall(owner.Execute, owner, table.concat(lines, "\n"))
  if not ok then CB:Warn("pad", "secure bind failed: " .. tostring(err)) end
  return ok
end

-- Out of combat only: which keys the secure combat snippet may bind to the combat close button.
-- Empty unless Baggler itself (not a game window, not another broker claimant) holds the controller.
-- Publish this allowlist before lockdown. The combat state driver can then drop
-- ordinary bindings and retain only close; insecure events cannot rebuild it.
-- If another path closes the bags in combat, the next close-key press releases
-- the retained key (or regen clears it). Restricted code cannot inspect the
-- unprotected bag frame to discover that external close immediately.
local function syncCombatClose(want)
  if Pad.InCombat() then return end
  local keys = {}
  local map = CB.db and CB.db.pad and CB.db.pad.map
  if want and map then
    for key, action in pairs(map) do
      if action == "close" and type(key) == "string" and key:match("^[%w]+$") then keys[#keys + 1] = key end
    end
    table.sort(keys)
  end
  local value = table.concat(keys, " ")
  if owner:GetAttribute("combatclose") ~= value then pcall(owner.SetAttribute, owner, "combatclose", value) end
  Pad.combatCloseKeys = value
end

-- The Baggler window B may close in combat: the bags (a plain unprotected frame). Other contexts (bank, vendor,
-- mail ...) close through the game's own frames and are left alone.
local function combatViews()
  return { CB.Window }
end
local function combatClosable(ctx)
  for _, view in ipairs(combatViews()) do
    if view and view.ctx == ctx then return true end
  end
  return false
end

--- The combat close button was pressed (its restricted click has already given the keys back to the game).
--- Closes the Baggler bag windows. Hiding these unprotected frames is allowed in combat.
function Pad:CombatClose()
  if #Pad.stack == 0 then return end
  CB:Journal("pad", "combat close: B closes the bags; the game has the controller")
  for _, view in ipairs(combatViews()) do
    if view and view.IsOpen and view:IsOpen() then CB:Safe("pad:combat close", view.Close, view) end
  end
end
combatClose:HookScript("OnClick", function() Pad:CombatClose() end)

-- Direct reception, observation, caching and ordinary binding construction are
-- wholly replaced by InputHost.lua. Secure owner and auction proxies remain host.
local function useCatcher() return CB.db and CB.db.pad.backend == "catcher" end
Pad.secureHost = {broker=EnsureBroker, bind=secureBindings, closeKeys=syncCombatClose, closable=combatClosable, owner=owner}

function Pad:Snapshot(why) CB:Journal("pad", tostring(why)..": "..self:Describe()) end

local POST_KEY = "PAD4" -- retained native Create Auction shortcut
local function postButtonNow()
  local ah = rawget(_G, "AuctionHouseFrame")
  if not ah then return nil end
  for _, key in ipairs({ "ItemSellFrame", "CommoditiesSellFrame" }) do
    local sf = ah[key]
    if sf and sf.IsShown and sf:IsShown() and sf.PostButton then return sf.PostButton end
  end
end

Pad.PostButtonNow = postButtonNow

--- True while the auction window shows one of its sell forms (an item, a stackable good, a token).
function Pad.ahOnSellTab()
  local ah = rawget(_G, "AuctionHouseFrame")
  if not ah then return false end
  for _, key in ipairs({ "ItemSellFrame", "CommoditiesSellFrame", "WoWTokenSellFrame" }) do
    local f = ah[key]
    if f and f.IsShown and f:IsShown() then return true end
  end
  return false
end

--- The game's controller cursor moves between a list of buttons it takes a snapshot of when a window opens and again
--- whenever a frame is created under that window (SmartNavigation hooks CreateFrame). An item placed from the Buy tab
--- switches the auction window to the Sell tab without creating anything, so the snapshot stays the Buy tab's: the
--- cursor can only reach that tab's column header, Refresh and Close. A throwaway child frame under the sell form makes
--- the game take the snapshot again, with the sell form in it. (The game's own hook does the refresh; we only create a
--- frame, and the hook runs in the game's context, not ours.)
function Pad:KickAuctionNav(why)
  if CB:IsOff("ahnav") then return end          -- (/baggler off ahnav: to find out whether these touches cause a game error)
  local ah = rawget(_G, "AuctionHouseFrame")
  if not ah or not (ah.IsShown and ah:IsShown()) then return end
  local parent
  for _, key in ipairs({ "ItemSellFrame", "CommoditiesSellFrame" }) do
    local f = ah[key]
    if f and f.IsShown and f:IsShown() then parent = f; break end
  end
  parent = parent or ah
  local ok, f = pcall(CreateFrame, "Frame", nil, parent)
  if ok and f then f:SetSize(1, 1); f:Hide() end
  Pad.navKicks = (Pad.navKicks or 0) + 1
  CB:Journal("pad", ("auction cursor refresh (%s) under %s: %s"):format(tostring(why), parent == ah and "window" or "sell form", ok and "ok" or tostring(f)))
end

local navHooked, navLines = false, 0

--- Read-only look at the game's cursor: which window it is confined to, how many buttons it knows in the auction
--- window, and for every clickable widget of the shown sell form whether it is in that list and whether the cursor
--- would accept it (visible, laid out). This is what tells a stale list from a wrong window from a direction problem.
function Pad:NavDump(why)
  navLines = 0
  Pad:HookNavProbe()
  local sn = rawget(_G, "SmartNavigation")
  local ah = rawget(_G, "AuctionHouseFrame")
  local function nm(f) return f and ((f.GetDebugName and f:GetDebugName()) or (f.GetName and f:GetName())) or "nil" end
  local function J(fmt, ...) CB:Journal("nav", fmt:format(...)) end
  if not sn or not ah then J("%s: no cursor module or no auction window", tostring(why)); return end
  local active = sn.activeInfo
  J("%s: active window=%s panels=%d", tostring(why), nm(active and active.frame), sn.activePanels and #sn.activePanels or -1)
  local info
  for _, p in ipairs(sn.activePanels or {}) do if p.frame == ah then info = p end end
  if not info then J("auction window is not a registered panel"); return end
  local inList = {}
  local g = info.buttonGroups
  local main = g and g.mainGroup and g.mainGroup.buttons or {}
  for _, b in ipairs(main) do inList[b] = true end
  local nScroll = 0
  for _, sf in ipairs(g and g.mainGroup and g.mainGroup.scrollFrames or {}) do
    nScroll = nScroll + 1
    for _, b in ipairs(sf.buttons or {}) do inList[b] = true end
  end
  J("known buttons: main=%d scrollLists=%d focusedKey=%s lastButton=%s", #main, nScroll, tostring(info.focusedKey), nm(info.lastButton))
  local form
  for _, key in ipairs({ "ItemSellFrame", "CommoditiesSellFrame", "WoWTokenSellFrame" }) do
    local f = ah[key]
    if f and f.IsShown and f:IsShown() then form = f; key = key; break end
  end
  if not form then J("no sell form shown"); return end
  local lines, missing = 0, 0
  local function walk(f, depth)
    for _, c in ipairs({ f:GetChildren() }) do
      local interactive = c:IsObjectType("Button") or c:IsObjectType("EditBox")
      if interactive then
        local ok = c.IsVisible and c:IsVisible()
        local rect = c.IsRectValid and c:IsRectValid()
        local w, h = c:GetSize()
        if not inList[c] then missing = missing + 1 end
        if lines < 40 then
          lines = lines + 1
          J("  %s known=%s visible=%s rect=%s size=%sx%s", nm(c), tostring(inList[c] or false), tostring(ok), tostring(rect),
            tostring(w and math.floor(w + 0.5)), tostring(h and math.floor(h + 0.5)))
        end
      end
      if depth < 6 then walk(c, depth + 1) end
    end
  end
  walk(form, 0)
  J("sell form widgets missing from the cursor's list: %d", missing)
end

--- Observe-only recorder for the game's cursor while the auction window is up: every selection, every direction press
--- (did the cursor move; if not, how far off the 45 degree cone each sell-form widget was), and who suspends the cursor
--- or makes another window the active one. Hooks run after the game's own code and change nothing.
local function navLog(fmt, ...)
  if navLines >= 120 then return end
  navLines = navLines + 1
  CB:Journal("nav", fmt:format(...))
end
function Pad:HookNavProbe()
  local sn = rawget(_G, "SmartNavigation")
  if navHooked or not sn then return end
  navHooked = true
  local function nm(f) return f and ((f.GetDebugName and f:GetDebugName()) or (f.GetName and f:GetName())) or "nil" end
  local function ahUp() local ah = rawget(_G, "AuctionHouseFrame"); return ah and ah:IsShown() end
  pcall(hooksecurefunc, sn, "SelectButton", function(self, b)
    if ahUp() then navLog("select %s (cursor suspended=%s)", nm(b), tostring(self.isCursorSuspended)) end
  end)
  pcall(hooksecurefunc, sn, "SetActiveFrame", function(self, info)
    if ahUp() then navLog("active window is now %s", nm(info and info.frame)) end
  end)
  pcall(hooksecurefunc, sn, "SuspendCursor", function(self, on)
    if ahUp() then navLog("cursor suspended=%s", tostring(on)) end
  end)
  pcall(hooksecurefunc, sn, "Navigate", function(self, dir)
    if not ahUp() then return end
    local cur = self.currentButton
    navLog("press x=%.0f y=%.0f -> cursor on %s | active=%s suspended=%s", dir.x or 0, dir.y or 0, nm(cur),
      nm(self.activeInfo and self.activeInfo.frame), tostring(self.isCursorSuspended))
    -- how the sell form looks from where the cursor is: angle between the press and the way to each widget
    local ah = rawget(_G, "AuctionHouseFrame")
    if not cur or not cur.GetScaledRect then return end
    local cx, cy, cw, ch = cur:GetScaledRect()
    if not cx then return end
    cx, cy = cx + cw / 2, cy + ch / 2
    local len = math.sqrt((dir.x or 0) ^ 2 + (dir.y or 0) ^ 2)
    if len == 0 then return end
    for _, key in ipairs({ "ItemSellFrame", "CommoditiesSellFrame" }) do
      local sf = ah[key]
      if sf and sf:IsShown() then
        for _, w in ipairs({ sf.PostButton, sf.Overlay, sf.ItemDisplay, sf.Duration and sf.Duration.Dropdown }) do
          if w and w.GetScaledRect then
            local x, y, ww, hh = w:GetScaledRect()
            if x then
              local dx, dy = x + ww / 2 - cx, y + hh / 2 - cy
              local d = math.sqrt(dx * dx + dy * dy)
              local ang = d > 0 and math.deg(math.acos(math.max(-1, math.min(1, (dx * dir.x + dy * dir.y) / (d * len))))) or -1
              navLog("   %s angle=%.0f dist=%.0f valid=%s", nm(w), ang, d, tostring(self:IsButtonValid(w)))
            end
          end
        end
      end
    end
  end)
  CB:Journal("nav", "cursor recorder installed")
end

--- The game's cursor picks the nearest button inside a 45 degree cone. Pressing Left on the listing's column headers or
--- Refresh button, the nearest one is always one of the listing's own rows (they sit below and further left), so the
--- cursor never gets to the sell form, even though every form widget is in its list and valid (journal [nav] lines).
--- The game provides jump overrides for exactly this: "from this button, Left goes to that button". They are plain
--- data on the buttons, set out of combat, and the game's own code does the move. Rows already sit left of the form and
--- need nothing but are covered too, in case their order changes.
function Pad:LinkAuctionNav(why)
  if CB:IsOff("ahnav") then return end
  local ah = rawget(_G, "AuctionHouseFrame")
  local add, dirs = rawget(_G, "SmartNavigation_AddJumpNavigationOverride"), rawget(_G, "SMART_NAV_INPUT_DIRECTION")
  if not ah or not add or not dirs or not dirs.LEFT or Pad.InCombat() then return end
  local form, list
  if ah.ItemSellFrame and ah.ItemSellFrame:IsShown() then form, list = ah.ItemSellFrame, ah.ItemSellList
  elseif ah.CommoditiesSellFrame and ah.CommoditiesSellFrame:IsShown() then form, list = ah.CommoditiesSellFrame, ah.CommoditiesSellList end
  if not form or not list then return end
  local target = form.ItemDisplay and form.ItemDisplay.ItemButton or form.PostButton
  if not target then return end
  local n = 0
  local function link(b)
    if b and b.IsObjectType and (b:IsObjectType("Button") or b:IsObjectType("EditBox")) then
      local ok = pcall(add, b, dirs.LEFT, target)
      if ok then n = n + 1 end
    end
  end
  if list.HeaderContainer then for _, c in ipairs({ list.HeaderContainer:GetChildren() }) do link(c) end end
  link(list.RefreshFrame and list.RefreshFrame.RefreshButton)
  if list.ScrollBox and list.ScrollBox.ForEachFrame then pcall(list.ScrollBox.ForEachFrame, list.ScrollBox, link) end
  Pad.navLinks = (Pad.navLinks or 0) + 1
  CB:Journal("pad", ("auction cursor: Left from the listing now goes to the sell form (%s): %d buttons linked to %s"):format(
    tostring(why), n, (target.GetDebugName and target:GetDebugName()) or "?"))
end

--- Kick a few times after the window changes: the new tab's contents settle over a moment.
function Pad:KickAuctionNavSoon(why)
  Pad:HookNavProbe()
  for _, delay in ipairs({ 0.15, 0.6, 1.5 }) do
    C_Timer.After(delay, function() Pad:KickAuctionNav(why); Pad:LinkAuctionNav(why) end)
  end
  C_Timer.After(2.0, function() Pad:NavDump("2s after " .. tostring(why)) end)
end

--- The top row of the listings beside the sell form: the cheapest current auction, since the game sorts them that way.
--- Selecting a row copies its price into the sell form, which is what makes Create Auction usable; the game's cursor
--- cannot reach these rows. nil when the list is empty or not built yet.
local PICK_KEY = "PAD3"
local function pickRowNow()
  local ah = rawget(_G, "AuctionHouseFrame")
  if not ah then return nil end
  local list
  if ah.ItemSellFrame and ah.ItemSellFrame:IsShown() then list = ah.ItemSellList
  elseif ah.CommoditiesSellFrame and ah.CommoditiesSellFrame:IsShown() then list = ah.CommoditiesSellList end
  local box = list and list.ScrollBox
  if not (box and box.GetFrames) then return nil end
  local ok, frames = pcall(box.GetFrames, box)
  if not ok or type(frames) ~= "table" then return nil end
  local best, bestTop
  for _, f in ipairs(frames) do
    local top = f.IsShown and f:IsShown() and f.GetTop and f:GetTop()
    if top and (not bestTop or top > bestTop) then best, bestTop = f, top end
  end
  return best
end

--- Aims the proxy at whichever sell frame is showing. Out of combat only (secure attributes).
function Pad:SyncPostProxy()
  if Pad.InCombat() then return end
  local want = Pad.holdGame ~= nil and Pad.holdGame == rawget(_G, "AuctionHouseFrame") and Pad.frameVisible(Pad.holdGame)
  local btn = Pad.postProxy
  if not want then return end
  if not btn then
    local ok, b = pcall(CreateFrame, "Button", "BagglerPadPostAH", UIParent, "SecureActionButtonTemplate")
    if not ok or not b then return end
    b:SetSize(1, 1); b:SetAlpha(0); b:EnableMouse(false)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "click")
    Pad.postProxy = b
    btn = b
  end
  local target = postButtonNow()
  if btn:GetAttribute("clickbutton") ~= target then btn:SetAttribute("clickbutton", target) end
  local pick = Pad.pickProxy
  if not pick then
    local ok, b = pcall(CreateFrame, "Button", "BagglerPadPickAH", UIParent, "SecureActionButtonTemplate")
    if ok and b then
      b:SetSize(1, 1); b:SetAlpha(0); b:EnableMouse(false)
      b:RegisterForClicks("AnyUp", "AnyDown")
      b:SetAttribute("type", "click")
      Pad.pickProxy, pick = b, b
    end
  end
  local row = pickRowNow()
  if pick and pick:GetAttribute("clickbutton") ~= row then pick:SetAttribute("clickbutton", row) end
  -- the keys are only bound while there is something to press; a tab change or a list filling turns them on or off
  local sig = (target and "P" or "") .. (row and "R" or "")
  if sig ~= (Pad.postSig or "") and not Pad.postApplying then
    Pad.postApplying = true
    Pad:Apply("post button")
    Pad.postApplying = false
  end
  -- journal only when the picture changes: which Post button, whether it is enabled, and what the key is bound to
  local okB, act = pcall(GetBindingAction, POST_KEY, true)
  local line = ("post proxy: row=%s target=%s enabled=%s %s=%s"):format(row and "yes" or "none", target and (target:GetParent() == rawget(_G, "AuctionHouseFrame").ItemSellFrame and "item" or "commodity") or "none",
    tostring(target and target:IsEnabled()), POST_KEY, tostring(okB and act or "?"))
  if line ~= Pad.lastPostLine then Pad.lastPostLine = line; CB:Journal("pad", line) end
end

-- The native return route is now an InputSession Visit, not a second catcher.

--- True while one of the *game's* bank windows is open (we only dress the bank when asked to).
--- Its controller cursor needs the buttons; our bags stay clickable with that cursor.
function Pad:BlizzardPanelOpen()
  -- Native visit windows participate in the existing HoldGame/Start hand-off.
  -- After an explicit return to bags Push marks that window declined; do not
  -- immediately hand off again merely because the native panel remains open.
  if CB.NativeWindows then return false end
  local function shown(f) return f and f.IsShown and f:IsShown() end
  local concealed = function(f) return f ~= nil and CB.UI:IsConcealed(f) end
  -- (the bank's inner panel is judged by the bank frame it sits in: its own "shown" flag stays set while the frame is hidden)
  if shown(rawget(_G, "BankFrame")) and not concealed(rawget(_G, "BankFrame")) then return true end
  if shown(rawget(_G, "GuildBankFrame")) and not concealed(rawget(_G, "GuildBankFrame")) then return true end
  if shown(rawget(_G, "TradeFrame")) and not (CB.Trade and CB.Trade.parked) then return true end
  if shown(rawget(_G, "MailFrame")) and not (CB.Mail and CB.Mail.parked) then return true end
  return false
end

local function frameVisible(f) return f and f.IsVisible and f:IsVisible() and true or false end
Pad.frameVisible = frameVisible

--- Secure stand-in. Clicking it runs `/use bag slot` on the hardware event, so a grimoire
--- (or any other item that opens a confirmation) is the game's use, not an add-on call.
function Pad:UseButton()
  if self.useButton then return self.useButton end
  if self.useButtonFailed then return nil end
  local ok, b = pcall(CreateFrame, "Button", "BagglerPadUse", UIParent, "SecureActionButtonTemplate")
  if not ok or not b then
    self.useButtonFailed = true
    CB:Warn("pad", "secure item use unavailable: " .. tostring(b))
    return nil
  end
  b:SetSize(1, 1)
  b:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
  b:SetAlpha(0)
  b:EnableMouse(false)
  b:RegisterForClicks("AnyUp", "AnyDown")
  -- Items that put the game into a placement mode (a campfire, a ground-targeted spell) need the controller back,
  -- and B would cancel the placement instead of closing us. So when such a use starts, close our window ourselves.
  -- PostClick on a secure button only observes; it never touches the protected action.
  b:HookScript("PostClick", function() Pad:CloseForPlacement() end)
  self.useButton = b
  return b
end

--- True when the item under the controller starts a placement (named like a campfire) or the game is now targeting.
--- The check runs a moment after the click, once the game has entered its targeting state.
function Pad:CloseForPlacement()
  local rec = self.lastUseRec
  -- At the native auction house, A puts the item in the sell slot; the Post button is the game window's, so
  -- hand the controller to it now rather than leaving the player to find the Start hop.
  local ah = rawget(_G, "AuctionHouseFrame")
  CB:Journal("pad", ("use clicked: ah=%s visible=%s stack=%d hold=%s ahSwitch=%s"):format(tostring(ah ~= nil),
    tostring(ah and frameVisible(ah)), #self.stack, tostring(self.holdGame ~= nil), tostring(CB.db.ahSwitch)))
  if ah and frameVisible(ah) and #self.stack > 0 and not self.holdGame and CB.db.ahSwitch ~= false then
    C_Timer.After(0.2, function()
      if frameVisible(ah) and #Pad.stack > 0 and not Pad.holdGame then Pad:HoldGame(ah, "auction house", true, true) end
    end)
    return
  end
  C_Timer.After(0.25, function()
    local placing = SpellIsTargeting and SpellIsTargeting()
    if not placing and rec and rec.itemID and GetItemSpell then
      local name = GetItemSpell(rec.itemID)
      placing = type(name) == "string" and name:lower():find("campfire", 1, true) ~= nil
    end
    local W = CB.Window
    if placing and W and W.frame and W.frame:IsShown() and not W.merchantOpen then
      CB:Info("use", "placement started: closing the bags so the game gets the controller")
      W:Close()
    end
  end)
end

--- Points the secure button at a bag slot. Does not click and does not rebind.
function Pad:WriteMacro(bag, slot)
  if Pad.InCombat() then return false end
  bag, slot = tonumber(bag), tonumber(slot)
  if not bag or not slot then return false end
  bag, slot = math.floor(bag), math.floor(slot)
  local btn = self:UseButton()
  if not btn then return false end
  local text = "/use " .. bag .. " " .. slot
  local okInfo, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  self.lastUseRec = okInfo and info and { itemID = info.itemID } or nil
  -- at the native auction house the same press goes through Blizzard's bag-button click, which puts the item
  -- into the sell slot (a plain /use would not)
  local route, refused
  if CB.Window and CB.Window.AuctionRoute then route, refused = CB.Window:AuctionRoute(bag, slot) end
  -- an item the auction house refuses: no secure press at all (a /use would equip or use it at the auction house);
  -- A goes to Baggler' own use, which only says it can't be auctioned
  if refused then return false end
  if route then
    text = "/click " .. route .. " RightButton"
    -- Placing an item while the window is on another tab makes the game switch tabs itself, and its controller cursor
    -- keeps the old tab's layout (stuck on the Buy list, Create Auction out of reach). Opening the Sell tab first,
    -- as a real click on its tab button, sets the cursor up properly. Both clicks ride the same key press.
    local ah = rawget(_G, "AuctionHouseFrame")
    local sellTab = ah and ah.SellTab and ah.SellTab.GetName and ah.SellTab:GetName()
    if sellTab and not Pad.ahOnSellTab() then text = "/click " .. sellTab .. "\n" .. text end
  end
  if not pcall(btn.SetAttribute, btn, "type", "macro") then return false end
  if not pcall(btn.SetAttribute, btn, "macrotext", text) then return false end
  return true
end

--- Rebind A when the highlighted item starts or stops being a direct use.
function Pad:SyncDirectUse()
  if self.syncing or Pad.InCombat() or self.handedOff or useCatcher() then return end
  self.syncing = true
  local top = self:Top()
  local rec = top and top.directUse and top.directUse()
  local armed = false
  if type(rec) == "table" and rec.bag ~= nil and rec.slot ~= nil and not rec.empty then
    if self:WriteMacro(rec.bag, rec.slot) then armed = true end
  end
  -- B can be the game's own Escape command (see Vendor.closeCommand); it changes with a search, menu or held item
  local sc = top and top.secureCommand and top.secureCommand("close") or nil
  local su = top and top.secureCommand and top.secureCommand("use") or nil       -- (a window may make A a game command too)
  if sc ~= self.closeCmd or su ~= self.useCmd then self.closeCmd, self.useCmd = sc, su; self:Apply("close command") end
  if armed ~= (self.directArmed and true or false) then self:Apply("direct use") end
  self.syncing = false
end

--- Returns true when the secure click was issued. False means the caller should fall back.
--- Menu rows and mouse clicks use this. A on a highlighted item is bound to the button itself.
--- Whether secure buttons act on key DOWN (the default in current clients) or on release.
--- A button clicked with the wrong phase silently does nothing, so the click must match.
function Pad:UsesKeyDown()
  if GetCVarBool then
    local ok, v = pcall(GetCVarBool, "ActionButtonUseKeyDown")
    if ok and v ~= nil then return v and true or false end
  end
  return true
end


-- All twelve ordinary buttons already have defaults (including R3 sort and
-- Start switchWindow); auction PAD3/PAD4 live in a separate native-window claim.
-- At a vendor the bags' filter button (RT by default) sells all junk instead: one button,
-- no chord, so nothing else (fold, sort) can fire by accident. Filtering stays reachable
-- from the top-row controls (Up -> Filter). The footer hint line shows it.
local function junkContext()
  local W = CB.Window
  return W and Pad:Top() == W.ctx and W:IsOpen() and Pad:Active()
    and not Pad.handedOff and not Pad.holdGame and not Pad.yield and not Pad.InCombat()
    and not W.sizing and not W.searching and not W.chrome and not CursorHasItem()
    and CB.NativeWindows and CB.NativeWindows:Context() == "merchant" and true or false
end
Pad.JunkContext = junkContext
-- the footer hint line gains / loses "Sell junk" as a vendor opens and closes
local function refreshJunkHint()
  C_Timer.After(0, function()
    local W = CB.Window
    if W and W.IsOpen and W:IsOpen() and W.RefreshPadHint then W:RefreshPadHint() end
  end)
end
CB:RegisterEvent("MERCHANT_SHOW", refreshJunkHint)
CB:RegisterEvent("MERCHANT_CLOSED", refreshJunkHint)

--- Hop between the open Baggler windows (vendor, bank, bags). Returns true if it moved.
--- Every Baggler window that is open right now, as { ctx, focusFn } in a fixed order.
function Pad:WindowList()
  local list = {}
  local V, B, W = CB.Vendor, CB.Bank and CB.Bank.window, CB.Window
  if V and V.ctx and V.atMerchant and V.frame and V.frame:IsShown() then list[#list + 1] = { V.ctx, function() V:Focus() end } end
  -- coming back to a window re-draws its selection ring (it hides while the window does not have the controller)
  local function refocus(win)
    Pad:Push(win.ctx)
    if win.selEntry and win.SelectEntry then win:SelectEntry(win.selEntry, true, true) else win:SelectFirstIfNone() end
  end
  if B and B.IsOpen and B:IsOpen() then list[#list + 1] = { B.ctx, function() refocus(B) end } end
  if W and W.IsOpen and W:IsOpen() then list[#list + 1] = { W.ctx, function() refocus(W) end } end
  for _, extra in pairs(CB.PadWindows or {}) do
    if extra.open() then list[#list + 1] = { extra.ctx(), extra.focus } end
  end
  for _, g in ipairs(Pad:GameWindowList()) do list[#list + 1] = g end
  return list
end

--- True when there is a bank, guild bank or trade window to send an item to.
function Pad:QuickMoveOpen()
  if CB.NativeWindows then
    local context = CB.NativeWindows:Context()
    return context == "bank" or context == "guildbank" or context == "trade" or context == "mail"
  end
  return (CB.Bank and CB.Bank.active) or (CB.GuildBank and CB.GuildBank.active) or (CB.Trade and CB.Trade.active) or (CB.Mail and CB.Mail:SendActive()) and true or false
end

--- True while a visit worth recording is under way (vendor, bank, guild bank, auction house ...).
function Pad:Tracing()
  if (CB.Vendor and CB.Vendor.atMerchant) or (CB.Bank and CB.Bank.active) or (CB.GuildBank and CB.GuildBank.active) then return true end
  for _, g in ipairs(Pad.GAME_WINDOWS or {}) do
    if g.keepOpt and frameVisible(g.frame()) then return true end
  end
  for _, extra in pairs(CB.PadWindows or {}) do
    if extra.open() then return true end
  end
  return false
end

--- Moves the controller to the next window (step 1) or the previous one (step -1).
--- True when a window-switch press would do something: another window is open, or the bags can be opened
--- next to a visit window (guild bank, mail, trade, bank, vendor ... that has no bags open beside it).
function Pad:CanSwitch()
  local n = #Pad:WindowList()
  if n >= 2 then return true end
  return n == 1 and CB.Window and not CB.Window:IsOpen() and Pad:Tracing() and true or false
end

-- Moves the controller to the next window (step 1) or the previous one (step -1). With only a
-- visit window up, it opens the bags first and hops to them.
function Pad:SwitchWindow(step)
  step = step or 1
  CB:Journal("pad", ("switch step=%d from=%s windows=%d"):format(step, Pad.holdGame and "game window" or (Pad:Describe():match("stack=%[([^%]]*)") or "?"), #Pad:WindowList()))
  -- a visit window with no bags beside it: open the bags first, then hop to them
  if #Pad:WindowList() == 1 and CB.Window and not CB.Window:IsOpen() and not Pad.InCombat() and Pad:Tracing() then
    CB.Window:Open()                              -- opening takes the controller to the bags
    if CB.Window.SelectFirstIfNone then CB.Window:SelectFirstIfNone() end
    return true
  end
  local top = Pad.holdGame or Pad:Top()
  local list = Pad:WindowList()
  if Pad:Tracing() then
    CB:Info("padswitch", ("step %d: %d window(s), top is %s | %s"):format(step, #list,
      (CB.Window and top == CB.Window.ctx and "bags") or "other", Pad:Describe():sub(1, 140)))
  end
  if #list == 0 then return false end
  local at = 0
  for i, item in ipairs(list) do if item[1] == top then at = i end end
  if #list == 1 and at == 1 then return false end
  local target = list[((at - 1 + step) % #list) + 1]
  target[2]()
  -- Make sure the hop stuck: if one of the other windows took the controller straight back (something else
  -- pushed it), say so in the journal and finish the hop. A newer press or a menu opening cancels the check.
  Pad.hopToken = (Pad.hopToken or 0) + 1
  local token = Pad.hopToken
  C_Timer.After(0.3, function()
    -- (a game window is held, not pushed: nothing to verify there)
    if token ~= Pad.hopToken or Pad.holdGame or Pad:Top() == target[1] then return end
    if type(target[1]) ~= "table" or type(target[1].alive) ~= "function" then return end
    local top = Pad:Top()
    for _, item in ipairs(Pad:WindowList()) do
      if item[1] == top then
        CB:Journal("pad", "a hop was undone: " .. Pad:Describe():sub(1, 60) .. " - moving the controller again")
        target[2]()
        return
      end
    end
  end)
  return true
end

--- True when nothing lies further `dir` along the same row, so a sideways press
--- should leave the window instead of wrapping to the next row.
function Pad:RowEdge(entries, cur, dir)
  if not cur or (dir ~= "left" and dir ~= "right") then return false end
  for _, e in ipairs(entries) do
    if e ~= cur and math.abs(e.cy - cur.cy) < 8 then
      local dx = (dir == "right") and (e.cx - cur.cx) or (cur.cx - e.cx)
      if dx > 4 then return false end
    end
  end
  return true
end

--- One-line description of who holds the controller, for /baggler pad.
function Pad:Describe()
  return ("contexts=%d bound=%s native=%s text=%s combat=%s"):format(#self.stack,tostring(self.bound),tostring(self.handedOff),tostring(self.yield),tostring(self.suspended))
end

--- True when a direction pressed at the edge of a window may walk into the next one. Not while the button is held
--- (the repeat would carry on through the next window too) and not straight after a window switch, so a stick
--- resting off-centre cannot undo a hop.
function Pad:CanEdgeWalk()
  if Pad.lastRepeat then return false end
  return not (Pad.lastSwitch and GetTime() - Pad.lastSwitch < 0.6)
end

---------------------------------------------------------------------------
-- Geometry: pick the neighbour of `cur` in direction `dir` from `entries`.
-- Each entry needs cx, cy (centre, y grows downward).
---------------------------------------------------------------------------
function Pad:Neighbor(entries, cur, dir)
  if not cur then return entries[1] end
  local best, bestScore
  for _, e in ipairs(entries) do
    if e ~= cur then
      local dx, dy = e.cx - cur.cx, e.cy - cur.cy
      local primary, secondary
      if dir == "right" then primary, secondary = dx, math.abs(dy)
      elseif dir == "left" then primary, secondary = -dx, math.abs(dy)
      elseif dir == "down" then primary, secondary = dy, math.abs(dx)
      else primary, secondary = -dy, math.abs(dx) end
      if primary > 4 then
        local score = primary + secondary * 3
        if not bestScore or score < bestScore then best, bestScore = e, score end
      end
    end
  end
  if best then return best end

  -- Horizontal wrap: continue onto the next/previous row.
  if (dir == "left" or dir == "right") and not (CB.db and CB.db.rowWrap == false) then
    local wantDown = dir == "right"
    local rowBest, rowScore
    for _, e in ipairs(entries) do
      local dy = e.cy - cur.cy
      if (wantDown and dy > 4) or (not wantDown and dy < -4) then
        local score = math.abs(dy) * 1000 + (wantDown and e.cx or -e.cx)
        if not rowScore or score < rowScore then rowBest, rowScore = e, score end
      end
    end
    return rowBest
  end
  return nil
end

---------------------------------------------------------------------------
-- State changes
---------------------------------------------------------------------------
-- Switching between keyboard/mouse and controller, plugging/unplugging, loading screens:
-- re-check that what is bound matches what is open.
for _, ev in ipairs({ "GAME_PAD_ACTIVE_CHANGED", "GAME_PAD_CONNECTED", "GAME_PAD_DISCONNECTED",
                      "PLAYER_ENTERING_WORLD", "LOADING_SCREEN_DISABLED", "CVAR_UPDATE" }) do
  CB:RegisterEvent(ev, function(event)
    Pad:StopRepeat()
    Pad:Reconcile(event)
  end)
end
-- The game's own bank / guild bank opening or closing: settle shortly after it has drawn.
for _, ev in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED" }) do
  CB:RegisterEvent(ev, function(event)
    if C_Timer and C_Timer.After then
      C_Timer.After(0.2, function() Pad:Reconcile(event) end)
      C_Timer.After(0.55, function() Pad:Reconcile(event) end)
      C_Timer.After(0.8, function() Pad:Reconcile(event) end)
    end
  end)
end
-- A confirmation or a targeting cursor opened by an item has to receive the controller
-- on the same press, not half a second later.
-- (done by the 0.1s check below, not by hooking the game's StaticPopup_Show)
for _, ev in ipairs({ "CURRENT_SPELL_CAST_CHANGED", "CURSOR_CHANGED" }) do
  CB:RegisterEvent(ev, function()
    if Pad:GameNeedsPad() then Pad:HandOff("spell")
    else Pad:SyncDirectUse() end
  end)
end

--- The game's own controller system (InputFunctionBindingButton_*) can take a key back after
--- things like selling an item. If one of OUR keys now points elsewhere, take it back.
function Pad:ReclaimStolen()
  if not GetBindingAction then return false end
  if not (Pad.appliedBinds and #Pad.stack > 0 and not Pad.suspended and not Pad.handedOff and not Pad.yield
      and not Pad.InCombat()) then return false end
  -- Never fight the game: a popup, a targeting cursor or one of its own panels owns the pad right now.
  if Pad:GameNeedsPad() then return false end
  -- If the game keeps taking a key straight back (some panel of its own is driving), stand down.
  local t = GetTime and GetTime() or 0
  if Pad.standDownUntil and t < Pad.standDownUntil then return false end
  Pad.recent = Pad.recent or {}
  for i = #Pad.recent, 1, -1 do if t - Pad.recent[i] > 3 then table.remove(Pad.recent, i) end end
  if #Pad.recent >= 6 then
    Pad.standDownUntil = t + 10
    Pad.recent = {}
    CB:Warn("pad", "the game keeps retaking the controller; standing down for 10 seconds")
    return false
  end
  for _, b in ipairs(Pad.appliedBinds) do
    local ok, act = pcall(GetBindingAction, b[1], true)
    local now = GetTime and GetTime() or 0
    local expected = b[3] and b[2] or ("CLICK " .. b[2] .. ":LeftButton")
    if ok and act ~= expected and now - (Pad.lastFix or -1) > 0.3 then
      Pad.lastFix = now
      Pad.recent[#Pad.recent + 1] = now
      Pad.stolen = (Pad.stolen or 0) + 1
      CB:Info("padbind", ("%s was taken by '%s'; taking it back (#%d)"):format(b[1], tostring(act), Pad.stolen))
      Pad:Apply("binding taken by the game")
      return true
    end
  end
  return false
end

-- Passive binding check (merchant visits only): record whenever what A / Start are bound to changes.
-- It reads the binding table; it never touches input. If A "stops working", this shows whether the
-- override was lost, replaced by another click target, or never changed.
do
  local last = {}
  local watch = CreateFrame("Frame")
  local acc = 0
  watch:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < 0.1 then return end
    acc = 0
    if not GetBindingAction then return end
    Pad:ReclaimStolen()
    Pad:AmbientCheck()
    if Pad.postProxy and Pad.holdGame then Pad:SyncPostProxy() end
    -- A is aimed at a different secure click while the native auction house is up (see View:AuctionRoute)
    local ah = rawget(_G, "AuctionHouseFrame")
    local ahUp = ah and ah.IsVisible and ah:IsVisible() and true or false
    -- the tab matters too: A clicks the Sell tab first when the window is somewhere else (see WriteMacro)
    local ahTab = ahUp and Pad.ahOnSellTab() or false
    if ahUp ~= Pad.ahWasUp or ahTab ~= Pad.ahWasSell then
      local upChanged = ahUp ~= Pad.ahWasUp
      Pad.ahWasSellBefore = Pad.ahWasSell
      Pad.ahWasUp, Pad.ahWasSell = ahUp, ahTab
      Pad:SyncDirectUse()
      if upChanged and CB.Window and CB.Window.SyncNativeClick then CB.Window:SyncNativeClick() end   -- the mouse path (WindowUse)
      if ahTab and not Pad.ahWasSellBefore then Pad:KickAuctionNavSoon("sell form appeared") end     -- the cursor snapshot is stale
    elseif CB.Window and CB.Window.nativeClickPending then CB.Window:SyncNativeClick() end
    if #Pad.stack > 0 and not Pad.handedOff and not Pad.holdGame and Pad:GameNeedsPad() then Pad:HandOff("popup") end
    if not Pad:Tracing() then return end
    for _, key in ipairs({ "PAD1", "PAD2", "PADFORWARD", "PADLTRIGGER", "PADRTRIGGER" }) do
      local ok, act = pcall(GetBindingAction, key, true)
      act = ok and act or "?"
      if last[key] ~= act then
        CB:Info("padbind", ("%s: '%s' -> '%s' | handedOff=%s bound=%s armed=%s"):format(key, tostring(last[key]), tostring(act),
          tostring(Pad.handedOff), tostring(Pad.bound), tostring(Pad.directArmed)))
        last[key] = act
      end
    end
  end)
end

-- The game re-applies its own bindings on this event; check ours straight afterwards.
-- Watchdog: twice a second, while anything is captured, confirm it is still wanted.
local dog = NewFrame("Frame")
local acc = 0
dog:SetScript("OnUpdate", function(_, dt)
  acc = acc + dt
  if acc < 0.5 then return end
  acc = 0
  if #Pad.stack > 0 or Pad.bound then Pad:Reconcile("watchdog") end
end)
