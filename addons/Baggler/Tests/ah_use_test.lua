-- Run from repository root: timeout 90 luajit addons/Baggler/Tests/ah_use_test.lua
-- Regression: at the native auction house, controller A on an item the auction house refuses (live report: a gray
-- equippable "Elastic Wristguards") gave "Interface action failed because of an AddOn" and nothing was placed, while
-- other items went into the sell slot.
-- Real TOC / real WindowUse + Gamepad code. The client boundary is modelled after the pinned Forever source
-- (wow-ui-source-9dc84f0d, Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua):
--   l.1555  itemIsValidAuctionItem = itemLocation:IsValid() and C_AuctionHouse.IsSellItemValid(itemLocation, false)
--   l.1559  shouldAuctionReceiveEvent = AuctionHouseFrame:IsShown() and (IsListingAuctions() or itemIsValidAuctionItem)
--   l.1560-1562  -> AuctionHouseFrame:SetPostItem(itemLocation); return
--   l.1573-1611  otherwise (no bank/mail/trade ...) falls through to C_Container.UseContainerItem(bag, slot, ...)
-- Blizzard_AuctionHouseUI/Shared/Blizzard_AuctionHouseFrame.lua l.603-611: IsListingAuctions / SetPostItem, which
-- re-checks C_AuctionHouse.IsSellItemValid(itemLocation) (displayError defaults to true) and returns for a refused item.
-- Count addon OnClick registrations after simulated template creation, separately from callback identity.
-- Native API edges below are a control-flow model only: no WoW taint/protected-execution simulation.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end

