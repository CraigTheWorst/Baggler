# Accent palette

Choose the accent colour under **Settings → Look → Accent colour**. It colours
Baggler's headers, highlights, menus and focus borders; the game's own windows
are not recoloured.

## Choices

There are **46 options**:
- **My class** (`class`), the default for a fresh/missing accent.
- **15 explicit class colours** (`class_<lowercase class token>`): Warrior,
  Paladin, Hunter, Rogue, Priest, Death Knight, Shaman, Mage, Warlock, Monk,
  Druid, Demon Hunter, Evoker, Adventurer and Traveler. Display names use the
  client's localized class-name table where present; readable English otherwise.
- **6 legacy presets**, keeping their keys and RGBs: Ice, Violet, Emerald,
  Amber, Rose and Monochrome (`mono`).
- **24 new presets**: Coral, Salmon, Peach, Apricot, Copper, Gold, Lemon,
  Chartreuse, Lime, Sage, Mint, Seafoam, Teal, Turquoise, Aqua, Sky, Azure,
  Periwinkle, Lavender, Lilac, Orchid, Mauve, Pink and Ruby.

Earlier builds saved Ice as the default and didn't record whether it was
chosen on purpose, so an existing Ice setting (like every other saved choice)
is kept. Pick **My class** to follow your character's class colour. New
installs start with My class. Saved and shared values are names such as
`class_mage` or `teal`; unknown or numeric values in a share code are refused.

## API reference

Checked against Blizzard's UI source (Forever 1.60.1.70938) at commit
`bebcb6bf309cf41b41bd74f8ca651e6a105b2676`:

- [ClassColorDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated/ClassColorDocumentation.lua):
  `C_ClassColor.GetClassColor(className)` returns an optional ColorMixin.
- [ClassColors.lua](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_SharedXML/ClassColors.lua):
  `RAID_CLASS_COLORS` is populated by that API for all fifteen tokens above,
  including Forever's Adventurer and Traveler.
- [Color.lua](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_SharedXMLBase/Color.lua):
  ColorMixin stores public `r`, `g`, `b` channels.

The live client API wins, then its raid-colour table; fixed RGBs are safe offline
fallbacks when unavailable. An unknown/missing player class uses Ice. Explicit
class choices never query player information. Only `UnitClass("player")`'s
class token is consumed for My class, with secret-value guards; no identity or
class data is added to logs or exports. Adventurer/Traveler fallback shades are
neutral placeholders only when the client's colours are unavailable.

## Tests

Run from the source root (it is also part of `tools/baggler test`):

```sh
timeout 60 luajit addons/Baggler/Tests/accent_palette_test.lua
```

The test loads the shipping TOC and checks fresh My class,
Mage/Warlock, all fifteen explicit API routes, API/raid/fixed fallback behavior,
localized labels, exact counts, unique named preset RGBs, at least 4.5:1 contrast
for the 24 extras against luminance 0.01, all option labels in the existing Look
selector, every saved/exported/imported key, legacy choice preservation and
unknown/numeric share rejection. Recorded paint calls cover already-open bags,
bank, settings header/underline/highlight, menu rows and shared focus borders,
including import; recoloring does not change current page or menu ownership.
Opaque class tokens, API color objects and channel values are also tested.

How the colours look in game is checked by hand; see
[LIVE-CHECKS.md](../../../docs/LIVE-CHECKS.md).
