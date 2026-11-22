-- Run from repository root: timeout 90 luajit addons/Baggler/Tests/stack_split_merchant_test.lua
-- Regression (live report, independent controller stack): at a merchant, Start to the bags, Y -> Split stack opened the
-- amount dialog but the controller stayed with the MERCHANT: the amount could not be changed or confirmed.
-- Same real TOC / client model as stack_split_focus_test.lua, plus a visible native MerchantFrame (native-first visit,
-- Start hop) and an optional second overlapping native window (CharacterFrame). The game's receiver is modelled as the
-- game does it: when no add-on binding owns a key, the topmost native modal (StackSplitFrame) gets A/B/D-pad, otherwise
-- the visible native window gets it (recorded in `nativeGot`). Offline only: not an in-game proof.
-- WARNING: that "topmost modal gets input" receiver is an ASSUMPTION, not the client's behaviour. In the client's own
-- source (GamepadFrameControlsManager) native pad focus is `focusedFrame`, set by FrameShown/FocusFrame and re-stolen by
-- any later FrameShown/FocusFrame call; it is not stacking order. This test cannot confirm the live fix.
dofile('tests/harness/ca_stubs.lua')
local now = 100
function GetTime() return now end
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end

local create = CreateFrame
local world = { PAD1 = 'JUMP', PAD2 = 'WORLD_B', PAD3 = 'WORLD_X', PAD4 = 'WORLD_Y', PADFORWARD = 'TOGGLEGAMEMENU',
  PADDUP = 'WORLD_UP', PADDDOWN = 'WORLD_DOWN', PADDLEFT = 'WORLD_LEFT', PADDRIGHT = 'WORLD_RIGHT' }
local overrides, order = {}, {}
local secure = false
local driver
function SetBinding() error('must never change global bindings') end
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
  function h:ClearBindings() wipe(ownerTable(f)) end
  function h:ClearBinding(key) ownerTable(f)[key] = nil end
  function h:SetBindingClick(_, key, target, button) ownerTable(f)[key] = 'CLICK ' .. target .. ':' .. (button or 'LeftButton') end
  function h:SetBinding(_, key, action) ownerTable(f)[key] = action end
  function h:GetAttribute(k) return f.__attr and f.__attr[k] end
  function h:SetAttribute(k, v) f.__attr = f.__attr or {}; f.__attr[k] = v end
  function h:GetName() return f:GetName() end
  function h:GetFrameRef(label) local r = f.__attr and f.__attr['frameref-' .. label]; return r and r.__handle end
  return h
end
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
  function f:RegisterForClicks(...) self.__clicks = {}; for _, c in ipairs({ ... }) do self.__clicks[c] = true end end
  function f:SetPropagateKeyboardInput(on) self.__propagate = on end
  if template and template:find('SecureHandler') then
    f.__handle = handleFor(f)
    local setAttribute = f.SetAttribute
    function f:SetAttribute(k, v) return setAttribute(self, k, v) end
    function f:Execute(body)
      local fn = assert(loadstring('return function(self) ' .. body .. ' end'))
      setfenv(fn, restrictedEnv)
      local was = secure; secure = true
      local ok, err = pcall(fn(), self.__handle)
      secure = was
      assert(ok, 'Execute failed: ' .. tostring(err))
    end
    function f:SetFrameRef(label, ref) setAttribute(self, 'frameref-' .. label, ref) end
    if template:find('SecureHandlerStateTemplate') then
      f.__state = function(state, value) runSnippet(f, '_onstate-' .. state, 'self, stateid, newstate', state, tonumber(value) or value) end -- client: resolveDriver hands the snippet a number
    end
    if template:find('SecureHandlerClickTemplate') then
      f.__scripts.OnClick = function(self, button, down) runSnippet(self, '_onclick', 'self, button, down', button, down) end
    end
  end
  if kind == "Frame" then
    function f:EnableGamePadButton(on) self.__padEnabled = on end
  end
  return f
