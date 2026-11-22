-- Baggler action bars: put a bag item on a bar from the item menu (Y, or Alt-click).
-- Keyboard bars use PlaceAction on the normal slots. The controller bar is the
-- game's Gamepad Action Bar: the same storage slots the pad already presses in
-- the world. This never rebinds those buttons.
local ADDON, CB = ...
local AB = {}
CB.ActionBars = AB

-- name, button-frame prefix, key-binding command prefix, first action slot (fallback only)
local BARS = {
  { "Action Bar 1", "ActionButton",             "ACTIONBUTTON",         1   },
  { "Action Bar 2", "MultiBarBottomLeftButton",  "MULTIACTIONBAR1BUTTON", 61 },
  { "Action Bar 3", "MultiBarBottomRightButton", "MULTIACTIONBAR2BUTTON", 49 },
  { "Action Bar 4", "MultiBarRightButton",       "MULTIACTIONBAR3BUTTON", 25 },
  { "Action Bar 5", "MultiBarLeftButton",        "MULTIACTIONBAR4BUTTON", 37 },
  { "Action Bar 6", "MultiBar5Button",           "MULTIACTIONBAR5BUTTON", 145 },
  { "Action Bar 7", "MultiBar6Button",           "MULTIACTIONBAR6BUTTON", 157 },
  { "Action Bar 8", "MultiBar7Button",           "MULTIACTIONBAR7BUTTON", 169 },
}

