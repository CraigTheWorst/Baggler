-- Run from repository root: timeout 90 luajit addons/Baggler/Tests/stack_split_focus_test.lua
-- Regression (live report): Y menu -> "Split stack" showed Blizzard's amount dialog, but the controller stayed on the
-- bags: the amount could not be changed, A did not confirm, the dialog could not be operated.
-- Path under test (real TOC, real Menu / WindowMenus / WindowPad / Gamepad code): the item menu's "Split stack" row calls
-- the NATIVE StackSplitFrame:OpenStackSplitFrame(count, button, ...) (WindowMenus.lua); there is no custom quantity modal in
-- the shipping TOC (Vendor.lua's BagglerQuantity picker is retired). Focus ownership for a game modal is Pad:GameNeedsPad
-- -> Pad:HandOff (release our bindings so the game's own controller navigation drives the dialog) -> Pad:Reclaim.
-- Client boundary modelled after Blizzard's StackSplitFrame: OpenStackSplitFrame(maxStack, parent, anchor, anchorTo)
-- stores the owner and shows the frame; Okay calls owner:SplitStack(amount); Cancel only hides. The game's gamepad
-- navigation reaches the dialog ONLY when no add-on override binding owns the key (what is simulated below).
-- Offline only: this is not proof of in-game behaviour; the live acceptance steps are in the final report.
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
-- The native StackSplitFrame (modelled; see header)
---------------------------------------------------------------------------
local usedSecure = {}          -- /use macros fired by the secure use button: a use while the dialog is up is the bug
local splitCalls = {}          -- C_Container.SplitContainerItem(bag, slot, amount)
local cursor = false
function CursorHasItem() return cursor end
C_Container.SplitContainerItem = function(bag, slot, amount)
  splitCalls[#splitCalls + 1] = { bag, slot, amount }
  cursor = true
end
local stack = create('Frame', 'StackSplitFrame', UIParent)
stack:Hide()
stack.split, stack.max = 1, 1
-- Native StackSplitMixin:OpenStackSplitFrame sets parent.hasStackSplit = 1; OnHide sets owner.hasStackSplit = 0
-- (StackSplitFrame.lua at client source 70862; the 70938 file was not obtainable).
function stack:OpenStackSplitFrame(maxStack, parent)
  if self.owner then self.owner.hasStackSplit = 0 end
  self.max, self.owner, self.split = maxStack, parent, 1
  parent.hasStackSplit = 1
  self:Show()
  if self.afterShow then self.afterShow(self) end   -- test hook: something else the game does synchronously inside Show
end
local rawStackHide = stack.Hide
function stack:Hide()
  if self.owner then self.owner.hasStackSplit = 0 end
  return rawStackHide(self)
end
-- Native ContainerFrameItemButtonMixin:OnHide (ContainerFrame.lua 1816-1822): an item button that owns the dialog hides it
-- when it is hidden, including when its parent holder is hidden. Baggler's item buttons use that template, so model it:
-- hiding a holder that was shown runs the child button's OnHide.
local nativeButtonOnHide = function(button)
  if button.hasStackSplit and button.hasStackSplit == 1 then stack:Hide() end
end
local createForHolders = CreateFrame
function CreateFrame(kind, name, parent, template)
  local f = createForHolders(kind, name, parent, template)
  if template and template:find('ContainerFrameItemButtonTemplate') and parent then
    parent.__nativeChild = f
    if not parent.__holderHideWrapped then
      parent.__holderHideWrapped = true
      local rawHide = parent.Hide
      function parent:Hide()
        local was = self:IsShown()
        rawHide(self)
        if was and self.__nativeChild then nativeButtonOnHide(self.__nativeChild) end
      end
    end
  end
  return f
end
local function stackOkay() local owner, n = stack.owner, stack.split; stack:Hide(); if owner and owner.SplitStack then owner:SplitStack(n) end end
local function stackCancel() stack:Hide() end

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
-- the secure use button's macro is the game's /use; record each time one would fire
local function fireSecureUse(button)
  local text = P:UseButton():GetAttribute('macrotext') or ''
  usedSecure[#usedSecure + 1] = text
end

-- Run every addon OnUpdate once (the 0.1s pad watcher and the 0.5s watchdog), as the client would between key presses.
local function tick(seconds)
  now = now + seconds
  for _, f in ipairs(frames) do
    local h = f.__scripts and f.__scripts.OnUpdate
    if h and f.__shown then pcall(h, f, seconds) end
  end
  FLUSH(); FLUSH()
end

-- A hardware press: an override binding to one of our buttons runs our click; otherwise the game's own controller
-- navigation answers (the native dialog when it is up and has the focus).
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
  if stack:IsShown() then
    if key == 'PADDUP' or key == 'PADDRIGHT' then stack.split = math.min(stack.max, stack.split + 1); return 'native:up' end
    if key == 'PADDDOWN' or key == 'PADDLEFT' then stack.split = math.max(1, stack.split - 1); return 'native:down' end
    if key == 'PAD1' then stackOkay(); return 'native:confirm' end
    if key == 'PAD2' then stackCancel(); return 'native:cancel' end
  end
  return 'world:' .. tostring(action)
end

local function selectPotion()
  for _, e in ipairs(W.nav) do
    if e.rec and e.rec.bag == 0 and e.rec.slot == 5 then W:SelectEntry(e); return e end
  end
  error('Healing Potion (0:5, count 5) is not in the bag layout')
end
local function reset()
  stack:Hide(); M:Close(); W:Close(); P:Reset(); wipe(splitCalls); wipe(usedSecure); cursor = false
  now = now + 5
  W:Open(); FLUSH(); tick(0.2)
  assert(W:IsOpen(), 'precondition: bags open')
  selectPotion(); P:SyncDirectUse(); FLUSH()
  assert(P:Top() == W.ctx, 'precondition: the bags own the controller')
end
-- Y on the highlighted item, then walk the menu to "Split stack" and press A on it (all through real bindings).
local function openSplitFromMenu()
  assert(press('PAD4'):match('^ours:'), 'Y must open the item menu')
  assert(M:IsOpen() and P:Top() == M.ctx, 'the menu owns the controller')
  local guard = 0
  while M.entries[M.index].text ~= 'Split stack' do
    assert(press('PADDDOWN'):match('^ours:'), 'menu navigation')
    guard = guard + 1
    if guard >= 40 then
      local t = {}
      for _, x in ipairs(M.entries) do t[#t + 1] = tostring(x.text) end
      error('no "Split stack" row for a 5-stack; menu ' .. tostring(M.title) .. ': ' .. table.concat(t, ' | '))
    end
  end
  press('PAD1')                           -- A on the row
  FLUSH(); tick(0.15)                     -- the pad's own 0.1s modal check
end
local function bagsRestored(where)
  tick(0.6)
  assert(not stack:IsShown(), where .. ': dialog should be closed')
  assert(P:Top() == W.ctx and not P.handedOff and not P.holdGame, where .. ': bags must be the pad owner again')
  assert(GetBindingAction('PAD4'):match('^CLICK '), where .. ': our Y must be back, got ' .. GetBindingAction('PAD4'))
end

local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print('PASS split focus: ' .. name) end

check('Y -> Split stack shows the NATIVE dialog (the only modal path) and the controller leaves the bags', function()
  reset(); openSplitFromMenu()
  local tile = stack.owner and stack.owner.cbButton
  assert(stack:IsShown() and tile and tile.cbBag == 0 and tile.cbSlot == 5, 'native StackSplitFrame must be open anchored on the 0:5 tile')
  assert(not (stack.owner.GetScript and stack.owner:GetScript('OnHide')) and stack.owner.cbBag == nil,
    'the dialog owner must not be an item-template button (its native OnHide closes the dialog)')
  assert(not _G.BagglerQuantity, 'no custom quantity modal exists in the shipping TOC')
  -- focus ownership: no Baggler override may sit on the dialog's keys
  for _, key in ipairs({ 'PAD1', 'PAD2', 'PADDUP', 'PADDDOWN', 'PADDLEFT', 'PADDRIGHT' }) do
    local a = GetBindingAction(key)
    assert(not tostring(a):find('^CLICK Baggler'), key .. ' still bound to ' .. a .. ' while the split dialog owns focus')
  end
  assert(P.handedOff, 'pad must be handed off to the game while the dialog is up')
  assert(not P.directArmed, 'secure direct-use must not be armed under the modal')
  assert(not (P:Top() == W.ctx and P.bound), 'bags must not remain the bound pad owner under the modal')
end)

check('amount adjust, A once confirms the exact quantity, bags get the controller back', function()
  reset(); openSplitFromMenu()
  assert(press('PADDUP') == 'native:up' and press('PADDUP') == 'native:up' and stack.split == 3, 'D-pad must adjust the native amount')
  assert(press('PADDDOWN') == 'native:down' and stack.split == 2, 'D-pad down lowers the amount')
  assert(press('PAD1') == 'native:confirm', 'A must reach the dialog, not our secure use')
  assert(#splitCalls == 1 and splitCalls[1][1] == 0 and splitCalls[1][2] == 5 and splitCalls[1][3] == 2,
    'exactly one split of exactly 2 from 0:5, got ' .. #splitCalls)
  assert(#usedSecure == 0, 'A must not have used the item: ' .. table.concat(usedSecure, ';'))
  bagsRestored('after confirm')
end)

check('B cancels the dialog without splitting; bags restored', function()
  reset(); openSplitFromMenu()
  assert(press('PAD2') == 'native:cancel', 'B must reach the dialog, not our close')
  assert(W:IsOpen() and #splitCalls == 0, 'cancel must neither split nor close the bags')
  bagsRestored('after cancel')
end)

check('mouse-initiated split (menu row clicked) gives the dialog the same focus and restores it', function()
  reset()
  W:ItemMenu({ rec = W.selEntry.rec, btn = W.selEntry.btn })
  local row
  for i, e in ipairs(M.entries) do if e.text == 'Split stack' then row = i end end
  assert(row, 'Split stack row')
  M:Activate(row); FLUSH(); tick(0.15)         -- a mouse click runs Menu:Activate directly
  assert(stack:IsShown() and P.handedOff, 'dialog up and pad handed off')
  assert(GetBindingAction('PAD1') == 'JUMP' or not tostring(GetBindingAction('PAD1')):find('^CLICK Baggler'), 'A not ours')
  stack.split = 4; stackOkay()
  assert(#splitCalls == 1 and splitCalls[1][3] == 4)
  bagsRestored('mouse path')
end)

check('shift-click / native opener (not through our menu) is covered by the same watcher', function()
  reset()
  stack:OpenStackSplitFrame(5, W.selEntry.btn)
  tick(0.15)
  assert(P.handedOff and not tostring(GetBindingAction('PAD1')):find('^CLICK Baggler'), 'native opener must also hand the pad over')
  stackCancel(); bagsRestored('native opener')
end)

check('repeated opens never leave the pad stuck either way', function()
  reset()
  for i = 1, 3 do
    openSplitFromMenu()
    assert(P.handedOff and stack:IsShown(), 'open #' .. i)
    if i % 2 == 1 then press('PAD2') else press('PAD1') end
    bagsRestored('repeat #' .. i)
    assert(press('PAD4'):match('^ours:'), 'Y works again after #' .. i)
    M:Close(); FLUSH()
  end
  assert(#splitCalls == 1, 'only the confirmed open (#2) splits, got ' .. #splitCalls)
end)

check('stale source: item gone / changed before confirm does not split a different item', function()
  reset(); openSplitFromMenu()
  local saved = STUB_CONTENTS[0][5]
  STUB_CONTENTS[0][5] = { id = 99, q = 1, name = 'Other', class = 0, sub = 0, count = 5 }   -- slot now holds another item
  stack.split = 2; press('PAD1')
  STUB_CONTENTS[0][5] = saved
  assert(#splitCalls == 0, 'a stale slot must not be split')
  bagsRestored('stale item')
end)

check('dialog closed by something else (Escape, walking away) never strands the pad', function()
  reset(); openSplitFromMenu()
  stack:Hide(); tick(0.6)                      -- closed by something else (Escape, walking away)
  bagsRestored('closed externally')
end)

-- Live evidence (20:23, four attempts): the dialog opened with native focus, then was hidden again within 0.4s with no input.
-- Native source: the owner item button's OnHide hides the dialog; Baggler's layout hides every item holder first.
check('a window relayout while the dialog is up does not dismiss it (owner button OnHide path)', function()
  reset(); openSplitFromMenu()
  assert(stack:IsShown(), 'precondition: dialog up')
  CB:Fire('DIRTY'); FLUSH(); tick(0.6)
  assert(stack:IsShown(), 'a relayout of the bag window hid the native amount dialog (owner OnHide)')
  stack.split = 2; press('PAD1')
  assert(#splitCalls == 1 and splitCalls[1][3] == 2, 'confirm after a relayout must still split')
end)

-- Live trace (merchant open, 3 identical attempts): FrameShown(StackSplit) > OnShow > SmartNav.active=nil >
-- StackSplit:Hide() called from ContainerFrameItemButtonMixin:OnHide (ContainerFrame.lua:1820) inside Show > ... > OnHide.
-- The native OnHide hides the GLOBAL dialog for whichever item-template button has hasStackSplit == 1. Which actor hides
-- an item button during Show is not identified; the dialog must not be coupled to any template button's OnHide at all.
check('an item-template button hidden synchronously during Show (merchant open) does not dismiss the dialog', function()
  reset()
  local btn = W.selEntry.btn
  stack.afterShow = function() btn.cbHolder:Hide() end
  local ok, err = pcall(openSplitFromMenu)
  stack.afterShow = nil
  assert(ok, tostring(err))
  assert(stack:IsShown(), 'the native OnHide of an item button closed the dialog during its own Show')
  stack.split = 2; press('PAD1')
  assert(#splitCalls == 1 and splitCalls[1][1] == 0 and splitCalls[1][2] == 5 and splitCalls[1][3] == 2,
    'confirm must split exactly 2 from 0:5, got ' .. #splitCalls)
  btn.cbHolder:Show(); FLUSH()
end)

check('closing the bag window takes the dialog with it', function()
  reset(); openSplitFromMenu()
  assert(stack:IsShown(), 'precondition')
  W:Close(); FLUSH(); tick(0.2)
  assert(not stack:IsShown(), 'the dialog must not outlive the window it was opened from')
end)

assert((CB.errorCount or 0) == 0, 'shipping modules logged Lua errors')
print(('ALL PASS stack split focus (%d cases; offline only, not an in-game proof)'):format(passed))
