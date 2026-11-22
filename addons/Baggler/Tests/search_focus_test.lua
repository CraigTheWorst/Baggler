-- Run from repository root: timeout 90 luajit addons/Baggler/Tests/search_focus_test.lua
-- Regression (live report): bags open, clicking the search box with the MOUSE does not focus it / cannot type, while the
-- controller (select Search, press A -> View:FocusSearch -> EditBox:SetFocus) works.
-- The harness stubs have no geometry, so this test adds a small client model on top of the real TOC:
--   * frame parent / strata / level (child = parent + 1, as in the game) / anchors / sizes / mouse-enabled
--   * hit test: highest strata, then highest level, then LATEST created wins (the game's draw order for equal levels)
--   * a mouse click = the topmost mouse-enabled frame under the cursor gets the press; only an EditBox that receives it
--     takes keyboard focus (the client's own behaviour). Controller path = search:SetFocus() directly.
-- Offline only: this is not proof of in-game behaviour; the live acceptance steps are in the final report.
dofile('tests/harness/ca_stubs.lua')
local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local seq, kbFocus = 0, nil
local originalCreate = CreateFrame
local function parentOf(f) return f.__parent end
CreateFrame = function(kind, name, parent, template)
  local f = originalCreate(kind, name, parent, template)
  seq = seq + 1
  f.__seq, f.__kind, f.__points = seq, kind, {}
  f.__mouse = (kind == 'EditBox' or kind == 'Button' or kind == 'ItemButton' or kind == 'Slider') and true or false
  f.__level = (parent and parent.__level or 0) + 1
  f.__strata = nil
  function f:SetFrameLevel(l) self.__level = l end
  function f:GetFrameLevel() return self.__level end
  function f:SetFrameStrata(s) self.__strata = s end
  function f:GetFrameStrata() return self.__strata or (parent and parent.GetFrameStrata and parent:GetFrameStrata()) or 'MEDIUM' end
  function f:EnableMouse(on) self.__mouse = on and true or false end
  function f:IsMouseEnabled() return self.__mouse end
  function f:SetPoint(p, rel, rp, x, y)
    if type(rel) == 'number' or rel == nil then rel, rp, x, y = parent, p, rel, rp end   -- (point, x, y) form
    if type(rp) == 'number' then rp, x, y = p, rp, x end                                   -- (point, rel, x, y) form
    self.__points[#self.__points + 1] = { p, rel or parent, rp or p, x or 0, y or 0 }
  end
  function f:ClearAllPoints() self.__points = {} end
  function f:SetAllPoints(rel) self.__points = { { 'TOPLEFT', rel or parent, 'TOPLEFT', 0, 0 }, { 'BOTTOMRIGHT', rel or parent, 'BOTTOMRIGHT', 0, 0 } } end
  if kind == 'EditBox' then
    f.__focus = false
    function f:SetAutoFocus() end
    function f:SetFocus()
      if kbFocus and kbFocus ~= self then kbFocus:ClearFocus() end
      kbFocus, self.__focus = self, true
      if self.__scripts.OnEditFocusGained then self.__scripts.OnEditFocusGained(self) end
    end
    function f:ClearFocus()
      if not self.__focus then return end
      self.__focus = false; if kbFocus == self then kbFocus = nil end
      if self.__scripts.OnEditFocusLost then self.__scripts.OnEditFocusLost(self) end
    end
    function f:HasFocus() return self.__focus end
    function f:SetText(t) self.__text = t; if self.__scripts.OnTextChanged then self.__scripts.OnTextChanged(self, false) end end
  end
  local createText = f.CreateFontString
  f.CreateFontString = function(self, ...)
    local t = createText(self, ...)
    t.__points = {}; t.__level = self.__level
    function t:SetPoint(p, rel, rp, x, y)
      if type(rel) == 'number' or rel == nil then rel, rp, x, y = self.__parent, p, rel, rp end
      if type(rp) == 'number' then rp, x, y = p, rp, x end
      self.__points[#self.__points + 1] = { p, rel or self.__parent, rp or p, x or 0, y or 0 }
    end
    function t:ClearAllPoints() self.__points = {} end
    function t:SetFontObject() end
    function t:GetStringWidth() return #(tostring(self:GetText() or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '')) * 7 end
    return t
  end
  return f
end
function GetCurrentKeyBoardFocus() return kbFocus end
function UnitClass() return 'Warrior', 'WARRIOR' end
function UnitName() return 'Tester' end

-- anchor solver (x right, y up; UIParent is 1920x1080 at 0,0). Width of a frame with two horizontal anchors = their span.
local function size(f) return f.__w or 100, f.__h or 100 end
local rect
local function anchorXY(f, pt, rel, rpt, ox, oy)
  local rl, rb, rw, rh = rect(rel)
  local ax = ({ LEFT = 0, TOPLEFT = 0, BOTTOMLEFT = 0, CENTER = 0.5, TOP = 0.5, BOTTOM = 0.5, RIGHT = 1, TOPRIGHT = 1, BOTTOMRIGHT = 1 })[rpt]
  local ay = ({ BOTTOM = 0, BOTTOMLEFT = 0, BOTTOMRIGHT = 0, CENTER = 0.5, LEFT = 0.5, RIGHT = 0.5, TOP = 1, TOPLEFT = 1, TOPRIGHT = 1 })[rpt]
  return rl + rw * ax + ox, rb + rh * ay + oy
end
function rect(f)
  if f == UIParent or not f then return 0, 0, 1920, 1080 end
  local w, h = size(f)
  if f.__kind == 'FontString' and not f.__w then w = f.GetStringWidth and f:GetStringWidth() or 60; h = 14 end
  local pts = f.__points
  if #pts == 0 then return 0, 0, w, h end
  local xs, ys = {}, {}
  local fx = ({ LEFT = 0, TOPLEFT = 0, BOTTOMLEFT = 0, CENTER = 0.5, TOP = 0.5, BOTTOM = 0.5, RIGHT = 1, TOPRIGHT = 1, BOTTOMRIGHT = 1 })
  local fy = ({ BOTTOM = 0, BOTTOMLEFT = 0, BOTTOMRIGHT = 0, CENTER = 0.5, LEFT = 0.5, RIGHT = 0.5, TOP = 1, TOPLEFT = 1, TOPRIGHT = 1 })
  local left, right, bottom, top
  for _, p in ipairs(pts) do
    local x, y = anchorXY(f, p[1], p[2], p[3], p[4], p[5])
    local px, py = fx[p[1]], fy[p[1]]
    if p[1] == 'LEFT' or p[1] == 'TOPLEFT' or p[1] == 'BOTTOMLEFT' then left = x end
    if p[1] == 'RIGHT' or p[1] == 'TOPRIGHT' or p[1] == 'BOTTOMRIGHT' then right = x end
    if p[1] == 'TOP' or p[1] == 'TOPLEFT' or p[1] == 'TOPRIGHT' then top = y end
    if p[1] == 'BOTTOM' or p[1] == 'BOTTOMLEFT' or p[1] == 'BOTTOMRIGHT' then bottom = y end
    if px == 0.5 then xs.c = x end
    if py == 0.5 then ys.c = y end
  end
  if left and right then w = right - left elseif left then right = left + w elseif right then left = right - w
  elseif xs.c then left = xs.c - w / 2 else left = 0 end
  if bottom and top then h = top - bottom elseif bottom then top = bottom + h elseif top then bottom = top - h
  elseif ys.c then bottom = ys.c - h / 2 else bottom = 0 end
  return left, bottom, w, h
end
-- the frame's window position: the real code anchors it through ApplyPosition (CENTER of UIParent by default)

local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, n, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
CB.db.pad.mode = 'on'
local W, UI = CB.Window, CB.UI

local function visible(f) return f:IsVisible() end
-- Equal strata AND level: the client's order is not something an add-on may rely on, so every check runs under both
-- tie-breaks (later-created on top / earlier-created on top).
local tieEarlierWins = false
local function rank(f)
  local s = STRATA[f:GetFrameStrata()] or 3
  return s, f.__level, f.__seq
end
-- The frame that receives a mouse press at (x, y): highest strata, then level, then latest created.
local function hit(x, y, earlier)
  if earlier == nil then earlier = tieEarlierWins end
  local best
  for _, f in ipairs(frames) do
    if f.__mouse and f.__kind ~= 'FontString' and f.__kind ~= 'Texture' and visible(f) then
      local l, b, w, h = rect(f)
      if x >= l and x <= l + w and y >= b and y <= b + h then
        local s1, l1, q1 = rank(f)
        if not best then best = f else
          local s2, l2, q2 = rank(best)
          local later = earlier and q1 < q2 or (not earlier and q1 > q2)
          if s1 > s2 or (s1 == s2 and (l1 > l2 or (l1 == l2 and later))) then best = f end
        end
      end
    end
  end
  return best
end
local function describe(f)
  local out, n = {}, f
  while n and #out < 4 do out[#out + 1] = (n.__name or n.__kind) .. '[L' .. tostring(n.__level) .. ']'; n = n.__parent end
  return table.concat(out, ' < ')
end
-- A real mouse click: only the topmost frame hears it; an EditBox that hears it takes the keyboard.
local function click(x, y, earlier)
  local f = hit(x, y, earlier)
  if f and f.__kind == 'EditBox' then f:SetFocus() end
  if f and f.__scripts.OnMouseDown then f.__scripts.OnMouseDown(f, 'LeftButton') end
  return f
end

local fails = 0
local function check(ok, msg) if not ok then fails = fails + 1; print('FAIL ' .. msg) end end

local function windowAt(kind, innerW)
  local win = kind == 'bank' and CB.Bank and CB.Bank.window or W
  return win
end

-- 1. The controller path works (this is the control: SetFocus directly is not what the mouse does)
W:Open(); FLUSH()
W.innerW = 340; W:ApplySize()
local f = W.frame
f:ClearAllPoints(); f:SetPoint('CENTER', UIParent, 'CENTER', 0, 0)
W:FocusSearch()
check(f.search:HasFocus(), 'controller path: View:FocusSearch must focus the search box')
check(W.searching == true and CB.Pad.yield, 'controller path: Pad yields to the typing')
f.search:ClearFocus()
check(not CB.Pad.yield, 'losing focus releases the controller yield')

-- 2. Mouse: at every width/mode the centre of the search box must hit the search box itself, and the click must focus it
local widths = { 300, 336, 400, 520, 640, 760 }
local function overlaps(a, b)
  local al, ab, aw, ah = rect(a); local bl, bb, bw, bh = rect(b)
  return al < bl + bw and al + aw > bl and ab < bb + bh and ab + ah > bb
end
local function exercise(win, label)
  win:Open(); FLUSH()
  local wf = win.frame
  wf:ClearAllPoints(); wf:SetPoint('CENTER', UIParent, 'CENTER', 0, 0)
  for _, innerW in ipairs(widths) do
    CB.db.locked = false
    win.innerW = innerW; win:ApplySize()
    local l, b, w, h = rect(wf.search)
    local cx, cy = l + w / 2, b + h / 2
    for _, frac in ipairs({ 0.05, 0.5, 0.95 }) do
      for _, earlier in ipairs({ false, true }) do
        local t = hit(l + w * frac, cy, earlier)
        check(t == wf.search, ('%s innerW=%d tie=%s: point %.2f across the search box is covered by %s'):format(label, innerW, earlier and 'earlier' or 'later', frac, t and describe(t) or 'nothing'))
      end
    end
    for _, earlier in ipairs({ false, true }) do
      local got = click(cx, cy, earlier)
      check(wf.search:HasFocus(), ('%s innerW=%d tie=%s: a mouse click must give the search box the keyboard (press went to %s)'):format(label, innerW, earlier and 'earlier' or 'later', got and describe(got) or 'nothing'))
      wf.search:ClearFocus()
    end
    -- header controls: every visible title-bar button stays clear of the search box
    for _, other in ipairs(frames) do
      if other ~= wf.search and other.__kind == 'Button' and other:IsVisible() and other.__parent and other.__parent.__parent == wf
         and other.__parent.__points and #other.__parent.__points == 2 then
        check(not overlaps(other, wf.search), ('%s innerW=%d: header button %s overlaps the search box'):format(label, innerW, describe(other)))
      end
    end
    -- the title text box ends before the search box starts
    local tl, tb, tw, th = rect(wf.title)
    check(tl + tw <= l, ('%s innerW=%d: title (right edge %.0f) runs under the search box (left edge %.0f)'):format(label, innerW, tl + tw, l))
    if arg and arg[1] == 'geom' then print(('%s innerW=%d frameW=%d title=%.0f..%.0f search=%.0f..%.0f'):format(label, innerW, wf:GetWidth(), tl, tl + tw, l, l + w)) end
  end
  win:Close()
end
exercise(W, 'bags')
if CB.Bank and CB.Bank.window then exercise(CB.Bank.window, 'bank') else check(false, 'bank window exists') end
W:Open(); FLUSH(); f = W.frame

-- 4. Typing filters, Escape clears first, then closes
W:Open(); FLUSH(); f = W.frame
f:ClearAllPoints(); f:SetPoint('CENTER', UIParent, 'CENTER', 0, 0)
W.innerW = 340; W:ApplySize()
local sl, sb, sw, sh = rect(f.search)
-- mouse -> keyboard handover: the click focuses, the controller yields to the typing, then typing filters
local got = click(sl + sw / 2, sb + sh / 2, true)
check(got == f.search and f.search:HasFocus(), 'mouse click focuses the search box')
check(W.searching == true and CB.Pad.yield, 'mouse focus: the controller yields to the typing (same as the A path)')
f.search:SetText('pot')
check(W.query == 'pot', 'typing filters: W.query follows the text')
-- Escape priorities, through the window's real key handler:
--   1. in the box: the box's own Escape clears the text and leaves it (the window stays)
f.search.__scripts.OnEscapePressed(f.search)
check((f.search:GetText() or '') == '' and not f.search:HasFocus() and W.query == '', 'Escape in the box clears the text and leaves the box')
check(f:IsShown(), 'Escape in the box must not close the window')
check(not CB.Pad.yield and not W.searching, 'leaving the box hands the controller back')
--   2. a standing search (Enter left the box, text kept): Escape clears it first, like the controller\'s B
f.search:SetFocus(); f.search:SetText('pot'); f.search.__scripts.OnEnterPressed(f.search)
check(not f.search:HasFocus() and W.query == 'pot', 'Enter leaves the box and keeps the filter')
-- (bags alone: no merchant/bank/mail/... frame is up, so Escape is the window's; with one up it is the game's - "pass")
for _, visit in ipairs(CB.NativeWindows.visits) do local g = rawget(_G, visit[1]); if g then g:Hide() end end
for _, n in ipairs({ 'MailFrame', 'GuildBankFrame', 'BankFrame', 'LootFrame' }) do local g = rawget(_G, n); if g then g:Hide() end end
f.__scripts.OnKeyDown(f, 'ESCAPE'); FLUSH()
check(W.query == '' and (f.search:GetText() or '') == '' and f:IsShown(), 'Escape with a standing search clears it and keeps the window open')
--   3. nothing left to clear: Escape closes
f.__scripts.OnKeyDown(f, 'ESCAPE'); FLUSH()
check(not f:IsShown(), 'Escape with no search closes the window')
-- the clear cross is above the search box and works with the mouse
W:Open(); FLUSH(); f:ClearAllPoints(); f:SetPoint('CENTER', UIParent, 'CENTER', 0, 0); W.innerW = 340; W:ApplySize()
f.search:SetText('abc'); FLUSH()
local cl, cb, cw, ch = rect(f.search.clearButton)
local cross = hit(cl + cw / 2, cb + ch / 2, true)
check(cross == f.search.clearButton, 'the clear cross is the topmost thing over its own spot (got ' .. (cross and describe(cross) or 'nothing') .. ')')

print(fails == 0 and 'ALL PASS search focus (offline only)' or ('FAILED: ' .. fails))
os.exit(fails == 0 and 0 or 1)
