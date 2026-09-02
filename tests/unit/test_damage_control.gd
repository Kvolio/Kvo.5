extends SimTest

## The crew fighting to save the ship.
##
## The property that matters is that effort is FINITE and spread across everything at
## once. Two fires are each fought half as well as one; five are barely fought at all.
## That is how severe damage overwhelms a crew — not by a threshold that switches
## damage control off, but by there being too much of it, which is what actually
## happened aboard ships lost to damage they had initially contained.


func suite_name() -> String:
	return "Damage control"


func _world_with(spec_id: String) -> SimWorld:
	var world: SimWorld = TestShips.armed_world()
	world.add_ship(TestShips.load_ship(spec_id), Vector2.ZERO, 0.0, 0)
	return world


func _compartments_of(ship: ShipEntity, count: int) -> Array[ShipStructureState.CompartmentState]:
	var out: Array[ShipStructureState.CompartmentState] = []
	for compartment: ShipStructureState.CompartmentState in ship.structure_state.compartments:
		if compartment != null:
			out.append(compartment)
			if out.size() >= count:
				break
	return out


# ---------------------------------------------------------------------------

func test_an_intact_crew_puts_a_fire_out() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var compartment: ShipStructureState.CompartmentState = _compartments_of(ship, 1)[0]
	compartment.fire = 0.8

	TestShips.run_seconds(world, 400.0)
	almost(compartment.fire, 0.0, 0.02, "the fire is out")


func test_effort_is_spread_so_many_fires_are_each_fought_worse() -> void:
	# The whole point. One fire gets the ship's full attention; twenty share it.
	var single: SimWorld = _world_with("uss_iowa")
	var many: SimWorld = _world_with("uss_iowa")
	_compartments_of(single.ships[0], 1)[0].fire = 0.6
	for compartment: ShipStructureState.CompartmentState in _compartments_of(many.ships[0], 20):
		compartment.fire = 0.6

	TestShips.run_seconds(single, 120.0)
	TestShips.run_seconds(many, 120.0)

	lt(_compartments_of(single.ships[0], 1)[0].fire,
		_compartments_of(many.ships[0], 1)[0].fire,
		"any one of twenty fires is fought less well than a fire on its own")
	almost(_compartments_of(single.ships[0], 1)[0].fire, 0.0, 0.05,
		"the single fire is essentially out")
	gt(_total_fire(many.ships[0]), _total_fire(single.ships[0]) + 1.0,
		"and the ship with twenty is still well alight")
	lt(many.ships[0].structural_integrity(), single.ships[0].structural_integrity(),
		"which costs her far more of herself")


func test_a_ship_with_heavy_casualties_fights_damage_worse() -> void:
	# Fewer people means fewer parties, so a ship that has been badly hurt copes worse
	# with the next hit than she did with the last.
	var healthy: SimWorld = _world_with("uss_iowa")
	var mauled: SimWorld = _world_with("uss_iowa")
	mauled.ships[0].structure_state.crew_alive = int(float(mauled.ships[0].spec.crew) * 0.15)

	for world: SimWorld in [healthy, mauled]:
		for compartment: ShipStructureState.CompartmentState in _compartments_of(world.ships[0], 6):
			compartment.fire = 0.7
		TestShips.run_seconds(world, 150.0)

	lt(_compartments_of(healthy.ships[0], 1)[0].fire,
		_compartments_of(mauled.ships[0], 1)[0].fire,
		"the ship with her company intact does much better")


func test_a_breach_is_shored_before_it_can_be_pumped() -> void:
	# Pumping against an open hole is wasted work, and the model says so: the sealing
	# rate gates the pumping.
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var compartment: ShipStructureState.CompartmentState = _compartments_of(ship, 1)[0]
	compartment.breached = true
	compartment.breach_area_m2 = 0.05
	compartment.breach_depth_m = 3.0
	compartment.flood = 0.5

	TestShips.run_seconds(world, 600.0)
	almost(compartment.breach_area_m2, 0.0, 0.001, "the hole is shored and plugged")
	not_ok(compartment.breached, "she is no longer open to the sea")
	lt(compartment.flood, 0.5, "and only then does the water start going down")


func test_damaged_fittings_are_repaired_but_destroyed_ones_are_not() -> void:
	# The whole reason the two states are distinguished.
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	var mounts: PackedInt32Array = structure.volumes_with_role(
		ShipStructureBuilder.COMPONENT_TURRET)

	var repairable: ShipStructureState.ComponentState = ship.structure_state.component(mounts[0])
	var wrecked: ShipStructureState.ComponentState = ship.structure_state.component(mounts[1])
	repairable.condition = 0.4
	wrecked.condition = 0.0
	eq(repairable.state, 1, "one is damaged")
	eq(wrecked.state, 3, "the other destroyed")

	TestShips.run_seconds(world, 600.0)
	gt(repairable.condition, 0.4, "the damaged mount is brought back")
	almost(wrecked.condition, 0.0, 0.001, "the destroyed one stays destroyed")


func test_a_compartment_nearly_full_of_water_cannot_be_worked_in() -> void:
	# Beyond a point the party is driven out and the space is written off.
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var compartment: ShipStructureState.CompartmentState = _compartments_of(ship, 1)[0]
	compartment.flood = 0.98
	compartment.breached = false
	compartment.breach_area_m2 = 0.0

	TestShips.run_seconds(world, 400.0)
	gt(compartment.flood, 0.9, "the water stays: nobody can get in there to pump it")


func test_damage_control_is_the_difference_between_surviving_and_not() -> void:
	# The same fires, on a ship with a crew and on one without. A battleship's company
	# can cope with three fires; nobody at all cannot cope with anything.
	var crewed: SimWorld = _world_with("uss_iowa")
	var abandoned: SimWorld = _world_with("uss_iowa")
	abandoned.ships[0].structure_state.crew_alive = 0

	for world: SimWorld in [crewed, abandoned]:
		for compartment: ShipStructureState.CompartmentState in _compartments_of(world.ships[0], 3):
			compartment.fire = 0.9
		TestShips.run_seconds(world, 600.0)

	gt(crewed.ships[0].structural_integrity(),
		abandoned.ships[0].structural_integrity() + 0.01,
		"a ship with nobody left to fight the fire burns")
	almost(_total_fire(crewed.ships[0]), 0.0, 0.1, "the crewed ship has hers out")
	gt(_total_fire(abandoned.ships[0]), 0.5, "the abandoned one is still burning")


## Total fire intensity across the ship — a better measure of how badly she is alight
## than any single compartment, since fire spreads.
func _total_fire(ship: ShipEntity) -> float:
	var total: float = 0.0
	for compartment: ShipStructureState.CompartmentState in ship.structure_state.compartments:
		if compartment != null:
			total += compartment.fire
	return total


func test_damage_control_is_reproducible() -> void:
	var results: Array[float] = []
	for _run: int in 2:
		var world: SimWorld = _world_with("uss_iowa")
		for compartment: ShipStructureState.CompartmentState in _compartments_of(world.ships[0], 8):
			compartment.fire = 0.7
			compartment.breached = true
			compartment.breach_area_m2 = 0.3
			compartment.breach_depth_m = 2.0
		TestShips.run_seconds(world, 300.0)
		results.append(world.ships[0].structural_integrity())
	eq(results[0], results[1], "identical outcome from identical inputs")
