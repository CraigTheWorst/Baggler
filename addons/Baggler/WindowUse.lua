-- Baggler window: using, equipping, selling and destroying the selected item.
-- (Split from Window.lua; the View table and its helpers are shared through CB.View.)
-- Trust boundary: ordinary addon callbacks are insecure even when a hardware
-- press started them. Native mouse scripts and pre-armed secure bindings handle
-- protected use; these helpers select context and implement explicit menu work.
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local View = CB.View
local UI, Inv, Cat, Pad = CB.UI, CB.Inventory, CB.Categories, CB.Pad
local Container = C_Container
local initButton = View.initButton

--- Selling guard: favorites and gear-set items are never sold by accident, and epics need a second press.
function View:SellGuard(rec)
  if CB.db.sellProtect == false then return true end
  if CB.db.favorites[rec.itemID] then
    CB:Print((rec.name or "that item") .. " is a favorite - unfavorite it (or use Y > Favorite) to sell it.")
    return false
  end
  if CB.Categories and CB.Categories.setItems and CB.Categories.setItems[rec.itemID] then
    CB:Print((rec.name or "that item") .. " belongs to an equipment set - not selling it.")
    return false
  end
  if (rec.quality or 0) >= 4 then
    local now = GetTime and GetTime() or 0
    local p = self.pendingSell
    if p and p.key == rec.key and now - p.time < 4 then
      self.pendingSell = nil
      return true
    end
    self.pendingSell = { key = rec.key, time = now }
    CB:Print(("press again to sell %s (it's an epic)."):format(rec.link or rec.name or "it"))
    return false
  end
  return true
end

