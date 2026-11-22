#!/usr/bin/env python3
"""Build Baggler release ZIPs from explicit file lists, never the working tree wholesale.

The install ZIP follows the TOC, not whatever happens to be beside it. The
separate source ZIP contains the addon, its tests, tools and public docs.
Nothing is installed or uploaded, and saved settings are never touched.
"""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ("Assets/baggler-icon.tga", "Assets/baggler-header.tga")
PRIVATE = re.compile(rb"/ho" rb"me/|/Us" rb"ers/|[A-Za-z]:\\Users\\|-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----|(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}")
TEXT = {".lua", ".toc", ".xml", ".md", ".py", ".sh", ".conf", ".json", ".yml", ".yaml", ""}


def checked(path, base):
    """Reject traversal/symlinks rather than following a surprising local file."""
    relative = PurePosixPath(path)
    if relative.is_absolute() or ".." in relative.parts or "\\" in path:
        raise ValueError(f"unsafe manifest path: {path}")
    source = base / path
    if any(p.is_symlink() for p in (source, *source.parents)):
        raise ValueError(f"symlink not allowed: {path}")
    if not source.is_file():
        raise ValueError(f"missing manifest file: {path}")
    data = source.read_bytes()
    if source.suffix in TEXT and PRIVATE.search(data):
        raise ValueError(f"private path or secret signature in {path}")
    return data


def runtime_manifest(root=ROOT):
    base = root / "addons/Baggler"
    toc = checked("Baggler.toc", base).decode()
    loaded = [line.strip() for line in toc.splitlines()
              if line.strip() and not line.lstrip().startswith("#")]
    if not loaded or any(not p.endswith(".lua") for p in loaded):
        raise ValueError("only explicit TOC-loaded Lua is supported; review new dependencies")
    paths = ["Baggler.toc", *loaded, *ASSETS]
    # License/notice files always ship with the addon.
    paths += [p.name for p in base.iterdir() if p.is_file()
              and p.name.upper().split(".")[0] in {"LICENSE", "COPYING", "NOTICE"}]
    if len(paths) != len(set(paths)):
        raise ValueError("duplicate runtime manifest entry")
    return {"Baggler/" + p: checked(p, base) for p in paths}


def source_manifest(root=ROOT):
    # Start with exactly what the install ZIP ships.
    files = {"addons/Baggler/" + name.removeprefix("Baggler/"): data
             for name, data in runtime_manifest(root).items()}
    # Behaviour tests and the standalone unit tests (tests/harness/ca_stubs.lua is
    # the fake client they share).
    for path in sorted((root / "addons/Baggler/Tests").rglob("*")):
        if path.is_file() and path.suffix in {".lua", ".py", ".md", ".txt"}:
            relative = path.relative_to(root).as_posix()
            files[relative] = checked(relative, root)
    for relative in ("tools/baggler", "tools/package_baggler.py",
                     "tests/harness/ca_stubs.lua", "tests/test_packaging.py",
                     "docs/INTEGRATION.md", "docs/STATUS.md", "docs/LIVE-CHECKS.md",
                     "addons/Baggler/Assets/baggler.tga", "addons/Baggler/Assets/baggler-master.png",
                     "release-assets/README.md", "release-assets/baggler-curseforge-avatar.png"):
        files[relative] = checked(relative, root)
    # The local configuration holds a personal game path; ship a neutral template
    # that cannot install anywhere until it is configured.
    files["project.conf"] = b'ADDONS_DIR="/configure-your-game/Interface/AddOns"\nADDONS="Baggler"\nPENDING=""\n'
    for relative in ("README.md", "LICENSE", ".gitignore", "SOURCE-README.md",
                     "docs/INSTALL.md", "docs/ASSISTED-INSTALL.md", "docs/GALLERY.md",
                     "addons/Baggler/docs/ACCENTS.md", "docs/USAGE.md", "docs/TROUBLESHOOTING.md",
                     "docs/BETA-CHECKLIST.md", "docs/DEVELOPMENT.md", "docs/PROVENANCE.md",
                     ".github/ISSUE_TEMPLATE/bug_report.md", ".github/ISSUE_TEMPLATE/feature_request.md",
                     "tools/verify_release.py", "tests/test_release_verification.py"):
        files[relative] = checked(relative, root)
    for relative in (
        "docs/screenshots/bag-search-highlight.png",
        "docs/screenshots/bank-categorized-inventory.png",
        "docs/screenshots/behaviour-automation-settings.png",
        "docs/screenshots/categorized-bag-overview.png",
        "docs/screenshots/clean-up-sort-tooltip.png",
        "docs/screenshots/controller-navigation-button-mapping.png",
        "docs/screenshots/custom-section-editor.png",
        "docs/screenshots/destroy-drop-target.png",
        "docs/screenshots/folded-bag-sections.png",
        "docs/screenshots/item-binding-chord-overlay.png",
        "docs/screenshots/item-context-menu.png",
        "docs/screenshots/look-window-item-settings.png",
        "docs/screenshots/organise-grouping-section-settings.png",
    ):
        files[relative] = checked(relative, root)
    return {"Baggler-source/" + p: data for p, data in files.items()}


def build(root=ROOT, source=False):
    files = source_manifest(root) if source else runtime_manifest(root)
    toc = (root / "addons/Baggler/Baggler.toc").read_text()
    match = re.search(r"^## Version: ([\w.\-]+)$", toc, re.M)
    if match is None:
        raise ValueError("missing or unsafe TOC version")
    version = match.group(1)
    out = root / "dist" / f"Baggler-{version}{'-source' if source else ''}.zip"
    out.parent.mkdir(exist_ok=True)
    # Stable ordering and timestamps make unchanged candidates reproducible.
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if name.endswith("tools/baggler") else 0o100644) << 16
            archive.writestr(info, data)
    with zipfile.ZipFile(out) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == set(files)
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"Built {out}\n{len(files)} files; SHA-256 {digest}")
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="store_true", help="separate developer source ZIP")
    args = parser.parse_args()
    build(source=args.source)
