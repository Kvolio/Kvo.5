class_name SimWorld
extends RefCounted

## The simulation. Owns every entity and every piece of deterministic state, and
## advances all of it one fixed tick at a time.
##
## Contains no Nodes and never touches the scene tree. Renderers read it; they never
## write to it. External intent — a player order, a scenario script, a test — arrives
## only through `commands`, which is what makes a battle reproducible from
## seed + initial state + command log.
##
## SYSTEM ORDER is fixed and explicit. It is written out in `step()` rather than
## discovered from a registry, because "which system ran first" is exactly the kind
## of detail that silently decides outcomes.

## Command types recognised at world level.
const CMD_SET_THROTTLE: StringName = &"set_throttle"
const CMD_SET_RUDDER: StringName = &"set_rudder"
const CMD_SET_SPEED_KNOTS: StringName = &"set_speed_knots"
const CMD_STEER_HEADING: StringName = &"steer_heading"
const CMD_STEER_POINT: StringName = &"steer_point"
const CMD_SET_TARGET: StringName = &"set_target"
const CMD_SELECT_SHELL: StringName = &"select_shell"

var clock: SimClock = SimClock.new()
var ids: IdAllocator = IdAllocator.new()
var rng: RngStreams = null
var events: SimEventBus = null
var commands: CommandQueue = CommandQueue.new()
var spatial: SpatialIndex = null

## Guns, shells and range tables. Optional: a movement-only test has no reason to
## load one, and ships built without it simply have no mounts.
var armory: Armory = null

var map_size: Vector2 = Vector2(40000.0, 40000.0)

## Ships in ascending ID order. The ordering is load-bearing: every system that
## iterates ships inherits its determinism from this invariant.
var ships: Array[ShipEntity] = []

var _ships_by_id: Dictionary = {}
var _movement: MovementSystem = MovementSystem.new()
var _seed: int = 0


static func create(seed_value: int = 0, config: Dictionary = {}) -> SimWorld:
	var world: SimWorld = SimWorld.new()
	world._seed = seed_value
	world.rng = RngStreams.new(seed_value)

	var sim_config: Dictionary = config.get("sim", {}) as Dictionary
	world.clock.configure(sim_config)
	var events_config: Dictionary = sim_config.get("events", {}) as Dictionary
	world.events = SimEventBus.new(int(events_config.get("historyLimit", SimEventBus.DEFAULT_HISTORY_LIMIT)))

	var world_config: Dictionary = sim_config.get("world", {}) as Dictionary
	world.map_size = Serializer.array_to_vec2(world_config.get("defaultMapSizeM"), world.map_size)

	world.spatial = BruteForceIndex.new()
	world._movement.configure(config.get("physics", {}) as Dictionary)
	return world


## Attach the armoury. Ships added afterwards get their mounts built automatically;
## ships already present are rebuilt, so the order of setup calls does not matter.
func set_armory(p_armory: Armory) -> void:
	armory = p_armory
	for ship: ShipEntity in ships:
		ship.build_turrets(armory)


func get_seed() -> int:
	return _seed


# ------------------------------------------------------------------ entities --

func add_ship(spec: ShipSpec, position: Vector2, heading: float, team: int = 0,
		name_override: String = "") -> ShipEntity:
	var ship: ShipEntity = ShipEntity.create(ids.allocate(), spec, team)
	ship.position = position
	ship.heading = SimUnits.normalise_angle(heading)
	if not name_override.is_empty():
		ship.display_name = name_override

	# Ships are kept in ascending ID order. IDs are allocated monotonically so an
	# append is already sorted; the assert guards against a future caller that
	# inserts a ship with a hand-picked ID.
	assert(ships.is_empty() or ships[ships.size() - 1].id < ship.id,
		"ships must stay sorted by id")
	if armory != null:
		ship.build_turrets(armory)
	ships.append(ship)
	_ships_by_id[ship.id] = ship
	spatial.insert(ship.id, ship.position, ship.hull().bounding_radius(), SpatialIndex.Layer.SHIP)

	events.emit_event(&"ship_spawned", ship.id, 0, SimEvent.Severity.NOTABLE, {
		"name": ship.display_name, "team": team, "type": spec.ship_type,
	})
	return ship


func get_ship(ship_id: int) -> ShipEntity:
	return _ships_by_id.get(ship_id) as ShipEntity


func has_ship(ship_id: int) -> bool:
	return _ships_by_id.has(ship_id)


func remove_ship(ship_id: int) -> bool:
	var ship: ShipEntity = get_ship(ship_id)
	if ship == null:
		return false
	ships.erase(ship)
	_ships_by_id.erase(ship_id)
	spatial.remove(ship_id)
	events.emit_event(&"ship_removed", ship_id, 0, SimEvent.Severity.NOTABLE,
		{"name": ship.display_name})
	return true


