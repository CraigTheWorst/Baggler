-- Core slice of the standalone settings codec. Run: luajit test.lua (from this folder or with a path).
local path = arg[0]:match('^(.*)/') or '.'
local M = dofile(path .. '/ProfileShare.lua')
local codec = M.new()

-- Empty share; private fields of the current profile survive untouched and are never exported.
local p, why = codec:Import('  BAGGLER2:{}\n', {private = {x = 1}})
assert(p, why)
assert(p.private.x == 1)
assert(codec:Export({private = true}) == 'BAGGLER2:{}')
print('PASS empty share and private preservation')

-- Scalars in range import; out of range rejects with the setting named.
local scalar = assert(codec:Import('BAGGLER2:{"locked":false,"scale":0.6}', {}))
assert(scalar.scale == 0.6 and scalar.locked == false)
local none, reason = codec:Import('BAGGLER2:{"scale":2}', {})
assert(none == nil and reason:find('scale'), tostring(reason))
print('PASS scalar slice')

-- A controller patch merges into the current pad.
local merged = assert(codec:Import('BAGGLER2:{"pad":{"map":{"PAD1":false}}}', {pad = {mode = 'on', map = {PAD1 = 'use', PAD2 = 'close'}}}))
assert(merged.pad.mode == 'on' and merged.pad.map.PAD1 == false and merged.pad.map.PAD2 == 'close')
print('PASS partial controller merge')

-- The previous format is refused with a friendly reason.
local old, oldReason = codec:Import('BAGGLER1:{s5:scalen1;}', {})
assert(old == nil and oldReason == 'This share code is from an older Baggler version; please export it again.', tostring(oldReason))
print('PASS older version refused')
