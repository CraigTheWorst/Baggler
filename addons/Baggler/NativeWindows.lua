-- Native-window boundary (personal/account bank is owned by Bank.lua):
-- observe other windows, never skin, hide, move, reparent,
-- replace scripts, or build a competing window. No Blizzard window is loaded here.
local ADDON, CB = ...
local N = {}
CB.NativeWindows = N

-- Old profiles/imports can contain enabled replacement flags. They are inert:
-- their modules are no longer in the TOC. Keep the diagnostics honest as well.
-- Core retains old saved keys/migrations for compatibility. The READY callback
-- normalizes those flags; the TOC exclusion, not a user option, prevents loading
-- the retired replacements. The active custom bank is deliberately excluded
-- from native visibility tests to avoid a second focus/lifetime owner.
N.retired = { vendor = "replaceVendor", guildbank = "replaceGuildBank",
  mail = "replaceMail", trade = "replaceTrade", loot = "replaceLoot", trainer = "replaceTrainer" }
for _, key in pairs(N.retired) do CB.defaults[key] = false end
CB:On("READY", function()
  for _, key in pairs(N.retired) do CB.db[key] = false end
end)

function N:Visible(name)
  local frame = rawget(_G, name)
  if name == "BankFrame" and ((CB.Bank and CB.Bank.active) or (frame and CB.UI:IsConcealed(frame))) then return false end
  return frame and frame.IsVisible and frame:IsVisible() and true or false
end

N.visits = {
  { "MerchantFrame", "MERCHANT_SHOW", "MERCHANT_CLOSED" },
  { "BankFrame", "BANKFRAME_OPENED", "BANKFRAME_CLOSED" },
  { "GuildBankFrame", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED" },
  { "MailFrame", "MAIL_SHOW", "MAIL_CLOSED" },
  { "TradeFrame", "TRADE_SHOW", "TRADE_CLOSED" },
  { "LootFrame", "LOOT_OPENED", "LOOT_CLOSED" },
  { "ClassTrainerFrame", "TRAINER_SHOW", "TRAINER_CLOSED" },
  { "AuctionHouseFrame", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" },
}
N.active = {}
for _, visit in ipairs(N.visits) do
  local name = visit[1]
  CB:RegisterEvent(visit[2], function()
    if name == "BankFrame" and CB.Bank and CB.Bank.active then return end
    N.active[name] = true
  end)
  CB:RegisterEvent(visit[3], function()
    N.active[name] = nil
    -- Bank.lua owns the custom visit's close timestamp (including interaction
    -- manager / polling closes). Alpha-zero BankFrame is not a native visit.
    if name == "BankFrame" and ((CB.Bank and CB.Bank.active) or (BankFrame and CB.UI:IsConcealed(BankFrame))) then return end
    N.endedAt = GetTime()
  end)
end

-- Paired native visits: the bags and the game's window open together and close together.
-- `close` ends the server interaction (the game then hides its own frame); `first` gives the native window the
-- controller first when it opens the bags (Start hops to the bags and back); `bagsStay` = the game's own hide does
-- not close the bags, so the visit's end must. Pinned Forever source (wow-ui-source-9dc84f0d):
--   MerchantFrame_OnHide: CloseMerchant(); CloseAllBags(self)              (Mainline/MerchantFrame.lua 163-167)
--   MailMixin:OnHide: CloseMail(); HideUIPanel(OpenMailFrame); MailFrame_Hide: CloseAllBags() (MailFrame.lua 49-51, 118-121)
--   TradeFrame_OnHide: CloseTrade(); CloseAllBags()                          (Mainline/TradeFrame.lua 239-245)
--   AuctionHouseFrame:OnHide: C_AuctionHouse.CloseAuctionHouse(); CloseAllBags(self) (Blizzard_AuctionHouseFrame.lua 448-462)
--   GuildBankFrame:OnHide: CloseGuildBankFrame(), no CloseAllBags           (Mainline/Blizzard_GuildBankUI.lua 125-131)
-- The merchant window is also the warlock demon trainer's (the trainer UI never opens the bags: Blizzard_TrainerUI has
-- no OpenAllBags, ClassTrainerFrame is Integrations.NO_BAGS), so it follows the same native-first rule. Taxi is never paired.
N.PAIRED = {
  { frame = "MerchantFrame", show = "MERCHANT_SHOW", closed = "MERCHANT_CLOSED", first = true, close = function() return rawget(_G, "CloseMerchant") end },
  { frame = "MailFrame", show = "MAIL_SHOW", closed = "MAIL_CLOSED", first = true, close = function() return rawget(_G, "CloseMail") end },
  { frame = "TradeFrame", show = "TRADE_SHOW", closed = "TRADE_CLOSED", first = true, close = function() return rawget(_G, "CloseTrade") end },
  { frame = "AuctionHouseFrame", show = "AUCTION_HOUSE_SHOW", closed = "AUCTION_HOUSE_CLOSED", first = true,
    close = function() return C_AuctionHouse and C_AuctionHouse.CloseAuctionHouse end },
  { frame = "GuildBankFrame", show = "GUILDBANKFRAME_OPENED", closed = "GUILDBANKFRAME_CLOSED", first = true, bagsStay = true,
    close = function() return rawget(_G, "CloseGuildBankFrame") end },
}

--- The paired native visit whose window is up, if any.
function N:Paired()
  for _, p in ipairs(self.PAIRED) do if self:Visible(p.frame) then return p end end
