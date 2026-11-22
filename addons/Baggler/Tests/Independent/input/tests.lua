local chunk = assert(loadfile('InputSession.lua'))
local standard = {assert=assert,type=type,setmetatable=setmetatable,rawget=rawget,
    pairs=pairs,ipairs=ipairs,pcall=pcall,table=table}
setfenv(chunk,setmetatable(standard,{
    __index=function(_,key) error('unknown game/global API '..tostring(key)) end,
    __newindex=function(_,key) error('unexpected global write '..tostring(key)) end,
}))
local Engine = chunk()
local tests, count = {}, 0
local function test(name, f) tests[#tests+1] = {name, f} end
local function eq(a,b) assert(a == b, tostring(a)..' ~= '..tostring(b)) end
local function fixture()
    local f = {time=0, actions={}, releases={}, writes={}, combat=false, notices={}}
    local host = {
        clock=function() return f.time end,
        combat=function() return f.combat end,
        dispatch=function(ctx, action, meta)
            f.actions[#f.actions+1]={ctx=ctx, action=action, meta=meta}
            if ctx and ctx.OnPad then ctx:OnPad(action) end
        end,
        release=function(ctx, action, meta) f.releases[#f.releases+1]={ctx=ctx, action=action, meta=meta} end,
        reception=function(on) assert(not f.combat, 'insecure reception'); f.writes[#f.writes+1]={'receive',on} end,
        propagate=function(on) assert(not f.combat, 'insecure propagation'); f.writes[#f.writes+1]={'propagate',on} end,
        suspend=function() f.suspends=(f.suspends or 0)+1 end,
        ownership=function(on) f.notices[#f.notices+1]=on end,
    }
    setmetatable(host,{__index=function(_,k) error('unknown host API '..k) end})
    f.host=host
    f.e=Engine.new(host)
    f.ctx={}
    f.e:Configure({mode='on',backend='catcher',stickNav=true,map={PAD1='use',PAD2='close',PAD3='filter',PAD4='favorite',PADFORWARD='switchWindow'}})
    f.e:Environment({hardware=true,winner=true,combat=false})
    f.e:Push(f.ctx)
    function f:press(k,source) return self.e:Observe(k,true,source or 'event') end
    function f:up(k) return self.e:Observe(k,false,'event') end
    function f:step(dt) self.time=self.time+dt; self.e:Tick() end
    function f:boundary(state) if state.combat ~= nil then self.combat=state.combat end; self.e:Environment(state) end
    return f
end

test('I01 eligible on/auto, off, missing hardware, foreign owner', function()
    local f=fixture(); eq(f:press('PAD1'),true); eq(#f.actions,1); f:up('PAD1')
    for _,state in ipairs({{winner=false},{winner=true,hardware=false}}) do
        f:boundary(state); eq(f:press('PAD1'),false); f:up('PAD1')
    end
    eq(#f.actions,1)
    f:boundary({hardware=true}); f.e:Configure({mode='off'}); eq(f:press('PAD1'),false); f:up('PAD1')
    f.e:Configure({mode='auto'}); eq(f:press('PAD1'),true); eq(#f.actions,2)
end)

test('I02 explicit focus, uniqueness, prune and no context', function()
    local f=fixture(); local other={}; f.e:Push(other); f.e:Push(f.ctx)
    eq(f.e:Top(),f.ctx); f:press('PAD1'); eq(f.actions[1].ctx,f.ctx); f:up('PAD1')
    f.e:Pop(f.ctx); eq(f.e:Top(),other)
    other.alive=function() return false end; f.e:Reconcile(); eq(f.e:Top(),nil)
    eq(f:press('PAD1'),false); eq(f.e:Reset(),0)
end)

test('I03 mapped/unbound overlap both orders', function()
    for _,reverse in ipairs({false,true}) do
        local f=fixture()
        if reverse then eq(f:press('PADBACK'),false) end
        eq(f:press('PAD1'),true)
        eq(f:press('PADBACK'),false); eq(f:up('PADBACK'),false)
        eq(f:press('PAD1'),true); eq(#f.actions,1)
        eq(f:up('PAD1'),true); eq(#f.releases,1)
    end
end)

test('I04 event and binding route share physical identity, rapid cycles', function()
    local f=fixture()
    for _,button in ipairs({'PAD1','PAD3','PAD4','PADFORWARD'}) do
        f:press(button); f:press(button,'binding'); f:step(2)
        f:up(button); f:up(button)
    end
    eq(#f.actions,4); eq(#f.releases,4)
    f:press('PADFORWARD'); f:up('PADFORWARD'); f:press('PADFORWARD'); f:up('PADFORWARD')
    eq(#f.actions,6)
end)

test('I06 precise direction repeat, no catch-up, release stops', function()
    local f=fixture(); f:press('PADDUP'); eq(#f.actions,1)
    f:step(.35); eq(#f.actions,1); f:step(.01); eq(#f.actions,2)
    f:step(.074); eq(#f.actions,2); f:step(.001); eq(#f.actions,3)
    f:step(3); eq(#f.actions,4); f:up('PADDUP'); f:step(1); eq(#f.actions,4)
end)

test('I07 newest direction wins, no resurrection, duplicate-action release identity', function()
    for _,keys in ipairs({{'PADDUP','PADDLEFT'},{'PADDLEFT','PADDUP'}}) do
        local f=fixture(); f:press(keys[1]); f:step(.1); f:press(keys[2]); f:step(.36)
        eq(#f.actions,3); eq(f.actions[3].action,keys[2]=='PADDUP' and 'up' or 'left')
        f:up(keys[2]); f:step(1); eq(#f.actions,3); f:up(keys[1])
    end
    local f=fixture(); f.e:Configure({map={PAD1='up',PAD2='up'}})
    f:press('PAD1'); f:press('PAD2'); f:up('PAD1'); f:step(.36)
    eq(#f.actions,3); eq(#f.releases,1); f:up('PAD2'); eq(#f.releases,2)
end)

local function polling(f)
    f.device=10; f.buttons={false,false}; f.indices={PAD1=0,PADDUP=1}
    local api={
        GetActiveDeviceID=function() return f.device end,
        GetDeviceMappedState=function() return f.malformed or {buttons=f.buttons} end,
        ButtonBindingToIndex=function(button) return f.indices[button] end,
    }
    setmetatable(api,{__index=function(_,k) error('unknown game API '..k) end})
    f.e:SetPolling(api,function(state,index) return state.buttons[index+1] end)
end

test('I04 polling-only, observation duplicate, binding plus polling', function()
    local f=fixture(); polling(f); f:step(0)
    f.buttons[1]=true; f:step(0); eq(#f.actions,1)
    f:press('PAD1'); f:press('PAD1','binding'); f:step(2); eq(#f.actions,1)
    f.buttons[1]=false; f:step(0); f:up('PAD1'); eq(#f.releases,1)
    f:press('PAD1','binding'); f.buttons[1]=true; f:step(0); eq(#f.actions,2)
end)

test('I05 unknown/malformed data, device changes, reconnect baseline', function()
    local f=fixture(); f.e:SetPolling(nil); f:step(0)
    polling(f); f.buttons[1]=true; f:step(0); eq(#f.actions,0)
    f.buttons[1]=false; f:step(0); f.buttons[1]=true; f:step(0); eq(#f.actions,1)
    f.malformed={buttons='wrong'}; f:step(0); eq(#f.releases,0)
    f.malformed=nil; f:step(0); eq(#f.actions,1)
    f:boundary({hardware=false}); f:boundary({hardware=true}); f:step(0); eq(#f.actions,1)
    f.buttons[1]=false; f:step(0); f.device=11; f.buttons[1]=true; f:step(0); eq(#f.actions,1)
    f.buttons[1]=false; f:step(0); f.buttons[1]=true; f:step(0); eq(#f.actions,2)
    f.e:SetPolling({GetActiveDeviceID=function() error('unavailable') end}); f:step(0)
end)

test('I08 held focus/remap/unbind/backend quarantine and original release', function()
    for _,change in ipairs({
        function(f) f.e:Configure({map={PAD1='close'}}) end,
        function(f) f.e:Configure({map={PAD1=false}}) end,
        function(f) f.e:SetBackend('bindings') end,
        function(f) f.e:Push({}) end,
        function(f) f.e:Yield(true) end,
    }) do
        local f=fixture(); f:press('PAD1'); change(f); f:press('PAD1'); f:step(1)
        eq(#f.actions,1); eq(#f.releases,1); eq(f.releases[1].action,'use')
        f:up('PAD1'); eq(#f.releases,1)
    end
    local f=fixture(); eq(f.e:SetBackend('invalid'),false); eq(f.e.config.backend,'catcher')
end)

test('I09 text routes back only, fresh ordinary input after exit', function()
    local f=fixture(); f.e:Yield(true)
    eq(f:press('PAD1'),false); eq(f:press('PADDUP'),false)
    eq(f:press('PAD2'),true); eq(#f.actions,1); eq(f.actions[1].action,'close')
    f.e:Yield(false); f:press('PAD1'); eq(#f.actions,1)
    f:up('PAD1'); f:press('PAD1'); eq(#f.actions,2)
end)

test('I10 native return only, bags closed and explicit focus survives reconcile', function()
    for _,kind in ipairs({'merchant','bank','guildbank','mail','trade','auction','crafting'}) do
        local f=fixture(); f.e:Pop(f.ctx)
        local hops={}; f.host.switch=function(target) hops[#hops+1]=target end
        f.e:Visit({kind=kind,allowed=true,keep=true})
        eq(f:press('PAD1'),false); eq(f:press('PADDUP'),false)
        f:press('PADFORWARD'); eq(#hops,1); eq(hops[1],'bags'); f:up('PADFORWARD')
        f.e:Push(f.ctx); f.e:Reconcile(); eq(f.e:Active(),true)
        f:press('PADFORWARD'); f:up('PADFORWARD'); eq(hops[2],'native')
        f:press('PADFORWARD'); f:up('PADFORWARD'); eq(hops[3],'bags')
        f.e:Reconcile(); eq(f.e:Active(),true)
        f.e:Visit(nil); f.e:Pop(f.ctx); eq(f:press('PADFORWARD'),false)
    end
end)

test('I11 combat stops repeats even without cached env update, logical teardown', function()
    local f=fixture(); f:press('PADDUP'); local before=#f.writes
    f.combat=true; f:step(1); eq(#f.actions,1); eq(#f.writes,before)
    eq(f.e.bound,false); eq(f.suspends,1); eq(#f.releases,1)
    f.e:Yield(true); eq(f.e:Reset(),1); eq(f.e:Top(),nil)
    f.combat=false; f:boundary({combat=false}); eq(f.e.env.text,false)
    f.e:Push(f.ctx); f:press('PADDUP'); eq(#f.actions,1)
    f:up('PADDUP'); f:press('PADDUP'); eq(#f.actions,2)
end)

test('I12 engine close reservation description only; host secure close outside engine', function()
    local f=fixture(); f.e:Configure({map={PAD1='close',PAD2='close',PAD3='use'}})
    local buttons,ctx=f.e:CloseCandidates(); eq(#buttons,2); eq(ctx,f.ctx)
    eq(buttons[1],'PAD1'); eq(buttons[2],'PAD2')
    f.e:Configure({map={PAD1='use',PAD2='close'}}); buttons=f.e:CloseCandidates(); eq(#buttons,1)
    f:boundary({combat=true}); eq(f.e:CloseCandidates(),nil)
    -- Simulate only the notification after a separately secured close, not its execution.
    f.e:Pop(f.ctx); eq(f.e.bound,false); eq(f.e:Top(),nil)
    f:boundary({combat=false}); eq(f.e:CloseCandidates(),nil)
end)

test('I14 contextual requests delegate once, unsafe variants never request sale', function()
    local f=fixture(); local requests={}
    f.host.policy=function(intent,ctx,meta) requests[#requests+1]={intent,ctx,meta} end
    f:boundary({merchantBag=true}); f:press('PAD3'); f:press('PAD3','binding'); f:up('PAD3')
    eq(#requests,1); eq(requests[1][1],'junkSale')
    for _,field in ipairs({'sizing','topControls','heldItem','text','combat'}) do
        f:boundary({[field]=true}); f:press('PAD3'); f:up('PAD3'); f:boundary({[field]=false})
    end
    eq(#requests,1)
    f:boundary({merchantBag=false,destination='bank'}); f:press('PAD4'); f:up('PAD4')
    eq(#requests,2); eq(requests[2][1],'quickTransfer')
end)

test('release callback reentry cannot release same press twice', function()
    local f=fixture(); local n=0
    f.host.release=function() n=n+1; assert(n<3,'recursive release'); f.e:Reset() end
    f:press('PAD1'); f:up('PAD1'); eq(n,1)
end)

test('propagation is selective per direct event, never written by polling', function()
    local f=fixture(); polling(f); f:step(0)
    local n=#f.writes; f:step(0); eq(#f.writes,n)
    f:press('PAD1'); eq(f.writes[#f.writes][2],false)
    f:press('PADBACK'); eq(f.writes[#f.writes][2],true)
    f:press('PAD1'); eq(f.writes[#f.writes][2],false)
    f.e:Configure({map={PAD1=false}}); eq(f.writes[#f.writes][2],true)
end)

test('unknown polls stop repeat without inventing physical release', function()
    local f=fixture(); polling(f); f:step(0); f.buttons[2]=true; f:step(0)
    eq(#f.actions,1); f.indices.PADDUP=nil; f:step(.5)
    eq(#f.actions,1); eq(#f.releases,0)
    f.indices.PADDUP=1; f:step(1); eq(#f.actions,1)
end)

test('one-shot dispatch has no repeat; StopRepeat does not revive held input', function()
    local f=fixture(); eq(f.e:Dispatch('up'),true); f:step(1); eq(#f.actions,1)
    f:press('PADDUP'); f.e:StopRepeat(); f:step(1); eq(#f.actions,2)
    f:up('PADDUP'); f:press('PADDUP'); f:step(.36); eq(#f.actions,4)
end)

test('I01 every supported key retains synthetic world route when ineligible', function()
    local keys={'PADDUP','PADDDOWN','PADDLEFT','PADDRIGHT','PADLSTICKUP','PADLSTICKDOWN','PADLSTICKLEFT','PADLSTICKRIGHT',
        'PAD1','PAD2','PAD3','PAD4','PADLSHOULDER','PADRSHOULDER','PADLTRIGGER','PADRTRIGGER','PADLSTICK','PADRSTICK','PADBACK','PADFORWARD'}
    for _,condition in ipairs({'off','none','invalid','foreign','hardware'}) do
        local f=fixture(); local world=0
        if condition=='off' then f.e:Configure({mode='off'})
        elseif condition=='none' then f.e:Pop(f.ctx)
        elseif condition=='invalid' then f.ctx.alive=function() return false end
        elseif condition=='foreign' then f:boundary({winner=false})
        else f:boundary({hardware=false}) end
        for _,k in ipairs(keys) do if not f:press(k) then world=world+1 end; f:up(k) end
        eq(world,#keys); eq(#f.actions,0)
    end
end)

test('I05 absent functions, nil state, malformed index and boolean are unknown', function()
    for _,variant in ipairs({'absent','nil','badindex','badboolean','throws'}) do
        local f=fixture(); local state={buttons={false}}
        local api={GetActiveDeviceID=function() return 4 end,
            GetDeviceMappedState=function() return state end,
            ButtonBindingToIndex=function() return 0 end}
        if variant=='absent' then api.GetDeviceMappedState=nil
        elseif variant=='nil' then api.GetDeviceMappedState=function() return nil end
        elseif variant=='badindex' then api.ButtonBindingToIndex=function() return -1 end
        elseif variant=='badboolean' then state.buttons[1]=1
        else api.GetDeviceMappedState=function() error('device unavailable') end end
        f.e:SetPolling(api,function(s,i) return s.buttons[i+1] end)
        f:step(0); f:step(1); eq(#f.actions,0); eq(#f.releases,0)
    end
end)

test('return route works under bindings and never captures native non-switch', function()
    local f=fixture(); f.e:SetBackend('bindings'); eq(f.e.receiving,false)
    f.e:Visit({allowed=true,keep=true}); eq(f.e.receiving,true)
    local hops=0; f.host.switch=function() hops=hops+1 end
    eq(f:press('PAD2'),false); eq(f:press('PADFORWARD'),true); eq(hops,1)
    f:up('PADFORWARD'); f.e:Visit({allowed=false,keep=true}); f.e:Pop(f.ctx)
    eq(f.e.receiving,false); eq(f:press('PADFORWARD'),false)
end)

test('stick policy, no superseded revival when older release occurs', function()
    local f=fixture(); f.e:Configure({stickNav=false}); eq(f:press('PADLSTICKUP'),false)
    f:up('PADLSTICKUP'); f.e:Configure({stickNav=true}); eq(f:press('PADLSTICKUP'),true)
    f:press('PADDRIGHT'); f:up('PADLSTICKUP'); f:step(.36)
    eq(#f.actions,3); eq(f.actions[3].action,'right')
end)

test('device-only event path requires fresh up after reconnect or device change', function()
    local f=fixture(); f:boundary({device=1}); f:press('PAD1'); f:up('PAD1')
    f:boundary({device=2}); eq(f:press('PAD1'),false); eq(#f.actions,1)
    f:up('PAD1'); f:press('PAD1'); eq(#f.actions,2); f:up('PAD1')
    f:boundary({hardware=false}); f:boundary({hardware=true}); eq(f:press('PAD1'),false)
    f:up('PAD1'); f:press('PAD1'); eq(#f.actions,3)
end)

test('native handoff without return opt-in must not capture retained contexts', function()
    for _,visit in ipairs({{allowed=false,keep=true},{allowed=true,keep=false}}) do
        local f=fixture(); f.e:Visit(visit)
        eq(f.e.bound,false); eq(f:press('PAD1'),false); eq(f:press('PADFORWARD'),false)
        f.e:FocusBags(); f:up('PAD1'); eq(f:press('PAD1'),true)
    end
end)

test('ambient observation of same native visit preserves explicit bags choice', function()
    local f=fixture(); local id={}
    f.e:Visit({id=id,kind='bank',allowed=true,keep=true})
    f:press('PADFORWARD'); f:up('PADFORWARD'); eq(f.e:Active(),true)
    f.e:Visit({id=id,kind='bank',allowed=true,keep=true}); eq(f.e:Active(),true)
    f.e:FocusNative(); eq(f.e:Active(),false)
end)

local function run()
    for _,entry in ipairs(tests) do
        local ok,err=pcall(entry[2]); if not ok then error('FAIL '..entry[1]..': '..err,0) end
        count=count+1; print('PASS '..entry[1])
    end
    print(count..' fixtures passed; in-game checks are listed in docs/LIVE-CHECKS.md')
end
run()
