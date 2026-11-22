-- Real shipping TOC, recorded layout contracts; not an in-game font renderer.
dofile('tests/harness/ca_stubs.lua')
local create = CreateFrame
CreateFrame = function(...)
  local f = create(...)
  local function record(obj)
    obj.__points = {}
    function obj:SetPoint(point, ...) self.__points[point] = { ... } end
    function obj:ClearAllPoints() self.__points = {} end
    function obj:SetWordWrap(value) self.__wrap = value end
    function obj:SetNonSpaceWrap(value) self.__nonSpaceWrap = value end
    function obj:SetMaxLines(value) self.__maxLines = value end
    function obj:SetFontObject(value) self.__fontObject = value end
    function obj:SetFont(...) self.__fontOverride = { ... } end
  end
  record(f)
  local font = f.CreateFontString
  function f:CreateFontString(...)
    local fs = font(self, ...)
    record(fs)
    fs.__fontObject = select(3, ...)
    return fs
  end
  return f
end
function UnitClass() return 'Warrior', 'WARRIOR' end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, n, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
local O, Pad = CB.Options, CB.Pad
O:Open()
local function valueButton(row)
  for _, f in ipairs(frames) do
    if f:GetParent() == row and f.__type == 'Button' and f.text then return f end
  end
end
local function contained(row)
  local b = assert(valueButton(row), 'cycle needs a value button')
  local l, r = b.text.__points.TOPLEFT, b.text.__points.BOTTOMRIGHT
  assert(l and r, 'selected text needs opposing inset anchors, not an unbounded CENTER')
  assert(l[1] == 8 and l[2] == -2 and r[1] == -8 and r[2] == 2, 'selected text must stay padded inside button')
  assert(b.text.__wrap == false and b.text.__nonSpaceWrap == false and b.text.__maxLines == 1,
    'one-line selected values must truncate, never wrap beyond the row')
  assert(b.text.__fontObject == 'BagglerFont' and not b.text.__fontOverride, 'retain readable shared body font')
  local labelRight = row.label.__points.RIGHT
  assert(labelRight and labelRight[1] == b and labelRight[2] == 'LEFT' and labelRight[3] <= -8,
    'row label must reserve the value button and a gap')
  assert(b:GetWidth() + 8 + 8 < 484, 'value control must leave room for left label at minimum width')
  return b
end
-- Every cycle uses the same bounded text path, including non-mapping settings.
local cycles = 0
for name, def in pairs(O.specByTab) do
  for i, spec in ipairs(def.rows or {}) do
    if spec.type == 'cycle' or spec.type == 'padmap' then contained(O.pages[name].rows[i]); cycles = cycles + 1 end
  end
end
print('PASS bounded selected text and label separation on ' .. cycles .. ' cycle/mapping rows')
local cases = 0
for _, scale in ipairs({0.6, 1.6}) do
  for _, fontScale in ipairs({0.9, 1.2}) do
    for _, font in ipairs({'game', 'narrow', 'classic'}) do
      for _, width in ipairs({520, 980}) do
        for _, style in ipairs({'xbox', 'playstation', 'nintendo', 'text'}) do
          CB.db.scale, CB.db.fontScale, CB.db.font, CB.db.pad.style = scale, fontScale, font, style
          CB.UI:MakeFonts()
          CB.db.sizes = { options = { w = width, h = 540 } }
          O:ApplySavedSize(); O:ShowPage('Controller')
          for _, row in ipairs(O.pages.Controller.rows) do
            if row.padKey then
              local b = contained(row)
              assert(b:GetWidth() >= 220, 'mapping controls use available row space without shrinking text')
              for _, action in ipairs(Pad.ACTIONS) do
                CB.db.pad.map[row.padKey] = action; row.refresh()
                contained(row)
                assert(row.label:GetText() == 'Button: ' .. CB.UI:PadLabel(row.padKey), 'preserve style-specific mapping label')
                assert(b.text:GetText() == (action == 'switchWindow' and 'Switch window' or Pad.ACTION_LABEL[action]), 'preserve readable action labels')
                cases = cases + 1
              end
              CB.db.pad.map[row.padKey] = false; row.refresh()
              assert(b.text:GetText() == 'unassigned')
              -- Both button clicks and row/controller activation retain the full catalogue.
              b:Click('LeftButton'); assert(CB.db.pad.map[row.padKey] == Pad.ACTIONS[1])
              b:Click('RightButton'); assert(CB.db.pad.map[row.padKey] == false)
              row.activate(); assert(CB.db.pad.map[row.padKey] == Pad.ACTIONS[1])
              row.adjust(-1); assert(CB.db.pad.map[row.padKey] == false)
            end
          end
        end
      end
    end
  end
end
print('PASS ' .. cases .. ' action/style/font/scale/width combinations, unassigned, mouse and controller cycling')
-- The compact visible label keeps its full explanation on hover.
local menu
for _, row in ipairs(O.pages.Controller.rows) do if row.padKey == 'PADFORWARD' then menu = row end end
CB.db.pad.map.PADFORWARD = 'switchWindow'; menu.refresh()
local mb = valueButton(menu)
mb.__scripts.OnEnter(mb)
assert(CB.UI.Tip.lines[1].left:GetText() == Pad.ACTION_LABEL.switchWindow, 'tooltip keeps the descriptive action text')
assert(mb.cbFocused == nil or mb.cbFocused == false)
mb.__scripts.OnLeave(mb)
print('PASS compact Switch window label with descriptive tooltip')
print('ALL PASS settings mapping (offline only)')
