# InputSession: controller input policy

A standalone Lua 5.1 unit that decides what each controller press means. The
chunk returns `InputSession`; `addons/Baggler/InputSession.lua` wraps the same
code and publishes it on the Baggler namespace, and `InputHost.lua` connects it
to the game. It accesses no game globals, frames, bindings, SavedVariables or
item APIs and creates no input receivers.

The engine owns a record of physical presses, one repeat cursor, context
priority and the choice between Baggler and an open game window. The host owns
the actual input receiver, permissions, secure actions, the shared controller
binding lease and all UI policy.

Run the tests from this folder:

```sh
timeout 60 luajit tests.lua
```

The fixtures use a controlled clock and a fake host that rejects insecure
reception/propagation writes during simulated combat and throws on unknown API
access. A returned `false` is a *simulated* world-routing decision; real
propagation is checked in game ([LIVE-CHECKS.md](../../../../../docs/LIVE-CHECKS.md)).

## Host construction contract

```lua
local engine = InputSession.new(host)
engine:Configure({mode='auto', backend='catcher', stickNav=true, map=myMap})
engine:Environment({hardware=true, winner=true, combat=false})
engine:Push(context)
```

Host callbacks are plain functions, **not methods**. Provide nonthrowing callbacks
for every enabled integration feature. Missing optional sinks are safe no-ops,
not fallback authorization to execute an action elsewhere. No callback is allowed
to mutate the engine's internal tables. Reentrant focus changes from dispatch are
supported; release callbacks must remain logical bookkeeping. Callback exceptions
are integration errors, not something the engine retries.

| Callback | Contract |
| --- | --- |
| `clock()` | Required monotonic seconds, normally the host's game-time clock. |
| `combat()` | Live Boolean lockdown read. Always provide it; cached environment combat is an additional fail-closed guard, not a substitute. |
| `dispatch(context, action, meta)` | Sole ordinary logical-action sink; normally delegates once to `context:OnPad(action)`. Must enforce existing secure-use policy. Never execute protected use/pickup/sale/transfer from polling or insecure code. |
| `release(context, action, meta)` | One logical end notification per delivered physical action, including boundary cancellation; never executes a gameplay action, restricted teardown, or a foreign broker rebind. |
| `reception(enabled)` | Out-of-combat-only request to arm/disarm the host-owned **unprotected** direct receiver. Host guarantees success or reports an integration error. No receiver creation is prescribed. |
| `propagate(boolean)` | Out-of-combat-only propagation request for that receiver. True passes input. See per-event semantics below. Must not change any other claimant's receiver. |
| `suspend()` | Safe combat-time relinquishment of this host's unprotected reception, e.g. a previously verified unprotected hide path. **No** EnableGamePadButton, SetPropagateKeyboardInput, binding, secure-attribute, or broker writes, directly or through listeners. Host must prove the chosen hide path is permitted. |
| `ownership(boolean)` | Pure logical notification after `bound` changes; host emits `PAD_STATE`. May occur in combat. Cannot invoke restricted broker cleanup or other claimants. |
| `switch(target, visit, meta)` | `target` is `bags` or `native`. Host opens/selects bags or hands off the ordinary context, once. Never insecurely closes a protected native window. Updates visible contexts through Push/Pop. Host retains native auction secure actions separately. |
| `policy(intent, context, meta)` | `junkSale` or `quickTransfer`: call the *existing* host policy once, not a second mutation implementation. `meta.destination` is the host's already-selected destination for transfer. Polling metadata is not hardware authorization. |

`meta.id` identifies a logical press instance; `button` is its physical binding
token, absent for one-shots; `source` is `event`, `poll`, `binding`, or an explicit
one-shot diagnostic source. Releases additionally carry `reason`. Repeat requests
carry the original press ID and source. Only directional actions repeat, so no
repeat phase is needed to distinguish irreversible commands. A boundary can end
an action before its physical release. That later release does not release it
again or consult its new mapping.

### Ownership and environment

`Environment(patch)` merges supplied fields. Supply explicit false to clear a
Boolean; Lua nil cannot be a patch entry. `destination=false` clears a destination.
Any effective environment change cancels held actions and quarantines observations
until their physical up. Do not put continually changing diagnostics in this patch.

