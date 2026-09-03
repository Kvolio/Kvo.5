extends Node

## Captures the viewport to a PNG and exits. Development and CI tool.
##
##   godot --path . -- --screenshot=/tmp/shot.png --screenshot-frame=120
##
## Added once at the root so any screen can be captured — the battle, the designer or
## the menu. It runs off the real
## scene, autoloads and all, rather than a synthetic harness, so what lands in the
## file is exactly what a player would see — which is the only way a screenshot is
## worth anything as a check.
##
## Does nothing at all unless --screenshot is passed, so it is free to leave in.

const ARG_PATH: String = "--screenshot="
const ARG_FRAME: String = "--screenshot-frame="
const ARG_ZOOM: String = "--screenshot-zoom="
const ARG_FOCUS: String = "--screenshot-focus="
const DEFAULT_WARMUP_FRAMES: int = 90

var _output_path: String = ""
var _capture_frame: int = DEFAULT_WARMUP_FRAMES
var _zoom: float = 0.0
var _focus_index: int = -1
var _frames: int = 0


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(ARG_PATH):
			_output_path = arg.trim_prefix(ARG_PATH)
		elif arg.begins_with(ARG_FRAME):
			_capture_frame = maxi(int(arg.trim_prefix(ARG_FRAME)), 1)
		elif arg.begins_with(ARG_ZOOM):
			_zoom = maxf(float(arg.trim_prefix(ARG_ZOOM)), 0.0)
		elif arg.begins_with(ARG_FOCUS):
			_focus_index = int(arg.trim_prefix(ARG_FOCUS))
	set_process(not _output_path.is_empty())


## Point the camera somewhere specific before capturing, so a screenshot can show a
## ship close up rather than only ever the whole battlefield.
func _apply_framing() -> void:
	if _zoom <= 0.0 and _focus_index < 0:
		return
	var camera: Camera2D = get_viewport().get_camera_2d()
	if camera == null:
		return
	var world: SimWorld = _find_world()
	if _focus_index >= 0 and world != null and _focus_index < world.ships.size():
		camera.global_position = world.ships[_focus_index].position
	if _zoom > 0.0:
		camera.zoom = Vector2(_zoom, _zoom)


## The simulation belonging to whatever screen is currently up, if it has one. Checked
## on the parent first and then among its children, so this works whether it is a child
## of the battle itself or a sibling of it under the application root.
func _find_world() -> SimWorld:
	var parent: Node = get_parent()
	if parent == null:
		return null
	var found: SimWorld = parent.get("world") as SimWorld
	if found != null:
		return found
	for sibling: Node in parent.get_children():
		found = sibling.get("world") as SimWorld
		if found != null:
			return found
	return null


## A warm-up delay is not optional: the first frames are drawn before shaders have
## finished compiling and before the camera has framed anything, so capturing
## immediately reliably produces a black or half-built image.
func _process(_delta: float) -> void:
	_frames += 1
	if _frames == _capture_frame - 2:
		# Reframe early: the renderers pick the new camera up on their next _process,
		# so the change needs a frame to propagate before it is worth capturing.
		_apply_framing()
		return
	if _frames < _capture_frame:
		return
	set_process(false)

	# During _process the viewport texture still holds the PREVIOUS frame. Waiting
	# for frame_post_draw is what makes the capture show the state the counters say
	# it does, rather than one frame of stale camera and stale overlays.
	await RenderingServer.frame_post_draw

	var image: Image = get_viewport().get_texture().get_image()
	var error: Error = image.save_png(_output_path)
	if error == OK:
		print("Screenshot written to %s (%dx%d)" % [
			_output_path, image.get_width(), image.get_height()])
	else:
		printerr("Screenshot failed: %s" % error_string(error))
	get_tree().quit(0 if error == OK else 1)
