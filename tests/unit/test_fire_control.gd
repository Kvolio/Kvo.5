extends SimTest

## Gunnery direction: solving where to point so that a shell and a ship arrive
## together.
##
## The interesting property here is not that the maths is right, it is that being
## right is not enough. The solution is computed for the course the target is on now,
## so a ship that turns after the salvo leaves the guns will not be where the solution
## said. No evasion behaviour is written anywhere; it falls out of the lead being
## computed against a course the target need not keep.


func suite_name() -> String:
	return "Fire control"


## Shooter at the origin heading east; target `range_m` away on the given bearing,
## running at `target_knots` on the given heading. Run up to steady speed first, so
## the straight-line lead is being tested rather than the target's acceleration.
func _engagement(
	range_m: float, target_knots: float, target_heading: float,
	bearing_from_shooter: float = 0.0
) -> SimWorld:
	var world: SimWorld = TestShips.armed_world()
	world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var offset: Vector2 = Vector2(range_m, 0.0).rotated(bearing_from_shooter)
	var target: ShipEntity = world.add_ship(TestShips.fletcher(), offset, target_heading, 1)
	MovementSystem.order_speed(target, SimUnits.knots_to_ms(target_knots))
	TestShips.run_seconds(world, 400.0)
	return world


func _solve(world: SimWorld, turret_index: int = 0) -> FireControlSystem.Solution:
	var shooter: ShipEntity = world.ships[0]
	var target: ShipEntity = world.ships[1]
	var turret: Turret = shooter.main_battery_turrets()[turret_index]
	var table: RangeTable = world.armory.range_table(turret.gun.gun_id, turret.selected_shell)
	return FireControlSystem.solve(shooter, turret, target, table)


# ----------------------------------------------------------------------- lead --

func test_a_stationary_target_needs_no_lead() -> void:
	var world: SimWorld = _engagement(20000.0, 0.0, 0.0)
	var solution: FireControlSystem.Solution = _solve(world)
	ok(solution.valid, "solution found")
	lt(solution.lead_m, 5.0, "the guns point straight at her")


func test_a_moving_target_is_led() -> void:
	# A Fletcher at 30 knots crosses 15 m every second, and a 16-inch shell is in the
	# air for half a minute at 20 km.
	var world: SimWorld = _engagement(20000.0, 30.0, PI * 0.5)
	var solution: FireControlSystem.Solution = _solve(world)
	ok(solution.valid, "solution found")
	gt(solution.lead_m, 300.0, "aiming hundreds of metres ahead of her")
	gt(solution.time_of_flight, 25.0, "because the shell takes that long to arrive")


func test_lead_grows_with_range() -> void:
	var near: FireControlSystem.Solution = _solve(_engagement(10000.0, 30.0, PI * 0.5))
	var far: FireControlSystem.Solution = _solve(_engagement(30000.0, 30.0, PI * 0.5))
	gt(far.lead_m, near.lead_m * 2.0, "a longer flight means a longer lead")


func test_lead_grows_with_target_speed() -> void:
	var slow: FireControlSystem.Solution = _solve(_engagement(20000.0, 10.0, PI * 0.5))
	var fast: FireControlSystem.Solution = _solve(_engagement(20000.0, 33.0, PI * 0.5))
	gt(fast.lead_m, slow.lead_m * 2.0, "a faster ship must be led further")


func test_a_target_closing_head_on_is_barely_led_across() -> void:
	# Lead is about where the target will be, so a ship coming straight at the guns
	# needs a correction in range rather than in bearing.
	var world: SimWorld = _engagement(20000.0, 30.0, PI)   # heading west, straight at us
	var solution: FireControlSystem.Solution = _solve(world)
	var target: ShipEntity = world.ships[1]
	var bearing_to_target: float = (target.position - world.ships[0].position).angle()
	almost(rad_to_deg(SimUnits.angle_delta(solution.world_bearing, bearing_to_target)), 0.0, 1.0,
		"the bearing barely changes")
	lt(solution.range_m, solution.present_range_m, "but the guns are laid for a shorter range")


func test_the_intercept_actually_intercepts() -> void:
	# The end-to-end check: solve, then let the world run for the solved time of
	# flight and see whether the target is where the solution said she would be.
	var world: SimWorld = _engagement(22000.0, 30.0, PI * 0.5)
	var solution: FireControlSystem.Solution = _solve(world)
	ok(solution.valid, "solution found")

	TestShips.run_seconds(world, solution.time_of_flight)
	var target: ShipEntity = world.ships[1]
	lt(target.position.distance_to(solution.aim_point), 60.0,
		"the target arrives at the aim point, within a fraction of a ship's length")


func test_a_target_that_turns_defeats_the_solution() -> void:
	# No evasion logic exists. This works because the lead was computed for a course
	# the target then declined to keep.
	var world: SimWorld = _engagement(22000.0, 30.0, PI * 0.5)
	var solution: FireControlSystem.Solution = _solve(world)
	var target: ShipEntity = world.ships[1]

	MovementSystem.order_rudder(target, 1.0)   # hard a-starboard the moment we fire
	TestShips.run_seconds(world, solution.time_of_flight)
	gt(target.position.distance_to(solution.aim_point), 500.0,
		"she is nowhere near where the guns were laid")


# ----------------------------------------------------------------------- arcs --

