-- Baggler menu: a small popup list that works with mouse AND controller.
--
-- Entries: { text=, func=, sub=function()->entries, checked=, disabled=, color={r,g,b}, hint=, tip= }
--   separator = true    a thin line between groups (not selectable)
--   header    = "Name"  a small group heading (not selectable)
--   hint                muted text on the right of the row (a price, a key)
--   tip                 a tooltip shown while the row is highlighted
--   secureUse = { bag, slot }  the row uses that item through a secure press (controller A and mouse click), never
--                       through add-on code, which the game blocks for some items (a quest item, a grimoire)
-- A submenu opens in place of its parent; B steps back to the parent, the menu button or a click outside closes
-- everything. A menu taller than 70% of the screen scrolls (mouse wheel, or the d-pad past its edge).
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local Menu = {}
CB.Menu = Menu
local UI = CB.UI

local ROW_H, SEP_H, HEAD_H = 24, 9, 20
local TOP_PAD, BOTTOM_PAD, SIDE = 28, 6, 4
local MIN_W, MAX_W = 150, 420
local frame, catcher
local useOverlay            -- the secure button laid over an item-use row (below)

Menu.stack = {}          -- parents of the open submenu: { title=, entries=, anchor=, index= }
Menu.top = 1             -- first entry shown (a long menu scrolls)

local function selectable(e) return e ~= nil and not e.separator and not e.header end

local function heightOf(e)
  if e.separator then return SEP_H end
  if e.header then return HEAD_H end
  return ROW_H
end

-- Builds the menu frame once, together with the full-screen click catcher behind it.
local function build()
  if frame then return end
  UI:MakeFonts()
  catcher = NewFrame("Button", "BagglerMenuCatcher", UIParent)
  catcher:SetAllPoints(UIParent)
  catcher:SetFrameStrata("FULLSCREEN")
  catcher:RegisterForClicks("AnyDown")
  catcher:SetScript("OnClick", function() Menu:Close() end)
  catcher:Hide()
  -- Safety: this invisible full-screen button must never outlive the menu, or it would swallow
  -- every mouse click (action bars included).
  catcher:SetScript("OnUpdate", function(self)
    if not frame or not frame:IsShown() then self:Hide() end
  end)

  frame = NewFrame("Frame", "BagglerMenu", UIParent, "BackdropTemplate")
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:EnableMouseWheel(true)
  UI:Backdrop(frame, UI.bg, UI.border, 0.98, 0)
  UI:Shadow(frame)
  frame.title = frame:CreateFontString(nil, "OVERLAY", "BagglerFontHeader")
  frame.back = UI:Icon(frame, "back", 8)          -- beside the title inside a submenu: B goes back
  frame.back:SetColor(unpack(CB.COLOR.muted))
  frame.back:Hide()
  frame.moreUp = UI:Icon(frame, "up", 8)          -- there is more above / below: scroll
  frame.moreUp:SetColor(unpack(CB.COLOR.muted))
  frame.moreUp:SetPoint("TOPRIGHT", -10, -10)
  frame.moreUp:Hide()
  frame.moreDown = UI:Icon(frame, "down", 8)
  frame.moreDown:SetColor(unpack(CB.COLOR.muted))
  frame.moreDown:SetPoint("BOTTOMRIGHT", -10, 1)
  frame.moreDown:Hide()
  frame.rows = {}
  frame:Hide()
  frame:SetScript("OnHide", function()
    catcher:Hide()
    UI:HideTip()
    if CB.Card then CB.Card:HideMouse() end
    if useOverlay and not InCombatLockdown() then useOverlay:Hide() end
    CB.Pad:Pop(Menu.ctx)
  end)
  frame:SetScript("OnMouseWheel", function(_, delta) Menu:Scroll(-delta) end)
end


