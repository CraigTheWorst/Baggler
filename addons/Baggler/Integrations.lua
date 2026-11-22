-- Baggler integrations: take over Blizzard's bags, open at vendors etc., auto-sell junk, and warn about other bag add-ons.
--
-- How the bag key reaches Baggler
--   The game's bags stay alive but hidden. When the player presses the bag key, or picks the bag on the controller's
--   radial wheel, the game calls one of its bag functions. Baggler watches those calls with hooksecurefunc and opens
--   or closes its own window in response:
--     * the keyboard key        -> ToggleAllBags / ToggleBackpack ... (a "toggle")
--     * the radial wheel        -> ToggleBackpack_Combined, which only hides or shows the game's own frame when
--                                  that frame is still counted as shown, so it must be hooked itself
--     * a vendor, mail, trade   -> OpenAllBags(frame) ... and CloseAllBags(frame) when the visit ends
--   Nested calls (ToggleAllBags -> ToggleBackpack -> ...) arrive in the same frame and are settled as one decision.
--
-- IMPORTANT (taint): Baggler never calls Blizzard's bag functions (OpenAllBags, CloseAllBags, ToggleBag ...).
-- Calling secure code from an add-on taints it, which later makes spells and actions "blocked" (the Escape menu, the
-- map and the controller itself died that way). Hooks only observe; Baggler keeps its own open/closed state, and a
-- static test fails if any file calls one of those functions.
local ADDON, CB = ...
local I = {}
CB.Integrations = I

-- What the game believes about its own hidden bags, kept by watching what it asks for. After a reload it believes
-- them open (the journal showed the first bag key press of a session arriving as "close"), so tracking starts there.
I.gameOpen = true
I.startedAt = GetTime()

