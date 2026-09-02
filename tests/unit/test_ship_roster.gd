extends SimTest

## The historical roster, checked for internal consistency and against what the ships
## actually were.
##
## A data set this size decays quietly: a typo in a gun id, a belt thickness in the
## wrong units, a hull form that does not exist. These tests are the thing that keeps
## adding a ship an act of data entry rather than a source of mysterious bugs.

const SHIP_DIR: String = "res://data/ships"

var _specs: Array[ShipSpec] = []


func suite_name() -> String:
	return "Ship roster"


func before_each() -> void:
	if _specs.is_empty():
		for path: String in JsonLoader.list_json_files(SHIP_DIR):
			var spec: ShipSpec = ShipSpecLoader.load_from_file(path)
			if spec != null:
				_specs.append(spec)


func _by_id(spec_id: String) -> ShipSpec:
	for spec: ShipSpec in _specs:
		if spec.spec_id == spec_id:
			return spec
	return null


func _of_type(ship_type: String) -> Array[ShipSpec]:
	var out: Array[ShipSpec] = []
	for spec: ShipSpec in _specs:
		if spec.ship_type == ship_type:
			out.append(spec)
	return out


func test_every_named_ship_in_the_specification_is_present() -> void:
	for spec_id: String in [
		"uss_iowa", "uss_south_dakota", "hms_king_george_v", "hms_vanguard",
		"ijn_yamato", "bismarck",
		"uss_essex", "hms_illustrious", "ijn_shokaku",
		"uss_baltimore", "uss_cleveland", "ijn_mogami", "admiral_hipper",
		"uss_fletcher", "uss_gearing", "hms_tribal", "ijn_kagero",
	]:
		ok(_by_id(spec_id) != null, "%s is in the roster" % spec_id)


func test_all_four_ship_categories_are_represented() -> void:
	gt(float(_of_type("battleship").size()), 4.0, "battleships")
	gt(float(_of_type("carrier").size()), 2.0, "carriers")
	gt(float(_of_type("cruiser").size()), 3.0, "cruisers")
	gt(float(_of_type("destroyer").size()), 3.0, "destroyers")


func test_every_gun_reference_resolves() -> void:
	# A dangling gun id would leave a ship silently unarmed rather than failing.
	var armory: Armory = TestWeapons.armory()
	for spec: ShipSpec in _specs:
		if spec.has_main_battery():
			ok(armory.has_gun(spec.main_battery.gun_id),
				"%s main battery gun '%s' exists" % [spec.display_name, spec.main_battery.gun_id])
		if spec.has_secondary_battery():
			ok(armory.has_gun(spec.secondary_battery.gun_id),
				"%s secondary gun '%s' exists" % [spec.display_name, spec.secondary_battery.gun_id])


func test_every_armour_material_reference_resolves() -> void:
	var materials: Dictionary = (JsonLoader.load_dict("res://data/materials/armor.json")
		.get("materials", {}) as Dictionary)
	for spec: ShipSpec in _specs:
		for zone: String in ArmourSchemeDef.ZONES:
			var material: String = spec.armour.plate(zone).material_id
			ok(materials.has(material),
				"%s %s uses a defined material ('%s')" % [spec.display_name, zone, material])


func test_every_shell_a_gun_lists_exists() -> void:
	var armory: Armory = TestWeapons.armory()
	for gun_id: String in armory.gun_ids():
		var gun: GunDef = armory.get_gun(gun_id)
		gt(float(gun.ammunition.size()), 0.0, "%s has ammunition" % gun_id)
		for shell_id: String in gun.ammunition:
			ok(armory.get_shell(shell_id) != null, "%s can fire '%s'" % [gun_id, shell_id])


func test_dimensions_and_displacement_are_physically_consistent() -> void:
	for spec: ShipSpec in _specs:
		gt(spec.length_m, spec.beam_m * 4.0, "%s is at least four beams long" % spec.display_name)
		lt(spec.length_m, spec.beam_m * 16.0, "%s is not absurdly narrow" % spec.display_name)
		gt(spec.draft_m, 2.0, "%s has a real draft" % spec.display_name)
		# Geometry should account for the displacement the source books give.
		var geometric: float = spec.hull().estimated_displacement_tonnes(spec.vertical_fullness)
		between(geometric / spec.displacement_t, 0.6, 1.6,
			"%s hull volume is consistent with her stated displacement" % spec.display_name)


func test_armour_scales_with_ship_type() -> void:
	# Not enforced anywhere in code — it emerges from the data being right.
	var yamato: ShipSpec = _by_id("ijn_yamato")
	var baltimore: ShipSpec = _by_id("uss_baltimore")
	var fletcher: ShipSpec = _by_id("uss_fletcher")
	gt(yamato.armour.thickness_mm("belt"), baltimore.armour.thickness_mm("belt") * 2.0,
		"a battleship belt dwarfs a heavy cruiser's")
	gt(baltimore.armour.thickness_mm("belt"), 100.0, "a heavy cruiser has a real belt")
	almost(fletcher.armour.thickness_mm("belt"), 0.0, 0.01, "a destroyer has no belt at all")


