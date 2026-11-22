-- Run from repository root: timeout 60 luajit addons/Baggler/Tests/combat_b_close_test.lua
-- Regression: bags open as combat starts, then controller B (PAD2) must close them at once, and
-- control must go straight back to the world. Real TOC / real lifecycle; the client boundary
-- (override bindings, restricted snippets, secure click templates, hardware presses) is simulated
-- after the pinned Forever 1.60.1.70938 RestrictedFrames/SecureHandlers source. Offline only:
-- this is not an in-game taint proof.
dofile('tests/harness/ca_stubs.lua')
-- (the shared stubs leave MerchantFrame shown; no vendor is open here. Vendor pairing: merchant_pair_test.lua)
MerchantFrame.__shown = false
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end

local create = CreateFrame
local world = { PAD1 = 'JUMP', PAD2 = 'WORLD_B', PAD3 = 'WORLD_X', PAD4 = 'WORLD_Y', PADDUP = 'WORLD_UP',
  PADDDOWN = 'WORLD_DOWN', PADLSHOULDER = 'WORLD_LB', PADFORWARD = 'TOGGLEGAMEMENU' }
local overrides = {}     -- owner frame -> key -> action (restricted override bindings)
local order = {}         -- owners, most recent writer last
local secure = false     -- true only while restricted/secure code runs
local blocked = {}
local driver

