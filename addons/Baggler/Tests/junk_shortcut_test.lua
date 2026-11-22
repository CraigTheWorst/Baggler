-- Run from repository root: timeout 60 luajit addons/Baggler/Tests/junk_shortcut_test.lua
-- Offline controller routing test; not proof of in-game protected API permission.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
CB.db.pad.mode = 'on'
local W, P = CB.Window, CB.Pad
MerchantFrame = CreateFrame('Frame', 'MerchantFrame', UIParent)
MerchantFrame:Show()
W:Open()
P.handedOff, P.holdGame, P.yield = false, nil, false
P:Push(W.ctx)
local sales, sorted, folded = 0, 0, 0
local realSellJunk = CB.Integrations.SellJunk
CB.Integrations.SellJunk = function(_, manual)
  assert(manual == true, 'shortcut must reuse manual safe seller')
  sales = sales + 1
end
W.CleanUp = function() sorted = sorted + 1 end
W.ToggleSection = function() folded = folded + 1 end
local filtered = 0
W.CycleFilter = function() filtered = filtered + 1 end
W.selEntry = { sec = 1 }
W.sections = { { name = 'Junk' } }
-- One button at a vendor: the filter button (RT) sells junk. No chord, so LT/R3 never fire by accident.
P:Press('filter', true, 'binding')
assert(sales == 1, 'RT in merchant bags must call existing SellJunk(true)')
P:Press('filter', false, 'binding')
assert(sales == 1, 'release must not repeat the sale')
assert(sorted == 0 and folded == 0 and filtered == 0, 'selling junk must not sort, fold or filter')
print('PASS merchant RT sells junk once through the existing manual seller')

P:Press('collapse', true, 'binding'); P:Press('collapse', false, 'binding')
assert(folded == 1 and sales == 1, 'LT alone folds immediately and never sells')
P:Press('sort', true, 'binding'); P:Press('sort', false, 'binding')
assert(sorted == 1 and sales == 1, 'R3 alone still sorts at merchants')
P:Press('collapse', true, 'binding'); P:Press('sort', true, 'binding')
P:Press('sort', false, 'binding'); P:Press('collapse', false, 'binding')
assert(sales == 1, 'the old LT + R3 chord no longer sells')
assert(CB.db.pad.map.PAD3 == 'pickup' and CB.db.pad.map.PAD4 == 'menu')
assert(CB.db.pad.map.PADFORWARD == 'switchWindow' and CB.db.pad.map.PADBACK == 'options')
assert(CB.db.pad.map.PADRTRIGGER == 'filter', 'no saved mapping is rewritten')
print('PASS LT fold, R3 sort, Start, Back and face-button mappings untouched')

local function press() P:Press('filter', true, 'binding'); P:Press('filter', false, 'binding') end
local function rejected(name, setup, restore)
  setup()
  local before, fb = sales, filtered
  press()
  assert(sales == before, 'must not sell: ' .. name)
  restore()
end
rejected('no merchant', function() MerchantFrame:Hide() end, function() MerchantFrame:Show() end)
assert(filtered >= 1, 'away from a vendor RT is the filter again')
rejected('native controller focus', function() P.handedOff = true end, function() P.handedOff = false end)
rejected('native hold', function() P.holdGame = MerchantFrame end, function() P.holdGame = nil end)
rejected('keyboard focus', function() P.yield = true end, function() P.yield = false end)
rejected('pad disabled', function() CB.db.pad.mode = 'off' end, function() CB.db.pad.mode = 'on' end)
local realCombat = InCombatLockdown
rejected('combat', function() InCombatLockdown = function() return true end end,
  function() InCombatLockdown = realCombat end)
rejected('resizing', function() W.sizing = true end, function() W.sizing = false end)
rejected('search', function() W.searching = true end, function() W.searching = false end)
rejected('top-row controls', function() W.chrome = 1 end, function() W.chrome = nil end)
local realCursor = CursorHasItem
rejected('item on cursor', function() CursorHasItem = function() return true end end,
  function() CursorHasItem = realCursor end)
local foreignContext={OnPad=function() end}
rejected('menu or bank focus', function() P:Push(foreignContext) end,
  function() P:Pop(foreignContext) end)
print('PASS merchant/focus/combat/cursor/mode guards')

