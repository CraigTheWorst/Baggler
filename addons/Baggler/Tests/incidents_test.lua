-- Offline contract; NOT native taint/gameplay proof. Run from repo root.
-- timeout 60 luajit addons/Baggler/Tests/incidents_test.lua
local function boot(saved, beforeReady, beforeDB)
  dofile('tests/harness/ca_stubs.lua')
  function UnitClass() return 'Warrior', 'WARRIOR' end
  function IsAltKeyDown() return false end
  function IsControlKeyDown() return false end
  function IsShiftKeyDown() return false end
  BagglerDB = saved or {}
  local CB = {}
  for line in io.lines('addons/Baggler/Baggler.toc') do
    if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
  end
  local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
  if beforeDB then beforeDB(CB, event) end
  event('ADDON_LOADED', 'Baggler')
  if beforeReady then beforeReady(CB, event) end
  event('PLAYER_LOGIN'); FLUSH()
  return CB, event
end
local CB, event = boot()
assert(type(CB.db.incidents) == 'table', 'missing persistent bounded incident recorder')
event('AUCTION_HOUSE_SHOW')
event('AUCTION_HOUSE_CLOSED')
event('ADDON_ACTION_FORBIDDEN', 'OtherAddon', 'UseAction()')
local db = CB.db
assert(#db.incidents.errors == 1, 'forbidden event must be retained')
local first = db.incidents.errors[1]
assert(first.event == 'ADDON_ACTION_FORBIDDEN' and first.addon == 'OtherAddon')
assert(first.context[#first.context].kind == 'AUCTION_HOUSE_CLOSED', 'close prelude lost')
assert(first.context[#first.context - 1].kind == 'AUCTION_HOUSE_SHOW', 'open prelude lost')
CB, event = boot(db)
assert(CB.db.incidents.errors[1] == first, 'reload must preserve earliest incident evidence')
assert(#CB.db.incidents.sessions == 2, 'reload appends a session instead of replacing evidence')
print('PASS incident shipping TOC, forbidden prelude and same-DB reload')

-- Installed !BugGrabber uses EventRegistry callback + opaque table ID, NOT
-- CallbackHandler or an error-table callback argument. Never read .locals.
local callbacks, objects = {}, {}
local callbackRegistrations = 0
EventRegistry = { RegisterCallback = function(_, name, fn, owner)
  callbackRegistrations = callbackRegistrations + 1
  callbacks[name] = { fn = fn, owner = owner }
end }
BugGrabber = { GetErrorByID = function(_, id) return objects[id] end }
local function grabbed(id, message, stack)
  objects[id] = setmetatable({ message = message, stack = stack }, {
    __index = function(_, key) error('must not inspect BugGrabber.' .. key) end })
  local cb = assert(callbacks['BugGrabber.BugGrabbed'], 'missing verified BugGrabber callback')
  cb.fn(cb.owner, id)
end
CB, event = boot()
event('AUCTION_HOUSE_SHOW')
grabbed('id1', 'Interface/AddOns/Baggler/Window.lua:42: attempt to index field \'SellerName\' (a nil value)',
  'Interface/AddOns/Baggler/Window.lua:42: in function <PRIVATE>\n/' .. 'home' .. '/alice/private.lua:3: arbitrary identity')
assert(#CB.db.incidents.errors == 1, 'Lua error callback must create incident')
local luaFirst = CB.db.incidents.errors[1]
for i = 1, 1000 do grabbed('id1', objects.id1.message, 'later stack') end
assert(#CB.db.incidents.errors == 1 and luaFirst.count == 1001, 'error flood must dedupe')
assert(luaFirst.stack:find('Window.lua:42', 1, true), 'earliest source stack retained')
assert(not luaFirst.stack:find('alice', 1, true) and not luaFirst.stack:find('PRIVATE', 1, true), 'stack identity/path must be redacted')
for i = 1, 35 do
  grabbed('new' .. i, 'Interface/AddOns/Baggler/Window.lua:' .. (100 + i) .. ': division by zero', '')
end
assert(#CB.db.incidents.errors == 20 and CB.db.incidents.errors[1] == luaFirst, 'retain first and latest distinct, bounded')
assert(CB.db.incidents.errors[20].func:find('135', 1, true), 'latest distinct retained')
print('PASS verified BugGrabber callback, earliest stack, redaction and bounded flood')

-- Installed BugGrabber stacks use [Interface/AddOns/...lua]:line, including
-- !BugGrabber. Keep locations only, never function arguments or .locals.
CB, event = boot()
grabbed('bracketed', 'Interface/AddOns/Baggler/Core.lua:177: attempt to call',
  "[Interface/AddOns/!BugGrabber/BugGrabber.lua]:554: in function '?' with args (PRIVATE)\n" ..
  "[Interface/AddOns/Blizzard_GamepadSharedUtility/InputBindingStack/InputBindingManager.lua]:190: in function 'RemoveSet'\n" ..
  '/' .. 'home' .. '/alice/private.lua:42: PRIVATE\n[C]: in function PRIVATE')
local bracketed = CB.db.incidents.errors[1]
assert(bracketed.stack == 'Interface/AddOns/!BugGrabber/BugGrabber.lua:554\n' ..
  'Interface/AddOns/Blizzard_GamepadSharedUtility/InputBindingStack/InputBindingManager.lua:190',
  'real bracketed BugGrabber stack locations must survive without private arguments: ' .. bracketed.stack)
print('PASS bracketed native/BugGrabber stack locations survive privacy filtering')

-- A protected-action callback has no source in its message. Classify only
-- fixed event tags and derive its source from the trusted string stack.
CB, event = boot()
local protectedStack = '[Interface/AddOns/!BugGrabber/BugGrabber.lua]:554: PRIVATE\n' ..
  '[Interface/AddOns/Blizzard_GamepadActionBars/MainActionBarFrame.lua]:373: PRIVATE'
grabbed('forbidden', "[ADDON_ACTION_FORBIDDEN] AddOn 'PRIVATE' tried to call 'PRIVATE()'.", protectedStack)
local forbidden = CB.db.incidents.errors[1]
assert(forbidden.func == 'Interface/AddOns/!BugGrabber/BugGrabber.lua:554 ADDON_ACTION_FORBIDDEN',
  'protected callback needs fixed category and stack-derived source, not unknown: ' .. forbidden.func)
assert(not forbidden.func:find('PRIVATE', 1, true) and not forbidden.stack:find('PRIVATE', 1, true))
grabbed('blocked', '[ADDON_ACTION_BLOCKED] PRIVATE', protectedStack)
assert(#CB.db.incidents.errors == 2 and CB.db.incidents.errors[2].func:find('ADDON_ACTION_BLOCKED', 1, true),
  'blocked and forbidden callbacks must not collapse into one unknown error')
grabbed('forbidden', '[ADDON_ACTION_FORBIDDEN] PRIVATE', protectedStack .. '\nlater private stack')
assert(forbidden.count == 2 and forbidden.stack:find('MainActionBarFrame.lua:373', 1, true),
  'repeats must preserve the earliest actual stack')
print('PASS protected callback fixed category, stack-derived source and earliest-stack retention')

local globalHandlerWrites = 0
function seterrorhandler() globalHandlerWrites = globalHandlerWrites + 1 end
function geterrorhandler() return function() end end
CB, event = boot(nil, nil, function(_, earlyEvent)
  grabbed('startup', 'Interface/AddOns/Baggler/Core.lua:9: attempt to call secret', 'Interface/AddOns/Baggler/Core.lua:9: startup')
  earlyEvent('AUCTION_HOUSE_SHOW')
end)
assert(#CB.db.incidents.errors == 1, 'pre-DB callback must survive startup order')
assert(CB.db.incidents.errors[1].func:find('Core.lua:9', 1, true))
local startupFirst = CB.db.incidents.errors[1]
CB, event = boot(CB.db, nil, function()
  grabbed('startup', 'Interface/AddOns/Baggler/Core.lua:9: attempt to call secret', 'Interface/AddOns/Baggler/Core.lua:88: later')
end)
assert(#CB.db.incidents.errors == 1 and CB.db.incidents.errors[1] == startupFirst and startupFirst.count == 2,
  'reload startup duplicate must merge without replacing earliest stack')
assert(globalHandlerWrites == 0, 'must not replace global error handler')
print('PASS pre-DB error retention and no global handler replacement')

-- Snapshot fixed provenance, not values or arbitrary native frame trees.
AuctionHouseFrame = rawget(_G, 'AuctionHouseFrame') or CreateFrame('Frame', 'AuctionHouseFrame', UIParent)
GamepadMode = { FrameControlsManager = { isUIFocused = true, focusedFrame = AuctionHouseFrame } }
function issecurevariable(t, key)
  if t == GamepadMode.FrameControlsManager and key == 'focusedFrame' then return false, 'OtherWriter' end
  return true
end
CB.Window:Open()
event('AUCTION_HOUSE_SHOW')
CB.Pad.input.host.dispatch(CB.Window.ctx, 'left', { source = 'binding', id = 22 })
event('AUCTION_HOUSE_CLOSED')
event('ADDON_ACTION_FORBIDDEN', 'OtherAddon', 'TestAction()')
local latest = CB.db.incidents.errors[#CB.db.incidents.errors]
local text = ''
for _, e in ipairs(latest.context) do text = text .. e.kind .. ':' .. (e.action or '') .. ':' .. (e.route or '') .. '\n' end
assert(text:find('AUCTION_HOUSE_SHOW\naction:left:binding\nAUCTION_HOUSE_CLOSED', 1, true) or
  text:find('action:left:binding', 1, true), 'selected owned action and route missing from prelude: ' .. text)
assert(latest.snapshot.nativeFocus == 'auction', 'safe native focus classification missing')
assert(table.concat(latest.snapshot.writers, '\n'):find('OtherWriter', 1, true), 'writer provenance missing')
for i = 1, 100 do event('AUCTION_HOUSE_SHOW'); event('AUCTION_HOUSE_CLOSED') end
assert(#CB.db.incidents.sessions[#CB.db.incidents.sessions].context <= 16)
assert(#latest.context <= 16 and #latest.snapshot.writers <= 16)
print('PASS AH action route, fixed focus/writer snapshot and bounded prelude')

-- Callback absence/late availability must not disable protected-action events.
EventRegistry, BugGrabber = nil, nil
CB, event = boot()
event('ADDON_ACTION_BLOCKED', 'Baggler', 'ProtectedCall()')
assert(#CB.db.incidents.errors == 1, 'blocked events work without BugGrabber')
assert(CB:BuildIncidentReport():find('BugGrabber: unavailable', 1, true), 'fallback must be visible')
callbacks = {}
EventRegistry = { RegisterCallback = function(_, name, fn, owner)
  callbackRegistrations = callbackRegistrations + 1
  callbacks[name] = {fn=fn, owner=owner}
end }
BugGrabber = { GetErrorByID = function(_, id) return objects[id] end }
event('ADDON_LOADED', '!BugGrabber')
grabbed('late', 'Interface/AddOns/Baggler/Core.lua:999: attempt to call', '')
assert(#CB.db.incidents.errors == 2, 'late BugGrabber startup must register callback')
local saved = CB.db
saved.auraWatch = { 'earliest old aura evidence' }
CB, event = boot(saved)
assert(CB.db.auraWatch[1] == 'earliest old aura evidence', 'login must not erase old aura evidence')
for i = 1, 25 do CB, event = boot(saved) end
assert(#saved.incidents.sessions == 20 and #saved.incidents.errors == 2, 'sessions bounded without resetting errors')
local before = #saved.incidents.errors
local secret = newproxy(true)
local formattedSecret = 0
getmetatable(secret).__tostring = function() formattedSecret = formattedSecret + 1; error('formatted secret') end
function issecretvalue(v) return rawequal(v, secret) end
grabbed('secret', secret, secret)
assert(#saved.incidents.errors == before, 'secret callback payload must be ignored')
event('ADDON_ACTION_FORBIDDEN', secret, secret)
assert(formattedSecret == 0, 'blocked observer must not format opaque event metadata')
local popup = false
CB.ShowReport = function() popup = true end
local printed = {}
CB.Print = function(_, text) printed[#printed + 1] = text end
SlashCmdList.BAGGLER('incidents')
assert(#printed > 0 and printed[1]:find('Baggler incidents', 1, true), 'accessible incident command missing')
assert(not popup, 'incident command must not open a focus-stealing popup')
assert(CB:BuildReport():find('== Baggler incidents ==', 1, true), 'existing copyable report must include incidents')
local isOpen = CB.Window.IsOpen
CB.Window.IsOpen = function() error('snapshot unavailable') end
local blockedBefore = CB.blockedCount
event('ADDON_ACTION_BLOCKED', 'OtherAddon', 'SnapshotFailure()')
assert(CB.blockedCount == blockedBefore + 1, 'diagnostic failure must not abort legacy blocked-event handling')
local callbackOK = pcall(grabbed, 'snapshot', 'Interface/AddOns/Baggler/Core.lua:998: failure', '')
assert(callbackOK, 'diagnostic failure must not escape BugGrabber callback')
CB.Window.IsOpen = isOpen
print('PASS missing/late BugGrabber, session cap, secret opacity, prior aura preservation and report command')

-- Roaming combat needs no AH visit and must not sample native combat getters.
CB, event = boot()
local clock = 100
GetTime = function() return clock end
local combatGetter = InCombatLockdown
event('PLAYER_REGEN_DISABLED')
InCombatLockdown = function() error('incident recorder must use observed combat edges') end
grabbed('roam-combat', 'Interface/AddOns/Blizzard_Test/World.lua:1: attempt to call', '')
local combatError = CB.db.incidents.errors[1]
assert(combatError, 'native Lua error in combat without AH must be retained')
assert(combatError.snapshot.combat == true and combatError.snapshot.combatEncounter == 1,
  'combat snapshot needs observed active state and monotonically assigned encounter ID')
assert(combatError.snapshot.scope == 'combat')
local episode = CB.db.incidents.sessions[1].combats[1]
assert(episode.id == 1 and episode.startTime and episode.startElapsed == 100)
InCombatLockdown = combatGetter
print('PASS world combat incident and observed encounter start')
clock = 110
event('PLAYER_REGEN_ENABLED')
event('LOOT_OPENED', secret, secret)
event('LOOT_CLOSED', secret)
event('PLAYER_ENTERING_WORLD', secret, secret)
event('ZONE_CHANGED_NEW_AREA', secret)
grabbed('post-loot', 'Interface/AddOns/Blizzard_Test/World.lua:2: secret', '')
local postError = CB.db.incidents.errors[2]
assert(postError.snapshot.scope == 'post-combat' and not postError.snapshot.combat)
assert(postError.snapshot.combatEncounter == 1 and postError.snapshot.combatEnd == episode.endTime)
assert(episode.endTime and episode.endElapsed == 110 and combatError.snapshot.combatEnd == nil,
  'first combat snapshot must stay immutable when episode ends')
local kinds = {}
for _, b in ipairs(postError.context) do kinds[b.kind] = true end
assert(kinds.LOOT_OPENED and kinds.LOOT_CLOSED and kinds.PLAYER_ENTERING_WORLD and kinds.ZONE_CHANGED_NEW_AREA,
  'roaming and loot breadcrumbs missing')
clock = 140
grabbed('grace-boundary', 'Interface/AddOns/Blizzard_Test/World.lua:3: secret', '')
assert(CB.db.incidents.errors[3].snapshot.scope == 'post-combat')
clock = 141
grabbed('grace-expired', 'Interface/AddOns/Blizzard_Test/World.lua:4: secret', '')
assert(CB.db.incidents.errors[4].snapshot.scope == 'world' and not CB.db.incidents.errors[4].snapshot.combatEncounter)
event('AUCTION_HOUSE_SHOW')
event('PLAYER_REGEN_DISABLED')
grabbed('overlap', 'Interface/AddOns/Blizzard_Test/World.lua:5: secret', '')
assert(CB.db.incidents.errors[5].snapshot.scope == 'auction+combat')
local report = CB:BuildIncidentReport()
assert(report:find('scope=post-combat encounter=1', 1, true), 'report must label saved encounter/scope')
assert(report:find('combat encounter=1 start=', 1, true), 'report must explain episode timestamps')
local combatSaved = CB.db
CB, event = boot(combatSaved)
grabbed('after-reload', 'Interface/AddOns/Blizzard_Test/World.lua:6: secret', '')
assert(CB.db.incidents.errors[1] == combatError and combatError.snapshot.combat == true)
local fresh = CB.db.incidents.errors[6].snapshot
assert(fresh.scope == 'world' and fresh.combat == false and fresh.combatEncounter == nil,
  'reload preserves evidence but cannot inherit active combat or grace')
event('PLAYER_REGEN_ENABLED') -- unmatched end must not invent an episode
event('PLAYER_REGEN_DISABLED')
event('PLAYER_REGEN_DISABLED') -- duplicate start is the same episode
local latestSession = CB.db.incidents.sessions[#CB.db.incidents.sessions]
assert(#latestSession.combats == 1 and latestSession.combats[1].id == 3)
for i = 1, 100 do event('PLAYER_REGEN_ENABLED'); event('PLAYER_REGEN_DISABLED') end
assert(#latestSession.combats == 20 and #latestSession.context == 16)
for i = 1, 1000 do grabbed('repeat-world', 'Interface/AddOns/Blizzard_Test/World.lua:6: secret', '') end
assert(CB.db.incidents.errors[6].count == 1001 and CB.db.incidents.errors[6].snapshot == fresh,
  'repeat merging must preserve earliest scope across encounters')
assert(formattedSecret == 0 and globalHandlerWrites == 0)
print('PASS loot/roaming context, 30s grace, AH overlap, immutable snapshots, clean reload and episode flood cap')
local priorSequence = combatSaved.incidents.combatSequence
CB, event = boot(combatSaved, nil, function(_, earlyEvent)
  earlyEvent('PLAYER_REGEN_DISABLED')
  grabbed('early-combat-a', 'Interface/AddOns/Blizzard_Test/Early.lua:1: secret', '')
  grabbed('early-combat-b', 'Interface/AddOns/Blizzard_Test/Early.lua:2: secret', '')
  for i = 1, 20 do earlyEvent('ZONE_CHANGED_NEW_AREA', secret) end
end)
local errors = CB.db.incidents.errors
for i = #errors - 1, #errors do
  local e = errors[i]
  assert(e.snapshot.combatEncounter == priorSequence + 1)
  for _, b in ipairs(e.context) do
    if b.state.combatEncounter then
      assert(b.state.combatEncounter == priorSequence + 1, 'shared pre-DB prelude must be rebased exactly once')
    end
  end
end
event('ADDON_ACTION_FORBIDDEN', 'OtherAddon', 'WorldCombatProtected()')
local protected = errors[#errors]
assert(protected.snapshot.scope == 'combat' and protected.snapshot.combatEncounter == priorSequence + 1)
event('PLAYER_REGEN_ENABLED')
event('LOOT_CLOSED', secret)
event('ADDON_ACTION_BLOCKED', 'OtherAddon', 'WorldPostLootProtected()')
assert(errors[#errors].snapshot.scope == 'post-combat')
print('PASS pre-DB encounter ID rebasing and protected events during combat/post-loot without AH')

-- KBM interaction: no Baggler controller dispatch is needed for the prelude.
CB, event = boot()
GamepadSharedUtility = { InputBindingManager = { activeBindings = {} } }
GamepadMode = { FrameControlsManager = {} }
local dirty = false
function issecurevariable(t, key)
  if dirty and t == GamepadSharedUtility.InputBindingManager.activeBindings and key == 'PAD3' then
    return false, 'SyntheticWriter'
  end
  return true
end
local clock2 = 200
GetTime = function() return clock2 end
local timers, oldAfter = {}, C_Timer.After
C_Timer.After = function(delay, fn) assert(delay == 0); timers[#timers + 1] = fn end
local nativeCalls = 0
GossipFrame = { IsShown = function() error('no native visibility getter allowed') end }
TaxiFrame, FlightMapFrame = nil, nil
local oldShow = ShowUIPanel
ShowUIPanel = function() nativeCalls = nativeCalls + 1 end
local function recentContext() return CB.db.incidents.sessions[#CB.db.incidents.sessions].context end
event('GOSSIP_SHOW', secret)
local gossip = recentContext()[#recentContext()]
assert(gossip.kind == 'GOSSIP_SHOW' and gossip.state.scope == 'gossip', 'KBM gossip prelude missing')
assert(gossip.snapshot.slots['GamepadSharedUtility.InputBindingManager.activeBindings.PAD3'].secure == true)
assert(#timers == 1, 'event needs one deferred observation')
dirty = true; clock2 = 201
grabbed('gossip-fatal', '[ADDON_ACTION_FORBIDDEN] PRIVATE', protectedStack)
local gossipError = CB.db.incidents.errors[1]
assert(gossipError.snapshot.scope == 'gossip' and not gossipError.snapshot.taxi)
local interval = CB.db.incidents.sessions[1].firstInteractionTransition
assert(interval and interval.slot == 'GamepadSharedUtility.InputBindingManager.activeBindings.PAD3', 'same-slot clean predecessor missing')
assert(interval.before.phase == 'GOSSIP_SHOW:event' and interval.after.phase == 'error')
assert(interval.before.elapsed == 200 and interval.after.elapsed == 201)
assert(gossipError.interactionTransition == interval, 'first error must preserve interaction interval')
event('GOSSIP_CLOSED', secret); event('TAXIMAP_OPENED', secret)
assert(#timers == 1, 'same-tick events must coalesce')
local taxi = recentContext()[#recentContext()]
assert(taxi.state.scope == 'taxi' and taxi.state.flightmasterConfirmed, 'taximap confirms flight-map context only now')
assert(gossip.state.scope == 'gossip' and not gossip.state.flightmasterConfirmed, 'later taxi cannot relabel earlier gossip')
timers[1](); assert(recentContext()[#recentContext()].snapshot.phase == 'interaction:next-tick')
event('AUCTION_HOUSE_SHOW'); event('PLAYER_REGEN_DISABLED')
event('GOSSIP_SHOW', secret)
assert(recentContext()[#recentContext()].state.scope == 'gossip+taxi+auction+combat')
event('TAXIMAP_CLOSED', secret); event('GOSSIP_CLOSED', secret)
for i = 1, 100 do event('GOSSIP_SHOW', secret); event('GOSSIP_CLOSED', secret) end
assert(#recentContext() == 16 and CB.db.incidents.sessions[1].firstInteractionTransition == interval)
assert(nativeCalls == 0 and formattedSecret == 0)
C_Timer.After, ShowUIPanel = oldAfter, oldShow
local interactionSaved = CB.db
CB, event = boot(interactionSaved)
assert(CB.db.incidents.errors[1] == gossipError and gossipError.interactionTransition == interval)
assert(not CB.db.incidents.sessions[#CB.db.incidents.sessions].firstInteractionTransition, 'new session must not inherit predecessors')
assert(CB:BuildIncidentReport():find('GOSSIP_SHOW:event', 1, true), 'report must include pinned interval')
print('PASS KBM gossip -> protected error -> reload, taxi confirmation, deferred order, overlap, privacy and bounded interval')

-- Already dirty, unavailable and replaced parents cannot manufacture a clean
-- predecessor. A later real interval must still win, including repeated errors.
CB, event = boot()
local after2 = C_Timer.After
local deferred = {}
C_Timer.After = function(_, fn) deferred[#deferred + 1] = fn end
local manager = { activeBindings = {} }
GamepadSharedUtility = { InputBindingManager = manager }
GamepadMode = { FrameControlsManager = {} }
local secureState = false
function issecurevariable(t, key)
  if t == manager and key == 'currentCoreBindingActive' then return secureState, secret end
  return true
end
event('GOSSIP_SHOW', secret)
grabbed('repeat-interaction', '[ADDON_ACTION_FORBIDDEN] PRIVATE', protectedStack)
assert(not CB.db.incidents.sessions[1].firstInteractionTransition, 'already dirty is not ingress')
secureState = true
event('GOSSIP_SHOW', secret)
local goodAPI = issecurevariable
issecurevariable = nil
event('GOSSIP_SHOW', secret)
issecurevariable = goodAPI; secureState = false
event('GOSSIP_SHOW', secret)
assert(not CB.db.incidents.sessions[1].firstInteractionTransition, 'missing API breaks predecessor chain')
secureState = true
event('GOSSIP_SHOW', secret)
manager = { activeBindings = {} }; GamepadSharedUtility.InputBindingManager = manager
secureState = false
event('GOSSIP_SHOW', secret)
assert(not CB.db.incidents.sessions[1].firstInteractionTransition, 'replaced parent breaks predecessor chain')
secureState = true; event('GOSSIP_SHOW', secret)
secureState = false
grabbed('repeat-interaction', '[ADDON_ACTION_FORBIDDEN] PRIVATE', protectedStack)
assert(CB.db.incidents.sessions[1].firstInteractionTransition, 'repeat error must not hide first interaction interval')
assert(CB.db.incidents.errors[1].count == 2)
assert(#deferred == 1)
C_Timer.After = nil
deferred[1]()
event('GOSSIP_CLOSED', secret); event('TAXIMAP_CLOSED', secret)
assert(recentContext()[#recentContext()].state.scope == 'world', 'unmatched closes do not invent context')
assert(recentContext()[#recentContext()].snapshot.slots['GamepadSharedUtility.InputBindingManager.currentCoreBindingActive'].owner == nil)
C_Timer.After = after2
print('PASS unavailable API/replaced parents reject false predecessors, repeated errors preserve real interval, missing timer and unmatched closes')

CB, event = boot()
local savedAfter = C_Timer.After
local nextTick
C_Timer.After = function(_, fn) assert(not nextTick); nextTick = fn end
local fm = { fallThroughCatcherActive = secret }
local ab = { PAD1 = secret, PAD3 = secret, PADLTRIGGER = secret, PADRTRIGGER = secret }
GamepadMode = { FrameControlsManager = fm }
GamepadSharedUtility = { InputBindingManager = { activeBindings = ab, currentCoreBindingActive = secret } }
local changed = false
function issecurevariable(t, key)
  if t == fm and key == 'fallThroughCatcherActive' then return not changed, changed and 'SyntheticWriter' or nil end
  return true
end
local originalRawget, payloadReads = rawget, 0
rawget = function(t, key)
  if t == ab or (t == fm and key == 'fallThroughCatcherActive') or
      (t == GamepadSharedUtility.InputBindingManager and key == 'currentCoreBindingActive') then
    payloadReads = payloadReads + 1; error('slot payload read')
  end
  return originalRawget(t, key)
end
local mutations = 0
local oldHook = hooksecurefunc
hooksecurefunc = function() mutations = mutations + 1 end
for _, name in ipairs({'ShowUIPanel', 'HideUIPanel', 'SetPreferredGamepadInteractTarget', 'TakeTaxiNode'}) do
  _G[name] = function() mutations = mutations + 1 end
end
event('GOSSIP_SHOW', secret)
changed = true
nextTick()
local deferredInterval = CB.db.incidents.sessions[1].firstInteractionTransition
assert(deferredInterval and deferredInterval.slot == 'GamepadMode.FrameControlsManager.fallThroughCatcherActive')
assert(deferredInterval.before.phase == 'GOSSIP_SHOW:event' and deferredInterval.after.phase == 'interaction:next-tick')
assert(deferredInterval.before.order < deferredInterval.after.order, 'order distinguishes same timestamp observations')
for _, key in ipairs({'PAD1', 'PAD3', 'PADLTRIGGER', 'PADRTRIGGER'}) do
  assert(deferredInterval.before.slots['GamepadSharedUtility.InputBindingManager.activeBindings.' .. key].secure)
end
assert(payloadReads == 0 and mutations == 0 and formattedSecret == 0)
rawget, hooksecurefunc, C_Timer.After = originalRawget, oldHook, savedAfter
print('PASS event-first/deferred native-order interval, full selected slots, zero payload reads/new native hooks/mutation calls')

local priorSaved = { incidents = { sequence = 4, combatSequence = 40, errors = {}, sessions = {} } }
CB, event = boot(priorSaved, nil, function(_, earlyEvent)
  earlyEvent('PLAYER_REGEN_DISABLED')
  earlyEvent('GOSSIP_SHOW', secret)
  grabbed('early-gossip', '[ADDON_ACTION_FORBIDDEN] PRIVATE', protectedStack)
end)
local earlyError = CB.db.incidents.errors[1]
for _, b in ipairs(earlyError.context) do
  if b.snapshot then assert(b.snapshot.combatEncounter == 41, 'pre-DB interaction checkpoint must rebase with incident') end
end
print('PASS pre-DB interaction checkpoint encounter rebasing')

CB, event = boot()
local registrationBaseline = callbackRegistrations
for i = 1, 10 do event('ADDON_LOADED', '!BugGrabber') end
assert(callbackRegistrations == registrationBaseline, 'must reuse the existing global error callback')
GamepadSharedUtility = { InputBindingManager = { activeBindings = {} } }
GamepadMode = { FrameControlsManager = {} }
local bagDirty = false
function issecurevariable(t, key)
  if t == GamepadSharedUtility.InputBindingManager.activeBindings and key == 'PAD1' then return not bagDirty, 'SyntheticWriter' end
  return true
end
CB.Window:Open(); CB.Window:Close()
local ring = recentContext()
local hidden = ring[#ring]
assert(hidden.kind == 'WINDOW_HIDDEN' and hidden.snapshot, 'own bag close must feed fixed recorder')
bagDirty = true
event('GOSSIP_SHOW', secret)
event('ADDON_ACTION_FORBIDDEN', 'OtherAddon', 'SetPreferredGamepadInteractTarget()')
local bagInterval = CB.db.incidents.sessions[1].firstInteractionTransition
assert(bagInterval and bagInterval.before == hidden.snapshot and bagInterval.after.phase == 'GOSSIP_SHOW:event')
assert(CB.db.incidents.errors[1].func == 'SetPreferredGamepadInteractTarget()')
assert(callbackRegistrations == registrationBaseline)
print('PASS own bag open/close predecessor, direct preferred-target refusal, no duplicate error callbacks')
