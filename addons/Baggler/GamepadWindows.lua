-- Baggler controller: handing the controller to the game's own windows (auction house, character panel ...) and
-- taking it back. (Split from Gamepad.lua; the Pad table and its helpers are shared through CB.Pad.)
local ADDON, CB = ...
local Pad = CB.Pad
local frameVisible = Pad.frameVisible

-- The game's own windows Baggler can hand the controller to and take it back from (Start toggles).
Pad.GAME_WINDOWS = {
  { name = "bank", keepOpt = "nativeSwitch", ambient = true, frame = function()
    local f = rawget(_G, "BankFrame")
    if (CB.Bank and CB.Bank.active) or (f and CB.UI:IsConcealed(f)) then return nil end
    return f
  end },
  { name = "guild bank", keepOpt = "nativeSwitch", ambient = true, frame = function() return rawget(_G, "GuildBankFrame") end },
  { name = "merchant", keepOpt = "nativeSwitch", ambient = true, frame = function() return rawget(_G, "MerchantFrame") end },
  { name = "mail", keepOpt = "nativeSwitch", ambient = true, frame = function() return rawget(_G, "MailFrame") end },
  { name = "trade", keepOpt = "nativeSwitch", ambient = true, frame = function() return rawget(_G, "TradeFrame") end },
  { name = "loot", keepOpt = "nativeSwitch", frame = function() return rawget(_G, "LootFrame") end },
  { name = "auction house", keepOpt = "ahSwitch", ambient = true, frame = function() return rawget(_G, "AuctionHouseFrame") end },
  { name = "crafting orders", keepOpt = "ahSwitch", ambient = true, frame = function() return rawget(_G, "ProfessionsCustomerOrdersFrame") end },
  { name = "trainer", keepOpt = "nativeSwitch", frame = function() return rawget(_G, "ClassTrainerFrame") end },
  { name = "flight map", frame = function() return rawget(_G, "TaxiFrame") end },
  { name = "barber shop", frame = function() return rawget(_G, "BarberShopFrame") end },
  { name = "transmogrifier", frame = function() return rawget(_G, "TransmogFrame") or rawget(_G, "WardrobeFrame") end },
  { name = "void storage", frame = function() return rawget(_G, "VoidStorageFrame") end },
  { name = "stable", frame = function() return rawget(_G, "StableFrame") or rawget(_G, "PetStableFrame") end },
  { name = "tabard designer", frame = function() return rawget(_G, "TabardFrame") end },
  { name = "guild registrar", frame = function() return rawget(_G, "GuildRegistrarFrame") end },
  { name = "petition", frame = function() return rawget(_G, "PetitionFrame") end },
  { name = "item upgrade", frame = function() return rawget(_G, "ItemUpgradeFrame") end },
  { name = "reforging", frame = function() return rawget(_G, "ReforgingFrame") end },
  { name = "scrapping machine", frame = function() return rawget(_G, "ScrappingMachineFrame") end },
  { name = "item interaction", frame = function() return rawget(_G, "ItemInteractionFrame") end },
  { name = "battlemaster", frame = function() return rawget(_G, "PVPQueueFrame") end },
  { name = "player choice", frame = function() return rawget(_G, "PlayerChoiceFrame") end },
  { name = "talent respec", frame = function() return rawget(_G, "PlayerTalentFrame") end },
  { name = "profession", keepOpt = "ahSwitch", frame = function() return rawget(_G, "ProfessionsFrame") end },
  -- the game's own panels you open next to the bags (your character to look at armour ...): the controller is
  -- theirs while they are up, and Start brings it back to the bags
  { name = "character", keepOpt = "ahSwitch", frame = function() return rawget(_G, "CharacterFrame") end },
  { name = "spellbook", keepOpt = "ahSwitch", frame = function() return rawget(_G, "PlayerSpellsFrame") or rawget(_G, "SpellBookFrame") end },
  { name = "collections", keepOpt = "ahSwitch", frame = function() return rawget(_G, "CollectionsJournal") end },
  { name = "group finder", keepOpt = "ahSwitch", frame = function() return rawget(_G, "PVEFrame") end },
  { name = "social", keepOpt = "ahSwitch", frame = function() return rawget(_G, "FriendsFrame") end },
  { name = "guild", keepOpt = "ahSwitch", frame = function() return rawget(_G, "CommunitiesFrame") or rawget(_G, "GuildFrame") end },
  { name = "world map", keepOpt = "ahSwitch", frame = function() return rawget(_G, "WorldMapFrame") end },
  { name = "quest log", keepOpt = "ahSwitch", frame = function() return rawget(_G, "QuestLogFrame") end },
  { name = "achievements", keepOpt = "ahSwitch", frame = function() return rawget(_G, "AchievementFrame") end },
  { name = "adventure guide", keepOpt = "ahSwitch", frame = function() return rawget(_G, "EncounterJournal") end },
  { name = "inspect", keepOpt = "ahSwitch", frame = function() return rawget(_G, "InspectFrame") end },
  { name = "socketing", keepOpt = "ahSwitch", frame = function() return rawget(_G, "ItemSocketingFrame") end },
  { name = "macros", keepOpt = "ahSwitch", frame = function() return rawget(_G, "MacroFrame") end },
  { name = "game menu", frame = function() return rawget(_G, "GameMenuFrame") end },
  { name = "settings", frame = function() return rawget(_G, "SettingsPanel") end },
  { name = "azerite / relics", frame = function() return rawget(_G, "AzeriteRespecFrame") end },
}


