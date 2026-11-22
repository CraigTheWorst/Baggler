-- Loader envelope: publishes the standalone module below (also kept as
-- Tests/Independent/settings/ProfileShare.lua) on the Baggler namespace.
local addonName, namespace = ...
local unit = (function()
-- Settings share: profile schema plus the BAGGLER2 text codec. Lua 5.1, no game globals.
local M = {}
local MAX_BYTES, MAX_VALUES, MAX_DEPTH = 200000, 25000, 8
local function fail(message) error(message, 0) end
local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end
local function plain(t) return type(t) == 'table' and getmetatable(t) == nil end
local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}; seen[value] = result
    for k, v in next, value do result[copy(k, seen)] = copy(v, seen) end
    return result
end
-- Wire format: "BAGGLER2:" followed by one JSON (RFC 8259) object. Only a strict subset is spoken: objects,
-- arrays, strings, finite numbers and true/false; null is refused. Output is canonical (sorted keys, no
-- whitespace) so the same profile always exports to the same line. '|' is written as \u007c because the chat
-- and edit boxes treat a raw bar as the start of an escape sequence.
local PREFIX, OLD_PREFIX = 'BAGGLER2:', 'BAGGLER1:'
-- Item-keyed maps travel as objects with decimal keys and come back with number keys.
local NUMBER_KEYED = {favorites = true, junk = true, pinTop = true, pins = true}
-- Settings that are dictionaries; a JSON list in their place would otherwise slip through as number keys.
local DICTIONARIES = {favorites = true, junk = true, pinTop = true, pins = true, collapsed = true, views = true, custom = true, pad = true}

local function isPatternList(path)
    return #path == 3 and path[1] == 'custom' and path[3] == 'patterns'
end

-- Writer ---------------------------------------------------------------------------------------------------
local ESCAPES = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
local function quote(s)
    return '"' .. s:gsub('[%c"\\|]', function(ch)
        return ESCAPES[ch] or string.format('\\u%04x', ch:byte())
    end) .. '"'
end

local NUMBER_SHAPE = '^%-?%d+%.?%d*[eE]?[-+]?%d*$'
local function numberText(n)
    if not finite(n) then fail('Cannot share a non-finite number') end
    -- Shortest precision that still reads back as the very same double.
    for _, digits in ipairs({15, 16, 17}) do
        local s = string.format('%.' .. digits .. 'g', n)
        if tonumber(s) == n then
            if not s:find(NUMBER_SHAPE) or s:find('%.$') or s:find('%.[eE]') then
                fail('Number formatting produced an unreadable value')
            end
            return s
        end
    end
    fail('Number cannot be written exactly')
end

local written = 0                     -- values and keys emitted by the current encode
local function tally()
    written = written + 1
    if written > MAX_VALUES then fail('These settings hold too many values to share') end
end

