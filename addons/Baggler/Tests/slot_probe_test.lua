-- Run from repository root: timeout 60 luajit addons/Baggler/Tests/slot_probe_test.lua
-- Diagnostic seam only: CB:SlotProbe names the probe point at which a game slot FIRST shows as not secure and the last
-- probe that still saw it clean, so the tainting call is bracketed instead of guessed. Offline stub of issecurevariable
-- (a slot is "written by Baggler" when the test says so); this is not an in-game taint proof.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior', 'WARRIOR' end
function IsAltKeyDown() return false end
function IsControlKeyDown() return false end
function IsShiftKeyDown() return false end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()

local calledNative, wroteNative = 0, 0
local guard = { __newindex = function() wroteNative = wroteNative + 1 end }
local pad1 = setmetatable({ name = 'PAD1', boundFunction = function() calledNative = calledNative + 1 end }, guard)
local manager = setmetatable({ activeBindings = setmetatable({ PAD1 = pad1 }, guard), currentCoreBindingActive = true }, guard)
GamepadSharedUtility = { InputBindingManager = manager }
MerchantFrame = rawget(_G, 'MerchantFrame') or CreateFrame('Frame', 'MerchantFrame', UIParent)
MerchantFrame.selectedTab = 1
ContainerFrameCombinedBags = { size = 0, shownSlots = 0 }

local writer = {}
local function mark(t, k, by) writer[t] = writer[t] or {}; writer[t][k] = by end
function issecurevariable(t, k)
  local w = type(t) == 'table' and writer[t]
  if w and w[k] then return false, w[k] end
  return true
end
local function probeLines()
  local out = {}
  for _, l in ipairs(CB.db.log) do if l.ctx == 'taint' and l.msg:find('probe: first not secure', 1, true) then out[#out + 1] = l.msg end end
  return out
end

-- clean probes say nothing but leave a trail
CB:SlotProbe('before HideBlizzardBags'); CB:SlotProbe('after HideBlizzardBags'); CB:SlotProbe('after game OpenAllBags()')
assert(#probeLines() == 0, 'clean probes log nothing')

-- the write happens between two probes: the later one is named, the earlier one is the last clean point
mark(ContainerFrameCombinedBags, 'shownSlots', 'Baggler')
CB:SlotProbe('after item button 3 CreateFrame')
local got = probeLines()
assert(#got == 1, 'one line for the first sighting: ' .. #got)
assert(got[1]:find("at 'after item button 3 CreateFrame'", 1, true), 'names the probe that saw it: ' .. got[1])
assert(got[1]:find("still clean: 'after game OpenAllBags()'", 1, true), 'names the last clean probe: ' .. got[1])
assert(got[1]:find('ContainerFrameCombinedBags.shownSlots (by Baggler)', 1, true), 'names the slot and writer: ' .. got[1])

-- already-reported slots are not repeated; a later new slot is, bracketed by the new previous probe
CB:SlotProbe('after item button 3 Initialize')
assert(#probeLines() == 1, 'an already reported slot is not repeated')
mark(pad1, 'boundFunction', 'Baggler'); mark(manager.activeBindings, 'PAD1', 'Baggler')
CB:SlotProbe('after game PanelTemplates_SetTab(MerchantFrame)')
got = probeLines()
assert(#got == 2 and got[2]:find("still clean: 'after item button 3 Initialize'", 1, true)
  and got[2]:find('activeBindings.PAD1 (by Baggler)', 1, true), 'second sighting bracketed: ' .. tostring(got[2]))

-- another add-on's write is attributed to that add-on
mark(MerchantFrame, 'selectedTab', 'OtherAddon')
CB:SlotProbe('event MERCHANT_SHOW')
got = probeLines()
assert(got[3] and got[3]:find('MerchantFrame.selectedTab (by OtherAddon)', 1, true), 'writer named: ' .. tostring(got[3]))

-- the call sites exist and the probes are read-only
assert(calledNative == 0, 'no game function called (' .. calledNative .. ')')
assert(wroteNative == 0, 'nothing written into game tables (' .. wroteNative .. ')')
local function source(f) local h = assert(io.open(f)); local s = h:read('*a'); h:close(); return s end
assert(source('addons/Baggler/Integrations.lua'):find('SlotProbe("before HideBlizzardBags")', 1, true), 'probe brackets HideBlizzardBags')
assert(source('addons/Baggler/Integrations.lua'):find('SlotProbe("after game " .. name', 1, true), 'probe after each game bag call')
assert(source('addons/Baggler/Window.lua'):find('Initialize")', 1, true), 'probe after item button Initialize')
print('PASS slot probe brackets the first call after which a game slot is not secure, and is read-only')
