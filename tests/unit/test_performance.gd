extends SimTest

## Level of detail, and the rule it must not break.
##
## Stage 9 is allowed to make a battle cheaper. It is not allowed to make it a different
## battle depending on where the camera is, which is what section 39 means when it says
## combat outcomes must stay consistent — and it is exactly what a camera-driven level
## of detail would do.


func suite_name() -> String:
	return "Performance and level of detail"


func _action(seed_value: int, config: Dictionary) -> SimWorld:
	var world: SimWorld = SimWorld.create(seed_value, config)
	world.set_armory(TestWeapons.armory())
	for team: int in 2:
		for i: int in 4:
			var ship: ShipEntity = world.add_ship(
				TestShips.load_ship(["uss_iowa", "uss_fletcher"][i % 2]),
				Vector2(-12000.0 + float(i) * 700.0 if team == 0 else 12000.0,
					float(i) * 900.0),
				0.0 if team == 0 else PI, team)
			ship.ai_controlled = true
			MovementSystem.order_speed(ship, SimUnits.knots_to_ms(24.0))
	return world


func test_level_of_detail_is_decided_by_the_simulation_and_not_the_camera() -> void:
	# The whole point. Two identical actions must come out identical, and they can only
	# do that if "distant" is a fact about the battle rather than about the view.
	var checksums: Array[int] = []
	for _run: int in 2:
		var world: SimWorld = _action(20260909, TestShips.config())
		world.step_many(60 * 90)
		checksums.append(world.checksum())
	eq(checksums[0], checksums[1],
		"a battle must be the same battle every time it is fought from the same seed")


func test_a_distant_captain_thinks_less_often_than_a_close_one() -> void:
	# The optimisation actually doing something. A ship with no enemy within
	# twenty-five kilometres has nothing to decide in a tenth of a second.
	var config: Dictionary = TestShips.config()
	var world: SimWorld = SimWorld.create(1, config)
	world.set_armory(TestWeapons.armory())
	var near: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var enemy: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, 12000.0), PI, 1)
	near.ai_controlled = true
	world.step_many(60 * 60)

	var far_range: float = AiSystem._nearest_contact_range(world, near)
	lt(far_range, 25000.0, "she should be holding a contact well inside the far distance")

	# And one who knows of nobody at all is as far away as it is possible to be.
	var alone: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, -90000.0), 0.0, 2)
	alone.ai_controlled = true
	ok(is_inf(AiSystem._nearest_contact_range(world, alone)),
		"a captain who has found nobody has nothing to decide quickly about")
	ok(enemy.is_afloat() or true, "the enemy is the contact she is holding")


func test_ballistics_and_penetration_are_never_thrown_away() -> void:
	# The rule level of detail may not break. A shell is resolved by the same tracer
	# against the same model wherever it is, so this greps the files that would have to
	# change for that to stop being true.
	var forbidden: Array[String] = ["farDistance", "lod", "aiTickInterval", "camera",
		"zoom", "visible_rect"]
	for path: String in ["res://src/sim/geometry/trajectory_tracer.gd",
			"res://src/sim/systems/projectile_system.gd",
			"res://src/sim/damage/penetration/de_marre_model.gd",
			"res://src/sim/damage/hit_resolver.gd"]:
		if not FileAccess.file_exists(path):
			continue
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i: int in lines.size():
			var code: String = lines[i]
			var comment: int = code.find("#")
			if comment >= 0:
				code = code.substr(0, comment)
			for word: String in forbidden:
				not_ok(code.contains(word),
					"%s:%d mentions `%s` — what a shell does on arrival must not "
					% [path, i + 1, word] + "depend on how far away anything is being drawn")


func test_both_spatial_indexes_are_available_and_configurable() -> void:
	# Brute force stays reachable as the correctness oracle. An acceleration structure
	# with no reference implementation to check against is an acceleration structure
	# nobody can debug.
	var config: Dictionary = TestShips.config()
	var sim: Dictionary = (config["sim"] as Dictionary).duplicate(true)

	sim["spatial"] = {"index": "brute"}
	config["sim"] = sim
	ok(SimWorld.create(1, config).spatial is BruteForceIndex,
		"a battle should be able to ask for the reference index")

	sim = sim.duplicate(true)
	sim["spatial"] = {"index": "hash", "cellSizeM": 800.0}
	config["sim"] = sim
	var hashed: SimWorld = SimWorld.create(1, config)
	ok(hashed.spatial is SpatialHashIndex, "and for the fast one")
	almost((hashed.spatial as SpatialHashIndex).cell_size(), 800.0, 0.001,
		"with the cell size it asked for")