local function writeValue(out, value, path)
    tally()
    local kind = type(value)
    if kind == 'boolean' then out[#out + 1] = value and 'true' or 'false'; return end
    if kind == 'number' then out[#out + 1] = numberText(value); return end
    if kind == 'string' then out[#out + 1] = quote(value); return end
    if kind ~= 'table' then fail('Cannot share a ' .. kind .. ' value') end
    if #path >= MAX_DEPTH then fail('Settings are nested too deeply to share') end
    if isPatternList(path) then
        out[#out + 1] = '['
        for i = 1, #value do
            if i > 1 then out[#out + 1] = ',' end
            path[#path + 1] = i
            writeValue(out, value[i], path)
            path[#path] = nil
        end
        out[#out + 1] = ']'
        return
    end
    local numericKeys = #path == 1 and NUMBER_KEYED[path[1]]
    local names, original = {}, {}
    for k in next, value do
        local name
        if type(k) == 'string' then name = k
        elseif numericKeys and type(k) == 'number' and k % 1 == 0 then name = string.format('%d', k)
        else fail('Cannot share a table key of type ' .. type(k)) end
        if original[name] ~= nil then fail('Two keys would be written the same way') end
        original[name] = k
        names[#names + 1] = name
    end
    table.sort(names)
    out[#out + 1] = '{'
    for i, name in ipairs(names) do
        if i > 1 then out[#out + 1] = ',' end
        tally()
        out[#out + 1] = quote(name)
        out[#out + 1] = ':'
        path[#path + 1] = name
        writeValue(out, value[original[name]], path)
        path[#path] = nil
    end
    out[#out + 1] = '}'
end

local function encode(profile)
    local out = {PREFIX}
    written = 0
    writeValue(out, profile, {})
    local text = table.concat(out)
    if #text > MAX_BYTES then fail('These settings are too large to share') end
    return text
end

-- Reader ---------------------------------------------------------------------------------------------------
local function utf8(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40) end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local UNESCAPE = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}

-- A small recursive-descent reader over one string. `pos` always points at the next unread byte.
local function newReader(src)
    local pos, values = 1, 0
    local reader = {}

    local function bad(what) fail('Settings text is malformed: ' .. what .. ' at character ' .. pos) end
    local function count()
        values = values + 1
        if values > MAX_VALUES then fail('Settings text holds too many values') end
    end
    local function skipSpace() pos = src:find('[^ \t\r\n]', pos) or (#src + 1) end
    local function expect(ch)
        skipSpace()
        if src:sub(pos, pos) ~= ch then bad("expected '" .. ch .. "'") end
        pos = pos + 1
    end

    local function hex4()
        local digits = src:match('^%x%x%x%x', pos)
        if not digits then bad('broken \\u escape') end
        pos = pos + 4
        return tonumber(digits, 16)
    end

    local function readString()
        pos = pos + 1                          -- opening quote
        local parts = {}
        while true do
            local stop = src:find('["\\%c]', pos)
            if not stop then bad('unterminated string') end
            parts[#parts + 1] = src:sub(pos, stop - 1)
            local ch = src:sub(stop, stop)
            pos = stop + 1
            if ch == '"' then break end
            if ch ~= '\\' then bad('control character in string') end
            local esc = src:sub(pos, pos)
            pos = pos + 1
            if UNESCAPE[esc] then
                parts[#parts + 1] = UNESCAPE[esc]
            elseif esc == 'u' then
                local code = hex4()
                if code >= 0xD800 and code <= 0xDBFF then
                    if src:sub(pos, pos + 1) ~= '\\u' then bad('unpaired surrogate') end
                    pos = pos + 2
                    local low = hex4()
                    if low < 0xDC00 or low > 0xDFFF then bad('unpaired surrogate') end
                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                elseif code >= 0xDC00 and code <= 0xDFFF then
                    bad('unpaired surrogate')
                end
                parts[#parts + 1] = utf8(code)
            else
                bad('unknown escape')
            end
        end
        return table.concat(parts)
    end

    local function readNumber()
        -- JSON number: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
        local start = pos
        if src:sub(pos, pos) == '-' then pos = pos + 1 end
        local int = src:match('^%d+', pos)
        if not int then bad('number without digits') end
        if #int > 1 and int:sub(1, 1) == '0' then bad('leading zero') end
        pos = pos + #int
        if src:sub(pos, pos) == '.' then
            local frac = src:match('^%d+', pos + 1)
            if not frac then bad('number without fraction digits') end
            pos = pos + 1 + #frac
        end
        if src:find('^[eE]', pos) then
            local exp = src:match('^[eE][-+]?%d+', pos)
            if not exp then bad('number with an empty exponent') end
            pos = pos + #exp
        end
        local n = tonumber(src:sub(start, pos - 1))
        if not finite(n) then bad('number out of range') end
        return n
    end

    local readValue
    local function readObject(depth)
        pos = pos + 1
        local result, seen = {}, {}
        skipSpace()
        if src:sub(pos, pos) == '}' then pos = pos + 1; return result end
        while true do
            skipSpace()
            if src:sub(pos, pos) ~= '"' then bad('expected a quoted key') end
            local key = readString()
            if seen[key] then bad('duplicate key') end
            seen[key] = true
            count()
            expect(':')
            result[key] = readValue(depth)
            skipSpace()
            local ch = src:sub(pos, pos)
            pos = pos + 1
            if ch == '}' then return result end
            if ch ~= ',' then pos = pos - 1; bad("expected ',' or '}'") end
        end
    end

    local function readArray(depth)
        pos = pos + 1
        local result = {}
        skipSpace()
        if src:sub(pos, pos) == ']' then pos = pos + 1; return result end
        while true do
            result[#result + 1] = readValue(depth)
            skipSpace()
            local ch = src:sub(pos, pos)
            pos = pos + 1
            if ch == ']' then return result end
            if ch ~= ',' then pos = pos - 1; bad("expected ',' or ']'") end
        end
    end

    reader.arrays = setmetatable({}, {__mode = 'k'})
    function readValue(depth)
        skipSpace()
        count()
        local ch = src:sub(pos, pos)
        if ch == '{' or ch == '[' then
            if depth + 1 > MAX_DEPTH then fail('Settings text is nested too deeply') end
            if ch == '{' then return readObject(depth + 1) end
            local list = readArray(depth + 1)
            reader.arrays[list] = true
            return list
        end
        if ch == '"' then return readString() end
        if ch == '-' or ch:find('%d') then return readNumber() end
        if src:find('^true', pos) then pos = pos + 4; return true end
        if src:find('^false', pos) then pos = pos + 5; return false end
        if ch == '' then bad('unexpected end') end
        bad('unexpected character')
    end

    function reader.document()
        skipSpace()
        if src:sub(pos, pos) ~= '{' then bad('settings must be one object') end
        local root = readValue(0)
        skipSpace()
        if pos <= #src then bad('extra text after the settings') end
        return root
    end
    return reader
end

-- Arrays are only meaningful for section patterns; item-keyed maps get their number keys back.
local function shapeProfile(value, arrays, path)
    if type(value) ~= 'table' then return value end
    if arrays[value] and not isPatternList(path) and DICTIONARIES[path[1]] then
        fail('Settings text has a list where a setting expects a value or a dictionary')
    end
    if not arrays[value] and isPatternList(path) and next(value) ~= nil then
        fail('Section patterns must be a list')
    end
    local numericKeys = #path == 1 and NUMBER_KEYED[path[1]]
    local out = {}
    for k, v in next, value do
        path[#path + 1] = k
        local shaped = shapeProfile(v, arrays, path)
        path[#path] = nil
        if numericKeys and type(k) == 'string' and k:find('^[1-9]%d*$') and #k <= 10 then
            out[tonumber(k)] = shaped
        else
            out[k] = shaped
        end
    end
    return out
end

local function decode(text)
    if type(text) ~= 'string' then fail('Settings text must be a string') end
    if #text > MAX_BYTES then fail('Settings text is too long') end
    local body = text:match('^%s*(.-)%s*$')
    if body:sub(1, #OLD_PREFIX) == OLD_PREFIX then
        fail('This share code is from an older Baggler version; please export it again.')
    end
    if body:sub(1, #PREFIX) ~= PREFIX then fail('This is not a Baggler settings string') end
    local reader = newReader(body:sub(#PREFIX + 1))
    local root = reader.document()
    return shapeProfile(root, reader.arrays, {})
end
local function words(text)
    local set = {}; for word in text:gmatch('%S+') do set[word] = true end; return set
end
local numbers = {
    scale={0.6,1.6}, iconSize={28,52,true}, spacing={0,10,true},
    columns={6,24,true}, vendorColumns={4,12,true}, bgAlpha={0.3,1},
    fontScale={0.9,1.2}, lowSpaceAt={0,200,true},
}
local enums = {
    accent=words('class class_warrior class_paladin class_hunter class_rogue class_priest class_deathknight class_shaman class_mage class_warlock class_monk class_druid class_demonhunter class_evoker class_adventurer class_traveler ice violet emerald amber rose mono coral salmon peach apricot copper gold lemon chartreuse lime sage mint seafoam teal turquoise aqua sky azure periwinkle lavender lilac orchid mauve pink ruby'), font=words('game narrow classic'),
    cardSide=words('auto left right'), group=words('category type expansion bag bagtype none'),
    sort=words('quality name ilvl type recent'), emptyMode=words('collapse show hide'),
}
local bools = words('showBorders showIlvl alwaysCompare sellProtect askEquipSlot itemCard cardCompare autoUnfold rowWrap tooltipHints qualityFocus showBoE showUpgrade tintUnusable showNewGlow dimJunk showFooter showBagSlots locked showSubtype sectionCounts newSection favSection separateJunk junkAll showSets splitTradeGoods replaceGuildBank replaceTrainer ahSwitch nativeSwitch replaceLoot replaceMail replaceTrade replaceDefault replaceBank replaceVendor autoOpen autoSellJunk autoRepair lowSpaceWarn showAltCounts closeOnCombat animations highContrast reduceMotion sounds qualityMarks')
local collections = words('favorites junk pinTop pins collapsed views custom')
local buttons = words('PAD1 PAD2 PAD3 PAD4 PADLSHOULDER PADRSHOULDER PADLTRIGGER PADRTRIGGER PADLSTICK PADRSTICK PADBACK PADFORWARD')
local actions = words('use close pickup menu prevSection nextSection collapse filter sort favorite options sellJunk switchWindow quickMove')
local padEnums = {mode=words('auto on off'), backend=words('bindings catcher'), style=words('xbox playstation nintendo text')}
local function integer(n, low, high) return finite(n) and n >= low and n <= high and n % 1 == 0 end
local function str(s, low, high) return type(s) == 'string' and #s >= low and #s <= high end
local function member(set, v) return type(v) == 'string' and set[v] == true end
local function validCollection(name, value)
    if not plain(value) then return false end
    local count = 0
    for k,v in next, value do
        count = count + 1
        if count > (name == 'custom' and 200 or 5000) then return false end
        if name == 'custom' then
            if not str(k,1,100) or not plain(v) or not plain(v.patterns) then return false end
            for field in next,v do if field ~= 'patterns' and field ~= 'order' then return false end end
            if v.order ~= nil and not integer(v.order,0,10000) then return false end
            local n = 0
            for index, pattern in next,v.patterns do
                if not integer(index,1,100) or not str(pattern,1,200) then return false end
                n = n + 1
            end
            for i=1,n do if v.patterns[i] == nil then return false end end
        elseif name == 'collapsed' then
            if not str(k,1,200) or type(v) ~= 'boolean' then return false end
        elseif name == 'views' then
            if not str(k,1,100) or not str(v,0,1000) then return false end
        else
            if not integer(k,1,2147483647) then return false end
            if name == 'pins' then
                if not str(v,1,200) then return false end
            elseif type(v) ~= 'boolean' then return false end
        end
    end
    return true
end
local function selectPad(value, strict)
    if not plain(value) then
        if strict then fail('Invalid pad dictionary') end
        return nil
    end
    local out = {}
    for k,v in next,value do
        if k == 'map' and plain(v) then
            local map = {}; out.map = map
            for b,a in next,v do
                if member(buttons,b) and (a == false or member(actions,a)) then map[b] = a
                elseif strict then fail('Invalid pad map entry') end
            end
        elseif (padEnums[k] and member(padEnums[k],v)) or ((k == 'hints' or k == 'stickNav') and type(v) == 'boolean') then out[k] = v
        elseif strict then fail('Invalid pad field') end
    end
    return out
end
local function selectFields(profile, strict)
    local out = {}
    for k,v in next,profile do
        local valid, known = false, true
        if numbers[k] then
            local b = numbers[k]
            valid = finite(v) and v >= b[1] and v <= b[2] and (not b[3] or v % 1 == 0)
        elseif enums[k] then valid = member(enums[k],v)
        elseif bools[k] then valid = type(v) == 'boolean'
        elseif collections[k] then valid = validCollection(k,v)
        elseif k == 'pad' then out.pad = selectPad(v,strict); known = false
        else known = false end
        if known then
            if valid then out[k] = copy(v)
            elseif strict then fail('Invalid setting: ' .. tostring(k)) end
        end
    end
    return out
end
local function mergePad(base, patch)
    local out = copy(base or {})
    for k,v in pairs(patch) do
        if k == 'map' then
            if not plain(out.map) then out.map = {} end
            for b,a in pairs(v) do out.map[b] = a end
        else out[k] = v end
    end
    return out
end
function M.new(deps)
    deps = deps or {}
    local defaults = deps.padDefaults and selectPad(deps.padDefaults, true) or {}
    local api = {}
    function api:Export(profile)
        local ok, result = pcall(function()
            if not plain(profile) then fail('Profile must be a plain table') end
            return encode(selectFields(profile, false))
        end)
        if ok then return result end
        return nil, tostring(result)
    end
    function api:Import(text, current)
        local ok, result = pcall(function()
            if not plain(current) then fail('Current profile must be a plain table') end
            local accepted = selectFields(decode(text), true)
            local out = copy(current)
            for k,v in pairs(accepted) do
                if k == 'pad' then
                    out.pad = mergePad(mergePad(defaults, plain(current.pad) and current.pad or {}),v)
                else out[k] = copy(v) end
            end
            return out
        end)
        if ok then return result end
        return nil, tostring(result)
    end
    return api
end
return M

end)()
if type(namespace) == "table" then namespace.ProfileShare = unit end
return unit
