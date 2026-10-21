#!/usr/bin/env python3
"""Offline curve experiments; never imported or packaged by the mod.

Requires numpy, scipy, cvxpy and matplotlib. Run from any directory:
  python tools/benchmark_curves.py --lua lua5.2 --output /tmp/c2m-curves

Compares production trajectories at three work budgets, the article's SOCP
followed by production smoothing, and globally fitted C2 cubic Bezier curves.
Times for Python solvers are NOT estimates of Lua execution cost. Native
Factorio construction/driving benchmarks remain separate (tests/engine/run.py).
"""

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time

import cvxpy as cp
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOLVER_STATUSES = {}
LAST_SOLVER_STATUS = None


def cases():
    fixture = (ROOT / "tests/engine/build-profile.lua").read_text()
    trace = re.search(r"local hairpin_trace = \[\[(.*?)\]\]", fixture, re.S)[1]
    hairpin = [[float(x), float(y)] for x, y in re.findall(r"([-\d.]+),([-\d.]+)", trace)]
    assert len(hairpin) == 403
    return {
        "right-angle": [[0, 0], [100, 0], [100, 100]],
        "short-turn": [[0, 0], [4, 0], [4, 4]],
        "s-bend": [[0, 0], [60, 0], [60, 40], [120, 40]],
        "lane-shift": [[0, 0], [174, 0], [177, 3], [295, 3], [295, 100]],
        "native-hairpin": hairpin,
        "zigzag16": [[i * 10, (i % 2) * 10] for i in range(16)],
        "stair128": [[i, i // 2] for i in range(128)],
    }


def collapse(points):
    """Remove duplicates and exactly collinear forward nodes, preserving bends."""
    result = []
    for p in np.asarray(points, dtype=float):
        if result and np.linalg.norm(p - result[-1]) < 1e-10:
            continue
        while len(result) > 1:
            a, b = result[-1] - result[-2], p - result[-1]
            if abs(a[0] * b[1] - a[1] * b[0]) > 1e-10 or a @ b <= 0:
                break
            result.pop()
        result.append(p)
    return np.array(result)


def lua_literal(value):
    if isinstance(value, dict):
        return "{" + ",".join(f"[{json.dumps(k)}]={lua_literal(v)}" for k, v in value.items()) + "}"
    if isinstance(value, (list, tuple, np.ndarray)):
        return "{" + ",".join(lua_literal(v) for v in value) + "}"
    return json.dumps(value)


def build_lua(requests, lua):
    with tempfile.TemporaryDirectory(prefix="c2m-curve-input-") as tmp:
        input_path = Path(tmp) / "input.lua"
        input_path.write_text("return " + lua_literal(requests))
        result = subprocess.run([lua, str(ROOT / "tools/benchmark_trajectory.lua"), str(input_path)],
                                cwd=ROOT, capture_output=True, text=True, check=True)
    return {row["id"]: row for row in map(json.loads, result.stdout.splitlines())}


def solve(problem):
    global LAST_SOLVER_STATUS
    problem.solve(solver="CLARABEL", tol_gap_abs=1e-8, tol_gap_rel=1e-8,
                  tol_feas=1e-9, max_iter=300)
    SOLVER_STATUSES[problem.status] = SOLVER_STATUSES.get(problem.status, 0) + 1
    LAST_SOLVER_STATUS = problem.status
    if problem.status not in (cp.OPTIMAL, cp.OPTIMAL_INACCURATE):
        raise RuntimeError(f"no solver candidate: {problem.status}")
    # An inaccurate termination is not an optimality certificate. Such a
    # candidate is retained only if the independent geometry checks pass.


def article_path(points, allowance, initial_heading=True):
    p = collapse(points)
    q = cp.Variable(p.shape)
    constraints = [q[0] == p[0], q[-1] == p[-1],
                   cp.norm(q - p, axis=1) <= allowance * (1 - 1e-5)]
    # Retain the initial direction for a meaningful steering comparison.
    # End heading is free, as in the production terminal-circle construction.
    u = (p[1] - p[0]) / np.linalg.norm(p[1] - p[0])
    if initial_heading:
        constraints += [(q[1, 0] - q[0, 0]) * u[1] == (q[1, 1] - q[0, 1]) * u[0],
                        (q[1] - q[0]) @ u >= 1e-6]
    problem = cp.Problem(cp.Minimize(cp.sum(cp.norm(q[1:] - q[:-1], axis=1))), constraints)
    solve(problem)
    result = q.value
    if np.max(np.linalg.norm(result - p, axis=1)) > allowance + 1e-7:
        raise RuntimeError("SOCP violates its disk constraints")
    return result


def bezier_path(points, allowance, bending_weight):
    """Cubic control-point bounds prove whole-curve containment, not just samples.

    Reference controls describe each original straight leg. If each candidate
    control stays within epsilon of its reference control, Bernstein convexity
    bounds the error everywhere on that leg. C1/C2 matching uses original arc
    length as parameter. The bending term is a convex parameter-space surrogate,
    NOT geometric curvature energy or a globally optimal driving-time objective.
    """
    original = collapse(points)
    refined = [original[0]]
    # Local knots are essential: one cubic spanning a 100-tile leg cannot
    # change direction inside a sub-tile allowance at its far endpoint.
    for a, z in zip(original[:-1], original[1:]):
        length = np.linalg.norm(z-a)
        fractions = {0.5, 1.0}
        for multiplier in [1, 2, 4, 8]:
            fraction = allowance * multiplier / length
            if fraction < .45:
                fractions.update([fraction, 1-fraction])
        refined.extend(a + t*(z-a) for t in sorted(fractions))
    p = np.array(refined)
    h = np.linalg.norm(np.diff(p, axis=0), axis=1)
    n = len(h)
    b = cp.Variable((n * 4, 2))
    reference = np.concatenate([p[i] + np.arange(4)[:, None] / 3 * (p[i + 1] - p[i])
                                for i in range(n)])
    constraints = [cp.norm(b - reference, axis=1) <= allowance * (1 - 1e-5),
                   b[0] == p[0], b[-1] == p[-1]]
    u = (p[1] - p[0]) / h[0]
    constraints += [(b[1, 0] - b[0, 0]) * u[1] == (b[1, 1] - b[0, 1]) * u[0]]
    nodes, weights = np.polynomial.legendre.leggauss(12)
    nodes, weights = (nodes + 1) / 2, weights / 2
    c0, c1, c2, c3 = b[0::4], b[1::4], b[2::4], b[3::4]
    d0, d1, d2 = c1-c0, c2-c1, c3-c2
    tangents = np.diff(p, axis=0) / h[:, None]
    for d in [d0, d1, d2]:
        constraints.append(cp.sum(cp.multiply(d, tangents), axis=1) >= h*1e-7)
    length = sum(w * cp.sum(cp.norm(3*((1-t)**2*d0 + 2*t*(1-t)*d1 + t*t*d2), axis=1))
                 for t, w in zip(nodes, weights))
    a, z = c2-2*c1+c0, c3-2*c2+c1
    bending = cp.sum(cp.multiply(6/h**3, cp.sum(cp.square(a+z)+cp.square(a)+cp.square(z), axis=1)))
    constraints += [c3[:-1] == c0[1:],
                    cp.multiply(1/h[:-1, None], d2[:-1]) == cp.multiply(1/h[1:, None], d0[1:]),
                    cp.multiply(1/h[:-1, None]**2, z[:-1]) == cp.multiply(1/h[1:, None]**2, a[1:])]
    problem = cp.Problem(cp.Minimize(length + bending_weight * bending), constraints)
    solve(problem)
    controls = b.value.reshape(n, 4, 2)
    if np.max(np.linalg.norm(b.value - reference, axis=1)) > allowance + 1e-7:
        raise RuntimeError("Bezier control-point containment certificate failed")
    for i in range(1, n):
        a, z = controls[i-1], controls[i]
        if (np.linalg.norm(a[3]-z[0]) > 1e-6
                or np.linalg.norm((a[3]-a[2])/h[i-1]-(z[1]-z[0])/h[i]) > 1e-6
                or np.linalg.norm((a[3]-2*a[2]+a[1])/h[i-1]**2
                                  -(z[2]-2*z[1]+z[0])/h[i]**2) > 1e-6):
            raise RuntimeError("Bezier continuity check failed")
    return controls


def sample_bezier(controls):
    positions, curvature = [], []
    for b in controls:
        control_length = np.linalg.norm(np.diff(b, axis=0), axis=1).sum()
        # A fixed minimum also resolves tight changes near short-leg endpoints.
        # Include curvature extrema: a uniform sample alone can miss a narrow
        # peak. For k=N/V^(3/2), stationary points solve 2*N'*V-3*N*V'=0.
        cross = lambda a, z: a[0]*z[1]-a[1]*z[0]
        da, db, dc = 3*(-b[0]+3*b[1]-3*b[2]+b[3]), 6*(b[0]-2*b[1]+b[2]), 3*(b[1]-b[0])
        numerator = np.array([cross(dc, db), 2*cross(dc, da), cross(db, da)])
        velocity = np.polynomial.polynomial.polyadd(
            np.polynomial.polynomial.polymul([dc[0], db[0], da[0]], [dc[0], db[0], da[0]]),
            np.polynomial.polynomial.polymul([dc[1], db[1], da[1]], [dc[1], db[1], da[1]]))
        equation = np.polynomial.polynomial.polysub(
            2*np.polynomial.polynomial.polymul(np.polynomial.polynomial.polyder(numerator), velocity),
            3*np.polynomial.polynomial.polymul(numerator, np.polynomial.polynomial.polyder(velocity)))
        roots = np.polynomial.polynomial.polyroots(equation)
        critical = [float(r.real) for r in roots if abs(r.imag) < 1e-8 and 0 < r.real < 1]
        t = np.unique(np.r_[np.linspace(0, 1, max(257, int(control_length / .1) + 1)), critical])[:, None]
        p = (1-t)**3*b[0]+3*(1-t)**2*t*b[1]+3*(1-t)*t*t*b[2]+t**3*b[3]
        d = 3*((1-t)**2*(b[1]-b[0])+2*(1-t)*t*(b[2]-b[1])+t*t*(b[3]-b[2]))
        dd = 6*((1-t)*(b[2]-2*b[1]+b[0])+t*(b[3]-2*b[2]+b[1]))
        speed = np.linalg.norm(d, axis=1)
        if np.min(speed) < 1e-9:
            raise RuntimeError("non-regular Bezier curve")
        k = abs(d[:, 0]*dd[:, 1]-d[:, 1]*dd[:, 0]) / speed**3
        positions.extend(p)
        curvature.extend(k)
    return np.array(positions), np.array(curvature)


def sample_plan(plan, midpoint_checks=None):
    positions, curvature, jump = [], [], 0
    previous, previous_end = None, None
    for index, s in enumerate(plan["segments"]):
        a = np.array([s["a"]["x"], s["a"]["y"]])
        tangent = np.array([s["tangent"]["x"], s["tangent"]["y"]])
        if previous_end is not None and np.linalg.norm(previous_end-a) > 1e-6:
            raise RuntimeError("trajectory has a gap between pieces")
        previous_end = np.array([s["b"]["x"], s["b"]["y"]])
        if previous is not None and s["length"] > 1e-7:
            jump = max(jump, math.acos(np.clip(previous @ tangent, -1, 1)))
        n = max(2, math.ceil(s["length"] / .1) + 1)
        t = np.linspace(0, 1, n)
        if "radius" in s:
            sweep, radius = s["sweep"], s["radius"]
            # Same local representation as production arc_coordinates.
            angle = abs(sweep) * t
            along = radius * np.sin(angle)
            across = radius * 2 * np.sin(angle / 2)**2 * np.sign(sweep)
            p = a + along[:, None]*tangent + across[:, None]*np.array([-tangent[1], tangent[0]])
            k = np.full(n, 1 / radius)
            previous = np.array([tangent[0]*math.cos(sweep)-tangent[1]*math.sin(sweep),
                                 tangent[1]*math.cos(sweep)+tangent[0]*math.sin(sweep)])
        else:
            z = np.array([s["b"]["x"], s["b"]["y"]])
            p, k = a + t[:, None]*(z-a), np.zeros(n)
            if s["length"] > 1e-7:
                previous = tangent
        if midpoint_checks is not None:
            if "radius" in s:
                angle = abs(s["sweep"]) / 2
                midpoint = a + s["radius"]*math.sin(angle)*tangent + s["radius"]*2*math.sin(angle/2)**2*np.sign(s["sweep"])*np.array([-tangent[1], tangent[0]])
            else:
                midpoint = (a+previous_end)/2
            if np.linalg.norm(midpoint-np.array(midpoint_checks[index])) > 1e-7:
                raise RuntimeError("offline sampler differs from production")
        positions.extend(p)
        curvature.extend(k)
    return np.array(positions), np.array(curvature), jump


def distance_to_path(samples, points):
    points = collapse(points)
    a, d = points[:-1], np.diff(points, axis=0)
    length2 = np.sum(d*d, axis=1)
    distances = []
    for chunk in np.array_split(samples, max(1, math.ceil(len(samples) / 2048))):
        offsets = chunk[:, None, :] - a
        t = np.clip(np.sum(offsets*d, axis=2) / length2, 0, 1)
        distances.extend(np.sqrt(np.min(np.sum((offsets-t[:, :, None]*d)**2, axis=2), axis=1)))
    return np.array(distances)


def quality(samples, curvature, points, clearance, jump=0):
    distances = distance_to_path(samples, points)
    if distances.max() > clearance + 1e-6:
        raise RuntimeError(f"curve left corridor: {distances.max()} > {clearance}")
    p = np.asarray(points)
    endpoint_error = max(np.linalg.norm(samples[0]-p[0]), np.linalg.norm(samples[-1]-p[-1]))
    if endpoint_error > 1e-6:
        raise RuntimeError("curve changed an endpoint")
    ds = np.linalg.norm(np.diff(samples, axis=0), axis=1)
    length = float(ds.sum())
    kmax = float(curvature.max())
    # Diagnostic ceiling from the production car turning law: v=(2*pi*.015*.9*R)^2.
    # Instant acceleration/braking, no tracking error; this is NOT arrival time.
    caps = np.minimum(1.25, (.9 * 2 * math.pi * .015 / np.maximum(curvature, 1e-15))**2)
    curve_ticks = float(np.sum(ds * .5 * (1/caps[:-1] + 1/caps[1:])))
    return dict(length=length, min_radius=1/kmax if kmax else None,
                max_offset=float(distances.max()), endpoint_error=float(endpoint_error),
                join_jump_degrees=math.degrees(jump),
                # Near-cusps make this sampling integral unreliable and cannot
                # be followed at useful speed. Report their radius, not a
                # misleading numerical travel time across a near singularity.
                curvature_only_seconds=curve_ticks/60 if jump < .01 and kmax < 100 else None)


def self_check():
    # Independent analytic reference from the article: a V with epsilon=.25.
    # The solver's small numerical reserve raises the optimum slightly.
    v = article_path([[-1, 0], [0, 1], [1, 0]], .25, initial_heading=False)
    assert abs(np.linalg.norm(np.diff(v, axis=0), axis=1).sum()-2.5) < 1e-5
    p, k = sample_bezier(np.array([[[0., 0], [1., 0], [2., 0], [3., 0]]]))
    q = quality(p, k, [[0, 0], [3, 0]], .01)
    assert q["min_radius"] is None and abs(q["curvature_only_seconds"]-.04) < 1e-10
    # Check polynomial extrema against an independent dense derivative evaluation.
    b = np.array([[0., 0], [10., 0], [10., 10], [0., 10]])
    _, k = sample_bezier(b[None, :, :])
    t = np.linspace(0, 1, 100001)[:, None]
    d = 3*((1-t)**2*(b[1]-b[0])+2*(1-t)*t*(b[2]-b[1])+t*t*(b[3]-b[2]))
    dd = 6*((1-t)*(b[2]-2*b[1]+b[0])+t*(b[3]-2*b[2]+b[1]))
    dense = abs(d[:, 0]*dd[:, 1]-d[:, 1]*dd[:, 0])/np.linalg.norm(d, axis=1)**3
    assert abs(k.max()-dense.max()) < 1e-6
    print("PASS analytic V optimum, straight traversal diagnostic and curvature-extrema checks", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=20)
    parser.add_argument("--solver-repeats", type=int, default=3)
    parser.add_argument("--bending-weights", nargs="+", type=float, default=[0, 1, 10, 100, 1000])
    parser.add_argument("--cases", nargs="+", choices=list(cases()))
    parser.add_argument("--clearances", nargs="+", type=float, default=[.36, 1.11, 2.08, 3])
    args = parser.parse_args()
    if min(args.repeats, args.solver_repeats) < 2 or min(args.clearances) <= 0 or min(args.bending_weights) < 0:
        parser.error("need at least two repeats and positive clearances")
    args.output.mkdir(parents=True, exist_ok=True)
    self_check()
    default_work = int(re.search(r"Trajectory.WORK_LIMIT = (\d+)", (ROOT / "scripts/vehicle-trajectory.lua").read_text())[1])
    selected = {k: v for k, v in cases().items() if not args.cases or k in args.cases}
    records, curves, requests, pending, failures = [], {}, [], [], []
    for case, points in selected.items():
        for clearance in args.clearances:
            for mode, work in [("current", default_work), ("budget-10k", 10240), ("fillets-only", 0)]:
                key = f"{case}/{clearance}/{mode}"
                requests.append(dict(id=key, points=points, clearance=clearance, work=work, repeats=args.repeats))
                pending.append((key, case, clearance, mode, points, 0, []))
    baseline = build_lua(requests, args.lua)
    for case, points in selected.items():
        for clearance in args.clearances:
            key = f"{case}/{clearance}/socp-plus-smoothing"
            solve_times, statuses = [], []
            for _ in range(args.solver_repeats):
                start = time.perf_counter()
                optimized = article_path(points, clearance * .5)
                solve_times.append((time.perf_counter() - start) * 1000)
                statuses.append(LAST_SOLVER_STATUS)
            elapsed = float(np.median(solve_times))
            pending.append((key, case, clearance, "socp-plus-smoothing", optimized.tolist(), elapsed, statuses))
            result = build_lua([dict(id=key, points=optimized.tolist(), clearance=clearance*.5,
                                     work=default_work, repeats=args.repeats)], args.lua)
            baseline.update(result)
            for weight in args.bending_weights:
                mode = f"bezier-c2-weight-{weight:g}"
                key = f"{case}/{clearance}/{mode}"
                solve_times, statuses = [], []
                try:
                    for _ in range(args.solver_repeats):
                        start = time.perf_counter()
                        controls = bezier_path(points, clearance, weight)
                        solve_times.append((time.perf_counter() - start) * 1000)
                        statuses.append(LAST_SOLVER_STATUS)
                except (RuntimeError, cp.error.SolverError) as error:
                    failures.append(dict(case=case, clearance=clearance, mode=mode, reason=str(error)))
                    print(f"REJECTED {key}: {error}", flush=True)
                    continue
                elapsed = float(np.median(solve_times))
                samples, curvature = sample_bezier(controls)
                metrics = quality(samples, curvature, points, clearance)
                records.append(dict(case=case, clearance=clearance, mode=mode, raw_nodes=len(points),
                                    build_median_ms=elapsed, build_p95_ms=float(np.percentile(solve_times, 95)), build_samples=len(solve_times),
                                    lua_build_median_ms=None, python_optimizer_ms=elapsed,
                                    optimizer_statuses="|".join(statuses), **metrics))
                curves[key] = dict(points=samples.tolist(), controls=controls.tolist(), optimizer_times_ms=solve_times)
            print(f"Solved {case} allowance={clearance}", flush=True)
    for key, case, clearance, mode, points, optimizer_ms, statuses in pending:
        result = baseline[key]
        plan = result["plan"]
        samples, curvature, jump = sample_plan(plan, result["midpoint_checks"])
        metrics = quality(samples, curvature, selected[case], clearance, jump)
        times = np.array(result["times_ms"])
        records.append(dict(case=case, clearance=clearance, mode=mode, raw_nodes=len(selected[case]),
                            build_median_ms=float(np.median(times))+optimizer_ms,
                            build_p95_ms=float(np.percentile(times, 95)) if not optimizer_ms else None,
                            build_samples=len(times) if not optimizer_ms else 1,
                            lua_build_median_ms=float(np.median(times)), python_optimizer_ms=optimizer_ms,
                            optimizer_statuses="|".join(statuses),
                            **metrics))
        curves[key] = dict(points=samples.tolist(), times_ms=times.tolist())
    (args.output / "results.json").write_text(json.dumps(records, indent=2) + "\n")
    with (args.output / "results.csv").open("w") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    (args.output / "curves.json").write_text(json.dumps(curves))
    (args.output / "rejected.json").write_text(json.dumps(failures, indent=2) + "\n")
    metadata = dict(commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    python=platform.python_version(), platform=platform.platform(), cvxpy=cp.__version__,
                    numpy=np.__version__, solver="CLARABEL", lua=args.lua, repeats=args.repeats, solver_repeats=args.solver_repeats,
                    solver_status_counts=SOLVER_STATUSES,
                    bending_weights=args.bending_weights,
                    default_work_limit=default_work,
                    source_sha256=hashlib.sha256((ROOT / "scripts/vehicle-trajectory.lua").read_bytes()).hexdigest(),
                    optimizer_timing="Independent cold problems including construction/canonicalization/solve; diagnostic only",
                    constraints="Production: geometric corridor. SOCP/Bezier: stricter fixed-correspondence constraints and a fixed initial heading.",
                    timing_caveat="Lua CPU measurements exclude GC collection before each trial; Python/native times are not interchangeable. SOCP-plus-smoothing totals add independently measured medians.",
                    driving_caveat="curvature_only_seconds assumes instant acceleration/braking and exact tracking, uses a 1.25 tiles/tick ceiling; not a native arrival prediction. Omitted for radius below .01 tiles.",
                    optimality_caveat="Bezier length uses 12-point quadrature; bending is a parameter-space surrogate. optimal_inaccurate candidates have feasibility checks, not optimality certificates.")
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    plot(records, curves, selected, args.output)
    print(f"PASS {len(records)} curves: endpoint, continuity and corridor checks; {len(failures)} candidates rejected; results in {args.output}")


def plot(records, curves, selected, output):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    cases_to_plot = [c for c in ["right-angle", "short-turn", "lane-shift", "native-hairpin"] if c in selected]
    if not cases_to_plot:
        return
    fig, axes = plt.subplots(len(cases_to_plot), 2, figsize=(14, 4*len(cases_to_plot)), squeeze=False)
    for row, case in enumerate(cases_to_plot):
        allowances = sorted({r["clearance"] for r in records if r["case"] == case})
        for col, clearance in enumerate([allowances[0], allowances[-1]]):
            ax = axes[row, col]
            ref = np.array(selected[case])
            ax.plot(ref[:, 0], ref[:, 1], ":", color="grey", label="Original")
            for mode in ["current", "socp-plus-smoothing", "bezier-c2-weight-0", "bezier-c2-weight-1000"]:
                if f"{case}/{clearance}/{mode}" not in curves:
                    continue
                p = np.array(curves[f"{case}/{clearance}/{mode}"]["points"])
                ax.plot(p[:, 0], p[:, 1], label=mode, linewidth=1.2)
            if case == "right-angle":
                extent = max(4, clearance*8)
                ax.set_xlim(100-extent, 100+extent/3)
                ax.set_ylim(-extent/3, extent)
            elif case == "short-turn":
                ax.set_xlim(-.5, 4.5); ax.set_ylim(-.5, 4.5)
            elif case == "lane-shift":
                ax.set_xlim(155, 310); ax.set_ylim(-8, 30)
            else:
                ax.set_xlim(-140, -96); ax.set_ylim(-315, -288)
            ax.set_aspect("equal", adjustable="box")
            ax.set_title(f"{case} detail, allowance {clearance} tiles")
            ax.grid(alpha=.2)
            ax.legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(output / "curve-comparison.png", dpi=160)
    plt.close(fig)


if __name__ == "__main__":
    main()
