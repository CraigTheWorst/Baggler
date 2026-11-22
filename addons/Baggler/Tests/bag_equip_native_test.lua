-- Run from repository root: luajit addons/Baggler/Tests/bag_equip_native_test.lua
-- Drives the SHIPPED TOC and menu (mouse path: Y menu -> exact target -> confirm -> Replace) against a fake that
-- explores delayed server acceptance after a synchronously vacated pickup origin. An origin still shown occupied
-- after pickup is deliberately rejected before PutItemInBag. pump() models a later answer; refusal can expose
-- a locked occupied origin again. These are safety hypotheses, NOT a documented native contract or live proof.
-- Native contract: Blizzard_MainMenuBarBagButtons/Shared/MainMenuBarBagButtons.lua (PutItemInBag(inventoryID),
-- its return is used as truthiness to decide whether to toggle the bag, NOT proof of server acceptance).
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
NUM_BAG_SLOTS = 4
DEFER = true                       -- timers wait for FLUSH(), as in the game

-- ---- fake inventory ---------------------------------------------------------------------------------------------
local equipped, caps, bags, cursor, locked, pending, calls
local function reset()
  equipped = { [20] = 101, [21] = 102, [22] = 103, [23] = 104 }          -- inventory slot -> bag item
  caps = { [0] = 16, 8, 8, 6, 4 }                                          -- container id -> capacity
  bags = { [0] = { [1] = { itemID = 200, hyperlink = '|cffffffff|Hitem:200|h[Big Bag]|h|r' } } }
  cursor, locked, pending, calls = nil, {}, nil, {}
