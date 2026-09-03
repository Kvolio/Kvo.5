extends Node2D

## Root of the battle screen. Owns the simulation and everything that draws it.
##
## The boundary this class enforces is the important part: it calls `world.step()` a
## whole number of fixed ticks per frame and then READS the result to draw it. It
## never integrates anything itself and never nudges an entity directly — player
## intent becomes a SimCommand, which is what keeps a battle reproducible from its
## seed and command log alone.

## Raised when the player asks to leave the battle. AppRoot listens; the battle itself
## does not know what is above it.
signal exit_requested()

const SPEED_ORDER_STEP_KN: float = 2.0

## The action fought when nobody has chosen one.
const DEFAULT_SCENARIO: String = "carrier_action"

const SAVE_DIR: String = "user://saves"
const SAVE_PATH: String = "user://saves/battle.json"
const CLICK_PIXEL_RADIUS: float = 24.0

var world: SimWorld = null

var _camera: Camera2D = null
var _ocean: ColorRect = null
var _grid: Node2D = null
var _ships: Node2D = null
var _effects: Node2D = null
var _air: Node2D = null
var _labels: Control = null
var _hud: Control = null
var _selected_id: int = 0
var _time_scale_before_pause: float = 1.0
var _engagements: Array[ShipEntity] = []

# -- inspection surfaces -------------------------------------------------------
## Three ways of looking at the same causal data: what happened in words, what a ship
## looks like inside, and why the last shell did what it did. All three read the
## simulation and none of them writes to it.
var _combat_log: Control = null
var _inspector: Control = null
var _debug: Control = null

## The battle being fought, and the recording of it. A replay is the scenario, the
## seed and the orders — see docs/REPLAY.md.
var _scenario: ScenarioDef = null
var _recorder: ReplayRecorder = null
var _base_config: Dictionary = {}

## A design sent straight from the ship designer. She joins the line as the player's
## flagship, which is what makes the designer worth using: build a ship, take her out,
## and watch the armour scheme you chose meet a shell.
var _player_design: ShipSpec = null


func _ready() -> void:
	_build_scene()
	_start_battle()
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

	# Aircraft, if anything registered a module that has any. Drawn above the effects
	# because they are the only thing on the plot that is not on the water.
	_air = _instantiate("res://src/view/air_renderer.gd") as Node2D
	if _air != null:
		add_child(_air)

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

	# The three inspection surfaces, all hidden until asked for. They are separate
	# scripts rather than tabs of the HUD because they answer different questions and
	# a player usually wants one of them, not all three.
	_combat_log = _instantiate("res://src/ui/combat_log.gd") as Control
	if _combat_log != null:
		_combat_log.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT,
			Control.PRESET_MODE_MINSIZE, 12)
		_combat_log.visible = false
		hud_layer.add_child(_combat_log)

	_inspector = _instantiate("res://src/ui/ship_inspector.gd") as Control
	if _inspector != null:
		_inspector.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT,
			Control.PRESET_MODE_MINSIZE, 12)
		_inspector.visible = false
		hud_layer.add_child(_inspector)

	_debug = _instantiate("res://src/ui/debug_overlay.gd") as Control
	if _debug != null:
		_debug.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT,
			Control.PRESET_MODE_MINSIZE, 12)
		_debug.visible = false
		hud_layer.add_child(_debug)



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


## Set up the battle a scenario describes.
##
## Everything goes through `ScenarioIo.build()`, and deliberately nothing else does: a
## replay works by building the same world from the same file and the same seed, so a
## battle set up by any other route would be one no replay could reproduce.
func _start_battle() -> void:
	_base_config = {
		"sim": GameConfig.get_dict("sim"),
		"physics": GameConfig.get_dict("physics"),
		"ballistics": GameConfig.get_dict("ballistics"),
		"structure": GameConfig.get_dict("structure"),
		"damage": GameConfig.get_dict("damage"),
		"torpedo": GameConfig.get_dict("torpedo"),
		"fire_control": GameConfig.get_dict("fire_control"),
		"detection": GameConfig.get_dict("detection"),
		"ai": GameConfig.get_dict("ai"),
	}
	if _scenario == null:
		_scenario = ScenarioIo.load_from_file(
			"res://data/scenarios/%s.json" % DEFAULT_SCENARIO)
	if _scenario == null:
		push_error("BattleView: no scenario to fight")
		return

	world = ScenarioIo.build(_scenario, _base_config, WeaponDatabase.armory(),
		func(spec_id: String) -> ShipSpec: return ShipDatabase.get_spec(spec_id))

	# Carrier aviation is a module the game registers, not a part of the simulation.
	# Comment this line out and the battle still runs — the carriers simply have nobody
	# to tell that their flight decks work. See docs/AIR_MODULE.md.
	AirModule.register(world, GameConfig.get_dict("air"))

	# The player's own design joins the first force, and is hers to steer rather than
	# the AI's — which is the whole point of having built her.
	if _player_design != null and not _scenario.forces.is_empty():
		var force: ScenarioDef.Force = _scenario.forces[0]
		var own: ShipEntity = world.add_ship(_player_design.duplicate_spec(),
			force.position + Vector2(0.0, -3000.0).rotated(force.heading_rad),
			force.heading_rad, force.team)
		MovementSystem.order_speed(own, SimUnits.knots_to_ms(force.speed_knots))
		_selected_id = own.id

	for ship: ShipEntity in world.ships:
		_engagements.append(ship)

	# Recording starts with the battle, because a replay that had to be asked for is
	# one nobody has when they want it.
	_recorder = ReplayRecorder.start(world, _scenario.scenario_id, _base_config)

	_ships.world = world
	_effects.world = world
	if _air != null:
		_air.world = world
	_labels.world = world
	_hud.world = world
	if _combat_log != null:
		_combat_log.world = world
	if _inspector != null:
		_inspector.world = world
	if _debug != null:
		_debug.world = world
	(_grid as Object).set("map_size", world.map_size)


