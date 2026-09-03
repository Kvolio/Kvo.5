extends Node2D

## Draws the ships.
##
## Silhouettes come from each ship's own HullGeometry, and the detail above them from
## her ShipStructureTemplate — the same geometry shells are intersected against. There
## is no separate "art" that can disagree with the simulation. Change a hull's beam in
## the designer and the shape on screen changes with it; give a design a second director
## and it appears on the plot, because the plot is drawing the thing the tracer hits.
##
## Detail is tiered by APPARENT size, not by ship class, so zooming in on a destroyer
## resolves her exactly as it does a battleship:
##
##   under 14 px of hull   a fixed-size tactical symbol
##   14 - 70 px            her real silhouette
##   70 - 240 px           and her turrets, trained where they are trained
##   over 240 px           and her barbettes, superstructure, directors and deck seams
##
## Geometry only. Text lives in TacticalLabels, drawn in screen space, because world-
## space text has to be scaled by 1/zoom and integer font sizes make that quantise
## badly at high zoom and absurdly expensive at low zoom.

var world: SimWorld = null
var selected_id: int = 0
var show_headings: bool = true

var _zoom: float = 1.0
var _config: Dictionary = {}
var _zoom_config: Dictionary = {}
var _turret_config: Dictionary = {}
var _detail_config: Dictionary = {}


func _ready() -> void:
	set_config(GameConfig.get_dict("view"))


func set_config(config: Dictionary) -> void:
	_config = config
	_zoom_config = config.get("zoom", {}) as Dictionary
	_turret_config = config.get("turret", {}) as Dictionary
	_detail_config = config.get("detail", {}) as Dictionary
	queue_redraw()


func set_zoom(zoom: float) -> void:
	if not is_equal_approx(_zoom, zoom):
		_zoom = zoom
		queue_redraw()


## Fill a polygon, skipping anything that would cover less than a pixel.
##
## Judged on AREA, not on a bounding box: a barrel drawn on the diagonal is a thin
## sliver with a large square bounding box, so a box test passes it straight through.
## Below a pixel there is nothing to see anyway, and Godot's triangulator reports a
## failure for every degenerate polygon it is handed, which at fleet zoom is hundreds
## of lines of noise a frame.
func _fill(points: PackedVector2Array, colour: Color) -> void:
	if points.size() < 3:
		return
	var twice_area: float = 0.0
	for i: int in points.size():
		var a: Vector2 = points[i]
		var b: Vector2 = points[(i + 1) % points.size()]
		twice_area += a.x * b.y - b.x * a.y
	# Metres squared into pixels squared.
	if absf(twice_area) * 0.5 * _zoom * _zoom < 1.0:
		return
	draw_colored_polygon(points, colour)


func _draw() -> void:
	if world == null:
		return
	for ship: ShipEntity in world.ships:
		_draw_ship(ship)


## Everything below is drawn in SHIP-LOCAL metres under a canvas transform, rather than
## in world coordinates worked out here.
##
## Not a tidiness preference — a correctness one. Vector2 is 32-bit, and a battleship
## eleven kilometres from the origin has coordinates around 11000; a gun barrel is a
## third of a metre wide. Baking the ship transform into each vertex asks a float to
## hold both, and it cannot: the barrel quads arrived at the triangulator as degenerate
## slivers and silently vanished. In local space the same vertices are small numbers
## around zero and keep every digit that matters.
func _draw_ship(ship: ShipEntity) -> void:
	var colour: Color = ViewPalette.ship_colour(ship.team, ship.status)
	var is_selected: bool = ship.id == selected_id
	if is_selected:
		colour = colour.lerp(ViewPalette.SELECTED, 0.5)

	draw_set_transform(ship.position, ship.heading, Vector2.ONE)
	var apparent: float = ship.spec.length_m * _zoom
	if apparent < float(_zoom_config.get("minSilhouettePixels", 14.0)):
		_draw_symbol(ship, colour, is_selected)
	else:
		_draw_silhouette(ship, colour, is_selected, apparent)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_silhouette(ship: ShipEntity, colour: Color, is_selected: bool,
		apparent: float) -> void:
	var outline: PackedVector2Array = ship.hull().outline_local()
	var fill: Color = colour
	fill.a = ViewPalette.HULL_FILL_ALPHA
	draw_colored_polygon(outline, fill)

	# Line widths are divided by zoom so they stay a constant thickness on screen at
	# every scale — a hairline outline that vanishes when zoomed out is useless on a
	# tactical plot.
	var width: float = (2.0 if is_selected else 1.0) / _zoom
	draw_polyline(_close(outline), colour, width, true)

	var detailed: bool = apparent >= float(_zoom_config.get("minDetailPixels", 240.0))
	if detailed:
		_draw_detail(ship, colour)

	if show_headings:
		_draw_heading_vector(ship, colour)
	if apparent >= float(_zoom_config.get("minTurretPixels", 70.0)):
		_draw_turrets(ship, colour, detailed)


