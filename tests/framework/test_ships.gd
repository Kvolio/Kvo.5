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
	var world: SimWorld = SimWorld.create(seed_value, config())
	world.add_ship(spec, Vector2.ZERO, 0.0, 0)
	return world


## Minimal config matching data/config/*.json, without needing the autoload.
static func config() -> Dictionary:
	return {
		"sim": JsonLoader.load_dict("res://data/config/sim.json"),
		"physics": JsonLoader.load_dict("res://data/config/physics.json"),
		"ballistics": JsonLoader.load_dict("res://data/config/ballistics.json"),
	}


## A world with guns. Built once per call, but the armoury itself is shared so range
## tables survive between tests.
static func armed_world(seed_value: int = 1234) -> SimWorld:
	var world: SimWorld = SimWorld.create(seed_value, config())
	world.set_armory(TestWeapons.armory())
	return world


## Run a world forward by `seconds` of simulated time.
static func run_seconds(world: SimWorld, seconds: float) -> void:
	world.step_many(int(round(seconds / world.clock.dt)))
