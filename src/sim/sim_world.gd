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
const CMD_FIRE_TORPEDOES: StringName = &"fire_torpedoes"

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

## Torpedoes running.
var torpedoes: Array[Torpedo] = []

## Configuration the damage systems read. Held on the world so a saved battle carries
## the numbers it was actually fought with.
var damage_config: Dictionary = {}
var torpedo_config: Dictionary = {}

## Gunnery direction quality: how wrong a ship's plot is allowed to be. Held on the
## world for the same reason as the damage numbers — a saved battle should reproduce
## the gunnery it was actually fought with.
var fire_control_config: Dictionary = {}

## Sea state, 0 (glassy) to 9. Costs pointing accuracy, and costs it worst to the
## smallest ships. Set by the scenario in Stage 8; a flat calm until then.
var sea_state: float = 2.0

## Who can see what. Detection is per TEAM, not per ship: a fleet shares what its
## lookouts and its radar find, which is what a flagship's plot was.
var detection_config: Dictionary = {}
var contacts: ContactPlot = null

## How the AI fights. Held on the world so a saved battle reproduces the doctrine it
## was actually fought with.
var ai_config: Dictionary = {}

## Formations, in formation-id order. Station keeping runs after the AI has decided
## what each ship is doing, so a ship that has broken off is not steered back into line.
var formations: Array[FormationSystem.Formation] = []

## Optional modules, stepped after everything else. Held as bare objects and called
## through a duck-typed hook, so the naval core names no module type and a build with a
## module's directory deleted still compiles. This is what makes the aircraft isolation
## real rather than a convention: there is nothing here for aircraft to be special in.
var _modules: Array = []

## Hits resolved recently, newest last. The debug overlay and the combat log read
## these; Stage 4's damage resolver writes their consequences back into them.
var recent_hits: Array[HitReport] = []

var _structure_config: Dictionary = {}
var _damage_interval: int = 30
var _structures: Dictionary = {}
var _immunity_zones: Dictionary = {}
var _projectile_pool: Array[Projectile] = []
var _torpedo_pool: Array[Torpedo] = []
var _hit_history_limit: int = 128

var map_size: Vector2 = Vector2(40000.0, 40000.0)

## Ships in ascending ID order. The ordering is load-bearing: every system that
## iterates ships inherits its determinism from this invariant.
var ships: Array[ShipEntity] = []

var _ships_by_id: Dictionary = {}
var _movement: MovementSystem = MovementSystem.new()
var _ready_to_fire: Dictionary = {}
var _fire_control_interval: int = 6
var _detection_interval: int = 15
var _ai_interval: int = 6

## Level-of-detail settings the AI reads. Held on the world so a saved battle carries
## the cadence it was actually fought at, and so nothing has to reach for the config.
var ai_lod: Dictionary = {}
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

	# Both indexes satisfy the same contract and are asserted to produce bit-identical
	# battles, so this is a performance choice and nothing else. Brute force stays
	# available as the correctness oracle: if a spatial result is ever in doubt, switch
	# to it and see whether the doubt goes away.
	var spatial_config: Dictionary = sim_config.get("spatial", {}) as Dictionary
	if str(spatial_config.get("index", "hash")) == "brute":
		world.spatial = BruteForceIndex.new()
	else:
		world.spatial = SpatialHashIndex.new(float(spatial_config.get("cellSizeM", 500.0)))
	world._movement.configure(config.get("physics", {}) as Dictionary)
	world._structure_config = config.get("structure", {}) as Dictionary
	world.damage_config = config.get("damage", {}) as Dictionary
	world.torpedo_config = config.get("torpedo", {}) as Dictionary
	world.fire_control_config = config.get("fire_control", {}) as Dictionary
	world.detection_config = config.get("detection", {}) as Dictionary
	world.ai_config = config.get("ai", {}) as Dictionary
	world.contacts = ContactPlot.new()
	world.sea_state = float(world_config.get("seaState", 2.0))
	ShipStructureState.ComponentState.configure(world.damage_config)
	var lod: Dictionary = sim_config.get("lod", {}) as Dictionary
	world._fire_control_interval = maxi(int(lod.get("fireControlIntervalTicks", 6)), 1)
	world._damage_interval = maxi(int(lod.get("damageControlTickInterval", 30)), 1)
	var detection_plot: Dictionary = \
		(world.detection_config.get("plot", {}) as Dictionary)
	world._detection_interval = maxi(int(detection_plot.get("updateIntervalTicks", 15)), 1)
	world._ai_interval = maxi(int(lod.get("aiTickIntervalNear", 6)), 1)
	world.ai_lod = lod
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
		shooter_id: int, target_id: int, team: int,
		battery: StringName = &"main") -> Projectile:
	var projectile: Projectile = (_projectile_pool.pop_back() as Projectile
		if not _projectile_pool.is_empty() else Projectile.new())
	# `gun` is null for ordnance that was never in one. A bomb arrives at a ship as a
	# mass with a velocity and a fuze, and the tracer has no way to ask what dropped it.
	projectile.reset(ids.allocate(), shell, shell.penetration_k, origin, velocity,
		shooter_id, target_id, team, "" if gun == null else gun.gun_id, battery)
	projectiles.append(projectile)
	return projectile


