# Usage

Open your bags with the game's normal bag key or `/baggler toggle`. `/baggler` (or View on a controller) opens settings. Click search and type; clear it to show everything again. Supported tokens include `q:epic`, `ilvl>400`, `t:armor`, `fav`, `junk`, `bound`, `!bound`, `new`, `loot`. These are inventory filters, not auction queries.

## Mouse / keyboard

Item buttons keep the game's normal click and modified-click behavior. **Alt-click an item** (out of combat, empty cursor) to open Baggler's item menu; controller Y opens the same menu. Plain right-click uses the item in context (which can **sell a whole stack at a merchant**). For an eligible merchant stack, plain left-click or Shift-right-click sells **one**; a single item retains normal left pickup/right sale. At a merchant, left-click doesn't always pick up, so check the labels before confirming. Drag and drop, or use Pick up / Place here, to move items. Other modified clicks follow your game key bindings.

Click a section title to fold/unfold; Shift-click folds/unfolds all to match. Right-click a section for its menu. Item menus offer favorite/category placement, pin-to-top and other applicable actions; custom categories/grouping and appearance are in settings. Your own choices override automatic sorting into sections. The Camping section holds camping supplies, blueprints and crafted camp items, not every shared crafting reagent.

Use the window's clean-up (sort) button or `/baggler sort` for carried bags. Sorting changes physical slots; section folding/filtering does not. The resize grip changes layout; locked windows must be unlocked in settings. Bank sort and deposit act on the selected bank type and tab.

## Controller defaults (Xbox labels)

**Settings navigation:** press Up from the first row of a page to reach the tabs, Down to return to the rows, and B to leave text entry or the current settings level. Icon-only buttons show a short label when they have controller focus. Choose **Accent colour** (including **My class**) on the Look tab; see [Accent palette](../addons/Baggler/docs/ACCENTS.md).

Button actions and button-label style can be changed in settings, and the on-screen hints follow your mapping. Keyboard and mouse keep working alongside the controller. The game's own windows keep their own look and controller navigation.

| Input | Bag action |
|---|---|
| D-pad | Move selection; Up at the top reaches search/filter/controls |
| A / PAD1 | Use/equip or context transfer/sale; activate control / place held item |
| B / PAD2 | Leave text/menu, clear search/cursor, then back/close as applicable |
| X / PAD3 | Pick up/place; **sell one** from eligible stacks at a merchant |
| Y / PAD4 | Item, folded section or window menu |
| LB / RB | Previous / next section |
| LT | Fold/unfold selected section |
| RT | Cycle filter; **with merchant bag-item focus, request Sell junk instead** |
| L3 | Favorite; when a destination exists, quick transfer instead |
| R3 | Sort, not the default merchant junk shortcut |
| View / Select | Settings |
| Menu / Start | Switch bags ↔ eligible open native window |

RT junk selling is contextual: not while text entry, resizing, top controls, held items, native focus or combat owns input. Top controls still allow filtering. Junk selling follows your junk settings; check your bags afterwards to see what sold. Check favorites/protection and automatic junk/repair settings before your first merchant visit. Mouse users can choose the visible **Sell junk** control while at a merchant. Buy, buyback and repair controls stay native.

The default **Input method** is **bindings**. The experimental catcher method cannot perform protected actions such as use, sale or deposit, so keep bindings unless you are troubleshooting. Stick navigation is optional and off by default.

## Bags: equip or replace

1. Select the new bag in your bags, open its item menu (Y), choose **Equip bag / Replace bag...**, then the bag slot. An empty slot equips straight away; replacing an existing bag asks for confirmation.
2. If the new bag is inside the bag being replaced, use **Prepare replacement** first. Either move the new bag somewhere outside that bag yourself, or accept the single move Baggler offers. Baggler does not rearrange the rest of your items to make them fit.
3. When Baggler shows the bag is ready, open the new bag's item menu (or the window menu), choose **Continue replacing Bag ...**, then confirm with **Replace this bag**.
4. The game decides whether the swap is allowed. Check the bag slots and free-space count afterwards. If the replacement is cancelled (for example by combat or something on the cursor), look at your cursor and bags before trying again.

## Split stacks

Choose a stack → item menu → **Split stack**. Enter an amount in the game's dialog, confirm, then place the held items in a free slot. The controller moves to the game's dialog while it is open. Cancel to leave the stack unchanged. At a merchant, X sells one item instead of splitting, so use the **Split stack** menu entry there.

## Bank and other visits

Visit a banker to open Baggler's personal/account bank. Choose the bank type and tab before depositing, withdrawing or sorting. `/baggler bank on|off` followed by `/reload` switches between Baggler's bank and the game's own bank window. The guild bank always uses the game's window. Buying bank tabs and account-bank access follow the game's usual rules.

Use or quick transfer deposits/withdraws at the bank, attaches an item at the mailbox (**only with Send Mail open**), or adds an item to a trade. Reading and sending mail, accepting trades, auction posting, buying and buyback stay in the game's own windows. Start switches between Baggler and the open game window where supported. If an auction or other native window shows a UI error, please [report it](BETA-CHECKLIST.md) with the error text.

## Useful commands

`/baggler toggle`, `sort`, `reset` (position), `bank on|off`, `find <item name>`, `chars`, `view <character>`, `export`, `import`, `pad off|on|auto`, `fix`, `incidents`, `report`. Export/import shares your settings, not your saved character data; check any custom text before sharing a code. Share codes made with an earlier Baggler build need to be exported again. `/baggler fix` tries to recover stuck input or a stuck cursor. Diagnostic commands and `wipe` are not a normal way to reset; see [Troubleshooting](TROUBLESHOOTING.md) first.
