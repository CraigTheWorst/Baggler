-- Run from repository root: timeout 90 luajit addons/Baggler/Tests/panel_close_test.lua
-- Regression: closing a native non-bag panel (talents, spellbook, character, collections, settings,
-- game menu, quest log, map, professions ...) must never open Baggler. Only a real bag request may:
-- the bag keybindings, the bag bar buttons and the controller radial's "Bags" all reach a Toggle*
-- bag function; paired visits hand their frame to OpenAllBags/CloseAllBags.
--
-- The native side is modelled on the pinned Forever source (wow-ui-source 9dc84f0d, client 1.60.1):
--   Bindings_Camelot.xml 1172-1192   TOGGLEBACKPACK -> ToggleBackpack(), TOGGLEBAGn -> ToggleBag(n),
--                                    OPENALLBAGS -> ToggleAllBags(), TOGGLEGAMEMENU -> ToggleGameMenu()
--   MainMenuBarBagButtons.lua 69-81  bag bar click -> ToggleBag(id) / shift -> ToggleAllBags()
--   GamepadRadial.lua 617-619        radial "Bags" -> ToggleBackpack_Combined()
--   ContainerFrame.lua 172-198, 2173-2216 (Mainline, loaded for Camelot) toggles; 2282 CloseAllBags(frame)
--   Blizzard_GameMenuEsc.lua 105-121 ToggleGameMenu runs Esc handlers; GameMenuFrame.lua 26-36 hides the menu
--   UIParentPanelManager.lua 1175-1190 CloseAllWindows (Esc AddOnPost handler) = CloseAllBags() + CloseWindows()
--   UIParentPanelManager.lua 287-293 ShowUIPanel(center, no allowOtherPanels) -> CloseAllBags()
--   Blizzard_PlayerSpellsFrame.lua 72-93 talents/spellbook OnHide: no bag call (UpdateMicroButtons only)
-- Offline only: this is not an in-game proof.
dofile('tests/harness/ca_stubs.lua')
MerchantFrame.__shown = false
local now = 100
function GetTime() return now end
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end

-- Native bag functions (combined bags, controller UI on; the hidden game frame only tracks belief).
local nativeOpen, openedBy = true, nil       -- after a reload the game believes its bags open
function OpenBackpack() nativeOpen = true end
function CloseBackpack() local was = nativeOpen; nativeOpen = false; return was end
function OpenBag() nativeOpen = true end
function CloseBag() return false end
function ToggleBackpack_Combined()
  if nativeOpen then ContainerFrameCombinedBags:Hide(); nativeOpen = false else OpenBackpack() end
end
function ToggleBackpack() ToggleBackpack_Combined() end
function ToggleBag() ToggleBackpack_Combined() end
function ToggleAllBags() ToggleBackpack_Combined() end
function OpenAllBags(frame)
  if nativeOpen then return end
  if frame and not openedBy then openedBy = frame:GetName() end
  OpenBackpack()
end
function CloseAllBags(frame)
  if frame and frame:GetName() ~= openedBy then return false end
  openedBy = nil
  local closed = CloseBackpack()
  for i = 1, 5 do closed = CloseBag(i) or closed end
  return closed
end

-- Native panel manager and Escape.
local panels = {}
function ShowUIPanel(f)
  if f.center and not f.allowOtherPanels then CloseAllBags() end
  f:Show()
end
function HideUIPanel(f) f:Hide() end
local function CloseWindows()
  local found = false
  for _, f in ipairs(panels) do if f:IsShown() then f:Hide(); found = true end end
  return found
end
function CloseAllWindows()
  local bags = CloseAllBags()
  local windows = CloseWindows()
  return bags or windows
end

local CB = {}
BagglerDB = { replaceBank = false, bankOptInMigrated = true, personalBankRestored1 = true }
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
local function flush() FLUSH(); FLUSH() end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); flush()
local W, I = CB.Window, CB.Integrations
now = 200   -- well past the post-reload tidy window and the zoning grace

local GameMenuFrame = CreateFrame('Frame', 'GameMenuFrame', UIParent); GameMenuFrame:Hide()
local SettingsPanel = CreateFrame('Frame', 'SettingsPanel', UIParent); SettingsPanel:Hide()
function ToggleGameMenu()
  -- GameMenuFrame_EscapePressed (Framework) runs before CloseAllWindows (AddOnPost)
  if GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame); return end
  if CloseAllWindows() then return end
  ShowUIPanel(GameMenuFrame)
