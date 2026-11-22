-- Offline diagnostic contract only: Lua cannot model the client's taint engine.
-- Run: timeout 60 luajit addons/Baggler/Tests/aura_probe_test.lua
local events, lifecycle, pending, writers = {}, {}, {}, {}
local clock, reads, auraFallbackReads = 0, 0, 0
function GetTime() return clock end
C_Timer = { After = function(_, f) pending[#pending + 1] = f end }
local CB = { db = {}, HEX = { brand = '' } }
function CB:RegisterEvent(ev, fn) events[ev] = fn end
function CB:On(ev, fn) lifecycle[ev] = fn end
function issecurevariable(t, k)
  reads = reads + 1
  local w = writers[t]
  if w and w[k] then return false, w[k] end
  return true
end
local secret = newproxy(true)
getmetatable(secret).__tostring = function() error('secret formatted') end
getmetatable(secret).__eq = function() error('secret compared') end
function issecretvalue(v) return rawequal(v, secret) end
local function guarded(t)
  return setmetatable(t, { __index = function(_, k)
    if k == 'auraType' then auraFallbackReads = auraFallbackReads + 1; error('auraType fallback') end
  end, __newindex = function() error('native write') end })
end
local info = guarded({ expirationTime = secret, auraInstanceID = secret, timeMod = secret })
local button = guarded({ buttonInfo = info, OnUpdate = function() error('native callback called') end })
BuffFrame = guarded({ auraFrames = { button }, auraTooltipQueue = {}, Update = function() error('native update called') end })
local tipInfo = guarded({ tooltipData = secret })
GameTooltip = guarded({ processingInfo = tipInfo })
local focus = guarded({})
function GetMouseFoci() return { focus } end
assert(loadfile('addons/Baggler/Log.lua'))('Baggler', CB)
assert(type(CB.AuraProbe) == 'function', 'missing targeted native aura/focus provenance probe')
CB:AuraProbe('before hover')
writers[info] = { expirationTime = 'OtherAddon' }
CB:AuraProbe('after hover')
local text = table.concat(CB.db.auraWatch or {}, '\n')
assert(text:find('BuffFrame.auraFrames[1].buttonInfo.expirationTime', 1, true), text)
assert(text:find('OtherAddon', 1, true) and text:find('before hover', 1, true) and text:find('after hover', 1, true), text)
local count = #(CB.db.auraWatch or {})
for _ = 1, 200 do CB:AuraProbe('same state') end
assert(#CB.db.auraWatch == count, 'unchanged observations must not flood the log')
assert(auraFallbackReads == 0, 'metadata must raw-read absent auraType, never invoke its metatable')
writers[button] = { OnUpdate = 'Baggler' }
writers[tipInfo] = { tooltipData = 'OtherTooltipAddon' }
writers[focus] = { auraType = 'Baggler' } -- even absent raw fields carry provenance
CB:AuraProbe('native callback/tooltip boundary')
text = table.concat(CB.db.auraWatch, '\n')
for _, path in ipairs({ 'BuffFrame.auraFrames[1].OnUpdate=insecure by Baggler',
  'GameTooltip.info.tooltipData=insecure by OtherTooltipAddon', 'mouse[1]:anonymous.auraType=insecure by Baggler' }) do
  assert(text:find(path, 1, true), 'missing slot: ' .. path)
end
writers[info] = nil
CB:AuraProbe('recovered')
assert(table.concat(CB.db.auraWatch, '\n'):find('expirationTime=secure', 1, true), 'record recovery as well as first taint')
assert(events.UNIT_AURA and events.PLAYER_REGEN_ENABLED and events.PLAYER_REGEN_DISABLED, 'missing aura/regen event boundaries')
reads = 0
for _ = 1, 1000 do events.UNIT_AURA('UNIT_AURA', 'target', secret) end
assert(reads == 0, 'non-player aura events ignored without inspecting event payload')
for _ = 1, 1000 do events.UNIT_AURA('UNIT_AURA', 'player', secret) end
assert(reads < 5000 and #pending <= 1, 'player aura burst must coalesce/throttle scans')
for _, fn in ipairs(pending) do fn() end
for i = 1, 100 do
  clock = i
  writers[info] = { expirationTime = i % 2 == 0 and 'Baggler' or 'OtherAddon' }
  CB:AuraProbe('bounded ' .. i)
end
assert(#CB.db.auraWatch <= 48, 'saved first-transition evidence is bounded')
assert(CB.db.auraWatch[1]:find('before hover', 1, true), 'retain earliest evidence, not just final flood state')
CB.defaults = {}
function InCombatLockdown() return false end
CB.Capabilities = function() return {} end
assert(CB:BuildReport():find('-- native aura provenance (first observations, preserved across sessions) --', 1, true),
  'copyable report must retain dedicated aura evidence even after ordinary log flood')
CB.db.auraWatch = { 'old session' }
CB.db.log = 'old invalid log shape'
lifecycle.DB_READY()
assert(CB.db.auraWatch[1] == 'old session' and #CB.db.auraWatch <= 48,
  'new session must retain earliest evidence rather than overwrite it at login')
print('PASS aura provenance boundaries, writer attribution, absent auraType raw read, secret opacity, coalescing and bounded first evidence (offline only)')