# ------------------------------------------------------- structure, from above --

## Superstructure, directors, radar and deck seams, projected from the ship's own
## structure template. None of this is drawn art: every block is a volume a shell can
## be traced into.
func _draw_detail(ship: ShipEntity, colour: Color) -> void:
	if world == null:
		return
	var detail: ShipDetail = ShipDetail.for_ship(
		ship.spec, world.structure_for(ship), _config)

	var seam: Color = colour
	seam.a = float(_detail_config.get("deckLineAlpha", 0.16))
	var hairline: float = 1.0 / _zoom
	for line: PackedVector2Array in detail.deck_lines:
		draw_line(line[0], line[1], seam, hairline, true)

	for block: ShipDetail.Block in detail.blocks:
		var fill: Color = colour
		fill.a = float(_detail_config.get("componentAlpha", 0.55)) if block.is_equipment \
			else float(_detail_config.get("superstructureAlpha", 0.42))
		_fill(block.polygon, fill)
		draw_polyline(_close(block.polygon), colour, hairline, true)


# ---------------------------------------------------------------------- turrets --

## Gun mounts, drawn where they are and pointing where they are trained.
##
## Worth the pixels: a ship with her turrets trained hard round is visibly engaging
## something off the bow, and one whose after turret sits fore and aft while the
## forward pair are trained out is visibly unable to bring it to bear. Both are real
## tactical facts that would otherwise be buried in a panel.
func _draw_turrets(ship: ShipEntity, colour: Color, detailed: bool) -> void:
	var hairline: float = 1.0 / _zoom
	var plan: Dictionary = ShipDetail.plan_for(_config, ship.spec.nation)

	for turret: Turret in ship.turrets:
		# A gunhouse is sized by its gun and by how many of them it holds: a triple
		# 16-inch turret is about 11 m across and a twin 5-inch mount about 3, and both
		# come out of the same two numbers. So a battleship's main battery dwarfs her
		# secondaries on the same plot without either being drawn to a fixed size.
		var calibre: float = turret.gun.calibre_m
		var width: float = calibre * float(_turret_config.get("gunhouseWidthCalibres", 20.0)) \
			+ float(turret.barrels()) * calibre \
			* float(_turret_config.get("gunhousePerBarrelCalibres", 2.5))
		var length: float = width * float(_turret_config.get("gunhouseLengthRatio", 1.15))
		var centre: Vector2 = turret.mount.local_position(
			ship.spec.length_m, ship.spec.beam_m)

		# The barbette is fixed to the ship while the gunhouse turns on it. Drawing both
		# is what makes training legible: the ring shows from under the overhang as soon
		# as the turret comes off the centreline.
		if detailed:
			var radius: float = width * 0.5 \
				* float(_turret_config.get("barbetteDiameterFraction", 0.85))
			var ring: Color = colour
			ring.a = 0.30
			draw_arc(centre, radius, 0.0, TAU, 24, ring, hairline, true)

		# The gunhouse turns about its own axis, so its outline is drawn in turret-local
		# space and carried into the world by one transform. Turret bearing is relative
		# to the ship, which is exactly what composing with the hull transform gives.
		var gun_house: Transform2D = Transform2D(turret.bearing, centre)

		var body: PackedVector2Array = PackedVector2Array()
		for point: Vector2 in ShipDetail.gunhouse_plan(plan, length, width):
			body.append(gun_house * point)
		var fill: Color = colour
		fill.a = 0.55 if turret.is_operational() else 0.20
		_fill(body, fill)
		if detailed:
			draw_polyline(_close(body), colour, hairline, true)

		if not turret.is_operational():
			continue
		_draw_barrels(turret, colour, gun_house, length, width, detailed)


