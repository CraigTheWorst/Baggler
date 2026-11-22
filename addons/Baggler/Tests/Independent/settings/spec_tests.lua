-- Schema, grammar and budget checks for the standalone settings codec. Run: luajit spec_tests.lua (this folder).
-- `json` below is a small fixture writer for building share texts; it is a test aid, not a call into the codec,
-- and it deliberately emits keys in table order (the codec's own output is checked for sorted keys separately).
local M = dofile('ProfileShare.lua')
local c = M.new()
local total = 0
local function check(ok, msg) total = total + 1; assert(ok, msg or ('check ' .. total)) end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function jstr(s)
    return '"' .. s:gsub('[%c"\\|]', function(ch) return string.format('\\u%04x', ch:byte()) end) .. '"'
end
local function json(v, asList)
    local t = type(v)
    if t == 'string' then return jstr(v) end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        if v ~= v then return 'NaN' end
        if v == math.huge then return '1e9999' end
        if v == -math.huge then return '-1e9999' end
        return string.format('%.17g', v)
    end
    if asList then
        local parts = {}
        for i = 1, #v do parts[i] = json(v[i]) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    local parts = {}
    for k, x in pairs(v) do
        local list = type(x) == 'table' and k == 'patterns'
        parts[#parts + 1] = jstr(tostring(k)) .. ':' .. json(x, list)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end
local function wire(v) return 'BAGGLER2:' .. json(v) end

local seed = {scale = 1, chars = {private = {1, 2}}, unknownFuture = true,
    pad = {mode = 'on', backend = 'bindings', map = {PAD1 = 'use', PAD2 = 'close'}}, favorites = {[9] = true}}
local snapshot = wire(seed)
local function good(v)
    local p, r = c:Import(wire(v), {}); check(p ~= nil, r)
    local s, e = c:Export(p); check(s ~= nil, e)
    check(c:Export(p) == s, 'export must be byte-stable')
    local q, f = c:Import(s, {}); check(q ~= nil, f); check(same(p, q), 'round trip')
    return p
end
local function bad(v)
    local p, r = c:Import(type(v) == 'string' and v or wire(v), seed)
    check(p == nil and type(r) == 'string' and #r > 0, 'accepted: ' .. (type(v) == 'string' and v or wire(v)):sub(1, 120))
    check(wire(seed) == snapshot, 'rejected import changed the current profile')
end

-- Numeric settings: bounds, integers, wrong types, non-finite values.
local bounds = {scale = {.6, 1.6}, iconSize = {28, 52, 1}, spacing = {0, 10, 1}, columns = {6, 24, 1}, vendorColumns = {4, 12, 1},
    bgAlpha = {.3, 1}, fontScale = {.9, 1.2}, lowSpaceAt = {0, 200, 1}}
for k, b in pairs(bounds) do
    good({[k] = b[1]}); good({[k] = b[2]})
    bad({[k] = b[1] - .01}); bad({[k] = b[2] + .01}); bad({[k] = '1'}); bad({[k] = true}); bad({[k] = {}})
    for _, special in ipairs({0 / 0, math.huge, -math.huge}) do
        bad({[k] = special}); check(c:Export({[k] = special}) == 'BAGGLER2:{}', 'non-finite values are not exported')
    end
    if b[3] then bad({[k] = b[1] + .5}) end
end
local choices = {accent = 'class ice violet mono class_mage ruby', font = 'game narrow classic', cardSide = 'auto left right',
    group = 'category type expansion bag bagtype none', sort = 'quality name ilvl type recent', emptyMode = 'collapse show hide'}
for k, s in pairs(choices) do
    for v in s:gmatch('%S+') do good({[k] = v}) end
    bad({[k] = 'unknown'}); bad({[k] = false})
end
for k in ('showBorders showIlvl itemCard cardCompare rowWrap junkAll replaceBank showAltCounts reduceMotion qualityMarks'):gmatch('%S+') do
    good({[k] = true}); good({[k] = false}); bad({[k] = 1})
end
print('PASS scalar schema')

-- Collections.
good({favorites = {[1] = false, [2147483647] = true}, junk = {[2] = true}, pinTop = {[3] = false}, pins = {[4] = 'é' .. string.char(0, 255)},
    collapsed = {x = false}, views = {empty = '', utf8 = 'é'}, custom = {s = {patterns = {'a', string.rep('x', 200)}, order = 10000}, e = {patterns = {}, order = 0}}})
for _, k in ipairs({'favorites', 'junk', 'pinTop', 'pins', 'collapsed', 'views', 'custom'}) do good({[k] = {}}); bad({[k] = false}) end
for _, k in ipairs({'favorites', 'junk', 'pinTop', 'pins'}) do
    for _, id in ipairs({'0', '-1', '1.5', '2147483648', '01', 'abc'}) do
        bad('BAGGLER2:{"' .. k .. '":{"' .. id .. '":' .. (k == 'pins' and '"x"' or 'true') .. '}}')
    end
    bad('BAGGLER2:{"' .. k .. '":[' .. (k == 'pins' and '"x"' or 'true') .. ']}')     -- a list is not a dictionary
end
bad({views = {a = 1}}); bad({views = {a = string.rep('x', 1001)}}); bad({collapsed = {a = 1}})
bad('BAGGLER2:{"custom":{"a":{"patterns":{"1":"x"}}}}')                                  -- patterns must be a list
for _, v in ipairs({{}, {patterns = {''}}, {patterns = {string.rep('x', 201)}}, {patterns = {}, other = true},
    {patterns = {}, order = -1}, {patterns = {}, order = 10001}, {patterns = {}, order = .5}, {patterns = false}, {patterns = {}, order = 'x'}}) do
    bad({custom = {a = v}})
end
local patterns = {}; for i = 1, 100 do patterns[i] = 'x' end
good({custom = {a = {patterns = patterns}}}); patterns[101] = 'x'; bad({custom = {a = {patterns = patterns}}})
local maps = {favorites = {}, junk = {}}; for i = 1, 5000 do maps.favorites[i] = true; maps.junk[i] = false end
local mapsText = assert(c:Export(maps)); good(maps)
print('PASS collections, two 5000-entry maps = ' .. #mapsText .. ' bytes')

-- Controller.
for k, s in pairs({mode = 'auto on off', backend = 'bindings catcher', style = 'xbox playstation nintendo text'}) do
    for v in s:gmatch('%S+') do good({pad = {[k] = v}}) end
    bad({pad = {[k] = 'other'}})
end
for _, k in ipairs({'hints', 'stickNav'}) do good({pad = {[k] = false}}); bad({pad = {[k] = 1}}) end
for _, pad in ipairs({false, {foo = true}, {map = false}, {map = {PAD5 = 'use'}}, {map = {PAD1 = true}}, {map = {PAD1 = 'other'}}}) do bad({pad = pad}) end
local d = M.new({padDefaults = {mode = 'auto', style = 'text', map = {PAD1 = 'use', PAD3 = 'menu'}}})
local out = assert(d:Import('BAGGLER2:{"favorites":{},"pad":{"map":{"PAD1":false}}}', seed))
check(out.pad.mode == 'on' and out.pad.style == 'text' and out.pad.map.PAD1 == false and out.pad.map.PAD2 == 'close' and out.pad.map.PAD3 == 'menu')
check(next(out.favorites) == nil and seed.favorites[9] == true, 'collections replace; current untouched')
out.chars.private[1] = 99; check(seed.chars.private[1] == 1, 'no aliasing of the current profile')
print('PASS controller merge and defaults')

-- Private and unknown fields.
local dirty = {scale = 1.1, log = 'SECRET', chars = 'SECRET', pad = {mode = 'on', strange = 'SECRET', map = {PAD1 = 'use', PAD2 = 'INVALID'}}}
local exported = assert(c:Export(dirty))
check(not exported:find('SECRET', 1, true) and not exported:find('INVALID', 1, true))
check(same(assert(c:Import('BAGGLER2:{"futureThing":[1,2,{"x":true}]}', seed)), seed), 'unknown keys are ignored')
print('PASS private exclusion')

-- Canonical output.
local canon = assert(c:Export({views = {b = 'x|y', a = 'line\nbreak'}, scale = 1.1, favorites = {[10] = true, [9] = true}}))
check(canon == 'BAGGLER2:{"favorites":{"10":true,"9":true},"scale":1.1,"views":{"a":"line\\nbreak","b":"x\\u007cy"}}', canon)
check(not canon:find('|', 1, true) and not canon:find('\n', 1, true))
for _, n in ipairs({0.1, 1 / 3, 0.94, 1.2000000000000002, 123456789, 1e-7}) do
    if n >= .3 and n <= 1 then
        local back = assert(c:Import(assert(c:Export({bgAlpha = n})), {}))
        check(back.bgAlpha == n, 'number round trip ' .. string.format('%.17g', n))
    end
end
print('PASS canonical sorted output, escapes, exact numbers')

-- Grammar.
local malformed = {'OTHER:{}', 'BAGGLER2:', 'BAGGLER2:1', 'BAGGLER2:[]', 'BAGGLER2:"x"', 'BAGGLER2:return os.exit()', 'BAGGLER2:{',
    'BAGGLER2:{"scale":1', 'BAGGLER2:{"scale":1}x', 'BAGGLER2:{}{}', 'BAGGLER2:{"views":{"a":"x}}', 'BAGGLER2:{"views":["a"}',
    'BAGGLER2:{"scale":1,"scale":1.1}', 'BAGGLER2:{"scale":null}', 'BAGGLER2:{scale:1}', "BAGGLER2:{'scale':1}",
    'BAGGLER2:{"scale":1,}', 'BAGGLER2:{"views":{"a":"\\x"}}', 'BAGGLER2:{"views":{"a":"\\ud800"}}', 'BAGGLER2:{"views":{"a":"a\tb"}}',
    'BAGGLER2:{"locked":tru}', 'BAGGLER2:{"locked":falsey}', 'baggler2:{}'}
for _, n in ipairs({'NaN', 'inf', '-inf', '1e9999', '+1', '1.', '.1', '0x10', '01', '-01', '--1', '1e', '1e+', '1 2', '1e1e1'}) do
    malformed[#malformed + 1] = 'BAGGLER2:{"scale":' .. n .. '}'
end
for _, s in ipairs(malformed) do bad(s) end
for _, n in ipairs({'1', '1.0', '1e0', '10E-1', '0.1e1', '-0.0e0'}) do
    local p = c:Import('BAGGLER2:{"spacing":' .. n .. '}', {})
    check(p ~= nil and p.spacing == tonumber(n), 'valid number ' .. n)
end
check(assert(c:Import(' \t BAGGLER2: { "views" : { "a" : "\\u00e9\\ud83d\\ude00\\/" } } \r\n', {})).views.a == 'é\240\159\152\128/', 'escapes and whitespace')
local p, r = c:Import(false, seed); check(p == nil and r:find('string'))
for i = 1, #exported - 1 do check(c:Import(exported:sub(1, i), seed) == nil, 'truncated text accepted') end
print('PASS grammar')

-- Budgets.
local function nested(levels) return 'BAGGLER2:' .. string.rep('{"x":', levels - 1) .. '{}' .. string.rep('}', levels - 1) end
check(c:Import(nested(8), {}) ~= nil, 'depth 8 accepted')
p, r = c:Import(nested(9), {}); check(p == nil and r:find('deep'), r)
p, r = c:Import(nested(10), {}); check(p == nil and r:find('deep'), r)
local function members(n) local t = {}; for i = 1, n do t[i] = '"k' .. i .. '":true' end; return 'BAGGLER2:{' .. table.concat(t, ',') .. '}' end
check(c:Import(members(12499), {}) ~= nil, '24999 values accepted')
local wide = members(12501); check(#wide < 200000)
p, r = c:Import(wide, {}); check(p == nil and r:find('too many'), r)
local filler = 'BAGGLER2:{"views":{"a":"' .. string.rep('x', 200000) .. '"}}'
p, r = c:Import(filler:sub(1, 200001), {}); check(p == nil and r:find('too long'), r)
local exact = 'BAGGLER2:{}' .. string.rep(' ', 200000 - #'BAGGLER2:{}'); check(#exact == 200000 and c:Import(exact, {}) ~= nil, 'exact byte limit')
p, r = c:Import(exact .. ' ', {}); check(p == nil and r:find('too long'), 'untrimmed length counts')
local huge = {favorites = maps.favorites, junk = maps.junk, pinTop = maps.favorites}
p, r = c:Export(huge); check(p == nil and r:find('too many'), tostring(r))
local views = {}; for i = 1, 200 do views['v' .. i] = string.rep('x', 1000) end
p, r = c:Export({views = views}); check(p == nil and r:find('too large'), tostring(r))
print('PASS budgets: depth 8/9/10, values 24999/25003, bytes 200000/200001')

-- Older share texts.
p, r = c:Import('BAGGLER1:{s5:scalen1.1;}', seed)
check(p == nil and r == 'This share code is from an older Baggler version; please export it again.')
check(wire(seed) == snapshot)
print('PASS older version message')
print('PASS ' .. total .. ' checks; ' .. _VERSION .. '; ' .. (jit and jit.version or 'no jit'))
