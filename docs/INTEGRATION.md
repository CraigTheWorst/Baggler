# Module overview

Developer notes on how Baggler's main modules fit together. Load order is defined by `addons/Baggler/Baggler.toc`.

## Standalone modules

Three modules are plain Lua 5.1 units with no game globals, frames or saved data. Each lives as a standalone file under `addons/Baggler/Tests/Independent/` with its own tests, and the copy in `addons/Baggler/` wraps the same code in a small loader envelope that publishes it on the Baggler namespace. `tests/test_packaging.py` checks that the two copies match.

| Module | Responsibility | Connected through |
|---|---|---|
| `InputSession.lua` | What each controller press means: press/release tracking, event and polling de-duplication, direction repeat, context priority, text-entry and combat handling, switching between Baggler and game windows | `InputHost.lua`, `GamepadWindows.lua` |
| `ProfileShare.lua` | Settings share codes (`BAGGLER2:`): schema, validation, limits, merge and canonical export. Older `BAGGLER1:` codes are refused with an "export it again" message | `Extras.lua` (`/baggler export`, `/baggler import`) |
| `EquippedCompare.lua` | Equipment slot resolution, comparison alternatives and stat deltas, upgrade checks | `ComparisonHost.lua`, `Card.lua`, `Inventory.lua` |

## Game-facing modules

- **`InputHost.lua` / `GamepadWindows.lua`** receive controller input from the game, find open game windows and pass both to InputSession. Polling is only used to observe button state; it never triggers item use, sales or transfers.
- **`Gamepad.lua`** owns secure bindings: the selected-slot use macro, the close binding prepared before combat, and the auction-house buttons. No bindings or secure attributes are changed during combat.
- **`ComparisonHost.lua`** reads equipped items and the game's tooltip comparison data (`C_TooltipComparison`) for EquippedCompare. If data is missing, no delta is shown rather than a guessed one.
- **`NativeWindows.lua`** watches the game's merchant, mail, trade, guild bank, loot and auction windows. Baggler never reskins, hides or moves them.
- **`Bank.lua`** is the one replaced game window: Baggler's personal/account bank. The game's own bank frame stays open but invisible during the visit.

## API references

API details come from Blizzard's UI source as mirrored at [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source) (commit `bebcb6bf309cf41b41bd74f8ca651e6a105b2676`), mainly `GamePadDocumentation.lua` and `TooltipComparisonDocumentation.lua`. Things the documentation doesn't settle, such as the array offset of mapped controller buttons, are handled by an explicit adapter in `InputHost.lua` and confirmed in game (see [LIVE-CHECKS.md](LIVE-CHECKS.md)).

## Combat limitation

The close binding for the controller's back button is prepared before combat and can be used once during combat. If the bags are closed another way, that reservation stays until one back press or the end of combat. Bags first opened *during* combat can't yet be closed with the controller's back button without risking blocked actions, so Escape is the fallback; see [DEVELOPMENT.md](DEVELOPMENT.md#tests) for the probe that covers this.
