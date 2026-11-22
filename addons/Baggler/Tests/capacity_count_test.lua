-- Run from repository root: luajit addons/Baggler/Tests/capacity_count_test.lua
-- Offline regression for the bag window's free-space / capacity counts (no in-game claim).
--
-- Live report: carried bags full, yet the window said "FREE SPACE 32" and the footer "46/78".
-- 78 - 46 = 32 is exactly an empty keyring: on client 1.60.1.70938 Enum.BagIndex.Keyring = -1
-- (Blizzard_APIDocumentationGenerated/BagIndexConstantsDocumentation.lua) and
-- C_Container.GetContainerNumSlots(KEYRING_CONTAINER) reports the full keyring size, which the
-- native UI itself trims to filled rows (MainMenuBarBagButtons/Camelot GetKeyRingSize).
-- The arithmetic 46 used / 78 total implies the backpack reports 20 slots on that character
-- (20+8+8+6+4 = 46 carried); a 16-slot backpack case is checked too.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end

-- Pinned client enum values (BagIndexConstantsDocumentation.lua, 1.60.1.70938).
Enum.BagIndex.Keyring = -1
Enum.BagIndex.Characterbanktab = -2
Enum.BagIndex.Accountbanktab = -3
C_ActionBar.ShouldShowKeyring = function() return true end

local KEYRING, SKINNING_FAMILY = -1, 32       -- family value is arbitrary non-zero (specialty)
local sizes, contents = STUB_SIZES, STUB_CONTENTS
local families = {}
local nextID = 1000
local function fill(bag, n, first)
  contents[bag] = {}
  for s = first or 1, n do
    nextID = nextID + 1
    contents[bag][s] = { id = nextID, q = 1, name = 'Thing ' .. nextID, class = 7, sub = 0 }
  end
end
local function setup(backpack)
  for k in pairs(sizes) do sizes[k] = nil end
  for k in pairs(contents) do contents[k] = nil end
  for k in pairs(families) do families[k] = nil end
  sizes[0], sizes[1], sizes[2], sizes[3], sizes[4], sizes[5] = backpack, 8, 8, 6, 4, 0
  sizes[KEYRING] = 32                          -- empty keyring, full reported size
  sizes[6] = 28                                -- a bank tab: must never count away from (or at) the bank
  fill(0, backpack); fill(1, 8); fill(2, 8); fill(3, 6); fill(4, 4); fill(6, 28, 29)
  contents[KEYRING] = {}
  families[4] = SKINNING_FAMILY
  families[KEYRING] = 256
end
C_Container.GetContainerNumFreeSlots = function(bag)
  local n = 0
  for s = 1, sizes[bag] or 0 do if not (contents[bag] and contents[bag][s]) then n = n + 1 end end
  return n, families[bag] or 0
end
setup(20)

local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, n, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
local W = CB.Window
CB.db.showFooter = true
CB.db.emptyMode = 'collapse'
W:Open()
local function tick() W.frame.__scripts.OnUpdate(W.frame, 0) end
local function plain(s) return (s or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '') end
local function footer() return plain(W.frame.slotsText:GetText()) end
local function freeHeader()
  for _, h in ipairs(W.headers or {}) do
    if h:IsShown() and h.secName == 'Free Space' then return (plain(h.text:GetText())) end
  end
  return nil
end
local function refresh() W:Refresh() end

-- 1. The user's exact configuration: everything carried is full, the keyring is empty.
refresh()
assert(W.freeCount == 0, 'full carried bags must report 0 free, got ' .. tostring(W.freeCount))
assert(W.totalSlots == 46, 'carried capacity is 20+8+8+6+4=46, got ' .. tostring(W.totalSlots))
assert(footer():match('^46 / 46'), 'footer must read 46 / 46, got "' .. footer() .. '"')
assert(not freeHeader(), 'no Free Space section when nothing general is free, got ' .. tostring(freeHeader()))
local _, empties = CB.Inventory:Scan(W:BagIDs())
for _, e in ipairs(empties) do
  assert(e.bag ~= KEYRING, 'keyring slots are not general free space / drop targets')