- `hardware`: authoritative hardware-enabled eligibility (host may use documented
  `C_GamePad.IsEnabled`). `on` does not override false; `auto` requires true too.
- `winner`: true only while the **existing shared broker** has granted this host
  the appropriate current lease. Not a request to compete for a lease. Host is
  responsible for successful binding installation before declaring binding-mode
  ownership. Foreign/unknown ownership is false.
- `combat`: update from enter/exit combat events. `combat()` remains live as well.
- `device`: optional authoritative identity for an event-only host. A change from
  an established identity, or hardware false -> true, quarantines all configured
  physical tokens until a known up. Thus reconnect may deliberately require a
  release/repress instead of acting on a device's initial held state.
- `text`: text-entry focus; `Yield(boolean)` is the shorthand. Only mapped `close`
  can dispatch; arrows and all ordinary mappings pass through. The close consumer
  owns leaving text mode and calling Yield(false).
- `merchantBag`: host asserts normal merchant bag focus, not merely merchant open.
  `filter` requests junk sale only if this is true and `sizing`, `topControls`, and
  `heldItem` are false. Text/native/combat gates apply first.
- `destination`: false, or host-authorized bank/guild-bank/mail/trade destination
  selected by the retained transfer policy. `favorite` requests quick transfer.
  The engine does not discover destinations or decide what items to move.

Combat reconciliation stops repeats and logically releases ownership even if the
host forgot to update cached combat but `combat()` reports true. It clears text /
native handoff/visit state; fresh native discovery is required after combat.
Contexts remain registered unless popped/pruned/reset. If a window closes by
another path, host must Pop it or give it a reliable `alive` callback.
Restricted disarm/propagation requests defer until out of combat; safe `suspend`
must return reception to the world immediately. All listener behavior is part of
that host obligation, not proven by the fake host.

## Engine methods

- `Configure(patch)`: replace supplied config fields. Config is a host-validated
  controller profile; this is not the settings schema validator. `map`, when
  supplied, is copied and **replaces** the entire map (not a partial import merge).
  False entries remain unbound. Direction tokens are `PADDUP`, `PADDDOWN`,
  `PADDLEFT`, `PADDRIGHT`; `PADLSTICKUP/DOWN/LEFT/RIGHT` require stickNav. No raw-axis
  threshold or third-party mapping table is invented. Returns false for an invalid
  backend before changing state, true otherwise.
- `SetBackend(name)`: accepts `bindings` or `catcher`, rejects anything else without
  changing config. A change ends all holds and reconciles reception. Host must
  atomically retire the previous binding route under its retained secure engine.
- `Enabled()`: mode/hardware eligibility. `Active()`: ordinary context eligibility
  including broker/combat/native selection. `bound` is policy ownership under the
  host's already-granted lease, including a native-return-only lease; `receiving`
  reflects direct reception requests, not a binding stack. Neither proves actual
  client capture if the host fails its callback contract.
- `Push(context)`, `Pop(context)`, `Top()`: most recently explicitly pushed context
  wins; duplicate registration is removed. Optional `context:alive()` false or
  error prunes that context on Reconcile, Observe, or Tick. Host dispatch adapts
  existing `context:OnPad(action)`. These methods never call directUse/secureCommand.
- `Reconcile()`: prune, honor current selection/lease and update reception. Safe
  from ambient checks: no gameplay action is executed. Reasons can be accepted by
  the host's adapter as diagnostics; they are not executable commands here.
- `Observe(button, down, source)`: Boolean **physical** observation. Use the same
  token for direct, retained-binding and polling routes. Defaults source to event.
  True on down means eligible mapped input was accepted (duplicates remain accepted
  without dispatching again). On up it means a still-active logical press ended;
  cancelled/quarantined/unowned ups return false. Invalid observations return false.
  One ledger record survives until up, including for unbound input. Only event
  source requests per-event propagation. Binding source is observational: the host
  secure route must not execute the same mutation in parallel with dispatch.
- `Dispatch(action, source)`: explicitly independent one-shot, with immediate
  logical release. No held repeat. Never use this to mirror an already-observed
  physical binding: it has no physical identity and cannot deduplicate that route.
- `StopRepeat()`: stop the current stream without reviving any older direction.
- `Tick()`: optional poll plus at most one due directional repeat. First repeat
  at 0.36s, later repeats 0.075s after the last delivered repeat. No catch-up loop.
