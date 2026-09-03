extends SimTest

## Exterior ballistics, checked against published naval range tables.
##
## This is the most consequential suite in the project. Everything the armour model
## does depends on two numbers the trajectory produces — the velocity a shell is
## still carrying when it arrives, and the angle it is falling at. If those are
## wrong, a penetration model of any sophistication is being fed fiction.
##
## The reference figures are from published range tables, not from this
## implementation, so these tests can fail by the model being wrong rather than
## merely by it changing.


func suite_name() -> String:
	return "Ballistics"


# ------------------------------------------------------------- atmosphere --

func test_atmosphere_thins_with_altitude() -> void:
	var air: Atmosphere = Atmosphere.from_config(TestWeapons.config())
	almost(air.density_at(0.0), 1.225, 0.001, "sea level density")
	almost(air.density_at(5000.0), 0.7364, 0.001, "5 km density")
	lt(air.density_at(10000.0), air.density_at(0.0) * 0.4, "a third as thick at 10 km")
	almost(air.speed_of_sound_at(0.0), 340.3, 0.1, "sea level speed of sound")
	lt(air.speed_of_sound_at(10000.0), air.speed_of_sound_at(0.0), "colder and slower aloft")


func test_atmosphere_interpolates_and_clamps() -> void:
	var air: Atmosphere = Atmosphere.from_config(TestWeapons.config())
	var midpoint: float = air.density_at(500.0)
	between(midpoint, 1.1117, 1.2250, "interpolated between the tabulated points")
	eq(air.density_at(-100.0), air.density_at(0.0), "below sea level clamps")
	eq(air.density_at(99999.0), air.density_at(20000.0), "above the table clamps")


func test_drag_rises_through_the_sound_barrier() -> void:
	# The transonic rise is the defining feature of the curve: drag roughly doubles
	# through Mach 1 and falls away again supersonically.
	var drag: DragModel = DragModel.from_config(TestWeapons.config())
	var subsonic: float = drag.coefficient_at(0.6)
	var transonic: float = drag.coefficient_at(1.05)
	var supersonic: float = drag.coefficient_at(2.5)
	gt(transonic, subsonic * 1.8, "drag roughly doubles through Mach 1")
	lt(supersonic, transonic, "and falls away again above it")
	gt(supersonic, subsonic, "though never back to the subsonic value")


# -------------------------------------------------- published range tables --

func test_maximum_ranges_match_the_published_figures() -> void:
	# gun, shell, max elevation, published maximum range (m)
	var cases: Array = [
		["usa_16in50_mk7", "usa_16in50_ap_mk8", 45.0, 38720.0],
		["jpn_46cm45_t94", "jpn_46cm45_ap_t91", 45.0, 42026.0],
		["ger_38cm52_skc34", "ger_38cm52_ap", 30.0, 35550.0],
		["uk_14in45_mk7", "uk_14in45_ap_mk7", 40.0, 35260.0],
		["usa_8in55_mk15", "usa_8in55_ap_mk21", 41.0, 27480.0],
		["usa_5in38_mk12", "usa_5in38_aac_mk34", 45.0, 16640.0],
	]
	for entry: Array in cases:
		var flight: BallisticSolver.TrajectoryResult = TestWeapons.fire(
			entry[0] as String, entry[1] as String, entry[2] as float)
		ok(flight.valid, "%s produced a trajectory" % entry[0])
		var expected: float = entry[3] as float
		# 2% covers the difference between this model and a real range table, which
		# also folds in drift, Coriolis and non-standard atmosphere corrections.
		almost(flight.range_m(), expected, expected * 0.02,
			"%s reaches its published maximum range" % entry[0])


func test_iowa_impact_conditions_match_her_range_table() -> void:
	# USS Iowa, 16"/50 Mark 7 firing AP Mark 8. Range, published striking velocity
	# (m/s) and published descent angle (degrees).
	var reference: Array = [
		[18288.0, 510.0, 15.0],
		[27432.0, 464.0, 29.9],
		[36576.0, 473.0, 45.2],
	]
	var table: RangeTable = TestWeapons.range_table("usa_16in50_mk7", "usa_16in50_ap_mk8")
	for entry: Array in reference:
		var solution: RangeTable.FiringSolution = table.solve_for_range(entry[0] as float)
		ok(solution.valid, "solution exists at %.0f m" % entry[0])
		if not solution.valid:
			continue
		var expected_velocity: float = entry[1] as float
		almost(solution.striking_velocity, expected_velocity, expected_velocity * 0.05,
			"striking velocity at %.0f m" % entry[0])
		almost(rad_to_deg(solution.descent_angle), entry[2] as float, 3.0,
			"descent angle at %.0f m" % entry[0])


