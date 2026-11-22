# Development and tests

This repository and the source archive (`Baggler-0.2.0-beta.1-source.zip`) contain the addon, its tests and the packaging tools. The [license](../LICENSE) covers personal gameplay use; it does not grant modification or redistribution rights, so please ask before distributing a modified version.

## Prerequisites

A Unix-like shell with **Bash, LuaJIT, Python 3.10+, GNU coreutils (`timeout`, `readlink -f`), grep, cut, head and wc**. Tests use only the Python standard library and need no WoW client, network or credentials. Development happens on Linux; on Windows use WSL, and on macOS put GNU `readlink`/`timeout` on PATH. rsync is needed only for the optional `status`/`sync`/`pull` commands.

If your extractor drops the executable bit, run `chmod +x tools/baggler`. Work from the source root and quote paths containing spaces.

```sh
tools/baggler check Baggler
tools/baggler test
tools/baggler pack Baggler
python3 tools/package_baggler.py --source
python3 tools/verify_release.py --write-manifests
```

Outputs: `dist/Baggler-0.2.0-beta.1.zip` (only `Baggler/` at the root), `dist/Baggler-0.2.0-beta.1-source.zip` (a self-contained `Baggler-source/`), a JSON manifest for each archive and `dist/SHA256SUMS`. `verify_release.py` checks each ZIP's CRC, exact file list and bytes, duplicate entries, file modes and a basic scan for private paths and keys; run it without `--write-manifests` to check existing manifests. ZIP timestamps and ordering are fixed, so unchanged sources give identical archives. The version always comes from the TOC.

## Local game folder

`project.conf` points at a placeholder folder. To use `sync`/`install`, `pull` or `status`, set `ADDONS_DIR` to your own `Interface/AddOns` folder first. `sync` copies the whole addon source folder; players should install the release ZIP instead. `interface` and `version` rewrite the TOC.

## Tests

`tools/baggler test` loads the shipping TOC in a simulated client and runs the regression suites: bags, bank and native windows, controller input, bag replacement, stack splitting and selling, settings and share codes, error reports, artwork and packaging. `addons/Baggler/Tests/Independent/` holds standalone modules (InputSession, ProfileShare, EquippedCompare) with their own tests; the copies in `addons/Baggler/` must match them, which the packaging tests check. [INTEGRATION.md](INTEGRATION.md) gives an overview of how the modules fit together.

A simulated client can't show how the real game delivers controller input, enforces protected actions or draws the UI, so those are checked in game; see [LIVE-CHECKS.md](LIVE-CHECKS.md).

**Opening bags during combat.** One known-failing probe is kept out of the default suite:

```sh
timeout 90 luajit addons/Baggler/Tests/combat_b_close_test.lua --during-combat-open
```

It covers bags that were closed when combat started, then opened and closed with the controller's back button during combat. Bags opened *before* combat close correctly; for bags opened during combat no safe fix exists yet, so this probe fails. Keyboard Escape still closes the bags. This is the combat limitation listed in the README's known issues.

**UI errors with several addons.** Some "blocked action" reports name Baggler when several addons are enabled, and the cause has not been isolated. The addon named in a report is where the game stopped, not necessarily the cause. Baggler's diagnostics only observe and record; when investigating, ask for the exact error text and stack.

See also [Credits and rights](PROVENANCE.md) and the [release notes](STATUS.md).
