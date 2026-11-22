# Aura error diagnostics

Some players have seen repeated errors from the game's own buff/debuff (aura) code. The cause hasn't been found. Baggler includes a read-only probe that records evidence if it happens again; it does not change the game's aura code.

## Where the game code was checked

Line references are to the Forever UI source at commit `9dc84f0d3bbae1768ac3405b3716000bd93eda06`:

- `Blizzard_BuffFrame/BuffFrame.lua:667–681`: aura tooltip processing runs before `AuraFrameEditModeMixin.Update`.
- `:974–1002`: `ShouldProcessTooltipQueue` reads `frame.auraType` on every frame under the mouse. A missing field can fall through to an addon frame's metatable. This shows a possible path, not that it actually causes the errors.
- `:1231–1240`, `:1271–1273`, `:1333–1357`: aura duration code installs a persistent OnUpdate, so one bad value can keep repeating without further Baggler activity.
- `Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua:1705–1753`: item button OnEnter calls OnUpdate, which updates the shared GameTooltip. Baggler forwards hover and drag events to these item buttons.

No Blizzard mixin or global is replaced. `securecallfunction` is not used as a workaround, because isolating a call doesn't clean already-tainted data and must not be used to get around protected actions.

## What the probe records

`Log.lua` checks with `issecurevariable` whether key fields are still secure: BuffFrame, DebuffFrame and ExternalDefensivesFrame, up to 64 aura buttons each, their `buttonInfo` fields (`expirationTime`, `auraInstanceID`, `timeMod`), aura callback slots, and GameTooltip/BuffFrameTooltip processing fields. It records the first insecure reading of each field and what was happening at the time.

Mouse-focus details include up to four frame names and the *type* of `auraType`, never its value. The probe never reads aura values, calls aura callbacks, wraps native functions or changes native frames. Item hover/drag forwarding is bracketed with before/after readings without changing what is forwarded. Snapshots are taken on player `UNIT_AURA` (at most once per second) and on entering/leaving combat; there is no continuous polling.

Evidence is capped at 48 rows per session and eight changes per snapshot, stored in `BagglerDB.auraWatch` so normal log traffic can't push it out. It is saved with your settings, so it can still be read in the report after logging out, but the next login or `/reload` starts a fresh session. `/baggler report` includes it. A clean result doesn't rule out short-lived taint between snapshots.

## Collecting evidence in game

1. `/reload` once, then keep the session short.
2. Open bags, move the mouse over an item, use the controller on an item as you normally would, then close bags with the controller.
3. Enter and leave one ordinary fight, ideally with a buff or debuff change. Note whether spells and controller input still work.
4. If the error appears, copy `/baggler report` (including the *native aura provenance* section) and the first BugSack error **before reloading**, since a reload starts a new evidence session.

## Tests

```sh
timeout 60 luajit addons/Baggler/Tests/aura_probe_test.lua
timeout 60 luajit addons/Baggler/Tests/native_item_boundary_test.lua
```

Both also run as part of `tools/baggler test`. They exercise the real probe and forwarding code with simulated security results; they can't reproduce the game's taint system.
