-- Optional exact-client source contract probe, invoked from bank_slots_test.lua.
-- BAGGLER_BANK_SOURCE must be the extracted source root containing Interface/.
local CB, root = ...
local function read(relative)
  local f = assert(io.open(root .. '/Interface/AddOns/' .. relative))
  local text = f:read('*a'); f:close(); return text
end
local native = read('Blizzard_UIPanels_Game/Mainline/BankFrameTemplates.lua')
local xml = read('Blizzard_UIPanels_Game/Mainline/BankFrameTemplates.xml')
local camelot = read('Blizzard_UIPanels_Game/Camelot/BankFrame.lua')
assert(xml:find('name="BankPanelPurchaseButtonScriptTemplate"', 1, true))
local code = assert(native:match('(BankPanelPurchaseTabButtonMixin = .-)BankPanelMoneyFrameMixin ='))
local popupCode = assert(camelot:match('^(.-)bankFrameWidthOverride'))
local shown, purchased, amount
local env = {
  BankPanelSystemMixin = {}, StaticPopupDialogs = {}, SOUNDKIT = { IG_MAINMENU_OPTION = 1 },
  PlaySound = function() end,
  CreateFromMixins = function() return {} end,
  StaticPopup_Show = function(key, _, _, data) shown = { key = key, data = data } end,
  C_Bank = {
    FetchNextPurchasableBankTabData = function(kind)
      assert(kind == CB.Bank:ViewType()); return { tabCost = 345678 }
    end,
    PurchaseBankTab = function(kind) purchased = kind end,
  },
  MoneyFrame_Update = function(_, cost) amount = cost end,
}
local chunk = assert(loadstring(code)); setfenv(chunk, env); chunk()
chunk = assert(loadstring(popupCode)); setfenv(chunk, env); chunk()
local W = CB.Bank.window
local button = W.frame.purchaseBtn
assert(button.__template == 'BankPanelPurchaseButtonScriptTemplate,BackdropTemplate')
assert(button:GetScript('OnClick') == nil, 'addon must not replace the inherited native purchase script')
local originalClick = button:GetScript('OnClick')
-- The generic harness does not interpret XML. Supply only the exact pinned
-- inherited script/method, not a synthetic implementation of the purchase.
button.GetBankTypeForTabPurchase = env.BankPanelPurchaseTabButtonMixin.GetBankTypeForTabPurchase
button:SetScript('OnClick', env.BankPanelPurchaseTabButtonMixin.OnClick)
for i, entry in ipairs(W:ChromeList()) do if entry.widget == button then W.chrome = i end end
W:ActivateChrome()
assert(shown and shown.key == 'CONFIRM_BUY_BANK_TAB' and shown.data.bankType == CB.Bank:ViewType())
assert(purchased == nil, 'controller activation must only show confirmation, not purchase')
local popup = env.StaticPopupDialogs.CONFIRM_BUY_BANK_TAB
popup.OnShow({ MoneyFrame = {} }, shown.data)
assert(amount == 345678, 'native confirmation re-fetches current cost')
popup.OnAccept({}, shown.data)
assert(purchased == CB.Bank:ViewType(), 'accept retains native restricted PurchaseBankTab route')
button:SetScript('OnClick', originalClick)
button.GetBankTypeForTabPurchase = nil
W.chrome = nil
print('PASS exact FrameXML native purchase template, controller dialog, live cost and confirmation-only purchase')