## Put a torpedo in the water.
func spawn_torpedo(definition: TorpedoDef, origin: Vector2, heading: float, speed: float,
		shooter_id: int, target_id: int, team: int) -> Torpedo:
	var torpedo: Torpedo = (_torpedo_pool.pop_back() as Torpedo
		if not _torpedo_pool.is_empty() else Torpedo.new())
	# The range a torpedo will run is a property of the SETTING it was fired on, so
	# find the setting that matches the ordered speed rather than assuming the longest.
	var range_m: float = definition.maximum_range()
	for candidate: TorpedoDef.Setting in definition.settings:
		if is_equal_approx(candidate.speed_ms, speed):
			range_m = candidate.range_m
	torpedo.reset(ids.allocate(), definition, origin, heading, speed, range_m,
		shooter_id, target_id, team)
	torpedoes.append(torpedo)
	return torpedo


func retire_torpedo(torpedo: Torpedo) -> void:
	torpedo.active = false
	torpedo.definition = null
	_torpedo_pool.append(torpedo)


## Record a torpedo hit. The damage has already been applied by the torpedo model;
## this is what puts it in the log and reassesses the ship.
func record_torpedo_hit(report: HitReport, target: ShipEntity) -> void:
	recent_hits.append(report)
	if recent_hits.size() > _hit_history_limit:
		recent_hits = recent_hits.slice(recent_hits.size() - _hit_history_limit)
	_reassess(target)
	events.emit_event(&"torpedo_hit", report.shooter_id, target.id,
		SimEvent.Severity.CRITICAL, {
			"torpedo": report.shell_name,
			"warheadKg": report.burster_charge_kg,
			"compartmentsOpened": report.compartments_entered.size(),
			"integrityDelta": report.damage.integrity_delta() if report.damage != null else 0.0,
			"casualties": report.damage.crew_casualties if report.damage != null else 0,
		})


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
			target.structure_state, damage_config, rng.stream(DamageResolver.RNG_STREAM))
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
		"calibreMm": report.calibre_mm,
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
	if damage_config.is_empty():
		return
	var interval_dt: float = clock.dt * float(_damage_interval)
	for ship: ShipEntity in ships:
		if ship.structure_state == null or ship.status == ShipEntity.Status.DESTROYED:
			continue
		if (clock.tick + ship.id) % _damage_interval != 0:
			continue
		var template: ShipStructureTemplate = structure_for(ship)
		FloodingSystem.step(ship, template, ship.structure_state, damage_config,
			interval_dt, rng.stream(FloodingSystem.RNG_STREAM))
		FireSystem.step(ship, template, ship.structure_state, damage_config,
			interval_dt, rng.stream(FireSystem.RNG_STREAM))
		DamageControlSystem.step(ship, template, ship.structure_state, damage_config, interval_dt)
		_reassess(ship)


## Recompute a ship's condition and let it take effect.
## Reassess every ship's condition from the state she is actually in.
##
## Called after a snapshot restore, because condition is DERIVED: a save carries the
## flooding and the wreckage and the dead, and the integrity, the list and the status
## are worked out again from them. Storing the conclusions as well as the evidence
## would be two fields that are supposed to agree, and eventually would not.
func reassess_all() -> void:
	for ship: ShipEntity in ships:
		_reassess(ship)


