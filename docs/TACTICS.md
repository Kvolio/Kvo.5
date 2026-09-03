# Detection, captains and formations

## The horizon is the whole story

The single most important number in detection is not a spotting range in anybody's data
file. It is the horizon. A lookout does not fail to see a battleship at 25 km because she
is small — he fails because she is below the curve of the earth.

Distance to the horizon goes as the square root of height (`3570 * sqrt(h)` metres for
the eye, `4120 * sqrt(h)` for centimetric radar, which the atmosphere bends downwards),
and **both ships get their own**. That one piece of geometry produces:

* the masts sighted long before the hull — a ship appears as a smudge and resolves
* a destroyer with a 25 m mast sees a battleship's 50 m foretop at the same distance the
  battleship sees her masts: the geometry is symmetric even though the ships are not
* running below the horizon actually working, which is how ships escaped

None of it is stated per ship. A ship's sighting height is read from the superstructure
her own design produced (`ShipStructureBuilder`), multiplied up to reach the foretop and
the masthead where the lookouts and the aerials actually were. A design nobody has drawn
before gets a horizon that follows from its own shape.

Within the horizon, weather and size decide. At night, radar decides, which is the reason
the US Navy stopped losing night actions. Two things give a ship away beyond all of it: a
gun flash, visible far past the horizon reflected off haze, which is how most night
actions actually opened and why opening fire is a decision; and a fire aboard, which is
why a damaged ship at night was so much easier to finish than to find.

## The plot, and why the AI reads it

Detection is held **per team**, not per ship: every lookout and every set in the formation
reporting into one picture that the whole formation manoeuvres on. That is what a
flagship's plot was.

It is also the restriction the AI rests on. `AiSystem` decides from `ContactPlot` and
never from `world.ships`. An AI that read the world directly would be playing with the lid
off — it could never lose a target in the dark, never be surprised, never be drawn onto a
contact that turned away four minutes ago. Every interesting thing a night action does to
a fleet comes from that one restriction.

A contact is carried forward on its last known course after it is lost, and only then
forgotten. Dead reckoning is not a nicety: a contact carried forward on a course the
target has since left is the most dangerous kind of information there is, and a plot that
dropped a contact the instant it was lost could never produce that mistake.

A contact from a gun flash is a bearing and a guess. It is never firm enough to shoot at.

## Where to fight: the immunity zone

The preferred fighting range is not a number in a config file. It is read off the ship's
own **immunity zone** against the gun she is facing.

Close in, a shell arrives flat and fast and goes through the belt. Far out it arrives
slowly but steeply and comes through the deck. Between the two there may be a band where
it does neither, and that band is the single most important tactical fact about an
armoured ship: it is what her armour was designed to produce and what her captain fought
to stay inside.

`ImmunityZone.compute()` finds it by asking **the same penetration model the trajectory
tracer asks**, at each range in the gun's own range table, and seeing what it answers. So
a design nobody has ever drawn gets a doctrine from its own plate, and if the penetration
model is ever replaced the zone moves with it.

The zones the model produces, for the roster:

| Ship | vs Yamato 46 cm | vs Iowa 16"/50 | vs Baltimore 8"/55 |
|---|---|---|---|
| Iowa | none | — | 5–24 km |
| Yamato | — | 24–26 km | 2–28 km |
| Baltimore | none | none | — |
| Fletcher | none | none | none |

**Both** zones decide where to fight, and that is the half the first version got wrong.
It read only the ship's own zone and steered for the middle of it — which is correct in
isolation and disastrous in company, because two battle lines each holding the middle of
their own zone sit twenty-five kilometres apart firing at each other for half an hour and
hit nothing. That is precisely what it did: fifteen hundred shells, no hits. Real
commanders closed, and they closed because a long-range gunnery duel achieves nothing.

So the wanted range is the one where **she cannot be hurt and he can**. Where no such
range exists — and against a heavy enough gun there often is none — being able to hurt
him wins, and closing is what makes that true, because accuracy improves as the range
falls far faster than protection does. Two documented simplifications, both the
ones the historical calculation made: the target is taken beam-on, which is the worst case
for her and therefore the honest one to design against; and the armour deck is taken as
the plate that decides a plunging hit, the weather deck's job being to strip the cap and
start the fuze rather than to stop the shell.

