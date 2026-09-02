# Exterior ballistics

Everything the armour model does depends on two numbers this produces: **the velocity
a shell is still carrying when it arrives**, and **the angle it is falling at**. If
those are wrong, a penetration model of any sophistication is being fed fiction.

So the trajectory model is not tuned to feel right. It is calibrated against published
naval range tables, and the tests assert against those published figures rather than
against the implementation's own output — so they can fail by the model being wrong,
not merely by it changing.

---

## The model

A shell is integrated in three dimensions — `x`, `y` and altitude `z` — under gravity
and aerodynamic drag:

```
a = -(½ ρ(z) Cd(M) A f / m) · |v| · v  −  g ẑ
```

with Runge-Kutta 4 throughout (`src/sim/ballistics/ballistic_solver.gd`).

**Air density and the speed of sound vary with altitude.** This is not a refinement:
a 16-inch shell fired for 35 km reaches an apex above 6 km, where the air is barely
half as thick as at sea level. Treating the atmosphere as uniform shortens long-range
trajectories by kilometres. The International Standard Atmosphere is tabulated and
interpolated (`atmosphere.gd`) rather than computed from the exponential barometric
formula — partly because the ISA is itself defined piecewise, and partly to keep
`exp()` out of the innermost loop of the simulation, since transcendental functions
are where two platforms would first disagree about where a shell landed.

**Drag is split into a shared curve and a per-shell form factor.** The `Cd(Mach)`
curve in `data/config/ballistics.json` shows the expected transonic rise — drag
roughly doubles through Mach 1 and falls away again supersonically. Each shell then
scales it by its own `formFactor`. That split is physical: the transonic rise is a
property of moving through air, while how much drag a particular projectile suffers
depends on how sharply pointed it is and how good its ballistic cap was.

Making the form factor per-shell rather than per-gun is what lets a Japanese Type 91,
with its very long fine ogive, out-range an American shell of higher sectional
density — which it genuinely did.

---

## Calibration

Each shell's form factor is **solved**, not guessed: it is the value at which the
model reproduces that shell's published maximum range at its gun's maximum elevation.

The resulting factors land between 0.83 and 1.05, which is the physically sensible
band for capped naval projectiles — and the Type 91's 0.833 being the lowest in the
set is a useful cross-check that the model is capturing something real rather than
absorbing error.

One shell, the British 4.7"/45 HE Mark IX, solves to 1.214. That is outside the
plausible band, which means one of the published figures used for it (mass, muzzle
velocity or maximum range) is unreliable. Rather than bake in a number implying an
impossibly blunt shell, the data file records it with `confidence: low` and a note
saying so. The generator flags any such outlier automatically.

### How well it does

Against USS Iowa's 16"/50 Mark 7 range table (AP Mark 8, 1,225 kg at 762 m/s):

| Range | Striking velocity | | Descent angle | |
|---|---|---|---|---|
| | published | model | published | model |
| 18,288 m | 510 m/s | 521 | 15.0° | 15.3° |
| 27,432 m | 464 m/s | 468 | 29.9° | 29.1° |
| 36,576 m | 473 m/s | 485 | 45.2° | 46.2° |

And against Bismarck's 38 cm/52 SK C/34 — a second, differently shaped shell from a
different navy, which is what shows the curve generalises rather than having been
fitted to one weapon:

| Range | Striking velocity | | Descent angle | |
|---|---|---|---|---|
| | published | model | published | model |
| 10,000 m | 631 m/s | 643 | 5.2° | 5.8° |
| 20,000 m | 519 m/s | 514 | 14.5° | 16.3° |
| 30,000 m | 452 m/s | 459 | 31.4° | 31.8° |

Maximum ranges across eight guns come within 2%. Striking velocities are within about
3% and descent angles within 2°, which is comfortably inside the accuracy the armour
model needs.

The residual is mostly in *elevation*: the model reaches a given range at roughly one
to three degrees less elevation than the printed tables. Real range tables fold in
drift from spin, Coriolis, and non-standard atmosphere corrections, none of which are
modelled here. Since elevation is an input the gun uses rather than an output the
damage model consumes, this is the right place for the error to live.

---

## Range tables

Solving a trajectory takes hundreds of integration steps, and fire control needs an
answer every time it lays a gun. So each gun/shell pairing is solved once into a
range table (`range_table.gd`) — elevation against range, time of flight, striking
velocity, descent angle and apex — and everything afterwards interpolates.

Tables are built **lazily**: a destroyer action never needs Yamato's.

Only the rising branch is used for lookups. Past the elevation of maximum range, a
higher angle gives a *shorter* range, so a naive search would happily return the
high-angle solution and drop a plunging shell where a flat one was wanted.

Guns are given a **muzzle height** above the waterline. Without it a shell fired at
zero elevation is below the water on its first step, and the flat end of every range
table degenerates.

### Step size

RK4 is stable enough that a quarter-second step costs under half a metre of range
over 33 km. Range tables use that; shells in flight integrate at the simulation tick
for smooth motion and swept hit tests. A test asserts the two agree to within metres,
because a discrepancy between the table a gun is laid from and the flight the shell
actually takes is a systematic miss.

