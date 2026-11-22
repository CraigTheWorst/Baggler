-- Run from repository root: timeout 60 luajit addons/Baggler/Tests/combat_lag_test.lua
-- Regression for the combat-start race seen in the saved journal: PLAYER_REGEN_DISABLED arrives with
-- InCombatLockdown()==false and UnitAffectingCombat()==true ("lockdown=false affecting=true"), and the
-- secure state driver resolves on the NEXT OnUpdate, either before or after that event. Add-on writers
-- (Apply, ReclaimStolen, watchdog) that trust InCombatLockdown() alone can rewrite the full override set
-- after the secure clear. The secure snippet fires once per state change, so nothing would undo it.
-- Client boundary (override bindings, restricted snippets, driver timing) is SIMULATED after the pinned
-- 70938 RestrictedFrames/SecureStateDriver source. Offline only: not an in-game proof.
dofile('tests/harness/ca_stubs.lua')
MerchantFrame.__shown = false
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
AFFECTING = false
function UnitAffectingCombat() return AFFECTING end

local create = CreateFrame
local world = { PAD1 = 'JUMP', PAD2 = 'WORLD_B', PAD3 = 'WORLD_X', PAD4 = 'WORLD_Y', PADDUP = 'WORLD_UP',
  PADDDOWN = 'WORLD_DOWN', PADLSHOULDER = 'WORLD_LB', PADFORWARD = 'TOGGLEGAMEMENU' }
local overrides, order, secure, driver = {}, {}, false, nil
local function guard(op) if COMBAT and not secure then error('ADDON_ACTION_BLOCKED: ' .. op, 3) end end
function SetBinding() error('must never change global bindings') end
function ClearOverrideBindings() error('must not clear another owner') end
function SetOverrideBindingClick() error('must use restricted owner') end
function SetOverrideBinding() error('must use restricted owner') end
local function ownerTable(f)
  if not overrides[f] then overrides[f] = {}; order[#order + 1] = f end
  return overrides[f]
end
function GetBindingAction(key)
  for i = #order, 1, -1 do local a = overrides[order[i]][key]; if a then return a end end
  return world[key] or ''
end
local function handleFor(f)
  local h = {}
  function h:ClearBindings() guard('ClearBindings'); wipe(ownerTable(f)) end
  function h:SetBindingClick(_, key, target, button) guard('SetBindingClick'); ownerTable(f)[key] = 'CLICK ' .. target .. ':' .. (button or 'LeftButton') end
  function h:SetBinding(_, key, action) guard('SetBinding'); ownerTable(f)[key] = action end
  function h:GetAttribute(k) return f.__attr and f.__attr[k] end
  function h:SetAttribute(k, v) f.__attr = f.__attr or {}; f.__attr[k] = v end
  function h:GetName() return f:GetName() end
  function h:GetFrameRef(label) local r = f.__attr and f.__attr['frameref-' .. label]; return r and r.__handle end
  return h
end
local restrictedEnv = { gmatch = string.gmatch, strmatch = string.match, format = string.format,
  tostring = tostring, tonumber = tonumber, type = type, pairs = pairs, ipairs = ipairs }
local function runSnippet(f, attr, sig, ...)
  local body = f:GetAttribute(attr); if not body then return end
  local fn = assert(loadstring('return function(' .. sig .. ') ' .. body .. ' end'))
  setfenv(fn, restrictedEnv)
  local was = secure; secure = true
  local ok, err = pcall(fn(), f.__handle, ...)
  secure = was
  assert(ok, 'restricted snippet failed: ' .. tostring(err))
end
function CreateFrame(kind, name, parent, template)
  local f = create(kind, name, parent, template)
  f.__clicks = (kind == 'Button') and { LeftButtonUp = true } or {}
  function f:RegisterForClicks(...) self.__clicks = {}; for _, c in ipairs({ ... }) do self.__clicks[c] = true end end
  if template and template:find('SecureHandler') then
    f.__handle = handleFor(f)
    local setAttribute = f.SetAttribute
    function f:SetAttribute(k, v) guard('SetAttribute ' .. tostring(k)); return setAttribute(self, k, v) end
    function f:Execute(body)
      guard('Execute')
      local fn = assert(loadstring('return function(self) ' .. body .. ' end'))
      setfenv(fn, restrictedEnv)
      local was = secure; secure = true
      local ok, err = pcall(fn(), self.__handle); secure = was
      assert(ok, 'Execute failed: ' .. tostring(err))
    end
    function f:SetFrameRef(label, ref) guard('SetFrameRef'); setAttribute(self, 'frameref-' .. label, ref) end
    if template:find('SecureHandlerStateTemplate') then
      f.__state = function(state, value) runSnippet(f, '_onstate-' .. state, 'self, stateid, newstate', state, tonumber(value) or value) end
    end
    if template:find('SecureHandlerClickTemplate') then
      f.__scripts.OnClick = function(self, button, down) runSnippet(self, '_onclick', 'self, button, down', button, down) end
    end
  end
  if template and template:find('SecureActionButtonTemplate') then
    local setAttribute = f.SetAttribute
    function f:SetAttribute(...) guard('secure action SetAttribute'); return setAttribute(self, ...) end
  end
  if kind == 'Frame' then
    function f:EnableGamePadButton(on) guard('EnableGamePadButton'); self.__padEnabled = on end
    function f:SetPropagateKeyboardInput(on) guard('SetPropagateKeyboardInput'); self.__propagate = on end
  end
  return f
end
function RegisterStateDriver(f, state, condition) driver = f end

-- Native focus manager as the 70938 FrameControlsManager exposes it (read-only fields).
local shownA = CreateFrame('Frame', 'NativePanelA', UIParent)
GamepadMode = { FrameControlsManager = { isUIFocused = true, focusedFrame = shownA, shownFrames = { shownA }, topSuspendedFrame = nil } }

local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name) end
CB.eventFrame.__scripts.OnEvent(CB.eventFrame, 'ADDON_LOADED', 'Baggler')
event('PLAYER_LOGIN'); FLUSH()
CB.db.pad.mode = 'on'
local P, W = CB.Pad, CB.Window
assert(driver, 'secure combat state driver must be registered')

