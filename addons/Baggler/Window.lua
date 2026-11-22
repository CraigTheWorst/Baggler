-- Baggler window: a reusable "view" (the backpack, and the bank, are instances) -
-- layout, item buttons, search, footer, and the controller navigation inside it.
--
-- Combat note: Blizzard's item buttons are protected frames. In combat we never
-- move, resize, show, hide or create them; we only move/hide the plain "holder"
-- frame each one lives in, and only change textures/text on the button.
-- A View owns its records, section layout and selection; WindowUse/WindowMenus/
-- WindowPad extend this shared prototype before Bank.lua instantiates it. Keep
-- bag-only behavior scoped by kind so bank overrides do not change backpack use.
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local View = {}
View.__index = View
CB.View = View
local UI, Inv, Cat, Pad = CB.UI, CB.Inventory, CB.Categories, CB.Pad
local Container = C_Container

local HEADER_H, SEC_GAP = 22, 14
local PADDING, TOP_H, FOOT_H = UI.METRICS.pad, UI.METRICS.topH, UI.METRICS.footH
local MIN_WIDTH = 400   -- the title bar needs this much room
local BANK_MIN_WIDTH = 480   -- the bank title carries a descriptor (Bank / Warband Bank) beside the 36px Baggler art
local function minWidth(W) return W.kind == "bank" and BANK_MIN_WIDTH or MIN_WIDTH end
local INSET = 4         -- breathing room inside the scroll area so rings/edges are never clipped

local buttonCount = 0

--- opts: kind ("bags"|"bank"), frameName, title(), pointKey, getBagIDs(),
---       sellButton, bagSlots, extraButtons, onShow, onHide, edgeLeft, edgeRight
function View.New(opts)
  local W = setmetatable({}, View)
  W.opts = opts
  W.kind = opts.kind
  W.buttons = {}     -- "bag:slot" -> ItemButton (each lives in button.cbHolder)
  W.headers = {}     -- pooled section headers
  W.nav = {}         -- focusable entries in layout order
  W.sections = {}
  W.query = ""
  W.filterCat = nil
  W.ctx = {
    OnPad = function(_, action)
      W:OnPad(action)
      Pad:SyncDirectUse()
    end,
    alive = function() return W.frame ~= nil and W.frame:IsShown() end,
    -- During a visit that has a game frame (vendor, mailbox, guild bank, bank) the bags leave with it: B is then the same
    -- game command as in that visit's own window, so the game closes its frame and both windows go together.
    secureCommand = function(action)
      if action ~= "close" then return nil end
      local v = CB.Vendor
      if v and v.atMerchant and v.closeCommand then return v.closeCommand() end
      if W.kind == "bank" and CB.Bank and CB.Bank.closeCommand then return CB.Bank.closeCommand() end
      local paired = CB.NativeWindows and CB.NativeWindows:PairedCloseCommand(W)
      if paired then return paired end
      if W.kind == "bags" then
        for _, m in ipairs({ CB.Mail, CB.GuildBank, CB.Bank }) do         -- (only a visit that opened these bags itself)
          if m and m.active and m.openedBags and m.closeCommand then return m.closeCommand() end
        end
      end
    end,
    -- While this returns an item, A is bound to the secure use and never enters OnPad.
    directUse = function()
      if W.chrome or W.sizing then return nil end
      return W:SecureUseRec(W.selEntry and W.selEntry.rec)
    end,
  }
  return W
end


--- The item to use through a secure press (the game blocks a plain add-on call for quest items and grimoires), or nil
--- when "use" means something else right now (selling, depositing, an equip question) and the add-on must handle it.
function View:SecureUseRec(rec)
  local W = self
  if CursorHasItem and CursorHasItem() then return nil end
  if SpellIsTargeting and SpellIsTargeting() then return nil end   -- gems, enchants, scrolls: target it, don't use it
  if CB.UseHookActive and CB.UseHookActive() then return nil end   -- an auction window wants the item
  if CB.NativeWindows and CB.NativeWindows:Context() then return nil end
  -- at a bank, A must deposit/withdraw into the right place; a bare `/use` cannot say which
  if (CB.Bank and CB.Bank.active) or (CB.GuildBank and CB.GuildBank.active) or (CB.Mail and CB.Mail:SendActive()) then return nil end
  -- selling: every press must reach the add-on, which re-reads the slot each time.
  if W.merchantOpen or (CB.Vendor and CB.Vendor.atMerchant) then return nil end
  -- a ring / trinket with both slots full needs a question first: let the add-on handle it
  if rec and W:NeedsSlotChoice(rec) then return nil end
  if rec and not rec.empty then
    -- never aim the secure button at a slot that has emptied or changed since the last scan
    local ok, info = pcall(Container.GetContainerItemInfo, rec.bag, rec.slot)
    if ok and info and info.itemID == rec.itemID then return rec end
  end
end

function View:BagIDs() return self.opts.getBagIDs() end

local function accentHex()
  local r, g, b = CB:Accent()
  return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
end

---------------------------------------------------------------------------
-- Item buttons
---------------------------------------------------------------------------
local function hideChild(b, name)
  local c = b[name] or _G[(b:GetName() or "") .. name]
  if c and c.Hide then c:Hide() end
end

