-- Controller input policy; no globals, frames, secure actions or bindings.
local InputSession = {}
InputSession.__index = InputSession
local directions = {up=true, down=true, left=true, right=true}
local dpad = {PADDUP='up', PADDDOWN='down', PADDLEFT='left', PADDRIGHT='right'}
local stick = {PADLSTICKUP='up', PADLSTICKDOWN='down', PADLSTICKLEFT='left', PADLSTICKRIGHT='right'}

function InputSession.new(host)
    assert(type(host)=='table' and type(host.clock)=='function', 'clock required')
    return setmetatable({host=host, config={mode='off',backend='catcher',map={}},
        env={}, contexts={}, presses={}, serial=0, bound=false, receiving=false}, InputSession)
end

function InputSession:_call(name, ...)
    local f=rawget(self.host,name)
    if f then return f(...) end
end

function InputSession:_combat()
    return self.env.combat == true or self:_call('combat') == true
end

function InputSession:Enabled()
    return self.config.mode ~= 'off' and self.env.hardware == true
end

function InputSession:Top()
    return self.contexts[#self.contexts]
end

function InputSession:_route()
    if self:_combat() or not self:Enabled() or self.env.winner ~= true then return nil end
    if self.visit and self.nativeFocus then
        if self.visit.allowed and self.visit.keep then return 'native' end
        return nil
    end
    if self:Top() then return 'context',self:Top() end
    if self.visit and self.visit.allowed and self.visit.keep then return 'native' end
end

function InputSession:Active()
    return self:_route() == 'context'
end

function InputSession:_finish(p, reason)
    local action=p.action
    p.action=nil
    if self.repeatPress == p then self.repeatPress=nil end
    if action then
        self:_call('release',p.context,action,{id=p.id,button=p.button,source=p.source,reason=reason})
    end
end

function InputSession:_barrier(reason)
    self.repeatPress=nil
    for _,p in pairs(self.presses) do
        self:_finish(p,reason)
        p.blocked=true
    end
    self.pollSeen={}
    if not self:_combat() then self:_call('propagate',true) end
end

function InputSession:Configure(patch)
    patch=patch or {}
    if patch.backend and patch.backend ~= 'bindings' and patch.backend ~= 'catcher' then return false end
    self:_barrier('configuration')
    for k,v in pairs(patch) do
        if k=='map' then
            local copy={}; for button,action in pairs(v) do copy[button]=action end
            self.config.map=copy
        else self.config[k]=v end
    end
    self:Reconcile()
    return true
end

function InputSession:SetBackend(name)
    if name ~= 'bindings' and name ~= 'catcher' then return false end
    if self.config.backend==name then return true end
    return self:Configure({backend=name})
end

function InputSession:Environment(patch)
    local changed=false
    local newDevice=patch.device ~= nil and self.env.device ~= nil and patch.device ~= self.env.device
    local reconnect=patch.hardware==true and self.env.hardware==false
    for k,v in pairs(patch) do if self.env[k] ~= v then changed=true; self.env[k]=v end end
    if changed then self:_barrier('environment') end
    if newDevice or reconnect then
        local keys={}
        for k in pairs(self.config.map) do keys[k]=true end
        for k in pairs(dpad) do keys[k]=true end
        for k in pairs(stick) do keys[k]=true end
        for k in pairs(keys) do
            if not self.presses[k] then self.presses[k]={button=k,blocked=true} end
        end
    end
    self:Reconcile()
end

function InputSession:Push(context)
    assert(type(context)=='table','context must be a table')
    for i=#self.contexts,1,-1 do if self.contexts[i]==context then table.remove(self.contexts,i) end end
    local old=self:Top()
    self.contexts[#self.contexts+1]=context
    if old ~= context then self:_barrier('focus') end
    self:Reconcile()
end

function InputSession:Pop(context)
    local old=self:Top()
    for i=#self.contexts,1,-1 do if self.contexts[i]==context then table.remove(self.contexts,i) end end
    if old ~= self:Top() then self:_barrier('focus') end
    self:Reconcile()
end

function InputSession:Reconcile()
    local old=self:Top()
    for i=#self.contexts,1,-1 do
        local ctx=self.contexts[i]
        if ctx.alive then
            local ok,alive=pcall(ctx.alive,ctx)
            if not ok or not alive then table.remove(self.contexts,i) end
        end
    end
    if old ~= self:Top() then self:_barrier('invalid context') end
    local route,context=self:_route()
    if self.lastRoute ~= route or self.lastContext ~= context then
        self:_barrier('route')
        self.lastRoute=route; self.lastContext=context
    end
    if self:_combat() then
        self.env.text=false; self.nativeFocus=false; self.visit=nil
    end
    local owned=route ~= nil
    if owned ~= self.bound then self.bound=owned; self:_call('ownership',owned) end
    local receive=owned and (self.config.backend=='catcher' or route=='native')
    if self:_combat() then
        if self.receiving then self:_call('suspend'); self.receiving=false end
        self.dirty=true
        return
    end
    if self.receiving ~= receive or self.dirty then
        self:_call('reception',receive); self.receiving=receive
        self:_call('propagate',true); self.dirty=false
    end
end

function InputSession:Reset()
    local n=#self.contexts
    self:_barrier('reset'); self.contexts={}; self.env.text=false
    self.visit=nil; self.nativeFocus=false
    self:Reconcile()
    return n
end

function InputSession:Yield(value)
    self:Environment({text=value==true})
end

-- A visit is a host-authorized native-window route, never a frame reference.
function InputSession:Visit(visit)
    local id=visit and (visit.id or visit)
    local same=self.visit and visit and self.visit.id==id
    local unchanged=same and self.visit.kind==visit.kind
        and self.visit.allowed==(visit.allowed==true) and self.visit.keep==(visit.keep==true)
    if not unchanged then self:_barrier('native visit') end
    self.visit=visit and {id=id,kind=visit.kind,allowed=visit.allowed==true,keep=visit.keep==true} or nil
    if not same then self.nativeFocus=self.visit ~= nil end
    self:Reconcile()
end

function InputSession:FocusNative()
    if not self.nativeFocus then self:_barrier('explicit native focus') end
    self.nativeFocus=self.visit ~= nil
    self:Reconcile()
end

function InputSession:FocusBags()
    if self.nativeFocus then self:_barrier('explicit return') end
    self.nativeFocus=false
    self:Reconcile()
end

function InputSession:StopRepeat()
    self.repeatPress=nil
end

function InputSession:_action(button)
    return dpad[button] or (self.config.stickNav and stick[button]) or self.config.map[button]
end

function InputSession:CloseCandidates()
    local route,ctx=self:_route()
    if route~='context' then return nil end
    local buttons={}
    for button,action in pairs(self.config.map) do
        if action=='close' then buttons[#buttons+1]=button end
    end
    table.sort(buttons)
    return buttons,ctx
end

function InputSession:_deliver(p)
    local action=p.action
    local meta={id=p.id,button=p.button,source=p.source}
    if action=='switchWindow' and self.visit and self.visit.allowed then
        local target=p.route=='native' and 'bags' or 'native'
        self:_barrier('switch')
        self.nativeFocus=target=='native'
        self:_call('switch',target,self.visit,meta)
        self:Reconcile()
    elseif action=='filter' and self.env.merchantBag and not self.env.sizing
        and not self.env.topControls and not self.env.heldItem then
        self:_call('policy','junkSale',p.context,meta)
    elseif action=='favorite' and self.env.destination then
        meta.destination=self.env.destination
        self:_call('policy','quickTransfer',p.context,meta)
    else
        self:_call('dispatch',p.context,action,meta)
    end
end

function InputSession:_propagation(source, consumed)
    if source=='event' and not self:_combat() then self:_call('propagate',not consumed) end
end

function InputSession:Dispatch(action, source)
    self:Reconcile()
    local route,ctx=self:_route()
    if not route or type(action)~='string' or (self.env.text and action~='close')
        or (route=='native' and action~='switchWindow') then return false end
    self.serial=self.serial+1
    local p={id=self.serial,context=ctx,route=route,action=action,source=source or 'oneshot'}
    self:_deliver(p)
    self:_finish(p,'oneshot')
    return true
end

-- Event and retained-binding observations MUST use the same physical token.
function InputSession:Observe(button, down, source)
    self:Reconcile()
    if type(button) ~= 'string' or type(down) ~= 'boolean' then return false end
    source=source or 'event'
    local p=self.presses[button]
    if not down then
        local owned=p and p.action ~= nil or false
        if p then self:_finish(p,'up'); self.presses[button]=nil end
        self:_propagation(source,false)
        return owned
    end
    if p then
        self:_propagation(source,p.action ~= nil)
        return p.action ~= nil
    end
    self.serial=self.serial+1
    p={button=button,id=self.serial,source=source or 'event'}
    self.presses[button]=p
    local route,ctx=self:_route()
    local action=self:_action(button)
    local allowed=route and action and (route~='native' or action=='switchWindow')
        and (not self.env.text or action=='close')
    if allowed then
        p.action=action; p.context=ctx; p.route=route
        if directions[action] then
            self.repeatPress=p; p.nextAt=self.host.clock()+0.36
        end
        self:_deliver(p)
    end
    self:_propagation(source,allowed and self:_route()~=nil or false)
    return allowed and true or false
end

local function safe(api, name, ...)
    local f=api and rawget(api,name)
    if type(f)~='function' then return nil end
    local ok,result=pcall(f,...)
    if ok then return result end
end

function InputSession:SetPolling(api, readButton)
    self:_barrier('polling adapter')
    self.api=api; self.readButton=readButton; self.pollSeen={}; self.device=nil
end

function InputSession:_poll()
    if not self.api then return end
    local device=safe(self.api,'GetActiveDeviceID')
    local state=safe(self.api,'GetDeviceMappedState',device)
    if type(device)~='number' or device~=device or type(state)~='table' or type(state.buttons)~='table' then
        self:StopRepeat(); return
    end
    if self.device ~= device then
        if self.device ~= nil then self:_barrier('device') end
        self.device=device; self.pollSeen={}
    end
    local keys={}
    for k in pairs(self.config.map) do keys[k]=true end
    for k in pairs(dpad) do keys[k]=true end
    for k in pairs(stick) do keys[k]=true end
    for k in pairs(self.presses) do keys[k]=true end
    -- Sorted only to make simultaneous polling transitions deterministic.
    local ordered={}; for k in pairs(keys) do ordered[#ordered+1]=k end; table.sort(ordered)
    for _,button in ipairs(ordered) do
        local index=safe(self.api,'ButtonBindingToIndex',button)
        local down
        if type(index)=='number' and index>=0 and index%1==0 and self.readButton then
            local ok,value=pcall(self.readButton,state,index)
            if ok and type(value)=='boolean' then down=value end
        end
        if down ~= nil then
            if not self.pollSeen[button] and down and not self.presses[button] then
                self.presses[button]={button=button,blocked=true}
            end
            self.pollSeen[button]=true
            self:Observe(button,down,'poll')
        elseif self.repeatPress and self.repeatPress.button==button then self:StopRepeat() end
    end
end

function InputSession:Tick()
    self:Reconcile()
    self:_poll()
    local p=self.repeatPress
    local now=self.host.clock()
    if p and p.action and now+1e-9 >= p.nextAt then
        p.nextAt=now+0.075
        self:_deliver(p)
    end
end

return InputSession