func _reassess(ship: ShipEntity) -> void:
	var template: ShipStructureTemplate = structure_for(ship)
	var previous: ShipEntity.Status = ship.status
	# Component effects first: the assessment reads the ship's propulsion, steering
	# and turret state, so pushing the damage through afterwards would leave it a tick
	# behind — and a ship whose steering gear had just been wrecked would be reported
	# as still able to steer.
	SurvivabilityEvaluator.apply_component_effects(ship, template, ship.structure_state)
	ship.condition = SurvivabilityEvaluator.assess(ship, template, ship.structure_state,
		damage_config)

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
		ship.build_torpedo_launchers(armory)


func get_seed() -> int:
	return _seed


## Register an optional module.
##
## The contract is one method, `step_module(world, dt)`, asserted here rather than
## trusted: a module that forgets it fails at registration instead of quietly never
## running. The world knows nothing else about what it has been given.
func register_module(module: Object) -> void:
	assert(module != null and module.has_method("step_module"),
		"a simulation module must implement step_module(world, dt)")
	_modules.append(module)


func module_count() -> int:
	return _modules.size()


## The first registered module that implements `method`, or null.
##
## How the view finds out whether there is anything to draw beyond ships and shells,
## without the core naming a module type or the view assuming one is there. A build
## with `src/sim/air/` deleted simply gets null back and draws no aircraft.
func module_providing(method: StringName) -> Object:
	for module: Object in _modules:
		if module.has_method(method):
			return module
	return null


func _step_modules() -> void:
	for module: Object in _modules:
		module.call("step_module", self, clock.dt)


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
		ship.build_torpedo_launchers(armory)
	# Her own damage state, built from the shared geometry of her design.
	var template: ShipStructureTemplate = structure_for(ship)
	# How far she can see, and from how far she can be seen, measured off her own
	# upperworks plus her masts — which stand well above the highest plating and are
	# what a lookout is actually standing in.
	ship.sighting_height_m = template.superstructure_top_z * float(
		(detection_config.get("sighting", {}) as Dictionary).get("mastFactor", 1.35))
	ship.structure_state = ShipStructureState.create(template, spec, _structure_config)
	ship.condition = SurvivabilityEvaluator.assess(ship, template, ship.structure_state,
		damage_config)
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


## What this ship's armour is worth against that ship's main gun.
##
## Cached per design pair: the answer depends only on the armour scheme and the gun,
## both of which are immutable for the length of a battle, and computing it walks a
## whole range table through the penetration model. Two Iowas facing four Yamatos ask
## this question eight times and compute it once.
func immunity_zone(ship: ShipEntity, enemy: ShipEntity) -> ImmunityZone:
	if armory == null or ship.spec.armour == null or not enemy.spec.has_main_battery():
		return null
	var battery: BatteryDef = enemy.spec.main_battery
	var gun: GunDef = armory.get_gun(battery.gun_id)
	if gun == null:
		return null
	var shell_id: String = gun.default_ammunition()
	var key: String = "%s|%s|%s" % [ship.spec.spec_id, battery.gun_id, shell_id]
	var cached: Variant = _immunity_zones.get(key)
	if cached != null:
		return cached as ImmunityZone

	var table: RangeTable = armory.range_table(battery.gun_id, shell_id)
	var zone: ImmunityZone = ImmunityZone.compute(
		ship.spec.armour, table, armory.get_shell(shell_id), penetration_model, materials)
	_immunity_zones[key] = zone
	return zone


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
##   3. detection     each side's plot is brought up to date, so gunnery and the AI
##                    act on the picture they have this tick rather than last tick's
##   4. AI            captains choose targets and courses from that plot, and then
##                    formations close up on whoever has not broken away
##   5. fire control  gunnery solves against those new positions, not last tick's
##   6. mounts        turrets train, elevate and load towards their orders
##   7. gunnery       mounts that are laid, loaded and bearing put shells in the air
##   8. projectiles   shells fly, and the ones that arrive are resolved against armour
##   9. torpedoes     tubes train, and torpedoes already running close their targets
##  10. damage        flooding spreads, fires burn, damage control fights both, and
##                    each ship's condition is reassessed from what is wrong with her
##  11. modules       optional modules run — aircraft, if any are registered. Last,
##                    so anything they create enters the world on the next tick and
##                    a battle with no modules is bit-identical to one before they
##                    existed
##  12. spatial       the index is brought up to date for next tick's queries
func step() -> void:
	events.begin_tick(clock.tick)
	_apply_commands()
	_movement.step(ships, clock.dt)
	_step_detection()
	_step_ai()
	_direct_gunnery()
	_step_turrets()
	_fire_guns()
	if armory != null:
		ProjectileSystem.step(self, clock.dt)
		_direct_torpedoes()
		TorpedoSystem.step(self, clock.dt)
	_step_damage()
	_step_modules()
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
	var cycle_dt: float = clock.dt * float(_fire_control_interval)
	for ship: ShipEntity in ships:
		if not ship.is_afloat() or ship.turrets.is_empty():
			continue
		if (clock.tick + ship.id) % _fire_control_interval != 0:
			continue
		var target: ShipEntity = get_ship(ship.target_id) if ship.target_id != 0 else null
		var ready: Array[FireControlSystem.ReadyMount] = []
		# Each battery is directed on its own plot. Batteries are taken in name order
		# so the sequence of random draws — and therefore the battle — does not depend
		# on the order the design happens to list her mounts in.
		var by_battery: Dictionary = _turrets_by_battery(ship)
		for battery: String in Serializer.sorted_keys(by_battery):
			var group: Array[Turret] = by_battery[battery]
			var plot: FireControlSolution = _run_plot(ship, target, cycle_dt, StringName(battery))
			ready.append_array(FireControlSystem.direct_battery(
				ship, group, target, armory, plot))
		if not ready.is_empty():
			_ready_to_fire[ship.id] = ready


