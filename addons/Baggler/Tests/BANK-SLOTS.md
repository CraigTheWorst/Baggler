# Bank bag slots

How Baggler's bank shows and handles bank bag slots, and the game code it follows.

## API reference

References are to Blizzard's UI source mirrored at Gethe/wow-ui-source commit **bebcb6bf309cf41b41bd74f8ca651e6a105b2676** (Forever 1.60.1.70938). Baggler targets client 1.60.1.71037; re-check these references when the client updates.

- [UIPanels TOC, lines 137–141](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_UIPanels_Game/Blizzard_UIPanels_Game.toc#L137-L141): Forever loads the Mainline bank templates plus its own (Camelot) bank frame, so the Vanilla bank API is not the right model.
- [Camelot BankFrame.lua, lines 136–191](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_UIPanels_Game/Camelot/BankFrame.lua#L136-L191): with player bags enabled, purchased bank tabs are **bag slots**. Purchased slot 1 is the built-in bank storage; slots 2 and up hold bags. They are not empty storage tabs.
- [Camelot BankFrame.lua, lines 312–395](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_UIPanels_Game/Camelot/BankFrame.lua#L312-L395): bag contents use `CharacterBankTab_N` / `AccountBankTab_N`, while the bag itself is equipped through `Characterbanktab` / `Accountbanktab` plus the slot number, using `C_Container.PickupContainerItem(bagID, slotID)`.
- [Camelot BankFrame.xml, lines 4–30](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_UIPanels_Game/Camelot/BankFrame.xml#L4-L30): empty-slot background, lock overlay, clicks and drag handling for bag slots.
- [Camelot BankFrame.lua, lines 41–52](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_UIPanels_Game/Camelot/BankFrame.lua#L41-L52): the purchase button is hidden at full capacity and when the account bank has no purchased slots.
- [Mainline BankFrameTemplates.xml, lines 513–521](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/BankFrameTemplates.xml#L513-L521): `BankPanelPurchaseButtonScriptTemplate` is documented for addon use with `overrideBankType`.
- [Mainline BankFrameTemplates.lua, lines 1324–1340](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/BankFrameTemplates.lua#L1324-L1340) and [Camelot BankFrame.lua, lines 1–22](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_UIPanels_Game/Camelot/BankFrame.lua#L1-L22): the purchase button opens the game's confirmation, which reads the current price and only buys on accept.
- [BankDocumentation.lua, lines 311–327 and 454–462](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated/BankDocumentation.lua#L311-L327): `PurchaseBankTab` restrictions, the `ShouldUsePlayerBagsInBank` switch, and the `tabCost`/`canAfford` values from `FetchNextPurchasableBankTabData`. No prices are hardcoded.

## Behavior

- Only unlocked bag slots are shown, with an empty-bag placeholder or the equipped bag's icon.
- Clicking an equipped bag shows its contents; clicking an empty slot doesn't change the view. Right-click, drag or the controller's pick-up action removes a bag; A equips a bag held on the cursor.
- The controller can reach every bag slot, the bank-type switch and the purchase button from the top row. **All** returns to the combined view.
- The purchase button keeps the game's own click script and additionally checks bank access, affordability and combat.
- When bank bags are not in use, the existing storage-tab UI (with tab rename/icon settings) is shown instead.
- Money updates refresh the price shown next to the purchase button without replacing it with your gold.

## Tests

```sh
luajit addons/Baggler/Tests/bags_only_test.lua
```

`bags_only_test.lua` (which includes `bank_restore_test.lua` and `bank_slots_test.lua`) also runs as part of `tools/baggler test`. With `BAGGLER_BANK_SOURCE` set to an extracted copy of the UI source above (the folder containing `Interface/`), `bank_native_contract_test.lua` additionally runs the game's own purchase button and confirmation code against Baggler's bank:

```sh
BAGGLER_BANK_SOURCE=/path/to/wow-ui-source luajit addons/Baggler/Tests/bags_only_test.lua
```

Server prices, protected-call permissions, controller focus in the real client, bag-swap rules and the final layout are checked in game.
