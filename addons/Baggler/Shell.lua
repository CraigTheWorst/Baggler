-- Baggler shell: the parts every visit window is made of (panel, item tile, list row), so windows built by
-- other modules have the same title bar, edges, spacing and states as the Baggler windows.
-- The older Baggler windows build these by hand; new windows should use this file instead of copying them.
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local UI = CB.UI

local PAD, TOP_H = UI.METRICS.pad, UI.METRICS.topH

---------------------------------------------------------------------------
-- Item quality colour
---------------------------------------------------------------------------
--- r, g, b for an item quality number (0 grey ... 5 orange). Unknown values come out white.
function UI:QualityRGB(quality)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end

---------------------------------------------------------------------------
-- Hiding a game window without closing it
---------------------------------------------------------------------------
-- The game's windows close whatever they show when they are hidden: the quest frame closes the quest, the gossip frame
-- the conversation, the flight map the flight master, the inspect frame the inspection. Hiding is therefore not
-- allowed, and neither is moving a shown frame under a hidden parent (that fires the same hide script). A window that
-- is taken over stays "shown" to the game and is only made invisible and too small to click.
local concealed = setmetatable({}, { __mode = "k" })
local generation = setmetatable({}, { __mode = "k" })     -- bumped on every Conceal, so a late restore can tell it is stale

--- Makes a game frame invisible without hiding it. Safe to call again; it never forgets the original look.
function UI:Conceal(frame)
  if not frame then return end
  local was = concealed[frame]
  if not was then
    was = { alpha = frame:GetAlpha(), scale = frame:GetScale() }
    concealed[frame] = was
  end
  generation[frame] = (generation[frame] or 0) + 1
  frame:SetAlpha(0)
  frame:SetScale(0.001)
end

--- Gives a concealed frame its look back.
function UI:Unconceal(frame)
  local was = frame and concealed[frame]
  if not was then return end
  concealed[frame] = nil
  frame:SetScale(was.scale or 1)
  frame:SetAlpha(was.alpha or 1)
end

function UI:IsConcealed(frame) return frame ~= nil and concealed[frame] ~= nil end

--- Gives a concealed frame its look back once the game has hidden it (restoring while it is still open would flash
--- it on screen). If the frame is concealed again in the meantime, nothing is restored.
function UI:UnconcealWhenHidden(frame)
  if not (frame and concealed[frame]) then return end
  local mine, tries = generation[frame], 0
  local function check()
    tries = tries + 1
    if not concealed[frame] or generation[frame] ~= mine then return end
    if not frame:IsShown() or tries > 24 then UI:Unconceal(frame) else C_Timer.After(0.25, check) end
  end
  C_Timer.After(0.25, check)
end

--- Puts a secure overlay (a child of UIParent) over `target` by SCREEN position: the numbers are read from the target and
--- set on the overlay, and nothing connects the two. Out of combat only (a secure frame cannot be moved in combat).
--- Never anchor a secure frame to a window or one of its parts: the game then treats that window as protected too
--- (it cannot be shown, hidden, moved, resized or scaled in combat), which is exactly when a loot window opens.
function UI:PlaceOver(overlay, target)
  if InCombatLockdown() then return end
  local left, bottom, width, height = target:GetRect()
  if not left then return end
  local k = target:GetEffectiveScale() / UIParent:GetEffectiveScale()
  overlay:ClearAllPoints()
  overlay:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * k, bottom * k)
  overlay:SetSize(math.max(1, width * k), math.max(1, height * k))
end

