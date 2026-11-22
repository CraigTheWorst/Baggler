-- Baggler input host: connects InputSession to the game. This file owns client
-- permissions, the secure binding host and Baggler's UI policy; InputSession
-- only decides what each controller press means. Mapped reads use Blizzard's
-- generated GamePad API (wow-ui-source bebcb6bf309cf41b41bd74f8ca651e6a105b2676).
local _, CB = ...
local Pad, secure = CB.Pad, CB.Pad.secureHost
local engine, receiver
local bindingButtons, delegated = {}, {}
local navigation = {PADDUP='up',PADDDOWN='down',PADDLEFT='left',PADDRIGHT='right'}
local virtual = {PADLSTICKUP='up',PADLSTICKDOWN='down',PADLSTICKLEFT='left',PADLSTICKRIGHT='right'}
local appliedConfig
-- Delivery fences, not another action ledger: a hardware press accepted by
-- this host owns its matching UP even after a focus/text/context change.
local bindingDown, eventDown = {}, {}
local receptionWanted = false

local function propagate(value)
  if receiver and not Pad.InCombat() then receiver:SetPropagateKeyboardInput(value) end
end
local function discardDelivery()
  bindingDown={};eventDown={};receptionWanted=false
  if receiver then
    if not Pad.InCombat() then receiver:EnableGamePadButton(false) end
    receiver:Hide()
  end
end
function Pad:Receiver()
  if receiver then return receiver end
  if Pad.InCombat() then return nil end
  -- Unprotected, centered receiver with ordinary HIGH ordering. Geometry is not
  -- a compatibility dependency. Native delivery/priority needs a hardware pass.
  receiver = CreateFrame('Frame', nil, UIParent)
  receiver:SetSize(24,24)
  receiver:SetPoint('CENTER',UIParent,'CENTER',0,0)
  receiver:SetFrameStrata('HIGH')
  receiver:Hide()
  receiver:SetScript('OnGamePadButtonDown',function(_,token)
    Pad:UpdatePolicy()
    local held=eventDown[token]
    eventDown[token]=true
    local consumed=engine:Observe(token,true,'event')
    if not consumed and not held then eventDown[token]=nil end
    -- Focus can vanish inside the action (Close/Pop). The event's ownership
    -- decision still belongs to that press, not to the now-empty context stack.
    -- Propagation is only touched outside lockdown; the receiver may be hidden.
    if consumed or held then propagate(false) end
  end)
  receiver:SetScript('OnGamePadButtonUp',function(_,token)
    local consumed=eventDown[token]
    engine:Observe(token,false,'event')
    eventDown[token]=nil
    -- A logical cancellation inside the independent engine does not authorize
    -- this hardware release to execute the underlying TOGGLEGAMEMENU binding.
    propagate(not consumed)
    if not receptionWanted and not next(eventDown) and not Pad.InCombat() then
      receiver:EnableGamePadButton(false);receiver:Hide()
    end
  end)
  return receiver
end
local function notify(value)
  if Pad.bound~=value then Pad.bound=value; CB:Fire('PAD_STATE') end
end
local function deliver(context,action,meta)
  -- A poll is not a hardware authorization. Navigation and focus are safe data
  -- actions; mutations are never synthesized from a mapped-state observation.
  if meta.source=='poll' and action~='up' and action~='down' and action~='left' and action~='right' and action~='switchWindow' then return end
  if meta.button and delegated[meta.button] then return end -- secure route already owns this physical key
  Pad.lastAction,Pad.lastActionAt=action,GetTime()
  Pad.lastRepeat=meta.id==Pad.lastPressID
  Pad.lastPressID=meta.id
  if action=='switchWindow' then Pad.lastSwitch=GetTime(); Pad:SwitchWindow(); return end
  if context and context.OnPad then CB:Safe('pad:'..action,context.OnPad,context,action) end