-- Discoverable: the footer hint line shows the button while (and only while) a vendor is open.
local hint = W.frame.hints
W:SetHintText(400)
local text = hint.text or (hint.GetText and hint:GetText()) or ''
assert(text:find('Sell junk'), 'merchant footer hints must advertise Sell junk: ' .. text)
assert(text:find(CB.UI:PadLabel('PADRTRIGGER'), 1, true), 'hint must name the actual button')
MerchantFrame:Hide()
W:SetHintText(400)
text = hint.text or (hint.GetText and hint:GetText()) or ''
assert(not text:find('Sell junk'), 'no Sell junk hint away from a vendor')
MerchantFrame:Show()
print('PASS footer hint shows Sell junk on the real button only at a vendor')

-- Exercise the actual sale queue and actual IsJunk policy; only the client timer
-- and inventory boundary are controlled. The shortcut must not bypass either.
CB.Integrations.SellJunk = realSellJunk
local ticks, uses = {}, {}
C_Timer.NewTicker = function(interval, fn, count)
  assert(interval == 0.1, 'existing paced seller must be reused')
  local t = { fn = fn, count = count, cancelled = false }
  function t:Cancel() self.cancelled = true end
  ticks[#ticks + 1] = t
  return t
end
C_Container.UseContainerItem = function(bag, slot) uses[#uses + 1] = { bag, slot } end
CB.db.autoSellJunk = false
CB.db.favorites[102] = true
CB.db.junk[105] = true
CB.Inventory.Scan = function()
  return {
    { itemID = 101, quality = 0, bag = 0, slot = 1, count = 2, sellPrice = 3 },
    { itemID = 102, quality = 0, bag = 0, slot = 2, count = 1, sellPrice = 3 },
    { itemID = 103, quality = 0, bag = 0, slot = 3, count = 1, hasNoValue = true },
    { itemID = 104, quality = 1, bag = 0, slot = 4, count = 1, sellPrice = 3 },
    { itemID = 105, quality = 1, bag = 0, slot = 5, count = 1, sellPrice = 3 },
  }
end
-- The seller now re-reads native slot data on every tick. Model the same
-- unchanged slots at that boundary, rather than the harness's unrelated bags.
C_Container.GetContainerItemInfo = function(bag, slot)
  for _, rec in ipairs(CB.Inventory:Scan()) do
    if rec.bag == bag and rec.slot == slot then
      return { itemID = rec.itemID, quality = rec.quality, stackCount = rec.count,
        hasNoValue = rec.hasNoValue, isLocked = rec.locked, hyperlink = rec.link }
    end
  end
end
press()
assert(#ticks == 1 and #uses == 0, 'manual shortcut must start the existing async queue, not immediately use items')
local t = ticks[1]
for _ = 1, t.count do if not t.cancelled then t.fn(t) end end
assert(t.cancelled and #uses == 2, 'seller must finish with only unprotected junk')
assert(uses[1][2] == 1 and uses[2][2] == 5, 'favorite/no-value/ordinary items must remain; marked junk keeps existing policy')
press()
assert(#ticks == 2)
event('MERCHANT_CLOSED')
assert(ticks[2].cancelled, 'merchant closure must cancel the existing seller ticker')
print('PASS actual async seller: favorites/no-value/nonjunk retained, marked junk included, close cancels')
-- The visible "Sell junk" footer button must be a controller stop (D-pad up into the window controls, A).
do
  CB.Integrations.SellJunk = function(_, manual) assert(manual == true); sales = sales + 1 end
  local btn = W.frame.sellBtn
  W.selEntry = nil -- the earlier fake entry has no layout; LeaveChrome would try to place it
  assert(btn, 'bags window must own a Sell junk button')
  btn:Show()
  local index
  for i, entry in ipairs(W:ChromeList()) do if entry.widget == btn then index = i end end
  assert(index, 'shown Sell junk button must be reachable as a controller chrome stop')
  local before = sales
  W:EnterChrome(index)
  assert(W:ChromeId() == 'selljunk' and btn.cbFocused, 'Sell junk stop must draw controller focus')
  W:ActivateChrome()
  assert(sales == before + 1, 'A on the Sell junk stop must use the existing manual seller')
  W:LeaveChrome()
  assert(not btn.cbFocused, 'leaving chrome must clear Sell junk focus')
  btn:Hide()
  for _, entry in ipairs(W:ChromeList()) do assert(entry.widget ~= btn, 'hidden Sell junk button must not be a stop') end
  print('PASS Sell junk button reachable and usable by controller only while shown')
end
print('ALL PASS junk controller shortcut (offline only)')
