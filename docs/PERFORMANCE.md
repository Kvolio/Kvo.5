# Performance, and the two things it may not cost

Stage 9 is allowed to make a battle cheaper. It is not allowed to make it a *different*
battle, and it is not allowed to make it depend on where the camera is.

## The spatial index, and a lesson in measuring

`SpatialIndex` has been an interface since Stage 0 precisely so that this could be a swap
rather than a rewrite. `SpatialHashIndex` is a uniform grid; `BruteForceIndex` is a linear
scan and remains available as the correctness oracle. Both satisfy the same contract, and
`tests/unit/test_spatial_index.gd` goes further: it asserts they return **byte-identical**
results over randomised workloads, and that a whole battle fought with one is bit for bit
the battle fought with the other. An acceleration structure that is merely almost right
produces a subtly different naval action, and a subtly different naval action is
indistinguishable from a correct one until it matters.

The first version had no fallback path, and it was **six times slower than brute force**:

| index | ms per tick | times realtime |
|---|---:|---:|
| brute force | 17.8 | 0.9 |
| grid, no fallback | 107.7 | 0.2 |

Identical results, six times the cost. The reason is worth keeping: a detection sweep asks
for everything within tens of kilometres — a radius comparable to the whole battlefield —
and walking a hundred-by-hundred block of mostly empty cells to answer it costs far more
than simply looking at every ship. A uniform grid is the wrong structure when the queries
are large relative to the cell, and no amount of tuning the cell size fixes a query that
covers the map.

The fix is to answer large queries by scanning. Both paths are exact, so which one is
taken cannot change an answer:

| index | ms per tick | times realtime |
|---|---:|---:|
| brute force | 19.5 | 0.9 |
| grid, with the scan fallback | **13.9** | **1.2** |

A sixty-ship action at 13.9 ms a tick is a little faster than real time. Modest — but it is
a measured 1.4× rather than an assumed one, and the measurement is the part that was worth
having. `tools/probe_performance.gd` runs it.

There is no timing assertion in the test suite. A frame-time budget checked on shared
hardware is a flaky test, and a flaky test is worse than no test: it trains people to
ignore failures. The budget is measured by the probe and reported here instead.

## Level of detail, and why it is not the camera's business

The obvious implementation of level of detail is to throttle work for things that are far
from the camera. It would be a disaster here. A battle whose outcome depended on where the
player was looking would mean two people watching the same action saw different results,
and every replay would be wrong.

So level of detail is decided by the **simulation**: a captain with no contact within
twenty-five kilometres has nothing to decide in a tenth of a second, and in a sixty-ship
action most captains are in that position most of the time. Range to the nearest contact
his own side is holding is simulation state — deterministic, identical on every machine,
and captured by a snapshot along with everything else.

Two further rules:

* **Damage control, flooding and fire run at a fixed cadence for every ship.** They are
  physical rates rather than decision cadences, and throttling them would mean a burning
  ship put herself out faster or slower depending on where the fighting was.
* **Ballistics, trajectory tracing and penetration are never simplified.** They decide what
  happens at the moment of a hit. `test_ballistics_and_penetration_are_never_thrown_away`
  greps the four files that would have to change for that to stop being true and fails if
  any of them so much as mentions a distance, a zoom or a camera.

## Where the time actually goes

Pooling was already in place for projectiles from Stage 3, and the hot paths were measured
rather than guessed with `tools/bench.gd` in the same stage — which found a 3× on a gun
action by fixing a broadphase that was tracing every shell against every ship on every
tick.

What remains expensive in a large action is the trajectory tracer and the AI, in that
order, and both are expensive for good reasons: the tracer resolves real geometry in real
order, and the AI scores real alternatives. Neither is a candidate for approximation,
because approximating either changes outcomes. The honest summary is that this simulation
costs what it costs, and a sixty-ship fleet action is about the size it is comfortable at.