-- Strips the game's item-button decorations (quality border, overlays, new-item glow, junk
-- coin ...) so the tile can be drawn in the add-on's own style.
local function styleButton(b)
  for _, child in ipairs({ "IconBorder", "IconOverlay", "IconQuestTexture", "NewItemTexture",
                           "BattlepayItemTexture", "UpgradeIcon", "Stock", "JunkIcon" }) do
    hideChild(b, child)
  end
  if b.ItemContextOverlay then b.ItemContextOverlay:SetAlpha(0) end
  local nt = b.GetNormalTexture and b:GetNormalTexture()
  if nt then nt:SetTexture(""); nt:Hide() end
  local pt = b.GetPushedTexture and b:GetPushedTexture()
  if pt then pt:SetTexture(""); pt:Hide() end

  b:SetHighlightTexture(UI.WHITE)
  local hl = b:GetHighlightTexture()
  if hl then hl:SetVertexColor(1, 1, 1, 0.16) end

  local icon = b.icon or b.Icon or _G[(b:GetName() or "") .. "IconTexture"]
  if icon then
    -- strictly inside the outline: inset by the outline's own physical thickness (a fixed 1 unit is under a pixel
    -- at small scales, which left the art beneath the strips)
    UI:Inset(icon, b, UI.OUTLINE_PX)
  end

  -- outline = the visible ring of a full-tile texture (BACKGROUND -8) with the fill and the icon exactly one physical
  -- pixel inside it; all three are pixel-snapped the same way, so every side is at least one whole pixel
  b.cbRing = b:CreateTexture(nil, "BACKGROUND", nil, -8)
  b.cbBg = b:CreateTexture(nil, "BACKGROUND", nil, -6)
  UI:Inset(b.cbBg, b, UI.OUTLINE_PX)
  b.cbBg:SetSnapToPixelGrid(true); b.cbBg:SetTexelSnappingBias(0)
  b.cbBg:SetColorTexture(UI.tile[1], UI.tile[2], UI.tile[3], 1)
  if icon then icon:SetSnapToPixelGrid(true); icon:SetTexelSnappingBias(0) end

  b.cbBorder = NewFrame("Frame", nil, b, "BackdropTemplate")
  b.cbBorder:SetAllPoints()
  b.cbBorder:SetFrameLevel(b:GetFrameLevel() + 3)
  b.cbBorder:EnableMouse(false)
  UI:ItemOutline(b.cbBorder, b.cbRing)
  b.cbBorder:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)

  -- a thin wash of the item's quality colour up from the bottom edge: rarity reads at a glance, not only by the outline
  -- (drawn on the button itself, above the icon but below its count, so the number is never tinted)
  b.cbQual = b:CreateTexture(nil, "ARTWORK", nil, 3)
  UI:Inset(b.cbQual, b, UI.OUTLINE_PX, true)
  b.cbQual:SetHeight(12)
  b.cbQual:Hide()

  -- dark pills behind the numbers keep them readable over bright icons
  b.cbIlvlBg = b.cbBorder:CreateTexture(nil, "OVERLAY", nil, -1)       -- (sublevel -1: below the text it backs)
  b.cbIlvlBg:SetColorTexture(0, 0, 0, 0.55)
  b.cbIlvlBg:Hide()
  local countText = b.Count or _G[(b:GetName() or "") .. "Count"]
  if countText then UI:StyleCount(countText, b) end
  b.cbCountText = countText

  -- pressing a tile darkens it for as long as the button is down
  b.cbPress = b.cbBorder:CreateTexture(nil, "OVERLAY", nil, 2)
  b.cbPress:SetAllPoints()
  b.cbPress:SetColorTexture(0, 0, 0, 0.28)
  b.cbPress:Hide()
  b:HookScript("OnMouseDown", function(self) self.cbPress:Show() end)
  b:HookScript("OnMouseUp", function(self) self.cbPress:Hide() end)
  b:HookScript("OnLeave", function(self) self.cbPress:Hide() end)

  b.cbIlvl = b.cbBorder:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
  b.cbIlvl:SetPoint("BOTTOMLEFT", 3, 3)
  b.cbIlvlBg:SetPoint("TOPLEFT", b.cbIlvl, "TOPLEFT", -2, 1)
  b.cbIlvlBg:SetPoint("BOTTOMRIGHT", b.cbIlvl, "BOTTOMRIGHT", 2, -1)

  -- a slow gold shimmer over gear that beats what the character wears
  b.cbGlow = b.cbBorder:CreateTexture(nil, "OVERLAY", nil, -2)
  UI:Inset(b.cbGlow, b.cbBorder, UI.OUTLINE_PX)
  b.cbGlow:SetColorTexture(1, 0.84, 0.3, 1)
  b.cbGlow:SetAlpha(0)
  b.cbGlow:Hide()

  b.cbNew = b.cbBorder:CreateTexture(nil, "OVERLAY")
  b.cbNew:SetPoint("CENTER", b.cbBorder, "TOPLEFT", 8, -8)
  b.cbNew:SetSize(5, 5)
  b.cbNew:SetRotation(math.rad(45))               -- a small diamond reads as a mark; a square reads as a pixel
  b.cbNew:SetColorTexture(1, 1, 1, 1)
  b.cbNew:Hide()

  b.cbBoe = b.cbBorder:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
  b.cbBoe:SetPoint("BOTTOMLEFT", 3, 14)

  b.cbUp = b.cbBorder:CreateTexture(nil, "OVERLAY")
  b.cbUp:SetSize(11, 11)
  b.cbUp:SetPoint("TOPRIGHT", -2, -2)
  b.cbUp:SetDesaturated(true)
  b.cbUp:SetVertexColor(1, 0.84, 0.25)               -- gold, not the game's green
  if not (b.cbUp.SetAtlas and pcall(b.cbUp.SetAtlas, b.cbUp, "bags-greenarrow")) then
    b.cbUp:SetTexture("Interface\\Buttons\\UI-MicroStream-Green")
  end
  b.cbUp:Hide()

  b.cbRed = b.cbBorder:CreateTexture(nil, "ARTWORK")
  UI:Inset(b.cbRed, b.cbBorder, UI.OUTLINE_PX)
  b.cbRed:SetColorTexture(0.9, 0.1, 0.1, 0.32)
  b.cbRed:Hide()

  b.cbPin = b.cbBorder:CreateTexture(nil, "OVERLAY")
  b.cbPin:SetSize(10, 2)
  b.cbPin:SetPoint("TOP", 0, -2)
  b.cbPin:Hide()

  b.cbFav = UI:Icon(b.cbBorder, "star", 9)
  b.cbFav:SetPoint("TOPRIGHT", -3, -3)
  b.cbFav:SetColor(unpack(CB.COLOR.gold))
  b.cbFav:Hide()

  -- for players who cannot tell the quality colours apart: a letter in the corner (Settings > Look)
  b.cbQ = b.cbBorder:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
  b.cbQ:SetPoint("BOTTOMRIGHT", -3, 3)

  -- the cooldown countdown: the game's own cooldown frame only draws a sweep unless a client setting asks for
  -- numbers, so the remaining time is written here, over the sweep
  -- (its own frame, above the game's cooldown frame, so the sweep cannot cover it)
  local cdLayer = NewFrame("Frame", nil, b)
  cdLayer:SetAllPoints()
  cdLayer:SetFrameLevel(b:GetFrameLevel() + 20)
  cdLayer:EnableMouse(false)
  b.cbCD = cdLayer:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
  b.cbCD:SetPoint("CENTER", 0, 0)
  b.cbCD:SetTextColor(1, 0.9, 0.5)
  b.cbCD:Hide()
end

-- Cooldown timers. Buttons with a running cooldown are kept in a set and one ticker rewrites their text a few times
-- a second; it sleeps when the set is empty. Cooldowns of 2 seconds or less are the global cooldown and are left out.
local cooling = {}
local cdTicker
local function cooldownText(left)
  if left >= 3600 then return ("%dh"):format(math.ceil(left / 3600)) end
  if left >= 60 then return ("%dm"):format(math.ceil(left / 60)) end
  if left >= 10 then return ("%d"):format(math.ceil(left)) end
  return ("%.1f"):format(left)
end

local function tickCooldowns()
  local now = GetTime()
  local any = false
  for b, c in pairs(cooling) do
    local left = c.start + c.duration - now
    if left <= 0 or not b:IsVisible() then
      cooling[b] = nil
      b.cbCD:Hide()
    else
      any = true
      b.cbCD:SetText(cooldownText(left))
    end
  end
  if not any and cdTicker then cdTicker:Cancel(); cdTicker = nil end
end

--- Shows or clears the cooldown of one item button from the slot's current cooldown: the game's clockwise sweep
--- and, over it, the countdown. Called when a bag is painted, on the game's cooldown event, and by a light check while
--- the window is open, so the display never depends on one event arriving.
local function paintCooldown(b, rec)
  local start, duration = 0, 0
  if rec and not rec.empty and Container.GetContainerItemCooldown then
    local ok, s, d = pcall(Container.GetContainerItemCooldown, rec.bag, rec.slot)
    if ok then start, duration = s or 0, d or 0 end
  end
  if not (start > 0 and duration > 0) and rec and Inv:IsBandage(rec) then
    -- a bandage's lockout is the "Recently Bandaged" effect on the player, shown the same way as an item cooldown
    local left, total = Inv:BandageLockout()
    if left and total then start, duration = GetTime() + left - total, total end
  end
  local active = start > 0 and duration > 0 and start + duration > GetTime()
  local key = active and (start .. ":" .. duration) or false
  if key ~= b.cbCDKey then
    -- the sweep follows the slot's cooldown whenever it changes
    b.cbCDKey = key
    if b.Cooldown and CooldownFrame_Set then
      pcall(CooldownFrame_Set, b.Cooldown, active and start or 0, active and duration or 0, active and 1 or 0)
    elseif b.UpdateCooldown then
      b:UpdateCooldown(rec and rec.icon or false)
    end
    if active then CB:Info("cd", ("cooldown on %s:%s start=%s duration=%s"):format(tostring(rec.bag), tostring(rec.slot), tostring(start), tostring(duration))) end
  end
  if active and duration > 2 then
    if b.Cooldown and b.Cooldown.SetHideCountdownNumbers then pcall(b.Cooldown.SetHideCountdownNumbers, b.Cooldown, true) end
    cooling[b] = { start = start, duration = duration }
    b.cbCD:SetText(cooldownText(start + duration - GetTime()))
    b.cbCD:Show()
    if not cdTicker and C_Timer and C_Timer.NewTicker then cdTicker = C_Timer.NewTicker(0.25, tickCooldowns) end
  else
    cooling[b] = nil
    b.cbCD:Hide()
  end
end

--- Initialises a template button for (bag, slot). Forever and retail differ in
--- signature; try the likely one first and verify the result.
local function initButton(b, holder, bag, slot)
  if not b.Initialize then
    b:SetID(slot)
    b.bagID = bag
    return
  end
  local order = CB.isForever and { "forever", "retail" } or { "retail", "forever" }
  for _, kind in ipairs(order) do
    local ok
    if kind == "forever" then ok = pcall(b.Initialize, b, holder, bag, slot)
    else ok = pcall(b.Initialize, b, bag, slot) end
    if ok and (not b.GetBagID or b:GetBagID() == bag) and b:GetID() == slot then
      CB:Debug("button", "initialised", bag .. ":" .. slot, "via", kind)
      return
    end
  end
  CB:Warn("button", ("Initialize failed for %d:%d - using SetID fallback"):format(bag, slot))
  b:SetID(slot)
  b.bagID = bag
end
View.initButton = initButton        -- (WindowUse builds the auction house proxy button with it)

-- Diagnostic brackets only: this deliberately preserves the existing invocation
-- semantics. A pcall/securecallfunction is not proof that native data stays secure.
local function forwardNativeItemScript(b, script, ...)
  CB:AuraProbe("before native item " .. script)
  local f = b:GetScript(script)
  if f then pcall(f, b, ...) end
  CB:AuraProbe("after native item " .. script)
end

-- Creates one item button from the game's template, so use and drag stay the game's own secure
-- actions, inside a holder frame that carries the bag id the template reads.
function View:NewButton(bag, slot)
  local W = self
  buttonCount = buttonCount + 1
  local name = "BagglerItem" .. buttonCount
  local size = CB.db.iconSize

  -- the holder carries the bag id the template reads and is what we move/hide
  local holder = NewFrame("Frame", name .. "Holder", W.frame.content)
  holder:Hide()
  holder:SetID(bag)
  holder:SetSize(size, size)
  holder.IsCombinedBagContainer = function() return false end

  -- Blizzard's secure template: created with the raw CreateFrame, never wrapped.
  CB:SlotProbe("before item button " .. buttonCount)
  local ok, b = pcall(CreateFrame, "ItemButton", name, holder, "ContainerFrameItemButtonTemplate")
  if not ok then
    CB:Warn("button", "ItemButton frame type failed (" .. tostring(b) .. "), using Button")
    b = CreateFrame("Button", name, holder, "ContainerFrameItemButtonTemplate")
  end
  CB:SlotProbe("after item button " .. buttonCount .. " CreateFrame")
  initButton(b, holder, bag, slot)
  CB:SlotProbe("after item button " .. buttonCount .. " Initialize")
  b:SetAllPoints(holder)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  -- Keep the template click, but send a plain "use" through the secure button below.
  b.cbOrigClick = b:GetScript("OnClick")
  b.cbWrapClick = function(self, button, ...) W:ClickItem(self, button, ...) end
  -- The template's click script is NEVER replaced: a script set from add-on code runs tainted, and the game then blocks
  -- its own use call for quest items and spell items. Where a click must be ours (a vendor, a bank, Alt held ...), an
  -- invisible catcher lies over the button and takes the click instead (View:ClickMode / SyncNativeClick).
  local catch = NewFrame("Button", nil, b)
  catch:SetAllPoints(b)
  catch:SetFrameLevel(b:GetFrameLevel() + 8)
  catch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  catch:RegisterForDrag("LeftButton")
  catch:SetScript("OnClick", function(_, button) W:ClickItem(b, button) end)
  -- the drag and the hover are the item button's own, run from here (the catcher is above it and has the mouse)
  catch:SetScript("OnDragStart", function() forwardNativeItemScript(b, "OnDragStart", "LeftButton") end)
  catch:SetScript("OnReceiveDrag", function() forwardNativeItemScript(b, "OnReceiveDrag") end)
  catch:SetScript("OnEnter", function() forwardNativeItemScript(b, "OnEnter"); W:ItemEnter(b) end)
  catch:SetScript("OnLeave", function() forwardNativeItemScript(b, "OnLeave"); W:HoverCardEnd() end)
  catch:Hide()
  b.cbCatch = catch
  -- let the mouse wheel reach our scroll frame
  b:SetScript("OnMouseWheel", nil)
  b:EnableMouseWheel(false)

  styleButton(b)
  b.cbHolder, b.cbBag, b.cbSlot = holder, bag, slot
  b:HookScript("OnEnter", CB:Wrap("item:OnEnter", function(self) W:ItemEnter(self) end))
  b:HookScript("OnLeave", function() W:HoverCardEnd() end)
  -- read-only: while a split trace runs, note which tile was hidden (see Pad:BeginSplitTrace)
  b:HookScript("OnHide", function(self) if Pad.TraceTileHide then Pad:TraceTileHide(self) end end)
  -- with the game's own click script on the button (View:ClickMode) our handler does not run: note what a click lifts
  -- (a drop on the destroy button needs it). A hook only observes; the game's script does the work.
  b:HookScript("PreClick", function(self)
    if not (self.cbCatch and self.cbCatch:IsShown()) and not (CursorHasItem and CursorHasItem()) and self.cbEntry and self.cbEntry.rec and not self.cbEntry.rec.empty then
      W.heldRec = self.cbEntry.rec
    end
  end)
  return b
end

--- The mouse entering an item: select it, show its card.
function View:ItemEnter(b)
  local W = self
  if not b.cbEntry then return end
  if W.chrome or W.sizing then W.chrome, W.sizing = nil, false; W:ClearChromePaint() end
  W:SelectEntry(b.cbEntry, true)
  W:HoverCard(b)             -- the card, like the controller's, in place of the plain tooltip
end

--- Returns the button for a slot, creating it if allowed (never in combat).
function View:GetButton(bag, slot)
  local W = self
  local key = bag .. ":" .. slot
  local b = W.buttons[key]
  if not b then
    if InCombatLockdown() then
      W.needsCombatRefresh = true
      return nil
    end
    b = W:NewButton(bag, slot)
    W.buttons[key] = b
    W:SyncNativeClick(b)
  end
  return b
end

--- Create every button the current containers can need, while it is safe to.
function View:Precreate()
  local W = self
  if InCombatLockdown() or not W.frame then return end
  for _, bag in ipairs(W:BagIDs()) do
    for slot = 1, (Container.GetContainerNumSlots(bag) or 0) do W:GetButton(bag, slot) end
  end
end

local function qualityColor(q)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return c.r, c.g, c.b end
  return 0.6, 0.6, 0.6
end

local QUALITY_LETTER = { [3] = "R", [4] = "E", [5] = "L", [6] = "A", [7] = "H" }

-- Draws one item record into its button: icon, count, quality edge and the small state marks.
local function paintButton(b, rec)
  local icon = b.icon or b.Icon or _G[(b:GetName() or "") .. "IconTexture"]
  if b.IconBorder then b.IconBorder:Hide() end
  hideChild(b, "JunkIcon")

  if rec.empty then
    if b.SetHasItem then b:SetHasItem(false) end
    SetItemButtonTexture(b, 0)
    SetItemButtonCount(b, 0)
    SetItemButtonDesaturated(b, false)
    b.cbBorder:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 0.55)
    b.cbBg:SetColorTexture(0.085, 0.085, 0.10, 1)          -- an empty slot sits lower than a full one
    b.cbQual:Hide(); b.cbIlvlBg:Hide()
    b.cbIlvl:SetText("")
    b.cbBoe:SetText("")
    b.cbPin:Hide()
    b.cbUp:Hide()
    if b.cbGlowAnim then b.cbGlowAnim:Stop() end
    b.cbGlow:Hide()
    b.cbRed:Hide()
    b.cbNew:Hide()
    b.cbFav:Hide()
    b.cbQ:SetText("")
    local ehl = b:GetHighlightTexture()
    if ehl then ehl:SetVertexColor(1, 1, 1, 0.16) end        -- no leftover quality tint from the item that was here
    if b.UpdateCooldown then b:UpdateCooldown(false) end
    paintCooldown(b, nil)
    return
  end

  b.cbBg:SetColorTexture(UI.tile[1], UI.tile[2], UI.tile[3], 1)
  if b.SetHasItem then b:SetHasItem(rec.icon) end
  SetItemButtonTexture(b, rec.icon)
  if icon then
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetAlpha(1)
    -- junk is dimmed only a little: irregular grey-item art must still read as a full square
    if CB.db.dimJunk and Inv:IsJunk(rec) then icon:SetVertexColor(0.72, 0.72, 0.72)
    else icon:SetVertexColor(1, 1, 1) end
  end
  local shownCount = rec.charges or rec.count
  SetItemButtonCount(b, shownCount)
  if b.cbCountText and shownCount and shownCount > 1 then b.cbCountText:SetText(UI:Count(shownCount)) end
  SetItemButtonDesaturated(b, rec.locked)

  if CB.db.showBorders and rec.quality >= 2 then
    local r, g, bl = qualityColor(rec.quality)
    b.cbBorder:SetBackdropBorderColor(r, g, bl, 0.95)
  elseif rec.isQuest then
    b.cbBorder:SetBackdropBorderColor(1, 0.82, 0.1, 0.95)
  elseif rec.quality == 0 or Inv:IsJunk(rec) then
    b.cbBorder:SetBackdropBorderColor(0.36, 0.36, 0.40, 1)   -- junk keeps a clear square outline
  else
    local e = CB.db.highContrast and UI.border or UI.itemEdge      -- (high contrast already has a bright edge)
    b.cbBorder:SetBackdropBorderColor(e[1], e[2], e[3], 1)
  end

  -- better than what the character wears: a gold edge, a gold wash and a slow shimmer
  local upgrade = CB.db.showUpgrade ~= false and rec.upgrade and true or false
  if upgrade then b.cbBorder:SetBackdropBorderColor(1, 0.84, 0.25, 1) end
  if upgrade then
    b.cbGlow:Show()
    if not b.cbGlowAnim then
      local ag = b.cbGlow:CreateAnimationGroup()
      ag:SetLooping("BOUNCE")
      local a = ag:CreateAnimation("Alpha")
      a:SetFromAlpha(0.03); a:SetToAlpha(0.26); a:SetDuration(1.3)
      b.cbGlowAnim = ag
    end
    if UI:MotionOn() then b.cbGlowAnim:Play() else b.cbGlowAnim:Stop(); b.cbGlow:SetAlpha(0.14) end
  else
    if b.cbGlowAnim then b.cbGlowAnim:Stop() end
    b.cbGlow:SetAlpha(0)
    b.cbGlow:Hide()
  end

  if CB.db.showIlvl and rec.ilvl and rec.ilvl > 1 and rec.quality >= 2 then
    local r, g, bl = qualityColor(rec.quality)
    b.cbIlvl:SetTextColor(r, g, bl)
    b.cbIlvl:SetText(rec.ilvl)
    b.cbIlvlBg:Show()
  else
    b.cbIlvl:SetText("")
    b.cbIlvlBg:Hide()
  end

  -- quality wash along the bottom and a hover tint in the same colour (white for plain items)
  local hl = b:GetHighlightTexture()
  if upgrade then
    UI:VGradient(b.cbQual, { 1, 0.84, 0.25, 0 }, { 1, 0.84, 0.25, 0.5 })
    b.cbQual:Show()
    if hl then hl:SetVertexColor(1, 0.84, 0.25, 0.28) end
  elseif CB.db.showBorders and rec.quality >= 2 then
    local r, g, bl = qualityColor(rec.quality)
    UI:VGradient(b.cbQual, { r, g, bl, 0 }, { r, g, bl, 0.42 })
    b.cbQual:Show()
    if hl then hl:SetVertexColor(r, g, bl, 0.24) end
  else
    b.cbQual:Hide()
    if hl then hl:SetVertexColor(1, 1, 1, 0.16) end
  end

  -- (rare is R, epic E, legendary L, artifact A, heirloom H)
  local qLetter = CB.db.qualityMarks and QUALITY_LETTER[rec.quality]
  if qLetter then
    local qr, qg, qb = qualityColor(rec.quality)
    b.cbQ:SetTextColor(qr, qg, qb)
    b.cbQ:SetText(qLetter)
  else
    b.cbQ:SetText("")
  end

  b.cbBoe:SetText((CB.db.showBoE ~= false and not rec.bound and rec.quality >= 2
    and (rec.bindType == 2 or rec.bindType == 3)) and (rec.bindType == 2 and CB.HEX.info .. "BoE|r" or CB.HEX.info .. "BoU|r") or "")
  if CB.db.pinTop[rec.itemID] then
    local pr, pg, pb = CB:Accent()
    b.cbPin:SetColorTexture(pr, pg, pb, 0.95)
    b.cbPin:Show()
  else
    b.cbPin:Hide()
  end
  b.cbUp:SetShown(CB.db.showUpgrade ~= false and rec.upgrade and true or false)
  b.cbRed:SetShown(CB.db.tintUnusable ~= false and rec.unusable and true or false)
  b.cbFav:ClearAllPoints()
  b.cbFav:SetPoint("TOPRIGHT", (rec.upgrade and CB.db.showUpgrade ~= false) and -14 or -3, -3)

  if CB.db.showNewGlow and rec.isNew then
    local r, g, bl = CB:Accent()
    b.cbNew:SetColorTexture(r, g, bl, 1)
    b.cbNew:Show()
    if not b.cbNewAnim then
      local ag = b.cbNew:CreateAnimationGroup()
      ag:SetLooping("BOUNCE")
      local a = ag:CreateAnimation("Alpha")
      a:SetFromAlpha(1); a:SetToAlpha(0.3); a:SetDuration(0.9)
      b.cbNewAnim = ag
    end
    if UI:MotionOn() then b.cbNewAnim:Play() else b.cbNewAnim:Stop() end
  else
    if b.cbNewAnim then b.cbNewAnim:Stop() end
    b.cbNew:Hide()
  end
  b.cbFav:SetShown(CB.db.favorites[rec.itemID] and true or false)

  if b.Cooldown and b.Cooldown.SetHideCountdownNumbers then pcall(b.Cooldown.SetHideCountdownNumbers, b.Cooldown, false) end
  if b.UpdateCooldown then
    b:UpdateCooldown(rec.icon)
  elseif Container.GetContainerItemCooldown and b.Cooldown and CooldownFrame_Set then
    local start, duration, enable = Container.GetContainerItemCooldown(rec.bag, rec.slot)
    CooldownFrame_Set(b.Cooldown, start or 0, duration or 0, enable and 1 or 0)
  end
  paintCooldown(b, rec)
