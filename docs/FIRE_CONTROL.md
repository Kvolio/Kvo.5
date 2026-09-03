# Fire control: why ships miss

Until Stage 7 the gunnery in this project read the target's exact position and velocity.
The only error left in the system was the dispersion of the guns, and the result was a
hit rate about three times the historical one — reached, worse, for the wrong reason.
Real ships did not miss because their guns scattered. They missed because their
**solution was wrong**.

The numbers make the point. A battleship's salvo pattern at 18 km is some 50 m in
standard deviation. Her range error could easily be twice that. A perfectly tight salvo
fired at the wrong range simply lands somewhere else, and no amount of gunnery quality
recovers it.

So the error moved into the plot, where the physics is.

## Four errors, four behaviours

`FireControlSolution` (`src/sim/systems/fire_control_solution.gd`) holds what one ship
believes about one target. It is wrong in four separate ways, and the point of splitting
them is that each behaves differently over time.

| Error | Source | Over time |
|---|---|---|
| **Measurement** | rangefinder or radar | averages down while she keeps ranging |
| **Ballistic bias** | wind aloft, air density, powder temperature, barrel wear | never averages down; absorbed whole by the first correction that straddles |
| **Plot lag** | the estimate of the target's course and speed | zero only while the target holds her course |
| **Pointing** | director stabilisation residual and ship motion | neither; it sets the floor |

**Measurement.** Optical error goes as the *square* of the range and inversely with the
rangefinder's base length, because what a rangefinder measures is a parallax angle:
`sigma = R^2 * angularError / baseLength`. Radar error is essentially flat. That
crossover is the whole story of gunnery from 1942 onwards — a set worse than a good
rangefinder at 8 km is far better than one at 25 km — and it is why a destroyer's own
ranging is close to worthless past 15 km while a battleship's 10 m instrument is not.

**Ballistic bias** is drawn once when a plot is opened and held for the engagement,
because these things do not vary shot to shot. That is exactly why spotting works: one
correction absorbs the whole of it.

**Plot lag** is where the interesting behaviour lives. The plot integrates a range rate
derived from the course and speed it *believes* the target is making. Where that belief
is wrong, the error grows — and it grows fastest just after the target has turned.
Nothing in the model says "evasion". A ship that turns invalidates every plot solving on
her, not by a rule that says so, but because the range rate being integrated is now the
range rate of a course she is no longer on.

**Pointing** is an *angle*, not a fraction of range, and that distinction is worth more
than it sounds. A director a twentieth of a degree off is a twentieth of a degree off at
any range; what it costs on the water is decided by how fast the gun's own range table
trades elevation for range. For the Iowa's 16"/50:

| Range | Elevation | dR/d(elevation) | 0.0012 rad is worth |
|---:|---:|---:|---:|
| 6 km | 3.0° | 94,800 m/rad | 114 m |
| 12 km | 6.9° | 81,500 m/rad | 98 m |
| 18 km | 11.6° | 65,600 m/rad | 79 m |
| 30 km | 24.8° | 41,000 m/rad | 49 m |

So a laying error throws a shell **further** off at ten kilometres than at twenty-five —
the opposite of what an error stated as a percentage of range would say. That is read off
the gun's own table (`RangeTable.range_gradient`) rather than assumed.

## Spotting: the ladder

The fall of shot is the only feedback a ship gets, and it corrects the range whatever was
wrong with it, because the officer calling the correction cannot tell the four sources
apart either. Open fire, miss, spot, correct, straddle.

Two details matter. A salvo is spotted as a **pattern**: the splashes are gathered for a
second and corrected for once, because correcting on every splash separately would apply
a battery's worth of corrections for one salvo and drive the plot into oscillation. And
each **battery keeps its own plot** — a main battery director and a secondary director
were separate installations solving separate problems, and letting a five-inch splash
correct a sixteen-inch solution ruins both. This was found the hard way: the first
implementation shared one plot, the Iowa's fast-firing secondaries flooded the main
battery's spotting with their own errors, and the standing error went from 50 m to 700 m.

