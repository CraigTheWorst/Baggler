-- Baggler options: a settings window built from a spec table. Works with mouse
-- and controller (D-pad to move, left/right to change, A to toggle/activate,
-- LB/RB to switch tabs, B to close).
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local O = {}
CB.Options = O
local UI, Pad = CB.UI, CB.Pad

local ROW_H, PAD_X = 30, 14
local WIDTH, HEIGHT = 520, 540

---------------------------------------------------------------------------
-- Value access with dotted keys ("pad.mode", "pad.map.PAD1")
---------------------------------------------------------------------------
local function resolve(key)
  local parts = {}
  for p in key:gmatch("[^.]+") do parts[#parts + 1] = p end
  local t = CB.db
  for i = 1, #parts - 1 do t = t[parts[i]] end
  return t, parts[#parts], parts[1]
end
local function getv(key) local t, k = resolve(key); return t[k] end
local reloadKeys = {}        -- settings that only take effect after a /reload (marked reload = true in the spec)
local function setv(key, v)
  local t, k, top = resolve(key)
  t[k] = v
  CB:Fire("SETTING", top, v)
  if reloadKeys[key] then
    O.reloadNeeded = true
    if O.UpdateReload then O:UpdateReload() end
  end
end

--- The value a setting has out of the box (nil for keys that have none).
local function defaultOf(key)
  local t = CB.defaults
  for part in key:gmatch("[^.]+") do
    if type(t) ~= "table" then return nil end
    t = t[part]
  end
  return t
end

---------------------------------------------------------------------------
-- The settings
---------------------------------------------------------------------------
local function padActionValues()
  local v = {}
  for _, a in ipairs(Pad.ACTIONS) do v[#v + 1] = a end
  v[#v + 1] = false
  return v
end

-- The settings screen as data: tabs, each a list of rows (caption, toggle, slider, cycle,
-- button). The row builders below turn each spec into widgets, so adding a setting is one line.
local function build()
  local spec = {
    { tab = "Look", rows = {
      { type = "caption", label = "Window" },
      { type = "slider", key = "scale", label = "Window scale", min = 0.6, max = 1.6, step = 0.05, fmt = "%.2f" },
      { type = "slider", key = "iconSize", label = "Item size", min = 28, max = 52, step = 1, fmt = "%d" },
      { type = "slider", key = "spacing", label = "Item spacing", min = 0, max = 10, step = 1, fmt = "%d" },
      { type = "slider", key = "vendorColumns", label = "Vendor items per row", min = 4, max = 12, step = 1, fmt = "%d" },
      { type = "slider", key = "columns", label = "Items per row", min = 6, max = 24, step = 1, fmt = "%d" },
      { type = "slider", key = "bgAlpha", label = "Background opacity", min = 0.3, max = 1, step = 0.02, fmt = "%.2f" },
      { type = "slider", key = "fontScale", label = "Text size", min = 0.9, max = 1.2, step = 0.05, fmt = "%.2f" },
      { type = "cycle", key = "font", label = "Font", values = UI.FONT_NAMES },
      { type = "cycle", key = "accent", label = "Accent colour", values = CB.accentList },
      { type = "toggle", key = "locked", label = "Lock window position and size" },
      { type = "caption", label = "Items" },
      { type = "toggle", key = "showBorders", label = "Quality-coloured borders" },
      { type = "toggle", key = "qualityMarks", label = "Quality letter on rare and better items" },
      { type = "toggle", key = "showIlvl", label = "Item level on gear" },
      { type = "toggle", key = "sellProtect", label = "Protect favorites, set and epic items from sale" },
      { type = "toggle", key = "askEquipSlot", label = "Ask which ring / trinket to replace" },
      { type = "toggle", key = "alwaysCompare", label = "Always compare gear with what you wear" },
      { type = "toggle", key = "autoUnfold", label = "Unfold a section when something new lands in it" },
      { type = "toggle", key = "rowWrap", label = "Left / right wraps onto the next row" },
      { type = "toggle", key = "itemCard", label = "Item card beside the highlighted item" },
      { type = "toggle", key = "cardCompare", label = "Item card compares gear with what you wear" },
      { type = "cycle", key = "cardSide", label = "Item card side", values = { "auto", "left", "right" } },
      { type = "toggle", key = "tooltipHints", label = "Show what each button does in item tooltips" },
      { type = "toggle", key = "qualityFocus", label = "Selection ring in the item's quality colour" },
      { type = "toggle", key = "showBoE", label = "BoE / BoU text on unbound gear" },
      { type = "toggle", key = "showUpgrade", label = "Gold shine on better gear" },
      { type = "toggle", key = "tintUnusable", label = "Red tint on gear you cannot use" },
      { type = "toggle", key = "showNewGlow", label = "Mark new items" },
      { type = "toggle", key = "dimJunk", label = "Dim junk (grey) items" },
      { type = "toggle", key = "showBagSlots", label = "Show equipped-bag slots" },
      { type = "toggle", key = "showFooter", label = "Show gold and free slots" },
    } },
    { tab = "Organise", rows = {
      { type = "caption", label = "Grouping" },
      { type = "cycle", key = "group", label = "Group items by", values = { "category", "type", "expansion", "bag", "bagtype", "none" } },
      { type = "toggle", key = "showSubtype", label = "Show subtype (group by type)" },
      { type = "cycle", key = "sort", label = "Sort items by", values = { "quality", "name", "ilvl", "type", "recent" } },
      { type = "cycle", key = "emptyMode", label = "Empty slots", values = { "collapse", "show", "hide" } },
      { type = "caption", label = "Sections" },
      { type = "toggle", key = "sectionCounts", label = "Show item counts in headers" },
      { type = "toggle", key = "newSection", label = "'New' section for fresh items" },
      { type = "toggle", key = "favSection", label = "'Favorites' section" },
      { type = "toggle", key = "separateJunk", label = "Separate 'Junk' section" },
      { type = "toggle", key = "junkAll", label = "All grey items go in Junk (armor, weapons too)" },
      { type = "toggle", key = "showSets", label = "'Equipment Sets' section" },
      { type = "toggle", key = "splitTradeGoods", label = "Split trade goods by profession" },
    } },
    { tab = "Behaviour", rows = {
      { type = "caption", label = "Automation" },
      { type = "toggle", key = "replaceVendor", label = "Replace the vendor window", reload = true },
      { type = "toggle", key = "replaceGuildBank", label = "Replace the guild bank window" },
      { type = "toggle", key = "replaceTrainer", label = "Replace the trainer window" },
      { type = "toggle", key = "ahSwitch", label = "Allow focus switching to other native windows" },
      { type = "toggle", key = "replaceLoot", label = "Replace the loot window" },
      { type = "toggle", key = "replaceMail", label = "Replace the mailbox window", reload = true },
      { type = "toggle", key = "replaceTrade", label = "Replace the trade window", reload = true },
      { type = "toggle", key = "autoOpen", label = "Open at vendors, mail, trade, auction" },
      { type = "toggle", key = "autoSellJunk", label = "Auto-sell grey items at vendors" },
      { type = "toggle", key = "autoRepair", label = "Repair gear at vendors (guild funds first)" },
      { type = "toggle", key = "lowSpaceWarn", label = "Warn when the bags are nearly full" },
      { type = "toggle", key = "showAltCounts", label = "Other characters' item counts in tooltips" },
      { type = "toggle", key = "closeOnCombat", label = "Close bags when combat starts" },
      { type = "toggle", key = "animations", label = "Subtle animations" },
      { type = "toggle", key = "reduceMotion", label = "Reduce motion (fades only)" },
      { type = "toggle", key = "highContrast", label = "High contrast (brighter edges and text)" },
      { type = "toggle", key = "sounds", label = "Open and close sounds" },
      { type = "caption", label = "Maintenance" },
      { type = "button", label = "Clear favorites, pins and folded sections", onClick = function()
          CB.db.favorites, CB.db.pins, CB.db.collapsed = {}, {}, {}
          CB:Fire("SETTING", "pins")
          CB:Print("cleared.")
        end },
      { type = "button", label = "Reset window positions and sizes", onClick = function() CB:ResetWindowPlaces() end },
    } },
  }

  local pad = { tab = "Controller", rows = {
    { type = "caption", label = "Navigation" },
    { type = "cycle", key = "pad.mode", label = "Controller navigation", values = { "auto", "on", "off" } },
    { type = "toggle", key = "pad.hints", label = "Show button hints" },
    { type = "cycle", key = "pad.backend", label = "Input method (catcher cannot use or sell)", values = { "bindings", "catcher" } },
    { type = "cycle", key = "pad.style", label = "Button labels", values = { "xbox", "playstation", "nintendo", "text" } },
    { type = "toggle", key = "pad.stickNav", label = "Left stick also navigates (stops movement)" },
    { type = "caption", label = "Button mapping" },
  } }
  for _, key in ipairs(Pad.MAPPABLE) do
    pad.rows[#pad.rows + 1] = { type = "padmap", key = "pad.map." .. key, padKey = key }
  end
  spec[#spec + 1] = pad
  O.specByTab = {}
  for _, def in ipairs(spec) do
    if CB.NativeWindows and def.rows then
      for i = #def.rows, 1, -1 do
        local key = def.rows[i].key
        if key and key:match("^replace") and key ~= "replaceDefault" and key ~= "replaceBank" then table.remove(def.rows, i) end
      end
    end
    O.specByTab[def.tab] = def
    for _, rowSpec in ipairs(def.rows or {}) do
      if rowSpec.reload and rowSpec.key then reloadKeys[rowSpec.key] = true end
    end
    if def.rows then
      local tab = def.tab
      def.rows[#def.rows + 1] = { type = "caption", label = "Reset" }
      def.rows[#def.rows + 1] = { type = "button", label = "Put this tab's settings back to their defaults",
        onClick = function() O:ResetTab(tab) end }
    end
  end
  spec[#spec + 1] = { tab = "Sections", custom = true }
  return spec
end

---------------------------------------------------------------------------
-- Row widgets
---------------------------------------------------------------------------
local function newRow(page, label)
  local row = NewFrame("Button", nil, page.content)
  row:SetHeight(ROW_H)
  row.sel = row:CreateTexture(nil, "BACKGROUND")
  row.sel:SetAllPoints()
  row.sel:Hide()
  row.label = row:CreateFontString(nil, "OVERLAY", "BagglerFont")
  row.label:SetPoint("LEFT", 8, 0)
  row.label:SetText(label or "")
  row.div = row:CreateTexture(nil, "BACKGROUND")
  UI:Line(row.div, "h", 1)
  row.div:SetPoint("BOTTOMLEFT", 0, 0); row.div:SetPoint("BOTTOMRIGHT", 0, 0)
  row.div:SetColorTexture(1, 1, 1, 0.035)
  row:SetScript("OnEnter", function(self)
    if not self.skip then
      if O.tabFocus then O:FocusTabs(false) end
      O:Focus(page, self.index, true)
    end
  end)
  return row
end

local function makeCaption(page, spec)
  local row = newRow(page, "")
  row.skip = true
  row.div:Hide()
  row.tick = row:CreateTexture(nil, "ARTWORK")
  UI:Line(row.tick, "w", 2); row.tick:SetHeight(10)
  row.tick:SetPoint("LEFT", 8, -4)
  row.label:SetFontObject("BagglerFontHeader")
  row.label:ClearAllPoints()
  row.label:SetPoint("LEFT", 16, -4)
  row.label:SetText((spec.label or ""):upper())
  function row.refresh()
    local r, g, b = CB:Accent()
    row.tick:SetColorTexture(r, g, b, 1)
  end
  row.activate = function() end
  row.adjust = function() end
  return row
end

local function makeToggle(page, spec)
  local row = newRow(page, spec.label)
  local box = NewFrame("Frame", nil, row, "BackdropTemplate")
  box:SetSize(18, 18)
  box:SetPoint("RIGHT", -8, 0)
  UI:Backdrop(box, UI.panel, UI.border)
  box.fill = box:CreateTexture(nil, "OVERLAY")
  box.fill:SetPoint("TOPLEFT", 3, -3); box.fill:SetPoint("BOTTOMRIGHT", -3, 3)
  function row.refresh()
    local r, g, b = CB:Accent()
    box.fill:SetColorTexture(r, g, b, 1)
    box.fill:SetShown(getv(spec.key) and true or false)
  end
  function row.activate()
    setv(spec.key, not getv(spec.key))
    local on = getv(spec.key) and true or false
    row.refresh()
    box.fill:Show()
    UI:Animate(box, "fill", 0.14, function(p)
      box.fill:SetAlpha(on and p or (1 - p))
      box.fill:SetSize((box:GetWidth() - 6) * (on and (0.6 + 0.4 * p) or (1 - 0.4 * p)), (box:GetHeight() - 6) * (on and (0.6 + 0.4 * p) or (1 - 0.4 * p)))
    end, function() box.fill:SetShown(on); box.fill:SetAlpha(1) end)
  end
  function row.adjust() row.activate() end
  row:SetScript("OnClick", row.activate)
  return row
end

local function makeCycle(page, spec, valueText)
  local row = newRow(page, spec.label)
  local btn = UI:Button(row, "", spec.valueWidth or 150, 22)
  btn:SetPoint("RIGHT", -8, 0)
  -- The shared button's centered label is unconstrained. Settings values can
  -- be much longer: keep a readable body font and let the client truncate.
  btn.text:ClearAllPoints()
  btn.text:SetPoint("TOPLEFT", 8, -2)
  btn.text:SetPoint("BOTTOMRIGHT", -8, 2)
  btn.text:SetWordWrap(false)
  btn.text:SetNonSpaceWrap(false)
  btn.text:SetMaxLines(1)
  row.label:SetPoint("RIGHT", btn, "LEFT", -8, 0)
  row.label:SetJustifyH("LEFT")
  row.label:SetWordWrap(false)
  row.label:SetNonSpaceWrap(false)
  row.label:SetMaxLines(1)
  row.valueButton = btn
  local values = spec.values
  local function index()
    local cur = getv(spec.key)
    for i, v in ipairs(values) do if v == cur then return i end end
    return 1
  end
  function row.refresh()
    local v = getv(spec.key)
    btn.text:SetText(valueText and valueText(v) or tostring(v))
  end
  local function step(dir)
    local i = index() + dir
    if i > #values then i = 1 elseif i < 1 then i = #values end
    setv(spec.key, values[i])
    row.refresh()
  end
  function row.activate() step(1) end
  function row.adjust(dir) step(dir) end
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:SetScript("OnClick", function(_, b) step(b == "RightButton" and -1 or 1) end)
  row:SetScript("OnClick", row.activate)
  return row
end

local function makeSlider(page, spec)
  local row = newRow(page, spec.label)
  local val = row:CreateFontString(nil, "OVERLAY", "BagglerFontMuted")
  val:SetPoint("RIGHT", -8, 0)
  val:SetWidth(44); val:SetJustifyH("RIGHT")
  local s = NewFrame("Slider", nil, row, "BackdropTemplate")
  s:SetOrientation("HORIZONTAL")
  s:SetSize(150, 14)
  s:SetPoint("RIGHT", val, "LEFT", -8, 0)
  s:SetBackdrop({ bgFile = UI.WHITE })
  s:SetBackdropColor(UI.panel[1], UI.panel[2], UI.panel[3], 1)
  s:SetThumbTexture(UI.WHITE)
  local thumb = s:GetThumbTexture()
  thumb:SetSize(8, 14)
  s:SetMinMaxValues(spec.min, spec.max)
  s:SetValueStep(spec.step)
  if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
  local function show(v) val:SetText(string.format(spec.fmt or "%s", v)) end
  function row.refresh()
    local r, g, b = CB:Accent()
    thumb:SetColorTexture(r, g, b, 1)
    row.updating = true
    s:SetValue(getv(spec.key))
    row.updating = false
    show(getv(spec.key))
  end
  s:SetScript("OnValueChanged", function(_, v)
    if row.updating then return end
    local step = spec.step
    v = math.floor(v / step + 0.5) * step
    setv(spec.key, v)
    show(v)
  end)
  function row.adjust(dir)
    local v = getv(spec.key) + dir * spec.step
    v = math.max(spec.min, math.min(spec.max, v))
    setv(spec.key, v)
    row.refresh()
  end
  function row.activate() end
  return row
end

local function makeButton(page, spec)
  local row = newRow(page, "")
  local btn = UI:Button(row, spec.label, 300, 22)
  btn:SetPoint("LEFT", 8, 0)
  btn:SetScript("OnClick", spec.onClick)
  function row.refresh() end
  function row.activate() spec.onClick() end
  function row.adjust() end
  row:SetScript("OnClick", spec.onClick)
  return row
end

local function padActionText(v)
  if not v then return "unassigned" end
  if v == "switchWindow" then return "Switch window" end
  return Pad.ACTION_LABEL[v] or v
end

local makeRowInner
local function makeRow(page, spec)
  local row = makeRowInner(page, spec)
  if spec.reload and row and row.label then
    row.label:SetText(spec.label .. "   " .. CB.HEX.dim .. "needs reload|r")
  end
  return row
end

-- Dispatches a row spec to the builder for its type.
function makeRowInner(page, spec)
  if spec.type == "caption" then return makeCaption(page, spec)
  elseif spec.type == "toggle" then return makeToggle(page, spec)
  elseif spec.type == "slider" then return makeSlider(page, spec)
  elseif spec.type == "button" then return makeButton(page, spec)
  elseif spec.type == "padmap" then
    local row = makeCycle(page, { key = spec.key, values = padActionValues(), label = "", valueWidth = 230 }, padActionText)
    local refresh = row.refresh
    function row.refresh()
      refresh()
      row.label:SetText("Button: " .. UI:PadLabel(spec.padKey))
    end
    row.padKey = spec.padKey
    local btn = row.valueButton
    btn:HookScript("OnEnter", function(self)
      local action = getv(spec.key)
      local full = action and Pad.ACTION_LABEL[action]
      if full then
        UI.Tip:SetOwner(self, "ANCHOR_TOP")
        UI.Tip:SetText(full, 1, 1, 1)
        UI.Tip:Show()
      end
    end)
    btn:HookScript("OnLeave", function() UI:HideTip() end)
    return row
  end
  local text
  if spec.key == "accent" then text = function(v) return CB:AccentLabel(v) end end
  return makeCycle(page, spec, text)
end

---------------------------------------------------------------------------
-- Custom sections page
---------------------------------------------------------------------------
local function buildSectionsPage(page)
  page.dynamic = function()
    -- rebuild rows from the saved custom sections
    for _, r in ipairs(page.rows) do r:Hide() end
    page.rows = {}
    local names = {}
    for name in pairs(CB.db.custom) do names[#names + 1] = name end
    table.sort(names, function(a, b) return (CB.db.custom[a].order or 0) < (CB.db.custom[b].order or 0) end)

    local function addRow(row) row.index = #page.rows + 1; page.rows[row.index] = row end

    -- form row
    if not page.form then
      local form = newRow(page, "")
      form:SetHeight(94)
      local function label(text, x, y, role)
        local fs = form:CreateFontString(nil, "OVERLAY", role or "BagglerFontMuted")
        fs:SetPoint("TOPLEFT", x, y); fs:SetText(text)
        return fs
      end
      form.nameLabel = label("1. Section name", 8, -4, "BagglerFontHeader")
      form.matchLabel = label("2. Item name contains", 158, -4, "BagglerFontHeader")
      label("Example: My supplies", 8, -62)
      label("Example: potion, elixir", 158, -62)
      local nameBox = NewFrame("EditBox", nil, form, "BackdropTemplate")
      nameBox:SetSize(138, 26); nameBox:SetPoint("TOPLEFT", 8, -28)
      nameBox:SetAutoFocus(false); nameBox:SetFontObject("BagglerFont"); nameBox:SetTextInsets(6, 6, 0, 0)
      UI:Backdrop(nameBox, UI.panel, UI.border)
      local patBox = NewFrame("EditBox", nil, form, "BackdropTemplate")
      patBox:SetSize(224, 26); patBox:SetPoint("TOPLEFT", 158, -28)
      patBox:SetAutoFocus(false); patBox:SetFontObject("BagglerFont"); patBox:SetTextInsets(6, 6, 0, 0)
      UI:Backdrop(patBox, UI.panel, UI.border)
      local add = UI:Button(form, "Add", 64, 26)
      add:SetPoint("LEFT", patBox, "RIGHT", 8, 0)
      local function submit()
        local name = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then CB:Print("give the section a name first."); return end
        local patterns = {}
        for piece in (patBox:GetText() or ""):gmatch("[^,]+") do
          local q = piece:lower():gsub("^%s+", ""):gsub("%s+$", "")
          if q ~= "" then patterns[#patterns + 1] = q end
        end
        local count = 0
        for _ in pairs(CB.db.custom) do count = count + 1 end
        CB.db.custom[name] = { patterns = patterns, order = count + 1 }
        nameBox:SetText(""); patBox:SetText("")
        nameBox:ClearFocus(); patBox:ClearFocus()
        CB:Fire("SETTING", "custom")
        O:ShowPage(page.name)
      end
      add:SetScript("OnClick", submit)
      nameBox:SetScript("OnEnterPressed", function() patBox:SetFocus() end)
      patBox:SetScript("OnEnterPressed", submit)
      nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
      patBox:SetScript("OnEscapePressed", patBox.ClearFocus)
      form.refresh = function() end
      form.focusWhich = form.focusWhich or "name"
      form.nameBox, form.patBox = nameBox, patBox
      local function watch(box, which)
        box:SetScript("OnEditFocusGained", function()
          O.edit = box
          form.focusWhich = which
          Pad:Yield(true)
          O:UpdateHint()
        end)
        box:SetScript("OnEditFocusLost", function()
          if O.edit == box then O.edit = nil end
          Pad:Yield(false)
          O:UpdateHint()
        end)
      end
      watch(nameBox, "name")
      watch(patBox, "pat")
      function form.adjust()
        form.focusWhich = form.focusWhich == "pat" and "name" or "pat"
        local box = form.focusWhich == "pat" and patBox or nameBox
        box:SetFocus()
      end
      function form.activate()
        local name = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then
          if form.focusWhich == "name" and O.edit == nameBox then
            CB:Print("Give the section a name first. Typing uses a keyboard, or the on-screen keyboard if the game shows one.")
          end
          form.focusWhich = "name"
          nameBox:SetFocus()
          return
        end
        if form.focusWhich ~= "pat" then
          form.focusWhich = "pat"
          patBox:SetFocus()
          return
        end
        submit()
      end
      form:SetScript("OnClick", form.activate)
      page.form = form
    end
    page.form:Show()
    addRow(page.form)

    local hint = page.hint
    if not hint then
      hint = page.content:CreateFontString(nil, "OVERLAY", "BagglerFontMuted")
      hint:SetText(CB.HEX.gold .. "CREATE A SECTION|r\n" ..
        "1. Name the heading shown in your bags.\n" ..
        "2. Enter parts of item names, separated by commas.\n" ..
        "Matches any entry, ignoring case: potion also matches Healing Potion.\n" ..
        "Names only: literal text, not types, item IDs or wildcard patterns.\n\n" ..
        CB.HEX.gold .. "ADD / UPDATE|r\n" ..
        "Add saves immediately; the same section name replaces its match list.\n" ..
        "Leave matches blank for a manual-only section; assign items via their menu.\n" ..
        "Pins, Favorites, New, Hearthstone and Soul Shards can take priority.\n\n" ..
        CB.HEX.gold .. "SAVED SECTIONS|r\n" ..
        (#names == 0 and "None yet. Try My supplies with potion, elixir above.\n" or "Saved rows above show the heading and its matches.\n") ..
        "Activate a saved row to confirm deletion. Add does not move items.\n" ..
        "Use Activate to focus name, then matches, then save; Back leaves a field.\n" ..
        "Typing needs a keyboard, or the game's on-screen keyboard if available.")
      hint:SetJustifyH("LEFT")
      page.hint = hint
    end

    -- Refresh the empty-state explanation after create/delete.
    page.hint:SetText((page.hint:GetText():gsub(
      #names == 0 and "Saved rows above show the heading and its matches%." or "None yet%. Try My supplies with potion, elixir above%.",
      #names == 0 and "None yet. Try My supplies with potion, elixir above." or "Saved rows above show the heading and its matches.")))
    for _, name in ipairs(names) do
      local def = CB.db.custom[name]
      local row = newRow(page, name)
      row.label:SetWidth(140); row.label:SetJustifyH("LEFT")
      local pats = row:CreateFontString(nil, "OVERLAY", "BagglerFontMuted")
      pats:SetPoint("LEFT", 160, 0)
      pats:SetWidth(220); pats:SetWordWrap(false); pats:SetJustifyH("LEFT")
      pats:SetText(#def.patterns > 0 and table.concat(def.patterns, ", ") or "(manual only)")
      local del = UI:Button(row, "Delete", 60, 22)
      del:SetPoint("RIGHT", -8, 0)
      local function ask()
        CB.Menu:Open(del, "Delete '" .. name .. "'?", {
          { text = "Delete", func = function()
              CB.db.custom[name] = nil
              for id, pin in pairs(CB.db.pins) do if pin == name then CB.db.pins[id] = nil end end
              CB:Fire("SETTING", "custom")
              O:ShowPage(page.name)
            end },
          { text = "Cancel" },
        })
      end
      del:SetScript("OnClick", ask)
      row.refresh = function() end
      row.adjust = function() end
      row.activate = ask
      row:SetScript("OnClick", ask)
      addRow(row)
    end
  end
end

---------------------------------------------------------------------------
-- Page / tab handling
---------------------------------------------------------------------------
local function layoutPage(page)
  local y = 6
  for i, row in ipairs(page.rows) do
    row.index = i
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetPoint("TOPRIGHT", 0, -y)
    row:Show()
    if row.refresh then row.refresh() end
    row.layoutTop = y
    y = y + row:GetHeight()
  end
  if page.hint then
    page.hint:ClearAllPoints()
    page.hint:SetPoint("TOPLEFT", 8, -(y + 8))
    page.hint:SetWidth(WIDTH - 70)
    page.hint:Show()
    y = y + math.ceil(page.hint:GetStringHeight()) + 16
  end
  page.content:SetSize(WIDTH - 36, y + 6)
  page.height = y + 6
end

local function nextFocusable(page, from, dir)
  local n = #page.rows
  local i = from
  for _ = 1, n do
    i = i + dir
    if i > n then i = 1 elseif i < 1 then i = n end
    if not page.rows[i].skip then return i end
  end
  return from
end

-- Moves the row highlight and, for controller or keyboard navigation, scrolls the row into view.
function O:Focus(page, index, fromMouse)
  if not page or not page.rows[index] or page.rows[index].skip then return end
  if page.focus and page.rows[page.focus] then page.rows[page.focus].sel:Hide() end
  page.focus = index
  local row = page.rows[index]
  local r, g, b = CB:Accent()
  row.sel:SetColorTexture(r, g, b, 0.14)
  row.sel:Show()
  if not fromMouse then
    local top = row.layoutTop or (index - 1) * ROW_H
    local bottom = top + row:GetHeight() + 6
    local cur, view = page.scroll:GetVerticalScroll(), page.scroll:GetHeight()
    if top < cur then page.scroll:SetVerticalScroll(top)
    elseif bottom > cur + view then page.scroll:SetVerticalScroll(bottom - view) end
  end
end

-- Shows one tab's page, hides the others and slides the underline under the tab.
function O:ShowPage(name)
  -- A mouse/shoulder tab change must not leave a hidden field owning typing.
  if O.edit then O.edit:ClearFocus() end
  local f = O.frame
  for pname, page in pairs(O.pages) do
    local on = pname == name
    page.scroll:SetShown(on)
    if page.tabBtn then
      UI:SetFocused(page.tabBtn, O.tabFocus and on or false)
      if on then
        local r, g, b = CB:Accent()
        UI:SlideUnderline(O.frame, page.tabBtn, r, g, b)
        page.tabBtn.text:SetTextColor(unpack(CB.COLOR.white))
      else
        page.tabBtn.text:SetTextColor(unpack(CB.COLOR.muted))
      end
    end
    if on then
      if page.dynamic then page.dynamic() end
      layoutPage(page)
      O.current = page
      if not page.focus or not page.rows[page.focus] or page.rows[page.focus].skip then
        page.focus = nextFocusable(page, 0, 1)
      end
      O:Focus(page, page.focus, true)
      if O.tabFocus and page.rows[page.focus] then page.rows[page.focus].sel:Hide() end
    end
  end
end

-- Keep the existing settings context/shoulder map; the first row's Up is the
-- missing return edge to the ordinary tab buttons, not another input owner.
function O:FocusTabs(on)
  O.tabFocus = on and true or false
  for _, page in pairs(O.pages) do
    UI:SetFocused(page.tabBtn, O.tabFocus and page == O.current or false)
  end
  if O.current then
    if O.tabFocus then
      local row = O.current.rows[O.current.focus or 1]
      if row then row.sel:Hide() end
    else
      O:Focus(O.current, nextFocusable(O.current, 0, 1))
    end
  end
end

function O:RefreshAll()
  if not O.frame then return end
  for _, page in pairs(O.pages) do
    for _, row in ipairs(page.rows) do if row.refresh then row.refresh() end end
  end
end

function O:SwitchTab(delta)
  local idx
  for i, n in ipairs(O.tabOrder) do if O.current and n == O.current.name then idx = i end end
  idx = ((idx or 1) - 1 + delta) % #O.tabOrder + 1
  O:ShowPage(O.tabOrder[idx])
end

-- Size limits for the shared resize mode.
function O:ResizeCfg()
  return {
    mode = "pixel",
    step = 40,
    minW = WIDTH, maxW = 980, minH = 360,
    maxH = function() return math.floor(UIParent:GetHeight() * 0.9) end,
    getW = function()
      local sz = CB.db.sizes and CB.db.sizes.options
      return (sz and sz.w) or WIDTH
    end,
    getH = function()
      local sz = CB.db.sizes and CB.db.sizes.options
      return (sz and sz.h) or HEIGHT
    end,
    apply = function(w, h)
      CB.db.sizes = CB.db.sizes or {}
      CB.db.sizes.options = { w = w, h = h }
      O:ApplySavedSize()
    end,
    reset = function()
      if CB.db.sizes then CB.db.sizes.options = nil end
      O:ApplySavedSize()
    end,
  }
end

function O:ApplySavedSize()
  if not O.frame then return end
  local sz = CB.db.sizes and CB.db.sizes.options
  local w = (sz and sz.w) or WIDTH
  local h = (sz and sz.h) or HEIGHT
  O.frame:SetSize(w, h)
  O:UpdateHint()
end

function O:BeginSize()
  if CB.db.locked then
    CB:Print("The window is locked. Unlock it in settings.")
    return
  end
  if not O.frame then return end
  O.sizing = true
  local grip = O.frame.grip
  if grip and grip.cbPaint then
    local r, g, b = CB:Accent()
    grip.cbPaint(r, g, b)
  end
  if grip and grip.readout then
    grip.readout:SetText(O:ResizeCfg().getW() .. " x " .. O:ResizeCfg().getH())
    grip.readout:SetAlpha(1)
  end
  O:UpdateHint()
end

function O:EndSize()
  local grip = O.frame and O.frame.grip
  O.sizing = false
  if grip and grip.cbPaint then grip.cbPaint(0.55, 0.55, 0.6) end
  if grip and grip.readout then
    UI:Animate(grip, "readout", 0.35, function(p) grip.readout:SetAlpha(1 - p) end)
  end
  O:UpdateHint()
end

function O:UpdateHint()
  if not O.frame or not O.frame.hint then return end
  local hint = O.frame.hint
  hint:SetWidth(math.max(160, O.frame:GetWidth() - 32))
  if O.sizing then
    hint:SetText((UI:SizingHint():gsub("Columns", "Width")))
  elseif O.edit then
    hint:SetText(UI:PadHints({ { "close", "Leave field" } }, "Type with keyboard"))
  else
    local entries = { { "use", "Activate" }, { "prevSection", "nextSection", "Tabs" } }
    if not CB.db.locked then entries[#entries + 1] = { "menu", "Resize" } end
    entries[#entries + 1] = { "close", "Close" }
    hint:SetText(UI:PadHints(entries, "Select / change"))
  end
  -- Repaint badge colors even when only controller style/contrast changed.
  hint:Layout()
  O.footerH = math.ceil(hint:GetStringHeight()) + 28
  for _, page in pairs(O.pages or {}) do
    page.scroll:ClearAllPoints()
    page.scroll:SetPoint("TOPLEFT", 14, -80)
    page.scroll:SetPoint("BOTTOMRIGHT", -22, O.footerH)
  end
end

O.ctx = {
  alive = function() return O.frame ~= nil and O.frame:IsShown() end,
  OnPad = function(_, action)
    if O.sizing then
      local result = UI:SizePad(O:ResizeCfg(), O.frame.grip, action)
      if result == "done" then O:EndSize() end
      return
    end
    if action == "close" and O.edit then
      O.edit:ClearFocus()
      O.edit = nil
      Pad:Yield(false)
      O:UpdateHint()
      return
    end
    if action == "menu" then O:BeginSize(); return end
    local page = O.current
    if not page then return end
    if O.tabFocus then
      if action == "left" then O:SwitchTab(-1)
      elseif action == "right" then O:SwitchTab(1)
      elseif action == "down" or action == "use" then O:FocusTabs(false)
      elseif action == "close" or action == "options" then O:Close()
      elseif action == "prevSection" then O:SwitchTab(-1)
      elseif action == "nextSection" then O:SwitchTab(1) end
      return
    end
    if action == "up" then
      if page.focus == nextFocusable(page, 0, 1) then O:FocusTabs(true)
      else O:Focus(page, nextFocusable(page, page.focus or 1, -1)) end
    elseif action == "down" then O:Focus(page, nextFocusable(page, page.focus or 1, 1))
    elseif action == "left" or action == "right" then
      local row = page.rows[page.focus or 1]
      if row and row.adjust then row.adjust(action == "right" and 1 or -1) end
    elseif action == "use" then
      local row = page.rows[page.focus or 1]
      if row and row.activate then row.activate() end
    elseif action == "prevSection" then O:SwitchTab(-1)
    elseif action == "nextSection" then O:SwitchTab(1)
    elseif action == "close" or action == "options" then O:Close()
    end
  end,
}

-- Builds the settings window: title bar, tab strip and one scroll page per tab.
function O:Create()
  if O.frame then return end
  UI:MakeFonts()
  local f = NewFrame("Frame", "BagglerOptions", UIParent, "BackdropTemplate")
  O.frame = f
  f:SetSize(WIDTH, HEIGHT)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  UI:Backdrop(f, UI.bg, UI.border, 0.98, 40)
  UI:Shadow(f)
  f:Hide()

  local line = f:CreateTexture(nil, "OVERLAY")
  line:SetPoint("TOPLEFT", 1, -1); line:SetPoint("TOPRIGHT", -1, -1); UI:Line(line, "h", 2)
  f.line = line
  local title = f:CreateFontString(nil, "OVERLAY", "BagglerFont")
  title:SetPoint("TOPLEFT", 14, -14)
  title:SetText("Baggler settings   " .. CB.HEX.dim .. "v" .. CB.version .. "|r")
  f.title = title
  local close = UI:GlyphButton(f, "cross", "Close", function() O:Close() end)
  close:SetPoint("TOPRIGHT", -10, -10)
  -- a setting that needs a reload says so here, with the button to do it
  f.reloadBtn = UI:Button(f, "Reload UI to apply", 140, 22, function() ReloadUI() end)
  f.reloadBtn:SetPoint("RIGHT", close, "LEFT", -8, 0)
  f.reloadBtn:Hide()

  O.pages, O.tabOrder = {}, {}
  local spec = build()
  local x = 14
  for _, def in ipairs(spec) do
    local page = { name = def.tab, rows = {} }
    O.pages[def.tab] = page
    O.tabOrder[#O.tabOrder + 1] = def.tab

    local scroll = NewFrame("ScrollFrame", nil, f)
    UI:ScrollBar(scroll)
    scroll:SetPoint("TOPLEFT", 14, -80)
    scroll:SetPoint("BOTTOMRIGHT", -22, 40)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
      local maxScroll = math.max(0, (page.height or 0) - self:GetHeight())
      self:SetVerticalScroll(math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 2)))
    end)
    local content = NewFrame("Frame", nil, scroll)
    content:SetSize(WIDTH - 36, 10)
    scroll:SetScrollChild(content)
    scroll:Hide()
    page.scroll, page.content = scroll, content

    if def.custom then
      buildSectionsPage(page)
    else
      for _, rowSpec in ipairs(def.rows) do
        local row = makeRow(page, rowSpec)
        page.rows[#page.rows + 1] = row
      end
    end

    local tab = UI:Button(f, def.tab, 92, 26, function() O:ShowPage(def.tab) end)
    tab:SetPoint("TOPLEFT", x, -44)
    tab:SetBackdropColor(0, 0, 0, 0)
    tab:SetBackdropBorderColor(0, 0, 0, 0)
    tab:SetScript("OnEnter", function(self) self.text:SetTextColor(unpack(CB.COLOR.white)) end)
    tab:SetScript("OnLeave", function(self)
      if O.current and O.current.tabBtn ~= self then self.text:SetTextColor(unpack(CB.COLOR.muted)) end
    end)
    x = x + 96
    page.tabBtn = tab
  end

  local hint = UI:HintBar(f)
  hint:SetPoint("BOTTOMLEFT", 16, 14)
  hint:SetWidth(WIDTH - 32)
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(true)
  f.hint = hint
  O:UpdateHint()

  f.grip = UI:ResizeGrip(f, O:ResizeCfg())
  f.grip:SetShown(not CB.db.locked)

  f:SetScript("OnShow", function()
    local r, g, b = CB:Accent()
    f.line:SetColorTexture(r, g, b, 0.9)
    f.title:SetTextColor(r, g, b)
    local base = math.max(0.8, math.min(1.2, CB.db.scale))
    f:SetScale(base)
    UI:Resnap(true)
    UI:Arrive(f, base)
    Pad:Push(O.ctx)
    O:ApplySavedSize()
    O:UpdateHint()
    O:ShowPage(O.current and O.current.name or O.tabOrder[1])
  end)
  f:SetScript("OnHide", function()
    O.sizing = false
    O.tabFocus = false
    if O.edit and O.edit.ClearFocus then O.edit:ClearFocus() end
    O.edit = nil
    Pad:Yield(false)
    Pad:Pop(O.ctx)
  end)
  CB.UI:EscapeClose(_G["BagglerOptions"])
end

function O:UpdateReload()
  if O.frame and O.frame.reloadBtn then
    O.frame.reloadBtn:SetShown(O.reloadNeeded and true or false)
    if O.reloadNeeded then
      local r, g, b = CB:Accent()
      O.frame.reloadBtn:SetBackdropBorderColor(r, g, b, 1)
    end
  end
end

--- Puts every setting on a tab back to its out-of-the-box value.
function O:ResetTab(name)
  local def = O.specByTab and O.specByTab[name]
  if not def or not def.rows then return end
  local n = 0
  for _, rowSpec in ipairs(def.rows) do
    if rowSpec.key then
      local d = defaultOf(rowSpec.key)
      if d ~= nil and type(d) ~= "table" then setv(rowSpec.key, d); n = n + 1 end
    end
  end
  O:RefreshAll()
  CB:Print(("%s settings are back to their defaults (%d)."):format(name, n))
end

function O:Open() O:Create(); O.frame:Show() end
function O:Close() if O.frame then O.frame:Hide() end end
function O:Toggle()
  O:Create()
  if O.frame:IsShown() then O.frame:Hide() else O.frame:Show() end
end

CB:On("SETTING", function(key)
  if key == "sizes" then O:ApplySavedSize() end
  if key == "locked" and O.frame and O.frame.grip then O.frame.grip:SetShown(not CB.db.locked) end
  if O.sizing and CB.db.locked then O:EndSize() end
  if O.frame and O.frame:IsShown() then O:RefreshAll(); O:UpdateHint() end
end)
