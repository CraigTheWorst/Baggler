#!/usr/bin/env python3
"""Verify release ZIP membership, bytes and modes; optionally write hash sidecars.

Uses only Python's standard library.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
import package_baggler as package

ROOT = Path(__file__).resolve().parents[1]


def verify_archive(path, expected):
    """Return a content manifest only after checking the actual archive."""
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC failure')
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('duplicate archive members')
        if set(names) != set(expected):
            raise ValueError('archive membership differs from current allowlist')
        files = []
        for info in archive.infolist():
            member = Path(info.filename)
            if (member.is_absolute() or '\\' in info.filename or '..' in member.parts
                    or member.parts[0] not in {'Baggler', 'Baggler-source'}
                    or any(p in {'.git', 'WTF', 'archives', 'scratch', '__pycache__'} for p in member.parts)):
                raise ValueError('unsafe/private archive path: ' + info.filename)
            data = archive.read(info)
            if member.suffix in package.TEXT and package.PRIVATE.search(data):
                raise ValueError('private path or secret signature: ' + info.filename)
            if data != expected[info.filename]:
                raise ValueError('archive bytes differ: ' + info.filename)
            mode = info.external_attr >> 16
            required_mode = 0o100755 if info.filename.endswith('tools/baggler') else 0o100644
            if mode != required_mode:
                raise ValueError('unexpected Unix mode: ' + info.filename)
            files.append({'path': info.filename, 'size': len(data),
                          'sha256': hashlib.sha256(data).hexdigest(), 'mode': oct(mode)})
    return {'archive': Path(path).name, 'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest(),
            'file_count': len(files), 'files': sorted(files, key=lambda f: f['path']),
            'release': 'public beta; known issues: docs/BETA-CHECKLIST.md'}


def verify_tree(root, expected):
    """Require the source tree to equal its source allowlist, ignoring build/cache outputs."""
    actual = {}
    for path in root.rglob('*'):
        relative = path.relative_to(root)
        if relative.parts[0] in ('dist', '.git') or '__pycache__' in relative.parts:
            continue
        if path.is_symlink():
            raise ValueError('symlink in source tree: ' + relative.as_posix())
        if path.is_file():
            actual[relative.as_posix()] = package.checked(relative.as_posix(), root)
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        changed = sorted(p for p in actual.keys() & expected.keys() if actual[p] != expected[p])
        raise ValueError(f'source tree differs: missing={missing} extra={extra} changed={changed}')
    return len(actual)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-manifests', action='store_true')
    args = parser.parse_args()
    source_files = package.source_manifest(ROOT)
    tree_files = {p.removeprefix('Baggler-source/'): data for p, data in source_files.items()}
    print(f'PASS source tree: {verify_tree(ROOT, tree_files)} allowlisted files; private-path scan passed')
    if (ROOT / 'LICENSE').read_bytes() != (ROOT / 'addons/Baggler/LICENSE').read_bytes():
        raise ValueError('root and installed license notices differ')
    version_match = re.search(r'^## Version: ([\w.\-]+)$',
                              (ROOT / 'addons/Baggler/Baggler.toc').read_text(), re.M)
    if version_match is None:
        raise ValueError('missing or unsafe TOC version')
    version = version_match.group(1)
    records = []
    for source in (False, True):
        files = package.source_manifest(ROOT) if source else package.runtime_manifest(ROOT)
        path = ROOT / 'dist' / f"Baggler-{version}{'-source' if source else ''}.zip"
        record = verify_archive(path, files)
        text = json.dumps(record, indent=2, sort_keys=True) + '\n'
        sidecar = path.with_suffix('.manifest.json')
        if args.write_manifests:
            sidecar.write_text(text)
        elif sidecar.read_text() != text:
            raise ValueError('stale archive sidecar: ' + sidecar.name)
        records.append(record)
        print(f"PASS {path.name}: {record['file_count']} exact files; SHA-256 {record['sha256']}")
    sums = ''.join(f"{r['sha256']}  {r['archive']}\n" for r in records)
    sums_path = ROOT / 'dist/SHA256SUMS'
    if args.write_manifests:
        sums_path.write_text(sums)
    elif sums_path.read_text() != sums:
        raise ValueError('stale SHA256SUMS')
    print('Release packages verified.')


if __name__ == '__main__':
    main()
