-- Baggler widgets: fonts, flat styling helpers, small controls.
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local UI = {}
CB.UI = UI

UI.WHITE = "Interface\\Buttons\\WHITE8X8"
UI.FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
-- Fonts the player can pick (all ship with the game; "game" is whatever the client uses for its own text, which is
-- the only one that is safe in every language).
UI.FONTS = { game = UI.FONT, narrow = "Fonts\\ARIALN.TTF", classic = "Fonts\\FRIZQT__.TTF" }
UI.FONT_NAMES = { "game", "narrow", "classic" }
local function fontPath()
  return (UI.FONTS[(CB.db and CB.db.font) or "game"]) or UI.FONT
end

---------------------------------------------------------------------------
-- Type. Every size the add-on uses is one of these roles, and each role is a font object, so the whole add-on
-- follows the "Text size" setting (CB.db.fontScale) by changing the objects. Nothing is smaller than 10.
---------------------------------------------------------------------------
UI.TYPE = {
  --  font object          size  flags      colour
  BagglerFont        = { 12, "",        "text" },    -- body
  BagglerFontSmall   = { 10, "OUTLINE", "text" },    -- numbers drawn over item icons
  BagglerFontCount   = { 12, "OUTLINE", "white" },   -- stack counts in the corner of an item
  BagglerFontHeader  = { 10, "",        "muted" },   -- section headers, captions
  BagglerFontMuted   = { 11, "",        "muted" },   -- labels and sub-lines
  BagglerFontTiny    = { 10, "",        "muted" },   -- the smallest readable line (row sub-lines)
  BagglerFontHint    = { 10, "",        "muted" },   -- the controller hint line under a window
  BagglerFontTitle   = { 15, "",        "text" },    -- window titles
  BagglerFontBig     = { 18, "",        "white" },   -- one large figure on a page (a gold total, a count)
  BagglerFontNumber  = { 13, "",        "text" },    -- figures in a row of numbers
}

local function scaledSize(base)
  local k = (CB.db and CB.db.fontScale) or 1
  return math.max(10, math.floor(base * k + 0.5))
end

--- Creates the font objects, or re-sizes them after the "Text size" setting changed.
function UI:MakeFonts()
  for name, spec in pairs(UI.TYPE) do
    local f = _G[name] or CreateFont(name)
    f:SetFont(fontPath(), scaledSize(spec[1]), spec[2])
    f:SetTextColor(unpack(CB.COLOR[spec[3]]))
  end
  -- a hard drop shadow under the outline keeps the numbers legible on any icon art
  if BagglerFontCount then BagglerFontCount:SetShadowColor(0, 0, 0, 1); BagglerFontCount:SetShadowOffset(1, -1) end
end

---------------------------------------------------------------------------
-- High contrast: brighter edges and text. The colour tables are changed in place, so everything that reads them
-- afterwards (the fonts, borders, inline codes) picks the new values up; windows are told to restyle.
---------------------------------------------------------------------------
local normalLook
local CONTRAST = CB.CONTRAST
-- Switches the shared colours and border between the normal look and the high-contrast one.
-- The normal values are captured the first time so they can be restored exactly.
function UI:ApplyContrast()
  if not normalLook then
    normalLook = { border = { unpack(UI.border) }, color = {}, hex = {} }
    for k in pairs(CONTRAST.color) do normalLook.color[k] = { unpack(CB.COLOR[k]) } end
    for k in pairs(CONTRAST.hex) do normalLook.hex[k] = CB.HEX[k] end
  end
  local look = (CB.db and CB.db.highContrast) and CONTRAST or normalLook
  for i = 1, 3 do UI.border[i] = look.border[i] end
  for k, v in pairs(look.color) do for i = 1, 3 do CB.COLOR[k][i] = v[i] end end
  for k, v in pairs(look.hex) do CB.HEX[k] = v end
  UI:MakeFonts()
  CB:Fire("SETTING", "accent", CB.db and CB.db.accent)        -- every window restyles itself on an accent change
  CB:Fire("DIRTY")
end

CB:On("DB_READY", function() if CB.db.highContrast then UI:ApplyContrast() end end)

CB:On("SETTING", function(key)
  if key == "highContrast" then UI:ApplyContrast() end
  if key == "fontScale" or key == "font" then
    UI:MakeFonts()
    CB:Fire("DIRTY")
  end
end)

---------------------------------------------------------------------------
-- Sound. The bags' open / close sounds go through here so they can be switched off.
---------------------------------------------------------------------------
function UI:Sound(kitName, fallbackId)
  if CB.db and CB.db.sounds == false then return end
  local id = (SOUNDKIT and SOUNDKIT[kitName]) or fallbackId
  if id and PlaySound then PlaySound(id) end
end

--- Window metrics shared by every Baggler window, so title bars, edges and footers line up from one window to the next.
UI.METRICS = { pad = 12, topH = 42, footH = 32 }

UI.bg = { 0.055, 0.055, 0.065 }
UI.border = { 0.18, 0.18, 0.21 }
UI.OUTLINE_PX = 1                       -- item outline thickness in physical pixels (icons are inset by the same amount)
UI.itemEdge = { 0.42, 0.42, 0.47 }      -- a plain item's outline: light enough to read against bright icon art
UI.panel = { 0.09, 0.09, 0.105 }
UI.tile = { 0.125, 0.125, 0.145 }       -- the fill behind an item icon or a list row

---------------------------------------------------------------------------
-- Pixel snapping. A 1-unit border on a frame whose scale is 0.94 covers 0.94 of a screen pixel: some edges come out
-- thick, some thin, and they shimmer when a window moves. Every hairline (borders, rules, ticks) is therefore sized
-- in whole physical pixels for the scale its frame has right now, and re-sized when that scale changes.
---------------------------------------------------------------------------
local snapped = setmetatable({}, { __mode = "k" })     -- frame or texture -> { kind=, pixels=, scale=, ... }
UI.snapHooks = {}                                        -- called by Resnap after a scale change (windows re-place tiles)
local snapDirty, snapSignature = true, nil               -- new registrations, or a changed scale, make Resnap do its work

local function pixelFactor()
  local _, h = nil, nil
  if GetPhysicalScreenSize then _, h = GetPhysicalScreenSize() end
  if not h or h <= 0 then return nil end
  return 768 / h                                      -- one physical pixel, in the units of an unscaled UI
end

--- `count` physical pixels, in the units of `frame` (a frame's scale makes its units bigger or smaller).
function UI:Pixels(frame, count)
  count = count or 1
  local factor = pixelFactor()
  local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
  if not factor or not scale or scale <= 0 then return count end
  return count * factor / scale
end

local function scaleOf(obj)
  if obj.GetEffectiveScale then return obj:GetEffectiveScale() end
  local parent = obj.GetParent and obj:GetParent()
  return parent and parent.GetEffectiveScale and parent:GetEffectiveScale() or 1
end

--- Applies a snapped edge size to a backdrop frame without losing its colours.
local function applyEdge(frame, info)
  local px = UI:Pixels(frame, info.pixels)
  if info.applied and math.abs(info.applied - px) < 1e-4 then return end
  info.applied = px
  local bi = frame.backdropInfo
  if bi and frame.ApplyBackdrop then
    bi.edgeSize = px
    if bi.insets then bi.insets.left, bi.insets.right, bi.insets.top, bi.insets.bottom = px, px, px, px end
    -- ApplyBackdrop resets both colours to white and calls SetBackdropColor itself, which would overwrite the
    -- remembered colours through the tracking hook; so copy them first and restore from the copies.
    local bg, edge = frame.cbLastBG, frame.cbLastEdge
    bg = bg and { bg[1], bg[2], bg[3], bg[4] }
    edge = edge and { edge[1], edge[2], edge[3], edge[4] }
    frame:ApplyBackdrop()
    if bg then frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4]) end
    if edge then frame:SetBackdropBorderColor(edge[1], edge[2], edge[3], edge[4]) end
  end
end

--- Remembers the colours a backdrop frame was given, so they survive a re-snap.
local function trackColours(frame)
  if frame.cbTracked then return end
  frame.cbTracked = true
  local function remember(key)
    return function(_, r, g, b, a)
      local t = frame[key]
      if t then t[1], t[2], t[3], t[4] = r, g, b, a else frame[key] = { r, g, b, a } end
    end
  end
  hooksecurefunc(frame, "SetBackdropColor", remember("cbLastBG"))
  hooksecurefunc(frame, "SetBackdropBorderColor", remember("cbLastEdge"))
end

--- An edge-only backdrop one or two physical pixels wide (item borders, selection rings, shadows ...).
--- Call SetBackdropBorderColor on the frame afterwards as usual.
function UI:EdgeFile(frame, pixels)
  if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
  pixels = pixels or 1
  frame:SetBackdrop({ edgeFile = UI.WHITE, edgeSize = UI:Pixels(frame, pixels) })
  trackColours(frame)
  local info = { kind = "edge", pixels = pixels }
  snapped[frame] = info
  info.applied = UI:Pixels(frame, pixels)
  snapDirty = true
end

--- Physical screen pixels per unit of `frame` (effective scale * screen height / 768); nil when unknown.
function UI:PixelScale(frame)
  local _, h
  if GetPhysicalScreenSize then _, h = GetPhysicalScreenSize() end
  local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
  if not h or h <= 0 or not scale or scale <= 0 then return nil end
  return scale * h / 768