## Fight a particular action. Called by the menu before the view is added to the tree.
func set_scenario(scenario: ScenarioDef) -> void:
	_scenario = scenario


## Take a design straight from the designer, without it having to be saved first.
func set_player_design(spec: ShipSpec) -> void:
	_player_design = spec


func _process(delta: float) -> void:
	if world == null:
		return
	# A whole number of fixed ticks. The frame delta decides HOW MANY, never how big.
	var ticks: int = world.clock.advance(delta)
	for _i: int in ticks:
		world.step()
		# The recorder watches every tick rather than every frame, so a battle run at
		# ten times speed records the same thing as one run at normal speed.
		if _recorder != null:
			_recorder.observe(world)
	# Effects age in SIMULATED time, so a splash lasts the same number of simulated
	# seconds at 1x and at 10x instead of littering the sea at high speed.
	(_effects as Object).call("advance", float(ticks) * world.clock.dt)
	_sync_view()


## Toggle one of the inspection surfaces.
func _toggle_panel(panel: Control) -> void:
	if panel == null:
		return
	panel.visible = not panel.visible
	if panel.visible and panel == _inspector:
		panel.call("show_ship", _selected_id)


## Save the battle as it stands, and put it back.
##
## The same snapshot the replay system takes for a rewind — one serializer, because a
## save that used a different one would eventually disagree with it about what a battle
## is. Reloading rebuilds the world from the scenario and restores the state into it,
## which is exactly what `Snapshot.restore` requires and why the scenario id is written
## into the save.
func _save_battle() -> void:
	if world == null or _scenario == null:
		return
	var data: Dictionary = Snapshot.capture(world)
	data["scenario"] = _scenario.scenario_id
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("BattleView: could not write %s" % SAVE_PATH)
		return
	file.store_string(Serializer.to_json(data))
	file.close()
	print("Battle saved to %s" % SAVE_PATH)


func _load_battle() -> void:
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return
	var data: Dictionary = parsed as Dictionary
	var saved: ScenarioDef = ScenarioIo.load_from_file(
		"res://data/scenarios/%s.json" % str(data.get("scenario", DEFAULT_SCENARIO)))
	if saved == null:
		return
	# A fresh world from the same scenario, then the state put back into it. The
	# snapshot carries condition and position, not designs — a save that duplicated the
	# ships would eventually disagree with the files they came from.
	_scenario = saved
	_engagements.clear()
	_start_battle()
	Snapshot.restore(world, data)
	print("Battle restored from %s" % SAVE_PATH)


func _refresh_panels() -> void:
	if _combat_log != null and _combat_log.visible:
		_combat_log.call("refresh")
	if _inspector != null and _inspector.visible:
		_inspector.call("show_ship", _selected_id)
	if _debug != null and _debug.visible:
		_debug.call("refresh")


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
	if _air != null:
		(_air as Object).call("set_zoom", zoom)
		_air.queue_redraw()

	# The canvas transform is the exact mapping the world layer was drawn with, so
	# screen-space labels stay locked to their hulls at every zoom.
	(_labels as Object).set("selected_id", _selected_id)
	(_labels as Object).call("sync_view", get_viewport().get_canvas_transform(), zoom)

	(_hud as Object).set("selected_id", _selected_id)
	(_hud as Object).call("refresh")
	_refresh_panels()


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
		KEY_L:
			_toggle_panel(_combat_log)
		KEY_I:
			_toggle_panel(_inspector)
		KEY_G:
			_toggle_panel(_debug)
		KEY_F5:
			_save_battle()
		KEY_F9:
			_load_battle()
		KEY_ESCAPE:
			exit_requested.emit()


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
