-- Baggler extras: auto-repair, low-space warning, other characters' item counts, equipment sets,
-- "open next container", saved searches, quick new sections, and moving a whole section at once.
local ADDON, CB = ...
local UI, Pad, Inv = CB.UI, CB.Pad, CB.Inventory
local X = {}
CB.Extras = X

---------------------------------------------------------------------------
-- Auto-repair at vendors
---------------------------------------------------------------------------
function X:Repair()
  if CB:IsOff("extras") then return end
  if not CB.db.autoRepair or not CanMerchantRepair or not CanMerchantRepair() then return end
  local cost, can = GetRepairAllCost()
  if not can or not cost or cost <= 0 then return end
  local useGuild = false
  if CanGuildBankRepair and CanGuildBankRepair() and GetGuildBankWithdrawMoney then
    local left = GetGuildBankWithdrawMoney()
    useGuild = (left == -1) or (left and left >= cost)
  end
  if not useGuild and GetMoney() < cost then CB:Print("can't afford repairs (" .. UI:Money(cost) .. ")."); return end
  local ok, err = pcall(RepairAllItems, useGuild and true or false)
  if ok then
    CB:Print("repaired for " .. UI:Money(cost) .. (useGuild and " (guild funds)." or "."))
  else
    CB:Warn("repair", "RepairAllItems failed: " .. tostring(err))
  end
end
CB:RegisterEvent("MERCHANT_SHOW", function() C_Timer.After(0.4, function() CB:Safe("repair", X.Repair, X) end) end)

---------------------------------------------------------------------------
-- Low space warning
---------------------------------------------------------------------------
local wasLow = false
function X:CheckSpace()
  if CB:IsOff("extras") then return end
  if not CB.db.lowSpaceWarn then return end
  local free = 0
  for _, bag in ipairs(Inv:BagIDs()) do
    local n = C_Container.GetContainerNumFreeSlots and C_Container.GetContainerNumFreeSlots(bag)
    free = free + (tonumber(n) or 0)
  end
  local low = free <= (CB.db.lowSpaceAt or 4)
  if low and not wasLow then CB:Print((CB.HEX.gold .. "bags nearly full|r - %d free slot%s."):format(free, free == 1 and "" or "s")) end
  wasLow = low
end
local spaceQueued
CB:RegisterEvent("BAG_UPDATE_DELAYED", function()
  if spaceQueued then return end
  spaceQueued = true
  C_Timer.After(1, function() spaceQueued = false; CB:Safe("space", X.CheckSpace, X) end)
end)

---------------------------------------------------------------------------
-- Other characters: snapshots, tooltip lines, /baggler find, /baggler chars
---------------------------------------------------------------------------
local function charKey()
  return (GetRealmName and GetRealmName() or "?") .. "-" .. (UnitName and UnitName("player") or "?")
end

local function countsOf(items)
  local t = {}
  for _, rec in ipairs(items) do t[rec.itemID] = (t[rec.itemID] or 0) + (rec.count or 1) end
  return t
end

-- Saves what this character carries (bags, worn gear, money) so other characters can see it.
-- This is local SavedVariables history, not a remote query. Bank counts update
-- only while a bank is readable and only for the selected type; unvisited bank
-- data can be stale. Remote.lua presents these counts read-only.
function X:Snapshot(withBank)
  if CB:IsOff("extras") then return end
  if not CB.db or not CB.db.chars then return end
  local key = charKey()
  local c = CB.db.chars[key] or {}
  CB.db.chars[key] = c
  local items = Inv:Scan()
  c.bags = countsOf(items)
  c.worn = {}
  for slot = INVSLOT_FIRST_EQUIPPED or 1, INVSLOT_LAST_EQUIPPED or 19 do
    local id = GetInventoryItemID and GetInventoryItemID("player", slot)
    if id then c.worn[id] = (c.worn[id] or 0) + 1 end
  end
  c.money = GetMoney and GetMoney() or 0
  c.name = UnitName and UnitName("player")
  c.class = select(2, UnitClass("player"))
  c.level = UnitLevel and UnitLevel("player")
  c.updated = time and time() or 0
  if withBank and CB.NativeWindows and CB.NativeWindows:Visible("BankFrame") then
    local native = CB.NativeWindows
    local counts = countsOf((Inv:Scan(native:BankBagIDs())))
    local account = Enum and Enum.BankType and Enum.BankType.Account
    if account ~= nil and native:BankType() == account then
      CB.db.account.bank = counts; CB.db.account.updated = time and time() or 0
    else c.bank = counts end
  elseif withBank and CB.Bank and CB.Bank.active then
    local bank = CB.Bank
    local wasWarband = bank.viewType
    -- read whichever bank is showing; the other is refreshed when it is shown
    local ids = bank.BagIDs()
    local counts = countsOf((Inv:Scan(ids)))
    if bank:IsWarband() then CB.db.account.bank = counts; CB.db.account.updated = time and time() or 0
    else c.bank = counts end
  end
