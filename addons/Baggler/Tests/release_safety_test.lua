-- Actual shipping TOC; deterministic offline boundary tests, not live permission tests.
-- Run: luajit addons/Baggler/Tests/release_safety_test.lua [import|export|seller]
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
-- Fixture writer for share texts (JSON object, keys in table order); a test aid, not the codec.
local function encode(v, list)
  if type(v) == 'table' then
    local out = {}
    if list then
      for i = 1, #v do out[i] = encode(v[i]) end
      return '[' .. table.concat(out, ',') .. ']'
    end
    for k, value in pairs(v) do
      out[#out+1] = encode(tostring(k)) .. ':' .. encode(value, k == 'patterns' and type(value) == 'table')
    end
    return '{' .. table.concat(out, ',') .. '}'
  elseif type(v) == 'string' then return '"' .. v:gsub('[%c"\\|]', function(ch) return ('\\u%04x'):format(ch:byte()) end) .. '"'
  elseif type(v) == 'boolean' then return tostring(v)
  elseif v ~= v then return 'NaN'
  elseif v == math.huge then return '1e9999'
  else return ('%.17g'):format(v) end
end
local function paste(v) return 'BAGGLER2:' .. encode(v) end
local mode = arg[1]
if not mode or mode == 'import' then
  local before = CB.Extras:Export()
  assert(before:sub(1, 9) == 'BAGGLER2:' and not before:find('|', 1, true) and not before:find('\n', 1, true))
  local ok, result = pcall(CB.Extras.Import, CB.Extras, paste({pad=false}))
  assert(ok and result == false, 'malformed pad must reject without throwing')
  assert(CB.Extras:Export() == before, 'rejected import must be atomic')
  local bad = {
    {scale=0}, {scale=1.7}, {columns=6.5}, {fontScale=0/0}, {bgAlpha=math.huge},
    {group='bogus'}, {pad={map={PAD1='bogus'}}}, {pad={map={INJECT='use'}}},
    {pad={hints='yes'}}, {custom={Bad={patterns=false}}},
    {custom={Bad={patterns={false},order=1}}}, {custom={Bad={patterns={'ok'},order=-1}}},
    {favorites={abc=true}}, {views={Bad=false}}, {pins={[123]=false}},
    {scale=1.1,custom={Bad={patterns={'ok'},order='first'}}},
  }
  for i, value in ipairs(bad) do
    assert(CB.Extras:Import(paste(value)) == false, 'reject bad schema case ' .. i)
    assert(CB.Extras:Export() == before, 'atomic rejection case ' .. i)
  end
  for _, text in ipairs({'{}junk', '{"scale":1}{}', '{"scale":1', '{"views":[', '{"views":{"a":"x}}',
      '{"scale":1,"scale":1}', '{"scale":NaN}', '{"scale":inf}', '{"scale":1e9999}', '{"scale":+1}', '{"scale":1.}',
      '{"scale":.1}', '{"scale":0x10}', '{"spacing":01}', '[]', '"x"',
      string.rep('{"x":',9)..'{}'..string.rep('}',9)}) do
    assert(CB.Extras:Import('BAGGLER2:'..text) == false, 'reject malformed grammar '..text)
    assert(CB.Extras:Export() == before)
  end
  assert(CB.Extras:Import(string.rep('x',200001)) == false)
  assert(CB.Extras:Import('BAGGLER2:{}' .. string.rep(' ', 200001 - 11)) == false, 'byte limit counts the whole paste')
  local many = {}
  for i=1,12501 do many[#many+1] = '"k'..i..'":true' end
  local broad = 'BAGGLER2:{' .. table.concat(many, ',') .. '}'
  assert(#broad < 200000 and CB.Extras:Import(broad) == false, 'value budget rejects broad tables within byte limit')
  assert(CB.Extras:Import(false) == false)
  local printed
  local realPrint = CB.Print
  CB.Print = function(_, text) printed = text end
  assert(CB.Extras:Import('BAGGLER1:{s5:scalen1.1;}') == false, 'older share codes are refused')
  CB.Print = realPrint
  assert(printed and printed:find('older Baggler version', 1, true), tostring(printed))
  assert(CB.Extras:Export() == before, 'older share code changes nothing')
  local oldUse, oldStyle = CB.db.pad.map.PAD1, CB.db.pad.style
  assert(CB.Extras:Import(paste({scale=1.1,pad={map={PAD2=false}},
    custom={Herbs={patterns={'herb'},order=1}},favorites={[123]=true},pins={[123]='Herbs'},views={Herbs='herb'}})))
  assert(CB.db.scale == 1.1 and CB.db.pad.map.PAD2 == false)
  assert(CB.db.pad.map.PAD1 == oldUse and CB.db.pad.style == oldStyle, 'partial pad merges safely')
  assert(CB.db.custom.Herbs.patterns[1] == 'herb' and CB.db.favorites[123] == true and CB.db.pins[123] == 'Herbs')
  local again = CB.Extras:Export()
  assert(again == CB.Extras:Export(), 'export is byte-stable')
  assert(CB.Extras:Import(again) and CB.Extras:Export() == again, 'valid settings round trip')
  print('PASS strict data grammar, recursive schema, ranges, atomic rejection and partial pad merge')
end
if not mode or mode == 'export' then
  for _, key in ipairs({'journal','log','chars','account','runtimeSecret','personalBankRestored1','holdHints','point','off'}) do
    CB.db[key] = {private='DO_NOT_SHARE_'..key}
  end
  CB.db.pad.private = 'PAD_PRIVATE'; CB.db.pad.map.UNKNOWN = 'MAP_PRIVATE'
  CB.db.scale = 1.05; CB.db.views.Safe = 'herb'; CB.db.favorites[123] = true
  local text = CB.Extras:Export()
  assert(not text:find('DO_NOT_SHARE',1,true), 'export excludes journal, snapshots and unknown debris')
  assert(not text:find('PAD_PRIVATE',1,true) and not text:find('MAP_PRIVATE',1,true), 'nested allowlist')
  assert(text:find('Safe',1,true) and text:find('herb',1,true), 'saved searches preserved')
  assert(CB.Extras:Import(text) and CB.db.scale == 1.05 and CB.db.favorites[123], 'shareable settings round trip')
  local saved = {favorites=CB.db.favorites,junk=CB.db.junk,pinTop=CB.db.pinTop,views=CB.db.views}
  CB.db.favorites, CB.db.junk = {}, {}
  for i=1,5000 do CB.db.favorites[i]=true; CB.db.junk[i+5000]=true end
  local aggregate = assert(CB.Extras:Export())
  assert(CB.Extras:Import(aggregate), 'maximum favorites plus junk aggregate must round trip')
  assert(CB.db.favorites[5000] and CB.db.junk[10000], 'aggregate preserves both maps completely')
  CB.db.pinTop = {}
  for i=1,5000 do CB.db.pinTop[i]=true end
  local ok, overflow, reason = pcall(CB.Extras.Export, CB.Extras)
  assert(ok and overflow == nil and type(reason)=='string' and #reason>0, 'value overflow fails explicitly without throwing or truncation')
  local shown, highlighted, focused, hidden = nil, false, false, false
  local popup = {editBox={SetText=function(_,v) assert(type(v)=='string'); shown=v end,
    HighlightText=function() highlighted=true end, SetFocus=function() focused=true end},
    Hide=function() hidden=true end}
  local uiOK = pcall(StaticPopupDialogs.BAGGLER_EXPORT.OnShow, popup)
  assert(uiOK and shown=='' and hidden and not highlighted and not focused, 'failed export UI clears stale text and closes safely')
  CB.db.pinTop = saved.pinTop
  CB.db.views = {}
  for i=1,250 do CB.db.views['Search'..i]=string.rep('x',1000) end
  overflow, reason = CB.Extras:Export()
  assert(overflow == nil and type(reason)=='string', 'byte overflow fails gracefully')
  for k,v in pairs(saved) do CB.db[k]=v end
  shown, highlighted, focused, hidden = nil, false, false, false
  StaticPopupDialogs.BAGGLER_EXPORT.OnShow(popup)
  assert(shown==CB.Extras:Export() and highlighted and focused and not hidden, 'normal export UI remains copyable')
  print('PASS private settings excluded; maximum aggregate round trip; value/byte overflow and export UI fail gracefully')
end
if not mode or mode == 'seller' then
  MerchantFrame = CreateFrame('Frame', 'MerchantFrame', UIParent); MerchantFrame:Show()
  local tick, uses, messages, current = nil, {}, {}, nil
  local cursorBusy, clears = false, 0
  CursorHasItem = function() return cursorBusy end
  ClearCursor = function() clears=clears+1; cursorBusy=false end
  CB.Print = function(_, text) messages[#messages+1] = text end
  C_Timer.NewTicker = function(_, fn, count)
    tick = {fn=fn,count=count}; function tick:Cancel() self.cancelled=true end; return tick
  end
  C_Container.UseContainerItem = function(bag,slot) uses[#uses+1] = {bag,slot} end
  C_Container.GetContainerItemInfo = function() return current end
  local rec = {itemID=101,link='item:101',quality=0,bag=0,slot=1,count=2,sellPrice=3}
  CB.Inventory.Scan = function() return {rec} end
  local function start()
    CB.db.favorites={}; CB.db.junk={}; MerchantFrame:Show()
    InCombatLockdown=function() return false end
    current={itemID=101,hyperlink='item:101',quality=0,stackCount=2}
    CB.Integrations:SellJunk(true)
  end
  start(); current.itemID=999; tick.fn(tick)
  assert(#uses==0, 'changed slot must never be used')
  local cases = {
    function() current=nil end, function() current.isLocked=true end,
    function() current.hyperlink='item:101:variant' end, function() current.stackCount=3 end,
    function() CB.db.favorites[101]=true end, function() current.hasNoValue=true end,
    function() current.quality=1 end, function() MerchantFrame:Hide() end,
    function() InCombatLockdown=function() return true end end,
    function() current.stackCount=0 end,
  }
  for i, mutate in ipairs(cases) do start(); mutate(); tick.fn(tick); assert(#uses==0,'unsafe queued case '..i) end
  start(); rec.itemID=999; tick.fn(tick); assert(#uses==1, 'queue must snapshot records, not share mutable scan table')
  rec.itemID=101
  start(); current.stackCount=1; tick.fn(tick); assert(#uses==2, 'decreased quantity within queued bound allowed')
  start(); current.quality=4; CB.db.junk[101]=true; tick.fn(tick)
  assert(#uses==3, 'explicit junk marking keeps deliberate epic/set override policy')
  for _, text in ipairs(messages) do assert(not text:find('sold ',1,true), 'scheduled requests must not claim confirmed sales') end
  start(); event('MERCHANT_CLOSED'); assert(tick.cancelled)
  MerchantFrame:Hide(); local old=tick; CB.Integrations:SellJunk(true); assert(tick==old,'no queue away from native merchant')
  start(); cursorBusy=true; tick.fn(tick)
  assert(tick.cancelled and #uses==3 and cursorBusy, 'cursor occupied after queue cancels before any use without clearing')
  cursorBusy=false
  CB.Inventory.Scan = function() return {rec, {itemID=101,link='item:101',quality=0,bag=0,slot=2,count=2}} end
  start(); tick.fn(tick); assert(#uses==4, 'first tick may sell with empty cursor')
  cursorBusy=true; tick.fn(tick)
  assert(tick.cancelled and #uses==4 and cursorBusy, 'every tick checks cursor, including after a sale request')
  cursorBusy=false; start(); old=tick; cursorBusy=true
  CB.Integrations:SellJunk(true)
  assert(tick==old and old.cancelled and #uses==4, 'occupied cursor at manual start cancels pending seller without replacement')
  CB.db.autoSellJunk=true
  event('MERCHANT_SHOW')
  assert(tick==old and cursorBusy and clears==0, 'auto-sell must not start or clear an occupied cursor')
  cursorBusy=false; CB.Integrations:SellJunk(true); tick.fn(tick)
  assert(#uses==5, 'explicit restart after cursor is empty still works')
  print('PASS queued seller identity, locks, eligibility, quantity bounds, native context, cursor cancellation and honest reporting')
end
print('ALL PASS release safety (offline only)')
