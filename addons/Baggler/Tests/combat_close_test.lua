-- Run from repository root: timeout 60 luajit addons/Baggler/Tests/combat_close_test.lua
-- Real TOC / real lifecycle, simulated client boundary. Not an in-game taint proof.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
local create, driver, secure, protectedWrites = CreateFrame, nil, false, 0
local owned, world = {}, { PAD1 = 'WORLD_ACTION', PAD2 = 'WORLD_BACK' }
local function protected(op)
  if COMBAT and not secure then protectedWrites = protectedWrites + 1; error('protected combat write: ' .. op) end
end
function SetBinding() error('must never change global bindings') end
function ClearOverrideBindings() error('must not clear another owner') end
function SetOverrideBindingClick() error('must use restricted owner, not addon overrides') end
function CreateFrame(kind, name, parent, template)
  local f = create(kind, name, parent, template)
  if name == 'BagglerPadOwner' then
    local handle = {}
    function handle:ClearBindings() wipe(owned) end
    function handle:SetBindingClick(_, key, target, button) owned[key] = 'CLICK ' .. target .. ':' .. button end
    function handle:SetBinding(_, key, action) owned[key] = action end
    function handle:SetAttribute(k, v) f.__attr = f.__attr or {}; f.__attr[k] = v end
    function handle:GetAttribute(k) return f.__attr and f.__attr[k] end
    function f:Execute(body)
      protected('Execute')
      return assert(loadstring('return function(self) ' .. body .. ' end'))()(handle)
    end
    f.__driver = function(state)
      secure = true
      local fn = assert(loadstring('return function(self, newstate) ' .. f:GetAttribute('_onstate-combat') .. ' end'))
      setfenv(fn, { gmatch = string.gmatch })   -- the restricted environment: no add-on globals
      fn()(handle, tonumber(state) or state)   -- client: resolveDriver hands the snippet a number
      secure = false
    end
  end
  if template and template:find('SecureActionButtonTemplate') then
    local setAttribute = f.SetAttribute
    function f:SetAttribute(...) protected('secure action SetAttribute'); return setAttribute(self, ...) end
  end
  if kind == "Frame" then
    function f:EnableGamePadButton(on) protected('EnableGamePadButton'); self.__padEnabled = on end
    function f:SetPropagateKeyboardInput(on) protected('SetPropagateKeyboardInput'); self.__propagate = on end
  end
  return f
end
function RegisterStateDriver(f, state, condition)
  assert(state == 'combat' and condition == '[combat] 1; 0')
  driver = f
end
function GetBindingAction(key) return owned[key] or world[key] or '' end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name) end
CB.eventFrame.__scripts.OnEvent(CB.eventFrame, 'ADDON_LOADED', 'Baggler')
event('PLAYER_LOGIN'); FLUSH()
CB.db.pad.mode = 'on'
local P, W = CB.Pad, CB.Window
local function enterCombat()
  COMBAT = true; driver.__driver('1'); event('PLAYER_REGEN_DISABLED')
end
local function leaveCombat()
  COMBAT = false; driver.__driver('0'); event('PLAYER_REGEN_ENABLED')
end
-- B may stay on the secure combat close button (only B, only to close) while bags that were open at combat
-- start are still up or until the next B / regen; every other key must be the game's.
local COMBAT_B = 'CLICK BagglerPadCombatClose:LeftButton'
local function released(where, bMayCloseBags)
  local c = P:Receiver()
  assert(not c:IsShown() or c.__propagate == true, where .. ': catcher still shown with propagation disabled')
  assert(next(P.catchMap) == nil, where .. ': stale catcher actions/held buttons')
  assert(not P.bound and not P.directArmed, where .. ': stale binding/direct-use state')
  local b = GetBindingAction('PAD2')
  assert(GetBindingAction('PAD1') == world.PAD1 and (b == world.PAD2 or (bMayCloseBags and b == COMBAT_B)),
    where .. ': controller not released to world bindings (PAD2=' .. tostring(b) .. ')')
  for key, act in pairs(owned) do
    assert(bMayCloseBags and key == 'PAD2' and act == COMBAT_B, where .. ': stray combat override ' .. key .. '=' .. act)
  end
  assert(protectedWrites == 0, where .. ': attempted protected writes during combat')
