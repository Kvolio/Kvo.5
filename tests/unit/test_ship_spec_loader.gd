extends SimTest

## The data layer is the seam the whole project rests on: historical presets and
## player designs must arrive at the simulation as the same kind of object, and the
## numbers a source book gives must survive the trip intact.


func suite_name() -> String:
	return "ShipSpecLoader"


func test_a_historical_preset_loads_with_its_documented_figures() -> void:
	var iowa: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	ok(iowa != null, "Iowa loads")
	if iowa == null:
		return
	eq(iowa.display_name, "USS Iowa", "name")
	eq(iowa.ship_type, "battleship", "type")
	eq(iowa.nation, "USA", "nation")
	eq(iowa.year, 1943, "year")
	almost(iowa.length_m, 270.43, 0.01, "length overall")
	almost(iowa.beam_m, 32.97, 0.01, "beam")
	almost(iowa.displacement_t, 57540.0, 1.0, "full-load displacement is used, not standard")
	eq(iowa.crew, 2788, "crew")


func test_units_are_converted_once_at_load() -> void:
	# Data files are authored in the units their sources use — knots and shaft
	# horsepower. The simulation must only ever see SI.
	var iowa: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	almost(SimUnits.ms_to_knots(iowa.max_speed_ms), 33.0, 0.01, "33 knots became m/s")
	almost(iowa.propulsion_power_w / SimUnits.SHP_TO_W, 212000.0, 1.0, "212,000 shp became watts")
	gt(iowa.propulsion_power_w, 1.0e8, "and it really is in watts, not horsepower")


func test_the_hull_form_is_resolved_and_attached() -> void:
	var iowa: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	eq(iowa.hull_form_id, "battleship", "names its hull form")
	gt(float(iowa.hull_profile.size()), 4.0, "and the profile was loaded from that form")
	between(iowa.hull().waterplane_coefficient(), 0.70, 0.78, "a battleship-shaped waterplane")
	# Geometry alone should land near the displacement the data file states.
	between(iowa.hull().estimated_displacement_tonnes(iowa.vertical_fullness),
		45000.0, 70000.0, "hull volume is consistent with the stated displacement")


func test_manoeuvring_defaults_are_derived_from_size_when_unstated() -> void:
	# Neither ship file gives a yaw response time, so it is scaled from length: a
	# 270 m battleship must not inherit a destroyer's answer to the helm.
	var iowa: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	var fletcher: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_fletcher.json")
	gt(iowa.yaw_response_time_s, fletcher.yaw_response_time_s * 1.8,
		"the larger ship is much slower to answer")
	gt(fletcher.yaw_response_time_s, 3.0, "but nothing is instantaneous")


func test_the_destroyer_differs_from_the_battleship_in_every_way_that_matters() -> void:
	var iowa: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	var fletcher: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_fletcher.json")
	gt(iowa.displacement_t, fletcher.displacement_t * 20.0, "twenty times the displacement")
	gt(fletcher.max_speed_ms, iowa.max_speed_ms, "but faster")
	lt(fletcher.turning_radius_m(), iowa.turning_radius_m(), "and turns in less water")
	gt(iowa.resistance_coefficient(), fletcher.resistance_coefficient() * 3.0,
		"far more resistance to push")


func test_a_future_schema_version_is_refused_rather_than_half_loaded() -> void:
	# Better to fail loudly than to load a ship missing whatever a later schema added.
	var spec: ShipSpec = ShipSpecLoader.parse({
		"schemaVersion": ShipSpecLoader.CURRENT_SCHEMA_VERSION + 1,
		"id": "from_the_future",
	}, "test")
	eq(spec, null, "rejected")


func test_missing_fields_fall_back_instead_of_crashing() -> void:
	# A half-written ship file being edited by hand should still open.
	var spec: ShipSpec = ShipSpecLoader.parse({"schemaVersion": 1, "id": "sketch"}, "test")
	ok(spec != null, "loads")
	if spec == null:
		return
	eq(spec.spec_id, "sketch", "id kept")
	eq(spec.display_name, "sketch", "name falls back to the id")
	gt(spec.length_m, 0.0, "usable dimensions")
	gt(spec.max_speed_ms, 0.0, "usable speed")
	gt(spec.yaw_response_time_s, 0.0, "derived defaults still applied")


func test_an_unknown_hull_form_falls_back_to_the_generic_warship_shape() -> void:
	var spec: ShipSpec = ShipSpecLoader.parse({
		"schemaVersion": 1, "id": "odd", "hull": {"form": "no_such_form", "lengthM": 150.0},
	}, "test")
	ok(spec != null, "still loads")
	gt(spec.hull().bounding_radius(), 0.0, "and produces a usable hull")


func test_a_custom_design_is_indistinguishable_from_a_preset() -> void:
	# This is the requirement that keeps the combat engine free of special cases:
	# the designer emits the same document a preset is written in.
	var document: Dictionary = {
		"schemaVersion": 1,
		"id": "my_battleship",
		"name": "My Battleship",
		"type": "battleship",
		"custom": true,
		"hull": {"form": "battleship", "lengthM": 250.0, "beamM": 34.0, "draftM": 11.0,
			"displacementFullT": 55000},
		"propulsion": {"powerShp": 150000, "shafts": 4, "maxSpeedKn": 28.0},
	}
	var custom: ShipSpec = ShipSpecLoader.parse(document, "memory")
	var preset: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	ok(custom != null, "custom design parses")
	eq(typeof(custom), typeof(preset), "same kind of object as a historical preset")
	ok(custom.is_custom, "flagged as custom for the UI")
	almost(SimUnits.ms_to_knots(custom.max_speed_ms), 28.0, 0.01, "its own speed")
	# And it drives the physics without any special handling.
	var world: SimWorld = SimWorld.create(1, TestShips.config())
	var ship: ShipEntity = world.add_ship(custom, Vector2.ZERO, 0.0, 0)
	ship.throttle = 1.0
	TestShips.run_seconds(world, 600.0)
	almost(ship.speed_knots(), 28.0, 0.6, "and reaches its design speed in the simulation")


func test_specs_are_copied_not_shared() -> void:
	# Two Fletchers in a battle must not share one spec object, or renaming one
	# renames both.
	var a: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_fletcher.json")
	var b: ShipSpec = a.duplicate_spec()
	b.display_name = "USS Radford"
	eq(a.display_name, "USS Fletcher", "the original is untouched")
	almost(b.length_m, a.length_m, 0.001, "but the figures carried over")
