-- Run from repository root: luajit addons/Baggler/Tests/card_body_test.lua
-- What the item card draws: title, subtitle, body rows from tooltip data, the known line, facts, buttons and the
-- cards for worn gear. Boots the shipping TOC in the fake client; colours and widths are those handed to the fake
-- font strings, so this is NOT an in-game rendering check.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
function UnitLevel() return 60 end

NORMAL_FONT_COLOR = { r = 0.9, g = 0.8, b = 0.1 }
ITEM_SPELL_KNOWN = 'Already known'
ITEM_DELTA_DESCRIPTION = 'If you replace this item, the following stat changes will occur:'

local contents = STUB_CONTENTS
local CHEST = { id = 40, q = 3, name = 'Bright Breastplate', class = 4, sub = 4, ilvl = 60, equip = 'INVTYPE_CHEST' }
contents[0][8] = CHEST
local WORN = { id = 41, name = 'Rusty Breastplate', link = '|cffffffff|Hitem:41|h[Rusty Breastplate]|h|r' }
local worn = { [5] = WORN }
local function linkOf(it) return '|cffffffff|Hitem:' .. it.id .. '|h[' .. it.name .. ']|h|r' end
C_TooltipInfo = {
  GetBagItem = function(b, s)
    local it = contents[b] and contents[b][s]
    return it and { guid = 'bag-' .. it.id, lines = { { leftText = it.name, leftColor = { r = 0, g = 0.44, b = 0.87 } }, { leftText = 'Chest' } } }
  end,
  GetInventoryItem = function(_, slot)
    local it = worn[slot]
    return it and { guid = 'worn-' .. it.id, lines = { { leftText = it.name, leftColor = { r = 0.1, g = 1, b = 0 } }, { leftText = 'Armor 20' } } }
  end,
}
local itemInstant = C_Item.GetItemInfoInstant
C_Item.GetItemInfoInstant = function(id)
  if type(id) == 'string' then id = tonumber(id:match('item:(%d+)')) end
  if id == CHEST.id then return id, 't', 's', CHEST.equip, 1, CHEST.class, CHEST.sub end
  return itemInstant(id)
end
function GetInventoryItemLink(_, slot) return worn[slot] and worn[slot].link end
function GetInventoryItemID(_, slot) return worn[slot] and worn[slot].id end
local deltaLines = { '+5 Stamina', '-3 Agility', 'Durability changes' }
C_TooltipComparison = {
  GetItemComparisonInfo = function(native) return { method = 0, item = { guid = 'worn-41' }, additionalItems = {} } end,
  GetItemComparisonDelta = function() return deltaLines end,
}

local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
CB.db.itemCard, CB.db.cardCompare = true, true

local W = CB.Window
W:Open(); FLUSH()
local Card = CB.Card

-- Font strings in the fake client do not remember colours; record them.
local function remember(fs)
  if fs.__recording then return end
  fs.__recording = true
  fs.SetTextColor = function(self, r, g, b) self.__colour = { r, g, b } end
end
local function instrument(f)
  remember(f.name); remember(f.sub)
  for _, w in ipairs(f.lines) do remember(w.left); remember(w.right) end
end

local function tip(lines) return { lines = lines } end
local function show(data, extra)
  local spec = { data = data, icon = 1, name = 'Spec Name', facts = { { left = 'Carried', right = '1' } }, noCompare = true }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return Card:Show(W, spec)
end
-- Show twice so the pooled widgets exist before they are instrumented.
local function showRecorded(data, extra)
  assert(show(data, extra))
  for _, f in ipairs(Card.frames) do instrument(f) end
  assert(show(data, extra))
  return Card.frame
