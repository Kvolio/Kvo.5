# Drawing the ships

> There is no art. There is only the ship.

`src/view/**` reads simulation state and draws it. It never writes to the sim, and the
determinism lint enforces that. What it draws is not a picture *of* a ship — it is the
ship's own geometry, projected.

---

## Nothing drawn can disagree with what a shell hits

A silhouette comes from the ship's `HullGeometry`, which is the outline the trajectory
tracer intersects. The detail above it comes from her `ShipStructureTemplate` — the
deckhouse, the bridge tower, the funnels, the barbettes, the directors, the radar — and
every one of those is a volume a shell can be traced into.

The consequence worth having: **a design nobody has ever seen renders correctly**. Build
a ship in the designer with her bridge somewhere unusual and it appears there, because
being above the main deck is what "you can see it from above" means. No artist has to
draw it and no lookup table has to know about it.

---

## The zoom ladder

Tiered by **apparent** size, not by ship class, so zooming in on a destroyer resolves her
exactly as it does a battleship. Thresholds are in `data/config/view.json`.

| apparent hull length | drawn |
|---|---|
| under 14 px | a fixed-size tactical chevron — readable at two pixels, and still shows her heading |
| 14–70 px | her real silhouette |
| 70–240 px | and her turrets, trained where they are trained |
| over 240 px | and her barbettes, superstructure, directors, secondaries and deck seams |

Turrets earn their pixels: a ship with her turrets trained hard round is visibly engaging
something off the bow, and one whose after turret sits fore and aft while the forward pair
are trained out is visibly unable to bring it to bear. Both are real tactical facts that
would otherwise be buried in a panel.

---

## What makes a turret look like a turret

A gunhouse in plan view is not a rectangle, and a rectangle with sticks does not read as a
turret. Four things fix it, and all four are driven by data the simulation already holds:

- **The barbette, drawn as a ring.** It is genuinely a cylinder in the structure template.
  It stays fixed to the ship while the gunhouse turns on it, so the ring appears from under
  the overhang the moment a turret comes off the centreline.
- **A gunhouse plan with a narrow face.** The sides converge on the face plate and the rear
  is cut away. Proportions come from `view.json` as named plans — `hexagonal` for US and
  Japanese practice, `rounded` for German, `box` for British — and they describe a *shape*:
  fractions of the gunhouse's own size, carrying no ship statistics.
- **Barrels at their real length, on real spacing,** sized in calibres so a 16-inch gun's
  tube is visibly thicker than a 5-inch one's. Gunhouse size follows the gun and the number
  of barrels, so a triple 16-inch turret comes out about 11 m across and a twin 5-inch mount
  about 3 — from the same two numbers.
- **A blast bag at each barrel root.** Small, and most of what makes the difference.

**Recoil is caused, not animated.** It is driven from the turret's own reload state, so a
gun that has just fired is run in and runs out over the following seconds. A ship firing
salvoes visibly works her guns because she is working them.

---

## Two bugs worth remembering

**Precision, not aesthetics.** Ships are drawn in *ship-local metres* under a canvas
transform rather than in world coordinates worked out per vertex. `Vector2` is 32-bit; a
battleship eleven kilometres from the origin has coordinates around 11000, and a gun barrel
is a third of a metre wide. Baking the ship transform into each vertex asks one float to
hold both, and it cannot — the barrel quads reached the triangulator as degenerate slivers
and silently drew nothing, at one error per barrel per frame. In local space the same
vertices are small numbers near zero.

**Judge polygons by area, not by bounding box.** A barrel drawn on the diagonal is a thin
sliver with a large square bounding box, so a box test passes it straight through. The
sub-pixel cull uses the shoelace area.

Both were found by looking at a screenshot and reading the log, not by reasoning — which is
the general lesson. `tools/screenshot.sh` renders the real game to a PNG, falling back to
Xvfb when there is no display. Some bugs only exist once something is actually drawn.

---

## Testing something visual

`tests/unit/test_ship_detail.gd` covers what can be asserted: that every configured turret
plan produces a polygon Godot will actually triangulate, that a gunhouse really is narrower
across its face than across its body, that detail blocks come from the ship's own structure
above her main deck and are ordered so the bridge draws over the deckhouse it stands on.

What it cannot cover is whether the result *looks* right. That is what the screenshots are
for, and there is no substitute for opening one.
