-- Newly authored native-data normalization fixtures, not copied UI implementation.
dofile('tests/harness/ca_stubs.lua')
local CB={}
for _,name in ipairs({'EquippedCompare','ComparisonHost'}) do assert(loadfile('addons/Baggler/'..name..'.lua'))('Baggler',CB) end
local equipment={[11]={link='worn:a',guid='a',ilvl=20},[12]={link='worn:b',guid='b',ilvl=30}}
function GetInventoryItemLink(_,slot) return equipment[slot] and equipment[slot].link end
function GetInventoryItemID(_,slot) return equipment[slot] and 7 end
C_Item.GetDetailedItemLevelInfo=function(link) for _,item in pairs(equipment) do if item.link==link then return item.ilvl end end;return 40 end
C_TooltipInfo={GetInventoryItem=function(_,slot) local item=equipment[slot];return item and {guid=item.guid,lines={{leftText=item.link}}} end}
local info,calls
C_TooltipComparison={
 GetItemComparisonInfo=function(candidate) assert(candidate.guid=='candidate');return info end,
 GetItemComparisonDelta=function(candidate,worn,paired,add)
  calls[#calls+1]={candidate.guid,worn.guid,paired and paired.guid,add}
  return {'+4 Strength','-2 Agility','Localized neutral'}
 end,
}
local service=CB.ComparisonHost:New(function() return true end)
local candidate={link='candidate',equipLoc='INVTYPE_FINGER',native={guid='candidate'}}
for method=0,3 do
 calls={}
 info={method=method,item={guid='a'},additionalItems={{guid=method==0 and 'b' or 'partner'}}}
 local result=service:Compare(candidate)
 assert(#result.alternatives==2,'rings must retain both actual equipped instances')
 assert(#calls==(method==0 and 2 or 1),'only Single has independent secondary deltas')
 for _,call in ipairs(calls) do
  assert(call[1]=='candidate','current candidate identity must reach native delta')
  if method==0 then assert(call[3]==nil,'Single must discard pairing')
  else assert(call[3]=='partner','native partner selection') end
  if method==1 then assert(call[4]==false,'equipped partner must subtract') end
  if method>=2 then assert(call[4]==true,'bag partner must add') end
 end
 assert(result.deltas[1].lines[1].sign=='positive' and result.deltas[1].lines[2].sign=='negative')
end
info={method=99,item={guid='a'},additionalItems={}}
calls={};assert(#service:Compare(candidate).deltas==0 and #calls==0,'unknown method must not invent a plan')
C_TooltipComparison.GetItemComparisonInfo=function() error('not available') end
assert(#service:Compare(candidate).alternatives==2,'native data failure must retain readable worn cards')
equipment[11]={guid='loading'}
assert(CB.ComparisonHost:Worn(11)==nil,'occupied slot with unavailable link is unknown, not empty')
equipment[11]=nil
assert(CB.ComparisonHost:Worn(11).empty==true,'confirmed empty slot is distinguishable')
print('PASS native Single/both-hands/bag-hand normalization, no duplicate aggregate, failure and loading semantics')