--- The native auction house takes an item into its sell slot from Blizzard's own bag-button click handler (a
--- right click on a bag item while the sell tab is up). Calling that handler, or the auction frame, from add-on
--- code would taint the auction house, so the controller's A is aimed at a secure `/click` on an untouched
--- Blizzard item button instead. This builds that one button (our usual item buttons have their click replaced)
--- and points it at the slot. Returns its name, or nil when the native auction house is not what is in front.
--- An item the auction house refuses (a gray one, a soulbound one ...) must not take that route: Blizzard's handler then
--- either re-checks and refuses from tainted code, or, off the sell tabs, falls through to C_Container.UseContainerItem
--- (ContainerFrame.lua l.1555-1611), which the game forbids from the proxy. The second result says "refused".
function View:AuctionRoute(bag, slot)
  if self:UseContext() ~= "blizzah" or self.kind ~= "bags" or InCombatLockdown() then return nil end
  if bag == nil or slot == nil or not self.frame then return nil end      -- (the proxy lives inside the window's frame)
  if self:AuctionSellable(bag, slot) == false then return nil, true end
  local proxy = self.auctionProxy
  if proxy == false then return nil end
  if not proxy then
    local ok, b = pcall(self.NewButton, self, bag, slot)
    if not ok or not b or not b.cbOrigClick then self.auctionProxy = false; return nil end
    -- NewButton preserves the inherited native OnClick; never re-register it:
    -- even the same callback would acquire addon script-registration provenance.
    b:SetScript("OnEnter", nil)
    b:Hide()
    proxy = b
    self.auctionProxy = b
  end
  local ok = pcall(initButton, proxy, proxy.cbHolder, bag, slot)
  if not ok then return nil end
  proxy.cbBag, proxy.cbSlot = bag, slot
  return proxy:GetName()
end

--- Whether the native auction house takes this bag item: the same question Blizzard's bag click asks
--- (C_AuctionHouse.IsSellItemValid with displayError false, ContainerFrame.lua l.1555). nil when the client can't say.
function View:AuctionSellable(bag, slot)
  local IL = rawget(_G, "ItemLocation")
  local valid = C_AuctionHouse and C_AuctionHouse.IsSellItemValid
  if not valid or not (IL and IL.CreateFromBagAndSlot) or bag == nil or slot == nil then return nil end
  local okLoc, loc = pcall(IL.CreateFromBagAndSlot, IL, bag, slot)
  if not okLoc or not loc then return nil end
  if loc.IsValid and not loc:IsValid() then return false end
  local ok, answer = pcall(valid, loc, false)
  if not ok then return nil end
  return answer and true or false
end

--- Who handles a click on a bag item: the game or us.
--- In the ordinary case (no vendor, bank, mail, trade or auction add-on window up, no ring/trinket question, Alt not held)
--- the item button runs the GAME'S OWN click script (never replaced, see NewButton), exactly as in the game's bags: use, equip, pick up, split, link, target
--- a spell on it. That is the only way every item works, because the game blocks a use call from add-on code for quest
--- items, grimoires and other spell items however the call is reached (and a handler of ours that calls the game's script
--- taints it). Our script is on the button only when "use" means something else than the game's answer: selling, depositing,
--- listing for the auction, the equip-slot question, or Alt held (the item menu): an invisible catcher over the button takes
--- the click then. The game's auction window needs the game's script too (only that puts the item in the sell slot).
function View:ClickMode(b)
  if self.kind ~= "bags" then return false end
  if self.altDown then return false end
  local ctx = self:UseContext()
  if ctx == "blizzah" then return true end
  if ctx ~= nil then return false end
  local rec = b and b.cbEntry and b.cbEntry.rec
  if rec and not rec.empty and self:NeedsSlotChoice(rec) then return false end
  return true
end

function View:SyncNativeClick(only)
  self.nativeClickPending = nil
  local function apply(b)
    if not b or not b.cbCatch then return end
    local native = self:ClickMode(b)
    b.cbNative = native
    if b.cbCatch:IsShown() == native then b.cbCatch:SetShown(not native) end
  end
  if only then apply(only) else for _, b in pairs(self.buttons) do apply(b) end end
end

--- Looks for a change in what "use" means (a window opened, Alt pressed) and re-picks every button's click script.
--- Run from the window's update, ten times a second, and at once when Alt changes.
function View:SyncClickMode(dt, force)
  self.clickSyncAcc = (self.clickSyncAcc or 0) + (dt or 0)
  if not force and self.clickSyncAcc < 0.1 then return end
  self.clickSyncAcc = 0
  if self.kind ~= "bags" or not (self.frame and self.frame:IsShown()) then return end
  local key = tostring(self:UseContext())
  if key ~= self.clickKey or self.nativeClickPending then
    self.clickKey = key
    self:SyncNativeClick()
    -- Native pane changes (Send Mail -> Inbox, for example) also change whether
    -- controller A needs the secure /use route. Successful bindings otherwise
    -- remain stale until the selection moves. SyncDirectUse guards combat itself.
    if CB.Pad and CB.Pad.SyncDirectUse then CB.Pad:SyncDirectUse() end
  end
end
CB:RegisterEvent("MODIFIER_STATE_CHANGED", function()
  local W = CB.Window
  if not W then return end
  local alt = IsAltKeyDown and IsAltKeyDown() and true or false
  if alt ~= (W.altDown and true or false) then
    W.altDown = alt
    W:SyncNativeClick()
  end
end)

--- A right click that uses a spell item (a drink, a potion, a scroll) cannot come from add-on code: the game blocks
--- UseContainerItem for those, however the call is reached. The controller gets round it with a secure button that
--- runs `/use bag slot` (Pad:WriteMacro); the mouse gets the same thing here. One invisible secure button follows
--- the item under the mouse and answers the right button only. Left clicks and mouse motion pass straight through
--- to the item button underneath, so picking up, dragging and tooltips are untouched. It is armed only when a plain
--- use is what a right click means (no vendor, bank, mail, trade or auction window, no ring/trinket question);
--- otherwise it is hidden and the usual handling applies. Alt+right does nothing (Alt-click is the item menu).
--- A secure frame cannot be moved or changed in combat, so in combat it stays where it was.
local mouseUse
local isEquippable            -- (defined further down)
local function mouseUseButton()
  if mouseUse ~= nil then return mouseUse or nil end
  mouseUse = false
  local ok, b = pcall(CreateFrame, "Button", "BagglerMouseUse", UIParent, "SecureActionButtonTemplate")
  if not ok or not b or not b.SetPassThroughButtons or not b.SetPropagateMouseMotion then
    CB:Warn("use", "mouse use button unavailable: " .. tostring(ok and "no pass-through" or b))
    return nil          -- without pass-through it would swallow left clicks and tooltips, so it is not used at all
  end
  b:RegisterForClicks("RightButtonUp", "RightButtonDown")
  b:SetAttribute("type2", "macro")
  -- the button under it loses the mouse when this one appears over it, so hover is handed on: the game's own tooltip
  -- and our selection come from the item button's scripts
  b:SetScript("OnEnter", function(self)
    local item = self.cbItem
    if not item then return end
    local enter = item:GetScript("OnEnter")
    if enter then enter(item) end
    if self.cbView then
      if item.cbEntry then self.cbView:SelectEntry(item.cbEntry, true) end
      self.cbView:HoverCard(item)
    end
  end)
  b:SetScript("OnLeave", function(self)
    local item = self.cbItem
    local leave = item and item:GetScript("OnLeave")
    if leave then leave(item) end
    if self.cbView then self.cbView:HoverCardEnd() end
  end)
  pcall(b.SetPassThroughButtons, b, "LeftButton", "MiddleButton", "Button4", "Button5")
  pcall(b.SetPropagateMouseMotion, b, true)
  b:Hide()
  mouseUse = b
  return b
end

function View:ArmMouseUse(btn)
  local ov = mouseUseButton()
  if not ov or InCombatLockdown() then return end
  local rec = btn and btn.cbEntry and btn.cbEntry.rec
  local plain = self.kind == "bags" and rec and not rec.empty and not self:UseContext()
    and not self:NeedsSlotChoice(rec) and not self.chrome and not self.sizing
    and not (CursorHasItem and CursorHasItem()) and not (SpellIsTargeting and SpellIsTargeting())
  if not plain or btn.cbBag == nil or btn.cbSlot == nil then ov:Hide(); return end
  ov.cbView, ov.cbItem = self, btn
  -- laid over the item button by screen position: not its child and not anchored to it (see UI:PlaceOver), or the bags
  -- window would become protected and could not be opened in combat
  UI:PlaceOver(ov, btn)
  ov:SetFrameStrata(btn:GetFrameStrata())
  ov:SetFrameLevel(btn:GetFrameLevel() + 5)
  ov:SetAttribute("macrotext2", ("/use [nomod:alt] %d %d"):format(btn.cbBag, btn.cbSlot))
  ov:Show()
end


--- The invisible secure overlay that used to answer right clicks is no longer needed: the game's own click script runs on
--- the item buttons (see View:ClickMode). This only makes sure it is out of the way.
function View:ArmMouseUse() if mouseUse and not InCombatLockdown() then mouseUse:Hide() end end

--- Hides the overlay (the bags closed). In combat it cannot be hidden; it goes when combat ends.
function View.HideMouseUse()
  if mouseUse and not InCombatLockdown() then mouseUse:Hide() end
end
CB:RegisterEvent("PLAYER_REGEN_ENABLED", function()
  if mouseUse and not (CB.Window and CB.Window:IsOpen()) then mouseUse:Hide() end
end)

--- Another window taking over what "use" means disarms it at once, even with the mouse resting on an item.
for _, ev in ipairs({ "MERCHANT_SHOW", "BANKFRAME_OPENED", "MAIL_SHOW", "TRADE_SHOW", "GUILDBANKFRAME_OPENED", "AUCTION_HOUSE_SHOW" }) do
  CB:RegisterEvent(ev, function()
    if mouseUse and not InCombatLockdown() then mouseUse:Hide() end
  end)
end

--- Use / equip / (at a bank) deposit or withdraw, for a menu row or a mouse click.
--- A direct UseContainerItem from the addon can be blocked for spell items.
--- Plain controller use normally runs a pre-armed secure binding instead; contextual
--- actions and refused auction items can still reach this function. Do not turn a
--- fallback callback into a synthetic secure click: it remains addon-originated.
function View:UseItem(rec)
  if not rec or rec.empty then return end
  if self:UseContext() == "merchant" and not self:SellGuard(rec) then return end
  -- (A on a refused item reaches here: Pad:WriteMacro leaves it unarmed. Nothing is called; the player is told why.)
  if self:UseContext() == "blizzah" and self.kind == "bags" and self:AuctionSellable(rec.bag, rec.slot) == false then
    CB:Print((rec.link or rec.name or "this item") .. " can't be auctioned.")
    return
  end
  if not self:UseContext() and self:NeedsSlotChoice(rec) and not (CursorHasItem and CursorHasItem()) then
    self:Equip(rec, self.selEntry and self.selEntry.btn)
    return
  end
  if CB.UseHook and self.opts.kind == "bags" then
    local ok, took = pcall(CB.UseHook, rec)
    if ok and took then return end
  end
  if CB.NativeWindows and CB.NativeWindows:SendActive() and self.kind == "bags" then
    if not ClickSendMailItemButton then return end
    if CursorHasItem and CursorHasItem() then ClearCursor() end
    Container.PickupContainerItem(rec.bag, rec.slot)
    ClickSendMailItemButton()
    if CursorHasItem and CursorHasItem() then ClearCursor() end
    return
  end
  if CB.Mail and CB.Mail:SendActive() and self.opts.kind == "bags" then
    if CB.Mail:Attach(rec) then return end
  end
  local bankType
  if CB.NativeWindows and self:UseContext() == "bank" then
    bankType = CB.NativeWindows:BankType()
  elseif CB.Bank and CB.Bank.active and CB.Bank.ActiveBankType then
    bankType = CB.Bank:ActiveBankType()
  end
  local account = Enum and Enum.BankType and Enum.BankType.Account
  -- NOTE: clicking the secure /use button from add-on code is itself forbidden
  -- (ADDON_ACTION_FORBIDDEN RunMacroText), so a mouse/menu use calls the container API directly.
  -- The controller's A button reaches the secure button through a real key binding (directUse).
  -- the bags change a moment after a use; point the controller at what is there now
  if C_Timer and C_Timer.After then
    C_Timer.After(0.15, function() Pad:SyncDirectUse() end)
    C_Timer.After(0.6, function() Pad:SyncDirectUse() end)
  end
  local args = { rec.bag, rec.slot }
  if bankType ~= nil then args = { rec.bag, rec.slot, nil, bankType } end
  local ok, err = pcall(Container.UseContainerItem, unpack(args, 1, 4))
  CB:Info("use", ("UseContainerItem(%s,%s) %s"):format(tostring(rec.bag), tostring(rec.slot), ok and "called" or "failed"))
  if not ok then
    CB:Warn("use", "UseContainerItem failed: " .. tostring(err))
    CB:Print("can't use that right now.")
  end
end

--- At a vendor, whether "sell one" is on offer for this item: a stack of a sellable item.
function View:CanSellOne(rec)
  return rec and not rec.empty and (rec.count or 1) > 1 and (rec.sellPrice or 0) > 0 and self:UseContext() == "merchant"
end

--- What the controller's "pick up" button does for this item right now, in words: at a vendor it sells one from a stack.
function View:PickupLabel(rec)
  return self:CanSellOne(rec) and "Sell 1" or "Pick up"
end

--- An empty slot in an ordinary bag, or nil.
function View:FreeSlot()
  local _, empties = Inv:Scan(self:BagIDs())
  for _, r in ipairs(empties or {}) do
    local free, kind = Container.GetContainerNumFreeSlots(r.bag)
    if free and free > 0 and (kind or 0) == 0 then return r.bag, r.slot end
  end
end

--- Sells what is on the cursor to the open vendor. Calling the game's "drop on the merchant" (PickupMerchantItem)
--- from add-on code does nothing, but selling a bag slot the usual way does: so the held item is set down in an empty
--- slot and that slot is sold. Used for "sell what I hold" and for selling part of a stack.
function View:SellCursor()
  if not (CursorHasItem and CursorHasItem()) or self:UseContext() ~= "merchant" then return false end
  local bag, slot = self:FreeSlot()
  if not bag then CB:Print("no free bag slot to sell it from - make room, or put it back."); return false end
  Container.PickupContainerItem(bag, slot)                   -- set it down in the empty slot
  local waited = 0
  local function sell()
    waited = waited + 0.05
    local info = Container.GetContainerItemInfo(bag, slot)
    if info and info.itemID then
      local ok, err = pcall(Container.UseContainerItem, bag, slot)
      CB:Info("use", ("sold the held item from %d:%d (waited %.2fs) %s"):format(bag, slot, waited, ok and "called" or tostring(err)))
      C_Timer.After(0.2, function() Pad:SyncDirectUse() end)
    elseif waited < 1.5 then
      C_Timer.After(0.05, sell)
    else
      CB:Warn("use", "the held item never settled into the free slot")
    end
  end
  C_Timer.After(0.05, sell)
  return true
end

--- Sells `n` of a stack to the open vendor (the whole stack goes the usual way). A part is split off onto the cursor,
--- set down in an empty slot and sold from there, so the selling guard still applies (favourites, gear sets, epics) and
--- nothing is sold that was not asked for.
function View:SellAmount(rec, n)
  if not self:CanSellOne(rec) then return end
  n = math.max(1, math.floor(n or 1))
  if n >= rec.count then self:UseItem(rec); return end         -- the whole stack: the usual sale (it guards itself)
  if CursorHasItem and CursorHasItem() then return end
  if not self:FreeSlot() then CB:Print("no free bag slot to split it into - make room first."); return end
  if not self:SellGuard(rec) then return end
  local ok, err = pcall(Container.SplitContainerItem, rec.bag, rec.slot, n)
  if not ok then CB:Warn("use", "SplitContainerItem failed: " .. tostring(err)); return end
  -- the split item reaches the cursor a moment later (the game confirms it first)
  local waited = 0
  local function handOver()
    waited = waited + 0.05
    if CursorHasItem and CursorHasItem() then
      self:SellCursor()
    elseif waited < 1.5 then
      C_Timer.After(0.05, handOver)
    else
      CB:Warn("use", "the split stack never reached the cursor")
    end
  end
  C_Timer.After(0.05, handOver)
end

--- Mouse click on a slot. Modified clicks and a held cursor keep the template's behavior.
--- A plain use is taken over by UseItem so it does not call the protected function itself.
function View:ClickItem(b, button, ...)
  local W = self
  local orig = b.cbOrigClick
  if W.merchantOpen then
    CB:Info("use", ("click %s on %s:%s cursor=%s combat=%s modified=%s"):format(tostring(button), tostring(b.cbBag), tostring(b.cbSlot),
      tostring(CursorHasItem and CursorHasItem()), tostring(InCombatLockdown()), tostring(IsModifiedClick and IsModifiedClick())))
  end
  -- Alt-click opens the same item menu the controller's menu button opens, so a mouse
  -- can reach Bind. A plain click still uses or picks up, the way it always has.
  if not InCombatLockdown() and not (CursorHasItem and CursorHasItem())
      and IsAltKeyDown and IsAltKeyDown() then
    local e = b.cbEntry
    if e and e.rec and not e.rec.empty then
      W:ItemMenu(e)
      return
    end
  end
  -- At a vendor a stack is sold a piece at a time with the left click, and whole with the right click (Shift+right-click
  -- also sells one). A single item keeps the usual clicks: left picks it up, right sells it.
  if not InCombatLockdown() and not (CursorHasItem and CursorHasItem()) and b.cbEntry and self:CanSellOne(b.cbEntry.rec) then
    local shift = IsShiftKeyDown and IsShiftKeyDown()
    local other = (IsControlKeyDown and IsControlKeyDown()) or (IsAltKeyDown and IsAltKeyDown())
    if (button == "LeftButton" and not shift and not other) or (button == "RightButton" and shift) then
      W:SellAmount(b.cbEntry.rec, 1)
      return
    end
  end
  -- remember what a left click lifts, so a drop on the destroy button knows what is on the cursor
  if not (CursorHasItem and CursorHasItem()) and b.cbEntry and b.cbEntry.rec and not b.cbEntry.rec.empty then
    W.heldRec = b.cbEntry.rec
  end
  if InCombatLockdown() or (IsModifiedClick and IsModifiedClick()) or (CursorHasItem and CursorHasItem()) then
    if orig then return orig(b, button, ...) end
    return
  end
  -- A plain right-click is "use". We already know the slot, so route it to UseItem directly.
  -- (Never swap Blizzard's UseContainerItem out and back: writing to that table from add-on
  -- code taints the slot, and the game's own secure code reading it later is blocked.)
  if button == "RightButton" and b.cbBag ~= nil and b.cbSlot ~= nil then
    local rec = (b.cbEntry and b.cbEntry.rec) or { bag = b.cbBag, slot = b.cbSlot, empty = false }
    -- the whole record, not a stub: the selling guard, the equip-slot question and the auction hook all read it
    W:UseItem(rec)
    return
  end
  if orig then
    local ok, err = pcall(orig, b, button, ...)
    if not ok then CB:Warn("use", "item click failed: " .. tostring(err)) end
  end
end

-- Slots an item can go to when there is more than one (rings, trinkets, one-handers).
local EQUIP_CHOICES = {
  INVTYPE_FINGER  = { { 11, "Ring 1" }, { 12, "Ring 2" } },
  INVTYPE_TRINKET = { { 13, "Trinket 1" }, { 14, "Trinket 2" } },
  INVTYPE_WEAPON  = { { 16, "Main hand" }, { 17, "Off hand" } },
}

--- Which other window (if any) makes the game treat "use" as something else.
function View:UseContext()
  if CB.UseHook and CB.UseHookActive and CB.UseHookActive() and self.kind == "bags" then return "auction" end
  if CB.NativeWindows then
    local context = CB.NativeWindows:Context()
    if context then return context end
  end
  if self.merchantOpen or (CB.Vendor and CB.Vendor.atMerchant) then return "merchant" end
  if CB.Bank and CB.Bank.active then return "bank" end
  if CB.GuildBank and CB.GuildBank.active then return "guildbank" end
  if CB.Trade and CB.Trade.active then return "trade" end
  if CB.Mail and CB.Mail:SendActive() then return "mail" end
  local ah = rawget(_G, "AuctionHouseFrame")
  if ah and ah.IsVisible and ah:IsVisible() then return "blizzah" end
  return nil
end

isEquippable = function(rec)
  return rec and rec.equipLoc and rec.equipLoc ~= "" and rec.equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" and rec.equipLoc ~= "INVTYPE_NON_EQUIP"
end

--- What A will do to this item right now, in words (shown in its tooltip so it is never a surprise).
function View:UseLabel(rec)
  if not rec or rec.empty then return nil end
  if CursorHasItem and CursorHasItem() then return "Place" end
  local ctx = self:UseContext()
  if ctx == "auction" then return "Send to the auction" end
  if ctx == "blizzah" then
    return self:AuctionSellable(rec.bag, rec.slot) == false and "Can't auction" or "Put in the auction slot"
  end
  if ctx == "merchant" then return (rec.sellPrice or 0) > 0 and "Sell" or "Can't sell" end
  if ctx == "bank" then return self.kind == "bank" and "Take out" or "Deposit" end
  if ctx == "guildbank" then return "Deposit" end
  if ctx == "trade" then return "Add to trade" end
  if ctx == "mail" then return "Attach to the letter" end
  if isEquippable(rec) then return rec.equipLoc == "INVTYPE_BAG" and "Equip bag" or "Equip" end
  if rec.lootable then return "Open" end
  return "Use"
end

--- True when both slots a ring / trinket could take are filled, so the player should choose which to replace.
function View:NeedsSlotChoice(rec)
  if rec and rec.equipLoc == "INVTYPE_BAG" then return true end
  if not rec or CB.db.askEquipSlot == false then return false end
  if rec.equipLoc ~= "INVTYPE_FINGER" and rec.equipLoc ~= "INVTYPE_TRINKET" then return false end
  local choices = EQUIP_CHOICES[rec.equipLoc]
  for _, c in ipairs(choices or {}) do
    if not (GetInventoryItemID and GetInventoryItemID("player", c[1])) then return false end
  end
  return true
end

-- Exact wearable bag slots only: never backpack, reagent, keyring or bank tabs.
-- Native BaseBagSlotButtonMixin uses PutItemInBag(inventoryID), not generic equip.
function View:BagEquipEntries(rec)
  local list = {}
  local source = {}
  for k, v in pairs(rec) do source[k] = v end -- menu records may be recycled on refresh
  for bag = 1, (NUM_BAG_SLOTS or 4) do
    local invSlot = Container.ContainerIDToInventoryID and Container.ContainerIDToInventoryID(bag)
    if invSlot then
      local itemID = GetInventoryItemID("player", invSlot)
      local link = GetInventoryItemLink("player", invSlot)
      local capacity = Container.GetContainerNumSlots(bag)
      local _, family = Container.GetContainerNumFreeSlots(bag)
      local kind = family == 0 and "General" or "Specialty (type unknown)"
      if family and family ~= 0 and link and C_Item and C_Item.GetItemInfo then
        local _, _, _, _, _, _, subtype = C_Item.GetItemInfo(link)
        kind = subtype or kind
      elseif family == nil then kind = "Type unknown" end
      local name = itemID and ((link and link:match("%[(.-)%]")) or Container.GetBagName(bag) or "Unknown bag") or "Empty"
      local expected = { itemID = itemID, link = link, capacity = capacity }
      local description = ("Bag %d: %s - %s slots - %s"):format(bag, name, tostring(capacity or "?"), itemID and kind or "Empty")
      local entry = {
        text = description,
        tip = description .. "\nThe game checks capacity and specialty compatibility; Baggler never moves bag contents.",
      }
      if itemID and source.bag == bag then
        entry.text = description .. " (holds the new bag)"
        entry.subTitle = ("Prepare replacement of Bag %d"):format(bag)
        entry.tip = "Prepare the new bag outside this target first. Replacement requires a separate Continue press."
        entry.sub = function() return self:PrepareBagReplacementEntries(source, bag, expected) end
      elseif itemID then
        -- A nested menu, not a second popup: it opens where this one did and B steps back to the chooser.
        entry.subTitle = ("Replace bag %d?"):format(bag)
        entry.sub = function()
          return {
            { text = ("Replace %s (%s slots)"):format(name, tostring(capacity or "?")),
              tip = "A new bag's size is only known once it is worn, so the result is reported afterwards. The game refuses the swap if the contents do not fit.",
              func = function() self:EquipBagTo(source, bag, expected) end },
            { text = "Cancel", func = function() end },
          }
        end
      else
        entry.func = function() self:EquipBagTo(source, bag, expected) end
      end
      list[#list + 1] = entry
    end
  end
  if #list == 0 then list[1] = { text = "Bag slot API unavailable", disabled = true } end
  return list
end

-- Physical-placement preparation only. All snapshots contain scalars, never live scan records.
-- Blizzard UI source, 1.60.1.70938, pin bebcb6bf309cf41b41bd74f8ca651e6a105b2676:
-- ContainerDocumentation.lua:420-429; Mainline/ContainerFrame.lua:1503-1540;
-- GameCursorDocumentation.lua:74-76; MainMenuBarBagButtons.lua:69-95.
-- Cached under profile scratch/forever-research/bag-source-<pin>. Native source
-- exposes pickup/drop, not an atomic server receipt: stop on any unverified phase.
local function placementContainer(bag)
  local inv = bag > 0 and Container.ContainerIDToInventoryID(bag) or nil
  local _, family = Container.GetContainerNumFreeSlots(bag)
  return { bag = bag, inv = inv, itemID = inv and GetInventoryItemID("player", inv),
    link = inv and GetInventoryItemLink("player", inv), capacity = Container.GetContainerNumSlots(bag), family = family }
end
local function placementUnchanged(c)
  local now = placementContainer(c.bag)
  return now.inv == c.inv and now.itemID == c.itemID and now.link == c.link
    and now.capacity == c.capacity and now.family == c.family
    and not (c.inv and IsInventoryItemLocked and IsInventoryItemLocked(c.inv))
end
local function placementItem(bag, slot)
  local i = Container.GetContainerItemInfo(bag, slot)
  if i then return { bag = bag, slot = slot, itemID = i.itemID, link = i.hyperlink,
    count = i.stackCount or 1, locked = i.isLocked } end
end
local function placementMatches(wanted, bag, slot)
  local i = placementItem(bag, slot)
  return i and not i.locked and i.itemID == wanted.itemID and i.link == wanted.link and i.count == wanted.count
end
local function placementCursor(i)
  local kind, id, link = GetCursorInfo()
  return kind == "item" and id == i.itemID and link == i.link
end
local function placementWhere(bag, slot)
  local inv = bag > 0 and Container.ContainerIDToInventoryID(bag)
  local link = inv and GetInventoryItemLink("player", inv)
  local name = link and link:match("%[(.-)%]")
  return (bag == 0 and "Backpack" or ("Bag " .. bag .. (name and (" (" .. name .. ")") or ""))) .. ", slot " .. slot
end

-- Continuations retain the chosen target and scalar source identity, not a coordinate-only selection.
local function replacementIntent(source, target, expected, dest, sc, dc, displaced)
  local r = { bag = dest.bag, slot = dest.slot, itemID = source.itemID, link = source.link,
    count = source.count or 1, name = source.name or (source.link and source.link:match("%[(.-)%]")), equipLoc = "INVTYPE_BAG" }
  return { source = r, origin = { bag = source.bag, slot = source.slot }, target = target,
    expected = { itemID = expected.itemID, link = expected.link, capacity = expected.capacity },
    sc = sc, dc = dc, displaced = displaced, tries = 0, status = "pending" }
end

-- One chat line per continuation transition (ready / discarded); the journal keeps the exact predicate.
local function discardReplacement(view, intent, why)
  view.bagReplacement = nil
  CB:Print(("Bag %d replacement discarded: %s."):format(intent.target, why))
end

-- A bag the player carries by hand: observe (never move) until it is verifiably set down outside the target.
local HELD_STEP, HELD_TRIES = 0.2, 300 -- about a minute; the player is choosing a slot

-- Coordinates holding an item indistinguishable from `s` (same itemID/link/count), keyed "bag:slot".
local function sameItemCoords(s, wantInside, target)
  local found = {}
  for b = 0, (NUM_BAG_SLOTS or 4) do
    if (b == target) == wantInside then
      for slot = 1, (Container.GetContainerNumSlots(b) or 0) do
        if placementMatches(s, b, slot) then found[#found + 1] = { bag = b, slot = slot } end
      end
    end
  end
  return found
end

--- One observation of a hand-carried bag. Returns true once it is verified outside the target (the intent is
--- then an ordinary verified continuation); otherwise waits, or discards with one line.
function View:ObserveHeldBag(intent, schedule)
  local s, target, expected = intent.source, intent.target, intent.expected
  local tc = placementContainer(target)
  local name = s.name or "the new bag"
  if tc.itemID ~= expected.itemID or tc.link ~= expected.link or tc.capacity ~= expected.capacity then
    CB:Journal("bag", "held continuation discarded: predicate=target-identity")
    return discardReplacement(self, intent, ("Bag %d changed"):format(target))
  end
  if self.bagSwap then return discardReplacement(self, intent, "another bag swap is in progress") end
  if not (GetCursorInfo() or (CursorHasItem and CursorHasItem())) then
    local inside = sameItemCoords(s, true, target)
    if #inside > #intent.priorInside then
      CB:Journal("bag", "held continuation discarded: predicate=placed-inside-target")
      return discardReplacement(self, intent, ("%s is back inside Bag %d"):format(name, target))
    end
    local fresh = {}
    for _, c in ipairs(sameItemCoords(s, false, target)) do
      if not intent.priorOutside[c.bag .. ":" .. c.slot] then fresh[#fresh + 1] = c end
    end
    if #fresh == 1 then
      local at = fresh[1]
      s.bag, s.slot = at.bag, at.slot
      intent.sc, intent.dc = placementContainer(target), placementContainer(at.bag)
      intent.status = "pending"
      CB:Journal("bag", ("held continuation placed: target=%d new=%d:%d"):format(target, at.bag, at.slot))
      return true
    end
  end
  if not schedule then return end
  intent.tries = intent.tries + 1
  if intent.tries >= HELD_TRIES or not (C_Timer and C_Timer.After) then
    CB:Journal("bag", "held continuation discarded: predicate=not-placed-outside-before-timeout")
    return discardReplacement(self, intent, ("%s was not placed outside Bag %d in time; your cursor was left untouched"):format(name, target))
  end
  C_Timer.After(HELD_STEP, function() self:ObserveBagReplacement(intent, true) end) -- observation ONLY
end

-- Read-only verification. Only the observation chain (schedule=true) creates timers; menus merely read state.
function View:ObserveBagReplacement(intent, schedule)
  if self.bagReplacement ~= intent then return end
  if intent.status == "holding" and not self:ObserveHeldBag(intent, schedule) then return end
  local expected, tc = intent.expected, placementContainer(intent.target)
  local why
  if GetCursorInfo() or (CursorHasItem and CursorHasItem()) then why = "something is on the cursor"
  elseif self.bagSwap then why = "another bag swap is in progress"
  elseif tc.itemID ~= expected.itemID or tc.link ~= expected.link or tc.capacity ~= expected.capacity then
    why = ("Bag %d changed"):format(intent.target)
  elseif not placementUnchanged(intent.sc) or not placementUnchanged(intent.dc) then why = "a carried bag changed or is locked"
  end
  if why then
    CB:Journal("bag", ("continuation discarded: phase=observe predicate=cursor/pending/container/target-identity target=%d now id=%s link=%s capacity=%s")
      :format(intent.target, tostring(tc.itemID), tostring(tc.link), tostring(tc.capacity)))
    return discardReplacement(self, intent, why)
  end
  local origin = intent.origin
  -- (after a player-made swap the origin holds whatever they put there: only the new bag's place is verified)
  local originOK = intent.manual or (intent.displaced and placementMatches(intent.displaced, origin.bag, origin.slot))
    or (not intent.displaced and not Container.GetContainerItemInfo(origin.bag, origin.slot))
  if originOK and placementMatches(intent.source, intent.source.bag, intent.source.slot) then
    if intent.status ~= "ready" then
      intent.status = "ready"
      self.selKey = intent.source.bag .. ":" .. intent.source.slot -- select the relocated new bag once
      CB:Journal("bag", ("continuation ready: target=%d source=%d:%d"):format(intent.target, intent.source.bag, intent.source.slot))
      CB:Print(("%s moved \226\128\148 press Continue to replace Bag %d."):format(intent.source.name or "The new bag", intent.target))
      CB:Fire("DIRTY")
    end
    return true
  end
  if intent.status == "ready" then
    CB:Journal("bag", "continuation discarded: phase=observe predicate=relocated-source-changed")
    return discardReplacement(self, intent, "the moved bag changed")
  end
  if not schedule then return end
  intent.tries = intent.tries + 1
  if intent.tries >= (intent.manual and HELD_TRIES or 15) or not (C_Timer and C_Timer.After) then
    CB:Journal("bag", "continuation discarded: phase=observe predicate=placement-not-verified-before-timeout")
    return discardReplacement(self, intent, "the move was not verified in time")
  end
  C_Timer.After(0.2, function() self:ObserveBagReplacement(intent, true) end) -- observation ONLY
end

function View:BagReplacementEntry(rec)
  local intent = self.bagReplacement
  if not intent then return end
  -- Item menus offer Continue only on the relocated new bag itself (the window menu passes no record).
  local s = intent.source
  if rec and not (rec.bag == s.bag and rec.slot == s.slot and rec.itemID == s.itemID
      and (rec.link == nil or rec.link == s.link)) then
    self:ObserveBagReplacement(intent) -- read-only: a stale intent is still discarded (and said once)
    return
  end
  if not self:ObserveBagReplacement(intent) then
    if not self.bagReplacement then return end
    if intent.status == "holding" then
      return { text = ("Place %s on any slot or item outside Bag %d"):format(s.name or "the new bag", intent.target), disabled = true }
    end
    return { text = "Replacement preparation awaiting verified placement", disabled = true }
  end
  local expected = intent.expected
  local name = expected.link and expected.link:match("%[(.-)%]") or "bag"
  local label = ("Continue replacing Bag %d %s (%s) with %s"):format(intent.target, name,
    tostring(expected.capacity), intent.source.name or "the new bag")
  return { text = label, tip = label .. ". Only this chosen target is used.", subTitle = label, sub = function()
    return {
      { text = "Replace this bag", func = function()
        local live = self.bagReplacement == intent
        if not live or not self:ObserveBagReplacement(intent) then
          -- (an observed discard has already said why in one line)
          if not live or self.bagReplacement == intent then
            CB:Print("replacement intent changed; select the new bag and target again. Cursor left untouched.")
          end
          return
        end
        self.bagReplacement = nil
        self:EquipBagTo(intent.source, intent.target, intent.expected)
      end },
      { text = "Cancel replacement", func = function() if self.bagReplacement == intent then self.bagReplacement = nil end end },
    }
  end }
end

-- The one automatic swap partner outside `target`: an ordinary, unlocked, non-bag, non-quest item in a carried
-- general-purpose bag (Backpack first). Unknown item class fails closed. No list is ever offered.
local function autoExchangePartner(source, target)
  local instant = C_Item and C_Item.GetItemInfoInstant
  if not instant then return end
  for b = 0, (NUM_BAG_SLOTS or 4) do
    if b ~= target then
      local dc = placementContainer(b)
      if dc.family == 0 then
        for s = 1, (dc.capacity or 0) do
          local dest = placementItem(b, s)
          if dest and dest.itemID and dest.link and not dest.locked and dest.itemID ~= source.itemID then
            local _, _, _, equipLoc, _, classID = instant(dest.itemID)
            local quest = Container.GetContainerItemQuestInfo and Container.GetContainerItemQuestInfo(b, s)
            if classID ~= nil and classID ~= 1 and classID ~= 12 and equipLoc ~= "INVTYPE_BAG"
                and not (quest and (quest.isQuestItem or quest.questID)) then
              return dest, dc
            end
          end
        end
      end
    end
  end
end

local function itemName(link, fallback) return (link and link:match("%[(.-)%]")) or fallback end
local function shortWhere(bag)
  if bag == 0 then return "Backpack" end
  local inv = Container.ContainerIDToInventoryID(bag)
  return itemName(inv and GetInventoryItemLink("player", inv), "Bag " .. bag)
end

--- What Replace offers when the new bag sits inside the target: at most two entries, never a list.
--- (1) pick the new bag up and let the player drop it on any slot/item outside the target (native swap);
--- (2) one automatic verified move (empty compatible slot first, else one ordinary item) behind one confirmation.
function View:PrepareBagReplacementEntries(source, target, expected)
  for b = 0, (NUM_BAG_SLOTS or 4) do
    local free, family = Container.GetContainerNumFreeSlots(b)
    CB:Journal("bag", ("census bag=%d target=%s free=%s family=%s capacity=%s compatible=%s")
      :format(b, tostring(b == target), tostring(free), tostring(family), tostring((Container.GetContainerNumSlots(b))),
        tostring(b ~= target and family == 0 and (free or 0) > 0)))
  end
  local name = source.name or itemName(source.link, "the new bag")
  local after = ("Then press Continue to replace Bag %d."):format(target)
  local out = {
    { text = ("Pick up %s \226\128\148 place it on any item outside Bag %d"):format(name, target),
      tip = ("Lifts only %s onto your cursor. Click or press A on any slot or item outside Bag %d to swap it there yourself. %s")
        :format(name, target, after),
      func = function() self:StartManualBagMove(source, target, expected) end },
  }
  local action, tip, run
  local db, ds = self:FindStagingSlot(target)
  if db then
    action = ("Move %s out of Bag %d to an empty slot (%s)"):format(name, target, shortWhere(db))
    tip = ("Moves only %s (%s) to the empty %s. %s"):format(name, placementWhere(target, source.slot), placementWhere(db, ds), after)
    run = function() self:StageBagOut(source, target, expected, db, ds) end
  else
    local live = source and placementItem(source.bag, source.slot)
    local dest, dc
    if live and not live.locked and live.itemID == source.itemID and live.link == source.link
        and live.count == (source.count or 1) and source.bag == target then
      dest, dc = autoExchangePartner(live, target)
    end
    local sc = placementContainer(target)
    if dest and sc.family == 0 then
      local other = itemName(dest.link, "that item")
      action = ("Move %s out of Bag %d by swapping it with %s (%s)"):format(name, target, other, shortWhere(dest.bag))
      tip = ("%s (%s) <-> %s (%s). Only these two items move. %s"):format(name, placementWhere(target, source.slot),
        other, placementWhere(dest.bag, dest.slot), after)
      run = function() self:ExchangeBagOut(live, dest, sc, dc, expected) end
    end
  end
  if run then
    out[2] = { text = "Swap automatically...", tip = tip, subTitle = "Swap automatically?", sub = function()
      return {
        { text = action, tip = tip, func = run },
        { text = after, disabled = true },
        { text = "Cancel", func = function() end },
      }
    end }
  end
  return out
end

-- Native PickupContainerItem exchanges the cursor with the specified slot. Never yield,
-- retry, ClearCursor, or infer a successful exchange from the API return value alone.
local function placementMismatch(wanted, bag, slot)
  local now = placementItem(bag, slot)
  if not now then return "missing-item" end
  if now.locked then return "item-locked" end
  if now.itemID ~= wanted.itemID then return "item-id-changed" end
  if now.link ~= wanted.link then return "item-link-changed" end
  if now.count ~= wanted.count then return "item-count-changed" end
end

local function placementCondition(view, sc, dc)
  if InCombatLockdown() then return "combat" end
  if view.bagSwap then return "pending-equip" end
  if SpellIsTargeting and SpellIsTargeting() then return "spell-targeting" end
  if not placementUnchanged(sc) then return "source-container-changed-or-locked" end
  if not placementUnchanged(dc) then return "destination-container-changed-or-locked" end
end

local function placementDiagnostic(phase, predicate, source, dest, sc, dc)
  local function item(i)
    if not i then return "empty" end
    return ("%s:%s id=%s link=%s count=%s lock=%s"):format(tostring(i.bag), tostring(i.slot),
      tostring(i.itemID), tostring(i.link), tostring(i.count), tostring(i.locked))
  end
  local function container(c)
    if not c then return "unavailable" end
    return ("bag=%s inv=%s id=%s link=%s capacity=%s family=%s lock=%s"):format(tostring(c.bag),
      tostring(c.inv), tostring(c.itemID), tostring(c.link), tostring(c.capacity), tostring(c.family),
      tostring(c.inv and IsInventoryItemLocked and IsInventoryItemLocked(c.inv)))
  end
  local ct, id, link = GetCursorInfo()
  -- Non-item cursor payloads are not item identities; never inspect extra cursor values.
  if ct ~= "item" then id, link = nil, nil end
  CB:Journal("bag", ("phase=%s predicate=%s cursor=%s/%s/%s | source expected={%s} now={%s} | destination expected={%s} now={%s}")
    :format(phase, predicate, tostring(ct), tostring(id), tostring(link), item(source),
      item(source and placementItem(source.bag, source.slot)), item(dest), item(dest and placementItem(dest.bag, dest.slot))))
  CB:Journal("bag", ("phase=%s containers source expected={%s} now={%s} destination expected={%s} now={%s}")
    :format(phase, container(sc), container(sc and placementContainer(sc.bag)), container(dc), container(dc and placementContainer(dc.bag))))
end

function View:ExchangeBagOut(source, dest, sc, dc, expected)
  local phase = "preflight"
  local function stop(reason)
    self.bagPlacement, self.bagReplacement = nil, nil
    placementDiagnostic(phase, reason, source, dest, sc, dc)
    CB:Print("couldn't confirm the exchange: " .. phase .. " / " .. reason
      .. ". Your cursor was left untouched; check both slots and place any held item yourself. No further move was attempted.")
  end
  if not source or not dest or not sc or not dc or source.bag ~= sc.bag or dest.bag ~= dc.bag
      or sc.bag < 1 or sc.bag > (NUM_BAG_SLOTS or 4) or dc.bag < 0 or dc.bag > (NUM_BAG_SLOTS or 4)
      or sc.bag == dc.bag or sc.family ~= 0 or dc.family ~= 0
      or not source.link or not dest.link or source.itemID == dest.itemID
      or source.slot < 1 or source.slot > sc.capacity or dest.slot < 1 or dest.slot > dc.capacity then return stop("invalid-placement-or-indistinguishable-items") end
  if self.bagPlacement then return stop("pending-placement") end
  local reason = placementCondition(self, sc, dc)
  if reason then return stop(reason) end
  if GetCursorInfo() or (CursorHasItem and CursorHasItem()) then return stop("cursor-not-empty") end
  reason = placementMismatch(source, source.bag, source.slot)
  if reason then return stop("source-" .. reason) end
  reason = placementMismatch(dest, dest.bag, dest.slot)
  if reason then return stop("destination-" .. reason) end
  if expected and (sc.itemID ~= expected.itemID or sc.link ~= expected.link or sc.capacity ~= expected.capacity
      or expected.itemID == source.itemID) then return stop("chosen-target-changed-or-same-id") end
  self.bagReplacement = nil
  self.bagPlacement = true
  placementDiagnostic(phase, "verified", source, dest, sc, dc)
  phase = "source-pickup"
  local ok = pcall(Container.PickupContainerItem, source.bag, source.slot)
  if not ok then return stop("native-call-error") end
  reason = placementCondition(self, sc, dc)
  if reason then return stop(reason) end
  if not placementCursor(source) then return stop("source-cursor-mismatch") end
  if Container.GetContainerItemInfo(source.bag, source.slot) then return stop("origin-occupied") end
  reason = placementMismatch(dest, dest.bag, dest.slot)
  if reason then return stop("destination-" .. reason) end
  placementDiagnostic(phase, "verified", source, dest, sc, dc)
  phase = "destination-exchange"
  ok = pcall(Container.PickupContainerItem, dest.bag, dest.slot)
  if not ok then return stop("native-call-error") end
  reason = placementCondition(self, sc, dc)
  if reason then return stop(reason) end
  if not placementCursor(dest) then return stop("displaced-cursor-mismatch") end
  if Container.GetContainerItemInfo(source.bag, source.slot) then return stop("origin-occupied") end
  reason = placementMismatch(source, dest.bag, dest.slot)
  if reason then return stop("relocated-source-" .. reason) end
  placementDiagnostic(phase, "verified", source, dest, sc, dc)
  phase = "return-displaced"
  ok = pcall(Container.PickupContainerItem, source.bag, source.slot)
  self.bagPlacement = nil
  if not ok then return stop("native-call-error") end
  reason = placementCondition(self, sc, dc)
  if reason then return stop(reason) end
  if GetCursorInfo() or (CursorHasItem and CursorHasItem()) then return stop("cursor-not-empty") end
  reason = placementMismatch(dest, source.bag, source.slot) or placementMismatch(source, dest.bag, dest.slot)
  placementDiagnostic(phase, reason or "verified", source, dest, sc, dc)
  if expected then
    self.bagReplacement = replacementIntent(source, sc.bag, expected, dest, sc, dc, dest)
    self:ObserveBagReplacement(self.bagReplacement, true)
  end
  if reason then
    CB:Print("couldn't confirm final placement: " .. phase .. " / " .. reason .. ". Awaiting observation only; check both slots and place any held item yourself.")
  elseif not expected then
    CB:Print("Preparation verified. Continue replacing Bag " .. sc.bag .. " from the item or window menu; Replace is a separate press.")
  else
    self:BagReplacementPendingNote()
  end
  CB:Fire("DIRTY")
end

--- After a verified preparation the observer prints the ready/discard line itself; only a still-pending intent needs a note.
function View:BagReplacementPendingNote()
  local intent = self.bagReplacement
  if intent and intent.status == "pending" then
    CB:Print(("Preparation sent; Continue for Bag %d appears once the move is verified."):format(intent.target))
  end
end

--- "Pick up the new bag" for a target that holds it: one verified synchronous pickup inside the player's press and
--- nothing else. The player sets it down on any slot or item outside the target with the game's own click/A (a
--- native swap); Baggler only observes. Never ClearCursor, never a second move.
function View:StartManualBagMove(rec, target, expected)
  local phase, source, sc = "hand-preflight"
  local function stop(reason)
    placementDiagnostic(phase, reason, source, nil, sc, nil)
    CB:Print("couldn't pick up the new bag: " .. phase .. " / " .. reason .. ". Your cursor was left untouched.")
  end
  if InCombatLockdown() then return stop("combat") end
  if (SpellIsTargeting and SpellIsTargeting()) or GetCursorInfo() or (CursorHasItem and CursorHasItem()) then return stop("cursor-or-spell-targeting") end
  if self.bagSwap or self.bagPlacement then return stop("pending-transaction") end
  if not rec or rec.equipLoc ~= "INVTYPE_BAG" or type(rec.itemID) ~= "number" or type(rec.slot) ~= "number"
      or type(target) ~= "number" or target < 1 or target > (NUM_BAG_SLOTS or 4) or rec.bag ~= target or not expected then
    return stop("invalid-source-or-target")
  end
  source = { bag = rec.bag, slot = rec.slot, itemID = rec.itemID, link = rec.link, count = rec.count or 1,
    name = rec.name or itemName(rec.link) }
  local reason = placementMismatch(source, source.bag, source.slot)
  if reason then return stop("source-" .. reason) end
  sc = placementContainer(target)
  if not placementUnchanged(sc) then return stop("target-container-changed-or-locked") end
  if sc.itemID ~= expected.itemID or sc.link ~= expected.link or sc.capacity ~= expected.capacity
      or expected.itemID == source.itemID then return stop("chosen-target-changed-or-same-id") end
  local priorOutside = {}
  for _, c in ipairs(sameItemCoords(source, false, target)) do priorOutside[c.bag .. ":" .. c.slot] = true end
  self.bagReplacement = nil
  phase = "hand-pickup"
  local ok = pcall(Container.PickupContainerItem, source.bag, source.slot)
  if not ok then return stop("native-call-error") end
  if not placementCursor(source) then return stop("source-cursor-mismatch") end
  if Container.GetContainerItemInfo(source.bag, source.slot) then return stop("origin-occupied") end
  placementDiagnostic(phase, "verified", source, nil, sc, nil)
  local intent = { source = { bag = source.bag, slot = source.slot, itemID = source.itemID, link = source.link,
      count = source.count, name = source.name, equipLoc = "INVTYPE_BAG" },
    origin = { bag = source.bag, slot = source.slot }, target = target,
    expected = { itemID = expected.itemID, link = expected.link, capacity = expected.capacity },
    priorOutside = priorOutside, priorInside = sameItemCoords(source, true, target),
    manual = true, tries = 0, status = "holding" }
  self.bagReplacement = intent
  self:ObserveBagReplacement(intent, true)
  CB:Fire("DIRTY")
end

--- First verified empty slot in the Backpack or a carried general-purpose bag other than `excludeBag`.
function View:FindStagingSlot(excludeBag)
  for b = 0, (NUM_BAG_SLOTS or 4) do
    if b ~= excludeBag then
      local free, family = Container.GetContainerNumFreeSlots(b)
      if free and free > 0 and family == 0 then
        for s = 1, (Container.GetContainerNumSlots(b) or 0) do
          if not Container.GetContainerItemInfo(b, s) then return b, s end
        end
      end
    end
  end
end

--- Step one of replacing a bag that holds the new bag: moves that single bag (no contents, nothing else) to a free
--- general slot outside the target. Runs inside the player's click; no timers, no retries, never ClearCursor.
--- The replace itself is a separate, later choice once the game has settled the move.
function View:StageBagOut(rec, bag, expected, chosenBag, chosenSlot)
  local phase, owned = "stage-preflight", false
  local source, dest, sc, dc
  local function stop(reason)
    if owned then self.bagPlacement = nil end
    self.bagReplacement = nil
    placementDiagnostic(phase, reason, source, dest, sc, dc)
    CB:Print("couldn't confirm preparation: " .. phase .. " / " .. reason
      .. ". Cursor left untouched; check both slots and place any held bag yourself. No further move was attempted.")
  end
  if InCombatLockdown() then return stop("combat") end
  if (SpellIsTargeting and SpellIsTargeting()) or GetCursorInfo() or (CursorHasItem and CursorHasItem()) then return stop("cursor-or-spell-targeting") end
  if self.bagSwap or self.bagPlacement then return stop("pending-transaction") end
  if not rec or rec.equipLoc ~= "INVTYPE_BAG" or type(rec.itemID) ~= "number" or type(rec.slot) ~= "number"
      or rec.slot < 1 or rec.slot % 1 ~= 0 or type(bag) ~= "number" or bag < 1 or bag > (NUM_BAG_SLOTS or 4)
      or rec.bag ~= bag then return stop("invalid-source-or-target") end
  source = { bag = rec.bag, slot = rec.slot, itemID = rec.itemID, link = rec.link, count = rec.count or 1, name = rec.name }
  local reason = placementMismatch(source, source.bag, source.slot)
  if reason then return stop("source-" .. reason) end
  local db, ds = chosenBag, chosenSlot
  if db == nil then db, ds = self:FindStagingSlot(bag) end
  if db == nil then return stop("no-compatible-free-slot-outside-target") end
  if db == bag or db < 0 or db > (NUM_BAG_SLOTS or 4) then return stop("invalid-destination") end
  sc, dc = placementContainer(bag), placementContainer(db)
  dest = { bag = db, slot = ds }
  if type(ds) ~= "number" or ds < 1 or ds % 1 ~= 0 or ds > dc.capacity or dc.family ~= 0 then return stop("destination-not-compatible") end
  if Container.GetContainerItemInfo(db, ds) then return stop("destination-occupied") end
  reason = placementCondition(self, sc, dc)
  if reason then return stop(reason) end
  if expected and (sc.itemID ~= expected.itemID or sc.link ~= expected.link or sc.capacity ~= expected.capacity
      or expected.itemID == source.itemID) then return stop("chosen-target-changed-or-same-id") end
  self.bagReplacement = nil
  self.bagPlacement, owned = true, true
  placementDiagnostic(phase, "verified", source, dest, sc, dc)
  phase = "stage-source-pickup"
  local ok = pcall(Container.PickupContainerItem, source.bag, source.slot)
  if not ok then return stop("native-call-error") end
  reason = placementCondition(self, sc, dc)
  if reason then return stop(reason) end
  if not placementCursor(source) then return stop("source-cursor-mismatch") end
  if Container.GetContainerItemInfo(source.bag, source.slot) then return stop("origin-occupied") end
  if Container.GetContainerItemInfo(db, ds) then return stop("destination-occupied") end
  placementDiagnostic(phase, "verified", source, dest, sc, dc)
  phase = "stage-destination-drop"
  ok = pcall(Container.PickupContainerItem, db, ds)
  self.bagPlacement = nil
  if not ok then return stop("native-call-error") end
  reason = placementCondition(self, sc, dc)
  if reason then return stop(reason) end
  if GetCursorInfo() or (CursorHasItem and CursorHasItem()) then return stop("cursor-not-empty") end
  reason = Container.GetContainerItemInfo(source.bag, source.slot) and "origin-occupied" or placementMismatch(source, db, ds)
  placementDiagnostic(phase, reason or "verified", source, dest, sc, dc)
  if expected then
    self.bagReplacement = replacementIntent(source, bag, expected, dest, sc, dc)
    self:ObserveBagReplacement(self.bagReplacement, true)
  end
  if reason then
    CB:Print("couldn't confirm final placement: " .. phase .. " / " .. reason .. ". Awaiting observation only; check your cursor and both slots yourself.")
  elseif not expected then
    CB:Print("Preparation verified. Continue replacing Bag " .. bag .. " from the item or window menu (Replace again is a separate press).")
  else
    self:BagReplacementPendingNote()
  end
  CB:Fire("DIRTY")
end

-- PutItemInBag is the native bag-slot drop operation (it handles bag contents).
-- This is a two-sided identity check, not just an item-ID lookup: a menu may stay
-- open through a bag refresh. Revalidate source, destination and capacity before
-- lifting anything. Afterward, recover only a known bag into its verified empty
-- origin outside the replaced container. Unknown cursor contents stay untouched
-- for the player; never ClearCursor, blindly retry, or relocate contained items.
function View:EquipBagTo(rec, bag, expected)
  -- Every refusal is journalled (kept in the saved settings even with debug off) as well as printed, so a
  -- "nothing happened" report can be traced to the exact gate: /baggler journal.
  local function stop(gate, text)
    CB:Journal("bag", ("gate %d refused: %s | src=%s/%s id=%s equipLoc=%s target=%s"):format(gate, text,
      tostring(rec and rec.bag), tostring(rec and rec.slot), tostring(rec and rec.itemID), tostring(rec and rec.equipLoc), tostring(bag)))
    CB:Print(text)
  end
  CB:Journal("bag", ("EquipBagTo start: src=%s/%s id=%s link=%s target bag=%s expected=%s/%s"):format(
    tostring(rec and rec.bag), tostring(rec and rec.slot), tostring(rec and rec.itemID), tostring(rec and rec.link),
    tostring(bag), tostring(expected and expected.itemID), tostring(expected and expected.capacity)))
  if InCombatLockdown() then return stop(1, "can't swap bags in combat.") end
  if SpellIsTargeting and SpellIsTargeting() then return stop(2, "finish or cancel spell targeting first.") end
  if GetCursorInfo and GetCursorInfo() then return stop(3, "put away the item or spell on your cursor first.") end
  if CursorHasItem and CursorHasItem() then return stop(4, "put away the item on your cursor first.") end
  if not rec or rec.empty or rec.equipLoc ~= "INVTYPE_BAG" then return stop(5, "select a bag first.") end
  if type(rec.itemID) ~= "number" or rec.itemID <= 0 or type(rec.slot) ~= "number" or rec.slot < 1 or rec.slot % 1 ~= 0 then
    return stop(6, "that bag's item data is unavailable; select it again.")
  end
  if type(bag) ~= "number" or bag % 1 ~= 0 or bag < 1 or bag > (NUM_BAG_SLOTS or 4) then
    return stop(7, "that is not a wearable bag slot.")
  end
  if type(rec.bag) ~= "number" or rec.bag % 1 ~= 0 or rec.bag < 0 or rec.bag > (NUM_BAG_SLOTS or 4) or rec.bag == bag then
    return stop(8, "the new bag is stored inside the bag you are replacing. Choose that bag in Equip bag / Replace bag and confirm \"Prepare replacement\" first, or move it to the backpack or another carried bag.")
  end
  if not (Container.ContainerIDToInventoryID and Container.GetContainerItemInfo and PutItemInBag and GetCursorInfo) then
    return stop(9, "this client has no safe bag equip API.")
  end
  local invSlot = Container.ContainerIDToInventoryID(bag)
  if not invSlot then return stop(10, "that bag slot is unavailable.") end
  CB:Journal("bag", ("inventory id for bag %d = %s (source bag %d inv = %s)"):format(bag, tostring(invSlot), rec.bag,
    tostring(rec.bag > 0 and Container.ContainerIDToInventoryID(rec.bag) or "backpack")))
  local info = Container.GetContainerItemInfo(rec.bag, rec.slot)
  -- Parenthesized getter calls supply one value to tostring even when native APIs return none.
  CB:Journal("bag", ("source info: id=%s link=%s locked=%s | equipped target: id=%s locked=%s capacity=%s"):format(
    tostring(info and info.itemID), tostring(info and info.hyperlink), tostring(info and info.isLocked),
    tostring((GetInventoryItemID("player", invSlot))), tostring(IsInventoryItemLocked and IsInventoryItemLocked(invSlot)),
    tostring((Container.GetContainerNumSlots(bag)))))
  if not info or info.itemID ~= rec.itemID or (rec.link and info.hyperlink ~= rec.link)
      or (info.stackCount or 1) ~= (rec.count or 1) then
    return stop(11, "that bag changed or moved; select it again.")
  end
  local oldID = GetInventoryItemID("player", invSlot)
  if not expected or oldID ~= expected.itemID
      or (expected.link and GetInventoryItemLink("player", invSlot) ~= expected.link)
      or Container.GetContainerNumSlots(bag) ~= expected.capacity then
    return stop(12, "that equipped bag changed; open the slot chooser again.")
  end
  if info.isLocked or (IsInventoryItemLocked and IsInventoryItemLocked(invSlot)) then
    return stop(13, "that bag is locked; wait and try again.")
  end
  if oldID == rec.itemID then
    return stop(14, "that slot already contains the same bag type; identical bag instances cannot be safely distinguished. Choose another slot.")
  end
  if self.bagSwap or self.bagPlacement then return stop(15, "the previous bag transaction is still finishing; wait a moment.") end
  -- Copy only scalar transaction data: inventory/menu refreshes recycle records.
  rec = { bag = rec.bag, slot = rec.slot, itemID = rec.itemID,
    link = info.hyperlink, name = rec.name, count = info.stackCount or 1 }
  local sc, tc = placementContainer(rec.bag), placementContainer(bag)
  if not placementUnchanged(sc) or not placementUnchanged(tc) then
    return stop(16, "a container is locked or changed; select it again.")
  end
  local sourceInv = sc.inv
  local swap = { rec = rec, bag = bag, invSlot = invSlot, oldID = oldID,
    oldLink = GetInventoryItemLink("player", invSlot), oldCapacity = expected.capacity,
    sourceInv = sourceInv, sourceID = sourceInv and GetInventoryItemID("player", sourceInv),
    sourceLink = sourceInv and GetInventoryItemLink("player", sourceInv),
    sourceCapacity = Container.GetContainerNumSlots(rec.bag), tries = 0, synchronous = true }
  local ok = pcall(Container.PickupContainerItem, rec.bag, rec.slot)
  local cursorType, cursorID, cursorLink = GetCursorInfo()
  if not ok or cursorType ~= "item" or cursorID ~= rec.itemID
      or (rec.link and cursorLink ~= rec.link) then
    CB:Journal("bag", ("gate 17 pickup refused: pcall=%s cursor=%s/%s/%s wanted id=%s link=%s"):format(tostring(ok),
      tostring(cursorType), tostring(cursorID), tostring(cursorLink), tostring(rec.itemID), tostring(rec.link)))
    CB:Warn("bag", ("pickup of %s from %s/%s left cursor=%s/%s"):format(tostring(rec.itemID), tostring(rec.bag), tostring(rec.slot), tostring(cursorType), tostring(cursorID)))
    CB:Print("couldn't pick up that bag; no equip attempted. Check your cursor before retrying.")
    return
  end
  local _, _, pickupLink = GetCursorInfo()
  swap.pickupLink = pickupLink
  self.bagSwap = swap
  -- Do not lift the old bag first: only the engine may transfer contained items. This runs inside the click that
  -- chose the row (a real hardware event); nothing here clicks a secure button on the player's behalf.
  -- A true/nil native return is not a server acceptance receipt. Blizzard's
  -- bag button only tests return truthiness to decide whether to toggle its bag.
  -- Each native move needs fresh provenance. A changed container, occupied
  -- origin or competing operation makes even synchronous recovery unsafe.
  if InCombatLockdown() or (SpellIsTargeting and SpellIsTargeting())
      or self.bagSwap ~= swap or self.bagPlacement
      or not placementUnchanged(sc) or not placementUnchanged(tc)
      or Container.GetContainerItemInfo(rec.bag, rec.slot)
      or not placementCursor(rec) then
    CB:Journal("bag", "gate 18: conditions changed after pickup; PutItemInBag not called")
    self:BagSwapFinish(swap, "unknown", "conditions changed; cursor left untouched")
    return
  end
  CB:Journal("bag", ("cursor holds %s/%s; calling PutItemInBag(%s)"):format(tostring(cursorType), tostring(cursorID), tostring(invSlot)))
  local called, handled = pcall(PutItemInBag, invSlot)
  local aType, aID = GetCursorInfo()
  CB:Journal("bag", ("PutItemInBag(%s) pcall=%s returned=%s | cursor after=%s/%s (unchanged cursor = the game did not take it; a server answer may still be pending) | target now=%s"):format(
    tostring(invSlot), tostring(called), tostring(handled), tostring(aType), tostring(aID), tostring((GetInventoryItemID("player", invSlot)))))
  CB:Info("bag", ("PutItemInBag(%s) called=%s returned=%s cursor=%s"):format(tostring(invSlot), tostring(called), tostring(handled), tostring((GetCursorInfo()))))
  if not called or handled == false then
    -- Native false/error is not a server verdict. Attempt only a strictly guarded
    -- synchronous return; an occupied/locked origin or changed cursor stays untouched.
    self:BagSwapFinish(swap, "refused", called and "the game declined the drop" or tostring(handled))
    return
  end
  -- The inventory may update later. Observe it without assuming a particular server timing.
  self:BagSwapSettle(swap)
end

local SWAP_STEP, SWAP_TRIES = 0.2, 15
-- A source container may itself have been replaced during the server round trip.
local function swapSourceUnchanged(swap)
  return Container.GetContainerNumSlots(swap.rec.bag) == swap.sourceCapacity
    and (not swap.sourceInv or
      (GetInventoryItemID("player", swap.sourceInv) == swap.sourceID
        and GetInventoryItemLink("player", swap.sourceInv) == swap.sourceLink))
end

-- Only the original hardware callback may return a known cursor to a verified
-- empty, unlocked origin. Timers cannot prove cursor instance ownership (same-ID
-- user items exist); they NEVER perform item operations, even outside combat.
local function returnSwapCursor(swap, itemID, link)
  if not swap.synchronous or InCombatLockdown() or not itemID then return end
  local rec = swap.rec
  local cursorType, cursorID, cursorLink = GetCursorInfo()
  if cursorType ~= "item" or cursorID ~= itemID or cursorLink ~= link then return end
  if rec.bag == swap.bag or not swapSourceUnchanged(swap)
      or Container.GetContainerItemInfo(rec.bag, rec.slot)
      or (IsInventoryItemLocked and (IsInventoryItemLocked(swap.invSlot)
        or (swap.sourceInv and IsInventoryItemLocked(swap.sourceInv)))) then return end
  pcall(Container.PickupContainerItem, rec.bag, rec.slot)
end

--- Observes the outcome; global UI errors cannot identify this transaction.
function View:BagSwapSettle(swap)
  if self.bagSwap ~= swap then return end
  local rec = swap.rec
  local targetID = GetInventoryItemID("player", swap.invSlot)
  local targetLink = GetInventoryItemLink("player", swap.invSlot)
  local origin = Container.GetContainerItemInfo(rec.bag, rec.slot)
  local worn = swapSourceUnchanged(swap) and targetID == rec.itemID
    and (not rec.link or targetLink == rec.link) and not origin
  if worn then
    returnSwapCursor(swap, swap.oldID, swap.oldLink)
    return self:BagSwapFinish(swap, GetCursorInfo() and "held" or "done")
  end
  swap.tries = swap.tries + 1
  if swap.tries == 1 or swap.tries > SWAP_TRIES then
    CB:Journal("bag", ("settle try %d: target=%s want=%s origin still=%s sourceUnchanged=%s"):format(swap.tries,
      tostring(targetID), tostring(rec.itemID), tostring(origin and origin.itemID), tostring(swapSourceUnchanged(swap))))
  end
  if swap.tries > SWAP_TRIES or not (C_Timer and C_Timer.After) then
    return self:BagSwapFinish(swap, "unknown")
  end
  swap.synchronous = false
  C_Timer.After(SWAP_STEP, function() self:BagSwapSettle(swap) end)
end

--- Reports observed results without claiming a timeout or global error is a refusal.
function View:BagSwapFinish(swap, result, detail)
  if self.bagSwap ~= swap then return end
  self.bagSwap = nil
  local rec = swap.rec
  CB:Journal("bag", ("finish: %s %s | target=%s"):format(tostring(result), tostring(detail or ""), tostring((GetInventoryItemID("player", swap.invSlot)))))
  if result == "done" or result == "held" then
    local now = Container.GetContainerNumSlots(swap.bag)
    CB:Print(("bag %d now holds %s (%s slots, was %s).%s"):format(swap.bag,
      rec.name or "the new bag", tostring(now or "?"), tostring(swap.oldCapacity or "?"),
      result == "held" and " Check your cursor and place any held item yourself; it was left untouched." or ""))
  else
    if result == "refused" then
      -- A failed native call may still have changed state; restore only while
      -- both original equipment and cursor signatures remain unchanged.
      if GetInventoryItemID("player", swap.invSlot) == swap.oldID
          and GetInventoryItemLink("player", swap.invSlot) == swap.oldLink then
        returnSwapCursor(swap, rec.itemID, swap.pickupLink)
      end
    end
    CB:Warn("bag", ("swap %s: %s; cursor=%s"):format(result, tostring(detail), tostring((GetCursorInfo()))))
    CB:Print((result == "refused" and "the native bag drop was refused" or "couldn't confirm that bag swap")
      .. (detail and (" (" .. tostring(detail) .. ")") or "")
      .. ". Check the equipped bag and your cursor before retrying; no items were deleted."
      .. (GetCursorInfo() and " Place any held item yourself in a free general bag slot." or ""))
  end
  CB:Fire("DIRTY")
end

--- Equips an item no matter what else is open (a vendor, bank or the auction house would otherwise
--- turn "use" into sell / deposit / list). Rings and trinkets with both slots full ask which to replace.
function View:Equip(rec, anchor)
  if not rec or rec.empty then return end
  if InCombatLockdown() then CB:Print("can't swap equipment in combat."); return end
  if rec.equipLoc == "INVTYPE_BAG" then
    CB.Menu:Open(anchor or self.frame, "Equip bag / Replace bag", self:BagEquipEntries(rec))
    return
  end
  if self:NeedsSlotChoice(rec) then
    local list = {}
    for _, c in ipairs(EQUIP_CHOICES[rec.equipLoc]) do
      local link = GetInventoryItemLink and GetInventoryItemLink("player", c[1])
      local name = link and link:match("%[(.-)%]") or c[2]
      list[#list + 1] = { text = c[2] .. ": replace " .. name, func = function() self:EquipTo(rec, c[1]) end }
    end
    CB.Menu:Open(anchor or self.frame, "Replace which?", list)
    return
  end
  if CursorHasItem() then ClearCursor() end
  Container.PickupContainerItem(rec.bag, rec.slot)
  if not CursorHasItem() then return end
  if AutoEquipCursorItem then AutoEquipCursorItem() end
  if CursorHasItem() then Container.PickupContainerItem(rec.bag, rec.slot) end   -- could not equip: put it back
end

--- Equip into a chosen slot (the item that was there goes back to where this one was).
function View:EquipTo(rec, invSlot)
  if rec and rec.equipLoc == "INVTYPE_BAG" then return self:Equip(rec) end
  if InCombatLockdown() then CB:Print("can't swap equipment in combat."); return end
  if CursorHasItem() then ClearCursor() end
  Container.PickupContainerItem(rec.bag, rec.slot)
  if not CursorHasItem() then return end
  PickupInventoryItem(invSlot)
  if CursorHasItem() then Container.PickupContainerItem(rec.bag, rec.slot) end   -- put the swapped-out item back
end

--- Destroy an item, behind a confirmation of our own (the same menu as everything else, so mouse and controller work
--- alike). The game's own delete dialog is not used: showing a game dialog from add-on code taints the dialog and the
--- controller bindings the game sets up for it, and the game then blocks its own call when the dialog closes (the
--- "interface action failed" error, every time). Rare and better items ask a second time.
--- `anchor` is where the confirmation opens (the item's tile); `rec` is re-checked at the last moment.
function View:Destroy(rec, anchor)
  local W = self
  if InCombatLockdown() then CB:Print("can't destroy items in combat."); return end
  if not rec or rec.empty then return end
  anchor = anchor or (W.selEntry and W.selEntry.btn) or W.frame
  local rare = (rec.quality or 0) >= 3
  local function destroyNow()
    if InCombatLockdown() then CB:Print("can't destroy items in combat."); return end
    local ok, info = pcall(Container.GetContainerItemInfo, rec.bag, rec.slot)
    if not (ok and info and info.itemID == rec.itemID) then CB:Print("that item is no longer there."); return end
    if CursorHasItem() then ClearCursor() end
    Container.PickupContainerItem(rec.bag, rec.slot)
    if not CursorHasItem() then return end
    DeleteCursorItem()
    if CursorHasItem() then ClearCursor() end            -- (the game refused: nothing is left hanging on the cursor)
    CB:Fire("DIRTY")
  end
  local function ask(title, yes)
    CB.Menu:Open(anchor, title, {
      { text = yes, color = CB.COLOR.danger, func = function()
          if rare and title ~= "Really destroy it?" then
            C_Timer.After(0, function() ask("Really destroy it?", "Yes, destroy it for good") end)
          else
            destroyNow()
          end
        end },
      { text = "Cancel", func = function() end },
    })
  end
  ask("Destroy " .. (rec.name or "this item") .. "?", rare and "Continue..." or "Destroy")
end

function View:ToggleJunk(rec)
  if not rec or rec.empty then return end
  CB.db.junk[rec.itemID] = (not CB.db.junk[rec.itemID]) or nil
  CB:Fire("DIRTY")
end

View.EQUIP_CHOICES, View.isEquippable = EQUIP_CHOICES, isEquippable