## Ships still afloat, in ID order.
func active_ships() -> Array[ShipEntity]:
	var out: Array[ShipEntity] = []
	for ship: ShipEntity in ships:
		if ship.is_afloat():
			out.append(ship)
	return out


func ships_of_team(team: int) -> Array[ShipEntity]:
	var out: Array[ShipEntity] = []
	for ship: ShipEntity in ships:
		if ship.team == team:
			out.append(ship)
	return out


# --------------------------------------------------------------------- step --

## Advance exactly one fixed tick.
## Advance exactly one fixed tick.
##
## The order below is the simulation's contract and is written out here rather than
## discovered from a registry, because "which system ran first" is exactly the kind of
## detail that silently decides outcomes.
##
##   1. commands      external intent enters, and only here
##   2. movement      ships take up their new positions
##   3. fire control  gunnery solves against those new positions, not last tick's
##   4. mounts        turrets train, elevate and load towards their orders
##   5. spatial       the index is brought up to date for next tick's queries
func step() -> void:
	events.begin_tick(clock.tick)
	_apply_commands()
	_movement.step(ships, clock.dt)
	_direct_gunnery()
	_step_turrets()
	_sync_spatial()
	clock.consume_tick()


func _direct_gunnery() -> void:
	if armory == null:
		return
	for ship: ShipEntity in ships:
		if not ship.is_afloat() or ship.turrets.is_empty():
			continue
		var target: ShipEntity = get_ship(ship.target_id) if ship.target_id != 0 else null
		FireControlSystem.direct_battery(ship, ship.turrets, target, armory)


func _step_turrets() -> void:
	for ship: ShipEntity in ships:
		if not ship.turrets.is_empty():
			FireControlSystem.step_turrets(ship.turrets, clock.dt)


## Run `count` ticks. The renderer calls this with whatever SimClock.advance() asked
## for; tests call it directly.
func step_many(count: int) -> void:
	for _i: int in count:
		step()


func _apply_commands() -> void:
	for command: SimCommand in commands.take_due(clock.tick):
		_apply_command(command)


func _apply_command(command: SimCommand) -> void:
	var ship: ShipEntity = get_ship(command.entity_id)
	if ship == null:
		return
	var params: Dictionary = command.params
	match command.type:
		CMD_SET_THROTTLE:
			ship.throttle = clampf(float(params.get("value", 0.0)), -1.0, 1.0)
		CMD_SET_RUDDER:
			MovementSystem.order_rudder(ship, float(params.get("value", 0.0)))
		CMD_SET_SPEED_KNOTS:
			MovementSystem.order_speed(ship, SimUnits.knots_to_ms(float(params.get("value", 0.0))))
		CMD_STEER_HEADING:
			MovementSystem.steer_to_heading(ship, float(params.get("value", 0.0)))
		CMD_STEER_POINT:
			MovementSystem.steer_to_point(ship, Serializer.array_to_vec2(params.get("value")))
		CMD_SET_TARGET:
			ship.target_id = int(params.get("value", 0))
		CMD_SELECT_SHELL:
			_select_shell(ship, str(params.get("battery", "main")), str(params.get("value", "")))
		_:
			push_warning("SimWorld: unhandled command type '%s'" % command.type)


## Change what a battery is loading. Refused rather than silently ignored if the gun
## cannot fire that shell, since an order that quietly does nothing is worse than one
## that reports why.
func _select_shell(ship: ShipEntity, battery: String, shell_id: String) -> void:
	for turret: Turret in ship.turrets:
		if String(turret.battery) != battery:
			continue
		if not turret.gun.ammunition.has(shell_id):
			push_warning("SimWorld: %s cannot fire '%s'" % [turret.gun.display_name, shell_id])
			return
		turret.selected_shell = shell_id


func _sync_spatial() -> void:
	for ship: ShipEntity in ships:
		spatial.update(ship.id, ship.position, ship.hull().bounding_radius())


# ---------------------------------------------------------------- inspection --

## Checksum of everything that affects future evolution.
##
## Two runs that should be identical are compared tick by tick; the first mismatch
## localises the divergence. See docs/DETERMINISM.md.
func checksum() -> int:
	var hasher: StateHasher = StateHasher.new()
	hasher.write_int(clock.tick)
	hasher.write_int(ids.peek_next())
	for ship: ShipEntity in ships:
		ship.hash_into(hasher)
	return hasher.value()


func serialize() -> Dictionary:
	var ship_data: Array = []
	for ship: ShipEntity in ships:
		ship_data.append(ship.serialize())
	return {
		"seed": _seed,
		"clock": clock.serialize(),
		"ids": ids.serialize(),
		"rng": rng.serialize(),
		"mapSize": Serializer.vec2_to_array(map_size),
		"ships": ship_data,
	}