local function guard(op)
  if COMBAT and not secure then blocked[#blocked + 1] = op; error('ADDON_ACTION_BLOCKED: ' .. op, 3) end
end
function SetBinding() error('must never change global bindings') end
function ClearOverrideBindings() error('must not clear another owner') end
function SetOverrideBindingClick() error('must use restricted owner, not addon overrides') end
function SetOverrideBinding() error('must use restricted owner, not addon overrides') end

local function ownerTable(f)
  if not overrides[f] then overrides[f] = {}; order[#order + 1] = f end
  return overrides[f]
end
function GetBindingAction(key)
  for i = #order, 1, -1 do local a = overrides[order[i]][key]; if a then return a end end
  return world[key] or ''
end

-- A restricted handle: bindings belong to the handle's frame, protected while in combat unless secure.
local function handleFor(f)
  local h = {}
  function h:ClearBindings() guard('ClearBindings'); wipe(ownerTable(f)) end
  function h:ClearBinding(key) guard('ClearBinding'); ownerTable(f)[key] = nil end
  function h:SetBindingClick(_, key, target, button)
    guard('SetBindingClick'); assert(type(target) == 'string' and not target:find(':'), 'invalid click target')
    ownerTable(f)[key] = 'CLICK ' .. target .. ':' .. (button or 'LeftButton')
  end
  function h:SetBinding(_, key, action) guard('SetBinding'); ownerTable(f)[key] = action end
  function h:GetAttribute(k) return f.__attr and f.__attr[k] end
  function h:SetAttribute(k, v) f.__attr = f.__attr or {}; f.__attr[k] = v end
  function h:GetName() return f:GetName() end
  function h:GetFrameRef(label) local r = f.__attr and f.__attr['frameref-' .. label]; return r and r.__handle end
  return h
end
-- The restricted environment: no addon globals (CB, Pad ...) are reachable from a snippet.
local restrictedEnv = { gmatch = string.gmatch, strmatch = string.match, strsplit = function(sep, s)
  local out = {}; for part in s:gmatch('[^' .. sep .. ']+') do out[#out + 1] = part end; return unpack(out) end,
  format = string.format, tostring = tostring, tonumber = tonumber, type = type, pairs = pairs, ipairs = ipairs }
local function runSnippet(f, attr, sig, ...)
  local body = f:GetAttribute(attr)
  if not body then return end
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
  function f:RegisterForClicks(...)
    self.__clicks = {}
    for _, c in ipairs({ ... }) do self.__clicks[c] = true end
  end
  if template and template:find('SecureHandler') then
    f.__handle = handleFor(f)
    f.__protected = true
    local setAttribute = f.SetAttribute
    function f:SetAttribute(k, v) guard('SetAttribute ' .. tostring(k)); return setAttribute(self, k, v) end
    function f:Execute(body)
      guard('Execute')
      local fn = assert(loadstring('return function(self) ' .. body .. ' end'))
      setfenv(fn, restrictedEnv)
      local was = secure; secure = true
      local ok, err = pcall(fn(), self.__handle)
      secure = was
      assert(ok, 'Execute failed: ' .. tostring(err))
    end
    function f:SetFrameRef(label, ref)
      guard('SetFrameRef'); assert(ref and ref.__handle, 'frame refs in snippets need a secure handler frame here')
      setAttribute(self, 'frameref-' .. label, ref)
    end
    if template:find('SecureHandlerStateTemplate') then
      f.__state = function(state, value) runSnippet(f, '_onstate-' .. state, 'self, stateid, newstate', state, tonumber(value) or value) end -- client: resolveDriver hands the snippet tonumber("1") == 1, never "1"
    end
    if template:find('SecureHandlerClickTemplate') then
      assert(kind == 'Button', 'SecureHandlerClickTemplate is a Button template')
      f.__scripts.OnClick = function(self, button, down) runSnippet(self, '_onclick', 'self, button, down', button, down) end
    end
  end
  if template and template:find('SecureActionButtonTemplate') then
    local setAttribute = f.SetAttribute
    function f:SetAttribute(...) guard('secure action SetAttribute'); return setAttribute(self, ...) end
  end
  if kind == "Frame" then
    function f:EnableGamePadButton(on) guard('EnableGamePadButton'); self.__padEnabled = on end
    function f:SetPropagateKeyboardInput(on) guard('SetPropagateKeyboardInput'); self.__propagate = on end
  end
  return f
end
function RegisterStateDriver(f, state, condition)
  assert(state == 'combat' and condition == '[combat] 1; 0')
  driver = f
end

-- A hardware press of a controller button: the binding seen at DOWN gets both halves of the press.
local function clickFires(f, down)
  local c = f.__clicks or {}
  if down then return c.AnyDown or c.LeftButtonDown end
  return c.AnyUp or c.LeftButtonUp
end
local function press(key)
  -- Model direct gamepad delivery as well as bindings. An observer which closes
  -- the window but propagates B must still report the world's B action here.
  -- Do not count that double-action route as a successful exclusive UI close.
  local c = (_G.Baggler and _G.Baggler.Pad:Receiver())
  if c and c:IsVisible() and c.__padEnabled and c.__scripts.OnGamePadButtonDown then
    c.__scripts.OnGamePadButtonDown(c, key)
    if c.__propagate == false then
      if c.__scripts.OnGamePadButtonUp then c.__scripts.OnGamePadButtonUp(c, key) end
      return 'ui:direct-receiver'
    end
  end
  local action = GetBindingAction(key)
  local target, button = tostring(action):match('^CLICK ([%w_]+):(%w+)$')
  if target then
    local f = assert(_G[target], 'binding to a missing button ' .. target)
    if clickFires(f, true) then f:Click(button, true) end
    if clickFires(f, false) then f:Click(button, false) end
    return 'ui:' .. target
  end
  return 'world:' .. tostring(action)
end

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
assert(CB.db.pad.map.PAD2 == 'close', 'stock mapping: B is close')

-- Combat begins: PLAYER_REGEN_DISABLED reaches add-ons, then the secure state driver resolves.
local function enterCombat()
  COMBAT = true; event('PLAYER_REGEN_DISABLED'); driver.__state('combat', '1')
end
local function leaveCombat()
  COMBAT = false; driver.__state('combat', '0'); event('PLAYER_REGEN_ENABLED'); FLUSH()
end
local function noOtherKeyCaptured(where)
  for key, action in pairs(world) do
    if key ~= 'PAD2' then
      assert(GetBindingAction(key) == action, where .. ': ' .. key .. ' must reach the game in combat, got ' .. GetBindingAction(key))
    end
  end
  for _, key in ipairs({ 'PADDLEFT', 'PADDRIGHT', 'PADRSHOULDER', 'PADLTRIGGER', 'PADRTRIGGER', 'PADLSTICK', 'PADRSTICK', 'PADBACK' }) do
    assert(GetBindingAction(key) == '', where .. ': ' .. key .. ' still captured in combat: ' .. GetBindingAction(key))
  end
  local c = P:Receiver()
  assert(not c or not c:IsShown() or c.__propagate == true, where .. ': catcher swallowing input in combat')
end
local function worldBack(where)
  assert(GetBindingAction('PAD2') == world.PAD2, where .. ': B not returned to the game: ' .. GetBindingAction('PAD2'))
  noOtherKeyCaptured(where)
  assert(next(P.catchMap) == nil, where .. ': stale catcher state')
  assert(not P.bound and not P.directArmed, where .. ': stale bound/direct-use state')
end

for _, backend in ipairs({ 'bindings', 'catcher' }) do
  CB.db.pad.backend = backend
  wipe(blocked)
  -- 1. The user's exact symptom: bags open, combat starts, B.
  W:Open(); P:Apply('test open')
  assert(P.bound and W:IsOpen(), backend .. ': precondition, bags own the controller')
  enterCombat()
  assert(W:IsOpen(), backend .. ': entering combat must not itself close the bags')
  do -- the event route is proven before Apply runs, through the real registered handler
    local j, seen = CB.db.journal or {}, false
    for i = #j, math.max(1, #j - 6), -1 do if j[i]:find('PLAYER_REGEN_DISABLED received', 1, true) then seen = true end end
    assert(seen, backend .. ': combat start was not journaled by the event handler')
  end
  noOtherKeyCaptured(backend .. ' combat entry')
  assert(press('PAD2'):match('^ui:'), backend .. ': B in combat with bags open must reach Baggler, not the world')
  assert(not W:IsOpen() and #P.stack == 0, backend .. ': B in combat did not close the bags')
  worldBack(backend .. ' after B close')
  assert(press('PAD2') == 'world:' .. world.PAD2, backend .. ': the next B must be the game\'s again')
  assert(press('PAD1') == 'world:JUMP', backend .. ': A must be the game\'s in combat')
  assert(#blocked == 0, backend .. ': blocked protected calls: ' .. table.concat(blocked, ', '))
  leaveCombat()
  assert(not BagglerPadBroker:Has('Baggler') and not P.pending, backend .. ': regen cleanup incomplete')
  worldBack(backend .. ' postcombat')
  print('PASS ' .. backend .. ': B closes bags opened before combat; every key is the game\'s afterwards')

  -- 2. Bags closed some other way in combat (Menu / radial wheel): the close capture is
  --    released by regen at the latest, and a B press is never swallowed twice.
  W:Open(); P:Apply('test reopen')
  enterCombat()
  W:Close()
  assert(not W:IsOpen() and #P.stack == 0, backend .. ': external combat close must pop the bags')
  noOtherKeyCaptured(backend .. ' external close')
  local first = press('PAD2')
  assert(GetBindingAction('PAD2') == world.PAD2, backend .. ': B still captured after an external close and one press')
  assert(press('PAD2') == 'world:' .. world.PAD2, backend .. ': second B after an external close must be the game\'s')
  assert(#blocked == 0, backend .. ': blocked protected calls: ' .. table.concat(blocked, ', '))
  leaveCombat(); worldBack(backend .. ' external close postcombat')
  print('PASS ' .. backend .. ': external combat close releases B by the next press (first press: ' .. first .. ')')

  -- 3. Regen with the capture never pressed leaves nothing behind (bindings re-applied normally).
  W:Open(); P:Apply('test keep open')
  enterCombat(); leaveCombat()
  assert(W:IsOpen() and P.bound and BagglerPadBroker:Winner() == 'Baggler', backend .. ': kept-open bags must rebind at regen')
  if backend == 'bindings' then
    assert(GetBindingAction('PAD2'):match('^CLICK '), backend .. ': normal B after regen')
  else
    assert(GetBindingAction('PAD2') == world.PAD2 and P.catchMap.PAD2 == 'close', backend .. ': catcher owns B after regen')
  end
  W:Close()
  worldBack(backend .. ' ordinary close')
  print('PASS ' .. backend .. ': combat capture is dropped at regen and ordinary bindings return')

  -- 4. Bags closed when combat starts: B is never touched.
  enterCombat()
  assert(press('PAD2') == 'world:' .. world.PAD2, backend .. ': B taken in combat with no bags open')
  noOtherKeyCaptured(backend .. ' closed bags combat')
  leaveCombat()
  print('PASS ' .. backend .. ': no capture when no bags are open at combat start')

  -- 5. The state driver can resolve before add-ons see PLAYER_REGEN_DISABLED: same result.
  W:Open(); P:Apply('test order')
  COMBAT = true; driver.__state('combat', '1'); event('PLAYER_REGEN_DISABLED')
  noOtherKeyCaptured(backend .. ' driver-first entry')
  assert(press('PAD2'):match('^ui:') and not W:IsOpen(), backend .. ': driver-first order: B must close the bags')
  worldBack(backend .. ' driver-first close')
  leaveCombat()
  print('PASS ' .. backend .. ': driver-first combat entry order')

  -- 6. A game window holding the controller keeps B: no combat capture is armed for it.
  local panel = CreateFrame('Frame', 'TestGamePanel', UIParent)
  W:Open(); P:Apply('test hold'); P:HoldGame(panel, 'test panel', false, true)
  assert(P.handedOff and P.holdGame == panel, backend .. ': precondition, controller handed to the game window')
  enterCombat()
  assert(press('PAD2') == 'world:' .. world.PAD2, backend .. ': B captured in combat while a game window had it')
  leaveCombat(); panel:Hide(); W:Close(); P:Reconcile('test hold end')
  print('PASS ' .. backend .. ': no combat capture while a game window holds the controller')
  assert(#blocked == 0, backend .. ': blocked protected calls: ' .. table.concat(blocked, ', '))
end
-- HYPOTHESIS PROBE (not part of the default suite): the game's own controller keys are
-- `CLICK InputFunctionBindingButton_<KEY>` (see the saved padbind journal), and the triggers
-- are tracked by DOWN/UP pairs. Baggler overrides PADLTRIGGER/PADRTRIGGER while bags are
-- open and drops them at combat entry (and at bind time), so a physical press can have its
-- DOWN routed to one owner and its UP to another. This only proves the SPLIT exists in
-- Baggler's binding ownership; whether the native binding manager then stays wedged is NOT
-- provable offline. Run: timeout 60 luajit addons/Baggler/Tests/combat_b_close_test.lua --press-split
if arg[1] == '--press-split' then
  local native = 'CLICK InputFunctionBindingButton_PADLTRIGGER:LeftButton'
  world.PADLTRIGGER = native
  CB.db.pad.backend = 'bindings'
  local splits = {}
  local function halves(label, setup, change)
    setup()
    local downTo = GetBindingAction('PADLTRIGGER')
    change()
    local upTo = GetBindingAction('PADLTRIGGER')
    if downTo ~= upTo then
      splits[#splits + 1] = label .. ': DOWN->' .. downTo .. ' but UP->' .. upTo
      print('SPLIT ' .. splits[#splits])
    else print('whole ' .. label) end
  end
  halves('bags open, trigger held, combat starts',
    function() W:Open(); P:Apply('probe') end, enterCombat)
  W:Close(); leaveCombat()
  halves('trigger held, bags opened (out of combat)',
    function() end, function() W:Open(); P:Apply('probe') end)
  W:Close(); P:Apply('probe cleanup'); world.PADLTRIGGER = nil
  assert(#splits == 0, #splits .. ' press(es) would have DOWN and UP routed to different owners')
end
-- Explicit RED acceptance probe for the still-unimplemented during-combat open
-- case. Not part of the passing default suite until a supported exclusive-close
-- path exists. Run:
-- timeout 60 luajit addons/Baggler/Tests/combat_b_close_test.lua --during-combat-open
-- This intentionally fails rather than accepting an observer that also fires
-- WORLD_B, a permanent reservation, or an insecure protected binding write.
if arg[1] == '--during-combat-open' then
  local failures = {}
  for _, backend in ipairs({ 'bindings', 'catcher' }) do
    CB.db.pad.backend = backend
    wipe(blocked)
    local ok, err = pcall(function()
      enterCombat()
      assert(not W:IsOpen() and #P.stack == 0, 'precondition: enter combat with bags closed')
      assert(press('PAD2') == 'world:' .. world.PAD2, 'closed bags must preserve world B')
      for attempt = 1, 3 do
        W:Open()
        assert(W:IsOpen() and P:Top() == W.ctx, 'real combat open must push the bags')
        local route = press('PAD2')
        assert(not W:IsOpen() and #P.stack == 0,
          backend .. ': bags opened DURING combat did not close on B (attempt ' .. attempt .. ', route=' .. route .. ')')
        assert(route:match('^ui:'), 'handled B must not also fire a world action')
        worldBack(backend .. ' during-combat close ' .. attempt)
        assert(press('PAD2') == 'world:' .. world.PAD2, 'next B must reach world immediately')
        assert(press('PAD1') == 'world:JUMP', 'A must still reach world immediately')
        assert(press('PADFORWARD') == 'world:TOGGLEGAMEMENU', 'native menu binding must be untouched')
        assert(#blocked == 0, 'insecure protected calls: ' .. table.concat(blocked, ', '))
      end
    end)
    W:Close(); leaveCombat(); worldBack(backend .. ' probe cleanup')
    if not ok then
      failures[#failures + 1] = tostring(err)
      print('FAIL ' .. tostring(err))
    else
      print('PASS ' .. backend .. ': during-combat open -> B close -> world input, three reopens')
    end
  end
  assert(#failures == 0, 'during-combat open acceptance remains blocked: ' .. #failures .. ' backend(s) failed')
end
print('ALL PASS combat B close (offline only; not an in-game proof)')