A destroyer facing a 16-inch gun has no immunity zone at all, and the model says so
rather than inventing one.

## Captains

`AiSystem` gives each ship a posture — hold, engage, close, disengage, evade — and one
decision cycle per interval, staggered by id.

**Target selection** is scored: what she is worth, how far off, whether anyone has
identified her yet, whether the guns can actually reach her, and how many friends are
already engaging her. The concentration penalty is what stops a fleet piling onto one
destroyer; the reach penalty is what stopped an Essex engaging a cruiser thirty-seven
kilometres away with five-inch guns that reach sixteen. Ties break by entity id, which is
what makes a fleet action reproducible.

Selection is deliberately **sticky**, on a timer. Shifting target is a deliberate order
and a costly one — it reopens the plot, and a plot reopened every twenty seconds never
gets past its opening salvo. Reconsidering on every decision cycle let the score churn as
contacts came and went and ranges changed; ships shifted several times a minute, and the
guns never settled. Now the guns stay on a target for `reviewSeconds` before shifting is
even considered, and then only for something clearly better.

**Manoeuvre** scores candidate headings rather than solving for one, because the two goals
genuinely conflict: the heading that closes the range fastest is bow-on, and bow-on masks
most of her guns. Which way that trade falls is the whole of naval tactics, and
`unmaskWeight` in `data/config/ai.json` is where it is stated.

**Torpedoes** are the one decision a destroyer captain really makes. She gets one salvo,
and firing at extreme range gives the target minutes to turn away — history is full of
salvos that missed for exactly that reason — so she holds until she is well inside the
run and her tubes actually bear, asked of the same solver the player's own order uses.

**Combing** a torpedo track works for a reason that needs no special case anywhere: a ship
end-on is a target a tenth as wide, and the torpedo's run against her hull is resolved by
the same geometry as everything else. Torpedo tracks are read straight off the world
rather than through the contact plot, bounded by a wake-spotting range instead — a track
is not a ship and is not reported into a fleet's plot. It is seen, from the ship it is
running at, or not at all. Which is why the first warning was so often the explosion.

## Formations

A formation is an offset in the **guide's frame**, not a set of world positions, and
everything good about it follows from that. When the guide turns, every station turns with
her, so a column turning together is a turn and not a teleport. A formation whose guide is
sunk re-forms on the next ship in the line rather than dissolving, which is what a squadron
did — and why a battle line could lose its flagship without losing its formation.

Station keeping decomposes the error: **course** for the across-track part, **speed** for
the along-track part. Steering at the station point directly is the obvious implementation
and it is wrong — a ship two cables astern of station would turn round and steam back
towards it, and a whole column that had just followed a turn would do it at once. If you
are astern of station you go faster; you do not turn round. Closing a big turn takes six
or seven minutes, which is about right.

A ship evading torpedoes or breaking off stops keeping station, so the formation cannot
steer her back into a salvo she has just turned to comb.

## Fleets

`data/fleets/*.json` describes an order of battle: divisions, each with a formation, a
station relative to the fleet, and its ships. `FleetIo.deploy()` puts them on the water
already formed up. Ships are added in a fixed order — divisions as listed, units as listed
— because entity ids are allocated as ships are added and the whole simulation's
determinism rests on those ids. A fleet that deployed in a different order would be a
different battle from the same file.

Four are included: a US fast carrier task group, a Japanese mobile force detachment, a
Home Fleet squadron, and the Bismarck sortie as it was actually composed — two ships, no
carrier, no screen worth the name, and nowhere to run to.

## What a fleet action looks like

`tests/integration/test_fleet_action.gd` puts the first two in contact and fights them for
eight minutes: seventeen ships, both AIs choosing targets and courses from their own
plots, detection, gunnery, torpedoes, aircraft and damage, all from one seed — and asserts
that a battle actually happens. Roughly five thousand shells, five per cent of them
arriving, torpedo salvos from both screens, and ships lost on both sides.

That suite exists because every unit test in this stage passed while the whole thing did
nothing. Two task groups closed for twenty-five minutes, fired fifteen hundred shells and
scored not one hit — no component broken, just engaging at thirty kilometres where the hit
rate is genuinely zero, and shifting target often enough that no plot ever settled. It is
the class of failure a suite of unit tests cannot see, and the reason the integration
suite asserts an outcome rather than a mechanism.