end
engine = CB.InputSession.new({
  clock=GetTime, combat=Pad.InCombat,
  dispatch=deliver,
  release=function() end, -- bookkeeping is entirely inside the independent engine
  reception=function(enabled)
    receptionWanted=enabled
    local f = Pad:Receiver()
    if not f then return end
    local receive=enabled or next(eventDown)~=nil
    f:EnableGamePadButton(receive)
    if receive then f:Show() else f:Hide() end
  end,
  propagate=propagate,
  suspend=function() if receiver then receiver:Hide() end end,
  ownership=notify,
  switch=function(target)
    Pad.lastSwitch=GetTime()
    if target=='bags' then
      if Pad.holdGame and Pad.declinedGame then Pad.declinedGame[Pad.holdGame]=true end
      Pad.handedOff=false; Pad.holdGame=nil
      if CB.Window then
        if not CB.Window:IsOpen() then CB.Window:Open() else Pad:Push(CB.Window.ctx) end
        if CB.Window.SelectFirstIfNone then CB.Window:SelectFirstIfNone() end
      end
    else
      Pad:SwitchWindow()
    end
    Pad:Apply('native switch')
  end,
  policy=function(intent,context,meta)
    if meta.source=='poll' then return end
    if intent=='junkSale' then
      if CB.Integrations then CB.Integrations:SellJunk(true) end
    elseif intent=='quickTransfer' then deliver(context,'quickMove',meta) end
  end,
})
Pad.input=engine
Pad.stack=engine.contexts

-- Generated API tables describe mapped buttons as a Lua bool array and binding
-- indices as numeric. Require a count/range/type guard; unknown or
-- malformed samples remain nil. Zero-based API index -> Lua array position is
-- the client integration assumption to confirm live, not a hardware permission.
local api = C_GamePad
if api then
  engine:SetPolling({GetActiveDeviceID=api.GetActiveDeviceID,
    GetDeviceMappedState=api.GetDeviceMappedState,ButtonBindingToIndex=api.ButtonBindingToIndex},
    function(state,index)
      if type(state.buttonCount)~='number' or index>=state.buttonCount then return nil end
      if type(state.buttons[index+1])=='boolean' then return state.buttons[index+1] end
    end)
end
local function hardware()
  if not (C_GamePad and C_GamePad.IsEnabled) then return false end
  local ok,on=pcall(C_GamePad.IsEnabled)
  return ok and on==true
end
local function effectiveMap()
  local map={}
  for key,value in pairs(CB.db.pad.map) do map[key]=value end
  -- Start remains the game's menu key when there is nowhere to switch.
  if Pad.CanSwitch and not Pad:CanSwitch() and not engine.visit then
    for key,value in pairs(map) do if value=='switchWindow' then map[key]=false end end
  end
  return map
