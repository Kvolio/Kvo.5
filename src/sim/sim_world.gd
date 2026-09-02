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

## Armour materials and the configured penetration model. Held here rather than
## reached for globally, so a battle carries everything it needs to be reproduced.
var materials: ArmourMaterials = null
var penetration_model: PenetrationModel = null

## Shells in the air.
var projectiles: Array[Projectile] = []

## Hits resolved recently, newest last. The debug overlay and the combat log read
## these; Stage 4's damage resolver writes their consequences back into them.
var recent_hits: Array[HitReport] = []

var _structure_config: Dictionary = {}
var _damage_config: Dictionary = {}
var _damage_interval: int = 30
var _structures: Dictionary = {}
var _projectile_pool: Array[Projectile] = []
var _hit_history_limit: int = 128

var map_size: Vector2 = Vector2(40000.0, 40000.0)

## Ships in ascending ID order. The ordering is load-bearing: every system that
## iterates ships inherits its determinism from this invariant.
var ships: Array[ShipEntity] = []

var _ships_by_id: Dictionary = {}
var _movement: MovementSystem = MovementSystem.new()
var _ready_to_fire: Dictionary = {}
var _fire_control_interval: int = 6
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
	world._structure_config = config.get("structure", {}) as Dictionary
	world._damage_config = config.get("damage", {}) as Dictionary
	ShipStructureState.ComponentState.configure(world._damage_config)
	var lod: Dictionary = sim_config.get("lod", {}) as Dictionary
	world._fire_control_interval = maxi(int(lod.get("fireControlIntervalTicks", 6)), 1)
	world._damage_interval = maxi(int(lod.get("damageControlTickInterval", 30)), 1)
	world.materials = ArmourMaterials.load_from("res://data/materials/armor.json")
	world.penetration_model = PenetrationModelRegistry.create(
		config.get("ballistics", {}) as Dictionary)
	return world


## Internal geometry for a ship's design, built once per design and shared.
##
## Shared because it is immutable: a twelve-destroyer squadron traces against one copy
## of the same geometry rather than twelve. Stage 4 adds the per-ship mutable state —
## plate deformation, flooding, wrecked machinery — alongside it.
func structure_for(ship: ShipEntity) -> ShipStructureTemplate:
	var cached: Variant = _structures.get(ship.spec.spec_id)
	if cached != null:
		return cached as ShipStructureTemplate
	var built: ShipStructureTemplate = ShipStructureBuilder.build(ship.spec, _structure_config)
	_structures[ship.spec.spec_id] = built
	return built


# ------------------------------------------------------------- projectiles --

## Take a projectile from the pool, or make one if the pool is empty.
func spawn_projectile(shell: ShellDef, gun: GunDef, origin: Vector3, velocity: Vector3,
		shooter_id: int, target_id: int, team: int) -> Projectile:
	var projectile: Projectile = (_projectile_pool.pop_back() as Projectile
		if not _projectile_pool.is_empty() else Projectile.new())
	projectile.reset(ids.allocate(), shell, shell.penetration_k, origin, velocity,
		shooter_id, target_id, team, gun.gun_id)
	projectiles.append(projectile)
	return projectile


func retire_projectile(projectile: Projectile) -> void:
	projectile.active = false
	projectile.shell = null
	_projectile_pool.append(projectile)


## Record a resolved hit and work out what it broke.
##
## The report is not a summary written after the fact — resolving it IS how the damage
## happens, and the DamageReport it produces is hung off the same object so the whole
## causal chain stays in one place.
func record_hit(report: HitReport, target: ShipEntity) -> void:
	if target.structure_state != null:
		DamageResolver.resolve(report, target, structure_for(target),
			target.structure_state, _damage_config, rng.stream(DamageResolver.RNG_STREAM))
		_reassess(target)
	recent_hits.append(report)
	if recent_hits.size() > _hit_history_limit:
		recent_hits = recent_hits.slice(recent_hits.size() - _hit_history_limit)

	var severity: SimEvent.Severity = SimEvent.Severity.INFO
	if report.detonated:
		severity = SimEvent.Severity.NOTABLE
	if report.damage != null and report.damage.catastrophic:
		severity = SimEvent.Severity.CRITICAL
	events.emit_event(&"shell_hit", report.shooter_id, target.id, severity, {
		"shell": report.shell_name,
		"rangeM": report.range_m,
		"termination": HitReport.termination_to_string(report.termination),
		"penetrated": report.penetrated_armour(),
		"detonated": report.detonated,
		"aboveWater": report.hit_above_water,
		"integrityDelta": report.damage.integrity_delta() if report.damage != null else 0.0,
		"casualties": report.damage.crew_casualties if report.damage != null else 0,
	})


