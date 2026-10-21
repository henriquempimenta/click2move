#!/usr/bin/env python3
"""Optional native Factorio save/load and Hovercraft physics checks.

Run: python3 tests/engine/run.py --factorio /path/to/factorio --hovercraft /path/to/Hovercrafts_<version>
Add --target 2.0 when the executable is Factorio 2.0.
Uses only temporary config/mod/save directories. Production movement schedules
are captured and player/UI calls are mocked because headless saves have no
players. Entities, physics, rendering objects, storage and saves are native.
"""

import argparse
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from package import load_targets, target_files

SHIM = '''local c2m_test_bootstrap = script
local c2m_test_init_handler, c2m_test_load_handler, c2m_test_config_handler, c2m_test_tick_handler
local c2m_test_nth_handlers = {}
local c2m_test_expect_migration = false
script = setmetatable({}, {__index = c2m_test_bootstrap})
script.on_init = function(handler) c2m_test_init_handler = handler end
script.on_load = function(handler) c2m_test_load_handler = handler end
script.on_configuration_changed = function(handler) c2m_test_config_handler = handler end
script.on_event = function(event, handler, filters)
  if event == defines.events.on_tick then c2m_test_tick_handler = handler
  else c2m_test_bootstrap.on_event(event, handler, filters) end
end
script.on_nth_tick = function(interval, handler) c2m_test_nth_handlers[interval] = handler end
'''


FACTORIO_VERSION = load_targets(ROOT)[0][0]


# Supported drift modes and default vehicles for each Hovercrafts line. In 2.0.x the
# electric and laser hovercrafts also need the Laser Tanks mod, and New drift is
# unsupported: it reports reverse movement as positive speed, so braking a reversing
# hovercraft accelerates it. 2.0.x also ignores script_raised_built, so the test
# registers script-created vehicles itself.
HOVERCRAFT_PROFILES = {
    "2.1": (("new", "off", "old", "low-latency", "low-latency-b"),
            ("hovercraft", "missile-hovercraft", "electric-hovercraft", "laser-hovercraft"), False),
    "2.0": (("off", "old"), ("hovercraft", "missile-hovercraft"), True),
}


def install_mod(mod):
    """Write the packaged files for the selected game version into an unpacked mod directory."""
    for name, content in target_files(ROOT, FACTORIO_VERSION).items():
        target = mod / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


def run(command, log_path, timeout=120):
    with log_path.open("w") as log_file:
        result = subprocess.run(command, stdout=log_file, stderr=subprocess.STDOUT, timeout=timeout)
    output = log_path.read_text()
    if result.returncode:
        raise RuntimeError(f"Factorio failed ({result.returncode}); see {log_path}\n{output[-5000:]}")
    return output