---

## Armour penetration

The trajectory model exists to hand the armour model two numbers: **striking
velocity** and **descent angle**. What happens next is
`src/sim/damage/penetration/`.

### The interface comes first

`PenetrationModel` is an interface, and the simulation depends only on it.
`DeMarreModel` is one implementation, chosen by id in
`data/config/ballistics.json`. Replacing it with a fuller analytical treatment means
writing a class and changing one line of configuration — `HitResolver`,
`DamageResolver`, the tracer and every `HitReport` consumer stay as they are.

A model returns a `PenetrationOutcome`, never a boolean. "Did it get through" is the
least interesting part of an armour interaction: what the next layer needs to know is
how fast the shell is still going, whether it is still in one piece, whether its cap
survived, whether its fuze has started running, and what came off the back of the
plate. A shell's journey through a ship is a sequence of these, and an outcome that
reported only true or false would make the second plate unresolvable.

### De Marre

```
V_limit = K · T^0.7 · d^0.75 / √W
```

evaluated in the imperial units the formula is published in, so `K` here is the same
`K` a gunnery manual quotes and can be checked against one.

**Note the direction: K is the velocity a shell *needs* per unit of plate, so a
higher K means a worse penetrator.** It lives per-shell in `data/ammo/`, fitted
against published penetration tables where they exist:

| Shell | K | fitted against |
|---|---|---|
| 16"/50 AP Mark 8 | 1371 | 20,000–35,000 yd |
| 46 cm AP Type 91 | 1304 | 20 and 30 km |
| 8"/55 AP Mark 21 | 1383 | 20,000–25,000 yd |

The Type 91's lower figure is not noise. Its very long cap was optimised for an
underwater trajectory against a ship's unarmoured bottom, at some cost to straight
penetration — the model recovering that from published data is a useful sign it is
measuring something real.

Shells with no published table get a class default derived so that each type reaches
the fraction of AP penetration it historically managed (SAP 60%, common 50%, HE 28%,
AA 18%), and are marked `confidence: low`.

Zero-range figures were excluded from the fits: no gun fires at zero range, and they
are the visible outliers in every set.

### What sits on top of the formula

None of this is a law of physics. It is this model's account of what happens, all of
it configured, and another model is free to disagree:

- **Normalization** — a capped shell bites and turns towards the normal. Strong
  against plate thinner than the shell's calibre, negligible against plate thicker.
- **Ricochet** — past a critical angle a shell skids off. The critical angle falls as
  the plate thickens relative to the calibre, and a shell that hugely overmatches the
  plate drives through regardless of angle.
- **Shatter** — the classic shatter gap: a fast shell against face-hardened plate near
  its own calibre in thickness can break up even with the energy to get through. The
  plate wins by destroying the projectile rather than by stopping it.
- **The marginal band** — a ballistic limit is a 50% probability, not a wall. Within
  12% either side of it the outcome is a roll, drawn from the simulation's own RNG
  stream so it stays reproducible. With no stream supplied the model returns its
  central prediction, which is exactly the quantity published tables report — and is
  what the validation tests compare against.
- **Partial penetration** — below the band but above 88% of the limit, the plate is
  holed and the shell breaks up going through: fragments enter, an intact bursting
  charge does not. **That 0.88 is a heuristic of this model, not a universal law.**
- **Cap stripping** — a thin plate met first tears the armour-piercing cap off, and
  the belt then sees an uncapped shell. This needs no special case; it falls out of
  the tracer resolving layers in order.
- **Spall** — even a plate that holds sheds fragments off its inner face, which is how
  a non-penetrating hit still wrecks equipment behind armour that was never beaten.

### How well it does

Against Iowa's and Yamato's published penetration tables, within 15% across combat
ranges — which is what an empirical fit of this age is worth, and precisely why it
sits behind an interface rather than being the model.

---

## Following a shell through a ship

`TrajectoryTracer` intersects the shell's path against every plate, bulkhead,
compartment and component, sorts the results by distance, and resolves each in turn
with the projectile's state carried forward. It is an **ordered geometric
resolution**, not a grid march, and the ordering is the point: a shell stops at the
first plate that beats it, and what lies behind that plate is never consulted.

Two behaviours usually written as special cases fall out of this for free:

- **Overpenetration.** The fuze runs on distance travelled since arming, so a shell
  that crosses a thin-skinned destroyer and leaves the far side before the fuze
  expires simply does very little. No rule says so.
- **Decapping.** The plating is resolved before the belt, and it is thin enough
  relative to the shell to tear the cap off. Two layers, in order.

Ship list and trim enter through the coordinate transform, so a heeling ship
genuinely presents more deck and less belt — a flooding ship becomes progressively
easier to hurt without any rule to that effect.

---

## Tuning

Every number is in `data/config/ballistics.json` (drag curve, atmosphere, integration
steps) and in the per-shell files under `data/ammo/`. Correcting the model is a data
edit. If Yamato's shells feel wrong, the first number to revisit is her form factor;
if her *armour* feels wrong, see the material quality factors in
`data/materials/armor.json`, which are the most contested figures in the project.