- `Reset()`: return number of contexts removed; clear contexts, text/native visit
  state and release all actions. Physical down records stay quarantined until up,
  intentionally preventing reset -> stale-held replay. Restricted cleanup can wait.
- `CloseCandidates()`: out-of-combat description only: sorted current configured
  close tokens plus context, or nil without ordinary eligibility. Host uses this
  to configure its separately supported secure close path *before combat*. This
  does not arm, execute, reserve, rearm, or promise a combat-close capability.

### Direct propagation and release

The host feeds an event synchronously, while its handler may still select
propagation. Eligible mapped down (including a duplicate down) requests false;
unbound/ineligible down and releases request true. Propagation is a **per-event**
decision, not a global claim that every key is held by the addon. An unrelated
release passes through but does not erase a mapped press or repeat; the next mapped
event requests suppression again. Never implement this by globally swallowing all
keys while any mapped key is held. Boundary cleanup requests true out of combat.
Poll observations never issue per-event propagation writes or claim to consume
already-delivered world input. Actual gamepad propagation semantics and handler
priority must be measured live. A receiver whose API cannot selectively deliver
these decisions is an integration blocker, not permission to swallow all keys.

### Native visits and explicit return latch

`Visit(nil)` ends a visit. `Visit({id=stableVisitID, kind=diagnosticName,
allowed=boolean, keep=boolean})` registers the host's observed native window. First
registration selects native focus; only switchWindow can be intercepted when both
allowed and keep are true. Handoff without return opt-in captures nothing, even
with contexts retained underneath. Return reception works with either backend,
including bindings mode and zero bag contexts. Ordinary native keys always pass.

Use a unique stable id per opening; repeated same-id observations preserve explicit
bags selection. Without id, the supplied table itself is identity. Reconcile never
reselects native. `FocusNative()` represents an actual explicit native focus change;
`FocusBags()` represents an actual explicit bags focus change. Push alone only
registers/focuses the context priority, not a native handoff reversal. Host must
not call FocusNative from every ambient visibility check. Switching updates the
selection before invoking the host callback and quarantines the triggering press.

## Polling adapter and documented API access

`SetPolling(api, readButton)` installs or replaces the optional polling reader;
`SetPolling(nil)` removes it. Supply a plain table containing only read functions:

- `GetActiveDeviceID()` -> numeric identity
- `GetDeviceMappedState(deviceID)` -> nil or mapped state with `buttons` table
- `ButtonBindingToIndex(bindingName)` -> nil or nonnegative integer index

These signatures and Boolean mapped buttons are documented in Blizzard's generated
[GamePadDocumentation.lua](https://raw.githubusercontent.com/Gethe/wow-ui-source/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated/GamePadDocumentation.lua).
The pinned document does **not** establish client-specific Lua array-index conversion
or virtual-stick availability. Therefore `readButton(state, documentedIndex)` is a
required explicit host adapter: return exactly Boolean only for a readable value,
otherwise nil. Verify the offset in the target client; the fixtures deliberately
choose zero-based API indices and one-based arrays. That is fixture data, not a
claim about every client. No guess is made when the adapter is absent.

First observation of a held button, and held input on device changes, is baseline
quarantine rather than a fresh press. A known false makes the next true eligible.
Missing functions, errors, missing/invalid indices, malformed state or non-Boolean
values are unknown: no speculative down, up or item action. Unknown polling data
stops the affected repeat, but does not manufacture a physical release. A later
valid held sample does not restart that stopped stream. Event-only operation needs
no polling API. Polling-only operation needs an initial up/baseline observation.
Direct events observed before a first valid poll retain their physical identity.
Simultaneous first-seen polling edges use sorted tokens for deterministic ordering;
real event order wins when available. Polling cannot infer a temporal order within
one snapshot or observe a full press/release between snapshots.

Feed coherent, current observations. There is no API sequence number here to
identify a stale/reordered snapshot contradicting a real event. Do not replay
queued old-device events or feed fabricated hardware presses. A logical-action-only
binding callback cannot safely participate in physical deduplication; host must
supply its physical token or route that action exclusively outside this engine.
Polling is an observation fallback, never a hardware-event/secure-permission source.