def main():
    global FACTORIO_VERSION
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factorio", type=Path, required=True)
    parser.add_argument("--hovercraft", type=Path)
    parser.add_argument("--waypoints", action="store_true", help="Run native character/exoskeleton and car waypoint checks")
    parser.add_argument("--spiders", action="store_true", help="Run native spidertron autopilot ownership checks")
    parser.add_argument("--corners", action="store_true", help="Run native car and character cornering checks")
    parser.add_argument("--fast-cars", action="store_true", help="Run native high-speed vehicle corridor checks (needs the quality mod)")
    parser.add_argument("--physics", action="store_true", help="Measure native braking against production speed limits (needs the quality mod)")
    parser.add_argument("--profile-build", action="store_true", help="Profile trajectory construction in native Factorio (reports times without hardware-specific deadlines)")
    parser.add_argument("--debug-preview", action="store_true", help="Check Bezier/margin/reference rendering and zero movement in native Factorio")
    parser.add_argument("--vulcanus", action="store_true", help="Drive fast cars across generated Vulcanus terrain (needs Space Age)")
    parser.add_argument("--space-age", action="store_true", help="Enable Space Age and include native powered mech armor flight")
    parser.add_argument("--target", choices=load_targets(ROOT)[0], default=FACTORIO_VERSION,
                        help="Game version to package the mod for; must match the --factorio executable")
    args = parser.parse_args()
    FACTORIO_VERSION = args.target
    factorio = args.factorio.resolve()
    data = factorio.parents[2] / "data"
    workspace = Path(tempfile.mkdtemp(prefix="c2m-native-"))
    print(f"Native test workspace: {workspace}", flush=True)
    if args.waypoints:
        run_waypoints(factorio, data, workspace, args.space_age)
        return
    if args.spiders:
        run_spiders(factorio, data, workspace)
        return
    if args.corners:
        run_corners(factorio, data, workspace)
        return
    if args.fast_cars:
        run_fast_cars(factorio, data, workspace)
        return
    if args.physics:
        run_physics(factorio, data, workspace)
        return
    if args.profile_build:
        run_profile_build(factorio, data, workspace)
        return
    if args.debug_preview:
        run_debug_preview(factorio, data, workspace)
        return
    if args.vulcanus:
        run_vulcanus(factorio, data, workspace)
        return
    if args.hovercraft is None:
        parser.error("--hovercraft is required unless --waypoints is selected")
    hover_info = json.loads((args.hovercraft / "info.json").read_text())
    if hover_info["factorio_version"] != FACTORIO_VERSION:
        parser.error(f"Hovercrafts {hover_info['version']} is for Factorio {hover_info['factorio_version']}, not {FACTORIO_VERSION}")
    modes, models, register_built = HOVERCRAFT_PROFILES[hover_info["factorio_version"]]
    cases = len(models) * 3
    for mode in modes:
        root = workspace / mode
        mods = root / "mods"
        mod = mods / "click2move"
        mod.mkdir(parents=True)
        install_mod(mod)
        control = mod / "control.lua"
        control.write_text(SHIM + control.read_text() + "\n"
            + "local C2M_NATIVE_HOVERCRAFTS = {" + ", ".join(f'"{model}"' for model in models) + "}\n"
            + (ROOT / "tests/engine/fixture.lua").read_text())
        # Factorio requires a versioned mod folder name to match its info.json.
        hover_mod = mods / f"Hovercrafts_{hover_info['version']}"
        shutil.copytree(args.hovercraft, hover_mod)
        hover_control = hover_mod / "control.lua"
        with hover_control.open("a") as source:
            source.write('''
-- Test-only state seeding: Click2Move's on_init runs before Hovercrafts' on_init.
local c2m_test_register_built = ''' + ("true" if register_built else "false") + '''
remote.add_interface("c2m-native-hovercraft", {initialize = function(vehicle)
  if c2m_test_register_built and not storage.hovercrafts[vehicle.unit_number] then
    -- The record Hovercrafts 2.0.x writes in on_built_entity.
    storage.hovercrafts[vehicle.unit_number] = {entity = vehicle, drift = {x = 0, y = 0}, last_speed = 0,
      last_pos = vehicle.position, position = vehicle.position, idle_ticks = 0}
  end
  local state = assert(storage.hovercrafts[vehicle.unit_number], "hovercraft not registered")
  local angle = vehicle.orientation * 2 * math.pi
  state.drift = {x = math.sin(angle) * vehicle.speed, y = -math.cos(angle) * vehicle.speed}
  state.last_speed = vehicle.speed
  return true
end})
''')
        defaults = mods / "c2m-engine-settings"
        defaults.mkdir()
        (defaults / "info.json").write_text(json.dumps({"name": "c2m-engine-settings", "version": "1.0.0",
            "title": "Click2Move native fixture settings", "author": "test", "factorio_version": FACTORIO_VERSION,
            "dependencies": ["base", "click2move", "Hovercrafts"]}))
        (defaults / "settings-updates.lua").write_text(
            f'data.raw["string-setting"]["hovercraft-drifting"].default_value = "{mode}"\n')
        (mods / "mod-list.json").write_text(json.dumps({"mods": [{"name": name, "enabled": True}
            for name in ("base", "Hovercrafts", "click2move", "c2m-engine-settings")]
            + expansion_mods(args.space_age)}))
        write_data = root / "userdata"
        write_data.mkdir()
        config = root / "config.ini"
        config.write_text(f"[path]\nread-data={data}\nwrite-data={write_data}\n[other]\ncheck-updates=false\n")
        common = [str(factorio), "--config", str(config), "--mod-directory", str(mods)]
        save = root / "fixture.zip"
        run(common + ["--create", str(save), "--map-gen-seed", "1"], root / "create.log")
        output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "7200", "--benchmark-runs", "1"], root / "reload.log")
        if not all(marker in output for marker in ("C2M_NATIVE_RELOAD_OK", "C2M_NATIVE_CALLBACK_OK",
                "C2M_NATIVE_SCHEDULER_OK", f"C2M_NATIVE_STOPPING_OK {cases} {mode}")):
            raise RuntimeError(f"Missing native assertions for {mode}; see {root / 'reload.log'}")
        print(f"PASS {mode}: real save/load, restored braking/queue/render state, {cases} stopping cases", flush=True)
        if mode == modes[0]:
            info = json.loads((mod / "info.json").read_text())
            version = [int(part) for part in info["version"].split(".")]
            version[2] += 1
            info["version"] = ".".join(map(str, version))
            (mod / "info.json").write_text(json.dumps(info))
            control.write_text(control.read_text().replace("local c2m_test_expect_migration = false",
                "local c2m_test_expect_migration = true"))
            output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "7200", "--benchmark-runs", "1"], root / "migration.log")
            if not all(marker in output for marker in ("C2M_NATIVE_RELOAD_OK", "C2M_NATIVE_CALLBACK_OK",
                    "C2M_NATIVE_SCHEDULER_OK", f"C2M_NATIVE_STOPPING_OK {cases} {mode}")):
                raise RuntimeError(f"Configuration migration assertions failed; see {root / 'migration.log'}")
            print("PASS configuration migration preserves saved route and mocked disabled preference", flush=True)
    print(f"PASS {cases * len(modes)} native Hovercraft stopping scenarios, {len(modes)} save/load checks and configuration migration", flush=True)