end
reset()
local NEW = 200
local ERR
C_Container = {
  ContainerIDToInventoryID = function(b) return 19 + b end,
  GetContainerNumSlots = function(b) return caps[b] or 0 end,
  GetContainerNumFreeSlots = function(b) return 0, 0 end,
  GetBagName = function(b) return 'Bag ' .. b end,
  GetContainerItemInfo = function(b, s)
    local it = bags[b] and bags[b][s]
    if it then return { itemID = it.itemID, hyperlink = it.hyperlink, isLocked = locked[b .. ':' .. s] or false } end
  end,
  PickupContainerItem = function(b, s)
    calls[#calls + 1] = 'pickup ' .. b .. ':' .. s
    local it = bags[b] and bags[b][s]
    if not cursor and it and not locked[b .. ':' .. s] then
      cursor = { itemID = it.itemID, from = b .. ':' .. s, original = it }
      bags[b][s] = nil
    elseif cursor then
      local key = b .. ':' .. s
      if cursor.from == key then bags[b][s] = cursor.original; locked[key] = nil; cursor = nil
      elseif not it then
        bags[b] = bags[b] or {}
        bags[b][s] = { itemID = cursor.itemID, hyperlink = '|Hitem:' .. cursor.itemID .. '|h[Old]|h' }
        cursor = nil
      end
    end
  end,
}
C_Item = {
  GetItemInfo = function() return 'x', nil, nil, nil, nil, 'Container', 'Bag' end,
  GetItemInfoInstant = function(id) return id, 'Container', 'Bag', id == NEW and 'INVTYPE_BAG' or '', 1, 1, 0 end,
}
function GetInventoryItemID(_, slot) return equipped[slot] end
function GetInventoryItemLink(_, slot)
  if equipped[slot] == NEW then return '|cffffffff|Hitem:200|h[Big Bag]|h|r' end
  return equipped[slot] and ('|Hitem:' .. equipped[slot] .. '|h[Equipped ' .. equipped[slot] .. ']|h')
end
function IsInventoryItemLocked() return false end
function InCombatLockdown() return false end
function CursorHasItem() return cursor ~= nil end
function GetCursorInfo()
  if cursor then
    local link = cursor.itemID == NEW and '|cffffffff|Hitem:200|h[Big Bag]|h|r'
      or ('|Hitem:' .. cursor.itemID .. '|h[Equipped ' .. cursor.itemID .. ']|h')
    return 'item', cursor.itemID, link
  end
end
function ClearCursor() error('must never clear the cursor') end
local serverMode = 'accept'
function PutItemInBag(slot)
  calls[#calls + 1] = 'put ' .. slot
  if not cursor then return false end
  pending = { slot = slot, item = cursor }
  if serverMode == 'refuse' then
    local b, s = cursor.from:match('(%d+):(%d+)')
    bags[tonumber(b)][tonumber(s)] = cursor.original
    locked[cursor.from] = true
  end
  return true                                                              -- asked, not yet done
end
-- the server's answer
local function pump()
  if not pending then return end
  local p = pending; pending = nil
  if serverMode == 'accept' then
    local old = equipped[p.slot]
    equipped[p.slot] = p.item.itemID
    local b, s = p.item.from:match('(%d+):(%d+)')
    bags[tonumber(b)][tonumber(s)] = nil; locked[p.item.from] = nil
    caps[p.slot - 19] = 12                                                  -- the new bag's real size
    cursor = old and { itemID = old, from = 'equip' } or nil
  else
    ERR = ERR or function() end
    ERR('Bag is full: the contents would not fit')
  end
end
local function settle() for _ = 1, 30 do pump(); FLUSH() end end

-- ---- load the shipped add-on --------------------------------------------------------------------------------------
local Live = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', Live) end
end
local function event(name, ...) Live.eventFrame.__scripts.OnEvent(Live.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
ERR = function(msg) event('UI_ERROR_MESSAGE', 50, msg) end
local printed = {}
function Live:Print(...) printed[#printed + 1] = table.concat({ ... }, ' ') end
local function last() return printed[#printed] or '' end

local rec = { bag = 0, slot = 1, itemID = NEW, equipLoc = 'INVTYPE_BAG', name = 'Big Bag', count = 1,
  link = '|cffffffff|Hitem:200|h[Big Bag]|h|r' }
local W = Live.Window
local frame = _G.BagglerMenu
local function menuIndex(label)
  for i, e in ipairs(Live.Menu.entries) do if e.text:find(label, 1, true) then return i end end
  error('missing menu entry: ' .. label .. ' (have ' .. (Live.Menu.entries[1] and Live.Menu.entries[1].text or 'none') .. ')')
end
local function click(i) local row = _G.BagglerMenu.rows[i]; row:GetScript('OnClick')(row) end
local passed = 0
local function check(name, fn) reset(); printed = {}; serverMode = 'accept'; fn(); passed = passed + 1; print('PASS native bag equip: ' .. name) end

local function openChooser()
  W:ItemMenu({ rec = rec, btn = W.frame })
  click(menuIndex('Equip bag / Replace bag'))
end

check('delayed combat answer never performs automatic item operations', function()
  openChooser(); click(3); click(1)
  local n = #calls
  InCombatLockdown = function() return true end
  settle()
  InCombatLockdown = function() return false end
  assert(#calls == n, 'timer must not pick up items during combat')
  assert(cursor and cursor.itemID == 103, 'leave replaced bag for player')
end)

check('unrelated global error must not end a pending transaction or touch its cursor', function()
  openChooser(); click(3); click(1)
  local n = #calls
  ERR('That spell is not ready yet')
  FLUSH()
  assert(W.bagSwap, 'unrelated UI error ended pending swap')
  assert(#calls == n, 'unrelated UI error moved cursor')
  settle()
end)

check('refusal cannot click an occupied locked origin', function()
  serverMode = 'refuse'
  openChooser(); click(3); click(1)
  local n = #calls
  settle()
  assert(#calls == n and cursor and cursor.itemID == NEW, 'occupied origin was clicked')
  assert(not last():find('bag swapped', 1, true), 'must not announce a swap')
end)

check('pending records are immutable and unknown same-ID user cursors remain untouched', function()
  local r = {}; for k, v in pairs(rec) do r[k] = v end
  W:EquipBagTo(r, 3, { itemID = 103, capacity = 6 })
  r.bag, r.slot, r.itemID, r.name = 6, 9, 999, 'Mutated' -- refreshed account/bank record
  local n = #calls
  pump()
  -- Cannot infer instance identity from itemID alone after the hardware callback ends.
  cursor = { itemID = 103, from = 'user' }
  FLUSH()
  assert(#calls == n and cursor and cursor.from == 'user', 'timer moved a user cursor')
  assert(not W.bagSwap and not last():find('Mutated', 1, true), 'pending record was mutated')
end)

check('same-ID worn target is not mistaken for completed replacement', function()
  equipped[22] = NEW
  openChooser(); click(3); click(1)
  assert(#calls == 0 and not W.bagSwap, 'ambiguous identical bag must require reselection without pickup')
end)

check('source container replacement during delay is not treated as success', function()
  local r = {}; for k, v in pairs(rec) do r[k] = v end
  r.bag = 1; bags[1] = { [1] = bags[0][1] }; bags[0][1] = nil
  W:EquipBagTo(r, 3, { itemID = 103, capacity = 6 })
  local n = #calls
  equipped[20] = 999 -- another action changed the source container
  settle()
  assert(#calls == n and cursor and cursor.itemID == 103, 'changed source received an item')
  assert(last():find("couldn't confirm", 1, true) and not W.bagSwap, 'unverified source must not claim success')
end)

check('zero cursor and stale callbacks cannot clear a newer pending transaction', function()
  openChooser(); click(3); click(1)
  local first = W.bagSwap
  cursor, pending = nil, nil
  for _ = 1, 30 do FLUSH() end
  assert(not W.bagSwap and last():find("couldn't confirm", 1, true), 'zero cursor must time out without invented success/refusal')
  reset()
  openChooser(); click(2); click(1)
  local current, n = W.bagSwap, #calls
  W:BagSwapSettle(first); W:BagSwapFinish(first, 'refused')
  assert(W.bagSwap == current and #calls == n, 'stale callbacks affected newer swap')
  settle()
end)

check('nil native return is observed, not assumed accepted or refused', function()
  local real = PutItemInBag
  PutItemInBag = function(slot) real(slot); return nil end
  openChooser(); click(3); click(1)
  PutItemInBag = real
  assert(W.bagSwap and #printed == 0, 'nil return is not a verdict')
  settle()
  assert(equipped[22] == NEW and not W.bagSwap)
end)

check('menu -> exact target -> confirm -> Replace swaps once the game answers, and says so', function()
  openChooser()
  assert(#Live.Menu.entries == 4, 'chooser lists the four wearable slots')
  click(3)                                                     -- Bag 3 (occupied)
  assert(#calls == 0, 'confirming never touches the cursor')
  assert(Live.Menu.entries[1].text:find('Replace', 1, true) and #Live.Menu.stack == 2, 'confirm is a nested menu (B goes back)')
  click(1)
  assert(calls[1] == 'pickup 0:1' and calls[2] == 'put 22', 'exact native slot (inventory id of bag 3)')
  assert(equipped[22] == 103, 'the swap has not happened until the server answers; nothing is judged yet')
  assert(#printed == 0, 'no verdict before the answer')
  settle()
  assert(equipped[22] == NEW, 'new bag worn')
  assert(not bags[0][1] and cursor and cursor.itemID == 103, 'delayed cursor left for player; timer cannot establish ownership')
  assert(last():find('12 slots', 1, true) and last():find('was 6', 1, true), 'real capacity read from the game: ' .. last())
end)

check('modeled server refusal leaves locked origin/cursor untouched and does not claim success', function()
  serverMode = 'refuse'
  openChooser(); click(3); click(1)
  settle()
  assert(equipped[22] == 103, 'old bag still worn')
  assert(bags[0][1].itemID == NEW and cursor and locked['0:1'], 'locked occupied origin must remain untouched')
  assert(last():find("couldn't confirm", 1, true), 'global error is not attributed to transaction: ' .. last())
end)

check('PutItemInBag returning false is an immediate, explained refusal', function()
  local real = PutItemInBag
  PutItemInBag = function(slot)
    calls[#calls + 1] = 'put ' .. slot
    bags[0][1] = cursor.original; locked['0:1'] = true
    return false
  end
  openChooser(); click(3); click(1)
  FLUSH()
  PutItemInBag = real
  assert(bags[0][1].itemID == NEW and cursor, 'occupied locked origin not clicked even on false return')
  assert(last():find('refused', 1, true), last())
end)

check('live Woolen Bag empty bag 1 repro tolerates zero native inventory returns', function()
  local getID, getLink, getCursor, toInventory, journal = GetInventoryItemID, GetInventoryItemLink, GetCursorInfo,
    C_Container.ContainerIDToInventoryID, Live.Journal
  local oldNew = NEW
  NEW = 4240
  local link = '|cffffffff|Hitem:4240|h[Woolen Bag]|h|r'
  local source = { bag = 0, slot = 2, itemID = NEW, count = 1, equipLoc = 'INVTYPE_BAG', name = 'Woolen Bag', link = link }
  bags[0] = { [2] = { itemID = NEW, hyperlink = link } }
  equipped[31], caps[1] = nil, 0
  C_Container.ContainerIDToInventoryID = function(b) if b == 1 then return 31 end; return toInventory(b) end
  GetInventoryItemID = function(unit, inv)
    if inv == 31 and not equipped[inv] then return end -- ZERO values, not `return nil`
    return getID(unit, inv)
  end
  GetCursorInfo = function() if cursor then return 'item', cursor.itemID, link end end
  GetInventoryItemLink = function(unit, inv) if inv == 31 then return equipped[inv] and link end; return getLink(unit, inv) end
  local log = {}
  Live.Journal = function(self, ctx, msg) log[#log + 1] = msg; return journal(self, ctx, msg) end
  local ok, err = pcall(function()
    W:EquipBagTo(source, 1, { capacity = 0 })
    assert(table.concat(calls, ',') == 'pickup 0:2,put 31', 'must reach normal empty-target native equip')
    assert(W.bagSwap and W.bagSwap.rec.name == 'Woolen Bag', 'source label must survive snapshot')
    pump(); caps[1] = 12; FLUSH()
    assert(equipped[31] == NEW and not cursor and not W.bagSwap, 'empty slot equip must settle normally')
    assert(last():find('Woolen Bag', 1, true), 'completion must name the source bag: ' .. last())
    assert(table.concat(log, '\n'):find('equipped target: id=nil', 1, true), 'empty target must be logged as nil')
  end)
  GetInventoryItemID, GetInventoryItemLink, GetCursorInfo, C_Container.ContainerIDToInventoryID, Live.Journal = getID, getLink, getCursor, toInventory, journal
  NEW = oldNew
  assert(ok, 'live zero-return empty target repro: ' .. tostring(err))
end)

-- A native `return` supplies zero arguments to tostring unless the call is scalarized.
-- Exercise logging at preflight, census, and timeout, not just the happy-path empty ID.
local zeroReturnFailures = {}
for _, phase in ipairs({ 'preflight capacity', 'census capacity', 'finish inventory ID' }) do
  local ok, err = pcall(function()
    check('logging tolerates no-return client getter: ' .. phase, function()
      local getSlots, getID = C_Container.GetContainerNumSlots, GetInventoryItemID
      local ran, failure = pcall(function()
        if phase == 'preflight capacity' then
          C_Container.GetContainerNumSlots = function(b) if b == 3 then return end; return getSlots(b) end
          W:EquipBagTo(rec, 3, { itemID = 103, capacity = 6 })
          assert(#calls == 0 and last():find('changed', 1, true), 'unknown capacity must fail closed without pickup')
        elseif phase == 'census capacity' then
          C_Container.GetContainerNumSlots = function(b) if b == 4 then return end; return getSlots(b) end
          local entries = W:PrepareBagReplacementEntries(rec, 3, { itemID = 103, capacity = 6 })
          assert(entries[1] and #calls == 0, 'census must remain observational')
        else
          equipped[21], caps[2] = nil, 0
          GetInventoryItemID = function(unit, inv) if inv == 21 then return end; return getID(unit, inv) end
          W:EquipBagTo(rec, 2, { capacity = 0 })
          assert(W.bagSwap and calls[2] == 'put 21', 'must reach pending equip')
          pending, cursor = nil, nil -- no server acceptance; empty target times out
          for _ = 1, 30 do FLUSH() end
          assert(not W.bagSwap and last():find("couldn't confirm", 1, true), 'timeout must report uncertainty normally')
        end
      end)
      C_Container.GetContainerNumSlots, GetInventoryItemID = getSlots, getID
      W.bagSwap = nil
      assert(ran, failure)
    end)
  end)
  if not ok then zeroReturnFailures[#zeroReturnFailures + 1] = phase .. ': ' .. tostring(err) end
end
assert(#zeroReturnFailures == 0, table.concat(zeroReturnFailures, '\n'))

check('empty target slot equips directly (no confirm) and finishes after the answer', function()
  equipped[21] = nil; caps[2] = 0
  openChooser(); click(2)
  assert(calls[2] == 'put 21')
  settle()
  assert(equipped[21] == NEW and not cursor, 'worn, cursor clear')
  assert(last():find('12 slots', 1, true), last())
end)

check('a second attempt while one is pending is refused, not stacked', function()
  openChooser(); click(3); click(1)
  local n = #calls
  W:EquipBagTo(rec, 2, { itemID = 102, capacity = 8 })
  assert(#calls == n, 'no extra native calls while pending')
  settle()
end)

-- ---- placement and tooltips -----------------------------------------------------------------------------------------
check('Menu.Position keeps menus on screen and off their anchor', function()
  local M = Live.Menu
  local sw, sh = 1920, 1080
  local function inside(x, top, w, h) return x >= 0 and x + w <= sw and top <= sh and top - h >= 0 end
  -- anchor in the bottom-right corner (the screenshot case): must not run off right or bottom
  local a = { left = 1800, right = 1840, top = 120, bottom = 80 }
  local x, top = M.Position(a, 300, 160, sw, sh)
  assert(inside(x, top, 300, 160), 'bottom-right anchor stays on screen')
  assert(x + 300 <= a.left or x >= a.right or top <= a.bottom or top - 160 >= a.top, 'does not cover its anchor when room exists')
  -- roomy anchor: opens beside it
  x, top = M.Position({ left = 500, right = 540, top = 600, bottom = 560 }, 300, 160, sw, sh)
  assert(x == 544 and top == 600)
  -- a big window as anchor (window menu): inside its top-right, not off its bottom-right corner
  x, top = M.Position({ left = 100, right = 900, top = 900, bottom = 100 }, 300, 160, sw, sh)
  assert(inside(x, top, 300, 160))
  -- nothing fits (tiny screen): pulled in, never outside
  x, top = M.Position({ left = 10, right = 50, top = 60, bottom = 20 }, 300, 160, 320, 200)
  assert(inside(x, top, 300, 160) or x >= 0, 'clamped')
end)

check('the live menu opens inside the screen for an anchor at the screen corner, and confirm stays at the chooser', function()
  local pts = {}
  local anchor = { GetCenter = function() return 1810, 100 end, GetEffectiveScale = function() return 1 end,
    GetLeft = function() return 1800 end, GetRight = function() return 1840 end, GetTop = function() return 120 end,
    GetBottom = function() return 80 end }
  frame = _G.BagglerMenu or frame
  Live.Menu:Open(anchor, 'Probe', { { text = 'One', func = function() end }, { text = 'Two', func = function() end } })
  frame = _G.BagglerMenu
  local orig = frame.SetPoint
  frame.SetPoint = function(self, p, rel, rp, x, y) pts[#pts + 1] = { p, rel, rp, x, y }; return orig(self, p, rel, rp, x, y) end
  Live.Menu:Open(anchor, 'Probe', { { text = 'One', func = function() end }, { text = 'Two', func = function() end } })
  local p = pts[#pts]
  assert(p[1] == 'TOPLEFT' and p[2] == UIParent and p[3] == 'BOTTOMLEFT', 'anchored to the screen, not to a hidden row or the footer')
  assert(p[4] >= 0 and p[4] + frame:GetWidth() <= 1920 and p[5] <= 1080 and p[5] - frame:GetHeight() >= 0, 'fully on screen')
  frame.SetPoint = orig
  Live.Menu:Close()
end)

check('tooltips and cards are gone when the menu closes or changes level', function()
  openChooser()
  Live.Menu:Select(3)                                           -- row tip shows
  local tip = _G.BagglerTip
  assert(tip:IsShown(), 'row tip shown while highlighted')
  click(3)                                                      -- into the confirm level
  Live.Menu:Select(1)
  assert(tip:IsShown())
  click(1)                                                      -- Replace
  assert(not tip:IsShown(), 'no tooltip left after the popup closes')
  settle()
  -- watchdog: an owner that is gone takes its tooltip with it, even if nobody called HideTip
  tip:SetOwner(frame, 'ANCHOR_RIGHT'); tip:SetText('stale', 1, 1, 1); tip:Show()
  frame:Hide(); tip.__shown = true
  tip.__scripts.OnUpdate(tip)
  assert(not tip:IsShown(), 'tooltip follows its owner')
end)

check('tip side is chosen so it never lies over the menu rows', function()
  local r = { left = 1500, right = 1700 }
  Live.Menu:Open({ GetCenter = function() return 0, 0 end, GetEffectiveScale = function() return 1 end,
    GetLeft = function() return 100 end, GetRight = function() return 140 end, GetTop = function() return 500 end, GetBottom = function() return 460 end },
    'x', { { text = 'a', func = function() end } })
  local side = Live.Menu:TipAnchor()
  assert(side == 'BESIDE_RIGHT' or side == 'BESIDE_LEFT' or side == 'ANCHOR_TOP' or side == 'ANCHOR_BOTTOM', tostring(side))
  Live.Menu:Close()
end)

-- Full inventory: the new Feed Pouch is inside the Linen Bag selected for replacement.
-- A synchronous native pickup model; this is offline safety coverage, not server timing proof.
local fullRec = { bag = 3, slot = 3, itemID = NEW, count = 1, equipLoc = 'INVTYPE_BAG',
  name = 'Feed Pouch', link = '|Hitem:200|h[Feed Pouch]|h' }
local function fullSetup()
  reset(); W.bagSwap = nil
  for b = 0, 4 do
    bags[b] = {}
    for s = 1, caps[b] do bags[b][s] = { itemID = 300, stackCount = 2, hyperlink = '|Hitem:300|h[Linen Cloth]|h' } end
  end
  bags[3][3] = { itemID = NEW, stackCount = 1, hyperlink = fullRec.link }
  C_Container.GetContainerItemInfo = function(b, s)
    local it = bags[b] and bags[b][s]
    if it then return { itemID = it.itemID, stackCount = it.stackCount, hyperlink = it.hyperlink, isLocked = locked[b .. ':' .. s] or false } end
  end
  GetCursorInfo = function() if cursor then return cursor.type or 'item', cursor.itemID, cursor.hyperlink end end
  C_Container.PickupContainerItem = function(b, s)
    calls[#calls + 1] = 'pickup ' .. b .. ':' .. s
    bags[b][s], cursor = cursor, bags[b][s]
  end
  -- item class: the new bag and other bags are Containers (1); quest items 12; cloth Tradeskill (7)
  C_Item.GetItemInfoInstant = function(id)
    local class = (id == NEW or (id >= 100 and id < 200) or id == 400) and 1 or id == 500 and 12 or 7
    return id, 'x', 'y', class == 1 and 'INVTYPE_BAG' or '', 1, class, 0
  end
  C_Container.GetContainerItemQuestInfo = function(b, s)
    local it = bags[b] and bags[b][s]
    return { isQuestItem = it and it.quest or false }
  end
end
local function fullConfirm(pad)
  W:Create()
  W.selKey = '3:3'
  W:ItemMenu({ rec = fullRec, btn = W.frame })
  local function activate(i)
    if pad then Live.Menu:Select(i); Live.Menu.ctx.OnPad(nil, 'use') else click(i) end
  end
  activate(menuIndex('Equip bag / Replace bag')); activate(3)
  -- at most two entries, never a list: hand pickup first, one automatic swap second
  local top = Live.Menu.entries
  assert(#top == 2, 'replace on a target holding the new bag offers two entries, got ' .. #top)
  assert(top[1].text == 'Pick up Feed Pouch \226\128\148 place it on any item outside Bag 3' and top[1].func and not top[1].sub, top[1].text)
  assert(top[2].text == 'Swap automatically...' and top[2].sub, tostring(top[2].text))
  for _, row in ipairs(top) do assert(not row.text:find('Other', 1, true) and not row.text:find('alternatives', 1, true)) end
  activate(2)
  -- ONE confirmation naming exactly what happens; no list of bag items, no further level
  local e = Live.Menu.entries
  assert(#e == 3, 'confirmation is action + note + cancel, got ' .. #e)
  assert(e[1].text == 'Move Feed Pouch out of Bag 3 by swapping it with Linen Cloth (Backpack)', e[1].text)
  assert(e[2].disabled and e[2].text == 'Then press Continue to replace Bag 3.', tostring(e[2].text))
  assert(e[3].text == 'Cancel')
  for _, row in ipairs(e) do assert(not row.sub, 'default path must not open any list: ' .. row.text) end
  assert(e[1].tip:find('Feed Pouch', 1, true) and e[1].tip:find('Linen Cloth', 1, true)
    and e[1].tip:find('slot 3', 1, true) and e[1].tip:find('Backpack, slot 1', 1, true), 'tip names both items and slots: ' .. e[1].tip)
  assert(#calls == 0, 'opening the confirmation must not move either item')
  return function() activate(1) end
end
for _, pad in ipairs({ false, true }) do
  check('full inventory explicit exchange via ' .. (pad and 'controller' or 'mouse'), function()
    fullSetup(); fullConfirm(pad)()
    assert(table.concat(calls, ',') == 'pickup 3:3,pickup 0:1,pickup 3:3', 'only the two explicitly selected items move')
    assert(not cursor and bags[0][1].itemID == NEW and bags[3][3].itemID == 300)
    assert(equipped[22] == 103 and not W.bagSwap, 'preparation must never equip or silently choose a different target')
    assert(last():find('press Continue to replace Bag 3', 1, true), last())
  end)
end
local originalInventoryLink = GetInventoryItemLink
GetInventoryItemLink = function(unit, slot)
  if equipped[slot] == NEW then return fullRec.link end
  if equipped[slot] == 103 then return '|Hitem:103|h[Linen Bag]|h' end
  return originalInventoryLink(unit, slot)
end
for _, pad in ipairs({ true, false }) do
check('exact user flow via ' .. (pad and 'controller' or 'mouse') .. ': menu -> Prepare -> DIRTY refresh -> Continue -> native replace', function()
  fullSetup(); fullConfirm(pad)()
  local n = #calls
  -- The shipping DIRTY event + window OnUpdate rebuild the selection; no staged record is fabricated.
  assert(W.dirty, 'preparation must fire DIRTY')
  W.frame.__scripts.OnUpdate(W.frame, 0.016)
  assert(not W.dirty)
  assert(W.selEntry and W.selEntry.rec and W.selEntry.rec.bag == 0 and W.selEntry.rec.slot == 1
    and W.selEntry.rec.itemID == NEW, 'DIRTY refresh retained displaced source-coordinate item instead of relocated new bag')
  local originalPut = PutItemInBag
  PutItemInBag = function(inv)
    calls[#calls + 1] = 'put ' .. inv
    assert(inv == 22, 'only chosen Linen Bag 3 may be replaced')
    -- Engine-owned contents transfer: existing 6 slots remain, capacity becomes 8.
    equipped[inv], cursor = cursor.itemID, { itemID = 103, stackCount = 1, hyperlink = GetInventoryItemLink('player', inv) }
    caps[3] = 8
    return true
  end
  W:ItemMenu(W.selEntry)
  click(menuIndex('Continue replacing Bag 3'))
  assert(#calls == n, 'another explicit hardware confirmation is required')
  click(1)
  PutItemInBag = originalPut
  assert(equipped[22] == NEW and caps[3] == 8 and bags[3][3].itemID == 300 and bags[0][1].itemID == 103 and not cursor)
  assert(calls[n + 1] == 'pickup 0:1' and calls[n + 2] == 'put 22' and #calls == n + 3)
  assert(not W.bagReplacement, 'continuation consumed exactly once')
end)
end

local mutations = {
  { 'source id', function() bags[3][3].itemID = 999 end },
  { 'source link', function() bags[3][3].hyperlink = 'changed' end },
  { 'source count', function() bags[3][3].stackCount = 2 end },
  { 'destination id', function() bags[0][1].itemID = 999 end },
  { 'destination link', function() bags[0][1].hyperlink = 'changed' end },
  { 'destination count', function() bags[0][1].stackCount = 3 end },
  { 'source lock', function() locked['3:3'] = true end },
  { 'destination lock', function() locked['0:1'] = true end },
  { 'source container', function() equipped[22] = 999 end },
  { 'destination capacity', function() caps[0] = 17 end },
  { 'pending equip', function() W.bagSwap = {} end },
  { 'pending placement', function() W.bagPlacement = true end },
  { 'combat', function() InCombatLockdown = function() return true end end },
  { 'cursor spell', function() cursor = { type = 'spell', itemID = 999 } end },
}
for _, case in ipairs(mutations) do
  check('exchange confirmation rejects changed ' .. case[1], function()
    fullSetup(); local confirm = fullConfirm(false); case[2](); confirm()
    assert(#calls == 0 and last():find('cursor', 1, true), 'stale confirmation moved an item')
    W.bagSwap, W.bagPlacement = nil, nil
    InCombatLockdown = function() return false end
  end)
end
for phase = 1, 2 do
  for _, mode in ipairs({ 'combat', 'unknown cursor', 'occupied origin', 'container replaced', 'lock', 'error', 'no movement' }) do
    check('exchange interruption after pickup ' .. phase .. ': ' .. mode, function()
      fullSetup(); local confirm = fullConfirm(false)
      local pickup = C_Container.PickupContainerItem
      C_Container.PickupContainerItem = function(b, s)
        if #calls + 1 == phase and mode == 'no movement' then calls[#calls + 1] = 'noop'; return end
        pickup(b, s)
        if #calls == phase then
          if mode == 'combat' then InCombatLockdown = function() return true end
          elseif mode == 'unknown cursor' then cursor = { itemID = 999, hyperlink = 'unknown' }
          elseif mode == 'occupied origin' then bags[3][3] = { itemID = 999, hyperlink = 'unrelated' }
          elseif mode == 'container replaced' then equipped[22] = 999
          elseif mode == 'lock' then locked['0:1'] = true
          elseif mode == 'error' then error('interrupted native operation') end
        end
      end
      confirm()
      assert(#calls == phase, 'interrupted exchange performed another item operation')
      assert(not W.bagPlacement and last():find("couldn't confirm", 1, true), 'must report uncertainty and release pending state')
      local n = #calls; for _ = 1, 20 do FLUSH() end
      assert(#calls == n, 'timer moved an item after interruption')
      InCombatLockdown = function() return false end
    end)
  end
end
-- Inject changes inside the real pickup boundary, before the next native move.
local equipInterruptions = {
  { 'target inventory lock', function() IsInventoryItemLocked = function(inv) return inv == 22 end end },
  { 'source inventory lock', function() IsInventoryItemLocked = function(inv) return inv == 20 end end },
  { 'source container replaced', function() equipped[20] = 999 end },
  { 'target container replaced', function() equipped[22] = 999 end },
  { 'source capacity changed', function() caps[1] = 9 end },
  { 'target capacity changed', function() caps[3] = 9 end },
  { 'source family changed', function() C_Container.GetContainerNumFreeSlots = function(b) return 0, b == 1 and 4 or 0 end end },
  { 'target family changed', function() C_Container.GetContainerNumFreeSlots = function(b) return 0, b == 3 and 4 or 0 end end },
  { 'origin occupied', function() bags[1][1] = { itemID = 999, hyperlink = 'unrelated' } end },
  { 'unknown cursor', function() cursor = { itemID = 999, hyperlink = 'unrelated' } end },
  { 'spell targeting', function() SpellIsTargeting = function() return true end end },
  { 'pending placement', function() W.bagPlacement = true end },
  { 'combat', function() InCombatLockdown = function() return true end end },
}
local equipFailures = {}
for _, case in ipairs(equipInterruptions) do
  local name = 'equip interruption after pickup: ' .. case[1]
  local ok, err = pcall(function()
    check(name, function()
      fullSetup()
      local r = {}; for k, v in pairs(fullRec) do r[k] = v end
      r.bag, r.slot = 1, 1; bags[1][1] = bags[3][3]
      local pickup = C_Container.PickupContainerItem
      C_Container.PickupContainerItem = function(b, s) pickup(b, s); case[2]() end
      W:EquipBagTo(r, 3, { itemID = 103, link = GetInventoryItemLink('player', 22), capacity = 6 })
      assert(table.concat(calls, ',') == 'pickup 1:1', 'unsafe next move: ' .. table.concat(calls, ','))
      assert(not W.bagSwap and last():find('cursor', 1, true), 'must release transaction and explain manual cursor handling')
      local n = #calls; for _ = 1, 20 do FLUSH() end
      assert(#calls == n, 'timer performed recovery after uncertain pickup')
    end)
  end)
  IsInventoryItemLocked = function() return false end
  InCombatLockdown = function() return false end
  SpellIsTargeting = function() return false end
  C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
  W.bagSwap, W.bagPlacement = nil, nil
  if not ok then equipFailures[#equipFailures + 1] = name .. ': ' .. tostring(err); print('FAIL ' .. equipFailures[#equipFailures]) end
end
assert(#equipFailures == 0, table.concat(equipFailures, '\n'))
check('equip rejects same-ID same-link source with changed count before pickup', function()
  fullSetup()
  local r = {}; for k, v in pairs(fullRec) do r[k] = v end
  r.bag, r.slot = 1, 1
  bags[1][1] = { itemID = r.itemID, hyperlink = r.link, stackCount = 2 }
  W:EquipBagTo(r, 3, { itemID = 103, capacity = 6 })
  assert(#calls == 0, 'count mismatch picked up source: ' .. table.concat(calls, ','))
end)
check('equip preserves immutable non-default source count across pickup refresh', function()
  fullSetup()
  local r = {}; for k, v in pairs(fullRec) do r[k] = v end
  r.bag, r.slot, r.count = 1, 1, 2
  local info = { itemID = r.itemID, hyperlink = r.link, stackCount = 2 }
  bags[1][1] = info
  local pickup, getInfo = C_Container.PickupContainerItem, C_Container.GetContainerItemInfo
  C_Container.GetContainerItemInfo = function(b, s)
    if b == 1 and s == 1 and bags[b][s] then return info end
    return getInfo(b, s)
  end
  C_Container.PickupContainerItem = function(b, s)
    pickup(b, s)
    r.count, info.stackCount = 99, 99 -- reused records must not rewrite the transaction
  end
  W:EquipBagTo(r, 3, { itemID = 103, capacity = 6 })
  assert(W.bagSwap and W.bagSwap.rec.count == 2, 'source count missing or retained by reference')
  assert(table.concat(calls, ',') == 'pickup 1:1,put 22', 'matching count should equip normally')
  cursor, pending = nil, nil
  for _ = 1, 30 do FLUSH() end
end)
check('empty-slot preparation retains target and selects verified relocated bag', function()
  fullSetup(); bags[0][2] = nil
  C_Container.GetContainerNumFreeSlots = function(b) return b == 0 and 1 or 0, 0 end
  W:ItemMenu({ rec = fullRec, btn = W.frame }); click(menuIndex('Equip bag / Replace bag')); click(3); click(2)
  assert(#Live.Menu.entries == 3 and Live.Menu.entries[1].text == 'Move Feed Pouch out of Bag 3 to an empty slot (Backpack)'
    and Live.Menu.entries[2].text == 'Then press Continue to replace Bag 3.', 'empty slot must be preferred ahead of a swap: ' .. Live.Menu.entries[1].text)
  click(1)
  assert(table.concat(calls, ',') == 'pickup 3:3,pickup 0:2' and not cursor)
  assert(W.bagReplacement and W.bagReplacement.target == 3 and W.bagReplacement.status == 'ready'
    and W.selKey == '0:2', 'verified stage lost replacement intent')
  assert(W:WindowEntries()[1].text:find('Continue replacing Bag 3', 1, true))
  C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
end)
local bagJournal = {}
local journalImpl = Live.Journal
function Live:Journal(ctx, msg)
  bagJournal[#bagJournal + 1] = tostring(msg)
  return journalImpl(self, ctx, msg)
end
check('stale occupied native source snapshot stops at source-pickup with exact predicate', function()
  fullSetup(); local confirm = fullConfirm(false)
  local pickup = C_Container.PickupContainerItem
  C_Container.PickupContainerItem = function(b, s)
    local stale = bags[b][s]
    pickup(b, s)
    bags[b][s] = stale -- cursor confirms pickup but snapshot has not vacated: hypothesis, not live evidence
  end
  bagJournal = {}; confirm()
  assert(#calls == 1 and cursor and cursor.itemID == NEW and not W.bagReplacement)
  local log = table.concat(bagJournal, '\n')
  assert(log:find('phase=source-pickup', 1, true) and log:find('origin-occupied', 1, true), 'missing exact stop phase/predicate: ' .. log)
  assert(log:find('count=', 1, true) and log:find('family=', 1, true) and log:find('cursor=item/200/', 1, true), 'missing scalar diagnostics')
  assert(last():find('origin-occupied', 1, true) and last():find('yourself', 1, true), 'manual instruction must explain the refusal')
  local n = #calls; for _ = 1, 20 do FLUSH() end
  assert(#calls == n, 'observation must not continue item moves')
end)
check('pending continuation is observation-only and becomes actionable only after verified settle', function()
  fullSetup(); bags[0][2] = nil
  C_Container.GetContainerNumFreeSlots = function(b) return b == 0 and 1 or 0, 0 end
  local pickup = C_Container.PickupContainerItem
  local delayed
  C_Container.PickupContainerItem = function(b, s)
    pickup(b, s)
    if b == 0 and s == 2 then delayed = bags[0][2]; bags[0][2] = nil end -- destination not yet reported
  end
  W:ItemMenu({ rec = fullRec, btn = W.frame }); click(menuIndex('Equip bag / Replace bag')); click(3); click(2); click(1)
  C_Container.PickupContainerItem = pickup
  assert(W.bagReplacement and W.bagReplacement.status == 'pending', 'unverified placement must remain pending')
  assert(W:WindowEntries()[1].disabled, 'pending continuation must not be actionable')
  local n = #calls
  FLUSH(); assert(#calls == n and W.bagReplacement.status == 'pending')
  bags[0][2] = delayed; FLUSH()
  assert(#calls == n and W.bagReplacement and W.bagReplacement.status == 'ready' and W.selKey == '0:2')
  -- Target identity changes before Continue: discard, never choose a new target.
  equipped[22] = 105
  W:ItemMenu(W.selEntry or { rec = { bag = 0, slot = 2, itemID = NEW, equipLoc = 'INVTYPE_BAG', count = 1, link = fullRec.link }, btn = W.frame })
  assert(not W.bagReplacement, 'changed target must discard continuation')
  for _, e in ipairs(Live.Menu.entries) do assert(not e.text:find('Continue', 1, true)) end
  assert(#calls == n)
  C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
end)
check('specialty free-space census explains unusable free slots without claiming full inventory', function()
  fullSetup(); caps[4], bags[4] = 32, {}
  C_Container.GetContainerNumFreeSlots = function(b) return b == 4 and 32 or 0, b == 4 and 32 or 0 end
  bagJournal = {}
  local choices = W:PrepareBagReplacementEntries(fullRec, 3, { itemID = 103, link = GetInventoryItemLink('player', 22), capacity = 6 })
  local auto = choices[2].sub()[1].text
  assert(auto:find('swapping it with Linen Cloth', 1, true) and not auto:lower():find('full', 1, true), auto)
  local log = table.concat(bagJournal, '\n')
  assert(log:find('census bag=4', 1, true) and log:find('free=32', 1, true)
    and log:find('family=32', 1, true) and log:find('compatible=false', 1, true), 'missing per-container free-space explanation: ' .. log)
  C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
end)
check('hundreds of physical alternatives still yield one automatic partner and no list', function()
  fullSetup()
  for b = 0, 4 do
    caps[b] = 100
    for s = 1, 100 do
      if not (b == 3 and s == 3) then bags[b][s] = { itemID = 300, stackCount = 2, hyperlink = '|Hitem:300:' .. b .. ':' .. s .. '|h[Linen Cloth]|h' } end
    end
  end
  local out = W:PrepareBagReplacementEntries(fullRec, 3, { itemID = 103, link = GetInventoryItemLink('player', 22), capacity = 6 })
  assert(#out == 2 and out[1].func and not out[1].sub, 'hand pickup + one automatic swap, not a list')
  local confirm = out[2].sub()
  assert(#confirm == 3 and confirm[1].func, 'one confirmation')
  for _, e in ipairs(confirm) do assert(not e.sub) end
  for _, e in ipairs(out) do assert(not e.text:find('alternatives', 1, true) and not e.text:find('Other', 1, true), e.text) end
  assert(#calls == 0)
end)
-- ---- continuation UX polish: chat transitions, menu scope, in-place pagination, wording -------------------------
local function count(pattern)
  local n = 0
  for _, line in ipairs(printed) do if line:find(pattern, 1, true) then n = n + 1 end end
  return n
end
local function stageReady()
  fullSetup(); bags[0][2] = nil
  C_Container.GetContainerNumFreeSlots = function(b) return b == 0 and 1 or 0, 0 end
  W:ItemMenu({ rec = fullRec, btn = W.frame }); click(menuIndex('Equip bag / Replace bag')); click(3); click(2)
  printed = {}
  click(1)
  assert(W.bagReplacement and W.bagReplacement.status == 'ready')
end
check('ready continuation prints exactly one concise chat line', function()
  stageReady()
  assert(#printed == 1 and printed[1] == 'Feed Pouch moved \226\128\148 press Continue to replace Bag 3.',
    'one ready line, no duplicate preparation text: ' .. table.concat(printed, ' || '))
  W:WindowEntries(); W:ItemMenu({ rec = { bag = 0, slot = 2, itemID = NEW, equipLoc = 'INVTYPE_BAG', count = 1, link = fullRec.link, name = 'Feed Pouch' }, btn = W.frame })
  for _ = 1, 20 do FLUSH() end
  assert(#printed == 1, 'ready line repeated: ' .. table.concat(printed, ' || '))
  C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
end)
check('delayed ready transition prints once from observation', function()
  fullSetup(); bags[0][2] = nil
  C_Container.GetContainerNumFreeSlots = function(b) return b == 0 and 1 or 0, 0 end
  local pickup, delayed = C_Container.PickupContainerItem
  C_Container.PickupContainerItem = function(b, s)
    pickup(b, s)
    if b == 0 and s == 2 then delayed = bags[0][2]; bags[0][2] = nil end
  end
  W:ItemMenu({ rec = fullRec, btn = W.frame }); click(menuIndex('Equip bag / Replace bag')); click(3); click(2)
  printed = {}; click(1)
  C_Container.PickupContainerItem = pickup
  assert(count('moved') == 0 and count('discarded') == 0, 'pending must not claim ready: ' .. table.concat(printed, ' || '))
  local before = #printed
  FLUSH(); assert(#printed == before)
  bags[0][2] = delayed
  for _ = 1, 20 do FLUSH() end
  assert(#printed == before + 1 and count('Feed Pouch moved') == 1, table.concat(printed, ' || '))
  C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
end)
for _, case in ipairs({
  { 'timeout', 'not verified in time', function()
      local pickup = C_Container.PickupContainerItem
      return function(b, s) pickup(b, s); if b == 0 and s == 2 then bags[0][2] = nil end end
    end },
  { 'cursor', 'cursor', nil, function() cursor = { itemID = 999, hyperlink = 'x' } end },
  { 'target change', 'Bag 3 changed', nil, function() equipped[22] = 105 end },
}) do
  check('discarded continuation prints one line with reason: ' .. case[1], function()
    fullSetup(); bags[0][2] = nil
    C_Container.GetContainerNumFreeSlots = function(b) return b == 0 and 1 or 0, 0 end
    local pickup = C_Container.PickupContainerItem
    if case[3] then C_Container.PickupContainerItem = case[3]() end
    W:ItemMenu({ rec = fullRec, btn = W.frame }); click(menuIndex('Equip bag / Replace bag')); click(3); click(2)
    printed = {}; click(1)
    C_Container.PickupContainerItem = pickup
    if case[4] then case[4]() end
    for _ = 1, 20 do FLUSH(); W:WindowEntries() end
    assert(not W.bagReplacement, 'continuation must be discarded')
    assert(count('discarded') == 1, 'exactly one discard line: ' .. table.concat(printed, ' || '))
    assert(count(case[2]) >= 1, 'discard reason missing: ' .. table.concat(printed, ' || '))
    cursor = nil
    C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
  end)
end
local function hasContinue()
  for _, e in ipairs(Live.Menu.entries) do if (e.text or ''):find('Continue', 1, true) then return true end end
end
check('Continue appears only on the moved new bag and in the window menu', function()
  stageReady()
  W:ItemMenu({ rec = { bag = 1, slot = 1, itemID = 300, count = 2, link = '|Hitem:300|h[Linen Cloth]|h', name = 'Linen Cloth' }, btn = W.frame })
  assert(not hasContinue(), 'unrelated item menu must not offer Continue')
  W:ItemMenu({ rec = { bag = 3, slot = 3, itemID = 300, count = 2, link = '|Hitem:300|h[Linen Cloth]|h', name = 'Linen Cloth' }, btn = W.frame })
  assert(not hasContinue(), 'old source coordinate must not offer Continue')
  W:ItemMenu({ rec = { bag = 0, slot = 2, itemID = NEW, equipLoc = 'INVTYPE_BAG', count = 1, link = fullRec.link, name = 'Feed Pouch' }, btn = W.frame })
  assert(hasContinue(), 'moved new bag must offer Continue')
  W:WindowMenu()
  assert(hasContinue(), 'window menu must offer Continue')
  assert(W.bagReplacement and W.bagReplacement.status == 'ready')
  Live.Menu:Close()
  C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
end)
check('automatic partner skips bags, quest items and locked items', function()
  fullSetup()
  bags[0][1] = { itemID = 400, stackCount = 1, hyperlink = '|Hitem:400|h[Spare Bag]|h' }
  bags[0][2] = { itemID = 500, stackCount = 1, hyperlink = '|Hitem:500|h[Quest Thing]|h' }
  bags[0][3] = { itemID = 301, stackCount = 1, hyperlink = '|Hitem:301|h[Odd Note]|h', quest = true }
  locked['0:4'] = true
  bags[0][5] = { itemID = 302, stackCount = 3, hyperlink = '|Hitem:302|h[Wool Cloth]|h' }
  local out = W:PrepareBagReplacementEntries(fullRec, 3, { itemID = 103, link = GetInventoryItemLink('player', 22), capacity = 6 })
  local c = out[2].sub()[1]
  assert(c.text == 'Move Feed Pouch out of Bag 3 by swapping it with Wool Cloth (Backpack)', c.text)
  assert(c.tip:find('Backpack, slot 5', 1, true), c.tip)
  assert(#calls == 0)
end)
check('no safe automatic partner leaves only the hand pickup, no list or move', function()
  fullSetup()
  for b = 0, 4 do for s, it in pairs(bags[b]) do if not (b == 3 and s == 3) then it.quest = true end end end
  local out = W:PrepareBagReplacementEntries(fullRec, 3, { itemID = 103, link = GetInventoryItemLink('player', 22), capacity = 6 })
  assert(#out == 1 and out[1].text:find('Pick up Feed Pouch', 1, true) and not out[1].sub, 'only the hand pickup remains')
  assert(#calls == 0)
end)
-- ---- hand pickup: Baggler lifts the new bag once; the player swaps it natively; Baggler only observes ----------
local function handPickup(extra)
  fullSetup(); if extra then extra() end
  W:Create()
  W:ItemMenu({ rec = fullRec, btn = W.frame }); click(menuIndex('Equip bag / Replace bag')); click(3)
  printed = {}
  click(menuIndex('Pick up Feed Pouch'))
end
local function padUseOn(bag, slot)
  W.dirty = true; W.frame.__scripts.OnUpdate(W.frame, 0.016)
  for _, e in ipairs(W.nav) do
    if e.rec and e.rec.bag == bag and e.rec.slot == slot then W:SelectEntry(e); W:OnPad('use'); return end
  end
  error('no window entry for ' .. bag .. ':' .. slot)
end
check('hand pickup: one verified pickup, controller A swaps natively outside the target, one ready line, Continue replaces', function()
  handPickup()
  assert(table.concat(calls, ',') == 'pickup 3:3' and cursor and cursor.itemID == NEW, 'exactly one pickup of the new bag')
  assert(W.bagReplacement and W.bagReplacement.status == 'holding' and #printed == 0)
  local hint = W:WindowEntries()[1]
  assert(hint.disabled and hint.text == 'Place Feed Pouch on any slot or item outside Bag 3', tostring(hint.text))
  padUseOn(0, 1)                                                 -- shipping A while holding: the native swap
  assert(calls[2] == 'pickup 0:1' and bags[0][1].itemID == NEW and cursor.itemID == 300, 'A must route to native pickup/swap')
  for _ = 1, 5 do FLUSH() end
  assert(W.bagReplacement and W.bagReplacement.status == 'holding' and #printed == 0, 'waits while the displaced item is held')
  C_Container.PickupContainerItem(3, 3)                          -- the player sets the displaced item down
  assert(not cursor)
  local n = #calls
  FLUSH()
  assert(#calls == n, 'observation never moves items')
  assert(#printed == 1 and printed[1] == 'Feed Pouch moved \226\128\148 press Continue to replace Bag 3.', table.concat(printed, ' || '))
  assert(W.bagReplacement.status == 'ready' and W.selKey == '0:1')
  for _ = 1, 20 do FLUSH() end
  assert(#printed == 1, 'ready said once')
  local originalPut = PutItemInBag
  PutItemInBag = function(inv)
    calls[#calls + 1] = 'put ' .. inv
    assert(inv == 22, 'only chosen Bag 3 may be replaced')
    equipped[inv], cursor = cursor.itemID, { itemID = 103, stackCount = 1, hyperlink = GetInventoryItemLink('player', inv) }
    caps[3] = 8
    return true
  end
  W:ItemMenu({ rec = { bag = 1, slot = 1, itemID = 300, count = 2, link = '|Hitem:300|h[Linen Cloth]|h', name = 'Linen Cloth' }, btn = W.frame })
  assert(not hasContinue(), 'Continue only on the moved bag')
  W:ItemMenu({ rec = { bag = 0, slot = 1, itemID = NEW, equipLoc = 'INVTYPE_BAG', count = 1, link = fullRec.link, name = 'Feed Pouch' }, btn = W.frame })
  click(menuIndex('Continue replacing Bag 3'))
  assert(#calls == n, 'Continue needs its own press')
  click(1)
  PutItemInBag = originalPut
  assert(calls[n + 1] == 'pickup 0:1' and calls[n + 2] == 'put 22' and equipped[22] == NEW and not W.bagReplacement)
end)
check('hand pickup put back inside the target is discarded with one line', function()
  handPickup(function() bags[1][1] = { itemID = NEW, stackCount = 1, hyperlink = fullRec.link } end) -- identical bag already outside
  for _ = 1, 3 do FLUSH() end
  assert(W.bagReplacement and W.bagReplacement.status == 'holding', 'a pre-existing identical bag outside is not proof')
  C_Container.PickupContainerItem(3, 3)                          -- dropped straight back where it was
  for _ = 1, 5 do FLUSH(); W:WindowEntries() end
  assert(not W.bagReplacement and count('discarded') == 1 and count('back inside Bag 3') == 1, table.concat(printed, ' || '))
  assert(not hasContinue())
end)
check('hand pickup never placed times out with one line and leaves the cursor alone', function()
  handPickup()
  local n = #calls
  for _ = 1, 400 do FLUSH() end
  assert(#calls == n and cursor and cursor.itemID == NEW, 'timer touched the cursor')
  assert(not W.bagReplacement and count('discarded') == 1 and count('not placed outside Bag 3 in time') == 1, table.concat(printed, ' || '))
end)
check('hand pickup in flight is not confused with an identical bag already outside', function()
  handPickup(function() bags[1][1] = { itemID = NEW, stackCount = 1, hyperlink = fullRec.link } end)
  cursor = nil                                                   -- cursor empty, placement not yet reported
  for _ = 1, 5 do FLUSH() end
  assert(W.bagReplacement and W.bagReplacement.status == 'holding' and count('moved') == 0, table.concat(printed, ' || '))
  W.bagReplacement = nil
end)
for _, case in ipairs({
  { 'cursor', function() cursor = { itemID = 999, hyperlink = 'x' } end },
  { 'combat', function() InCombatLockdown = function() return true end end },
  { 'source lock', function() locked['3:3'] = true end },
  { 'target changed', function() equipped[22] = 105 end },
  { 'pending swap', function() W.bagSwap = {} end },
}) do
  check('hand pickup refuses before any move: ' .. case[1], function()
    fullSetup(); W:Create()
    W:ItemMenu({ rec = fullRec, btn = W.frame }); click(menuIndex('Equip bag / Replace bag')); click(3)
    case[2]()
    printed = {}
    click(menuIndex('Pick up Feed Pouch'))
    assert(#calls == 0 and not W.bagReplacement and count('untouched') == 1, table.concat(printed, ' || '))
    InCombatLockdown = function() return false end
    W.bagSwap, cursor = nil, nil
  end)
end
print(('PASS native bag equip: %d cases'):format(passed))
