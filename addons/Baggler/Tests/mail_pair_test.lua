-- Run from repository root: timeout 90 luajit addons/Baggler/Tests/mail_pair_test.lua
-- Regression: at the native mailbox, trade window, auction house and guild bank the Baggler bags and the native window
-- open together, the NATIVE window takes the controller first (Start hops to the bags and back at will), and they
-- close together whichever has the controller: B on the bags, the game's own B/back on the native window, keyboard
-- Escape, or the server ending the visit -- one press. The merchant window (also the warlock demon trainer's grimoire
-- vendor) follows the same native-first rule.
-- Real TOC / real lifecycle. The client boundary is modelled after the pinned Forever source
-- (wow-ui-source-9dc84f0d, 1.60.1.70862; installed client 1.60.1.70938 -- not re-verified against that build):
--   Blizzard_MailFrame/MailFrame.lua
--     MailMixin:OnHide        -> CloseMail(); HideUIPanel(OpenMailFrame)              (l.49-51)
--     MailFrame_Show (showFunc)-> ShowUIPanel(MailFrame); OpenAllBags(MailFrame)       (l.99-111)
--     MailFrame_Hide (hideFunc)-> HideUIPanel(MailFrame); CloseAllBags(self) [self=nil] (l.118-121)
--     InboxFrame_OnClick       -> ShowUIPanel(OpenMailFrame) / HideUIPanel(OpenMailFrame) (l.459-471)
--     OpenMailFrame has no UIPanelWindows entry and is not in UISpecialFrames: Escape closes it through MailFrame.
--   Blizzard_UIPanels_Game/Mainline/TradeFrame.lua
--     TRADE_SHOW -> ShowUIPanel(self,1) (l.37-38); OnShow -> OpenAllBags(self,true) with the gamepad UI (l.24-33)
--     TRADE_CLOSED -> HideUIPanel(self) (l.48-49); OnHide -> CloseTrade(); CloseAllBags() (l.239-245)
--   Blizzard_AuctionHouseUI/Shared/Blizzard_AuctionHouseFrame.lua
--     OnShow -> OpenAllBags(self) (l.402); OnHide -> C_AuctionHouse.CloseAuctionHouse(); CloseAllBags(self) (l.448-462)
--   Blizzard_GuildBankUI/Mainline/Blizzard_GuildBankUI.lua
--     OnShow: no OpenAllBags (l.117-123); OnHide -> CloseGuildBankFrame(), no CloseAllBags (l.125-131).
--     The pinned source never opens the bags at the guild bank; the live report says it does, so both are run.
--   PlayerInteractionFrameManager.lua: server hide -> hideFunc or HideUIPanel(frame) (l.139-162)
--   UIPanelWindows: MailFrame/TradeFrame area=left; AuctionHouseFrame/GuildBankFrame area=doublewide
--   CloseAllWindows: CloseAllBags(); CloseWindows() hides left/doublewide panels (UIParentPanelManager.lua l.1134-1183)
--   Native gamepad B = SmartNavigation:AttemptClose on the FOCUSED frame: clicks its CloseButton
--     (SmartNavigation.lua l.1662-1690) -> HideUIPanel of that frame only. A shown letter (OpenMailFrame) is
--     focused, so the native B closes the letter first, as in the game.
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
-- The native windows (pinned source above) and the server interactions.
---------------------------------------------------------------------------
local serverQueue = {}
local function later(fn) serverQueue[#serverQueue + 1] = fn end
function HideUIPanel(frame)
  if not gameCode then misuse[#misuse + 1] = 'HideUIPanel from add-on code' end
  if frame and frame:IsShown() then frame:Hide() end
end
function ShowUIPanel(frame)
  if not gameCode then misuse[#misuse + 1] = 'ShowUIPanel from add-on code' end
  frame:Show()
end
local function asGame(fn, ...) local was = gameCode; gameCode = true; fn(...); gameCode = was end
local function hidden(kind, name, parent) local f = create(kind, name, parent or UIParent); f.__shown = false; return f end

local calls, combatCalls = {}, {}
local function served(name)
  calls[name] = (calls[name] or 0) + 1
  if COMBAT and not gameCode then combatCalls[#combatCalls + 1] = name end
end
local win = {}
local function def(key, t) t.key = key; win[key] = t; return t end

-- Mail
local mail = hidden('Frame', 'MailFrame')
local inbox = create('Frame', 'InboxFrame', mail)
local sendMail = hidden('Frame', 'SendMailFrame', mail)
local letter = hidden('Frame', 'OpenMailFrame')
local mailD = def('mail', { frame = mail, showEvent = 'MAIL_SHOW', closeEvent = 'MAIL_CLOSED' })
mail:SetScript('OnHide', function() CloseMail(); HideUIPanel(letter); sendMail.__shown = false; inbox.__shown = true end)
function CloseMail()
  served('CloseMail')
  if mailD.at then mailD.at = false; later(function() CB_EVENT('MAIL_CLOSED'); asGame(function() HideUIPanel(mail); CloseAllBags(nil) end) end) end
end
mailD.serverShow = function() ShowUIPanel(mail); if mail:IsShown() then OpenAllBags(mail) end end
mailD.walkAway = CloseMail

-- Trade
local trade = hidden('Frame', 'TradeFrame')
local tradeD = def('trade', { frame = trade, showEvent = 'TRADE_SHOW', closeEvent = 'TRADE_CLOSED' })
trade:SetScript('OnShow', function(self) OpenAllBags(self, true) end)
trade:SetScript('OnHide', function() CloseTrade(); CloseAllBags() end)
function CloseTrade()
  served('CloseTrade')
  if tradeD.at then tradeD.at = false; later(function() CB_EVENT('TRADE_CLOSED'); asGame(HideUIPanel, trade) end) end
end
tradeD.serverShow = function() ShowUIPanel(trade) end
tradeD.walkAway = CloseTrade

-- Auction house
local ah = hidden('Frame', 'AuctionHouseFrame')
local ahD = def('auction', { frame = ah, showEvent = 'AUCTION_HOUSE_SHOW', closeEvent = 'AUCTION_HOUSE_CLOSED' })
ah:SetScript('OnShow', function(self) OpenAllBags(self) end)
ah:SetScript('OnHide', function(self) C_AuctionHouse.CloseAuctionHouse(); CloseAllBags(self) end)
C_AuctionHouse = { CloseAuctionHouse = function()
  served('CloseAuctionHouse')
  if ahD.at then ahD.at = false; later(function() CB_EVENT('AUCTION_HOUSE_CLOSED'); asGame(HideUIPanel, ah) end) end
end }
ahD.serverShow = function() ShowUIPanel(ah) end
ahD.walkAway = function() C_AuctionHouse.CloseAuctionHouse() end

-- Guild bank (opensBags=false is the pinned source; true is the live report)
local gb = hidden('Frame', 'GuildBankFrame')
local gbD = def('guildbank', { frame = gb, showEvent = 'GUILDBANKFRAME_OPENED', closeEvent = 'GUILDBANKFRAME_CLOSED' })
gb:SetScript('OnShow', function(self) if gbD.opensBags then OpenAllBags(self) end end)
gb:SetScript('OnHide', function() CloseGuildBankFrame() end)
function CloseGuildBankFrame()
  served('CloseGuildBankFrame')
  if gbD.at then gbD.at = false; later(function() CB_EVENT('GUILDBANKFRAME_CLOSED'); asGame(HideUIPanel, gb) end) end
end
gbD.serverShow = function() ShowUIPanel(gb) end
gbD.walkAway = CloseGuildBankFrame


-- Merchant: also the warlock demon trainer's window. The pinned trainer UI never opens the bags
-- (Blizzard_TrainerUI has no OpenAllBags; ClassTrainerFrame/StableFrame are Integrations.NO_BAGS), so a trainer that
-- opens WITH the bags is a vendor window (Mainline/MerchantFrame.lua 147-149 OnShow, 163-167 OnHide, 79-83 hideFunc).
local merchant = hidden('Frame', 'MerchantFrame')
local merchD = def('merchant', { frame = merchant, showEvent = 'MERCHANT_SHOW', closeEvent = 'MERCHANT_CLOSED' })
merchant:SetScript('OnShow', function(self) OpenAllBags(self, true) end)
merchant:SetScript('OnHide', function(self) CloseMerchant(); CloseAllBags(self, true) end)
function CloseMerchant()
  served('CloseMerchant')
  if merchD.at then merchD.at = false; later(function() CB_EVENT('MERCHANT_CLOSED'); asGame(HideUIPanel, merchant) end) end
end
merchD.serverShow = function() ShowUIPanel(merchant) end
merchD.walkAway = CloseMerchant

local panelsClosed = 0
local function CloseAllWindows()
  CloseAllBags()
  for _, f in ipairs({ merchant, mail, trade, ah, gb }) do
    if f:IsShown() then HideUIPanel(f); panelsClosed = panelsClosed + 1 end
  end
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

-- The native frame the game's controller cursor is on while the controller is the game's.
local function nativeFocus(d)
  if d == mailD and letter:IsShown() then return letter end
  return d.frame
end
local current
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
  if key == 'PAD2' and current and P.holdGame == current.frame and current.frame:IsShown() then
    asGame(HideUIPanel, nativeFocus(current))   -- SmartNavigation:AttemptClose -> focused frame's CloseButton
    return 'native:B'
  end
  return 'world:' .. tostring(action)
end
local function escape()
  local h = bagFrame.__scripts.OnKeyDown
  if bagFrame:IsShown() and h then
    h(bagFrame, 'ESCAPE')
    if bagFrame.__propagate == false then return 'ours' end
  end
  ToggleGameMenu()
  return 'game'
end
local function start()                    -- Start (switchWindow), a real second press apart
  now = now + 1
  P:Press('switchWindow', true, 'binding'); P:Press('switchWindow', false)
end
local function bagsB(backend)
  if backend == 'catcher' then
    assert(P.catchMap.PAD2 == 'close', 'catcher owns B on the bags'); P:Press('close', true, 'catcher'); P:Press('close', false)
  else
    return press('PAD2')
  end
end

local function reset(open, backend)
  for _, d in pairs(win) do d.at = false; if d.frame:IsShown() then asGame(HideUIPanel, d.frame) end end
  flush()
  now = now + 10
  current = nil
  CB.db.pad.backend = backend or 'bindings'
  CB.NativeWindows.active = {}; CB.NativeWindows.endedAt = nil
  I.gameOpen = true; I.openedFor = nil
  W:Close(); W.closedAt = now - 10
  W:ClearSearch()
  P:Reset(); P.seenGame, P.declinedGame = {}, {}
  if open then ToggleAllBags(); flush(); assert(W:IsOpen(), 'precondition: manual bags open') end
  wipe(calls); wipe(combatCalls); panelsClosed = 0
  wipe(blocked); wipe(misuse)
end
local function visit(d, eventFirst)
  current = d
  d.at = true
  if eventFirst then event(d.showEvent) end
  asGame(d.serverShow)
  if not eventFirst then event(d.showEvent) end
  flush()
  now = now + 0.1
end
local function bothClosed(d, where)
  flush()
  assert(not d.frame:IsShown(), where .. ': ' .. d.key .. ' window must close')
  assert(not W:IsOpen(), where .. ': bags must close')
  assert(not d.at, where .. ': server interaction must end')
  assert(#misuse == 0, where .. ': ' .. table.concat(misuse, ', '))
  assert(#blocked == 0, where .. ': blocked ' .. table.concat(blocked, ', '))
end
local function nativeHasPad(d, where)
  assert(P.holdGame == d.frame and P.handedOff, where .. ': the native ' .. d.key .. ' window must hold the controller (hold=' ..
    tostring(P.holdGame and P.holdGame:GetName()) .. ')')
end
local function bagsHavePad(where)
  assert(P:Top() == W.ctx and not P.handedOff and not P.holdGame, where .. ': the bags must hold the controller')
end

---------------------------------------------------------------------------
-- 1. Every bag-opening native window: native focus first, Start hops, close together by every route.
---------------------------------------------------------------------------
local cases = { merchD, mailD, tradeD, ahD, gbD }
gbD.opensBags = true
for _, d in ipairs(cases) do
  for _, backend in ipairs({ 'bindings', 'catcher' }) do
    for _, pre in ipairs({ false, true }) do
      for _, eventFirst in ipairs({ true, false }) do
        local tag = ('%s %s pre=%s eventFirst=%s'):format(d.key, backend, tostring(pre), tostring(eventFirst))
        -- focus: the native window first; Start to the bags and back
        reset(pre, backend); visit(d, eventFirst)
        assert(d.frame:IsShown() and W:IsOpen(), tag .. ': window and bags must open together')
        nativeHasPad(d, tag .. ' on open')
        start(); bagsHavePad(tag .. ' after Start')
        start(); nativeHasPad(d, tag .. ' after Start again')
        -- B on the bags (bags focused) closes both
        start(); bagsHavePad(tag .. ' Start to the bags')
        bagsB(backend)
        bothClosed(d, tag .. ' B on bags')
        if backend == 'bindings' then assert(press('PAD2') == 'world:WORLD_B', tag .. ': next B must be the game\'s') end

        -- the game's own B on the focused native window closes both
        reset(pre, backend); visit(d, eventFirst)
        nativeHasPad(d, tag)
        assert(press('PAD2') == 'native:B', tag .. ': B must reach the native window')
        bothClosed(d, tag .. ' native B')

        -- keyboard Escape, native focused and bags focused
        reset(pre, backend); visit(d, eventFirst)
        escape(); bothClosed(d, tag .. ' Escape native focused')
        reset(pre, backend); visit(d, eventFirst); start(); bagsHavePad(tag)
        escape(); bothClosed(d, tag .. ' Escape bags focused')

        -- walking away / the other side cancelling: the server ends the visit
        reset(pre, backend); visit(d, eventFirst)
        asGame(d.walkAway); bothClosed(d, tag .. ' walk away')
      end
    end
    print(('PASS %s %s: native focus first, Start hops, B bags / native B / Escape / walk away close both'):format(d.key, backend))
  end
end

---------------------------------------------------------------------------
-- 2. Guild bank as in the pinned source: the game never opens the bags there. Bags opened by hand (Start) at the
--    guild bank keep the controller (the player asked for them) and still leave with it.
---------------------------------------------------------------------------
gbD.opensBags = false
for _, backend in ipairs({ 'bindings', 'catcher' }) do
  local tag = 'guildbank (no auto-open) ' .. backend
  reset(false, backend); visit(gbD, true)
  assert(gb:IsShown() and not W:IsOpen(), tag .. ': the pinned guild bank does not open the bags')
  start(); flush()
  assert(W:IsOpen(), tag .. ': Start opens the bags beside the guild bank')
  bagsB(backend); bothClosed(gbD, tag .. ' B on bags')
  reset(false, backend); visit(gbD, true); start(); flush(); start()
  nativeHasPad(gbD, tag .. ' Start back to the guild bank')
  assert(press('PAD2') == 'native:B', tag .. ': native B'); bothClosed(gbD, tag .. ' native B')
end
gbD.opensBags = true
print('PASS guild bank without auto-open: hand-opened bags still leave with it')

---------------------------------------------------------------------------
-- 3. Mail specifics: Send Mail tab, the open letter.
---------------------------------------------------------------------------
for _, backend in ipairs({ 'bindings', 'catcher' }) do
  local tag = 'mail ' .. backend
  -- Send Mail tab: bags still send to the letter (context "mail"), and B on the bags leaves together
  reset(false, backend); visit(mailD, true)
  inbox.__shown = false; sendMail.__shown = true                 -- MailFrameTab_OnClick(nil, 2)
  assert(CB.NativeWindows:Context() == 'mail', tag .. ': Send Mail context must stay')
  nativeHasPad(mailD, tag .. ' send tab')
  start(); bagsHavePad(tag .. ' send tab')
  bagsB(backend); bothClosed(mailD, tag .. ' send tab B on bags')
  reset(false, backend); visit(mailD, true)
  inbox.__shown = false; sendMail.__shown = true
  assert(press('PAD2') == 'native:B', tag .. ': native B on the send tab'); bothClosed(mailD, tag .. ' send tab native B')

  -- an open letter: the game's B closes the letter only (native); the next B closes mailbox and bags together
  reset(false, backend); visit(mailD, true)
  asGame(ShowUIPanel, letter)                                    -- InboxFrame_OnClick
  nativeHasPad(mailD, tag .. ' letter open')
  assert(press('PAD2') == 'native:B', tag .. ': native B on the letter')
  flush()
  assert(not letter:IsShown() and mail:IsShown() and W:IsOpen() and mailD.at, tag .. ': first B closes the letter only')
  nativeHasPad(mailD, tag .. ' after the letter')
  assert(press('PAD2') == 'native:B', tag .. ': native B on the inbox'); bothClosed(mailD, tag .. ' letter then inbox')

  -- an open letter with the bags focused: B on the bags leaves the whole visit, like Escape
  reset(false, backend); visit(mailD, true); asGame(ShowUIPanel, letter); start(); bagsHavePad(tag)
  bagsB(backend); bothClosed(mailD, tag .. ' letter open, B on bags')
  assert(not letter:IsShown(), tag .. ': the letter closes with the mailbox')
  -- Escape with a letter open closes everything at once (MailMixin:OnHide hides OpenMailFrame)
  reset(false, backend); visit(mailD, true); asGame(ShowUIPanel, letter)
  escape(); bothClosed(mailD, tag .. ' letter open, Escape'); assert(not letter:IsShown(), tag .. ': letter closed')
end
print('PASS mail: send tab and open letter (native B closes the letter first; B bags / Escape close all)')

---------------------------------------------------------------------------
-- 4. Bag-local work first, no stale paired B after the visit.
---------------------------------------------------------------------------
reset(false); visit(mailD, true); start()
local box = W.frame.search
box:SetText('linen'); box.__scripts.OnTextChanged(box)
assert(W.query == 'linen', 'precondition: search typed')
press('PAD2'); flush()
assert(mail:IsShown() and W:IsOpen() and W.query == '', 'first B clears the search only')
press('PAD2'); bothClosed(mailD, 'B after a cleared search')
ToggleAllBags(); flush()
assert(W:IsOpen() and not mail:IsShown(), 'precondition: bags reopened after the visit')
assert(GetBindingAction('PAD2'):match('^CLICK '), 'stale game-menu B after the visit: ' .. GetBindingAction('PAD2'))
panelsClosed = 0
press('PAD2'); flush()
assert(not W:IsOpen() and panelsClosed == 0, 'B after the visit must close only the bags')
print('PASS search is cleared first; no stale paired B after the visit')

---------------------------------------------------------------------------
-- 5. Combat: B on the bags still closes the bags; add-on code never ends a visit in lockdown; Escape still closes.
---------------------------------------------------------------------------
for _, d in ipairs(cases) do
  for _, backend in ipairs({ 'bindings', 'catcher' }) do
    local tag = d.key .. ' ' .. backend .. ' combat'
    reset(false, backend); visit(d, true); start(); bagsHavePad(tag)
    COMBAT = true; event('PLAYER_REGEN_DISABLED'); driver.__state('combat', '1')
    press('PAD2') -- both backends use the already-armed secure combat-close button
    flush()
    assert(not W:IsOpen(), tag .. ': B must close the bags')
    assert(#combatCalls == 0, tag .. ': add-on ended the visit in combat: ' .. table.concat(combatCalls, ','))
    assert(#blocked == 0, tag .. ': blocked ' .. table.concat(blocked, ', '))
    escape(); flush()
    assert(not d.frame:IsShown() and not d.at, tag .. ': Escape still closes the native window')
    COMBAT = false; driver.__state('combat', '0'); event('PLAYER_REGEN_ENABLED'); flush()
    assert(#blocked == 0, tag .. ': blocked ' .. table.concat(blocked, ', '))
  end
end
print('PASS combat: B closes the bags, the native window degrades to Escape / its own close')

-- Opened in combat: no protected hand-off is attempted; the bags keep the controller until combat ends.
reset(false, 'bindings')
COMBAT = true; event('PLAYER_REGEN_DISABLED'); driver.__state('combat', '1')
visit(mailD, true)
assert(#blocked == 0, 'combat open: blocked ' .. table.concat(blocked, ', '))
COMBAT = false; driver.__state('combat', '0'); event('PLAYER_REGEN_ENABLED'); flush()
asGame(mailD.walkAway); flush()
print('PASS opened in combat: no blocked actions')

assert((CB.errorCount or 0) == 0, 'shipping modules logged Lua errors')
print('ALL PASS mail/trade/auction/guild-bank pairing (offline only; not an in-game proof)')
