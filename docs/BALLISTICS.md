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

## Tuning

Every number is in `data/config/ballistics.json` (drag curve, atmosphere, integration
steps) and in the per-shell files under `data/ammo/`. Correcting the model is a data
edit. If Yamato's shells feel wrong, the first number to revisit is her form factor;
if her *armour* feels wrong, see the material quality factors in
`data/materials/armor.json`, which are the most contested figures in the project.