static func _turrets_by_battery(ship: ShipEntity) -> Dictionary:
	var grouped: Dictionary = {}
	for turret: Turret in ship.turrets:
		var key: String = String(turret.battery)
		if not grouped.has(key):
			var group: Array[Turret] = []
			grouped[key] = group
		(grouped[key] as Array[Turret]).append(turret)
	return grouped


## Advance one ship's gunnery plot, and hand it to the guns.
##
## A ship that checks fire loses her solution: the plot is marked shut, and picking the
## target up again starts from a fresh set of errors. That is not a penalty invented to
## make checking fire costly — it is what happened, and it is why ships held on to a
## target they were solving for even when a better one appeared.
func _run_plot(ship: ShipEntity, target: ShipEntity, dt: float,
		battery: StringName) -> FireControlSolution:
	var plot: FireControlSolution = ship.plot_for(battery)
	if target == null or not target.is_afloat():
		if plot != null:
			plot.opened = false
		return null
	if fire_control_config.is_empty():
		return null  # gunnery with perfect information, for tests that want the geometry alone
	if ship.fire_control_fit == null:
		ship.fire_control_fit = FireControlSolution.fit_for(ship.spec, fire_control_config)
	if plot == null:
		plot = FireControlSolution.new()
		ship.fire_control[battery] = plot
	plot.track(ship, target, ship.fire_control_fit, fire_control_config,
		dt, sea_state, rng.stream(FireControlSolution.RNG_STREAM))
	return plot


## A shell has fallen where the spotting officer can see it.
##
## The fall of shot is the only feedback a ship gets, and it is the feedback that
## matters most: it corrects the range whatever was wrong with it — the rangefinder,
## the wind aloft, the powder, or the plot's idea of the target's course — because the
## officer calling the correction cannot tell those apart either.
func report_fall_of_shot(projectile: Projectile, splash: Vector2) -> void:
	var shooter: ShipEntity = get_ship(projectile.shooter_id)
	if shooter == null:
		return
	# The plot that laid this gun, and no other. Corrections flow back to the director
	# that made the error, which is why the batteries carry their labels this far.
	var plot: FireControlSolution = shooter.plot_for(projectile.battery)
	if plot == null or not plot.opened or projectile.target_id != plot.target_id:
		return
	var target: ShipEntity = get_ship(projectile.target_id)
	if target == null or not target.is_afloat():
		return
	var origin: Vector2 = shooter.position
	var true_range: float = origin.distance_to(target.position)
	plot.observe_fall(origin.distance_to(splash) - true_range, true_range)


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


## Captains decide, then formations close up.
##
## In that order, and it matters: station keeping must not steer a ship back into line
## after her captain has just turned her out of it to comb a torpedo track.
func _step_ai() -> void:
	if ai_config.is_empty():
		return
	AiSystem.step(self, clock.dt, _ai_interval)
	FormationSystem.step(self, clock.dt)


