extends SimTest

## Gunnery direction that can be WRONG.
##
## The claim these tests defend is that hit rates at long range are set by the quality
## of the ship's firing solution and not by the dispersion of her guns. Everything below
## is an assertion about the plot rather than about hits, because the plot is where the
## physics is; the hit rate is only its consequence.


func suite_name() -> String:
	return "Fire control quality"


func _config() -> Dictionary:
	return JsonLoader.load_dict("res://data/config/fire_control.json")


func _iowa_pair(seed_value: int = 7, range_m: float = 18000.0) -> Array:
	var world: SimWorld = TestShips.armed_world(seed_value)
	var shooter: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var target: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, range_m), 0.0, 1)
	MovementSystem.set_steady_speed(shooter, SimUnits.knots_to_ms(25.0))
	MovementSystem.set_steady_speed(target, SimUnits.knots_to_ms(25.0))
	shooter.target_id = target.id
	return [world, shooter, target]


func test_the_first_salvo_is_aimed_wrong() -> void:
	# The whole point of the stage. Before it, the solution was computed from the
	# target's exact position and velocity, so the only error left in the system was
	# the dispersion of the guns — about 55 m at 18 km against a target 33 m wide, and
	# hence three times the historical hit rate.
	#
	# Note WHERE the error is. With 1943 radar the plot's estimate of where the target
	# is standing is good to a few tens of metres; what it does not know is her course
	# and speed, and what the range table does not know is the atmosphere the shell has
	# to fly through. Those are what put the first salvo hundreds of metres out.
	var parts: Array = _iowa_pair()
	var world: SimWorld = parts[0]
	var shooter: ShipEntity = parts[1]
	var target: ShipEntity = parts[2]
	var turret: Turret = shooter.main_battery_turrets()[0]
	var table: RangeTable = world.armory.range_table(turret.gun.gun_id, turret.selected_shell)
	var fit: FireControlSolution.Fit = FireControlSolution.fit_for(shooter.spec, _config())

	var total: float = 0.0
	var position_error: float = 0.0
	for i: int in 60:
		var plot: FireControlSolution = FireControlSolution.new()
		plot.open(shooter, target, fit, _config(), world.rng.stream("opening_%d" % i))
		total += FireControlSystem.solve(
			shooter, turret, target, table, plot).solution_error_m
		position_error += plot.estimated_target_position(
			shooter.position, target).distance_to(target.position)

	var mean_aim: float = total / 60.0
	var mean_position: float = position_error / 60.0
	gt(mean_aim, 150.0,
		"an opening salvo at 18 km should be badly aimed (%.0f m)" % mean_aim)
	gt(mean_aim, mean_position * 3.0,
		"the aim should be far worse than the plot's idea of where she is standing "
		+ "(%.0f m aimed vs %.0f m positional) — the lead and the ballistics are the "
		% [mean_aim, mean_position] + "hard part, not the rangefinder")


func test_the_plot_learns_the_targets_course_while_she_holds_it() -> void:
	var parts: Array = _iowa_pair()
	var world: SimWorld = parts[0]
	var shooter: ShipEntity = parts[1]
	var target: ShipEntity = parts[2]
	var fit: FireControlSolution.Fit = FireControlSolution.fit_for(shooter.spec, _config())
	var plot: FireControlSolution = FireControlSolution.new()
	var rng: DeterministicRng = world.rng.stream("course")
	plot.open(shooter, target, fit, _config(), rng)

	var opening: float = absf(SimUnits.angle_delta(plot.course_estimate, target.heading))
	for _i: int in 600:
		plot.track(shooter, target, fit, _config(), 0.5, 2.0, rng)
	var settled: float = absf(SimUnits.angle_delta(plot.course_estimate, target.heading))

	gt(opening, 0.0, "the opening estimate of the target's course should be wrong")
	lt(settled, opening * 0.35,
		"tracking a steady target should converge the course estimate (%.3f -> %.3f rad)" % [
			opening, settled])


func test_a_target_that_turns_invalidates_the_plot() -> void:
	# Nothing in the model says "evasion". The plot integrates a range rate derived from
	# the course it believes the target is on, so a ship that leaves that course makes
	# the plot wrong at a rate proportional to how wrong the course is. This is what
	# makes a manoeuvring target hard, and it is not a rule.
	var parts: Array = _iowa_pair()
	var world: SimWorld = parts[0]
	var shooter: ShipEntity = parts[1]
	var target: ShipEntity = parts[2]
	var fit: FireControlSolution.Fit = FireControlSolution.fit_for(shooter.spec, _config())
	var config: Dictionary = _config()

	var plot: FireControlSolution = FireControlSolution.new()
	var rng: DeterministicRng = world.rng.stream("turn")
	plot.open(shooter, target, fit, config, rng)
	for _i: int in 400:
		plot.track(shooter, target, fit, config, 0.5, 2.0, rng)
	var settled: float = absf(plot.range_error_m)

	# She turns ninety degrees and steadies on the new course.
	target.heading = deg_to_rad(90.0)
	var after_turn: float = 0.0
	for _i: int in 40:
		plot.track(shooter, target, fit, config, 0.5, 2.0, rng)
		after_turn = maxf(after_turn, absf(plot.range_error_m))

	gt(after_turn, settled + 20.0,
		"a target that turns should throw the plot out (%.0f m settled, %.0f m after)" % [
			settled, after_turn])


