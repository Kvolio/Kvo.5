# The damage model

> Armour decides whether the projectile gets in.
> The internal layout decides what it reaches.
> What it reaches decides what breaks.
> What breaks decides how the ship performs and whether she survives.

There is no per-shell damage number anywhere in this model, and nothing subtracts
from a health pool. What follows is how a physical event becomes a consequence.

---

## The two rules

### A clean non-penetration costs exactly zero structural integrity

Not a small number. **Zero.** A 350 mm belt that stops a 406 mm shell has done its
job, and the ship is structurally exactly as sound as she was a moment earlier.

What such a hit can still do is real and often decisive, and every one of these is a
modelled mechanism with a cause:

- **Plate deformation** accumulates on the face that was struck, so it resists less
  next time.
- **Spall** comes off the inner face and wrecks equipment behind armour that was
  never beaten.
- **Shock** propagates through intact plate. Radar and directors are delicate; a
  propeller shaft is a steel bar, and the model distinguishes them.
- **Exposed fittings** near the impact — anti-aircraft mounts, rangefinders, optics,
  boats — are simply removed. A non-penetrating hit is very good at this, which is
  how a ship can be structurally untouched and half-blind.
- **Crew** in the compartment behind are killed.

If any structural consequence follows, it is because spall got into a compartment or
a component was wrecked. Never because "a shell does damage".

### Structural integrity is derived, not decremented

`SurvivabilityEvaluator.assess()` recomputes it from the ship's condition every time
that condition changes:

```
integrity = f(wrecked compartment volume weighted by structural contribution,
              hull breach area against plating area,
              flooded volume, fire-consumed structure, hull girder damage)
```

It exists because the UI, scenario victory rules and the designer's survivability
estimate all want one headline number. **It is not what decides survival.**

Survival is decided from the conditions directly:

| Destroyed | Mission kill |
|---|---|
| magazine detonation | main battery destroyed |
| reserve buoyancy exhausted (foundered) | propulsion lost |
| list past the stability limit (capsized) | steering lost |
| trim past the limit (down by the head or stern) | fire control lost — *every* director **and** the radar |
| hull girder severed (broke in two) | flooding beyond control |

Which is why a ship can be combat-dead at 90% integrity with her turrets wrecked, and
still fighting at 60% with her guns and engines intact. Both are asserted by test.

---

## Flooding

Torricelli, and almost everything else follows from it:

```
Q = Cd · A · √(2gh)
```

Damage low down is far worse than damage high up, because `h` is the depth of the
hole. And as a ship floods she settles, which increases `h` on every hole she already
has — so **flooding accelerates itself**. That is how a damaged ship that looked
stable half an hour ago suddenly goes.

Flooding is **local**. One opened compartment floods one compartment. It crosses a
boundary only where damage has actually opened one, which is what makes subdivision
worth anything and why a torpedo hit is survivable at all.

Water off the centreline heels the ship; water forward or aft trims her. Both fall
out of *where* the flooded compartments are rather than from a list value being set.

**Reserve buoyancy** is the watertight volume standing *above* the waterline — the
difference between what the hull encloses and what she already displaces. It is not
"volume not yet flooded": a ship goes down at something under half her volume, not at
all of it.

---

## Fire

Fires grow while there is something left to burn, spread through shared boundaries,
consume the structure they burn through, kill the people fighting them, and cook off
magazines. A fire in a void is an inconvenience; a fire in the aviation petrol
stowage or beside a magazine is how carriers and battlecruisers were lost.

Magazines are flash-tight and could be flooded on suspicion, so fire reaches them
rarely — which is exactly what makes it decisive when it does.

Flooding puts fires out. That is not a consolation: a flooded machinery space is as
useless as a burning one.

---

## Torpedoes

A torpedo is **not** a projectile that penetrates. It detonates against the hull and
the blast works its way inboard, being absorbed by whatever is in the way.

That is why torpedo defence is modelled as **real layered structure** — an expansion
void to let the gas bubble vent, a liquid layer to spread the shock, a holding
bulkhead to stop what is left — rather than as a percentage taken off a damage number.

The model separates two questions:

- **How deep?** The blast walks inboard through the layers, spending energy on each.
  This is the defence system's entire job, and the absorption constants are
  calibrated so that a well-designed system defeats the warhead it was designed
  against. Bismarck's 5.5 m system with its 45 mm holding bulkhead absorbs about
  340 MJ against the ~310 MJ a 280 kg G7a couples into the hull. A Fletcher, with ten
  millimetres of plating and no system at all, absorbs under 200 MJ across her whole
  beam — so the same torpedo goes straight through her.
- **How wide?** The warhead. Everything inside a cylinder of the hole's radius,
  reaching as far in as the blast got, is opened to the sea.

Getting this wrong in an instructive way: treating the whole effect as the single
*line* the blast traced meant a torpedo opened three compartments of a destroyer and
she barely noticed it. A ten-metre hole is a volume.

**The flooding is the weapon, not the wreckage.** A torpedo destroys relatively
little structure; it makes a hole and lets the sea do the rest. The shock also springs
the watertight boundaries of the compartments *around* the ones it opened, so water
works its way further into the ship over the following minutes. That progressive
flooding is what turns a contained hit into a lost ship.

Other consequences that come from position rather than from rules:

- A hit right aft wrecks the steering gear, which sits outside the citadel. The ship
  is structurally sound, fully buoyant, and cannot steer — the classic torpedo
  mission kill.
- A hit amidships strains the hull girder. Enough of them in the same place and her
  back breaks.
- A torpedo set deeper than the target's draft runs harmlessly underneath, which is
  part of why a destroyer is a much harder torpedo target than a battleship quite
  apart from being smaller.

---

## Damage control

Effort is **finite and spread across every emergency at once**. Two fires are each
fought half as well as one; five are barely fought at all.

That is how severe damage overwhelms a crew — not by a threshold that switches damage
control off, but by there being too much of it, which is what actually happened aboard
ships lost to damage they had initially contained.

Casualties compound it directly. Fewer people means fewer parties, so a ship that has
been badly hurt copes worse with the next hit than she did with the last.

Priorities, highest first: fire beside a magazine, magazine flooding, fire, flooding
below the waterline, flooding, repairs. Nothing is abandoned outright — it is simply
attended to badly, which is the honest model of being swamped.

Two details worth stating:

- **Shoring comes before pumping.** Pumping against an open hole is wasted work, so
  the sealing rate gates it.
- **Damaged and disabled fittings come back; destroyed ones do not.** That is the
  whole reason the two states are distinguished.

---

## Tuning

Every constant is in `data/config/damage.json` and `data/config/torpedo.json`, and
each carries a comment explaining what it means and how it was calibrated.

The values most worth revisiting are the ones calibrated against outcomes rather than
measured: `energyPerWreckedCubicMetre` (set from both ends — a 16-inch burst should
gut about one machinery space, and twelve 8-inch bursts should sink a destroyer), the
torpedo absorption constants, and the fire spread rate.

Calibrating against a simulated duel rather than by reading the code found four
things that inspection had missed: a single unarmoured director was an instant
mission kill; fire crossed a steel warship in seconds; fires never burned out; and
the energy-to-wreckage constant was some twelve times too high. If something feels
wrong, fight a battle and watch it rather than reasoning about the constant.
