extends SimTest

## Ship motion, checked against the ships it is modelling.
##
## The point of the physics model is that behaviour comes out of mass, power and
## dimensions rather than a per-class table. These tests are how that claim is kept
## honest: an Iowa must accelerate like a 57,000-tonne ship because it is one, not
## because a "battleship" branch made it sluggish.

const FULL_AHEAD: float = 1.0


func suite_name() -> String:
	return "MovementSystem"


func _ship(world: SimWorld) -> ShipEntity:
	return world.ships[0]


# ------------------------------------------------------------------ surge --

func test_a_ship_accelerates_to_its_design_speed_and_settles_there() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.iowa())
	var iowa: ShipEntity = _ship(world)
	iowa.throttle = FULL_AHEAD

	TestShips.run_seconds(world, 400.0)
	almost(iowa.speed_knots(), 33.0, 0.6, "Iowa works up to her design 33 knots")

	# Equilibrium, not overshoot: thrust and resistance balance.
	var settled: float = iowa.speed
	TestShips.run_seconds(world, 200.0)
	almost(iowa.speed, settled, 0.02, "and holds there rather than creeping past it")


func test_acceleration_comes_from_mass_and_power_not_ship_class() -> void:
	# Iowa: 212,000 shp pushing 57,500 tonnes. Fletcher: 60,000 shp pushing 2,500.
	# The destroyer should be roughly six times quicker off the mark, and nothing in
	# the code says "destroyers accelerate faster".
	var bb_world: SimWorld = TestShips.world_with(TestShips.iowa())
	var dd_world: SimWorld = TestShips.world_with(TestShips.fletcher())
	_ship(bb_world).throttle = FULL_AHEAD
	_ship(dd_world).throttle = FULL_AHEAD

	TestShips.run_seconds(bb_world, 10.0)
	TestShips.run_seconds(dd_world, 10.0)

	var ratio: float = _ship(dd_world).speed / maxf(_ship(bb_world).speed, 0.001)
	between(ratio, 4.5, 7.5, "destroyer out-accelerates the battleship by roughly 6x")


func test_a_battleship_takes_minutes_to_reach_full_speed() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.iowa())
	var iowa: ShipEntity = _ship(world)
	iowa.throttle = FULL_AHEAD
	var target: float = 0.9 * iowa.spec.max_speed_ms

	var elapsed: float = 0.0
	while elapsed < 400.0 and iowa.speed < target:
		world.step()
		elapsed += world.clock.dt
	between(elapsed, 80.0, 180.0, "about two minutes to 90% of full speed")


func test_a_destroyer_reaches_full_speed_in_well_under_a_minute() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	var target: float = 0.9 * dd.spec.max_speed_ms

	var elapsed: float = 0.0
	while elapsed < 200.0 and dd.speed < target:
		world.step()
		elapsed += world.clock.dt
	between(elapsed, 12.0, 45.0, "well under a minute to 90% of full speed")


func test_a_ship_coasts_to_a_stop_when_the_throttle_comes_off() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 120.0)
	gt(dd.speed_knots(), 30.0, "up to speed first")

	dd.throttle = 0.0
	TestShips.run_seconds(world, 300.0)
	lt(dd.speed_knots(), 3.0, "resistance alone brings her nearly to a stop")
	ge(dd.speed, 0.0, "and never reverses through zero")


func test_astern_power_is_a_fraction_of_ahead_power() -> void:
	# Reversing turbines deliver far less than the ahead plant, so a ship backs down
	# much more slowly than she runs.
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = -1.0
	TestShips.run_seconds(world, 300.0)
	lt(dd.speed, 0.0, "making sternway")
	var astern_speed: float = absf(dd.speed_knots())
	# Slightly under the stated 30% ceiling because at these low speeds the screws
	# are bollard-limited rather than power-limited, which is correct behaviour.
	between(astern_speed, 9.0, 11.2, "roughly 10 knots astern against 36.5 ahead")


func test_losing_power_costs_speed_by_the_cube_root_law() -> void:
	# Resistance grows with the cube of speed, so top speed scales with the cube root
	# of power. Half the plant is about 79% of the speed — which is why a battleship
	# down two shafts is still a fast ship.
	var world: SimWorld = TestShips.world_with(TestShips.iowa())
	var iowa: ShipEntity = _ship(world)
	iowa.propulsion_fraction = 0.5
	iowa.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 500.0)
	almost(iowa.speed_knots(), 33.0 * pow(0.5, 1.0 / 3.0), 0.6, "half power, about 26 knots")


func test_total_propulsion_loss_leaves_a_ship_dead_in_the_water() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 120.0)

	dd.propulsion_fraction = 0.0
	not_ok(dd.can_manoeuvre(), "reported as unable to manoeuvre")
	TestShips.run_seconds(world, 600.0)
	lt(absf(dd.speed_knots()), 1.0, "drifts to a halt")


# ------------------------------------------------------------------- yaw --