func test_spotting_the_fall_of_shot_corrects_the_plot() -> void:
	# The ladder: open fire, miss, spot the fall of shot, correct, straddle. It is why
	# sustained fire is so much more dangerous than opening fire.
	var parts: Array = _iowa_pair()
	var world: SimWorld = parts[0]
	var shooter: ShipEntity = parts[1]
	var target: ShipEntity = parts[2]
	var fit: FireControlSolution.Fit = FireControlSolution.fit_for(shooter.spec, _config())
	var config: Dictionary = _config()
	var rng: DeterministicRng = world.rng.stream("spot")

	var plot: FireControlSolution = FireControlSolution.new()
	plot.open(shooter, target, fit, config, rng)
	# A standing error of four hundred metres over, and a ship that can see it.
	plot.range_error_m = 400.0
	var opening: float = absf(plot.range_error_m + plot.spot_correction_m)

	for _salvo: int in 8:
		var error: float = plot.range_error_m + plot.spot_correction_m
		plot.observe_fall(error, 18000.0)
		for _cycle: int in 12:
			plot.track(shooter, target, fit, config, 0.1, 2.0, rng)
	var corrected: float = absf(plot.range_error_m + plot.spot_correction_m)

	lt(corrected, opening * 0.5,
		"eight spotted salvos should more than halve the standing error (%.0f -> %.0f m)" % [
			opening, corrected])
	ge(float(plot.salvos_spotted), 6.0, "each salvo should be corrected for once, not once per shell")


func test_radar_beats_the_rangefinder_at_long_range_and_not_at_short() -> void:
	# The whole story of gunnery from 1942 onwards, and it falls straight out of the
	# geometry: optical error grows with the SQUARE of the range because a rangefinder
	# measures a parallax angle, while radar error is flat.
	var config: Dictionary = _config()
	var optical: FireControlSolution.Fit = FireControlSolution.Fit.new()
	optical.rangefinder_base_m = 10.0
	var radar: FireControlSolution.Fit = FireControlSolution.Fit.new()
	radar.rangefinder_base_m = 10.0
	radar.radar_range_sigma_m = 18.0
	radar.radar_max_range_m = 36000.0
	radar.radar_blind_range_m = 700.0

	var short_optical: float = FireControlSolution.measurement_range_sigma(4000.0, optical, config)
	var short_radar: float = FireControlSolution.measurement_range_sigma(4000.0, radar, config)
	var long_optical: float = FireControlSolution.measurement_range_sigma(24000.0, optical, config)
	var long_radar: float = FireControlSolution.measurement_range_sigma(24000.0, radar, config)

	lt(long_radar, long_optical * 0.25,
		"at 24 km radar should be far better than a 10 m rangefinder (%.0f vs %.0f m)" % [
			long_radar, long_optical])
	lt(short_optical, long_optical * 0.2,
		"optical error should grow with the square of the range (%.0f m at 4 km, %.0f at 24)" % [
			short_optical, long_optical])
	le(short_radar, short_optical + 1.0, "radar should be no worse than optics up close")


func test_a_longer_rangefinder_is_a_better_rangefinder() -> void:
	var config: Dictionary = _config()
	var destroyer: FireControlSolution.Fit = FireControlSolution.Fit.new()
	destroyer.rangefinder_base_m = 3.0
	var battleship: FireControlSolution.Fit = FireControlSolution.Fit.new()
	battleship.rangefinder_base_m = 15.0

	var poor: float = FireControlSolution.measurement_range_sigma(20000.0, destroyer, config)
	var good: float = FireControlSolution.measurement_range_sigma(20000.0, battleship, config)
	almost(poor / good, 5.0, 0.2,
		"error should scale inversely with base length (%.0f m vs %.0f m)" % [poor, good])


func test_a_laying_error_costs_more_at_short_range_than_at_long() -> void:
	# The reason pointing error is stored as an ANGLE rather than as a fraction of
	# range. On the flat early part of the trajectory a gun's elevation buys range
	# fast, so the same director wander throws a shell FURTHER off at ten kilometres
	# than at twenty-five — the opposite of what a percentage-of-range error would say.
	var table: RangeTable = TestWeapons.range_table("usa_16in50_mk7", "usa_16in50_ap_mk8")
	ok(table != null, "the Iowa's range table should load")
	var near: float = table.range_gradient(8000.0)
	var far: float = table.range_gradient(24000.0)
	gt(near, far, "dR/d(elevation) should fall with range (%.0f vs %.0f m/rad)" % [near, far])
	gt(near * 0.001, 60.0, "a thousandth of a radian should be worth over 60 m at 8 km")


