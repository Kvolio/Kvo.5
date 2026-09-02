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

Structural integrity is a *derived summary* of the ship's actual condition, shown
because one headline number is useful. It is never what decides whether a ship
lives: that comes from flooding, stability, girder strength, fire, and the state of
the machinery and magazines.

---

## Running it

Open the project folder in Godot 4.4 and press play.

### Tests

The simulation core is Node-free, so the whole thing is testable headless:

```bash
tools/test.sh                 # all suites
tools/test.sh --filter=rng    # only suites whose filename contains "rng"
```

Exit code is non-zero on failure. Lint suites run before unit suites so an
architectural violation is reported before the behaviour it breaks.

The script runs Godot's import pass first, which is not optional: `class_name`
types are resolved from a cache built during import, so running the tests against
a stale cache makes every suite referencing a newly added class fail to parse.

### Screenshots

```bash
tools/screenshot.sh /tmp/shot.png
tools/screenshot.sh /tmp/shot.png --screenshot-zoom=1.1 --screenshot-focus=1
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
- [`docs/SOURCES.md`](docs/SOURCES.md) — where the historical figures came from, and which to doubt

---

## Status

Built in stages, each one tested before the next begins.

- [x] **Stage 0** — foundations: determinism, spatial abstraction, test harness
- [x] **Stage 1** — battlefield, ocean, hull geometry, movement physics
- [x] **Stage 2** — data layer, historical ship presets, weapons
- [ ] **Stage 3** — ballistics, ship structure, trajectory tracing, penetration
- [ ] **Stage 4** — damage, compartments, flooding, fire, derived integrity
- [ ] **Stage 5** — magazine detonation, torpedoes, capsize, damage control
- [ ] **Stage 6** — ship designer and naval architecture
- [ ] **Stage 7** — AI, formations, detection, carrier aircraft
- [ ] **Stage 8** — scenario editor, save/load, replay, debug mode, combat log
- [ ] **Stage 9** — performance and visual polish
