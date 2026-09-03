# Scenarios, saves and replays

## A battle is four things

A whole naval action is described by the scenario it was fought in, the seed, the
ordered log of commands that entered the simulation from outside, and nothing else. A
recorded seventeen-ship fleet action is a few kilobytes.

That is the payoff for two rules kept since Stage 0. Nothing mutates simulation state
from outside except through `CommandQueue`, so the command log is complete by
construction. And AI decisions are *derived* inside the simulation from state that is
itself derived from the seed and the initial conditions, so they need no recording at
all — which is why `AiSystem` steers through `MovementSystem` directly and never through
the command queue. An AI order that went through the queue would be replayed from the
log *and* re-derived by the AI, and the ship would empty her tubes twice.

`ReplayRecorder.replay_into()` returns the tick at which a replay diverged, or −1. The
periodic checksums are what turn a silent divergence into a named tick, and
`test_a_replay_notices_when_it_diverges` asserts that the mechanism actually catches a
corrupted log rather than sailing past it.

## Scenarios

`data/scenarios/*.json` names fleets and ships by id and sets the seed, the weather and
the victory condition. `ScenarioIo.build()` is the **only** way a battle is set up —
including the one the game boots into — because a battle set up by any other route would
be one no replay could reproduce.

The weather is not handed to the systems separately. It is written *into* the config they
already read, so a night action is one whose detection config says night and whose fire
control config says the rangefinders are useless. Setting sea state, darkness and
visibility in the scenario editor and watching the same two fleets produce a completely
different battle is the point of the screen.

Four are included, and they are chosen to exercise different parts of the model:

| Scenario | What it is for |
|---|---|
| Carrier Action | two task groups beyond sight of one another — detection, aircraft, and a long approach |
| Battleship Duel | Iowa against Yamato at 18 km, nothing else on the sea: the cleanest test of gunnery there is |
| Night Destroyer Action | Kagero against Fletcher in the dark: no radar and the best torpedoes of the war, against radar and worse ones |
| Denmark Strait | heavy sea, half visibility, and both sides in a hurry |

## Snapshots, and what "complete" means

`Snapshot.capture()` takes everything that decides what happens next, and the word is
meant literally: the position of every random number stream, the id allocator's counter,
shells and torpedoes already in the air, each side's contact plot, each ship's damage,
her gunnery solution and her captain's intentions.

A snapshot that restored the ships but not the plots would produce a battle that looked
identical for thirty seconds and then diverged, which is the worst kind of wrong. So the
specification is a test rather than a list: `test_a_snapshot_restored_re_simulates_
identically` runs a battle to its halfway point, snapshots it, runs it to the end, then
builds a fresh world from the same scenario, restores the snapshot into it, and requires
the second half to come out bit for bit the same.

It found a real bug immediately, and a good example of the kind: the id allocator was
restored *before* the shells in the air, and putting those back goes through the ordinary
spawn path, which allocates ids as it does so. The counter ended up several dozen ahead of
where the battle actually was and the next shell fired carried an id the recording never
issued. One line of ordering, and it made every restored battle diverge on its first
salvo.

One serializer does three jobs — saving a battle in progress (F5/F9), rewinding a replay,
and that test — because a save that used a different one would eventually disagree with
the replay about what a battle is.

Condition is **derived** and so is not stored: a save carries the flooding, the wreckage
and the dead, and the integrity, the list and the status are worked out again from them by
`reassess_all()`. Storing the conclusions as well as the evidence would be two fields that
are supposed to agree, and eventually would not.

## Looking at what happened

Three surfaces, all reading the same causal data, none of them writing anything.

**Combat log** (`L`) — the battle in words, in order. Events are an *output* of the
simulation and never an input to it, so the log can be as chatty as it likes without
costing reproducibility anything.

**Ship inspector** (`I`) — the compartment plan, drawn from the same
`ShipStructureTemplate` the trajectory tracer intersects. A second drawing of a ship's
insides would be a second thing to keep in step, and it would lose the argument with the
tracer every time. Compartments are coloured by what is wrong with them, which makes the
*shape* of the damage legible: a line of flooded spaces down one side is a torpedo hit, a
burning cluster amidships is a fire in the machinery.

**Debug mode** (`G`) — the whole causality chain for the last shell that arrived. This is
the payoff for `HitReport` being the damage *mechanism* rather than a log of it. Nothing
is reconstructed: every line is a `LayerInteraction` the tracer actually resolved, with
the projectile's state before and after and the penetration model's own reasoning. A
player who wants to know why a 16-inch shell failed against a cruiser can read the plate
it met, the obliquity, the effective thickness against the capability, whether the cap
survived, and where it stopped — instead of being told it did 4,200 damage.

The formatting for the log and the debug view lives in `CombatLogText` and
`DebugOverlayText` rather than in the widgets, because it is not a widget concern: the
same text serves the screen, a headless dump and any future export, and it is the half
worth testing.
