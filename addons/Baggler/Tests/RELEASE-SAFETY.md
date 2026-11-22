# Share codes and junk selling: safety rules

The rules below are checked by `release_safety_test.lua`, which loads the
shipping TOC in the simulated client. Run it from the repository root:

```sh
luajit addons/Baggler/Tests/release_safety_test.lua
```

Pass `import`, `export` or `seller` to run one part only. A simulated pass can't
confirm the game's protected-call rules or a real sale.

## Settings paste policy

- Data-only `BAGGLER2:` grammar (strict JSON object subset, no `null`); no Lua
  evaluation. Require exactly one object, finite JSON numbers, unique keys, at
  most 200,000 input bytes, depth 8 and 25,000 parsed keys plus values. Older
  `BAGGLER1:` codes are refused with an "export it again" message.
- Validate all recognized supplied settings before writing any. One invalid
  recognized value rejects the entire paste without settings/dirty events.
- Scalar ranges follow Options.lua: scale 0.6–1.6, icons 28–52, spacing 0–10,
  columns 6–24, vendor columns 4–12, opacity 0.3–1, font scale 0.9–1.2.
  Pixel/count controls are integral. Low-space threshold accepts 0–200 free slots.
- Validate enum values, controller field names, mappable buttons and actions
  (including deliberate `false` unbindings). Partial controller settings merge
  into the existing valid controller profile; omitted fields are not erased.
- Favorites/junk/top pins require positive integral item IDs and boolean values;
  category pins require names; folds require names/booleans; saved searches require
  names/text. Dynamic maps replace in full, preserving the existing import model.
- Custom categories require a patterns table containing only a dense list of
  nonempty literal strings; optional order is integral 0–10,000. Unknown category
  fields are rejected. Limits: 200 categories, 100 patterns each, 200 bytes per
  pattern; other maps at most 5,000 entries. Names/searches have bounded lengths.
- Ignore unknown/private/old migration top-level keys for compatibility with old
  exports; never import them. Future legitimate settings require extending the
  explicit schema. Do not infer trust from current SavedVariables types.

## What export shares

Export only the recognized validated settings above and boolean defaults, not an
open-ended SavedVariables dump. Exclude journal/logs, character/account inventory
snapshots, positions/sizes, diagnostic flags, runtime data and migration debris.
Controller output has a nested allowlist. Invalid saved collections are omitted,
not partially reinterpreted. Favorites, categories and searches intentionally
remain shareable settings and may contain custom text: check a code
before sharing. Diagnostic reports are separate and are not anonymized.

## Paced junk seller policy

Preserve the existing explicit-junk policy: greys and deliberately marked items
are eligible, including marked high-quality/set items; favorites and no-value
items remain excluded. `manual` bypasses auto-sell opt-in, **not** safety checks.

Copy queue coordinates, identity/link and stack quantity. Before each use request,
require a currently visible native merchant and no combat; otherwise cancel.
Re-read the slot and skip missing/replaced/locked items, changed link variants,
new favorites, no-value items and items no longer junk. Never chase moved items.
Reject invalid or increased quantities; a decreased positive integral stack is
allowed, bounding the request by the original quantity. A new invocation cancels
the preceding queue, and merchant-close cancels as before.

The notification says **queued**, not **sold**; no gold or confirmed-sale totals
are inferred from scheduled requests. Same-ID/link replacements are not uniquely
identifiable through these slot fields; they must still satisfy current junk
eligibility and quantity bounds. Client/server outcomes remain asynchronous.