func test_bismarck_impact_conditions_match_her_range_table() -> void:
	# A second gun, so the drag curve is shown to generalise rather than having been
	# fitted to one weapon.
	var reference: Array = [
		[10000.0, 631.0, 5.2],
		[20000.0, 519.0, 14.5],
		[30000.0, 452.0, 31.4],
	]
	var table: RangeTable = TestWeapons.range_table("ger_38cm52_skc34", "ger_38cm52_ap")
	for entry: Array in reference:
		var solution: RangeTable.FiringSolution = table.solve_for_range(entry[0] as float)
		ok(solution.valid, "solution exists at %.0f m" % entry[0])
		if not solution.valid:
			continue
		var expected_velocity: float = entry[1] as float
		almost(solution.striking_velocity, expected_velocity, expected_velocity * 0.05,
			"striking velocity at %.0f m" % entry[0])
		almost(rad_to_deg(solution.descent_angle), entry[2] as float, 3.0,
			"descent angle at %.0f m" % entry[0])


# --------------------------------------------------------- trajectory shape --

func test_fire_plunges_more_steeply_with_range() -> void:
	# The single most important consequence of modelling flight in three dimensions:
	# at short range a shell arrives almost flat and strikes the belt, and at long
	# range it falls onto the deck.
	var table: RangeTable = TestWeapons.range_table("usa_16in50_mk7", "usa_16in50_ap_mk8")
	var previous: float = -1.0
	for range_m: float in [10000.0, 15000.0, 20000.0, 25000.0, 30000.0, 35000.0]:
		var solution: RangeTable.FiringSolution = table.solve_for_range(range_m)
		gt(solution.descent_angle, previous, "descent angle keeps increasing at %.0f m" % range_m)
		previous = solution.descent_angle
	lt(rad_to_deg(table.solve_for_range(10000.0).descent_angle), 8.0, "nearly flat at 10 km")
	gt(rad_to_deg(table.solve_for_range(35000.0).descent_angle), 35.0, "plunging at 35 km")


func test_shells_shed_most_of_their_velocity_but_not_all_of_it() -> void:
	var table: RangeTable = TestWeapons.range_table("usa_16in50_mk7", "usa_16in50_ap_mk8")
	var muzzle: float = TestWeapons.shell("usa_16in50_ap_mk8").muzzle_velocity_ms
	var far: RangeTable.FiringSolution = table.solve_for_range(30000.0)
	lt(far.striking_velocity, muzzle * 0.72, "well down on muzzle velocity at 30 km")
	gt(far.striking_velocity, muzzle * 0.5, "but still carrying enough to matter")


func test_long_shots_climb_high_and_take_a_long_time() -> void:
	var table: RangeTable = TestWeapons.range_table("usa_16in50_mk7", "usa_16in50_ap_mk8")
	var far: RangeTable.FiringSolution = table.solve_for_range(35000.0)
	gt(far.time_of_flight, 60.0, "over a minute in the air")
	lt(far.time_of_flight, 110.0, "but not absurdly long")
	gt(far.apex_altitude, 5000.0, "reaching thin air, which is why altitude is modelled")


func test_a_heavier_shell_carries_better_than_a_light_one() -> void:
	# Sectional density is the classic measure of how well a projectile holds its
	# velocity. The 2,700 lb AP shell should beat the lighter high-capacity shell at
	# long range despite starting slower.
	var ap: ShellDef = TestWeapons.shell("usa_16in50_ap_mk8")
	var he: ShellDef = TestWeapons.shell("usa_16in50_he_mk13")
	gt(ap.sectional_density(), he.sectional_density(), "AP is denser for its calibre")
	lt(ap.muzzle_velocity_ms, he.muzzle_velocity_ms, "and starts slower")

	var ap_far: RangeTable.FiringSolution = TestWeapons.range_table(
		"usa_16in50_mk7", "usa_16in50_ap_mk8").solve_for_range(30000.0)
	var he_far: RangeTable.FiringSolution = TestWeapons.range_table(
		"usa_16in50_mk7", "usa_16in50_he_mk13").solve_for_range(30000.0)
	gt(ap_far.striking_velocity, he_far.striking_velocity,
		"yet arrives faster at 30 km, because it carries its velocity better")


