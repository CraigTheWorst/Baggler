-- Offline regression coverage for the retained real bag code, not a game emulator.
-- Invoked by bags_only_test.lua after booting the shipping bags + bank TOC.
local CB = ...
local W, Inv = CB.Window, CB.Inventory
local passed = 0
local function check(name, fn)
  fn()
  passed = passed + 1
  print('PASS parity: ' .. name)
end
local function overrides(target, values, fn)
  local before = {}
  for key, value in pairs(values) do before[key] = target[key]; target[key] = value end
  local ok, err = xpcall(fn, debug.traceback)
  for key in pairs(values) do target[key] = before[key] end
  assert(ok, err)
end
local rec = { bag = 0, slot = 5, key = '0:5', itemID = 5, name = 'Healing Potion',
  nameLower = 'healing potion', count = 5, quality = 2, sellPrice = 10, classID = 0, subID = 1,
  link = '|cffffffff|Hitem:5|h[Healing Potion]|h|r' }
W:Open()

check('plain mouse use/equip and modified clicks keep the original item script', function()
  local button = W:GetButton(0, 5)
  button.cbEntry = { rec = rec, btn = button }
  assert(button:GetScript('OnClick') == button.cbOrigClick)
  assert(W:ClickMode(button))
  local gear = { equipLoc = 'INVTYPE_HEAD', itemID = 3, bag = 0, slot = 3 }
  button.cbEntry.rec = gear
  assert(W:ClickMode(button), 'ordinary equipment still runs the native template')
  button.cbEntry.rec = rec
end)

check('secure controller use is aimed at the current bag slot', function()
  assert(W:SecureUseRec(rec) == rec)
  assert(CB.Pad:WriteMacro(rec.bag, rec.slot))
  assert(CB.Pad:UseButton():GetAttribute('macrotext') == '/use 0 5')
end)

