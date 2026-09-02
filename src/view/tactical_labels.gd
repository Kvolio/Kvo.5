extends Control

## Ship labels, drawn in screen space over the plot.
##
## Deliberately NOT drawn inside the world-space ship layer. Text there has to be
## scaled by 1/zoom to keep a constant apparent size, and since font sizes are
## integers that quantises badly when zoomed in and asks the font renderer for
## 2000-point glyphs when zoomed out. Projecting the ship's position to the screen
## and drawing at a fixed point size instead keeps labels crisp and cheap at every
## scale, from a whole ocean down to a single destroyer.

const NAME_FONT_SIZE: int = 12
const DETAIL_FONT_SIZE: int = 10
const LINE_HEIGHT: float = 13.0
const LEADER_LENGTH: float = 14.0

## Below this apparent hull length the ship is a symbol, so the label is offset from
## a fixed radius instead of from the hull.
const SYMBOL_OFFSET_PIXELS: float = 11.0

var world: SimWorld = null
var selected_id: int = 0
var show_labels: bool = true

var _font: Font = null
var _canvas_transform: Transform2D = Transform2D()
var _zoom: float = 1.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


## The canvas transform is the exact world-to-screen mapping the renderer used, so
## labels cannot drift out of register with the hulls they belong to.
func sync_view(canvas_transform: Transform2D, zoom: float) -> void:
	_canvas_transform = canvas_transform
	_zoom = zoom
	queue_redraw()


func _draw() -> void:
	if world == null or _font == null or not show_labels:
		return
	var bounds: Rect2 = Rect2(Vector2(-120.0, -40.0), size + Vector2(240.0, 80.0))

	for ship: ShipEntity in world.ships:
		var screen_position: Vector2 = _canvas_transform * ship.position
		if not bounds.has_point(screen_position):
			continue  # off screen: no work, no overdraw
		_draw_label(ship, screen_position)


func _draw_label(ship: ShipEntity, anchor: Vector2) -> void:
	var colour: Color = ViewPalette.ship_colour(ship.team, ship.status)
	if ship.id == selected_id:
		colour = colour.lerp(ViewPalette.SELECTED, 0.5)

	# Offset clear of the hull, whether it is drawn as a silhouette or a symbol, and
	# lifted above the heading vector so the two never overlap.
	var half_length: float = maxf(ship.spec.length_m * 0.5 * _zoom, SYMBOL_OFFSET_PIXELS)
	var origin: Vector2 = anchor + Vector2(half_length + LEADER_LENGTH, -LINE_HEIGHT * 1.6)

	draw_line(anchor, origin + Vector2(-5.0, 3.0), Color(colour, 0.35), 1.0, true)

	var name_text: String = ship.display_name
	match ship.status:
		ShipEntity.Status.DESTROYED:
			name_text += "  SUNK"
		ShipEntity.Status.MISSION_KILL:
			name_text += "  OUT OF ACTION"
		_:
			pass
	draw_string(_font, origin, name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE, colour)

	var detail: String = "%.0f kn   %03.0f" % [absf(ship.speed_knots()), ship.compass_bearing()]
	draw_string(_font, origin + Vector2(0.0, LINE_HEIGHT), detail,
		HORIZONTAL_ALIGNMENT_LEFT, -1, DETAIL_FONT_SIZE, ViewPalette.TEXT_DIM)
