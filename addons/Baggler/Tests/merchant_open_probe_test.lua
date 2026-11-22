-- Offline shipping-TOC contract, NOT native taint or in-game proof.
-- timeout 60 luajit addons/Baggler/Tests/merchant_open_probe_test.lua
local function boot(saved, late)
  dofile('tests/harness/ca_stubs.lua')
  function UnitClass() return 'Warrior', 'WARRIOR' end
  function IsAltKeyDown() return false end
  function IsControlKeyDown() return false end
  function IsShiftKeyDown() return false end
  BagglerDB = saved or { replaceDefault = false }
  local hooks, counts, writers = {}, {}, {}
  -- Model both secure-hook overloads; never call native functions to install.
  function hooksecurefunc(target, key, fn)
    if type(target) == 'string' then fn, key, target = key, target, _G end
    assert(type(rawget(target, key)) == 'function', 'missing native ' .. key)
    hooks[target] = hooks[target] or {}; hooks[target][key] = hooks[target][key] or {}
    local list = hooks[target][key]; list[#list + 1] = fn
    counts[key] = (counts[key] or 0) + 1
  end
  local function returned(target, key, ...)
    for _, fn in ipairs(hooks[target] and hooks[target][key] or {}) do fn(...) end
  end
  local secret = setmetatable({}, { __tostring = function() error('secret formatted') end,
    __eq = function() error('secret compared') end, __index = function() error('secret indexed') end })
  function issecretvalue(v) return rawequal(v, secret) end
  function issecurevariable(t, k)
    local by = writers[t] and writers[t][k]
    if by then return false, by end
    return true
  end
  local nativeCalls = 0
  local function forbidden() nativeCalls = nativeCalls + 1; error('probe called native mutator/getter') end
  OpenAllBags, PanelTemplates_SetTab = forbidden, forbidden
  MerchantFrame = { selectedTab = secret, refundItem = secret, itemHover = secret }
  local merchant = MerchantFrame
  local function natives()
    merchant.footer = { Refresh = forbidden, isShown = secret, promptedBindingsActive = secret, bindings = secret }
    MerchantFrame_UpdateCanRepairAll, MerchantFrame_UpdateGuildBankRepair = forbidden, forbidden
  end
  if not late then natives() else
    MerchantFrame_UpdateCanRepairAll, MerchantFrame_UpdateGuildBankRepair = nil, nil
  end
  GamepadSharedUtility = { InputBindingManager = { currentCoreBindingActive = secret,
    activeBindings = { PAD1 = secret, PAD3 = secret, PADLTRIGGER = secret, PADRTRIGGER = secret } } }
  local CB = {}
  for line in io.lines('addons/Baggler/Baggler.toc') do
    if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
  end
  local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
  event('ADDON_LOADED', 'Baggler')
  -- The probe works independently of replacement/controller startup.
  return CB, event, returned, counts, writers, merchant, natives, function() return nativeCalls end, secret
end
local CB, event, returned, counts, writers, merchant, natives, calls, secret = boot()
returned(_G, 'OpenAllBags', {})
assert(CB.db.merchantOpenProbe and #CB.db.merchantOpenProbe.opens == 0, 'persistent opening ledger missing or nonmerchant accepted')
returned(_G, 'OpenAllBags', merchant)
local open = CB.db.merchantOpenProbe.opens[1]
assert(open and open.checkpoints[1].phase == 'OpenAllBags:return', 'merchant OpenAllBags return must start opening')
returned(merchant.footer, 'Refresh', merchant.footer)
returned(_G, 'MerchantFrame_UpdateCanRepairAll')
returned(_G, 'MerchantFrame_UpdateGuildBankRepair')
returned(_G, 'PanelTemplates_SetTab', {})
assert(#open.checkpoints == 4, 'nonmerchant SetTab must be ignored')
writers[merchant] = { selectedTab = 'Baggler' }
returned(_G, 'PanelTemplates_SetTab', merchant)
local expected = { 'OpenAllBags:return', 'footer.Refresh:return', 'UpdateCanRepairAll:return',
  'UpdateGuildBankRepair:return', 'PanelTemplates_SetTab:return' }
for i, phase in ipairs(expected) do
  local cp = open.checkpoints[i]
  assert(cp.phase == phase and (i == 1 or cp.order > open.checkpoints[i - 1].order), 'nested return ordering')
  assert(cp.slots['MerchantFrame.refundItem'].secure == true, 'metadata only, never secret payload')
  assert(cp.slots['_G.MerchantFrame_UpdateCanRepairAll'].secure == true, 'repair function slot provenance missing')
end
assert(open.firstTaint.after.phase == expected[5] and open.firstTaint.before.phase == expected[4], 'first taint interval missing')
assert(open.firstTaint.transition == true, 'clean-to-insecure transition must be distinguished from already dirty')
assert(calls() == 0, 'probe must never invoke native functions')
assert(CB:BuildIncidentReport():find('PanelTemplates_SetTab:return', 1, true), 'opening evidence absent from incidents report')
assert(CB:BuildIncidentReport():find('post-hook interval', 1, true), 'report must not claim entry execution security')
print('PASS shipping TOC, nested repair/footer ordering, merchant filter, metadata-only provenance and report')

-- A hundred nested returns cannot evict the first transition or grow storage.
event('MERCHANT_CLOSED')
writers[merchant] = nil
returned(_G, 'OpenAllBags', merchant)
local flooded = CB.db.merchantOpenProbe.opens[2]
for i = 1, 100 do returned(merchant.footer, 'Refresh', merchant.footer) end
writers[merchant] = { selectedTab = 'Baggler' }
returned(_G, 'MerchantFrame_UpdateCanRepairAll')
assert(#flooded.checkpoints <= 12 and flooded.firstTaint.transition, 'post-prefix first transition must survive')
local firstInterval = flooded.firstTaint
for i = 1, 100 do returned(merchant.footer, 'Refresh', merchant.footer) end
assert(flooded.firstTaint == firstInterval and #flooded.checkpoints == 12, 'flood evicted first interval')
returned(_G, 'PanelTemplates_SetTab', merchant)
local saved, earliest = CB.db, CB.db.merchantOpenProbe.opens[1]
CB, event, returned, counts, writers, merchant, natives, calls, secret = boot(saved)
assert(CB.db.merchantOpenProbe.opens[1] == earliest, 'reload erased first opening')
for i = 1, 100 do
  returned(_G, 'OpenAllBags', merchant)
  returned(_G, 'PanelTemplates_SetTab', merchant)
end
assert(#CB.db.merchantOpenProbe.opens == 10 and CB.db.merchantOpenProbe.opens[1] == earliest, 'opening flood/reload erased earliest taint')
assert(CB.db.merchantOpenProbe.opens[10].id == 102, 'opening sequence must survive reload')
print('PASS checkpoint flood after prefix, earliest taint interval, opening cap and same-DB reload')

CB, event, returned, counts, writers, merchant, natives, calls, secret = boot(nil, true)
assert(counts.MerchantFrame_UpdateCanRepairAll == nil and counts.Refresh == nil, 'missing APIs should not be hooked')
natives()
event('ADDON_LOADED', 'UnrelatedAddon')
assert(counts.Refresh == nil, 'unrelated addon must not trigger installation')
event('ADDON_LOADED', 'Blizzard_UIPanels_Game')
for i = 1, 100 do event('ADDON_LOADED', 'Blizzard_UIPanels_Game') end
assert(counts.Refresh == 1 and counts.MerchantFrame_UpdateCanRepairAll == 1 and counts.MerchantFrame_UpdateGuildBankRepair == 1,
  'late native load must install once, not once per event/open')
assert(counts.OpenAllBags == 1 and counts.PanelTemplates_SetTab == 1, 'global probe hooks duplicated')
returned(_G, 'OpenAllBags', merchant)
returned(merchant.footer, 'Refresh', {})
assert(#CB.db.merchantOpenProbe.opens[1].checkpoints == 1, 'foreign footer receiver must be ignored')
merchant.footer, GamepadSharedUtility.InputBindingManager.activeBindings = secret, secret
returned(_G, 'MerchantFrame_UpdateCanRepairAll')
local cp = CB.db.merchantOpenProbe.opens[1].checkpoints[2]
assert(cp.slots['MerchantFrame.footer.Refresh'].status == 'unavailable', 'opaque parents must not be traversed')
assert(cp.slots['InputBindingManager.activeBindings.PAD3'].status == 'unavailable', 'opaque binding parent must not be traversed')
issecurevariable = nil
returned(_G, 'MerchantFrame_UpdateGuildBankRepair')
assert(calls() == 0, 'missing/opaque handling invoked native')
print('PASS late/missing native APIs, correct addon loading, one-time hooks and opaque parent safety')

-- Automatic transitions and incidents no longer walk globals/recursive trees.
CB, event = boot()
local broad, manual = 0, CB.TaintScan
CB.TaintScan = function() broad = broad + 1; return {} end
CB.NativeInputScan = function() broad = broad + 1; return {} end
CB:Fire('READY'); FLUSH()
CB:TaintWatch('native window transition')
event('MERCHANT_SHOW'); event('MERCHANT_CLOSED'); FLUSH()
event('ADDON_ACTION_FORBIDDEN', 'OtherAddon', 'UseAction()'); FLUSH()
assert(broad == 0, 'automatic open/incident/login diagnostics must not run broad scans')
SlashCmdList.BAGGLER('taint')
assert(broad == 1, 'explicit manual /baggler taint must retain the broad scan')
CB.TaintScan = manual
print('PASS automatic broad scans disabled, explicit manual taint retained')

-- An already-insecure unrelated slot must not conceal the first actual transition.
CB, event, returned, counts, writers, merchant = boot()
writers[merchant] = { refundItem = 'OtherAddon' }
returned(_G, 'OpenAllBags', merchant)
local dirtyAtStart = CB.db.merchantOpenProbe.opens[1]
assert(dirtyAtStart.firstTaint and not dirtyAtStart.firstTaint.transition, 'already dirty must not be called a transition')
for i = 1, 100 do returned(merchant.footer, 'Refresh', merchant.footer) end
writers[merchant].selectedTab = 'Baggler'
returned(_G, 'MerchantFrame_UpdateCanRepairAll')
assert(dirtyAtStart.firstTaint.transition and dirtyAtStart.firstTaint.after.phase == 'UpdateCanRepairAll:return',
  'first actual clean-to-insecure transition concealed by baseline dirt')
local transition = dirtyAtStart.firstTaint
writers[merchant].itemHover = 'Baggler'
returned(_G, 'MerchantFrame_UpdateGuildBankRepair')
assert(dirtyAtStart.firstTaint == transition, 'later transition replaced first transition')
print('PASS already-dirty baseline distinguished from first actual transition after flood')

-- Fail even on a raw payload lookup, not only on formatting/indexing a sentinel.
CB, event, returned, counts, writers, merchant, natives, calls, secret = boot()
local realRawget, realSecure = rawget, issecurevariable
local payloadKeys = { selectedTab = true, refundItem = true, itemHover = true, Refresh = true,
  isShown = true, promptedBindingsActive = true, bindings = true, currentCoreBindingActive = true,
  PAD1 = true, PAD3 = true, PADLTRIGGER = true, PADRTRIGGER = true }
local queried = 0
rawget = function(t, k)
  assert(not payloadKeys[k], 'probe fetched selected payload ' .. tostring(k))
  return realRawget(t, k)
end
issecurevariable = function(t, k)
  assert(payloadKeys[k] or k == 'footer' or k == 'MerchantFrame_UpdateCanRepairAll' or k == 'MerchantFrame_UpdateGuildBankRepair',
    'query outside fixed allowlist')
  queried = queried + 1
  return realSecure(t, k)
end
returned(_G, 'OpenAllBags', merchant)
returned(merchant.footer, 'Refresh', merchant.footer)
returned(_G, 'MerchantFrame_UpdateCanRepairAll')
returned(_G, 'MerchantFrame_UpdateGuildBankRepair')
returned(_G, 'PanelTemplates_SetTab', merchant)
rawget, issecurevariable = realRawget, realSecure
assert(queried == 75, 'five checkpoints must query exactly 15 allowlisted metadata slots')
assert(#CB.db.merchantOpenProbe.opens[1].checkpoints == 5, 'opaque payload lookup silently aborted capture')
assert(calls() == 0, 'metadata-only probe invoked native')
local function scalarsOnly(t)
  assert(not rawequal(t, secret), 'secret persisted')
  for _, v in pairs(t) do
    if type(v) == 'table' then scalarsOnly(v)
    else assert(type(v) == 'boolean' or type(v) == 'string' or type(v) == 'number', 'non-scalar persisted') end
  end
end
scalarsOnly(CB.db.merchantOpenProbe)
assert(counts.Refresh == 1 and counts.MerchantFrame_UpdateCanRepairAll == 1, 'per-open hook duplication')
print('PASS exact 15-slot allowlist, zero raw payload lookups, scalar-only saved ledger')

-- Prefer the first proven transition over an older already-dirty opening.
CB, event, returned, counts, writers, merchant = boot()
writers[merchant] = { refundItem = 'OtherAddon' }
returned(_G, 'OpenAllBags', merchant); returned(_G, 'PanelTemplates_SetTab', merchant)
returned(_G, 'OpenAllBags', merchant)
writers[merchant].selectedTab = 'Baggler'
returned(_G, 'PanelTemplates_SetTab', merchant)
local firstProven = CB.db.merchantOpenProbe.opens[2]
assert(firstProven.firstTaint.transition)
for i = 1, 100 do
  returned(_G, 'OpenAllBags', merchant); returned(_G, 'PanelTemplates_SetTab', merchant)
end
assert(CB.db.merchantOpenProbe.opens[1] == firstProven, 'already-dirty older opening displaced first proven transition')
print('PASS first proven transition pinned across opening floods despite older baseline dirt')
