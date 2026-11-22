-- Behavior checks through the shipping loader; independent engines retain their own suites.
dofile('addons/Baggler/Tests/bags_only_test.lua')
local CB = Baggler
assert(CB and CB.InputSession and CB.ProfileShare and CB.EquippedCompare, 'replacement units must be registered by the shipping TOC')
local Pad = CB.Pad
assert(Pad.input, 'Pad must delegate physical input to InputSession')
CB.Window:Open(); Pad:Push(CB.Window.ctx)
local received = {}
local ctx = {OnPad=function(_, action) received[#received+1]=action end}
Pad:Push(ctx)
local f = Pad:Receiver()
f:GetScript('OnGamePadButtonDown')(f,'PADDUP')
f:GetScript('OnGamePadButtonDown')(f,'PADDUP')
f:GetScript('OnGamePadButtonUp')(f,'PADDUP')
assert(#received==1 and received[1]=='up', 'duplicate direct events must dispatch one action')
Pad:Pop(ctx)
local original = CB.db
local private = CB.db.chars
local events = {}
CB:On('SETTING',function(key) if key=='import' then events[#events+1]='setting' end end)
CB:On('DIRTY',function() events[#events+1]='dirty' end)
assert(CB.Extras:Import('BAGGLER2:{"pad":{"map":{"PAD1":false}}}'))
assert(CB.db==original and CB.db.pad.map.PAD1==false and CB.db.chars~=nil, 'atomic import preserves profile root and private data')
assert(#events==2, 'successful import publishes exactly two success events')
local n=#events
assert(not CB.Extras:Import('BAGGLER2:{"scale":9}'))
assert(#events==n and CB.db==original, 'rejection publishes no success')
local export=assert(CB.Extras:Export())
assert(export:sub(1,9)=='BAGGLER2:' and not export:find('"chars"',1,true))
local box={text='stale'}
function box:SetText(text) self.text=text end
function box:GetText() return self.text end
function box:HighlightText() self.selected=true end
function box:SetFocus() self.focused=true end
local popup={editBox=box,Hide=function(self) self.hidden=true end}
StaticPopupDialogs.BAGGLER_EXPORT.OnShow(popup)
assert(box.text==CB.Extras:Export() and box.selected and box.focused,'popup must select/focus complete current export')
local exportMethod=CB.Extras.Export
CB.Extras.Export=function() return nil,'fixture resource limit' end
StaticPopupDialogs.BAGGLER_EXPORT.OnShow(popup)
CB.Extras.Export=exportMethod
assert(box.text=='' and popup.hidden,'export failure must clear stale text and hide unsuccessful output')
box.text='BAGGLER2:{"scale":1.1}'
StaticPopupDialogs.BAGGLER_IMPORT.OnAccept(popup)
assert(CB.db.scale==1.1 and #events==n+2,'actual popup acceptance commits and emits one success pair')
print('PASS replacement loader, direct observation, transactional sharing, notifications and production popups')
