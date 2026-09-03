class_name TestShips
extends RefCounted

## Ship fixtures for tests.
##
## These load the SAME files the game loads, rather than hard-coding a parallel set
## of numbers. That matters: a physics assertion is only meaningful if it is testing
## the ship the player actually gets, and a fixture that drifted from the data would
## quietly stop testing anything.
##
## Real ships rather than invented ones, so an assertion can be checked against
## something knowable — if the model says Iowa reaches 33 knots and needs minutes to
## turn a circle, that is a claim about reality, not just internal consistency.

## USS Iowa (BB-61), 1943.
static func iowa() -> ShipSpec:
	return load_ship("uss_iowa")


## USS Fletcher (DD-445), 1942.
static func fletcher() -> ShipSpec:
	return load_ship("uss_fletcher")


static func load_ship(spec_id: String) -> ShipSpec:
	var spec: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/%s.json" % spec_id)
	assert(spec != null, "test fixture could not load ship '%s'" % spec_id)
	return spec


## A world containing one ship, ready to step. Seeded so tests are reproducible.
static func world_with(spec: ShipSpec, seed_value: int = 1234) -> SimWorld:
	var world: SimWorld = SimWorld.create(seed_value, movement_config())
	world.add_ship(spec, Vector2.ZERO, 0.0, 0)
	return world


## Minimal config matching data/config/*.json, without needing the autoload.
static func config() -> Dictionary:
	return {
		"sim": JsonLoader.load_dict("res://data/config/sim.json"),
		"physics": JsonLoader.load_dict("res://data/config/physics.json"),
		"ballistics": JsonLoader.load_dict("res://data/config/ballistics.json"),
		"structure": JsonLoader.load_dict("res://data/config/structure.json"),
		"damage": JsonLoader.load_dict("res://data/config/damage.json"),
		"torpedo": JsonLoader.load_dict("res://data/config/torpedo.json"),
		"fire_control": JsonLoader.load_dict("res://data/config/fire_control.json"),
		"detection": JsonLoader.load_dict("res://data/config/detection.json"),
		"ai": JsonLoader.load_dict("res://data/config/ai.json"),
	}


## Configuration for a movement-only world: no damage systems at all.
##
## The movement suite is a unit test of how a ship handles, and a world with damage
## control running would have the crew repairing the steering gear underneath the
## test. Omitting the damage config leaves flooding, fire and damage control switched
## off, so what is measured is the movement model and nothing else.
static func movement_config() -> Dictionary:
	return {
		"sim": JsonLoader.load_dict("res://data/config/sim.json"),
		"physics": JsonLoader.load_dict("res://data/config/physics.json"),
		"ballistics": JsonLoader.load_dict("res://data/config/ballistics.json"),
		"structure": JsonLoader.load_dict("res://data/config/structure.json"),
	}


## A world with guns. Built once per call, but the armoury itself is shared so range
## tables survive between tests.
static func armed_world(seed_value: int = 1234) -> SimWorld:
	var world: SimWorld = SimWorld.create(seed_value, config())
	world.set_armory(TestWeapons.armory())
	return world


static var _structures: Dictionary = {}


## Internal geometry for a design, built once and cached across the whole test run.
static func structure(spec_id: String) -> ShipStructureTemplate:
	if _structures.has(spec_id):
		return _structures[spec_id] as ShipStructureTemplate
	var built: ShipStructureTemplate = ShipStructureBuilder.build(
		load_ship(spec_id), JsonLoader.load_dict("res://data/config/structure.json"))
	_structures[spec_id] = built
	return built


## Set the condition of some or all components with a role, then let it take effect.
##
## Ship handling is DERIVED from component condition — a ship is slow because her
## engines are wrecked, not because a number was set — so this is how a test expresses
## damage. Assigning propulsion_fraction directly would simply be recomputed away on
## the next damage tick, which is the behaviour working correctly.
static func wreck_components(world: SimWorld, ship: ShipEntity, role: String,
		condition: float, count: int = -1) -> int:
	var structure: ShipStructureTemplate = world.structure_for(ship)
	var indices: PackedInt32Array = structure.volumes_with_role(role)
	var limit: int = indices.size() if count < 0 else mini(count, indices.size())
	for i: int in limit:
		var component: ShipStructureState.ComponentState = ship.structure_state.component(indices[i])
		if component != null:
			component.condition = clampf(condition, 0.0, 1.0)
	world._reassess(ship)
	return limit


## Wreck only the components of a role on one side of the centreline.
static func wreck_components_on_side(world: SimWorld, ship: ShipEntity, role: String,
		condition: float, starboard: bool) -> int:
	var structure: ShipStructureTemplate = world.structure_for(ship)
	var wrecked: int = 0
	for index: int in structure.volumes_with_role(role):
		var on_starboard: bool = structure.volumes[index].centre().y > 0.0
		if on_starboard != starboard:
			continue
		var component: ShipStructureState.ComponentState = ship.structure_state.component(index)
		if component != null:
			component.condition = clampf(condition, 0.0, 1.0)
			wrecked += 1
	world._reassess(ship)
	return wrecked


## Run a world forward by `seconds` of simulated time.
static func run_seconds(world: SimWorld, seconds: float) -> void:
	world.step_many(int(round(seconds / world.clock.dt)))