def expansion_mods(enabled):
    # Official expansion mods default to enabled when omitted. Be explicit so
    # the base-only suite also verifies the mod's declared base dependency.
    return [{"name": name, "enabled": enabled}
            for name in ("space-age", "quality", "elevated-rails", "recycler")]


def run_waypoints(factorio, data, workspace, space_age):
    for interval in (1, 10, 60):
        root = workspace / str(interval)
        mods = root / "mods"
        mod = mods / "click2move"
        mod.mkdir(parents=True)
        install_mod(mod)
        control = mod / "control.lua"
        fixture = (ROOT / "tests/engine/waypoints.lua").read_text()
        control.write_text(SHIM + f"\nlocal C2M_NATIVE_INTERVAL = {interval}\n"
            + f"local C2M_NATIVE_WITH_SPACE_AGE = {str(space_age).lower()}\n"
            + control.read_text() + "\n" + fixture)
        (mods / "mod-list.json").write_text(json.dumps({"mods": [
            {"name": "base", "enabled": True}, {"name": "click2move", "enabled": True}]
            + expansion_mods(space_age)}))
        write_data = root / "userdata"
        write_data.mkdir()
        config = root / "config.ini"
        config.write_text(f"[path]\nread-data={data}\nwrite-data={write_data}\n[other]\ncheck-updates=false\n")
        common = [str(factorio), "--config", str(config), "--mod-directory", str(mods)]
        save = root / "fixture.zip"
        run(common + ["--create", str(save), "--map-gen-seed", "1"], root / "create.log")
        output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "3600", "--benchmark-runs", "1"], root / "reload.log")
        cases = 7 if space_age else 6
        if f"C2M_NATIVE_WAYPOINTS_OK {cases} interval={interval}" not in output:
            raise RuntimeError(f"Missing native waypoint assertions; see {root / 'reload.log'}")
        print(f"PASS interval {interval}: {cases} native waypoint/arrival cases, Space Age={space_age}", flush=True)
    print(f"PASS {cases * 3} native waypoint scenarios across intervals 1, 10 and 60", flush=True)