--- The real action slot behind button i of a bar (the game moves bar 1's slots with its page).
local function slotOf(bar, i)
  local btn = _G[bar[2] .. i]
  if btn then
    local a = btn.action
    if type(a) ~= "number" and btn.GetAttribute then a = btn:GetAttribute("action") end
    if type(a) == "number" and a > 0 then return a end
  end
  return bar[4] + i - 1
end

--- Bars worth offering: bar 1 always, the others only if the player has them switched on.
function AB:Bars()
  local list = {}
  for index, bar in ipairs(BARS) do
    local first = _G[bar[2] .. "1"]
    if index == 1 or (first and first.IsShown and first:IsShown()) then list[#list + 1] = bar end
  end
  if #list == 0 then list[1] = BARS[1] end
  return list
end

local function bindingText(bar, i)
  local key = GetBindingKey and GetBindingKey(bar[3] .. i)
  if not key then return nil end
  local ok, text = pcall(GetBindingText, key)
  return (ok and text and text ~= "") and text or key
end

-- What a gamepad action slot holds right now, as a menu label: icon plus spell, item or macro name.
local function contentsText(slot)
  if not (HasAction and HasAction(slot)) then return CB.HEX.dim .. "empty|r" end
  local kind, id = GetActionInfo(slot)
  local name
  if kind == "item" then
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    name = info and info(id)
  elseif kind == "spell" then
    name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id) or (GetSpellInfo and GetSpellInfo(id))
  elseif kind == "macro" then
    name = GetActionText and GetActionText(slot)
  end
  name = name or kind or "something"
  local tex = GetActionTexture and GetActionTexture(slot)
  return (tex and ("|T" .. tostring(tex) .. ":14:14:0:0|t ") or "") .. name
end

--- Puts the item in (bag, slot) on an action slot.
function AB:Place(rec, actionSlot, label)
  if InCombatLockdown() then
    CB:Print("can't change action bars in combat.")
    return false
  end
  ClearCursor()
  C_Container.PickupContainerItem(rec.bag, rec.slot)
  if not CursorHasItem() then
    CB:Warn("actionbar", "could not pick up " .. tostring(rec.name))
    CB:Print("couldn't pick that item up.")
    return false
  end
  local ok, err = pcall(PlaceAction, actionSlot)
  ClearCursor()          -- drops whatever the slot held before
  if not ok then
    CB:Error("actionbar", err)
    return false
  end
  CB:Print(("%s -> %s"):format(rec.name or "item", label or ("slot " .. actionSlot)))
  return true
end

-- Gamepad page layout (Blizzard_GamepadActionBars). Four bars of 8 buttons.
-- Page-unit slots 5-8, the face buttons on the top bar, are reserved by the game
-- (targeting and shortcuts) and cannot take an item. The other 28 slots on each
-- of the 3 sets can. Storage indexes come from the client when it exposes them.
local FIRST_RESERVED = 5
local BUTTON_KEYS = {
  "PADDLEFT", "PADDUP", "PADDRIGHT", "PADDDOWN",
  "PAD3", "PAD4", "PAD2", "PAD1", -- face: left, up, right, down (X Y B A)
}

local function num(name, fallback)
  local t = Constants and Constants.GamepadActionBarConstants
  local v = t and t[name]
  if type(v) == "number" and v > 0 then return v end
  return fallback
end

function AB:GamepadReady()
  local util = _G.GamepadActionBarBindingUtil
  if util and util.GetGamepadStorageSlotIndexFromPageAndPageUnitSlotID then return true end
  local api = _G.C_GamepadUI
  return (api and type(api.GetFirstGamepadActionStorageSlotIndex) == "function") and true or false
end

--- Storage slot for one controller button, or nil when that button cannot take an item.
function AB:StorageSlot(page, pageUnitSlotID)
  local util = _G.GamepadActionBarBindingUtil
  if util and util.GetGamepadStorageSlotIndexFromPageAndPageUnitSlotID then
    local ok, slot = pcall(util.GetGamepadStorageSlotIndexFromPageAndPageUnitSlotID, page, pageUnitSlotID)
    if ok then return type(slot) == "number" and slot or nil end
  end
  local pages = num("NUM_STANDARD_PAGES_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT", 3)
  local perPage = num("NUM_PAGEABLE_SLOTS_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT_STANDARD_PAGE", 32)
  local reserved = num("NUM_RESERVED_SLOTS_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT", 4)
  if type(page) ~= "number" or page < 1 or page > pages then return nil end
  if type(pageUnitSlotID) ~= "number" or pageUnitSlotID < 1 or pageUnitSlotID > perPage then return nil end
  if pageUnitSlotID >= FIRST_RESERVED and pageUnitSlotID < FIRST_RESERVED + reserved then return nil end
  local api = C_GamepadUI
  local first = api and api.GetFirstGamepadActionStorageSlotIndex and api.GetFirstGamepadActionStorageSlotIndex()
  if type(first) ~= "number" then return nil end
  local storage = (perPage * (page - 1)) + first + (pageUnitSlotID - 1)
  storage = storage - reserved * (page - 1)
  if pageUnitSlotID >= FIRST_RESERVED then storage = storage - reserved end
  return storage
end

function AB:CurrentPage()
  local frame = rawget(_G, "GamepadMainActionBarFrame")
  local unit = frame and frame.PageUnit
  local pages = num("NUM_STANDARD_PAGES_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT", 3)
  if unit and unit.GetCurrentPage then
    local ok, page = pcall(unit.GetCurrentPage, unit)
    if ok and type(page) == "number" and page >= 1 and page <= pages then return page end
  end
  return 1
end

local function spellName(rec)
  local fn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
  if type(fn) ~= "function" then return nil, false end
  local query = rec.link or rec.itemID
  if not query then return nil, true end
  local ok, name = pcall(fn, query)
  if ok and type(name) == "string" and name ~= "" then return name, true end
  return nil, true
end

--- True when the item can sit on an action button: it has a use, or it equips.
function AB:ItemCanSitOnBar(rec)
  if not rec or rec.empty or not rec.itemID then return false end
  local spell, api = spellName(rec)
  if spell then return true end
  local loc = rec.equipLoc
  if type(loc) == "string" and loc ~= "" then return true end
  local c = rec.classID
  if c == 1 or c == 2 or c == 4 then return true end -- bag, weapon, armor
  -- No spell API at all: consumables and miscellaneous (hearthstone) are the ones
  -- players put on a bar. When the API exists, a missing spell means it cannot.
  if not api and (c == 0 or c == 15) then return true end
  return false
end

function AB:CanBind(rec)
  return AB:GamepadReady() and AB:ItemCanSitOnBar(rec) or false
end

local function barTitle(mod)
  local UI = CB.UI
  if mod == nil then return "Bar" end
  if mod == "both" then return UI:PadLabel("PADLTRIGGER") .. " + " .. UI:PadLabel("PADRTRIGGER") end
  return UI:PadLabel(mod)
end

local function chord(mod, key)
  local button = CB.UI:PadLabel(key)
  if mod == nil then return button end
  if mod == "both" then
    return CB.UI:PadLabel("PADLTRIGGER") .. " + " .. CB.UI:PadLabel("PADRTRIGGER") .. " + " .. button
  end
  return CB.UI:PadLabel(mod) .. " + " .. button
end

--- Puts the item on one controller action slot. Uses the game's own assigner when it is loaded.
function AB:Bind(rec, storage, label)
  if InCombatLockdown() then
    CB:Print("can't change action bars in combat.")
    return false
  end
  if type(storage) ~= "number" then return false end
  local util = _G.GamepadActionBarBindingUtil
  if util and util.AssignActionToGamepadStandardSlot then
    local ok, placed = pcall(util.AssignActionToGamepadStandardSlot, storage, function()
      C_Container.PickupContainerItem(rec.bag, rec.slot)
    end)
    if not ok then
      CB:Error("actionbar", placed)
      ClearCursor()
      return false
    end
    if placed then
      CB:Print(("%s -> %s"):format(rec.name or "item", label or ("slot " .. storage)))
    else
      CB:Print("couldn't bind that.")
    end
    return placed and true or false
  end
  return AB:Place(rec, storage, label)
end

-- Menu rows for the buttons of one bar layer; picking a row binds `rec` to that slot.
function AB:ButtonMenu(rec, page, mod, firstSlot)
  local perBar = num("NUM_SLOTS_PER_GAMEPAD_ACTION_BAR", 8)
  local rows = {}
  for i = 1, perBar do
    local pageSlot = firstSlot + i - 1
    local storage = AB:StorageSlot(page, pageSlot)
    if storage then
      local key = BUTTON_KEYS[i] or ("slot " .. i)
      local shown = BUTTON_KEYS[i] and chord(mod, key) or key
      local slot = storage
      local text = shown
      local placeLabel = ("Set %d, %s"):format(page, shown)
      rows[#rows + 1] = {
        text = text .. "   " .. contentsText(slot),
        func = function() AB:Bind(rec, slot, placeLabel) end,
      }
    end
  end
  return rows
end

-- Top-level menu: one entry per modifier layer (none, left trigger, right trigger, both)
-- that has at least one usable slot on this page.
function AB:BarMenu(rec, page)
  local perBar = num("NUM_SLOTS_PER_GAMEPAD_ACTION_BAR", 8)
  local specs = {
    { nil, 1 },
    { "PADLTRIGGER", 1 + perBar },
    { "PADRTRIGGER", 1 + perBar * 2 },
    { "both", 1 + perBar * 3 },
  }
  local list = {}
  for _, spec in ipairs(specs) do
    local mod, firstSlot = spec[1], spec[2]
    local any = false
    for i = 0, perBar - 1 do
      if AB:StorageSlot(page, firstSlot + i) then any = true; break end
    end
    if any then
      local m, first = mod, firstSlot
      list[#list + 1] = {
        text = barTitle(m),
        sub = function() return AB:ButtonMenu(rec, page, m, first) end,
      }
    end
  end
  return list
end

--- Set, then which bar the triggers select, then the button.
function AB:BindMenu(rec)
  local pages = num("NUM_STANDARD_PAGES_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT", 3)
  local current = AB:CurrentPage()
  local order = { current }
  for p = 1, pages do
    if p ~= current then order[#order + 1] = p end
  end
  local entries = {}
  for _, page in ipairs(order) do
    local pageNum = page
    local text = "Set " .. pageNum
    if pageNum == current then text = text .. "  " .. CB.HEX.info .. "(current)|r" end
    entries[#entries + 1] = {
      text = text,
      sub = function() return AB:BarMenu(rec, pageNum) end,
    }
  end
  return entries
end

--- Menu entries: choose a bar, then a slot (each shows its controller binding and current content).
function AB:Menu(rec)
  local bars = {}
  for _, bar in ipairs(AB:Bars()) do
    bars[#bars + 1] = { text = bar[1], sub = function()
      local slots = {}
      for i = 1, 12 do
        local slot = slotOf(bar, i)
        local bind = bindingText(bar, i)
        local label = ("%s, slot %d%s"):format(bar[1], i, bind and (" [" .. bind .. "]") or "")
        slots[#slots + 1] = {
          text = ("%d%s   %s"):format(i, bind and ("  " .. CB.HEX.info .. "[" .. bind .. "]|r") or "", contentsText(slot)),
          func = function() AB:Place(rec, slot, label) end,
        }
      end
      return slots
    end }
  end
  return bars
end
