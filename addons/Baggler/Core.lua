-- Baggler core: namespace, saved settings, tiny event bus, slash commands.
local ADDON, CB = ...
_G.Baggler = CB

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
CB.version = (GetMeta and GetMeta(ADDON, "Version")) or "dev"

---------------------------------------------------------------------------
-- Client flavour. WoW: Forever ("Camelot") is a retail fork whose item buttons
-- are initialised as Initialize(holder, bag, slot) instead of (bag, slot).
---------------------------------------------------------------------------
do
  local _, _, _, toc = GetBuildInfo()
  CB.isForever = (WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT) or toc == 16001
end

---------------------------------------------------------------------------
-- Defaults. Anything the user can change lives here. `false` means "off /
-- unbound"; never use nil for a deliberate user choice (defaults re-fill nil).
---------------------------------------------------------------------------
CB.defaults = {
  -- look & feel
  scale = 1.0,
  iconSize = 38,
  spacing = 4,
  columns = 12,
  bgAlpha = 0.94,
  accent = "class",         -- My class (dynamic); fixed symbolic presets below
  showBorders = true,       -- quality-coloured 1px item borders
  showIlvl = true,          -- item level on gear
  alwaysCompare = false,    -- hovering gear always shows what you wear (the game's alwaysCompareItems)
  sellProtect = true,       -- favorites / set items never sell; epics need a second press
  askEquipSlot = true,      -- rings / trinkets with both slots full ask which to replace
  itemCard = true,          -- a panel beside the window that stays while an item is highlighted
  cardCompare = true,       -- ... and compares gear with what you wear
  cardSide = "auto",         -- auto | left | right
  autoUnfold = true,        -- a folded section unfolds when something new lands in it
  rowWrap = true,           -- left / right continues onto the next row (off = movement stops at the row edge)
  tooltipHints = true,      -- what each button does, in the item tooltip
  qualityFocus = false,     -- the selection ring takes the item's quality colour
  showBoE = true,           -- BoE / BoU text on unbound gear
  showUpgrade = true,       -- gold shine on gear better than what you wear
  tintUnusable = true,      -- red tint on gear you cannot use
  showNewGlow = true,
  dimJunk = true,
  showFooter = true,
  showBagSlots = true,
  locked = false,
  point = { "BOTTOMRIGHT", "UIParent", "BOTTOMRIGHT", -40, 120 },

  -- organisation
  group = "category",       -- category | type | expansion | none
  showSubtype = false,      -- "type" mode: append the subtype
  sort = "quality",         -- quality | name | ilvl | recent | type
  sectionCounts = true,
  emptyMode = "collapse",   -- collapse | show | hide
  newSection = false,       -- fresh items go to their own sections; a gold shine marks gear that beats what you wear
  favSection = true,
  separateJunk = true,
  junkAll = true,            -- every grey item goes in Junk, even grey weapons and armor (false: typed ones keep their section)
  showSets = true,          -- gear in an equipment set gets its own section
  splitTradeGoods = true,
  collapsed = {},           -- [sectionName] = true
  pins = {},                -- [itemID] = category name
  favorites = {},           -- [itemID] = true
  -- Legacy replacement keys remain for profile compatibility. NativeWindows.lua
  -- forces retired windows off at READY; only replaceBank is active today.
  replaceGuildBank = true,
  replaceTrainer = true,    -- Baggler-styled trainer window (concealed game frame, closed through the game; confirmed in game)
  ahSwitch = true,          -- Start hops between the bags and the game's auction house (taken through the gamepad catcher, no bindings)
  nativeSwitch = true,      -- keep Start when handing bags to a native item window
  replaceLoot = true,       -- Baggler-styled loot window (the game's loot frame is concealed, closed through the game)
  replaceMail = true,       -- Baggler-styled mailbox (needs /reload)
  replaceTrade = true,      -- Baggler-styled trade window (needs /reload)
  junk = {},                -- [itemID] = true: items the player marked as junk (sold with the grey ones)
  pinTop = {},              -- [itemID] = true: shown first inside its section
  custom = {},              -- [name] = { patterns = {"lowercase", ...}, order = n }

  -- behaviour
  replaceDefault = true,
  replaceBank = true,       -- Baggler-styled bank window (needs /reload)
  vendorColumns = 7,        -- items per row in the vendor window
  replaceVendor = true,     -- Baggler-styled vendor window (needs /reload)
  autoOpen = true,          -- open at vendor / mailbox / trade / auction house
  autoSellJunk = false,
  autoRepair = false,       -- repair everything when a vendor opens (guild funds first)
  lowSpaceWarn = true,      -- chat warning when the bags are nearly full
  lowSpaceAt = 4,
  showAltCounts = true,     -- other characters' item counts in tooltips
  off = {},                 -- parts switched off for testing (/baggler off <name>)
  chars = {},               -- per-character inventory snapshots
  account = {},             -- warband bank snapshot
  views = {},               -- saved searches
  closeOnCombat = false,
  animations = true,        -- subtle motion; off = everything is instant
  highContrast = false,     -- brighter edges and text (see UI:ApplyContrast)
  reduceMotion = false,     -- true: windows only fade (no slides, ripples or pulsing)
  sounds = true,            -- the open / close sounds of the bags
  font = "game",            -- game | narrow | classic (see UI.FONTS)
  fontScale = 1.0,          -- every Baggler text size is multiplied by this (0.9 - 1.3)
  qualityMarks = false,     -- a small letter in the corner of rare and better items, for players who cannot tell the colours apart
  sizes = {},               -- remembered window sizes: sizes.bags / .bank / .vendor = { cols=, h= }
  welcomed = false,

  -- diagnostics
  debug = false,            -- verbose logging to chat (/baggler debug on)
  log = {},                 -- persistent log (see /baggler report)

  -- gamepad
  pad = {
    mode = "auto",          -- auto | on | off
    stickNav = false,       -- left stick also navigates (steals movement while open)
    hints = true,
    backend = "bindings",   -- bindings | catcher. catcher = no override bindings, but the game blocks selling / using / depositing from it
    style = "xbox",         -- xbox | playstation | text
    map = {
      PAD1 = "use",
      PAD2 = "close",
      PAD3 = "pickup",
      PAD4 = "menu",
      PADLSHOULDER = "prevSection",
      PADRSHOULDER = "nextSection",
      PADLTRIGGER = "collapse",
      PADRTRIGGER = "filter",
      PADRSTICK = "sort",
      PADLSTICK = "favorite",
      PADBACK = "options",
      PADFORWARD = "switchWindow",
    },
  },
}

-- Saved profiles are topped up from CB.defaults at load. Whatever the player saved stays (false included); only
-- holes are filled, always with fresh copies so later edits to the profile never reach the defaults table.
-- Keys the defaults do not know about are compatibility data and are left exactly where they are.
local function freshCopy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for k, v in pairs(value) do copy[k] = freshCopy(v) end
  return copy
end

local function fillFromDefaults(saved, defaults)
  -- Walk the defaults with an explicit work list of { savedTable, defaultTable, path }.
  local work = { { saved, defaults, "" } }
  while #work > 0 do
    local item = table.remove(work)
    local into, from, path = item[1], item[2], item[3]
    for key, want in pairs(from) do
      local have = into[key]
      local where = path .. (path ~= "" and "." or "") .. tostring(key)
      if have == nil then
        into[key] = freshCopy(want)
      elseif type(want) == "table" then
        if type(have) == "table" then
          work[#work + 1] = { have, want, where }
        else
          into[key] = freshCopy(want)
          if CB.Warn then
            CB:Warn("db", "saved setting '" .. where .. "' was a " .. type(have) .. ", expected a table; reset to default")
          end
        end
      end
    end
  end
  return saved
end
CB.FillFromDefaults = fillFromDefaults

---------------------------------------------------------------------------
-- Event bus
-- Files register callbacks during TOC loading; they must not read CB.db yet.
-- ADDON_LOADED merges/migrates the profile and emits DB_READY. PLAYER_LOGIN
-- emits READY, when modules may create windows and install their runtime hooks.
-- CB:Safe isolates each callback; it does not make a protected API call secure.
---------------------------------------------------------------------------
local handlers = {}

function CB:On(msg, fn)
  handlers[msg] = handlers[msg] or {}
  table.insert(handlers[msg], fn)
end

function CB:Fire(msg, ...)
  local list = handlers[msg]
  if not list then return end
  for i = 1, #list do CB:Safe("bus:" .. msg, list[i], ...) end
end

local eventFrame = CreateFrame("Frame")
local wowHandlers = {}
CB.eventFrame = eventFrame

function CB:RegisterEvent(event, fn)
  wowHandlers[event] = wowHandlers[event] or {}
  table.insert(wowHandlers[event], fn)
  pcall(eventFrame.RegisterEvent, eventFrame, event) -- tolerate events this client lacks
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  local list = wowHandlers[event]
  if list then for i = 1, #list do CB:Safe("event:" .. event, list[i], event, ...) end end
end)

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
--- True when a part has been switched off with /baggler off <part>. SavedVariables are only available once
--- the add-on has loaded, so this is asked when the part is about to do something, never while files load.
function CB:IsOff(part)
  return CB.db and CB.db.off and CB.db.off[part] and true or false
end

function CB:Print(...)
  print(CB.HEX.brand .. "Baggler|r", ...)
end

function CB:Get(key) return CB.db[key] end

function CB:Set(key, value)
  CB.db[key] = value
  CB:Fire("SETTING", key, value)
end

---------------------------------------------------------------------------
-- Colours. Every colour the add-on uses is named here, so the look can be judged (and changed) in one place.
-- COLOR is for SetTextColor / SetVertexColor, HEX is for inline |cff...|r codes. The "dim" grey is the faintest
-- text that still reads on the dark panels (about 4.8:1 against the window background).
---------------------------------------------------------------------------
CB.COLOR = {
  text     = { 0.91, 0.91, 0.93 },   -- primary text
  soft     = { 0.77, 0.77, 0.80 },   -- numbers beside primary text
  muted    = { 0.60, 0.60, 0.65 },   -- labels, hints, sub-lines
  dim      = { 0.49, 0.49, 0.54 },   -- counts and other low-priority text
  disabled = { 0.40, 0.40, 0.43 },
  white    = { 1, 1, 1 },
  danger   = { 1, 0.50, 0.50 },
  gold     = { 1, 0.82, 0.29 },
  ok       = { 0.35, 0.85, 0.55 },   -- sold, done, a good price
  warn     = { 1, 0.72, 0.25 },      -- expiring, close to a limit
}
CB.HEX = {
  text   = "|cffe9e9ee", soft  = "|cffc4c4cc", muted = "|cff9a9aa6", dim  = "|cff7e7e8a",
  white  = "|cffffffff", gold  = "|cffffd24a", danger = "|cffff8080", loss = "|cffff6060",
  gain   = "|cff40ff60", good  = "|cff80ff80", info  = "|cff8fd0ff", brand = "|cff5ec8ff",
  copper = "|cffe0905a", ok    = "|cff59d98c", warn  = "|cffffb840",
}

--- The values the colour names above take in high-contrast mode (UI:ApplyContrast swaps them in).
CB.CONTRAST = {
  border = { 0.50, 0.50, 0.56 },
  color = { soft = { 0.92, 0.92, 0.95 }, muted = { 0.80, 0.80, 0.85 }, dim = { 0.70, 0.70, 0.76 } },
  hex = { soft = "|cffebebf2", muted = "|cffcdcdd8", dim = "|cffb0b0bd" },
}

-- Keep the original six keys/RGBs stable for existing SavedVariables/shares.
CB.accents = {
  ice     = { 0.37, 0.78, 1.00 },
  violet  = { 0.69, 0.55, 1.00 },
  emerald = { 0.30, 0.85, 0.55 },
  amber   = { 1.00, 0.72, 0.25 },
  rose    = { 1.00, 0.45, 0.60 },
  mono    = { 0.88, 0.88, 0.90 },
  coral   = { 1.00, 0.55, 0.45 },
  salmon  = { 0.96, 0.62, 0.57 },
  peach   = { 1.00, 0.76, 0.61 },
  apricot = { 0.98, 0.67, 0.43 },
  copper  = { 0.84, 0.58, 0.40 },
  gold    = { 0.94, 0.79, 0.40 },
  lemon   = { 0.94, 0.90, 0.58 },
  chartreuse = { 0.77, 0.85, 0.43 },
  lime    = { 0.62, 0.83, 0.43 },
  sage    = { 0.62, 0.74, 0.57 },
  mint    = { 0.63, 0.90, 0.72 },
  seafoam = { 0.46, 0.79, 0.67 },
  teal    = { 0.33, 0.72, 0.69 },
  turquoise = { 0.36, 0.84, 0.80 },
  aqua    = { 0.56, 0.88, 0.91 },
  sky     = { 0.58, 0.77, 0.94 },
  azure   = { 0.40, 0.65, 0.92 },
  periwinkle = { 0.62, 0.66, 0.93 },
  lavender = { 0.77, 0.69, 0.94 },
  lilac   = { 0.84, 0.68, 0.87 },
  orchid  = { 0.82, 0.56, 0.82 },
  mauve   = { 0.76, 0.59, 0.69 },
  pink    = { 0.96, 0.66, 0.79 },
  ruby    = { 0.91, 0.43, 0.53 },
}
-- The pinned Forever ClassColors.lua enumerates all fifteen, including its
-- Adventurer/Traveler classes. Standard class RGBs are offline fallbacks only;
-- the client's public colour API/table wins, including fork-specific colours.
local classPresets = {
  { "WARRIOR", "Warrior", .78, .61, .43 },
  { "PALADIN", "Paladin", .96, .55, .73 },
  { "HUNTER", "Hunter", .67, .83, .45 },
  { "ROGUE", "Rogue", 1, .96, .41 },
  { "PRIEST", "Priest", 1, 1, 1 },
  { "DEATHKNIGHT", "Death Knight", .77, .12, .23 },
  { "SHAMAN", "Shaman", 0, .44, .87 },
  { "MAGE", "Mage", .25, .78, .92 },
  { "WARLOCK", "Warlock", .53, .53, .93 },
  { "MONK", "Monk", 0, 1, .60 },
  { "DRUID", "Druid", 1, .49, .04 },
  { "DEMONHUNTER", "Demon Hunter", .64, .19, .79 },
  { "EVOKER", "Evoker", .20, .58, .50 },
  { "ADVENTURER", "Adventurer", .37, .78, 1 },
  { "TRAVELER", "Traveler", .88, .88, .90 },
}
CB.accentList = { "class" }
local accentClasses, accentNames = {}, { class = "My class", mono = "Monochrome" }
for _, entry in ipairs(classPresets) do
  local key = "class_" .. entry[1]:lower()
  CB.accentList[#CB.accentList + 1] = key
  accentClasses[key], accentNames[key] = entry[1], entry[2]
  CB.accents[key] = { entry[3], entry[4], entry[5] }
end
for key in ("ice violet emerald amber rose mono coral salmon peach apricot copper gold lemon chartreuse lime sage mint seafoam teal turquoise aqua sky azure periwinkle lavender lilac orchid mauve pink ruby"):gmatch("%S+") do
  CB.accentList[#CB.accentList + 1] = key
end

function CB:AccentLabel(key)
  local token = accentClasses[key]
  local localized = token and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
  return localized or accentNames[key] or (type(key) == "string" and key:sub(1, 1):upper() .. key:sub(2)) or "My class"
end

-- Public class colours: C_ClassColor.GetClassColor returns a ColorMixin with
-- r/g/b fields; RAID_CLASS_COLORS is populated from that API by Blizzard.
-- Resolve only the player's class token, never identity, and never log it.
local function public(value)
  return not (issecretvalue and issecretvalue(value))
end
local function classRGB(token)
  if not public(token) or type(token) ~= "string" then return end
  local color
  if C_ClassColor and C_ClassColor.GetClassColor then
    local ok, result = pcall(C_ClassColor.GetClassColor, token)
    if ok and public(result) then color = result end
  end
  if type(color) ~= "table" then color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token] end
  if not public(color) or type(color) ~= "table" then return end
  local r, g, b = color.r, color.g, color.b
  local function channel(v)
    return public(v) and type(v) == "number" and v >= 0 and v <= 1
  end
  if channel(r) and channel(g) and channel(b) then return r, g, b end
end

function CB:Accent()
  local key = CB.db and CB.db.accent or CB.defaults.accent
  local token = accentClasses[key]
  if key == "class" and UnitClass then
    local ok, _, playerToken = pcall(UnitClass, "player")
    if ok and public(playerToken) then token = playerToken end
  end
  local r, g, b = classRGB(token)
  if r then return r, g, b end
  local fallback = public(token) and type(token) == "string" and CB.accents["class_" .. token:lower()]
  local c = fallback or CB.accents[key] or CB.accents.ice
  return c[1], c[2], c[3]
end

CB:RegisterEvent("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  BagglerDB = BagglerDB or {}
  -- No accent-choice provenance was saved by older builds: a stored "ice"
  -- could be either the old default or an explicit selection. Preserve every
  -- existing value; only fresh/missing accents adopt dynamic "My class".
  fillFromDefaults(BagglerDB, CB.defaults)
  -- Start used to be unbound (false); give it the window switch unless the user chose something else.
  if BagglerDB.pad and BagglerDB.pad.map and BagglerDB.pad.map.PADFORWARD == false and not BagglerDB.padForwardMigrated then
    BagglerDB.pad.map.PADFORWARD = "switchWindow"
  end
  BagglerDB.padForwardMigrated = true
  -- Historical migration, retained for old profiles. NativeWindows.lua disables
  -- the retired guild-bank flag at READY; the personal bank remains supported.
  if BagglerDB.bankOptInMigrated == nil then
    BagglerDB.replaceBank = true
    BagglerDB.replaceGuildBank = true
    BagglerDB.bankOptInMigrated = true
  end
  -- Bags-only builds forced this saved flag off. Restore once for the bank
  -- exception; later explicit opt-outs must survive READY and /reload.
  if not BagglerDB.personalBankRestored1 then
    BagglerDB.replaceBank = true
    BagglerDB.personalBankRestored1 = true
  end
  -- Core replacements no longer have user-facing opt-out switches. Upgrade
  -- legacy false flags once, without resetting any optional preferences.
  if not BagglerDB.coreReplacements1 then
    BagglerDB.replaceDefault, BagglerDB.replaceBank = true, true
    BagglerDB.coreReplacements1 = true
  end
  CB.db = BagglerDB
  -- one-time: sections folded by accident (a stray LT) hid whole categories, even the hearthstone
  -- Override bindings replace the game's own gamepad bindings for the same buttons and the game does not put them
  -- back when they are cleared, which left the game's windows dead after a hop. The catcher never touches them.
  -- The catcher cannot use, sell, deposit or buy: the game only allows those from a real key press that reaches a
  -- secure binding (a gamepad event is not enough). Bindings it is; the game's own bindings are restored after a hand-off.
  if not BagglerDB.bindingsDefault6 then
    BagglerDB.pad = BagglerDB.pad or {}
    BagglerDB.pad.backend = "bindings"
    BagglerDB.bindingsDefault6 = true
  end
  if not BagglerDB.ahSwitchSafe4 then   -- the hop no longer uses bindings, so it is safe to have on
    BagglerDB.ahSwitch = true
    BagglerDB.ahSwitchSafe4 = true
  end
  if not BagglerDB.lootOn1 then        -- the loot window was off for everyone while it was experimental; it is rebuilt now
    BagglerDB.replaceLoot = true
    BagglerDB.lootOn1 = true
  end
  BagglerDB.trainerOff3 = true          -- (the trainer window was once forced off for everyone; it is confirmed now, so it is simply the default)
  if not BagglerDB.newSectionOff1 then        -- the "New" section was on by default; new items now sort into their own sections
    BagglerDB.newSection = false
    BagglerDB.newSectionOff1 = true
  end
  if not BagglerDB.junkAllDefault then      -- the toggle first shipped off; grey items are junk, so it now starts on
    BagglerDB.junkAll = true
    BagglerDB.junkAllDefault = true
  end
  if not BagglerDB.foldsReset2 then
    BagglerDB.collapsed = {}
    BagglerDB.foldsReset2 = true
  end
  CB:Fire("DB_READY")
end)

--- Other bag add-ons that would fight Baggler over the same windows.
local CONFLICTS = { "BetterBags", "Bagnon", "Baganator", "ArkInventory", "AdiBags", "Combuctor", "BagPad", "LiteBag", "Sorted", "Inventorian" }
--- Ends a window's visit even if the game ignores our close request: after a short wait, if the window is still
--- up, just close it (the game's own interaction ends when the player walks away, or on the next close).
function CB:ForceEndLater(isActive, endFn, label)
  C_Timer.After(0.6, function()
    if isActive() then
      CB:Warn("close", (label or "window") .. " did not close when asked; closing Baggler's window")
      CB:Safe("forceend", endFn)
    end
  end)
end

function CB:Conflicts()
  if CB.conflictCache then return CB.conflictCache end
  local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  local out = {}
  for _, n in ipairs(CONFLICTS) do
    if loaded and loaded(n) then out[#out + 1] = n end
  end
  CB.conflictCache = out
  return out
end

--- True when another bag add-on is running: Baggler then leaves the game's windows alone (it never fights).
--- /baggler force overrides this for people who know what they are doing.
function CB:StandDown()
  return #CB:Conflicts() > 0 and not (CB.db and CB.db.ignoreConflicts)
end

CB:RegisterEvent("PLAYER_LOGIN", function()
  CB:Fire("READY")
  if not CB.db.welcomed then
    CB.db.welcomed = true
    CB:Print("welcome! Open your bags as usual. " .. CB.HEX.white .. "/baggler|r has settings; press " .. CB.HEX.white .. "Y|r on an item for its menu. From the top row, " .. CB.HEX.white .. "Up|r reaches search, filters and size.")
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_BAGGLER1 = "/baggler"
-- Handler for /baggler. With no argument it opens the settings; the subcommands are listed
-- in the help text at the end.
--- Puts every window back where it starts: the bags, vendor, bank, guild bank, trade, mail, loot, trainer and the
--- other-characters viewer each remember their own place. Windows that are open move now, the rest next time.
function CB:ResetWindowPlaces()
  CB.db.point = { "BOTTOMRIGHT", "UIParent", "BOTTOMRIGHT", -40, 120 }
  for _, key in ipairs({ "vendorPoint", "bankPoint", "guildBankPoint", "tradePoint", "mailPoint", "lootPoint", "trainerPoint", "remotePoint" }) do
    CB.db[key] = nil
  end
  CB.db.sizes = {}
  CB:Fire("SETTING", "sizes")
  CB.Window:ApplyPosition()
  if CB.Vendor and CB.Vendor.frame then CB.Vendor:ApplyPosition() end
  if CB.Bank and CB.Bank.window.frame then CB.Bank.window:ApplyPosition() end
  if CB.Trainer and CB.Trainer.frame then CB.Trainer:ApplyPosition() end
  CB:Print("window positions and sizes reset (windows that are not open yet will start in their usual places).")
end

local function slash(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local native = CB.NativeWindows
  local window = msg:match("^(%a+) on$") or msg:match("^(%a+) off$")
  if native and window and native.retired[window] then
    CB.db[native.retired[window]] = false
    CB:Print(window .. " uses the game's native window; Baggler replaces bags and the personal/account bank.")
    return
  end
  if native and (msg == "vendor" or msg == "guildbank info") then
    CB:Print("native window context: " .. tostring(native:Context() or "none"))
    return
  end
  if msg == "" or msg == "options" or msg == "config" or msg == "settings" then
    CB.Options:Toggle()
  elseif msg == "toggle" or msg == "bags" then
    CB.Window:Toggle()
  elseif msg == "ahdiag" then
    for _, line in ipairs(CB.Pad:Snapshot("by hand")) do CB:Print(line) end
  elseif msg == "ahnav" then
    CB.Pad:NavDump("by hand")
    CB:Print("wrote what the game's cursor can reach in the auction window to the journal ([nav] lines); /reload then /baggler report.")
  elseif msg == "ahkick" then
    CB.Pad:KickAuctionNav("by hand"); CB.Pad:LinkAuctionNav("by hand")
    CB:Print("asked the game to rebuild the auction window's controller cursor.")
  elseif msg == "ahcatcher" then
    CB.Pad.noHoldCatcher = not CB.Pad.noHoldCatcher
    CB:Print("auction house experiment: the catcher is " .. (CB.Pad.noHoldCatcher and "OFF" or "on") .. " while the game's auction window has the controller (Start will not hop back while it is off).")
    CB.Pad:Apply("experiment")
  elseif msg == "sort" then
    CB.Window:CleanUp()
  elseif msg == "reset" then
    CB:ResetWindowPlaces()
  elseif msg == "wipe" then
    CB.db.pins, CB.db.favorites, CB.db.collapsed = {}, {}, {}
    CB:Fire("SETTING", "pins")
    CB:Print("manual category assignments, favorites and collapsed sections cleared.")
  elseif msg:match("^off ") or msg:match("^on ") then
    -- /baggler off trade|mail|loot|remote|extras|guildbank|autohold|ahnav   (then /reload): leaves one part out, to find out
    -- what a game problem is caused by. /baggler on <name> puts it back. /baggler off lists what is off.
    local on, name = msg:match("^(%a+) (%a+)$")
    local valid = { trainer = 1, trade = 1, mail = 1, loot = 1, remote = 1, extras = 1, guildbank = 1, autohold = 1, ahnav = 1 }
    if not name or not valid[name] then
      CB:Print("parts that can be switched: trainer, trade, mail, loot, remote, extras, guildbank, autohold, ahnav")
    else
      BagglerDB.off = BagglerDB.off or {}
      BagglerDB.off[name] = (on == "off") or nil
      CB.db.off = BagglerDB.off
      CB:Print(name .. (on == "off" and " is OFF" or " is back ON") .. " - takes effect at the next visit; /reload if it was already open.")
    end
  elseif msg == "off" then
    local list = {}
    for k, v in pairs(CB.db.off or {}) do if v then list[#list + 1] = k end end
    CB:Print("switched off: " .. (#list > 0 and table.concat(list, ", ") or "nothing"))
  elseif msg == "export" then
    StaticPopup_Show("BAGGLER_EXPORT")
  elseif msg == "import" then
    StaticPopup_Show("BAGGLER_IMPORT")
  elseif msg == "journal" then
    local j = CB.db.journal or {}
    for i = math.max(1, #j - 15), #j do CB:Print(j[i]) end
    if #j == 0 then CB:Print("the journal is empty.") end
  elseif msg == "card" then
    CB.Card:Toggle()
  elseif msg == "force" then
    CB.db.ignoreConflicts = not CB.db.ignoreConflicts
    CB:Print("running next to other bag add-ons: " .. (CB.db.ignoreConflicts and "ON (not recommended)" or "off") .. " - type /reload.")
  elseif msg == "about" or msg == "version" then
    CB:Print(("version %s - %d window module(s) active; other bag add-ons: %s"):format(
      (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "?",
      (CB.Trade and 1 or 0) + (CB.Mail and 1 or 0) + (CB.Loot and 1 or 0) + (CB.Trainer and 1 or 0) + (CB.GuildBank and 1 or 0),
      #CB:Conflicts() > 0 and table.concat(CB:Conflicts(), ", ") or "none"))
  elseif msg == "taint" then
    local scan = CB:TaintScan()
    if #scan == 0 then CB:Print("no game variables written by Baggler were found.")
    else CB:Print("game variables Baggler has written to: " .. table.concat(scan, ", ")) end
  elseif msg == "pad catcher" or msg == "pad bindings" then
    CB.Pad:SetBackend(msg:sub(5))
    CB:Print("controller input method: " .. CB.db.pad.backend .. (CB.db.pad.backend == "catcher" and " (no override bindings; experimental)" or ""))
  elseif msg == "pad off" or msg == "pad on" or msg == "pad auto" then
    CB.db.pad.mode = msg:sub(5)
    CB.Pad:Apply("setting")
    CB:Print("controller mode: " .. CB.db.pad.mode .. (CB.db.pad.mode == "off" and " (Baggler will not touch the controller at all)" or ""))
  elseif msg == "view" or msg:match("^view ") then
    CB.Remote:Open(msg:sub(6))
  elseif msg == "chars" then
    CB.Extras:Chars()
  elseif msg:match("^find ") then
    CB.Extras:Find(msg:sub(6))
  elseif msg == "open" then
    CB.Extras:OpenNext()
  elseif msg == "hearth" then
    CB.Window:UseHearthstone()
  elseif msg == "pad" then
    local d = CB.Pad:Describe()
    CB:Print(d); CB:Info("pad", d)
  elseif msg == "vendor" then
    CB.Vendor:Dump()
  elseif msg == "vendor off" or msg == "vendor on" then
    CB.db.replaceVendor = msg == "vendor on"
    CB:Print("vendor window " .. (CB.db.replaceVendor and "enabled" or "disabled") .. " - type /reload to apply.")
  elseif msg == "guildbank info" then
    CB.GuildBank:Dump()
  elseif msg == "guildbank off" or msg == "guildbank on" then
    CB.db.replaceGuildBank = msg == "guildbank on"
    CB:Print("guild bank window " .. (CB.db.replaceGuildBank and "enabled" or "disabled") .. " - type /reload to apply.")
  elseif msg == "loot off" or msg == "loot on" then
    CB.db.replaceLoot = msg == "loot on"
    CB:Print("loot window " .. (CB.db.replaceLoot and "enabled" or "disabled") .. ".")
    CB:Fire("SETTING", "replaceLoot")
  elseif msg == "mail off" or msg == "mail on" then
    CB.db.replaceMail = msg == "mail on"
    CB:Print("mail window " .. (CB.db.replaceMail and "enabled" or "disabled") .. " - type /reload to apply.")
  elseif msg == "trade off" or msg == "trade on" then
    CB.db.replaceTrade = msg == "trade on"
    CB:Print("trade window " .. (CB.db.replaceTrade and "enabled" or "disabled") .. " - type /reload to apply.")
  elseif msg == "bank off" or msg == "bank on" then
    CB.db.replaceBank = msg == "bank on"
    CB:Print("bank window " .. (CB.db.replaceBank and "enabled" or "disabled") .. " - type /reload to apply.")
  elseif msg == "debug on" or msg == "debug off" then
    CB.db.debug = msg == "debug on"
    CB.debugMode = CB.db.debug
    CB:Print("debug logging " .. (CB.db.debug and "ON (details print to chat and the log)" or "off"))
  elseif msg == "debug" then
    CB.Window:DebugDump()
  elseif msg == "fix" or msg == "unbind" then
    local did = CB:EmergencyReset("manual")
    CB:Print("reset: " .. table.concat(did, "; ") .. ".")
  elseif msg == "incidents" then
    CB:PrintIncidents()
  elseif msg == "report" or msg == "errors" then
    CB:ShowReport()
  elseif msg == "log" or msg:match("^log %d+$") then
    CB:PrintLog(msg:match("%d+"))
  elseif msg == "clearlog" then
    CB.db.log = {}
    CB.errorCount = 0
    CB:Print("log cleared.")
  else
    CB:Print("/baggler            settings")
    CB:Print("/baggler toggle     open or close the bags")
    CB:Print("/baggler sort       clean up (sort) your bags")
    CB:Print("/baggler reset      reset window position")
    CB:Print("/baggler wipe       clear pins, favorites and collapsed sections")
    CB:Print("Baggler replaces bags and the personal/account bank; vendor, guild bank, trade, mail, loot and trainer windows are native.")
    CB:Print("/baggler bank on|off        custom personal/account bank (then /reload)")
    CB:Print("/baggler hearth             use your hearthstone")
    CB:Print("/baggler find <name>        where an item is across your characters")
    CB:Print("/baggler view <name>        look at another character's bags / bank")
    CB:Print("/baggler export | import   copy your settings to another character or a friend")
    CB:Print("/baggler taint             list game variables Baggler has written to (for tracing blocked actions)")
    CB:Print("/baggler pad off|on|auto   turn Baggler's controller handling off for testing")
    CB:Print("/baggler chars              the characters Baggler has recorded")
    CB:Print("/baggler open               open the next lootable bag item")
    CB:Print("/baggler pad        who holds the controller right now (for bug reports)")
    CB:Print("/baggler debug      print diagnostics  (debug on|off for verbose logging)")
    CB:Print("/baggler fix        release controller bindings / click catcher / held item (no reload needed)")
    CB:Print("/baggler incidents  print bounded reload-surviving world/combat/gossip/taxi/AH error evidence (no popup)")
    CB:Print("/baggler report     open a copyable error + diagnostics report")
    CB:Print("/baggler log [n]    print the last n log entries")
  end
end
SlashCmdList["BAGGLER"] = function(msg) CB:Safe("slash", slash, msg) end