func test_steady_turning_radius_matches_the_ships_tactical_diameter() -> void:
	# In a steady turn the yaw rate is speed / turning radius, so the radius the ship
	# actually achieves should equal the figure in her data regardless of how fast
	# she happens to be going.
	for spec: ShipSpec in [TestShips.iowa(), TestShips.fletcher()]:
		var world: SimWorld = TestShips.world_with(spec)
		var ship: ShipEntity = _ship(world)
		ship.throttle = FULL_AHEAD
		TestShips.run_seconds(world, 300.0)
		MovementSystem.order_rudder(ship, 1.0)
		TestShips.run_seconds(world, 200.0)

		var achieved_radius: float = absf(ship.speed) / maxf(absf(ship.yaw_rate), 1e-6)
		almost(achieved_radius, spec.turning_radius_m(), spec.turning_radius_m() * 0.05,
			"%s turns at her stated tactical diameter" % spec.display_name)


func test_a_destroyer_turns_inside_a_battleship() -> void:
	var bb: ShipSpec = TestShips.iowa()
	var dd: ShipSpec = TestShips.fletcher()
	lt(dd.turning_radius_m(), bb.turning_radius_m() * 0.6,
		"a 115 m destroyer turns in far less water than a 270 m battleship")


func test_a_full_circle_takes_a_battleship_several_minutes() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.iowa())
	var iowa: ShipEntity = _ship(world)
	iowa.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 300.0)
	MovementSystem.order_rudder(iowa, 1.0)
	TestShips.run_seconds(world, 60.0)

	var turned: float = 0.0
	var previous: float = iowa.heading
	var elapsed: float = 0.0
	while turned < TAU and elapsed < 900.0:
		world.step()
		turned += absf(SimUnits.angle_delta(previous, iowa.heading))
		previous = iowa.heading
		elapsed += world.clock.dt
	between(elapsed, 120.0, 400.0, "a 360-degree turn takes minutes, not seconds")


func test_the_turning_path_is_actually_a_circle_of_the_right_size() -> void:
	# The steady-state check above tests the yaw equation; this one tests the
	# integration, by measuring the geometry the ship actually traces out.
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 200.0)
	MovementSystem.order_rudder(dd, 1.0)
	TestShips.run_seconds(world, 120.0)  # settle into the turn

	var start_position: Vector2 = dd.position
	var start_heading: float = dd.heading
	var turned: float = 0.0
	var previous: float = start_heading
	while turned < PI:
		world.step()
		turned += absf(SimUnits.angle_delta(previous, dd.heading))
		previous = dd.heading

	# Half a circle later, the ship is one diameter away from where she started.
	var measured_diameter: float = start_position.distance_to(dd.position)
	var expected: float = dd.spec.turning_radius_m() * 2.0
	almost(measured_diameter, expected, expected * 0.10, "measured turning circle diameter")


func test_a_ship_with_no_way_on_cannot_steer() -> void:
	# Rudders work by deflecting water flowing past them. Stationary, there is none.
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = 0.0
	MovementSystem.order_rudder(dd, 1.0)
	var heading_before: float = dd.heading
	TestShips.run_seconds(world, 120.0)
	almost(dd.heading, heading_before, 0.001, "hard rudder does nothing without steerage way")


func test_speed_is_lost_in_a_hard_turn() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 200.0)
	var straight_speed: float = dd.speed

	MovementSystem.order_rudder(dd, 1.0)
	TestShips.run_seconds(world, 200.0)
	# data/config/physics.json calls for a 35% speed loss at full rudder.
	almost(dd.speed / straight_speed, 0.65, 0.04, "loses about a third of her speed")


# ----------------------------------------------------------------- rudder --

func test_the_rudder_takes_time_to_go_hard_over() -> void:
	# Iowa's rudder swings at about 2.5 deg/s, so 35 degrees takes some 14 seconds.
	# Ordering hard-a-starboard is not the same as having it there.
	var world: SimWorld = TestShips.world_with(TestShips.iowa())
	var iowa: ShipEntity = _ship(world)
	MovementSystem.order_rudder(iowa, 1.0)

	TestShips.run_seconds(world, 2.0)
	lt(rad_to_deg(iowa.rudder_angle), 10.0, "barely started after two seconds")
	TestShips.run_seconds(world, 20.0)
	almost(rad_to_deg(iowa.rudder_angle), 35.0, 0.5, "hard over after about fourteen")


func test_a_destroyer_rudder_swings_faster_than_a_battleships() -> void:
	var bb_world: SimWorld = TestShips.world_with(TestShips.iowa())
	var dd_world: SimWorld = TestShips.world_with(TestShips.fletcher())
	MovementSystem.order_rudder(_ship(bb_world), 1.0)
	MovementSystem.order_rudder(_ship(dd_world), 1.0)
	TestShips.run_seconds(bb_world, 6.0)
	TestShips.run_seconds(dd_world, 6.0)
	gt(_ship(dd_world).rudder_angle, _ship(bb_world).rudder_angle * 1.5,
		"the smaller ship's steering gear is quicker")


