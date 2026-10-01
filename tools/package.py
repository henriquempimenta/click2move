#!/usr/bin/env python3
"""Build a Factorio archive using only the reviewed runtime allowlist."""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import zipfile


ROOT = Path(__file__).resolve().parents[1]
LOCAL_REQUIRE = re.compile(r"require\s*\(\s*['\"](scripts[/.][^'\"]+)['\"]\s*\)")
LOCAL_ASSET = re.compile(r"__click2move__/([^'\"\s]+)")


def package_files(root):
    files = json.loads((root / "package-manifest.json").read_text())
    if not isinstance(files, list) or not files or len(set(files)) != len(files):
        raise ValueError("Package manifest must contain a nonempty list of unique paths")
    for name in files:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or str(path) != name:
            raise ValueError(f"Invalid package path: {name}")
        source = root / name
        if not source.is_file() or source.is_symlink() or not source.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Missing or unsafe package file: {name}")
    required = {"info.json", "control.lua", "data.lua", "settings.lua", "changelog.txt", "thumbnail.png"}
    for name in files:
        if name.endswith(".lua"):
            source = (root / name).read_text()
            required.update(module.replace(".", "/") + ".lua" for module in LOCAL_REQUIRE.findall(source))
            required.update(LOCAL_ASSET.findall(source))
    missing = required.difference(files)
    if missing:
        raise ValueError("Runtime dependencies absent from package manifest: " + ", ".join(sorted(missing)))
    return sorted(files)


def build(root=ROOT, output_dir=None, expected_version=None):
    root = Path(root)
    files = package_files(root)
    info = json.loads((root / "info.json").read_text())
    name, version = info.get("name", ""), info.get("version", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("info.json must contain a valid mod name and three-part version")
    if expected_version is not None and version != expected_version:
        raise ValueError(f"Tag version {expected_version} differs from info.json version {version}")
    changelog = (root / "changelog.txt").read_text()
    if not re.search(r"^Version: " + re.escape(version) + r"$", changelog, re.MULTILINE):
        raise ValueError(f"changelog.txt has no entry for version {version}")
    output_dir = Path(output_dir) if output_dir else root / "dist"
    output_dir.mkdir(parents=True, exist_ok=True)
    prefix = f"{name}_{version}"
    archive = output_dir / f"{prefix}.zip"
    # Fixed ZIP timestamps and sorted entries make identical inputs reproducible.
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name in files:
            entry = zipfile.ZipInfo(f"{prefix}/{name}", date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            package.writestr(entry, (root / name).read_bytes())
    with zipfile.ZipFile(archive) as package:
        expected = {f"{prefix}/{name}" for name in files}
        if set(package.namelist()) != expected or package.testzip() is not None:
            raise ValueError("Archive verification failed")
        for name in files:
            if package.read(f"{prefix}/{name}") != (root / name).read_bytes():
                raise ValueError(f"Archive content differs from source: {name}")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--expected-version", help="Require info.json to match a release tag")
    args = parser.parse_args()
    try:
        archive = build(output_dir=args.output_dir, expected_version=args.expected_version)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")
    print(archive)


if __name__ == "__main__":
    main()
