-- Shipping TOC + actual receiver/binding entry points. Offline routing model,
-- not proof of native hardware dispatch, secure execution or in-game focus.
-- Pin: Gethe/wow-ui-source 734f065329cff4992835b01a84f210a297db91b6 (71037).
dofile('tests/harness/ca_stubs.lua')
local create, focus = CreateFrame, nil
CreateFrame = function(kind, ...)
  local f = create(kind, ...)
  if kind == 'EditBox' then
    function f:SetFocus()
      if focus == self then return end
      if focus then focus:ClearFocus() end
      focus = self
      local fn = self:GetScript('OnEditFocusGained'); if fn then fn(self) end
    end
    function f:ClearFocus()
      if focus ~= self then return end
      focus = nil
      local fn = self:GetScript('OnEditFocusLost'); if fn then fn(self) end
    end
    function f:HasFocus() return focus == self end
  end
  return f
end
function GetCurrentKeyBoardFocus() return focus end
function UnitClass() return 'Warrior', 'WARRIOR' end
local indices, buttons = {}, {}
for i, key in ipairs({'PAD1','PAD2','PAD3','PAD4','PADBACK','PADFORWARD','PADLSHOULDER','PADRSHOULDER',
  'PADLTRIGGER','PADRTRIGGER','PADLSTICK','PADRSTICK','PADDUP','PADDDOWN','PADDLEFT','PADDRIGHT'}) do
  indices[key], buttons[i] = i - 1, false
end
C_GamePad.GetActiveDeviceID = function() return 1 end
C_GamePad.GetDeviceMappedState = function() return {buttonCount=#buttons, buttons=buttons} end
C_GamePad.ButtonBindingToIndex = function(key) return indices[key] end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n) CB.eventFrame:GetScript('OnEvent')(CB.eventFrame, n, 'Baggler') end
event('ADDON_LOADED'); event('PLAYER_LOGIN'); FLUSH()
local P, O, W = CB.Pad, CB.Options, CB.Window
local hardware = true
C_GamePad.IsEnabled = function() return hardware end
CB.db.pad.mode = 'on'
local receiver, backend, leaks = P:Receiver(), 'catcher', 0
-- The configured native B route is TOGGLEGAMEMENU. Model both phases reaching
-- the world if the actual receiver leaves propagation enabled. No fake OnPad.
local function phase(key, down)
  if backend == 'bindings' then
    local command = BagglerPadOwner.__bindings[key]
    if command then
      local target = command:match('^CLICK ([%w_]+):')
      if target then _G[target]:Click('LeftButton', down)
      else leaks = leaks + 1 end -- real installed native command, including TOGGLEGAMEMENU
    else leaks = leaks + 1 end
  else
    receiver:GetScript(down and 'OnGamePadButtonDown' or 'OnGamePadButtonUp')(receiver, key)
    if receiver.__propagate then leaks = leaks + 1 end
  end
end
local function press(key) phase(key, true); phase(key, false) end
local function open(which)
  if focus then focus:ClearFocus() end
  CB.Menu:Close(); O:Close(); W:Close(); P:Reset()
  backend = which; P:SetBackend(which)
  W:Open(); FLUSH(); P.input:Tick(); press('PADBACK')
  assert(O.frame:IsShown() and P:Top() == O.ctx, 'bags -> controller settings')
  -- Shoulder cycling, rather than direct ShowPage, reaches Sections.
  for _ = 1, #O.tabOrder do
    if O.current.name == 'Sections' then break end
    press('PADRSHOULDER')
  end
  assert(O.current.name == 'Sections')
  leaks = 0
end
local failures = 0
local function test(name, fn)
  if arg[1] and not name:find(arg[1], 1, true) then return end
  local ok, err = xpcall(fn, debug.traceback)
  if ok then print('PASS ' .. name) else failures = failures + 1; print('FAIL ' .. name .. '\n' .. err) end
end
for _, method in ipairs({'catcher', 'bindings'}) do
  test(method .. ' edit cancel owns both phases and returns to settings', function()
    open(method); press('PAD1')
    local form = O.current.form
    assert(focus == form.nameBox and O.edit == focus and P.yield, 'A enters name editing')
    leaks = 0; phase('PAD2', true)
    assert(not focus and not O.edit and not P.yield and O.frame:IsShown(), 'first B only leaves edit')
    phase('PAD2', false)
    assert(leaks == 0, 'B down/up must not reach TOGGLEGAMEMENU while leaving edit')
    -- Left/right chooses the second field via the existing form action.
    press('PADDRIGHT'); assert(focus == form.patBox, 'item-name field reachable')
    leaks = 0; press('PAD2')
    assert(not focus and O.frame:IsShown() and leaks == 0, 'item-name cancel consumed')
    leaks = 0; press('PAD2')
    assert(not O.frame:IsShown() and W:IsOpen() and P:Top() == W.ctx and leaks == 0,
      'next B closes only settings and consumes down/up, not bags/world')
  end)
  test(method .. ' directional return reaches every selectable tab', function()
    open(method); press('PAD1'); press('PAD2'); press('PADDUP')
    assert(O.tabFocus, 'Up from first Sections row must reach tab strip instead of wrapping')
    local visited = {}
    for _ = 1, #O.tabOrder do
      visited[O.current.name] = true
      assert(O.current.tabBtn.cbFocused, 'active tab has a controller focus affordance')
      assert(not O.current.rows[O.current.focus].sel:IsShown(), 'tab focus must not highlight a content row too')
      press('PAD1'); assert(not O.tabFocus, 'A enters selected page: ' .. O.current.name .. ' binding=' .. tostring(BagglerPadOwner.__bindings.PAD1) .. ' yield=' .. tostring(P.yield))
      press('PADDUP'); assert(O.tabFocus, 'Up from first row returns to tabs on every page')
      press('PADDRIGHT')
    end
    for _, name in ipairs(O.tabOrder) do assert(visited[name], 'unreachable tab: ' .. name) end
    press('PADDDOWN'); assert(not O.tabFocus, 'Down returns to page rows')
    local before = O.current.name; press('PADLSHOULDER'); assert(O.current.name ~= before, 'shoulder mapping retained')
  end)
