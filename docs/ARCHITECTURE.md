# Architecture

## The one rule

> Armor decides whether the projectile gets in.
> The internal layout decides what it reaches.
> What it reaches decides what breaks.
> What breaks decides how the ship performs and whether it survives.

Nothing shortcuts that chain. There are no per-shell damage constants, no class
modifiers, and no table that says "a 16-inch hit costs 4%". If a number can be
derived from physical properties, it is derived.

---

## Five load-bearing decisions

### 1. The simulation core contains no Nodes

Everything under `src/sim/` is plain typed GDScript (`RefCounted`), advanced by
explicit `step()` calls on a fixed 1/60 s tick. It never touches the scene tree,
`_process`, a frame delta, or `get_node()`. Code under `src/view/` and `src/ui/`
*reads* simulation state in order to draw it, and sends intent back through
`CommandQueue`.

This one decision buys most of the others: headless testability, determinism,
trivial time control, whole-battle serialization, and no per-shell Node overhead
when several hundred projectiles are in the air.

### 2. Projectiles are simulated in 3D; the battlefield is drawn in 2D

Ships lie on the `z = 0` plane. Shells carry full `(x, y, z)` state through drag and
gravity.

This is not decoration. A shell's **descent angle** and **striking velocity** at
impact are what decide whether it strikes the deck or the belt, and what its
effective armour thickness is. A purely 2D projectile cannot answer "did this plunge
onto the deck or slam into the side?", which is the single most important question
in a naval gunnery duel. Splashes are drawn where `z` crosses zero, and the player
still sees a clean top-down tactical view.

### 3. Ships are geometry, not stats

A ship is built from data into an immutable `ShipStructureTemplate` (shared by every
ship of that design) plus a per-ship mutable `ShipStructureState`. The template holds
distinct primitive types, each matching its physical role — crucially, **a compartment
boundary is not automatically an armour barrier**:

| Primitive | Represents | Behaviour |
|---|---|---|
| `ArmorFace` | belt, upper belt, deck, turret face/side/roof, barbette, conning tower, torpedo bulkhead | thickness, material, inclination; full penetration model |
| `StructuralFace` | shell plating, decks, ordinary bulkheads | thin plating: resists little, but breaches, spalls and floods |
| `CompartmentVolume` | magazine, boiler room, engine room, fuel, steering, fire control, crew, void, bulge, hangar | volume, permeability, crew, ammunition, watertight neighbour links |
| `ComponentVolume` | turrets, directors, radar, engines, shafts, rudder, elevators | bounding volume, vulnerability profile, state machine |
| `HullSurface` | the outer envelope | entry/exit, breach area accounting |

### 4. Determinism is a hard requirement

See [`DETERMINISM.md`](DETERMINISM.md). It is enforced by lint, not by convention.

### 5. Every outcome is explainable

`HitReport` records the complete causal chain of an impact and is a first-class
simulation output, not debug decoration — it *is* the damage mechanism. The debug
overlay and combat log are two views of the same data.

---

## Hit resolution: ordered geometric intersection

Not a voxel march. The tracer resolves layers in true geometric order along the
projectile's actual path:

```
loop (bounded by a maximum interaction count):
  1. transform the current ray into ship-local space
     — including list and trim, so a listing ship really does expose more
       deck and less belt
  2. broadphase: hull AABB, then primitives bucketed by longitudinal station
  3. intersect the ray against each candidate primitive
  4. collect intersections as {t, kind, primitive, point, normal}
  5. sort by t                                    <- ordered, not marched
  6. resolve the nearest one by kind:
       ArmorFace / StructuralFace -> PenetrationModel.evaluate()
       CompartmentVolume          -> enter/exit, fuze distance accrual
       ComponentVolume            -> component interaction
       HullSurface (outbound)     -> exit / overpenetration
  7. update projectile state: velocity, energy, integrity, cap status, yaw,
     fuze arming, and direction on a ricochet
  8. if the direction changed, restart from step 1 at the deflection point
  9. terminate on stop / detonation / exit / iteration cap
```

Every iteration appends a `LayerInteraction` carrying the projectile's pre- and
post-state, so the whole path is reconstructable afterwards.

Overpenetration needs no special rule. The fuze accrues distance since arming, so a
shell that crosses a thin-skinned destroyer and exits before detonating simply does
very little — which is exactly what happens in reality.

---

## Penetration is a replaceable model

De Marre is a *starting* model, not the architecture.

```
PenetrationModel (interface)
  evaluate(ArmorInteractionContext) -> PenetrationOutcome
    +-- DeMarreModel            implemented now
    +-- NavalEmpiricalModel     future; drops in with no caller changes
```

Selected by ID from `data/config/ballistics.json`. `HitResolver` and `DamageResolver`
depend only on the interface.

