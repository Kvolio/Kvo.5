# The air module, and the line it does not cross

Aircraft are an **optional module**. Nothing in `src/sim/` outside `src/sim/air/` names an
aircraft type, and a build with that directory deleted still compiles and still fights
battles.

That is easy to say and easy to lose. One `if projectile.is_bomb()` in the tracer and the
claim is gone without any test failing. So it is checked mechanically on every run by
`tests/lint/lint_air_isolation.gd`.

## Where the line runs

The module reaches into the naval core only through interfaces anything else could use:

* **Aircraft are `SimEntity`s** and go in the ordinary spatial index. `AirGroup` extends
  the same base class `ShipEntity` does.
* **Bombs are ordinary `Projectile`s.** A bomb arrives at a ship as a mass with a velocity
  and a fuze; the trajectory tracer decides what it goes through and the penetration model
  decides whether it gets in. There is nowhere in that chain to ask what dropped it —
  `spawn_projectile()` takes a null gun, because a bomb was never in one.
* **Aerial torpedoes are ordinary `Torpedo`s**, run by the ordinary torpedo system.
* **Carrier facilities are ordinary geometry.** The flight deck, the hangar and the
  elevators are components and compartments that the damage core wrecks, floods and burns
  exactly as it does a boiler room. It has no idea what any of them are for.
* **The module is stepped through a duck-typed hook.** `SimWorld.register_module()` asserts
  one method, `step_module(world, dt)`, and knows nothing else about what it has been
  given. The core names no module type.

So `HitResolver` contains no aircraft branch and cannot acquire one.

The consequence worth stating: **a carrier in a battle with the air module unregistered is
still a ship whose flight deck can be wrecked. She simply has nobody to tell.**

## What the module knows that the core does not

`CarrierOperations.assess()` is the whole isolation boundary in one file. It reads the
state of a carrier's own structure — flight deck condition, serviceable elevators, hangar
fire and flooding, how far she is listing — and turns it into whether she can fly.

The damage core produced all of that without knowing it was stopping a strike. Knowing
that a jammed elevator means whatever is in the hangar stays there, that a hangar well
alight means nothing flies at all, and that a 12° list is not something a Dauntless can
land on, is the module's business.

Which is why a single bomb down an open elevator well can end a carrier's day without
coming close to sinking her.

## Groups, not aeroplanes

The entity is the **group**. A carrier strike is six or eight groups, not ninety separate
objects. That keeps the entity count sane and — more to the point — matches how carrier
air was actually controlled: squadrons launched, flew, attacked and were shot at as units,
and no admiral ever manoeuvred an individual Dauntless.

Air combat and anti-aircraft fire are therefore resolved between groups, statistically.
That is a real abstraction and it is stated rather than hidden. What decided a carrier
battle was whether the fighters reached the bombers before the bombers reached the ships.

**Air combat** scores how much fire each side can bring, how well each side can turn, and
how much punishment each side can take. The A6M5's pairing of the highest agility in the
set with the lowest toughness is the whole story of that design, and it is in the data. A
loaded bomber fights badly, which is why bombers jettisoned when jumped. Fighters go for
strike aircraft first — the whole point of an interception, and the whole point of an
escort is to make that cost something.

**Anti-aircraft fire** is every barrel that bears, from every ship in range. Heavy AA is
the dual-purpose secondary battery, reaching furthest and hitting least, roughly tripled
from 1943 by the proximity fuze. The 40 mm band in the middle does most of the killing;
the 20 mm guns are last-ditch. A group in its attack run is flying predictably and cannot
dodge, and is hit far harder for it — which is the whole cost of pressing home an attack,
and why torpedo squadrons were annihilated and dive bombers were not. Damage tells: a ship
whose upperworks are wrecked has lost the guns that were on them.

**Fuel** is modelled, and groups that run out ditch. An unglamorous way to lose a
squadron, and one that cost the Japanese more at the Philippine Sea than fighters did.

## Data

`data/aircraft/*.json` — eight types covering the three carrier navies in the roster.
`data/ammo/*bomb*.json` — bombs as ordinary shell definitions, with a muzzle velocity of
zero, because a bomb has none: it arrives at whatever speed the dive and the fall gave it,
which is why release altitude decides what it can penetrate. Aerial torpedoes reuse the
existing torpedo definitions — the Mk 13, the Type 91 and the Mk IX are the same weapons
whether a ship or an aircraft delivers them, and modelling them twice would have been a
way to get two different answers.

`data/config/air.json` carries the constants. Nothing in the naval core reads that file.