func test_checking_fire_loses_the_solution() -> void:
	# A plot that took three minutes and four salvos to build is thrown away when the
	# guns are shifted, which is why ships held on to a target they were solving for
	# even when a better one appeared. The AI's targeting hysteresis exists for this.
	var parts: Array = _iowa_pair()
	var world: SimWorld = parts[0]
	var shooter: ShipEntity = parts[1]
	world.step_many(240)
	var plot: FireControlSolution = shooter.main_plot()
	ok(plot != null and plot.opened, "she should have a plot open on her target")

	shooter.target_id = 0
	world.step_many(30)
	not_ok(shooter.main_plot().opened, "checking fire should shut the plot")


func test_each_battery_keeps_its_own_plot() -> void:
	# A main battery director and a secondary director were separate installations
	# solving separate problems. Sharing one plot would let a five-inch splash correct
	# a sixteen-inch solution, which would ruin both.
	var parts: Array = _iowa_pair(11, 9000.0)
	var world: SimWorld = parts[0]
	var shooter: ShipEntity = parts[1]
	world.step_many(600)

	ge(float(shooter.fire_control.size()), 2.0,
		"a ship with a main and a secondary battery should keep two plots")
	var main: FireControlSolution = shooter.main_plot()
	var secondary: FireControlSolution = shooter.plot_for(&"secondary")
	ok(main != null and secondary != null, "both plots should exist")
	ne(main.ballistic_bias, secondary.ballistic_bias,
		"the two directors should not share one ballistic error")


func test_a_shell_carries_its_ships_motion_and_the_solution_allows_for_it() -> void:
	# A shell leaves a ship making twenty knots already carrying those twenty knots, and
	# over half a minute of flight that is nearly four hundred metres — as large as every
	# other error in the system put together. Real fire control compensated for own-ship
	# motion, and the compensation and the inherited velocity very nearly cancel.
	#
	# Modelled with PERFECT information (no fire-control config, so no plot), because
	# what is being checked is the geometry of the intercept and not the quality of the
	# solution. If the two halves ever stop agreeing, the salvo walks off to one side by
	# the shooter's own speed times the time of flight, and it does it silently.
	var config: Dictionary = TestShips.config()
	config.erase("fire_control")
	var world: SimWorld = SimWorld.create(4242, config)
	world.set_armory(TestWeapons.armory())

	# The shooter steams hard ACROSS the line of fire, where own-ship motion turns into
	# pure deflection error and nothing else can hide it.
	var shooter: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var target: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, 18000.0), 0.0, 1)
	MovementSystem.set_steady_speed(shooter, SimUnits.knots_to_ms(28.0))
	shooter.target_id = target.id

	var across_total: float = 0.0
	var splashes: int = 0
	for _i: int in 60 * 200:
		world.step()
		for event: SimEvent in world.events.events_this_tick():
			if event.type != &"shell_splash" or event.actor_id != shooter.id:
				continue
			if float(event.data.get("calibreMm", 0.0)) < 200.0:
				continue
			var at: Vector2 = Serializer.array_to_vec2(event.data.get("position"))
			across_total += (at - target.position).x   # +x is the shooter's own course
			splashes += 1
		if not target.is_afloat():
			break

	gt(float(splashes), 8.0, "she should get enough salvos away to measure")
	var drift: float = absf(across_total / float(splashes))
	# Uncompensated, the pattern would sit a full 28 knots times the time of flight off
	# to one side — better than 400 m at this range.
	lt(drift, 120.0,
		"the pattern should be centred on the target across the line of fire, not "
		+ "carried off by the shooter's own speed (%.0f m mean offset)" % drift)


func test_the_guns_are_laid_where_the_plot_says_and_not_at_the_target() -> void:
	var parts: Array = _iowa_pair(3, 20000.0)
	var world: SimWorld = parts[0]
	var shooter: ShipEntity = parts[1]
	var target: ShipEntity = parts[2]
	world.step_many(120)

	var plot: FireControlSolution = shooter.main_plot()
	ok(plot != null, "she should have opened a plot")
	var turret: Turret = shooter.main_battery_turrets()[0]
	var table: RangeTable = world.armory.range_table(turret.gun.gun_id, turret.selected_shell)
	var solution: FireControlSystem.Solution = FireControlSystem.solve(
		shooter, turret, target, table, plot)
	ok(solution.valid, "the solution should be valid at 20 km")
	gt(solution.solution_error_m, 1.0,
		"the aim point should miss the target — it is built from the plot, not the truth")

	var perfect: FireControlSystem.Solution = FireControlSystem.solve(
		shooter, turret, target, table, null)
	lt(perfect.solution_error_m, solution.solution_error_m,
		"a null plot means perfect information, and should aim closer")
