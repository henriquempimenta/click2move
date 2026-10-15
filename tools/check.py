#!/usr/bin/env python3
"""Run runtime/test Lua syntax checks, regression scripts, and packaging tests."""

import os
from pathlib import Path
import shutil
import subprocess
import sys

from package import package_files


def main():
    root = Path(__file__).resolve().parents[1]
    lua = os.environ.get("LUA") or shutil.which("lua5.2") or shutil.which("lua")
    luac = os.environ.get("LUAC") or shutil.which("luac5.2") or shutil.which("luac")
    if not lua or not luac:
        sys.exit("Install Lua and luac (CI uses Lua 5.2) before running checks")
    tests = sorted(root.glob("tests/*.lua"))
    support = sorted(root.glob("tests/support/*.lua"))
    runtime = [root / name for name in package_files(root) if name.endswith(".lua")]
    for source in runtime + support + tests:
        subprocess.run([luac, "-p", str(source)], cwd=root, check=True)
    print(f"Lua syntax passed for {len(runtime)} runtime files and {len(tests)} test scripts", flush=True)
    for test in tests:
        print(f"Running {test.relative_to(root)}", flush=True)
        subprocess.run([lua, str(test.relative_to(root))], cwd=root, check=True)
    subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tools", "-p", "test_*.py"],
                   cwd=root, check=True)


if __name__ == "__main__":
    main()
