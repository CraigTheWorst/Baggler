-- Run from repository root: timeout 90 luajit addons/Baggler/Tests/merchant_pair_test.lua
-- Regression: at any MERCHANT_SHOW vendor the Baggler bags and the native MerchantFrame open together and close
-- together, whichever has the controller, by controller B or keyboard Escape, with one press. The native merchant
-- takes the controller first (mail_pair_test.lua: same rule for mail/trade/auction/guild bank); Start hops.
-- Real TOC / real lifecycle. The client boundary is modelled after the pinned Forever source
-- (wow-ui-source-9dc84f0d, Blizzard_UIPanels_Game/Mainline/MerchantFrame.lua):
--   MerchantFrame_MerchantShow  -> ShowUIPanel(MerchantFrame)            (l.68-77)
--   MerchantFrame_OnShow        -> OpenAllBags(self, true)                (l.147-149)
--   MerchantFrame_OnHide        -> CloseMerchant(); CloseAllBags(self, true) (l.163-167)
--   MerchantFrame_MerchantClosed-> HideUIPanel(MerchantFrame)             (l.79-83, interaction-manager hideFunc)
--   ToggleGameMenu -> TryHandleGameMenuEsc -> CloseAllWindows: CloseAllBags(); CloseWindows() hides UI panels
--   (Blizzard_GameMenuEsc.lua l.109; UIParentPanelManager.lua l.1175-1183, MerchantFrame area=left)
-- Restricted bindings / secure click templates are simulated as in combat_b_close_test.lua. Offline only:
-- not an in-game taint proof.
dofile('tests/harness/ca_stubs.lua')
local now = 100
function GetTime() return now end
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end

