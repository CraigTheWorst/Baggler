-- Loader envelope: publishes the standalone module below (also kept as
-- Tests/Independent/comparison/EquippedCompare.lua) on the Baggler namespace.
local addonName, namespace = ...
local unit = (function()
-- Lua 5.1 data-only module. No globals, frames, event handlers or equipment writes.
local EquippedCompare = {}
local Service = {}
Service.__index = Service

-- Equipment-location families translated to documented inventory-slot names.
-- Numeric IDs are always obtained from the host client, never assumed here.
local positions = {
    HEAD='HEADSLOT', NECK='NECKSLOT', SHOULDER='SHOULDERSLOT',
    BODY='SHIRTSLOT', CHEST='CHESTSLOT', ROBE='CHESTSLOT',
    WAIST='WAISTSLOT', LEGS='LEGSSLOT', FEET='FEETSLOT',
    WRIST='WRISTSLOT', HAND='HANDSSLOT', CLOAK='BACKSLOT',
    TABARD='TABARDSLOT', WEAPONMAINHAND='MAINHANDSLOT',
    ['2HWEAPON']='MAINHANDSLOT', WEAPONOFFHAND='SECONDARYHANDSLOT',
    SHIELD='SECONDARYHANDSLOT', HOLDABLE='SECONDARYHANDSLOT',
    RANGED='RANGEDSLOT', RANGEDRIGHT='RANGEDSLOT',
    THROWN='RANGEDSLOT', RELIC='RANGEDSLOT',
}

local function invoke(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
end

local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for k,v in pairs(value) do result[k] = copy(v) end
    return result
end

function EquippedCompare.new(dependencies)
    return setmetatable({host=dependencies or {}}, Service)
end

function Service:Slots(equipLoc, purpose)
    local names = {}
    local family = type(equipLoc)=='string' and equipLoc:match('^INVTYPE_(.+)$')
    if family == 'FINGER' or family == 'TRINKET' then
        names = {family..'0SLOT', family..'1SLOT'}
    elseif family == 'WEAPON' then
        names = {'MAINHANDSLOT'}
        if purpose ~= 'upgrade' then names[2] = 'SECONDARYHANDSLOT' end
    elseif positions[family] then
        names[1] = positions[family]
    end
    local slots, seen = {}, {}
    for _,name in ipairs(names) do
        local id = invoke(self.host.getInventorySlotInfo, name)
        if type(id)=='number' and id>=0 and id%1==0 and not seen[id] then
            slots[#slots+1] = id
            seen[id] = true
        end
    end
    return slots
end

local function nativeIdentity(value)
    return type(value)=='table' and type(value.guid)=='string' and value.guid~=''
end

-- A normalized host plan avoids depending on undocumented info-field ordering.
-- Paired equipped stats subtract; paired bag stats add to the candidate.
local function delta(host, candidate, alternative, alternatives)
    if not nativeIdentity(candidate.native) or not nativeIdentity(alternative.item.native) then return nil end
    local plan = invoke(host.comparisonPlan, copy(candidate), copy(alternative), copy(alternatives))
    if type(plan)~='table' then return nil end
    local paired, add
    if plan.method=='Single' or plan.method==0 then
        paired, add = nil, nil
    elseif plan.method=='WithBothHands' or plan.method==1 then
        paired, add = plan.pairedItem, false
    elseif plan.method=='WithBagMainHandItem' or plan.method==2 or
           plan.method=='WithBagOffHandItem' or plan.method==3 then
        paired, add = plan.pairedItem, true
    else
        return nil
    end
    if add~=nil and not nativeIdentity(paired) then return nil end
    local lines = invoke(host.getItemComparisonDelta, copy(candidate.native),
        copy(alternative.item.native), copy(paired), add)
    if type(lines)~='table' then return nil end
    local output = {}
    for _,text in ipairs(lines) do
        if type(text)=='string' then
            local plain = text:gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r','')
            local prefix = plain:match('^%s*([+%-])%s*%d')
            local sign = prefix=='+' and 'positive' or prefix=='-' and 'negative' or 'neutral'
            output[#output+1] = {text=text, sign=sign}
        end
    end
    if #output>0 then return {slot=alternative.slot, lines=output} end
end

function Service:Compare(candidate, gates)
    candidate = candidate or {}
    gates = gates or {}
    local result = {candidate=copy(candidate), slots={}, alternatives={}, deltas={},
        primary=gates.cardEnabled~=false, empty=false}
    if not result.primary or gates.compareEnabled==false or gates.noCompare or candidate.noCompare then
        return result
    end
    result.slots = self:Slots(candidate.equipLoc, 'card')
    for _,slot in ipairs(result.slots) do
        local data = invoke(self.host.readWorn, slot)
        if type(data)=='table' and type(data.link)=='string' and data.link~='' then
            result.alternatives[#result.alternatives+1] = {slot=slot, item=copy(data)}
        end
    end
    result.empty = #result.slots>0 and #result.alternatives==0
    for _,alternative in ipairs(result.alternatives) do
        local entry = delta(self.host, candidate, alternative, result.alternatives)
        if entry then result.deltas[#result.deltas+1] = entry end
    end
    return result
end

local function levelKnown(value)
    return type(value)=='number' and value==value and value>1 and value<math.huge
end

-- A deliberately limited indicator, not a score, equip recommendation or mutation.
function Service:IsUpgrade(candidate)
    if type(candidate)~='table' or type(candidate.link)~='string' or candidate.link=='' then return false end
    if candidate.classID~=2 and candidate.classID~=4 then return false end
    if type(candidate.quality)~='number' or not (candidate.quality>1) or candidate.usable~=true then return false end
    if not levelKnown(candidate.ilvl) then return false end
    if invoke(self.host.eligible, copy(candidate))~=true then return false end
    local slots = self:Slots(candidate.equipLoc, 'upgrade')
    if #slots==0 then return false end
    -- Capability presence, not a truthy response, determines authority.
    if self.host.nativeUpgrade~=nil then
        return invoke(self.host.nativeUpgrade, copy(candidate))==true
    end
    for _,slot in ipairs(slots) do
        local worn = invoke(self.host.readWorn, slot)
        if type(worn)=='table' then
            if worn.empty==true and worn.link==nil then return true end
            if type(worn.link)=='string' and worn.link~='' and
               levelKnown(worn.ilvl) and candidate.ilvl>worn.ilvl then return true end
        end
    end
    return false
end

return EquippedCompare

end)()
if type(namespace) == "table" then namespace.EquippedCompare = unit end
return unit
