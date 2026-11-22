-- Actual shipping catcher forwarding path; simulated provenance, NOT a live taint proof.
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
local W = CB.Window
W:Open(); FLUSH()
local b = assert(W:GetButton(0, 1))
local seen, called = {}, 0
CB.AuraProbe = function(_, label) seen[#seen + 1] = label end
W.ItemEnter = function() end
W.HoverCardEnd = function() end
for _, script in ipairs({ 'OnEnter', 'OnLeave', 'OnDragStart', 'OnReceiveDrag' }) do
  seen = {}
  b:SetScript(script, function(self)
    assert(self == b, 'native script still receives item button, not catcher')
    called = called + 1
    seen[#seen + 1] = 'native body'
  end)
  b.cbCatch:GetScript(script)(b.cbCatch)
  assert(#seen == 3 and seen[1]:find('before native item ' .. script, 1, true)
    and seen[2] == 'native body' and seen[3]:find('after native item ' .. script, 1, true),
    'diagnostic must bracket real forwarded ' .. script .. ': ' .. table.concat(seen, ' > '))
end
assert(called == 4, 'native forwarding is neither suppressed nor duplicated')
print('PASS shipping item catcher native hover/drag calls are bracketed without changing forwarding (offline only)')
