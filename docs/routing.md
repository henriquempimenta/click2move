# Belt-aware routing — design notes

Implementation detail for the three routing strategies. For what they do and
when to pick one, see the [README](../README.md#routing-strategies).

- [The problem](#the-problem)
- [Where belt awareness is applied](#where-belt-awareness-is-applied)
- [The cost model](#the-cost-model)
- [Phase 2: the belt graph](#phase-2-the-belt-graph)
- [The swap decision](#the-swap-decision)
- [Measuring changes](#measuring-changes)
- [Known limitations](#known-limitations)

## The problem

`LuaSurface.request_path` has no per-tile cost hook. It can be told a tile is
*impassable*, never that it is *expensive*. Transport belts are passable and
expensive — differently so depending on which way you are going relative to the
belt — so the pathfinder cannot represent them at all, and there is no API to
teach it. Every mechanism here exists because of that one constraint.

## Where belt awareness is applied

Three places, in increasing order of ambition:

1. **`Belts.plan`** (`scripts/belts.lua`) — a post-pass over the path the
   pathfinder returned. Splices in lateral detours where a segment fights a
   belt, and can route onto a belt worth riding.
2. **`Belts.escape_direction`** (`scripts/belts.lua`) — a per-tick correction
   for when the character ends up on an opposing belt anyway (pushed there, or
   the route was planned before it drifted). Walks perpendicular to leave.
3. **`BeltGraph`** (`scripts/belt-graph.lua`) — an A* over the mod's own graph,
   used by `dual-phase` only. This is the one that can produce routes the
   pathfinder would never suggest, such as "walk clear of the bus, travel
   parallel on open ground, re-enter near the goal".

The graph models belts and open ground and nothing else — no walls, water, or
buildings. So its output is never a route: it is a short list of *waypoints*
that the vanilla pathfinder is then asked to connect. The graph picks the
corridor; `request_path` handles the obstacles inside it.

## The cost model

Everything is priced in ticks, and `belts.lua` is the single source of truth —
`belt-graph.lua` calls into it so the two cannot disagree about what a stretch
of ground costs.

The constants are calibrated against per-tick traces, not chosen by feel.
Deriving them mattered more than it sounds: the obvious model made the whole
feature inert.

| Quantity | Naive guess | Measured | Why it matters |
| --- | --- | --- | --- |
| Clear-ground speed | 0.15 (prototype `running_speed`) | **0.092** | A waypoint-follower spends part of every tick turning. 0.15 is a straight-line sprint, which the character never does. |
| Walking against a yellow belt | 0.12 (`walk - belt_speed`) | **-0.0066** | Not "20% slower" — *net backward*. The character is shoved sideways while chasing waypoints, so most of its speed budget goes into correction. |

`OPPOSING_BELT_PENALTY = 5.22` is solved from that second row
(`0.15 - 0.03 * P = -0.0066`), not picked. It is calibrated against **yellow**
belts specifically, since that is what the bench arena's bus is built from;
extrapolating to red and blue is linear and untested.

Two distinctions the model must make, both of which were bugs first:

- **Opposing vs crossing.** The penalty applies to fighting a belt *along its
  axis*. A belt crossed perpendicular costs a few ticks and must not be priced
  as a stall — doing so priced "step off the bus, walk clear, step back on" at
  1000 ticks for four tiles of belt, so the planner preferred grinding 100
  tiles up the bus. `ESCAPE_MIN_OPPOSITION` (0.7, ~45°) is the threshold, and
  the planner and the per-tick escape share it so they cannot undo each other.
- **Crossing vs boarding.** `LANE_CROSSING_COST` discourages blundering across
  a bus, but a route that boards a belt *on purpose* looks identical to the
  counter. A deliberate ride is therefore scored without that penalty; without
  this, a 619-tick ride was swapped out for a 942-tick walk.

Avoidance is classified over a **contiguous belt encounter**, rather than each
raw pathfinder segment independently. Factorio's staircase paths can include a
one-tile adverse segment inside an otherwise perpendicular crossing. Such a
kink is left alone unless the encounter contains at least two tiles of actual
opposing travel. The completed avoidance route must also win by at least 10%
and stay within a geometric detour bound.

## Phase 2: the belt graph

A* over a lattice of points spaced `GRID` (4) tiles apart, bounded to the
start/goal box plus `MARGIN`.

Two properties worth preserving if this is ever modified:

- **The lattice is anchored on the origin**, not on world zero. A world-aligned
  lattice does not generally contain the straight line between the two
  endpoints — a route from `y = -138` could reach `-136` or `-140` but never
  `-138` again — so A* was structurally unable to express "just walk there" and
  returned a 24067-tick route where the straight line cost 9074. Anchoring on
  the origin keeps the straight line a candidate, so A* can only improve on it.
- **The heuristic must stay admissible.** It estimates at
  `walk_speed + express_belt_speed`, i.e. faster than anything can actually
  move. An estimate that exceeds true remaining cost would let A* return a
  route that is not the cheapest, which undermines the measured tick counts the
  feature is justified on.

The search is budgeted (`EXPANSIONS_PER_STEP` per call, `MAX_EXPANSIONS`
total) and resumable, because Factorio has no threads: a search long enough to
matter is long enough to stall the tick if run in one go. It is advanced from
the tick loop while the character is already walking the Phase-1 route.

When the graph wins the preliminary comparison, its sparse corridor points are
not installed as the movement path. Each corridor leg is submitted to
`request_path` and concatenated only after every leg resolves. Because the
character continues along Phase 1 during those requests, one final request
connects its latest position to the cheapest remaining validated suffix. The
fully connected result is scored again before it can replace the incumbent.
This keeps obstacle handling in Factorio's pathfinder and prevents a sparse
graph suffix from appearing as the entire rendered or traversed route.

## The swap decision

`scripts/dual-phase.lua`. The rule that matters:

> Both routes are scored **from the character's current position**, at the
> moment Phase 2 finishes — never from where the search started.

By then the character has been walking for anywhere from a few ticks to a
couple of seconds, and a detour that was better from the start line is often
behind it. Comparing from the origin would swap in routes that lengthen the
trip while appearing on paper to improve it.

The candidate is therefore rebased to the cheapest remaining suffix before it
is compared. Waypoints that the moving character has already passed are
discarded rather than becoming a backtracking leg. A second guard rejects a
candidate whose geometric length exceeds the incumbent by more than 1.75x plus
eight tiles. Belt avoidance may legitimately take a longer line, but a larger
detour is more likely to be a stale answer or a graph blind spot than a useful
shortcut.

`SWAP_MIN_GAIN` (1.15) suppresses marginal swaps: a visible re-route that saves
a handful of ticks reads as the mod changing its mind for no reason.

`MIN_OPPOSED_TICKS_TO_SWAP` (60) suppresses swaps on routes where belts are not
the problem, and it is the more important of the two. The graph does not model
walls, so on an ordinary walking route it knows *less* than the pathfinder it
is second-guessing, and its "improvement" is a straight line through an
obstacle it cannot see. `SWAP_MIN_GAIN` cannot catch that — the predicted gain
is large and confident, just wrong. Measured before the gate existed:
`around-wall` 471 → 614 and `against-belt` 605 → 657, while every swap was
being accepted and none rejected.

The general lesson, if this is extended: **the question is not how big the
predicted win is, but whether the win is made of something the graph can
actually see.**

## Measuring changes

Do not tune these constants by eye. The harness at `~/projects/factorio-mod-testing`
runs a real client against a headless server on a deterministic arena
(`scenario/c2m-bench`) and reports ticks-to-arrival per strategy:

```
./run_bench.py --repeat 5 \
    --strategy naive --strategy belt-aware --strategy dual-phase \
    --json-out logs/whatever.json
```

Trials are deterministic (stdev 0.0 on most routes), so a difference of more
than a few ticks is real. `--keep-samples` adds the per-tick position/on-belt
time series, which is how every bug above was actually found — the summary
numbers say a route is slow, the samples say *where* and *why*.

To inspect the A* in isolation without running a whole benchmark:

Enable the **Enable benchmark interface** startup setting and restart the
game, then run:

```lua
/silent-command rcon.print(helpers.table_to_json(remote.call(
  "click2move-debug", "probe_route", {x=40,y=-138}, {x=-60,y=-138})))
```

That returns the chosen waypoints alongside both cost estimates, which
distinguishes "the search found nothing", "the swap was rejected", and "the
cost model is wrong" — three failures that look identical from the outside.

## Known limitations

- `OPPOSING_BELT_PENALTY` is calibrated on yellow belts only.
- The graph ignores walls and water. This is mitigated rather than fixed:
  `MIN_OPPOSED_TICKS_TO_SWAP` keeps it from being consulted on routes it would
  be bad at, while suffix rebasing and the geometric-detour cap reject common
  stale or implausible results. Those checks are still proxies for "is the graph
  competent here", and a proxy will eventually be wrong. The real fix is to
  validate a candidate through `request_path` before committing to it, at the
  cost of an extra async round-trip. See `OPEN_DECISIONS.md`.
- Splitters, underground belts and loaders are treated as neutral rather than
  modelled; only `transport-belt` contributes to cost.
- A goal on a belt completes as soon as the character enters the normal arrival
  radius, before the reactive escape correction runs. The belt can carry the
  character away after auto-walking stops; holding position is intentionally
  left to the player rather than turning arrival into an endless correction.
