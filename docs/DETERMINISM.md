# The determinism contract

The same seed, initial state, scenario and command sequence must produce the same
battle, every time. Everything downstream depends on it: replays, rewind, the "why
did my ship die" investigation loop, and the regression tests that stop the damage
model from drifting.

This is enforced structurally rather than by convention. `tests/lint/lint_determinism.gd`
reads every script under `src/sim/` and fails the build on violations.

---

## The rules

### 1. Fixed timestep

The simulation advances in ticks of exactly `1/60` s. It never sees a frame delta.
Time scaling (0.25x to 10x) changes *how many ticks run per rendered frame*, never
the size of a tick. A 10x battle and a 1x battle from the same seed produce
identical results.

### 2. No engine randomness

`randi()`, `randf()`, `randomize()` and `RandomNumberGenerator` are banned in
`src/sim/`. They share process-global state, and their algorithms are engine
internals that may change between Godot versions.

The simulation uses `DeterministicRng`: xorshift128 with every intermediate masked
to 32 bits. The masking matters — a 64-bit generator written in GDScript would
depend on signed `int64` overflow wrapping, which is not a property to bet
reproducibility on. `DeterministicRng.mul32()` splits the multiply so no partial
product ever exceeds 2^48.

Its output sequence is pinned by test. If a refactor changes it, every saved replay
in existence has become unreplayable, and that must fail loudly.

### 3. Named RNG streams

Systems draw from `RngStreams.stream("gunnery")`, `"penetration"`, `"fire"` — never
from a shared generator. Without this, adding one roll anywhere would shift every
subsequent draw and change the outcome of every saved battle. Stream seeds derive
from the stream *name*, so they are also independent of the order streams are first
touched.

### 4. Ordering is explicit, never incidental

- Entity collections are arrays walked in ID order. `IdAllocator` is monotonic and
  never recycles.
- **Dictionaries are lookup-only.** Godot iterates them in insertion order, so
  iterating one to make a decision makes that decision depend on construction
  history. Use `Serializer.sorted_keys()`.
- `SpatialIndex` implementations return results **sorted by ID**. This is what lets
  Stage 9 swap a spatial hash in for the brute-force index without changing a single
  outcome.
- Comparators define a *total* order. `Array.sort_custom` is not documented as
  stable, so any comparator that leaves two elements "equal" is free to reorder
  them. `CommandQueue` sorts by `(tick, entityId, seq)` — the sequence number
  guarantees no ties remain.
- Events go into an ordered queue (`SimEventBus`), not Godot signals. Signal
  dispatch order depends on connection order, which depends on construction order.

### 5. No wall clock, no frame counters, no await

`Time.*`, `OS.get_ticks_*` and `Engine.get_*_frames` are banned in simulation code,
as is `await` — asynchronous resumption makes execution order unpredictable.

### 6. Serialization is canonical and exact

`Serializer` writes sorted keys and the shortest decimal form that round-trips a
double *exactly*.

Godot's own `JSON.stringify(..., full_precision = true)` does **not** round-trip:
in 4.4 it emits about 15 significant digits, so `1.0/3.0` comes back as a different
double. A battle reloaded from such a file resumes from numbers it was never saved
at. `String.num(v, 17)` does round-trip, and is what the encoder uses.

Reading uses Godot's parser, which is correctly rounded — but note that it returns
**every** number as a double, integers included. Loaders coerce with `int()`/`float()`
rather than switching on `typeof()`, and any integer that must survive a round trip
stays inside the 2^53 a double holds exactly. Tick counts and entity IDs are nowhere
near that ceiling: 2^53 ticks is about 4.7 million years of simulated time.

### 7. The simulation core holds no Nodes

`src/sim/` contains no `Node` subclasses and no lifecycle methods. It cannot reach
the scene tree, so nothing about frame rate, window state or node order can leak in.

---

## The honest limit

GDScript floats are IEEE-754 doubles. Basic arithmetic and `sqrt` are correctly
rounded and therefore identical everywhere. `sin`, `cos`, `pow` and friends are
**not** required to be correctly rounded, so two platforms with different libm
implementations can legitimately disagree in the last bit.

So: **determinism is guaranteed for the same build on the same platform.** Bit-exact
cross-platform reproducibility is not promised.

Two things keep that honest rather than hidden:

- `StateHasher` produces a per-tick checksum from the exact IEEE bits of the state.
  A replay that diverges is caught, and the first mismatching tick localises it.
  (`-0.0` is normalised to `0.0` — they compare equal and are never a real
  divergence.)
- Hot paths avoid gratuitous transcendentals. `DeterministicRng.next_gaussian()`
  uses the Irwin-Hall construction — a sum of 12 uniforms — rather than Box-Muller,
  precisely to keep `log` and `cos` out of the dispersion calculation that decides
  where every shell lands.

---

## Replay

A battle is fully described by four things:

```
seed  +  initial serialized state  +  scenario config  +  ordered command log
```

AI decisions are computed inside the simulation from state it already has, so they
are reproduced by re-running rather than recorded. Only *external* intent — player
orders, scenario scripting, test input — enters through `CommandQueue`, and that is
the only channel permitted to change sim state from outside.

Events are an output, never an input. The combat log and debug overlay can therefore
carry as much detail as they like at no cost to reproducibility.

Rewind works by restoring the nearest snapshot and re-simulating forward, so
snapshots must be *complete*: RNG stream positions, ID allocator state, projectile
pool contents and the pending command queue all have to survive the round trip.
Anything that affects future evolution but is not in the snapshot is a bug.

---

## The escape hatch

A line marked `# determinism-ok: <reason>` is skipped by the lint. It is deliberately
noisy so that reaching for it is a conscious act, and the reason is for the next
reader. Current uses are the two places that collect Dictionary keys specifically in
order to sort them.
