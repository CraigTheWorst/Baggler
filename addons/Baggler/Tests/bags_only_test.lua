-- Run from repository root: luajit addons/Baggler/Tests/bags_only_test.lua
-- Loads the shipping TOC, not the historical harness's hard-coded module list.
local root = 'addons/Baggler/'
local files = {}
for line in io.lines(root .. 'Baggler.toc') do
  if line:match('%.lua$') then files[#files + 1] = line end
end
local retired = { Vendor = true, VendorPad = true, GuildBank = true,
  GuildBankPages = true, Mail = true, Trade = true, Loot = true, Trainer = true }
for _, file in ipairs(files) do
  assert(not retired[file:gsub('%.lua$', '')], 'non-bag replacement still ships in TOC: ' .. file)
end
assert(table.concat(files, '\n'):find('\nBank.lua\n', 1, true), 'shipping TOC must restore personal/account Bank.lua')
print('PASS shipping TOC restores only the personal/account bank exception')

dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
local baselineContainer = {}
for key, fn in pairs(C_Container) do baselineContainer[key] = fn end
local CB = {}
-- Fail on any attempt to visually take over a native visit window, including
-- login, saved opt-ins, delayed callbacks, and context-menu actions below.
local nativeNames = { 'MerchantFrame', 'GuildBankFrame', 'MailFrame', 'SendMailFrame',
  'TradeFrame', 'LootFrame', 'ClassTrainerFrame', 'AuctionHouseFrame' }
for _, name in ipairs(nativeNames) do
  local f = rawget(_G, name) or CreateFrame('Frame', name, UIParent)
  f:Hide()
  for _, method in ipairs({ 'SetAlpha', 'SetScale', 'SetParent', 'SetScript', 'HookScript',
    'SetPoint', 'ClearAllPoints', 'SetSize', 'SetBackdrop', 'SetBackdropColor' }) do
    f[method] = function() error('Baggler modified native frame: ' .. name .. ':' .. method) end
  end
end
BagglerDB = { replaceVendor = true, replaceBank = false, bankOptInMigrated = true, replaceGuildBank = true, replaceMail = true,
  replaceTrade = true, replaceLoot = true, replaceTrainer = true }
for _, file in ipairs(files) do assert(loadfile(root .. file))('Baggler', CB) end
local function event(name, ...)
  CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...)
end
event('ADDON_LOADED', 'Baggler')
event('PLAYER_LOGIN')
FLUSH()
assert(CB.db.replaceBank == true, 'restore bank once even when bags-only forced the saved value false')
assert(loadfile(root .. 'Tests/bank_restore_test.lua'))(CB, event)
SlashCmdList.BAGGLER('bank off')
assert(not CB.db.replaceBank, 'bank opt-out must remain available')
CB:Fire('READY')
assert(not CB.db.replaceBank, 'bank restoration migration must not override a later opt-out')
event('ADDON_LOADED', 'Baggler')
assert(not CB.db.replaceBank, 'bank opt-out must survive saved-variable initialization on reload')
local function native(name)
  local f = rawget(_G, name) or CreateFrame('Frame', name, UIParent)
  f:Hide()
  return f