## One barrel per gun, on the real gun spacing, at the real barrel length.
##
## Recoil is driven by the turret's own reload state rather than by an animation: a gun
## that has just fired is run in, and runs out over the following seconds. So a ship
## firing salvoes visibly works her guns, and it is caused rather than decorated.
func _draw_barrels(turret: Turret, colour: Color, gun_house: Transform2D,
		length: float, width: float, detailed: bool) -> void:
	var barrels: int = turret.barrels()
	if barrels <= 0:
		return
	var barrel_length: float = turret.gun.barrel_length_m()
	var barrel_half: float = turret.gun.calibre_m \
		* float(_turret_config.get("barrelWidthCalibres", 2.6)) * 0.5
	var root_x: float = length * 0.62      # the face plate, in gunhouse-local metres

	# How far the gun is still run in. Full travel the instant it fires, running out
	# over the next few seconds — but never longer than the reload itself.
	var run_out: float = maxf(float(_turret_config.get("recoilRunOutSeconds", 2.5)), 0.01)
	var elapsed: float = maxf(turret.gun.seconds_per_round() - turret.reload_remaining, 0.0)
	var recoil: float = 0.0
	if turret.reload_remaining > 0.0 and elapsed < run_out:
		recoil = (1.0 - elapsed / run_out) * barrel_length \
			* float(_turret_config.get("recoilTravel", 0.16))

	# Gun spacing follows the turret, not the drawing: guns sit close together in a
	# common cradle, which is why a triple turret is not three times as wide as a single.
	var spacing: float = width * 0.30
	for i: int in barrels:
		var offset: float = 0.0
		if barrels > 1:
			offset = (float(i) / float(barrels - 1) - 0.5) * spacing * float(barrels - 1)
		var base: float = root_x - recoil
		var muzzle: float = base + barrel_length

		_fill(PackedVector2Array([
			gun_house * Vector2(base, offset - barrel_half),
			gun_house * Vector2(muzzle, offset - barrel_half * 0.82),
			gun_house * Vector2(muzzle, offset + barrel_half * 0.82),
			gun_house * Vector2(base, offset + barrel_half),
		]), colour)

		# The canvas boot where the barrel leaves the gunhouse. Small, and most of what
		# makes a turret read as a turret rather than a box with sticks.
		if not detailed:
			continue
		var bag: float = barrel_length * float(_turret_config.get("blastBagLength", 0.16))
		var bag_half: float = barrel_half * float(_turret_config.get("blastBagWidth", 1.9))
		var boot: Color = colour
		boot.a = 0.75
		_fill(PackedVector2Array([
			gun_house * Vector2(root_x - bag * 0.35, offset - bag_half),
			gun_house * Vector2(root_x + bag, offset - bag_half * 0.72),
			gun_house * Vector2(root_x + bag, offset + bag_half * 0.72),
			gun_house * Vector2(root_x - bag * 0.35, offset + bag_half),
		]), boot)


# ------------------------------------------------------------------- symbols --

func _draw_symbol(ship: ShipEntity, colour: Color, is_selected: bool) -> void:
	# A chevron pointing along the ship's heading: readable at two pixels, and still
	# tells the player which way she is going.
	var size: float = float(_zoom_config.get("symbolPixels", 9.0)) / _zoom
	# Local space: the ship faces along +x and the transform carries her heading.
	var forward: Vector2 = Vector2.RIGHT
	var side: Vector2 = Vector2.DOWN
	var points: PackedVector2Array = PackedVector2Array([
		forward * size,
		-forward * size * 0.5 + side * size * 0.55,
		-forward * size * 0.15,
		-forward * size * 0.5 - side * size * 0.55,
	])
	var fill: Color = colour
	fill.a = 0.55
	draw_colored_polygon(points, fill)
	draw_polyline(_close(points), colour, (2.0 if is_selected else 1.0) / _zoom, true)


## A line ahead of the ship showing where she will be in one minute at present speed.
## Length carries information rather than being decorative: a fast ship's vector is
## visibly longer than a slow one's.
func _draw_heading_vector(ship: ShipEntity, colour: Color) -> void:
	if absf(ship.speed) < 0.1:
		return
	var faded: Color = colour
	faded.a = 0.45
	draw_line(Vector2(ship.spec.length_m * 0.5, 0.0),
		Vector2(ship.speed * 60.0, 0.0), faded, 1.0 / _zoom, true)


static func _close(points: PackedVector2Array) -> PackedVector2Array:
	var closed: PackedVector2Array = points.duplicate()
	if not closed.is_empty():
		closed.append(closed[0])
	return closed