`PenetrationOutcome` is a physical result, never a boolean: `PENETRATED` / `PARTIAL`
/ `STOPPED` / `RICOCHET` / `SHATTERED`, plus remaining velocity and energy,
projectile integrity, cap status, yaw, fuze state, obliquity, normalization,
effective thickness, penetration capability, and any spall generated.

**Partial penetration is not a universal law.** The 0.9-1.0 margin band exists only
as a configurable parameter *of the De Marre model*, documented as the heuristic it
is. Another model is free to derive partial penetration however its physics dictates;
the outcome carries enough state that refining it never touches a caller.

Decapping needs no special case either: a thin `StructuralFace` ahead of the belt
strips the AP cap, and the next `ArmorFace` sees `cap_status = STRIPPED`.

---

## Damage: effects first, integrity derived

### A clean non-penetration costs zero structural integrity

What it *can* do, all through modelled mechanisms: deform the plate (degrading its
future resistance), throw spall behind it, shock nearby components, kill crew
locally, and destroy exposed equipment near the impact — radar, directors, optics,
AA mounts, secondary mounts. If structural damage follows, it is because spall got
into a compartment or a component was wrecked, never because "a shell does damage".

### Structural integrity is a summary, not the authority

It is recomputed from condition — wrecked compartment volume weighted by structural
contribution, hull breach area, girder damage, fire-consumed structure, flooded
volume against reserve buoyancy — because one headline number is genuinely useful to
the UI, to scenario victory rules and to the designer's survivability estimate.

Survival is decided separately, by `SurvivabilityEvaluator`, from actual conditions:

- **Destroyed** — magazine detonation, reserve buoyancy exhausted (founder), list past
  the stability limit (capsize), hull girder severed (break-up), catastrophic explosion
- **Mission kill** — main battery gone, fire control gone, propulsion gone, steering
  gone, or flooding beyond damage-control capacity — evaluated *independently of
  integrity*

Which is why a 70%-integrity ship can be combat-dead while a 30%-integrity ship
fights on.

---

## Isolation boundaries

### Aircraft never touch the naval core

The core defines narrow interfaces — `SimEntity`, `Damageable`, `Detectable`,
`OrdnanceSource` — and `src/sim/air/` is an optional module that registers itself
with `SimWorld`.

Bombs are projectiles with their own parameters; air-dropped torpedoes construct
ordinary torpedoes. `HitResolver` contains no aircraft branch. Carrier facilities are
ordinary compartments and components with roles: the damage core damages components,
and the *air module* reads component state to decide sortie capability. The core
never learns what a sortie is.

**The full naval test suite must pass with the air module unregistered**, and that is
asserted rather than assumed.

### Spatial queries are an interface from day one

```
SpatialIndex (interface)
  +-- BruteForceIndex     Stage 0 — obviously correct, the oracle
  +-- SpatialHashIndex    Stage 9 — drop-in replacement
```

Detection, AI, projectile proximity, torpedo interaction and effects all depend on
the interface. Because results are contractually sorted by ID, an equivalence test
can assert both implementations return identical results — so Stage 9 is a swap, not
a rewrite. No premature optimization, and no architectural rewrite to optimize later
either.

---

## Data is outside the code

Every ship, gun, shell, armour material, propulsion plant and tuning constant lives
in JSON under `data/`. Historical presets and player-designed ships use the **same
schema** — the engine cannot tell them apart. Adding a ship means adding a file.

Historical values disagree between sources, so every ship file carries `sources`,
`notes`, and `confidence` markers on contested figures. Correcting a number is a data
edit, never a code change.

---

## Directory map

```
data/config/          tuning constants: sim, ballistics, damage, naval architecture
data/ships/           historical presets (also read from user:// for custom designs)
data/{guns,ammo,torpedoes,aircraft,propulsion,materials,hullforms}/

src/core/             autoloads: GameConfig, AppBus; JSON loading
src/data/             typed definitions, schema validation, version migration
src/sim/
  determinism/        DeterministicRng, RngStreams, IdAllocator, StateHasher
  spatial/            SpatialIndex interface and implementations
  events/             SimEvent, SimEventBus
  replay/             SimCommand, CommandQueue, recorder, snapshots
  interfaces/         SimEntity, Damageable, Detectable, OrdnanceSource
  entities/           ship, projectile, torpedo, island
  geometry/           hull, structure template/state, faces, volumes, tracer
  damage/             hit resolver, damage resolver, reports, survivability
    penetration/      model interface, De Marre model, outcomes, registry
  systems/            movement, fire control, gunnery, detection, flooding, fire, AI...
  air/                OPTIONAL aircraft module
  naval_arch/         weights, stability, speed, design validation
src/view/             rendering; reads sim state, never writes it
src/ui/               menus, ship designer, scenario editor, inspection, debug
src/persistence/      save/load for ships, fleets, scenarios, battles, replays

tests/lint/           structural rules (run first)
tests/unit/           per-class behaviour
tests/integration/    whole-battle scenarios
```