func test_a_jammed_rudder_stays_where_it_was() -> void:
	# A wrecked steering gear leaves the ship circling — the way more than one real
	# action was decided.
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 120.0)
	MovementSystem.order_rudder(dd, 1.0)
	TestShips.run_seconds(world, 30.0)

	dd.rudder_jammed = true
	var jammed_at: float = dd.rudder_angle
	MovementSystem.order_rudder(dd, 0.0)  # frantic attempt to straighten up
	TestShips.run_seconds(world, 60.0)
	almost(dd.rudder_angle, jammed_at, 0.0001, "the rudder does not answer")
	gt(absf(dd.yaw_rate), 0.001, "and the ship keeps turning")


func test_reduced_rudder_effectiveness_widens_the_turn() -> void:
	var healthy: SimWorld = TestShips.world_with(TestShips.fletcher())
	var damaged: SimWorld = TestShips.world_with(TestShips.fletcher())
	_ship(damaged).rudder_effectiveness = 0.4

	for world: SimWorld in [healthy, damaged]:
		_ship(world).throttle = FULL_AHEAD
		TestShips.run_seconds(world, 200.0)
		MovementSystem.order_rudder(_ship(world), 1.0)
		TestShips.run_seconds(world, 200.0)

	lt(absf(_ship(damaged).yaw_rate), absf(_ship(healthy).yaw_rate) * 0.6,
		"damaged steering turns the ship more slowly")


func test_an_unbalanced_shaft_pair_turns_the_ship_on_its_own() -> void:
	# Lose a shaft on one side and the ship crabs off course with the rudder
	# amidships — the helmsman has to hold opposite rudder to steer straight.
	var world: SimWorld = TestShips.world_with(TestShips.iowa())
	var iowa: ShipEntity = _ship(world)
	iowa.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 200.0)
	var heading_before: float = iowa.heading

	iowa.shaft_asymmetry = 0.5
	TestShips.run_seconds(world, 120.0)
	gt(absf(SimUnits.angle_delta(heading_before, iowa.heading)), 0.05,
		"the ship swings although the rudder is amidships")


# ------------------------------------------------------------------ orders --

func test_ordering_a_speed_reaches_that_speed() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	MovementSystem.order_speed(dd, SimUnits.knots_to_ms(20.0))
	TestShips.run_seconds(world, 300.0)
	almost(dd.speed_knots(), 20.0, 1.0, "settles at the ordered 20 knots")


func test_ordering_half_speed_takes_an_eighth_of_the_power() -> void:
	# Speed goes as the cube root of power, so the inverse is a cube. This is the
	# relationship that makes economical cruising speeds worth having.
	var dd: ShipEntity = _ship(TestShips.world_with(TestShips.fletcher()))
	MovementSystem.order_speed(dd, dd.effective_max_speed() * 0.5)
	almost(dd.throttle, 0.125, 0.001, "half speed is one eighth throttle")
	MovementSystem.order_speed(dd, dd.effective_max_speed())
	almost(dd.throttle, 1.0, 0.001, "full speed is full power")


func test_ordering_sternway_backs_the_ship_at_the_ordered_speed() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	var ordered: float = -SimUnits.knots_to_ms(6.0)
	MovementSystem.order_speed(dd, ordered)
	TestShips.run_seconds(world, 400.0)
	almost(dd.speed_knots(), -6.0, 1.0, "settles at the ordered sternway")


func test_ordering_more_speed_than_the_ship_has_left_means_everything_she_has() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.propulsion_fraction = 0.25
	MovementSystem.order_speed(dd, SimUnits.knots_to_ms(36.5))
	almost(dd.throttle, 1.0, 0.001, "the order becomes full ahead rather than an error")
	TestShips.run_seconds(world, 400.0)
	almost(dd.speed_knots(), 36.5 * pow(0.25, 1.0 / 3.0), 0.8, "makes what she can")


func test_steering_to_a_heading_converges_without_oscillating() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 120.0)

	var target: float = deg_to_rad(90.0)
	for _i: int in 12000:
		MovementSystem.steer_to_heading(dd, target)
		world.step()

	almost(SimUnits.angle_delta(dd.heading, target), 0.0, deg_to_rad(2.0), "settles on course")
	lt(absf(dd.yaw_rate), 0.01, "and stops swinging rather than hunting either side of it")


func test_steering_to_a_point_turns_the_ship_towards_it() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 120.0)

	var waypoint: Vector2 = Vector2(0.0, 20000.0)
	for _i: int in 12000:
		MovementSystem.steer_to_point(dd, waypoint)
		world.step()
	lt(dd.position.distance_to(waypoint), 18000.0, "closing the waypoint")
	almost(SimUnits.angle_delta(dd.heading, (waypoint - dd.position).angle()), 0.0,
		deg_to_rad(5.0), "pointed at it")


func test_a_destroyed_ship_stops_being_integrated() -> void:
	var world: SimWorld = TestShips.world_with(TestShips.fletcher())
	var dd: ShipEntity = _ship(world)
	dd.throttle = FULL_AHEAD
	TestShips.run_seconds(world, 120.0)

	dd.status = ShipEntity.Status.DESTROYED
	var resting_place: Vector2 = dd.position
	TestShips.run_seconds(world, 60.0)
	eq(dd.position, resting_place, "a sunk ship does not keep steaming")
