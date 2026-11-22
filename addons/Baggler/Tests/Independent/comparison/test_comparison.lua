local function eq(a,b) assert(a == b, tostring(a)..' ~= '..tostring(b)) end
local module = loadfile('EquippedCompare.lua')
assert(module, 'comparison service is not implemented')
local allowed = {pairs=pairs, ipairs=ipairs, type=type, pcall=pcall,
    setmetatable=setmetatable, math=math}
setfenv(module, setmetatable({}, {__index=function(_,key)
    if allowed[key] then return allowed[key] end
    error('Unexpected client/global API: '..tostring(key))
end, __newindex=function(_,key) error('Unexpected global write: '..tostring(key)) end}))
local Compare = module()
local tests = {}
local function test(name, f) tests[#tests+1] = {name, f} end
local function fixture()
    local names = {'HEADSLOT','NECKSLOT','SHOULDERSLOT','SHIRTSLOT','CHESTSLOT','WAISTSLOT','LEGSSLOT','FEETSLOT','WRISTSLOT','HANDSSLOT','FINGER0SLOT','FINGER1SLOT','TRINKET0SLOT','TRINKET1SLOT','BACKSLOT','MAINHANDSLOT','SECONDARYHANDSLOT','RANGEDSLOT','TABARDSLOT'}
    local ids, worn = {}, {}
    for i,name in ipairs(names) do ids[name] = i + 100 end
    local deps = {
        getInventorySlotInfo = function(name) return ids[name] end,
        readWorn = function(slot) return worn[slot] or {empty=true} end,
    }
    return deps, ids, worn
end
local function item(loc, level) return {link='candidate', equipLoc=loc, ilvl=level or 100} end

test('C01 documented slot families, two alternatives, unavailable and empty', function()
    local d, ids, w = fixture()
    local s = Compare.new(d)
    local families = {HEAD='HEADSLOT',NECK='NECKSLOT',SHOULDER='SHOULDERSLOT',BODY='SHIRTSLOT',CHEST='CHESTSLOT',ROBE='CHESTSLOT',WAIST='WAISTSLOT',LEGS='LEGSSLOT',FEET='FEETSLOT',WRIST='WRISTSLOT',HAND='HANDSSLOT',CLOAK='BACKSLOT',TABARD='TABARDSLOT',WEAPONMAINHAND='MAINHANDSLOT',['2HWEAPON']='MAINHANDSLOT',WEAPONOFFHAND='SECONDARYHANDSLOT',SHIELD='SECONDARYHANDSLOT',HOLDABLE='SECONDARYHANDSLOT',RANGED='RANGEDSLOT',RANGEDRIGHT='RANGEDSLOT',THROWN='RANGEDSLOT',RELIC='RANGEDSLOT'}
    for loc, name in pairs(families) do
        local r = s:Compare(item('INVTYPE_'..loc))
        eq(r.slots[1],ids[name]); eq(r.empty,true); eq(#r.alternatives,0)
    end
    for _, loc in ipairs({'FINGER','TRINKET','WEAPON'}) do
        local r = s:Compare(item('INVTYPE_'..loc))
        eq(#r.slots,2)
        w[r.slots[1]]={link='same',ilvl=80}; w[r.slots[2]]={link='same',ilvl=90}
        r=s:Compare(item('INVTYPE_'..loc)); eq(#r.alternatives,2)
        -- Same item link in distinct equipment slots represents two real items.
        w[r.slots[2]]={empty=true}
        r=s:Compare(item('INVTYPE_'..loc)); eq(#r.alternatives,1); eq(r.empty,false)
    end
    ids.RANGEDSLOT=nil
    eq(#s:Compare(item('INVTYPE_RELIC')).slots,0)
    d.readWorn=function() error('unreadable') end
    eq(s:Compare(item('INVTYPE_HEAD')).empty,true)
end)

test('C02 gates return fresh empty comparisons without suppressing primary', function()
    local d, ids, w = fixture(); local s=Compare.new(d)
    w[ids.HEADSLOT]={link='helm'}
    eq(#s:Compare(item('INVTYPE_HEAD')).alternatives,1)
    for _, gates in ipairs({{cardEnabled=false},{compareEnabled=false},{noCompare=true}}) do
        local r=s:Compare(item('INVTYPE_HEAD'),gates)
        eq(#r.alternatives,0); eq(#r.deltas,0)
        eq(r.primary,gates.cardEnabled~=false)
    end
    eq(#s:Compare(item('INVTYPE_NON_EQUIP')).alternatives,0)
end)

test('C03 native method pairing, failure and localized delta preservation', function()
    local d, ids, w=fixture(); local s=Compare.new(d)
    w[ids.MAINHANDSLOT]={link='worn',native={guid='equipped'}}
    local c=item('INVTYPE_WEAPONMAINHAND'); c.native={guid='candidate'}
    local method, calls='Single',0
    d.comparisonPlan=function(candidate, alternative)
        eq(candidate.link,'candidate'); eq(alternative.item.link,'worn')
        return {method=method, pairedItem={guid='pair'}}
    end
    d.getItemComparisonDelta=function(candidate,equipped,paired,add)
        calls=calls+1
        eq(candidate.guid,'candidate'); eq(equipped.guid,'equipped')
        if method=='Single' then eq(paired,nil); eq(add,nil)
        else eq(paired.guid,'pair'); eq(add,method~='WithBothHands') end
        return {'+12 Stärke','-7 Hâte','没有变化','|cff00ff00+3 Crit|r'}
    end
    for _, m in ipairs({'Single','WithBothHands','WithBagMainHandItem','WithBagOffHandItem'}) do
        method=m
        local r=s:Compare(c)
        eq(#r.deltas,1); eq(r.deltas[1].lines[1].text,'+12 Stärke')
        eq(r.deltas[1].lines[1].sign,'positive')
        eq(r.deltas[1].lines[2].sign,'negative')
        eq(r.deltas[1].lines[3].sign,'neutral')
        eq(r.deltas[1].lines[4].text,'|cff00ff00+3 Crit|r')
        eq(r.deltas[1].lines[4].sign,'positive')
    end
    eq(calls,4)
    method='Unknown'; eq(#s:Compare(c).deltas,0)
    method='Single'
    d.getItemComparisonDelta=function() error('native error') end
    local r=s:Compare(c); eq(#r.deltas,0); eq(#r.alternatives,1)
    d.getItemComparisonDelta=function() return nil end
    eq(#s:Compare(c).deltas,0)
    d.comparisonPlan=function() error('info unavailable') end
    eq(#s:Compare(c).deltas,0)
    d.comparisonPlan=nil; d.getItemComparisonDelta=nil
    eq(#s:Compare(c).deltas,0)
end)

test('C04 snapshots never reuse selection or equipment data', function()
    local d,ids,w=fixture(); local s=Compare.new(d)
    local c=item('INVTYPE_HEAD'); c.link='first'; c.native={guid='first'}
    w[ids.HEADSLOT]={link='old',native={guid='old'}}
    d.comparisonPlan=function() return {method='Single'} end
    d.getItemComparisonDelta=function(a,b) return {a.guid..' versus '..b.guid} end
    local first=s:Compare(c)
    eq(first.deltas[1].lines[1].text,'first versus old')
    c.link='next'; c.native.guid='next'
    w[ids.HEADSLOT]={link='new',native={guid='new'}}
    local nextResult=s:Compare(c)
    eq(nextResult.deltas[1].lines[1].text,'next versus new')
    eq(first.candidate.link,'first'); eq(first.alternatives[1].item.link,'old')
    nextResult.alternatives[1].item.native.guid='tamper'
    eq(s:Compare(c).alternatives[1].item.native.guid,'new')
    w[ids.HEADSLOT]={empty=true}
    eq(#s:Compare(c).deltas,0)
    -- The service has no scheduling or visibility side effects. Parent owns hide cancellation.
    eq(#s:Compare(c,{cardEnabled=false}).alternatives,0)
end)

test('C05 upgrade capability is authoritative; fallback conservative', function()
    local d,ids,w=fixture(); local s=Compare.new(d)
    local c=item('INVTYPE_HEAD'); c.quality=3; c.usable=true; c.classID=4
    d.eligible=function(v) return v.family~='wrong' and v.requiredLevel~=999 end
    w[ids.HEADSLOT]={link='helm',ilvl=90}
    eq(s:IsUpgrade(c),true)
    d.nativeUpgrade=function() return false end; eq(s:IsUpgrade(c),false)
    d.nativeUpgrade=function() error('upgrade API failed') end; eq(s:IsUpgrade(c),false)
    d.nativeUpgrade=function() return nil end; eq(s:IsUpgrade(c),false)
    d.nativeUpgrade=function() return true end; eq(s:IsUpgrade(c),true)
    c.quality=0; eq(s:IsUpgrade(c),false); c.quality=3
    c.usable=false; eq(s:IsUpgrade(c),false); c.usable=true
    c.family='wrong'; eq(s:IsUpgrade(c),false); c.family=nil
    c.requiredLevel=999; eq(s:IsUpgrade(c),false); c.requiredLevel=nil
    d.nativeUpgrade=nil
    for _,level in ipairs({1,80,90}) do c.ilvl=level; eq(s:IsUpgrade(c),false) end
    c.ilvl=100
    w[ids.HEADSLOT]={empty=true}; eq(s:IsUpgrade(c),true)
    w[ids.HEADSLOT]={link='unreadable level'}; eq(s:IsUpgrade(c),false)
    w[ids.HEADSLOT]=nil; d.readWorn=function() return nil end; eq(s:IsUpgrade(c),false)
    d.readWorn=function(slot) return w[slot] or {empty=true} end
    c.equipLoc='INVTYPE_FINGER'; w[ids.FINGER0SLOT]={link='strong',ilvl=120}
    w[ids.FINGER1SLOT]={link='weak',ilvl=80}; eq(s:IsUpgrade(c),true)
    w[ids.FINGER1SLOT].ilvl=100; eq(s:IsUpgrade(c),false)
    c.equipLoc='INVTYPE_WEAPON'; c.classID=2
    w[ids.MAINHANDSLOT]={link='main',ilvl=120}; w[ids.SECONDARYHANDSLOT]={link='off',ilvl=20}
    eq(s:IsUpgrade(c),false)
    c.equipLoc='INVTYPE_WEAPONOFFHAND'; eq(s:IsUpgrade(c),true)
    c.ilvl=nil; eq(s:IsUpgrade(c),false); c.ilvl=100
    c.link=nil; eq(s:IsUpgrade(c),false); c.link='candidate'
    c.classID=15; eq(s:IsUpgrade(c),false); c.classID=2
    d.eligible=nil; eq(s:IsUpgrade(c),false)
end)

test('C01 duplicate client aliases do not duplicate an alternative', function()
    local d,ids,w=fixture(); local s=Compare.new(d)
    ids.FINGER1SLOT=ids.FINGER0SLOT
    w[ids.FINGER0SLOT]={link='ring'}
    eq(#s:Compare(item('INVTYPE_FINGER')).alternatives,1)
    d.getInventorySlotInfo=function() error('unsupported client slot') end
    eq(#s:Compare(item('INVTYPE_HEAD')).slots,0)
end)

test('C03 invalid paired identity and unknown native method never invent delta', function()
    local d,ids,w=fixture(); local s=Compare.new(d)
    local c=item('INVTYPE_HEAD'); c.native={guid='candidate'}
    w[ids.HEADSLOT]={link='worn',native={guid='worn'}}
    local calls=0
    d.getItemComparisonDelta=function() calls=calls+1; return {'+1 Stat'} end
    for _,method in ipairs({1,2,3,99}) do
        d.comparisonPlan=function() return {method=method} end
        eq(#s:Compare(c).deltas,0)
    end
    eq(calls,0)
    d.comparisonPlan=function() return {method=0} end
    eq(#s:Compare(c).deltas,1); eq(calls,1)
end)

test('C05 unknown worn data, nonfinite levels and bad capabilities fail closed', function()
    local d,ids,w=fixture(); local s=Compare.new(d)
    local c=item('INVTYPE_TRINKET'); c.classID=4; c.quality=2; c.usable=true
    d.eligible=function() return true end
    w[ids.TRINKET0SLOT]={link='high',ilvl=110}; w[ids.TRINKET1SLOT]={link='low',ilvl=95}
    eq(s:IsUpgrade(c),true)
    w[ids.TRINKET1SLOT]={link='unknown'}; eq(s:IsUpgrade(c),false)
    w[ids.TRINKET1SLOT]={empty=true}; eq(s:IsUpgrade(c),true)
    d.nativeUpgrade=false; eq(s:IsUpgrade(c),false)
    d.nativeUpgrade=nil
    for _,level in ipairs({math.huge,-math.huge,0/0}) do c.ilvl=level; eq(s:IsUpgrade(c),false) end
    c.ilvl=100; d.eligible=function() error('unknown class') end
    eq(s:IsUpgrade(c),false)
end)

for _, t in ipairs(tests) do t[2](); print('PASS '..t[1]) end
print('PASS '..#tests..' test groups')