end
for _, backend in ipairs({ 'bindings', 'catcher' }) do
  CB.db.pad.backend = backend
  W:Open(); P:Apply('test open')
  assert(P.bound == true, 'precondition: actual backend must bind successfully')
  if backend == 'bindings' then assert(next(owned), 'test must execute real secure binding body') end
  assert(P:WriteMacro(0, 1), 'precondition: highlighted item direct-use macro must arm')
  P.directArmed = true
  -- Simulate a handled catcher DOWN just before combat; its UP arrives too late.
  local c = P:Receiver()
  c:GetScript('OnGamePadButtonDown')(c, 'PADDUP') -- real observation, no private held-state injection
  c:SetPropagateKeyboardInput(false)
  enterCombat()
  released(backend .. ' combat entry', true)
  assert(GetBindingAction('PAD2') == COMBAT_B, 'bags open at combat start: B must be the secure combat close')
  print('PASS ' .. backend .. ': combat entry releases catcher and secure overrides without insecure protected writes')
  -- A stale hold/yield must not survive closing the final bag context in combat.
  P.holdGame, P.holdName, P.holdKeep = CreateFrame('Frame'), 'stale panel', true
  P.handedOff, P.yield = true, true
  W:Close()
  assert(not W:IsOpen() and #P.stack == 0, 'combat close must pop the real bag context')
  released(backend .. ' combat close', true)
  assert(not P.holdGame and not P.handedOff and not P.yield, 'combat close retained hand-off/yield state')
  assert(P.pending, 'restricted binding cleanup must remain pending until combat ends')
  leaveCombat()
  assert(not P.pending and not BagglerPadBroker:Has('Baggler') and not BagglerPadBroker:Winner(), 'postcombat broker cleanup incomplete')
  released(backend .. ' postcombat')
  assert(P.appliedBinds == nil, 'postcombat restricted cleanup incomplete')
  print('PASS ' .. backend .. ': combat close forgets stale ownership; regen drains pending cleanup')
  W:Open(); P:Apply('test reopen')
  assert(P.bound and BagglerPadBroker:Winner() == 'Baggler' and #P.stack == 1, 'subsequent bags reopen must capture normally')
  W:Close()
  assert(not BagglerPadBroker:Has('Baggler') and next(owned) == nil, 'ordinary close after combat must release only own overrides')
  print('PASS ' .. backend .. ': subsequent reopen and ordinary close work')
  -- Opening and closing entirely inside combat must not recreate the catcher
  -- or write secure action attributes; leaving bags open must resume at regen.
  enterCombat()
  W:Open(); event('GAME_PAD_ACTIVE_CHANGED')
  released(backend .. ' combat open')
  W:Close(); released(backend .. ' combat open-close')
  W:Open(); released(backend .. ' combat reopen')
  leaveCombat()
  assert(P.bound and BagglerPadBroker:Winner() == 'Baggler', 'bags kept open must bind on regen')
  W:Close()
  print('PASS ' .. backend .. ': combat-only open/close, device event and kept-open regen resume')
end
-- Cosmetic equipped-bag metadata must not replace the existing pickup/swap path.
CB.db.showBagSlots = true
C_Container.ContainerIDToInventoryID = function(bag) return 19 + bag end
C_Container.GetContainerNumSlots = function(bag) return ({ [1] = 8, [2] = 12 })[bag] or 0 end
C_Container.GetContainerNumFreeSlots = function(bag) return 0, ({ [1] = 0, [2] = 32 })[bag] end
GetInventoryItemTexture = function(_, inv) if inv == 20 or inv == 21 then return 'bag-icon' end end
GetInventoryItemLink = function(_, inv) if inv == 21 then return '|Hitem:200|h[Herb Bag]|h' end end
C_Item.GetItemInfo = function() return 'Herb Bag', nil, nil, nil, nil, nil, 'Herb Bag' end
W:UpdateBagSlots()
local slots = W.frame.bagSlots
assert(slots[1].capacity and slots[1].capacity:GetText() == '8', 'equipped general bag must show small capacity number')
assert(slots[2].capacity:GetText() == '12' and slots[2].specialty:GetText() == '*', 'specialty bag must show capacity and subtle marker')
assert(slots[2].bagKind == 'Herb Bag', 'specialty metadata must use item subtype when available')
assert(slots[1].specialty:GetText() == '' and slots[3].capacity:GetText() == '', 'general/empty slots must not show misleading specialty/capacity')
local lines, addLine = {}, GameTooltip.AddLine
GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
slots[2]:GetScript('OnEnter')(slots[2])
assert(lines[1] == '12 slots - Herb Bag', 'equipped tooltip must explain capacity and specialty')
GameTooltip.AddLine = addLine
local click, receive, drag = slots[2].cbClick, slots[2]:GetScript('OnReceiveDrag'), slots[2]:GetScript('OnDragStart')
COMBAT = true; W:UpdateBagSlots(); COMBAT = false
assert(slots[2].cbClick == click and slots[2]:GetScript('OnReceiveDrag') == receive
  and slots[2]:GetScript('OnDragStart') == drag, 'cosmetics must retain native pickup/drop swap handlers')
assert(protectedWrites == 0, 'cosmetic bag refresh must not write protected controller state')
print('PASS equipped bag capacity, specialty marker, tooltip and unchanged pickup/drop handlers')
print('ALL PASS combat close lifecycle and bag metadata (offline only)')
