import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

from package import ROOT, build, package_files, target_version


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = package_files(ROOT)
        for name in self.files + ["package-manifest.json", "targets.json"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def test_archive_contains_only_runtime_and_all_required_modules(self):
        for name in ["Hovercrafts_2.1.4/control.lua", "tests/not-runtime.lua", ".vscode/settings.json"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("excluded")
        archive = build(self.root, "2.1")
        info = json.loads((self.root / "info.json").read_text())
        prefix = f"{info['name']}_{target_version(info['version'], '2.1')}/"
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(set(package.namelist()), {prefix + name for name in self.files})
            self.assertIn(prefix + "scripts/vehicle-braking.lua", package.namelist())

    def test_missing_required_module_is_rejected(self):
        files = [name for name in self.files if name != "scripts/vehicle-braking.lua"]
        (self.root / "package-manifest.json").write_text(json.dumps(files))
        with self.assertRaisesRegex(ValueError, "Runtime dependencies absent"):
            build(self.root, "2.1")

    def test_missing_source_is_rejected(self):
        (self.root / "scripts/vehicle-braking.lua").unlink()
        with self.assertRaisesRegex(ValueError, "Missing or unsafe"):
            build(self.root, "2.1")

    def test_tag_version_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "differs from info.json"):
            build(self.root, "2.1", expected_version="999.0.0")

    def test_missing_changelog_entry_is_rejected(self):
        (self.root / "changelog.txt").write_text("")
        with self.assertRaisesRegex(ValueError, "has no entry"):
            build(self.root, "2.1")

    def test_build_is_reproducible(self):
        archive = build(self.root, "2.1")
        first = archive.read_bytes()
        self.assertEqual(first, build(self.root, "2.1").read_bytes())

    def test_path_traversal_is_rejected(self):
        (self.root / "package-manifest.json").write_text(json.dumps(self.files + ["../secret"]))
        with self.assertRaisesRegex(ValueError, "Invalid package path"):
            build(self.root, "2.1")

    def read(self, archive, name):
        with zipfile.ZipFile(archive) as package:
            return package.read(f"{archive.stem}/{name}").decode()

    def test_each_game_version_gets_its_own_version_and_dependency(self):
        (self.root / "info.json").write_text(json.dumps({"name": "click2move", "version": "0.1.16",
            "factorio_version": "2.1", "dependencies": ["base >= 2.1", "(?) jetpack", "? base-extension >= 1.0"]}))
        (self.root / "changelog.txt").write_text("Version: 0.1.16\n  Changes:\n    - New.\nVersion: 0.1.15\n")
        for factorio_version, version in (("2.1", "0.1.21016"), ("2.0", "0.1.20016")):
            archive = build(self.root, factorio_version)
            self.assertEqual(archive.name, f"click2move_{version}.zip")
            info = json.loads(self.read(archive, "info.json"))
            self.assertEqual((info["version"], info["factorio_version"]), (version, factorio_version))
            self.assertEqual(info["dependencies"], [f"base >= {factorio_version}", "(?) jetpack", "? base-extension >= 1.0"])
            # Releases before multi-version packaging keep the version they were published as.
            self.assertEqual(self.read(archive, "changelog.txt"),
                             f"Version: {version}\n  Changes:\n    - New.\nVersion: 0.1.15\n")

    def test_target_file_replaces_shared_file_for_one_game_version(self):
        override = self.root / "targets/2.0/scripts/util.lua"
        override.parent.mkdir(parents=True)
        override.write_text("return {}\n")
        self.assertEqual(self.read(build(self.root, "2.0"), "scripts/util.lua"), "return {}\n")
        self.assertEqual(self.read(build(self.root, "2.1"), "scripts/util.lua"),
                         (ROOT / "scripts/util.lua").read_text())

    def test_target_file_outside_manifest_is_rejected(self):
        extra = self.root / "targets/2.0/scripts/extra.lua"
        extra.parent.mkdir(parents=True)
        extra.write_text("return {}\n")
        with self.assertRaisesRegex(ValueError, "does not replace"):
            build(self.root, "2.0")

    def test_target_symlinks_are_rejected(self):
        # Each case points a different level of targets/2.0/scripts/util.lua outside the repository.
        for link, destination in (("targets", ""), ("targets/2.0", "2.0"),
                                  ("targets/2.0/scripts", "2.0/scripts"), ("targets/2.0/scripts/util.lua", "2.0/scripts/util.lua")):
            with self.subTest(link):
                outside = Path(tempfile.mkdtemp(dir=self.temp.name, prefix="outside-"))
                (outside / "2.0/scripts").mkdir(parents=True)
                (outside / "2.0/scripts/util.lua").write_text("return 'outside the repository'\n")
                if (self.root / "targets").is_symlink():
                    (self.root / "targets").unlink()
                shutil.rmtree(self.root / "targets", ignore_errors=True)
                (self.root / link).parent.mkdir(parents=True, exist_ok=True)
                (self.root / link).symlink_to(outside / destination)
                with self.assertRaisesRegex(ValueError, "must not be a symlink"):
                    build(self.root, "2.0")

    def test_unlisted_game_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not listed"):
            build(self.root, "1.1")

    def test_versions_that_cannot_hold_the_game_version_are_rejected(self):
        self.assertEqual(target_version("1.2.3", "1.1"), "1.2.11003")
        with self.assertRaisesRegex(ValueError, "below 100"):
            target_version("0.1.100", "2.1")


if __name__ == "__main__":
    unittest.main()
