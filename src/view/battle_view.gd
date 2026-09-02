extends Node2D

## Root of the battle screen. Owns the simulation and everything that draws it.
##
## The boundary this class enforces is the important part: it calls `world.step()` a
## whole number of fixed ticks per frame and then READS the result to draw it. It
## never integrates anything itself and never nudges an entity directly — player
## intent becomes a SimCommand, which is what keeps a battle reproducible from its
## seed and command log alone.

const SPEED_ORDER_STEP_KN: float = 2.0
const CLICK_PIXEL_RADIUS: float = 24.0

var world: SimWorld = null

var _camera: Camera2D = null
var _ocean: ColorRect = null
var _grid: Node2D = null
var _ships: Node2D = null
var _effects: Node2D = null
var _labels: Control = null
var _hud: Control = null
var _selected_id: int = 0
var _time_scale_before_pause: float = 1.0
var _engagements: Array[ShipEntity] = []


func _ready() -> void:
	_build_scene()
	_start_demo_battle()
	_camera.frame_points(_ship_positions())


func _build_scene() -> void:
	# The sea sits on its own CanvasLayer below everything, drawn in screen space.
	var sea_layer: CanvasLayer = CanvasLayer.new()
	sea_layer.layer = -10
	add_child(sea_layer)
	_ocean = _instantiate("res://src/view/ocean_renderer.gd") as ColorRect
	if _ocean != null:
		sea_layer.add_child(_ocean)

	_grid = _instantiate("res://src/view/grid_overlay.gd") as Node2D
	if _grid != null:
		add_child(_grid)

	_ships = _instantiate("res://src/view/ship_renderer.gd") as Node2D
	if _ships != null:
		add_child(_ships)

	# Above the ships: shells in flight, splashes and hit flashes.
	_effects = _instantiate("res://src/view/effects_renderer.gd") as Node2D
	if _effects != null:
		add_child(_effects)

	_camera = _instantiate("res://src/view/battle_camera.gd") as Camera2D
	if _camera != null:
		_camera.enabled = true
		add_child(_camera)

	# Labels sit above the plot but below the HUD, in screen space.
	var label_layer: CanvasLayer = CanvasLayer.new()
	label_layer.layer = 5
	add_child(label_layer)
	_labels = _instantiate("res://src/view/tactical_labels.gd") as Control
	if _labels != null:
		label_layer.add_child(_labels)

	var hud_layer: CanvasLayer = CanvasLayer.new()
	hud_layer.layer = 10
	add_child(hud_layer)
	_hud = _instantiate("res://src/ui/battle_hud.gd") as Control
	if _hud == null:
		return
	hud_layer.add_child(_hud)
	_hud.time_scale_requested.connect(_on_time_scale_requested)
	_hud.pause_toggled.connect(_toggle_pause)

	# Inert unless --screenshot is on the command line.
	var capture: Node = _instantiate("res://src/view/screenshot_capture.gd") as Node
	if capture != null:
		add_child(capture)


## Instantiate a view script, reporting a compile failure rather than raising a
## runtime error part-way through building the scene.
##
## Calling new() on a script that failed to parse raises an error, and a GDScript
## runtime error aborts the whole enclosing call — so one broken renderer would leave
## the camera, HUD and ship layer silently unbuilt, and the resulting flood of null
## errors buries the one message that says what actually went wrong.
static func _instantiate(path: String) -> Object:
	var script: Variant = load(path)
	if not (script is GDScript) or not (script as GDScript).can_instantiate():
		push_error("BattleView: could not instantiate %s — see the parse errors above" % path)
		return null
	return (script as GDScript).new()


## A stand-in engagement so the battlefield has something on it.
##
## Ships come from ShipDatabase, the same path the scenario system will use in Stage
## 8, so this is a placeholder scenario rather than a placeholder pipeline.
func _start_demo_battle() -> void:
	world = SimWorld.create(20260902, {
		"sim": GameConfig.get_dict("sim"),
		"physics": GameConfig.get_dict("physics"),
		"ballistics": GameConfig.get_dict("ballistics"),
	})
	world.set_armory(WeaponDatabase.armory())

	# Two lines passing on opposite courses about 9 km apart — the classic gun action
	# geometry, and the one that actually shows the guns doing something, since both
	# sides can bring a full broadside to bear.
	var line_up: Array[String] = ["uss_iowa", "uss_fletcher"]
	for team: int in 2:
		var facing: float = 0.0 if team == 0 else PI
		var x: float = -11000.0 if team == 0 else 11000.0
		var y_offset: float = -4500.0 if team == 0 else 4500.0
		for i: int in line_up.size():
			var spec: ShipSpec = ShipDatabase.get_spec(line_up[i])
			if spec == null:
				continue
			if team == 1:
				spec.display_name = "%s (Red)" % spec.display_name
			# Ships in each line follow one another, spaced astern.
			var along: float = float(i) * (-1400.0 if team == 0 else 1400.0)
			var ship: ShipEntity = world.add_ship(
				spec, Vector2(x + along, y_offset), facing, team)
			MovementSystem.order_speed(ship, SimUnits.knots_to_ms(24.0))
			_engagements.append(ship)

	# Each side engages its opposite number. Stage 7 replaces this with target
	# selection by the AI; the mechanism is the same either way.
	var half: int = _engagements.size() / 2
	for i: int in half:
		_engagements[i].target_id = _engagements[i + half].id
		_engagements[i + half].target_id = _engagements[i].id

	_ships.world = world
	_effects.world = world
	_labels.world = world
	_hud.world = world
	(_grid as Object).set("map_size", world.map_size)