local create = CreateFrame
local world = { PAD1 = 'JUMP', PAD2 = 'WORLD_B', PAD3 = 'WORLD_X', PAD4 = 'WORLD_Y', PADFORWARD = 'TOGGLEGAMEMENU' }
local overrides, order = {}, {}
local secure, gameCode = false, false   -- restricted snippet / Blizzard code running (not add-on code)
local blocked, misuse = {}, {}
local driver
local function guard(op)
  if COMBAT and not secure then blocked[#blocked + 1] = op; error('ADDON_ACTION_BLOCKED: ' .. op, 3) end
end
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
  function h:ClearBindings() guard('ClearBindings'); wipe(ownerTable(f)) end
  function h:ClearBinding(key) guard('ClearBinding'); ownerTable(f)[key] = nil end
  function h:SetBindingClick(_, key, target, button) guard('SetBindingClick'); ownerTable(f)[key] = 'CLICK ' .. target .. ':' .. (button or 'LeftButton') end
  function h:SetBinding(_, key, action) guard('SetBinding'); ownerTable(f)[key] = action end
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
  function f:SetPropagateKeyboardInput(on) guard('SetPropagateKeyboardInput'); self.__propagate = on end
  if template and template:find('SecureHandler') then
    f.__handle = handleFor(f)
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
    function f:SetFrameRef(label, ref) guard('SetFrameRef'); setAttribute(self, 'frameref-' .. label, ref) end
    if template:find('SecureHandlerStateTemplate') then
      f.__state = function(state, value) runSnippet(f, '_onstate-' .. state, 'self, stateid, newstate', state, tonumber(value) or value) end -- client: resolveDriver hands the snippet a number
    end
    if template:find('SecureHandlerClickTemplate') then
      f.__scripts.OnClick = function(self, button, down) runSnippet(self, '_onclick', 'self, button, down', button, down) end
    end
  end
  if template and template:find('SecureActionButtonTemplate') then
    local setAttribute = f.SetAttribute
    function f:SetAttribute(...) guard('secure action SetAttribute'); return setAttribute(self, ...) end
  end
  if kind == "Frame" then
    function f:EnableGamePadButton(on) guard('EnableGamePadButton'); self.__padEnabled = on end
  end
  return f
end
function RegisterStateDriver(f, state, condition) driver = f end

---------------------------------------------------------------------------
-- The native merchant (pinned Mainline MerchantFrame.lua) and the server interaction.
---------------------------------------------------------------------------
local serverQueue = {}     -- events the client delivers on a later frame
local atVendor = false
local closeCalls, closeInCombat = 0, 0
local merchant = create('Frame', 'MerchantFrame', UIParent)
merchant.__shown = false
function HideUIPanel(frame)
  if not gameCode then misuse[#misuse + 1] = 'HideUIPanel from add-on code' end
  if frame and frame:IsShown() then frame:Hide() end
end
function ShowUIPanel(frame)
  if not gameCode then misuse[#misuse + 1] = 'ShowUIPanel from add-on code' end
  frame:Show()
end
local function asGame(fn, ...) local was = gameCode; gameCode = true; fn(...); gameCode = was end
function CloseMerchant()
  closeCalls = closeCalls + 1
  if COMBAT and not gameCode then closeInCombat = closeInCombat + 1 end
  if atVendor then
    atVendor = false
    serverQueue[#serverQueue + 1] = function()
      CB_EVENT('MERCHANT_CLOSED')
      asGame(HideUIPanel, merchant)          -- interaction manager hideFunc
    end
  end
end
merchant:SetScript('OnShow', function(self) OpenAllBags(self, true) end)
merchant:SetScript('OnHide', function(self) CloseMerchant(); CloseAllBags(self, true) end)

local panelsClosed = 0
local function CloseAllWindows()
  local bags = CloseAllBags()
  if merchant:IsShown() then HideUIPanel(merchant); panelsClosed = panelsClosed + 1 end
  return true
end
function ToggleGameMenu() asGame(CloseAllWindows) end

local CB = {}
BagglerDB = { replaceBank = false, bankOptInMigrated = true, personalBankRestored1 = true }
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
function CB_EVENT(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
local event = CB_EVENT
local function flush()
  for _ = 1, 3 do
    local q = serverQueue; serverQueue = {}
    for _, fn in ipairs(q) do fn() end
    FLUSH()
  end
end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); flush()
now = 120
CB.db.pad.mode = 'on'
local P, W, I = CB.Pad, CB.Window, CB.Integrations
assert(CB.db.pad.map.PAD2 == 'close', 'stock mapping: B is close')
local bagFrame = assert(_G.BagglerFrame, 'bag frame')

-- A hardware press of a controller key, with the native gamepad UI answering B for a focused game window.
local function press(key)
  local action = GetBindingAction(key)
  local target, button = tostring(action):match('^CLICK ([%w_]+):(%w+)$')
  if target then
    local f = assert(_G[target], 'binding to a missing button ' .. target)
    local c = f.__clicks or {}
    if c.AnyDown or c.LeftButtonDown then f:Click(button, true) end
    if c.AnyUp or c.LeftButtonUp then f:Click(button, false) end
    return 'ui:' .. target
  end
  if action == 'TOGGLEGAMEMENU' then ToggleGameMenu(); return 'game:TOGGLEGAMEMENU' end
  if key == 'PAD2' and P.holdGame == merchant and merchant:IsShown() then
    asGame(HideUIPanel, merchant)            -- native gamepad B on the focused merchant (FrameControlsManager)
    return 'native:B'
  end
  return 'world:' .. tostring(action)
end
-- Keyboard Escape: the shown bag frame hears the key first; the game's binding runs when it lets the key through.
local function escape()
  local h = bagFrame.__scripts.OnKeyDown
  if bagFrame:IsShown() and h then
    h(bagFrame, 'ESCAPE')
    if bagFrame.__propagate == false then return 'ours' end
  end
  ToggleGameMenu()
  return 'game'
end

local function reset(open, backend)
  if merchant:IsShown() then asGame(HideUIPanel, merchant) end
  atVendor = false; flush()
  now = now + 10
  CB.db.pad.backend = backend or 'bindings'
  CB.NativeWindows.active = {}; CB.NativeWindows.endedAt = nil
  I.gameOpen = true; I.openedFor = nil
  W:Close(); W.closedAt = now - 10
  W:ClearSearch()
  P:Reset(); P.seenGame, P.declinedGame = {}, {}
  if open then ToggleAllBags(); flush(); assert(W:IsOpen(), 'precondition: manual bags open') end
  closeCalls, closeInCombat, panelsClosed = 0, 0, 0
  wipe(blocked); wipe(misuse)
end
-- Talk to a vendor. Either delivery order: the add-on event before or after the game shows its frame.
local function visit(eventFirst)
  atVendor = true
  if eventFirst then event('MERCHANT_SHOW') end
  asGame(ShowUIPanel, merchant)
  if not eventFirst then event('MERCHANT_SHOW') end
  flush()
  now = now + 0.1
end
local function start()                    -- Start (switchWindow), a real second press apart
  now = now + 1
  P:Press('switchWindow', true, 'binding'); P:Press('switchWindow', false)
end
local function bothClosed(where)
  flush()
  assert(not merchant:IsShown(), where .. ': merchant must close')
  assert(not W:IsOpen(), where .. ': bags must close')
  assert(not atVendor, where .. ': server interaction must end')
  assert(#misuse == 0, where .. ': ' .. table.concat(misuse, ', '))
  assert(#blocked == 0, where .. ': blocked ' .. table.concat(blocked, ', '))
end

for _, backend in ipairs({ 'bindings', 'catcher' }) do
  for _, pre in ipairs({ false, true }) do
    for _, eventFirst in ipairs({ true, false }) do
      local tag = ('%s pre=%s eventFirst=%s'):format(backend, tostring(pre), tostring(eventFirst))
      -- 1. open together; the native merchant (also the demon trainer's window) takes the controller first;
      --    Start hops to the bags, and B with the bags focused closes both at once
      reset(pre, backend); visit(eventFirst)
      assert(merchant:IsShown() and W:IsOpen(), tag .. ': merchant and bags must open together')
      assert(P.holdGame == merchant and P.handedOff, tag .. ': the native merchant holds the controller first')
      start(); assert(P:Top() == W.ctx and not P.handedOff, tag .. ': Start gives the bags the controller')
      if backend == 'catcher' then
        assert(P.catchMap.PAD2 == 'close', tag .. ': catcher owns B'); P:Press('close', true, 'catcher'); P:Press('close', false)
      else
        press('PAD2')
      end
      bothClosed(tag .. ' B on bags')
      if backend == 'bindings' then
        assert(press('PAD2') == 'world:WORLD_B', tag .. ': next B must be the game\'s')
      end

      -- 2. B with the native merchant focused (it has the controller on open)
      reset(pre, backend); visit(eventFirst)
      assert(P.holdGame == merchant, tag .. ': controller handed to the native merchant')
      assert(press('PAD2') == 'native:B', tag .. ': B must reach the native merchant')
      bothClosed(tag .. ' native B')

      -- 3. keyboard Escape, bags focused and merchant focused
      reset(pre, backend); visit(eventFirst); start()                            -- Start: hop to the bags
      escape(); bothClosed(tag .. ' Escape bags focused')
      reset(pre, backend); visit(eventFirst)
      escape(); bothClosed(tag .. ' Escape merchant focused')

      -- 4. walking away (server ends the visit)
      reset(pre, backend); visit(eventFirst)
      CloseMerchant(); bothClosed(tag .. ' walk away')
    end
  end
  print('PASS ' .. backend .. ': merchant and bags open/close together (B bags, native B, Escape, walk away; pre-open and closed; both event orders)')
end

-- B finishes bag-local work first; the next B closes both.
reset(false); visit(true); start()
local box = W.frame.search
box:SetText('linen'); box.__scripts.OnTextChanged(box)      -- typed with the keyboard / mouse, no pad action
assert(W.query == 'linen', 'precondition: search typed')
press('PAD2'); flush()
assert(merchant:IsShown() and W:IsOpen() and W.query == '', 'first B clears the search only')
press('PAD2'); bothClosed('B after a cleared search')
print('PASS search is cleared first, the next B closes both')

-- After the visit, bags reopened by hand: B closes the bags only and never opens the game menu.
reset(false); visit(true); start(); press('PAD2'); flush()
ToggleAllBags(); flush()
assert(W:IsOpen() and not merchant:IsShown(), 'precondition: bags reopened after the visit')
assert(GetBindingAction('PAD2'):match('^CLICK '), 'stale game-menu B after the visit: ' .. GetBindingAction('PAD2'))
panelsClosed = 0
press('PAD2'); flush()
assert(not W:IsOpen() and panelsClosed == 0, 'B after the visit must close only the bags')
print('PASS no stale merchant B after the visit')

-- Bags already open, merchant arrives: B must already be the paired close (no reopen needed).
reset(true); visit(false); start()
assert(GetBindingAction('PAD2') == 'TOGGLEGAMEMENU', 'pre-open bags must take the paired B at MERCHANT_SHOW: ' .. GetBindingAction('PAD2'))
press('PAD2'); bothClosed('pre-open bags B')
print('PASS pre-opened bags rebind B at MERCHANT_SHOW')

-- Combat: B still closes the bags at once (secure combat close); add-on code never calls CloseMerchant in lockdown.
for _, backend in ipairs({ 'bindings', 'catcher' }) do
  reset(false, backend); visit(true); start()
  COMBAT = true; event('PLAYER_REGEN_DISABLED'); driver.__state('combat', '1')
  press('PAD2') -- combat uses the pre-established secure close binding in both backends
  flush()
  assert(not W:IsOpen(), backend .. ': combat B must close the bags')
  assert(closeInCombat == 0, backend .. ': add-on CloseMerchant in combat')
  assert(#blocked == 0, backend .. ': blocked ' .. table.concat(blocked, ', '))
  escape(); flush()
  assert(not merchant:IsShown() and not atVendor, backend .. ': Escape still closes the merchant in combat')
  COMBAT = false; driver.__state('combat', '0'); event('PLAYER_REGEN_ENABLED'); flush()
  print('PASS ' .. backend .. ': combat B closes bags, merchant degrades to Escape/native close')
end

assert((CB.errorCount or 0) == 0, 'shipping modules logged Lua errors')
print('ALL PASS merchant pairing (offline only; not an in-game proof)')
