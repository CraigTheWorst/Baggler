"""Release verifier regressions, using real ZIP members and shipping manifests."""
from pathlib import Path
import importlib.util
import tempfile
import os
import sys
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))


def load(name):
    path = ROOT / 'tools' / (name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReleaseVerificationTests(unittest.TestCase):
    def test_exact_archive_verifies(self):
        self.assertTrue((ROOT / 'tools/verify_release.py').is_file(), 'release verifier is missing')
        verifier = load('verify_release')
        with tempfile.TemporaryDirectory(prefix='baggler verify ', dir=os.environ.get('TMPDIR')) as tmp:
            path = Path(tmp) / 'candidate.zip'
            files = {'Baggler/Baggler.toc': b'## Version: 0.2.0-beta.1\n'}
            with zipfile.ZipFile(path, 'w') as archive:
                for name, data in files.items():
                    info = zipfile.ZipInfo(name)
                    info.external_attr = 0o100644 << 16
                    archive.writestr(info, data)
            result = verifier.verify_archive(path, files)
            self.assertEqual(result['file_count'], 1)
            self.assertEqual(result['files'][0]['path'], 'Baggler/Baggler.toc')
            self.assertEqual(len(result['sha256']), 64)


    def test_public_docs_gallery_and_regressions_ship_only_in_source(self):
        package = load('package_baggler')
        source = package.source_manifest(ROOT)
        runtime = package.runtime_manifest(ROOT)
        required = ('docs/GALLERY.md', 'docs/ASSISTED-INSTALL.md', 'addons/Baggler/docs/ACCENTS.md',
                    'addons/Baggler/Tests/settings_controller_test.lua',
                    'addons/Baggler/Tests/accent_palette_test.lua',
                    'addons/Baggler/Tests/chrome_labels_test.lua')
        for relative in required:
            self.assertEqual(source['Baggler-source/' + relative], (ROOT / relative).read_bytes())
        gallery = sorted((ROOT / 'docs/screenshots').glob('*.png'))
        self.assertEqual(len(gallery), 13)
        shipped = [p for p in source if p.startswith('Baggler-source/docs/screenshots/')]
        self.assertEqual(set(shipped), {'Baggler-source/docs/screenshots/' + p.name for p in gallery})
        for image in gallery:
            self.assertEqual(source['Baggler-source/docs/screenshots/' + image.name], image.read_bytes())
        self.assertFalse(any('/Tests/' in p or '/docs/' in p or '/screenshots/' in p for p in runtime))
        runner = (ROOT / 'tools/baggler').read_text()
        for name in ('settings_controller', 'accent_palette', 'chrome_labels'):
            self.assertIn('Tests/' + name + '_test.lua', runner)
        self.assertIn('tests/test_release_verification.py', runner)

    def test_editorial_disclosure_and_assisted_install_links(self):
        readme = (ROOT / 'README.md').read_text()
        disclosure = 'A' + 'I assistance during development'
        self.assertEqual(readme.count(disclosure), 1)
        self.assertTrue(readme.split('\n\n')[1].startswith('With ' + disclosure + ', **Baggler** was created'))
        self.assertIn('docs/ASSISTED-INSTALL.md', readme)
        guide = (ROOT / 'docs/ASSISTED-INSTALL.md').read_text()
        self.assertTrue(guide.startswith('# Assisted installation'))
        self.assertIn('local assistant with file access', guide)
        self.assertFalse((ROOT / ('docs/A' + 'I-INSTALL.md')).exists())

    def test_tree_rejects_nonallowlisted_publication_files(self):
        verifier = load('verify_release')
        with tempfile.TemporaryDirectory(prefix='baggler tree ', dir=os.environ.get('TMPDIR')) as tmp:
            root = Path(tmp)
            (root / 'README.md').write_bytes(b'# Candidate\n')
            expected = {'README.md': b'# Candidate\n'}
            self.assertEqual(verifier.verify_tree(root, expected), 1)
            (root / 'extra.txt').write_bytes(b'not approved')
            with self.assertRaises(ValueError):
                verifier.verify_tree(root, expected)

    def test_unsafe_or_private_expected_members_still_rejected(self):
        verifier = load('verify_release')
        cases = [
            ('Baggler/../escape.lua', b'-- safe', 0o100644),
            ('Baggler/private.lua', b'-- /' + b'home/private/player', 0o100644),
            ('Baggler/private.lua', b'-- token ghp_' + b'z' * 24, 0o100644),
            ('Baggler/WTF/account.lua', b'-- safe', 0o100644),
            ('Baggler/link.lua', b'target', 0o120777),
            ('Baggler/Baggler.toc', b'-- safe', 0o100777),
            ('Baggler/tools/baggler', b'-- safe', 0o100644),
        ]
        with tempfile.TemporaryDirectory(prefix='baggler unsafe ', dir=os.environ.get('TMPDIR')) as tmp:
            path = Path(tmp) / 'candidate.zip'
            for name, data, mode in cases:
                with self.subTest(name=name, mode=oct(mode), data=data):
                    with zipfile.ZipFile(path, 'w') as archive:
                        info = zipfile.ZipInfo(name)
                        info.external_attr = mode << 16
                        archive.writestr(info, data)
                    with self.assertRaises(ValueError):
                        verifier.verify_archive(path, {name: data})


if __name__ == '__main__':
    unittest.main()