local NORMAL, GRAY = 1001, 2002
local items = {
  [1] = { itemID = NORMAL, quality = 1, hyperlink = 'item:1001[Linen Cloth]' },
  [2] = { itemID = GRAY, quality = 0, hyperlink = 'item:2002[Elastic Wristguards]' },
}
local auctionable = { [NORMAL] = true, [GRAY] = false }
local log = {}
local function note(s) log[#log + 1] = s end

-- the auction house refuses the gray item (runtime answer; Baggler must ask, not guess from quality)
C_AuctionHouse = {
  IsSellItemValid = function(loc, displayError)
    local info = items[loc.slot]
    if displayError ~= false then note('IsSellItemValid(displayError)') end
    return info ~= nil and auctionable[info.itemID] == true
  end,
}
ItemLocation = {
  CreateFromBagAndSlot = function(_, bag, slot)
    return { bag = bag, slot = slot, IsValid = function() return items[slot] ~= nil end }
  end,
}

local listing = true            -- the sell tab is up
local ah = CreateFrame('Frame', 'AuctionHouseFrame', UIParent)
ah.ItemSellFrame = CreateFrame('Frame', nil, ah)
ah.CommoditiesSellFrame = CreateFrame('Frame', nil, ah); ah.CommoditiesSellFrame:Hide()
ah.WoWTokenSellFrame = CreateFrame('Frame', nil, ah); ah.WoWTokenSellFrame:Hide()
ah.SellTab = CreateFrame('Button', 'AuctionHouseFrameSellTab', ah)
ah:Hide()
function ah:IsListingAuctions() return listing end
local posted
function ah:SetPostItem(loc)
  note('SetPostItem')
  if not C_AuctionHouse.IsSellItemValid(loc) then return end   -- l.609: native error, nothing placed
  posted = items[loc.slot].itemID
  -- Commodity UI edge only; exact pinned native SetDisplayMode is replayed privately,
  -- not copied into this independently authored shipping harness.
  if posted == NORMAL then
    ah.ItemSellFrame:Hide()
    ah.CommoditiesSellFrame:Show()
    ah.CommoditiesSellFrame.itemLocation = loc
  end
end

-- the native item-button click (ContainerFrameItemButton_OnClick, right button, no merchant/bank/mail)
local function nativeItemClick(self, button)
  if button ~= 'RightButton' then return end
  local loc = ItemLocation:CreateFromBagAndSlot(self:GetBagID(), self:GetID())
  local valid = loc:IsValid() and C_AuctionHouse.IsSellItemValid(loc, false)
  if ah:IsShown() and (ah:IsListingAuctions() or valid) then ah:SetPostItem(loc); return end
  C_Container.UseContainerItem(self:GetBagID(), self:GetID())
end
local create = CreateFrame
function CreateFrame(kind, name, parent, template)
  local f = create(kind, name, parent, template)
  if template and template:find('ContainerFrameItemButtonTemplate') then
    f.__scripts.OnClick = nativeItemClick
    f.addonClickRegistrations = 0
    local setScript = f.SetScript
    function f:SetScript(script, fn)
      if script == 'OnClick' then self.addonClickRegistrations = self.addonClickRegistrations + 1 end
      return setScript(self, script, fn)
    end
  end
  return f
end

local Live = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', Live) end
end
local function event(name, ...) Live.eventFrame.__scripts.OnEvent(Live.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()

-- Unexpected item operations below are failures; this does not model engine security.
local protected = {}
C_Container.GetContainerItemInfo = function(bag, slot) if bag == 0 then return items[slot] end end
C_Container.UseContainerItem = function(bag, slot)
  protected[#protected + 1] = ('UseContainerItem(%s,%s)'):format(tostring(bag), tostring(slot))
end
C_Container.PickupContainerItem = function(bag, slot) protected[#protected + 1] = ('PickupContainerItem(%s,%s)'):format(bag, slot) end
EquipItemByName = function() protected[#protected + 1] = 'EquipItemByName' end
AutoEquipCursorItem = function() protected[#protected + 1] = 'AutoEquipCursorItem' end
ClickAuctionSellItemButton = function() protected[#protected + 1] = 'ClickAuctionSellItemButton' end

local W, Pad = Live.Window, Live.Pad
MerchantFrame:Hide(); if Live.Vendor then Live.Vendor.atMerchant = nil end
W:Open(); FLUSH()
ah:Show()
assert(W:UseContext() == 'blizzah', 'native auction house must be the use context, got ' .. tostring(W:UseContext()))

-- One controller A press as the client runs it: armed -> the secure use button's macro (each /click a real click on
-- the named button; /use is the game's own secure use); not armed -> Baggler' own "use" action (WindowPad.lua l.281-292).
local function pressA(slot)
  local rec = { bag = 0, slot = slot, itemID = items[slot].itemID, quality = items[slot].quality, equipLoc = 'INVTYPE_WRIST',
    name = items[slot].hyperlink:match('%[(.-)%]'), count = 1 }
  posted, log, protected, Live.message = nil, {}, {}, nil
  local armed = Pad:WriteMacro(0, slot)
  if armed then
    local text = Pad:UseButton():GetAttribute('macrotext')
    for line in text:gmatch('[^\n]+') do
      local target, button = line:match('^/click (%S+) ?(%S*)')
      if target then
        local f = assert(_G[target], 'macro clicks a missing button ' .. target)
        f:Click(button ~= '' and button or 'LeftButton')
      elseif line:match('^/use ') then
        protected[#protected + 1] = 'secure /use at the auction house (equips instead of listing)'
      end
    end
  else
    W:UseItem(rec)
  end
  return rec, armed
end
local printed
function Live:Print(text) printed = text; Live.message = text end

local passed = 0
local function check(name, fn) printed = nil; fn(); passed = passed + 1; print('PASS ah use: ' .. name) end

check('an auctionable item still goes into the sell slot through the native item click', function()
  local _, armed = pressA(1)
  assert(armed, 'A must stay armed on the secure route for an auctionable item')
  assert(posted == NORMAL, 'normal item must reach AuctionHouseFrame:SetPostItem')
  assert(#protected == 0, 'no protected call for a normal item: ' .. table.concat(protected, ', '))
end)

check('repeated controller priming never re-registers the inherited native click', function()
  local proxy = assert(W.auctionProxy)
  assert(proxy:GetScript('OnClick') == nativeItemClick, 'template callback identity must be preserved')
  assert(proxy.addonClickRegistrations == 0, 'native template OnClick was re-registered from addon code')
  for _ = 1, 3 do
    W.selEntry = { rec = { bag = 0, slot = 1, itemID = NORMAL, count = 1 } }
    Pad.handedOff = false
    Pad:Push(W.ctx)
    Pad:SyncDirectUse()
    assert(Pad.directArmed, 'shipping direct-use context must stay armed')
    local _, armed = pressA(1)
    assert(armed and posted == NORMAL and #protected == 0, 'native SetPostItem route must remain intact')
    assert(ah.CommoditiesSellFrame:IsShown() and ah.CommoditiesSellFrame.itemLocation.slot == 1,
      'commodity posting must retain the selected source slot')
    assert(W.auctionProxy == proxy and proxy.addonClickRegistrations == 0, 'priming must reuse template registration')
  end
  local mouse = assert(W:NewButton(0, 1))
  W:SyncNativeClick(mouse)
  assert(not mouse.cbCatch:IsShown(), 'ordinary AH mouse click must bypass the addon catcher')
  assert(mouse:GetScript('OnClick') == nativeItemClick and mouse.addonClickRegistrations == 0)
  posted = nil
  mouse:Click('RightButton')
  assert(posted == NORMAL and proxy.addonClickRegistrations == 0, 'mouse keeps the native posting route')
end)

check('sell tab: a refused (gray equippable) item makes no item operation and says why', function()
  listing = true
  local rec = pressA(2)
  assert(posted == nil, 'refused item must not be placed')
  assert(#protected == 0, 'refused item reached a protected call: ' .. table.concat(protected, ', '))
  for _, s in ipairs(log) do
    assert(s ~= 'SetPostItem', 'refused item must not run the native auction click through the proxy')
  end
  assert(printed and printed:lower():find("can't be auctioned", 1, true), 'missing clear message, got ' .. tostring(printed))
  assert(W:UseLabel(rec) == "Can't auction", 'A label must say it cannot be auctioned, got ' .. tostring(W:UseLabel(rec)))
end)

check('another tab: the refused item is never sent to the native UseContainerItem fall-through', function()
  listing = false
  pressA(2)
  assert(#protected == 0, 'refused item reached a protected call: ' .. table.concat(protected, ', '))
  assert(printed and printed:lower():find("can't be auctioned", 1, true), 'missing clear message')
  listing = true
end)

check('the auctionable item still works after the refused one (A re-armed)', function()
  local _, armed = pressA(1)
  assert(armed and posted == NORMAL and #protected == 0)
end)

print(('PASS ah use: %d cases'):format(passed))
