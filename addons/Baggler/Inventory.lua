-- Baggler inventory: reads the bags into plain item records.
local ADDON, CB = ...
local Inv = {}
CB.Inventory = Inv

local Container = C_Container
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetDetailedItemLevelInfo = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo

---------------------------------------------------------------------------
-- Which containers belong to the backpack view
---------------------------------------------------------------------------
local function enumValue(name, fallback)
  local e = Enum and Enum.BagIndex
  return (e and e[name]) or fallback
end

-- The keyring container: the enum on newer clients (-1 on 1.60.1), bag -2 on older ones.
local function keyringID()
  return (Enum and Enum.BagIndex and Enum.BagIndex.Keyring) or -2
end
Inv.KeyringID = keyringID

-- Container IDs to scan: the backpack, the equipped bags, the reagent bag when present and
-- the keyring when the game shows it.
function Inv:BagIDs()
  local ids = { enumValue("Backpack", 0) }
  for i = 1, 4 do
    ids[#ids + 1] = enumValue("Bag_" .. i, i)
  end
  local reagent = enumValue("ReagentBag", 5)
  if reagent and Container.GetContainerNumSlots(reagent) > 0 then
    ids[#ids + 1] = reagent
  end
  -- keyring: listed for its keys only; Inv:Scan never counts its slots as capacity or free space
  local keyring = keyringID()
  local show = true
  if C_ActionBar and C_ActionBar.ShouldShowKeyring then show = C_ActionBar.ShouldShowKeyring() end
  if show and keyring and (Container.GetContainerNumSlots(keyring) or 0) > 0 then
    ids[#ids + 1] = keyring
  end
  return ids
end

function Inv:IsBackpackBag(bag)
  for _, id in ipairs(Inv:BagIDs()) do
    if id == bag then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------
local function nameFromLink(link)
  return link and link:match("%[(.-)%]") or nil
end

local function isNewItem(bag, slot)
  if C_NewItems and C_NewItems.IsNewItem then
    return C_NewItems.IsNewItem(bag, slot) and true or false
  end
  return false
end

-- Red tint like the default bags: gear the character cannot use (class, level, proficiency).
local usableCache = {}
function Inv:ClearUsable() usableCache = {} end
-- True for weapons and armor the player cannot use (drawn red). Cached per item because the
-- game call is not free; Inv:ClearUsable empties the cache.
local wantedArmor            -- (defined below, with the armour table it needs)

--- True when the item's own tooltip has a red requirement line ("Requires level 20", a weapon or armour type the class
--- cannot use ...). This is what the game's bags tint red, and it is the game's own text, so no class or skill tables
--- are guessed here. nil when the tooltip is not there yet (item data still loading): nothing is decided or cached then.
local function tooltipRed(bag, slot)
  local get = C_TooltipInfo and C_TooltipInfo.GetBagItem
  if not get then return nil end
  local ok, data = pcall(get, bag, slot)
  if not ok or type(data) ~= "table" then return nil end
  if TooltipUtil and TooltipUtil.SurfaceArgs then pcall(TooltipUtil.SurfaceArgs, data) end
  local lines = data.lines
  if type(lines) ~= "table" or #lines == 0 then return nil end
  local issecret = rawget(_G, "issecretvalue")
  for _, line in ipairs(lines) do
    for _, c in ipairs({ line.leftColor, line.rightColor }) do
      if type(c) == "table" and not (issecret and (issecret(c.r) or issecret(c.g))) then
        -- the game's red text colour is (1, 0.125, 0.125); the colour shown for "already known" is not a requirement
        if (c.r or 0) > 0.9 and (c.g or 1) < 0.3 and (c.b or 1) < 0.3 then
          local text = line.leftText or ""
          if not (ITEM_SPELL_KNOWN and text == ITEM_SPELL_KNOWN) then return true end
        end
      end
    end
  end
  return false
end

-- Red means the character cannot use the item. Armour is judged first by its type against what the class wears
-- (certain); anything the character cannot use according to the item's own tooltip is red too, like the game's bags.
-- The result is remembered per item link until a level up, since reading a tooltip is not free.
local function isUnusable(itemID, link, equipLoc, classID, subID, bag, slot)
  if not (classID == 2 or classID == 4) or not equipLoc or equipLoc == "" then return false end
  if classID == 4 and subID and subID >= 1 and subID <= 4 then
    local kind = wantedArmor and wantedArmor()
    if kind and subID > kind then return true end
  end
  local key = link or itemID
  local v = usableCache[key]
  if v == nil then
    v = tooltipRed(bag, slot)
    if v == nil then return false end
    usableCache[key] = v
  end
  return v
end

-- The armour type the character should be wearing (1 cloth, 2 leather, 3 mail, 4 plate). Warriors, paladins, hunters
-- and shamans wear the lighter type until level 40.
local ARMOR_OF_CLASS = { MAGE = 1, PRIEST = 1, WARLOCK = 1, ROGUE = 2, DRUID = 2, MONK = 2, DEMONHUNTER = 2,
  SHAMAN = 3, HUNTER = 3, EVOKER = 3, WARRIOR = 4, PALADIN = 4, DEATHKNIGHT = 4 }
wantedArmor = function()
  local _, class = UnitClass("player")
  local kind = ARMOR_OF_CLASS[class]
  if not kind then return nil end
  if (class == "WARRIOR" or class == "PALADIN" or class == "SHAMAN" or class == "HUNTER") and (UnitLevel("player") or 1) < 40 then
    kind = kind - 1
  end
  return kind
end

-- The comparison service (EquippedCompare) owns slot selection and upgrade measurement.
-- Retain character eligibility here: it is shared with the existing unusable
-- tint policy, so the service does not need its own class/slot table.
local function eligibleUpgrade(candidate)
  local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not info then return false end
  local required = select(5, info(candidate.link))
  local level = UnitLevel and UnitLevel("player")
  if type(required) ~= "number" or type(level) ~= "number" or required > level then return false end
  if candidate.classID == 4 and candidate.subID and candidate.subID >= 1 and candidate.subID <= 4
      and candidate.equipLoc ~= "INVTYPE_CLOAK" then
    return wantedArmor() == candidate.subID
  end
  return true
end
local function isUpgrade(bag, slot, equipLoc, classID, subID, link)
  local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local quality = info and select(3, info(link))
  local candidate = {bag=bag,slot=slot,equipLoc=equipLoc,classID=classID,subID=subID,
    link=link,quality=quality,ilvl=CB.ComparisonHost:Level(link),
    usable=not isUnusable(nil,link,equipLoc,classID,subID,bag,slot)}
  return CB.ComparisonHost:New(eligibleUpgrade):IsUpgrade(candidate)
end
Inv.IsGearUpgrade = isUpgrade -- Public plain function, deliberately not a method.

local function isQuest(bag, slot)
  if Container.GetContainerItemQuestInfo then
    local q = Container.GetContainerItemQuestInfo(bag, slot)
    if q then return (q.isQuestItem or q.questID) and true or false end
  end
  return false
end

--- Sellable junk: grey items plus anything the player marked. Favorites are never junk.
function Inv:IsJunk(rec)
  if not rec or rec.empty or not rec.itemID then return false end
  if CB.db.favorites[rec.itemID] or rec.hasNoValue then return false end
  return rec.quality == 0 or (CB.db.junk and CB.db.junk[rec.itemID]) and true or false
end

-- The bag's family from GetContainerNumFreeSlots (0 = general purpose; nil is treated as
-- general, the backpack and ordinary bags never report a family).
local function bagFamily(bag)
  local get = Container.GetContainerNumFreeSlots
  if not get then return 0 end
  local ok, _, family = pcall(get, bag)
  if ok and type(family) == "number" then return family end
  return 0
end

-- Reads every slot of the given bags (all by default) into item records plus a list of
-- empty slots, followed by total and free counts and a counts table. Missing item info is
-- treated as empty; record-construction errors are logged and excluded from total.
--   total  capacity of the scanned containers, EXCEPT the keyring: GetContainerNumSlots
--          reports its full size, which is neither bag space nor shown by the game.
--   free   empty GENERAL-purpose slots only (bag family 0, like the game's own free count);
--          specialty-bag empties (skinning, herbs, ammo, ...) are counts.specialFree.
--   empties  general empties first, then specialty empties (marked special = true, family);
--          keyring empties are never listed, so "first free slot" is always a general slot.
--   counts { used, specialFree, specialTotal }
-- These are UI snapshots, not proof that a slot is still safe for a later inventory mutation.
-- key = "bag:slot" identifies coordinates, not the item occupying them. Consumers
-- that defer work must re-read identity/locks as appropriate to their operation.
function Inv:Scan(ids)
  local items, empties, specialEmpties = {}, {}, {}
  local total, free, specialFree, specialTotal = 0, 0, 0, 0
  local keyring = keyringID()

  for _, bag in ipairs(ids or Inv:BagIDs()) do
    local numSlots = Container.GetContainerNumSlots(bag) or 0
    local isKeyring = bag == keyring
    local family = (numSlots > 0 and not isKeyring) and bagFamily(bag) or 0
    local special = family ~= 0
    for slot = 1, numSlots do
      if not isKeyring then
        total = total + 1
        if special then specialTotal = specialTotal + 1 end
      end
      local okInfo, info = pcall(Container.GetContainerItemInfo, bag, slot)
      if not okInfo then
        CB:Warn("scan", ("GetContainerItemInfo(%d,%d) failed: %s"):format(bag, slot, tostring(info)))
        info = nil
      end
      if info and info.itemID then
        local ok, rec = pcall(function()
          local itemID = info.itemID
          local link = info.hyperlink
          local _, _, _, equipLoc, _, classID, subID = GetItemInfoInstant(itemID)
          local name = info.itemName or nameFromLink(link) or ""
          local r = {
            bag = bag, slot = slot, key = bag .. ":" .. slot,
            itemID = itemID, link = link, count = info.stackCount or 1,
            quality = info.quality or 1, icon = info.iconFileID,
            locked = info.isLocked and true or false, bound = info.isBound and true or false,
            name = name, nameLower = name:lower(),
            classID = classID, subID = subID, equipLoc = equipLoc,
            isNew = isNewItem(bag, slot), isQuest = isQuest(bag, slot),
            hasNoValue = info.hasNoValue, lootable = info.hasLoot and true or false,
          }
          if classID == 2 or classID == 4 then
            r.ilvl = GetDetailedItemLevelInfo and GetDetailedItemLevelInfo(link) or nil
          end
          if GetItemInfo then
            local _, _, _, _, _, _, _, _, _, _, sellPrice, _, _, _, expansionID = GetItemInfo(link or itemID)
            r.sellPrice = sellPrice
            r.expansionID = expansionID
            local _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(link or itemID)
            r.bindType = bindType
          end
          -- items with charges show how many are left (one item whose charge count exceeds its stack count)
          if r.count == 1 and (classID == 0 or classID == 15 or classID == 12) and GetItemCount then
            local plain, withCharges = GetItemCount(itemID, false, false), GetItemCount(itemID, false, true)
            if plain == 1 and withCharges and withCharges > 1 then r.charges = withCharges end
          end
          r.unusable = isUnusable(itemID, link, equipLoc, classID, subID, bag, slot)
          -- a piece the character cannot use yet, or a grey one, is never offered as an upgrade
          r.upgrade = not r.unusable and (info.quality or 1) > 0 and isUpgrade(bag, slot, equipLoc, classID, subID, link or itemID)
          return r
        end)
        if ok and rec then
          items[#items + 1] = rec
        else
          CB:Warn("scan", ("could not read item at %d:%d (%s)"):format(bag, slot, tostring(rec)))
          if not isKeyring then
            total = total - 1
            if special then specialTotal = specialTotal - 1 end
          end
        end
      elseif not isKeyring then
        local e = { bag = bag, slot = slot, key = bag .. ":" .. slot, empty = true, count = 1, quality = 0 }
        if special then
          e.special, e.family = true, family
          specialFree = specialFree + 1
          specialEmpties[#specialEmpties + 1] = e
        else
          free = free + 1
          empties[#empties + 1] = e
        end
      end
    end
  end
  for _, e in ipairs(specialEmpties) do empties[#empties + 1] = e end
  return items, empties, total, free,
    { used = total - free - specialFree, specialFree = specialFree, specialTotal = specialTotal }
end

---------------------------------------------------------------------------
-- Search. Plain words match the name/type/section; a few power-user tokens:
--   q:epic  q:4   ilvl>400  ilvl<200  ilvl=250  t:armor  c:potions
--   bound  new  junk  fav
---------------------------------------------------------------------------
local QUALITY_NAMES = { poor = 0, junk = 0, gray = 0, grey = 0, common = 1, white = 1,
  uncommon = 2, green = 2, rare = 3, blue = 3, epic = 4, purple = 4, legendary = 5, orange = 5 }

local typeNameCache = {}
local function typeName(rec)
  local c = rec.classID
  if not c then return "" end
  if typeNameCache[c] == nil then
    local f = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
    typeNameCache[c] = (f and f(c) or ""):lower()
  end
  return typeNameCache[c]
end

-- Evaluates one search term of the form key:value or key>value (quality, item level ...)
-- against an item record.
local function matchToken(rec, tok)
  local key, op, val = tok:match("^(%a+)([:<>=])(.+)$")
  if not key then key, op, val = tok:match("^(%a+)([<>=])(.+)$") end
  if key then
    if key == "q" or key == "quality" then
      local want = tonumber(val) or QUALITY_NAMES[val]
      if want == nil then return false end
      if op == ">" then return rec.quality > want end
      if op == "<" then return rec.quality < want end
      return rec.quality == want
    elseif key == "ilvl" or key == "i" then
      local n = tonumber(val)
      if not n or not rec.ilvl then return false end
      if op == ">" then return rec.ilvl > n end
      if op == "<" then return rec.ilvl < n end
      return rec.ilvl == n
    elseif key == "t" or key == "type" then
      return typeName(rec):find(val, 1, true) ~= nil
    elseif key == "c" or key == "cat" then
      return (rec.category or ""):lower():find(val, 1, true) ~= nil
    end
  end
  if tok == "bound" or tok == "soulbound" then return rec.bound end
  if tok == "!bound" or tok == "unbound" then return not rec.bound end
  if tok == "new" then return rec.isNew end
  if tok == "loot" or tok == "lootable" then return rec.lootable and true or false end
  if tok == "junk" then return rec.quality == 0 or (CB.db.junk and CB.db.junk[rec.itemID]) and true or false end
  if tok == "fav" or tok == "favorite" then return CB.db.favorites[rec.itemID] and true or false end
  if rec.nameLower and rec.nameLower:find(tok, 1, true) then return true end
  if typeName(rec):find(tok, 1, true) then return true end
  if rec.category and rec.category:lower():find(tok, 1, true) then return true end
  return false
end

--- query is a lowercase string; every space-separated token must match.
function Inv:Matches(rec, query)
  if not query or query == "" then return true end
  for tok in query:gmatch("%S+") do
    if not matchToken(rec, tok) then return false end
  end
  return true
end

---------------------------------------------------------------------------
-- Change tracking: coalesce bursts of events into one refresh per frame.
---------------------------------------------------------------------------
CB:RegisterEvent("BAG_UPDATE_DELAYED", function() CB:Fire("DIRTY") end)
CB:RegisterEvent("BAG_NEW_ITEMS_UPDATED", function() CB:Fire("DIRTY") end)
CB:RegisterEvent("GET_ITEM_INFO_RECEIVED", function() CB:Fire("DIRTY") end)
CB:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function() CB:Fire("DIRTY") end)
CB:RegisterEvent("INVENTORY_SEARCH_UPDATE", function() CB:Fire("DIRTY") end)
CB:RegisterEvent("UNIT_INVENTORY_CHANGED", function(_, unit) if unit == "player" then CB:Fire("DIRTY") end end)
CB:RegisterEvent("ITEM_LOCK_CHANGED", function() CB:Fire("LOCKS") end)
CB:RegisterEvent("PLAYER_LEVEL_UP", function() Inv:ClearUsable(); CB:Fire("DIRTY") end)
CB:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() CB:Fire("DIRTY") end)
CB:RegisterEvent("BAG_UPDATE_COOLDOWN", function() CB:Fire("COOLDOWNS") end)
CB:RegisterEvent("PLAYER_MONEY", function() CB:Fire("FOOTER") end)
CB:RegisterEvent("BAG_CONTAINER_UPDATE", function() CB:Fire("DIRTY") end)


--- Seconds left on an item's cooldown, or nil when it is ready. Cooldowns of 2 seconds or less are the global
--- cooldown and do not count.
function Inv:CooldownLeft(bag, slot, rec)
  if C_Container and C_Container.GetContainerItemCooldown then
    local ok, start, duration = pcall(C_Container.GetContainerItemCooldown, bag, slot)
    if ok and start and duration and start > 0 and duration > 2 then
      local left = start + duration - GetTime()
      if left > 0 then return left, duration end
    end
  end
  if Inv:IsBandage(rec) then return Inv:BandageLockout() end
  return nil
end

--- Bandages have no cooldown of their own: using one puts "Recently Bandaged" on the player, and that is what stops the
--- next one. Linen to Heavy bandages are consumables of the Bandage subclass.
function Inv:IsBandage(rec)
  return rec ~= nil and rec.classID == 0 and rec.subID == 7
end

local RECENTLY_BANDAGED = 11196
--- Seconds left on "Recently Bandaged" and its full length, or nil when it is not on the player.
function Inv:BandageLockout()
  local expires, duration
  if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, RECENTLY_BANDAGED)
    if ok and type(aura) == "table" then expires, duration = aura.expirationTime, aura.duration end
  end
  if not expires and AuraUtil and AuraUtil.FindAuraByName then
    local ok, name, _, _, _, dur, exp = pcall(AuraUtil.FindAuraByName, "Recently Bandaged", "player", "HARMFUL")
    if ok and name then duration, expires = dur, exp end
  end
  if not expires and UnitDebuff then                       -- the older call, one debuff at a time
    for i = 1, 40 do
      local ok, name, _, _, _, dur, exp = pcall(UnitDebuff, "player", i)
      if not ok or not name then break end
      if name == "Recently Bandaged" then duration, expires = dur, exp break end
    end
  end
  if type(expires) ~= "number" or type(duration) ~= "number" or expires <= 0 then return nil end
  local left = expires - GetTime()
  return left > 0 and left or nil, duration
end