func _process(delta: float) -> void:
	if world == null:
		return
	# A whole number of fixed ticks. The frame delta decides HOW MANY, never how big.
	var ticks: int = world.clock.advance(delta)
	world.step_many(ticks)
	# Effects age in SIMULATED time, so a splash lasts the same number of simulated
	# seconds at 1x and at 10x instead of littering the sea at high speed.
	(_effects as Object).call("advance", float(ticks) * world.clock.dt)
	_sync_view()


func _sync_view() -> void:
	var zoom: float = _camera.zoom.x
	var viewport: Vector2 = get_viewport_rect().size
	(_ocean as Object).call("sync_camera", _camera.global_position, zoom, viewport)

	var visible_span: Vector2 = viewport / maxf(zoom, 0.00001)
	var view_rect: Rect2 = Rect2(_camera.global_position - visible_span * 0.5, visible_span)
	(_grid as Object).call("sync_view", view_rect, zoom)

	(_ships as Object).set("selected_id", _selected_id)
	(_ships as Object).call("set_zoom", zoom)
	_ships.queue_redraw()
	(_effects as Object).call("set_zoom", zoom)

	# The canvas transform is the exact mapping the world layer was drawn with, so
	# screen-space labels stay locked to their hulls at every zoom.
	(_labels as Object).set("selected_id", _selected_id)
	(_labels as Object).call("sync_view", get_viewport().get_canvas_transform(), zoom)

	(_hud as Object).set("selected_id", _selected_id)
	(_hud as Object).call("refresh")


# -------------------------------------------------------------------- input --

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_select_at(get_global_mouse_position(), _camera.zoom.x)
		return

	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	var key: InputEventKey = event as InputEventKey
	if key.echo:
		return

	match key.keycode:
		KEY_SPACE:
			_toggle_pause()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
			var index: int = key.keycode - KEY_1
			if index < BattleHudScales.size():
				_on_time_scale_requested(BattleHudScales[index])
		KEY_F:
			_camera.frame_points(_ship_positions())
		KEY_W:
			_nudge_speed(SPEED_ORDER_STEP_KN)
		KEY_S:
			_nudge_speed(-SPEED_ORDER_STEP_KN)
		KEY_A:
			_nudge_rudder(-0.25)
		KEY_D:
			_nudge_rudder(0.25)
		KEY_X:
			_order_rudder_absolute(0.0)


## Mirrors BattleHud.TIME_SCALES; kept as a constant here so the keyboard shortcuts
## do not depend on the HUD existing.
const BattleHudScales: Array[float] = [0.25, 0.5, 1.0, 2.0, 5.0, 10.0]


func _select_at(world_point: Vector2, zoom: float) -> void:
	# Pick radius is expressed in screen pixels so clicking feels the same whether a
	# ship is a full silhouette or a two-pixel symbol.
	var reach: float = CLICK_PIXEL_RADIUS / maxf(zoom, 0.00001)
	var candidates: PackedInt32Array = world.spatial.query_radius(
		world_point, reach, SpatialIndex.Layer.SHIP)

	var best_id: int = 0
	var best_distance: float = INF
	for id: int in candidates:
		var ship: ShipEntity = world.get_ship(id)
		if ship == null:
			continue
		# Prefer an actual hull hit; fall back to nearest centre for small targets.
		var distance: float = ship.position.distance_to(world_point)
		if ship.hull().contains_world(world_point, ship.position, ship.heading):
			distance = -1.0
		if distance < best_distance:
			best_distance = distance
			best_id = id
	_selected_id = best_id


func _selected() -> ShipEntity:
	return world.get_ship(_selected_id) if _selected_id != 0 else null


func _nudge_speed(delta_knots: float) -> void:
	var ship: ShipEntity = _selected()
	if ship == null:
		return
	var target: float = ship.speed_knots() + delta_knots
	_submit(SimWorld.CMD_SET_SPEED_KNOTS, {"value": target})


func _nudge_rudder(delta_fraction: float) -> void:
	var ship: ShipEntity = _selected()
	if ship == null:
		return
	var current: float = ship.rudder_order / maxf(ship.spec.max_rudder_rad, 0.0001)
	_order_rudder_absolute(clampf(current + delta_fraction, -1.0, 1.0))


func _order_rudder_absolute(fraction: float) -> void:
	_submit(SimWorld.CMD_SET_RUDDER, {"value": fraction})


## Every player order enters the simulation as a command, timestamped for the tick it
## should take effect on. Nothing reaches an entity by any other route.
func _submit(type: StringName, params: Dictionary) -> void:
	if _selected_id == 0:
		return
	world.commands.submit_new(type, world.clock.tick, _selected_id, params)


func _toggle_pause() -> void:
	if world.clock.is_paused():
		world.clock.time_scale = _time_scale_before_pause
	else:
		_time_scale_before_pause = world.clock.time_scale
		world.clock.time_scale = 0.0


func _on_time_scale_requested(scale: float) -> void:
	world.clock.time_scale = scale
	_time_scale_before_pause = scale


func _ship_positions() -> PackedVector2Array:
	var points: PackedVector2Array = PackedVector2Array()
	for ship: ShipEntity in world.ships:
		points.append(ship.position)
	return points
