-- Baggler comparison host: connects EquippedCompare to the game's tooltip
-- comparison API. API reference: Blizzard TooltipComparisonDocumentation and
-- TooltipComparisonManager (wow-ui-source bebcb6bf309cf41b41bd74f8ca651e6a105b2676).
local _, CB = ...
local Host = {}
CB.ComparisonHost = Host

local function attempt(fn, ...)
  if type(fn) ~= 'function' then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
end
function Host:Level(link)
  local api = C_Item or {}
  local level = attempt(api.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo, link)
  if level then return level end
  local info = api.GetItemInfo or GetItemInfo
  if info then
    local ok, _, _, _, value = pcall(info, link)
    if ok then return value end
  end
end
function Host:Identity(data)
  if type(data)=='table' and type(data.guid)=='string' and data.guid~='' then
    return {guid=data.guid, overrideItemLevel=data.overrideItemLevel}
  end
end
function Host:Worn(slot)
  if not GetInventoryItemLink then return nil end
  local ok, link = pcall(GetInventoryItemLink, 'player', slot)
  if not ok then return nil end
  if not link then
    -- A nil hyperlink can mean item data is loading. Only a readable empty
    -- inventory identity authorizes the fallback's empty-slot upgrade result.
    if type(GetInventoryItemID)~='function' then return nil end
    local readable, id=pcall(GetInventoryItemID,'player',slot)
    if readable and id==nil then return {empty=true} end
    return nil
  end
  local data = attempt(C_TooltipInfo and C_TooltipInfo.GetInventoryItem,'player',slot)
  return {link=link, ilvl=self:Level(link), native=self:Identity(data),
    data=data, icon=attempt(GetInventoryItemTexture,'player',slot)}
end

-- Native Single describes independent equipped alternatives. Combined methods
-- describe one aggregate: info.item is the equipped anchor; additionalItems[1]
-- is the first native-selected partner (equipped subtraction or bag addition).
-- Do not repeat that aggregate on a secondary equipped card. There is no custom
-- scoring, guessed pairing by item level, protected CompareItem call, or cache.
function Host:Plan(candidate, alternative)
  local info = attempt(C_TooltipComparison and C_TooltipComparison.GetItemComparisonInfo,candidate.native)
  if type(info)~='table' or type(info.item)~='table' then return nil end
  local guid = alternative.item.native and alternative.item.native.guid
  if not guid then return nil end
  local method = info.method
  if method==0 then
    local applicable = info.item.guid==guid
    for _, item in ipairs(info.additionalItems or {}) do
      if item.guid==guid then applicable=true end
    end
    if applicable then return {method=0} end
  elseif method==1 or method==2 or method==3 then
    if info.item.guid~=guid then return nil end
    local partner = info.additionalItems and info.additionalItems[1]
    if type(partner)=='table' and type(partner.guid)=='string' then
      return {method=method,pairedItem=partner}
    end
  end
end
function Host:New(eligible)
  local native = (C_Container and C_Container.IsContainerItemAnUpgrade) or IsContainerItemAnUpgrade
  return CB.EquippedCompare.new({
    getInventorySlotInfo=function(name)
      -- A removed ranged family must not be resurrected by a numeric fallback.
      return attempt(GetInventorySlotInfo,name)
    end,
    readWorn=function(slot) return self:Worn(slot) end,
    eligible=eligible,
    nativeUpgrade=native and function(candidate) return native(candidate.bag,candidate.slot) end or nil,
    comparisonPlan=function(...) return self:Plan(...) end,
    getItemComparisonDelta=function(...)
      return attempt(C_TooltipComparison and C_TooltipComparison.GetItemComparisonDelta,...)
    end,
  })
end
