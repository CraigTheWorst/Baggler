-- Host-level behavior through the TOC and actual event/binding entry points.
-- Independent policy suites separately cover controlled repeat/alias budgets.
dofile('tests/harness/ca_stubs.lua')
function UnitClass() return 'Warrior','WARRIOR' end
local now=0
function GetTime() return now end
local device=1
local mapped={buttonCount=1,buttons={false}}
C_GamePad.GetActiveDeviceID=function() return device end
C_GamePad.GetDeviceMappedState=function() return mapped end
C_GamePad.ButtonBindingToIndex=function(key) if key=='PAD4' then return 0 end end
local CB={}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/'..line))('Baggler',CB) end
end
CB.eventFrame:GetScript('OnEvent')(CB.eventFrame,'ADDON_LOADED','Baggler')
CB.eventFrame:GetScript('OnEvent')(CB.eventFrame,'PLAYER_LOGIN');FLUSH()
for _,g in ipairs(CB.Pad.GAME_WINDOWS) do local f=g.frame();if f then f:Hide() end end
local P=CB.Pad
CB.db.pad.mode='on';P:SetBackend('catcher')
local count=0
local ctx={OnPad=function(_,action) if action=='menu' then count=count+1 end end}
P:Push(ctx)
local receiver=assert(P:Receiver())
local function down(key) receiver:GetScript('OnGamePadButtonDown')(receiver,key) end
local function up(key) receiver:GetScript('OnGamePadButtonUp')(receiver,key) end
P.input:Tick() -- establish known-up polling baseline
mapped.buttons[1]=true
down('PAD4');P.input:Tick();down('PAD4')
assert(count==1,'event and poll must share one physical press identity')
up('PAD4');mapped.buttons[1]=false;P.input:Tick()
CB.db.pad.map.PAD4=false;P:Apply('unbind')
down('PAD4');up('PAD4');assert(count==1,'false mapping must not dispatch')
assert(receiver.__propagate==true,'unbound key must propagate')
CB.db.pad.map.PAD4='menu';P:Apply('remap')
P:Pop(ctx)
local closer={OnPad=function() count=count+1;P:Pop(closer) end}
-- Lua locals are not in scope in their own initializer.
closer.OnPad=function() count=count+1;P:Pop(closer) end
P:Push(closer);down('PAD4')
assert(count==2 and not P.bound,'closing dispatch must execute once and release ownership')
assert(receiver.__propagate==false,'a consumed closing press must not also execute the world binding')
up('PAD4')
assert(receiver.__propagate==false,'host consumes matching release after engine Pop cancellation')
down('PAD4');up('PAD4')
assert(receiver.__propagate==true,'fresh unowned input restores per-event propagation')
P:Push(ctx);now=10;down('PADDUP')
COMBAT=true;CB.eventFrame:GetScript('OnEvent')(CB.eventFrame,'PLAYER_REGEN_DISABLED')
P:Pop(ctx)
assert(not P.bound and not receiver:IsShown(),'combat closes reception without restricted writes')
COMBAT=false;CB.eventFrame:GetScript('OnEvent')(CB.eventFrame,'PLAYER_REGEN_ENABLED')
print('PASS physical event/poll dedup, explicit unbind, exclusive closing press and combat relinquishment')
-- A context can disappear without a Pop; engine pruning must also release the
-- retained secure host/broker, not only change a logical bound flag.
P:SetBackend('bindings')
local alive=true
local unexpected=0
local transient={alive=function() return alive end,OnPad=function() unexpected=unexpected+1 end}
P:Push(transient)
assert(P.bound and next(BagglerPadOwner.__bindings),'precondition: real owner installed bindings')
local target=assert(BagglerPadOwner.__bindings.PAD4:match('^CLICK ([%w_]+):'))
local mappedButton=assert(_G[target])
mappedButton:Click('LeftButton',nil)
assert(unexpected==0,'unknown click phase must not invent physical input')
alive=false
for _,f in ipairs(frames) do local tick=f:GetScript('OnUpdate');if tick then tick(f,0.016) end end
assert(not P.bound and not BagglerPadBroker:Has('Baggler') and next(BagglerPadOwner.__bindings)==nil,
  'pruning an invalid last context must release secure bindings and broker claim')
print('PASS missed Pop pruning releases real host ownership')
alive=true;P:Push(transient)
alive=false
mappedButton:Click('LeftButton',true) -- Observe may prune before the host ticker.
mappedButton:Click('LeftButton',false)
for _,f in ipairs(frames) do local tick=f:GetScript('OnUpdate');if tick then tick(f,0.016) end end
assert(unexpected==0 and not BagglerPadBroker:Has('Baggler') and next(BagglerPadOwner.__bindings)==nil,
  'event-side pruning must drain the host even when the next tick starts empty')
print('PASS event-side stale-context rejection drains retained secure host')
alive=true;P:Push(transient)
local foreignApplies=0
BagglerPadBroker:Claim('fixture-foreign',function() foreignApplies=foreignApplies+1 end,function() end)
local beforeForeign=foreignApplies
COMBAT=true;CB.eventFrame:GetScript('OnEvent')(CB.eventFrame,'PLAYER_REGEN_DISABLED');P:Reset()
assert(foreignApplies==beforeForeign and BagglerPadBroker:Winner()=='fixture-foreign',
  'combat/reset may not resolve or rebind a foreign broker claimant')
COMBAT=false;CB.eventFrame:GetScript('OnEvent')(CB.eventFrame,'PLAYER_REGEN_ENABLED')
BagglerPadBroker:Release('fixture-foreign')
print('PASS combat logical teardown never invokes a foreign broker rebind')