function Pad:GameWindowList()
  local out = {}
  for _, g in ipairs(Pad.GAME_WINDOWS) do
    local f = g.frame()
    if (g.keepOpt ~= "nativeSwitch" or CB.NativeWindows) and frameVisible(f) then
      local gg = g
      out[#out + 1] = { f, function() Pad:HoldGame(f, gg.name, false, gg.keepOpt and CB.db[gg.keepOpt]) end }
    end
  end
  return out
end

-- Native focus is an InputSession visit, including the zero-context return
-- case. Stable visit IDs survive ambient checks, so an explicit return to bags
-- is not undone by visibility polling. No direct receiver implementation here.
local observedFrame, visitID
function Pad:AmbientCheck()
  if not CB.db or Pad.InCombat() then return end
  if self.handedOff and not self.holdGame and self:GameNeedsPad() then
    self.input:Visit(nil);self:Apply("modal observation");return
  end
  local found, descriptor
  if not (CB.db.off and CB.db.off.autohold) then
    for _, window in ipairs(self.GAME_WINDOWS) do
      local frame=window.frame()
      if frameVisible(frame) and (window.ambient or #self.stack>0)
          and (window.keepOpt~="nativeSwitch" or CB.NativeWindows) then
        found,descriptor=frame,window;break
      end
    end
  end
  if found~=observedFrame then
    observedFrame=found
    visitID=found and {} or nil
  end
  if found then
    local allowed=descriptor.keepOpt and CB.db[descriptor.keepOpt]~=false or false
    local same=self.input.visit and self.input.visit.id==visitID
    self.input:Visit({id=visitID,kind=descriptor.name,allowed=allowed,keep=allowed})
    if not same and #self.stack>0 and self.declinedGame[found] then self.input:FocusBags() end
    if self.input.nativeFocus then
      self.holdGame,self.holdName,self.holdKeep=found,descriptor.name,allowed
      self.handedOff=true
    elseif self.holdGame==found then self.holdGame=nil;self.handedOff=false end
  else
    self.input:Visit(nil)
    if self.holdGame then self.holdGame=nil;self.handedOff=false end
  end
  self:Apply("native observation")
end
function Pad:HoldGame(frame,name,automatic,keep)
  if Pad.InCombat() or not frameVisible(frame) then return end
  -- An automatic hold (a window that just opened, the game re-opening the bags for a visit) never takes the controller
  -- from a modal that already has it: the dialog stays the receiver until it closes, then the bags get it back.
  -- Only the player's own pick (the Start window list, automatic=false) may override it.
  if automatic and not self.holdGame and self:ModalUp() then return end
  if frame~=observedFrame then observedFrame=frame;visitID={} end
  self.holdGame,self.holdName,self.holdKeep=frame,name,keep==true
  self.handedOff=true;self.yield=false
  self.input:Visit({id=visitID,kind=name,allowed=keep==true,keep=keep==true})
  self.input:FocusNative()
  self:Apply("native focus")
  if name=="auction house" then self:KickAuctionNavSoon("native focus") end
end

-- A game window that opens while Baggler holds the controller gets it automatically (Start hops to the bags
-- and back). Seen for a moment first, so windows Baggler itself takes over are never mistaken for these.
Pad.seenGame, Pad.declinedGame = {}, {}
-- Polls the known Blizzard windows. One that appears while a Baggler window has the controller
-- gets the controller handed over, unless it was declined before or a menu is open.
function Pad:AutoHoldCheck()
  if Pad.InCombat() then return end
  if CB.db and CB.db.off and CB.db.off.autohold then return end
  local now = GetTime and GetTime() or 0
  for _, g in ipairs(Pad.GAME_WINDOWS) do
    local f = g.frame()
    if f then
      if frameVisible(f) then
        Pad.seenGame[f] = Pad.seenGame[f] or now
        if now - Pad.seenGame[f] >= 0.3 and not Pad.declinedGame[f] and not Pad.holdGame and #Pad.stack > 0
           and not (CB.Menu and CB.Menu.IsOpen and CB.Menu:IsOpen()) then
          Pad:HoldGame(f, g.name, true, g.keepOpt and CB.db[g.keepOpt])
        end
      else
        Pad.seenGame[f], Pad.declinedGame[f] = nil, nil
      end
    end
  end
end

--- True while one of the game's modals (amount dialog, confirmation popup, spell-target cursor) is up. A modal is
--- on top of every native window, so it is the controller's receiver: no window hold may be taken over it.
function Pad:ModalUp()
  -- The game's own amount dialog (item menu "Split stack", shift-click): a modal, so it gets the controller like a popup.
  if frameVisible(rawget(_G, "StackSplitFrame")) then return true end
  if SpellIsTargeting and SpellIsTargeting() then return true end
  local n = STATICPOPUP_NUMDIALOGS or 4
  for i = 1, n do
    local f = _G["StaticPopup" .. i]
    -- visible, not merely "shown": a popup parked under a hidden parent is not something to wait on
    local vis = f and ((f.IsVisible and f:IsVisible()) or (not f.IsVisible and f.IsShown and f:IsShown()))
    if vis then return true end
  end
  return false
end

--- True while a confirmation or a spell-target cursor should own the controller.
function Pad:GameNeedsPad()
  if Pad.holdGame then
    if frameVisible(Pad.holdGame) then return true end
    Pad.holdGame = nil
  end
  if Pad:BlizzardPanelOpen() then return true end
  return Pad:ModalUp()
end

--- Give the game its buttons back without forgetting which window is open.
function Pad:HandOff(reason)
  if #self.stack == 0 then return end
  local fresh = not self.handedOff
  self.handedOff = true
  self.yield = false
  if fresh then
    self:Apply(reason or "handoff")
    self:NoteExternalUI()
  end
end

--- Take the controller back once that confirmation is gone.
function Pad:Reclaim(reason)
  if not self.handedOff then return end
  if #self.stack == 0 then self.handedOff = false; return end
  if self:GameNeedsPad() then return end
  self.handedOff = false
  self:Apply(reason or "reclaim")
end

-- READ-ONLY diagnostics for the amount dialog (journal + /baggler report). Nothing here calls a setter, binds a key,
-- replaces a game function or touches protected state: only secure post-hooks (hooksecurefunc / HookScript), which run after
-- the game's own code and cannot taint it. Each hook is a no-op unless a split trace is running.
local function nameOf(f)
  if f == nil then return "nil" end
  local n = type(f) == "table" and f.GetName and f:GetName()
  return n or tostring(f)
end
local function trace(what)
  local t = Pad.splitTrace
  if t and #t < 60 then t[#t + 1] = what end
end

--- Starts recording the game's focus/visibility calls in the order they happen (use around OpenStackSplitFrame).
function Pad:BeginSplitTrace()
  self:HookSplitHide()
  self.splitTrace = {}
  -- which of our item buttons carry the game's "owns the amount dialog" flag right now (a stale flag would close it)
  local flagged = {}
  local W = CB.Window
  for _, b in pairs(W and W.buttons or {}) do
    if b.hasStackSplit == 1 then flagged[#flagged + 1] = nameOf(b) end
  end
  trace("flagged tiles at open: " .. (#flagged > 0 and table.concat(flagged, ",") or "none"))
end

--- Read-only note from a Baggler item button's OnHide hook (runs after the game's own OnHide): which tile was hidden.
function Pad:TraceTileHide(b)
  if self.splitTrace then trace(("tile hidden %s flag=%s"):format(nameOf(b), tostring(b.hasStackSplit))) end
end

--- Ends the recording and writes it as ONE line: the order of native calls made while the dialog was being shown.
function Pad:EndSplitTrace()
  local t = self.splitTrace
  self.splitTrace = nil
  if not (t and CB.Journal and CB.db) then return end
  local text = "open sequence: " .. (#t > 0 and table.concat(t, " > ") or "(no native call seen)")
  CB:Journal("split-trace", text)
  if CB.Info then CB:Info("split-trace", text) end
end

--- Read-only: look again, shortly after the amount dialog changed, for game slots that have become Baggler-written
--- (Log.lua TaintWatch, which now includes the controller input stack). Journals only what is new, so a later blocked
--- action can be tied to this transition. It calls nothing in the game.
local function watchTaintSoon(why)
  if C_Timer and C_Timer.After and CB.TaintWatch then
    C_Timer.After(0.5, function() CB:Safe("taintwatch", function() CB:TaintWatch(why) end) end)
  end
end

local splitHideHooked
function Pad:HookSplitHide()
  local split = rawget(_G, "StackSplitFrame")
  if splitHideHooked or not (split and split.HookScript and CB.Journal) then return end
  splitHideHooked = true
  pcall(function()
    split:HookScript("OnShow", function() trace("StackSplit.OnShow") end)
    local mgr = rawget(_G, "GamepadMode") and GamepadMode.FrameControlsManager
    local function hook(obj, key, fn) pcall(hooksecurefunc, obj, key, fn) end
    hook(split, "Hide", function() trace("StackSplit:Hide() [lua] " .. (debugstack and (debugstack(2, 9, 0):gsub("Interface/AddOns/", ""):gsub("\n", " <- ")) or "")) end)
    if mgr then
      hook(mgr, "FrameShown", function(_, f) trace("FrameShown " .. nameOf(f)) end)
      hook(mgr, "FrameHidden", function(_, f) trace("FrameHidden " .. nameOf(f)) end)
      hook(mgr, "FocusFrame", function(_, f) trace("FocusFrame " .. nameOf(f)) end)
      hook(mgr, "SetUIFocusState", function(_, v) trace("SetUIFocusState " .. tostring(v)) end)
      hook(mgr, "SuspendFrame", function() trace("SuspendFrame") end)
      hook(mgr, "UnsuspendFrame", function() trace("UnsuspendFrame") end)
    end
    hook(_G, "HideUIPanel", function(f) trace("HideUIPanel " .. nameOf(f)) end)
    hook(_G, "ShowUIPanel", function(f) trace("ShowUIPanel " .. nameOf(f)) end)
    hook(_G, "MerchantFrame_CloseStackSplitFrame", function() trace("MerchantFrame_CloseStackSplitFrame") end)
    hook(_G, "StackSplitCancelButton_OnClick", function() trace("StackSplitCancel") end)
    local sn = rawget(_G, "SmartNavigation")
    if sn then hook(sn, "SetActiveFrame", function(_, info) trace("SmartNav.active=" .. nameOf(info and info.frame)) end) end
  end)
  split:HookScript("OnHide", function(f)
    trace("StackSplit.OnHide")
    watchTaintSoon("amount dialog hidden")
    local ok, err = pcall(function()
      local owner = f.owner
      local stack = debugstack and debugstack(2, 12, 0) or "no debugstack"
      stack = stack:gsub("Interface/AddOns/", ""):gsub("\n", " <- ")
      local text = ("split hidden: ownerVisible=%s ownerShown=%s ownerFlag=%s age=%.2fs | stack: %s"):format(
        tostring(owner and owner.IsVisible and owner:IsVisible()), tostring(owner and owner.IsShown and owner:IsShown()),
        tostring(owner and owner.hasStackSplit), (GetTime and GetTime() or 0) - (Pad.splitOpenedAt or 0), stack)
      CB:Journal("split-hide", text)
      if CB.Info then CB:Info("split-hide", text) end
    end)
    if not ok then CB:Journal("split-hide", "hook error: " .. tostring(err)) end
  end)
end

function Pad:FocusProbe(tag)
  if tag == "open" then self.splitOpenedAt = GetTime and GetTime() or 0; self:HookSplitHide(); watchTaintSoon("amount dialog opened") end
  if Pad.InCombat() or not (CB.Journal and CB.db) then return end
  local function nm(f)
    if f == nil then return "nil" end
    local n = type(f) == "table" and f.GetName and f:GetName()
    return n or tostring(f)
  end
  local ok, line = pcall(function()
    local split = rawget(_G, "StackSplitFrame")
    local mgr = rawget(_G, "GamepadMode") and GamepadMode.FrameControlsManager
    local parts = {}
    parts[#parts + 1] = ("split shown=%s owner=%s kbd=%s"):format(tostring(split and split:IsShown()),
      nm(split and split.owner), tostring(split and split.IsKeyboardEnabled and split:IsKeyboardEnabled()))
    parts[#parts + 1] = ("gamepadUI=%s"):format(tostring(InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled()))
    if mgr then
      local shown = {}
      for _, f in ipairs(mgr.shownFrames or {}) do shown[#shown + 1] = nm(f) end
      parts[#parts + 1] = ("native focused=%s uiFocused=%s suspended=%s shown=[%s]"):format(nm(mgr.focusedFrame),
        tostring(mgr.isUIFocused), nm(mgr.topSuspendedFrame), table.concat(shown, ","))
    else
      parts[#parts + 1] = "native manager=nil"
    end
    local keys = {}
    for _, k in ipairs({ "PAD1", "PAD2", "PADDLEFT", "PADDRIGHT" }) do
      keys[#keys + 1] = k .. "=" .. tostring(GetBindingAction and GetBindingAction(k, true) or "?")
    end
    parts[#parts + 1] = "keys{" .. table.concat(keys, " ") .. "}"
    local inp = self.input or {}
    parts[#parts + 1] = ("baggler handedOff=%s hold=%s bound=%s visit=%s nativeFocus=%s"):format(tostring(self.handedOff),
      nm(self.holdGame), tostring(self.bound), inp.visit and tostring(inp.visit.kind) or "nil", tostring(inp.nativeFocus))
    return table.concat(parts, " | ")
  end)
  local text = tag .. ": " .. (ok and line or ("probe error: " .. tostring(line)))
  CB:Journal("split-focus", text)        -- /baggler journal, saved with the settings
  if CB.Info then CB:Info("split-focus", text) end -- /baggler report
end

--- Look again next frame, and once more shortly after, for a dialog the use just opened.
function Pad:NoteExternalUI()
  -- A confirmation can show a moment after the click. Keep looking for that long.
  self.watchExternal = (GetTime and GetTime() or 0) + 1
  local function check()
    if Pad:GameNeedsPad() then Pad:HandOff("item ui")
    else Pad:Reclaim("item ui closed") end
  end
  if C_Timer and C_Timer.After then
    C_Timer.After(0, check)
    C_Timer.After(0.25, check)
  end
end