end

--- Round to the nearest whole number (halves up).
function UI:Round(x) return math.floor(x + 0.5 + 1e-9) end

--- An item outline that cannot round away: `ring` is a texture covering the WHOLE tile (drawn beneath the art) and the
--- art/fill sit exactly one physical pixel inside it (UI:Inset), so the outline is the visible ring of that texture,
--- never a separate 1-pixel strip that a fractional tile position could snap to zero width.
--- Keeps the colour-writing interface of the decoration frame: SetBackdropBorderColor recolours the ring.
function UI:ItemOutline(frame, ring)
  ring:SetColorTexture(1, 1, 1, 1)
  ring:SetSnapToPixelGrid(true)
  ring:SetTexelSnappingBias(0)
  ring:SetAllPoints(ring:GetParent())
  frame.cbOutline = { ring }
  function frame:SetBackdropBorderColor(r, g, b, a)
    self.cbLastEdge = { r, g, b, a or 1 }
    ring:SetColorTexture(r, g, b, a or 1)
  end
end

--- Pins `region` inside `anchor` (default: its parent), inset by `pixels` physical pixels on every side (or, with
--- `bottomOnly`, left/right/bottom only). Item art uses this with the outline's own thickness, so the icon always sits
--- strictly inside the outline strips whatever the scale. Re-applied by Resnap when the scale changes.
function UI:Inset(region, anchor, pixels, bottomOnly)
  anchor = anchor or region:GetParent()
  local info = { kind = "inset", anchor = anchor, pixels = pixels or UI.OUTLINE_PX }
  snapped[region] = info
  info.apply = function()
    local d = UI:Pixels(anchor, info.pixels)
    region:ClearAllPoints()
    if bottomOnly then
      region:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", d, d)
      region:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -d, d)
    else
      region:SetPoint("TOPLEFT", anchor, "TOPLEFT", d, -d)
      region:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -d, d)
    end
    info.applied = d
  end
  info.apply()
  info.scale = scaleOf(region)
  snapDirty = true
end

--- A hairline texture: `axis` "h" fixes its height, "w" its width, to `pixels` physical pixels.
function UI:Line(tex, axis, pixels)
  pixels = pixels or 1
  snapped[tex] = { kind = "line", axis = axis, pixels = pixels }
  local size = UI:Pixels(tex:GetParent(), pixels)
  if axis == "w" then tex:SetWidth(size) else tex:SetHeight(size) end
  snapped[tex].applied = size
  snapDirty = true
end

--- Re-sizes everything above for the scale its frame has now. Cheap when nothing changed (one scale read each).
function UI:Resnap(force)
  -- (cheap to call often: it does nothing unless something new was registered or a scale changed)
  -- `force` is for a caller that has just changed a frame's scale: the setting's value alone cannot tell, because the
  -- setting changes before the windows take it, and a signature built from it would then call the job done too early.
  local signature = ((CB.db and CB.db.scale) or 1) .. ":" .. (UIParent:GetEffectiveScale() or 1)
  if not force and not snapDirty and signature == snapSignature then return end
  snapDirty, snapSignature = false, signature
  local changed = false
  for obj, info in pairs(snapped) do
    local scale = scaleOf(obj)
    if info.scale ~= scale then
      changed = true
      info.scale = scale
      if info.kind == "edge" then
        applyEdge(obj, info)
      elseif info.kind == "inset" then
        info.apply()
      else
        local size = UI:Pixels(obj:GetParent(), info.pixels)
        if info.axis == "w" then obj:SetWidth(size) else obj:SetHeight(size) end
        info.applied = size
      end
    end
  end
  -- tile geometry is quantised to whole physical pixels by the windows: a changed scale re-places them
  if changed or force then for _, fn in ipairs(UI.snapHooks) do fn() end end
end

CB:RegisterEvent("UI_SCALE_CHANGED", function() UI:Resnap() end)
CB:RegisterEvent("DISPLAY_SIZE_CHANGED", function() UI:Resnap() end)
-- The windows take the new scale a moment after the setting changes (the settings screen refreshes them), so the
-- hairlines are re-sized once that has happened, not only at the moment of the change.
CB:On("SETTING", function(key)
  if key ~= "scale" then return end
  UI:Resnap(true)
  C_Timer.After(0, function() UI:Resnap(true) end)
  C_Timer.After(0.3, function() UI:Resnap(true) end)
end)

-- The window panel look: a flat fill with a one-pixel edge sized to the screen, tracked so a
-- scale change re-snaps it. `topBar` is the height of the lighter title strip (0 for none).
function UI:Backdrop(frame, bg, border, alpha, topBar)
  if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
  local px = UI:Pixels(frame, 1)
  frame:SetBackdrop({ bgFile = UI.WHITE, edgeFile = UI.WHITE, edgeSize = px,
                      insets = { left = px, right = px, top = px, bottom = px } })
  trackColours(frame)
  snapped[frame] = { kind = "edge", pixels = 1, applied = px }
  snapDirty = true
  bg = bg or UI.bg; border = border or UI.border
  frame:SetBackdropColor(bg[1], bg[2], bg[3], alpha or 1)
  frame:SetBackdropBorderColor(border[1], border[2], border[3], 1)
  frame.cbBC = { border[1], border[2], border[3] }
  if topBar then UI:Depth(frame, topBar) end
end

