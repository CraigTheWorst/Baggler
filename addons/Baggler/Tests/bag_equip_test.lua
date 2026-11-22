-- Run from repository root: luajit addons/Baggler/Tests/bag_equip_test.lua
-- Real menu/use code; native mutation is simulated, NOT an in-game certification.
-- Source contract (Gethe/wow-ui-source, installed 1.60.1.70938):
-- bebcb6bf309cf41b41bd74f8ca651e6a105b2676, Interface/AddOns/
-- Blizzard_MainMenuBarBagButtons/Shared/MainMenuBarBagButtons.lua:69-95,313-327
-- Blizzard_APIDocumentationGenerated/ContainerDocumentation.lua:19-34
-- Blizzard_APIDocumentationGenerated/GameCursorDocumentation.lua:63-72
-- Blizzard_UIPanels_Game/Camelot/BankFrame.lua:312-327,378-394
-- Compared these four files byte-for-byte with the supplied 70862 cache: identical.
-- Bank equipment uses Characterbanktab/Accountbanktab + purchased ordinal, not
-- backpack inventory IDs. Y-menu bank targets are intentionally not guessed here.
local CB = { View = {}, UI = { Money = function() return '0' end }, Inventory = {},
  Categories = {}, Pad = {}, db = { pinTop = {}, favorites = {}, junk = {}, pins = {} },
  COLOR = {}, Menu = {} }