end
panels[#panels + 1] = GameMenuFrame
panels[#panels + 1] = SettingsPanel

local function panel(name, center, allowOtherPanels)
  local f = rawget(_G, name) or CreateFrame('Frame', name, UIParent)
  f:Hide(); f.center, f.allowOtherPanels = center, allowOtherPanels
  f.__scripts.OnHide = function() if UpdateMicroButtons then UpdateMicroButtons() end end
  panels[#panels + 1] = f
  return f
end
function UpdateMicroButtons() end
-- PlayerSpellsFrame (talents + spellbook in Forever): centerOrLeft, allowOtherPanels = 1 (Registration.lua)
local list = {
  { 'PlayerSpellsFrame', 'talents', false, true },
  { 'PlayerSpellsFrame', 'spellbook', false, true },
  { 'CharacterFrame', 'character' },
  { 'CollectionsJournal', 'collections' },
  { 'SettingsPanel', 'options', true, false },
  { 'QuestLogFrame', 'quest log' },
  { 'WorldMapFrame', 'map' },
  { 'ProfessionsFrame', 'professions' },
  { 'ProfessionsBookFrame', 'profession book' },
  { 'AchievementFrame', 'achievements' },
  { 'PVEFrame', 'group finder' },
  { 'EncounterJournal', 'adventure guide' },
  { 'CommunitiesFrame', 'guild & communities' },
  { 'MacroFrame', 'macros', true, false },
}
local frames = {}
for _, p in ipairs(list) do frames[p[1]] = frames[p[1]] or panel(p[1], p[3], p[4]) end

local failures = 0
local function check(cond, msg)
  if cond then return end
  failures = failures + 1
  print('FAIL ' .. msg)
end
local function reset(open)
  now = now + 10
  for _, f in ipairs(panels) do f:Hide() end
  CB.NativeWindows.active = {}; CB.NativeWindows.endedAt = nil
  W:Close(); W.closedAt = now - 10
  nativeOpen, openedBy, I.gameOpen = true, nil, true
  CB.Pad:Reset(); CB.Pad.seenGame, CB.Pad.declinedGame = {}, {}
  if open then W:Open() end
  now = now + 2
end

local closers = {
  escape = function() ToggleGameMenu() end,                   -- Esc / controller TOGGLEGAMEMENU
  ['close button'] = function(f) HideUIPanel(f) end,         -- the X / the panel's own key
}
for _, p in ipairs(list) do
  local f = frames[p[1]]
  for how, close in pairs(closers) do
    for _, belief in ipairs({ true, false }) do
      reset(false); nativeOpen, I.gameOpen = belief, belief
      ShowUIPanel(f); flush()
      check(not W:IsOpen(), ('opening %s must not open the bags'):format(p[2]))
      now = now + 2
      close(f); flush()
      check(not W:IsOpen(), ('closing %s with %s (game believed bags open=%s) must not open the bags'):format(p[2], how, tostring(belief)))
    end
  end
end
print('checked native panel open/close never opens the bags')

-- the game menu itself. While the game believes its hidden bags open, the first Escape is spent closing them
-- (CloseAllWindows returns true, no menu); the next one shows the menu; Escape on the menu hides it.
reset(false)
ToggleGameMenu(); flush()
check(not GameMenuFrame:IsShown() and not W:IsOpen(), 'Escape spent on the game\'s hidden bags must not open ours')
now = now + 2; ToggleGameMenu(); flush()
check(GameMenuFrame:IsShown(), 'model: Escape with nothing up shows the game menu')
check(not W:IsOpen(), 'opening the game menu with Escape must not open the bags')
now = now + 2; ToggleGameMenu(); flush()        -- GameMenuFrame_EscapePressed hides the menu
check(not GameMenuFrame:IsShown(), 'model: Escape on the menu hides it')
check(not W:IsOpen(), 'closing the game menu must not open the bags')
now = now + 2; ShowUIPanel(GameMenuFrame); ShowUIPanel(SettingsPanel); GameMenuFrame:Hide(); flush()
now = now + 2; HideUIPanel(SettingsPanel); flush()
check(not W:IsOpen(), 'closing options from the game menu must not open the bags')
-- Escape again and again from the world (menu up, down, up ...)
for i = 1, 4 do now = now + 2; ToggleGameMenu(); flush() end
check(not W:IsOpen(), 'repeated Escape must never open the bags')
print('checked game menu Escape open/close')

-- Positive controls: every real bag request still works, first press included.
local requests = {
  { 'TOGGLEBACKPACK binding', function() ToggleBackpack() end },
  { 'OPENALLBAGS binding', function() ToggleAllBags() end },
  { 'bag bar / TOGGLEBAGn', function() ToggleBag(0) end },
  { 'controller radial Bags', function() ToggleBackpack_Combined() end },
}
for _, r in ipairs(requests) do
  for _, belief in ipairs({ true, false }) do
    reset(false); nativeOpen, I.gameOpen = belief, belief
    r[2](); flush()
    check(W:IsOpen(), ('%s must open the bags on the first press (game believed open=%s)'):format(r[1], tostring(belief)))
    now = now + 2; r[2](); flush()
    check(not W:IsOpen(), ('%s must close the bags again'):format(r[1]))
    -- and it still works right after a native panel closed
    ShowUIPanel(frames.PlayerSpellsFrame); now = now + 2; ToggleGameMenu(); flush()
    now = now + 2; r[2](); flush()
    check(W:IsOpen(), ('%s must open the bags right after talents closed'):format(r[1]))
  end
end
print('checked bag keybinds, bag bar and radial Bags')

-- Native parity: Escape (CloseAllWindows) and center panels still put away bags that are up.
reset(true); now = now + 2
ToggleGameMenu(); flush()
check(not W:IsOpen(), 'Escape must still close open bags')
reset(true); now = now + 2
ShowUIPanel(frames.MacroFrame); flush()
check(not W:IsOpen(), 'a center panel without allowOtherPanels must still close open bags')
reset(true); now = now + 2
ShowUIPanel(frames.PlayerSpellsFrame); HideUIPanel(frames.PlayerSpellsFrame); flush()
check(W:IsOpen(), 'talents (allowOtherPanels) must leave open bags alone')
print('checked native Escape / panel parity for open bags')

-- Paired visit still owns the bag lifetime.
reset(false)
MerchantFrame:Show(); event('MERCHANT_SHOW'); OpenAllBags(MerchantFrame); flush()
check(W:IsOpen(), 'merchant must open the bags')
now = now + 2; MerchantFrame:Hide(); event('MERCHANT_CLOSED'); CloseAllBags(MerchantFrame); flush()
check(not W:IsOpen(), 'merchant close must put the bags away')
print('checked merchant pairing')

check((CB.errorCount or 0) == 0, 'shipping modules logged Lua errors')
if failures > 0 then print(('%d FAILURE(S) panel close'):format(failures)); os.exit(1) end
print('ALL PASS panel close (offline only)')
