extends Node2D

## Draws the ships.
##
## Silhouettes come from each ship's own HullGeometry, so a design's outline on the
## plot is the same outline shells are intersected against — there is no separate
## "art" that can disagree with the simulation. Change a hull's beam in the designer
## and the shape on screen changes with it.
##
## At fleet zoom a 115 m destroyer is under two pixels long, so below a readability
## threshold ships are drawn as fixed-size tactical symbols instead. The switch is on
## APPARENT size, not ship class, so zooming in on a destroyer resolves it into a
## real hull exactly as it does for a battleship.
##
## Geometry only. Text lives in TacticalLabels, drawn in screen space, because world-
## space text has to be scaled by 1/zoom and integer font sizes make that quantise
## badly at high zoom and absurdly expensive at low zoom.

## Below this on-screen hull length (pixels), draw a symbol rather than a silhouette.
const MIN_SILHOUETTE_PIXELS: float = 14.0
const SYMBOL_PIXELS: float = 9.0

var world: SimWorld = null
var selected_id: int = 0
var show_headings: bool = true

var _zoom: float = 1.0


func set_zoom(zoom: float) -> void:
	if not is_equal_approx(_zoom, zoom):
		_zoom = zoom
		queue_redraw()


func _draw() -> void:
	if world == null:
		return
	for ship: ShipEntity in world.ships:
		_draw_ship(ship)


func _draw_ship(ship: ShipEntity) -> void:
	var colour: Color = ViewPalette.ship_colour(ship.team, ship.status)
	var is_selected: bool = ship.id == selected_id
	if is_selected:
		colour = colour.lerp(ViewPalette.SELECTED, 0.5)

	var apparent_length: float = ship.spec.length_m * _zoom
	if apparent_length < MIN_SILHOUETTE_PIXELS:
		_draw_symbol(ship, colour, is_selected)
	else:
		_draw_silhouette(ship, colour, is_selected)


func _draw_silhouette(ship: ShipEntity, colour: Color, is_selected: bool) -> void:
	var outline: PackedVector2Array = ship.hull().outline_world(ship.position, ship.heading)
	var fill: Color = colour
	fill.a = ViewPalette.HULL_FILL_ALPHA
	draw_colored_polygon(outline, fill)

	# Line widths are divided by zoom so they stay a constant thickness on screen at
	# every scale — a hairline outline that vanishes when zoomed out is useless on a
	# tactical plot.
	var width: float = (2.0 if is_selected else 1.0) / _zoom
	draw_polyline(_close(outline), colour, width, true)

	if show_headings:
		_draw_heading_vector(ship, colour)


func _draw_symbol(ship: ShipEntity, colour: Color, is_selected: bool) -> void:
	# A chevron pointing along the ship's heading: readable at two pixels, and still
	# tells the player which way she is going.
	var size: float = SYMBOL_PIXELS / _zoom
	var forward: Vector2 = Vector2(cos(ship.heading), sin(ship.heading))
	var side: Vector2 = Vector2(-forward.y, forward.x)
	var points: PackedVector2Array = PackedVector2Array([
		ship.position + forward * size,
		ship.position - forward * size * 0.5 + side * size * 0.55,
		ship.position - forward * size * 0.15,
		ship.position - forward * size * 0.5 - side * size * 0.55,
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
	var forward: Vector2 = Vector2(cos(ship.heading), sin(ship.heading))
	var tip: Vector2 = ship.position + forward * ship.speed * 60.0
	var faded: Color = colour
	faded.a = 0.45
	draw_line(ship.position + forward * ship.spec.length_m * 0.5, tip, faded, 1.0 / _zoom, true)


static func _close(points: PackedVector2Array) -> PackedVector2Array:
	var closed: PackedVector2Array = points.duplicate()
	if not closed.is_empty():
		closed.append(closed[0])
	return closed
