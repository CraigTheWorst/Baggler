-- Real shipping TOC, offline only. Run from repository root with luajit.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
local CB = {}
BagglerDB = { replaceDefault = false, replaceBank = false, personalBankRestored1 = true, welcomed = true }
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, n, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
local W, O = CB.Window, CB.Options
W:Open()
assert(W.frame.icon:GetWidth() == 36, 'header artwork must be readable at 36px within 42px bar')
print('PASS readable header')
assert(CB.db.replaceDefault and CB.db.replaceBank, 'legacy false flags must migrate to core replacements')
assert(CB.db.coreReplacements1, 'core replacement migration must be versioned')
assert(BagglerDB.welcomed, 'migration must preserve unrelated settings')
O:Open()
for _, r in ipairs(O.specByTab.Behaviour.rows) do
  assert(r.key ~= 'replaceDefault' and r.key ~= 'replaceBank', 'core replacement switches must not be exposed')
end
print('PASS core replacements migration and settings')
assert(type(O.frame.hint.badges) == 'table', 'settings footer must use actual shared HintBar badges')
CB.db.pad.map.PAD1, CB.db.pad.map.PAD3 = 'pickup', 'use'
CB.db.pad.style = 'playstation'
CB:Fire('SETTING', 'pad')
local mapRow
for _, row in ipairs(O.pages.Controller.rows) do if row.padKey == 'PAD3' then mapRow = row end end
assert(mapRow and mapRow.label:GetText():find('Square', 1, true), 'mapping row labels must refresh with controller style')
for _, tab in ipairs(O.tabOrder) do
  O:ShowPage(tab); O:UpdateHint()
  assert(O.frame.hint:GetText():find('Square|r Activate', 1, true), 'footer must follow style and remapped confirm on every tab')
  assert(O.footerH >= O.frame.hint:GetStringHeight() + 20, 'scroll content must clear wrapped footer')
end
O.sizing = true; O:UpdateHint()
assert(#O.frame.hint.badges > 0 and O.frame.hint:GetText():find('Reset', 1, true), 'resize footer must use mapped actions')
O.sizing = nil; O:UpdateHint()
print('PASS shared settings badges, remapping, styles, wrapping and resize mode')
O:ShowPage('Sections')
local page = O.pages.Sections
assert(page.form.nameLabel:GetText():find('Section name', 1, true), 'name input needs a visible label')
assert(page.form.matchLabel:GetText():find('Item name contains', 1, true), 'match input needs a visible label')
assert(page.hint:GetText():find('literal', 1, true) and page.hint:GetText():find('any', 1, true), 'instructions must explain literal substring OR matching')
assert(not page.hint:GetText():find('Controller: A', 1, true), 'instructions must not hardcode controller face labels')
page.form.nameBox:SetText('My supplies'); page.form.patBox:SetText(' PoTiOn, elixir, [bracket] ')
page.form.patBox.__scripts.OnEnterPressed()
local def = CB.db.custom['My supplies']
assert(def and def.patterns[1] == 'potion' and def.patterns[3] == '[bracket]', 'form keeps literal case-insensitive comma-separated matching')
local function classify(name)
  return CB.Categories:Classify({ itemID = 999, nameLower = name, classID = 15 })
end
assert(classify('lesser healing potion') == 'My supplies')
assert(classify('battle elixir') == 'My supplies')
assert(classify('a bracket') ~= 'My supplies', 'brackets are literal, not Lua patterns')
O:ResetTab('Controller'); O:UpdateHint()
assert(CB.db.pad.map.PAD1 == CB.defaults.pad.map.PAD1, 'tab reset recovers confirm action')
print('PASS labeled Sections form, actual literal OR semantics, controller recovery')
-- All supported buttons expose the full existing action catalogue plus unassigned.
local seen = {}
for _, spec in ipairs(O.specByTab.Controller.rows) do
  if spec.padKey then assert(not seen[spec.padKey]); seen[spec.padKey] = true end
end
for _, key in ipairs(CB.Pad.MAPPABLE) do assert(seen[key], 'missing mapping row: ' .. key) end
for _, key in ipairs(CB.Pad.MAPPABLE) do CB.db.pad.map[key] = false end
CB:Fire('SETTING', 'pad'); O:UpdateHint()
assert(not O.frame.hint:GetText():find('Activate', 1, true), 'unassigned actions must not advertise a button')
CB.db.pad.map.PAD1, CB.db.pad.map.PAD3 = 'use', 'use'
CB:Fire('SETTING', 'pad'); O:UpdateHint()
assert(O.frame.hint:GetText():find('Activate', 1, true), 'duplicate actions remain safe and discoverable')
O:ResetTab('Controller')
for _, width in ipairs({400, 520, 760}) do
  W.innerW = width - 24; W:ApplySize()
  assert(W.frame.title:GetWidth() + W.frame.search:GetWidth() + 200 <= width, 'header text/search must reserve right controls')
end
local scale = CB.db.scale
event('ADDON_LOADED', 'Baggler')
assert(CB.db.replaceDefault and CB.db.replaceBank and CB.db.scale == scale, 'migration is reload-safe and preserves preferences')
print('ALL PASS settings polish (offline only)')