end
local function configuration()
  if not (CB.db and CB.db.pad) then return end
  local cfg=CB.db.pad
  local map=effectiveMap()
  local signature={tostring(cfg.mode),tostring(cfg.backend),tostring(cfg.stickNav)}
  local keys={}; for key in pairs(map) do keys[#keys+1]=key end;table.sort(keys)
  for _,key in ipairs(keys) do signature[#signature+1]=key..'='..tostring(map[key]) end
  signature=table.concat(signature,';')
  if signature~=appliedConfig then
    appliedConfig=signature
    engine:Configure({mode=cfg.mode or 'auto',backend=cfg.backend or 'bindings',stickNav=cfg.stickNav,map=map})
  end
end
function Pad:UpdatePolicy()
  if not CB.db then return end
  local W=CB.Window
  local merchant=Pad.JunkContext and Pad.JunkContext() or false
  local destination=Pad:QuickMoveOpen() and (CB.NativeWindows and CB.NativeWindows:Context() or 'transfer') or false
  local device
  if C_GamePad and C_GamePad.GetActiveDeviceID then
    local ok,id=pcall(C_GamePad.GetActiveDeviceID)
    if ok and type(id)=='number' and id==id then device=id end
  end
  engine:Environment({hardware=hardware(),combat=Pad.InCombat(),text=Pad.yield==true,device=device,
    merchantBag=merchant,sizing=W and W.sizing==true or false,
    topControls=W and W.chrome and true or false,heldItem=CursorHasItem and CursorHasItem() or false,
    destination=destination})
end
local function physicalButton(token)
  if bindingButtons[token] then return bindingButtons[token] end
  local b=CB.NewFrame('Button','BagglerInput_'..token,UIParent)
  b:RegisterForClicks('AnyDown','AnyUp')
  b:SetScript('OnClick',function(_,_,down)
    Pad:UpdatePolicy()
    -- A missing phase is unknown hardware state, not a fresh one-shot press.
    if type(down)~='boolean' then return end
    if down then
      local held=bindingDown[token]
      bindingDown[token]=true
      if not engine:Observe(token,true,'binding') and not held then bindingDown[token]=nil end
    else
      local held=bindingDown[token]
      engine:Observe(token,false,'binding')
      bindingDown[token]=nil
      if held then Pad:Apply('binding release') end
    end
  end)
  bindingButtons[token]=b
  return b
end
function Pad:InstallInput()
  if Pad.InCombat() then return end
  configuration()
  local binds={}
  delegated={}
  self.directArmed=false
  local native=self.handedOff or (engine.visit and engine.nativeFocus)
  local eligible=hardware() and CB.db.pad.mode~='off'
  if eligible and not native and CB.db.pad.backend~='catcher' then
    local map={}
    for k,a in pairs(navigation) do map[k]=a end
    if CB.db.pad.stickNav then for k,a in pairs(virtual) do map[k]=a end end
    for k,a in pairs(engine.config.map) do map[k]=a end
    local top=engine:Top()
    local useName
    if top and not self.yield and top.directUse then
      local rec=top.directUse()
      if rec and not rec.empty and rec.bag~=nil and rec.slot~=nil and self:WriteMacro(rec.bag,rec.slot) then
        local button=self:UseButton(); useName=button and button:GetName()
      end
    end
    self.directArmed=useName~=nil
    for token,action in pairs(map) do
      if action and top and (not self.yield or action=='close') then
        local command=not self.yield and top.secureCommand and top.secureCommand(action)
        if type(command)=='string' and command:match('^[%w_]+$') then
          binds[#binds+1]={token,command,true}; delegated[token]=true
        elseif action=='use' and useName then
          binds[#binds+1]={token,useName}; delegated[token]=true
        else binds[#binds+1]={token,physicalButton(token):GetName()} end
      end
    end
  elseif native and self.holdGame==rawget(_G,'AuctionHouseFrame') then
    -- Retained auction proxy secure actions are separate from return observation.
    self:SyncPostProxy()
    if self.postProxy and self.PostButtonNow() then binds[#binds+1]={'PAD4','BagglerPadPostAH'} end
    -- Pick proxy installation is owned by SyncPostProxy; it is never synthesized.
    if self.pickProxy and self.pickProxy:GetAttribute('clickbutton') then binds[#binds+1]={'PAD3','BagglerPadPickAH'} end
  end
  -- Keep held tokens on their original click target while focus changes
  -- reinstall the remaining map (e.g. bags' native close or text-only Back).
  if hardware() then
    for token in pairs(bindingDown) do
      for i=#binds,1,-1 do if binds[i][1]==token then table.remove(binds,i) end end
      delegated[token]=nil
      binds[#binds+1]={token,physicalButton(token):GetName()}
    end
  end
  local ok=secure.bind(binds)
  self.appliedBinds=ok and binds or nil
  self.installedInputContext=ok and engine:Top() or nil
  self.activeBackend=CB.db.pad.backend or 'bindings'
  self:UpdatePolicy()
  engine:Environment({winner=ok and eligible})
  secure.closeKeys(ok and eligible and not native and secure.closable(engine:Top()))
  self:PublishInputMap()
end
function Pad:PublishInputMap()
  -- Diagnostic compatibility only. No consumer drives another reception ledger.
  local map={}
  if engine.bound then
    if engine.visit and engine.nativeFocus then
      for k,a in pairs(engine.config.map) do if a=='switchWindow' then map[k]=a end end
    else
      if not self.yield then
        for k,a in pairs(navigation) do map[k]=a end
        if engine.config.stickNav then for k,a in pairs(virtual) do map[k]=a end end
      end
      for k,a in pairs(engine.config.map) do if a and (not self.yield or a=='close') then map[k]=a end end
    end
  end
  self.catchMap=map
end
Pad.catchMap={}
local function relinquish()
  engine:Environment({winner=false})
  Pad.directArmed=false;Pad.catchMap={};Pad.installedInputContext=nil
  if not Pad.InCombat() then secure.bind({});secure.closeKeys(false);Pad.appliedBinds=nil end
end
function Pad:Apply(reason)
  if not CB.db or self.applying then return end
  self.applying=true
  if not hardware() then discardDelivery() end
  self.stats.applies=self.stats.applies+1;self.stats.lastReason=reason or 'apply'
  self:UpdatePolicy();configuration()
  self.stack=engine.contexts
  if #self.stack==0 then self.yield=false;engine:Yield(false) end
  if Pad.InCombat() then
    discardDelivery()
    self.suspended=true;self.pending=true;self.directArmed=false
    self.handedOff=false;self.holdGame=nil;self.holdKeep=nil;self.watchExternal=nil
    engine:Reconcile();self:PublishInputMap();self.applying=false;return
  end
  self.suspended=false;self.pending=false
  local broker=secure.broker()
  broker:NoteHardware(hardware())
  if self.handedOff and not self.holdGame then engine:Visit(nil) end
  local wants=engine:Enabled() and (#self.stack>0 and not self.handedOff or engine.visit~=nil or next(bindingDown)~=nil)
  if wants then broker:Claim('Baggler',function() Pad:InstallInput() end,relinquish)
  else broker:Release('Baggler');relinquish() end
  engine:Environment({winner=broker:Winner()=='Baggler' and wants and (self.appliedBinds~=nil)})
  self:PublishInputMap();self.applying=false
end
function Pad:Enabled() return CB.db and CB.db.pad.mode~='off' and hardware() or false end
function Pad:Active() return engine:Active() end
function Pad:Top() return engine:Top() end
function Pad:Push(ctx)
  if CB.Card and self:Top()~=ctx then CB.Card:HideAll() end
  engine:Push(ctx)
  if self.holdGame and self.declinedGame then self.declinedGame[self.holdGame]=true end
  for _,g in ipairs(self.GAME_WINDOWS or {}) do
    local f=g.frame(); if self.frameVisible(f) then self.declinedGame[f]=true end
  end
  self.handedOff=false;self.holdGame=nil;engine:FocusBags()
  self.stack=engine.contexts;self:Apply('focus')
end
function Pad:Pop(ctx)
  engine:Pop(ctx);self.stack=engine.contexts
  if #self.stack==0 then self.yield=false;self.watchExternal=nil end
  self:Apply('pop')
  if Pad.InCombat() then self:JournalOwners('window closed in combat') end
end
function Pad:Prune()
  local n=#self.stack;engine:Reconcile();self.stack=engine.contexts;return n-#self.stack
end
function Pad:Reconcile(reason)
  if not CB.db then return end
  if not Pad.InCombat() then
    if self.AutoHoldCheck then self:AutoHoldCheck() end
    if self.handedOff and not self:GameNeedsPad() then self.handedOff=false;self.holdGame=nil;engine:Visit(nil) end
    if self.watchExternal and self:GameNeedsPad() then self:HandOff('external UI') end
    if self.yield and GetCurrentKeyBoardFocus and not GetCurrentKeyBoardFocus() then self.yield=false;engine:Yield(false) end
  end
  self:Apply(reason)
end
function Pad:Yield(value) self.yield=value==true;engine:Yield(self.yield);self:Apply('text') end
function Pad:SetBackend(name)
  if name~='catcher' and name~='bindings' then return false end
  CB.db.pad.backend=name;engine:SetBackend(name);self:Apply('backend');return true
end
function Pad:Press(action,down,source,physical)
  if #self.stack==0 and not Pad.InCombat() and self.AmbientCheck then self:AmbientCheck() end
  configuration();self:UpdatePolicy()
  if down==nil then return engine:Dispatch(action,source) end
  -- Legacy callers have only a logical action; infer a physical identity only
  -- when unique. Real direct/binding routes always supply their actual token.
  local token=physical
  if not token then
    for key,value in pairs(self.catchMap) do
      if value==action then if token then return false end;token=key end
    end
  end
  if token then return engine:Observe(token,down,source=='binding' and 'binding' or 'event') end
end
function Pad:Dispatch(action) configuration();self:UpdatePolicy();return engine:Dispatch(action) end
function Pad:StopRepeat() engine:StopRepeat() end
function Pad:Reset()
  discardDelivery()
  local n=engine:Reset();self.stack=engine.contexts
  self.yield=false;self.handedOff=false;self.holdGame=nil;self.watchExternal=nil
  self:Apply('reset');return n
end
function Pad.CatcherOn() if Pad.AmbientCheck then Pad:AmbientCheck() end;Pad:Reconcile('receiver') end
-- Read-only evidence for combat lockups: who owns each controller key at the edges of
-- combat. Only GetBindingAction is read; nothing is written, hooked or bound.
local watched={'PAD1','PAD2','PAD3','PAD4','PADLTRIGGER','PADRTRIGGER','PADLSHOULDER','PADRSHOULDER'}
function Pad:JournalOwners(why)
  if not (GetBindingAction and CB.Journal) then return end
  local parts={}
  for _,key in ipairs(watched) do
    local ok,act=pcall(GetBindingAction,key,true)
    parts[#parts+1]=key..'='..tostring(ok and act or '?')
  end
  CB:Journal('pad',('%s: stack=%d bound=%s receiver=%s | %s'):format(why,#engine.contexts,tostring(Pad.bound),
    tostring(receiver and receiver:IsShown() or false),table.concat(parts,' ')))
end
-- Read-only snapshot of the game's own controller focus (FrameControlsManager fields only; nothing is
-- called, set or hooked). While isUIFocused is true with native frames shown, the game's fall-through
-- catcher blocks the D-pad and face buttons by itself, whatever Baggler has bound.
function Pad:JournalNativeFocus(label)
  if not CB.Journal then return end
  local ok,line=pcall(function()
    local mode=rawget(_G,'GamepadMode')
    local mgr=mode and mode.FrameControlsManager
    if not mgr then return 'native focus: manager=nil' end
    local function nm(f)
      if f==nil then return 'nil' end
      return type(f)=='table' and f.GetName and f:GetName() or tostring(f)
    end
    local shown={}
    for _,f in ipairs(mgr.shownFrames or {}) do shown[#shown+1]=nm(f) end
    return ('native focus: edge=%s uiFocused=%s focused=%s suspended=%s catcher=%s shown=[%s]'):format(label,tostring(mgr.isUIFocused),
      nm(mgr.focusedFrame),nm(mgr.topSuspendedFrame),tostring(mgr.fallThroughCatcherActive),table.concat(shown,','))
  end)
  CB:Journal('pad',ok and line or ('native focus: probe error '..tostring(line)))
end
-- Logged BEFORE Apply so a failing Apply can never hide that the event arrived.
local function combatEdge(event,reason,label)
  CB:Journal('pad',('%s received: lockdown=%s affecting=%s state-combat=%s'):format(event,tostring(InCombatLockdown()),
    tostring(UnitAffectingCombat and UnitAffectingCombat('player')),tostring(Pad.secureHost.owner:GetAttribute('state-combat'))))
  Pad:JournalNativeFocus(label)
  local ok,err=pcall(Pad.Apply,Pad,reason)
  if not ok then CB:Journal('pad','Apply('..reason..') failed: '..tostring(err));CB:Error('pad',err) end
  Pad.applying=false -- an Apply that threw must not leave the host wedged
  Pad:JournalOwners(label)
end
CB:RegisterEvent('PLAYER_REGEN_DISABLED',function() combatEdge('PLAYER_REGEN_DISABLED','combat','combat start') end)
CB:RegisterEvent('PLAYER_REGEN_ENABLED',function() combatEdge('PLAYER_REGEN_ENABLED','regen','combat end') end)
CB:On('READY',function() Pad:Apply('ready') end)
CB:On('SETTING',function(key)
  if key=='import' or key=='pad' or tostring(key):match('^pad%.') then Pad:Apply('settings') end
end)
local ticker=CreateFrame('Frame')
ticker:SetScript('OnUpdate',function()
  if not CB.db then return end
  local previousTop,previousEnabled=engine:Top(),engine:Enabled()
  -- Apply refuses to write while Pad.InCombat() (lockdown OR affecting-combat). If regen's own Apply ran
  -- inside that gap, finish the deferred work as soon as both signals clear instead of waiting for a watchdog.
  if Pad.pending and not Pad.InCombat() then Pad:Apply('combat ended') end
  Pad:UpdatePolicy();engine:Tick();Pad.stack=engine.contexts
  -- Pruning/device loss changes logical ownership inside the engine. Drain the
  -- host lease too, even when the old watchdog would now see an empty stack.
  if previousTop~=engine:Top() or previousEnabled~=engine:Enabled()
      or (not Pad.InCombat() and Pad.installedInputContext~=nil
        and Pad.installedInputContext~=engine:Top()) then
    Pad:Apply('input eligibility changed')
  end
end)