end

---------------------------------------------------------------------------
-- Section headers and the "free space" pseudo button
---------------------------------------------------------------------------
local function getHeader(W, i)
  local h = W.headers[i]
  if h then return h end
  h = NewFrame("Button", nil, W.frame.content)
  h:SetHeight(HEADER_H)
  h.tick = h:CreateTexture(nil, "ARTWORK")
  UI:Line(h.tick, "w", 2); h.tick:SetHeight(9)
  h.tick:SetPoint("LEFT", 0, 1)
  h.text = h:CreateFontString(nil, "OVERLAY", "BagglerFontHeader")
  h.text:SetPoint("LEFT", 8, 1)
  h.line = h:CreateTexture(nil, "ARTWORK")
  UI:Line(h.line, "h", 1)
  h.line:SetPoint("BOTTOMLEFT", 0, 2)
  h.line:SetPoint("BOTTOMRIGHT", 0, 2)
  h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  h:SetScript("OnClick", function(self, button)
    if not self.secName then return end
    if button == "RightButton" then W:SectionMenu(self, self.secName)
    elseif IsShiftKeyDown and IsShiftKeyDown() then
      -- Shift-click: every section follows this one (all open if it was folded, all folded if it was open)
      W:SetAllFolds(not CB.db.collapsed[W:FoldKey(self.secName)])
    else W:ToggleSection(self.secName) end
  end)
  h:SetScript("OnEnter", function(self) self.text:SetTextColor(unpack(CB.COLOR.white)) end)
  h.text:SetTextColor(unpack(CB.COLOR.soft))
  h:SetScript("OnLeave", function(self) self.text:SetTextColor(unpack(CB.COLOR.soft)) end)
  W.headers[i] = h
  return h
end

-- The tile that summarises the free slots (a count with a short label).
local function getFreeButton(W)
  local b = W.freeBtn
  if b then return b end
  b = NewFrame("Button", nil, W.frame.content, "BackdropTemplate")
  UI:Backdrop(b, UI.tile, UI.border)
  b.text = b:CreateFontString(nil, "OVERLAY", "BagglerFont")
  b.text:SetPoint("CENTER", 0, 3)
  b.sub = b:CreateFontString(nil, "OVERLAY", "BagglerFontMuted")
  b.sub:SetPoint("BOTTOM", 0, 4)
  b.sub:SetText("free")
  b.sub:SetFontObject("BagglerFontTiny")
  b:SetScript("OnClick", function()
    if CursorHasItem() then
      local _, empties = Inv:Scan(W:BagIDs())
      if empties[1] then Container.PickupContainerItem(empties[1].bag, empties[1].slot) end
    end
  end)
  b:SetScript("OnReceiveDrag", b:GetScript("OnClick"))
  b:SetScript("OnEnter", function(self)
    local r, g, bl = CB:Accent()
    self:SetBackdropBorderColor(r, g, bl, 1)
    UI.Tip:SetOwner(self, "ANCHOR_RIGHT")
    UI.Tip:SetText((W.freeCount or 0) .. " free slots", 1, 1, 1)
    UI.Tip:AddLine("Drop an item here to put it in the first free slot.", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3], true)
    UI.Tip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
    UI:HideTip()
  end)
  W.freeBtn = b
  return b
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------
--- Fold state is kept per window: a section folded in the bags stays open in the bank.
function View:FoldKey(name)
  return (self.kind == "bank" and "bank:" or "") .. name
end

function View:ToggleSection(name)
  local W = self
  local key = W:FoldKey(name)
  CB.db.collapsed[key] = (not CB.db.collapsed[key]) or nil
  W:Layout()
  if not CB.db.collapsed[key] then
    for i, sec in ipairs(W.sections) do if sec.name == name then W:Cascade(i) end end
  end
end