end
test('repeated down cannot give a cancelled edit press back to the wheel', function()
  for _, method in ipairs({'catcher', 'bindings'}) do
    open(method); press('PAD1'); leaks = 0
    phase('PAD2', true); phase('PAD2', true); phase('PAD2', false)
    assert(leaks == 0 and O.frame:IsShown(), 'held B must neither leak nor close settings twice: ' .. method)
    press('PAD2'); assert(not O.frame:IsShown(), 'fresh B still closes settings: ' .. method)
  end
end)
test('keyboard mouse page changes clear hidden edit focus without losing data', function()
  open('bindings'); press('PAD1')
  local form = O.current.form
  form.nameBox:SetText('My supplies')
  O.pages.Look.tabBtn:Click('LeftButton')
  assert(not focus and not O.edit and not P.yield, 'mouse tab switch cannot leave hidden field holding input')
  assert(form.nameBox:GetText() == 'My supplies', 'tab switch preserves draft')
  O.pages.Sections.tabBtn:Click('LeftButton'); form.nameBox:SetFocus()
  form.nameBox:GetScript('OnEscapePressed')(form.nameBox)
  assert(not focus and O.frame:IsShown(), 'Escape leaves field, not settings')
  form.nameBox:SetFocus(); form.nameBox:GetScript('OnEnterPressed')(form.nameBox)
  assert(focus == form.patBox, 'Enter still moves to item names')
  form.patBox:SetText('potion, elixir'); form.patBox:GetScript('OnEnterPressed')(form.patBox)
  assert(CB.db.custom['My supplies'] and not focus, 'Enter still saves section')
end)
test('mouse row hover leaves controller tab-strip mode', function()
  open('catcher'); press('PADDUP'); assert(O.tabFocus)
  local row = O.current.rows[1]
  row:GetScript('OnEnter')(row)
  assert(not O.tabFocus and row.sel:IsShown(), 'mouse row selection must restore row controls')
end)
test('nested section delete popup owns cancel before settings', function()
  open('catcher')
  press('PAD1')
  local form = O.current.form
  form.nameBox:SetText('Delete candidate')
  form.nameBox:GetScript('OnEnterPressed')(form.nameBox)
  form.patBox:SetText('potion'); form.patBox:GetScript('OnEnterPressed')(form.patBox)
  press('PADDDOWN'); press('PAD1')
  assert(CB.Menu:IsOpen() and P:Top() ~= O.ctx, 'saved section opens actual delete popup')
  leaks = 0; press('PAD2')
  assert(not CB.Menu:IsOpen() and O.frame:IsShown() and leaks == 0, 'B dismisses popup only')
  press('PAD2'); assert(not O.frame:IsShown() and W:IsOpen(), 'next B dismisses settings only')
end)
test('last settings context holds only its closing release then drains host', function()
  for _, method in ipairs({'catcher', 'bindings'}) do
    open(method); W:Close(); leaks = 0
    phase('PAD2', true)
    assert(not O.frame:IsShown() and not W:IsOpen(), 'settings was the final window')
    if method == 'catcher' then assert(receiver:IsShown(), 'receiver must remain for owned UP') end
    phase('PAD2', false)
    assert(leaks == 0 and not receiver:IsShown() and not BagglerPadBroker:Has('Baggler')
      and not next(BagglerPadOwner.__bindings), 'closing release consumed, no retained lease/catcher/bindings: ' .. method)
  end
end)
test('device loss and explicit reset discard unreleasable delivery fences', function()
  for _, method in ipairs({'catcher', 'bindings'}) do
    open(method); phase('PAD1', true)
    hardware = false; P:Apply('device lost')
    assert(not receiver:IsShown() and not next(BagglerPadOwner.__bindings), 'device loss drains host: ' .. method)
    hardware = true; P:Apply('device restored'); P.input:Tick(); phase('PAD1', false)
    press('PAD2'); phase('PAD2', true); P:Reset()
    assert(not receiver:IsShown() and not BagglerPadBroker:Has('Baggler')
      and not next(BagglerPadOwner.__bindings), 'explicit reset drains host: ' .. method)
    phase('PAD2', false)
  end
end)
test('focused edit combat transition makes no insecure binding or propagation writes', function()
  for _, method in ipairs({'catcher', 'bindings'}) do
    open(method); press('PAD1'); phase('PAD2', true)
    COMBAT = true; event('PLAYER_REGEN_DISABLED')
    assert(not receiver:IsShown() and not P.bound, 'combat relinquishes controller')
    phase('PAD2', false); O:Close()
    COMBAT = false; event('PLAYER_REGEN_ENABLED')
    assert(not O.frame:IsShown() and not O.edit and not P.yield, 'combat settings close and regen recover')
  end
end)
assert(failures == 0, failures .. ' settings controller regressions')
print('ALL PASS settings controller (offline only)')
