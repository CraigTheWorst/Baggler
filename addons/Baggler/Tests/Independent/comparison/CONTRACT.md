# EquippedCompare: equipment comparison service

Standalone Lua 5.1 module: `EquippedCompare.lua` returns a module table without publishing any globals. `addons/Baggler/EquippedCompare.lua` wraps the same code for the addon, and `ComparisonHost.lua`, `Card.lua` and `Inventory.lua` connect it to the game. Inputs are plain acyclic tables. It accesses no UI, frames, timers, saved state, events, equip actions or game globals.

## Construction and methods

```lua
local service = EquippedCompare.new(host)
local slots = service:Slots(equipLoc, 'card') -- or 'upgrade'
local view = service:Compare(candidate, gates)
local upgrade = service:IsUpgrade(candidate) -- always Boolean
```

Candidate fields: `link`, `equipLoc`, optional `native={guid=...}` for native deltas; upgrade additionally needs finite `ilvl > 1`, `classID` 2 (weapon) or 4 (armor), numeric `quality > 1`, and `usable=true`. Other plain data fields pass to the host eligibility callback, including required level and armor subtype. Class IDs are Blizzard item-class data, not a copied character/class eligibility table.

Gates default enabled: `cardEnabled=false` suppresses all card intent (`primary=false`); `compareEnabled=false`, `noCompare=true`, or `candidate.noCompare` suppress comparison content only. Non-equipment yields no slots/alternatives/deltas. Primary card rendering and whether it can replace a tooltip remain the host's decision; `primary=true` is not a guarantee readable primary data exists.

Each result is fresh: `{candidate, primary, slots, alternatives, deltas, empty}`. Alternatives are `{slot, item}` records; delta entries are `{slot, lines={{text, sign}, ...}}`. `empty=true` means applicable slot(s) exist but no readable worn alternative exists: show an explicit empty comparison state, not an old card. Two actual equipped instances with identical item links are distinct alternatives; repeated client slot IDs are deduplicated. One readable alternative is never repeated to fill another card. No cache or deferred work exists in the service.

`sign` is `positive`, `negative`, or `neutral`. Only a leading explicit ASCII sign followed by digits (after ignoring native color escape codes for classification only) is classified. Original text, numeric spelling, localized words, and color escapes remain byte-for-byte unchanged. Unicode/unrecognized sign formats remain neutral rather than being reinterpreted.

## Host dependencies (plain functions, never colon methods)

- `getInventorySlotInfo(name) -> slotID|nil`: wrap Blizzard `GetInventorySlotInfo`. Names are documented uppercase inventory slot names. Do not substitute fixed numeric IDs. Unknown/unavailable slot families return nil or throw. Client-specific ranged applicability must be expressed here: a slot existing historically is not proof it is applicable on the current client.
- `readWorn(slotID) -> record|nil`: return `{link, ilvl?, native?}` for readable equipped items; `{empty=true}` **only for confirmed empty equipment slots**; nil for unavailable/unknown/loading data. Card display treats unavailable items as unreadable; upgrade logic does not treat them as empty. Read fresh equipment on every call.
- `eligible(candidate) -> true|false`: required for upgrade results. Retain host character/class/level/armor-family policy; true must mean required level met and armor family suitable. Missing callback, unknown data, false and errors fail closed. Candidate quality/usability and class/known-level checks are also enforced by the service.
- `nativeUpgrade(candidate) -> Boolean`: optional wrapper of the target client's native upgrade capability, with bag/slot identity carried in candidate fields as needed. **Set nil only if capability is absent.** Presence is authoritative: false, nil, error, or nonfunction values produce false, never item-level fallback. Native checks occur only after the eligibility/data gates above.
- `comparisonPlan(candidate, alternative, allAlternatives) -> {method, pairedItem?}|nil`: optional **normalized native-data adapter**. The host obtains current `C_TooltipComparison.GetItemComparisonInfo(candidate.native)` and interprets its result for the target build; do not guess a plan from item level. Return the documented method as its enum number 0–3 or name. `pairedItem` is a native `{guid=...}` descriptor, not a worn-record wrapper. For `WithBothHands`, provide the other *equipped* hand whose stats are subtracted; for either bag-hand method provide the native bag partner whose stats are added. Single discards pairing. The adapter must match the plan to the specific equipped alternative. It can return nil for a secondary presentation if the native plan only supports one aggregate comparison. Do not show two identical aggregate deltas unintentionally.
- `getItemComparisonDelta(comparisonItem, equippedItem, pairedItem, addPairedStats) -> string[]|nil`: can be Blizzard's documented data function directly. Single passes nil/nil; WithBothHands passes paired/false; WithBagMainHandItem and WithBagOffHandItem pass paired/true. Missing GUIDs/partner or unknown methods suppress delta generation. Data/API errors do not erase readable equipped content. No protected `CompareItem` call is used.

Callbacks receive snapshots for candidate/alternative/native data; they must be read-only data adapters. Callback errors are contained. Do not make equipment mutations from them. Host records should not contain frames/functions/cycles.

## Host responsibilities

- Preserve all primary card facts, action buttons, layout and existing public Card methods. Clear prior comparison cards/stat rows before rendering each result, including disabled/unavailable results; do not turn `empty=true` into fabricated item data.
- Public plain `Baggler.Inventory.IsGearUpgrade(bag, slot, equipLoc, classID, subID, link)` builds current candidate data and calls `service:IsUpgrade(candidate)`. Preserve scan-level unusable/poor-quality gating. Do not bind the public plain function as a colon method.
- Capture highlighted/hovered identity when scheduling a refresh; validate current identity and a visibility/generation token before and after data collection. Hide/selection/equipment change invalidates pending work. Never let a queued refresh call Show after Hide. The stateless service cannot reopen a card or cancel a host-owned timer.
- Generic one-hand cards resolve both hands, but generic one-hand upgrade fallback uses main hand only. Explicit off-hand, shields and holdables use off hand. Rings/trinkets may improve a known weaker alternative; equal level is false. A genuinely empty slot can qualify, an unreadable occupied item cannot establish measured improvement. There is no scoring formula.

## API references

- Blizzard's generated TooltipComparison documentation: https://raw.githubusercontent.com/Gethe/wow-ui-source/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated/TooltipComparisonDocumentation.lua
- https://warcraft.wiki.gg/wiki/API_GetInventorySlotInfo
- https://warcraft.wiki.gg/wiki/InventorySlotId
- https://warcraft.wiki.gg/wiki/API_C_TooltipComparison.GetItemComparisonInfo
- https://warcraft.wiki.gg/wiki/API_C_TooltipComparison.GetItemComparisonDelta

The generated documentation names `info.item` and `info.additionalItems` but doesn't explain their roles for each method, so this module takes an explicit normalized plan from the host instead of decoding those fields itself.

## Tests

Run `timeout 60 luajit test_comparison.lua` from this folder (also part of `tools/baggler test`). The tests load the real module in an environment that rejects unknown globals, client APIs and global writes. They cover slot families, duplicate slots, gates, all four comparison methods, localized lines, error paths, fresh snapshots, native upgrade results and the conservative fallback. Card rendering, the game's comparison data and live behavior are covered by `comparison_adapter_test.lua` and the in-game checks.
