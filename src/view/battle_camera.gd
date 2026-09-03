extends Camera2D

## Tactical camera: drag to pan, wheel to zoom, and a framing helper.
##
## The world is measured in metres and a fleet action can span 40 km, so the zoom
## range has to be enormous — from 0.004 px/m (a whole ocean on screen) to 4 px/m
## (close enough to read a destroyer's turrets). Zoom is stepped multiplicatively so
## each notch feels the same at any scale.

const MIN_ZOOM: float = 0.004
const MAX_ZOOM: float = 4.0
const ZOOM_STEP: float = 1.15
const DEFAULT_ZOOM: float = 0.05

var _dragging: bool = false


func _ready() -> void:
	zoom = Vector2(DEFAULT_ZOOM, DEFAULT_ZOOM)
	position_smoothing_enabled = false


func current_zoom() -> float:
	return zoom.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button: InputEventMouseButton = event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					_zoom_towards(button.position, ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					_zoom_towards(button.position, 1.0 / ZOOM_STEP)
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = button.pressed
	elif event is InputEventMouseMotion and _dragging:
		# Screen-space drag converted to world metres, so the water stays under the
		# cursor at every zoom level.
		global_position -= (event as InputEventMouseMotion).relative / current_zoom()


## Zoom about the cursor rather than the screen centre, so the point under the
## pointer stays put — the behaviour every map interface has trained people to expect.
func _zoom_towards(screen_point: Vector2, factor: float) -> void:
	var before: Vector2 = get_global_mouse_position()
	var new_zoom: float = clampf(current_zoom() * factor, MIN_ZOOM, MAX_ZOOM)
	zoom = Vector2(new_zoom, new_zoom)
	var after: Vector2 = get_global_mouse_position()
	global_position += before - after


## Frame a set of world positions with a margin, clamped to the zoom range.
func frame_points(points: PackedVector2Array, margin_fraction: float = 0.25) -> void:
	if points.is_empty():
		return
	var bounds: Rect2 = Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		bounds = bounds.expand(point)
	global_position = bounds.get_center()

	var viewport: Vector2 = get_viewport_rect().size
	var span: Vector2 = bounds.size * (1.0 + margin_fraction * 2.0)
	var fit: float = minf(
		viewport.x / maxf(span.x, 1.0),
		viewport.y / maxf(span.y, 1.0)
	)
	var clamped: float = clampf(fit, MIN_ZOOM, MAX_ZOOM)
	zoom = Vector2(clamped, clamped)