end

-- B on the bags only has to make the GAME close its frame: it is bound to the game's own Escape command
-- (ToggleGameMenu -> CloseAllWindows: CloseAllBags(); CloseWindows() hides the UI panel), with no add-on code in the
-- chain -- the same route as Bank.closeCommand. Bag-local work (search, menu, held item) comes first.
function N:PairedCloseCommand(W)
  if not (W and W.kind == "bags" and self:Paired()) then return nil end
  if W.searching or W.sizing or W.chrome or (W.query or "") ~= "" or W.filterCat then return nil end
  if CB.Menu and CB.Menu.IsOpen and CB.Menu:IsOpen() then return nil end
  local picker = rawget(_G, "BagglerQuantity")
  if picker and picker:IsShown() then return nil end
  if CursorHasItem and CursorHasItem() then return nil end
  return "TOGGLEGAMEMENU"
end

--- B reached add-on code at a paired visit (catcher input backend): close the bags now and end the visit on the next
--- frame, outside the key press. Never in combat lockdown: there the bags close alone and the native window is left to
--- Escape / the game's own B.
function N:LeavePaired(W)
  local p = self:Paired()
  W:Close()
  if not p or InCombatLockdown() then return end
  C_Timer.After(0, function()
    local close = p.close()
    if close and not InCombatLockdown() and N:Visible(p.frame) then pcall(close) end
  end)
end

--- The bags opened for a paired native window: that window gets the controller first (Start hops to the bags).
--- Called by Integrations when the game opens the bags for `frame`. Out of combat only (bindings change).
function N:FocusNativeFirst(frame)
  local name = frame and frame.GetName and frame:GetName()
  local entry
  for _, p in ipairs(self.PAIRED) do if p.frame == name and p.first then entry = p end end
  if not entry or (CB.db.off and CB.db.off.autohold) then return end
  C_Timer.After(0.1, function()
    local P = CB.Pad
    if not P or InCombatLockdown() or not P.frameVisible(frame) or #P.stack == 0 or P.holdGame then return end
    for _, g in ipairs(P.GAME_WINDOWS or {}) do
      if g.frame() == frame then
        if CB.db[g.keepOpt] == false then return end
        P:HoldGame(frame, g.name, true, true)
        return
      end
    end
  end)
end

-- Bags already up when the visit opens (or still up when it closes): B's binding must follow the visit now. A visit
-- whose own hide leaves the bags open (guild bank) takes them with it when it ends; never in combat lockdown.
for _, p in ipairs(N.PAIRED) do
  for _, ev in ipairs({ p.show, p.closed }) do
    CB:RegisterEvent(ev, function()
      if ev == p.closed and p.bagsStay and CB.Window and CB.Window:IsOpen() and not InCombatLockdown() then CB.Window:Close() end
      C_Timer.After(0, function() if CB.Pad and CB.Pad.SyncDirectUse then CB.Pad:SyncDirectUse() end end)
    end)
  end
end

function N:VisitVisible()
  for _, visit in ipairs(self.visits) do if self:Visible(visit[1]) then return true end end
  return false
end

function N:Closing()
  if self.endedAt and GetTime() - self.endedAt < 1.5 then return true end
  for name in pairs(self.active) do
    local customBank = name == "BankFrame" and ((CB.Bank and CB.Bank.active) or (BankFrame and CB.UI:IsConcealed(BankFrame)))
    if not customBank and not self:Visible(name) then
      self.active[name] = nil
      self.endedAt = GetTime()
      return true
    end
  end
  return false
end

function N:SendActive()
  return self:Visible("MailFrame") and self:Visible("SendMailFrame")
end

function N:BankType()
  if CB.Bank and CB.Bank.active then return CB.Bank:ActiveBankType() end
  local frame = rawget(_G, "BankFrame")
  if frame and frame.GetActiveBankType then
    local ok, kind = pcall(frame.GetActiveBankType, frame)
    if ok and kind ~= nil then return kind end
  end
  return (Enum and Enum.BankType and Enum.BankType.Character) or 0
end

-- Read the custom selection while Bank.lua owns the visit, otherwise the game.
function N:BankBagIDs()
  local ids = {}
  if C_Bank and C_Bank.FetchPurchasedBankTabData then
    local ok, tabs = pcall(C_Bank.FetchPurchasedBankTabData, self:BankType())
    if ok and type(tabs) == "table" then
      for _, tab in ipairs(tabs) do ids[#ids + 1] = tab.ID end
    end
  end
  if #ids == 0 and Enum and Enum.BagIndex then
    local account = Enum.BankType and Enum.BankType.Account
    local prefix = account ~= nil and self:BankType() == account and "AccountBankTab_" or "CharacterBankTab_"
    local i = 1
    while Enum.BagIndex[prefix .. i] ~= nil do
      local id = Enum.BagIndex[prefix .. i]
      if (C_Container.GetContainerNumSlots(id) or 0) > 0 then ids[#ids + 1] = id end
      i = i + 1
    end
  end
  return ids
end

function N:Context()
  if self:Visible("MerchantFrame") then return "merchant" end
  if self:Visible("BankFrame") then return "bank" end
  if self:Visible("GuildBankFrame") then return "guildbank" end
  if self:Visible("TradeFrame") then return "trade" end
  if self:SendActive() then return "mail" end
end
