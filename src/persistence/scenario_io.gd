class_name ScenarioIo
extends RefCounted

## Loading a scenario, saving one, and building the world it describes.
##
## `build()` is the important half and it is deliberately the ONLY way a battle is set
## up. A replay works by building the same world from the same scenario file and the
## same seed, so anything that placed ships by another route would be a battle no
## replay could reproduce.
##
## Ships are added in a fixed order — forces as the file lists them, ships as the force
## lists them — because entity ids are allocated as ships are added and the whole
## simulation's determinism rests on those ids.

const SCENARIO_DIR: String = "res://data/scenarios"
const USER_DIR: String = "user://scenarios"


static func load_from_file(path: String) -> ScenarioDef:
	var data: Dictionary = JsonLoader.load_dict(path)
	if data.is_empty():
		push_error("ScenarioIo: could not load %s" % path)
		return null
	return ScenarioDef.parse(data, path)


static func load_all(directory: String = SCENARIO_DIR) -> Dictionary:
	var out: Dictionary = {}
	for path: String in JsonLoader.list_json_files(directory):
		var scenario: ScenarioDef = load_from_file(path)
		if scenario != null:
			out[scenario.scenario_id] = scenario
	return out


static func save(scenario: ScenarioDef, directory: String = USER_DIR) -> bool:
	if not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var path: String = directory.path_join("%s.json" % scenario.scenario_id)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("ScenarioIo: could not write %s" % path)
		return false
	file.store_string(Serializer.to_json(scenario.to_document()))
	file.close()
	return true


## The simulation config a scenario is fought with.
##
## The weather is not passed to the systems separately: it is written INTO the config
## they already read, so a scenario fought at night is one whose detection config says
## night, and a saved battle carries the numbers it was actually fought with.
static func configure(scenario: ScenarioDef, base: Dictionary) -> Dictionary:
	var config: Dictionary = base.duplicate(true)

	var sim: Dictionary = config.get("sim", {}) as Dictionary
	var world: Dictionary = sim.get("world", {}) as Dictionary
	world["seaState"] = scenario.sea_state
	world["defaultMapSizeM"] = Serializer.vec2_to_array(scenario.map_size)
	sim["world"] = world
	config["sim"] = sim

	var detection: Dictionary = config.get("detection", {}) as Dictionary
	if not detection.is_empty():
		detection["conditions"] = {
			"night": scenario.night, "visibilityFactor": scenario.visibility_factor,
		}
		config["detection"] = detection

	var fire_control: Dictionary = config.get("fire_control", {}) as Dictionary
	if not fire_control.is_empty():
		# At night without radar the rangefinders are useless, and the fall of shot
		# cannot be spotted either. Both follow from the same fact and are set together.
		fire_control["conditions"] = {
			"visibilityFactor": scenario.visibility_factor,
			"opticalUsable": not scenario.night,
		}
		config["fire_control"] = fire_control
	return config


## Build the world a scenario describes.
##
## `specs` resolves a ship id to a `ShipSpec` — the battle view hands it `ShipDatabase`,
## a test hands it a fixture loader, and neither this file nor the scenario knows the
## difference.
static func build(scenario: ScenarioDef, base_config: Dictionary, armory: Armory,
		specs: Callable) -> SimWorld:
	var world: SimWorld = SimWorld.create(scenario.seed_value, configure(scenario, base_config))
	if armory != null:
		world.set_armory(armory)

	for force: ScenarioDef.Force in scenario.forces:
		var deployed: Array[ShipEntity] = []
		if not force.fleet_id.is_empty():
			var fleet: FleetDef = FleetIo.load_from_file(
				"res://data/fleets/%s.json" % force.fleet_id)
			if fleet == null:
				push_warning("ScenarioIo: %s names unknown fleet '%s'" % [
					scenario.scenario_id, force.fleet_id])
			else:
				fleet.team = force.team
				deployed = FleetIo.deploy(world, fleet, force.position, force.heading_rad, specs)

		for entry: Variant in force.ships:
			var row: Dictionary = entry as Dictionary
			var spec: ShipSpec = specs.call(str(row.get("spec", ""))) as ShipSpec
			if spec == null:
				push_warning("ScenarioIo: %s names unknown ship '%s'" % [
					scenario.scenario_id, str(row.get("spec", ""))])
				continue
			var at: Vector2 = force.position + Serializer.array_to_vec2(
				row.get("positionM"), Vector2.ZERO).rotated(force.heading_rad)
			var heading: float = force.heading_rad
			if row.has("headingDeg"):
				heading = deg_to_rad(float(row["headingDeg"]))
			var ship: ShipEntity = world.add_ship(
				spec, at, heading, force.team, str(row.get("name", "")))
			ship.ai_controlled = true
			deployed.append(ship)

		for ship: ShipEntity in deployed:
			# A force the player is fighting keeps her orders; everything else is the
			# AI's. Stated per force rather than per ship, because "which side am I"
			# is a property of the side.
			ship.ai_controlled = not force.player_controlled
			MovementSystem.order_speed(ship, SimUnits.knots_to_ms(force.speed_knots))
	return world