func test_a_target_in_a_mounts_blind_arc_is_reported_not_fired_at() -> void:
	# Target dead astern: the forward turrets cannot bear, the after turret can.
	var world: SimWorld = _engagement(20000.0, 0.0, 0.0, PI)
	var shooter: ShipEntity = world.ships[0]
	var forward: FireControlSystem.Solution = _solve(world, 0)
	ok(forward.valid, "a solution still exists")
	not_ok(forward.bears, "but the forward turret cannot train onto it")
	ne(forward.reason, "", "and the reason is reported rather than left blank")

	var after_index: int = shooter.main_battery_turrets().size() - 1
	ok(_solve(world, after_index).bears, "the after turret bears on it perfectly well")


func test_broadside_brings_far_more_guns_to_bear_than_bow_on() -> void:
	# The whole reason for manoeuvring in a gun action.
	var spec: ShipSpec = TestShips.iowa()
	var world: SimWorld = TestShips.armed_world()
	var iowa: ShipEntity = world.add_ship(spec, Vector2.ZERO, 0.0, 0)
	var main: Array[Turret] = iowa.main_battery_turrets()

	eq(FireControlSystem.barrels_bearing(main, deg_to_rad(90.0)), 9, "nine guns on the beam")
	eq(FireControlSystem.barrels_bearing(main, deg_to_rad(-90.0)), 9, "nine on the other beam")
	eq(FireControlSystem.barrels_bearing(main, 0.0), 6, "only the forward six dead ahead")
	eq(FireControlSystem.barrels_bearing(main, PI), 3, "and only the after three astern")


func test_a_destroyed_turret_stops_counting_towards_the_broadside() -> void:
	var world: SimWorld = TestShips.armed_world()
	var iowa: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var main: Array[Turret] = iowa.main_battery_turrets()
	main[0].state = Turret.State.DESTROYED
	eq(FireControlSystem.barrels_bearing(main, deg_to_rad(90.0)), 6, "three barrels gone")


# ------------------------------------------------------------------- geometry --

func test_mounts_are_aimed_from_where_they_actually_are() -> void:
	# On a 270 m ship the bearing from A turret and from the after turret to a close
	# target differ measurably. Treating every mount as amidships would put part of
	# the salvo consistently off.
	var world: SimWorld = _engagement(6000.0, 0.0, 0.0, deg_to_rad(60.0))
	var forward: FireControlSystem.Solution = _solve(world, 0)
	var after: FireControlSystem.Solution = _solve(world, world.ships[0].main_battery_turrets().size() - 1)
	gt(absf(rad_to_deg(SimUnits.angle_delta(forward.world_bearing, after.world_bearing))), 0.5,
		"the two ends of the ship see a different bearing")
	gt(absf(forward.range_m - after.range_m), 50.0, "and a different range")


# ------------------------------------------------------------------- validity --

func test_a_target_beyond_maximum_range_gives_no_solution() -> void:
	var world: SimWorld = _engagement(60000.0, 0.0, 0.0)
	var solution: FireControlSystem.Solution = _solve(world)
	not_ok(solution.valid, "no solution at 60 km")
	eq(solution.reason, "out of range", "and it says why")


func test_a_wrecked_mount_produces_no_solution() -> void:
	var world: SimWorld = _engagement(20000.0, 0.0, 0.0)
	world.ships[0].main_battery_turrets()[0].state = Turret.State.DESTROYED
	not_ok(_solve(world).valid, "a destroyed turret has no gunnery solution")


# ------------------------------------------------------------ battery control --

func test_directing_a_battery_lays_every_mount_that_can_bear() -> void:
	var world: SimWorld = _engagement(20000.0, 20.0, PI * 0.5, deg_to_rad(90.0))
	var shooter: ShipEntity = world.ships[0]
	shooter.target_id = world.ships[1].id

	# Long enough for the mounts to train round and settle.
	TestShips.run_seconds(world, 90.0)
	var laid: int = 0
	for turret: Turret in shooter.main_battery_turrets():
		if turret.has_orders:
			laid += 1
			gt(absf(turret.bearing), deg_to_rad(45.0), "%s is trained out on the beam" % turret.mount.mount_id)
	eq(laid, 3, "all three main turrets are laid on the target")


func test_losing_the_target_stands_the_battery_down() -> void:
	var world: SimWorld = _engagement(20000.0, 20.0, PI * 0.5, deg_to_rad(90.0))
	var shooter: ShipEntity = world.ships[0]
	shooter.target_id = world.ships[1].id
	TestShips.run_seconds(world, 60.0)

	world.ships[1].status = ShipEntity.Status.DESTROYED
	TestShips.run_seconds(world, 120.0)
	for turret: Turret in shooter.main_battery_turrets():
		not_ok(turret.has_orders, "%s has no orders" % turret.mount.mount_id)
		almost(turret.train_offset, 0.0, deg_to_rad(2.0),
			"%s has returned fore and aft" % turret.mount.mount_id)


func test_gunnery_is_deterministic() -> void:
	var checksums: Array[int] = []
	for _run: int in 2:
		var world: SimWorld = _engagement(24000.0, 28.0, PI * 0.6, deg_to_rad(40.0))
		world.ships[0].target_id = world.ships[1].id
		TestShips.run_seconds(world, 200.0)
		checksums.append(world.checksum())
	eq(checksums[0], checksums[1], "turret state is part of the reproducible simulation")