end
for _, name in ipairs({ 'MerchantFrame', 'BankFrame', 'GuildBankFrame', 'TradeFrame', 'MailFrame', 'SendMailFrame', 'AuctionHouseFrame' }) do native(name) end
local bank = native('BankFrame')
bank:Show()
event('BANKFRAME_OPENED')
assert(CB.Window:UseContext() == 'bank', 'native bank must remain an item deposit context')
assert(CB.Pad:QuickMoveOpen(), 'native bank must accept quick move')
print('PASS native bank bag-item context')
CB.Window:Open()
assert(CB.Pad:CanSwitch(), 'Start must offer native bank and custom bags')
CB.Pad:SwitchWindow()
assert(CB.Pad.holdGame == bank, 'Start must hand control to native bank')
CB.Pad:SwitchWindow()
CB.Pad:Reconcile('test return to bags')
assert(not CB.Pad.handedOff, 'native bank must not immediately steal control back after Start')
print('PASS native bank controller round trip')
CB.Menu:Close()
CB.Window.frame:GetScript('OnKeyDown')(CB.Window.frame, 'ESCAPE')
assert(CB.Window:IsOpen(), 'Escape beside a native bank must pass to the game, not close bags locally')
print('PASS Escape remains native during visits')
local rec = { bag = 0, slot = 1, itemID = 123, count = 3, quality = 1, sellPrice = 10 }
local used
C_Container.UseContainerItem = function(...) used = { ... } end
bank.GetActiveBankType = function() return Enum.BankType.Account end
CB.Window:UseItem(rec)
assert(used and used[4] == Enum.BankType.Account, 'deposit must use the native active bank type')
assert(CB.Window:SecureUseRec(rec) == nil, 'bank deposit must not become a plain equip/use macro')
print('PASS native bank deposit route')
local savedOpen, menuEntries = CB.Menu.Open
CB.Menu.Open = function(_, _, _, entries) menuEntries = entries end
CB.Window:ItemMenu({ rec = rec, btn = CB.Window.frame })
assert(menuEntries[1].text == 'Move to / from bank', 'bank item menu must describe a transfer, not Use/Equip')
CB.Menu.Open = savedOpen
print('PASS native bank item menu action')
bank:Hide()
local mail, send = native('MailFrame'), native('SendMailFrame')
mail:Show(); send:Show()
local picked, attached
C_Container.PickupContainerItem = function(bag, slot) picked = { bag, slot } end
ClickSendMailItemButton = function() attached = true end
assert(CB.Window:UseContext() == 'mail', 'native send-mail pane must be an attachment context')
CB.Window:UseItem(rec)
assert(picked and picked[1] == rec.bag and attached, 'bag item must attach to native outgoing letter')
send:Hide()
assert(CB.Window:UseContext() == nil, 'inbox alone must not attach items')
mail:Hide()
print('PASS native mail attachment route')
CB.Options:Create()
local bankToggle
for _, row in ipairs(CB.Options.specByTab.Behaviour.rows) do
  if row.key == 'replaceBank' then bankToggle = row end
end
assert(not bankToggle, 'core bank replacement must not expose an opt-out switch')
SlashCmdList.BAGGLER('bank on')
assert(CB.db.replaceBank, 'bank slash command must allow custom bank opt-in')
SlashCmdList.BAGGLER('bank off')
for _, spec in pairs(CB.Options.specByTab) do
  for _, row in ipairs(spec.rows or {}) do
    assert(not (row.key and row.key:match('^replace') and row.key ~= 'replaceDefault' and row.key ~= 'replaceBank'), 'retired replacement toggle remains: ' .. tostring(row.key))
  end
end
for _, name in ipairs({ 'vendor', 'guildbank', 'mail', 'trade', 'loot', 'trainer' }) do
  SlashCmdList.BAGGLER(name .. ' on')
  assert(not CB.db['replace' .. ({ vendor = 'Vendor', bank = 'Bank', guildbank = 'GuildBank', mail = 'Mail', trade = 'Trade', loot = 'Loot', trainer = 'Trainer' })[name]], 'retired replacement can be enabled: ' .. name)
