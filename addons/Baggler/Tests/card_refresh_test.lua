-- Run from repository root: luajit addons/Baggler/Tests/card_refresh_test.lua
-- The item card (and its "Currently equipped" comparison card) must follow an equip done on the highlighted
-- item without the highlight having to move. Boots the shipping TOC in the fake client; the equip itself is
-- simulated (bag slot + worn slot swapped, then the game's events), so this is NOT an in-game certification.
-- Events (pinned wow-ui-source 9dc84f0d, version.txt 1.60.1.70862, Blizzard_APIDocumentationGenerated):
--   PLAYER_EQUIPMENT_CHANGED  PaperDollInfoDocumentation.lua:386
--   BAG_UPDATE_DELAYED        ContainerDocumentation.lua:677
--   ITEM_LOCK_CHANGED         ContainerDocumentation.lua:721
--   C_Timer.After             UITimerDocumentation.lua:11
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
function UnitLevel() return 60 end

local contents = STUB_CONTENTS
local NEW = { id = 40, q = 3, name = 'Bright Breastplate', class = 4, sub = 4, ilvl = 60, equip = 'INVTYPE_CHEST' }
local OLD = { id = 41, q = 2, name = 'Rusty Breastplate', class = 4, sub = 4, ilvl = 40, equip = 'INVTYPE_CHEST' }
contents[0][8] = NEW
local worn = { [5] = OLD }
local function linkOf(it) return '|cffffffff|Hitem:' .. it.id .. '|h[' .. it.name .. ']|h|r' end
local function tipOf(it) return it and { lines = { { leftText = it.name, leftColor = { r = 1, g = 1, b = 1 } } } } end
C_TooltipInfo = {
  GetBagItem = function(b, s) return tipOf(contents[b] and contents[b][s]) end,
  GetInventoryItem = function(_, slot) return tipOf(worn[slot]) end,
}
local itemInstant = C_Item.GetItemInfoInstant
C_Item.GetItemInfoInstant = function(id)
  if type(id) == 'string' then id = tonumber(id:match('item:(%d+)')) end
  for _, it in ipairs({ NEW, OLD }) do if it.id == id then return id, 't', 's', it.equip, 1, it.class, it.sub end end
  return itemInstant(id)
end
function GetInventoryItemLink(_, slot) return worn[slot] and linkOf(worn[slot]) end
CURSOR_ITEM = false
function CursorHasItem() return CURSOR_ITEM end

local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
CB.db.itemCard, CB.db.cardCompare = true, true

local W = CB.Window
W:Open()
FLUSH()
local function frame() W.frame.__scripts.OnUpdate(W.frame, 0.016) end
local function entryAt(key) for _, e in ipairs(W.navFull or W.nav) do if e.key == key then return e end end end
local function mainTitle() return CB.Card.frame and CB.Card.frame:IsShown() and CB.Card.frame.name:GetText() end
local function wornTitle() local c = CB.Card.cmp and CB.Card.cmp[1]; return c and c:IsShown() and c.name:GetText() end

local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print('PASS card refresh: ' .. name) end

local function reset()
  contents[0][8], worn[5] = NEW, OLD
  CURSOR_ITEM = false
  event('BAG_UPDATE_DELAYED'); frame(); FLUSH(); frame(); FLUSH()
end

local function equipSwap()          -- the game swaps the bag piece and the worn piece
  contents[0][8], worn[5] = OLD, NEW
end

local function selectByPad()
  local e = assert(entryAt('0:8'), 'test chest piece is not listed')
  W:SelectEntry(e)
  assert(W.cardFrom == 'pad', 'controller highlight must hold the card')
  assert(mainTitle() == NEW.name and wornTitle() == OLD.name, 'setup: card must describe the bag piece and the worn piece')
end

check('controller equip swaps both cards in place (events then window redraw)', function()
  reset(); selectByPad()
  equipSwap()
  event('ITEM_LOCK_CHANGED', 0, 8)
  event('PLAYER_EQUIPMENT_CHANGED', 5, false)
  event('BAG_UPDATE_DELAYED')
  FLUSH()                        -- the card's deferred refresh may run before the window's own redraw
  frame(); FLUSH(); frame(); FLUSH()
  assert(mainTitle() == OLD.name, 'item card still shows ' .. tostring(mainTitle()) .. ' after equip')
  assert(wornTitle() == NEW.name, 'equipped card still shows ' .. tostring(wornTitle()) .. ' after equip')
end)

check('controller equip refreshes when the window redraws first', function()
  reset(); selectByPad()
  equipSwap()
  event('PLAYER_EQUIPMENT_CHANGED', 5, false)
  event('BAG_UPDATE_DELAYED')
  frame(); FLUSH()
  assert(mainTitle() == OLD.name and wornTitle() == NEW.name, 'cards must follow the swap')
end)

check('selection on a slot that emptied: card hides or follows the new highlight, never stale', function()
  reset(); selectByPad()
  contents[0][8], worn[5] = nil, NEW            -- equipped into an empty worn slot: the bag slot is empty now
  event('PLAYER_EQUIPMENT_CHANGED', 5, false)
  event('BAG_UPDATE_DELAYED')
  FLUSH(); frame(); FLUSH(); frame(); FLUSH()
  local sel = W.selEntry
  if sel and sel.rec and not sel.rec.empty then
    assert(mainTitle() == sel.rec.name, 'card must describe the item now highlighted, got ' .. tostring(mainTitle()))
  else
    assert(not mainTitle(), 'card must hide when the highlight is on nothing')
  end
  assert(mainTitle() ~= NEW.name, 'card must not keep the item that was equipped away')
end)

check('mouse click equip refreshes the hover card under the pointer', function()
  reset()
  W.cardFrom = nil; CB.Card:Hide()
  local e = assert(entryAt('0:8'))
  W:HoverCard(e.btn)
  assert(W.cardFrom == 'mouse' and mainTitle() == NEW.name and wornTitle() == OLD.name, 'setup: hover card')
  equipSwap()
  event('PLAYER_EQUIPMENT_CHANGED', 5, false)
  event('BAG_UPDATE_DELAYED')
  FLUSH(); frame(); FLUSH(); frame(); FLUSH()
  assert(mainTitle() == OLD.name and wornTitle() == NEW.name, 'hover card must follow the click equip')
end)

check('no work while the card is hidden or the window is closed', function()
  reset(); selectByPad()
  CB.Card:Hide()
  local calls, real = 0, C_TooltipInfo.GetBagItem
  C_TooltipInfo.GetBagItem = function(...) calls = calls + 1; return real(...) end
  equipSwap()
  event('PLAYER_EQUIPMENT_CHANGED', 5, false); event('BAG_UPDATE_DELAYED')
  FLUSH(); frame(); FLUSH(); frame(); FLUSH()
  assert(calls == 0 and not mainTitle(), 'a hidden card must not be rebuilt')
  C_TooltipInfo.GetBagItem = real
end)

check('burst of events is coalesced into one deferred rebuild', function()
  reset(); selectByPad()
  frame(); FLUSH()
  local calls, real = 0, C_TooltipInfo.GetBagItem
  C_TooltipInfo.GetBagItem = function(...) calls = calls + 1; return real(...) end
  equipSwap()
  for _ = 1, 5 do event('ITEM_LOCK_CHANGED', 0, 8) end
  event('PLAYER_EQUIPMENT_CHANGED', 5, false); event('UNIT_INVENTORY_CHANGED', 'player'); event('BAG_UPDATE_DELAYED')
  assert(calls == 0, 'refresh must be deferred, not run inside the event')
  frame(); FLUSH(); frame(); FLUSH()
  assert(calls == 1, 'expected exactly one card rebuild, got ' .. calls)
  C_TooltipInfo.GetBagItem = real
end)

check('combat: refresh only touches the addon card frames (no protected calls)', function()
  reset(); selectByPad()
  COMBAT = true
  equipSwap()
  event('PLAYER_EQUIPMENT_CHANGED', 5, false); event('BAG_UPDATE_DELAYED')
  local ok, err = pcall(function() FLUSH(); frame(); FLUSH(); frame(); FLUSH() end)
  COMBAT = false
  assert(ok, tostring(err))
  assert(mainTitle() == OLD.name, 'card must still refresh in combat')
end)

check('closing the window drops a pending refresh', function()
  reset(); selectByPad()
  equipSwap()
  event('PLAYER_EQUIPMENT_CHANGED', 5, false)
  W.frame:Hide()
  FLUSH(); FLUSH()
  assert(not mainTitle(), 'no card may come back for a closed window')
  W:Open(); FLUSH()
end)

print(('PASS card refresh: %d cases'):format(passed))