def run_spiders(factorio, data, workspace):
    mods = workspace / "spiders" / "mods"
    mod = mods / "click2move"
    mod.mkdir(parents=True)
    install_mod(mod)
    control = mod / "control.lua"
    control.write_text(control.read_text() + "\n" + (ROOT / "tests/engine/spiders.lua").read_text())
    (mods / "mod-list.json").write_text(json.dumps({"mods": [
        {"name": "base", "enabled": True}, {"name": "click2move", "enabled": True}] + expansion_mods(False)}))
    root = mods.parent
    write_data = root / "userdata"
    write_data.mkdir()
    config = root / "config.ini"
    config.write_text(f"[path]\nread-data={data}\nwrite-data={write_data}\n[other]\ncheck-updates=false\n")
    common = [str(factorio), "--config", str(config), "--mod-directory", str(mods)]
    save = root / "fixture.zip"
    run(common + ["--create", str(save), "--map-gen-seed", "1"], root / "create.log")
    output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "1900", "--benchmark-runs", "1"], root / "run.log")
    if "C2M_NATIVE_SPIDERS_OK 9" not in output:
        raise RuntimeError(f"Missing native spidertron assertions; see {root / 'run.log'}")
    distance = output.split("max_completion_distance=")[1].split()[0]
    foreign = output.split("foreign_at=")[1].split()[0]
    speedup = output.split("speedup=")[1].split()[0]
    print(f"PASS 9 native spidertron autopilot ownership scenarios (arrivals within {distance} tiles; "
          f"foreign completion from x={foreign} rejected; exoskeleton speedup {speedup}x)", flush=True)


def run_corners(factorio, data, workspace):
    total = 0
    for interval, cases in ((1, 210), (10, 210), (60, 210)):
        mods = workspace / f"corners-{interval}" / "mods"
        mod = mods / "click2move"
        mod.mkdir(parents=True)
        install_mod(mod)
        control = mod / "control.lua"
        control.write_text(f"local C2M_NATIVE_INTERVAL = {interval}\n" + control.read_text() + "\n"
            + (ROOT / "tests/engine/corners.lua").read_text())
        (mods / "mod-list.json").write_text(json.dumps({"mods": [
            {"name": "base", "enabled": True}, {"name": "click2move", "enabled": True}] + expansion_mods(False)}))
        root = mods.parent
        write_data = root / "userdata"
        write_data.mkdir()
        config = root / "config.ini"
        config.write_text(f"[path]\nread-data={data}\nwrite-data={write_data}\n[other]\ncheck-updates=false\n")
        common = [str(factorio), "--config", str(config), "--mod-directory", str(mods)]
        save = root / "fixture.zip"
        run(common + ["--create", str(save), "--map-gen-seed", "1"], root / "create.log")
        output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "3100", "--benchmark-runs", "1"], root / "run.log")
        marker = f"C2M_NATIVE_CORNERS_OK {cases} interval={interval}"
        if marker not in output:
            raise RuntimeError(f"Missing native cornering assertions; see {root / 'run.log'}")
        ticks = [int(tick) for tick in output.split(marker + " ticks=")[1].split()[0].split(",")]
        print(f"PASS interval {interval}: {cases} native cornering cases, slowest arrival {max(ticks)} ticks", flush=True)
        total += cases
    print(f"PASS {total} native cornering scenarios across intervals 1, 10 and 60", flush=True)


