# In-game checks

The automated tests run in a simulated client. Before a release, these checks are done in the real game. Players don't need this page; to report a problem, see [Beta feedback](BETA-CHECKLIST.md).

For each check, note the client version, controller and button mapping, input method (bindings or catcher), what was open at the start, and whether any "blocked action" error appeared. An empty error list alone doesn't count as a pass. Test the bindings and catcher input methods separately.

1. **Controller off or unavailable.** With controller navigation off, with no controller connected, or while another addon holds the controller, every key and button keeps its normal game action.
2. **Basic navigation.** One press gives one action at the current focus. Holding a direction repeats after a short delay and stops on release; only the newest direction repeats. Remapped and unbound buttons behave as configured. Disconnecting or switching controllers never replays a held button.
3. **Text entry.** In search or other text boxes, arrows and confirm work as normal typing keys; only the configured back button leaves the text box, and nothing is used by accident.
4. **Game windows.** At a merchant, bank, guild bank, mailbox, trade, auction house and crafting order, Start switches between the game's window and Baggler once per press, and the game window's own controls keep working. Auction house price-copy and Create Auction buttons still work from the controller.
5. **Combat.** Entering combat with bags open: the configured back button closes them once and the next world input works immediately, including with two back buttons or a remapped back. After combat, bags reopen normally with no leftover input.
6. **Opening bags during combat** (known limitation). Open bags in combat, close with back, check world input, and repeat. Keyboard Escape is the fallback. Record the result; this case is listed in the README's known issues.
7. **Merchant shortcuts.** With bag focus at a merchant, the filter button sells junk once. It never sells while typing, resizing, using the top controls, holding an item, in a game window or in combat. Use, equip, pick up, menu, sell and transfer actions each happen once.
8. **Share codes.** Export and import settings with remapped and unbound buttons, empty lists and non-English text. Character, account, log and window-position data never appear in a code. Invalid codes are refused with a message and change nothing; cancelling an import changes nothing.
9. **Item cards and comparisons.** Check armor, rings, trinkets, one- and two-handed weapons and off-hands against empty, loading and occupied slots. Card and comparison toggles work independently, and the numbers match the game's own tooltip comparison. Moving quickly, hovering with the mouse, equipping the selected item and closing the window never leave a stale card.
10. **Looks.** Check cards, search, settings, game-window visits and the personal/account bank at a few UI scales: borders, button hints, footer wrapping and focus outlines, with both mouse and controller.
11. **Accent colours.** On a couple of characters (for example a Mage and a Warlock), check **My class**, another class colour and an extra colour across bags, bank, settings and menus, then `/reload` and export/import.
12. **Camping section.** Simple Wood, Flint and Tinder, the campfire kits, a blueprint and a camp feature appear under Camping in bags and bank; favorites, custom sections and manual moves still win, and shared materials stay in their usual sections.

Record each check as pass or fail, with the error text for any failure.
