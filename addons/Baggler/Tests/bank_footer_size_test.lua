-- Real shipping TOC bank footer geometry (offline anchors; no live rendering claim).
dofile('tests/harness/ca_stubs.lua')
local create = CreateFrame
CreateFrame = function(...)
  local f = create(...)
  function f:SetPoint(...) self.__point = { ... } end
  local text = f.CreateFontString
  f.CreateFontString = function(self, _, _, role)
    local s = text(self)
    s.__fontObject = role
    function s:SetFontObject(r) self.__fontObject = r end
    function s:SetPoint(...) self.__point = { ... } end
    function s:GetStringWidth() return #(tostring(self:GetText() or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '')) * 6 end
    function s:GetStringHeight() return 14 end
    return s
  end
  return f
end
function UnitClass() return 'Warrior', 'WARRIOR' end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, n, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
local B, W = CB.Bank, CB.Bank.window
Enum.BagIndex.Characterbanktab, Enum.BagIndex.Accountbanktab = -4, -5
C_Bank.ShouldUsePlayerBagsInBank = function() return true end
C_Bank.CanUseBank = function() return true end
C_Bank.CanPurchaseBankTab = function() return true end
C_Bank.CanViewBank = function() return true end
C_Bank.FetchNumPurchasedBankTabs = function() return 3 end
C_Bank.FetchPurchasedBankTabData = function() return { { ID = 6 }, { ID = 7 }, { ID = 8 } } end
C_Bank.FetchNextPurchasableBankTabData = function() return { tabCost = 1234567, canAfford = true } end
C_Container.GetContainerNumSlots = function(id) return id == 6 and 28 or (id == 7 and 8 or 0) end
C_Container.GetContainerItemInfo = function(bag, slot) if bag == -4 and slot == 2 then return { iconFileID = 133622 } end end
B.active = true; B.viewType = nil
W:Open(); W:UpdateExtras()
local f = W.frame
local slot = f.bagSlots[1]
assert(slot:GetWidth() == 32 and slot:GetHeight() == 32, 'equipped bank bag remains the 32px reference')
local controls = { all = f.bankTabs[1], buy = f.purchaseBtn, view = f.viewBtn, empty = f.bagSlots[2] }
for name, b in pairs(controls) do
  assert(b and b:IsShown(), name .. ' control shown')
  assert(b:GetWidth() == 32 and b:GetHeight() == 32, name .. ' must match the 32px equipped bank-bag target')
end
assert(controls.all.label.__fontObject == 'BagglerFontCount', 'All label uses the readable bag-slot count role')
assert(controls.view.label.__fontObject == 'BagglerFontCount', 'warband switch label uses the readable count role')
assert(controls.buy.label.__fontObject == 'BagglerFontTitle', '+ is a large readable purchase glyph')
assert(f.moneyText.__fontObject == 'BagglerFontNumber', 'next-slot cost uses the larger number role')
assert(f.moneyText:GetText():find('Next', 1, true) and f.moneyText:GetText():find(CB.UI:Money(1234567), 1, true))
-- Fit at narrow and wide bank widths, with hints on: no overlap with each other, the
-- next-slot/fullness row, or the hint bar; hidden footer reserves nothing for it.
CB.db.pad.mode = 'on'; CB.db.pad.hints = true
for _, width in ipairs({ 140, 336, 520 }) do
  W.innerW = width; W:ApplySize()
  local inner, bottom, boxes = math.max(width + 24, 0) - 24, 0, {}
  for _, b in ipairs(W.footerControls) do
    if b:IsShown() then
      local p = b.__point
      local x, y = p[4], -p[5]
      assert(x >= 0 and x + b:GetWidth() <= math.max(inner, W.frame:GetWidth() - 24), 'control inside footer @' .. width)
      for _, o in ipairs(boxes) do
        assert(x >= o[1] + o[3] or o[1] >= x + b:GetWidth() or y >= o[2] + o[4] or o[2] >= y + b:GetHeight(), 'controls overlap @' .. width)
      end
      boxes[#boxes + 1] = { x, y, b:GetWidth(), b:GetHeight() }
      bottom = math.max(bottom, y + b:GetHeight())
    end
  end
  assert(-f.moneyText.__point[5] >= bottom + 6 and -f.slotsText.__point[5] >= bottom + 6, 'cost/fullness below controls @' .. width)
  assert(f.footer:GetHeight() == W.footerH - 8 and f.footer:GetHeight() >= -f.moneyText.__point[5] + 14, 'footer reserves cost row @' .. width)
  assert(f.footer.__point[3] == 8 + W.hintH, 'footer sits above the reserved hint height @' .. width)
end
CB.db.showFooter = false; W:ApplySize()
assert(not f.footer:IsShown() and W.footerH == 8, 'hidden footer reserves no bank control/cost space')
CB.db.showFooter = true
-- Storage-tab clients keep the same readable targets.
C_Bank.ShouldUsePlayerBagsInBank = function() return false end
C_Bank.FetchPurchasedBankTabData = function() return { { ID = 6, icon = 1 }, { ID = 7 } } end
W:UpdateExtras()
for _, b in ipairs(W.footerControls) do assert(b:GetWidth() == 32 and b:GetHeight() == 32, 'tab-mode control 32px') end
assert(f.bankTabs[3].label.__fontObject == 'BagglerFontCount', 'numbered tab label readable')
print('PASS bank footer: 32px All/empty/+/switch targets, readable labels and next-slot cost, no overlap (offline)')
