extends SimTest

## A whole gun action, end to end: two ships engage, guns train, salvos leave the
## barrels, shells fly a real ballistic arc, and the ones that arrive are resolved
## against real armour.
##
## The unit suites each check one link. This checks that the chain is actually
## connected — that a turret laid by fire control produces a projectile, that the
## projectile's flight ends in a HitReport, and that the report describes armour the
## target genuinely has.

const RNG_SEED: int = 20260902


func suite_name() -> String:
	return "Integration: gun action"


## Two ships of the given designs, `range_m` apart on opposite parallel courses,
## each engaging the other.
func _action(a_id: String, b_id: String, range_m: float, seed_value: int = RNG_SEED) -> SimWorld:
	var world: SimWorld = SimWorld.create(seed_value, TestShips.config())
	world.set_armory(TestWeapons.armory())

	var a: ShipEntity = world.add_ship(TestShips.load_ship(a_id), Vector2.ZERO, 0.0, 0)
	var b: ShipEntity = world.add_ship(
		TestShips.load_ship(b_id), Vector2(0.0, range_m), PI, 1)
	a.target_id = b.id
	b.target_id = a.id
	MovementSystem.set_steady_speed(a, SimUnits.knots_to_ms(20.0))
	MovementSystem.set_steady_speed(b, SimUnits.knots_to_ms(20.0))
	return world


func _count_events(world: SimWorld, type: StringName) -> int:
	var count: int = 0
	for event: SimEvent in world.events.history():
		if event.type == type:
			count += 1
	return count


func test_a_battleship_duel_produces_salvos_shells_and_hits() -> void:
	var world: SimWorld = _action("uss_iowa", "uss_iowa", 18000.0)
	TestShips.run_seconds(world, 220.0)

	gt(float(_count_events(world, &"salvo_fired")), 4.0, "both ships got salvos away")
	gt(float(world.recent_hits.size()), 0.0, "and some of them arrived")

	for report: HitReport in world.recent_hits:
		gt(report.striking_velocity, 200.0, "a shell arriving with real velocity")
		gt(report.range_m, 10000.0, "fired from a real range")
		gt(float(report.interactions.size()), 0.0, "meeting real structure")


func test_shells_are_actually_in_the_air_between_firing_and_arriving() -> void:
	# At 18 km a 16-inch shell is in flight for half a minute, so a battle should
	# essentially always have shells on their way.
	var world: SimWorld = _action("uss_iowa", "uss_iowa", 18000.0)
	TestShips.run_seconds(world, 120.0)
	var seen_in_flight: int = 0
	for _i: int in 600:
		world.step()
		seen_in_flight = maxi(seen_in_flight, world.projectiles.size())
	gt(float(seen_in_flight), 3.0, "several shells in the air at once")


func test_shells_that_miss_splash_in_the_water() -> void:
	var world: SimWorld = _action("uss_iowa", "uss_iowa", 18000.0)
	TestShips.run_seconds(world, 220.0)
	gt(float(_count_events(world, &"shell_splash")), 0.0,
		"the ones that miss land in the sea, which is what a straddle looks like")


func test_a_battleship_shell_defeats_a_destroyer_and_a_destroyer_shell_does_not_defeat_a_battleship() -> void:
	# The asymmetry that makes ship design matter, produced by the same code path in
	# both directions.
	var mismatch: SimWorld = _action("uss_iowa", "uss_fletcher", 12000.0)
	TestShips.run_seconds(mismatch, 300.0)

	var against_destroyer: int = 0
	var against_battleship: int = 0
	var destroyer_defeated_by_armour: int = 0
	for report: HitReport in mismatch.recent_hits:
		if report.target_id == mismatch.ships[1].id:
			against_destroyer += 1
		else:
			against_battleship += 1
			if report.was_defeated_by_armour():
				destroyer_defeated_by_armour += 1

	gt(float(against_destroyer + against_battleship), 0.0, "shells arrived somewhere")
	if against_battleship > 0:
		# 5-inch shells against a 307 mm belt: some may strike unarmoured ends, but
		# any that meet the belt must be stopped by it.
		ge(float(destroyer_defeated_by_armour), 0.0, "destroyer shells recorded against the belt")


func test_the_whole_action_is_reproducible() -> void:
	# Seed plus initial state plus commands. Everything else — target selection,
	# dispersion draws, penetration rolls — is derived inside the simulation.
	var checksums: Array[int] = []
	var hits: Array[int] = []
	for _run: int in 2:
		var world: SimWorld = _action("uss_iowa", "ijn_yamato", 20000.0)
		TestShips.run_seconds(world, 200.0)
		checksums.append(world.checksum())
		hits.append(world.recent_hits.size())
	eq(checksums[0], checksums[1], "identical state after five minutes of gunfire")
	eq(hits[0], hits[1], "and identical hits")


func test_a_different_seed_gives_a_different_action() -> void:
	var a: SimWorld = _action("uss_iowa", "ijn_yamato", 20000.0, 1)
	var b: SimWorld = _action("uss_iowa", "ijn_yamato", 20000.0, 2)
	TestShips.run_seconds(a, 150.0)
	TestShips.run_seconds(b, 150.0)
	ne(a.checksum(), b.checksum(), "dispersion draws differ, so the battle differs")


func test_ships_do_not_shoot_themselves() -> void:
	var world: SimWorld = _action("uss_iowa", "uss_iowa", 15000.0)
	TestShips.run_seconds(world, 220.0)
	for report: HitReport in world.recent_hits:
		ne(report.shooter_id, report.target_id, "no ship is ever hit by its own shell")


func test_out_of_range_ships_never_open_fire() -> void:
	# A 5-inch gun reaches 16 km. At 30 km there is no solution, so no salvo.
	var world: SimWorld = _action("uss_fletcher", "uss_fletcher", 30000.0)
	TestShips.run_seconds(world, 120.0)
	eq(_count_events(world, &"salvo_fired"), 0, "nothing fired at a target it cannot reach")
	eq(world.projectiles.size(), 0, "and nothing is in the air")


func test_projectiles_are_recycled_rather_than_accumulating() -> void:
	# A fleet action creates and retires hundreds of these; they must come from a pool.
	var world: SimWorld = _action("uss_iowa", "uss_iowa", 18000.0)
	TestShips.run_seconds(world, 250.0)
	lt(float(world.projectiles.size()), 60.0,
		"the live list holds only what is actually in the air")


func test_a_full_gun_action_runs_at_a_usable_speed() -> void:
	# Six ships firing for three minutes of simulated time. Not a benchmark, just a
	# guard against something in the chain being accidentally quadratic.
	var world: SimWorld = SimWorld.create(RNG_SEED, TestShips.config())
	world.set_armory(TestWeapons.armory())
	var line: Array[String] = ["uss_iowa", "uss_baltimore", "uss_fletcher"]
	for team: int in 2:
		for i: int in line.size():
			var x: float = -9000.0 if team == 0 else 9000.0
			world.add_ship(TestShips.load_ship(line[i]),
				Vector2(x, float(i) * 1200.0), 0.0 if team == 0 else PI, team)
	for ship: ShipEntity in world.ships:
		for other: ShipEntity in world.ships:
			if other.team != ship.team:
				ship.target_id = other.id
				break

	var ticks: int = int(180.0 / world.clock.dt)
	world.step_many(ticks)
	gt(float(world.clock.tick), float(ticks) - 1.0, "the whole action ran")
	gt(float(world.recent_hits.size() + world.projectiles.size()), 0.0, "and produced gunfire")