# ------------------------------------------------------------- range table --

func test_range_increases_with_elevation_up_to_the_maximum() -> void:
	var table: RangeTable = TestWeapons.range_table("usa_16in50_mk7", "usa_16in50_ap_mk8")
	gt(float(table.entries.size()), 50.0, "table has real resolution")
	var previous: float = -1.0
	for entry: RangeTable.Entry in table.entries:
		if entry.range_m < table.maximum_range():
			gt(entry.range_m, previous, "range rises monotonically on the low-angle branch")
		previous = entry.range_m


func test_the_solution_for_a_range_actually_reaches_that_range() -> void:
	# Round trip: ask the table for an elevation, fire at it, and see where it lands.
	# This is what catches an interpolation or branch-selection error.
	var table: RangeTable = TestWeapons.range_table("usa_16in50_mk7", "usa_16in50_ap_mk8")
	for target: float in [8000.0, 15000.0, 22000.0, 30000.0, 36000.0]:
		var solution: RangeTable.FiringSolution = table.solve_for_range(target)
		ok(solution.valid, "solution at %.0f m" % target)
		var flight: BallisticSolver.TrajectoryResult = TestWeapons.fire(
			"usa_16in50_mk7", "usa_16in50_ap_mk8", rad_to_deg(solution.elevation))
		almost(flight.range_m(), target, maxf(target * 0.005, 25.0),
			"firing the solved elevation lands at %.0f m" % target)


func test_out_of_range_is_reported_not_guessed() -> void:
	var table: RangeTable = TestWeapons.range_table("usa_5in38_mk12", "usa_5in38_aac_mk34")
	not_ok(table.solve_for_range(50000.0).valid, "a 5-inch gun cannot reach 50 km")
	ok(table.solve_for_range(10000.0).valid, "but 10 km is well within it")


func test_elevation_limits_cap_range_independently_of_velocity() -> void:
	# Bismarck's guns had the highest muzzle velocity of any battleship in this data
	# set and still could not out-range the Iowas, because her turrets stopped at 30
	# degrees. That is a real and decisive constraint, not a balance decision.
	var german: ShellDef = TestWeapons.shell("ger_38cm52_ap")
	var american: ShellDef = TestWeapons.shell("usa_16in50_ap_mk8")
	gt(german.muzzle_velocity_ms, american.muzzle_velocity_ms, "the German gun is faster")

	var german_max: float = TestWeapons.range_table("ger_38cm52_skc34", "ger_38cm52_ap").maximum_range()
	var american_max: float = TestWeapons.range_table("usa_16in50_mk7", "usa_16in50_ap_mk8").maximum_range()
	lt(german_max, american_max, "and still cannot reach as far, because of her elevation limit")


# ---------------------------------------------------------------- integrator --

func test_the_integrator_is_insensitive_to_step_size() -> void:
	# Range tables are built with a quarter-second step and shells in flight use the
	# simulation tick. If those disagreed, a gun would miss by exactly the amount of
	# the discrepancy.
	var shell: ShellDef = TestWeapons.shell("usa_16in50_ap_mk8")
	var coarse: BallisticSolver.TrajectoryResult = TestWeapons.solver().solve_flight_from_height(
		shell.muzzle_velocity_ms, deg_to_rad(30.0), shell.drag_over_mass(), 14.0, 0.25, 400.0)
	var fine: BallisticSolver.TrajectoryResult = TestWeapons.solver().solve_flight_from_height(
		shell.muzzle_velocity_ms, deg_to_rad(30.0), shell.drag_over_mass(), 14.0, 1.0 / 60.0, 400.0)
	almost(coarse.range_m(), fine.range_m(), 5.0, "range agrees to within metres over 33 km")
	almost(coarse.striking_velocity(), fine.striking_velocity(), 0.5, "striking velocity agrees")


func test_trajectories_are_reproducible() -> void:
	var a: BallisticSolver.TrajectoryResult = TestWeapons.fire("usa_16in50_mk7", "usa_16in50_ap_mk8", 25.0)
	var b: BallisticSolver.TrajectoryResult = TestWeapons.fire("usa_16in50_mk7", "usa_16in50_ap_mk8", 25.0)
	eq(a.range_m(), b.range_m(), "identical inputs give a bit-identical range")
	eq(a.time_of_flight, b.time_of_flight, "and time of flight")
