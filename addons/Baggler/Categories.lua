-- Baggler categories: decides which section an item belongs to, and orders
-- sections and the items inside them.
local ADDON, CB = ...
local Cat = {}
CB.Categories = Cat

local itemClassInfo = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
local itemSubClassInfo = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo

---------------------------------------------------------------------------
-- Display order of the built-in sections (lower = nearer the top).
---------------------------------------------------------------------------
local ORDER = {
  ["Hearthstone"] = 0,
  ["Soul Shards"] = 0.5,                     -- always the second section, right under the Hearthstone
  ["New"] = 1,
  ["Favorites"] = 2,
  ["Equipment Sets"] = 20,
  ["Quest"] = 30,
  ["Weapons"] = 40,
  ["Armor"] = 41,
  ["Accessories"] = 42,
  ["Potions"] = 50,
  ["Elixirs"] = 51,
  ["Flasks"] = 52,
  ["Food & Drink"] = 53,
  ["Bandages"] = 54,
  ["Consumables"] = 55,
  ["Camping"] = 56,
  ["Reagents"] = 60,
  ["Trade Goods"] = 61,
  ["Gems"] = 62,
  ["Enhancements"] = 63,
  ["Recipes"] = 64,
  ["Containers"] = 70,
  ["Ammo"] = 71,
  ["Keys"] = 72,
  ["Mounts"] = 80,
  ["Pets"] = 81,
  ["Glyphs"] = 82,
  ["Miscellaneous"] = 85,
  ["Junk"] = 900,
  ["Free Space"] = 1000,
}
Cat.ORDER = ORDER

-- Names the user can pin an item to (besides their own custom categories).
Cat.PINNABLE = {
  "Favorites", "Equipment Sets", "Quest", "Weapons", "Armor", "Accessories",
  "Consumables", "Camping", "Reagents", "Trade Goods", "Gems", "Recipes", "Containers",
  "Mounts", "Pets", "Miscellaneous", "Junk",
}