-- A loading screen (a portal, fast travel, a dungeon door) makes the game tidy up by itself: it closes its windows and
-- its bags. Those calls look just like the bag key arriving as "close", which opens Baggler' bags when the game believed
-- its own open (so a keypress works on the first try) and so the bags came up after every teleport. While a loading
-- screen is up, and for a few seconds after it, bag calls that did not come with the bag key are the game, not the player.
local ZONING_GRACE = 5
I.loading = false
I.worldAt = -100
-- Dying does the same: the game closes its windows and bags when the player dies, releases and resurrects, and
-- that arrives as a bag close just like the bag key, which opened Baggler' bags on every death. So the same rule
-- covers the moments around death, and the whole time the player is a corpse or a ghost (the bag key itself is a
-- toggle and still works: only the game's own open/close calls are ignored).
local function zoning()
  if I.loading or (GetTime() - I.worldAt) < ZONING_GRACE then return true end
  return UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") and true or false
end
for _, ev in ipairs({ "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_SKINNED", "RESURRECT_REQUEST", "CONFIRM_XP_LOSS" }) do
  CB:RegisterEvent(ev, function() I.worldAt = GetTime() end)
end
CB:RegisterEvent("LOADING_SCREEN_ENABLED", function() I.loading = true; I.worldAt = GetTime() end)
CB:RegisterEvent("LOADING_SCREEN_DISABLED", function() I.loading = false; I.worldAt = GetTime() end)
CB:RegisterEvent("PLAYER_ENTERING_WORLD", function() I.worldAt = GetTime() end)
CB:RegisterEvent("PLAYER_LEAVING_WORLD", function() I.worldAt = GetTime() end)
local W = CB.Window
local Inv = CB.Inventory

local pending, sawToggle, sawOpen, sawClose, sawInteract = false, false, false, false, nil
local hiddenParent
I.NO_BAGS = { ClassTrainerFrame = true, TaxiFrame = true, BarberShopFrame = true, TabardFrame = true, GuildRegistrarFrame = true,
  PetitionFrame = true, PlayerChoiceFrame = true, PVPQueueFrame = true, StableFrame = true, PetStableFrame = true,
  ItemUpgradeFrame = true, ReforgingFrame = true, AzeriteRespecFrame = true, PlayerTalentFrame = true,
  ProfessionsCustomerOrdersFrame = true }   -- (the auction house is not listed: the bags open beside it, there is where items are sold from)
I.openedFor = nil      -- the interacting frame (mail, trade ...) we opened the bags for

-- Taxi cleanup calls CloseAllBags without an interacting frame. It is not a
-- bag key, even after TaxiFrame has hidden. Observe the visit, never snapshot
-- or restore bags: the player's latest choice must survive departure.
local taxiActive, taxiEndedAt, sawTaxi = false, nil, false
CB:RegisterEvent("TAXIMAP_OPENED", function() taxiActive = true end)
CB:RegisterEvent("TAXIMAP_CLOSED", function() taxiActive = false; taxiEndedAt = GetTime() end)
local function taxiInteraction()
  if taxiActive or (taxiEndedAt and GetTime() - taxiEndedAt < 1.5) then return true end
  if UnitOnTaxi and UnitOnTaxi("player") then return true end
  for _, name in ipairs({ "TaxiFrame", "FlightMapFrame" }) do
    local frame = rawget(_G, name)
    if frame and frame.IsVisible and frame:IsVisible() then return true end
  end
  return false
end

--- Runs one frame after Blizzard's bag functions, so nested calls
--- (ToggleAllBags -> ToggleBackpack -> ...) collapse into ONE decision.
local function settle()
  pending = false
  local toggled, opened, closed, interacting, taxiCall = sawToggle, sawOpen, sawClose, sawInteract, sawTaxi
  sawToggle, sawOpen, sawClose, sawInteract, sawTaxi = false, false, false, nil, false
  -- The game also opens and closes its own bag frames by itself, often several times a second and in combat,
  -- handing its own frame to the call (the journal showed dozens). That is not the player, and it does not change
  -- what the bag key believes: ignored altogether.
  if type(interacting) == "table" and interacting.GetName then
    local okName, name = pcall(interacting.GetName, interacting)
    if okName and type(name) == "string" and name:find("^ContainerFrame") then
      -- the game's own tidying hands its bag frame over, and that is not the player; but the bag KEY does too once the
      -- game believes its bags are open (it closes its own frame), and that press must still toggle ours
      if not toggled then return end
      interacting = nil
    end
  end
  local gameWasOpen = I.gameOpen
  if opened then I.gameOpen = true elseif closed then I.gameOpen = false end
  if not CB.db or not CB.db.replaceDefault then return end
  if not toggled and not interacting and (taxiCall or taxiInteraction()) then return end

  -- windows that have nothing to do with bags (trainer, flight map, barber ...) never get the bags opened for them
  if interacting and type(interacting) == "table" and interacting.GetName then
    local ok, nm = pcall(interacting.GetName, interacting)
    if ok and nm and I.NO_BAGS[nm] then
      if toggled and nm == "TaxiFrame" then interacting = nil else return end
    end
  end
  CB:Journal("bags", ("game asked: toggle=%s open=%s close=%s for=%s | ours shown=%s visible=%s alpha=%s"):format(tostring(toggled),
    tostring(opened), tostring(closed), tostring(interacting and interacting.GetName and interacting:GetName() or interacting),
    tostring(W.frame and W.frame:IsShown()), tostring(W.frame and W.frame:IsVisible()), tostring(W.frame and W.frame:GetAlpha())))
  if toggled and not interacting then
    -- a window that is "shown" but cannot be seen counts as closed: close it properly, then open it again
    if W.frame and W.frame:IsShown() and (not W.frame:IsVisible() or (W.frame:GetAlpha() or 1) < 0.05) then
      CB:Journal("bags", "our window was shown but invisible - reopening")
      W:Close()
      W:Open()
    else
      W:Toggle()
    end
    CB:Journal("bags", "after toggle: shown=" .. tostring(W.frame and W.frame:IsShown()))
  elseif opened and not interacting and zoning() then
    -- the game opening its bags while it changes zones: not the player (what it believes is still recorded above)
    CB:Journal("bags", "open asked while changing zones: ignored")
  elseif opened then
    if interacting and not CB.db.autoOpen then return end
    -- Standard item visits own the bag lifetime even when bags were already up.
    -- Taxi and the other NO_BAGS windows returned above and never claim it.
    if interacting then I.openedFor = interacting end
    local wasOpen = W:IsOpen()
    if not wasOpen then W:Open() end
    -- the bags opened beside a vendor (also the demon trainer), mailbox, trade, auction house or guild bank: the player
    -- came for that window, so it gets the controller first (Start hops to the bags). See NativeWindows.PAIRED.
    if interacting and CB.NativeWindows then CB.NativeWindows:FocusNativeFirst(interacting) end
    if wasOpen and not interacting and not gameWasOpen and W.openedAt and GetTime() - W.openedAt > 0.5 and not InCombatLockdown() then
      -- the game thought its bags were closed (so the bag key asked to open them) while ours were up: the player
      -- pressed the key to put them away
      CB:Journal("bags", "bag key with ours open and the game's bags closed: closing ours")
      W:Close()
    end
  elseif closed and not interacting and zoning() then
    -- the game closing its windows and bags when a loading screen ends: not the player either
    CB:Journal("bags", "close asked while changing zones: ignored")
  elseif closed and not interacting and not W:IsOpen() then
    -- A close with no frame and no toggle is never the bag key: every bag request in the pinned Forever source reaches
    -- a Toggle* function (TOGGLEBACKPACK/TOGGLEBAGn/OPENALLBAGS bindings, the bag bar, the radial's ToggleBackpack_Combined),
    -- and that hook marks it as a toggle even when the game's own frame only hides. The frameless CloseAllBags() is the
    -- game tidying: Escape's CloseAllWindows (closing talents, spellbook, character, map ...), a center panel opening,
    -- the game menu, loading screens, death, taxi. Ours are closed already: nothing to do, and never open them.
    CB:Journal("bags", ("close asked with ours closed (the game tidying, believed open=%s): ignored"):format(tostring(gameWasOpen)))
  elseif closed then
    -- an interaction (mail, trade ...) ending closes only the bags it opened
    if interacting and I.openedFor ~= interacting then return end
    I.openedFor = nil
    W:Close()
  end
end

local function onBagFunction(name, arg)
  if not CB.db or not CB.db.replaceDefault then return end
  CB:SlotProbe("after game " .. name .. "()")   -- (read-only: names the call after which a game slot first shows as not secure)
  if name:sub(1, 6) == "Toggle" then sawToggle = true
  elseif name:sub(1, 4) == "Open" then sawOpen = true
  elseif name:sub(1, 5) == "Close" then sawClose = true end
  if type(arg) == "table" then sawInteract = arg end
  -- Remember origin at hook time too: the map can disappear before settle.
  if taxiInteraction() then sawTaxi = true end
  if not pending then
    pending = true
    C_Timer.After(0, function() CB:Safe("bags:settle", settle) end)
  end
end

-- loaded in combat, the game's bags could not be hidden yet: do it as soon as combat ends
CB:RegisterEvent("PLAYER_REGEN_ENABLED", function()
  if CB.db and CB.db.replaceDefault and not I.hidden and I.HideBlizzardBags then I:HideBlizzardBags() end
end)

function I:HideBlizzardBags()
  if I.hidden or InCombatLockdown() then return end
  I.hidden = true
  CB:SlotProbe("before HideBlizzardBags")
  hiddenParent = CreateFrame("Frame", "BagglerHiddenBlizzard")
  hiddenParent:Hide()
  if ContainerFrameCombinedBags then ContainerFrameCombinedBags:SetParent(hiddenParent) end
  for i = 1, 13 do
    local fr = _G["ContainerFrame" .. i]
    if fr then fr:SetParent(hiddenParent) end
  end
  CB:SlotProbe("after HideBlizzardBags")
end

local function hook(name)
  if _G[name] then
    hooksecurefunc(name, function(arg) onBagFunction(name, arg) end)
  end
end

---------------------------------------------------------------------------
-- Auto-sell junk
---------------------------------------------------------------------------
local sellTicker

-- UseContainerItem falls back to using/equipping away from a merchant. Check
-- the native window, not our remembered visit state, before *every* request.
local function canSellNow()
  return not InCombatLockdown() and not (CursorHasItem and CursorHasItem())
    and MerchantFrame and MerchantFrame.IsVisible
    and MerchantFrame:IsVisible()
end
local function boundedCount(n)
  return type(n) == "number" and n >= 1 and n <= 2147483647 and n % 1 == 0
end

--- Grey items and deliberately marked junk retain the existing IsJunk policy:
--- explicit marking overrides quality/set protection, but never favorites or
--- no-value protection. No claimed sale totals: a use request is not confirmation.
function I:SellJunk(manual)
  if not manual and not CB.db.autoSellJunk then return end
  if sellTicker then sellTicker:Cancel(); sellTicker = nil end
  if not canSellNow() then return end
  local queue = {}
  for _, rec in ipairs(Inv:Scan()) do
    if Inv:IsJunk(rec) and not rec.locked and boundedCount(rec.count) then
      -- Copy identity/quantity: scan records may be refreshed before the timer.
      queue[#queue + 1] = { bag = rec.bag, slot = rec.slot, itemID = rec.itemID,
        link = rec.link, count = rec.count }
    end
  end
  if #queue == 0 then
    if manual then CB:Print("no junk to sell.") end
    return
  end
  local i = 0
  sellTicker = C_Timer.NewTicker(0.1, function(t)
    if not canSellNow() then t:Cancel(); sellTicker = nil; return end
    i = i + 1
    local rec = queue[i]
    if not rec then t:Cancel(); sellTicker = nil; return end
    local ok, info = pcall(C_Container.GetContainerItemInfo, rec.bag, rec.slot)
    -- A moved/replaced/locked/expanded stack is skipped, never chased to another
    -- slot. Same-ID variants must match the original hyperlink when available.
    if not ok or not info or info.itemID ~= rec.itemID or info.isLocked
      or (rec.link and info.hyperlink ~= rec.link)
      or not boundedCount(info.stackCount) or info.stackCount > rec.count then return end
    local current = { itemID = info.itemID, quality = info.quality, hasNoValue = info.hasNoValue }
    if not Inv:IsJunk(current) then return end
    -- Re-read eligibility from current data/preferences immediately before use.
    -- Client/server acceptance remains asynchronous and is not reported as sold.
    C_Container.UseContainerItem(rec.bag, rec.slot)
  end, #queue + 1)
  CB:Print(("queued %d junk stack(s) for sale; changed or protected slots will be skipped."):format(#queue))
end

local function autoSell() I:SellJunk(false) end

CB:RegisterEvent("MERCHANT_SHOW", autoSell)
CB:RegisterEvent("MERCHANT_CLOSED", function()
  if sellTicker then sellTicker:Cancel(); sellTicker = nil end
end)

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
CB:On("READY", function()
  W:Create()

  local clash = CB:Conflicts()
  if #clash > 0 then
    if CB:StandDown() then
      CB:Print(CB.HEX.gold .. "another bag add-on is loaded (" .. table.concat(clash, ", ")
        .. "), so Baggler is standing down and leaves your bags and the game's windows alone. Disable the other one to use Baggler, or type /baggler force to run both anyway.|r")
      return
    end
    CB:Print(CB.HEX.danger .. "running next to " .. table.concat(clash, ", ") .. " (forced) - expect the two to fight.|r")
  end

  if CB.db.replaceDefault then
    I:HideBlizzardBags()
    -- ToggleBackpack_Combined is what the controller's radial wheel calls for its bag entry (the journal showed it
    -- from GamepadRadial.lua). When the game's hidden bag frame is still "shown" it only hides that frame and calls
    -- none of the others, so without this hook that press never reached us.
    for _, fn in ipairs({ "ToggleAllBags", "OpenAllBags", "CloseAllBags", "ToggleBackpack", "ToggleBackpack_Combined",
                          "OpenBackpack", "CloseBackpack", "ToggleBag", "OpenBag", "CloseBag" }) do
      hook(fn)
    end
    -- Observe-only post-hook: the game writes MerchantFrame / AuctionHouseFrame.selectedTab here (MerchantFrame_OnShow, right
    -- after OpenAllBags). Probing after it tells whether the visit's OnShow was already tainted when it got that far.
    pcall(hooksecurefunc, "PanelTemplates_SetTab", function(frame)
      if frame ~= nil and (frame == rawget(_G, "MerchantFrame") or frame == rawget(_G, "AuctionHouseFrame")) then
        CB:SlotProbe("after game PanelTemplates_SetTab(" .. (frame == rawget(_G, "MerchantFrame") and "MerchantFrame" or "AuctionHouseFrame") .. ")")
      end
    end)
  end
end)

CB:On("SETTING", function(key)
  if key == "replaceDefault" and CB.db.replaceDefault ~= I.hidden then
    CB:Print("Replacing/restoring the default bags takes effect after /reload.")
  end
end)

---------------------------------------------------------------------------
-- Gear comparison: the game's own tooltip setting, so it also works from a controller
---------------------------------------------------------------------------
local function applyCompare()
  if not CB.db or not SetCVar then return end
  if CB.db.alwaysCompare then
    I.compareWasSet = true
    pcall(SetCVar, "alwaysCompareItems", 1)
  elseif I.compareWasSet then
    I.compareWasSet = false
    pcall(SetCVar, "alwaysCompareItems", 0)
  end
end
CB:On("READY", applyCompare)
CB:On("SETTING", function(key) if key == "alwaysCompare" then applyCompare() end end)