def run_fast_cars(factorio, data, workspace):
    for interval in (1, 10):
        mods = workspace / f"fast-cars-{interval}" / "mods"
        mod = mods / "click2move"
        mod.mkdir(parents=True)
        install_mod(mod)
        control = mod / "control.lua"
        control.write_text(f"local C2M_NATIVE_INTERVAL = {interval}\n" + control.read_text() + "\n"
            + (ROOT / "tests/engine/fast-cars.lua").read_text())
        # Quality needs the recycler; Space Age itself stays disabled.
        (mods / "mod-list.json").write_text(json.dumps({"mods": [
            {"name": "base", "enabled": True}, {"name": "click2move", "enabled": True},
            {"name": "space-age", "enabled": False}, {"name": "quality", "enabled": True},
            {"name": "elevated-rails", "enabled": False}, {"name": "recycler", "enabled": True}]}))
        root = mods.parent
        write_data = root / "userdata"
        write_data.mkdir()
        config = root / "config.ini"
        config.write_text(f"[path]\nread-data={data}\nwrite-data={write_data}\n[other]\ncheck-updates=false\n")
        common = [str(factorio), "--config", str(config), "--mod-directory", str(mods)]
        save = root / "fixture.zip"
        run(common + ["--create", str(save), "--map-gen-seed", "1"], root / "create.log")
        output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "5100", "--benchmark-runs", "1"], root / "run.log")
        marker = f"C2M_NATIVE_FAST_CARS_OK 13 interval={interval}"
        if marker not in output:
            raise RuntimeError(f"Missing native fast-car assertions; see {root / 'run.log'}")
        report = output.split(marker + " ticks:top_speed=")[1].split()[0]
        print(f"PASS interval {interval}: 13 native high-speed corridor cases (arrival ticks:top speed {report})", flush=True)
    print("PASS 26 native high-speed corridor scenarios across intervals 1 and 10", flush=True)


def run_debug_preview(factorio, data, workspace):
    root = workspace / "debug-preview"
    mod = root / "mods/click2move"
    mod.mkdir(parents=True)
    install_mod(mod)
    (mod / "control.lua").write_text((ROOT / "tests/engine/debug-preview.lua").read_text())
    (mod.parent / "mod-list.json").write_text(json.dumps({"mods": [
        {"name": "base", "enabled": True}, {"name": "click2move", "enabled": True}]
        + expansion_mods(False)}))
    write = root / "userdata"
    write.mkdir()
    config = root / "config.ini"
    config.write_text(f"[path]\nread-data={data}\nwrite-data={write}\n[other]\ncheck-updates=false\n")
    output = run([str(factorio), "--config", str(config), "--mod-directory", str(mod.parent),
                  "--create", str(root / "fixture.zip"), "--map-gen-seed", "1"], root / "create.log")
    if "C2M_NATIVE_BEZIER_PREVIEW_OK margins=5" not in output:
        raise RuntimeError(f"Missing native debug-preview assertions; see {root / 'create.log'}")
    output = run([str(factorio), "--config", str(config), "--mod-directory", str(mod.parent),
                  "--benchmark", str(root / "fixture.zip"), "--benchmark-ticks", "1", "--benchmark-runs", "1"], root / "reload.log")
    if "C2M_NATIVE_REFERENCE_RELOAD_OK" not in output:
        raise RuntimeError(f"Missing reference save/load assertions; see {root / 'reload.log'}")
    print("PASS native Bezier/reference/margin rendering at five margins, zero movement, cleanup and committed-reference save/load", flush=True)