---------------------------------------------------------------------------
-- Secure item use (a row with `secureUse`)
---------------------------------------------------------------------------
local function overlayButton()
  if useOverlay then return useOverlay end
  local ok, b = pcall(CreateFrame, "Button", "BagglerMenuUse", UIParent, "SecureActionButtonTemplate")
  if not ok or not b then return nil end
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type", "macro")
  b:SetFrameStrata("FULLSCREEN_DIALOG")
  b:SetFrameLevel(50)
  -- the overlay hides the row beneath it from the mouse, so hover is handed on
  b:SetScript("OnEnter", function(self) local row = self.cbRow; local f = row and row:GetScript("OnEnter"); if f then f(row) end end)
  b:HookScript("PostClick", function() Menu:Close() end)      -- (observing only: the use itself is the game's)
  b:Hide()
  useOverlay = b
  return b
end

--- Lays the secure button over the row that uses an item, or hides it. Placed by screen position and not anchored to
--- the menu, like every secure overlay (a secure frame tied to a window makes the window protected). Out of combat only.
function Menu:ArmUse()
  if InCombatLockdown() then return end
  local b = overlayButton()
  if not b then return end
  local row, rec
  if frame and frame:IsShown() and Menu.entries then
    for i, e in ipairs(Menu.entries) do
      local r = frame.rows[i]
      if e.secureUse and r and r:IsShown() then row, rec = r, e.secureUse; break end
    end
  end
  if not row then b:Hide(); return end
  b.cbRow = row
  b:SetAttribute("macrotext", ("/use %d %d"):format(rec.bag, rec.slot))
  UI:PlaceOver(b, row)
  b:Show()
  -- the controller's A goes to the secure use button; the menu closes when it has been pressed
  local pb = CB.Pad and CB.Pad.UseButton and CB.Pad:UseButton()
  if pb and not pb.cbMenuClose then
    pb.cbMenuClose = true
    pb:HookScript("PostClick", function() if frame and frame:IsShown() then Menu:Close() end end)
  end
end

---------------------------------------------------------------------------
-- Controller
---------------------------------------------------------------------------
--- The next selectable entry from `i` in direction `dir` (+1 / -1), wrapping round.
local function step(i, dir)
  local n = #Menu.entries
  for _ = 1, n do
    i = i + dir
    if i > n then i = 1 elseif i < 1 then i = n end
    if selectable(Menu.entries[i]) then return i end
  end
  return Menu.index
end

Menu.ctx = {
  alive = function() return frame ~= nil and frame:IsShown() end,
  -- the highlighted row may be an item use: A is then bound to the secure use button (see Pad:SyncDirectUse)
  directUse = function()
    local e = frame and frame:IsShown() and Menu.entries and Menu.entries[Menu.index]
    return e and e.secureUse or nil
  end,
  OnPad = function(_, action)
    if not frame or not frame:IsShown() then return end
    if action == "up" then Menu:Select(step(Menu.index, -1))
    elseif action == "down" then Menu:Select(step(Menu.index, 1))
    elseif action == "use" then Menu:Activate(Menu.index)
    elseif action == "close" then Menu:Back()
    elseif action == "menu" then Menu:Close()
    end
  end,
}

---------------------------------------------------------------------------
-- Layout: rows are placed from Menu.top, as many as fit on the screen
---------------------------------------------------------------------------
local function maxBodyHeight()
  local scale = (CB.db and CB.db.scale) or 1
  return math.floor(UIParent:GetHeight() * 0.7 / scale) - TOP_PAD - BOTTOM_PAD
end

--- Places the rows from Menu.top and sizes the frame to them.
function Menu:Layout()
  local entries, y, last = Menu.entries, 0, Menu.top - 1
  local limit = maxBodyHeight()
  for i = 1, #frame.rows do frame.rows[i]:Hide() end
  for i = Menu.top, #entries do
    local h = heightOf(entries[i])
    if y + h > limit and i > Menu.top then break end
    local row = frame.rows[i]
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", SIDE, -(TOP_PAD + y))
    row:SetPoint("TOPRIGHT", -SIDE, -(TOP_PAD + y))
    row:SetHeight(h)
    row:Show()
    y = y + h
    last = i
  end
  Menu.last = last
  frame:SetHeight(TOP_PAD + y + BOTTOM_PAD)
  frame.moreUp:SetShown(Menu.top > 1)
  frame.moreDown:SetShown(last < #entries)
  C_Timer.After(0, function() Menu:ArmUse() end)
  for idx, row in ipairs(frame.rows) do
    row.sel:SetShown(idx == Menu.index and row:IsShown())
  end
end

--- Scrolls a long menu by `rows` entries (mouse wheel).
function Menu:Scroll(rows)
  if not frame or not frame:IsShown() or not Menu.entries then return end
  local n = #Menu.entries
  Menu.top = math.max(1, math.min(Menu.top + rows, n))
  Menu:Layout()
end

-- Highlights entry i and scrolls the list so it stays visible.
function Menu:Select(i)
  Menu.index = i
  -- keep the highlighted row on screen
  if i < Menu.top then Menu.top = i; Menu:Layout() end
  while Menu.last and i > Menu.last and Menu.top < i do
    Menu.top = Menu.top + 1
    Menu:Layout()
  end
  for idx, row in ipairs(frame.rows) do
    row.sel:SetShown(idx == i and row:IsShown())
  end
  if CB.Pad and CB.Pad.SyncDirectUse then CB.Pad:SyncDirectUse() end      -- A uses the item through a secure press on a `secureUse` row
  local e = Menu.entries and Menu.entries[i]
  if e and e.tip and frame.rows[i] then
    UI.Tip:SetOwner(frame, Menu:TipAnchor())
    UI.Tip:SetText(e.tip, 1, 1, 1, 1, true)
    UI.Tip:Show()
  else
    UI:HideTip()
  end
end

---------------------------------------------------------------------------
-- Placement. All maths is in screen pixels so it is right at any UI scale; Menu.Position is pure (tested).
---------------------------------------------------------------------------
local GAP, EDGE = 4, 6

--- Where a w x h menu goes next to the rect `a` ({ left, right, top, bottom }) on an sw x sh screen: returns the left
--- edge and the top edge. Tries beside the anchor, then below, above, left, and for an anchor that is itself a big
--- window (a window menu) inside its top-right corner. Never covers the anchor when there is room, never leaves the
--- screen: when nothing fits it is pulled in as far as needed.
function Menu.Position(a, w, h, sw, sh)
  if not a then return math.max(EDGE, (sw - w) / 2), math.min(sh - EDGE, (sh + h) / 2) end
  local function fits(x, top) return x >= EDGE and x + w <= sw - EDGE and top <= sh - EDGE and top - h >= EDGE end
  -- beside / above / below slide along the other axis to stay on screen (only the axis facing the anchor is fixed)
  local function slideY(t) return math.max(EDGE + h, math.min(t, sh - EDGE)) end
  local function slideX(x) return math.max(EDGE, math.min(x, sw - EDGE - w)) end
  local right, left = { a.right + GAP, slideY(a.top) }, { a.left - GAP - w, slideY(a.top) }
  local below, above = { slideX(a.left), a.bottom - GAP }, { slideX(a.left), a.top + GAP + h }
  local inside = { a.right - w - GAP, a.top - 28 }
  local big = (a.right - a.left) > 2 * w and (a.top - a.bottom) > 2 * h
  local order = big and { inside, right, left, below, above } or { right, below, left, above, inside }
  for _, c in ipairs(order) do
    if fits(c[1], c[2]) then return c[1], c[2] end
  end
  local x, top = order[1][1], order[1][2]
  x = math.max(EDGE, math.min(x, sw - EDGE - w))
  top = math.max(EDGE + h, math.min(top, sh - EDGE))
  return x, top
end

local function screenRect(f)
  local s = f:GetEffectiveScale()
  local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
  if not (l and r and t and b) then return nil end
  return { left = l * s, right = r * s, top = t * s, bottom = b * s }
end

local function screenSize()
  local s = UIParent:GetEffectiveScale()
  return UIParent:GetWidth() * s, UIParent:GetHeight() * s
end

--- Which side of the menu the tooltip goes on so it never lies over the rows: right, else left, else above / below.
function Menu:TipAnchor()
  local r = frame and screenRect(frame)
  if not r then return "ANCHOR_RIGHT" end
  local sw, sh = screenSize()
  local tw = (UI.TIP_WIDTH or 280) * (CB.db and CB.db.scale or 1) * UIParent:GetEffectiveScale()
  if r.right + 6 + tw <= sw then return "BESIDE_RIGHT" end
  if r.left - 6 - tw >= 0 then return "BESIDE_LEFT" end
  return (sh - r.top) >= r.bottom and "ANCHOR_BOTTOM" or "ANCHOR_TOP"
end

---------------------------------------------------------------------------
-- Opening, activating, going back
---------------------------------------------------------------------------
local function makeRow(i)
  local row = NewFrame("Button", nil, frame)
  row.sel = row:CreateTexture(nil, "BACKGROUND")
  row.sel:SetAllPoints()
  row.hl = row:CreateTexture(nil, "HIGHLIGHT")
  row.hl:SetAllPoints()
  row.hl:SetColorTexture(1, 1, 1, 0.06)
  row.text = row:CreateFontString(nil, "OVERLAY", "BagglerFont")
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  row.check = UI:Icon(row, "check", 10)
  row.check:SetPoint("LEFT", 9, 0)
  row.arrow = UI:Icon(row, "chevron", 8)
  row.arrow:SetPoint("RIGHT", -10, 0)
  row.arrow:SetColor(unpack(CB.COLOR.muted))
  row.hint = row:CreateFontString(nil, "OVERLAY", "BagglerFontMuted")
  row.hint:SetPoint("RIGHT", -12, 0)
  row.line = row:CreateTexture(nil, "ARTWORK")
  UI:Line(row.line, "h", 1)
  row.line:SetPoint("LEFT", 8, 0)
  row.line:SetPoint("RIGHT", -8, 0)
  row.line:SetColorTexture(1, 1, 1, 0.07)
  row:SetScript("OnClick", function(self) Menu:Activate(self.index) end)
  row:SetScript("OnEnter", function(self)
    if selectable(Menu.entries and Menu.entries[self.index]) then Menu:Select(self.index) end
  end)
  frame.rows[i] = row
  return row
end

-- Opens the menu: sizes it to the widest entry, lays out the rows and selects the first
-- selectable one.
local function show(anchor, title, entries)
  build()
  UI:HideTip()                                    -- the previous menu's explanation and any mouse card go before the next shows
  if CB.Card then CB.Card:HideMouse() end
  Menu.entries = entries
  Menu.anchor = anchor
  Menu.title = title
  Menu.top = 1
  local r, g, b = CB:Accent()
  local width = MIN_W
  local firstSelectable
  local function indentOf(e) return (e.checked or e.indent) and 18 or 0 end
  for i, e in ipairs(entries) do
    local row = frame.rows[i] or makeRow(i)
    row.index = i
    row.sel:SetColorTexture(r, g, b, 0.18)
    local isRow = selectable(e)
    row.line:SetShown(e.separator and true or false)
    row.check:SetShown(isRow and e.checked and true or false)
    row.check:SetColor(r, g, b)
    row.arrow:SetShown(isRow and e.sub and true or false)
    row.hint:SetText(isRow and e.hint or "")
    row.text:ClearAllPoints()
    if e.header then
      row.text:SetFontObject("BagglerFontHeader")
      row.text:SetPoint("LEFT", 12, -2)
      row.text:SetText((e.header or ""):upper())
    elseif e.separator then
      row.text:SetText("")
    else
      row.text:SetFontObject("BagglerFont")
      row.text:SetPoint("LEFT", 12 + indentOf(e), 0)
      row.text:SetText(e.text or "")
      if e.disabled then row.text:SetTextColor(unpack(CB.COLOR.disabled))
      elseif e.color then row.text:SetTextColor(e.color[1], e.color[2], e.color[3])
      else row.text:SetTextColor(unpack(CB.COLOR.text)) end
    end
    row:EnableMouse(isRow and true or false)
    if isRow and not firstSelectable then firstSelectable = i end
    local w = row.text:GetStringWidth() + 44 + indentOf(e) + (e.sub and 10 or 0)
      + ((isRow and e.hint) and (row.hint:GetStringWidth() + 16) or 0)
    width = math.max(width, math.min(w, MAX_W))
  end
  -- text that still does not fit (a long item name, a long entry) is cut by its row, never spilled outside
  for i, e in ipairs(entries) do
    local row = frame.rows[i]
    local room = width - 24 - indentOf(e) - (e.sub and 10 or 0) - ((selectable(e) and e.hint) and (row.hint:GetStringWidth() + 16) or 0)
    row.text:SetWidth(math.max(40, room))
  end
  local nested = #Menu.stack > 0
  frame.title:SetText((title or ""):upper())
  frame.title:ClearAllPoints()
  frame.title:SetPoint("TOPLEFT", nested and 24 or 12, -9)
  frame.back:ClearAllPoints()
  frame.back:SetPoint("TOPLEFT", 10, -9)
  frame.back:SetShown(nested)
  frame:SetWidth(width)
  frame:SetScale(CB.db.scale)
  UI:Resnap()
  Menu.index = firstSelectable or 1
  Menu:Layout()                                   -- the height is known from here on
  local fs = frame:GetEffectiveScale()
  local arect = anchor and anchor.GetCenter and screenRect(anchor) or nil
  local sw, sh = screenSize()
  local px, ptop = Menu.Position(arect, frame:GetWidth() * fs, frame:GetHeight() * fs, sw, sh)
  local function place(lift)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", px / fs, ptop / fs + lift)
  end
  place(0)
  catcher:Show()
  frame:SetAlpha(0)
  frame:Show()
  -- fades in; unless motion is reduced it also drops into place with a small overshoot
  UI:Animate(frame, "open", 0.16, function(_, raw)
    frame:SetAlpha(math.min(1, raw * 2.2))
    if UI:MotionOn() then place(8 * (1 - UI.Spring(raw))) end
  end, function() frame:SetAlpha(1); place(0) end)
  Menu:Select(Menu.index)
  CB.Pad:Push(Menu.ctx)
end

function Menu:Open(anchor, title, entries)
  Menu.stack = {}
  show(anchor, title, entries)
end

-- Runs entry i. A submenu replaces the list and remembers the previous one so Back returns.
function Menu:Activate(i)
  local e = Menu.entries and Menu.entries[i]
  if not e or e.disabled or not selectable(e) then return end
  if e.sub then
    local items = e.sub()
    local parent = { title = Menu.title, entries = Menu.entries, anchor = Menu.anchor, index = i }
    local stack = Menu.stack
    Menu:CloseFrame()
    stack[#stack + 1] = parent
    Menu.stack = stack
    show(parent.anchor, e.subTitle or e.text, items)
    return
  end
  Menu:Close()
  if e.func then e.func() end
end

--- B: out of a submenu back to its parent; at the top level it closes the menu.
function Menu:Back()
  local parent = table.remove(Menu.stack)
  if not parent then Menu:Close(); return end
  local stack = Menu.stack
  Menu:CloseFrame()
  Menu.stack = stack
  show(parent.anchor, parent.title, parent.entries)
  Menu:Select(parent.index)
end

--- Hides the frame but keeps the parents (used while switching between a menu and its submenu).
function Menu:CloseFrame()
  if frame and frame:IsShown() then frame:Hide() end
  if catcher then catcher:Hide() end
end

function Menu:Close()
  Menu.stack = {}
  Menu:CloseFrame()
end

-- Anything that changes who is driving the UI closes the menu (and so frees its click catcher).
for _, ev in ipairs({ "PLAYER_REGEN_DISABLED", "GAME_PAD_ACTIVE_CHANGED", "PLAYER_ENTERING_WORLD" }) do
  CB:RegisterEvent(ev, function() Menu:Close() end)
end

function Menu:IsOpen() return frame and frame:IsShown() end