## Flooding, fire, and the reassessment that follows from them.
##
## Run at a lower rate than the tick, staggered by ship id, with the elapsed time
## passed in — a flooding rate integrated over half a second is as accurate as one
## integrated over a sixtieth, and costs a thirtieth as much.
func _step_damage() -> void:
	if _damage_config.is_empty():
		return
	var interval_dt: float = clock.dt * float(_damage_interval)
	for ship: ShipEntity in ships:
		if ship.structure_state == null or ship.status == ShipEntity.Status.DESTROYED:
			continue
		if (clock.tick + ship.id) % _damage_interval != 0:
			continue
		var template: ShipStructureTemplate = structure_for(ship)
		FloodingSystem.step(ship, template, ship.structure_state, _damage_config,
			interval_dt, rng.stream(FloodingSystem.RNG_STREAM))
		FireSystem.step(ship, template, ship.structure_state, _damage_config,
			interval_dt, rng.stream(FireSystem.RNG_STREAM))
		_reassess(ship)


## Recompute a ship's condition and let it take effect.
func _reassess(ship: ShipEntity) -> void:
	var template: ShipStructureTemplate = structure_for(ship)
	var previous: ShipEntity.Status = ship.status
	# Component effects first: the assessment reads the ship's propulsion, steering
	# and turret state, so pushing the damage through afterwards would leave it a tick
	# behind — and a ship whose steering gear had just been wrecked would be reported
	# as still able to steer.
	SurvivabilityEvaluator.apply_component_effects(ship, template, ship.structure_state)
	ship.condition = SurvivabilityEvaluator.assess(ship, template, ship.structure_state,
		_damage_config)

	ship.list_angle = deg_to_rad(ship.condition.list_deg)
	ship.trim_angle = deg_to_rad(ship.condition.trim_deg)
	ship.status = ship.condition.status
	ship.loss_reason = ship.condition.reason

	if ship.status != previous:
		var severity: SimEvent.Severity = (SimEvent.Severity.CRITICAL
			if ship.status == ShipEntity.Status.DESTROYED else SimEvent.Severity.NOTABLE)
		events.emit_event(&"ship_status_changed", ship.id, 0, severity, {
			"name": ship.display_name,
			"status": ["active", "missionKill", "destroyed"][int(ship.status)],
			"reason": ship.condition.reason,
			"integrity": ship.condition.integrity,
		})
		if ship.status == ShipEntity.Status.DESTROYED:
			# A wreck stops steaming and stops shooting, but stays on the plot.
			ship.throttle = 0.0
			ship.target_id = 0


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
	# Her own damage state, built from the shared geometry of her design.
	var template: ShipStructureTemplate = structure_for(ship)
	ship.structure_state = ShipStructureState.create(template, spec, _structure_config)
	ship.condition = SurvivabilityEvaluator.assess(ship, template, ship.structure_state,
		_damage_config)
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
##   5. gunnery       mounts that are laid, loaded and bearing put shells in the air
##   6. projectiles   shells fly, and the ones that arrive are resolved against armour
##   7. damage        flooding spreads, fires burn, and each ship's condition is
##                    reassessed from what is actually wrong with her
##   8. spatial       the index is brought up to date for next tick's queries
func step() -> void:
	events.begin_tick(clock.tick)
	_apply_commands()
	_movement.step(ships, clock.dt)
	_direct_gunnery()
	_step_turrets()
	_fire_guns()
	if armory != null:
		ProjectileSystem.step(self, clock.dt)
	_step_damage()
	_sync_spatial()
	clock.consume_tick()


## Solve gunnery for the ships due an update this tick.
##
## A main battery turret trains at a few degrees a second, so re-solving the intercept
## every tick moves the ordered bearing by under a tenth of a degree between updates —
## all cost, no effect. Ships are staggered by id so the work spreads evenly across
## ticks rather than every ship solving on the same one.
##
## Turrets still TRAIN every tick; only the solution they are training towards is
## refreshed less often.
func _direct_gunnery() -> void:
	if armory == null:
		return
	_ready_to_fire.clear()
	for ship: ShipEntity in ships:
		if not ship.is_afloat() or ship.turrets.is_empty():
			continue
		if (clock.tick + ship.id) % _fire_control_interval != 0:
			continue
		var target: ShipEntity = get_ship(ship.target_id) if ship.target_id != 0 else null
		var ready: Array[FireControlSystem.ReadyMount] = FireControlSystem.direct_battery(
			ship, ship.turrets, target, armory)
		if not ready.is_empty():
			_ready_to_fire[ship.id] = ready


## Ships fire in ascending id order, and each mount in the order its design lists it,
## so a salvo's shells are always created in the same sequence.
func _fire_guns() -> void:
	if armory == null or _ready_to_fire.is_empty():
		return
	for ship: ShipEntity in ships:
		var ready: Variant = _ready_to_fire.get(ship.id)
		if ready == null:
			continue
		var target: ShipEntity = get_ship(ship.target_id)
		GunnerySystem.fire_ready_mounts(
			self, ship, ready as Array[FireControlSystem.ReadyMount], target)
	_ready_to_fire.clear()


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
	for projectile: Projectile in projectiles:
		projectile.hash_into(hasher)
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
