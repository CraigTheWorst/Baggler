-- Actual shipping TOC; offline classification, not in-game certification.
-- Factual fixture pinned to research 2026-11-14; no guide prose or addon code copied.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, n, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
CB.db.group = 'category'; CB.db.newSection = false
local function rec(id, class, sub)
  return { itemID=id, classID=class or 15, subID=sub or 0, quality=1,
    nameLower='objet localisé', count=1, bag=0, slot=1 }
end
assert(CB.Categories:Classify(rec(4470)) == 'Camping', 'Simple Wood 4470 must default to Camping, not Other/Miscellaneous')
-- Exhaustive factual allowlist; intentionally independent of the runtime table.
local expected = {
  4470,4471,11291,272941,273085,273086,273087,273092,273096,273097,273098,273099,
  273101,273102,273103,273105,273106,273109,273112,273113,273115,273116,273117,
  273118,273119,273120,273121,273122,273124,273125,273127,273128,273129,273130,
  273131,273141,278030,279938,279940,279941,279943,279944,279945,279947,279948,
  279949,279950,279951,279952,279955,279956,279957,279959,279960,279961,279962,
  279964,279965,279966,279967,279968,279969,279970,279972,279973,279974,279976,
  279978,279979,279981,279982,279985,279987,279988,279989,279990,
}
local seen = {}
for _, id in ipairs(expected) do
  assert(not seen[id], 'duplicate fixture ID'); seen[id] = true
  for _, class in ipairs({0,5,7,9,15}) do
    local name, order = CB.Categories:Classify(rec(id, class))
    assert(name == 'Camping' and order == 56, 'Camping inventory ID ' .. id .. ' class ' .. class)
  end
  assert(CB.Categories:Classify({itemID=id,quality=1}) == 'Camping', 'works before name/class cache fills')
