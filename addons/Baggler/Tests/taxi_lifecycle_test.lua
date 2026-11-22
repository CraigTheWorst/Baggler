-- Run from repository root: luajit addons/Baggler/Tests/taxi_lifecycle_test.lua
-- Real shipping modules with fake client events, native bag hooks and next-frame timers.
dofile('tests/harness/ca_stubs.lua')
local now, flying = 100, false
function GetTime() return now end
function UnitOnTaxi() return flying end
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
local CB = {}
BagglerDB = { replaceBank = false, bankOptInMigrated = true, personalBankRestored1 = true }
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
local function flush() FLUSH(); FLUSH() end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); flush()
now = 120
local W, I = CB.Window, CB.Integrations
local taxi = CreateFrame('Frame', 'TaxiFrame', UIParent)
taxi:Hide()
local function reset(open)
  taxi:Hide(); flying = false; now = now + 10
  CB.NativeWindows.active = {}; CB.NativeWindows.endedAt = nil
  I.gameOpen = true
  W:Close(); W.closedAt = now - 10
  CB.Pad:Reset(); CB.Pad.seenGame, CB.Pad.declinedGame = {}, {}
  if open then W:Open() end
end
local function begin()
  taxi:Show(); event('TAXIMAP_OPENED')
end
local function depart()
  -- Either native event order is possible: the map hides before queued bag
  -- cleanup settles. No interacting frame is supplied to CloseAllWindows' bags.
  taxi:Hide(); event('TAXIMAP_CLOSED'); flying = true
  event('PLAYER_CONTROL_LOST'); CloseAllBags(); flush()
end
reset(false); begin()
assert(not W:IsOpen(), 'closed bags must stay closed while flight map opens')
depart()
assert(not W:IsOpen(), 'taxi departure CloseAllBags must not reopen closed bags')
print('PASS closed bags stay closed at taxi departure')
reset(true); begin()
CloseAllBags(); flush()
assert(W:IsOpen(), 'taxi cleanup must not close bags that were already open')
depart()
assert(W:IsOpen(), 'open bags must remain open after taxi departure')
print('PASS open bags stay open through taxi cleanup')
for _, initial in ipairs({ false, true }) do
  reset(initial); begin()
  for i = 1, 3 do
    ToggleAllBags(); flush()
    local want
    if i % 2 == 0 then want = initial else want = not initial end
    assert(W:IsOpen() == want, 'manual bag key must work while flight map is open')
  end
  local latest = W:IsOpen()
  depart()
  assert(W:IsOpen() == latest, 'latest manual choice must win at departure')
  ToggleAllBags(); flush()
  assert(W:IsOpen() ~= latest, 'manual bag key must still work on the taxi')
end
print('PASS latest manual bag choice survives departure in both directions')
reset(false); begin()
OpenAllBags(taxi); ToggleAllBags(); flush()
assert(W:IsOpen(), 'explicit bag toggle must beat taxi cleanup in the same frame')
CloseAllBags(taxi); ToggleAllBags(); flush()
assert(not W:IsOpen(), 'explicit bag close must beat taxi cleanup in the same frame')
depart()
assert(not W:IsOpen(), 'coalesced manual close must survive taxi departure')
print('PASS explicit toggles win over same-frame taxi bag calls')
-- Cleanup before/after TAXIMAP_CLOSED, with no UnitOnTaxi signal yet, must
-- preserve both choices. Run real native handoff polling in the same sequence.
for _, initial in ipairs({ false, true }) do
  for _, order in ipairs({ 'cleanup-first', 'map-close-first' }) do
    reset(initial); begin()
    now = now + 0.4; CB.Pad:AutoHoldCheck()
    now = now + 0.4; CB.Pad:AutoHoldCheck()
    if initial then
      assert(CB.Pad.holdGame == taxi, 'open bags must still hand controller to native flight map')
    else
      assert(not W:IsOpen(), 'native taxi navigation must not auto-open bags')
    end
    if order == 'cleanup-first' then CloseAllBags() end
    taxi:Hide(); event('TAXIMAP_CLOSED'); event('PLAYER_CONTROL_LOST')
    if order == 'map-close-first' then CloseAllBags() end
    flush(); CB.Pad:GameNeedsPad(); CB.Pad:Reclaim('taxi departed')
    assert(W:IsOpen() == initial, 'taxi event order must not change bag visibility: ' .. order)
    now = now + 0.8; OpenAllBags(); flush()
    assert(W:IsOpen() == initial, 'delayed departure cleanup must preserve bag state')
    flying = true; now = now + 3; CloseAllBags(); flush()
    assert(W:IsOpen() == initial, 'in-flight cleanup must preserve bag state after close grace')
    W:Toggle()
    local latest = W:IsOpen()
    OpenAllBags(); CloseAllBags(); flush()
    assert(W:IsOpen() == latest, 'direct custom bag controls must remain authoritative in flight')
  end
end
print('PASS both taxi event orders, native handoff, delayed cleanup and direct bag controls')
local merchant = CreateFrame('Frame', 'MerchantFrame', UIParent)
merchant:Hide()
reset(true)
merchant:Show(); event('MERCHANT_SHOW'); OpenAllBags(merchant); flush()
assert(W:IsOpen(), 'merchant show must open bags')
merchant:Hide(); event('MERCHANT_CLOSED'); CloseAllBags(merchant); flush()
assert(not W:IsOpen(), 'merchant close must hide even bags open before the visit')
print('PASS merchant opens and closes bags together, including pre-opened bags')
for _, visit in ipairs({
  { 'MerchantFrame', 'MERCHANT_SHOW', 'MERCHANT_CLOSED' },
  { 'BankFrame', 'BANKFRAME_OPENED', 'BANKFRAME_CLOSED' },
  { 'MailFrame', 'MAIL_SHOW', 'MAIL_CLOSED' },
  { 'TradeFrame', 'TRADE_SHOW', 'TRADE_CLOSED' },
}) do
  local f = rawget(_G, visit[1]) or CreateFrame('Frame', visit[1], UIParent)
  f:Hide()
  for _, initial in ipairs({ false, true }) do
    reset(initial)
    -- A normal visit immediately after the taxi is not taxi cleanup.
    event('TAXIMAP_CLOSED')
    f:Show(); event(visit[2]); OpenAllBags(f); flush()
    assert(W:IsOpen(), visit[1] .. ' must bring up bags together')
    f:Hide(); event(visit[3]); CloseAllBags(f); flush()
    assert(not W:IsOpen(), visit[1] .. ' must put away bags together')
  end
end
print('PASS merchant/native bank/mail/trade paired bag lifetimes after taxi, from open and closed')
-- Outside a taxi, a frameless CloseAllBags() is the game tidying (Escape's CloseAllWindows, a panel
-- opening), never the bag key; the bag key always reaches a Toggle* hook (see panel_close_test.lua).
reset(false)
CloseAllBags(); flush()
assert(not W:IsOpen(), 'frameless native cleanup outside a taxi must not open the bags')
ToggleAllBags(); flush()
assert(W:IsOpen(), 'the bag key must still open the bags on the first press outside a taxi')
print('PASS outside taxi: frameless cleanup ignored, bag key opens on the first press')
assert((CB.errorCount or 0) == 0, 'shipping modules logged Lua errors')
print('ALL PASS taxi lifecycle (offline only)')
