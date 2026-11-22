"""Exercise the real dev helper in an isolated checkout, never the game install."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get("BAGGLER_TEST_TOOL", ROOT / "tools/baggler"))


class PackagingTest(unittest.TestCase):
    def test_independent_units_have_loader_only_envelopes(self):
        for folder, name in (("input", "InputSession"), ("settings", "ProfileShare"), ("comparison", "EquippedCompare")):
            standalone = (ROOT / f"addons/Baggler/Tests/Independent/{folder}/{name}.lua").read_text()
            production = (ROOT / f"addons/Baggler/{name}.lua").read_text()
            body = production.split("local unit = (function()\n", 1)[1].split("\nend)()\n", 1)[0]
            self.assertEqual(body, standalone, "production body must match the current standalone implementation")

    def test_removed_loader_target_is_not_an_alias(self):
        for command in ('check', 'pack'):
            result = subprocess.run([str(TOOL), command, 'CBags'], cwd=ROOT, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('unknown or unmanaged', result.stderr)

    def test_public_archive_keeps_only_internal_loader_root(self):
        self.assertTrue((ROOT / "addons/Baggler/Baggler.toc").is_file(), "actual Baggler loader must exist")
        with tempfile.TemporaryDirectory(prefix="baggler pack ", dir=os.environ.get("TMPDIR")) as tmp:
            project = Path(tmp)
            (project / "tools").mkdir()
            shutil.copy2(TOOL, project / "tools/baggler")
            shutil.copy2(ROOT / "tools/package_baggler.py", project / "tools/package_baggler.py")
            shutil.copy2(ROOT / "project.conf", project / "project.conf")
            shutil.copytree(ROOT / "addons/Baggler", project / "addons/Baggler")
            version = next(line.split(":", 1)[1].strip() for line in
                           (project / "addons/Baggler/Baggler.toc").read_text().splitlines()
                           if line.startswith("## Version:"))
            expected = project / "dist" / f"Baggler-{version}.zip"
            for target in (None, "Baggler", "all"):
                with self.subTest(target=target):
                    shutil.rmtree(project / "dist", ignore_errors=True)
                    (project / "dist").mkdir()
                    args = [str(project / "tools/baggler"), "pack"]
                    if target is not None:
                        args.append(target)
                    result = subprocess.run(args, cwd=project, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(sorted(p.name for p in (project / "dist").iterdir()), [expected.name])
                    with zipfile.ZipFile(expected) as archive:
                        self.assertIsNone(archive.testzip())
                        names = archive.namelist()
                        self.assertEqual({name.split("/", 1)[0] for name in names}, {"Baggler"})
                        self.assertIn("Baggler/Baggler.toc", names)
                        self.assertFalse(any("CvizUI" in name or ".." in Path(name).parts for name in names))
                        self.assertIn("## SavedVariables: BagglerDB", archive.read("Baggler/Baggler.toc").decode())
                        for name in names:
                            self.assertNotIn('cbags', name.lower())
                            if name.endswith(('.lua', '.toc', '.md', '.py', '.xml')):
                                self.assertNotIn(b'cbags', archive.read(name).lower(), name)
                                self.assertNotIn(b'cvizpad', archive.read(name).lower(), name)
                        toc = archive.read('Baggler/Baggler.toc').decode()
                        loaded = [line.strip() for line in toc.splitlines()
                                  if line.strip() and not line.startswith('#')]
                        self.assertEqual(loaded.count('CampingData.lua'), 1)
                        self.assertLess(loaded.index('CampingData.lua'), loaded.index('Categories.lua'))
                        self.assertEqual(archive.read('Baggler/CampingData.lua'),
                                         (ROOT / 'addons/Baggler/CampingData.lua').read_bytes())
                        expected_names = {'Baggler/Baggler.toc',
                                          'Baggler/Assets/baggler-icon.tga',
                                          'Baggler/Assets/baggler-header.tga'}
                        expected_names.update('Baggler/' + line for line in loaded)
                        expected_names.update('Baggler/' + p.name for p in (project / 'addons/Baggler').iterdir()
                                              if p.is_file() and p.name.upper().split('.')[0] in {'LICENSE', 'COPYING', 'NOTICE'})
                        self.assertEqual(set(names), expected_names)
                        for name in names:
                            self.assertNotIn(b'/' + b'home/', archive.read(name), name)
                            self.assertNotIn(b'/' + b'Users/', archive.read(name), name)

    def test_manifest_rejects_private_paths_and_missing_runtime_files(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('package_baggler', ROOT / 'tools/package_baggler.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='baggler manifest ', dir=os.environ.get('TMPDIR')) as tmp:
            root = Path(tmp)
            shutil.copytree(ROOT / 'addons/Baggler', root / 'addons/Baggler')
            core = root / 'addons/Baggler/Core.lua'
            for payload in (b'\n-- /' + b'home/private/player\n', b'\n-- ghp_' + b'z' * 24):
                core.write_bytes((ROOT / 'addons/Baggler/Core.lua').read_bytes() + payload)
                with self.assertRaisesRegex(ValueError, 'private path or secret'):
                    module.runtime_manifest(root)
            shutil.copy2(ROOT / 'addons/Baggler/Core.lua', core)
            core.unlink()
            with self.assertRaisesRegex(ValueError, 'missing manifest'):
                module.runtime_manifest(root)

    def test_source_manifest_is_complete_but_not_a_checkout_dump(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('package_baggler_source', ROOT / 'tools/package_baggler.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        files = module.source_manifest()
        for name in ('addons/Baggler/CampingData.lua', 'addons/Baggler/Tests/camping_test.lua',
                     'addons/Baggler/Tests/CAMPING.md',
                     'addons/Baggler/InputSession.lua', 'addons/Baggler/Tests/bags_only_test.lua',
                     'tests/harness/ca_stubs.lua', 'tools/baggler', 'tools/package_baggler.py'):
            self.assertIn('Baggler-source/' + name, files)
        for retired in ('addons/Baggler/Vendor.lua', 'addons/Baggler/VendorPad.lua',
                        'docs/PROVENANCE-AUDIT.md', 'addons/Baggler/DEVELOPING.md',
                        'tests/harness/ca_base.lua'):
            self.assertNotIn('Baggler-source/' + retired, files)
        for name, data in files.items():
            self.assertFalse(any(part in {'.git', 'archives', 'WTF', '__pycache__'} for part in Path(name).parts))
            if Path(name).suffix in module.TEXT:
                self.assertIsNone(module.PRIVATE.search(data), name)


if __name__ == "__main__":
    unittest.main()
