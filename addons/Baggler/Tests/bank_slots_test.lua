-- Runs against the real shipping Bank.lua; API boundaries only are simulated.
local CB = ...
local B, W = CB.Bank, CB.Bank.window
local saved, bank = {}, {}
for k, v in pairs(C_Bank) do saved[k] = v; bank[k] = v end
local oldInfo, oldSlots, oldPickup = C_Container.GetContainerItemInfo, C_Container.GetContainerNumSlots, C_Container.PickupContainerItem
local oldCursor, oldCombat = CursorHasItem, InCombatLockdown
local oldEnums = { Enum.BagIndex.Characterbanktab, Enum.BagIndex.Accountbanktab }
Enum.BagIndex.Characterbanktab, Enum.BagIndex.Accountbanktab = -4, -5
local equipped, cursor, calls = false, false, {}
local cost = 100000
C_Bank.ShouldUsePlayerBagsInBank = function() return true end
C_Bank.CanUseBank = function() return true end
C_Bank.CanPurchaseBankTab = function() return true end
C_Bank.FetchNumPurchasedBankTabs = function() return 2 end
C_Bank.FetchPurchasedBankTabData = function(kind)
  return { { ID = 6, icon = 134400 }, { ID = 7, icon = 134400 } }
end
C_Bank.FetchNextPurchasableBankTabData = function() return { tabCost = cost, canAfford = true } end
C_Container.GetContainerNumSlots = function(id) return id == 6 and 28 or (id == 7 and equipped and 8 or 0) end
C_Container.GetContainerItemInfo = function(bag, slot)
  if (bag == -4 or bag == -5) and slot == 2 and equipped then return { iconFileID = 133622, itemName = 'Test bag' } end
