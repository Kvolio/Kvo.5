# The ship designer

> Nothing in this screen knows that armour costs speed.
> It knows how to change a number, and how to ask what the ship became.

---

## Why it is built this way

A designer that applied a penalty for armour would be a designer whose numbers could be
argued with. This one weighs the plate, so it can only be argued with about the plate.

Every control edits a `ShipSpec`. After every edit the design is built into a
`ShipStructureTemplate` from scratch and handed to `NavalArchitect.analyse()`, which sums
the armour that is actually on her — every face, its area, its thickness, its material
density — and works out what she displaces, where her centre of gravity is, and how fast
she will go. Thicken the belt and she gets heavier, sits deeper and slows down, because
those are consequences of the same arithmetic rather than three rules that happen to
agree.

`docs/NAVAL_ARCHITECTURE.md` covers the model itself, including where it still misses.

---

## The screen

The analysis strip **is not a tab**. It sits under the editors, always visible, and
refreshes on every edit. That is deliberate: every slider on every tab exists to move
those numbers, and a consequence you have to go and look for is a consequence the
designer failed to show you.

| Tab | What it changes |
|---|---|
| Hull | Length, beam, draft, displacement (full and standard), crew |
| Engines | Shaft power, design speed, shafts, boilers, funnels, machinery type |
| Armour | Every zone, plus the depth of the torpedo defence system |
| Weapons | Gun choice, where each mount sits, how many barrels it carries |
| Layout | The weight statement, and how much room the machinery needs against how much it has |

Beside them is a plan view of the design — drawn by **the same renderer the battle uses**,
against a one-ship `SimWorld`. It is not a second drawing of the ship that could disagree
with the first. Widen the beam and the outline changes because the hull changed.

---

## Three things that are easy to get wrong

**A design is a deep copy.** `ShipDatabase.get_spec_for_editing()` copies the armour and
armament rather than sharing them. Sharing is right for a battle, which only ever reads
them, and wrong here: thickening a belt on a design based on Iowa would otherwise rewrite
Iowa for the rest of the session.

**The hull is cached and has to be invalidated.** `ShipSpec.hull()` builds the waterplane
once and keeps it, which is correct for a ship in a battle whose dimensions never change.
Move the beam slider without `invalidate_hull()` and the design goes on displacing,
floating and steering like the ship it used to be.

**Rebuilds are coalesced to one a frame.** Dragging a slider fires a change every frame,
and each rebuild regenerates several hundred plates and compartments and weighs them.
Without `call_deferred`, the designer fights the mouse.

---

## Saving

`ShipIO.to_document()` writes exactly what `data/ships/*.json` contains — the schema, not
a private one — and `ShipDatabase` scans `user://ships/` alongside the presets. So a
saved design is a preset in every way that matters, and the engine has no way to tell
them apart. That is §4, and it is verified rather than asserted: `test_ship_io.gd`
round-trips **all seventeen presets** — load, serialize, re-parse, compare field for
field by reflection — and then checks that a design which has been to disk and back is
weighed identically to the one that was saved.

The reflective comparison is the important part. A test that names the fields it checks
can be forgotten in exactly the same way as the serializer it is testing.

---

## Findings, not refusals

The validator warns and never fixes. A player may build something absurd and the
simulation will show them what happens, so every finding is a reason:

> **Floats 0.13 m deeper than drawn** — The hull displaces 57540 tonnes at the stated
> draft but the design weighs 58423, so she settles until she displaces her own weight.
> That costs 2% of her freeboard and puts more of the belt under water where it protects
> nothing.

Findings come back worst-first and are coloured by severity.

---

## What could not be tested headlessly, and what could

`tests/unit/test_screens.gd` builds every screen, checks the designer opens on a copy
under an id no preset is using, and drives the whole §44 loop: designer → design →
battle, asserting the player's own ship is in the line.

One thing about the harness is worth knowing, because it cost an hour. The headless
runner does its work inside `SceneTree._initialize()`, and at that point **the root
window is not yet inside the tree** — so adding a child triggers neither `_enter_tree`
nor `_ready`, and a screen added to it just sits there having built nothing.
`propagate_notification(NOTIFICATION_READY)` does not help either; it is a no-op for a
node whose tree has not started. The test drives `_ready` by calling it, recursively,
and `ShipDatabase` grew the lazy load that `GameConfig` and `WeaponDatabase` already had,
because a registry that answers "there are no ships" instead of going and reading them is
a trap regardless of who is asking.

Whether the screen is *usable* is not something any of that can tell you:

```bash
tools/screenshot.sh /tmp/designer.png --screen=designer
```
