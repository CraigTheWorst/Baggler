-- Offline real-TOC presentation regression; no in-game permission claims.
dofile('tests/harness/ca_stubs.lua')
local originalCreate = CreateFrame
CreateFrame = function(...)
  local f = originalCreate(...)
  function f:SetPoint(...) self.__point = { ... } end
  local createText = f.CreateFontString
  f.CreateFontString = function(self, ...)
    local text = createText(self, ...)
    function text:SetPoint(...) self.__point = { ... } end
    function text:SetFontObject(role) self.__fontObject = role end
    function text:GetStringWidth() return #(self:GetText():gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '')) * 5 end
    return text
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
CB.db.pad.mode = 'on'
local W, UI = CB.Window, CB.UI
W:Open()
MerchantFrame = CreateFrame('Frame', 'MerchantFrame', UIParent); MerchantFrame:Show()
local function hints()
  W:SetHintText(400)
  return UI.ParseHints(W.frame.hints:GetText())
end
local items = hints()
local expected = { 'Move', 'Use', 'Pick up', 'Menu', 'Section', 'Fold', 'Sell junk', 'Favorite', 'Sort' }
for i, label in ipairs(expected) do assert(items[i].label == label, 'logical hint order: expected ' .. label .. ', got ' .. tostring(items[i].label)) end
assert(items[6].keys[1] == 'LT' and items[7].keys[1] == 'RT')
assert(items[8].keys[1] == 'L3' and items[9].keys[1] == 'R3')
MerchantFrame:Hide(); items = hints(); assert(items[7].label == 'Filter')
CB.db.pad.map.PADLTRIGGER, CB.db.pad.map.PADRTRIGGER = 'filter', 'collapse'
CB.db.pad.style = 'playstation'
items = hints(); assert(items[6].keys[1] == 'R2' and items[7].keys[1] == 'L2', 'actual remap and style labels')
W.chrome = 1; W.ChromeId = function() return 'selljunk' end
W:SetHintText(400); assert(W.frame.hints:GetText():find('Sell junk', 1, true), 'chrome must name Sell junk')
W.chrome = nil; W.sizing = true; W:SetHintText(400); assert(W.frame.hints:GetText():find('Columns', 1, true))
W.sizing = nil
print('PASS logical hint order, contextual triggers, remapping, style and chrome/resize labels')
-- Pair-aware flow must retain real badges and never split a fitting pair.
local bar = UI:HintBar(UIParent)
local c = '|cff5ec8ff'
bar:SetWidth(170)
bar:SetText(c .. 'A|r One   ' .. c .. 'LT|r Fold   ' .. c .. 'RT|r Sell junk', { 1, 2, 2 })
assert(bar.layoutRows and bar.layoutRows[1] ~= bar.layoutRows[2] and bar.layoutRows[2] == bar.layoutRows[3], 'trigger pair must share wrapped row')
bar:SetWidth(100)
assert(bar:GetStringWidth() <= 100, 'oversized groups fall back to individual hints')
CB.db.showBagSlots = true
local iconSize, scale = CB.db.iconSize, CB.db.scale
W:UpdateBagSlots()
local slot = W.frame.bagSlots[1]
assert(slot:GetWidth() == 32 and slot:GetHeight() == 32, 'local bag equipment icons must be 32px')
assert(slot.capacity.__fontObject == 'BagglerFontCount', 'capacity must use readable scalable 12px count role')
-- equipped-bag slots use the same unroundable ring outline as item tiles: full-size ring, icon/fill inset inside it
assert(slot.cbRing and slot.cbBg, 'bag slots must draw the item-tile ring outline, not a 1px backdrop edge')
assert(slot.cbOutline and slot.cbOutline[1] == slot.cbRing, 'bag slot outline must be recoloured through the ring')
slot:SetBackdropBorderColor(0.9, 0.1, 0.1, 1)
assert(slot.cbLastEdge and slot.cbLastEdge[1] == 0.9, 'focus/hover colours must reach the ring')
local fontScale = CB.db.fontScale
CB.db.fontScale = 1; UI:MakeFonts()
local _, baseCapacitySize = BagglerFontCount:GetFont()
assert(baseCapacitySize == 12, 'capacity base font is 12px, not the old 9px override')
CB.db.fontScale = 1.3; UI:MakeFonts()
local _, enlargedCapacitySize = BagglerFontCount:GetFont()
assert(enlargedCapacitySize > baseCapacitySize, 'equipment numbers follow existing text-size preference')
CB.db.fontScale = fontScale; UI:MakeFonts()
W.innerW = 336; W:ApplySize()
assert(W.footerH >= 68, 'bag row and summary row need separate reserved space')
assert(W.frame.footer:GetHeight() == W.footerH - 8)
assert(CB.db.iconSize == iconSize and CB.db.scale == scale, 'global iconSize and UI scale must remain untouched')
CB.db.showFooter = false; W.frame.sellBtn:Show(); W:ApplySize()
assert(W.footerH >= 30, 'visible vendor action needs space even with footer hidden')
CB.db.showFooter = true; CB.db.locked = true; W.sizing = nil; W.chrome = nil
W:SetHintText(400)
assert(not W.frame.hints:GetText():find('filter, size', 1, true), 'locked layout must not advertise resizing')
-- Stress real flow at narrow and wide widths, with scaled approximate font metrics.
CB.db.locked = false
for _, width in ipairs({ 336, 520, 760 }) do
  for _, style in ipairs({ 'xbox', 'playstation', 'nintendo' }) do
    CB.db.pad.style = style
    W.innerW = width; W:ApplySize()
    assert(W.frame.hints:GetStringWidth() <= W.frame:GetWidth() - 24, 'hint overflow: ' .. style .. '/' .. width)
    assert(W.hintH == W.frame.hints:GetStringHeight() + 8, 'frame reserves actual wrapped hint height')
    local rows = W.frame.hints.layoutRows
    assert(rows[6] == rows[7] and rows[8] == rows[9], 'actual view keeps trigger and stick pairs together')
    local bottom = 0
    for _, b in ipairs(W.frame.bagSlots) do
      if b:IsShown() then
        local p = b.__point
        assert(p[4] >= 0 and p[4] + b:GetWidth() <= width, 'equipment stays inside footer')
        bottom = math.max(bottom, -p[5] + b:GetHeight())
      end
    end
    assert(-W.frame.slotsText.__point[5] >= bottom + 6, 'summary never overlays equipment')
  end
end
CB.db.showBagSlots = false; W:UpdateBagSlots()
for _, b in ipairs(W.frame.bagSlots) do assert(not b:IsShown()) end
CB.db.pad.hints = false; W:ApplySize()
assert(W.hintH == 0 and not W.frame.hints:IsShown(), 'hidden hints reserve no rows')
if os.getenv('BAGGLER_FOOTER_SVG') then assert(loadfile('addons/Baggler/Tests/footer_render.lua'))(CB, W, os.getenv('BAGGLER_FOOTER_SVG')) end
print('PASS pair-aware wrapping, local 32px equipment slots, scalable capacity and reserved footer rows')
print('ALL PASS footer polish (offline only)')
