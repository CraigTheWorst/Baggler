-- Shipping TOC accent regression; offline only, from repository root.
dofile('tests/harness/ca_stubs.lua')
local playerClass = 'MAGE'
function UnitClass(unit) assert(unit == 'player'); return 'Localized class', playerClass end
RAID_CLASS_COLORS = { MAGE = { r=.25, g=.78, b=.92 }, WARLOCK = { r=.53, g=.53, b=.93 } }
local CB = {}
BagglerDB = { welcomed=true }
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
local function rgb(r,g,b, message)
  local ar,ag,ab = CB:Accent()
  assert(ar == r and ag == g and ab == b, message)
end
assert(CB.defaults.accent == 'class' and CB.db.accent == 'class', 'fresh/default accent must follow My class')
rgb(.25,.78,.92, 'My class must use actual player mage blue')
playerClass = 'WARLOCK'
rgb(.53,.53,.93, 'My class must resolve warlock purple dynamically, not cache another character')
print('PASS fresh My class default, mage blue and warlock purple (actual TOC)')
local classes = {'WARRIOR','PALADIN','HUNTER','ROGUE','PRIEST','DEATHKNIGHT','SHAMAN','MAGE','WARLOCK','MONK','DRUID','DEMONHUNTER','EVOKER','ADVENTURER','TRAVELER'}
local newPresets = {'coral','salmon','peach','apricot','copper','gold','lemon','chartreuse','lime','sage','mint','seafoam','teal','turquoise','aqua','sky','azure','periwinkle','lavender','lilac','orchid','mauve','pink','ruby'}
local oldPresets = {'ice','violet','emerald','amber','rose','mono'}
local listed = {}
for _, key in ipairs(CB.accentList) do
  assert(type(key) == 'string' and not listed[key], 'unique stable symbolic keys')
  listed[key] = true
  assert(type(CB:AccentLabel(key)) == 'string' and #CB:AccentLabel(key) > 0, 'named preset')
end
assert(#CB.accentList == 46, 'exact catalogue: My class + 15 client classes + 6 legacy + 24 additional presets')
for _, token in ipairs(classes) do
  local key = 'class_' .. token:lower()
  assert(listed[key], 'missing explicit supported class: ' .. token)
end
local colors = {}
for _, key in ipairs(oldPresets) do
  assert(listed[key], 'legacy symbolic key must stay selectable')
  local c = CB.accents[key]; colors[table.concat(c, ',')] = true
end
for _, key in ipairs(newPresets) do
  assert(listed[key], 'missing extra preset ' .. key)
  local c = CB.accents[key]
  assert(c and not colors[table.concat(c, ',')], 'each extra must have a distinct RGB, including legacy presets')
  colors[table.concat(c, ',')] = true
  local function linear(v) return v <= .04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
  local l = .2126*linear(c[1]) + .7152*linear(c[2]) + .0722*linear(c[3])
  assert((l+.05)/(.01+.05) >= 4.5, 'extra accent must remain readable on dark panels: ' .. key)
end
CB:Set('accent', 'class_mage'); playerClass = 'WARLOCK'
rgb(.25,.78,.92, 'explicit Mage choice must not follow player class')
CB:Set('accent', 'class_warlock'); playerClass = 'MAGE'
rgb(.53,.53,.93, 'explicit Warlock choice stays purple on a mage')
CB.Options:Open(); CB.Options:ShowPage('Look')
local accentRow
for i,spec in ipairs(CB.Options.specByTab.Look.rows) do if spec.key == 'accent' then accentRow = CB.Options.pages.Look.rows[i] end end
assert(accentRow and accentRow.valueButton.text:GetText():find('Warlock',1,true), 'Look selector uses sensible class name')
CB:Set('accent', 'class'); accentRow.refresh()
assert(accentRow.valueButton.text:GetText() == 'My class', 'dynamic option must be named My class')
for _,key in ipairs(CB.accentList) do
  CB:Set('accent', key); accentRow.refresh()
  assert(accentRow.valueButton.text:GetText() == CB:AccentLabel(key), 'every option shown by existing compact selector')
end
print('PASS exact 46 options: 15 supported class choices, 6 legacy and 24 distinct readable extras; compact Look selector')
local share = CB.ProfileShare.new({padDefaults=CB.defaults.pad})
for _, key in ipairs(CB.accentList) do
  local encoded = assert(share:Export({accent=key}))
  local result = assert(share:Import(encoded, {}))
  assert(result.accent == key, 'share schema must preserve every accent key: ' .. key)
  CB:Set('accent', key)
  event('ADDON_LOADED', 'Baggler')
  assert(CB.db.accent == key, 'saved selections survive reload: ' .. key)
end
assert(not share:Import('BAGGLER2:{"accent":"invalid!"}', {}), 'unknown accents still rejected')
assert(not share:Import('BAGGLER2:{"accent":1}', {}), 'indices are not a supported share format')
for _,key in ipairs(oldPresets) do
  BagglerDB = {accent=key,welcomed=true}
  event('ADDON_LOADED','Baggler')
  assert(CB.db.accent == key, 'legacy string selection, including ambiguous former default Ice, is never overwritten')
end
BagglerDB={welcomed=true}; event('ADDON_LOADED','Baggler')
assert(CB.db.accent == 'class', 'missing legacy value adopts new dynamic default')
print('PASS all 46 saved/export/import keys, legacy choices preserved, missing default upgraded and invalid shares rejected')
CB:Set('accent','class')
local savedUnitClass, savedColors = UnitClass, RAID_CLASS_COLORS
UnitClass=nil
rgb(.37,.78,1, 'missing class API falls back safely')
UnitClass=function() return nil,nil end
rgb(.37,.78,1, 'missing class token falls back safely')
UnitClass=function() error('unavailable') end
rgb(.37,.78,1, 'throwing class API falls back safely')
UnitClass=savedUnitClass
C_ClassColor={GetClassColor=function(token) if token == 'MAGE' then return {r=.2,g=.6,b=.9} end end}
rgb(.2,.6,.9, 'supported class API takes priority over table')
CB:Set('accent','class_warlock'); rgb(.53,.53,.93, 'missing class color result falls back to public raid table')
CB:Set('accent','class'); C_ClassColor=nil; RAID_CLASS_COLORS=nil
rgb(.25,.78,.92, 'known player class keeps offline mage fallback without color APIs')
RAID_CLASS_COLORS=savedColors
LOCALIZED_CLASS_NAMES_MALE={MAGE='Localized Mage'}
assert(CB:AccentLabel('class_mage') == 'Localized Mage', 'explicit classes use client localized names')
LOCALIZED_CLASS_NAMES_MALE=nil
print('PASS missing/throwing class APIs, color API priority, raid table and fixed fallbacks, localized names')
-- Observe actual paints instead of accepting the harness's chainable no-ops.
CB.db.animations=false
CB.Window:Open(); CB.Bank.window:Create(); CB.Bank.window.frame:Show()
CB.Options:Open(); CB.Options:ShowPage('Look')
CB.Menu:Open(CB.Window.frame, 'Accent fixture', {{text='Checked',checked=true,func=function() end}})
local function painted(target, method)
  local result = {}
  target[method] = function(_, r,g,b) result[1],result[2],result[3] = r,g,b end
  return result
end
local paints = {
  painted(CB.Window.frame.chipBg,'SetColorTexture'),
  painted(CB.Bank.window.frame.chipBg,'SetColorTexture'),
  painted(CB.Options.frame.line,'SetColorTexture'),
  painted(CB.Options.frame.title,'SetTextColor'),
  painted(CB.Options.frame.cbUnder,'SetColorTexture'),
  painted(CB.Options.current.rows[CB.Options.current.focus].sel,'SetColorTexture'),
  painted(BagglerMenu.rows[1].sel,'SetColorTexture'),
}
local button = CB.UI:Button(CB.Options.frame,'Focused')
CB.UI:SetFocused(button,true)
paints[#paints+1]=painted(button,'SetBackdropBorderColor')
local function checkPaints(key)
  local c=CB.accents[key]
  for i, p in ipairs(paints) do assert(p[1]==c[1] and p[2]==c[2] and p[3]==c[3], 'immediate shared accent paint missing on custom surface ' .. i) end
end
CB:Set('accent','coral'); checkPaints('coral')
assert(CB.Extras:Import('BAGGLER2:{"accent":"mint"}'))
checkPaints('mint')
assert(CB.Options.current.name == 'Look' and CB.Menu:IsOpen(), 'recolor must not reopen/close windows or change focus/page')
print('PASS immediate bags, bank, settings chrome/highlight, menu and shared focus recolor, including import')
local unitClassCalls=0
UnitClass=function() unitClassCalls=unitClassCalls+1; error('explicit choice must not query player') end
local seenClasses={}
C_ClassColor={GetClassColor=function(token) seenClasses[token]=true; return {r=.61,g=.71,b=.81} end}
for _,token in ipairs(classes) do
  CB:Set('accent','class_' .. token:lower())
  rgb(.61,.71,.81, 'every supported explicit class uses the actual client color')
end
assert(unitClassCalls==0, 'explicit classes never query player identity')
for _,token in ipairs(classes) do assert(seenClasses[token], 'client color missing: ' .. token) end
C_ClassColor=nil; UnitClass=savedUnitClass
local secret=setmetatable({}, {__index=function() error('secret inspected') end,__tostring=function() error('secret logged') end})
function issecretvalue(v) return rawequal(v,secret) end
UnitClass=function() return secret,secret end
CB:Set('accent','class'); rgb(.37,.78,1,'secret class token must remain opaque')
UnitClass=savedUnitClass
C_ClassColor={GetClassColor=function() return secret end}
rgb(.25,.78,.92,'secret color result must remain opaque and use public fallback')
C_ClassColor={GetClassColor=function() return {r=secret,g=.5,b=.5} end}
rgb(.25,.78,.92,'secret color channel must remain opaque and use fixed fallback')
C_ClassColor=nil; issecretvalue=nil
print('PASS all 15 actual API color routes, no player lookup for explicit presets, opaque secret token/result/channel')
print('ALL PASS accent palette (offline only)')