def run_profile_build(factorio, data, workspace):
    root = workspace / "build-profile"
    mods = root / "mods"
    mod = mods / "click2move"
    mod.mkdir(parents=True)
    install_mod(mod)
    # Profilers only report duration; their values never affect game state.
    (mod / "control.lua").write_text((ROOT / "tests/engine/build-profile.lua").read_text())
    (mods / "mod-list.json").write_text(json.dumps({"mods": [
        {"name": "base", "enabled": True}, {"name": "click2move", "enabled": True}]
        + expansion_mods(False)}))
    write_data = root / "userdata"
    write_data.mkdir()
    config = root / "config.ini"
    config.write_text(f"[path]\nread-data={data}\nwrite-data={write_data}\n[other]\ncheck-updates=false\n")
    common = [str(factorio), "--config", str(config), "--mod-directory", str(mods)]
    save = root / "fixture.zip"
    run(common + ["--create", str(save), "--map-gen-seed", "1"], root / "create.log")
    output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "72", "--benchmark-runs", "1"],
                 root / "run.log", timeout=180)
    expected = {"short-turn", "native-hairpin", "native-hairpin-high", "winding400", "winding400-high",
                "winding1600", "stair1024", "stair4096", "stair16384", "straight16384", "zigzag4096", "zigzag16384"}
    summary = "C2M_NATIVE_BUILD_PROFILE_OK cases=12 trials=60"
    if output.splitlines().count(summary) != 1:
        raise RuntimeError(f"Missing complete native build profile; see {root / 'run.log'}")
    pattern = re.compile(r"C2M_BUILD_PROFILE case=(\S+) trial=(\d+) nodes=(\d+) pieces=(\d+) arcs=(\d+) "
                         r"radius=([\d.]+) work=(\d+) limit=(\d+) attempts=(\d+) total=Duration: ([\d.]+)ms")
    cases = {}
    for line in output.splitlines():
        if "C2M_BUILD_PROFILE " not in line:
            continue
        match = pattern.search(line)
        if not match:
            raise RuntimeError(f"Malformed native build measurement; see {root / 'run.log'}")
        name = match[1]
        trial, nodes, pieces, arcs = map(int, match.group(2, 3, 4, 5))
        radius = float(match[6])
        work, limit, attempts = map(int, match.group(7, 8, 9))
        milliseconds = float(match[10])
        trials = cases.setdefault(name, {})
        if name not in expected or trial in trials or not 1 <= trial <= 5 or not 0 <= work <= limit:
            raise RuntimeError(f"Invalid native build measurement; see {root / 'run.log'}")
        trials[trial] = (milliseconds, nodes, pieces, arcs, radius, work, limit, attempts)
    if set(cases) != expected or any(set(trials) != set(range(1, 6)) for trials in cases.values()):
        raise RuntimeError(f"Incomplete native build measurements; see {root / 'run.log'}")
    for name, trials in cases.items():
        measurements = list(trials.values())
        if len({row[1:] for row in measurements}) != 1:
            raise RuntimeError(f"Non-deterministic build metadata for {name}; see {root / 'run.log'}")
        times = [row[0] for row in measurements]
        _, nodes, pieces, arcs, radius, work, limit, attempts = measurements[0]
        print(f"PROFILE {name}: median={statistics.median(times):.3f}ms max={max(times):.3f}ms "
              f"nodes={nodes} pieces={pieces} arcs={arcs} tightest_radius={radius:g} "
              f"work={work}/{limit} attempts={attempts}", flush=True)
    print("PASS 12 native trajectory build profiles, 60 measured builds within the refinement work budget", flush=True)