end
C_Container.PickupContainerItem = function(bag, slot) calls[#calls + 1] = { bag, slot } end
CursorHasItem = function() return cursor end
B.viewType = nil; B.active = true
W:UpdateExtras()
assert(W.frame.bagSlots and #W.frame.bagSlots == 1, 'purchased empty bank bag must be an equipment placeholder, not a storage tab')
local slot = W.frame.bagSlots[1]
assert(slot:GetWidth() == 32 and slot:GetHeight() == 32, 'bank equipment must match readable carried 32px slots')
assert(slot.capacity and slot.capacity:GetText() == '', 'empty bank bag must not advertise capacity')
-- The shared fake texture has no texture-state model; capture this real renderer's writes.
local texture
slot.icon.SetTexture = function(_, value) texture = value end
slot.icon.GetTexture = function() return texture end
W:UpdateExtras()
assert(slot.bagSlotID == 2 and slot.bagID == 7 and slot:IsShown())
assert(slot.icon:GetTexture() ~= 134400, 'empty equipment slot must not show tab question-mark icon')
W.bagFilter = nil
slot:GetScript('OnClick')(slot)
assert(W.bagFilter == nil and #calls == 0, 'empty click must not select an empty storage pane')
cursor = true
slot:GetScript('OnReceiveDrag')(slot)
assert(calls[1][1] == -4 and calls[1][2] == 2, 'equip uses Camelot bank bag container/slot, not inventory bag IDs')
cursor = false; equipped = true; W:UpdateExtras()
assert(slot.icon:GetTexture() == 133622, 'equipped bank bag icon comes from its item, not tab metadata')
assert(slot.capacity:GetText() == '8', 'equipped bank bag must show actual capacity')
assert(W.footerH >= 68, 'bank equipment, purchase cost and fullness need separate rows')
slot:GetScript('OnClick')(slot)
assert(W.bagFilter == 7, 'equipped bank bag must select its storage')
local bagChrome
for i, entry in ipairs(W:ChromeList()) do if entry.widget == slot then bagChrome = i end end
W.chrome = bagChrome
calls = {}
W:OnPad('pickup')
assert(#calls == 1 and calls[1][1] == -4, 'controller pickup must remove an equipped bank bag')
B.viewType = Enum.BankType.Account
calls = {}; cursor = true
slot:GetScript('OnReceiveDrag')(slot)
assert(#calls == 1 and calls[1][1] == -5, 'account bag equip uses account equipment container')
B.viewType = nil; cursor = false; W.chrome = nil
local foundSlot, foundPurchase = false, false
for _, entry in ipairs(W:ChromeList()) do
  if entry.widget == slot then foundSlot = true end
  if entry.widget == W.frame.purchaseBtn then foundPurchase = true end
end
assert(foundSlot and foundPurchase, 'controller must reach equipped slot and the single purchase button')
assert(W.frame.moneyText:GetText():find(CB.UI:Money(cost), 1, true), 'actual next-slot cost must be visible')
cost = 250000; CB:Fire('FOOTER')
assert(W.frame.moneyText:GetText():find(CB.UI:Money(cost), 1, true), 'money events must retain refreshed next-slot price, not overwrite it with player gold')
W:UpdateExtras()
assert(W.frame.moneyText:GetText():find(CB.UI:Money(cost), 1, true), 'progressive price must refresh from API')
local source = os.getenv('BAGGLER_BANK_SOURCE')
if source then assert(loadfile('addons/Baggler/Tests/bank_native_contract_test.lua'))(CB, source) end
for _, entry in ipairs(W:BankEntries()) do assert(not entry.text:find('Rename tab', 1, true), 'bag equipment must not expose storage-tab rename settings') end
equipped = false
W:Refresh()
assert(W.bagFilter == nil, 'removing the selected bank bag must return to usable bank storage')
print('PASS bank empty equipment placeholder, bag equip/select, controller controls and progressive price')
C_Bank.CanUseBank = function() return false end
calls = {}; cursor = true
slot:GetScript('OnReceiveDrag')(slot)
assert(#calls == 0, 'read-only bank must not accept bag swaps')
assert(not B:CanBuyNextSlot(), 'read-only bank must not purchase')
C_Bank.CanUseBank = function() return true end
InCombatLockdown = function() return true end
calls = {}; slot:GetScript('OnReceiveDrag')(slot)
assert(#calls == 0 and not B:CanBuyNextSlot(), 'combat blocks bag swaps and purchase activation')
InCombatLockdown = function() return false end
C_Bank.CanPurchaseBankTab = function() return false end
assert(not B:CanBuyNextSlot(), 'native purchase permission must be honored')
C_Bank.CanPurchaseBankTab = function() return true end
C_Bank.FetchNextPurchasableBankTabData = function() return { tabCost = cost, canAfford = false } end
assert(not B:CanBuyNextSlot(), 'unaffordable next slot must not activate')
C_Bank.FetchNextPurchasableBankTabData = function() return nil end
W:UpdateExtras()
assert(not W.frame.purchaseBtn:IsShown(), 'max purchased must hide the single purchase control')
C_Bank.FetchNextPurchasableBankTabData = function() return { tabCost = cost, canAfford = true } end
C_Bank.FetchNumPurchasedBankTabs = function() return 0 end
B.viewType = Enum.BankType.Account
assert(not B:CanBuyNextSlot(), 'account zero-tab purchase must match native restriction')
B.viewType = nil; C_Bank.FetchNumPurchasedBankTabs = function() return 2 end
C_Bank.ShouldUsePlayerBagsInBank = function() return false end
W:UpdateExtras()
assert(not slot:IsShown(), 'non-bag bank must retain native purchased-storage-tab UI without equipment controls')
print('PASS bank use/purchase restrictions and non-bag storage-tab fallback')
for k in pairs(C_Bank) do C_Bank[k] = nil end
for k, v in pairs(saved) do C_Bank[k] = v end
C_Container.GetContainerItemInfo, C_Container.GetContainerNumSlots, C_Container.PickupContainerItem = oldInfo, oldSlots, oldPickup
CursorHasItem, InCombatLockdown = oldCursor, oldCombat
Enum.BagIndex.Characterbanktab, Enum.BagIndex.Accountbanktab = oldEnums[1], oldEnums[2]
B.viewType = nil; W.bagFilter = nil
