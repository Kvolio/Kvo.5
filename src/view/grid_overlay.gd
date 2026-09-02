extends Node2D

## Distance grid and map boundary.
##
## Naval gunnery is about range, and a plot with no scale on it tells you nothing. The
## grid spacing steps through 1 / 2 / 5 km (and up) so that lines stay roughly 80-200
## pixels apart at any zoom: close enough to judge distance by eye, far enough apart
## not to become a smear.

const TARGET_PIXEL_SPACING: float = 130.0
const SPACING_STEPS: Array[float] = [
	500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0, 50000.0, 100000.0,
]
const MAJOR_EVERY: int = 5

var map_size: Vector2 = Vector2(40000.0, 40000.0)
var show_grid: bool = true

var _zoom: float = 1.0
var _view_rect: Rect2 = Rect2()
var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font


func sync_view(view_rect: Rect2, zoom: float) -> void:
	_view_rect = view_rect
	_zoom = zoom
	queue_redraw()


## Grid spacing that lands nearest the target on-screen separation.
func _choose_spacing() -> float:
	for spacing: float in SPACING_STEPS:
		if spacing * _zoom >= TARGET_PIXEL_SPACING:
			return spacing
	return SPACING_STEPS[SPACING_STEPS.size() - 1]


func _draw() -> void:
	if not show_grid or _zoom <= 0.0:
		return
	var spacing: float = _choose_spacing()
	var width: float = 1.0 / _zoom

	# Only the visible span is drawn, so the cost does not grow with map size.
	var first_x: int = int(floor(_view_rect.position.x / spacing))
	var last_x: int = int(ceil(_view_rect.end.x / spacing))
	var first_y: int = int(floor(_view_rect.position.y / spacing))
	var last_y: int = int(ceil(_view_rect.end.y / spacing))

	for i: int in range(first_x, last_x + 1):
		var x: float = float(i) * spacing
		var colour: Color = ViewPalette.GRID_MAJOR if i % MAJOR_EVERY == 0 else ViewPalette.GRID
		draw_line(Vector2(x, _view_rect.position.y), Vector2(x, _view_rect.end.y), colour, width)

	for i: int in range(first_y, last_y + 1):
		var y: float = float(i) * spacing
		var colour: Color = ViewPalette.GRID_MAJOR if i % MAJOR_EVERY == 0 else ViewPalette.GRID
		draw_line(Vector2(_view_rect.position.x, y), Vector2(_view_rect.end.x, y), colour, width)

	_draw_scale_label(spacing)
	_draw_map_bounds(width)


func _draw_scale_label(spacing: float) -> void:
	if _font == null:
		return
	var text: String = "%.0f m grid" % spacing
	if spacing >= 1000.0:
		text = "%.0f km grid" % (spacing / 1000.0)
	var scale: float = 1.0 / _zoom
	draw_string(_font, _view_rect.position + Vector2(12.0, 24.0) * scale, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, int(maxf(11.0 * scale, 1.0)), ViewPalette.TEXT_DIM)


## The edge of the battlefield, so it is obvious where the world stops.
func _draw_map_bounds(width: float) -> void:
	var half: Vector2 = map_size * 0.5
	var bounds: PackedVector2Array = PackedVector2Array([
		Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
		Vector2(half.x, half.y), Vector2(-half.x, half.y),
		Vector2(-half.x, -half.y),
	])
	draw_polyline(bounds, ViewPalette.MAP_EDGE, width * 2.0, true)