--- Lays a secure button over `button` that clicks one of the game's own buttons (its close button, say): a game
--- window cannot be closed by add-on code without the game blocking its own close-down, but a click on the game's own
--- button is the game's. The overlay hands hover on, so the look and the tooltip stay. Aim it with
--- overlay:Arm(gameButton); unarmed it hides, so it never covers a button that would then do nothing.
--- The overlay is not a child of the window and not anchored to it (see UI:PlaceOver): it is placed by screen position
--- and follows the button from a light check out of combat, so it can never make a window protected. In combat it can
--- neither be moved nor shown or hidden, so it catches up when combat ends.
--- Returns nil when the client cannot make one.
function UI:SecureClick(button, name)
  local ok, secure = pcall(CreateFrame, "Button", name, UIParent, "SecureActionButtonTemplate")
  if not ok or not secure then return nil end
  secure:SetFrameStrata(button:GetFrameStrata())
  secure:SetFrameLevel(button:GetFrameLevel() + 5)
  -- both phases: the game acts on press or on release according to a setting, and the other one does nothing
  secure:RegisterForClicks("AnyUp", "AnyDown")
  secure:SetAttribute("type", "click")
  secure:SetScript("OnEnter", function() local s = button:GetScript("OnEnter"); if s then s(button) end end)
  secure:SetScript("OnLeave", function() local s = button:GetScript("OnLeave"); if s then s(button) end end)
  local function sync()
    if InCombatLockdown() then return end
    local show = secure.armed and button:IsVisible() and true or false
    if show then UI:PlaceOver(secure, button) end
    secure:SetShown(show)
  end
  secure.Sync = sync
  -- the window can be moved, shown or hidden at any time: a light check keeps the overlay over the button
  local watcher, acc = CreateFrame("Frame"), 0
  watcher:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < 0.1 then return end
    acc = 0
    if secure.armed or secure:IsShown() then sync() end
  end)
  CB:RegisterEvent("PLAYER_REGEN_ENABLED", sync)
  function secure:Arm(target)
    if InCombatLockdown() then return end
    self:SetAttribute("clickbutton", target)
    self.armed = target ~= nil
    sync()
  end
  secure:Hide()
  return secure
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
--- Builds the window shell and returns the frame. Fields on the result:
---   bar (draggable title strip), title, icon (optional), close (button), hints (controller hint bar), rule (line under
---   the bar), grip (resize handle, when `resize` is given).
--- The window can be dragged by its title bar or by any empty part of it, and is kept on the screen.
--- o = {
---   strata   frame strata (default "HIGH")
---   icon     texture shown before the title (optional)
---   onClose  called by the close button and by Escape; should end the visit
---   onHide   called whenever the frame hides (hand the controller back, close menus ...)
---   moved    called with { point, relativeName, relativePoint, x, y } after the player drags the window
---   escape   "game" leaves the Escape key to the game instead of closing the window itself
---   fixed    true for a window that frames something else and must not be dragged away from it
---   resize   { minW, minH, maxW?, maxH?, get() -> w, h | nil, set(w, h | nil), onSize(w, h) } makes the window
---            resizable: a grip in the corner for the mouse and f:BeginSize() for the controller. `set(nil)` clears the
---            saved size. The window must lay its contents out from f:GetWidth() / f:GetHeight() in onSize.
--- }
function UI:Panel(name, o)
  o = o or {}
  UI:MakeFonts()
  local f = NewFrame("Frame", name, UIParent, "BackdropTemplate")
  f:SetFrameStrata(o.strata or "HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(not o.fixed)
  f:EnableMouse(true)
  f:Hide()
  UI:Backdrop(f, UI.bg, UI.border, CB.db.bgAlpha, TOP_H)
  UI:Shadow(f)

  local function drag() if not CB.db.locked then f:StartMoving() end end
  local function drop()
    f:StopMovingOrSizing()
    if o.moved then
      local point, rel, relPoint, x, y = f:GetPoint()
      o.moved({ point, (rel and rel:GetName()) or "UIParent", relPoint, x, y })
    end
  end
  -- the whole window moves (children that take the mouse, like buttons and lists, keep their clicks)
  if not o.fixed then
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", drag)
    f:SetScript("OnDragStop", drop)
  end

  local bar = NewFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT", 0, 0); bar:SetPoint("TOPRIGHT", 0, 0); bar:SetHeight(TOP_H)
  bar:EnableMouse(true)
  if not o.fixed then
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", drag)
    bar:SetScript("OnDragStop", drop)
  end
  f.bar = bar

  local titleX = PAD
  if o.icon then
    f.icon = bar:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(18, 18)
    f.icon:SetPoint("LEFT", PAD, 0)
    f.icon:SetTexture(o.icon)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    titleX = PAD + 18 + 8
  end
  f.title = bar:CreateFontString(nil, "OVERLAY", "BagglerFontTitle")
  f.title:SetPoint("LEFT", titleX, 0)
  f.title:SetPoint("RIGHT", bar, "RIGHT", -(PAD + 40), 0)
  f.title:SetJustifyH("LEFT")
  f.title:SetWordWrap(false)

  f.close = UI:GlyphButton(bar, "cross", "Close", function() if o.onClose then o.onClose() end end)
  f.close:SetPoint("RIGHT", bar, "RIGHT", -10, 0)

  f.rule = f:CreateTexture(nil, "ARTWORK")
  f.rule:SetPoint("TOPLEFT", 1, -TOP_H); f.rule:SetPoint("TOPRIGHT", -1, -TOP_H)
  UI:Line(f.rule, "h", 1)
  f.rule:SetColorTexture(UI.border[1], UI.border[2], UI.border[3], 0.8)

  f.hints = UI:HintBar(f)

  f:SetScript("OnHide", function()
    if o.onHide then o.onHide() end
    CB.Menu:Close()
    UI:HideTip()
  end)
  -- Escape closes the window by itself, unless the window asks the game to handle the key (the game's own frame
  -- must close with it and an add-on cannot close that frame)
  if o.escape ~= "game" then
    UI:EscapeClose(f, o.onClose and function() o.onClose() end or nil)
  end

  if o.resize then UI:PanelResizable(f, o) end
  return f
end

---------------------------------------------------------------------------
-- Resizing a panel
---------------------------------------------------------------------------
--- Adds the corner grip, the saved size and the controller resize mode to a panel (see UI:Panel `resize`).
function UI:PanelResizable(f, o)
  local rz = o.resize
  local function lim(v) if type(v) == "function" then return v() end return v end
  f.sizeCfg = {
    mode = "pixel", step = 40,
    minW = rz.minW, minH = rz.minH,
    maxW = rz.maxW or function() return math.floor(UIParent:GetWidth() * 0.95) end,
    maxH = rz.maxH or function() return math.floor(UIParent:GetHeight() * 0.92) end,
    getW = function() return math.floor(f:GetWidth() + 0.5) end,
    getH = function() return math.floor(f:GetHeight() + 0.5) end,
    apply = function(w, h)
      f:SetSize(w, h)
      if rz.set then rz.set(w, h) end
      f.cbUserSized = true
      if rz.onSize then rz.onSize(w, h) end
    end,
    reset = function()
      if rz.set then rz.set(nil) end
      f.cbUserSized = false
      if rz.onSize then rz.onSize(nil, nil) end         -- nil: the window picks its own size again
    end,
    savePoint = function()
      if o.moved then
        local point, rel, relPoint, x, y = f:GetPoint()
        o.moved({ point, (rel and rel:GetName()) or "UIParent", relPoint, x, y })
      end
    end,
  }
  f.grip = UI:ResizeGrip(f, f.sizeCfg)

  --- The size the player saved, clamped to what fits now (nil when there is none).
  function f:SavedSize()
    local w, h = rz.get and rz.get()
    if type(w) == "table" then w, h = w.w, w.h end
    if not (w and h) then return nil end
    w = math.max(lim(rz.minW), math.min(w, lim(f.sizeCfg.maxW)))
    h = math.max(lim(rz.minH), math.min(h, lim(f.sizeCfg.maxH)))
    return w, h
  end

  --- Controller resize mode: the D-pad changes the size, Y resets it, A or B finishes.
  function f:BeginSize()
    if CB.db.locked then CB:Print("The window is locked. Unlock it in settings."); return false end
    f.sizing = true
    local r, g, b = CB:Accent()
    if f.grip.cbPaint then f.grip.cbPaint(r, g, b) end
    f.grip.readout:SetText(f.sizeCfg.getW() .. " x " .. f.sizeCfg.getH())
    f.grip.readout:SetAlpha(1)
    return true
  end

  function f:EndSize()
    f.sizing = false
    if f.grip.cbPaint then f.grip.cbPaint(0.55, 0.55, 0.6) end
    UI:Animate(f.grip, "readout", 0.35, function(p) f.grip.readout:SetAlpha(1 - p) end)
    f.sizeCfg.savePoint()
  end

  --- Feeds one controller action to the resize mode; returns true when the action was used.
  function f:SizePad(action)
    if not f.sizing then return false end
    if UI:SizePad(f.sizeCfg, f.grip, action) == "done" then f:EndSize() end
    return true
  end
end

--- The hint line while a panel is in controller resize mode.
function UI:PanelSizingHint()
  local inverse = {}
  for key, action in pairs(CB.db.pad.map) do if action then inverse[action] = key end end
  local r, g, b = CB:Accent()
  local col = ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
  local parts = { col .. "Left/Right|r Width", col .. "Up/Down|r Height" }
  if inverse.menu then parts[#parts + 1] = col .. UI:PadLabel(inverse.menu) .. "|r Reset" end
  if inverse.use and inverse.close then
    parts[#parts + 1] = col .. UI:PadLabel(inverse.use) .. "|r/" .. col .. UI:PadLabel(inverse.close) .. "|r Done"
  end
  return CB.HEX.muted .. table.concat(parts, "   ") .. "|r"
end

--- Puts a panel where the player left it, or at `fallback` ({ point, x, y } relative to the screen centre by default).
function UI:PlacePanel(f, saved, fallback)
  f:ClearAllPoints()
  if saved then
    f:SetPoint(saved[1], _G[saved[2]] or UIParent, saved[3], saved[4], saved[5])
  else
    fallback = fallback or { "CENTER", 0, 20 }
    f:SetPoint(fallback[1], UIParent, fallback[1], fallback[2] or 0, fallback[3] or 0)
  end
end

--- Sets the hint line and returns the height it needs (see UI:FitHints).
function UI:SetPanelHints(f, text)
  return UI:FitHints(f, f.hints, text, 6)
end

---------------------------------------------------------------------------
-- Item tile
---------------------------------------------------------------------------
--- A square item button in the look of the bag tiles: dark fill, icon, pixel-snapped quality edge, a thin wash of the
--- quality colour along the bottom, a count on a dark pill, press and hover states, and an accent ring for the
--- selection. Paint it with tile:Paint({ icon, count, quality, dim, label, meter }); `label` is a short text in the
--- top-left corner and `meter` (0..1) draws a thin bar along the bottom.
--- Layers: pills and the wash are textures of the button itself, which draw beneath the text because the text belongs
--- to the child edge frame (a child frame draws above its parent's own regions).
function UI:ItemTile(parent, size)
  local t = NewFrame("Button", nil, parent)
  t:SetSize(size, size)
  t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  t.bg = t:CreateTexture(nil, "BACKGROUND", nil, -6)
  t.bg:SetAllPoints()
  t.bg:SetColorTexture(UI.tile[1], UI.tile[2], UI.tile[3], 1)
  t.icon = t:CreateTexture(nil, "ARTWORK")
  t.icon:SetPoint("TOPLEFT", 1, -1); t.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  t:SetHighlightTexture(UI.WHITE)
  local hl = t:GetHighlightTexture()
  if hl then hl:SetVertexColor(1, 1, 1, 0.16) end

  -- a thin wash of the quality colour up from the bottom edge
  t.wash = t:CreateTexture(nil, "ARTWORK", nil, 3)
  t.wash:SetPoint("BOTTOMLEFT", 1, 1); t.wash:SetPoint("BOTTOMRIGHT", -1, 1)
  t.wash:SetHeight(math.max(8, math.floor(size * 0.26)))
  t.wash:Hide()
  t.pill = t:CreateTexture(nil, "ARTWORK", nil, 2)       -- behind the corner label
  t.pill:SetColorTexture(0, 0, 0, 0.6)
  t.pill:Hide()
  -- a thin meter along the bottom edge (durability)
  t.meterBg = t:CreateTexture(nil, "ARTWORK", nil, 4)
  t.meterBg:SetPoint("BOTTOMLEFT", 1, 1); t.meterBg:SetPoint("BOTTOMRIGHT", -1, 1); t.meterBg:SetHeight(3)
  t.meterBg:SetColorTexture(0, 0, 0, 0.7)
  t.meter = t:CreateTexture(nil, "ARTWORK", nil, 5)
  t.meter:SetPoint("BOTTOMLEFT", 1, 1); t.meter:SetHeight(3)
  t.meterBg:Hide(); t.meter:Hide()

  t.border = NewFrame("Frame", nil, t, "BackdropTemplate")
  t.border:SetAllPoints()
  t.border:SetFrameLevel(t:GetFrameLevel() + 3)
  t.border:EnableMouse(false)
  UI:EdgeFile(t.border, 1)
  t.border:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
  t.count = UI:StyleCount(t.border:CreateFontString(nil, "OVERLAY", "BagglerFontCount"), t.border)
  t.label = t.border:CreateFontString(nil, "OVERLAY", "BagglerFontTiny")
  t.label:SetPoint("TOPLEFT", 3, -3)
  t.pill:SetPoint("TOPLEFT", t.label, "TOPLEFT", -2, 1)
  t.pill:SetPoint("BOTTOMRIGHT", t.label, "BOTTOMRIGHT", 2, -1)

  -- pressing darkens the tile for as long as the button is down
  t.press = t.border:CreateTexture(nil, "OVERLAY", nil, 2)
  t.press:SetAllPoints()
  t.press:SetColorTexture(0, 0, 0, 0.28)
  t.press:Hide()
  t:HookScript("OnMouseDown", function(self) self.press:Show() end)
  t:HookScript("OnMouseUp", function(self) self.press:Hide() end)
  t:HookScript("OnLeave", function(self) self.press:Hide() end)

  t.sel = NewFrame("Frame", nil, t, "BackdropTemplate")
  t.sel:SetAllPoints()
  t.sel:SetFrameLevel(t.border:GetFrameLevel() + 2)
  t.sel:EnableMouse(false)
  UI:EdgeFile(t.sel, 2)
  t.sel:Hide()

  function t:Paint(spec)
    local hl = t:GetHighlightTexture()
    t.icon:SetTexture(spec.icon)
    t.icon:SetDesaturated(spec.dim and true or false)
    local shade = spec.dim and 0.7 or 1
    t.icon:SetVertexColor(shade, shade, shade)
    t.count:SetText((spec.count or 1) > 1 and UI:Count(spec.count) or "")
    t.label:SetText(spec.label or "")
    t.pill:SetShown(spec.label ~= nil)
    local q = spec.quality or 1
    if q >= 2 and CB.db.showBorders ~= false then
      local r, g, b = UI:QualityRGB(q)
      t.border:SetBackdropBorderColor(r, g, b, 0.95)
      if q >= 3 then
        UI:VGradient(t.wash, { r, g, b, 0 }, { r, g, b, 0.42 })
        t.wash:Show()
      else
        t.wash:Hide()
      end
      if hl then hl:SetVertexColor(r, g, b, 0.24) end
    else
      t.border:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
      t.wash:Hide()
      if hl then hl:SetVertexColor(1, 1, 1, 0.16) end
    end
    if spec.meter then
      -- green when whole, through amber to red as it wears out
      local m = math.max(0, math.min(1, spec.meter))
      local r, g = m < 0.5 and 1 or (1 - m) * 2, m > 0.5 and 1 or m * 2
      t.meter:SetWidth(math.max(1, (t:GetWidth() - 2) * m))
      t.meter:SetColorTexture(r, g * 0.85, 0.15, 1)
      t.meterBg:Show(); t.meter:Show()
    else
      t.meterBg:Hide(); t.meter:Hide()
    end
  end

  --- Selection ring in the accent colour (or the item's quality colour when that setting is on).
  function t:SetSelected(on, quality)
    if not on then t.sel:Hide(); return end
    local r, g, b = CB:Accent()
    if CB.db.qualityFocus and (quality or 1) >= 2 then r, g, b = UI:QualityRGB(quality) end
    t.sel:SetBackdropBorderColor(r, g, b, 1)
    t.sel:Show()
  end
  return t
end

--- Gives a BackdropTemplate frame a transparent fill and a one-pixel snapped edge (the colour is set by the caller).
function UI:EdgeOnly(frame)
  UI:EdgeFile(frame, 1)
  frame:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
end

---------------------------------------------------------------------------
-- List row
---------------------------------------------------------------------------
--- A full-width row: icon on the left, a name over a smaller sub line, and a right-hand value. Used for gossip
--- options, quests, flight destinations and the like. Paint it with row:Paint({ icon, name, sub, right, color, dim }).
--- States: hover lightens the row, a press darkens it, and the selected row gets an accent fill with a bar down its
--- left edge. `row:SetRowWidth(w)` re-fits it when the window is resized.
function UI:ListRow(parent, width, height)
  local r = NewFrame("Button", nil, parent)
  r:SetSize(width, height)
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r.bg = r:CreateTexture(nil, "BACKGROUND", nil, -6)
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(UI.tile[1], UI.tile[2], UI.tile[3], 1)
  r.hover = r:CreateTexture(nil, "BACKGROUND", nil, -3)
  r.hover:SetAllPoints()
  r.hover:SetColorTexture(1, 1, 1, 0.05)
  r.hover:Hide()
  r.sel = r:CreateTexture(nil, "ARTWORK", nil, -2)
  r.sel:SetAllPoints()
  r.sel:Hide()
  r.accent = r:CreateTexture(nil, "ARTWORK", nil, -1)         -- the bar down the left edge of the selected row
  r.accent:SetPoint("TOPLEFT"); r.accent:SetPoint("BOTTOMLEFT")
  UI:Line(r.accent, "w", 2)
  r.accent:Hide()
  r.press = r:CreateTexture(nil, "OVERLAY", nil, 2)
  r.press:SetAllPoints()
  r.press:SetColorTexture(0, 0, 0, 0.28)
  r.press:Hide()
  r.icon = r:CreateTexture(nil, "OVERLAY")
  r.icon:SetSize(height - 8, height - 8)
  r.icon:SetPoint("LEFT", 6, 0)
  r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  r.right = r:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
  r.right:SetPoint("RIGHT", -8, 0)
  r.right:SetJustifyH("RIGHT")
  r.name = r:CreateFontString(nil, "OVERLAY", "BagglerFont")
  r.name:SetJustifyH("LEFT")
  r.name:SetWordWrap(false)
  r.sub = r:CreateFontString(nil, "OVERLAY", "BagglerFontTiny")
  r.sub:SetJustifyH("LEFT")
  r.sub:SetWordWrap(false)

  r:HookScript("OnEnter", function(self) if not self.selected then self.hover:Show() end end)
  r:HookScript("OnLeave", function(self) self.hover:Hide(); self.press:Hide() end)
  r:HookScript("OnMouseDown", function(self) self.press:Show() end)
  r:HookScript("OnMouseUp", function(self) self.press:Hide() end)

  --- Keeps the two text lines clear of the icon and of the right-hand value.
  local function fit()
    local left = r.icon:IsShown() and (height - 8 + 14) or 12
    local room = r:GetWidth() - left - 14 - (r.right:GetStringWidth() or 0)
    r.name:SetWidth(math.max(40, room))
    r.sub:SetWidth(math.max(40, room))
  end

  function r:SetRowWidth(w)
    r:SetWidth(w)
    fit()
  end

  function r:Paint(spec)
    r.icon:SetTexture(spec.icon)
    r.icon:SetShown(spec.icon ~= nil)
    r.icon:SetDesaturated(spec.dim and true or false)
    r.right:SetText(spec.right or "")
    local c = spec.color or CB.COLOR.text
    r.name:SetText(spec.name or "")
    r.name:SetTextColor(c[1], c[2], c[3])
    local hasSub = (spec.sub or "") ~= ""
    r.sub:SetText(spec.sub or "")
    r.sub:SetShown(hasSub)
    local x = spec.icon and (6 + height - 8 + 8) or 12
    r.name:ClearAllPoints()
    r.name:SetPoint("LEFT", r, "LEFT", x, hasSub and 7 or 0)
    r.sub:ClearAllPoints()
    r.sub:SetPoint("LEFT", r, "LEFT", x, -8)
    fit()
  end

  function r:SetSelected(on)
    r.selected = on and true or false
    if not on then r.sel:Hide(); r.accent:Hide(); return end
    local ar, ag, ab = CB:Accent()
    r.sel:SetColorTexture(ar, ag, ab, 0.2)
    r.accent:SetColorTexture(ar, ag, ab, 1)
    r.sel:Show(); r.accent:Show()
    r.hover:Hide()
  end
  return r
end

---------------------------------------------------------------------------
-- Buttons the controller can walk
---------------------------------------------------------------------------
--- A row of window buttons (Decline / Accept, Fly / Close ...) for the D-pad. `getButtons()` must list them in the order
--- they appear on screen, left to right, so that Left and Right go the way they point. Left and Right move the highlight, A
--- presses the highlighted one. `getButtons()` returns the buttons in order; hidden ones are skipped. The highlighted
--- button gets the accent border, the same focus look as the other Baggler windows.
---   z:Enter(prefer?) -> false when there is nothing to focus     z:Clear()     z:Move(-1 | 1)     z:Press()
function UI:ButtonRow(getButtons)
  local z = { index = 1 }

  local function shown()
    local out = {}
    for _, b in ipairs(getButtons()) do if b:IsShown() then out[#out + 1] = b end end
    return out
  end

  local function paint()
    local list = shown()
    for _, b in ipairs(getButtons()) do UI:SetFocused(b, false) end
    if z.active and list[z.index] then UI:SetFocused(list[z.index], true) end
  end

  --- Starts the highlight, on `prefer` when it is given and shown (the main button), else where it was.
  function z:Enter(prefer)
    local list = shown()
    if #list == 0 then return false end
    z.active = true
    for i, b in ipairs(list) do if b == prefer then z.index = i end end
    z.index = math.min(math.max(z.index, 1), #list)
    paint()
    return true
  end

  function z:Clear()
    z.active = false
    paint()
  end

  function z:Move(delta)
    local list = shown()
    if #list == 0 then return end
    z.index = math.min(math.max(z.index + delta, 1), #list)
    paint()
  end

  --- The highlighted button, or nil.
  function z:Current() return shown()[z.index] end

  --- Presses the highlighted button (a disabled one does nothing). Returns true when something was pressed.
  function z:Press()
    local b = z:Current()
    if not b then return false end
    if b.IsEnabled and b:IsEnabled() == false then return false end
    b:Click()
    return true
  end
  return z
end
