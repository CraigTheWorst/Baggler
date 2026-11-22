# Troubleshooting

## Common problems

- **Baggler isn't in the AddOns list:** check you installed into the Forever client's folder and that the file is exactly `Interface/AddOns/Baggler/Baggler.toc` (no extra folder level, same capitalization). Return to character selection or restart the game after adding files.
- **The normal bags still appear:** make sure Baggler is enabled and turn off any other bag-replacement addon; Baggler may step aside if another one is in control. The bank has its own switch: `/baggler bank on`, then `/reload`.
- **Controller or keyboard input feels stuck:** leave combat when it's safe, then press Escape or type `/baggler fix`. Please report what you were doing when it happened.
- **Combat:** some controller interactions are restricted by the game; report any trouble.
- **UI errors / “blocked action” messages:** UI errors have been reported with several addons enabled; cause not isolated. Please include error text. An addon named in the message is where the game stopped, not necessarily the cause.
- **A bank or item action didn't happen:** check you're at the right bank type/tab, out of combat, with an empty cursor and a free compatible slot. Look at your bags before trying again rather than repeating the action.

## Getting details for a report

Baggler keeps a small record of protected-action errors and what was happening around them. `/baggler incidents` prints it in chat; `/baggler report` opens a longer copyable report. If you use BugSack, its error text is helpful too. These records survive `/reload` and logout, but a crash can lose the latest entries. `/baggler clearlog` does not erase incident history.

## Keep reports private

The incident record avoids names and item links, but the **full report, saved settings and other logs can contain personal details** such as character, realm or guild names and chat or mail text. Before sharing:

1. Copy only the part that relates to the problem — usually the error text and a few lines around it.
2. Replace character, realm, account and guild names, any folder paths containing your user name, chat/mail/search or custom text, and map coordinates with placeholders like `<character>`. Keep addon and function names, which are needed to diagnose the problem.
3. Don't attach your whole `WTF` folder, `SavedVariables` files, full logs or unchecked screenshots. Check screenshot edges and filenames too.
4. If you ever post a password or token by mistake, change it — editing the post afterwards isn't enough.

Then open an issue as described in [Beta feedback](BETA-CHECKLIST.md).

To reset Baggler's settings completely, see the optional reset in [Install](INSTALL.md#uninstall--optional-reset). It also removes favorites, categories, snapshots and incident history, so keep anything you still want to report first.
