-- Real shipping Bank.lua lifecycle in the offline harness, NOT an in-game test.
local CB, event = ...
local B, N, P = CB.Bank, CB.NativeWindows, CB.Pad
assert(B and CB.defaults.replaceBank, 'personal/account bank module and default must be enabled')
local errors = CB.errorCount or 0
BankFrame:Show()
event('BANKFRAME_OPENED')
FLUSH()
assert(B.active and B.window:IsOpen(), 'bank visit must open the real custom Bank window')
assert(CB.UI:IsConcealed(BankFrame) and BankFrame:IsShown(), 'custom bank must conceal, not hide, the native bank')
assert(N:Context() == nil, 'concealed native bank must not supply a competing item context')
assert(not N:Closing(), 'concealed bank is not a closed native visit')
for _, entry in ipairs(P:GameWindowList()) do
  assert(entry[1] ~= BankFrame, 'concealed bank must not enter native controller switch list')
end
P.seenGame[BankFrame] = GetTime() - 1
P:AutoHoldCheck()
assert(P.holdGame ~= BankFrame and not P.handedOff, 'native bank must not steal custom bank controller focus')
assert(P:Top() == B.window.ctx, 'bank must own the custom context')
P:SwitchWindow()
assert(P:Top() == CB.Window.ctx, 'Start must switch custom bank to bags')
P:SwitchWindow()
assert(P:Top() == B.window.ctx, 'Start must switch bags back to custom bank')
print('PASS restored bank lifecycle and custom controller switching')
assert(loadfile('addons/Baggler/Tests/bank_slots_test.lua'))(CB)
local used, oldUse = nil, C_Container.UseContainerItem
C_Container.UseContainerItem = function(...) used = { ... } end
B:SetViewType(Enum.BankType.Account)
assert(N:BankType() == Enum.BankType.Account, 'custom account tab must override the concealed native character tab')
CB.Window:UseItem({ bag = 0, slot = 1, itemID = 123, count = 1 })
assert(used and used[4] == Enum.BankType.Account, 'bag deposit must target the custom account bank')
assert(not CB.Window:SecureUseRec({ bag = 0, slot = 1 }), 'custom bank must not arm an equip/use macro')
C_Container.UseContainerItem = oldUse
local oldScan, oldTabs = CB.Inventory.Scan, C_Bank.FetchPurchasedBankTabData
C_Bank.FetchPurchasedBankTabData = function(kind)
  return { { ID = kind == Enum.BankType.Account and 13 or 6 } }
end
CB.Inventory.Scan = function(_, ids)
  return ids and ids[1] == 13 and { { itemID = 777, count = 9 } } or {}
end
CB.Extras:Snapshot(true)
assert(CB.db.account.bank[777] == 9, 'snapshot must use custom bank selection, not concealed native bank')
CB.Inventory.Scan, C_Bank.FetchPurchasedBankTabData = oldScan, oldTabs
B:SetViewType(nil)
assert(B:ActiveBankType() == Enum.BankType.Character)
print('PASS restored account/character bank deposit and snapshot selection')
BankFrame:Hide()
event('BANKFRAME_CLOSED')
FLUSH()
assert(not B.active and not B.window:IsOpen(), 'bank close must end custom visit')
assert(not CB.UI:IsConcealed(BankFrame), 'bank close must restore native frame ownership')
assert(not N.endedAt, 'custom bank close must be owned by Bank.lua, not duplicate native closing state')
assert(not CB.Window:IsOpen(), 'auto-opened bags must leave with bank visit')
assert((CB.errorCount or 0) == errors, 'custom bank lifecycle logged Lua errors')
print('PASS restored bank closes and releases the native frame')

-- Exercise delayed event ordering rather than making Begin immediate as the
-- default harness timer does. Only API/time boundaries are simulated here.
local oldKinds, oldDefer = Enum.PlayerInteractionType, DEFER
Enum.PlayerInteractionType = { Banker = 1, CharacterBanker = 2, AccountBanker = 3 }
DEFER = true
BankFrame:Show()
event('PLAYER_INTERACTION_MANAGER_FRAME_SHOW', 3)
event('BANKFRAME_OPENED')
assert(CB.UI:IsConcealed(BankFrame) and not B.active, 'bank must pre-conceal before delayed Begin')
assert(not N:Context() and not N:Closing(), 'pending custom bank must not become a native context/close')
for _, entry in ipairs(P:GameWindowList()) do assert(entry[1] ~= BankFrame, 'pending bank must not steal focus') end
BankFrame:Hide()
event('BANKFRAME_CLOSED')
FLUSH()
assert(not B.active and not B.window:IsOpen() and not CB.UI:IsConcealed(BankFrame), 'cancelled pending visit must not resurrect or stay concealed')
BankFrame:Show()
event('PLAYER_INTERACTION_MANAGER_FRAME_SHOW', 3)
event('BANKFRAME_OPENED')
FLUSH()
assert(B.active and B:IsWarband(), 'account-banker interaction must choose the custom account bank')
event('BANKFRAME_OPENED'); FLUSH()
assert(not N.active.BankFrame, 'duplicate opened event must not re-register a custom visit as native')
local oldTime = GetTime
GetTime = function() return B.shownAt + 1 end
BankFrame:Hide()
B.watcher:GetScript('OnUpdate')()
assert(B.active, 'one hidden poll must not close the bank')
B.watcher:GetScript('OnUpdate')()
assert(not B.active and not B.window:IsOpen(), 'two hidden polls must end a visit without CLOSED events')
GetTime = oldTime
FLUSH()
assert(not CB.UI:IsConcealed(BankFrame), 'watcher close must release native bank ownership')
assert(not N:Closing(), 'custom watcher close must not be rediscovered as a separate native close')
Enum.PlayerInteractionType, DEFER = oldKinds, oldDefer
assert((CB.errorCount or 0) == errors, 'interaction/polling bank lifecycle logged Lua errors')
print('PASS bank interaction ordering, pending cancellation and native-hide polling')
