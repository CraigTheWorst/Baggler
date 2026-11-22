-- Run from repository root: luajit addons/Baggler/Tests/alt_counts_tooltip_test.lua
-- Other characters' counts on item tooltips, through the shipping TOC in the fake client. The script boots once
-- with a tooltip data post-processor present and then re-runs itself without one to cover the fallback route.
-- Offline only: no claim about the live client's tooltip timing.
local route = arg[1] or 'processor'
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function UnitLevel() return 60 end

local postCall
if route == 'processor' then
  Enum.TooltipDataType = { Item = 0 }
  TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) assert(kind == 0); postCall = fn end }
end
ItemRefTooltip = CreateFrame('GameTooltip', 'ItemRefTooltip')
ShoppingTooltip1 = CreateFrame('GameTooltip', 'ShoppingTooltip1')

local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()

local ITEM = 4321
local function record(tip)
  tip.__lines = {}
  tip.AddLine = function(self, text, r, g, b) self.__lines[#self.__lines + 1] = { text = text, r = r, g = g, b = b } end
  return tip
end
for _, tip in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1 }) do record(tip) end

local function setChars(n)
  CB.db.chars = {}
  for i = 1, n do
    CB.db.chars['Realm-Alt' .. i] = { name = 'Alt' .. i, class = 'MAGE', bags = { [ITEM] = i } }
  end
  CB.db.account = {}
end

-- One fresh item display on a tooltip, as the client would drive it.
local function display(tip)
  tip.__lines = {}
  local cleared = tip.__scripts.OnTooltipCleared
  if cleared then cleared(tip) end
  if postCall then
    postCall(tip, { id = ITEM })
  else
    tip.GetItem = function() return 'Thing', '|cffffffff|Hitem:' .. ITEM .. '::::|h[Thing]|h|r' end
    local set = tip.__scripts.OnTooltipSetItem
    if set then set(tip) end
  end
  return tip.__lines
end
local function texts(lines) local t = {} for i, l in ipairs(lines) do t[i] = l.text end return t end

local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print('PASS alt counts [' .. route .. ']: ' .. name) end

check('route registered', function()
  if route == 'processor' then assert(postCall, 'post-processor hook expected')
  else assert(GameTooltip.__scripts.OnTooltipSetItem, 'item-set script fallback expected') end
end)

check('two characters: separator, two lines and a total', function()
  CB.db.showAltCounts = true
  setChars(2)
  local lines = display(GameTooltip)
  local t = texts(lines)
  assert(#t == 4, 'expected 4 lines, got ' .. #t .. ': ' .. table.concat(t, ' / '))
  assert(t[1] == ' ', 'separator first')
  assert(t[2]:find('Alt2') and t[3]:find('Alt1'), 'sorted by count')
  local soft = CB.COLOR.soft
  assert(lines[2].r == soft[1] and lines[2].g == soft[2] and lines[2].b == soft[3], 'character lines in the soft colour')
  assert(t[4] == 'Total elsewhere: 3', t[4])
end)

check('the block is added once per display', function()
  setChars(2)
  display(GameTooltip)
  local n = #GameTooltip.__lines
  if postCall then postCall(GameTooltip, { id = ITEM }) else GameTooltip.__scripts.OnTooltipSetItem(GameTooltip) end
  assert(#GameTooltip.__lines == n, 'repeated hook call on the same display must not add a second block')
end)

check('seven characters: six lines, "and 1 more" and the total', function()
  setChars(7)
  local t = texts(display(GameTooltip))
  assert(#t == 9, 'expected 9 lines, got ' .. #t)
  assert(t[8] == 'and 1 more', t[8])
  assert(t[9] == 'Total elsewhere: 28', t[9])
end)

check('chat link tooltip gets the block, comparison tooltip does not', function()
  setChars(2)
  assert(#display(ItemRefTooltip) == 4, 'ItemRefTooltip block')
  if postCall then
    ShoppingTooltip1.__lines = {}
    postCall(ShoppingTooltip1, { id = ITEM })
    assert(#ShoppingTooltip1.__lines == 0, 'shopping tooltip must stay untouched')
  else
    assert(not ShoppingTooltip1.__scripts.OnTooltipSetItem, 'fallback must not hook other tooltips')
  end
end)

check('switched off or nobody else: nothing added', function()
  setChars(2)
  CB.db.showAltCounts = false
  assert(#display(GameTooltip) == 0, 'showAltCounts=false')
  CB.db.showAltCounts = true
  setChars(0)
  assert(#display(GameTooltip) == 0, 'no characters')
  setChars(1)
  local t = texts(display(GameTooltip))
  assert(#t == 2, 'one character: separator + one line, no total')
end)

check('a CountLines error stays inside Baggler', function()
  setChars(2)
  local real = CB.Extras.CountLines
  CB.Extras.CountLines = function() error('boom') end
  local ok, err = pcall(display, GameTooltip)
  CB.Extras.CountLines = real
  assert(ok, 'error escaped the tooltip hook: ' .. tostring(err))
  assert(#GameTooltip.__lines == 0)
end)

print(('PASS alt counts [%s]: %d cases'):format(route, passed))

if route == 'processor' then
  local self = arg[0]
  local pipe = assert(io.popen('luajit "' .. self .. '" fallback 2>&1'))
  local out = pipe:read('*a')
  local ok = pipe:close()
  io.write(out)
  assert(ok == true or ok == 0, 'fallback route run failed')
  assert(out:find('PASS alt counts %[fallback%]: %d+ cases'), 'fallback route did not finish')
end
