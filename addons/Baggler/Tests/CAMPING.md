# Camping section

`CampingData.lua` is a list of item IDs that belong in the Camping section. It loads before `Categories.lua` and adds no game API calls, crafting features or settings.

## Item list and sources

The list was collected on 2026-11-14 for World of Warcraft: Forever. Each ID can be looked up at `https://forever.warcraftdb.com/data/item/<ID>`, and coverage was cross-checked against the [Forever camping guide](https://wow-professions.com/forever/camping-guide) and Blizzard's [camping announcement](https://news.blizzard.com/en-us/article/24301516/gather-around-the-campfire-in-world-of-warcraft-forever).

It contains **76 unique item IDs**: 39 crafted camp items, 26 blueprints, four firemaking supplies, six camping-only reagents and the Scarlet Banner. The 57 materials and two profession tools that other crafts also use are left out, so they stay in their usual sections. The basic kit item (279981) is an item, unlike the craft spell 1229737 and the old fire spell 818, which are not in the list.

Only item IDs and names are used; no guide text is copied.

## Behavior

Camping sorts after Consumables and before Reagents/Trade Goods (order 56) and can be chosen as a destination in the item menu. It applies after the special-item rules, manual pins, favorites, New, custom sections, grey junk, equipment sets and quest items, and only when grouping by category. Marking an item as junk still works for camping items, and pinning to Junk still wins. Items are matched by ID only, never by English name.

## Tests

```sh
timeout 60 luajit addons/Baggler/Tests/camping_test.lua
```

It also runs as part of `tools/baggler test`. It loads the shipping TOC and checks every listed ID, uncached and localized items, the excluded shared materials, precedence of manual/custom/favorite/New/quest/junk/set rules, other grouping modes, bag and bank scans, search, folding and pin-to-top. The packaging tests check that `CampingData.lua` ships and loads once, before `Categories.lua`.