## Add a formation and station its members on one another.
func add_formation(formation_id: String, team: int, members: Array[ShipEntity],
		shape: int = FormationSystem.Shape.COLUMN, spacing_m: float = 700.0
) -> FormationSystem.Formation:
	var formation: FormationSystem.Formation = FormationSystem.create(
		formation_id, team, members, shape, spacing_m)
	formations.append(formation)
	formations.sort_custom(func(a: FormationSystem.Formation, b: FormationSystem.Formation) -> bool:
		return a.formation_id < b.formation_id)
	return formation


## Sweep the lookouts and the sets.
##
## Runs before gunnery so a ship shoots at the picture she has this tick rather than
## last tick's, and at a lower rate than the tick because a horizon does not move in a
## sixtieth of a second. The whole formation's flash and fire markers are aged here too,
## so a ship that fired is briefly visible past the horizon at night.
func _step_detection() -> void:
	var interval: int = _detection_interval
	for ship: ShipEntity in ships:
		if ship.firing_seconds_ago >= 0.0:
			ship.firing_seconds_ago += clock.dt
	if clock.tick % interval != 0:
		return
	DetectionSystem.step(self, clock.dt * float(interval))


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
		CMD_FIRE_TORPEDOES:
			fire_torpedoes(ship)
		_:
			push_warning("SimWorld: unhandled command type '%s'" % command.type)


## Train every ship's tubes on its target.
##
## Torpedoes are NOT fired automatically. A destroyer captain gets one salvo and the
## decision of when to spend it is the biggest one he makes, so it stays a command —
## from the player now, from the AI in Stage 7.
func _direct_torpedoes() -> void:
	var launcher_config: Dictionary = torpedo_config.get("launcher", {}) as Dictionary
	var train_rate: float = deg_to_rad(float(launcher_config.get("trainRateDegPerSec", 12.0)))
	for ship: ShipEntity in ships:
		if ship.torpedo_launchers.is_empty() or not ship.is_afloat():
			continue
		var target: ShipEntity = get_ship(ship.target_id) if ship.target_id != 0 else null
		var definition: TorpedoDef = armory.get_torpedo(ship.spec.torpedo_battery.torpedo_id)
		TorpedoFireControl.direct(ship, target, definition, train_rate, clock.dt)


## Loose every tube that bears. One order empties the ship.
func fire_torpedoes(ship: ShipEntity) -> void:
	if armory == null or ship.torpedo_launchers.is_empty():
		return
	var target: ShipEntity = get_ship(ship.target_id)
	if target == null or not target.is_afloat():
		return
	var definition: TorpedoDef = armory.get_torpedo(ship.spec.torpedo_battery.torpedo_id)
	if definition == null:
		return

	var launcher_config: Dictionary = torpedo_config.get("launcher", {}) as Dictionary
	var spread: float = deg_to_rad(float(launcher_config.get("spreadAngleDeg", 2.5)))

	for launcher: TorpedoLauncher in ship.torpedo_launchers:
		var solution: TorpedoFireControl.Solution = TorpedoFireControl.solve(
			ship, launcher, target, definition)
		if not solution.valid or not solution.bears or not launcher.can_fire():
			continue
		var count: int = launcher.fire()
		var local: Vector2 = launcher.mount.local_position(ship.spec.length_m, ship.spec.beam_m)
		var origin: Vector2 = ship.position + local.rotated(ship.heading)
		for i: int in count:
			# A salvo is fired as a SPREAD across the target's possible courses, not
			# at a point. It is aimed at an area she might be in, which is why a
			# handful of tubes can threaten a ship a mile away.
			var offset: float = 0.0
			if count > 1:
				offset = (float(i) / float(count - 1) - 0.5) * spread * float(count)
			spawn_torpedo(definition, origin, solution.bearing + offset,
				solution.speed_ms, ship.id, target.id, ship.team)
		events.emit_event(&"torpedoes_fired", ship.id, target.id, SimEvent.Severity.NOTABLE, {
			"mount": launcher.mount.mount_id,
			"torpedo": definition.display_name,
			"count": count,
			"runTimeS": solution.run_time,
			"rangeM": solution.run_distance,
		})


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
	for torpedo: Torpedo in torpedoes:
		torpedo.hash_into(hasher)
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