Checking fire loses the solution. That is why the AI's targeting carries hysteresis: a
plot that took three minutes and four salvos to build is thrown away when the guns are
shifted.

## Own-ship motion

Found by calibration rather than by reading, and worth its own section because it was
the largest single error in the system and it was invisible.

A shell leaves a ship making twenty knots already carrying those twenty knots. Over half
a minute of flight that is nearly four hundred metres — as large as every other error in
the model put together. The code did neither half of it: the shell was given no inherited
velocity, and the intercept was solved against the target's *absolute* motion rather than
her motion relative to the firing ship.

Both halves are real, and they very nearly cancel. Real fire control compensated for
own-ship motion for exactly this reason. What survives the cancellation is the intercept
against **relative** motion, which is now what `FireControlSystem.solve()` computes, with
`GunnerySystem` adding the ship's velocity to the shell — the same statement made twice,
once for the gunlayer and once for the physics.

Leaving out both would at least have been self-consistent. Leaving out one meant every
salvo walked off to one side by the shooter's own speed times the time of flight, silently.
`test_a_shell_carries_its_ships_motion_and_the_solution_allows_for_it` measures it with the
compensation removed: 427 m of drift at 18 km from a ship making 28 knots, which is 28
knots times the time of flight to within two percent.

Fixing it also corrected the *direction* of a result that had been suspicious. Before, a
zigzagging target was easier to hit than a steady one; after, she is harder, which is what
a plot being repeatedly invalidated should do.

## Calibration

Measured with `tools/probe_gunnery.gd` — Iowa against Iowa, main battery only, four seeds,
240 s per run, the target put back on her feet when sunk (and the shooter's plot with her)
so that what is measured is fire control and not survivability.

| Range | Steady target | Manoeuvring target | Historical anchor |
|---:|---:|---:|---|
| 8 km | 37.5% | 47.6% | ~12% (Washington vs Kirishima, ~9 of 75 at 7–8 km) |
| 12 km | 15.3% | 23.3% | ~8% |
| 18 km | 9.0% | 7.6% | ~5% (radar-directed capital-ship gunnery) |
| 24 km | 0.0% | 1.0% | ~2% |

Time to first hit is 34 s at 8 km and 52 s at 18 km: the ladder, working.

**Long range is within about a factor of two of the historical figure — down from three
times it before this stage — and the manoeuvring column is now correctly the harder one.
Close range remains optimistic, and it is worth being plain about why rather than tuning
it away.**

Two reasons, and neither is a knob.

The probe fires at a target in clear weather, holding a steady course, with undamaged
directors, while nobody shoots back and nothing is on fire. That is not a battle, it is a
range exercise — and peacetime battle practice really did score 30–40% at moderate ranges.
The wartime figures come from actions fought in poor visibility against ships manoeuvring
hard, with directors being shot away and fire checked and reopened.

The second is geometric. Range error dominates deflection error by an order of magnitude,
so what matters is the target's depth **along the line of fire**, and at shallow descent
angles a warship is very deep indeed. At 8 km a shell falls at 4.3°, so shells aimed
hundreds of metres over still strike the upperworks on the way down. The hit distribution
confirms it — of 84 main-battery hits at 8 km: 36 weather deck, 15 superstructure, 9 shell
plating, 5 turret side, 2 belt. That is a consequence of modelling ships as
three-dimensional geometry rather than as a footprint, and it is right.

The close-range figures are therefore left standing as a known optimism rather than
corrected by inventing error, on the same principle as Bismarck's +17% displacement in
`docs/NAVAL_ARCHITECTURE.md`: a gap that is visible and explained is worth more than one
that has been tuned out of sight.

## What is in data

`data/config/fire_control.json` carries every constant, with the reasoning attached. Per
ship, an optional `fireControl` block states her rangefinder base, her director count and
her radar set; anything not stated is filled in by year, because the year is the part
that is true of everybody and which navy got a working set first is a per-ship fact.