end
local function shape(f)
  local out = {}
  for _, row in ipairs(f.drawn) do out[#out + 1] = row.kind == 'text' and row.left or ('<' .. row.kind .. '>') end
  return table.concat(out, ' | ')
end
local function widgetFor(f, text)
  for i, row in ipairs(f.drawn) do if row.kind == 'text' and row.left == text then return f.lines[i], row end end
end
local function near(c, r, g, b) return c and math.abs(c[1] - r) < 1e-6 and math.abs(c[2] - g) < 1e-6 and math.abs(c[3] - b) < 1e-6 end

local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print('PASS card body: ' .. name) end

check('1 spacer runs collapse and never lead or trail the tooltip rows', function()
  local f = showRecorded(tip({ { leftText = 'Name' }, { leftText = '' }, {}, { leftText = 'Binds when picked up' }, { leftText = '' },
    { leftText = 'Durability 50 / 50' }, {} }))
  local got = shape(f)
  assert(got == 'Binds when picked up | <space> | Durability 50 / 50 | <space> | Carried', got)
  for i, row in ipairs(f.drawn) do
    if row.kind == 'text' then assert(f.lines[i].left:IsShown() and f.lines[i].left:GetText() == row.left) end
  end
end)

check('2 left and right texts share a row without overlapping', function()
  local f = showRecorded(tip({ { leftText = 'Name' }, { leftText = 'Head', rightText = 'Plate' } }))
  local w = assert(widgetFor(f, 'Head'))
  assert(w.left:GetText() == 'Head' and w.right:GetText() == 'Plate' and w.right:IsShown())
  assert(w.left:GetWidth() + w.right:GetStringWidth() <= Card.contentWidth, 'left text overlaps the right text')
  assert(w.left:GetWidth() > 0)
  local empty = showRecorded(tip({ { leftText = 'Name' }, { rightText = 'Two-Hand' } }))
  assert(empty.drawn[1].kind == 'text' and empty.drawn[1].right == 'Two-Hand',
    'a line with only right text is a text row, not a spacer')
end)

check('3 missing colours use the game tooltip colour, with a fixed fallback', function()
  local f = showRecorded(tip({ { leftText = 'Name' }, { leftText = 'Plain line' }, { leftText = 'Green', leftColor = { r = 0, g = 1, b = 0 } } }))
  assert(near(widgetFor(f, 'Plain line').left.__colour, 0.9, 0.8, 0.1), 'NORMAL_FONT_COLOR expected')
  assert(near(widgetFor(f, 'Green').left.__colour, 0, 1, 0))
  local saved = NORMAL_FONT_COLOR
  NORMAL_FONT_COLOR = nil
  f = showRecorded(tip({ { leftText = 'Name' }, { leftText = 'Plain line' } }))
  NORMAL_FONT_COLOR = saved
  assert(near(widgetFor(f, 'Plain line').left.__colour, 1, 0.82, 0), 'fallback 1/0.82/0 expected')
end)

check('4 title text and colour come from tooltip line 1', function()
  local f = showRecorded(tip({ { leftText = 'Epic Thing', leftColor = { r = 0.64, g = 0.21, b = 0.93 } } }))
  assert(f.name:GetText() == 'Epic Thing' and near(f.name.__colour, 0.64, 0.21, 0.93))
  f = showRecorded(tip({ { leftText = 'Plain Thing' } }))
  assert(f.name:GetText() == 'Plain Thing' and near(f.name.__colour, 0.9, 0.8, 0.1))
  f = showRecorded(tip({}))
  assert(f.name:GetText() == 'Spec Name', 'no lines: spec.name')
  assert(shape(f) == 'Carried', 'only line 1: facts still shown, got ' .. shape(f))
end)

check('5 subtitle: class name and item level above 1', function()
  local f = showRecorded(tip({ { leftText = 'Name' } }), { classID = 4, ilvl = 60 })
  local sub = f.sub:GetText()
  assert(sub:find('Class4', 1, true) and sub:find('ilvl 60', 1, true), sub)
  f = showRecorded(tip({ { leftText = 'Name' } }), { classID = 4, ilvl = 1 })
  assert(f.sub:GetText() == 'Class4', f.sub:GetText())
  f = showRecorded(tip({ { leftText = 'Name' } }), { ilvl = 1 })
  assert(not f.sub:GetText():find('ilvl'), 'never ilvl 1')
end)

check('6 known line appears once, in red', function()
  local scan = function(t)
    t.NumLines = function() return 2 end
    _G.BagglerScanTipTextLeft2 = { GetText = function() return ITEM_SPELL_KNOWN end }
  end
  local f = showRecorded(tip({ { leftText = 'Recipe' }, { leftText = 'Teaches you something.' } }), { scan = scan })
  local count = 0
  for _, row in ipairs(f.drawn) do if row.left == ITEM_SPELL_KNOWN then count = count + 1 end end
  assert(count == 1, 'known line count ' .. count)
  assert(near(widgetFor(f, ITEM_SPELL_KNOWN).left.__colour, 1, 0.2, 0.2), 'known line must be red')
  f = showRecorded(tip({ { leftText = 'Recipe' }, { leftText = ITEM_SPELL_KNOWN } }), { scan = scan })
  count = 0
  for _, row in ipairs(f.drawn) do if row.left == ITEM_SPELL_KNOWN then count = count + 1 end end
  assert(count == 1, 'already in the tooltip: not added again')
  _G.BagglerScanTipTextLeft2 = nil
end)

local function factLabels(f)
  local out = {}
  for _, row in ipairs(f.drawn) do if row.kind == 'text' and row.right then out[#out + 1] = row.left .. '=' .. row.right end end
  return out
end

check('7 bag facts: count, sell value, location, cooldown', function()
  local realLeft = CB.Inventory.CooldownLeft
  CB.Inventory.CooldownLeft = function() return 65 end
  local rec = { bag = 0, slot = 8, key = '0:8', itemID = 40, count = 1, sellPrice = 250, name = CHEST.name, link = linkOf(CHEST),
    equipLoc = CHEST.equip, classID = 4, ilvl = 60, icon = 7 }
  CB.db.cardCompare = false
  assert(Card:ShowFor(W, rec, false))
  local facts = factLabels(Card.frame)
  assert(#facts == 4, table.concat(facts, ', '))
  assert(facts[1] == 'Carried=99', facts[1])
  assert(facts[2]:find('^Sells for=250'), facts[2])
  assert(facts[3] == 'Location=0 / 8', facts[3])
  assert(facts[4] == 'Cooldown=1m 5s', facts[4])
  assert(Card.source and Card.source.key == '0:8' and Card.source.mouse == false)
  rec.sellPrice = 0
  CB.Inventory.CooldownLeft = function() return nil end
  assert(Card:ShowFor(W, rec, true))
  facts = factLabels(Card.frame)
  assert(#facts == 2 and facts[2] == 'Location=0 / 8', table.concat(facts, ', '))
  assert(Card.mouseShown == true and Card.source.mouse == true)
  CB.Inventory.CooldownLeft = realLeft
  CB.db.cardCompare = true
end)

check('8 worn gear card with stat changes; off when comparison is off', function()
  local spec = { link = linkOf(CHEST), equipLoc = CHEST.equip, noCompare = false }
  local data = C_TooltipInfo.GetBagItem(0, 8)
  assert(show(data, spec))
  local cmp = assert(Card.cmp and Card.cmp[1], 'comparison card expected')
  assert(cmp:IsShown() and cmp.name:GetText() == WORN.name, tostring(cmp.name:GetText()))
  local heading, rows = nil, cmp.drawn
  for i, row in ipairs(rows) do if row.left == ITEM_DELTA_DESCRIPTION then heading = i end end
  assert(heading, 'delta heading missing: ' .. shape(cmp))
  assert(rows[heading - 1].kind == 'space', 'a spacer precedes the heading')
  local hc = rows[heading].leftColour
  assert(math.abs(hc.r - 0.9) < 1e-6 and math.abs(hc.g - 0.8) < 1e-6, 'heading in the tooltip colour')
  assert(rows[heading + 1].left == CB.HEX.gain .. '+5 Stamina|r', rows[heading + 1].left)
  assert(rows[heading + 2].left == CB.HEX.loss .. '-3 Agility|r', rows[heading + 2].left)
  assert(rows[heading + 3].left == 'Durability changes')
  assert(cmp.sub:GetText():find('Worn now', 1, true))
  CB.db.cardCompare = false
  assert(show(data, spec))
  assert(not Card.cmp[1]:IsShown(), 'comparison must hide with cardCompare off')
  CB.db.cardCompare = true
  assert(show(data, { link = spec.link, equipLoc = spec.equipLoc, noCompare = true }))
  assert(not Card.cmp[1]:IsShown(), 'noCompare hides it too')
end)

check('9 empty worn slot: one "Nothing equipped" card', function()
  worn[5] = nil
  assert(show(C_TooltipInfo.GetBagItem(0, 8), { link = linkOf(CHEST), equipLoc = CHEST.equip, noCompare = false }))
  local shown = 0
  for _, f in ipairs(Card.cmp) do if f:IsShown() then shown = shown + 1 end end
  assert(shown == 1 and Card.cmp[1].name:GetText() == 'Nothing equipped')
  assert(Card.cmp[1].sub:GetText() == 'No readable equipped item in this slot' and #Card.cmp[1].drawn == 0)
  worn[5] = WORN
end)

check('10 sixty tooltip lines stay within the row limit and the screen', function()
  local lines = { { leftText = 'Long' } }
  for i = 1, 60 do lines[#lines + 1] = { leftText = 'Line ' .. i, rightText = (i % 3 == 0) and 'R' or nil } end
  local ok, err = pcall(show, tip(lines))
  assert(ok and err, tostring(err))
  local f = Card.frame
  local visible = 0
  for _, w in ipairs(f.lines) do if w.left:IsShown() or w.rule:IsShown() then visible = visible + 1 end end
  assert(visible <= Card.rowLimit and #f.drawn <= Card.rowLimit, 'rows drawn ' .. visible)
  assert(f:GetHeight() <= UIParent:GetHeight() - 40, 'height ' .. f:GetHeight())
end)

check('11 a shorter card after a long one leaves nothing stale', function()
  assert(show(tip({ { leftText = 'Short' }, { leftText = 'Only line' } })))
  local f = Card.frame
  for i, w in ipairs(f.lines) do
    local row = f.drawn[i]
    if not row then
      assert(not w.left:IsShown() and not w.right:IsShown() and not w.rule:IsShown(), 'stale row ' .. i)
    elseif row.kind == 'text' and not row.right then
      assert(not w.right:IsShown(), 'stale right text on row ' .. i)
    end
  end
  assert(shape(f) == 'Only line | <space> | Carried', shape(f))
end)

check('12 no tooltip data: nothing shown', function()
  assert(show(tip({ { leftText = 'Visible' } })) and Card.frame:IsShown())
  assert(Card:Show(W, {}) == false)
  assert(not Card.frame:IsShown())
  for _, f in ipairs(Card.cmp or {}) do assert(not f:IsShown()) end
  assert(Card:Show(W, nil) == false and Card:Show(nil, { data = tip({}) }) == false)
end)

check('bgAlpha setting reaches every card frame', function()
  local seen = {}
  for _, f in ipairs(Card.frames) do f.SetBackdropColor = function(self, r, g, b, a) seen[self] = a end end
  CB.db.bgAlpha = 0.5
  CB:Fire('SETTING', 'bgAlpha', 0.5)
  for _, f in ipairs(Card.frames) do assert(seen[f] == 0.5) end
  assert(#Card.frames >= 2, 'main and comparison frames are registered')
end)

print(('PASS card body: %d cases'):format(passed))
