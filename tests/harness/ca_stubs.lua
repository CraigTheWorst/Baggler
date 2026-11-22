-- Minimal fake WoW environment to smoke-test Baggler logic.
local ADDON_DIR = arg[1]
local errors = {}

local numeric = { GetStringWidth = 60, GetStringHeight = 24, GetLeft = 100, GetTop = 600, GetBottom = 100, GetRight = 500, GetWidth = 100, GetHeight = 100, GetVerticalScroll = 0,
  GetFrameLevel = 5, GetScale = 1, GetAlpha = 1, GetEffectiveScale = 1 }

frames = {}
local function newFrame(ftype, name, parent)
  local f = { __type = ftype, __name = name, __parent = parent, __shown = true, __scripts = {}, __hooks = {}, __id = 0, __text = "" }
  if ftype == "Frame" or ftype == "Button" or ftype == "ItemButton" or ftype == "EditBox" or ftype == "Slider" or ftype == "ScrollFrame" or ftype == nil then end
  setmetatable(f, { __index = function(t, k)
    if numeric[k] then return function() return numeric[k] end end
    if k == "GetCenter" then return function() return 100, 100 end end
    if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
    if type(k) == "string" and k:match("^[A-Z][a-z]") and k:match("^[A-Z][a-z]+") and
       (k:match("^Set") or k:match("^Get") or k:match("^Is") or k:match("^Enable") or k:match("^Register") or k:match("^Clear")
        or k:match("^Create") or k:match("^Start") or k:match("^Stop") or k:match("^Click") or k:match("^Disable") or k:match("^Raise")
        or k:match("^Lower") or k:match("^Apply") or k:match("^Unregister") or k:match("^Fire") or k:match("^Add") or k:match("^Lock")
        or k:match("^Unlock") or k:match("^Update") or k:match("^Highlight") or k:match("^Play") or k:match("^Stop") or k:match("^Open") or k:match("^Close") or k:match("^Has") or k:match("^Can")) then
      return function(self, ...) return self end -- chainable no-op
    end
    return nil
  end })
  -- scroll frames remember where they were scrolled to
  function f:SetVerticalScroll(v) self.__vscroll = v end
  function f:GetVerticalScroll() return self.__vscroll or 0 end
  function f:GetVerticalScrollRange() return 100000 end
  function f:Show() self.__shown = true; if self.__scripts.OnShow then self.__scripts.OnShow(self) end end
  function f:Hide() local was = self.__shown; self.__shown = false; if was and self.__scripts.OnHide then self.__scripts.OnHide(self) end end
  function f:SetShown(v) if v then self:Show() else self:Hide() end end
  function f:IsShown() return self.__shown end
  -- visible = shown, and so is every ancestor (as in the game)
  function f:IsVisible()
    local node = self
    while node do
      if not node.__shown then return false end
      node = node.__parent
    end
    return true
  end
  function f:SetScale(v) self.__scale = v end
  function f:GetScale() return self.__scale or 1 end
  function f:SetAlpha(v) self.__alpha = v end
  function f:GetAlpha() return self.__alpha or 1 end
  function f:SetScript(n, fn) self.__scripts[n] = fn end
  function f:GetScript(n) return self.__scripts[n] end
  function f:GetRect() return 100, 100, 100, 100 end
  function f:HookScript(n, fn) local old = self.__scripts[n]; self.__scripts[n] = function(...) if old then old(...) end fn(...) end end
  function f:SetID(i) self.__id = i end
  function f:GetID() return self.__id end
  function f:GetName() return self.__name end
  -- sizes are remembered, as in the game (GetWidth / GetHeight fall back to 100 for a frame never sized)
  function f:SetSize(w, h) self.__w, self.__h = w, h end
  function f:SetWidth(w) self.__w = w end
  function f:SetHeight(h) self.__h = h end
  function f:GetWidth() return self.__w or 100 end
  function f:GetHeight() return self.__h or 100 end
  function f:GetParent() return self.__parent end
  -- Moving a shown frame under a hidden parent hides it, and the game runs its OnHide script (and the other way round
  -- for OnShow). Game frames close whatever they are showing in OnHide, so this matters.
  function f:SetParent(p)
    local was = self:IsVisible()
    self.__parent = p
    local now = self:IsVisible()
    if was and not now and self.__scripts.OnHide then self.__scripts.OnHide(self) end
    if not was and now and self.__shown and self.__scripts.OnShow then self.__scripts.OnShow(self) end
  end
  function f:SetText(t) self.__text = t end
  function f:GetText() return self.__text end
  function f:SetAttribute(k, v) self.__attr = self.__attr or {}; self.__attr[k] = v end
  function f:GetAttribute(k) return self.__attr and self.__attr[k] end
  function f:SetFrameRef(k,v) self.__refs=self.__refs or {};self.__refs[k]=v end
  function f:GetFrameRef(k) return self.__refs and self.__refs[k] end
  function f:EnableGamePadButton(on)
    assert(not COMBAT, "restricted receiver enable in combat")
    self.__padEnabled=on
  end
  function f:SetPropagateKeyboardInput(on)
    assert(not COMBAT, "restricted propagation in combat")
    self.__propagate=on
  end
  function f:CreateFontString() return newFrame("FontString", nil, self) end
  function f:CreateTexture() return newFrame("Texture", nil, self) end
  function f:GetNormalTexture() return newFrame("Texture") end
  function f:GetPushedTexture() return newFrame("Texture") end
  function f:GetHighlightTexture() return newFrame("Texture") end
  function f:GetThumbTexture() return newFrame("Texture") end
  function f:HasFocus() return false end
  function f:IsPlaying() return false end
  function f:Click(button, down) self.__lastClickDown = down; if self.__scripts.OnClick then self.__scripts.OnClick(self, button or "LeftButton", down) end end
  function f:RegisterEvent() end
  if name then _G[name] = f end
  frames[#frames + 1] = f
  return f
end

COMBAT = false
FOREVER = true
PROTECTED = { Show = 1, Hide = 1, SetPoint = 1, ClearAllPoints = 1, SetSize = 1, SetID = 1, SetAllPoints = 1, SetWidth = 1, SetHeight = 1, Initialize = 1 }
function CreateFrame(ftype, name, parent, template)
  local f = newFrame(ftype, name, parent)
  f.__template = template
  if template and template:find("SecureHandlerStateTemplate",1,true) then
    -- Execute the real generated binding snippet against an isolated fake owner.
    -- This is an offline permission model, not a native secure-execution proof.
    f.__bindings={}
    local handle={}
    function handle:ClearBindings() wipe(f.__bindings) end
    function handle:SetBindingClick(_,key,target,button) f.__bindings[key]="CLICK "..target..":"..button end
    function handle:SetBinding(_,key,command) f.__bindings[key]=command end
    function handle:SetAttribute(k,v) f.__attr=f.__attr or {};f.__attr[k]=v end
    function handle:GetAttribute(k) return f:GetAttribute(k) end
    function f:Execute(body)
      assert(not COMBAT,"restricted Execute in combat")
      local chunk=assert(loadstring("return function(self) "..body.." end"))
      setfenv(chunk,{})
      return chunk()(handle)
    end
  end
  if template and template:find("ContainerFrameItemButtonTemplate") then
    f.__protected = true
    f.__scripts.OnClick = function() end             -- the template ships Blizzard's click handler
    local base = getmetatable(f).__index
    setmetatable(f, { __index = function(t, k)
      if PROTECTED[k] and rawget(t, k) == nil then
        local fn = base(t, k)
        return function(self, ...)
          if COMBAT then error("ADDON_ACTION_BLOCKED: protected call " .. k .. " in combat on " .. tostring(self.__name), 2) end
          return fn(self, ...)
        end
      end
      return base(t, k)
    end })
    -- the real template methods
    rawset(f, "Initialize", function(self, a, b, c)
      if COMBAT then error("ADDON_ACTION_BLOCKED Initialize", 2) end
      if FOREVER then
        assert(type(a) == "table" and a.IsCombinedBagContainer, "forever Initialize needs a holder")
        self.bagID, self.__id = b, c
      else
        assert(type(a) == "number", "retail Initialize needs (bag, slot)")
        self.bagID, self.__id = a, b
      end
    end)
    rawset(f, "GetBagID", function(self) return self.bagID end)
    rawset(f, "SetHasItem", function(self, v) self.__hasItem = v end)
    rawset(f, "UpdateCooldown", function(self, icon) end)
  end
  if ftype == "ItemButton" or (template and template:find("ContainerFrameItemButtonTemplate")) then
    f.Cooldown = newFrame("Cooldown")
    if name then _G[name .. "IconTexture"] = newFrame("Texture") end
  end
  return f
end
function CreateFont(name)
  local f = newFrame("Font", name)
  function f:SetFont(path, size, flags) self.__font = { path, size, flags } end
  function f:GetFont() local t = self.__font or {}; return t[1], t[2], t[3] end
  if name then _G[name] = f end
  return f
end
UIParent = newFrame("Frame", "UIParent")
UIParent.__w, UIParent.__h = 1920, 1080
function UIParent:GetHeight() return 1080 end
UISpecialFrames = {}
STANDARD_TEXT_FONT = "x"
BackdropTemplateMixin = {}
function Mixin(a, b) for k, v in pairs(b) do a[k] = v end return a end
GameTooltip = newFrame("GameTooltip", "GameTooltip")
StackSplitFrame = newFrame("Frame", "StackSplitFrame")
StackSplitFrame.__shown = false      -- like the client: the amount dialog is hidden until something opens it
CUR_X, CUR_Y = 0, 0
function GetCursorPosition() return CUR_X, CUR_Y end
function InCombatLockdown() return COMBAT end
function RegisterStateDriver() end
function ClearOverrideBindings() end
local bound = {}
function SetOverrideBindingClick(_, _, key, btn) bound[key] = btn end
_G.__bound = bound
function hooksecurefunc(name, fn)
  local orig = _G[name]
  _G[name] = function(...) local r = orig and orig(...); fn(...); return r end
end
function CursorHasItem() return false end
function ClearCursor() end
function PlaySound() end
SOUNDKIT = {}
function GetMoney() return 123456 end
function GetInventoryItemTexture() return nil end
function GetBuildInfo() return "1.60.1", "70790", "x", 16001 end
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
WOW_PROJECT_ID = 1; WOW_PROJECT_MAINLINE = 1
function SetItemButtonTexture(b, t) b.__tex = t end
function SetItemButtonCount(b, c) b.__count = c end
function SetItemButtonDesaturated() end
function CooldownFrame_Set() end
ITEM_QUALITY_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })
Enum = { BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5 } }
EXPANSION_NAME0 = "Classic"; EXPANSION_NAME1 = "TBC"
SlashCmdList = {}
date = os.date
time = os.time
function debugstack() return "stack" end
function GetTime() return os.clock() end
local _h = function(m) end
function geterrorhandler() return _h end
function seterrorhandler(h) _h = h end
HANDLED = {}
_h = function(m) HANDLED[#HANDLED + 1] = m end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end

-- Fake inventory
local contents = {
  [0] = { [1] = {id=1, q=1, name="Hearthstone", class=15, sub=0}, [2] = {id=2, q=0, name="Broken Fang", class=15, sub=0},
          [3] = {id=3, q=3, name="Sword of Test", class=2, sub=7, ilvl=400}, [5] = {id=5, q=2, name="Healing Potion", class=0, sub=1, count=5},
          [6] = {id=6, q=1, name="Linen Cloth", class=7, sub=5, count=20}, [7] = {id=7, q=4, name="Epic Ring", class=4, sub=0, ilvl=450, equip="INVTYPE_FINGER"} },
  [1] = { [1] = {id=8, q=1, name="Roast Boar", class=0, sub=5, count=3} },
  [2] = {}, [3] = {}, [4] = {},
}
STUB_CONTENTS = contents
local sizes = { [0] = 16, [1] = 12, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
STUB_SIZES = sizes
C_Container = {
  GetContainerNumSlots = function(b) return sizes[b] or 0 end,
  GetContainerItemInfo = function(b, s)
    local it = contents[b] and contents[b][s]
    if not it then return nil end
    return { iconFileID = 1, stackCount = it.count or 1, isLocked = false, quality = it.q, itemID = it.id,
             itemName = it.name, hyperlink = "|cffffffff|Hitem:" .. it.id .. "|h[" .. it.name .. "]|h|r", isBound = false }
  end,
  GetContainerItemQuestInfo = function() return { isQuestItem = false } end,
  GetContainerItemCooldown = function() return 0, 0, 1 end,
  UseContainerItem = function(...) USED[#USED + 1] = { ... } end, PickupContainerItem = function(b, sl) PICKED[#PICKED + 1] = { b, sl }; if ACTION_TEST then CURSOR = true end end, SortBags = function() end,
  ContainerIDToInventoryID = function(b) return 19 + b end,
}
C_Container.GetContainerItemDurability = function() return nil end
C_Container.GetContainerNumFreeSlots = function(b) return 4, 0 end
C_Item = {
  GetItemInfoInstant = function(id)
    for _, bag in pairs(contents) do for _, it in pairs(bag) do if it.id == id then return id, "t", "s", it.equip or "", 1, it.class, it.sub end end end
  end,
  GetItemInfo = function(x) return nil end,
  GetDetailedItemLevelInfo = function(link) local id = tonumber(link:match("item:(%d+)")); for _, bag in pairs(contents) do for _, it in pairs(bag) do if it.id == id then return it.ilvl end end end end,
  GetItemCount = function() return 99 end,
  GetItemClassInfo = function(c) return "Class" .. c end,
  GetItemSubClassInfo = function(c, s) return "Sub" .. c .. "_" .. s end,
}
C_NewItems = { IsNewItem = function(b, s) return b == 0 and s == 1 end, ClearAll = function() end }
C_EquipmentSet = { GetEquipmentSetIDs = function() return {} end, GetItemIDs = function() return {} end }
C_ActionBar = { ShouldShowKeyring = function() return false end }
C_CurrencyInfo = { GetCoinTextureString = function(n) return n .. "c" end }
C_GamePad = { IsEnabled = function() return true end }
function GetInventorySlotInfo(name)
  local names={"HEADSLOT","NECKSLOT","SHOULDERSLOT","SHIRTSLOT","CHESTSLOT","WAISTSLOT","LEGSSLOT","FEETSLOT","WRISTSLOT","HANDSSLOT","FINGER0SLOT","FINGER1SLOT","TRINKET0SLOT","TRINKET1SLOT","BACKSLOT","MAINHANDSLOT","SECONDARYHANDSLOT","RANGEDSLOT","TABARDSLOT"}
  for i,value in ipairs(names) do if value==name then return i end end
end
DEFERRED = {}
function FLUSH() local q = DEFERRED; DEFERRED = {}; for _, fn in ipairs(q) do fn() end end
C_Timer = { NewTicker = function() return { Cancel = function() end } end,
  After = function(delay, f) if delay == 0 or DEFER then DEFERRED[#DEFERRED + 1] = f else f() end end }
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end, IsAddOnLoaded = function() return false end }
CloseAllBags = function() end
OpenAllBags = function() end
ToggleAllBags = function() end
ToggleBackpack = function() end
ContainerFrameCombinedBags = newFrame("Frame", "ContainerFrameCombinedBags"); ContainerFrameCombinedBags.__shown = false


-- merchant stubs
MerchantFrame = newFrame("Frame", "MerchantFrame")
function MerchantFrame:Hide() self.__shown = false end
local vendorItems = {
  { name = "Bread", tex = 1, price = 50, stack = 5, avail = -1, q = 1, usable = true },
  { name = "Fine Sword", tex = 2, price = 90000, stack = 1, avail = 3, q = 3, usable = true, extended = true },
  { name = "Arrows", tex = 3, price = 100, stack = 200, avail = -1, q = 1, usable = false },
}
C_MerchantFrame = { GetItemInfo = function(i) local v = vendorItems[i]; if not v then return nil end
  return { name = v.name, texture = v.tex, price = v.price, stackCount = v.stack, numAvailable = v.avail,
           isPurchasable = true, isUsable = v.usable, hasExtendedCost = v.extended } end,
  IsMerchantItemRefundable = function() return true end }
function GetMerchantNumItems() return #vendorItems end
function GetMerchantItemLink(i) return "|cffffffff|Hitem:" .. (900 + i) .. "|h[" .. vendorItems[i].name .. "]|h|r" end
function GetMerchantItemMaxStack(i) return 20 end
function CanAffordMerchantItem(i) return i ~= 2 end
function GetMerchantItemCostInfo(i) return vendorItems[i].extended and 1 or 0 end
function GetMerchantItemCostItem(i, n) return 5, 10, nil, "Honor" end
function GetNumBuybackItems() return 2 end
function GetBuybackItemInfo(i) return "Sold thing " .. i, 7, 123, 1, 0, true end
function GetBuybackItemLink(i) return nil end
function CanMerchantRepair() return true end
function GetRepairAllCost() return 4321, true end
function CanGuildBankRepair() return true end
function GetInventoryItemLink(unit, slot) if slot == 1 then return "|cffffffff|Hitem:77|h[Worn Helm]|h|r" end end
function GetInventoryItemDurability(slot) if slot == 1 then return 30, 100 end end
INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED = 1, 19
BOUGHT = {}
function BuyMerchantItem(i, q) BOUGHT[#BOUGHT + 1] = { i, q } end
function BuybackItem(i) BOUGHT[#BOUGHT + 1] = { "buyback", i } end
function RepairAllItems(g) BOUGHT[#BOUGHT + 1] = { "repairall", g } end
function MerchantFrame_ConfirmExtendedItemCost(b, q) BOUGHT[#BOUGHT + 1] = { "confirm", b:GetID(), q } end
function MerchantFrame_ConfirmHighCostItem(b) BOUGHT[#BOUGHT + 1] = { "high", b:GetID() } end
MERCHANT_HIGH_PRICE_COST = 1000000
CLOSED = false
function CloseMerchant() CLOSED = true end
function UnitName() return "Innkeeper Bob" end
function PickupMerchantItem() end
function GetCursorInfo() return nil end
function InRepairMode() return false end
function ShowRepairCursor() end
function HideRepairCursor() end
function PickupInventoryItem() end
C_Container_GetItemDurability = nil


-- bank stubs
Enum.BagIndex.CharacterBankTab_1 = 6; Enum.BagIndex.CharacterBankTab_2 = 7
Enum.BankType = { Character = 0, Account = 2 }
sizes[6] = 8; sizes[7] = 4
contents[6] = { [1] = {id=60, q=3, name="Bank Sword", class=2, sub=7, ilvl=300}, [2] = {id=61, q=1, name="Spare Linen", class=7, sub=5, count=40} }
contents[7] = { [1] = {id=62, q=2, name="Bank Potion", class=0, sub=1, count=3} }
BANK = { closed = 0, deposited = 0 }
C_Bank = {
  FetchPurchasedBankTabData = function() return { { ID = 7, name = "Tab 2", icon = 2 }, { ID = 6, name = "Tab 1", icon = 1 } } end,
  FetchNextPurchasableBankTabData = function() return { tabCost = 1000000 } end,
  CloseBankFrame = function() BANK.closed = BANK.closed + 1 end,
  AutoDepositItemsIntoBank = function() BANK.deposited = BANK.deposited + 1 end,
}
BankFrame = newFrame("Frame", "BankFrame")
BankFrame.GetActiveBankType = function() return 0 end
BankFrame:Hide()           -- (the game shows it when a banker is opened and hides it when the visit ends; see fireWow)
BankPanel = newFrame("Frame", "BankPanel")
BankPanel.MoneyDisplay = newFrame("Frame"); BankPanel.MoneyDisplay.UnregisterEvent = function() BANK.unreg = true end
BankPanel.SetBankType = function(self, t) BANK.type = t end
CLOSESPECIAL = function() end
function CloseSpecialWindows() CLOSESPECIAL() end
USED = {}


-- action bar stubs
CURSOR = false; ACTION_TEST = false; PICKED = {}; PLACED = {}
function CursorHasItem() return CURSOR end
function ClearCursor() CURSOR = false end
function PlaceAction(slot) PLACED[#PLACED + 1] = slot; CURSOR = false end
function HasAction(slot) return slot == 2 end
function GetActionInfo(slot) if slot == 2 then return "item", 123 end end
function GetActionTexture(slot) if slot == 2 then return 5 end end
function GetActionText() return nil end
function GetBindingKey(cmd) if cmd == "ACTIONBUTTON1" then return "PAD1" end if cmd == "ACTIONBUTTON3" then return "PADLTRIGGER-PAD2" end end
function GetBindingText(k) return "bind:" .. k end
for i = 1, 12 do local b = newFrame("Button", "ActionButton" .. i); b.action = i end
for i = 1, 12 do local b = newFrame("Button", "MultiBarBottomLeftButton" .. i); b.action = 60 + i end
for i = 1, 12 do local b = newFrame("Button", "MultiBarRightButton" .. i); b.action = 24 + i; b.__shown = false end

OPENCALLS, CLOSECALLS = 0, 0
function OpenAllBags() OPENCALLS = OPENCALLS + 1 end
function CloseAllBags() CLOSECALLS = CLOSECALLS + 1 end
function ToggleBackpack() end
function ToggleAllBags() ToggleBackpack() end
function ToggleBackpack_Combined() end
function ClearOverrideBindings() for k in pairs(__bound) do __bound[k] = nil end end
StaticPopupDialogs = StaticPopupDialogs or {}
