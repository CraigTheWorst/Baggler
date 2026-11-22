-- Run from repository root: luajit addons/Baggler/Tests/defaults_merge_test.lua
-- Saved settings are topped up from CB.defaults at ADDON_LOADED (shipping TOC, fake client). Offline only.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function UnitLevel() return 60 end

local function boot(saved)
  BagglerDB = saved
  local CB = {}
  for line in io.lines('addons/Baggler/Baggler.toc') do
    if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
  end
  CB.eventFrame.__scripts.OnEvent(CB.eventFrame, 'ADDON_LOADED', 'Baggler')
  return CB
end

local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print('PASS defaults merge: ' .. name) end

check('fresh profile receives an independent copy of every default', function()
  local CB = boot(nil)
  local db = CB.db
  for key, value in pairs(CB.defaults) do
    assert(db[key] ~= nil, 'missing ' .. key)
    if type(value) == 'table' then assert(db[key] ~= value, key .. ' shares the defaults table') end
  end
  assert(db.pad.map ~= CB.defaults.pad.map and db.pad.map.PAD1 == 'use')
  db.pad.map.PAD1 = 'menu'; db.favorites[5] = true; db.point[1] = 'TOP'
  assert(CB.defaults.pad.map.PAD1 == 'use', 'editing the profile changed the defaults')
  assert(next(CB.defaults.favorites) == nil and CB.defaults.point[1] == 'BOTTOMRIGHT')
end)

check('partial nested profile keeps its values and gains missing keys', function()
  local CB = boot({ scale = 1.2, showIlvl = false, pad = { hints = false, map = { PAD1 = 'menu', PADFORWARD = 'sort' } }, favorites = { [7] = true } })
  local db = CB.db
  assert(db.scale == 1.2 and db.showIlvl == false, 'saved scalars kept, false included')
  assert(db.pad.hints == false and db.pad.map.PAD1 == 'menu' and db.pad.map.PADFORWARD == 'sort')
  assert(db.pad.map.PAD2 == 'close' and db.pad.style == 'xbox', 'nested defaults filled in')
  assert(db.favorites[7] == true and db.columns == CB.defaults.columns)
end)

check('a scalar where a table belongs is replaced and logged', function()
  local CB = boot({ pad = 'broken', views = 3 })
  local db = CB.db
  assert(type(db.pad) == 'table' and db.pad.map.PAD1 == 'use', 'pad restored')
  assert(type(db.views) == 'table', 'views restored')
  CB:Info('test', 'flush')        -- warnings raised before CB.db existed are queued until the next entry
  local warned = {}
  for _, entry in ipairs(db.log or {}) do
    local text = entry.ctx == 'db' and tostring(entry.msg) or ''
    for _, key in ipairs({ 'pad', 'views' }) do
      if text:find("'" .. key .. "'", 1, true) then warned[key] = (warned[key] or 0) + 1 end
    end
  end
  assert(warned.pad == 1 and warned.views == 1, 'each corrupt value is logged once')
end)

check('keys unknown to the defaults survive', function()
  local CB = boot({ someOldKey = 'keep', pad = { legacy = 4 } })
  assert(CB.db.someOldKey == 'keep' and CB.db.pad.legacy == 4)
end)

check('empty-table defaults only appear when missing', function()
  local mine = { [12] = true }
  local CB = boot({ junk = mine })
  assert(CB.db.junk == mine and CB.db.junk[12], 'existing table kept')
  assert(type(CB.db.pinTop) == 'table' and next(CB.db.pinTop) == nil)
end)

print(('PASS defaults merge: %d cases'):format(passed))