func test_yamato_carries_the_thickest_armour_afloat() -> void:
	var yamato: ShipSpec = _by_id("ijn_yamato")
	for spec: ShipSpec in _of_type("battleship"):
		ge(yamato.armour.thickness_mm("belt"), spec.armour.thickness_mm("belt"),
			"no belt exceeds Yamato's")
		ge(yamato.armour.thickness_mm("turretFace"), spec.armour.thickness_mm("turretFace"),
			"no turret face exceeds Yamato's")
	gt(yamato.armour.thickness_mm("turretFace"), 600.0, "650 mm on the turret faces")


func test_destroyers_have_essentially_no_protection() -> void:
	for spec: ShipSpec in _of_type("destroyer"):
		lt(spec.armour.thickness_mm("belt") + spec.armour.total_deck_mm(), 40.0,
			"%s carries splinter plating at most" % spec.display_name)
		not_ok(spec.armour.has_torpedo_defence(),
			"%s has no torpedo defence system" % spec.display_name)


func test_carriers_differ_in_where_their_armour_is() -> void:
	# The central design argument of the carrier war, visible in the data: Illustrious
	# armoured her flight deck and carried 36 aircraft; Essex left hers as wood over
	# the hangar deck and carried 90.
	var illustrious: ShipSpec = _by_id("hms_illustrious")
	var essex: ShipSpec = _by_id("uss_essex")
	gt(illustrious.armour.thickness_mm("deckWeather"), 50.0, "Illustrious has an armoured flight deck")
	almost(essex.armour.thickness_mm("deckWeather"), 0.0, 0.01, "Essex does not")
	gt(float(int(essex.aviation.get("capacity", 0))),
		float(int(illustrious.aviation.get("capacity", 0))) * 2.0,
		"and carries more than twice the air group as a result")


func test_capital_ships_have_torpedo_defence_and_small_ships_do_not() -> void:
	for spec: ShipSpec in _of_type("battleship"):
		ok(spec.armour.has_torpedo_defence(), "%s has a torpedo defence system" % spec.display_name)
		gt(spec.armour.torpedo_defence_depth_m, 3.0, "%s: a system of real depth" % spec.display_name)


func test_speed_and_power_relationships_hold_across_the_roster() -> void:
	for spec: ShipSpec in _specs:
		between(SimUnits.ms_to_knots(spec.max_speed_ms), 25.0, 40.0,
			"%s has a plausible top speed" % spec.display_name)
		gt(spec.propulsion_power_w, 1.0e7, "%s has real power" % spec.display_name)
		# Power per tonne should rise sharply as ships get smaller.
		var power_per_tonne: float = spec.propulsion_power_w / spec.displacement_t
		between(power_per_tonne, 1000.0, 30000.0,
			"%s power-to-weight is in the naval range" % spec.display_name)


func test_a_destroyer_has_far_more_power_per_tonne_than_a_battleship() -> void:
	var fletcher: ShipSpec = _by_id("uss_fletcher")
	var yamato: ShipSpec = _by_id("ijn_yamato")
	gt(fletcher.propulsion_power_w / fletcher.displacement_t,
		(yamato.propulsion_power_w / yamato.displacement_t) * 5.0,
		"which is why one accelerates and turns and the other does not")


func test_every_mount_sits_on_the_ship_and_has_a_sensible_arc() -> void:
	for spec: ShipSpec in _specs:
		if not spec.has_main_battery():
			continue
		for mount: MountDef in spec.main_battery.mounts:
			between(mount.station, -0.5, 0.5, "%s %s is on the hull" % [spec.display_name, mount.mount_id])
			between(mount.lateral, -1.0, 1.0, "%s %s is within the beam" % [spec.display_name, mount.mount_id])
			gt(float(mount.guns), 0.0, "%s %s has guns" % [spec.display_name, mount.mount_id])
			gt(mount.train_max - mount.train_min, deg_to_rad(90.0),
				"%s %s has a usable arc" % [spec.display_name, mount.mount_id])
			lt(mount.train_max - mount.train_min, TAU,
				"%s %s has a blind arc, as every real mount does" % [spec.display_name, mount.mount_id])


func test_main_battery_weight_of_fire_matches_the_ship_type() -> void:
	var yamato: ShipSpec = _by_id("ijn_yamato")
	var cleveland: ShipSpec = _by_id("uss_cleveland")
	var kagero: ShipSpec = _by_id("ijn_kagero")
	eq(yamato.main_battery.total_barrels(), 9, "Yamato: three triple 46 cm turrets")
	eq(cleveland.main_battery.total_barrels(), 12, "Cleveland: four triple 6-inch turrets")
	eq(kagero.main_battery.total_barrels(), 6, "Kagero: three twin 12.7 cm mounts")


func test_every_ship_records_its_sources() -> void:
	# Historical figures are contested, so the data has to say where it came from and
	# how much to trust it. Without that, a correction is a guess.
	for path: String in JsonLoader.list_json_files(SHIP_DIR):
		var raw: Dictionary = JsonLoader.load_dict(path)
		gt(float((raw.get("sources", []) as Array).size()), 0.0,
			"%s cites at least one source" % path.get_file())
		ok(raw.has("notes"), "%s carries a note explaining the design" % path.get_file())