end
assert(#expected == 76)
local count = 0
for id in pairs(CB.CampingData) do
  count = count + 1; assert(seen[id], 'unexpected Camping ID ' .. id)
end
assert(count == 76, 'exact runtime membership')
local destinations = CB.Categories:Destinations()
local found = false
for _, name in ipairs(destinations) do if name == 'Camping' then found = true end end
assert(found, 'Camping is a built-in manual pin destination')
assert(CB.Categories.ORDER.Consumables < CB.Categories.ORDER.Camping and CB.Categories.ORDER.Camping < CB.Categories.ORDER.Reagents)
-- Shared consumed materials (all 57) and shared tools are not defaults.
local shared = {159,765,1251,2318,2319,2320,2321,2447,2452,2772,2835,2838,2840,2841,
  2842,2996,3356,3371,3372,3478,3575,3713,4234,4305,4359,4361,4371,4375,5784,6037,
  6291,6452,6453,8170,8365,8544,8831,8836,8925,10284,10940,11137,11174,12037,12204,
  12359,12365,13463,13465,14047,14048,14341,14344,14530,15994,16203,273295}
assert(#shared == 57)
for _, id in ipairs(shared) do
  assert(not CB.CampingData[id])
  assert(CB.Categories:Classify(rec(id,7,5)) == 'Sub7_5', 'shared profession split retained ' .. id)
end
CB.db.splitTradeGoods = false
for _, id in ipairs(shared) do assert(CB.Categories:Classify(rec(id,7)) == 'Trade Goods') end
for _, id in ipairs({6219,11130,818,1229737,1283400,1291341,999999}) do
  assert(not CB.CampingData[id], 'not an allowed inventory ID ' .. id)
  local r = rec(id); r.nameLower = 'campfire kit blueprint simple wood'
  assert(CB.Categories:Classify(r) == 'Miscellaneous', 'no English name inference')
end
assert(CB.Categories:Classify(rec(159,0,5)) == 'Food & Drink')
assert(CB.Categories:Classify(rec(1251,0,7)) == 'Bandages')
-- Preserve the existing precedence, including the distinction between manual
-- junk sale eligibility and a manual section pin to Junk.
local r = rec(4470)
CB.db.pins[4470] = 'Trade Goods'
assert(CB.Categories:Classify(r) == 'Trade Goods'); CB.db.pins[4470] = nil
CB.db.favSection = true; CB.db.favorites[4470] = true
assert(CB.Categories:Classify(r) == 'Favorites'); CB.db.favorites[4470] = nil
CB.db.newSection = true; r.isNew = true
assert(CB.Categories:Classify(r) == 'New'); r.isNew = false
CB.db.custom.Expedition = {patterns={'localisé'},order=1}
assert(CB.Categories:Classify(r) == 'Expedition')
CB.db.pins[4470] = 'Camping'
assert(CB.Categories:Classify(r) == 'Camping', 'manual built-in pin beats custom pattern')
CB.db.pins[4470] = 'Expedition'; r.nameLower = ''
assert(CB.Categories:Classify(r) == 'Expedition', 'manual custom pin works without name')
CB.db.pins[4470] = 'Junk'
assert(CB.Categories:Classify(r) == 'Junk'); CB.db.pins[4470] = nil
CB.db.custom = {}; CB.db.junk[4470] = true
assert(CB.Inventory:IsJunk(r), 'manual junk sale policy unchanged')
CB.db.junk[4470] = nil
r.quality = 0; CB.db.separateJunk = true
assert(CB.Categories:Classify(r) == 'Junk')
r.classID = 7; CB.db.junkAll = true
assert(CB.Categories:Classify(r) == 'Junk')
r.quality = 1; r.isQuest = true
assert(CB.Categories:Classify(r) == 'Quest'); r.isQuest = false
CB.db.showSets = true; CB.Categories.setItems[4470] = true
assert(CB.Categories:Classify(r) == 'Equipment Sets'); CB.Categories.setItems = {}
for mode, name in pairs({none='All Items',type='Class7',bag='Backpack',bagtype='General bags',expansion='Unknown'}) do
  CB.db.group = mode; CB.db.showSubtype = false
  assert(CB.Categories:Classify(r) == name, 'non-category grouping unchanged ' .. mode)
end
CB.db.group = 'category'
-- Scan through the real inventory schema, then build sections for bags and bank.
CB.db.newSection = false; CB.db.junkAll = false
for b in pairs(STUB_CONTENTS) do STUB_CONTENTS[b] = {} end
for b in pairs(STUB_SIZES) do STUB_SIZES[b] = 0 end
for _, bag in ipairs({0,6}) do
  STUB_SIZES[bag] = #expected + 1; STUB_CONTENTS[bag] = {}
  for slot,id in ipairs(expected) do
    STUB_CONTENTS[bag][slot] = {id=id,q=1,name='objet localisé',class=15,sub=0}
  end
end
C_Bank.FetchPurchasedBankTabData = function() return {{ID=6}} end
for _, source in ipairs({{CB.Inventory:BagIDs(),''},{CB.Bank.BagIDs(),'bank:'}}) do
  local items, empties, total, free = CB.Inventory:Scan(source[1])
  assert(#items == 76 and #empties == 1 and total == 77 and free == 1, 'scan accounts for every slot')
  CB.db.collapsed[source[2] .. 'Camping'] = true
  local sections = CB.Categories:Build(items,source[2])
  assert(#sections == 1 and sections[1].name == 'Camping' and #sections[1].items == 76)
  assert(sections[1].collapsed)
  for _, item in ipairs(items) do
    assert(item.category == 'Camping' and CB.Inventory:Matches(item,'c:camping'))
    assert(item.key == item.bag .. ':' .. item.slot, 'coordinates retained')
  end
end
CB.db.pinTop[279981] = true
local items = CB.Inventory:Scan({0})
assert(CB.Categories:Build(items)[1].items[1].itemID == 279981, 'pin-to-top remains first inside Camping')
print('PASS Camping: exact 76 IDs, 57 shared exclusions, overrides/grouping, bag+bank scans, search/folds/pin-top (offline)')