-- What the add-on's own timers do every 0.1 s / 0.5 s while bags hold the controller.
local function tick() P:ReclaimStolen(); P:Reconcile('watchdog') end
local function noOtherKeyCaptured(where)
  for key, action in pairs(world) do
    if key ~= 'PAD2' then
      assert(GetBindingAction(key) == action, where .. ': ' .. key .. ' must reach the game in combat, got ' .. GetBindingAction(key))
    end
  end
  for _, key in ipairs({ 'PADDLEFT', 'PADDRIGHT', 'PADRSHOULDER', 'PADLTRIGGER', 'PADRTRIGGER', 'PADLSTICK', 'PADRSTICK', 'PADBACK' }) do
    assert(GetBindingAction(key) == '', where .. ': ' .. key .. ' captured in combat: ' .. GetBindingAction(key))
  end
  local c = P:Receiver()
  assert(not c or not c:IsShown() or c.__propagate == true, where .. ': catcher swallowing input in combat')
end
local function leaveCombat()
  AFFECTING = false; COMBAT = false; driver.__state('combat', 0); event('PLAYER_REGEN_ENABLED'); FLUSH()
end

local failures, total = {}, 0
local function run(label, fn)
  total = total + 1
  local ok, err = pcall(fn)
  AFFECTING = false; COMBAT = false
  if W:IsOpen() then W:Close() end
  leaveCombat()
  if ok then print('PASS ' .. label) else failures[#failures + 1] = label .. ': ' .. tostring(err); print('FAIL ' .. label .. ' -- ' .. tostring(err)) end
end

-- Matrix: backend x order (event first / driver first) x where the add-on timers run
-- (before the driver resolves / only after it) x lockdown lag (ticks while lockdown still false).
for _, backend in ipairs({ 'bindings', 'catcher' }) do
  for _, first in ipairs({ 'event-first', 'driver-first' }) do
    for _, early in ipairs({ false, true }) do
      local label = ('%s %s%s'):format(backend, first, early and ' +tick before driver' or '')
      run(label, function()
        CB.db.pad.backend = backend
        W:Open(); P:Apply('probe open')
        assert(P.bound and W:IsOpen(), 'precondition: bags own the controller')
        AFFECTING = true                       -- the game is now in combat; lockdown has not begun
        if first == 'event-first' then
          event('PLAYER_REGEN_DISABLED')       -- lockdown=false here (journal)
          if early then tick() end
          driver.__state('combat', 1)          -- next OnUpdate
        else
          driver.__state('combat', 1)
          event('PLAYER_REGEN_DISABLED')
          if early then tick() end
        end
        tick(); tick()                         -- timers run while lockdown still lags
        noOtherKeyCaptured(label .. ' (lockdown lag)')
        COMBAT = true                          -- lockdown finally begins
        tick()
        noOtherKeyCaptured(label .. ' (in lockdown)')
        leaveCombat()
        assert(W:IsOpen() and P.bound, 'kept-open bags must rebind after regen')
      end)
    end
  end
end

-- Stale-signal guard: after regen the add-on must treat itself as out of combat even if the secure
-- state attribute still reads 1 (the journal shows state-combat=1 at every REGEN_ENABLED).
run('regen with stale state-combat=1 rebinds', function()
  CB.db.pad.backend = 'bindings'
  W:Open(); P:Apply('probe open')
  AFFECTING = true; COMBAT = true; driver.__attr = driver.__attr or {}
  rawset(driver.__attr, 'state-combat', 1)
  event('PLAYER_REGEN_DISABLED'); driver.__state('combat', 1)
  AFFECTING = false; COMBAT = false
  event('PLAYER_REGEN_ENABLED'); FLUSH()      -- driver has NOT yet reported 0
  assert(W:IsOpen() and P.bound and GetBindingAction('PAD1'):match('^CLICK '), 'bags must rebind at regen despite stale state')
end)

-- Read-only native focus snapshot at the combat edge, journaled BEFORE Apply runs.
run('native focus snapshot precedes Apply', function()
  CB.db.pad.backend = 'bindings'
  W:Open(); P:Apply('probe open')
  local seenAtApply
  local realApply = P.Apply
  P.Apply = function(self, reason)
    if reason == 'combat' and not seenAtApply then
      seenAtApply = false
      for _, line in ipairs(CB.db.journal or {}) do if tostring(line):find('native focus', 1, true) then seenAtApply = line end end
    end
    return realApply(self, reason)
  end
  AFFECTING = true
  event('PLAYER_REGEN_DISABLED')
  P.Apply = realApply
  assert(seenAtApply, 'no native focus snapshot journaled before Apply(combat)')
  assert(seenAtApply:find('uiFocused=true', 1, true) and seenAtApply:find('focused=NativePanelA', 1, true)
    and seenAtApply:find('NativePanelA', 1, true) and seenAtApply:find('edge=combat start', 1, true), 'snapshot content: ' .. seenAtApply)
end)

print(('%d/%d scenarios passed'):format(total - #failures, total))
if #failures > 0 then
  for _, f in ipairs(failures) do print('  RED ' .. f) end
  os.exit(1)
end
print('ALL PASS combat lag (offline only; not an in-game proof)')
