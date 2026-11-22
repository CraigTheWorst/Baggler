-- Baggler window: controller navigation inside the window (top-row chrome, resize mode, the OnPad handler).
-- (Split from Window.lua.)
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local View = CB.View
local UI, Inv, Cat, Pad = CB.UI, CB.Inventory, CB.Categories, CB.Pad
local Container = C_Container

-- The window's own controls in the order the controller walks them (search, filter, bank tabs ...).
function View:ChromeList()
  local W = self
  local f = W.frame
  if not f then return {} end
  local list = {
    { id = "search", widget = f.search, tip = "Search" },
    { id = "filter", widget = (f.filterChip and f.filterChip:IsShown()) and f.filterChip or f.search, tip = "Filter sections" },
  }
  if W.kind == "bank" and f.bankTabs then
    for _, b in ipairs(f.bankTabs) do
      if b:IsShown() then list[#list + 1] = { id = "tabs", widget = b, tip = b.tip or "Bank tabs" }; break end
    end
  end
  -- the equipped bags: each slot is a stop of its own, so a controller can swap bags
  if f.bagSlots then
    for _, b in ipairs(f.bagSlots) do
      if b:IsShown() then list[#list + 1] = { id = "bagslot", widget = b } end
    end
  end
  -- the vendor-only "Sell junk" footer button: a stop only while it is shown
  if f.sellBtn and f.sellBtn:IsShown() then list[#list + 1] = { id = "selljunk", widget = f.sellBtn, tip = "Sell junk" } end
  list[#list + 1] = { id = "size", widget = f.grip, tip = "Resize" }
  if f.settingsBtn then list[#list + 1] = { id = "settings", widget = f.settingsBtn } end
  return list
end

function View:ChromeId()
  local list = self:ChromeList()
  local t = list[self.chrome or 1]
  return t and t.id or "search"
end

-- Removes the focus highlight from every window control.
function View:ClearChromePaint()
  local W = self
  UI:HideFocusTip(W.ctx)
  local f = W.frame
  if not f then return end
  if f.search and f.search.cbFocused then UI:SetFocused(f.search, false) end
  if f.settingsBtn and f.settingsBtn.cbFocused then UI:SetFocused(f.settingsBtn, false) end
  if f.sellBtn and f.sellBtn.cbFocused then UI:SetFocused(f.sellBtn, false) end
  if f.bankTabs then
    for _, b in ipairs(f.bankTabs) do
      if b.cbFocused then UI:SetFocused(b, false) end
    end
  end
  if f.bagSlots then
    for _, b in ipairs(f.bagSlots) do
      if b.cbFocused then UI:SetFocused(b, false); UI:HideTip() end
    end
  end
  if f.chipBg then
    local r, g, b = CB:Accent()
    f.chipBg:SetColorTexture(r, g, b, 0.16)
  end
  if f.grip and f.grip.cbPaint and not W.sizing then f.grip.cbPaint(0.55, 0.55, 0.6) end
  if f.grip and f.grip.readout and not W.sizing then f.grip.readout:SetAlpha(0) end
end

-- Draws the focus on the current control and clears the item card, since the highlight has left
-- the items.
function View:ShowChrome()
  local W = self
  local list = W:ChromeList()
  if #list == 0 then return end
  if not W.chrome or W.chrome > #list then W.chrome = 1 end
  if W.chrome < 1 then W.chrome = #list end
  if CB.Card then CB.Card:HideAll() end                  -- the highlight left the items: their card and tooltips go
  W:ClearChromePaint()
  local t = list[W.chrome]
  if t.id == "size" and t.widget and t.widget.cbPaint then
    local r, g, b = CB:Accent()
    t.widget.cbPaint(r, g, b)
    if t.widget.readout then t.widget.readout:SetText("Resize"); t.widget.readout:SetAlpha(1) end
  elseif t.id == "filter" and t.widget == W.frame.search and W.frame.chipBg and not W.frame.filterChip:IsShown() then
    UI:SetFocused(W.frame.search, true)
  elseif t.id == "filter" and W.frame.chipBg and W.frame.filterChip:IsShown() then
    local r, g, b = CB:Accent()
    W.frame.chipBg:SetColorTexture(r, g, b, 0.45)
  elseif t.widget and t.widget.SetBackdropBorderColor then
    UI:SetFocused(t.widget, true)
    if t.id == "bagslot" then
      local b = t.widget
      UI:HideTip()
      if b.invID and GetInventoryItemTexture("player", b.invID) then
        GameTooltip:SetOwner(b, "ANCHOR_TOP")
        GameTooltip:SetInventoryItem("player", b.invID)
        GameTooltip:Show()
      else
        UI.Tip:SetOwner(b, "ANCHOR_TOP")
        UI.Tip:SetText("Empty bag slot", 1, 1, 1)
        UI.Tip:AddLine("Pick up a bag, then press A here to equip it.", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3], true)
        UI.Tip:Show()
      end
    end
  end
  local label = t.tip or (t.widget and t.widget.cbTooltip)
  if t.widget and label then
    UI:ShowFocusTip(t.widget, label, W.ctx)
  end
  if W.frame.sel then W.frame.sel:Hide() end
end

function View:RefreshPadHint()
  local W = self
  if W.frame and W:IsOpen() and W:HintsVisible() then W:ApplySize() end
end

function View:EnterChrome(index)
  local W = self
  if not W.frame then return end
  W.sizing = false
  W.chrome = index or W.chrome or 1
  W:ShowChrome()
  W:RefreshPadHint()
end

function View:LeaveChrome()
  local W = self
  W.chrome, W.sizing = nil, false
  W:ClearChromePaint()
  if W.selEntry then W:SelectEntry(W.selEntry, false, true) end
  W:RefreshPadHint()
end

function View:MoveChrome(dir)
  local W = self
  local list = W:ChromeList()
  if #list == 0 then return end
  local i = (W.chrome or 1) + dir
  if i > #list then i = 1 elseif i < 1 then i = #list end
  W:EnterChrome(i)
end

function View:FocusSearch()
  local W = self
  if not W.frame or not W.frame.search then return end
  W:EnterChrome(1)
  W.frame.search:SetFocus()
end

-- The use button on a window control: focus search, open the filter menu, open the bank tab menu ...
function View:ActivateChrome()
  local W = self
  local id = W:ChromeId()
  if id == "search" then W:FocusSearch()
  elseif id == "filter" then W:OpenFilterMenu()
  elseif id == "tabs" then
    local entries = W.ExtraFilters and W:ExtraFilters() or {}
    local list = W:ChromeList()
    local anchor = list[W.chrome or 1] and list[W.chrome or 1].widget or W.frame
    if #entries > 0 then CB.Menu:Open(anchor, "Bank tabs", entries) end
  elseif id == "size" then W:BeginSize()
  elseif id == "settings" then CB.Options:Toggle()
  elseif id == "selljunk" then
    if CB.Integrations then CB.Integrations:SellJunk(true) end
  elseif id == "bagslot" then
    local list = W:ChromeList()
    local w = list[W.chrome or 1] and list[W.chrome or 1].widget
    if w and w.cbClick then w.cbClick(w) end
    C_Timer.After(0.2, function() if W.frame and W.frame:IsShown() then W:Refresh() end end)
  end
end

-- Enters resize mode for the controller. Refused when the window is locked.
function View:BeginSize()
  local W = self
  if CB.db.locked then
    CB:Print("The window is locked. Unlock it in settings.")
    return
  end
  if not W.frame then return end
  W.chrome = nil
  W.sizing = true
  UI:HideFocusTip(W.ctx)
  local grip = W.frame.grip
  if grip and grip.cbPaint then
    local r, g, b = CB:Accent()
    grip.cbPaint(r, g, b)
  end
  if grip and grip.readout then
    grip.readout:SetText(W:Columns() .. " columns")
    grip.readout:SetAlpha(1)
  end
  if W.frame.sel then W.frame.sel:Hide() end
  W:RefreshPadHint()
  Pad:SyncDirectUse()
end

-- Leaves resize mode and fades the size read-out.
function View:EndSize()
  local W = self
  local grip = W.frame and W.frame.grip
  W.sizing = false
  W.chrome = nil
  if grip and grip.cbPaint then grip.cbPaint(0.55, 0.55, 0.6) end
  if grip and grip.readout then
    UI:Animate(grip, "readout", 0.35, function(p) grip.readout:SetAlpha(1 - p) end)
  end
  if W.selEntry then W:SelectEntry(W.selEntry, false, true) end
  W:RefreshPadHint()
  Pad:SyncDirectUse()
end

--- The visit window (mailbox, vendor, bank, guild bank, trade) that opened the bags on its own, if one did and is
--- still going. B on those bags ends the whole visit; bags the player opened by hand close alone.
function View.VisitOwningBags()
  local visits = { CB.Mail, CB.GuildBank, CB.Trade, CB.Vendor, CB.Bank }
  for _, v in pairs(visits) do
    if v.openedBags and (v.active or v.atMerchant) and v.Leave then return v end
  end
end

-- Closing the bags by any other route (the bag key, the window menu) cuts the tie: from then on B closes only the bags.
CB:On("WINDOW_HIDDEN", function(w)
  if w ~= CB.Window then return end
  for _, v in pairs({ CB.Mail, CB.GuildBank, CB.Trade, CB.Vendor, CB.Bank }) do v.openedBags = false end
end)

-- Handles one controller action for the window: resize mode first, then search, window
-- controls and item navigation.
function View:OnPad(action)
  local W = self
  if W.sizing then
    local result = UI:SizePad(W:ResizeCfg(), W.frame.grip, action)
    if result == "done" then W:EndSize() end
    return
  end
  if action == "close" and W.searching then
    -- B on the keyboard finishes the search and keeps it: straight on to the results
    W.frame.search:ClearFocus()
    W.searching = false
    Pad:Yield(false)
    W:LeaveChrome()
    return
  end
  if W.chrome then
    if action == "left" then W:MoveChrome(-1)
    elseif action == "right" then W:MoveChrome(1)
    elseif action == "down" or action == "close" then W:LeaveChrome()
    elseif action == "up" and W:ChromeId() == "bagslot" then W:LeaveChrome()
    elseif action == "use" or (action == "pickup" and W:ChromeId() == "bagslot") then W:ActivateChrome()
    elseif action == "filter" then W:CycleFilter()
    elseif action == "options" then CB.Options:Toggle()
    elseif action == "menu" then
      local id = W:ChromeId()
      if id == "filter" or id == "tabs" then W:ActivateChrome()
      else W:WindowMenu() end
    elseif action == "sellJunk" then
      if W.merchantOpen and CB.Integrations then CB.Integrations:SellJunk(true) end
    elseif action == "prevSection" then W:LeaveChrome(); W:JumpSection(-1)
    elseif action == "nextSection" then W:LeaveChrome(); W:JumpSection(1)
    end
    return
  end
  local e = W.selEntry
  if action == "up" or action == "down" or action == "left" or action == "right" then
    if #W.nav == 0 then
      local taken = W.opts.edge and W.opts.edge(action)
      if not taken and action == "up" then W:EnterChrome() end
      return
    end
    if not e then W:SelectEntry(W.nav[1]); return end
    local nxt = Pad:Neighbor(W.nav, e, action)
    -- down from the last row reaches the bag slots in the footer
    if action == "down" and not nxt and W.kind == "bags" then
      for i, c in ipairs(W:ChromeList()) do
        if c.id == "bagslot" then W:EnterChrome(i); return end
      end
    end
    local leave = W.opts.edge and Pad:RowEdge(W.nav, e, action) and W.opts.edge(action)
    if leave then return end
    if nxt then W:SelectEntry(nxt)
    else
      local taken = W.opts.edge and W.opts.edge(action)
      if not taken and action == "up" then W:EnterChrome() end
    end
  elseif action == "use" then
    if not e then return end
    if e.fold then
      W:ToggleSection(e.fold)                          -- a folded section opens
      return
    end
    if e.free then
      if CursorHasItem() then W.freeBtn:Click() end
    elseif CursorHasItem() then
      Container.PickupContainerItem(e.rec.bag, e.rec.slot)
    elseif not e.rec.empty then
      W:UseItem(e.rec)
    end
  elseif action == "pickup" then
    if e and e.rec and W:CanSellOne(e.rec) and not CursorHasItem() then W:SellAmount(e.rec, 1)     -- at a vendor: sell one
    elseif e and e.rec then W:Pickup(e.rec) end
  elseif action == "menu" then
    if e and e.fold then W:SectionMenu(e.btn, e.fold)
    elseif e and e.rec and not e.rec.empty then W:ItemMenu(e) else W:WindowMenu() end
  elseif action == "close" then
    if CursorHasItem() then ClearCursor()
    elseif W:ClearSearch() then                      -- B first leaves the search; the next B closes the window
    else
      -- bags that a visit (mailbox, vendor, bank ...) opened for itself leave together with it
      local visit = W == CB.Window and View.VisitOwningBags()
      -- at a merchant the bags and the vendor always leave together, whoever opened the bags
      if not visit and W == CB.Window and CB.Vendor and CB.Vendor.atMerchant then visit = CB.Vendor end
      local N = CB.NativeWindows
      if visit then visit:Leave()
      elseif W == CB.Window and N and N:Paired() then N:LeavePaired(W)   -- native vendor/mail/trade/AH/guild bank: leave together
      else W:Close() end
    end
  elseif action == "prevSection" then W:JumpSection(-1)
  elseif action == "nextSection" then W:JumpSection(1)
  elseif action == "collapse" then
    if e then local sec = W.sections[e.sec]; if sec then W:ToggleSection(sec.name) end end
  elseif action == "filter" then W:CycleFilter()
  elseif action == "sort" then W:CleanUp()
  elseif action == "favorite" then if e and e.rec then W:ToggleFavorite(e.rec) end
  elseif action == "quickMove" then W:QuickMove()
  elseif action == "options" then CB.Options:Toggle()
  elseif action == "sellJunk" then
    if W.merchantOpen and CB.Integrations then CB.Integrations:SellJunk(true) end
  end
end