-- Trade-goods subclasses -> friendly section names (falls back to the game's own name).
local CONSUMABLE = {
  [1] = "Potions", [2] = "Elixirs", [3] = "Flasks", [5] = "Food & Drink",
  [7] = "Bandages",
}

local ACCESSORY_SLOTS = {
  INVTYPE_FINGER = true, INVTYPE_NECK = true, INVTYPE_TRINKET = true,
  INVTYPE_CLOAK = true, INVTYPE_HOLDABLE = false,
}

-- Equipment set items, rebuilt on demand.
Cat.setItems = {}
-- Collects the item IDs that belong to equipment sets, so Classify can group them.
function Cat:RefreshSets()
  local sets = {}
  if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs then
    local ok, ids = pcall(C_EquipmentSet.GetEquipmentSetIDs)
    if ok and ids then
      for _, id in ipairs(ids) do
        local ok2, items = pcall(C_EquipmentSet.GetItemIDs, id)
        if ok2 and items then
          for _, itemID in pairs(items) do
            if itemID and itemID > 0 then sets[itemID] = true end
          end
        end
      end
    end
  end
  Cat.setItems = sets
end

local subNameCache = {}
local function subName(classID, subID)
  if not subID or not itemSubClassInfo then return nil end
  local key = classID * 1000 + subID
  local v = subNameCache[key]
  if v == nil then
    local ok, name = pcall(itemSubClassInfo, classID, subID)
    v = (ok and name) or false
    subNameCache[key] = v
  end
  return v or nil
end

local classNameCache = {}
local function className(classID)
  if not classID or not itemClassInfo then return nil end
  local v = classNameCache[classID]
  if v == nil then
    local ok, name = pcall(itemClassInfo, classID)
    v = (ok and name) or false
    classNameCache[classID] = v
  end
  return v or nil
end

---------------------------------------------------------------------------
-- Built-in classification by item class (always available, no item cache needed)
---------------------------------------------------------------------------
local function builtin(rec)
  local c, s = rec.classID, rec.subID
  if c == 0 then
    local n = CONSUMABLE[s] or "Consumables"
    return n, ORDER[n]
  elseif c == 1 then return "Containers", ORDER["Containers"]
  elseif c == 2 then return "Weapons", ORDER["Weapons"]
  elseif c == 3 then return "Gems", ORDER["Gems"]
  elseif c == 4 then
    if rec.equipLoc and ACCESSORY_SLOTS[rec.equipLoc] then
      return "Accessories", ORDER["Accessories"]
    end
    return "Armor", ORDER["Armor"]
  elseif c == 5 then return "Reagents", ORDER["Reagents"]
  elseif c == 6 or c == 11 then return "Ammo", ORDER["Ammo"]
  elseif c == 7 then
    if CB.db.splitTradeGoods then
      local n = subName(7, s)
      if n and n ~= "" then return n, 61 + (s or 0) / 100 end
    end
    return "Trade Goods", ORDER["Trade Goods"]
  elseif c == 8 then return "Enhancements", ORDER["Enhancements"]
  elseif c == 9 then return "Recipes", ORDER["Recipes"]
  elseif c == 12 then return "Quest", ORDER["Quest"]
  elseif c == 13 then return "Keys", ORDER["Keys"]
  elseif c == 15 then
    if s == 5 then return "Mounts", ORDER["Mounts"] end
    if s == 2 then return "Pets", ORDER["Pets"] end
    return "Miscellaneous", ORDER["Miscellaneous"]
  elseif c == 16 then return "Glyphs", ORDER["Glyphs"]
  elseif c == 17 then return "Pets", ORDER["Pets"]
  end
  return "Miscellaneous", ORDER["Miscellaneous"]
end

-- Item classes with a section of their own: grey items of these stay in it.
local HAS_OWN_SECTION = { [0] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true,
  [9] = true, [11] = true, [12] = true, [13] = true, [16] = true, [17] = true }

local function customOrder(name)
  local def = CB.db.custom[name]
  return 10 + ((def and def.order) or 0) / 100
end

local function matchesPatterns(rec, def)
  if not def or not def.patterns then return false end
  local name = rec.nameLower
  if not name then return false end
  for _, p in ipairs(def.patterns) do
    if p ~= "" and name:find(p, 1, true) then return true end
  end
  return false
end

--- Returns sectionName, sectionOrder for an item record.
-- Every hearthstone variant, wherever it sits, gets its own first section.
local HEARTH_IDS = { [6948] = true, [64488] = true, [54452] = true, [93672] = true, [110560] = true,
  [140192] = true, [142542] = true, [162973] = true, [163045] = true, [165669] = true, [165670] = true,
  [165802] = true, [166746] = true, [166747] = true, [168907] = true, [172179] = true, [188952] = true,
  [190196] = true, [190237] = true, [193588] = true, [200630] = true, [206195] = true, [208704] = true,
  [209035] = true, [212337] = true, [228940] = true }
--- Soul Shards (the warlock's reagent): found by item ID, with the localised name as a second way of knowing them.
local SOUL_SHARD_ID = 6265
function Cat:IsSoulShard(rec)
  if rec.itemID == SOUL_SHARD_ID then return true end
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(SOUL_SHARD_ID)
  return name ~= nil and rec.nameLower ~= nil and rec.nameLower == name:lower()
end

function Cat:IsHearthstone(rec)
  if not rec or not rec.itemID then return false end
  if HEARTH_IDS[rec.itemID] then return true end
  return rec.nameLower ~= nil and rec.nameLower:find("hearthstone", 1, true) ~= nil and rec.classID ~= 2 and rec.classID ~= 4
end

-- Chooses the section for an item and returns its name and sort order. Rules run in priority
-- order and the first match wins.
function Cat:Classify(rec)
  local db = CB.db
  if Cat:IsHearthstone(rec) then return "Hearthstone", ORDER["Hearthstone"] end
  if Cat:IsSoulShard(rec) then return "Soul Shards", ORDER["Soul Shards"] end

  -- 1. manual assignment wins
  local pin = db.pins[rec.itemID]
  if pin then
    if db.custom[pin] then return pin, customOrder(pin) end
    if ORDER[pin] then return pin, ORDER[pin] end
  end

  -- 2. favorites, new items
  if db.favSection and db.favorites[rec.itemID] then return "Favorites", ORDER["Favorites"] end
  if db.newSection and rec.isNew then return "New", ORDER["New"] end

  -- 3. user pattern categories
  -- (the user's own order decides between sections that both match, not the table's internal order)
  local bestName, bestOrder
  for name, def in pairs(db.custom) do
    if matchesPatterns(rec, def) then
      local o = customOrder(name)
      if not bestOrder or o < bestOrder or (o == bestOrder and name < bestName) then bestName, bestOrder = name, o end
    end
  end
  if bestName then return bestName, bestOrder end

  -- 4. junk, equipment sets, quest
  -- The Junk section is for vendor trash. A grey weapon, armor piece, potion, recipe ... stays with its own kind
  -- (it is still grey, still sold by "Sell junk"); `junkAll` puts every grey item in Junk instead.
  if db.separateJunk and rec.quality == 0 and (db.junkAll or not HAS_OWN_SECTION[rec.classID or -1]) then
    return "Junk", ORDER["Junk"]
  end
  if db.showSets and Cat.setItems[rec.itemID] then return "Equipment Sets", ORDER["Equipment Sets"] end
  if rec.isQuest then return "Quest", ORDER["Quest"] end

  -- 5. grouping mode
  local mode = db.group
  if mode == "none" then
    return "All Items", 50
  elseif mode == "type" then
    local n = className(rec.classID) or "Other"
    if db.showSubtype then
      local sn = subName(rec.classID, rec.subID)
      if sn and sn ~= "" and sn ~= n then n = n .. " - " .. sn end
    end
    return n, 100 + (rec.classID or 99) + (rec.subID or 0) / 100
  elseif mode == "bag" then
    local bag = rec.bag or 0
    local name = (bag == 0 and "Backpack") or (C_Container and C_Container.GetBagName and C_Container.GetBagName(bag)) or ("Bag " .. bag)
    return name, 100 + bag
  elseif mode == "bagtype" then
    local bag = rec.bag or 0
    local kind = "General bags"
    if bag == (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 5) then kind = "Reagent bag"
    elseif bag < 0 then kind = "Keyring" 
    else
      local ok, free, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
      if ok and family and family ~= 0 then kind = "Special bags" end
    end
    return kind, ({ ["General bags"] = 100, ["Special bags"] = 101, ["Reagent bag"] = 102, Keyring = 103 })[kind]
  elseif mode == "expansion" then
    local id = rec.expansionID
    if id == nil then return "Unknown", 999 end
    local name = _G["EXPANSION_NAME" .. id] or ("Expansion " .. id)
    return name, 100 - id
  end
  -- Dedicated inventory IDs only, after existing overrides and grouping modes.
  if CB.CampingData[rec.itemID] then return "Camping", ORDER["Camping"] end
  return builtin(rec)
end

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------
local function cmpName(a, b)
  if a.nameLower ~= b.nameLower then return (a.nameLower or "") < (b.nameLower or "") end
  return (a.count or 1) > (b.count or 1)
end

local sorters = {
  quality = function(a, b)
    if (a.quality or 1) ~= (b.quality or 1) then return (a.quality or 1) > (b.quality or 1) end
    if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
    return cmpName(a, b)
  end,
  name = cmpName,
  ilvl = function(a, b)
    if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
    if (a.quality or 1) ~= (b.quality or 1) then return (a.quality or 1) > (b.quality or 1) end
    return cmpName(a, b)
  end,
  type = function(a, b)
    if (a.classID or 0) ~= (b.classID or 0) then return (a.classID or 0) < (b.classID or 0) end
    if (a.subID or 0) ~= (b.subID or 0) then return (a.subID or 0) < (b.subID or 0) end
    return cmpName(a, b)
  end,
  recent = function(a, b)
    if (a.isNew and true or false) ~= (b.isNew and true or false) then return a.isNew and true or false end
    if (a.bag or 0) ~= (b.bag or 0) then return (a.bag or 0) < (b.bag or 0) end
    return (a.slot or 0) < (b.slot or 0)
  end,
}

--- Groups records into an ordered list of sections:
--- { { name=, order=, items={...}, collapsed=bool }, ... }
--- This only changes presentation: it annotates each record with category and
--- sorts section arrays, never moves inventory. foldPrefix keeps bank collapse
--- state separate from bags while preserving the existing saved section names.
function Cat:Build(records, foldPrefix)
  local byName, list = {}, {}
  for _, rec in ipairs(records) do
    local name, order = Cat:Classify(rec)
    rec.category = name
    local sec = byName[name]
    if not sec then
      sec = { name = name, order = order or 500, items = {} }
      byName[name] = sec
      list[#list + 1] = sec
    end
    sec.items[#sec.items + 1] = rec
  end

  local cmp = sorters[CB.db.sort] or sorters.quality
  local pins = CB.db.pinTop
  local pinned = pins and next(pins) ~= nil
  for _, sec in ipairs(list) do
    if pinned then
      -- items you pinned come first inside their section; the rest keep the chosen sort
      table.sort(sec.items, function(a, b)
        local pa, pb = pins[a.itemID] and 1 or 0, pins[b.itemID] and 1 or 0
        if pa ~= pb then return pa > pb end
        return cmp(a, b)
      end)
    else
      table.sort(sec.items, cmp)
    end
    sec.collapsed = CB.db.collapsed[(foldPrefix or "") .. sec.name] and true or false
  end
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  return list
end

--- All section names the user could pick as a destination (for the item menu).
function Cat:Destinations()
  local out = {}
  local customNames = {}
  for name in pairs(CB.db.custom) do customNames[#customNames + 1] = name end
  table.sort(customNames, function(a, b) return customOrder(a) < customOrder(b) end)
  for _, n in ipairs(customNames) do out[#out + 1] = n end
  for _, n in ipairs(Cat.PINNABLE) do out[#out + 1] = n end
  return out
end

CB:On("DB_READY", function() Cat:RefreshSets() end)
CB:RegisterEvent("EQUIPMENT_SETS_CHANGED", function() Cat:RefreshSets(); CB:Fire("DIRTY") end)
