# Install, update and uninstall

## Before installation

Baggler is built for the WoW Forever client (1.60.1.71037). Exit the game before changing addon files. If you are updating, back up your existing `Baggler` folder and Baggler saved settings first. Install `Baggler-<version>.zip`, not the `-source` ZIP or GitHub's "Source code" archive.

## Optional assisted installation

A local assistant with file access can follow the [copy-paste installation prompt](ASSISTED-INSTALL.md). It needs your permission to use its file and network tools, plus the path to your Forever installation; a chat-only assistant cannot install files. The prompt picks the official install ZIP from [Releases](https://github.com/CraigTheWorst/Baggler/releases), checks it, backs up an existing Baggler folder, and leaves saved settings and other addons untouched. If that isn't possible, use the manual steps below.

## Locate the right client folder

These are examples, not auto-detected paths. Choose the folder for the client you actually launch, not a different Retail/Classic installation. Create `Interface/AddOns` if absent.

- **Windows:** use your launcher/client's Open Folder/Browse installation option. A typical path is `C:\Games\World of Warcraft\_forever_\Interface\AddOns` (another installation may be under `Program Files (x86)`).
- **macOS:** locate the Forever client folder you play from; for example `/Applications/World of Warcraft/_forever_/Interface/AddOns`. If you run the Windows client through Wine or a similar wrapper, use the folder inside its `drive_c` instead.
- **Linux / Wine:** locate the active launcher prefix, for example `$WINEPREFIX/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns`. A launcher may manage a prefix elsewhere; do not assume the default Wine prefix. Example with spaces: `"$WINEPREFIX/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"`. Select the real prefix before using that expression.

## Extract and enable

1. Extract `Baggler-0.2.0-beta.1.zip` into `Interface/AddOns`. It contains exactly one root, **Baggler**.
2. Check the exact resulting file: `Interface/AddOns/Baggler/Baggler.toc`. Not `AddOns/Baggler-0.2.0-beta.1/Baggler/...` or `AddOns/Baggler/Baggler/...`. Preserve capitalization, especially on Linux.
3. Start the client, open AddOns at character selection and enable Baggler. A newly added addon can require character selection or a client restart; `/reload` alone may not discover it.
4. Log in, open your bags as usual and use `/baggler` for settings. If Baggler is marked out of date, check that you are using the Forever client and the latest Baggler release.
5. Disable other full bag-replacement addons; you don't need to delete them or their settings. If another one is active, Baggler may step aside.

Baggler needs no other addons. Controllers use the game's own controller support. BugGrabber/BugSack are optional and can help with error reports.

## Update / rollback

Exit the game. Back up the existing Baggler addon folder and `WTF/Account/<account>/SavedVariables/Baggler.lua` (plus its `.bak` if present). Remove **only** `Interface/AddOns/Baggler`, then extract the new install ZIP; this avoids leftover files from the old version. Leave `WTF` as it is to keep your settings, categories and character snapshots. To roll back, exit again and restore the previous addon folder, and if needed the matching backed-up settings. Settings saved by a newer version may not work with an older one.

## Uninstall / optional reset

To disable, uncheck Baggler in AddOns. To uninstall, exit and remove **only** `Interface/AddOns/Baggler`. Saved settings remain for reinstall.

Optional full reset: with the game exited, back up and then remove only that account's `SavedVariables/Baggler.lua` and `Baggler.lua.bak`. Baggler's settings (`BagglerDB`) are account-wide, so this clears favorites, custom categories, character snapshots and diagnostics for every character on that account. Never delete the whole `WTF` or `SavedVariables` folder or other addons' files. `/baggler reset` only resets the window position.