--- Folds (fold = true) or unfolds every section of this window in one go.
function View:SetAllFolds(fold)
  local W = self
  local prefix = W:FoldKey("")
  local function mine(key) return (prefix == "" and not key:find(":", 1, true)) or (prefix ~= "" and key:sub(1, #prefix) == prefix) end
  if fold then
    for _, sec in ipairs(W.sections) do if not sec.free then CB.db.collapsed[W:FoldKey(sec.name)] = true end end
  else
    for key in pairs(CB.db.collapsed) do if mine(key) then CB.db.collapsed[key] = nil end end
  end
  W:Layout()
  if not fold then W:Cascade() end
end

-- Places every section and tile for the current size, columns and filter, then sizes the
-- window and its scroll area to fit.
function View:Layout()
  local W = self
  local f = W.frame
  local db = CB.db
  local size, gap = db.iconSize, db.spacing
  local step = size + gap
  local maxCols = W:Columns()
  -- Tile geometry in whole physical pixels: size and offsets are rounded for the content's effective scale, and the
  -- content's own fractional screen origin is folded into each offset, so every tile edge lands on a pixel boundary.
  local ps = UI:PixelScale(f.content)
  local L, T = f.content.GetLeft and f.content:GetLeft(), f.content.GetTop and f.content:GetTop()
  local tileSize = ps and math.max(1, UI:Round(size * ps)) / ps or size
  local function snapX(off)
    if not ps then return off end
    local abs = (L or 0) * ps
    return (UI:Round(abs + off * ps) - abs) / ps
  end
  local function snapY(off)                      -- off is measured downward from the content's top edge
    if not ps then return off end
    local abs = (T or 0) * ps
    return (abs - UI:Round(abs - off * ps)) / ps
  end
  local innerW = maxCols * step - gap
  local ar, ag, ab = CB:Accent()

  -- A dialog the GAME opened for a tile (shift-click split: the tile button itself is the owner) is closed by the item
  -- template's OnHide when that tile is hidden (ContainerFrameItemButtonMixin:OnHide, hasStackSplit == 1), and a relayout
  -- hides every holder. Step that owner's flag aside for the hide pass; settled at the end of Layout. (The dialog our own
  -- menu opens is owned by a plain anchor instead, see View:SplitAnchor.)
  local splitOwner
  local sf0 = rawget(_G, "StackSplitFrame")
  if sf0 and sf0.IsShown and sf0:IsShown() and sf0.owner then
    for _, b in pairs(W.buttons) do
      if b == sf0.owner and b.hasStackSplit == 1 then splitOwner = b; b.hasStackSplit = 0; break end
    end
  end
  for _, b in pairs(W.buttons) do b.cbHolder:Hide(); b.cbEntry = nil end
  for _, h in ipairs(W.headers) do h:Hide() end
  if W.freeBtn then W.freeBtn:Hide() end

  local nav = {}
  local x, y, rowH = 0, 0, 0
  local headerIndex = 0

  for si, sec in ipairs(W.sections) do
    headerIndex = headerIndex + 1
    local h = getHeader(W, headerIndex)
    h.secName = sec.name
    local count = sec.free and (W.freeCount or 0) or #sec.items
    local label = sec.name:upper()
    -- a search or section filter looks inside folded sections too (what you saved as folded is left alone)
    sec.collapsed = CB.db.collapsed[W:FoldKey(sec.name)] and true or false      -- (read fresh: a fold changes without a rebuild)
    local folded = sec.collapsed and not (W.query ~= "" or W.filterCat)
    if db.sectionCounts then label = label .. "   " .. CB.HEX.dim .. count .. "|r" end
    if folded then label = label .. "   |cff" .. accentHex() .. "+ folded|r" end
    h.text:SetText(label)
    h.tick:SetColorTexture(ar, ag, ab, folded and 0.45 or 1)
    UI:Fade(h.line, ar, ag, ab, folded and 0.18 or 0.32, 0)
    local textW = h.text:GetStringWidth() + 14

    local shown = folded and 0 or (sec.free and 1 or #sec.items)
    local cols = math.max(1, math.min(shown, maxCols))
    local blockW = math.min(math.max(cols * step - gap, textW), innerW)
    local rows = math.ceil(shown / cols)
    local blockH = HEADER_H + (rows > 0 and (rows * step - gap + 4) or 0)

    if x > 0 and x + blockW > innerW then
      x = 0; y = y + rowH + SEC_GAP; rowH = 0
    end

    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", f.content, "TOPLEFT", INSET + x, -(INSET + y))
    h:SetWidth(blockW)
    h:Show()

    if folded then
      -- a folded section has no items to land on: its header is the stop, so the controller can open it again
      nav[#nav + 1] = { fold = sec.name, btn = h, key = "fold:" .. sec.name, sec = si,
        cx = INSET + x + blockW / 2, cy = INSET + y + HEADER_H / 2,
        rx = INSET + x - 3, ry = INSET + y - 2, rw = blockW + 6, rh = HEADER_H + 4 }
    end

    if shown > 0 then
      local top = y + HEADER_H + 4
      if sec.free then
        local fb = getFreeButton(W)
        fb:SetSize(tileSize, tileSize)
        fb:ClearAllPoints()
        fb:SetPoint("TOPLEFT", f.content, "TOPLEFT", snapX(INSET + x), -snapY(INSET + top))
        fb.text:SetText(W.freeCount or 0)
        fb:Show()
        nav[#nav + 1] = { free = true, btn = fb, key = "free", sec = si,
          cx = INSET + x + size / 2, cy = INSET + top + size / 2 }
      else
        for i, rec in ipairs(sec.items) do
          local col = (i - 1) % cols
          local row = math.floor((i - 1) / cols)
          local bx = x + col * step
          local by = top + row * step
          local b = W:GetButton(rec.bag, rec.slot)
          if b then
            local holder = b.cbHolder
            holder:ClearAllPoints()
            holder:SetPoint("TOPLEFT", f.content, "TOPLEFT", snapX(INSET + bx), -snapY(INSET + by))
            holder:SetSize(tileSize, tileSize)
            local ok = CB:Safe("paint", paintButton, b, rec)   -- one bad item never blanks the window
            if not ok then CB:Warn("paint", "could not draw " .. tostring(rec.name) .. " (" .. rec.key .. ")") end
            holder:Show()
            local entry = { btn = b, rec = rec, key = rec.key, sec = si,
              cx = INSET + bx + size / 2, cy = INSET + by + size / 2 }
            b.cbEntry = entry
            W:SyncNativeClick(b)          -- the game's own click script unless the item needs our handling
            nav[#nav + 1] = entry
          end
        end
      end
    end

    x = x + blockW + SEC_GAP
    rowH = math.max(rowH, blockH)
  end

  local contentH = y + rowH
  f.empty:SetShown(#W.sections == 0)
  if #W.sections == 0 then contentH = 44 end
  contentH = contentH + INSET * 2
  f.content:SetSize(innerW + INSET * 2, math.max(contentH, 1))
  W.contentH, W.innerW = contentH, innerW
  W.nav, W.navFull = nav, nav

  W:ApplySize()

  local keep
  if W.selKey then
    for _, e in ipairs(nav) do if e.key == W.selKey then keep = e break end end
  end
  W.selEntry = keep or nav[math.min(W.selIndex or 1, #nav)]
  if W.selEntry then W:SelectEntry(W.selEntry, true, true) else f.sel:Hide() end

  W:ApplySearch()

  -- The game's amount dialog is owned by a plain anchor over one tile (View:SplitAnchor), so the relayout above cannot
  -- reach it through the item template's OnHide. If its tile is no longer laid out, the dialog has no item: close it.
  local splitFrame, anchor = rawget(_G, "StackSplitFrame"), W.splitAnchor
  if anchor and splitFrame and splitFrame.IsShown and splitFrame:IsShown() and splitFrame.owner == anchor then
    local tile = anchor.cbButton
    if not (tile and tile:IsVisible() and tile.cbEntry) then splitFrame:Hide() end
  end
  -- a game-opened dialog owned by a tile button: still laid out -> keep it (flag restored), gone -> close it
  if splitOwner and splitFrame and splitFrame:IsShown() and splitFrame.owner == splitOwner then
    if splitOwner:IsVisible() and splitOwner.cbEntry then splitOwner.hasStackSplit = 1 else splitFrame:Hide() end
  end
end

--- Window columns: the user's dragged size wins over the global setting.
function View:Columns()
  local sz = CB.db.sizes and CB.db.sizes[self.opts.sizeKey]
  return (sz and sz.cols) or CB.db.columns
end

--- Equipment is local 32px chrome, independent of item size or saved UI scale.
--- Flow equipment first, then summary and vendor action on distinct rows. This
--- also reserves a vendor row when the informational footer is switched off.
function View:LayoutFooter(width)
  local f = self.frame
  local y, rowH, x = 0, 0, 0
  local visible = CB.db.showFooter
  f.footer:SetShown(visible)
  if visible then
    for _, b in ipairs(self.footerControls or f.bagSlots or {}) do
      if b:IsShown() then
        local bw, bh = b:GetWidth(), b:GetHeight()
        if x > 0 and x + bw > width then y, x, rowH = y + rowH + 6, 0, 0 end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f.footer, "TOPLEFT", x, -y)
        x, rowH = x + bw + 4, math.max(rowH, bh)
      end
    end
    if rowH > 0 then y = y + rowH + 6 end
    local summaryH = math.max(20, math.ceil(f.moneyText:GetStringHeight()), math.ceil(f.slotsText:GetStringHeight()))
    f.slotsText:ClearAllPoints()
    f.slotsText:SetPoint("TOPRIGHT", f.footer, "TOPRIGHT", 0, -y)
    f.moneyText:ClearAllPoints()
    local summaryW = f.slotsText:GetStringWidth() + 8 + 60 + 14 + f.moneyText:GetStringWidth()
    if summaryW > width then
      f.moneyText:SetPoint("TOPLEFT", f.footer, "TOPLEFT", 0, -(y + summaryH + 4))
      y = y + summaryH + 4
    else
      f.moneyText:SetPoint("TOPLEFT", f.footer, "TOPLEFT", 0, -y)
    end
    y = y + summaryH
  end
  local sell = f.sellBtn
  if sell and sell:IsShown() then
    if y > 0 then y = y + 6 end
    sell:ClearAllPoints()
    -- Window parent: remains visible when the informational footer is hidden.
    sell:SetPoint("TOPRIGHT", f.footer, "TOPRIGHT", 0, -y)
    y = y + sell:GetHeight()
  end
  self.footerH = y > 0 and y + 8 or 8
  f.footer:SetHeight(math.max(1, y))
  f.sep:SetShown(visible or (sell and sell:IsShown()))
  return self.footerH
end

--- Sizes the frame and scroll area from the current content (cheap; runs while resizing).
function View:ApplySize()
  local W = self
  local f = W.frame
  local db = CB.db
  local innerW, contentH = W.innerW or 100, W.contentH or 44
  local scale = db.scale
  local maxH = math.floor(UIParent:GetHeight() * 0.72 / scale)
  local sz = db.sizes and db.sizes[W.opts.sizeKey]
  local scrollH
  if sz and sz.h then scrollH = math.max(80, math.min(sz.h, math.floor(UIParent:GetHeight() * 0.9 / scale)))   -- the user's own height (same ceiling as the resize grip)
  else scrollH = math.min(contentH, maxH) end
  local hint = 0
  if W:HintsVisible() then hint = W:SetHintText(innerW) end
  W.hintH, W.scrollH = hint, scrollH
  local frameW = math.max(innerW + PADDING * 2, minWidth(W))
  if not f.cbArriving and f:GetScale() ~= scale then f:SetScale(scale); UI:Resnap(true) end
  -- the character's name sits after the title when there is room for it beside the search box and buttons
  local name = (W.kind == "bags" and frameW >= 560) and (CB.HEX.dim .. "   " .. (UnitName("player") or "") .. "|r") or ""
  f.title:SetText(W.opts.title() .. name)
  if W.kind == "bags" then
    -- Reserve the right-hand controls even at the minimum window width.
    local searchW = math.min(150, math.max(100, frameW - 300))
    f.search:SetWidth(searchW)
    f.title:SetWidth(math.max(70, math.min(name ~= "" and 180 or 90, frameW - searchW - 200)))
    f.title:SetJustifyH("LEFT")
    f.title:SetWordWrap(false)
  elseif W.kind == "bank" then
    -- Same 36px art as the bags; the descriptor needs a wider title, so search yields before it can reach the controls.
    local searchW = math.min(150, math.max(100, frameW - 380))
    f.search:SetWidth(searchW)
    f.title:SetWidth(184)
    f.title:SetJustifyH("LEFT")
    f.title:SetWordWrap(false)
  end
  local footerH = W:LayoutFooter(frameW - PADDING * 2)
  f:SetSize(frameW, TOP_H + 8 + scrollH + footerH + hint + 6)
  f.scroll:ClearAllPoints()
  f.scroll:SetPoint("TOPLEFT", PADDING - INSET, -(TOP_H + 8))
  f.scroll:SetSize(innerW + INSET * 2, scrollH)
  f.hints:SetWidth(frameW - PADDING * 2)
  f.hints:SetShown(hint > 0)
  f.footer:ClearAllPoints()
  f.footer:SetPoint("BOTTOMLEFT", PADDING, 8 + hint)
  f.footer:SetPoint("BOTTOMRIGHT", -PADDING, 8 + hint)
  f.meterFill:SetWidth(math.max(1, (frameW - 2) * (W.meterFrac or 0)))

  local maxScroll = math.max(0, contentH - scrollH)
  if f.scroll:GetVerticalScroll() > maxScroll then f.scroll:SetVerticalScroll(maxScroll) end
  if W.scrollTarget and W.scrollTarget > maxScroll then W.scrollTarget = maxScroll end
end

--- Configuration for the resize grip.
function View:ResizeCfg()
  local W = self
  local key = W.opts.sizeKey
  return {
    stepX = function() return CB.db.iconSize + CB.db.spacing end,
    chromeW = function() return PADDING * 2 - CB.db.spacing end,
    minCols = 6,
    maxCols = 24,
    minH = 80,
    maxH = function() return math.floor(UIParent:GetHeight() * 0.9 / CB.db.scale) end,
    stepY = function() return CB.db.iconSize + CB.db.spacing end,
    getCols = function() return W:Columns() end,
    getScrollH = function() return W.scrollH or 200 end,
    apply = function(cols, h, colsChanged)
      CB.db.sizes[key] = { cols = cols, h = h }
      if colsChanged then W:Layout() else W:ApplySize() end
    end,
    reset = function()
      CB.db.sizes[key] = nil
      W:Layout()
    end,
    savePoint = function()
      local point, rel, relPoint, x, y = W.frame:GetPoint()
      CB.db[W.opts.pointKey] = { point, (rel and rel:GetName()) or "UIParent", relPoint, x, y }
    end,
  }
end

--- Items ripple in (optionally only one section's).
function View:Cascade(onlySec)
  local W = self
  local frames, groups = {}, {}
  for _, e in ipairs(W.nav) do
    if not onlySec or e.sec == onlySec then
      frames[#frames + 1] = e.btn.cbHolder or e.btn
      groups[#groups + 1] = e.sec
    end
  end
  UI:Cascade(W, "cascade" .. tostring(onlySec or "all"), frames, groups)
end

---------------------------------------------------------------------------
-- Refresh = scan + categorise + layout   (protected: a failure shows a notice)
---------------------------------------------------------------------------
function View:RefreshImpl()
  local W = self
  W:Precreate()
  local items, empties, total, free, counts = Inv:Scan(W:BagIDs())
  local specialFree = counts and counts.specialFree or 0
  if W.bagFilter then
    local function keep(list)
      local out = {}
      for _, r in ipairs(list) do if r.bag == W.bagFilter then out[#out + 1] = r end end
      return out
    end
    items, empties = keep(items), keep(empties)
    free, specialFree = 0, 0
    for _, e in ipairs(empties) do
      if e.special then specialFree = specialFree + 1 else free = free + 1 end
    end
    total = #items + #empties
  end
  local sections = Cat:Build(items, W.kind == "bank" and "bank:" or nil)
  -- A folded section must never swallow something you just got: when an item's total goes up (bought, looted,
  -- mailed, crafted) the section it lands in unfolds by itself.
  if CB.db.autoUnfold ~= false and not W.bagFilter then
    local counts = {}
    for _, rec in ipairs(items) do counts[rec.itemID] = (counts[rec.itemID] or 0) + (rec.count or 1) end
    if W.prevCounts then
      for _, sec in ipairs(sections) do
        local key = W:FoldKey(sec.name)
        if CB.db.collapsed[key] then
          for _, rec in ipairs(sec.items) do
            if (counts[rec.itemID] or 0) > (W.prevCounts[rec.itemID] or 0) then
              CB.db.collapsed[key] = nil
              sec.collapsed = false
              break
            end
          end
        end
      end
    end
    W.prevCounts = counts
  end
  local mode = CB.db.emptyMode
  W.freeCount, W.totalSlots = free, total
  W.specialFree = specialFree
  local junkN, junkV = 0, 0
  for _, rec in ipairs(items) do
    if Inv:IsJunk(rec) then
      junkN = junkN + 1
      junkV = junkV + (rec.sellPrice or 0) * rec.count
    end
  end
  W.junkCount, W.junkValue = junkN, junkV
  if mode == "show" and #empties > 0 then
    -- general free space and specialty-bag slots (only their item type fits) are never mixed
    local general, special = {}, {}
    for _, e in ipairs(empties) do
      if e.special then special[#special + 1] = e else general[#general + 1] = e end
    end
    if #general > 0 then
      sections[#sections + 1] = { name = "Free Space", order = 1000, items = general,
        collapsed = CB.db.collapsed[W:FoldKey("Free Space")] and true or false }
    end
    if #special > 0 then
      sections[#sections + 1] = { name = "Specialty Free", order = 1001, items = special,
        collapsed = CB.db.collapsed[W:FoldKey("Specialty Free")] and true or false }
    end
  elseif mode == "collapse" and free > 0 then
    sections[#sections + 1] = { name = "Free Space", order = 1000, free = true, items = {},
      collapsed = CB.db.collapsed[W:FoldKey("Free Space")] and true or false }
  end
  W.sections = sections

  if W.filterCat then
    local present
    for _, s in ipairs(sections) do if s.name == W.filterCat then present = true end end
    if not present then W.filterCat = nil end
  end
  W:UpdateFilterChip()
  W:Layout()
  W:UpdateFooter()
  if W.UpdateExtras then W:UpdateExtras() end
end

function View:Refresh()
  local W = self
  if not W.frame then return end
  local ok = CB:Safe(W.opts.frameName .. ":refresh", W.RefreshImpl, W)
  W.frame.err:SetShown(not ok)
  if not ok then
    W.frame.err:SetText("Something went wrong drawing this window.\nOpen the report, copy it, and send it with what you were doing.")
  end
end

--- Dims what a search or section filter leaves out, and lets the controller move over only what it leaves in
--- (a search is for picking from the result). Without a filter the full list is back.
function View:ApplySearch()
  local W = self
  local q, cat = W.query, W.filterCat
  local filtering = q ~= "" or cat ~= nil
  if filtering ~= W.wasFiltering then
    W.wasFiltering = filtering
    W:RefreshPadHint()                                  -- the hint says "Clear search"
    if next(CB.db.collapsed or {}) then W:Layout(); return end    -- folded sections open for the search (and close after it)
  end
  local full = W.navFull or W.nav
  local shown = {}
  for _, e in ipairs(full) do
    if e.rec and not e.rec.empty then
      local ok = true
      if cat and e.rec.category ~= cat then ok = false end
      if ok and q ~= "" and not Inv:Matches(e.rec, q) then ok = false end
      e.btn:SetAlpha(ok and 1 or 0.2)
      if ok then shown[#shown + 1] = e end
    elseif e.btn and not e.fold then
      e.btn:SetAlpha(filtering and 0.35 or 1)
      if not filtering then shown[#shown + 1] = e end
    elseif e.fold and not filtering then
      shown[#shown + 1] = e
    end
  end
  W.nav = filtering and shown or full
  -- the highlight must be on something that is still listed
  local listed = false
  for _, e in ipairs(W.nav) do if e == W.selEntry then listed = true break end end
  if not listed then
    W.selEntry = W.nav[1]
    if W.selEntry then W:SelectEntry(W.selEntry, true, true) elseif W.frame.sel then W.frame.sel:Hide() end
  end
end

function View:UpdateFilterChip()
  local W = self
  local chip = W.frame.filterChip
  if W.filterCat then
    chip.text:SetText(W.filterCat)
    chip:SetWidth(chip.text:GetStringWidth() + 30)
    if not chip:IsShown() then UI:FadeIn(chip, 0.16) end
  else
    chip:Hide()
  end
end

---------------------------------------------------------------------------
-- Footer: free slot count, gold, fullness meter (+ bag slots on the backpack)
---------------------------------------------------------------------------
function View:UpdateFooter()
  local W = self
  local f = W.frame
  if not f then return end
  local free, total = W.freeCount or 0, W.totalSlots or 0
  local specialFree = W.specialFree or 0
  -- occupied slots: general and specialty empties are both not "used"
  local used = total - free - specialFree
  local frac = total > 0 and used / total or 0
  local r, g, b = CB:Accent()
  if frac >= 0.95 then r, g, b = 1, 0.35, 0.35 elseif frac >= 0.8 then r, g, b = 1, 0.72, 0.25 end
  f.meterFill:SetColorTexture(r, g, b, 0.9)
  local from = W.meterFrac or 0
  UI:Animate(W, "meter", 0.35, function(p)
    local v = from + (frac - from) * p
    W.meterFrac = v
    f.meterFill:SetWidth(math.max(1, (f:GetWidth() - 2) * v))
  end)

  local sell = f.sellBtn
  if sell then
    local vendorHandles = CB.Vendor and CB.Vendor.active
    if W.merchantOpen and not vendorHandles and (W.junkCount or 0) > 0 and not InCombatLockdown() then
      sell.text:SetText("Sell junk  " .. UI:Money(W.junkValue or 0))
      sell:SetWidth(sell.text:GetStringWidth() + 18)
      sell:Show()
    else
      sell:Hide()
    end
  end
  f.footer:SetShown(CB.db.showFooter)
  if not CB.db.showFooter then W:ApplySize(); return end
  local warn = free <= 4 and "ff6a6a" or "c4c4cc"
  f.footMeterFill:SetColorTexture(r, g, b, 0.9)
  f.footMeterFill:SetWidth(math.max(1, 58 * frac))
  f.footMeter:SetShown(total > 0)
  f.slotsText:SetText("|cff" .. warn .. used .. "|r" .. CB.HEX.dim .. " / " .. total .. "|r"
    .. (specialFree > 0 and (CB.HEX.dim .. "  +" .. specialFree .. " special|r") or ""))
  f.moneyText:SetText(UI:Money(GetMoney()))
  W:ApplySize()
end

local function bagInvID(bag)
  return Container.ContainerIDToInventoryID and Container.ContainerIDToInventoryID(bag) or nil
end

--- Equipped-bag slots (backpack only).
function View:UpdateBagSlots()
  local W = self
  local f = W.frame
  f.bagSlots = f.bagSlots or {}
  local n = 0
  if CB.db.showBagSlots then
    for _, bag in ipairs(W:BagIDs()) do
      if bag > 0 then
        n = n + 1
        local b = f.bagSlots[n]
        if not b then
          b = NewFrame("Button", nil, f.footer, "BackdropTemplate")
          b:SetSize(32, 32)
          -- Same outline as the item tiles: a full-size ring texture with the fill and icon one physical pixel
          -- inside it, so no side can round to zero width at fractional footer positions.
          b.cbRing = b:CreateTexture(nil, "BACKGROUND", nil, -8)
          b.cbBg = b:CreateTexture(nil, "BACKGROUND", nil, -6)
          UI:Inset(b.cbBg, b, UI.OUTLINE_PX)
          b.cbBg:SetSnapToPixelGrid(true); b.cbBg:SetTexelSnappingBias(0)
          b.cbBg:SetColorTexture(UI.tile[1], UI.tile[2], UI.tile[3], 1)
          UI:ItemOutline(b, b.cbRing)
          b:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
          b.icon = b:CreateTexture(nil, "ARTWORK")
          UI:Inset(b.icon, b, UI.OUTLINE_PX)
          b.icon:SetSnapToPixelGrid(true); b.icon:SetTexelSnappingBias(0)
          b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
          b.capacity = b:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
          b.capacity:SetFontObject("BagglerFontCount")
          b.capacity:SetPoint("BOTTOMRIGHT", -3, 3)
          b.capacity:SetTextColor(1, 1, 1)
          b.specialty = b:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
          b.specialty:SetFontObject("BagglerFontCount")
          b.specialty:SetPoint("TOPLEFT", 3, -2)
          b.specialty:SetTextColor(0.45, 0.85, 0.75)
          b:RegisterForClicks("LeftButtonUp")
          b:RegisterForDrag("LeftButton")
          local function click(self)
            if not self.invID then return end
            if CursorHasItem() then PutItemInBag(self.invID)
            else
              local pick = Container.PickupBagFromSlot or PickupBagFromSlot
              if pick then pick(self.invID) end
            end
          end
          b.cbClick = click
          b:SetScript("OnClick", click)
          b:SetScript("OnReceiveDrag", click)
          b:SetScript("OnDragStart", click)
          b:SetScript("OnEnter", function(self)
            local r, g, bl = CB:Accent()
            self:SetBackdropBorderColor(r, g, bl, 1)
            UI:HideTip()
            if self.invID and GetInventoryItemTexture("player", self.invID) then
              GameTooltip:SetOwner(self, "ANCHOR_TOP")
              GameTooltip:SetInventoryItem("player", self.invID)
              GameTooltip:AddLine(tostring(self.bagCapacity or "?") .. " slots - " .. (self.bagKind or "Type unknown"),
                CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3], true)
              GameTooltip:Show()
            else
              UI.Tip:SetOwner(self, "ANCHOR_TOP")
              UI.Tip:SetText("Empty bag slot", 1, 1, 1)
              UI.Tip:AddLine("Drag a bag here to equip it.", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3], true)
              UI.Tip:Show()
            end
          end)
          b:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(UI.border[1], UI.border[2], UI.border[3], 1)
            UI:HideTip()
          end)
          f.bagSlots[n] = b
        end
        b.invID = bagInvID(bag)
        local tex = b.invID and GetInventoryItemTexture("player", b.invID)
        b.icon:SetTexture(tex or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
        b.icon:SetDesaturated(not tex)
        b.icon:SetAlpha(tex and 1 or 0.45)
        -- Read-only metadata, matching the equip chooser's capacity/family
        -- policy. Never infer compatibility or replace pickup/drop handlers.
        b.bagCapacity = tex and Container.GetContainerNumSlots(bag) or nil
        local _, family = Container.GetContainerNumFreeSlots(bag)
        local special = tex and type(family) == "number" and family ~= 0
        b.bagKind = family == 0 and "General" or "Type unknown"
        if special then
          b.bagKind = "Specialty (type unknown)"
          local link = b.invID and GetInventoryItemLink("player", b.invID)
          if link and C_Item and C_Item.GetItemInfo then
            local _, _, _, _, _, _, subtype = C_Item.GetItemInfo(link)
            b.bagKind = subtype or b.bagKind
          end
        end
        b.capacity:SetText(tex and tostring(b.bagCapacity or "?") or "")
        b.specialty:SetText(special and "*" or "")
        b:ClearAllPoints()
        -- whole physical pixels: fold the footer's own fractional screen origin into the offset (as View:Layout does
        -- for item tiles), so slot edges land on pixel boundaries
        local x = (n - 1) * 36
        local ps = UI:PixelScale(f.footer)
        local left = f.footer.GetLeft and f.footer:GetLeft()
        if ps and left then
          local abs = left * ps
          x = (UI:Round(abs + x * ps) - abs) / ps
        end
        b:SetPoint("LEFT", f.footer, "LEFT", x, 0)
        b:Show()
      end
    end
  end
  for i = n + 1, #f.bagSlots do f.bagSlots[i]:Hide() end
  W:ApplySize()
end

---------------------------------------------------------------------------
-- Controller hints
---------------------------------------------------------------------------
function View:HintsVisible()
  local W = self
  return CB.db.pad.hints and Pad:Active() and W.frame and W.frame:IsShown()
end

--- Builds the hint text (wrapped to the window width) and returns its height.
function View:SetHintText(innerW)
  local W = self
  local f = W.frame
  local inverse = {}
  for key, action in pairs(CB.db.pad.map) do
    if action then inverse[action] = key end
  end
  local col = "|cff" .. accentHex()
  local parts, groups, group = {}, {}, 1
  local function key(k) return col .. UI:PadLabel(k) .. "|r" end
  local function add(action, label)
    local k = inverse[action]
    if k then parts[#parts + 1] = key(k) .. " " .. label; groups[#parts] = group end
  end
  f.hints:SetWidth(math.max(innerW, minWidth(W) - PADDING * 2))
  if W.sizing then
    f.hints:SetText(UI:SizingHint())
    return math.ceil(f.hints:GetStringHeight()) + 8
  end
  if W.chrome then
    local names = { search = "Search", filter = "Filter", tabs = "Bank tabs", size = "Resize", settings = "Settings", selljunk = "Sell junk", bagslot = "Pick up / equip bag" }
    f.hints:SetText(UI:ChromeHint(names[W:ChromeId()]))
    return math.ceil(f.hints:GetStringHeight()) + 8
  end
  parts[#parts + 1] = col .. "D-pad|r Move"
  groups[#parts], group = 1, 2
  W.hintPickup = W.selEntry and W:PickupLabel(W.selEntry.rec) or "Pick up"        -- ("Sell 1" for a stack at a vendor)
  W.hintInnerW = innerW
  add("use", W.kind == "bank" and "Move item" or "Use"); add("pickup", W.hintPickup); add("menu", "Menu")
  group = 3
  local p, n = inverse.prevSection, inverse.nextSection
  if p and n then parts[#parts + 1] = key(p) .. "/" .. key(n) .. " Section"; groups[#parts] = group end
  local other = (CB.Bank and CB.Bank.active) or (CB.Vendor and CB.Vendor.active) or (CB.GuildBank and CB.GuildBank.active)
    or (CB.Trade and CB.Trade.active) or (CB.Mail and CB.Mail.active) or (Pad:GameWindowList()[1] and true)
  group = 4
  add("collapse", "Fold")
  add("filter", CB.NativeWindows and CB.NativeWindows:Context() == "merchant" and "Sell junk" or "Filter")
  group = 5
  add("favorite", "Favorite"); add("sort", "Sort")
  group = 6
  if other then add("switchWindow", "Other window") end
  add("close", (W.query ~= "" or W.filterCat) and "Clear search" or "Close")
  add("options", "Settings")
  parts[#parts + 1] = col .. "Up|r Search, filter" .. (CB.db.locked and "" or ", size")
  groups[#parts] = 6
  f.hints:SetText(CB.HEX.muted .. table.concat(parts, "   ") .. "|r", groups)
  return math.ceil(f.hints:GetStringHeight()) + 8
end

function View:UpdateHints()
  local W = self
  local f = W.frame
  if not f then return end
  if W:HintsVisible() ~= f.hints:IsShown() and f:IsShown() then W:Layout() end
end

---------------------------------------------------------------------------
-- Selection (shared by mouse hover and controller)
---------------------------------------------------------------------------
--- Eased scrolling: set a target, the frame glides to it.
function View:ScrollTo(v)
  local W = self
  local f = W.frame
  local maxScroll = math.max(0, (W.contentH or 0) - f.scroll:GetHeight())
  W.scrollTarget = math.min(maxScroll, math.max(0, v))
end

function View:EnsureVisible(e)
  local W = self
  local f = W.frame
  local half = CB.db.iconSize / 2 + 6
  local top, bottom = e.cy - half - HEADER_H, e.cy + half + INSET
  local cur = W.scrollTarget or f.scroll:GetVerticalScroll()
  local view = f.scroll:GetHeight()
  if top < cur then W:ScrollTo(top)
  elseif bottom > cur + view then W:ScrollTo(bottom - view) end
end

--- Positions the selection ring over an entry; it glides there instead of jumping.
function View:PlaceSelection(e, snap)
  local W = self
  local f = W.frame
  local size = CB.db.iconSize
  local tx, ty = e.cx - size / 2 - 2, e.cy - size / 2 - 2     -- top-left, content coordinates
  if e.fold then
    f.sel:SetSize(e.rw, e.rh)                                 -- a folded section: the ring goes round its header
    tx, ty = e.rx, e.ry
  else
    f.sel:SetSize(size + 4, size + 4)
  end
  local function place(x, y)
    W.selX, W.selY = x, y
    f.sel:ClearAllPoints()
    f.sel:SetPoint("TOPLEFT", f.content, "TOPLEFT", x, -y)
  end
  if snap or not W.selX or not f.sel:IsShown() then
    UI:Cancel(W, "selglide")
    place(tx, ty)
    return
  end
  local fx, fy = W.selX, W.selY
  UI:Animate(W, "selglide", 0.11, function(p) place(fx + (tx - fx) * p, fy + (ty - fy) * p) end)
end

-- Makes `e` the selection and moves the highlight to it, in the item's quality colour when
-- that setting is on.
--- The line under the card for a mouse: what its clicks do for this item right now.
function View:MouseHint(rec)
  local col = "|cff" .. accentHex()
  local ctx = self:UseContext()
  local parts = {}
  if ctx == "merchant" then
    if self:CanSellOne(rec) then
      parts[#parts + 1] = col .. "Left-click|r Sell 1   " .. col .. "Right-click|r Sell all"
    else
      parts[#parts + 1] = col .. "Right-click|r Sell"
    end
  elseif self:UseLabel(rec) then
    parts[#parts + 1] = col .. "Right-click|r " .. self:UseLabel(rec)
  end
  parts[#parts + 1] = col .. "Alt-click|r Menu"
  return table.concat(parts, "   ")
end

--- The card for the item under the mouse, in place of the game's plain tooltip (the controller gets the same card).
function View:HoverCard(b)
  local e = b and b.cbEntry
  if not (e and e.rec and not e.rec.empty and CB.Card) then return end
  if self.chrome or self.sizing or CursorHasItem() then return end       -- (a held item has its own on-screen life)
  if CB.Card:ShowFor(self, e.rec, true) then self.cardFrom = "mouse"; UI:HideTip() end
end

--- The mouse left an item: its card goes, unless the controller's highlight is what keeps one up.
function View:HoverCardEnd()
  if CB.Card and self.cardFrom == "mouse" then CB.Card:Hide(); self.cardFrom = nil end      -- (the controller's own card stays)
end

function View:SelectEntry(e, fromMouse, snap)
  local W = self
  local f = W.frame
  W.selEntry, W.selKey = e, e.key
  for i, en in ipairs(W.nav) do if en == e then W.selIndex = i break end end
  local r, g, b = CB:Accent()
  if CB.db.qualityFocus and e.rec and not e.rec.empty and (e.rec.quality or 1) >= 2 then
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.rec.quality]
    if c then r, g, b = c.r, c.g, c.b end
  end
  f.sel:SetBackdropBorderColor(r, g, b, 1)
  local active = Pad:Active() and Pad:Top() == W.ctx and not W.chrome and not W.sizing
  W:PlaceSelection(e, snap or not active)
  -- the instruction line names what "pick up" does for THIS item (at a vendor it sells one from a stack)
  if W.merchantOpen and W.hintInnerW and W:HintsVisible() and (W:PickupLabel(e.rec) or "Pick up") ~= W.hintPickup then
    W:SetHintText(W.hintInnerW)
  end
  f.sel:SetShown(active)
  if active and f.selAnim and not f.selAnim:IsPlaying() and UI:MotionOn() then f.selAnim:Play() end
  if not fromMouse then
    W:EnsureVisible(e)
    -- the item card replaces the tooltip while it can: it stays as long as the item is highlighted
    if e.rec and not e.rec.empty and CB.Card and CB.Card:ShowFor(W, e.rec) then
      W.cardFrom = "pad"
      UI:HideTip()
      Pad:SyncDirectUse()
      return
    end
    if CB.Card then CB.Card:Hide() end
    UI:HideTip()
    if e.rec and not e.rec.empty then
      GameTooltip:SetOwner(e.btn, "ANCHOR_RIGHT")
      GameTooltip:SetBagItem(e.rec.bag, e.rec.slot)
      local label = W:UseLabel(e.rec)
      if label and Pad:Active() then
        local k
        for key, action in pairs(CB.db.pad.map) do if action == "use" then k = key end end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff" .. accentHex() .. (k and UI:PadLabel(k) or "A") .. "|r  " .. label, CB.COLOR.soft[1], CB.COLOR.soft[2], CB.COLOR.soft[3])
        if CB.db.tooltipHints ~= false then
          local inv = {}
          for key, action in pairs(CB.db.pad.map) do if action then inv[action] = key end end
          local more = {}
          local function add(action, text) if inv[action] then more[#more + 1] = "|cff" .. accentHex() .. UI:PadLabel(inv[action]) .. "|r " .. text end end
          add("pickup", W:PickupLabel(e.rec)); add("menu", "Menu"); add("favorite", "Favorite")
          if #more > 0 then GameTooltip:AddLine(table.concat(more, "   "), CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3]) end
        end
      end
      GameTooltip:Show()
    elseif e.free then
      UI.Tip:SetOwner(e.btn, "ANCHOR_RIGHT")
      UI.Tip:SetText((W.freeCount or 0) .. " free slots", 1, 1, 1)
      UI.Tip:Show()
    elseif e.fold then
      UI.Tip:SetOwner(e.btn, "ANCHOR_RIGHT")
      UI.Tip:SetText(e.fold .. " is folded", 1, 1, 1)
      local k
      for key, action in pairs(CB.db.pad.map) do if action == "use" then k = key end end
      UI.Tip:AddLine((k and UI:PadLabel(k) or "A") .. " opens it. The menu can open every section at once.", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3], true)
      UI.Tip:Show()
    end
  end
  Pad:SyncDirectUse()
end

---------------------------------------------------------------------------
-- Controller actions inside the window
---------------------------------------------------------------------------
function View:SectionStart(secIndex)
  for _, e in ipairs(self.nav) do if e.sec == secIndex then return e end end
end

function View:JumpSection(delta)
  local W = self
  local n = #W.sections
  if n == 0 then return end
  local cur = W.selEntry and W.selEntry.sec or 1
  for step = 1, n do
    local idx = ((cur - 1 + delta * step) % n) + 1
    local e = W:SectionStart(idx)
    if e then W:SelectEntry(e); return end
  end
end

-- Steps the section filter through the sections and back to "all".
function View:CycleFilter()
  local W = self
  local names = {}
  for _, sec in ipairs(W.sections) do if not sec.free then names[#names + 1] = sec.name end end
  if #names == 0 then return end
  local idx
  for i, n in ipairs(names) do if n == W.filterCat then idx = i end end
  if not idx then W.filterCat = names[1]
  elseif idx >= #names then W.filterCat = nil
  else W.filterCat = names[idx + 1] end
  W:UpdateFilterChip()
  W:ApplySearch()
end

function View:ToggleFavorite(rec)
  if not rec or rec.empty then return end
  local fav = CB.db.favorites
  fav[rec.itemID] = (not fav[rec.itemID]) or nil
  CB:Fire("DIRTY")
end

function View:Pin(rec, category)
  CB.db.pins[rec.itemID] = category
  CB:Fire("DIRTY")
end

--- Picks an item up. `keep` = it should stay on the cursor even if the window closes
--- (the "pick up and close" flow); otherwise closing the window puts it down again.
function View:Pickup(rec, keep)
  self.heldRec = rec
  CB.heldByUs = keep and "keep" or "yes"
  Container.PickupContainerItem(rec.bag, rec.slot)
end

--- Sends the highlighted (or held) item to the open bank, guild bank or trade, in one press.
function View:QuickMove()
  local rec = self.selEntry and self.selEntry.rec
  local held = CursorHasItem and CursorHasItem()
  if held then
    rec = self.heldRec or rec
    ClearCursor()                      -- the held item goes back to its slot first
  end
  if not rec or rec.empty then return end
  if not Pad:QuickMoveOpen() then CB:Print("nothing is open to send it to."); return end
  if held and C_Timer and C_Timer.After then
    C_Timer.After(0.05, function() self:UseItem(rec) end)   -- let the slot unlock
  else
    self:UseItem(rec)
  end
end

---------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------
function View:ApplyPosition()
  local W = self
  local f = W.frame
  if not f then return end
  local p = CB.db[W.opts.pointKey]
  f:ClearAllPoints()
  if p then
    f:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
  elseif W.opts.defaultAnchor then
    W.opts.defaultAnchor(f)
  else
    f:SetPoint("CENTER")
  end
end

function View:ApplyStyle()
  local W = self
  local f = W.frame
  if not f then return end
  UI:Backdrop(f, UI.bg, UI.border, CB.db.bgAlpha, TOP_H)
  local r, g, b = CB:Accent()
  f.title:SetText(W.opts.title())
  f.chipBg:SetColorTexture(r, g, b, 0.16)
  f:SetScale(CB.db.scale)
  UI:Resnap(true)
end

local function glyphClose(btn)
  UI:DrawIcon(btn, { { 11, 1.5, 0, 0, 45 }, { 11, 1.5, 0, 0, -45 } })
end
local function glyphSort(btn)
  UI:DrawIcon(btn, { { 10, 1.5, 0, 4 }, { 7, 1.5, -1.5, 0 }, { 4, 1.5, -3, -4 } })
end
local function glyphSettings(btn)
  UI:DrawIcon(btn, { { 11, 1.5, 0, 3 }, { 11, 1.5, 0, -3 }, { 3, 5, 2, 3 }, { 3, 5, -2, -3 } })
end
View.glyphs = { close = glyphClose, sort = glyphSort, settings = glyphSettings }

-- Builds the bag window once: title bar, search, filter chip, scroll area, footer and hint
-- bar, and connects their scripts.
function View:Create()
  local W = self
  if W.frame then return W.frame end
  UI:MakeFonts()
  local f = NewFrame("Frame", W.opts.frameName, UIParent, "BackdropTemplate")
  W.frame = f
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:Hide()
  UI:Shadow(f)

  -- title bar / drag handle
  local bar = NewFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT", 0, 0); bar:SetPoint("TOPRIGHT", 0, 0); bar:SetHeight(TOP_H)
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() if not CB.db.locked then f:StartMoving() end end)
  bar:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    local point, rel, relPoint, x, y = f:GetPoint()
    CB.db[W.opts.pointKey] = { point, (rel and rel:GetName()) or "UIParent", relPoint, x, y }
  end)

  f.icon = bar:CreateTexture(nil, "ARTWORK")
  local art = (W.kind == "bags" or W.kind == "bank") and 36 or 18   -- Baggler's transparent header art
  f.icon:SetSize(art, art)
  f.icon:SetPoint("LEFT", PADDING, 0)
  f.icon:SetTexture(W.opts.icon or "Interface\\Icons\\INV_Misc_Bag_10_Blue")
  if art == 36 then f.icon:SetTexCoord(0, 1, 0, 1)
  else f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
  f.title = bar:CreateFontString(nil, "OVERLAY", "BagglerFont")
  f.title:SetPoint("LEFT", PADDING + (art == 36 and 44 or 25), 0)
  f.title:SetFontObject("BagglerFontTitle")
  -- a hairline between the title and the search box
  f.titleDivider = bar:CreateTexture(nil, "ARTWORK")
  f.titleDivider:SetColorTexture(UI.border[1], UI.border[2], UI.border[3], 1)
  UI:Line(f.titleDivider, "w", 1)
  f.titleDivider:SetHeight(16)
  f.titleDivider:SetPoint("LEFT", f.title, "RIGHT", 9, 0)

  -- fullness meter (a thin line under the title bar)
  local meterBg = f:CreateTexture(nil, "ARTWORK")
  meterBg:SetPoint("TOPLEFT", 1, -TOP_H); meterBg:SetPoint("TOPRIGHT", -1, -TOP_H); UI:Line(meterBg, "h", 2)
  meterBg:SetColorTexture(UI.border[1], UI.border[2], UI.border[3], 0.7)
  f.meterFill = f:CreateTexture(nil, "OVERLAY")
  f.meterFill:SetPoint("TOPLEFT", 1, -TOP_H); UI:Line(f.meterFill, "h", 2); f.meterFill:SetWidth(1)

  -- search. A child of the title bar, not a sibling of it: the bar is one big mouse-enabled drag handle behind the whole
  -- header, and two siblings of the same frame level leave it to the client which of them hears a click. A child is
  -- always above its parent, so the mouse reaches the box (the controller's SetFocus never hit-tests, which is why only
  -- the mouse could miss it).
  local search = UI:SearchBox(bar, {
    width = W.kind == "bags" and 150 or 170, height = 24, placeholder = "Search items",
    onChange = function(t)
      W.query = t:lower()
      W:ApplySearch()
    end,
    onClear = function() W:ClearSearch() end,
    onEnter = function() if W.chrome and Pad:Active() then W:LeaveChrome() end end,        -- Enter on the keyboard lands on the first match
    onFocus = function(on)
      W.searching = on
    end,
  })
  search:SetPoint("LEFT", f.title, "RIGHT", 19, 0)
  search:SetScript("OnEnter", function(self)
    if self:HasFocus() then return end
    UI.Tip:SetOwner(self, "ANCHOR_BOTTOM")
    UI.Tip:SetText("Search", 1, 1, 1)
    UI.Tip:AddLine("Plain words match name, type and section.", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3], true)
    UI.Tip:AddLine("q:epic   q:3   ilvl>400   ilvl<200", 0.45, 0.78, 1)
    UI.Tip:AddLine("t:armor   c:potions   bound   new   junk   fav", 0.45, 0.78, 1)
    UI.Tip:AddLine("Combine several: epic ilvl>450 t:armor", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3], true)
    UI.Tip:Show()
  end)
  search:SetScript("OnLeave", function() UI:HideTip() end)
  f.search = search

  -- active section filter chip
  local chip = NewFrame("Button", nil, bar)
  chip:SetHeight(20)
  chip:SetPoint("LEFT", search, "RIGHT", 10, 0)
  f.chipBg = chip:CreateTexture(nil, "BACKGROUND")
  f.chipBg:SetAllPoints()
  chip.text = chip:CreateFontString(nil, "OVERLAY", "BagglerFontSmall")
  chip.text:SetPoint("LEFT", 8, 0)
  chip.cross = UI:Icon(chip, "cross", 8)
  chip.cross:SetPoint("RIGHT", -7, 0)
  chip.cross:SetColor(unpack(CB.COLOR.muted))
  chip:SetScript("OnClick", function() W.filterCat = nil; W:UpdateFilterChip(); W:ApplySearch() end)
  chip:Hide()
  f.filterChip = chip

  -- title buttons (right to left): close, settings, sort, then any extras
  local close = UI:GlyphButton(bar, "", "Close", function() W:Close() end)
  close:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
  glyphClose(close)
  -- the bank's X is a secure click on the game's own close button (the bank visit ends when the game closes its frame)
  if W.kind == "bank" then W.secureX = UI:SecureClick(close, "BagglerBankCloseX") end
  local settings = UI:GlyphButton(bar, "", "Settings", function() CB.Options:Toggle() end)
  settings:SetPoint("RIGHT", close, "LEFT", -5, 0)
  glyphSettings(settings)
  f.settingsBtn = settings
  local sort = UI:GlyphButton(bar, "", "Clean up (sort)", function() W:CleanUp() end)
  sort:SetPoint("RIGHT", settings, "LEFT", -5, 0)
  glyphSort(sort)
  local prev = sort
  for _, extra in ipairs(W.opts.extraButtons or {}) do
    local eb = UI:GlyphButton(bar, "", extra.tooltip, function() extra.onClick(W) end)
    eb:SetPoint("RIGHT", prev, "LEFT", -5, 0)
    extra.draw(eb)
    if extra.onDrop then
      eb:SetScript("OnReceiveDrag", function() extra.onDrop(W) end)
    end
    prev = eb
  end

  -- scrolling content (inset so selection rings and borders are never clipped)
  local scroll = NewFrame("ScrollFrame", nil, f)
  f.scroll = scroll
  UI:ScrollBar(scroll, { onChange = function() W.scrollTarget = nil end })
  local content = NewFrame("Frame", nil, scroll)
  content:SetSize(10, 10)
  scroll:SetScrollChild(content)
  f.content = content
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local step = (CB.db.iconSize + CB.db.spacing) * 1.5
    W:ScrollTo((W.scrollTarget or self:GetVerticalScroll()) - delta * step)
  end)

  -- like the base game: an item held on the cursor can be dropped anywhere on the window
  content:EnableMouse(true)
  local function dropAnywhere()
    if not CursorHasItem() then return end
    local _, empties = Inv:Scan(W:BagIDs())
    if empties[1] then Container.PickupContainerItem(empties[1].bag, empties[1].slot) end
  end
  content:SetScript("OnReceiveDrag", dropAnywhere)
  content:SetScript("OnMouseUp", dropAnywhere)

  f.empty = UI:StateNote(content, "empty")
  f.empty:SetPoint("TOP", content, "TOP", 0, -(INSET + 16))
  f.empty:SetText("Nothing here.")
  f.err = UI:StateNote(f, "error")
  f.err:SetPoint("CENTER")

  -- controller selection ring (gently pulses)
  local sel = NewFrame("Frame", nil, content, "BackdropTemplate")
  sel:SetFrameLevel(content:GetFrameLevel() + 40)
  UI:EdgeFile(sel, 2)
  sel:EnableMouse(false)
  sel:Hide()
  f.sel = sel
  local ag = sel:CreateAnimationGroup()
  ag:SetLooping("BOUNCE")
  local pulse = ag:CreateAnimation("Alpha")
  pulse:SetFromAlpha(1); pulse:SetToAlpha(0.55); pulse:SetDuration(0.7)
  f.selAnim = ag

  -- footer
  local sep = f:CreateTexture(nil, "ARTWORK")
  UI:Line(sep, "h", 1)
  sep:SetColorTexture(UI.border[1], UI.border[2], UI.border[3], 0.6)
  f.sep = sep
  local footer = NewFrame("Frame", nil, f)
  footer:SetHeight(FOOT_H - 8)
  f.footer = footer
  f.slotsText = footer:CreateFontString(nil, "OVERLAY", "BagglerFont")
  f.slotsText:SetPoint("RIGHT", footer, "RIGHT", 0, 0)
  -- a small fullness bar beside the slot count (the thin line under the title bar shows the same thing)
  f.footMeter = NewFrame("Frame", nil, footer, "BackdropTemplate")
  f.footMeter:SetSize(60, 8)
  f.footMeter:SetPoint("RIGHT", f.slotsText, "LEFT", -8, 0)
  UI:Backdrop(f.footMeter, UI.panel, UI.border)
  f.footMeterFill = f.footMeter:CreateTexture(nil, "ARTWORK")
  f.footMeterFill:SetPoint("TOPLEFT", 1, -1)
  f.footMeterFill:SetPoint("BOTTOMLEFT", 1, 1)
  f.footMeterFill:SetWidth(1)
  f.moneyText = footer:CreateFontString(nil, "OVERLAY", "BagglerFont")
  f.moneyText:SetPoint("RIGHT", f.footMeter, "LEFT", -14, 0)
  -- hover the gold for your tracked currencies, like the default backpack shows
  local moneyHit = NewFrame("Button", nil, footer)
  moneyHit:SetAllPoints(f.moneyText)
  moneyHit:SetScript("OnEnter", function(self)
    UI.Tip:SetOwner(self, "ANCHOR_TOP")
    UI.Tip:SetText("Currencies", 1, 1, 1)
    local n = 0
    local get = C_CurrencyInfo and C_CurrencyInfo.GetBackpackCurrencyInfo
    if get then
      for i = 1, 8 do
        local ok, info = pcall(get, i)
        if not ok or not info then break end
        local name, qty = info.name, info.quantity
        if name then
          n = n + 1
          local icon = info.iconFileID and ("|T" .. info.iconFileID .. ":14|t ") or ""
          UI.Tip:AddDoubleLine(icon .. name, tostring(qty or 0), 0.85, 0.85, 0.9, 1, 1, 1)
        end
      end
    end
    if n == 0 then UI.Tip:AddLine("None tracked. Tick currencies in the character panel to list them here.", CB.COLOR.muted[1], CB.COLOR.muted[2], CB.COLOR.muted[3], true) end
    UI.Tip:Show()
  end)
  moneyHit:SetScript("OnLeave", function() UI:HideTip() end)
  if W.opts.sellButton then
    -- a child of the window, not of the footer: with "show footer" off the footer is hidden, and this button must
    -- still appear at a vendor
    f.sellBtn = UI:Button(f, "Sell junk", 90, 22, function()
      if CB.Integrations then CB.Integrations:SellJunk(true) end
    end)
    f.sellBtn.text:SetFontObject("BagglerFontSmall")
    f.sellBtn:SetPoint("RIGHT", f.moneyText, "LEFT", -14, 0)
    f.sellBtn:Hide()
  end
  sep:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, 5)
  sep:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 5)

  f.hints = UI:HintBar(f)
  f.hints:SetPoint("BOTTOM", f, "BOTTOM", 0, 8)
  f.hints:Hide()

  -- resize grip (bottom-right corner)
  f.grip = UI:ResizeGrip(f, W:ResizeCfg())
  f.grip:SetShown(not CB.db.locked)

  f:SetScript("OnShow", function()
    Pad:Push(W.ctx)
    UI:Sound("IG_BACKPACK_OPEN", 862)
    if W.opts.onShow then W.opts.onShow(W) end
    W.openedAt = GetTime()
    UI:Arrive(f, CB.db.scale)           -- before Refresh, so layout leaves the scale to the animation
    W:Refresh()
    W:UpdateHints()
    W:Cascade()
    CB:Fire("WINDOW_SHOWN", W)
  end)
  f:SetScript("OnHide", function()
    if W.searching and f.search then f.search:ClearFocus() end
    W.chrome, W.sizing, W.searching = nil, false, false
    if W.ClearChromePaint then W:ClearChromePaint() end
    Pad:Yield(false)
    Pad:Pop(W.ctx)
    CB.Menu:Close()
    UI:HideTip()
    if CB.Card then CB.Card:Hide() end
    if f.selAnim then f.selAnim:Stop() end
    if View.HideMouseUse then View.HideMouseUse() end
    if W.kind == "bags" and C_NewItems and C_NewItems.ClearAll then C_NewItems.ClearAll() end
    -- an item we picked up must not stay on the cursor after the window closes (it would make
    -- action buttons place it instead of casting) - unless that was the point ("pick up and close")
    if CB.heldByUs == "yes" and CursorHasItem() then ClearCursor() end
    if CB.heldByUs == "yes" then CB.heldByUs = nil end
    UI:Sound("IG_BACKPACK_CLOSE", 863)
    if W.opts.onHide then W.opts.onHide(W) end
    W.closedAt = GetTime()
    -- the bags and the vendor go together: closing the bags (X, B, Escape) ends the merchant visit too.
    -- (the vendor's own End() clears atMerchant before it closes the bags, so this cannot loop)
    local v = CB.Vendor
    if W.kind == "bags" and v and v.atMerchant and not v.ending then v:Leave() end
    CB:Fire("WINDOW_HIDDEN", W)
  end)
  f:SetScript("OnUpdate", function(_, dt)
    if W.SyncClickMode then W:SyncClickMode(dt) end
    if W.dirty then
      W.dirty = false
      W:Refresh()
    end
    local target = W.scrollTarget
    if target then
      local cur = f.scroll:GetVerticalScroll()
      local diff = target - cur
      if math.abs(diff) < 0.5 then
        f.scroll:SetVerticalScroll(target)
        W.scrollTarget = nil
      else
        f.scroll:SetVerticalScroll(cur + diff * math.min(1, dt * 16))
      end
    end
  end)

  -- The bank window has no key handler of its own: while it is up the bags window (which opens with it) is the one
  -- listening for Escape, and the game closes the bank. With two of our windows both listening and both passing the key
  -- on, Escape never reached the game (seen with the bank and guild bank; with one it does).
  if W.kind ~= "bank" then
  CB.UI:EscapeClose(_G[W.opts.frameName], function()
    if CB.NativeWindows and CB.NativeWindows:VisitVisible() then return "pass" end
    -- during a mailbox, guild bank or bank visit Escape belongs to the game: it closes the game's frame and with it both windows
    local visits = { { CB.Mail, "MailFrame" }, { CB.GuildBank, "GuildBankFrame" }, { CB.Bank, "BankFrame" }, { CB.Loot, "LootFrame" } }
    for _, v in ipairs(visits) do
      local mod, frame = v[1], rawget(_G, v[2])
      if mod and mod.active and frame and frame:IsShown() then return "pass" end
    end
    if W:ClearSearch() then return end     -- like the controller's B: a standing search or filter goes first, the next Escape closes
    W:Close()
  end)
  end
  -- The bag key (B by default) puts the bags away by itself: while the window is up it is this window that hears
  -- the key, and relying on the game to report "close" back was not dependable. The key is swallowed so the game's
  -- own handling does not open them again.
  if W.kind == "bags" then
    f:HookScript("OnKeyDown", function(self, key)
      if InCombatLockdown() or not self:IsShown() then return end
      local mods = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "") .. (IsShiftKeyDown() and "SHIFT-" or "")
      for _, action in ipairs({ "TOGGLEBACKPACK", "OPENALLBAGS" }) do
        local k1, k2 = GetBindingKey(action)
        if k1 == mods .. key or k2 == mods .. key then
          CB:Journal("bags", "bag key " .. mods .. key .. " pressed with the bags open: closing them")
          pcall(self.SetPropagateKeyboardInput, self, false)
          W:Close()
          C_Timer.After(0, function() pcall(self.SetPropagateKeyboardInput, self, true) end)
          return
        end
      end
    end)
  end
  W:ApplyPosition()
  W:ApplyStyle()
  return f
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function View:IsOpen() return self.frame and self.frame:IsShown() end
function View:Open() self:Create(); if not self.frame:IsShown() then self.frame:Show() end end
function View:Close() if self.frame and self.frame:IsShown() then self.frame:Hide() end end
function View:Toggle() if self:IsOpen() then self:Close() else self:Open() end end

function View:DebugDump()
  local W = self
  local made = 0
  for _ in pairs(W.buttons) do made = made + 1 end
  CB:Print(W.opts.frameName, "| version", CB.version, "| forever:", tostring(CB.isForever), "| open:", tostring(W:IsOpen()))
  CB:Print("sections:", #W.sections, "| nav:", #W.nav, "| buttons made:", made, "| errors:", CB.errorCount)
  CB:Print("pad enabled:", tostring(Pad:Enabled()), "| pad active:", tostring(Pad:Active()),
    "| gamepad api:", tostring(C_GamePad and C_GamePad.IsEnabled and C_GamePad.IsEnabled()))
  CB:Print("containers:", table.concat(W:BagIDs(), ","), "| free:", tostring(W.freeCount), "/", tostring(W.totalSlots))
end

---------------------------------------------------------------------------
-- Event wiring for one view
---------------------------------------------------------------------------
function View:Wire()
  local W = self
  CB:On("DIRTY", function() W.dirty = true end)
  CB:On("LOCKS", function()
    if not W:IsOpen() then return end
    for _, e in ipairs(W.navFull or W.nav) do
      if e.rec and not e.rec.empty then
        local info = Container.GetContainerItemInfo(e.rec.bag, e.rec.slot)
        SetItemButtonDesaturated(e.btn, info and info.isLocked)
      end
    end
  end)
  CB:On("COOLDOWNS", function()
    if not W:IsOpen() then return end
    for _, e in ipairs(W.navFull or W.nav) do
      if e.rec and not e.rec.empty and e.btn.UpdateCooldown then e.btn:UpdateCooldown(e.rec.icon) end
      if e.btn and e.btn.cbCD then paintCooldown(e.btn, e.rec) end
    end
  end)
  -- a light check while the window is open: the cooldown display does not depend on the game's event arriving
  if W.kind == "bags" and C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(0.5, function()
      if not W:IsOpen() then return end
      for _, e in ipairs(W.navFull or W.nav) do
        if e.rec and not e.rec.empty and e.btn and e.btn.cbCD and e.btn:IsVisible() then paintCooldown(e.btn, e.rec) end
      end
    end)
  end
  CB:On("FOOTER", function() if W:IsOpen() then W:UpdateFooter() end end)
  CB:On("PAD_STATE", function()
    if W.frame then
      if not Pad:Active() and (W.chrome or W.sizing) then W:LeaveChrome() end
      W:UpdateHints()
      if W.chrome or W.sizing then W:RefreshPadHint() end
      if W.frame.sel then
        W.frame.sel:SetShown(Pad:Active() and Pad:Top() == W.ctx and not W.chrome and not W.sizing and W.selEntry ~= nil)
      end
    end
  end)
  CB:On("SETTING", function(key)
    -- changing the global column count hands the choice back to it
    if key == "columns" and CB.db.sizes[W.opts.sizeKey] then CB.db.sizes[W.opts.sizeKey].cols = nil end
    if not W.frame then return end
    if key == "scale" or key == "bgAlpha" or key == "accent" then W:ApplyStyle() end
    if key == "locked" and W.frame.grip then W.frame.grip:SetShown(not CB.db.locked) end
    W.dirty = true
  end)
  -- while an item is held on the cursor the window's edge takes the accent colour: it is a place the item can go
  CB:RegisterEvent("CURSOR_CHANGED", function()
    local f = W.frame
    if not f or not f:IsShown() then return end
    if CursorHasItem and CursorHasItem() then
      local r, g, b = CB:Accent()
      UI:TweenBorder(f, r, g, b, 0.12)
    else
      UI:TweenBorder(f, UI.border[1], UI.border[2], UI.border[3], 0.18)
    end
  end)
  CB:RegisterEvent("PLAYER_REGEN_DISABLED", function()
    if CB.db.closeOnCombat and W.kind == "bags" then W:Close() end
    if CB.heldByUs and CursorHasItem() then ClearCursor(); CB.heldByUs = nil end   -- never carry a held item into combat
    if W.frame then W:UpdateFooter() end
  end)
  CB:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if W.needsCombatRefresh then W.needsCombatRefresh = false; W.dirty = true end
  end)
  if W.kind == "bags" then
    CB:On("READY", function()
      -- build every button out of combat, once the UI has settled
      C_Timer.After(2, function() CB:Safe("precreate", W.Precreate, W) end)
    end)
    -- While shopping, record which frame actually receives each mouse press. If a click on a bag
    -- item "does nothing", this says whether it reached the item or something sat on top of it.
    CB:RegisterEvent("GLOBAL_MOUSE_DOWN", function(_, button)
      if not W.merchantOpen or not CB.debugMode then return end
      local f
      if GetMouseFoci then local t = GetMouseFoci(); f = t and t[1] elseif GetMouseFocus then f = GetMouseFocus() end
      local chain, n = {}, f
      for _ = 1, 4 do
        if not n then break end
        chain[#chain + 1] = (n.GetName and n:GetName()) or (n.GetObjectType and n:GetObjectType()) or "?"
        n = n.GetParent and n:GetParent() or nil
      end
      CB:Info("mouse", ("%s on %s | enabled=%s strata=%s level=%s alpha=%s"):format(tostring(button), table.concat(chain, " < "),
        tostring(f and f.IsMouseEnabled and f:IsMouseEnabled()), tostring(f and f.GetFrameStrata and f:GetFrameStrata()),
        tostring(f and f.GetFrameLevel and f:GetFrameLevel()), tostring(f and f.GetAlpha and f:GetAlpha())))
    end)
    CB:RegisterEvent("MERCHANT_SHOW", function() W.merchantOpen = true; if W.frame then W:UpdateFooter() end end)
    CB:RegisterEvent("MERCHANT_CLOSED", function() W.merchantOpen = false; if W.frame then W:UpdateFooter() end end)
  end
end

---------------------------------------------------------------------------
-- The backpack view
---------------------------------------------------------------------------
local W = View.New({
  kind = "bags",
  frameName = "BagglerFrame",
  sizeKey = "bags",
  pointKey = "point",
  sellButton = true,
  extraButtons = { { tooltip = "Destroy: drop an item here", draw = function(btn)
      UI:DrawIcon(btn, { { 9, 1.5, 0, 3 }, { 7, 1.5, -3.5, -1, 90 }, { 7, 1.5, 3.5, -1, 90 }, { 8, 1.5, 0, -4 } })
    end,
    onClick = function(W)
      if CursorHasItem and CursorHasItem() then
        if W.heldRec then W:Destroy(W.heldRec) end
      else
        CB:Print("pick an item up (X) or drag it, then use this to destroy it.")
      end
    end,
    onDrop = function(W) if W.heldRec then W:Destroy(W.heldRec) end end } },
  getBagIDs = function() return Inv:BagIDs() end,
  icon = "Interface\\AddOns\\Baggler\\Assets\\baggler-header.tga",
  title = function() return "|cff" .. accentHex() .. "B|r" .. CB.HEX.text .. "aggler|r" end,
  edge = function(action)
    if action ~= "left" or not Pad:CanEdgeWalk() then return false end
    if CB.Vendor and CB.Vendor.active and CB.Vendor.frame:IsShown() then CB.Vendor:Focus(); return true end
    if CB.Bank and CB.Bank.window and CB.Bank.window:IsOpen() then CB.Pad:Push(CB.Bank.window.ctx); CB.Bank.window:SelectFirstIfNone(); return true end
    if CB.GuildBank and CB.GuildBank.active and CB.GuildBank.frame:IsShown() then CB.Pad:Push(CB.GuildBank.ctx); CB.GuildBank:SelectFirstIfNone(); return true end
    return false
  end,
})
W.UpdateExtras = View.UpdateBagSlots
CB.Window = W
W:Wire()
