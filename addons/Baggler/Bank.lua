-- Baggler bank: the character bank in the Baggler style - a second instance of the
-- same window class as the backpack, with a tab strip and a Deposit button.
--
-- Visit ownership (other service windows now use their native UI):
--  * Blizzard's BankFrame stays "shown" to the game and is only made invisible (UI:Conceal). Its OnShow and OnHide
--    run as the game wrote them (they open and close the game's bags and end the interaction), so the frame is never
--    hidden, re-parented, or stripped of a script, and BankPanel is not touched at all. It is concealed the moment
--    the visit is announced, before it can be drawn.
--  * Closing goes through the game: Escape is left to it, the X is a secure click on the game's own close button,
--    and the controller's B is bound to the game's Escape command. The visit ends when the game's frame hides (the
--    game's "closed" events are not relied on). C_Bank.CloseBankFrame is never called from add-on code in the normal
--    case, only as the fallback for the "catcher" controller method.
--  * Our window passes the bank type (character or warband) explicitly to every call, so the game's own active
--    type need not match.
--  * Buying a tab is a protected action: the "+" button is Blizzard's own template with nothing replaced.
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local View, UI, Pad, Inv = CB.View, CB.UI, CB.Pad, CB.Inventory
local B = {}
CB.Bank = B

B.active = false     -- bank interaction open and OUR window is the bank UI

local function charType()
  return (Enum and Enum.BankType and Enum.BankType.Character) or 0
end

local function accountType()
  return Enum and Enum.BankType and Enum.BankType.Account
end

-- Which bank the window shows: the character's own tabs or the shared warband tabs.
B.viewType = nil
local function viewType() return B.viewType or charType() end
B.ViewType = viewType

function B:IsWarband()
  local a = accountType()
  return a ~= nil and viewType() == a
end

--- True when the client has a warband bank this character may look at.
function B:CanViewWarband()
  local a = accountType()
  if a == nil or not (C_Bank and C_Bank.FetchPurchasedBankTabData) then return false end
  if C_Bank.CanViewBank then
    local ok, can = pcall(C_Bank.CanViewBank, a)
    if ok then return can and true or false end
  end
  return true
end

function B:SetViewType(t)
  if t == B.viewType or (t == nil and B.viewType == nil) then return end
  B.viewType = t
  B.window.bagFilter = nil
  B.window.selKey = nil
  if B.window.frame and B.window.frame.purchaseBtn then B.window.frame.purchaseBtn:SetAttribute("overrideBankType", viewType()) end
  B.window:Refresh()
  CB:Info("bank", "viewing " .. (B:IsWarband() and "warband" or "character") .. " bank")
end

function B:ToggleView()
  if B:IsWarband() then B:SetViewType(nil)
  elseif B:CanViewWarband() then B:SetViewType(accountType())
  else CB:Print("the warband bank isn't available here.") end
end

--- The deposit destination: our selected bank while custom-owned, otherwise the
--- native BankFrame's active type. Do not rewrite the concealed BankPanel state.
function B:ActiveBankType()
  if B.active then return viewType() end
  if BankFrame and BankFrame.GetActiveBankType then
    local ok, t = pcall(BankFrame.GetActiveBankType, BankFrame)
    if ok and t ~= nil then return t end
  end
  return charType()
end

---------------------------------------------------------------------------
-- Which containers are the bank's
---------------------------------------------------------------------------
function B:Tabs()
  local tabs = {}
  if C_Bank and C_Bank.FetchPurchasedBankTabData then
    local ok, data = pcall(C_Bank.FetchPurchasedBankTabData, viewType())
    if ok and data then
      for _, t in ipairs(data) do tabs[#tabs + 1] = t end
      table.sort(tabs, function(a, b) return a.ID < b.ID end)
    elseif not ok then
      CB:Warn("bank", "FetchPurchasedBankTabData failed: " .. tostring(data))
    end
  end
  return tabs
end

-- Container IDs of the tabs being shown. Falls back to probing Enum.BagIndex when the tab
-- list is not available yet.
function B.BagIDs()
  local ids = {}
  for _, t in ipairs(B:Tabs()) do ids[#ids + 1] = t.ID end
  if #ids == 0 and Enum and Enum.BagIndex then
    -- fall back to probing the enum for tabs that hold slots
    local n = 1
    local prefix = B:IsWarband() and "AccountBankTab_" or "CharacterBankTab_"
    while Enum.BagIndex[prefix .. n] ~= nil do
      local id = Enum.BagIndex[prefix .. n]
      if (C_Container.GetContainerNumSlots(id) or 0) > 0 then ids[#ids + 1] = id end
      n = n + 1
    end
  end
  return ids
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
local function accentHex()
  local r, g, b = CB:Accent()
  return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
end

-- Footer targets match the equipped 32px bank-bag slot, so All, switch, tabs and + read alike.
local CONTROL = 32

local function drawDeposit(btn)
  UI:DrawIcon(btn, { { 1.5, 8, 0, 2 }, { 7, 1.5, -2.5, -1, 45 }, { 7, 1.5, 2.5, -1, -45 }, { 11, 1.5, 0, -5 } })
end

local window = View.New({
  kind = "bank",
  frameName = "BagglerBank",
  sizeKey = "bank",
  icon = "Interface\\AddOns\\Baggler\\Assets\\baggler-header.tga",
  pointKey = "bankPoint",
  getBagIDs = B.BagIDs,
  title = function()
    return "|cff" .. accentHex() .. "B|r" .. CB.HEX.text .. "aggler|r  " .. CB.HEX.dim .. (B:IsWarband() and "Warband Bank" or "Bank") .. "|r"
  end,
  defaultAnchor = function(f) f:SetPoint("LEFT", UIParent, "LEFT", 90, 40) end,
  extraButtons = { { tooltip = "Deposit everything eligible", draw = drawDeposit, onClick = function()
    if C_Bank and C_Bank.AutoDepositItemsIntoBank then
      local ok, err = pcall(C_Bank.AutoDepositItemsIntoBank, viewType())
      if not ok then CB:Warn("bank", "AutoDepositItemsIntoBank failed: " .. tostring(err)) end
    end
  end } },
  edge = function(action)
    if action == "right" and CB.Window:IsOpen() and Pad:CanEdgeWalk() then
      Pad:Push(CB.Window.ctx)
      CB.Window:SelectFirstIfNone()
      return true
    end
    return false
  end,
})
B.window = window

-- The window's own close controls: with the game's bank frame up the X and Escape are the game's (a secure click, a key
-- left to it), so this is only the fallback when they cannot be (the frame is not up, or the catcher input method).
local viewClose = View.Close
function window:Close()
  if B.active then B:Leave() else viewClose(self) end
end

function window:CleanUp()
  if InCombatLockdown() then CB:Print("can't sort in combat."); return end
  if C_Container.SortBank then
    local ok, err = pcall(C_Container.SortBank, viewType())
    if not ok then CB:Warn("bank", "SortBank failed: " .. tostring(err)) end
  elseif SortBankBags then SortBankBags()
  else CB:Print("this client has no bank sort.") end
end

---------------------------------------------------------------------------
-- Tab strip (footer, left side)
---------------------------------------------------------------------------
local function tabButton(f, index)
  f.bankTabs = f.bankTabs or {}
  local b = f.bankTabs[index]
  if b then return b end
  b = NewFrame("Button", nil, f.footer, "BackdropTemplate")
  b:SetSize(CONTROL, CONTROL)
  UI:Backdrop(b, UI.tile, UI.border)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 1, -1); b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.label = b:CreateFontString(nil, "OVERLAY", "BagglerFontCount")
  b.label:SetPoint("CENTER")
  b:SetScript("OnClick", function(self)
    window.bagFilter = self.bagID
    window.selKey = nil
    window:Refresh()
  end)
  b:SetScript("OnEnter", function(self)
    local r, g, bl = CB:Accent()
    self:SetBackdropBorderColor(r, g, bl, 1)
    UI.Tip:SetOwner(self, "ANCHOR_TOP")
    UI.Tip:SetText(self.tip or "Tab", 1, 1, 1)
    UI.Tip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    UI:HideTip()
    window:UpdateTabHighlight()
  end)
  f.bankTabs[index] = b
  return b
end

-- Accent border for the focused tab and for the tab used as the current filter.
function window:UpdateTabHighlight()
  local f = self.frame
  if not f or not f.bankTabs then return end
  for _, b in ipairs(f.bankTabs) do
    if b:IsShown() then
      local on = (b.bagID == self.bagFilter)
      if b.cbFocused or on then
        local r, g, bl = CB:Accent()
        b:SetBackdropBorderColor(r, g, bl, 1)
      else
        b:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
      end
    end
  end
  if f.purchaseBtn then
    f.purchaseBtn:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
  end
end

-- The "+" button that buys the next bank tab. Built on first use; returns nil when the
-- client has no purchase template.
-- The native script owns confirmation and purchase permission. An addon callback
-- or pcall does not gain that permission: do not replace OnClick or substitute a
-- direct PurchaseBankTab call. overrideBankType follows the displayed bank, not
-- the concealed native tab selection; affordability is refreshed separately.
local function purchaseButton(f)
  if f.purchaseBtn then return f.purchaseBtn end
  -- Blizzard's own template does the (protected) purchase; we only dress it. Never give it an OnClick.
  local ok, b = pcall(CreateFrame, "Button", nil, f.footer, "BankPanelPurchaseButtonScriptTemplate,BackdropTemplate")
  if not ok then
    CB:Warn("bank", "purchase template unavailable: " .. tostring(b))
    return nil
  end
  b:SetSize(CONTROL, CONTROL)
  UI:Backdrop(b, UI.tile, UI.border)
  b:SetAttribute("overrideBankType", viewType())
  b.label = b:CreateFontString(nil, "OVERLAY", "BagglerFontTitle")
  b.label:SetPoint("CENTER", 0, 1)
  b.label:SetText("+")
  b:HookScript("OnEnter", CB:Wrap("bank:purchase.OnEnter", function(self)
    local r, g, bl = CB:Accent()
    self:SetBackdropBorderColor(r, g, bl, 1)
    UI.Tip:SetOwner(self, "ANCHOR_TOP")
    UI.Tip:SetText(B:UsesBags() and "Purchase next bank bag slot" or "Purchase next bank storage tab", 1, 1, 1)
    local data = C_Bank and C_Bank.FetchNextPurchasableBankTabData and C_Bank.FetchNextPurchasableBankTabData(viewType())
    if data and data.tabCost then UI.Tip:AddLine(UI:Money(data.tabCost), CB.COLOR.soft[1], CB.COLOR.soft[2], CB.COLOR.soft[3]) end
    UI.Tip:Show()
  end))
  b:HookScript("OnLeave", CB:Wrap("bank:purchase.OnLeave", function(self)
    UI:HideTip()
    self:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
  end))
  f.purchaseBtn = b
  return b
end

-- Forever/Camelot BankFrame.lua: ShouldUsePlayerBagsInBank selects real
-- equipment slots. Purchased tab #1 is built-in storage; #2 onward hold bags.
-- These are NOT inventory bag slots: native PickupContainerItem uses the
-- Characterbanktab/Accountbanktab container and the purchased slot ordinal.
function B:UsesBags()
  return C_Bank and C_Bank.ShouldUsePlayerBagsInBank and C_Bank.ShouldUsePlayerBagsInBank() or false
end

function B:CanUse()
  return B.active and not InCombatLockdown() and C_Bank and C_Bank.CanUseBank
    and C_Bank.CanUseBank(viewType()) and true or false
end

function B:CanBuyNextSlot()
  if not B:CanUse() then return false end
  if C_Bank.CanPurchaseBankTab and not C_Bank.CanPurchaseBankTab(viewType()) then return false end
  -- Camelot hides its buy control for account banks with no initial slot.
  if B:UsesBags() and B:IsWarband() and C_Bank.FetchNumPurchasedBankTabs(viewType()) == 0 then return false end
  local data = C_Bank.FetchNextPurchasableBankTabData(viewType())
  return data ~= nil and data.canAfford ~= false
end

local function bankBagContainer()
  return Enum.BagIndex[B:IsWarband() and "Accountbanktab" or "Characterbanktab"]
end

local function bagSlotButton(f, index)
  f.bagSlots = f.bagSlots or {}
  local b = f.bagSlots[index]
  if b then return b end
  b = NewFrame("Button", nil, f.footer, "BackdropTemplate")
  b:SetSize(CONTROL, CONTROL)
  UI:Backdrop(b, UI.tile, UI.border)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 1, -1); b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.capacity = b:CreateFontString(nil, "OVERLAY", "BagglerFontCount")
  b.capacity:SetPoint("BOTTOMRIGHT", -3, 3)
  b.specialty = b:CreateFontString(nil, "OVERLAY", "BagglerFontCount")
  b.specialty:SetPoint("TOPLEFT", 3, -2)
  b.specialty:SetTextColor(0.45, 0.85, 0.75)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  local function equip(self)
    if B:CanUse() and bankBagContainer() then
      C_Container.PickupContainerItem(bankBagContainer(), self.bagSlotID)
      CB:Fire("DIRTY")
    end
  end
  local function click(self, button)
    if CursorHasItem() or button == "RightButton" or (IsModifiedClick and IsModifiedClick("PICKUPITEM")) then
      equip(self)
    elseif self.hasBag then
      window.bagFilter, window.selKey = self.bagID, nil
      window:Refresh()
    end
  end
  b.cbClick = click
  b:SetScript("OnClick", click)
  b:SetScript("OnReceiveDrag", equip)
  b:SetScript("OnDragStart", function(self) if self.hasBag then equip(self) end end)
  b:SetScript("OnEnter", function(self)
    UI:HideTip()
    if self.hasBag then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetBagItem(bankBagContainer(), self.bagSlotID)
      GameTooltip:AddLine("Click / A: show bag. Right-click or drag: pick up bag.", 1, 1, 1, true)
      GameTooltip:Show()
    else
      UI.Tip:SetOwner(self, "ANCHOR_TOP")
      UI.Tip:SetText("Empty bank bag slot", 1, 1, 1)
      UI.Tip:AddLine("Drag a bag here, or pick up a bag and press A here to equip it.", 1, 1, 1, true)
      UI.Tip:Show()
    end
  end)
  b:SetScript("OnLeave", function() UI:HideTip(); window:UpdateTabHighlight() end)
  f.bagSlots[index] = b
  return b
end

-- Keep controller specialization on this bank instance, not the shared View.
local viewChromeList, viewActivateChrome, viewShowChrome = View.ChromeList, View.ActivateChrome, View.ShowChrome
function window:ChromeList()
  local list = viewChromeList(self)
  for _, entry in ipairs(list) do
    if entry.widget and entry.widget.bagSlotID then entry.id = "bankbag" end
  end
  local f = self.frame
  if f and f.viewBtn and f.viewBtn:IsShown() then
    list[#list + 1] = { id = "bankview", widget = f.viewBtn,
      tip = B:IsWarband() and "Showing the warband bank" or "Showing the character bank" }
  end
  if f and f.purchaseBtn and f.purchaseBtn:IsShown() then
    list[#list + 1] = { id = "bankbuy", widget = f.purchaseBtn,
      tip = B:UsesBags() and "Purchase next bank bag slot" or "Purchase next bank storage tab" }
  end
  return list
end
function window:ActivateChrome()
  local entry = self:ChromeList()[self.chrome or 1]
  if entry and entry.id == "bankbag" then entry.widget.cbClick(entry.widget)
  elseif entry and entry.id == "bankview" then B:ToggleView()
  elseif entry and entry.id == "bankbuy" then
    if B:CanBuyNextSlot() then entry.widget:Click() end -- unchanged native confirmation script
  else return viewActivateChrome(self) end
end
local viewOnPad = View.OnPad
function window:OnPad(action)
  local entry = self.chrome and self:ChromeList()[self.chrome]
  if entry and entry.id == "bankbag" and action == "pickup" then
    entry.widget.cbClick(entry.widget, "RightButton")
    return
  end
  return viewOnPad(self, action)
end
function window:ShowChrome()
  viewShowChrome(self)
  local entry = self:ChromeList()[self.chrome or 1]
  if entry and entry.id == "bankbag" then entry.widget:GetScript("OnEnter")(entry.widget) end
end

-- Clear removed equipment filters before the shared scanner/layout runs.
local viewRefreshImpl = View.RefreshImpl
function window:RefreshImpl()
  if B:UsesBags() and self.bagFilter and (C_Container.GetContainerNumSlots(self.bagFilter) or 0) == 0 then
    self.bagFilter, self.selKey = nil, nil
  end
  return viewRefreshImpl(self)
end

-- Rebuilds the footer strip: character/warband switch, one button per bank tab, and the
-- purchase button.
function window:UpdateExtras()
  local W = self
  local f = W.frame
  f.moneyText:SetText("")            -- the strip needs the room
  f.moneyText:SetFontObject("BagglerFontNumber")   -- this bank-only row is the next-slot price
  -- the "+" (Blizzard's own template) buys a tab for the bank type it is told: the one on screen now
  if f.purchaseBtn then f.purchaseBtn:SetAttribute("overrideBankType", viewType()) end
  if f.title then f.title:SetText(W.opts.title()) end
  local tabs = B:Tabs()
  local n = 0
  W.footerControls = {}
  local function place(b)
    W.footerControls[#W.footerControls + 1] = b
    b:ClearAllPoints()
    b:SetPoint("LEFT", f.footer, "LEFT", n * (CONTROL + 4), 0)   -- (LayoutFooter flows the final rows)
    n = n + 1
    b:Show()
  end
  if B:CanViewWarband() then
    if not f.viewBtn then
      local vb = NewFrame("Button", nil, f.footer, "BackdropTemplate")
      vb:SetSize(CONTROL, CONTROL)
      UI:Backdrop(vb, UI.tile, UI.border)
      vb.label = vb:CreateFontString(nil, "OVERLAY", "BagglerFontCount")
      vb.label:SetPoint("CENTER")
      vb:SetScript("OnClick", function() B:ToggleView() end)
      vb:SetScript("OnEnter", function(self)
        UI.Tip:SetOwner(self, "ANCHOR_TOP")
        UI.Tip:SetText(B:IsWarband() and "Showing the warband bank" or "Showing the character bank", 1, 1, 1)
        UI.Tip:AddLine("Click to switch", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3])
        UI.Tip:Show()
      end)
      vb:SetScript("OnLeave", function() UI:HideTip() end)
      f.viewBtn = vb
    end
    f.viewBtn.label:SetText(B:IsWarband() and "WB" or "Me")
    place(f.viewBtn)
  elseif f.viewBtn then f.viewBtn:Hide() end
  local usesBags = B:UsesBags()
  local idx, slotCount = 0, 0
  if usesBags then
    -- Always provide a way back from an individual installed bag to all storage.
    local all = tabButton(f, 1)
    all.bagID, all.tip = nil, "All bank storage"
    all.icon:SetTexture(nil); all.label:SetText("All")
    place(all); idx = 1
    for ordinal, t in ipairs(tabs) do
      if ordinal > 1 then
        slotCount = slotCount + 1
        local b = bagSlotButton(f, slotCount)
        b.bagSlotID, b.bagID = ordinal, t.ID
        local info = bankBagContainer() and C_Container.GetContainerItemInfo(bankBagContainer(), ordinal)
        b.hasBag = info ~= nil
        b.icon:SetTexture(info and info.iconFileID or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
        b.icon:SetDesaturated(not b.hasBag)
        b.icon:SetAlpha(b.hasBag and 1 or 0.45)
        local capacity = b.hasBag and C_Container.GetContainerNumSlots(t.ID)
        local _, family = C_Container.GetContainerNumFreeSlots(t.ID)
        b.capacity:SetText(b.hasBag and tostring(capacity or "?") or "")
        b.specialty:SetText(b.hasBag and type(family) == "number" and family ~= 0 and "*" or "")
        place(b)
      end
    end
  else
    if #tabs > 1 then
      local all = tabButton(f, 1)
      all.bagID, all.tip = nil, "All tabs"
      all.icon:SetTexture(nil); all.label:SetText("All")
      place(all); idx = 1
    end
    for i, t in ipairs(tabs) do
      idx = idx + 1
      local b = tabButton(f, idx)
      b.bagID, b.tip = t.ID, t.name or ("Tab " .. i)
      if t.icon then b.icon:SetTexture(t.icon); b.label:SetText("") else b.icon:SetTexture(nil); b.label:SetText(tostring(i)) end
      if #tabs > 1 then place(b) else b:Hide() end
    end
  end
  for i = slotCount + 1, #(f.bagSlots or {}) do f.bagSlots[i]:Hide() end
  for i = idx + 1, #(f.bankTabs or {}) do f.bankTabs[i]:Hide() end

  local nextTab = C_Bank and C_Bank.FetchNextPurchasableBankTabData and C_Bank.FetchNextPurchasableBankTabData(viewType())
  local blockedAccount = usesBags and B:IsWarband() and C_Bank.FetchNumPurchasedBankTabs(viewType()) == 0
  local pb = (nextTab ~= nil and not blockedAccount) and purchaseButton(f) or nil
  if f.purchaseBtn then f.purchaseBtn:Hide() end
  if pb then
    pb:SetEnabled(B:CanBuyNextSlot())
    place(pb)
    f.moneyText:SetText("Next slot: " .. UI:Money(nextTab.tabCost))
  end

  -- if the filtered tab no longer exists, show everything again
  if W.bagFilter then
    local found
    for _, t in ipairs(tabs) do if t.ID == W.bagFilter then found = true end end
    if not found then W.bagFilter = nil end
  end
  f.empty:SetText(#tabs == 0 and "No bank tabs yet.\nUse the + below to purchase one." or "Nothing here.")
  W:UpdateTabHighlight()
  W:ApplySize()
end

-- Window-menu entries that limit the view to a single bank tab.
function window:ExtraFilters()
  local entries = {}
  local f = self.frame
  if not f or not f.bankTabs then return entries end
  for _, b in ipairs(f.bankTabs) do
    if b:IsShown() then
      local bagID = b.bagID
      local tip = b.tip or "All"
      entries[#entries + 1] = {
        text = "Tab: " .. tip,
        checked = self.bagFilter == bagID,
        func = function()
          self.bagFilter = bagID
          self.selKey = nil
          self:Refresh()
        end,
      }
    end
  end
  return entries
end

--- Menu entries for the bank: warband switch and tab rename / icon.
local ICONS = {
  { "Chest", 133784 }, { "Gem", 133250 }, { "Potion", 134862 }, { "Sword", 135274 },
  { "Armor", 132740 }, { "Herb", 134188 }, { "Ore", 134067 }, { "Cloth", 132896 },
  { "Book", 133741 }, { "Key", 134237 }, { "Coin", 133784 }, { "Food", 133964 },
}

local function currentTab()
  if B:UsesBags() then return nil end
  for _, t in ipairs(B:Tabs()) do
    if t.ID == window.bagFilter then return t end
  end
  return nil
end

local function saveTab(t, name, icon)
  if not (C_Bank and C_Bank.UpdateBankTabSettings) then CB:Print("this client can't edit bank tabs."); return end
  local ok, err = pcall(C_Bank.UpdateBankTabSettings, viewType(), t.ID, name or t.name or "", icon or t.icon or 134400,
    t.depositFlags or 0)
  if not ok then
    CB:Warn("bank", "UpdateBankTabSettings failed: " .. tostring(err))
    CB:Print("couldn't change the tab right now.")
  end
  C_Timer.After(0.2, function() CB:Fire("DIRTY"); window:Refresh() end)
end

StaticPopupDialogs["BAGGLER_RENAME_BANKTAB"] = {
  text = "Name for this bank tab:",
  button1 = ACCEPT or "OK", button2 = CANCEL or "Cancel",
  hasEditBox = 1, maxLetters = 24, timeout = 0, whileDead = 1, hideOnEscape = 1,
  OnShow = function(self)
    local eb = self.editBox or self.EditBox
    local t = B.renaming
    if eb and t then eb:SetText(t.name or ""); eb:HighlightText() end
  end,
  OnAccept = function(self)
    local eb = self.editBox or self.EditBox
    local t = B.renaming
    if eb and t then saveTab(t, eb:GetText(), nil) end
  end,
  EditBoxOnEnterPressed = function(self)
    local t = B.renaming
    if t then saveTab(t, self:GetText(), nil) end
    self:GetParent():Hide()
  end,
}

-- Bank-only window-menu entries: switch bank type, rename the current tab, change its icon.
function window:BankEntries()
  local entries = {}
  if B:CanViewWarband() then
    entries[#entries + 1] = {
      text = B:IsWarband() and "Show character bank" or "Show warband bank",
      func = function() B:ToggleView() end,
    }
  end
  local t = currentTab()
  if t then
    entries[#entries + 1] = { text = "Rename tab...", func = function()
      B.renaming = t
      if StaticPopup_Show then StaticPopup_Show("BAGGLER_RENAME_BANKTAB") end
    end }
    entries[#entries + 1] = { text = "Tab icon", sub = function()
      local list = {}
      for _, ic in ipairs(ICONS) do
        list[#list + 1] = { text = ic[1], checked = t.icon == ic[2], func = function() saveTab(t, nil, ic[2]) end }
      end
      return list
    end }
  elseif not B:UsesBags() and #B:Tabs() > 0 then
    entries[#entries + 1] = { text = "Rename tab... (pick a tab first)", func = function()
      CB:Print("choose a bank tab first (Bank tabs), then rename it.")
    end }
  end
  return entries
end

window:Wire()
-- View's money handler updates the ordinary footer first; restore this bank's
-- current purchase price and affordability afterwards.
CB:On("FOOTER", function() if window:IsOpen() then window:UpdateExtras() end end)
CB:RegisterEvent("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", function() CB:Fire("DIRTY") end)
CB:RegisterEvent("PLAYER_REGEN_DISABLED", function() if window:IsOpen() then window:UpdateExtras() end end)
CB:RegisterEvent("PLAYER_REGEN_ENABLED", function() if window:IsOpen() then window:UpdateExtras() end end)

---------------------------------------------------------------------------
-- The visit
---------------------------------------------------------------------------
local function bankKinds()
  local kinds = Enum and Enum.PlayerInteractionType
  return kinds or {}
end

local function isBankKind(kind)
  local k = bankKinds()
  return kind ~= nil and (kind == k.Banker or kind == k.CharacterBanker or kind == k.AccountBanker)
end

--- Whether this visit is ours to take.
local function taking()
  if not (CB.db.replaceBank and BankFrame and C_Bank) then return false end
  local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if loaded and loaded("BetterBags") then return false end
  return not CB:IsOff("bank") and not CB:StandDown()
end

--- Conceals the game's bank frame before it can be drawn (idempotent).
function B:Preconceal()
  if taking() and not UI:IsConcealed(BankFrame) then UI:Conceal(BankFrame) end
end

--- Gives the game's bank frame back (not taking this visit, or the window cannot be shown).
function B:Release()
  if BankFrame and UI:IsConcealed(BankFrame) then UI:Unconceal(BankFrame) end
end

--- Aims the secure X at the game's own close button (only possible out of combat).
function B:ArmClose()
  local x = window.secureX
  if not x then return end
  local close = BankFrame and type(BankFrame.CloseButton) == "table" and BankFrame.CloseButton or rawget(_G, "BankFrameCloseButton")
  x:Arm(close)
end
CB:RegisterEvent("PLAYER_REGEN_ENABLED", function() if B.active then B:ArmClose() end end)

--- While the game's bank frame is up and nothing else wants B, B is the game's own Escape command (see Mail.closeCommand).
function B.closeCommand()
  if not (B.active and BankFrame and BankFrame:IsShown()) then return nil end
  if window.searching or window.sizing or window.chrome or (window.query or "") ~= "" then return nil end
  if CB.Menu and CB.Menu.IsOpen and CB.Menu:IsOpen() then return nil end
  if CursorHasItem and CursorHasItem() then return nil end
  if CB.Window and (CB.Window.searching or CB.Window.sizing or CB.Window.chrome or (CB.Window.query or "") ~= "") then return nil end
  return "TOGGLEGAMEMENU"
end

--- Writes what the game's bank frame looks like right now to the journal (for tracing close problems).
function B:Probe(label)
  if not BankFrame then CB:Journal("bank", label .. ": no BankFrame"); return end
  CB:Journal("bank", ("%s: BankFrame shown=%s alpha=%.2f scale=%.3f | type=%s | X armed=%s"):format(label, tostring(BankFrame:IsShown()),
    BankFrame:GetAlpha() or -1, BankFrame:GetScale() or -1, tostring(B.IsWarband and B:IsWarband() and "warband" or "character"),
    tostring(window.secureX and window.secureX:GetAttribute("clickbutton") ~= nil)))
end

-- Opens the bank view when the banker is spoken to. If anything fails the error is logged and the game's bank is given
-- back, so the player is never locked out of their bank.
function B:Begin()
  if B.active or not taking() then return end
  local ok, err = pcall(function()
    B.active = true
    B.parked = BankFrame
    UI:Conceal(BankFrame)
    window.bagFilter = nil
    -- the warband banker opens the warband bank; any other opens the character bank
    local account = bankKinds().AccountBanker
    B.viewType = (account ~= nil and B.openKind == account and B:CanViewWarband()) and accountType() or nil
    window:Open()                      -- (builds the window the first time, and with it the secure X)
    B:ArmClose()
    B:Probe("opening")
    window:Refresh()
    -- the bags open alongside (the game's own OnShow asks for them too), and always leave with the visit
    if CB.db.autoOpen then
      if not CB.Window:IsOpen() then CB.Window:Open() end
      B.openedBags = true
    else
      B.openedBags = false
    end
    B.shownAt = GetTime and GetTime() or 0
    B.hiddenPolls = 0
    Pad:Push(window.ctx)
    window:SelectFirstIfNone()
    -- This visit is now custom-owned. Do not let the native observer later
    -- rediscover our concealed frame / polling close as a second native visit.
    if CB.NativeWindows then CB.NativeWindows.active.BankFrame = nil end
  end)
  if not ok then
    CB:Error("bank:begin", err)
    CB:Print(CB.HEX.danger .. "bank window error - see /baggler report.|r The game's own bank is shown instead.")
    B.active = false
    if window:IsOpen() then viewClose(window) end
    B:Release()
  end
end

-- Ends the visit: our window goes, the bags with it, and the game's frame is given back once it has hidden.
function B:End()
  if not B.active and not window:IsOpen() then return end
  B.active = false
  B.openKind = nil
  B.endedAt = GetTime and GetTime() or 0
  if window:IsOpen() then viewClose(window) end
  window.bagFilter = nil
  B.viewType = nil
  if B.parked then UI:UnconcealWhenHidden(B.parked) end
  if B.openedBags then B.openedBags = false; CB.Window:Close() end
end

--- Leaves the bank. Only reached by the "catcher" controller method and when the game's frame is not up: the normal
--- ways out (Escape, the X, B) go through the game.
function B:Leave()
  if not B.active then return end
  C_Timer.After(0, function()
    if C_Bank and C_Bank.CloseBankFrame then pcall(C_Bank.CloseBankFrame)
    elseif CloseBankFrame then pcall(CloseBankFrame) end
  end)
  CB:ForceEndLater(function() return B.active end, function() B:End() end, "bank")
end

-- The visit is announced twice (the event and the interaction manager): the first to arrive conceals the game's frame
-- at once; Begin runs once.
-- Each announcement invalidates older deferred opens. Close events increment the
-- same token, so walking away during the delay cannot resurrect a closed visit.
B.visit = 0
local function opened(kind)
  B.visit = B.visit + 1
  local token = B.visit
  B.openKind = kind
  if taking() then B:Preconceal() end
  C_Timer.After(0.15, function()
    if token ~= B.visit then
      -- the visit was cancelled before it began (the game closed the bank at once): its frame is not left concealed
      if not B.active and not (BankFrame and BankFrame:IsShown()) then B:Release() end
      return
    end
    CB:Safe("bank:begin", B.Begin, B)
    if not B.active then B:Release() end                     -- not taking this visit: the game's own bank must be seen
  end)
end
CB:RegisterEvent("BANKFRAME_OPENED", function() opened(B.openKind) end)
CB:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
  if isBankKind(kind) then opened(kind) end
end)
CB:RegisterEvent("BANKFRAME_CLOSED", function() B.visit = B.visit + 1; B:End() end)
CB:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
  if isBankKind(kind) then B.visit = B.visit + 1; B:End() end
end)

-- The visit also ends when the game's own frame hides (Escape, its X, walking away): the game's "closed" events are not
-- relied on. A separate frame owns this, because the window's own frame already runs its refresh loop. Two polls in a
-- row, so a frame the game hides and shows again in one go does not end the visit.
do
  local watcher = CreateFrame("Frame")
  B.watcher = watcher
  watcher:SetScript("OnUpdate", function()
    if not B.active then return end
    if BankFrame and not BankFrame:IsShown() and GetTime() - (B.shownAt or 0) > 0.3 then
      B.hiddenPolls = (B.hiddenPolls or 0) + 1
      if B.hiddenPolls >= 2 then
        CB:Journal("bank", "the game's bank frame closed: ending the visit")
        B:End()
      end
    else
      B.hiddenPolls = 0
    end
  end)
end

CB:RegisterEvent("BANK_TABS_CHANGED", function() CB:Fire("DIRTY") end)
CB:RegisterEvent("BANK_TAB_SETTINGS_UPDATED", function() CB:Fire("DIRTY") end)