check('cursor pickup/place keep the container route and keep-on-close intent', function()
  local calls = {}
  overrides(C_Container, { PickupContainerItem = function(b, s) calls[#calls + 1] = { b, s } end }, function()
    W:Pickup(rec, true)
    W:Pickup({ bag = 0, slot = 4 })
    assert(calls[1][1] == 0 and calls[1][2] == 5 and calls[2][2] == 4)
    assert(CB.heldByUs == 'yes')
    W:Pickup(rec, true)
    assert(CB.heldByUs == 'keep')
  end)
  CB.heldByUs = nil
end)

local function itemMenu(fn)
  local entries
  overrides(CB.Menu, { Open = function(_, _, _, list) entries = list end }, function()
    W:ItemMenu({ rec = rec, btn = W:GetButton(rec.bag, rec.slot) })
    fn(entries)
  end)
end
local function find(entries, label)
  for _, e in ipairs(entries) do if e.text == label then return e end end
  error('missing menu action: ' .. label)
end

check('split stack menu delegates the selected amount to the container API', function()
  local split, stack = nil, CreateFrame('Frame')
  stack.OpenStackSplitFrame = function(_, count, button)
    assert(count == rec.count)
    button:SplitStack(2)
  end
  overrides(_G, { StackSplitFrame = stack }, function()
    overrides(C_Container, { SplitContainerItem = function(b, s, n) split = { b, s, n } end }, function()
      itemMenu(function(entries) find(entries, 'Split stack').func() end)
    end)
  end)
  assert(split[1] == rec.bag and split[2] == rec.slot and split[3] == 2)
end)

check('chat linking preserves the exact item hyperlink', function()
  local link
  overrides(_G, { ChatEdit_InsertLink = function(value) link = value end }, function()
    itemMenu(function(entries) find(entries, 'Link in chat').func() end)
  end)
  assert(link == rec.link)
end)

check('destroy requires confirmation and validates the slot again', function()
  local entries, cursor, deleted = nil, false, false
  overrides(_G, { CursorHasItem = function() return cursor end,
    DeleteCursorItem = function() deleted = true; cursor = false end }, function()
    overrides(C_Container, { PickupContainerItem = function() cursor = true end }, function()
      overrides(CB.Menu, { Open = function(_, _, _, list) entries = list end }, function()
        W:Destroy(rec)
        assert(not deleted)
        find(entries, 'Cancel').func()
        assert(not deleted)
        find(entries, 'Destroy').func()
        assert(deleted)
      end)
    end)
  end)
end)

check('equip-in-slot uses pickup/inventory swap, not sale/deposit', function()
  local cursor, slot = false, nil
  overrides(_G, { CursorHasItem = function() return cursor end,
    PickupInventoryItem = function(value) slot = value; cursor = false end }, function()
    overrides(C_Container, { PickupContainerItem = function() cursor = true end }, function()
      W:EquipTo(rec, 11)
    end)
  end)
  assert(slot == 11)
end)

check('sale protection retains favourite, equipment-set and epic guards', function()
  CB.db.favorites[rec.itemID] = true
  assert(not W:SellGuard(rec))
  CB.db.favorites[rec.itemID] = nil
  CB.Categories.setItems = { [rec.itemID] = true }
  assert(not W:SellGuard(rec))
  CB.Categories.setItems = {}
  rec.quality = 4
  assert(not W:SellGuard(rec))
  assert(W:SellGuard(rec))
  rec.quality = 2
end)

check('selling one splits the stack then sells from an empty bag slot', function()
  local merchant = rawget(_G, 'MerchantFrame')
  merchant:Show()
  local cursor, split, sold = false, nil, nil
  overrides(_G, { CursorHasItem = function() return cursor end }, function()
    overrides(W, { FreeSlot = function() return 0, 4 end }, function()
      overrides(C_Container, {
        SplitContainerItem = function(b, s, amount) split = amount; cursor = true end,
        PickupContainerItem = function() cursor = false end,
        GetContainerItemInfo = function() return { itemID = rec.itemID } end,
        UseContainerItem = function(b, s) sold = { b, s } end,
      }, function() W:SellAmount(rec, 1) end)
    end)
  end)
  assert(split == 1 and sold and sold[1] == 0 and sold[2] == 4)
  merchant:Hide()
end)

check('scan retains count, lock, bound, lootable and quest flags plus capacity', function()
  overrides(C_Container, {
    GetContainerItemInfo = function(_, slot)
      if slot == 1 then return { itemID = 1, itemName = 'Flag item', stackCount = 7,
        isLocked = true, isBound = true, hasLoot = true, quality = 1 } end
    end,
    GetContainerItemQuestInfo = function() return { isQuestItem = true } end,
    GetContainerNumSlots = function() return 2 end,
  }, function()
    local items, empty, total, free = Inv:Scan({ 0 })
    assert(#items == 1 and #empty == 1 and total == 2 and free == 1)
    assert(items[1].locked and items[1].bound and items[1].lootable and items[1].isQuest and items[1].count == 7)
  end)
end)

check('cooldown data and bandage fallback are preserved', function()
  overrides(_G, { GetTime = function() return 100 end }, function()
    overrides(C_Container, { GetContainerItemCooldown = function() return 90, 30, 1 end }, function()
      local left, duration = Inv:CooldownLeft(0, 5, rec)
      assert(left == 20 and duration == 30)
    end)
    overrides(C_Container, { GetContainerItemCooldown = function() return 0, 0, 1 end }, function()
      overrides(_G, { C_UnitAuras = { GetPlayerAuraBySpellID = function() return { expirationTime = 120, duration = 60 } end } }, function()
        local left, duration = Inv:CooldownLeft(0, 5, { classID = 0, subID = 7 })
        assert(left == 20 and duration == 60)
      end)
    end)
  end)
end)

check('search, category filter and sort keep their bag code paths', function()
  assert(Inv:Matches(rec, 'healing'))
  assert(Inv:Matches(rec, 'q:uncommon'))
  assert(not Inv:Matches(rec, 'q:epic'))
  W.query = ''; W:SetFilter(nil); W:Refresh()
  W:SetFilter('Potions'); assert(W.filterCat == 'Potions')
  W:SetFilter(nil)
  local sorted = false
  overrides(C_Container, { SortBags = function() sorted = true end }, function() W:CleanUp() end)
  assert(sorted)
end)

check('equipped bags and gold/free-space footer remain present', function()
  W:UpdateBagSlots(); W:UpdateFooter()
  assert(W.frame.bagSlots and #W.frame.bagSlots > 0)
  assert(W.frame.moneyText and W.frame.moneyText:GetText() ~= '')
  assert(W.totalSlots and W.freeCount)
end)

check('combat rejects sort, equip and destroy; secure attributes are not rewritten', function()
  local touched = false
  COMBAT = true
  overrides(C_Container, { SortBags = function() touched = true end,
    PickupContainerItem = function() touched = true end }, function()
    W:CleanUp(); W:EquipTo(rec, 11); W:Destroy(rec)
    assert(not CB.Pad:WriteMacro(0, 5))
  end)
  COMBAT = false
  assert(not touched)
end)

check('personal/account bank is the only retained non-bag visual module', function()
  assert(CB.Bank and CB.Bank.window and CB.Bank.window.kind == 'bank')
  assert(not CB.Vendor and not CB.GuildBank and not CB.Mail and not CB.Trade and not CB.Loot and not CB.Trainer)
  assert(CB.defaults.replaceBank and not CB.NativeWindows.retired.bank)
  assert(not CB.Bank.active, 'closed bank must not leak a deposit context into plain bag use')
end)

print(('PASS retained bag + bank-exception parity regression groups: %d (offline only)'):format(passed))