end
print('PASS full bags + empty keyring: 0 free, footer 46 / 46 (was FREE SPACE 32, 46 / 78)')

-- Keyring keys still appear as items (only their capacity is excluded).
contents[KEYRING][1] = { id = 4242, q = 1, name = 'Key', class = 13, sub = 0 }
refresh()
local found = false
for _, rec in ipairs((CB.Inventory:Scan(W:BagIDs()))) do if rec.bag == KEYRING then found = true end end
assert(found, 'keys on the keyring are still listed')
assert(W.totalSlots == 46 and footer():match('^46 / 46'), 'a key does not change carried capacity: ' .. footer())
contents[KEYRING][1] = nil
print('PASS keyring items stay visible without inflating capacity')

-- 2. A 16-slot backpack gives 42 carried, never 78/74.
setup(16); refresh()
assert(W.totalSlots == 42 and W.freeCount == 0 and footer():match('^42 / 42'), '16-slot backpack: ' .. footer())
print('PASS 16-slot backpack: 42 / 42')

-- 3. Specialty (skinning) free slots are never mixed into general free space.
setup(20)
contents[4][3], contents[4][4] = nil, nil     -- 2 free in the skinning bag
contents[1][8] = nil                          -- 1 free general slot
refresh()
assert(W.freeCount == 1, 'general free must exclude specialty slots, got ' .. tostring(W.freeCount))
assert(W.specialFree == 2, 'specialty free counted separately, got ' .. tostring(W.specialFree))
assert(W.totalSlots == 46, 'specialty bag capacity is still carried capacity')
assert(footer():match('^43 / 46'), 'used counts every occupied slot, got "' .. footer() .. '"')
assert(footer():lower():find('2 special', 1, true), 'specialty free must be labelled in the footer: ' .. footer())
local hdr = freeHeader()
assert(hdr and hdr:match('FREE SPACE%s+1$'), 'Free Space header counts general slots only, got ' .. tostring(hdr))
_, empties = CB.Inventory:Scan(W:BagIDs())
assert(empties[1] and empties[1].bag == 1 and not empties[1].special, 'first drop target is a general slot')
for _, e in ipairs(empties) do if e.bag == 4 then assert(e.special, 'specialty empties are marked') end end
-- "show" mode lists specialty empties in their own clearly named section
CB.db.emptyMode = 'show'; refresh()
local names = {}
for _, sec in ipairs(W.sections) do names[sec.name] = #sec.items end
assert(names['Free Space'] == 1, 'Free Space lists general empties only, got ' .. tostring(names['Free Space']))
assert(names['Specialty Free'] == 2, 'specialty empties shown separately, got ' .. tostring(names['Specialty Free']))
CB.db.emptyMode = 'collapse'
print('PASS specialty free slots labelled separately, never in FREE SPACE')

-- 4. Bag swap: replace the full 6-slot bag with an empty 10-slot bag; the window follows the events.
setup(20); refresh()
sizes[3] = 10; contents[3] = {}
event('BAG_CONTAINER_UPDATE'); event('BAG_UPDATE', 3); event('BAG_UPDATE_DELAYED'); tick()
assert(W.totalSlots == 50 and W.freeCount == 10, 'after swap: ' .. tostring(W.freeCount) .. '/' .. tostring(W.totalSlots))
assert(footer():match('^40 / 50'), 'after swap footer: ' .. footer())
-- and back: removing the bag drops its capacity at once (no stale cached container)
sizes[3] = 0; contents[3] = {}
event('BAG_CONTAINER_UPDATE'); tick()
assert(W.totalSlots == 40 and W.freeCount == 0, 'after unequip: ' .. tostring(W.freeCount) .. '/' .. tostring(W.totalSlots))
event('PLAYERBANKSLOTS_CHANGED', 1); tick()
assert(W.totalSlots == 40, 'bank slot changes never add bank capacity to the bags window')
print('PASS counts follow BAG_CONTAINER_UPDATE / BAG_UPDATE_DELAYED / PLAYERBANKSLOTS_CHANGED, bank never counted')

print('ALL PASS capacity counts (offline only)')
