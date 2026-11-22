-- Baggler window: the item menu, section menu, filter list and window menu.
-- (Split from Window.lua.)
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local View = CB.View
local UI, Inv, Cat, Pad = CB.UI, CB.Inventory, CB.Categories, CB.Pad
local Container = C_Container
local EQUIP_CHOICES, isEquippable = View.EQUIP_CHOICES, View.isEquippable

--- Starts a new group in a menu: a thin line, unless the menu is empty or already ends in one.
local function groupBreak(entries)
  local last = entries[#entries]
  if last and not last.separator then entries[#entries + 1] = { separator = true, text = "" } end
end

--- The frame that owns the game's amount dialog for this window: an invisible plain Frame laid over item button `b`
--- (so the dialog stays anchored to the right tile), with no item-template scripts. It is not a child of the tile, so a
--- tile being hidden or re-laid-out does not reach the dialog; the dialog is closed explicitly when the window closes
--- (hook below) or when its tile is no longer laid out (end of View:Layout).
function View:SplitAnchor(b)
  local W = self
  local a = W.splitAnchor
  if not a then
    a = CreateFrame("Frame", nil, UIParent)
    W.splitAnchor = a
    if W.frame and W.frame.HookScript then
      W.frame:HookScript("OnHide", function()
        local sf = rawget(_G, "StackSplitFrame")
        if sf and sf.owner == a and sf:IsShown() then sf:Hide() end
      end)
    end
  end
  a:ClearAllPoints()
  a:SetAllPoints(b)
  a.cbButton = b
  a:Show()
  return a
end

-- The menu for one item. The first entry changes with context (bank, merchant, mail ...).
function View:ItemMenu(e)
  local W = self
  local rec = e and e.rec
  if not rec or rec.empty then return end
  if rec.equipLoc == "INVTYPE_BAG" then
    local copy = {}; for k, v in pairs(rec) do if type(v) ~= "table" then copy[k] = v end end
    rec = copy -- item-menu callbacks must not retain recycled scan records
  end
  local entries = {}
  local continuation = W:BagReplacementEntry(rec) -- only on the relocated new bag itself
  if continuation then entries[#entries + 1] = continuation end
  local atBank = W:UseContext() == "bank"
  local useText = "Use"
  if atBank then useText = "Move to / from bank"
  elseif W.merchantOpen and (rec.sellPrice or 0) > 0 then
    useText = ((rec.count or 1) > 1 and ("Sell all " .. rec.count .. "  ") or "Sell  ") .. UI:Money(rec.sellPrice * rec.count)
  elseif CB.NativeWindows and W:UseContext() then useText = W:UseLabel(rec) or "Use"
  elseif isEquippable(rec) and rec.equipLoc ~= "INVTYPE_BAG" then useText = "Equip" end
  if rec.equipLoc == "INVTYPE_BAG" then
    entries[#entries + 1] = { text = "Equip bag / Replace bag...", sub = function() return W:BagEquipEntries(rec) end }
  end
  if isEquippable(rec) and rec.equipLoc ~= "INVTYPE_BAG" and (atBank or W:UseContext()) then
    -- another window is making "use" mean sell / deposit / list: Equip must still be one press away
    entries[#entries + 1] = { text = "Equip", func = function() W:Equip(rec, e.btn) end }
  end
  if W:CanSellOne(rec) then
    entries[#entries + 1] = { text = "Sell 1  " .. UI:Money(rec.sellPrice), func = function() W:SellAmount(rec, 1) end }
  end
  -- a secure press where the game allows one (quest items and grimoires are blocked from add-on code)
  if rec.equipLoc ~= "INVTYPE_BAG" or W:UseContext() then
    entries[#entries + 1] = { text = useText, func = function() W:UseItem(rec) end, secureUse = W:SecureUseRec(rec) }
  end
  local choices = rec.equipLoc and EQUIP_CHOICES[rec.equipLoc]
  if choices and not atBank then
    entries[#entries + 1] = { text = "Equip in...", sub = function()
      local list = {}
      for _, c in ipairs(choices) do
        list[#list + 1] = { text = c[2], func = function() W:EquipTo(rec, c[1]) end }
      end
      return list
    end }
  end
  groupBreak(entries)
  entries[#entries + 1] = { text = CB.db.pinTop[rec.itemID] and "Unpin from the top of its section" or "Pin to the top of its section",
    func = function() CB.db.pinTop[rec.itemID] = (not CB.db.pinTop[rec.itemID]) or nil; CB:Fire("DIRTY") end }
  entries[#entries + 1] = { text = CursorHasItem() and "Place here" or "Pick up",
    func = function() W:Pickup(rec) end }
  if rec.count > 1 and StackSplitFrame and StackSplitFrame.OpenStackSplitFrame then
    entries[#entries + 1] = { text = "Split stack", func = function()
      local b = e.btn
      -- The dialog's owner is a plain anchor over the tile, never the item-template button: the game's
      -- ContainerFrameItemButtonMixin:OnHide closes the (global) dialog for any template button flagged hasStackSplit, and
      -- the live trace showed that firing inside the dialog's own Show. The native contract needs only an anchorable
      -- frame with a SplitStack method (StackSplitFrame.lua: owner.hasStackSplit, owner.SplitStack(owner, amount)).
      local bag, slot = b.cbBag, b.cbSlot
      local anchor = W:SplitAnchor(b)
      -- bound to this item and re-checked on confirm: the slot may have changed while the dialog was up
      anchor.SplitStack = function(_, amount)
        local ok, info = pcall(Container.GetContainerItemInfo, bag, slot)
        if not (ok and info and info.itemID == rec.itemID and not info.isLocked and (info.stackCount or 1) >= amount) then return end
        Container.SplitContainerItem(bag, slot, amount)
      end
      if Pad.BeginSplitTrace then Pad:BeginSplitTrace() end   -- read-only: records the game's calls made while it shows
      StackSplitFrame:OpenStackSplitFrame(rec.count, anchor, "BOTTOMRIGHT", "TOPRIGHT")
      if Pad.EndSplitTrace then Pad:EndSplitTrace() end
      -- the game's dialog drives the controller now: hand it over on this press (Reclaim returns it when it closes)
      if Pad.NoteExternalUI then Pad:NoteExternalUI() end
      -- read-only focus snapshots (journal, see /baggler report): at open, then after the hand-off timers have run
      if Pad.FocusProbe then
        Pad:FocusProbe("open")
        if C_Timer and C_Timer.After then
          C_Timer.After(0.4, function() Pad:FocusProbe("+0.4s") end)
          C_Timer.After(1.5, function() Pad:FocusProbe("+1.5s") end)
        end
      end
    end }
  end
  if W.kind == "bags" and CB.ActionBars then
    groupBreak(entries)
    if CB.ActionBars:CanBind(rec) then
      entries[#entries + 1] = { text = "Bind", sub = function() return CB.ActionBars:BindMenu(rec) end }
    end
    entries[#entries + 1] = { text = "Add to action bar", sub = function() return CB.ActionBars:Menu(rec) end }
    entries[#entries + 1] = { text = "Pick up and close bags", func = function()
      -- leaves the item on your cursor with the bags closed, so you can drop it on an action
      -- button with the controller's cursor (or the mouse) exactly as in the base game
      W:Pickup(rec, true)
      W:Close()
    end }
  end
  groupBreak(entries)
  local isFav = CB.db.favorites[rec.itemID]
  entries[#entries + 1] = { text = isFav and "Remove favorite" or "Add to favorites",
    func = function() W:ToggleFavorite(rec) end }
  if rec.quality ~= 0 or CB.db.junk[rec.itemID] then
    entries[#entries + 1] = { text = CB.db.junk[rec.itemID] and "Unmark as junk" or "Mark as junk",
      func = function() W:ToggleJunk(rec) end }
  end
  entries[#entries + 1] = { text = "Move to section", sub = function()
    local list = {}
    list[#list + 1] = { text = "Automatic", checked = CB.db.pins[rec.itemID] == nil,
      func = function() CB.db.pins[rec.itemID] = nil; CB:Fire("DIRTY") end }
    for _, name in ipairs(Cat:Destinations()) do
      list[#list + 1] = { text = name, checked = CB.db.pins[rec.itemID] == name,
        func = function() W:Pin(rec, name) end }
    end
    return list
  end }
  if rec.link then
    entries[#entries + 1] = { text = "Link in chat", func = function()
      if ChatEdit_InsertLink then ChatEdit_InsertLink(rec.link) end
    end }
  end
  -- other Baggler add-ons (CAuction ...) can add entries: CB.menuExtras = { function(rec, view) -> entries|nil }
  if not atBank then
    groupBreak(entries)
    entries[#entries + 1] = { text = "Destroy...", color = CB.COLOR.danger, func = function() local btn = e.btn; C_Timer.After(0, function() W:Destroy(rec, btn) end) end }
  end
  for _, fn in ipairs(CB.menuExtras or {}) do
    local ok, extra = CB:Safe("menuExtras", fn, rec, W)
    if ok and type(extra) == "table" then for _, entry in ipairs(extra) do entries[#entries + 1] = entry end end
  end
  CB.Menu:Open(e.btn, rec.name, entries)
end

function View:SectionMenu(anchor, name)
  local W = self
  CB.Menu:Open(anchor, name, {
    { text = CB.db.collapsed[W:FoldKey(name)] and "Expand" or "Fold", func = function() W:ToggleSection(name) end },
    { text = "Filter to this section", func = function() W.filterCat = name; W:UpdateFilterChip(); W:ApplySearch() end },
    { text = "Unfold all sections", func = function() W:SetAllFolds(false) end },
    { text = "Fold all sections", func = function() W:SetAllFolds(true) end },
  })
end

function View:SelectFirstIfNone()
  local W = self
  if W.selEntry then W:SelectEntry(W.selEntry) elseif W.nav[1] then W:SelectEntry(W.nav[1]) end
end

function View:CleanUp()
  if InCombatLockdown() then CB:Print("can't sort in combat."); return end
  if Container.SortBags then Container.SortBags()
  elseif SortBags then SortBags()
  else CB:Print("this client has no bag sort.") end
end

--- Back to the plain window: no search, no section filter. True when there was something to clear.
function View:ClearSearch()
  local W = self
  if W.query == "" and not W.filterCat then return false end
  if W.frame and W.frame.search then W.frame.search:SetText("") end
  W.query = ""
  W:SetFilter(nil)
  W:RefreshPadHint()
  return true
end

function View:SetFilter(name)
  local W = self
  W.filterCat = name
  if W.frame then W:UpdateFilterChip(); W:ApplySearch() end
end

-- Submenu that lists the sections as filters.
function View:FilterEntries()
  local W = self
  local entries = {
    { text = "All sections", checked = W.filterCat == nil, func = function() W:SetFilter(nil) end },
  }
  local seen = {}
  for _, sec in ipairs(W.sections) do
    if not sec.free and sec.name and not seen[sec.name] then
      seen[sec.name] = true
      local name = sec.name
      entries[#entries + 1] = {
        text = name, checked = W.filterCat == name,
        func = function() W:SetFilter(name) end,
      }
    end
  end
  -- one-press searches, so a controller never has to type
  local quick = { { "Epic or better", "q>3" }, { "Rare or better", "q>2" }, { "Junk", "junk" }, { "New", "new" },
    { "Favorites", "fav" }, { "Armor", "t:armor" }, { "Weapons", "t:weapon" }, { "Unbound", "!bound" } }
  for _, q in ipairs(quick) do
    entries[#entries + 1] = { text = "Show: " .. q[1], checked = W.query == q[2], func = function()
      if W.frame and W.frame.search then W.frame.search:SetText(q[2]) end
    end }
  end
  if W.query ~= "" then
    entries[#entries + 1] = { text = "Clear search", func = function()
      if W.frame and W.frame.search then W.frame.search:SetText("") end
    end }
  end
  if W.ExtraFilters then
    local extra = W:ExtraFilters()
    if type(extra) == "table" then
      for _, e in ipairs(extra) do entries[#entries + 1] = e end
    end
  end
  return entries
end

function View:OpenFilterMenu()
  local W = self
  local anchor = W.frame and W.frame.search or W.frame
  if W.frame and W.frame.filterChip and W.frame.filterChip:IsShown() then anchor = W.frame.filterChip end
  CB.Menu:Open(anchor, "Filter", W:FilterEntries())
end

-- Window-level menu entries: the bank's own buttons first, then layout and filter options.
function View:WindowEntries()
  local W = self
  local entries = {}
  local continuation = W:BagReplacementEntry()
  if continuation then entries[#entries + 1] = continuation end
  -- the bank's Deposit button and tab strip are reachable here, so a controller can use them
  for _, extra in ipairs(W.opts.extraButtons or {}) do
    if extra.onClick and extra.tooltip then
      entries[#entries + 1] = { text = extra.tooltip, func = function() extra.onClick(W) end }
    end
  end
  if W.kind == "bank" and W.BankEntries then
    for _, e in ipairs(W:BankEntries()) do entries[#entries + 1] = e end
  end
  -- fold or open every section at once
  groupBreak(entries)
  entries[#entries + 1] = { text = "Unfold all sections", func = function() W:SetAllFolds(false) end }
  entries[#entries + 1] = { text = "Fold all sections", func = function() W:SetAllFolds(true) end }
  if W.kind == "bank" and W.ExtraFilters then
    local tabs = W:ExtraFilters()
    if #tabs > 0 then entries[#entries + 1] = { text = "Bank tabs", sub = function() return W:ExtraFilters() end } end
  end
  for _, fn in ipairs(CB.windowExtras or {}) do
    local ok, extra = CB:Safe("windowExtras", fn, W)
    if ok and type(extra) == "table" then for _, entry in ipairs(extra) do entries[#entries + 1] = entry end end
  end
  groupBreak(entries)
  if CB.Card then
    entries[#entries + 1] = { text = "Item card: " .. ((CB.db.itemCard ~= false) and "on (turn off)" or "off (turn on)"), func = function() CB.Card:Toggle() end }
  end
  if W.kind == "bags" then
    entries[#entries + 1] = { text = "Use hearthstone", func = function() W:UseHearthstone() end }
  end
  groupBreak(entries)
  entries[#entries + 1] = { text = "Filter sections", sub = function() return W:FilterEntries() end }
  entries[#entries + 1] = { text = "Search", func = function() W:FocusSearch() end }
  entries[#entries + 1] = { text = "Resize window", func = function() W:BeginSize() end }
  entries[#entries + 1] = { text = "Settings", func = function() CB.Options:Toggle() end }
  return entries
end

--- Uses the first hearthstone found in the bags (one press from the window menu).
function View:UseHearthstone()
  if InCombatLockdown() then CB:Print("can't do that in combat."); return end
  local items = Inv:Scan()
  for _, rec in ipairs(items) do
    if CB.Categories:IsHearthstone(rec) then
      local ok, err = pcall(Container.UseContainerItem, rec.bag, rec.slot)
      if not ok then CB:Warn("use", "hearthstone failed: " .. tostring(err)) end
      return
    end
  end
  CB:Print("no hearthstone in your bags.")
end

function View:WindowMenu()
  local W = self
  CB.Menu:Open(W.frame, W.kind == "bank" and "Bank" or "Bags", W:WindowEntries())
end

