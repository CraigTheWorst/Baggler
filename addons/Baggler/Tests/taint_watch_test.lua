-- Run from repository root: timeout 60 luajit addons/Baggler/Tests/taint_watch_test.lua
-- Diagnostic only: when a visit starts/ends, the journal names game fields that BECAME Baggler-written since the
-- last look, so a later ADDON_ACTION_FORBIDDEN can be tied to the transition that tainted them. Offline stub of
-- issecurevariable; this is not an in-game taint proof.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
local CB = {}
-- Exercise retained legacy broad scanner semantics explicitly; production defaults
-- are covered by merchant_open_probe_test.lua and no longer scan automatically.
CB.autoBroadTaintScans = true
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()

local tainted = {}   -- field name on MerchantFrame -> true once "Baggler" wrote it
function issecurevariable(t, k)
  if type(t) == 'table' and t == rawget(_G, 'MerchantFrame') and tainted[k] then return false, 'Baggler' end
  return true
end
MerchantFrame = rawget(_G, 'MerchantFrame') or CreateFrame('Frame', 'MerchantFrame', UIParent)
MerchantFrame.selectedTab = 1

local function lines()
  local out = {}
  for _, l in ipairs(CB.db.log) do if l.ctx == 'taint' and l.msg:find('newly', 1, true) then out[#out + 1] = l.msg end end
  return out
end

event('MERCHANT_SHOW'); FLUSH()
assert(#lines() == 0, 'nothing written yet: no line')
tainted.selectedTab = true
event('MERCHANT_CLOSED'); FLUSH()
local got = lines()
assert(#got == 1 and got[1]:find('MerchantFrame.selectedTab', 1, true) and got[1]:find('MERCHANT_CLOSED', 1, true),
  'the transition that first showed the write is named: ' .. table.concat(got, ' | '))
event('MERCHANT_SHOW'); FLUSH()
assert(#lines() == 1, 'a field already reported is not reported again')
print('PASS taint watch names the transition after which a game field became Baggler-written')

---------------------------------------------------------------------------
-- The game's controller input stack (what the radial / interact code reads). The scan must name the slot and who wrote
-- it, tie it to the transition, show it in the blocked-action report, and stay strictly read-only and bounded.
---------------------------------------------------------------------------
local calledNative, wroteNative = 0, 0
local guard = { __newindex = function() wroteNative = wroteNative + 1 end }
local set1 = setmetatable({ treatBindsAsCore = true, name = 'StackSplitBindings',
  BindAll = function() calledNative = calledNative + 1 end }, guard)
local manager = setmetatable({ bindingSetStack = { set1 }, activeBindings = {}, currentCoreBindingActive = true,
  Init = function() calledNative = calledNative + 1 end }, guard)
manager.bindingSetStack.owner = manager            -- a cycle: the walk must terminate
GamepadSharedUtility = { InputBindingManager = manager }
GamepadMode = { FrameControlsManager = { shownFrames = {}, focusedFrame = nil, SetUIFocusState = function() calledNative = calledNative + 1 end } }
GamepadRadial = nil

local writer = {}                                   -- [table][key] = addon name that "wrote" it
local function mark(t, k, by) writer[t] = writer[t] or {}; writer[t][k] = by end
local baseSecure = issecurevariable
function issecurevariable(t, k)
  local w = type(t) == 'table' and writer[t]
  if w and w[k] then return false, w[k] end
  return baseSecure(t, k)
end

local function nativeLines(needle)
  local out = {}
  for _, l in ipairs(CB.db.log) do
    if l.ctx == 'taint' and l.msg:find(needle, 1, true) then out[#out + 1] = l.msg end
  end
  return out
end

-- 1. a clean stack reports nothing
assert(#CB:NativeInputScan() == 0, 'a clean input stack lists nothing')

-- 2. the slot and the writer are named; the transition that first showed it is journaled once
mark(set1, 'treatBindsAsCore', 'Baggler')
event('MERCHANT_CLOSED'); FLUSH()
local path = 'GamepadSharedUtility.InputBindingManager.bindingSetStack[1].treatBindsAsCore (by Baggler)'
local function transitions(slot)   -- journal lines that name this slot as newly written, with their transition
  local out = {}
  for _, l in ipairs(nativeLines('newly Baggler-written after')) do if l:find(slot, 1, true) then out[#out + 1] = l end end
  return out
end
local fresh = transitions('GamepadSharedUtility.InputBindingManager')
assert(#fresh == 1 and fresh[1]:find('after MERCHANT_CLOSED', 1, true) and fresh[1]:find(path, 1, true),
  'slot + writer named after the transition: ' .. table.concat(fresh, ' | '))
event('MERCHANT_SHOW'); FLUSH()
assert(#transitions('GamepadSharedUtility.InputBindingManager') == 1, 'an already-reported slot is not reported again')

-- 3. another add-on's write is attributed to that add-on, not to Baggler
mark(manager, 'currentCoreBindingActive', 'SomeOtherAddon')
local scan = CB:NativeInputScan()
local sawOther, sawMine = false, false
for _, s in ipairs(scan) do
  if s == 'GamepadSharedUtility.InputBindingManager.currentCoreBindingActive (by SomeOtherAddon)' then sawOther = true end
  if s == path then sawMine = true end
end
assert(sawOther and sawMine, 'both writers listed with their own names: ' .. table.concat(scan, ' | '))

-- 4. the blocked-action report carries the same slots, so one saved log line identifies the tainted input
event('ADDON_ACTION_FORBIDDEN', 'Baggler', 'SetPreferredGamepadInteractTarget()'); FLUSH()
local blocked = {}
for _, m in ipairs(nativeLines('game controller input stack, slots not secure:')) do
  if m:find('^game controller') then blocked[#blocked + 1] = m end      -- (not the "at login" baseline line)
end
assert(#blocked == 1 and blocked[1]:find(path, 1, true), 'blocked action lists the tainted input slot: ' .. table.concat(blocked, ' | '))

-- 5. strictly read-only: no game function called, nothing written into any game table, cycle survived
assert(calledNative == 0, 'the scan never calls game functions (called ' .. calledNative .. ')')
assert(wroteNative == 0, 'the scan never writes into game tables (wrote ' .. wroteNative .. ')')

-- 6. bounded: a huge, deeply nested stack cannot stall the client or flood the log
local big = {}
for i = 1, 2000 do big[i] = { nested = { deeper = {} } }; mark(big[i], 'x', 'Baggler') end
GamepadRadial = big
local capped = CB:NativeInputScan()
assert(#capped <= 40, 'result list is capped (got ' .. #capped .. ')')
GamepadRadial = nil
print('PASS native input stack scan names the tainted slot and its writer, ties it to a transition and the blocked report, and is read-only and bounded')
