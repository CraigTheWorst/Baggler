-- Actual shipping TOC. Offline presentation/routing checks, not live hardware proof.
dofile('tests/harness/ca_stubs.lua')
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local glyphs, glyphButton = {}, CB.UI.GlyphButton
function CB.UI:GlyphButton(...)
  local b = glyphButton(self, ...)
  glyphs[#glyphs + 1] = b
  return b
end
local function event(n) CB.eventFrame:GetScript('OnEvent')(CB.eventFrame, n, 'Baggler') end
event('ADDON_LOADED'); event('PLAYER_LOGIN'); FLUSH()
local W, UI, P = CB.Window, CB.UI, CB.Pad
CB.db.pad.mode = 'on'
W:Open(); FLUSH(); P.input:Tick()
local function focus(view, id)
  for i, entry in ipairs(view:ChromeList()) do
    if entry.id == id then view:EnterChrome(i); return entry.widget end
  end
  error('unreachable chrome: ' .. id)
end
local function title() return UI.Tip.lines[1].left:GetText() end
local gear = focus(W, 'settings')
assert(gear.cbFocused, 'gear already highlights via ShowChrome / SetFocused')
assert(UI.Tip:IsShown() and title() == 'Settings', 'controller-focused gear must show Settings without mouse OnEnter')
print('PASS controller gear label on shipping TOC')
W:ClearChromePaint()
assert(not UI.Tip:IsShown(), 'controller blur must hide its own chrome tip')
focus(W, 'settings')
CB.Options:Open()
BagglerTip:GetScript('OnUpdate')(BagglerTip)
assert(not UI.Tip:IsShown(), 'context handoff must hide the old focus tip')
CB.Options:Close()
focus(W, 'settings')
gear:GetScript('OnEnter')(gear)
assert(UI.Tip:IsShown() and title() == 'Settings' and UI.Tip.anchor == 'ANCHOR_BOTTOM', 'mouse hover remains unchanged')
W:ClearChromePaint()
assert(UI.Tip:IsShown(), 'controller blur must not remove a newer mouse tooltip')
gear:GetScript('OnLeave')(gear)
assert(not UI.Tip:IsShown(), 'mouse leave still hides its tooltip')
print('PASS controller blur/handoff cleanup and mouse tooltip ownership')

-- Keep the existing navigation stops; close/sort retain their mapped actions.
local function audit(view)
  P:Push(view.ctx)
  local expected = { search='Search', filter='Filter sections', size='Resize', settings='Settings', selljunk='Sell junk',
    bankview=CB.Bank:IsWarband() and 'Showing the warband bank' or 'Showing the character bank',
    bankbuy=CB.Bank:UsesBags() and 'Purchase next bank bag slot' or 'Purchase next bank storage tab' }
  view:EnterChrome(1)
  for _, entry in ipairs(view:ChromeList()) do
    local label = entry.id == 'tabs' and entry.widget.tip or expected[entry.id]
    if label then
      assert(UI.Tip:IsShown() and title() == label, 'reachable ' .. view.kind .. ' chrome needs label: ' .. entry.id)
      assert(UI.Tip.anchor == 'ANCHOR_TOP', 'focus tip stays above control, not over item grid')
    elseif entry.id ~= 'bagslot' and entry.id ~= 'bankbag' then
      error('unaudited chrome: ' .. entry.id)
    end
    view:MoveChrome(1)
  end
  view:LeaveChrome()
end
audit(W)
W.filterCat = 'Armor'; W:UpdateFilterChip(); audit(W)
W.filterCat = nil; W:UpdateFilterChip()
W.frame.sellBtn:Show(); audit(W); W.frame.sellBtn:Hide()
local B, bank = CB.Bank, CB.Bank.window
Enum.BagIndex.Characterbanktab, Enum.BagIndex.Accountbanktab = -4, -5
C_Bank.ShouldUsePlayerBagsInBank = function() return true end
C_Bank.CanUseBank = function() return true end
C_Bank.CanPurchaseBankTab = function() return true end
C_Bank.CanViewBank = function() return true end
C_Bank.FetchNumPurchasedBankTabs = function() return 3 end
C_Bank.FetchPurchasedBankTabData = function() return { {ID=6}, {ID=7}, {ID=8} } end
C_Bank.FetchNextPurchasableBankTabData = function() return {tabCost=1234567, canAfford=true} end
C_Container.GetContainerNumSlots = function(id) return id == 6 and 28 or (id == 7 and 8 or 0) end
C_Container.GetContainerItemInfo = function(bag, slot) if bag == -4 and slot == 2 then return {iconFileID=133622} end end
B.active = true; B.viewType = nil
bank:Open(); bank:UpdateExtras(); audit(bank)
C_Bank.ShouldUsePlayerBagsInBank = function() return false end
C_Bank.FetchPurchasedBankTabData = function() return { {ID=6, icon=1}, {ID=7} } end
bank:UpdateExtras(); audit(bank)
print('PASS all existing bag/bank chrome stops have labels or unchanged equipped-item tips')

local labels = {}
for _, b in ipairs(glyphs) do
  assert(b.cbTooltip and b.cbTooltip ~= '', 'own icon button must have a real label')
  local click, enter, leave = b:GetScript('OnClick'), b:GetScript('OnEnter'), b:GetScript('OnLeave')
  enter(b)
  assert(UI.Tip:IsShown() and title() == b.cbTooltip and UI.Tip.anchor == 'ANCHOR_BOTTOM', 'mouse glyph label unchanged')
  leave(b); assert(not UI.Tip:IsShown(), 'mouse glyph leave unchanged')
  assert(b:GetScript('OnClick') == click and b:GetScript('OnEnter') == enter and b:GetScript('OnLeave') == leave, 'no handler replacement')
  labels[b.cbTooltip] = true
end
assert(labels.Settings and labels.Close and labels['Clean up (sort)'], 'real header icon audit includes gear, close and sort')
print('PASS all constructed bags/bank/settings glyph mouse labels and handlers unchanged')
P:Push(W.ctx); focus(W, 'settings')
assert(UI.Tip:IsShown(), 'eligibility test starts with visible focus tip')
CB.db.pad.mode = 'off'; P:Apply('label blur test')
assert(P:Top() == W.ctx, 'eligibility loss keeps shown window context')
BagglerTip:GetScript('OnUpdate')(BagglerTip)
assert(not UI.Tip:IsShown(), 'disabled controller route must hide focus tip even if context remains')
CB.db.pad.mode = 'on'; P:Apply('label blur restore')
print('PASS controller eligibility blur hides focus tip')
W:Close(); bank:Close(); CB.Bank.active = false; P:Reset()
W:Open(); FLUSH(); P.input:Tick(); P:SetBackend('catcher')
W:EnterChrome(1)
local receiver = P:Receiver()
for _ = 1, #W:ChromeList() - 1 do
  receiver:GetScript('OnGamePadButtonDown')(receiver, 'PADDRIGHT')
  receiver:GetScript('OnGamePadButtonUp')(receiver, 'PADDRIGHT')
end
assert(W:ChromeId() == 'settings' and UI.Tip:IsShown() and title() == 'Settings', 'actual receiver navigation reaches labeled gear')
focus(W, 'size'); W:BeginSize()
assert(not UI.Tip:IsShown(), 'entering resize mode blurs the chrome explanation')
W:EndSize(); W:Close()
print('PASS real receiver gear navigation and resize/close cleanup')