--- A vertical gradient on a texture, from colour `top` to colour `bottom` ({r,g,b,a} each). Solid average if the
--- client has no gradients.
function UI:VGradient(tex, top, bottom)
  local ok = false
  if tex.SetGradient and CreateColor then
    ok = pcall(tex.SetGradient, tex, "VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], bottom[4]),
      CreateColor(top[1], top[2], top[3], top[4]))
  end
  if not ok then
    tex:SetColorTexture((top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2, (top[3] + bottom[3]) / 2, (top[4] + bottom[4]) / 2)
  end
end

--- Depth for a flat panel: a barely-there light-to-dark wash over the whole window, a one-pixel highlight along the
--- top edge, and a slightly lighter title bar of height `barHeight` (0 for none). Made once per frame.
function UI:Depth(frame, barHeight)
  if frame.cbDepth then return end
  local d = {}
  frame.cbDepth = d
  d.wash = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  d.wash:SetPoint("TOPLEFT", 1, -1)
  d.wash:SetPoint("BOTTOMRIGHT", -1, 1)
  UI:VGradient(d.wash, { 1, 1, 1, 0.035 }, { 0, 0, 0, 0.16 })
  d.light = frame:CreateTexture(nil, "BORDER")
  d.light:SetPoint("TOPLEFT", 1, -1)
  d.light:SetPoint("TOPRIGHT", -1, -1)
  d.light:SetColorTexture(1, 1, 1, 0.08)
  UI:Line(d.light, "h", 1)
  if barHeight and barHeight > 0 then
    d.bar = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
    d.bar:SetPoint("TOPLEFT", 1, -2)
    d.bar:SetPoint("TOPRIGHT", -1, -2)
    d.bar:SetHeight(barHeight - 2)
    d.bar:SetColorTexture(1, 1, 1, 0.025)
  end
end

function UI:NewFrame(parent, name)
  return NewFrame("Frame", name, parent, "BackdropTemplate")
end

--- Flat text button. Returns the button; .text is its FontString.
--- The hint line under a window: "D-pad Move   A Take out   ..." in the player's own button layout.
--- Each entry is { action, label }, or { actionA, actionB, label } for a pair shown as "LB/RB label".
--- Actions with no button assigned are left out. `lead` replaces the word after "D-pad" (default "Move").
function UI:PadHints(entries, lead)
  local inverse = {}
  for key, action in pairs(CB.db.pad.map) do if action then inverse[action] = key end end
  local r, g, b = CB:Accent()
  local col = ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
  local parts = { col .. "D-pad|r " .. (lead or "Move") }
  for _, e in ipairs(entries) do
    if #e == 3 then
      local first, second = inverse[e[1]], inverse[e[2]]
      if first and second then parts[#parts + 1] = col .. UI:PadLabel(first) .. "|r/" .. col .. UI:PadLabel(second) .. "|r " .. e[3] end
    elseif inverse[e[1]] then
      parts[#parts + 1] = col .. UI:PadLabel(inverse[e[1]]) .. "|r " .. e[2]
    end
  end
  return CB.HEX.muted .. table.concat(parts, "   ") .. "|r"
end

---------------------------------------------------------------------------
-- Windows with a fixed layout follow the interface scale from the settings, nothing more.
---------------------------------------------------------------------------
function UI:FollowScale(win)
  --- Call wherever the window is shown, and again when the scale setting changes.
  function win:ApplyScale()
    if win.frame then win.frame:SetScale(CB.db.scale or 1); UI:Resnap(true) end
  end
end

local function padKeys()
  local inverse = {}
  for key, action in pairs(CB.db.pad.map) do if action then inverse[action] = key end end
  local r, g, b = CB:Accent()
  local col = ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
  return inverse, col
end

--- The hint line while a window is being resized from the controller (the same in every window).
function UI:SizingHint()
  local inverse, col = padKeys()
  local parts = { col .. "Left/Right|r Columns", col .. "Up/Down|r Height" }
  if inverse.menu then parts[#parts + 1] = col .. UI:PadLabel(inverse.menu) .. "|r Reset" end
  if inverse.use and inverse.close then parts[#parts + 1] = col .. UI:PadLabel(inverse.use) .. "|r/" .. col .. UI:PadLabel(inverse.close) .. "|r Done"
  elseif inverse.close then parts[#parts + 1] = col .. UI:PadLabel(inverse.close) .. "|r Done" end
  return CB.HEX.muted .. table.concat(parts, "   ") .. "|r"
end

--- The hint line while the highlight is on a window's top row (tabs, search, size ...): what A does there.
function UI:ChromeHint(actionLabel)
  local inverse, col = padKeys()
  local parts = { col .. "Left/Right|r Move" }
  if inverse.use then parts[#parts + 1] = col .. UI:PadLabel(inverse.use) .. "|r " .. (actionLabel or "Choose") end
  if inverse.menu then parts[#parts + 1] = col .. UI:PadLabel(inverse.menu) .. "|r Window menu" end
  if inverse.close then parts[#parts + 1] = col .. UI:PadLabel(inverse.close) .. "|r Back" end
  parts[#parts + 1] = col .. "Down|r Items"
  return CB.HEX.muted .. table.concat(parts, "   ") .. "|r"
end

--- A small cross inside a search box that empties it; it only shows while there is something to clear.
function UI:SearchClearButton(search, onClear)
  local b = NewFrame("Button", nil, search)
  b:SetSize(18, 18)
  b:SetPoint("RIGHT", search, "RIGHT", -3, 0)
  b.icon = UI:Icon(b, "cross", 9)
  b.icon:SetPoint("CENTER")
  b.icon:SetColor(unpack(CB.COLOR.muted))
  b:SetScript("OnEnter", function(self)
    self.icon:SetColor(unpack(CB.COLOR.white))
    UI.Tip:SetOwner(self, "ANCHOR_BOTTOM"); UI.Tip:SetText("Clear search", 1, 1, 1); UI.Tip:Show()
  end)
  b:SetScript("OnLeave", function(self) self.icon:SetColor(unpack(CB.COLOR.muted)); UI:HideTip() end)
  b:SetScript("OnClick", function() search:SetText(""); search:ClearFocus(); if onClear then onClear() end end)
  b:Hide()
  search:HookScript("OnTextChanged", function(self) b:SetShown((self:GetText() or "") ~= "") end)
  search.clearButton = b
  return b
end

--- The search box every window uses: placeholder text, a clear cross, an accent border while it has the keyboard,
--- and the controller yields to the typing while it is focused.
--- o = { width, height, font, placeholder, maxLetters, onChange(text), onClear(), onEnter(), onFocus(on) }
function UI:SearchBox(parent, o)
  local search = NewFrame("EditBox", nil, parent, "BackdropTemplate")
  search:SetSize(o.width or 150, o.height or 22)
  search:SetAutoFocus(false)
  search:SetFontObject(o.font or "BagglerFont")
  search:SetTextInsets(9, 22, 0, 0)               -- (room on the right for the clear cross)
  if o.maxLetters then search:SetMaxLetters(o.maxLetters) end
  UI:Backdrop(search, UI.panel, UI.border)
  search.placeholder = search:CreateFontString(nil, "OVERLAY", "BagglerFontMuted")
  search.placeholder:SetPoint("LEFT", 9, 0)
  search.placeholder:SetText(o.placeholder or "Search")
  search:SetScript("OnTextChanged", function(self)
    local t = self:GetText() or ""
    self.placeholder:SetShown(t == "" and not self:HasFocus())
    if o.onChange then o.onChange(t) end
  end)
  search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
  search:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    if o.onEnter then o.onEnter() end
  end)
  search:SetScript("OnEditFocusGained", function(self)
    self.placeholder:Hide()
    local r, g, b = CB:Accent()
    self:SetBackdropBorderColor(r, g, b, 1)
    CB.Pad:Yield(true)
    if o.onFocus then o.onFocus(true) end
  end)
  search:SetScript("OnEditFocusLost", function(self)
    self.placeholder:SetShown((self:GetText() or "") == "")
    self:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
    CB.Pad:Yield(false)
    if o.onFocus then o.onFocus(false) end
  end)
  UI:SearchClearButton(search, o.onClear)
  return search
end

---------------------------------------------------------------------------
-- Tooltip for the add-on's own explanations (what a button does, what a limit is). It looks like the rest of the
-- windows and answers the same calls as GameTooltip (SetOwner, SetText, AddLine, AddDoubleLine, Show). Anything that
-- shows an item or a spell still uses the game's tooltip. UI:HideTip hides both.
---------------------------------------------------------------------------
local TIP_ANCHORS = {
  ANCHOR_BOTTOM      = { "TOP", "BOTTOM", 0, -6 },     -- tooltip point, owner point, x, y
  ANCHOR_TOP         = { "BOTTOM", "TOP", 0, 6 },
  ANCHOR_RIGHT       = { "LEFT", "RIGHT", 6, 0 },
  ANCHOR_LEFT        = { "RIGHT", "LEFT", -6, 0 },
  ANCHOR_TOPLEFT     = { "BOTTOMRIGHT", "TOPLEFT", 0, 6 },
  ANCHOR_TOPRIGHT    = { "BOTTOMLEFT", "TOPRIGHT", 0, 6 },
  ANCHOR_BOTTOMLEFT  = { "TOPRIGHT", "BOTTOMLEFT", 0, -6 },
  ANCHOR_BOTTOMRIGHT = { "TOPLEFT", "BOTTOMRIGHT", 0, -6 },
  BESIDE_RIGHT       = { "TOPLEFT", "TOPRIGHT", 6, 0 },    -- level with the owner's top edge, clear of it (menus)
  BESIDE_LEFT        = { "TOPRIGHT", "TOPLEFT", -6, 0 },
}
local TIP_WIDTH, TIP_PAD = 280, 9
UI.TIP_WIDTH = TIP_WIDTH
local tipFrame

-- The add-on's own tooltip, built on first use: lines of text, each with an optional right-hand column.
local function tip()
  if tipFrame then return tipFrame end
  UI:MakeFonts()
  local f = NewFrame("Frame", "BagglerTip", UIParent, "BackdropTemplate")
  f:SetFrameStrata("TOOLTIP")
  f:SetClampedToScreen(true)
  f:EnableMouse(false)
  UI:Backdrop(f, UI.bg, UI.border, 0.97, 0)
  UI:Shadow(f)
  f.lines = {}
  f.used = 0
  f:Hide()
  -- a tooltip never outlives what it describes: when its owner goes (a menu closing, a window hiding) so does it
  f:SetScript("OnUpdate", function(self)
    local o = self.owner
    if self:IsShown() and o and o.IsVisible and not o:IsVisible() then self:Hide() end
    if self:IsShown() and self.focusContext and CB.Pad:Top() ~= self.focusContext then self:Hide() end
  end)

  local function line(i)
    local l = f.lines[i]
    if not l then
      l = {}
      l.left = f:CreateFontString(nil, "OVERLAY", "BagglerFont")
      l.left:SetJustifyH("LEFT")
      l.right = f:CreateFontString(nil, "OVERLAY", "BagglerFont")
      l.right:SetJustifyH("RIGHT")
      f.lines[i] = l
    end
    return l
  end

  function f:SetOwner(owner, anchor)
    f.owner, f.anchor = owner, anchor or "ANCHOR_RIGHT"
    f.focusContext = nil -- ordinary mouse/menu tips take ownership from controller chrome
    f.used = 0
    for _, l in ipairs(f.lines) do l.left:Hide(); l.right:Hide() end
  end
  function f:ClearLines()
    f.used = 0
    for _, l in ipairs(f.lines) do l.left:Hide(); l.right:Hide() end
  end
  function f:NumLines() return f.used end

  --- Adds a line. left / right text, colours, and whether the left text wraps.
  local function add(left, lr, lg, lb, right, rr, rg, rb, wrap, title)
    f.used = f.used + 1
    local l = line(f.used)
    l.left:SetFontObject(title and "BagglerFontTitle" or "BagglerFont")
    l.left:SetText(left or "")
    l.left:SetTextColor(lr or 1, lg or 0.82, lb or 0.29)
    l.left:SetWordWrap(wrap and true or false)
    if right then
      l.right:SetText(right)
      l.right:SetTextColor(rr or 1, rg or 1, rb or 1)
    end
    l.hasRight = right and true or false
    l.wrap = wrap and true or false
    l.title = title and true or false
  end
  function f:SetText(text, r, g, b, _, wrap)
    f:ClearLines()
    add(text, r or 1, g or 1, b or 1, nil, nil, nil, nil, wrap, false)
  end
  function f:AddLine(text, r, g, b, wrap) add(text, r, g, b, nil, nil, nil, nil, wrap) end
  function f:AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb) add(left, lr, lg, lb, right, rr, rg, rb, false) end

  local baseShow = f.Show
  function f:Show()
    if f.used == 0 then return end
    local inner = TIP_WIDTH - TIP_PAD * 2
    -- width: as wide as the widest unwrapped line, up to TIP_WIDTH; wrapped lines fill it
    local widest = 0
    for i = 1, f.used do
      local l = f.lines[i]
      l.left:SetWidth(0)
      l.right:SetWidth(0)
      local w = l.left:GetStringWidth() + (l.hasRight and (l.right:GetStringWidth() + 16) or 0)
      if not l.wrap then widest = math.max(widest, w) else widest = math.max(widest, math.min(w, inner)) end
    end
    local width = math.max(60, math.min(widest, inner)) + TIP_PAD * 2
    local y = TIP_PAD
    for i = 1, f.used do
      local l = f.lines[i]
      l.left:ClearAllPoints(); l.right:ClearAllPoints()
      l.left:SetPoint("TOPLEFT", f, "TOPLEFT", TIP_PAD, -y)
      if l.hasRight then
        l.right:SetPoint("TOPRIGHT", f, "TOPRIGHT", -TIP_PAD, -y)
        l.left:SetWidth(width - TIP_PAD * 2 - l.right:GetStringWidth() - 12)
        l.right:Show()
      else
        l.left:SetWidth(width - TIP_PAD * 2)
        l.right:Hide()
      end
      l.left:Show()
      y = y + math.max(12, math.ceil(l.left:GetStringHeight())) + 3
    end
    for i = f.used + 1, #f.lines do f.lines[i].left:Hide(); f.lines[i].right:Hide() end
    f:SetSize(width, y + TIP_PAD - 3)
    f:SetScale((CB.db and CB.db.scale) or 1)
    UI:Resnap()
    f:ClearAllPoints()
    local a = TIP_ANCHORS[f.anchor] or TIP_ANCHORS.ANCHOR_RIGHT
    if f.owner and f.owner.GetCenter then f:SetPoint(a[1], f.owner, a[2], a[3], a[4])
    else f:SetPoint("CENTER") end
    f:SetAlpha(0)
    baseShow(f)
    UI:Animate(f, "tip", 0.08, function(p) f:SetAlpha(p) end, function() f:SetAlpha(1) end)
  end
  tipFrame = f
  return f
end

UI.Tip = setmetatable({}, { __index = function(_, k)
  local f = tip()
  local v = f[k]
  if type(v) == "function" then return function(self, ...) return v(f, ...) end end
  return v
end })

--- Hides both tooltips (the add-on's own and the game's).
function UI:HideTip()
  if tipFrame and tipFrame:IsShown() then tipFrame:Hide() end
  GameTooltip:Hide()
end

--- Controller chrome uses the shared card-styled tooltip above its control,
--- clear of the item grid. Never replay mouse hover scripts to synthesize focus.
function UI:ShowFocusTip(owner, text, context)
  local f = tip()
  f:SetOwner(owner, "ANCHOR_TOP")
  f.focusContext = context
  f:SetText(text, 1, 1, 1)
  f:Show()
end

function UI:HideFocusTip(context)
  if tipFrame and tipFrame.focusContext == context then tipFrame:Hide() end
end

--- A centred message for an empty list or a window that failed to draw. SetText("Title\nsecond line") fills the two
--- lines; "error" notes also offer a button that opens the copyable report.
function UI:StateNote(parent, kind)
  local n = NewFrame("Frame", nil, parent)
  n:SetSize(320, kind == "error" and 86 or 44)
  n.title = n:CreateFontString(nil, "OVERLAY", "BagglerFont")
  n.title:SetPoint("TOP", 0, 0)
  n.title:SetWidth(300)
  n.title:SetJustifyH("CENTER")
  n.sub = n:CreateFontString(nil, "OVERLAY", "BagglerFontMuted")
  n.sub:SetPoint("TOP", n.title, "BOTTOM", 0, -4)
  n.sub:SetWidth(300)
  n.sub:SetJustifyH("CENTER")
  if kind == "error" then
    n.title:SetTextColor(unpack(CB.COLOR.danger))
    n.button = UI:Button(n, "Copy report", 110, 22, function() if CB.ShowReport then CB:ShowReport() end end)
    n.button:SetPoint("BOTTOM", 0, 0)
  else
    n.title:SetTextColor(unpack(CB.COLOR.muted))
  end
  function n:SetText(text)
    local first, rest = tostring(text or ""):match("^([^\n]*)\n?(.*)$")
    self.title:SetText(first or "")
    self.sub:SetText(rest or "")
  end
  n:Hide()
  return n
end

---------------------------------------------------------------------------
-- Scrollbar: a slim track on the right edge of a scroll frame. The thumb is faint until the frame scrolls or the
-- mouse is on the bar, can be dragged, and a click on the track pages. Hidden when everything fits.
-- o = { onChange = function(value) ... end (called after the thumb moves the scroll; the window cancels its
-- own scroll animation there) }
---------------------------------------------------------------------------
function UI:ScrollBar(scroll, o)
  o = o or {}
  local parent = scroll:GetParent()
  local bar = NewFrame("Frame", nil, parent)
  bar:SetWidth(5)
  -- (just outside the scroll area, in the window's side margin, so it never covers a tile)
  bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 2, -2)
  bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 2, 2)
  bar:SetFrameLevel(scroll:GetFrameLevel() + 12)
  bar:EnableMouse(true)
  bar.track = bar:CreateTexture(nil, "BACKGROUND")
  bar.track:SetAllPoints()
  bar.track:SetColorTexture(1, 1, 1, 0.04)
  bar.thumb = NewFrame("Button", nil, bar)
  bar.thumb:SetWidth(5)
  bar.thumb.tex = bar.thumb:CreateTexture(nil, "ARTWORK")
  bar.thumb.tex:SetAllPoints()
  bar.thumb:RegisterForClicks("LeftButtonDown")
  bar.glow = 0.35                               -- how visible the thumb is (0.35 resting, up to 0.95)
  bar:Hide()

  local function metrics()
    local child = scroll:GetScrollChild()
    local view = scroll:GetHeight() or 0
    local content = child and child:GetHeight() or view
    local range = math.max(0, content - view)
    local trackH = math.max(1, (bar:GetHeight() or view))
    local thumbH = math.max(26, trackH * (view / math.max(1, content)))
    return range, trackH, math.min(thumbH, trackH)
  end

  local function paintThumb()
    local r, g, b = CB:Accent()
    bar.thumb.tex:SetColorTexture(r, g, b, bar.glow)
  end

  function bar:Update()
    local range, trackH, thumbH = metrics()
    if range <= 1 or not scroll:IsShown() then bar:Hide(); return end
    bar:Show()
    bar.thumb:SetHeight(thumbH)
    local pos = (scroll:GetVerticalScroll() or 0) / range
    pos = math.max(0, math.min(1, pos))
    bar.thumb:ClearAllPoints()
    bar.thumb:SetPoint("TOP", bar, "TOP", 0, -pos * (trackH - thumbH))
    paintThumb()
  end

  --- Lights the thumb for a moment (the frame just scrolled).
  function bar:Pulse()
    if bar.dragging then return end
    bar.glow = 0.8
    paintThumb()
    UI:Animate(bar, "glow", 0.9, function(p) if not bar.dragging and not bar.hover then bar.glow = 0.8 - 0.45 * p; paintThumb() end end)
  end

  local function setScroll(v)
    local range = metrics()
    v = math.max(0, math.min(range, v))
    scroll:SetVerticalScroll(v)
    if o.onChange then o.onChange(v) end
    bar:Update()
  end

  bar.thumb:SetScript("OnMouseDown", function()
    bar.dragging = true
    bar.glow = 0.95
    local _, y = GetCursorPosition()
    bar.dragFrom, bar.dragStart = y / bar:GetEffectiveScale(), scroll:GetVerticalScroll() or 0
    paintThumb()
    bar.thumb:SetScript("OnUpdate", function()
      if not IsMouseButtonDown or not IsMouseButtonDown("LeftButton") then
        bar.dragging = false
        bar.thumb:SetScript("OnUpdate", nil)
        bar.glow = bar.hover and 0.9 or 0.35
        paintThumb()
        return
      end
      local range, trackH, thumbH = metrics()
      local _, cy = GetCursorPosition()
      cy = cy / bar:GetEffectiveScale()
      local travel = math.max(1, trackH - thumbH)
      setScroll(bar.dragStart + (bar.dragFrom - cy) / travel * range)
    end)
  end)
  bar:SetScript("OnMouseDown", function(_, button)
    -- a click on the track outside the thumb pages towards it
    local range, trackH, thumbH = metrics()
    local _, cy = GetCursorPosition()
    cy = cy / bar:GetEffectiveScale()
    local thumbTop = bar.thumb:GetTop() or 0
    local dir = (cy > thumbTop) and -1 or 1
    setScroll((scroll:GetVerticalScroll() or 0) + dir * (scroll:GetHeight() or 100) * 0.9)
  end)
  local function over(on)
    bar.hover = on
    if not bar.dragging then bar.glow = on and 0.9 or 0.35; paintThumb() end
  end
  bar:SetScript("OnEnter", function() over(true) end)
  bar:SetScript("OnLeave", function() over(false) end)
  bar.thumb:SetScript("OnEnter", function() over(true) end)
  bar.thumb:SetScript("OnLeave", function() over(false) end)

  scroll:HookScript("OnVerticalScroll", function() bar:Update(); bar:Pulse() end)
  scroll:HookScript("OnScrollRangeChanged", function() bar:Update() end)
  scroll:HookScript("OnSizeChanged", function() bar:Update() end)
  scroll:HookScript("OnShow", function() bar:Update() end)
  scroll:HookScript("OnHide", function() bar:Hide() end)
  scroll.cbBar = bar
  return bar
end

-- A flat text button in the window style, with the accent border on hover and focus.
function UI:Button(parent, label, w, h, onClick)
  local b = NewFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(w or 60, h or 22)
  UI:Backdrop(b, UI.panel, UI.border)
  b.text = b:CreateFontString(nil, "OVERLAY", "BagglerFont")
  b.text:SetPoint("CENTER")
  b.text:SetText(label or "")
  b:SetScript("OnEnter", function(self)
    local r, g, bl = CB:Accent()
    UI:TweenBorder(self, r, g, bl)
  end)
  b:SetScript("OnLeave", function(self)
    if not self.cbFocused then UI:TweenBorder(self, UI.border[1], UI.border[2], UI.border[3]) end
  end)
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

local focusedAccents = setmetatable({}, { __mode = "k" })

--- Marks a widget as focused (for controller navigation) with the accent ring.
function UI:SetFocused(widget, on)
  widget.cbFocused = on
  focusedAccents[widget] = on and true or nil
  if widget.SetBackdropBorderColor then
    if on then
      local r, g, b = CB:Accent()
      UI:TweenBorder(widget, r, g, b)
    else
      UI:TweenBorder(widget, UI.border[1], UI.border[2], UI.border[3])
    end
  end
end

---------------------------------------------------------------------------
-- Accent-only repaint for already-open custom chrome. No window lifecycle,
-- focus/selection, geometry, native-frame styling or controller state changes.
-- Bag/bank views already subscribe to SETTING(accent); imports use a single
-- SETTING(import), so repaint their existing chrome here for that path too.
---------------------------------------------------------------------------
function UI:RefreshAccent(imported)
  local r, g, b = CB:Accent()
  for widget in pairs(focusedAccents) do
    if widget.cbFocused and widget:IsShown() then UI:TweenBorder(widget, r, g, b) end
  end
  local options = CB.Options
  if options and options.frame and options.frame:IsShown() then
    local f, page = options.frame, options.current
    f.line:SetColorTexture(r, g, b, 0.9)
    f.title:SetTextColor(r, g, b)
    if f.cbUnder then f.cbUnder:SetColorTexture(r, g, b, 1) end
    local row = page and page.rows[page.focus or 1]
    if row then row.sel:SetColorTexture(r, g, b, 0.14) end
  end
  -- Menu owns a named custom frame; recolour its existing rows in place, not
  -- by reopening it (which would reset its scroll, selection and secure use).
  local menu = rawget(_G, "BagglerMenu")
  if menu and menu:IsShown() then
    for _, row in ipairs(menu.rows) do
      row.sel:SetColorTexture(r, g, b, 0.18)
      row.check:SetColor(r, g, b)
    end
  end
  local remote = CB.Remote
  if remote and remote.frame and remote.frame:IsShown() and remote.selected then
    remote.selected.sel:SetBackdropBorderColor(r, g, b, 1)
  end
  if imported then
    for _, view in ipairs({ CB.Window, CB.Bank and CB.Bank.window }) do
      if view.frame then view:ApplyStyle() end
    end
  end
  if CB.Card then CB.Card:QueueRefresh() end
end
CB:On("SETTING", function(key)
  if key == "accent" or key == "import" then UI:RefreshAccent(key == "import") end
end)

local ICONS = {
  check   = { { 0.39, -50.2, -0.225, -0.15 }, { 0.78, 50.2, 0.15, 0.00 } },
  cross   = { { 0.80, 45, 0, 0 }, { 0.80, -45, 0, 0 } },
  chevron = { { 0.50, -45, 0.025, 0.175 }, { 0.50, 45, 0.025, -0.175 } },
  star    = { { 0.95, 0, 0, 0 }, { 0.95, 60, 0, 0 }, { 0.95, 120, 0, 0 } },
  back    = { { 0.50, 45, -0.025, 0.175 }, { 0.50, -45, -0.025, -0.175 } },     -- "<"
  down    = { { 0.50, -45, -0.175, 0.025 }, { 0.50, 45, 0.175, 0.025 } },       -- "v"
  up      = { { 0.50, 45, -0.175, -0.025 }, { 0.50, -45, 0.175, -0.025 } },     -- "^"
}

--- Square icon-style glyph button (used in the title bar).
function UI:GlyphButton(parent, glyph, tooltip, onClick)
  local drawn = ICONS[glyph]                      -- "cross", "check" ...: a drawn icon instead of a character
  local b = UI:Button(parent, drawn and "" or glyph, 22, 22, onClick)
  b.cbTooltip = tooltip -- controller chrome reuses the mouse label, not its hover script
  if drawn then
    b.icon = UI:Icon(b, glyph, 10)
    b.icon:SetPoint("CENTER")
    b.icon:SetColor(0.85, 0.85, 0.9)
  end
  b:SetScript("OnEnter", function(self)
    local r, g, bl = CB:Accent()
    UI:TweenBorder(self, r, g, bl)
    if tooltip then
      UI.Tip:SetOwner(self, "ANCHOR_BOTTOM")
      UI.Tip:SetText(tooltip, 1, 1, 1)
      UI.Tip:Show()
    end
  end)
  b:SetScript("OnLeave", function(self)
    if not self.cbFocused then UI:TweenBorder(self, UI.border[1], UI.border[2], UI.border[3]) end
    UI:HideTip()
  end)
  return b
end

---------------------------------------------------------------------------
-- The controller hint line. It is written as text by the window code ("|cff..A|r Use   |cff..Y|r Menu ...") and
-- drawn here as keycaps: each button name in a small bordered badge (the four face buttons in their own colours),
-- the action in plain muted text after it, wrapped to the window width and centred. The object stands in for the
-- FontString the windows used before: SetText, SetWidth, GetStringHeight, SetPoint, Show / Hide all work.
---------------------------------------------------------------------------
local FACE_COLORS = {
  xbox        = { A = { 0.40, 0.80, 0.45 }, B = { 0.92, 0.38, 0.38 }, X = { 0.40, 0.60, 0.98 }, Y = { 0.97, 0.82, 0.32 } },
  playstation = { Cross = { 0.40, 0.60, 0.98 }, Circle = { 0.92, 0.38, 0.38 }, Square = { 0.95, 0.55, 0.80 }, Triangle = { 0.40, 0.80, 0.45 } },
}
local BADGE_H, HINT_GAP, LINE_GAP_H = 16, 14, 4

--- Splits hint text into { { keys = {"A"}, label = "Use" }, ... }. Text outside key codes becomes a label only.
local function parseHints(text)
  text = tostring(text or "")
  local lead = text:match("^(|cff%x%x%x%x%x%x)")
  if lead and (lead == CB.HEX.muted or lead == CB.HEX.dim) then
    text = text:sub(#lead + 1)
    text = text:gsub("|r$", "", 1)
  end
  local out = {}
  local pos = 1
  while pos <= #text do
    local stop = text:find("   ", pos, true)
    local seg = text:sub(pos, stop and stop - 1 or #text)
    pos = stop and stop + 3 or #text + 1
    local keys = {}
    local rest = seg
    while true do
      local code, key, after = rest:match("^(|cff%x%x%x%x%x%x)(.-)|r(.*)$")
      if not code then break end
      keys[#keys + 1] = key
      rest = after
      if rest:match("^/|cff%x%x%x%x%x%x") then rest = rest:sub(2) else break end
    end
    rest = rest:gsub("^%s+", "")
    if #keys > 0 or rest ~= "" then out[#out + 1] = { keys = keys, label = rest } end
  end
  return out
end

UI.ParseHints = parseHints                      -- (the tests read hint lines through it)

-- The controller hint bar: each button name drawn as a keycap followed by its label, wrapped to
-- the available width. `SetText` takes the markup produced by UI:PadHints.
function UI:HintBar(parent)
  local bar = NewFrame("Frame", nil, parent)
  bar:EnableMouse(false)
  bar.badges, bar.labels, bar.slashes = {}, {}, {}
  bar.text, bar.layoutWidth, bar.layoutHeight, bar.layoutMax = "", 300, 0, 0
  local setWidth, setHeight = bar.SetWidth, bar.SetHeight

  local function newBadge()
    local b = NewFrame("Frame", nil, bar, "BackdropTemplate")
    b:SetHeight(BADGE_H)
    UI:Backdrop(b, UI.panel, UI.border)
    b.text = b:CreateFontString(nil, "OVERLAY", "BagglerFontHint")
    b.text:SetPoint("CENTER", 0, 0)
    return b
  end
  local function newLabel(pool)
    local l = bar:CreateFontString(nil, "OVERLAY", "BagglerFontHint")
    l:SetJustifyH("LEFT")
    return l
  end

  local function badge(i, key)
    local b = bar.badges[i] or newBadge()
    bar.badges[i] = b
    b.text:SetText(key)
    local face = FACE_COLORS[(CB.db and CB.db.pad and CB.db.pad.style) or "xbox"]
    local color = face and face[key]
    if color then
      b:SetBackdropBorderColor(color[1], color[2], color[3], 1)
      b:SetBackdropColor(color[1] * 0.2, color[2] * 0.2, color[3] * 0.2, 1)
      b.text:SetTextColor(color[1], color[2], color[3])
    else
      local r, g, bl = CB:Accent()
      b:SetBackdropBorderColor(0.34, 0.34, 0.40, 1)
      b:SetBackdropColor(UI.panel[1], UI.panel[2], UI.panel[3], 1)
      b.text:SetTextColor(r, g, bl)
    end
    b:SetWidth(math.max(BADGE_H, math.ceil(b.text:GetStringWidth()) + 10))
    return b
  end

  function bar:Layout()
    for _, b in ipairs(bar.badges) do b:Hide() end
    for _, l in ipairs(bar.labels) do l:Hide() end
    for _, sl in ipairs(bar.slashes) do sl:Hide() end
    local items = parseHints(bar.text)
    local width = math.max(60, bar.layoutWidth)
    local nb, nl, ns = 0, 0, 0
    -- measure every hint, then flow them into lines
    local measured = {}
    for _, item in ipairs(items) do
      local m = { parts = {}, w = 0 }
      for k, key in ipairs(item.keys) do
        if k > 1 then
          ns = ns + 1
          local sl = bar.slashes[ns] or bar:CreateFontString(nil, "OVERLAY", "BagglerFontHint")
          bar.slashes[ns] = sl
          sl:SetText("/")
          m.parts[#m.parts + 1] = { obj = sl, w = 8, isText = true }
          m.w = m.w + 8
        end
        nb = nb + 1
        local b = badge(nb, key)
        m.parts[#m.parts + 1] = { obj = b, w = b:GetWidth() }
        m.w = m.w + b:GetWidth()
      end
      if item.label ~= "" then
        nl = nl + 1
        local l = bar.labels[nl] or newLabel()
        bar.labels[nl] = l
        l:SetText(item.label)
        local lw = math.ceil(l:GetStringWidth())
        if #item.keys > 0 then m.w = m.w + 5 end
        m.parts[#m.parts + 1] = { obj = l, w = lw, isText = true, gapBefore = #item.keys > 0 and 5 or 0 }
        m.w = m.w + lw
      end
      measured[#measured + 1] = m
    end
    local lines, cur, curW = {}, {}, 0
    bar.layoutRows = {}
    for i, m in ipairs(measured) do
      local group = bar.groups and bar.groups[i]
      local groupW = m.w
      if group and (i == 1 or bar.groups[i - 1] ~= group) then
        local j = i + 1
        while measured[j] and bar.groups[j] == group do
          groupW = groupW + HINT_GAP + measured[j].w
          j = j + 1
        end
      end
      -- Keep a fitting logical pair/group together; oversized groups degrade
      -- to the existing individual-entry flow rather than overflowing.
      if #cur > 0 and groupW <= width and curW + HINT_GAP + groupW > width then
        lines[#lines + 1] = { items = cur, w = curW }
        cur, curW = {}, 0
      end
      local add = m.w + (#cur > 0 and HINT_GAP or 0)
      if #cur > 0 and curW + add > width then
        lines[#lines + 1] = { items = cur, w = curW }
        cur, curW = {}, 0
        add = m.w
      end
      cur[#cur + 1] = m
      bar.layoutRows[i] = #lines + 1
      curW = curW + add
    end
    if #cur > 0 then lines[#lines + 1] = { items = cur, w = curW } end
    local y, maxW = 0, 0
    for _, line in ipairs(lines) do
      local x = math.floor((width - line.w) / 2)
      for idx, m in ipairs(line.items) do
        if idx > 1 then x = x + HINT_GAP end
        for _, part in ipairs(m.parts) do
          x = x + (part.gapBefore or 0)
          part.obj:ClearAllPoints()
          if part.isText then
            part.obj:SetPoint("LEFT", bar, "TOPLEFT", x, -(y + BADGE_H / 2))
          else
            part.obj:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -y)
          end
          part.obj:Show()
          x = x + part.w
        end
      end
      maxW = math.max(maxW, line.w)
      y = y + BADGE_H + LINE_GAP_H
    end
    bar.layoutHeight = math.max(0, y - LINE_GAP_H)
    bar.layoutMax = maxW
    setHeight(bar, math.max(1, bar.layoutHeight))
  end

  -- the FontString surface the windows use
  function bar:SetText(text, groups)
    text = text or ""
    if text == bar.text and groups == bar.groups and bar.laidOutWidth == bar.layoutWidth then return end
    bar.groups = groups      -- (a selection move repeats the same line)
    bar.text = text
    bar.laidOutWidth = bar.layoutWidth
    bar:Layout()
  end
  function bar:GetText() return bar.text end
  bar.SetWidth = function(self, w)
    setWidth(self, w)
    if w == self.layoutWidth and self.laidOutWidth == w then return end
    self.layoutWidth = w
    self.laidOutWidth = w
    self:Layout()
  end
  function bar:GetStringHeight() return bar.layoutHeight end
  function bar:GetStringWidth() return bar.layoutMax end
  function bar:SetFontObject() end
  function bar:SetWordWrap() end
  function bar:SetJustifyH() end
  function bar:SetTextColor() end
  return bar
end

--- Puts a (possibly long) hint line inside a window: wrapped to the window's width and sitting on its bottom
--- edge. Returns the height it needs, so the window can make room for it.
function UI:FitHints(frame, fs, text, bottom)
  fs:ClearAllPoints()
  fs:SetPoint("BOTTOM", frame, "BOTTOM", 0, bottom or 6)
  fs:SetWidth(math.max(120, (frame:GetWidth() or 300) - 24))
  if fs.SetWordWrap then fs:SetWordWrap(true) end
  if fs.SetJustifyH then fs:SetJustifyH("CENTER") end
  fs:SetText(text or "")
  return math.ceil(fs:GetStringHeight() or 12) + (bottom or 6) + 4
end

--- Escape closes a Baggler window without writing into the game's UISpecialFrames list. Writing to that list
--- from an add-on leaves a tainted entry that the game's Escape handling reads every time it is pressed.
--- The window listens for the key itself and lets every other key through to the game.
function UI:EscapeClose(frame, closeFn)
  -- The key-passing setting cannot be changed in combat (the game blocks it and the controller is reset), so it is only
  -- touched out of combat; in combat it keeps its last value, which is "pass the key on".
  local function propagate(f, on)
    if not InCombatLockdown() then pcall(f.SetPropagateKeyboardInput, f, on) end
  end
  frame:EnableKeyboard(true)
  propagate(frame, true)
  frame:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" and self:IsShown() then
      propagate(self, false)
      -- a menu or the quantity box over the window is dismissed first; the window stays
      local picker = _G["BagglerQuantity"]
      if CB.Menu and CB.Menu:IsOpen() then CB.Menu:Close()
      elseif picker and picker:IsShown() then picker:Hide()
      elseif closeFn then
        -- a closeFn that returns "pass" leaves the key to the game (a game window is up that Escape must close)
        if closeFn(self) == "pass" then propagate(self, true) end
      else self:Hide() end
      -- let keys through again on the next frame (this window may already be hidden)
      C_Timer.After(0, function() propagate(self, true) end)
    else
      propagate(self, true)
    end
  end)
end

--- A stack count for a corner: 1,234 -> "1.2k", 25,000 -> "25k". Whole numbers below a thousand.
function UI:Count(n)
  n = tonumber(n) or 0
  if n >= 10000 then return ("%dk"):format(math.floor(n / 1000)) end
  if n >= 1000 then return (("%.1fk"):format(math.floor(n / 100) / 10):gsub("%.0k", "k")) end
  return tostring(n)
end

--- Styles a stack-count string for the bottom-right corner of a tile. No backing: a bright number with an outline
--- and shadow reads over any icon art without a dark box that would crowd the item. `tile` is the frame it sits in.
--- Returns the string.
function UI:StyleCount(fs, tile)
  fs:SetFontObject("BagglerFontCount")
  if fs.SetJustifyH then fs:SetJustifyH("RIGHT") end
  fs:ClearAllPoints()
  fs:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -3, 3)
  return fs
end

--- A time span for reading ("1h 5m", "2m 30s", "45s").
function UI:Duration(seconds)
  seconds = math.max(0, math.ceil(seconds or 0))
  local h, m, sec = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
  if h > 0 then return m > 0 and ("%dh %dm"):format(h, m) or ("%dh"):format(h) end
  if m > 0 then return sec > 0 and ("%dm %ds"):format(m, sec) or ("%dm"):format(m) end
  return ("%ds"):format(sec)
end

function UI:Money(amount)
  amount = amount or 0
  if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
    return C_CurrencyInfo.GetCoinTextureString(amount)
  end
  if GetCoinTextureString then return GetCoinTextureString(amount) end
  return tostring(amount)
end

--- Controller glyph label for a gamepad key, in the user's chosen style.
local LABELS = {
  xbox = { PAD1 = "A", PAD2 = "B", PAD3 = "X", PAD4 = "Y", PADLSHOULDER = "LB", PADRSHOULDER = "RB",
           PADLTRIGGER = "LT", PADRTRIGGER = "RT", PADLSTICK = "L3", PADRSTICK = "R3",
           PADBACK = "View", PADFORWARD = "Menu", PADDUP = "Up", PADDDOWN = "Down",
           PADDLEFT = "Left", PADDRIGHT = "Right" },
  nintendo = { PAD1 = "B", PAD2 = "A", PAD3 = "Y", PAD4 = "X", PADLSHOULDER = "L", PADRSHOULDER = "R",
           PADLTRIGGER = "ZL", PADRTRIGGER = "ZR", PADLSTICK = "L3", PADRSTICK = "R3",
           PADBACK = "Minus", PADFORWARD = "Plus", PADDUP = "Up", PADDDOWN = "Down",
           PADDLEFT = "Left", PADDRIGHT = "Right" },
  playstation = { PAD1 = "Cross", PAD2 = "Circle", PAD3 = "Square", PAD4 = "Triangle", PADLSHOULDER = "L1",
           PADRSHOULDER = "R1", PADLTRIGGER = "L2", PADRTRIGGER = "R2", PADLSTICK = "L3", PADRSTICK = "R3",
           PADBACK = "Share", PADFORWARD = "Options", PADDUP = "Up", PADDDOWN = "Down",
           PADDLEFT = "Left", PADDRIGHT = "Right" },
}
function UI:PadLabel(key)
  local style = CB.db.pad.style
  local set = LABELS[style]
  if set and set[key] then return set[key] end
  return (key:gsub("^PAD", ""))
end

--- Soft drop shadow: six faint 1px rings just outside the frame, fading quickly (a quadratic falloff reads as a
--- blur; three even rings read as an outline).
function UI:Shadow(frame)
  local alphas = { 0.34, 0.22, 0.13, 0.07, 0.035, 0.015 }
  frame.cbShadow = {}
  for i, a in ipairs(alphas) do
    local ring = NewFrame("Frame", nil, frame, "BackdropTemplate")
    ring:SetPoint("TOPLEFT", -i, i)
    ring:SetPoint("BOTTOMRIGHT", i, -i)
    ring:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
    UI:EdgeFile(ring, 1)
    ring:SetBackdropBorderColor(0, 0, 0, a)
    ring:EnableMouse(false)
    frame.cbShadow[i] = ring
  end
end

--- Horizontal fade on a texture (solid colour if gradients are unavailable).
function UI:Fade(tex, r, g, b, a1, a2)
  local ok = false
  if tex.SetGradient and CreateColor then
    ok = pcall(tex.SetGradient, tex, "HORIZONTAL", CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
  end
  if not ok then tex:SetColorTexture(r, g, b, (a1 + a2) / 2) end
end

--- A small drawn icon made of rectangles, centred on `parent`.
--- rects = { {w, h, x, y, rotationDegrees}, ... }
function UI:DrawIcon(parent, rects, r, g, b)
  parent.cbIcon = parent.cbIcon or {}
  for i, spec in ipairs(rects) do
    local t = parent.cbIcon[i]
    if not t then
      t = parent:CreateTexture(nil, "OVERLAY")
      parent.cbIcon[i] = t
    end
    t:SetColorTexture(r or 0.85, g or 0.85, b or 0.9, 1)
    t:SetSize(spec[1], spec[2])
    t:ClearAllPoints()
    t:SetPoint("CENTER", spec[3] or 0, spec[4] or 0)
    if spec[5] then t:SetRotation(math.rad(spec[5])) end
  end
end

--- Small vector-style icons built from anti-aliased bars, so a tick, a cross, a chevron and a star look the same at
--- every scale and in every window (typed characters such as "x", ">" and "*" never did). Returns a frame that is
--- positioned like any other; icon:SetColor(r, g, b, a) tints it.
--- Each bar: { length, angleDegrees, centreX, centreY } in units of the icon size (y up).

function UI:Icon(parent, kind, size, thickness)
  size = size or 12
  local bars = ICONS[kind] or ICONS.cross
  local holder = NewFrame("Frame", nil, parent)
  holder:SetSize(size, size)
  holder:EnableMouse(false)
  holder.parts = {}
  local t = thickness or math.max(1.5, size * 0.14)
  for i, bar in ipairs(bars) do
    local tex = holder:CreateTexture(nil, "OVERLAY")
    tex:SetSize(bar[1] * size, t)
    tex:SetPoint("CENTER", holder, "CENTER", bar[3] * size, bar[4] * size)
    tex:SetRotation(math.rad(bar[2]))
    tex:SetColorTexture(1, 1, 1, 1)
    holder.parts[i] = tex
  end
  function holder:SetColor(r, g, b, a)
    for _, tex in ipairs(self.parts) do tex:SetColorTexture(r, g, b, a or 1) end
  end
  return holder
end

--- Compact price: the two largest units, coloured (e.g. "12g 40s", "45s", "3c").
function UI:MoneyShort(amount)
  amount = math.floor(amount or 0)
  if amount <= 0 then return CB.HEX.muted .. "free|r" end
  local g = math.floor(amount / 10000)
  local sv = math.floor((amount % 10000) / 100)
  local c = amount % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = CB.HEX.gold .. g .. "g|r" end
  if sv > 0 and #parts < 2 then parts[#parts + 1] = CB.HEX.soft .. sv .. "s|r" end
  if c > 0 and #parts < 2 and g == 0 then parts[#parts + 1] = CB.HEX.copper .. c .. "c|r" end
  return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Animation engine: one shared updater drives every tween, so the whole add-on
-- moves the same way. "Animations" off in settings makes everything instant.
---------------------------------------------------------------------------
local anims = {}
local animFrame = CreateFrame("Frame")
animFrame:Hide()

local function easeOut(p) local q = 1 - p; return 1 - q * q * q end

function UI:AnimationsOn()
  return not (CB.db and CB.db.animations == false)
end

--- Motion beyond a plain fade (slides, ripples, pulsing): off with "Reduce motion", which keeps the fades.
function UI:MotionOn()
  return UI:AnimationsOn() and not (CB.db and CB.db.reduceMotion)
end

--- A short overshoot-and-settle curve for offsets: 0 -> 1 with a small bounce past 1 on the way.
function UI.Spring(t)
  if t >= 1 then return 1 end
  local s = 1.70158
  t = t - 1
  return 1 + t * t * ((s + 1) * t + s)
end

--- Advances every running animation by dt seconds (also called directly by tests).
function UI:StepAnimations(dt)
  local i = 1
  while i <= #anims do
    local a = anims[i]
    a.t = a.t + dt
    local raw = a.t / a.d
    if raw > 1 then raw = 1 end
    local ok = CB:Safe("anim:" .. a.key, a.step, easeOut(raw), raw)
    if raw >= 1 or not ok then
      table.remove(anims, i)
      if ok and a.done then CB:Safe("anim:" .. a.key .. ":done", a.done) end
    else
      i = i + 1
    end
  end
  if #anims == 0 then animFrame:Hide() end
end
animFrame:SetScript("OnUpdate", function(_, dt) UI:StepAnimations(dt) end)

--- step(eased, raw) runs from 0 to 1 over `duration`; a new animation with the same owner+key replaces the old.
function UI:Animate(owner, key, duration, step, done)
  for i = #anims, 1, -1 do
    if anims[i].owner == owner and anims[i].key == key then table.remove(anims, i) end
  end
  if not UI:AnimationsOn() or duration <= 0 then
    CB:Safe("anim:" .. key, step, 1, 1)
    if done then CB:Safe("anim:" .. key .. ":done", done) end
    return
  end
  anims[#anims + 1] = { owner = owner, key = key, t = 0, d = duration, step = step, done = done }
  animFrame:Show()
end

function UI:Cancel(owner, key)
  for i = #anims, 1, -1 do
    if anims[i].owner == owner and (not key or anims[i].key == key) then table.remove(anims, i) end
  end
end

function UI:Running() return #anims end

--- Eases a backdrop frame's border colour to (r,g,b).
function UI:TweenBorder(f, r, g, b, dur)
  if not f.SetBackdropBorderColor then return end
  local c = f.cbBC or { UI.border[1], UI.border[2], UI.border[3] }
  f.cbBC = c
  local fr, fg, fb = c[1], c[2], c[3]
  UI:Animate(f, "border", dur or 0.12, function(p)
    c[1], c[2], c[3] = fr + (r - fr) * p, fg + (g - fg) * p, fb + (b - fb) * p
    f:SetBackdropBorderColor(c[1], c[2], c[3], 1)
  end)
end

--- Briefly washes a backdrop border to a colour and back (feedback: bought, refused, ...).
function UI:FlashBorder(f, r, g, b)
  if not f.SetBackdropBorderColor then return end
  local c = f.cbBC or { UI.border[1], UI.border[2], UI.border[3] }
  f.cbBC = c
  local r0, g0, b0 = c[1], c[2], c[3]
  UI:Animate(f, "border", 0.5, function(_, p)
    local t = p < 0.25 and (p / 0.25) or (1 - (p - 0.25) / 0.75)
    f:SetBackdropBorderColor(r0 + (r - r0) * t, g0 + (g - g0) * t, b0 + (b - b0) * t, 1)
  end, function() f:SetBackdropBorderColor(r0, g0, b0, 1) end)
end

--- Window "arrival": a quick fade (a scale change would blur the text for the moment it lasts).
function UI:Arrive(f, baseScale, onDone)
  f.cbArriving = true
  f:SetScale(baseScale)
  UI:Resnap()                                     -- the hairlines are sized for the scale the window has now
  UI:Animate(f, "arrive", 0.14, function(p) f:SetAlpha(p) end, function()
    f.cbArriving = false
    f:SetAlpha(1)
    if onDone then onDone() end
  end)
end

--- Items arrive in a quick ripple rather than all at once. `groups[i]` (optional) is the section frame i belongs to:
--- sections start a little after one another and ripple inside themselves.
function UI:Cascade(owner, key, frames, groups)
  local n = #frames
  if n == 0 or not UI:MotionOn() then return end
  for _, fr in ipairs(frames) do fr:SetAlpha(0) end
  -- each frame fades in over FADE seconds, starting at a time worked out from its section and its place in it
  local FADE, SECTION_STEP, SECTION_CAP, RIPPLE = 0.14, 0.04, 0.24, 0.18
  local firstOf, countOf, order, sections = {}, {}, {}, 0
  for i = 1, n do
    local g = groups and groups[i] or 0
    if firstOf[g] == nil then sections = sections + 1; firstOf[g] = sections; countOf[g] = 0 end
    countOf[g] = countOf[g] + 1
    order[i] = countOf[g]
  end
  local starts, last = {}, 0
  for i = 1, n do
    local g = groups and groups[i] or 0
    local startAt = math.min((firstOf[g] - 1) * SECTION_STEP, SECTION_CAP)
      + ((order[i] - 1) / math.max(countOf[g] - 1, 1)) * math.min(RIPPLE, n * 0.004)
    starts[i] = startAt
    if startAt > last then last = startAt end
  end
  UI:Animate(owner, key, last + FADE, function(_, raw)
    local elapsed = raw * (last + FADE)
    for i, fr in ipairs(frames) do
      local a = (elapsed - starts[i]) / FADE
      fr:SetAlpha(a < 0 and 0 or (a > 1 and 1 or a))
    end
  end, function()
    for _, fr in ipairs(frames) do fr:SetAlpha(1) end
  end)
end

--- Fades a frame in (and shows it).
function UI:FadeIn(f, dur)
  f:Show()
  UI:Animate(f, "fadein", dur or 0.14, function(p) f:SetAlpha(p) end, function() f:SetAlpha(1) end)
end

--- One underline that glides between tabs.
function UI:SlideUnderline(host, tab, r, g, b)
  local u = host.cbUnder
  if not u then
    u = host:CreateTexture(nil, "OVERLAY")
    UI:Line(u, "h", 2)
    host.cbUnder = u
  end
  u:SetColorTexture(r, g, b, 1)
  local tx = (tab:GetLeft() or 0) - (host:GetLeft() or 0) + 6
  local ty = (tab:GetBottom() or 0) - (host:GetBottom() or 0)
  local tw = math.max(4, (tab:GetWidth() or 40) - 12)
  local fx, fw = u.cx or tx, u.cw or tw
  local function place(x, w)
    u.cx, u.cw = x, w
    u:ClearAllPoints()
    u:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", x, ty)
    u:SetWidth(w)
  end
  u:Show()
  if not u.cx then place(tx, tw) return end
  UI:Animate(u, "slide", 0.18, function(p) place(fx + (tx - fx) * p, fw + (tw - fw) * p) end)
end

---------------------------------------------------------------------------
-- Resize grip. Dragging it snaps the width to whole columns (sections reflow live)
-- and sets the height. cfg: stepX(), chromeW(), chromeH(), minCols, maxCols, minH, maxH(),
-- getCols(), getScrollH(), apply(cols, h, colsChanged), reset(), savePoint()
---------------------------------------------------------------------------
function UI:ResizeGrip(f, cfg)
  local grip = NewFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetFrameLevel(f:GetFrameLevel() + 20)
  grip:RegisterForClicks("LeftButtonUp")
  grip.lines = {}
  for k = 1, 3 do
    local t = grip:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(0.55, 0.55, 0.6, 0.9)
    t:SetSize(k * 4, 1.5)
    t:SetRotation(math.rad(45))
    t:SetPoint("CENTER", grip, "BOTTOMRIGHT", -3 * k, 3 * k)
    grip.lines[k] = t
  end
  grip.readout = f:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
  grip.readout:SetPoint("BOTTOMRIGHT", grip, "TOPLEFT", 6, 2)
  grip.readout:SetAlpha(0)

  local function paint(r, g, b)
    for _, t in ipairs(grip.lines) do t:SetColorTexture(r, g, b, 0.95) end
  end
  grip.cbPaint = paint
  grip:SetScript("OnEnter", function()
    if CB.db.locked then return end
    local r, g, b = CB:Accent(); paint(r, g, b)
    UI.Tip:SetOwner(grip, "ANCHOR_TOPLEFT")
    UI.Tip:SetText("Drag to resize", 1, 1, 1)
    UI.Tip:AddLine("Double-click to reset", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3])
    UI.Tip:Show()
  end)
  grip:SetScript("OnLeave", function()
    if not grip.dragging then paint(0.55, 0.55, 0.6) end
    UI:HideTip()
  end)

  local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

  local function cursor()
    local x, y = GetCursorPosition()
    local s = f:GetEffectiveScale()
    return x / s, y / s
  end

  grip:SetScript("OnMouseDown", function()
    if CB.db.locked then return end
    -- re-anchor to the top-left so the window grows toward the bottom-right
    local left, top = f:GetLeft(), f:GetTop()
    if left and top then
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    grip.dragging = true
    grip.sx, grip.sy = cursor()
    grip.sw, grip.sh = cfg.getCols and cfg.getCols() or 0, cfg.getScrollH and cfg.getScrollH() or 0
    grip.frameW = f:GetWidth()
    grip.frameH = f:GetHeight()
    local r, g, b = CB:Accent(); paint(r, g, b)
    grip.readout:SetAlpha(1)
  end)

  grip:SetScript("OnUpdate", function()
    if not grip.dragging then return end
    local x, y = cursor()
    if cfg.mode == "pixel" then
      local function lim(v) if type(v) == "function" then return v() end return v end
      local w = clamp(grip.frameW + (x - grip.sx), lim(cfg.minW), lim(cfg.maxW))
      local h = clamp(grip.frameH + (grip.sy - y), lim(cfg.minH), lim(cfg.maxH))
      w, h = math.floor(w + 0.5), math.floor(h + 0.5)
      cfg.apply(w, h)
      grip.readout:SetText(w .. " x " .. h)
      return
    end
    local step = cfg.stepX()
    local cols = clamp(math.floor((grip.frameW + (x - grip.sx) - cfg.chromeW()) / step + 0.5), cfg.minCols, cfg.maxCols)
    local h = clamp(grip.sh + (grip.sy - y), cfg.minH, cfg.maxH())
    local curCols, curH = cfg.getCols(), cfg.getScrollH()
    if cols ~= curCols or math.abs(h - curH) >= 1 then
      cfg.apply(cols, math.floor(h), cols ~= curCols)
    end
    grip.readout:SetText(cols .. " columns")
  end)

  local function finish()
    if not grip.dragging then return end
    grip.dragging = false
    paint(0.55, 0.55, 0.6)
    UI:Animate(grip, "readout", 0.5, function(p) grip.readout:SetAlpha(1 - p) end)
    if cfg.savePoint then cfg.savePoint() end
  end
  grip:SetScript("OnMouseUp", finish)
  grip:SetScript("OnHide", finish)
  grip:SetScript("OnDoubleClick", function()
    if cfg.reset then cfg.reset() end
  end)
  return grip
end

--- One step of a controller resize. `dir` is left/right (columns or width) or up/down (height).
--- Returns false when the window is locked. Mouse dragging is unchanged.
function UI:NudgeResize(cfg, grip, dir)
  if CB.db and CB.db.locked then return false end
  local function lim(v) if type(v) == "function" then return v() end return v end
  local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
  end
  if cfg.mode == "pixel" then
    local w, h = cfg.getW(), cfg.getH()
    local step = cfg.step or 40
    if dir == "right" then w = w + step
    elseif dir == "left" then w = w - step
    elseif dir == "down" then h = h + step
    else h = h - step end
    w = math.floor(clamp(w, lim(cfg.minW), lim(cfg.maxW)) + 0.5)
    h = math.floor(clamp(h, lim(cfg.minH), lim(cfg.maxH)) + 0.5)
    cfg.apply(w, h)
    if grip and grip.readout then
      grip.readout:SetText(w .. " x " .. h)
      grip.readout:SetAlpha(1)
    end
  else
    local cols, h = cfg.getCols(), cfg.getScrollH()
    if dir == "right" then cols = cols + 1
    elseif dir == "left" then cols = cols - 1
    else
      local row = cfg.stepY and cfg.stepY() or 28
      if dir == "down" then h = h + row else h = h - row end
    end
    cols = clamp(math.floor(cols + 0.5), cfg.minCols, cfg.maxCols)
    h = clamp(math.floor(h + 0.5), cfg.minH, lim(cfg.maxH))
    local curCols, curH = cfg.getCols(), cfg.getScrollH()
    if cols ~= curCols or math.abs(h - curH) >= 1 then
      cfg.apply(cols, h, cols ~= curCols)
    end
    if grip and grip.readout then
      grip.readout:SetText(cols .. " columns")
      grip.readout:SetAlpha(1)
    end
  end
  if grip and grip.cbPaint then
    local r, g, b = CB:Accent()
    grip.cbPaint(r, g, b)
  end
  return true
end

--- Shared pad handling while a window is in resize mode. "done" leaves the mode.
function UI:SizePad(cfg, grip, action)
  if action == "left" or action == "right" or action == "up" or action == "down" then
    return UI:NudgeResize(cfg, grip, action)
  elseif action == "menu" then
    if CB.db and CB.db.locked then return "ignore" end
    if cfg.reset then cfg.reset() end
    if grip and grip.readout then
      if cfg.mode == "pixel" then grip.readout:SetText("Reset")
      else grip.readout:SetText((cfg.getCols and cfg.getCols() or "") .. " columns") end
      grip.readout:SetAlpha(1)
    end
    return "reset"
  elseif action == "close" or action == "use" then
    return "done"
  end
  return "ignore"
end
