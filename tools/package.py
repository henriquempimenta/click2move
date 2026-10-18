#!/usr/bin/env python3
"""Build one Factorio archive per supported game version from the reviewed runtime allowlist.

Each archive uses version MAJOR.MINOR.(100 * line + PATCH), where line is 210 for
Factorio 2.1, 200 for 2.0 and 110 for 1.1: source 0.1.16 becomes 0.1.21016 for Factorio 2.1
and 0.1.20016 for 2.0. Files under targets/<factorio version>/ replace the shared file
at the same path for that game version only.
"""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import zipfile


ROOT = Path(__file__).resolve().parents[1]
LOCAL_REQUIRE = re.compile(r"require\s*\(\s*['\"](scripts[/.][^'\"]+)['\"]\s*\)")
LOCAL_ASSET = re.compile(r"__click2move__/([^'\"\s]+)")
CHANGELOG_VERSION = re.compile(r"^Version: (\d+\.\d+\.\d+)$", re.MULTILINE)


def parse_version(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(f"Invalid three-part version: {version}")
    return tuple(int(part) for part in version.split("."))


def check_dependencies(contents):
    required = {"info.json", "control.lua", "data.lua", "settings.lua", "changelog.txt", "thumbnail.png"}
    for name, content in contents.items():
        if name.endswith(".lua"):
            source = content.decode()
            required.update(module.replace(".", "/") + ".lua" for module in LOCAL_REQUIRE.findall(source))
            required.update(LOCAL_ASSET.findall(source))
    missing = required.difference(contents)
    if missing:
        raise ValueError("Runtime dependencies absent from package manifest: " + ", ".join(sorted(missing)))


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
    check_dependencies({name: (root / name).read_bytes() for name in files})
    return sorted(files)


def load_targets(root):
    """Return the supported Factorio versions and the first source version built for all of them."""
    config = json.loads((root / "targets.json").read_text())
    versions = config.get("factorio_versions")
    if not isinstance(versions, list) or not versions or len(set(versions)) != len(versions):
        raise ValueError("targets.json must list unique factorio_versions")
    for version in versions:
        if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d", version):
            raise ValueError(f"Invalid Factorio version in targets.json: {version}")
    return versions, parse_version(config["first_version"])


def target_version(version, factorio_version):
    major, minor, patch = parse_version(version)
    if patch >= 100:
        raise ValueError(f"Patch {patch} cannot be combined with a game version; it must stay below 100")
    game_major, game_minor = (int(part) for part in factorio_version.split("."))
    combined = (game_major * 100 + game_minor * 10) * 100 + patch
    if combined > 65535:
        raise ValueError(f"Version {version} for Factorio {factorio_version} exceeds 65535")
    return f"{major}.{minor}.{combined}"


def target_overrides(root, factorio_version):
    """Read targets/<factorio version>/ without following symlinks, which could reach outside the repository."""
    overlay = root / "targets" / factorio_version
    for path in (overlay.parent, overlay):
        if path.is_symlink():
            raise ValueError(f"Target path {path.relative_to(root)} must not be a symlink")
    if not overlay.exists():
        return {}
    if not overlay.is_dir():
        raise ValueError(f"Target path {overlay.relative_to(root)} must be a directory")
    overrides = {}
    # os.walk lists symlinked directories without entering them, so every symlink is seen and rejected.
    for directory, subdirectories, filenames in os.walk(overlay):
        for entry in subdirectories + filenames:
            path = Path(directory) / entry
            if path.is_symlink():
                raise ValueError(f"Target path {path.relative_to(root)} must not be a symlink")
            if entry in filenames:
                if not path.is_file():
                    raise ValueError(f"Target path {path.relative_to(root)} must be a regular file")
                overrides[path.relative_to(overlay).as_posix()] = path.read_bytes()
    return overrides


def target_files(root, factorio_version):
    """Return the archive contents for one game version, keyed by path inside the mod."""
    root = Path(root)
    versions, first_version = load_targets(root)
    if factorio_version not in versions:
        raise ValueError(f"Factorio {factorio_version} is not listed in targets.json")
    files = package_files(root)
    contents = {name: (root / name).read_bytes() for name in files}
    overrides = target_overrides(root, factorio_version)
    for name, content in overrides.items():
        if name not in contents or name in ("info.json", "changelog.txt"):
            raise ValueError(f"Target file targets/{factorio_version}/{name} does not replace a packaged runtime file")
        contents[name] = content
    if overrides:
        check_dependencies(contents)

    info = json.loads(contents["info.json"])
    version = info.get("version", "")
    if parse_version(version) < first_version:
        raise ValueError(f"info.json version {version} predates the first multi-version release")
    info["version"] = target_version(version, factorio_version)
    info["factorio_version"] = factorio_version
    info["dependencies"] = [f"base >= {factorio_version}" if re.fullmatch(r"base(\s.*)?", dependency) else dependency
                            for dependency in info.get("dependencies", [])]
    contents["info.json"] = (json.dumps(info, indent=2) + "\n").encode()

    changelog = contents["changelog.txt"].decode()
    if version not in CHANGELOG_VERSION.findall(changelog):
        raise ValueError(f"changelog.txt has no entry for version {version}")
    # Entries before the first multi-version release keep the single version they shipped as.
    contents["changelog.txt"] = CHANGELOG_VERSION.sub(
        lambda match: match[0] if parse_version(match[1]) < first_version
        else "Version: " + target_version(match[1], factorio_version), changelog).encode()
    return contents


def build(root, factorio_version, output_dir=None, expected_version=None):
    root = Path(root)
    source_info = json.loads((root / "info.json").read_text())
    if expected_version is not None and source_info.get("version") != expected_version:
        raise ValueError(f"Tag version {expected_version} differs from info.json version {source_info.get('version')}")
    contents = target_files(root, factorio_version)
    info = json.loads(contents["info.json"])
    name, version = info.get("name", ""), info["version"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        raise ValueError("info.json must contain a valid mod name")
    output_dir = Path(output_dir) if output_dir else root / "dist"
    output_dir.mkdir(parents=True, exist_ok=True)
    prefix = f"{name}_{version}"
    archive = output_dir / f"{prefix}.zip"
    # Fixed ZIP timestamps and sorted entries make identical inputs reproducible.
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name in sorted(contents):
            entry = zipfile.ZipInfo(f"{prefix}/{name}", date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            package.writestr(entry, contents[name])
    with zipfile.ZipFile(archive) as package:
        if set(package.namelist()) != {f"{prefix}/{name}" for name in contents} or package.testzip() is not None:
            raise ValueError("Archive verification failed")
        for name, content in contents.items():
            if package.read(f"{prefix}/{name}") != content:
                raise ValueError(f"Archive content differs from source: {name}")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--expected-version", help="Require info.json to match a release tag")
    parser.add_argument("--target", action="append", metavar="FACTORIO_VERSION",
                        help="Build only this game version (repeatable); defaults to every version in targets.json")
    args = parser.parse_args()
    try:
        for factorio_version in args.target or load_targets(ROOT)[0]:
            print(build(ROOT, factorio_version, args.output_dir, args.expected_version))
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")


if __name__ == "__main__":
    main()
