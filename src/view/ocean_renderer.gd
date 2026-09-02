extends ColorRect

## The sea.
##
## A full-screen rect carrying the ocean shader, sitting on a CanvasLayer below
## everything else. Because the water is computed per visible pixel from the camera
## transform rather than drawn as world geometry, its cost is fixed: a 200 km map
## renders exactly as cheaply as a 5 km one.

## NOTE on sizing: `set_anchors_and_offsets_preset` is required, not just
## `set_anchors_preset`. The latter leaves the offsets alone, and a Control under a
## CanvasLayer with unresolved offsets stays zero-sized — visible, laid out, and
## drawing nothing. Assigning `size` directly does not help either: Godot overrides
## it from the anchors after _ready() and warns about it.

const SHADER_PATH: String = "res://src/view/shaders/ocean.gdshader"

var sea_state: float = 3.0:
	set(value):
		sea_state = clampf(value, 0.0, 9.0)
		_push_uniform(&"sea_state", sea_state)

var wind_direction: Vector2 = Vector2.RIGHT:
	set(value):
		wind_direction = value.normalized() if value.length_squared() > 0.0 else Vector2.RIGHT
		_push_uniform(&"wind_direction", wind_direction)

var _material: ShaderMaterial = null
var _elapsed: float = 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_material = ShaderMaterial.new()
	_material.shader = load(SHADER_PATH)
	material = _material
	color = ViewPalette.SEA_DEEP

	_push_uniform(&"deep_colour", ViewPalette.SEA_DEEP)
	_push_uniform(&"shallow_colour", ViewPalette.SEA_SHALLOW)
	_push_uniform(&"crest_colour", ViewPalette.SEA_CREST)
	_push_uniform(&"sea_state", sea_state)
	_push_uniform(&"wind_direction", wind_direction)


## Animated with real frame time, not simulation time.
##
## The sea is scenery: it has no effect on any outcome, so tying it to the
## simulation clock would only mean the water freezes when the battle is paused and
## races when it is run at 10x, both of which look broken.
func _process(delta: float) -> void:
	_elapsed += delta
	_push_uniform(&"time_seconds", _elapsed)


func sync_camera(camera_position: Vector2, zoom: float, viewport: Vector2) -> void:
	_push_uniform(&"camera_position", camera_position)
	_push_uniform(&"camera_zoom", zoom)
	_push_uniform(&"viewport_size", viewport)


func _push_uniform(name: StringName, value: Variant) -> void:
	if _material != null:
		_material.set_shader_parameter(name, value)