end
print('PASS bank-only toggle exception; other skins cannot reactivate')
local auction = native('AuctionHouseFrame')
auction:Show()
C_Container.GetContainerItemInfo = function() return { itemID = rec.itemID } end
assert(CB.Window:SecureUseRec(rec) == rec, 'native AH must retain its secure native click route')
local route = CB.Window:AuctionRoute(rec.bag, rec.slot)
assert(route and CB.Pad:WriteMacro(rec.bag, rec.slot), 'native AH proxy must remain buildable')
assert(CB.Pad:UseButton():GetAttribute('macrotext'):find('/click ' .. route .. ' RightButton', 1, true), 'AH uses the native bag-button click, never a plain /use')
assert(CB.Window:ClickMode(CB.Window:GetButton(rec.bag, rec.slot)), 'mouse AH clicks must keep the native template')
auction:Hide()
print('PASS native AH secure routing retained')
local beforeErrors = CB.errorCount or 0
SlashCmdList.BAGGLER('vendor')
SlashCmdList.BAGGLER('guildbank info')
assert((CB.errorCount or 0) == beforeErrors, 'native diagnostic slash commands must not call removed modules')
print('PASS native diagnostic commands')
local helpLines, oldPrint = {}, CB.Print
CB.Print = function(_, text) helpLines[#helpLines + 1] = tostring(text) end
SlashCmdList.BAGGLER('help')
CB.Print = oldPrint
assert(not table.concat(helpLines, '\n'):find("use Baggler'", 1, true), 'help must not advertise retired window skins')
assert(table.concat(helpLines, '\n'):find('/baggler bank on|off', 1, true), 'help must advertise the custom bank toggle')
assert(table.concat(helpLines, '\n'):find('personal/account bank', 1, true), 'help must describe the bank exception')
print('PASS help describes bags and personal/account bank scope')
bank:Show()
local oldScan = CB.Inventory.Scan
CB.Inventory.Scan = function(_, ids)
  if ids and ids[1] == 6 then return { { itemID = 777, count = 4 } } end
  return {}
end
C_Bank.FetchPurchasedBankTabData = function() return { { ID = 6 } } end
CB.Extras:Snapshot(true)
assert(CB.db.account.bank and CB.db.account.bank[777] == 4, 'native bank must still record item snapshots')
CB.Inventory.Scan = oldScan
bank:Hide()
print('PASS native bank item snapshots')
-- The game may close bags without an explicit interacting-frame argument when
-- a native visit ends. That must not be mistaken for the player's bag key.
CB.Window:Close()
CB.Integrations.gameOpen = true
CB.Integrations.startedAt = GetTime() - 20
CB.Integrations.worldAt = GetTime() - 20
CB.Window.closedAt = GetTime() - 10
event('BANKFRAME_CLOSED')
assert(CB.NativeWindows.endedAt and GetTime() - CB.NativeWindows.endedAt < 0.1, 'native visit close needs lifecycle observation without a skin')
CloseAllBags()
FLUSH()
assert(not CB.Window:IsOpen(), 'game ending a native visit must not reopen closed custom bags')
ToggleAllBags()
FLUSH()
assert(CB.Window:IsOpen(), 'an explicit bag key must still open bags after a native visit')
print('PASS native visit close lifecycle')
CB.Window:Close()
bank:Show()
CB.Pad:AmbientCheck()
assert(CB.Pad.catchMap.PADFORWARD == 'switchWindow', 'Start must remain available when only a native item window is open')
CB.Pad:Dispatch('switchWindow')
assert(CB.Window:IsOpen(), 'Start from native bank must open custom bags')
bank:Hide()
print('PASS Start reaches bags from a native item window alone')
for _, visit in ipairs({
  { 'MerchantFrame', 'MERCHANT_SHOW', 'MERCHANT_CLOSED', 'merchant', false },
  { 'GuildBankFrame', 'GUILDBANKFRAME_OPENED', 'GUILDBANKFRAME_CLOSED', 'guildbank', true },
  { 'TradeFrame', 'TRADE_SHOW', 'TRADE_CLOSED', 'trade', true },
  { 'MailFrame', 'MAIL_SHOW', 'MAIL_CLOSED' },
  { 'LootFrame', 'LOOT_OPENED', 'LOOT_CLOSED' },
  { 'ClassTrainerFrame', 'TRAINER_SHOW', 'TRAINER_CLOSED' },
}) do
  local f = rawget(_G, visit[1])
  f:Show(); event(visit[2]); FLUSH()
  CB.Window:Open(); CB.Pad:Push(CB.Window.ctx)
  CB.Pad:SwitchWindow()
  assert(CB.Pad.holdGame == f, 'Start must reach ' .. visit[1])
  assert(CB.Pad.catchMap.PADFORWARD == 'switchWindow', 'Start return catcher missing for ' .. visit[1])
  CB.Pad:SwitchWindow()
  CB.Pad:Reconcile('native visit round trip')
  assert(not CB.Pad.handedOff and CB.Pad:Top() == CB.Window.ctx, 'bag focus not restored from ' .. visit[1])
  if visit[4] then
    assert(CB.Window:UseContext() == visit[4], 'wrong context for ' .. visit[1])
    assert(CB.Pad:QuickMoveOpen() == visit[5], 'quick-move state for ' .. visit[1])
    used = nil
    CB.Window:UseItem(rec)
    assert(used and used[1] == rec.bag and used[2] == rec.slot, 'item API route missing for ' .. visit[1])
    assert(CB.Window:SecureUseRec(rec) == nil, 'context must not equip item for ' .. visit[1])
    CB.Menu.Open = function(_, _, _, entries) menuEntries = entries end
    CB.Window:ItemMenu({ rec = rec, btn = CB.Window.frame })
    assert(menuEntries[1].text:find(CB.Window:UseLabel(rec), 1, true), 'item menu context label for ' .. visit[1])
    CB.Menu.Open = savedOpen
  end
  -- Building/using a bag item menu beside a native window must not style it.
  CB.Window:ItemMenu({ rec = rec, btn = CB.Window.frame })
  CB.Menu:Close()
  f:Hide(); event(visit[3]); FLUSH()
end
assert(not CB.Vendor and CB.Bank and not CB.GuildBank and not CB.Mail and not CB.Trade and not CB.Loot and not CB.Trainer,
  'retired visual module loaded')
print('PASS native visits and context menus never style native frames')
local hookUsed
CB.UseHookActive = function() return true end
CB.UseHook = function(item) hookUsed = item; return true end
assert(CB.Window:UseContext() == 'auction', 'CAuction use context retained')
CB.Window:UseItem(rec)
assert(hookUsed == rec, 'CAuction use hook retained')
CB.UseHookActive, CB.UseHook = nil, nil
print('PASS optional CAuction item hook retained')
CB.Options:Close()
CB.Window:Open()
for _, cmd in ipairs({ 'reset', 'about', 'pad', 'debug', 'vendor', 'guildbank info', 'help' }) do SlashCmdList.BAGGLER(cmd) end
if (CB.errorCount or 0) > 0 then
  for _, entry in ipairs(CB.db.log or {}) do print('LOG', type(entry) == 'table' and (entry.text or entry.message or entry.msg or entry[1]) or entry) end
end
for key, fn in pairs(baselineContainer) do C_Container[key] = fn end
assert(loadfile(root .. 'Tests/item_parity_test.lua'))(CB)
assert((CB.errorCount or 0) == 0, 'TOC boot or bag/native-window actions logged Lua errors')


for _, name in ipairs(nativeNames) do rawget(_G,name):Hide() end
CB.Pad:Reset()
CB.Window:Open()
CB.db.pad.mode = 'on'
CB.db.off.autohold = true
local r = {bag=0,slot=1,itemID=123,count=1}
C_Container.GetContainerItemInfo=function() return {itemID=123} end
CB.Window.chrome,CB.Window.sizing=false,false
CB.Window.selEntry={rec=r}
CB.Pad:Push(CB.Window.ctx)
MailFrame:Show(); SendMailFrame:Hide(); CB.Window.selEntry={rec=r}
CB.Pad:SyncDirectUse()

assert(CB.Pad.directArmed, 'setup direct use')
SendMailFrame:Show()
CB.Pad:SyncDirectUse() -- equivalent to selecting an item while native Send Mail is up
assert(not CB.Pad.directArmed, 'setup attachment dispatcher')
CB.Pad.bound=true
CB.Window.selEntry={rec=r}
SendMailFrame:Hide() -- native inbox tab, with bags still focused after Start return
CB.Window:SyncClickMode(0.2)
CB.Pad:Reconcile('watchdog after native mail tab change')
print('PROBE inbox context='..tostring(CB.Window:UseContext())..' directUse='..tostring(CB.Window.ctx.directUse())..' directArmed='..tostring(CB.Pad.directArmed))
assert(CB.Pad.directArmed, 'BUG: A still dispatches insecure UseItem instead of secure /use after switching Send Mail to inbox')

print('PASS secure controller use refreshes when Send Mail changes to Inbox')
print('ALL PASS bags + personal/account bank shipping TOC')