function CB.View:SecureUseRec() return nil end
function CB:RegisterEvent() end
function CB:Print(text) self.message = text end
function CB:Fire() end
function CB:Info() end
function CB:Warn() end
local journal = {}
function CB:Journal(ctx, msg) journal[#journal + 1] = ctx .. ': ' .. tostring(msg) end
local W = setmetatable({ kind = 'bags', frame = {}, opts = { kind = 'bags' } }, { __index = CB.View })
NUM_BAG_SLOTS = 4
local equipped = { [20] = 101, [22] = 103, [23] = 104 }
C_Container = {
  ContainerIDToInventoryID = function(b) return 19 + b end,
  GetContainerNumSlots = function(b) return ({ 16, 0, 12, 8 })[b] end,
  GetContainerNumFreeSlots = function(b) return 0, b == 3 and 32 or 0 end,
  GetBagName = function(b) return 'Bag ' .. b end,
}
function GetInventoryItemID(_, slot) return equipped[slot] end
function GetInventoryItemLink(_, slot) return equipped[slot] and ('item:' .. equipped[slot] .. '[Equipped ' .. slot .. ']') end
function IsInventoryItemLocked() return false end
function InCombatLockdown() return false end
function CursorHasItem() return false end
function GetCursorInfo() return nil end
C_Item = { GetItemInfo = function() return 'Bag', nil, nil, nil, nil, 'Container', 'Herb bag' end }
local entries
function CB.Menu:Open(_, _, list) entries = list end
assert(loadfile('addons/Baggler/WindowUse.lua'))('Baggler', CB)
assert(loadfile('addons/Baggler/WindowMenus.lua'))('Baggler', CB)
local rec = { bag = 0, slot = 1, itemID = 200, equipLoc = 'INVTYPE_BAG', name = 'Red Leather Bag', count = 1 }
local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print('PASS bag equip: ' .. name) end
check('Y menu exposes an exact-slot bag chooser even without another window', function()
  W:ItemMenu({ rec = rec, btn = {} })
  local choice
  for _, e in ipairs(entries) do if e.text == 'Equip bag / Replace bag...' then choice = e end end
  assert(choice and choice.sub, 'bag item is missing explicit Equip bag / Replace bag submenu')
  local slots = choice.sub()
  assert(#slots == 4, 'only the four wearable backpack bag slots belong here')
  assert(slots[1].text:find('16 slots', 1, true) and slots[1].text:find('General', 1, true))
  assert(slots[2].text:find('Empty', 1, true))
  assert(slots[3].text:find('Herb bag', 1, true))
  assert(slots[1].tip:find('16 slots', 1, true) and slots[3].tip:find('Herb bag', 1, true), 'full slot details must remain readable if menu text is clipped')
  assert((slots[1].func or slots[1].sub) and not slots[1].secureUse and slots[2].func, 'slot action must not become generic /use')
end)
local staged
local cursor, sourceItem, calls = nil, rec.itemID, {}
local locked, combat, refusal, sourceBag, sourceSlot = false, false, false, 0, 1
function CursorHasItem() return cursor ~= nil end
function GetCursorInfo()
  if cursor then
    local link = cursor >= 101 and cursor <= 104 and ('item:' .. cursor .. '[Equipped ' .. (cursor - 81) .. ']') or nil
    return 'item', cursor, link
  end
end
function InCombatLockdown() return combat end
function ClearCursor() error('must never clear or discard the cursor') end
function GetInventoryItemID(_, slot) return equipped[slot] end
function IsInventoryItemLocked() return locked == 'target' end
C_Container.GetContainerItemInfo = function(b, s)
  if b == sourceBag and s == sourceSlot and sourceItem then return { itemID = sourceItem, isLocked = locked == 'source' } end
end
C_Container.PickupContainerItem = function(b, s)
  calls[#calls + 1] = { 'pickup', b, s }
  assert(b == sourceBag and s == sourceSlot, 'must not move any bag contents')
  sourceItem, cursor = cursor, sourceItem
end
function PutItemInBag(slot)
  calls[#calls + 1] = { 'put', slot }
  if refusal then return false end
  equipped[slot], cursor = cursor, equipped[slot]
  return true
end
check('chosen empty slot uses native PutItemInBag with exact inventory ID', function()
  assert(W.EquipBagTo, 'missing guarded exact bag equip implementation')
  W:EquipBagTo(rec, 2, { capacity = 0 })
  assert(equipped[21] == rec.itemID and not cursor and sourceItem == nil)
  assert(calls[1][1] == 'pickup' and calls[2][1] == 'put' and calls[2][2] == 21)
end)
local function reset()
  cursor, sourceItem, calls = nil, rec.itemID, {}
  locked, combat, refusal, sourceBag = false, false, false, 0
  equipped[20], equipped[21] = 101, nil
  CB.message = nil
end
check('guards reject occupied cursor, combat, locks, stale and unsafe sources before mutation', function()
  local cases = {
    function() cursor = 999 end,
    function() combat = true end,
    function() locked = 'source' end,
    function() locked = 'target' end,
    function() sourceItem = 999 end,
    function() rec.bag = 1; sourceBag = 1 end, -- source inside replaced bag
    function() rec.bag = 6; sourceBag = 6 end, -- bank access not inferred from bag ID
  }
  for i, setup in ipairs(cases) do
    reset(); rec.bag = 0; setup()
    W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
    assert(#calls == 0, 'unsafe mutation in guard case ' .. i)
    assert(CB.message, 'blocked operations need a clear reason')
  end
  rec.bag = 0; reset()
  W:EquipBagTo(rec, 1, { itemID = 999, capacity = 16 })
  assert(#calls == 0 and CB.message, 'stale destination must be reselected')
  W:EquipBagTo(rec, 0, {})
  assert(#calls == 0, 'backpack cannot be replaced')
  W:EquipBagTo(rec, 5, {})
  assert(#calls == 0, 'reagent/bank slot cannot be guessed')
end)
check('every refusal and the native call are journalled gate by gate', function()
  reset(); rec.bag = 0; journal = {}
  cursor = 999
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  local text = table.concat(journal, '\n')
  assert(text:find('EquipBagTo start', 1, true) and text:find('gate 3 refused', 1, true), text)
  reset(); journal = {}
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  text = table.concat(journal, '\n')
  assert(text:find('calling PutItemInBag(20)', 1, true) and text:find('PutItemInBag(20) pcall=true', 1, true), text)
  assert(text:find('finish:', 1, true), text)
end)
check('pending physical placement blocks native equip without lifting another item', function()
  reset(); W.bagPlacement = true
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  assert(#calls == 0, 'equip must not overlap physical preparation')
  W.bagPlacement = nil
end)
check('replacement returns the native swapped-out bag to the vacated source slot', function()
  reset()
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  assert(equipped[20] == rec.itemID and sourceItem == 101 and not cursor, 'old bag must return without moving its contents')
  assert(#calls == 3 and calls[3][1] == 'pickup')
end)
check('native capacity or specialty refusal restores the new bag and reports refusal', function()
  reset(); refusal = true
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  assert(equipped[20] == 101 and sourceItem == rec.itemID and not cursor)
  assert(CB.message and CB.message:find('refused', 1, true), 'native refusal must be visible')
end)
check('plain bag equip always chooses a slot regardless of ring preference', function()
  reset(); CB.db.askEquipSlot = false
  assert(W:NeedsSlotChoice(rec), 'bags must never take blind AutoEquipCursorItem path')
  W:Equip(rec, {})
  assert(#entries == 4 and #calls == 0, 'Equip bag must only open a chooser')
  W:UseItem(rec)
  assert(#entries == 4 and #calls == 0, 'plain bag Use must only open a chooser')
  W:EquipTo(rec, 20)
  assert(#entries == 4 and #calls == 0, 'legacy generic EquipTo must not bypass bag guards')
  W:ItemMenu({ rec = rec, btn = {} })
  for _, e in ipairs(entries) do
    assert(e.text ~= 'Use' and not e.secureUse, 'plain bag menu must not retain generic /use')
  end
  CB.db.askEquipSlot = nil
end)
check('replacement requires explicit capacity warning confirmation and supports cancel', function()
  reset()
  local slots = W:BagEquipEntries(rec)
  assert(slots[1].sub and not slots[1].func, 'an occupied slot confirms through a nested menu, not a second popup')
  local confirm = slots[1].sub()
  assert(#calls == 0 and confirm[1].text:find('Replace', 1, true), 'replacement needs explicit consent')
  confirm[2].func()
  assert(#calls == 0, 'cancel must not pick up or equip')
  confirm[1].func()
  assert(equipped[20] == rec.itemID and sourceItem == 101)
end)
check('cursor anomalies and native API errors are preserved without deleting or blind retry', function()
  reset()
  local pickup, put = C_Container.PickupContainerItem, PutItemInBag
  PutItemInBag = function() error('blocked native call') end
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  assert(sourceItem == rec.itemID and not cursor and CB.message:find('refused', 1, true))
  reset()
  C_Container.PickupContainerItem = function() cursor = 999 end
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  assert(cursor == 999 and #calls == 0 and CB.message, 'unexpected cursor must remain untouched')
  C_Container.PickupContainerItem, PutItemInBag = pickup, put
  reset()
  PutItemInBag = function() cursor = 999; sourceItem = 888 end
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  assert(cursor == 999 and sourceItem == 888 and #calls == 1, 'do not overwrite an occupied origin or unknown cursor')
  PutItemInBag = put
end)
check('spell targeting and malformed source coordinates never mutate inventory', function()
  reset()
  SpellIsTargeting = function() return true end
  W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
  assert(#calls == 0 and CB.message, 'active spell targeting must not be overwritten')
  SpellIsTargeting = nil
  for _, slot in ipairs({ 0, -1, 1.5, '1' }) do
    reset(); rec.slot = slot
    W:EquipBagTo(rec, 1, { itemID = 101, capacity = 16 })
    assert(#calls == 0 and CB.message, 'invalid source coordinates must be rejected')
  end
  rec.slot = 1
end)
-- ---- source inside the replaced bag (live case: src 3/3 in bag 3): explicit one-bag staging step ----
local savedAPI = {}
for k, v in pairs(C_Container) do savedAPI[k] = v end
local function stageSetup(free)
  reset(); rec.bag = 3; rec.slot = 3; sourceBag, sourceSlot = 3, 3
  equipped[22] = 103
  local occupied = { ['0:1'] = true, ['0:2'] = true }
  if free == 'none' then for s = 1, 16 do occupied['0:' .. s] = true end end
  C_Container.GetContainerNumFreeSlots = function(b)
    if b == 0 then return free == 'none' and 0 or 4, 0 end
    return 0, b == 3 and 32 or 0
  end
  C_Container.GetContainerNumSlots = function(b) return ({ [0] = 16, 16, 0, 12, 8 })[b] end
  local placed
  C_Container.GetContainerItemInfo = function(b, s)
    if placed and b == placed.bag and s == placed.slot then return { itemID = placed.itemID, stackCount = 1 } end
    if b == 3 and s == 3 and sourceItem then return { itemID = sourceItem, isLocked = locked == 'source' } end
    if occupied[b .. ':' .. s] then return { itemID = 5 } end
  end
  C_Container.PickupContainerItem = function(b, s)
    calls[#calls + 1] = { 'pickup', b, s }
    if not cursor and b == 3 and s == 3 then cursor, sourceItem = sourceItem, nil
    elseif cursor and b == 0 and not occupied[b .. ':' .. s] then
      placed = { bag = b, slot = s, itemID = cursor }; cursor = nil; staged = { b, s }
    end
  end
end
check('source inside target is refused by gate 8 with an explanatory message, no mutation', function()
  stageSetup(); W:EquipBagTo(rec, 3, { itemID = 103, capacity = 12 })
  assert(#calls == 0 and CB.message:find('inside', 1, true))
  assert(CB.message:find('Prepare replacement', 1, true) and not CB.message:find('Move the new bag out', 1, true),
    'gate 8 must name the current Prepare replacement step: ' .. CB.message)
end)
check('chooser offers a one-bag move for the target that holds the new bag', function()
  stageSetup()
  local slots = W:BagEquipEntries(rec)
  assert(slots[3].text:find('holds the new bag', 1, true) and slots[3].sub and not slots[3].disabled)
  local prep = slots[3].sub()
  assert(#prep == 2 and prep[1].text:find('Pick up Red Leather Bag', 1, true), 'hand pickup first: ' .. prep[1].text)
  assert(prep[2].sub()[1].text:find('Backpack', 1, true), 'automatic move prefers the free Backpack slot')
  assert(#calls == 0, 'building the menu must not move anything')
end)
check('staging moves exactly the one bag to the first free backpack slot, never replacing', function()
  stageSetup(); staged = nil
  W:StageBagOut(rec, 3)
  assert(#calls == 2 and calls[1][2] == 3 and calls[2][2] == 0 and calls[2][3] == 3, 'one pickup, one drop at 0/3')
  assert(not cursor and staged and CB.message:find('Replace again', 1, true))
  for _, c in ipairs(calls) do assert(c[1] == 'pickup') end -- PutItemInBag never called
end)
check('staging refuses without free general slot, in combat, with cursor, locked or stale', function()
  local cases = {
    function() stageSetup('none') end,
    function() stageSetup(); combat = true end,
    function() stageSetup(); cursor = 999 end,
    function() stageSetup(); locked = 'source' end,
    function() stageSetup(); sourceItem = 999 end,
  }
  for i, setup in ipairs(cases) do
    setup(); calls = {}; CB.message = nil
    W:StageBagOut(rec, 3)
    assert(#calls == 0 and CB.message, 'staging mutated in case ' .. i)
  end
  stageSetup('none')
  local slots = W:BagEquipEntries(rec)
  assert(slots[3].sub and not slots[3].disabled, 'no free slot: offer explicit occupied-slot exchange')
  combat = false
end)
check('staging leaves an unexpectedly held bag on the cursor, no ClearCursor', function()
  stageSetup()
  local pick = C_Container.PickupContainerItem
  C_Container.PickupContainerItem = function(b, s)
    calls[#calls + 1] = { 'pickup', b, s }
    if not cursor and b == 3 then cursor, sourceItem = sourceItem, nil end -- drop does nothing
  end
  W:StageBagOut(rec, 3)
  assert(cursor == rec.itemID and CB.message:find('cursor', 1, true))
  C_Container.PickupContainerItem = pick
end)
check('free-slot preparation does not infer delivery from a vanished cursor', function()
  stageSetup()
  local pickup = C_Container.PickupContainerItem
  C_Container.PickupContainerItem = function(b, s)
    if b == 3 then pickup(b, s)
    else calls[#calls + 1] = { 'pickup', b, s }; cursor = nil end
  end
  W:StageBagOut(rec, 3)
  assert(#calls == 2 and CB.message:find("couldn't confirm", 1, true), 'vanished cursor is not placement proof')
end)
check('free-slot preparation revalidates combat and destination after pickup', function()
  for _, mode in ipairs({ 'combat', 'occupied destination', 'changed container' }) do
    stageSetup()
    local pickup = C_Container.PickupContainerItem
    C_Container.PickupContainerItem = function(b, s)
      pickup(b, s)
      if #calls == 1 then
        if mode == 'combat' then combat = true
        elseif mode == 'changed container' then equipped[22] = 999
        else
          local info = C_Container.GetContainerItemInfo
          C_Container.GetContainerItemInfo = function(db, ds)
            if db == 0 and ds == 3 then return { itemID = 999 } end
            return info(db, ds)
          end
        end
      end
    end
    W:StageBagOut(rec, 3)
    assert(#calls == 1 and cursor == rec.itemID, 'unsafe second staging move: ' .. mode)
  end
  combat = false
end)
for k, v in pairs(savedAPI) do C_Container[k] = v end
rec.bag, rec.slot, sourceBag, sourceSlot = 0, 1, 0, 1
equipped[22] = 103
print(('PASS bag equip: %d cases'):format(passed))

-- Exercise the shipped menu and controller broker, not just callback tables.
local api, globals, itemInfo = C_Container, {}, C_Item.GetItemInfo
for _, name in ipairs({ 'CursorHasItem', 'GetCursorInfo', 'GetInventoryItemID', 'GetInventoryItemLink',
  'IsInventoryItemLocked', 'InCombatLockdown', 'ClearCursor', 'PutItemInBag' }) do globals[name] = _G[name] end
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
local Live = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', Live) end
end
local function event(name, ...) Live.eventFrame.__scripts.OnEvent(Live.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
for name, fn in pairs(globals) do _G[name] = fn end
for name, fn in pairs(api) do C_Container[name] = fn end
C_Item.GetItemInfo = itemInfo
local function menuIndex(label)
  for i, e in ipairs(Live.Menu.entries) do if e.text == label then return i end end
  error('missing live menu entry: ' .. label)
end
reset()
Live.Window:ItemMenu({ rec = rec, btn = Live.Window.frame })
Live.Menu:Select(menuIndex('Equip bag / Replace bag...'))
Live.Menu.ctx.OnPad(nil, 'use')
assert(#Live.Menu.entries == 4)
Live.Menu.ctx.OnPad(nil, 'down') -- empty bag slot 2
Live.Menu.ctx.OnPad(nil, 'use')
assert(equipped[21] == rec.itemID and not cursor, 'real controller menu must equip the selected empty slot')
print('PASS bag equip: shipping Menu controller activation chooses exact slot 2')
reset()
Live.Window:ItemMenu({ rec = rec, btn = Live.Window.frame })
local frame = _G.BagglerMenu
local function click(i) local row = frame.rows[i]; row:GetScript('OnClick')(row) end
click(menuIndex('Equip bag / Replace bag...'))
click(1) -- occupied slot opens replacement confirmation
assert(#calls == 0 and Live.Menu.entries[1].text:find('Replace', 1, true))
click(1)
assert(equipped[20] == rec.itemID and sourceItem == 101 and not cursor, 'real mouse menu must replace exactly slot 1')
print('PASS bag equip: shipping Menu mouse activation confirms replacement of exact slot 1')
