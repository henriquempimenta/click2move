import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

from package import ROOT, build, package_files


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = package_files(ROOT)
        for name in self.files + ["package-manifest.json"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def test_archive_contains_only_runtime_and_all_required_modules(self):
        for name in ["Hovercrafts_2.1.4/control.lua", "tests/not-runtime.lua", ".vscode/settings.json"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("excluded")
        archive = build(self.root)
        info = json.loads((self.root / "info.json").read_text())
        prefix = f"{info['name']}_{info['version']}/"
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(set(package.namelist()), {prefix + name for name in self.files})
            self.assertIn(prefix + "scripts/vehicle-braking.lua", package.namelist())

    def test_missing_required_module_is_rejected(self):
        files = [name for name in self.files if name != "scripts/vehicle-braking.lua"]
        (self.root / "package-manifest.json").write_text(json.dumps(files))
        with self.assertRaisesRegex(ValueError, "Runtime dependencies absent"):
            build(self.root)

    def test_missing_source_is_rejected(self):
        (self.root / "scripts/vehicle-braking.lua").unlink()
        with self.assertRaisesRegex(ValueError, "Missing or unsafe"):
            build(self.root)

    def test_tag_version_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "differs from info.json"):
            build(self.root, expected_version="999.0.0")

    def test_missing_changelog_entry_is_rejected(self):
        (self.root / "changelog.txt").write_text("")
        with self.assertRaisesRegex(ValueError, "has no entry"):
            build(self.root)

    def test_build_is_reproducible(self):
        archive = build(self.root)
        first = archive.read_bytes()
        self.assertEqual(first, build(self.root).read_bytes())

    def test_path_traversal_is_rejected(self):
        (self.root / "package-manifest.json").write_text(json.dumps(self.files + ["../secret"]))
        with self.assertRaisesRegex(ValueError, "Invalid package path"):
            build(self.root)


if __name__ == "__main__":
    unittest.main()
