-- Baggler remote view: look at what another character (or the warband bank) holds, from anywhere.
-- It reads the snapshots Baggler records as you play (bags, bank, worn gear), so a character only appears
-- after it has logged in with this version. Read-only: nothing here can move an item.
--   Opened from the window menu ("Other characters") or  /baggler view <name>
--   LB / RB: previous / next list     D-pad: move     B: close
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local UI, Pad, Inv = CB.UI, CB.Pad, CB.Inventory
local R = {}
CB.Remote = R
UI:FollowScale(R)

R.tiles = {}
R.nav = {}
R.sources = {}
R.at = 1

local COLS, GAP = 10, 3
local PADDING, TOP_H = UI.METRICS.pad, UI.METRICS.topH

local function itemInfo(id)
  local name, _, quality, _, _, _, _, _, _, icon = (C_Item and C_Item.GetItemInfo or GetItemInfo)(id)
  if not icon then
    local f = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    icon = f and f(id) or nil
  end
  return name, quality or 1, icon
end

--- Every list worth showing: { label, counts }.
function R:BuildSources()
  local list = {}
  local names = {}
  for key, c in pairs(CB.db.chars or {}) do names[#names + 1] = { key = key, c = c } end
  table.sort(names, function(a, b) return (a.c.name or a.key) < (b.c.name or b.key) end)
  for _, e in ipairs(names) do
    local nm = e.c.name or e.key
    if next(e.c.bags or {}) then list[#list + 1] = { label = nm .. " - bags", counts = e.c.bags } end
    if next(e.c.bank or {}) then list[#list + 1] = { label = nm .. " - bank", counts = e.c.bank } end
    if next(e.c.worn or {}) then list[#list + 1] = { label = nm .. " - worn", counts = e.c.worn } end
  end
  local wb = (CB.db.account or {}).bank
  if wb and next(wb) then list[#list + 1] = { label = "Warband bank", counts = wb } end
  return list
end

local function newTile(i)
  local f = R.frame
  local t = NewFrame("Button", nil, f.content)
  t.bg = t:CreateTexture(nil, "BACKGROUND")
  t.bg:SetAllPoints()
  t.bg:SetColorTexture(UI.tile[1], UI.tile[2], UI.tile[3], 1)
  t.icon = t:CreateTexture(nil, "ARTWORK")
  t.icon:SetPoint("TOPLEFT", 1, -1); t.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  t.border = NewFrame("Frame", nil, t, "BackdropTemplate")
  t.border:SetAllPoints()
  t.border:EnableMouse(false)
  UI:EdgeFile(t.border, 1)
  t.count = UI:StyleCount(t.border:CreateFontString(nil, "OVERLAY", "BagglerFontCount"), t.border)
  t.sel = NewFrame("Frame", nil, t, "BackdropTemplate")
  t.sel:SetPoint("TOPLEFT", -2, 2); t.sel:SetPoint("BOTTOMRIGHT", 2, -2)
  t.sel:EnableMouse(false)
  UI:EdgeFile(t.sel, 2)
  t.sel:Hide()
  t:SetScript("OnEnter", function(self) R:Select(self, true) end)
  t:SetScript("OnLeave", function() CB.Card:HideMouse(); UI:HideTip() end)
  R.tiles[i] = t
  return t
end

-- Highlights a tile and shows that item's tooltip.
function R:Select(tile, fromMouse)
  for _, t in ipairs(R.tiles) do t.sel:Hide() end
  if not tile then return end
  R.selected = tile
  local r, g, b = CB:Accent()
  tile.sel:SetBackdropBorderColor(r, g, b, 1)
  tile.sel:Show()
  if tile.itemID then
    local id = tile.itemID
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local link = info and select(2, info(id))
    local getTip = C_TooltipInfo and C_TooltipInfo.GetItemByID
    if CB.Card:ShowLink(R, link, getTip and function() return getTip(id) end, nil, nil, nil, true, fromMouse) then
      UI:HideTip()
    elseif GameTooltip.SetItemByID then
      GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(id)
      GameTooltip:Show()
    end
  end
end

-- Opens the other-characters view on one character (cycling when `index` wraps) and lists
-- everything that character carries.
function R:Show(index)
  R.sources = R:BuildSources()
  if #R.sources == 0 then CB:Print("no other characters recorded yet - they appear after they log in with this version."); return end
  R.at = ((index or R.at) - 1) % #R.sources + 1
  R:Create()
  local src = R.sources[R.at]
  local f = R.frame
  f.title:SetText(CB.HEX.text .. "Other characters|r  " .. CB.HEX.dim .. src.label .. "  (" .. R.at .. "/" .. #R.sources .. ")|r")
  local rows = {}
  for id, n in pairs(src.counts) do
    local name, quality, icon = itemInfo(id)
    rows[#rows + 1] = { id = id, n = n, name = name or ("item " .. id), quality = quality, icon = icon }
  end
  table.sort(rows, function(a, b)
    if a.quality ~= b.quality then return a.quality > b.quality end
    return a.name < b.name
  end)
  local size = CB.db.iconSize
  local lines = math.max(1, math.ceil(#rows / COLS))
  f.content:SetSize(COLS * (size + GAP), lines * (size + GAP))
  f:SetWidth(COLS * (size + GAP) + PADDING * 2 - GAP)
  local hintsH = UI:FitHints(f, f.hints, UI:PadHints({ { "prevSection", "nextSection", "Next list" }, { "close", "Close" } }) .. " " .. CB.HEX.muted .. "(read only)|r", 8)
  f:SetSize(COLS * (size + GAP) + PADDING * 2 - GAP, TOP_H + lines * (size + GAP) + hintsH + 16)
  R.nav = {}
  for i = 1, math.max(#rows, #R.tiles) do
    local row = rows[i]
    if row then
      local t = R.tiles[i] or newTile(i)
      local col, ln = (i - 1) % COLS, math.floor((i - 1) / COLS)
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", col * (size + GAP), -ln * (size + GAP))
      t:SetSize(size, size)
      t.itemID = row.id
      t.icon:SetTexture(row.icon)
      t.count:SetText(row.n > 1 and UI:Count(row.n) or "")
      local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[row.quality]
      if c and row.quality >= 2 then t.border:SetBackdropBorderColor(c.r, c.g, c.b, 0.95)
      else t.border:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1) end
      t:Show()
      R.nav[#R.nav + 1] = { tile = t, cx = col * (size + GAP) + size / 2, cy = ln * (size + GAP) + size / 2 }
    elseif R.tiles[i] then
      R.tiles[i]:Hide()
    end
  end
  f:ClearAllPoints()
  local p = CB.db.remotePoint
  if p then f:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5]) else f:SetPoint("CENTER", UIParent, "CENTER", 0, 30) end
  R:ApplyScale()
  f:Show()
  if not R.pushed then Pad:Push(R.ctx); R.pushed = true end
  R.selected = nil
  if R.nav[1] then R:Select(R.nav[1].tile) end
end

R.ctx = {
  alive = function() return R.frame ~= nil and R.frame:IsShown() end,
  OnPad = function(_, action)
    if action == "up" or action == "down" or action == "left" or action == "right" then
      local cur
      for _, n in ipairs(R.nav) do if n.tile == R.selected then cur = n end end
      local nxt = Pad:Neighbor(R.nav, cur, action)
      if nxt then R:Select(nxt.tile) end
    elseif action == "prevSection" then R:Show(R.at - 1)
    elseif action == "nextSection" then R:Show(R.at + 1)
    elseif action == "close" then R.frame:Hide()
    end
  end,
}

function R:Create()
  if R.frame then return R.frame end
  UI:MakeFonts()
  local f = NewFrame("Frame", "BagglerRemote", UIParent, "BackdropTemplate")
  R.frame = f
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:Hide()
  UI:Backdrop(f, UI.bg, UI.border, CB.db.bgAlpha, TOP_H)
  UI:Shadow(f)
  local bar = NewFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT", 0, 0); bar:SetPoint("TOPRIGHT", 0, 0); bar:SetHeight(TOP_H)
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() if not CB.db.locked then f:StartMoving() end end)
  bar:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    local point, rel, relPoint, x, y = f:GetPoint()
    CB.db.remotePoint = { point, (rel and rel:GetName()) or "UIParent", relPoint, x, y }
  end)
  f.title = bar:CreateFontString(nil, "OVERLAY", "BagglerFont")
  f.title:SetPoint("LEFT", PADDING, 0)
  f.title:SetFontObject("BagglerFontTitle")
  local close = UI:GlyphButton(bar, "", "Close", function() f:Hide() end)
  close:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
  UI:DrawIcon(close, { { 11, 1.5, 0, 0, 45 }, { 11, 1.5, 0, 0, -45 } })
  local line = f:CreateTexture(nil, "ARTWORK")
  line:SetPoint("TOPLEFT", 1, -TOP_H); line:SetPoint("TOPRIGHT", -1, -TOP_H); UI:Line(line, "h", 1)
  line:SetColorTexture(UI.border[1], UI.border[2], UI.border[3], 0.8)
  f.content = NewFrame("Frame", nil, f)
  f.content:SetPoint("TOPLEFT", PADDING, -(TOP_H + 8))
  f.hints = UI:HintBar(f)
  f.hints:SetPoint("BOTTOM", f, "BOTTOM", 0, 8)
  f:SetScript("OnHide", function()
    Pad:Pop(R.ctx)
    R.pushed = false
    UI:HideTip()
  end)
  CB.UI:EscapeClose(_G["BagglerRemote"])
  return f
end

--- /baggler view <name>: jump straight to a character.
function R:Open(text)
  if CB:IsOff("remote") then CB:Print("the other-characters viewer is switched off (/baggler on remote, then /reload)."); return end
  R.sources = R:BuildSources()
  text = (text or ""):lower()
  for i, s in ipairs(R.sources) do
    if text == "" or s.label:lower():find(text, 1, true) then R:Show(i); return end
  end
  CB:Print("no recorded character matches '" .. text .. "'.")
end

CB.windowExtras = CB.windowExtras or {}
table.insert(CB.windowExtras, function(W)
  if W.kind ~= "bags" then return nil end
  if not next(CB.db.chars or {}) and not next((CB.db.account or {})) then return nil end
  return { { text = "Other characters", sub = function()
    local list = {}
    for i, s in ipairs(R:BuildSources()) do
      local idx = i
      list[#list + 1] = { text = s.label, func = function() R:Show(idx) end }
    end
    if #list == 0 then list[1] = { text = "Nothing recorded yet", disabled = true } end
    return list
  end } }
end)

CB:On("SETTING", function(key)
  if key == "bgAlpha" and R.frame then R.frame:SetBackdropColor(UI.bg[1], UI.bg[2], UI.bg[3], CB.db.bgAlpha) end
end)
