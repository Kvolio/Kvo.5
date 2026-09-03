# Naval Battle Sandbox

A top-down 2D naval engineering sandbox and tactical combat simulator: design a
warship, put it in a battle, and find out why it survived or died.

Built with **Godot 4.4** and GDScript. No addons, no runtime dependencies.

---

## The core idea

Most naval games give every ship a hit-point bar and subtract a number when a shell
lands. This one doesn't. Damage is the *result* of a physical chain:

```
armor → penetration result → internal path → compartment/component hit → effects → derived state
```

A 16-inch shell that fails to punch through a belt costs a battleship **zero**
structural integrity — though it may still wreck the radar, kill a gun crew, and
deform the plate. The same shell that gets through into a magazine ends the ship.
Where it hits matters more than what fired it.

Two consequences of that design show up without anyone writing a rule for them. A
battleship shell fired at a destroyer passes clean through and out the far side,
because the fuze runs on distance travelled and a destroyer is not thick enough to
use it up. And a shell meets the shell plating before it meets the belt, which is
enough to tear its armour-piercing cap off — so the belt faces an uncapped
projectile. Both fall out of resolving layers in the order the shell meets them.

Structural integrity is a *derived summary* of the ship's actual condition, shown
because one headline number is useful. It is never what decides whether a ship
lives: that comes from flooding, stability, girder strength, fire, and the state of
the machinery and magazines.

---

## Running it

Open the project folder in Godot 4.4 and press play. The menu offers a battle or the
ship designer.

### Tests

The simulation core is Node-free, so the whole thing is testable headless:

```bash
tools/test.sh                        # all suites
tools/test.sh --filter=rng           # only suites whose filename contains "rng"
tools/test.sh --exclude=gun_action   # everything except the integration suite
```

Each suite reports how long it took, because a suite that has quietly become slow is
usually a system that has quietly become slow. The two integration suites fight whole
battles — a gun action and a seventeen-ship fleet action — and take several minutes
between them, so `--exclude` is useful while iterating on the unit suites.

The fleet action suite is deliberately expensive, because it asserts an outcome rather
than a mechanism: two fleets in contact, both sides fought by the AI from their own
contact plots, and the assertion that a battle actually happens. Every unit test in
Stage 7 passed while the whole thing did nothing at all.

Exit code is non-zero on failure. Lint suites run before unit suites so an
architectural violation is reported before the behaviour it breaks.

The script runs Godot's import pass first, which is not optional: `class_name`
types are resolved from a cache built during import, so running the tests against
a stale cache makes every suite referencing a newly added class fail to parse.

### Screenshots

```bash
tools/screenshot.sh /tmp/shot.png
tools/screenshot.sh /tmp/shot.png --screenshot-zoom=1.1 --screenshot-focus=1
tools/screenshot.sh /tmp/shot.png --screen=designer      # or menu, or battle
```

Renders the real game to a PNG, falling back to Xvfb when there is no display.
Some bugs only exist once something is actually drawn.

---

## Layout

| Path | What lives there |
|---|---|
| `data/` | Every ship, gun, shell, armour material and tuning constant, as JSON |
| `src/sim/` | The simulation. Contains no Nodes and never touches the scene tree |
| `src/view/` | Rendering. Reads sim state, never writes it |
| `src/ui/` | Menus, ship designer, scenario editor, inspection panels |
| `src/core/` | Autoloads: config, application signal bus |
| `src/persistence/` | Save/load for ships, fleets, scenarios, battles, replays |
| `tests/` | `lint/` structural rules, `unit/`, `integration/` |
| `docs/` | Architecture, determinism contract, ballistics model, ship sources |

Ships are data. Adding one means adding a file to `data/ships/` — never touching
combat code.

---

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the pieces fit and why
- [`docs/DETERMINISM.md`](docs/DETERMINISM.md) — the reproducibility contract and its limits
- [`docs/BALLISTICS.md`](docs/BALLISTICS.md) — the trajectory model and how it was calibrated
- [`docs/DAMAGE.md`](docs/DAMAGE.md) — flooding, fire, torpedoes, damage control, and why integrity is derived
- [`docs/DESIGNER.md`](docs/DESIGNER.md) — the ship designer, and why it weighs rather than penalises
- [`docs/RENDERING.md`](docs/RENDERING.md) — how ships are drawn, and why none of it is art
- [`docs/NAVAL_ARCHITECTURE.md`](docs/NAVAL_ARCHITECTURE.md) — weighing a design, and where the model still misses
- [`docs/FIRE_CONTROL.md`](docs/FIRE_CONTROL.md) — why ships miss, and the four ways a firing solution is wrong
- [`docs/TACTICS.md`](docs/TACTICS.md) — the horizon, contact plots, immunity zones, captains and formations
- [`docs/AIR_MODULE.md`](docs/AIR_MODULE.md) — carrier aviation, and the line it does not cross
- [`docs/REPLAY.md`](docs/REPLAY.md) — scenarios, saves, replays, and the three ways of looking at a battle
- [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) — what a fleet action costs, and the two things it may not cost
- [`docs/SOURCES.md`](docs/SOURCES.md) — where the historical figures came from, and which to doubt

---

## Status

Built in stages, each one tested before the next begins.

- [x] **Stage 0** — foundations: determinism, spatial abstraction, test harness
- [x] **Stage 1** — battlefield, ocean, hull geometry, movement physics
- [x] **Stage 2** — data layer, historical ship presets, weapons
- [x] **Stage 3** — ballistics, ship structure, trajectory tracing, penetration
- [x] **Stage 4** — damage, compartments, flooding, fire, derived integrity
- [x] **Stage 5** — magazine detonation, torpedoes, capsize, damage control
- [x] **Stage 6** — ship designer and naval architecture
- [x] **Stage 7** — fire control quality, detection, AI, formations, the optional air module
- [x] **Stage 8** — scenarios, save/load, replay, ship inspector, debug mode, combat log
- [x] **Stage 9** — spatial hash index, deterministic level of detail, aircraft rendering