def run_physics(factorio, data, workspace):
    root = workspace / "physics"
    mods = root / "mods"
    mod = mods / "click2move"
    mod.mkdir(parents=True)
    install_mod(mod)
    # The fixture imports the production speed planner directly. It uses native
    # entities and event scheduling and does not install any player/UI shims.
    (mod / "control.lua").write_text((ROOT / "tests/engine/physics.lua").read_text())
    (mods / "mod-list.json").write_text(json.dumps({"mods": [
        {"name": "base", "enabled": True}, {"name": "click2move", "enabled": True},
        {"name": "space-age", "enabled": False}, {"name": "quality", "enabled": True},
        {"name": "elevated-rails", "enabled": False}, {"name": "recycler", "enabled": True}]}))
    write_data = root / "userdata"
    write_data.mkdir()
    config = root / "config.ini"
    config.write_text(f"[path]\nread-data={data}\nwrite-data={write_data}\n[other]\ncheck-updates=false\n")
    common = [str(factorio), "--config", str(config), "--mod-directory", str(mods)]
    save = root / "fixture.zip"
    run(common + ["--create", str(save), "--map-gen-seed", "1"], root / "create.log")
    output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "4100", "--benchmark-runs", "1"],
                 root / "run.log")
    marker = "C2M_NATIVE_PHYSICS_OK 48 actual native braking distances and live friction cache changes"
    if marker not in output:
        raise RuntimeError(f"Missing native physics assertions; see {root / 'run.log'}")
    print("PASS 48 native braking scenarios: car/tank, normal/legendary, fueled/unfueled, "
          "zero/tiny/stock friction, 100/300 tiles and live friction cache changes", flush=True)


def parse_vulcanus_result(output, interval, log_path):
    """Require the engine's complete result, including coverage-only failures."""
    marker = "C2M_NATIVE_VULCANUS_DONE"
    summaries = [line.strip() for line in output.splitlines() if marker in line]
    if len(summaries) != 1:
        raise RuntimeError(f"Expected one native Vulcanus summary, found {len(summaries)}; see {log_path}")
    summary = summaries[0]
    match = re.fullmatch(r"C2M_NATIVE_VULCANUS_DONE (\d+) interval=(\d+) reachable=(\d+) failures=(\d+)", summary)
    if not match:
        raise RuntimeError(f"Malformed native Vulcanus summary: {summary}; see {log_path}")
    sites, observed_interval, reachable, failures = map(int, match.groups())
    route_failures = [line.split("C2M_VULCANUS FAIL ", 1)[1]
                      for line in output.splitlines() if "C2M_VULCANUS FAIL " in line]
    if observed_interval != interval or not 8 <= reachable <= sites or failures or route_failures:
        details = "\n".join(route_failures)
        raise RuntimeError(f"Native Vulcanus failed: {summary}; expected interval={interval} and at least 8 reachable routes; "
                           f"see {log_path}" + ("\n" + details if details else ""))
    return summary[len(marker) + 1:]


def run_vulcanus(factorio, data, workspace):
    failed = []
    for interval in (1, 10):
        mods = workspace / f"vulcanus-{interval}" / "mods"
        mod = mods / "click2move"
        mod.mkdir(parents=True)
        install_mod(mod)
        control = mod / "control.lua"
        control.write_text(f"local C2M_NATIVE_INTERVAL = {interval}\n" + control.read_text() + "\n"
            + (ROOT / "tests/engine/vulcanus.lua").read_text())
        (mods / "mod-list.json").write_text(json.dumps({"mods": [
            {"name": "base", "enabled": True}, {"name": "click2move", "enabled": True}] + expansion_mods(True)}))
        root = mods.parent
        write_data = root / "userdata"
        write_data.mkdir()
        config = root / "config.ini"
        config.write_text(f"[path]\nread-data={data}\nwrite-data={write_data}\n[other]\ncheck-updates=false\n")
        common = [str(factorio), "--config", str(config), "--mod-directory", str(mods)]
        save = root / "fixture.zip"
        run(common + ["--create", str(save), "--map-gen-seed", "1"], root / "create.log")
        output = run(common + ["--benchmark", str(save), "--benchmark-ticks", "40000", "--benchmark-runs", "1"],
                     root / "run.log", timeout=900)
        try:
            summary = parse_vulcanus_result(output, interval, root / "run.log")
        except RuntimeError as error:
            failed.append(str(error))
            print(f"FAIL interval {interval}: {error}", flush=True)
        else:
            print(f"PASS {summary}", flush=True)
    if failed:
        raise RuntimeError("Vulcanus routes failed:\n" + "\n".join(failed))


if __name__ == "__main__":
    main()