end
function RegisterStateDriver(f, state, condition) driver = f end

---------------------------------------------------------------------------
-- Native windows: the merchant (+ a second overlapping window) and the native StackSplitFrame
---------------------------------------------------------------------------
local usedSecure = {}
local splitCalls = {}
local cursor = false
function CursorHasItem() return cursor end
C_Container.SplitContainerItem = function(bag, slot, amount)
  splitCalls[#splitCalls + 1] = { bag, slot, amount }
  cursor = true
end
local stack = create('Frame', 'StackSplitFrame', UIParent)
stack:Hide()
stack.split, stack.max = 1, 1
function stack:OpenStackSplitFrame(maxStack, parent)
  self.max, self.owner, self.split = maxStack, parent, 1
  self:Show()
end
local function stackOkay() local owner, n = stack.owner, stack.split; stack:Hide(); if owner and owner.SplitStack then owner:SplitStack(n) end end
local function stackCancel() stack:Hide() end
local merchant = create('Frame', 'MerchantFrame', UIParent); merchant:Hide()
local character = create('Frame', 'CharacterFrame', UIParent); character:Hide()
local nativeGot = {}      -- keys the game's own navigation delivered to a native window other than the split dialog

local CB = {}
BagglerDB = { replaceBank = false, bankOptInMigrated = true, personalBankRestored1 = true }
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
now = 120
CB.db.pad.mode = 'on'
local P, W, M = CB.Pad, CB.Window, CB.Menu
local function fireSecureUse()
  usedSecure[#usedSecure + 1] = P:UseButton():GetAttribute('macrotext') or ''
end

local function tick(seconds)
  now = now + seconds
  for _, f in ipairs(frames) do
    local h = f.__scripts and f.__scripts.OnUpdate
    if h and f.__shown then pcall(h, f, seconds) end
  end
  FLUSH(); FLUSH()
end

local function press(key)
  local action = GetBindingAction(key)
  local target, button = tostring(action):match('^CLICK ([%w_]+):(%w+)$')
  if target then
    local f = assert(_G[target], 'binding to a missing button ' .. target)
    if target == 'BagglerPadUse' then fireSecureUse(f) end
    local c = f.__clicks or {}
    if c.AnyDown or c.LeftButtonDown then f:Click(button, true) end
    if c.AnyUp or c.LeftButtonUp then f:Click(button, false) end
    FLUSH()
    return 'ours:' .. target
  end
  -- no add-on binding owns the key: the add-on's reception frame (enabled only on a native route) sees it first, as
  -- OnGamePadButtonDown; if it consumes the press (propagation off) the game never sees it.
  local recv = P:Receiver()
  if recv and recv.__shown and recv.__padEnabled then
    recv.__propagate = true
    recv.__scripts.OnGamePadButtonDown(recv, key); recv.__scripts.OnGamePadButtonUp(recv, key)
    FLUSH()
    if recv.__propagate == false then return 'ours:receiver' end
  end
  if stack:IsShown() then
    if key == 'PADDUP' or key == 'PADDRIGHT' then stack.split = math.min(stack.max, stack.split + 1); return 'native:up' end
    if key == 'PADDDOWN' or key == 'PADDLEFT' then stack.split = math.max(1, stack.split - 1); return 'native:down' end
    if key == 'PAD1' then stackOkay(); return 'native:confirm' end
    if key == 'PAD2' then stackCancel(); return 'native:cancel' end
  end
  if merchant:IsShown() or character:IsShown() then nativeGot[#nativeGot + 1] = key; return 'merchant:' .. key end
  return 'world:' .. tostring(action)
end

local function selectPotion()
  for _, e in ipairs(W.nav) do
    if e.rec and e.rec.bag == 0 and e.rec.slot == 5 then W:SelectEntry(e); return e end
  end
  error('Healing Potion (0:5, count 5) is not in the bag layout')
end

-- Merchant visit as the game delivers it: the bags open, the native merchant takes the controller first, Start hops
-- to the bags. `second` adds an overlapping native window (the character panel).
local function startToBags()
  now = now + 1
  press('PADFORWARD'); FLUSH(); tick(0.2)
end
local function reset(withMerchant, second)
  stack:Hide(); merchant:Hide(); character:Hide(); M:Close(); W:Close(); P:Reset()
  CB.NativeWindows.active = {}; CB.NativeWindows.endedAt = nil
  P.seenGame, P.declinedGame = {}, {}
  wipe(splitCalls); wipe(usedSecure); wipe(nativeGot); cursor = false
  now = now + 5
  if withMerchant then
    merchant:Show(); event('MERCHANT_SHOW')
    if second then character:Show() end
    FLUSH(); tick(0.2)
    W:Open(); FLUSH(); tick(0.2)
    CB.NativeWindows:FocusNativeFirst(merchant); tick(0.3)
    assert(P.handedOff and P.holdGame == merchant, 'precondition: native merchant has the controller first')
    startToBags()
    assert(P:Top() == W.ctx and not P.handedOff, 'precondition: Start hops to the bags')
  else
    if second then character:Show() end
    W:Open(); FLUSH(); tick(0.2)
  end
  assert(W:IsOpen(), 'precondition: bags open')
  selectPotion(); P:SyncDirectUse(); FLUSH()
  assert(P:Top() == W.ctx, 'precondition: the bags own the controller')
  assert(GetBindingAction('PAD4'):match('^CLICK '), 'precondition: our Y is bound')
  wipe(nativeGot)
end
local function openSplitFromMenu()
  assert(press('PAD4'):match('^ours:'), 'Y must open the item menu')
  assert(M:IsOpen() and P:Top() == M.ctx, 'the menu owns the controller')
  local guard = 0
  while M.entries[M.index].text ~= 'Split stack' do
    assert(press('PADDDOWN'):match('^ours:'), 'menu navigation')
    guard = guard + 1
    assert(guard < 40, 'no "Split stack" row')
  end
  press('PAD1')
  FLUSH(); tick(0.15)
end
local function dialogOwnsFocus(where)
  local r, e = P:Receiver(), P.input
  assert(not (r.__shown and r.__padEnabled) and not e.visit and not e.nativeFocus and not e.env.winner,
    where .. ': no native-window visit, receiver or add-on binding owner while the dialog is up')
  local tile = stack.owner and stack.owner.cbButton   -- the owner is a plain anchor over the tile (View:SplitAnchor)
  assert(stack:IsShown() and tile and tile.cbBag == 0 and tile.cbSlot == 5, where .. ': native dialog open for 0:5')
  for _, key in ipairs({ 'PAD1', 'PAD2', 'PADDUP', 'PADDDOWN', 'PADDLEFT', 'PADDRIGHT' }) do
    local a = GetBindingAction(key)
    assert(not tostring(a):find('^CLICK Baggler'), where .. ': ' .. key .. ' still bound to ' .. a .. ' while the split dialog owns focus')
  end
  assert(P.handedOff, where .. ': pad must be handed off to the game while the dialog is up')
  assert(not P.directArmed, where .. ': secure direct-use must not be armed under the modal')
  assert(not (P.input.visit and P.input.nativeFocus and P.holdGame and P.holdGame:IsShown() and P.holdGame ~= stack
    and P.holdGame == merchant), where .. ': merchant must not be the native receiver while the split dialog is up')
end
local function bagsRestored(where, withMerchant)
  tick(0.6)
  assert(not stack:IsShown(), where .. ': dialog should be closed')
  assert(P:Top() == W.ctx and not P.handedOff and not P.holdGame, where .. ': bags must be the pad owner again (handedOff=' ..
    tostring(P.handedOff) .. ' hold=' .. tostring(P.holdGame and P.holdGame:GetName()) .. ' nativeFocus=' .. tostring(P.input.nativeFocus) .. ')')
  assert(GetBindingAction('PAD4'):match('^CLICK '), where .. ': our Y must be back, got ' .. GetBindingAction('PAD4'))
  assert(GetBindingAction('PAD1'):match('^CLICK '), where .. ': our A must be back')
  if withMerchant then assert(merchant:IsShown(), where .. ': merchant is still up') end
end

local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print('PASS split+merchant: ' .. name) end

for _, scenario in ipairs({ { 'no merchant', false, false }, { 'merchant', true, false }, { 'merchant + overlapping native window', true, true } }) do
  local label, withMerchant, second = scenario[1], scenario[2], scenario[3]
  check(label .. ': Y -> Split stack gives the NATIVE dialog the controller', function()
    reset(withMerchant, second); openSplitFromMenu(); dialogOwnsFocus(label)
  end)
  check(label .. ': D-pad adjusts, A confirms once, bags get the controller back', function()
    reset(withMerchant, second); openSplitFromMenu(); dialogOwnsFocus(label)
    assert(press('PADDUP') == 'native:up' and press('PADDUP') == 'native:up' and stack.split == 3, 'D-pad must adjust the amount')
    assert(press('PADDDOWN') == 'native:down' and stack.split == 2)
    assert(press('PAD1') == 'native:confirm', 'A must reach the dialog')
    assert(#splitCalls == 1 and splitCalls[1][3] == 2, 'exactly one split of 2, got ' .. #splitCalls)
    assert(#usedSecure == 0 and #nativeGot == 0, 'A must not use the item nor reach the merchant')
    bagsRestored(label .. ' confirm', withMerchant)
  end)
  check(label .. ': B cancels without splitting or closing the bags', function()
    reset(withMerchant, second); openSplitFromMenu(); dialogOwnsFocus(label)
    assert(press('PAD2') == 'native:cancel')
    assert(W:IsOpen() and #splitCalls == 0 and #nativeGot == 0)
    bagsRestored(label .. ' cancel', withMerchant)
  end)
  check(label .. ': repeated opens never stick or duplicate', function()
    reset(withMerchant, second)
    for i = 1, 4 do
      openSplitFromMenu(); dialogOwnsFocus(label .. ' #' .. i)
      if i % 2 == 1 then assert(press('PAD2') == 'native:cancel') else assert(press('PAD1') == 'native:confirm') end
      bagsRestored(label .. ' repeat #' .. i, withMerchant)
      assert(press('PAD4'):match('^ours:'), 'Y works again after #' .. i)
      M:Close(); FLUSH()
    end
    assert(#splitCalls == 2, 'only the two confirmed opens split, got ' .. #splitCalls)
  end)
  check(label .. ': dialog closed externally never strands the pad', function()
    reset(withMerchant, second); openSplitFromMenu(); dialogOwnsFocus(label)
    stack:Hide(); bagsRestored(label .. ' external close', withMerchant)
  end)
end

check('merchant: the dialog keeps the controller while the player takes their time (watchers keep running)', function()
  for _, second in ipairs({ false, true }) do
    reset(true, second); openSplitFromMenu()
    for _ = 1, 30 do
      tick(0.1); dialogOwnsFocus('lingering')
      assert(stack:IsShown(), 'dialog still up')
    end
    assert(press('PADDUP') == 'native:up' and press('PAD1') == 'native:confirm' and #splitCalls == 1)
    bagsRestored('after lingering', true)
  end
end)

check('merchant: game events while the dialog is up (bag/merchant/cursor updates) never move the controller to the merchant', function()
  local events = { 'BAG_UPDATE', 'BAG_UPDATE_DELAYED', 'MERCHANT_UPDATE', 'ITEM_LOCK_CHANGED', 'CURSOR_CHANGED',
    'PLAYER_MONEY', 'UNIT_INVENTORY_CHANGED', 'GET_ITEM_INFO_RECEIVED', 'BAG_NEW_ITEMS_UPDATED' }
  for _, second in ipairs({ false, true }) do
    for _, ev in ipairs(events) do
      reset(true, second); openSplitFromMenu()
      event(ev, 0); FLUSH(); tick(0.15)
      dialogOwnsFocus(ev)
      tick(1.0); dialogOwnsFocus(ev .. ' later')
      assert(press('PAD1') == 'native:confirm', ev .. ': A reaches the dialog')
      bagsRestored('after ' .. ev, true)
    end
  end
end)

check('merchant: a bags re-focus or a forgotten "declined" mark while the dialog is up does not make the merchant the receiver', function()
  for _, second in ipairs({ false, true }) do
    reset(true, second); openSplitFromMenu()
    P:Push(W.ctx); FLUSH(); tick(0.15); dialogOwnsFocus('re-push')
    P.declinedGame = {}; P.seenGame = {}
    tick(0.5); dialogOwnsFocus('declined forgotten')
    tick(1.0); dialogOwnsFocus('declined forgotten later')
    assert(press('PAD1') == 'native:confirm' and #nativeGot == 0)
    tick(0.6)   -- (with the decline mark forgotten the merchant may legitimately be auto-held after the dialog: not asserted)
    assert(not stack:IsShown() and #splitCalls == 1)
    reset(true, second); openSplitFromMenu()
    P.declinedGame = {}; P.seenGame = {}; tick(0.5); dialogOwnsFocus('declined forgotten only')
    assert(press('PAD1') == 'native:confirm' and #nativeGot == 0)
    tick(0.6)
    assert(not stack:IsShown() and #splitCalls == 1)
  end
end)

check('merchant: the game re-opening its bags for the merchant (paired native-first request) while the dialog is up does not hand the controller to the merchant', function()
  for _, second in ipairs({ false, true }) do
    reset(true, second); openSplitFromMenu()
    CB.NativeWindows:FocusNativeFirst(merchant); tick(0.15); dialogOwnsFocus('native-first request')
    tick(1.0); dialogOwnsFocus('native-first request later')
    assert(press('PADDUP') == 'native:up' and press('PAD1') == 'native:confirm' and #nativeGot == 0)
    bagsRestored('native-first request', true)
  end
end)

check('merchant: the same request with no modal still gives the merchant the controller first (unchanged)', function()
  reset(true, false)
  M:Close(); P:Push(W.ctx); tick(0.2)
  CB.NativeWindows:FocusNativeFirst(merchant); tick(0.3)
  assert(P.handedOff and P.holdGame == merchant, 'native-first still works without a modal')
end)

check('merchant: A held across the dialog opening is not replayed into the dialog (no duplicate/stuck)', function()
  reset(true, false)
  assert(press('PAD4'):match('^ours:'))
  while M.entries[M.index].text ~= 'Split stack' do press('PADDDOWN') end
  P:Press('confirm', true, 'binding', 'PAD1')                -- A goes down on the row; the dialog opens under the press
  FLUSH(); tick(0.15)
  assert(stack:IsShown(), 'dialog open')
  P:Press('confirm', false, 'binding', 'PAD1')               -- the same press is released with the dialog up
  FLUSH(); tick(0.15)
  assert(#splitCalls == 0 and #usedSecure == 0, 'the opening press must not confirm/use anything')
  dialogOwnsFocus('held A')
  stack:Hide(); bagsRestored('held A', true)
end)

check('merchant: Start while the dialog is up does not hand the controller to the merchant', function()
  reset(true, false); openSplitFromMenu(); dialogOwnsFocus('start under dialog')
  press('PADFORWARD'); FLUSH(); tick(0.2)
  assert(stack:IsShown(), 'dialog stays')
  assert(not tostring(GetBindingAction('PAD1')):find('^CLICK Baggler'), 'still the dialog\'s keys')
  assert(press('PAD1') == 'native:confirm' or #splitCalls == 1, 'A reaches the dialog')
end)

assert((CB.errorCount or 0) == 0, 'shipping modules logged Lua errors')
print(('ALL PASS stack split + merchant (%d cases; offline only, not an in-game proof)'):format(passed))