end

local snapQueued
local function queueSnapshot()
  if snapQueued then return end
  snapQueued = true
  C_Timer.After(3, function() snapQueued = false; CB:Safe("snapshot", X.Snapshot, X, true) end)
end
CB:RegisterEvent("BAG_UPDATE_DELAYED", queueSnapshot)
CB:RegisterEvent("PLAYERBANKSLOTS_CHANGED", queueSnapshot)
CB:RegisterEvent("BANKFRAME_CLOSED", function() CB:Safe("snapshot", X.Snapshot, X, true) end)
CB:RegisterEvent("PLAYER_LOGOUT", function() CB:Safe("snapshot", X.Snapshot, X, false) end)
CB:On("READY", function() C_Timer.After(5, function() CB:Safe("snapshot", X.Snapshot, X, false) end) end)

local function classColor(class)
  local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
  if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
  return CB.HEX.soft
end

--- Lines like "Aria: bags 3, bank 20" for every other character that has the item.
function X:CountLines(itemID)
  if CB:IsOff("extras") then return {}, 0 end
  local lines, total = {}, 0
  local me = charKey()
  for key, c in pairs(CB.db.chars or {}) do
    local bags, bank, worn = (c.bags or {})[itemID] or 0, (c.bank or {})[itemID] or 0, (c.worn or {})[itemID] or 0
    -- my own bags and gear are already obvious; only my bank (closed) is worth a line
    if key == me then bags, worn = 0, 0 end
    if bags + bank + worn > 0 then
      local parts = {}
      if bags > 0 then parts[#parts + 1] = "bags " .. bags end
      if bank > 0 then parts[#parts + 1] = "bank " .. bank end
      if worn > 0 then parts[#parts + 1] = "worn" end
      lines[#lines + 1] = { ("%s%s|r: %s"):format(classColor(c.class), c.name or key, table.concat(parts, ", ")), bags + bank + worn }
      total = total + bags + bank + worn
    end
  end
  local wb = ((CB.db.account or {}).bank or {})[itemID] or 0
  if wb > 0 then lines[#lines + 1] = { "Warband bank: " .. wb, wb }; total = total + wb end
  table.sort(lines, function(a, b) return a[2] > b[2] end)
  return lines, total
end

-- Other characters' counts at the foot of item tooltips. Only the player's own item tooltip and the tooltip of a
-- clicked chat link get the block; comparison tooltips beside them already repeat the same item.
local ALT_LIMIT = 6
local altMarked = {}      -- [tooltip] = itemID already annotated during the current display

local function altTooltipAllowed(tip)
  return tip ~= nil and (tip == _G.GameTooltip or tip == _G.ItemRefTooltip)
end

local function itemIDFromLink(link)
  if type(link) ~= "string" then return nil end
  return tonumber(link:match("item:(%-?%d+)"))
end

local function appendAltCounts(tip, itemID)
  if not altTooltipAllowed(tip) or type(itemID) ~= "number" then return end
  if not CB.db or not CB.db.showAltCounts then return end
  if altMarked[tip] == itemID then return end
  local lines, total = X:CountLines(itemID)
  if type(lines) ~= "table" or #lines == 0 then return end
  altMarked[tip] = itemID
  local soft, muted = CB.COLOR.soft, CB.COLOR.muted
  tip:AddLine(" ")
  for i = 1, math.min(#lines, ALT_LIMIT) do
    tip:AddLine(lines[i][1], soft[1], soft[2], soft[3])
  end
  if #lines > ALT_LIMIT then
    tip:AddLine(("and %d more"):format(#lines - ALT_LIMIT), muted[1], muted[2], muted[3])
  end
  if #lines > 1 then
    tip:AddLine(("Total elsewhere: %d"):format(total or 0), muted[1], muted[2], muted[3])
  end
  if tip.Show and tip.IsShown and tip:IsShown() then tip:Show() end
end
X.AppendAltCounts = appendAltCounts

-- Installs fn(tooltip, itemID) on item tooltips, through the data post-processor where the client has one and the
-- item-set script otherwise. Returns the name of the route that was used.
local function registerItemTooltipHook(fn)
  local processor = _G.TooltipDataProcessor
  local itemType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
  if processor and processor.AddTooltipPostCall and itemType ~= nil then
    processor.AddTooltipPostCall(itemType, function(tip, data)
      fn(tip, data and data.id)
    end)
    return "post-processor"
  end
  local route
  for _, tip in ipairs({ _G.GameTooltip, _G.ItemRefTooltip }) do
    if tip and tip.HookScript then
      tip:HookScript("OnTooltipSetItem", function(self)
        local _, link = self:GetItem()
        fn(self, itemIDFromLink(link))
      end)
      route = "item-set script"
    end
  end
  return route
end

local altHooked = false
CB:On("READY", function()
  if altHooked then return end
  altHooked = true
  -- A fresh display starts from a cleared tooltip: forget what was annotated on the previous one.
  for _, tip in ipairs({ _G.GameTooltip, _G.ItemRefTooltip }) do
    if tip and tip.HookScript then
      tip:HookScript("OnTooltipCleared", function(self) altMarked[self] = nil end)
    end
  end
  local route = registerItemTooltipHook(function(tip, itemID)
    CB:Safe("altcounts", appendAltCounts, tip, itemID)
  end)
  CB:Info("altcounts", "tooltip counts via " .. tostring(route or "no available hook"))
end)

--- /baggler find <words>: where is it, across every character.
function X:Find(text)
  text = (text or ""):lower()
  if text == "" then CB:Print("usage: /baggler find <item name>"); return end
  local found = 0
  local function check(owner, where, counts)
    for id, n in pairs(counts or {}) do
      local name = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(id)) or (GetItemInfo and GetItemInfo(id))
      if name and name:lower():find(text, 1, true) then
        found = found + 1
        if found <= 12 then CB:Print(("%s - %s: %s x%d"):format(owner, where, name, n)) end
      end
    end
  end
  for key, c in pairs(CB.db.chars or {}) do
    check(c.name or key, "bags", c.bags); check(c.name or key, "bank", c.bank)
  end
  check("Warband", "bank", (CB.db.account or {}).bank)
  if found == 0 then CB:Print("nothing found for '" .. text .. "' (characters are recorded as you play them).")
  elseif found > 12 then CB:Print(("...and %d more."):format(found - 12)) end
end

function X:Chars()
  local n = 0
  for key, c in pairs(CB.db.chars or {}) do
    n = n + 1
    CB:Print(("%s%s|r  lvl %s  %s  (seen %s)"):format(classColor(c.class), c.name or key, tostring(c.level or "?"),
      UI:Money(c.money or 0), c.updated and date("%b %d", c.updated) or "?"))
  end
  if n == 0 then CB:Print("no characters recorded yet.") end
end

---------------------------------------------------------------------------
-- Window menu additions
---------------------------------------------------------------------------
local function sectionMover(W)
  local list = {}
  for _, sec in ipairs(W.sections or {}) do
    if not sec.free and #sec.items > 0 and sec.name ~= "Free Space" and sec.name ~= "Specialty Free" then
      local sc = sec
      list[#list + 1] = { text = ("%s  (%d)"):format(sc.name, #sc.items), func = function()
        local n = 0
        for _, rec in ipairs(sc.items) do
          if rec and not rec.empty then W:UseItem(rec); n = n + 1 end
        end
        CB:Print(("sent %d item%s from %s."):format(n, n == 1 and "" or "s", sc.name))
      end }
    end
  end
  return list
end

-- Menu entries for the player's equipment sets. Choosing one swaps gear, which the game
-- refuses in combat.
function X:SetEntries()
  local out = {}
  if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs then
    for _, id in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
      local name = C_EquipmentSet.GetEquipmentSetInfo(id)
      out[#out + 1] = { text = name or ("Set " .. id), func = function()
        if InCombatLockdown() then CB:Print("can't swap gear in combat."); return end
        C_EquipmentSet.UseEquipmentSet(id)
      end }
    end
  end
  return out
end

function X:OpenNext()
  if InCombatLockdown() then CB:Print("can't do that in combat."); return end
  for _, rec in ipairs(Inv:Scan()) do
    if rec.lootable then
      local ok, err = pcall(C_Container.UseContainerItem, rec.bag, rec.slot)
      if not ok then CB:Warn("use", "open failed: " .. tostring(err)) end
      return
    end
  end
  CB:Print("nothing to open.")
end

StaticPopupDialogs["BAGGLER_SAVE_VIEW"] = {
  text = "Name for this saved search:",
  button1 = ACCEPT or "OK", button2 = CANCEL or "Cancel",
  hasEditBox = 1, maxLetters = 24, timeout = 0, whileDead = 1, hideOnEscape = 1,
  OnAccept = function(self)
    local eb = self.editBox or self.EditBox
    local name = eb and eb:GetText() or ""
    if name ~= "" and X.pendingView then CB.db.views[name] = X.pendingView; CB:Print("saved search '" .. name .. "'.") end
  end,
}

CB.windowExtras = CB.windowExtras or {}
table.insert(CB.windowExtras, function(W)
  local entries = {}
  if W.kind == "bags" then
    local sets = X:SetEntries()
    if #sets > 0 then entries[#entries + 1] = { text = "Equipment sets", sub = function() return X:SetEntries() end } end
    local any
    if Inv then
      for _, e in ipairs(W.nav or {}) do if e.rec and e.rec.lootable then any = true; break end end
    end
    if any then entries[#entries + 1] = { text = "Open next container", func = function() X:OpenNext() end } end
  end
  if Pad:QuickMoveOpen() then
    entries[#entries + 1] = { text = "Send a whole section", sub = function() return sectionMover(W) end }
  end
  -- saved searches
  local names = {}
  for name in pairs(CB.db.views or {}) do names[#names + 1] = name end
  table.sort(names)
  if #names > 0 or (W.query and W.query ~= "") then
    entries[#entries + 1] = { text = "Saved searches", sub = function()
      local list = {}
      for _, name in ipairs(names) do
        local q = CB.db.views[name]
        list[#list + 1] = { text = name, func = function() if W.frame and W.frame.search then W.frame.search:SetText(q) end end }
      end
      if W.query and W.query ~= "" then
        list[#list + 1] = { text = "Save current search...", func = function()
          X.pendingView = W.query
          if StaticPopup_Show then StaticPopup_Show("BAGGLER_SAVE_VIEW") end
        end }
      end
      if #names > 0 then
        list[#list + 1] = { text = "Delete a saved search", sub = function()
          local del = {}
          for _, name in ipairs(names) do
            del[#del + 1] = { text = name, func = function() CB.db.views[name] = nil end }
          end
          return del
        end }
      end
      return list
    end }
  end
  return entries
end)

-- "Make a section from a word in this item's name", straight from the item menu.
CB.menuExtras = CB.menuExtras or {}
table.insert(CB.menuExtras, function(rec, W)
  if not rec or not rec.name then return nil end
  local words = {}
  for w in rec.name:gmatch("%a%a%a+") do
    local lw = w:lower()
    if lw ~= "the" and lw ~= "of" and lw ~= "and" then words[#words + 1] = w end
  end
  if #words == 0 then return nil end
  return { { text = "New section from a word...", sub = function()
    local list = {}
    for _, w in ipairs(words) do
      local word = w
      list[#list + 1] = { text = word, func = function()
        local count = 0
        for _ in pairs(CB.db.custom) do count = count + 1 end
        CB.db.custom[word] = { patterns = { word:lower() }, order = count + 1 }
        CB:Fire("SETTING", "custom")
        CB:Fire("DIRTY")
        CB:Print("new section '" .. word .. "' for items with that word in their name.")
      end }
    end
    return list
  end } }
end)

---------------------------------------------------------------------------
-- Export / import of settings (one pasteable line). /baggler export   /baggler import
---------------------------------------------------------------------------
-- All parsing, schema checks and serialization live in ProfileShare.lua.
-- Commit only after the whole share is accepted; keep
-- the SavedVariables root identity because existing windows retain that reference.
local function sharing()
  return CB.ProfileShare.new({padDefaults=CB.defaults.pad})
end
function X:Export()
  return sharing():Export(CB.db)
end
function X:Import(text)
  local accepted, reason = sharing():Import(text, CB.db)
  if not accepted then CB:Print("Import rejected: " .. tostring(reason)); return false end
  for key in pairs(CB.db) do CB.db[key] = nil end
  for key, value in pairs(accepted) do CB.db[key] = value end
  CB:Fire("SETTING", "import")
  CB:Fire("DIRTY")
  CB:Print("Settings imported; reload to apply settings used only at login.")
  return true
end

StaticPopupDialogs["BAGGLER_EXPORT"] = {
  text = "Your Baggler settings. Select all (Ctrl+A), copy (Ctrl+C):",
  button1 = CLOSE or "Close", hasEditBox = 1, maxLetters = 200000, timeout = 0, whileDead = 1, hideOnEscape = 1,
  OnShow = function(self)
    local eb = self.editBox or self.EditBox
    local text, err = X:Export()
    if not text then
      if eb then eb:SetText("") end
      CB:Print(err)
      self:Hide()
      return
    end
    if eb then eb:SetText(text); eb:HighlightText(); eb:SetFocus() end
  end,
}
StaticPopupDialogs["BAGGLER_IMPORT"] = {
  text = "Paste a Baggler settings line here (Ctrl+V), then press Import:",
  button1 = "Import", button2 = CANCEL or "Cancel", hasEditBox = 1, maxLetters = 200000, timeout = 0, whileDead = 1, hideOnEscape = 1,
  OnAccept = function(self)
    local eb = self.editBox or self.EditBox
    if eb then X:Import(eb:GetText()) end
  end,
}
