-- Real shipping TOC; offline presentation/compatibility evidence only.
dofile('tests/harness/ca_stubs.lua')
local create = CreateFrame
CreateFrame = function(...)
  local f = create(...)
  local texture = f.CreateTexture
  f.CreateTexture = function(self, ...)
    local t = texture(self, ...)
    function t:SetTexture(path) self.__texture = path end
    function t:SetTexCoord(...) self.__coords = { ... } end
    return t
  end
  local fontString = f.CreateFontString
  f.CreateFontString = function(self, ...)
    local s = fontString(self, ...)
    function s:SetPoint(...) self.__point = { ... } end
    return s
  end
  local setSize = f.SetSize
  function f:SetSize(w, h) self.__w = w; return setSize(self, w, h) end
  return f
end
function UnitClass() return 'Warrior', 'WARRIOR' end
local CB = {}
local incidentCallback, incidentOwner, grabbedError
local originalHandler = geterrorhandler()
EventRegistry = { RegisterCallback = function(_, event, fn, owner)
  if event == 'BugGrabber.BugGrabbed' then incidentCallback, incidentOwner = fn, owner end
end }
BugGrabber = { GetErrorByID = function(_, id) if id == 'fixture' then return grabbedError end end }
BagglerDB = { scale = 1.17, favorites = { [123] = true }, welcomed = true }
local saved = BagglerDB
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(name, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, name, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
assert(SLASH_BAGGLER1 == '/baggler', 'primary slash must be /baggler, not /baggler')
assert(type(SlashCmdList.BAGGLER) == 'function', 'runtime slash identity')
assert(CB.db == saved and CB.db.scale == 1.17 and CB.db.favorites[123], 'existing BagglerDB must survive')
assert(_G.Baggler == CB, 'runtime namespace must match loader')
CB.Window:Open()
local f = CB.Window.frame
assert(f:GetName() == 'BagglerFrame', 'stable frame name')
assert(f.title:GetText():gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', ''):find('Baggler', 1, true), 'bag title must use Baggler')
assert(f.icon.__texture == 'Interface\\AddOns\\Baggler\\Assets\\baggler-header.tga', 'header must load alpha TGA')
assert(f.icon:GetWidth() == 36 and f.icon:GetHeight() == 36, 'readable art stays within existing header')
assert(f.icon.__coords[1] == 0 and f.icon.__coords[2] == 1, 'transparent art must not be icon-cropped')
assert(f.search:GetWidth() == 150, 'reserve room for longer title and art without moving controls')
-- Bank and Warband Bank headers: same Baggler name and 36px transparent art as the bags, never the split C + Bags.
local function plain(t) return (tostring(t or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '')) end
local B, BW = CB.Bank, CB.Bank.window
Enum.BagIndex.Characterbanktab, Enum.BagIndex.Accountbanktab = -4, -5
C_Bank.CanUseBank = function() return true end
C_Bank.CanViewBank = function() return true end
C_Bank.FetchNumPurchasedBankTabs = function() return 1 end
C_Bank.FetchPurchasedBankTabData = function() return { { ID = 6 } } end
C_Container.GetContainerNumSlots = function(id) return id == 6 and 28 or 0 end
B.active = true; B.viewType = nil
BW:Open(); BW:UpdateExtras()
local bf = BW.frame
local function checkBank(label, descriptor)
  local text = plain(bf.title:GetText())
  assert(text:find('Baggler', 1, true) and text:find(descriptor, 1, true), label .. ' title must read Baggler + ' .. descriptor .. ': ' .. text)
  assert(not text:find('C' .. 'Bags', 1, true), label .. ' title must not carry the obsolete split name')
  assert(bf.icon.__texture == 'Interface\\AddOns\\Baggler\\Assets\\baggler-header.tga', label .. ' header art path')
  local c = bf.icon.__coords
  assert(c[1] == 0 and c[2] == 1 and c[3] == 0 and c[4] == 1, label .. ' art must use the full UV')
  assert(bf.icon:GetWidth() == 36 and bf.icon:GetHeight() == 36, label .. ' art must be 36px like the bags')
  -- minimum supported width: title wide enough for the descriptor, search clear of the title and the 4 right-hand buttons
  BW.innerW = 100; BW:ApplySize()
  local frameW = bf.__w
  assert(frameW >= 480, label .. ' minimum width must leave room for the descriptor, got ' .. tostring(frameW))
  local titleW, searchW = bf.title:GetWidth(), bf.search:GetWidth()
  assert(titleW >= 184, label .. ' title width must hold the descriptor, got ' .. tostring(titleW))
  local titleLeft = 12 + 44
  assert(bf.title.__point[2] == titleLeft, label .. ' title anchor sits right of the 36px art')
  local searchRight = titleLeft + titleW + 19 + searchW
  local controlsLeft = frameW - (10 + 4 * 22 + 3 * 5)
  assert(searchW >= 100 and searchRight + 8 <= controlsLeft, label .. ' search must clear the title bar controls at minimum width')
end
checkBank('Bank', 'Bank')
B.viewType = Enum.BankType and Enum.BankType.Account or 2
BW:UpdateExtras(); BW:ApplySize()
if B:IsWarband() then checkBank('Warband Bank', 'Warband Bank') else error('could not put the test bank in warband view') end
-- Observe raw runtime errors through the verified BugGrabber callback, never
-- by replacing the process-wide handler (covered in depth by incidents_test).
assert(geterrorhandler() == originalHandler, 'Baggler must leave the global handler alone')
assert(incidentCallback, 'BugGrabber callback must be registered')
grabbedError = { message = 'Interface/AddOns/Baggler/Core.lua:1: raw failure',
  stack = 'Interface/AddOns/Baggler/Core.lua:1: in function' }
incidentCallback(incidentOwner, 'fixture')
assert(#CB.db.incidents.errors == 1 and CB.db.incidents.errors[1].event == 'LUA_ERROR',
  'raw runtime-path errors must still be captured through supported callback')
local report = CB:BuildReport()
assert(report:find('Baggler report', 1, true), 'report branding')
local exported = CB.Extras:Export()
assert(exported:sub(1, 9) == 'BAGGLER2:', 'export prefix identity')
assert(CB.Extras:Import(exported), 'renamed export must round trip')
assert(BagglerPadBroker and BagglerPadBroker:Has('Baggler'), 'broker runtime identity')
print('ALL PASS Baggler TOC, saved settings, globals/frame/broker, export round trip and readable alpha header (offline only)')
