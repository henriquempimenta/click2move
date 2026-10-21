#!/usr/bin/env python3
"""Measure construction cost and actual driving with isolated work budgets.

Uses the existing native suites, never edits the installed mod or real saves.
Performance deadlines/speed floors are recorded rather than asserted in these
experiments; collision, stuck-recovery, completion and destination checks remain.
Run sequentially without other CPU benchmarks for useful construction timings.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError(f"Benchmark fixture changed; cannot replace {old[:70]!r}")
    return source.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factorio", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--target", choices=["2.0", "2.1"], default="2.1")
    current = int(re.search(r"Trajectory.WORK_LIMIT = (\d+)", (ROOT / "scripts/vehicle-trajectory.lua").read_text())[1])
    parser.add_argument("--budgets", nargs="+", type=int, default=list(dict.fromkeys([10240, current, 40960, 0])))
    args = parser.parse_args()
    if min(args.budgets) < 0:
        parser.error("budgets cannot be negative")
    version = subprocess.check_output([str(args.factorio.resolve()), "--version"], text=True)
    if not re.search(r"^Version: " + re.escape(args.target) + r"\.", version, re.M):
        parser.error("--target must match the Factorio executable")
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "metadata.json").write_text(json.dumps(dict(
        factorio=version, target=args.target, platform=platform.platform(), budgets=args.budgets,
        commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        protocol="Sequential, five measured native builds after warmup; default driving world/physics at intervals 1 and 10. Performance limits recorded, safety checks asserted."), indent=2) + "\n")
    spec = importlib.util.spec_from_file_location("c2m_native_runner", ROOT / "tests/engine/run.py")
    engine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(engine)
    engine.FACTORIO_VERSION = args.target
    from package import package_files
    summaries = []
    for budget in args.budgets:
        workspace = args.output / f"budget-{budget}"
        source = workspace / "source"
        source.mkdir(parents=True)
        for name in package_files(ROOT) + ["targets.json", "package-manifest.json",
                                          "tests/engine/build-profile.lua", "tests/engine/fast-cars.lua"]:
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        if (ROOT / "targets").exists():
            shutil.copytree(ROOT / "targets", source / "targets")
        trajectory = source / "scripts/vehicle-trajectory.lua"
        configured = re.search(r"Trajectory.WORK_LIMIT = \d+", trajectory.read_text())[0]
        trajectory.write_text(replace_once(trajectory.read_text(), configured,
                                          f"Trajectory.WORK_LIMIT = {budget}"))
        fast = source / "tests/engine/fast-cars.lua"
        fixture = replace_once(fast.read_text(),
            'assert(case.top >= MIN_TOP_SPEED[i], string.format("%s was too slow: peak %.3f, minimum %.3f",\n'
            '      case.name, case.top, MIN_TOP_SPEED[i]))',
            'log(string.format("C2M_BENCH_SPEED case=%d observed=%.8f minimum=%.8f", i, case.top, MIN_TOP_SPEED[i]))')
        fixture = replace_once(fixture,
            'assert(case.ticks and case.ticks <= deadline, string.format("%s took %s ticks, maximum %d",\n'
            '      case.name, tostring(case.ticks), deadline))',
            'log(string.format("C2M_BENCH_DEADLINE case=%d observed=%d maximum=%d", i, case.ticks or -1, deadline))')
        fast.write_text(fixture)
        engine.ROOT = source
        engine.run_profile_build(args.factorio.resolve(), args.factorio.resolve().parents[2] / "data", workspace)
        engine.run_fast_cars(args.factorio.resolve(), args.factorio.resolve().parents[2] / "data", workspace)
        rows = []
        for interval in [1, 10]:
            text = (workspace / f"fast-cars-{interval}/run.log").read_text()
            speeds = {int(i): (float(v), float(minimum)) for i, v, minimum in re.findall(
                r"C2M_BENCH_SPEED case=(\d+) observed=([\d.]+) minimum=([\d.]+)", text)}
            deadlines = {int(i): (int(v), int(maximum)) for i, v, maximum in re.findall(
                r"C2M_BENCH_DEADLINE case=(\d+) observed=(-?\d+) maximum=(\d+)", text)}
            if set(speeds) != set(range(1, 14)) or set(deadlines) != set(speeds):
                raise RuntimeError("Incomplete native driving measurements")
            for case in speeds:
                peak, minimum = speeds[case]
                ticks, maximum = deadlines[case]
                rows.append(dict(case=case, interval=interval, ticks=ticks, peak=peak,
                                 speed_floor=minimum, deadline=maximum, meets_performance=ticks <= maximum and peak >= minimum))
        summaries.append(dict(budget=budget, driving=rows))
        print(f"BENCHMARK budget={budget}: safety passed; {sum(not r['meets_performance'] for r in rows)} of 26 performance limits missed", flush=True)
        (args.output / "driving.json").write_text(json.dumps(summaries, indent=2) + "\n")


if __name__ == "__main__":
    main()
