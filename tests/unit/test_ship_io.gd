extends SimTest

## Saving a design and getting the same ship back.
##
## The designer writes exactly what `data/ships/*.json` contains, because §4 requires
## the engine to be unable to tell a player's design from a historical preset. So the
## test is the roster: load all seventeen presets, serialize each one, parse it back,
## and require the two specs to agree field for field.
##
## That is a much better test than any document written by hand. A serializer that
## quietly drops a field is the same class of bug as a copy that quietly drops a field
## — which had just happened — and seventeen real ships between them exercise every
## branch: ships with secondaries and without, with torpedoes and without, with
## aviation, with inclined belts, with tapered belts, with no belt at all.

func suite_name() -> String:
	return "Ship IO"


const ROSTER: Array[String] = [
	"uss_iowa", "uss_south_dakota", "hms_king_george_v", "hms_vanguard",
	"ijn_yamato", "bismarck",
	"uss_essex", "hms_illustrious", "ijn_shokaku",
	"uss_baltimore", "uss_cleveland", "ijn_mogami", "admiral_hipper",
	"uss_fletcher", "uss_gearing", "hms_tribal", "ijn_kagero",
]


func _round_trip(spec: ShipSpec) -> ShipSpec:
	return ShipSpecLoader.parse(ShipIO.to_document(spec), "<round trip>")


# --------------------------------------------------------------- the roster --

func test_every_preset_survives_a_round_trip() -> void:
	for spec_id: String in ROSTER:
		var original: ShipSpec = TestShips.load_ship(spec_id)
		var restored: ShipSpec = _round_trip(original)
		ok(restored != null, "%s serializes to a document that parses" % spec_id)
		if restored == null:
			continue
		_compare(original, restored, spec_id)


## Every scalar field on the spec, by reflection. A test that names the fields it
## checks can be forgotten in the same way as the serializer it is testing.
func _compare(a: ShipSpec, b: ShipSpec, label: String) -> void:
	for entry: Dictionary in a.get_property_list():
		if int(entry.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var name: String = str(entry.get("name", ""))
		if name.begins_with("_") or name == "is_custom":
			continue
		var original: Variant = a.get(name)
		if original is Object or original is Array or original is Dictionary:
			continue   # compared structurally below
		if original is float:
			# Floats go out through a unit conversion and come back through its
			# inverse, so they are compared to a relative tolerance rather than exactly.
			almost(b.get(name), original, maxf(absf(original) * 1.0e-6, 1.0e-9),
				"%s: %s" % [label, name])
		else:
			eq(b.get(name), original, "%s: %s" % [label, name])


func test_armour_survives_zone_for_zone() -> void:
	for spec_id: String in ROSTER:
		var original: ShipSpec = TestShips.load_ship(spec_id)
		var restored: ShipSpec = _round_trip(original)
		for zone: String in ArmourSchemeDef.ZONES:
			var before: ArmourSchemeDef.Plate = original.armour.plate(zone)
			var after: ArmourSchemeDef.Plate = restored.armour.plate(zone)
			almost(after.thickness_mm, before.thickness_mm, 1.0e-6,
				"%s %s thickness" % [spec_id, zone])
			eq(after.material_id, before.material_id, "%s %s material" % [spec_id, zone])
			almost(after.inclination_rad, before.inclination_rad, 1.0e-9,
				"%s %s inclination" % [spec_id, zone])
			almost(after.lower_edge_thickness_mm, before.lower_edge_thickness_mm, 1.0e-6,
				"%s %s lower edge" % [spec_id, zone])


func test_the_belt_taper_survives() -> void:
	# Added late, and exactly the kind of field a serializer forgets.
	var iowa: ShipSpec = _round_trip(TestShips.load_ship("uss_iowa"))
	ok(iowa.armour.plate("belt").is_tapered(), "Iowa's belt still tapers")
	almost(iowa.armour.plate("belt").lower_edge_thickness_mm, 41.0, 0.001,
		"to the 41 mm her sources give")


func test_armament_survives_mount_for_mount() -> void:
	for spec_id: String in ROSTER:
		var original: ShipSpec = TestShips.load_ship(spec_id)
		var restored: ShipSpec = _round_trip(original)
		eq(restored.has_main_battery(), original.has_main_battery(),
			"%s main battery present or absent alike" % spec_id)
		if original.has_main_battery():
			eq(restored.main_battery.gun_id, original.main_battery.gun_id,
				"%s main gun" % spec_id)
			eq(restored.main_battery.total_barrels(), original.main_battery.total_barrels(),
				"%s barrel count" % spec_id)
			for i: int in original.main_battery.mounts.size():
				var before: MountDef = original.main_battery.mounts[i]
				var after: MountDef = restored.main_battery.mounts[i]
				eq(after.mount_id, before.mount_id, "%s mount %d id" % [spec_id, i])
				almost(after.station, before.station, 1.0e-6, "%s mount %d station" % [spec_id, i])
				almost(after.rest_bearing, before.rest_bearing, 1.0e-9,
					"%s mount %d rest bearing" % [spec_id, i])
				almost(after.train_min, before.train_min, 1.0e-9,
					"%s mount %d train limit" % [spec_id, i])
		eq(restored.has_torpedoes(), original.has_torpedoes(),
			"%s torpedo tubes present or absent alike" % spec_id)
		if original.has_torpedoes():
			eq(restored.torpedo_battery.total_tubes(), original.torpedo_battery.total_tubes(),
				"%s tube count" % spec_id)


func test_a_round_tripped_ship_builds_the_same_structure() -> void:
	# The end of the chain that matters: if the document is right, the geometry a shell
	# is traced against is right, and so is the weight she comes out at.
	var config: Dictionary = JsonLoader.load_dict("res://data/config/structure.json")
	for spec_id: String in ["uss_iowa", "ijn_kagero", "uss_essex"]:
		var original: ShipSpec = TestShips.load_ship(spec_id)
		var restored: ShipSpec = _round_trip(original)
		var before: ShipStructureTemplate = ShipStructureBuilder.build(original, config)
		var after: ShipStructureTemplate = ShipStructureBuilder.build(restored, config)
		eq(after.faces.size(), before.faces.size(), "%s: same number of plates" % spec_id)
		eq(after.volumes.size(), before.volumes.size(), "%s: same compartments" % spec_id)
		almost(after.main_deck_z, before.main_deck_z, 1.0e-6, "%s: same freeboard" % spec_id)


# ----------------------------------------------------------- a design, saved --

func test_an_edited_design_round_trips_with_its_edits() -> void:
	var design: ShipSpec = TestShips.load_ship("uss_iowa").duplicate_spec(true)
	design.spec_id = "my_iowa"
	design.display_name = "USS Improved Iowa"
	design.is_custom = true
	design.armour.plate("belt").thickness_mm = 400.0
	design.armour.plate("belt").lower_edge_thickness_mm = 120.0
	design.beam_m = 36.0
	design.funnels = 1

	var restored: ShipSpec = _round_trip(design)
	eq(restored.spec_id, "my_iowa", "she keeps her id")
	eq(restored.display_name, "USS Improved Iowa", "and her name")
	almost(restored.armour.plate("belt").thickness_mm, 400.0, 0.001, "and her thicker belt")
	almost(restored.armour.plate("belt").lower_edge_thickness_mm, 120.0, 0.001,
		"and its taper")
	almost(restored.beam_m, 36.0, 1.0e-6, "and her wider beam")
	eq(restored.funnels, 1, "and her single funnel")


func test_a_document_is_plain_json_with_no_engine_types_in_it() -> void:
	# It has to survive being written to a file and read back by anything, including a
	# text editor. A Vector2 or a radian would break that.
	var document: Dictionary = ShipIO.to_document(TestShips.load_ship("uss_iowa"))
	var encoded: String = JSON.stringify(document)
	gt(float(encoded.length()), 100.0, "it encodes to JSON")
	var decoded: Variant = JSON.parse_string(encoded)
	ok(decoded is Dictionary, "and decodes back to a document")
	ok(ShipSpecLoader.parse(decoded as Dictionary, "<json>") != null,
		"which still parses as a ship")


# ------------------------------------------------- the designer's save path --

func test_a_design_saved_to_disk_comes_back_as_the_same_ship() -> void:
	# The other half of §4: a design the player saved is loaded by exactly the same
	# path as a historical preset, from a file with the same schema, and the engine
	# cannot tell which is which. This writes an actual file and reads it back.
	var design: ShipSpec = TestShips.load_ship("uss_fletcher").duplicate_spec(true)
	design.spec_id = "test_design_round_trip"
	design.display_name = "Test Boat"
	design.is_custom = true
	design.beam_m = 13.5
	design.armour.plate("belt").thickness_mm = 60.0

	var directory: String = "user://ships"
	if not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var path: String = directory.path_join("%s.json" % design.spec_id)

	ok(JsonLoader.save_dict(path, ShipIO.to_document(design)), "the document is written")
	var restored: ShipSpec = ShipSpecLoader.load_from_file(path)
	ok(restored != null, "and reads back as a ship")
	if restored != null:
		eq(restored.spec_id, design.spec_id, "with her id")
		eq(restored.display_name, "Test Boat", "and her name")
		almost(restored.beam_m, 13.5, 1.0e-6, "and the beam she was given")
		almost(restored.armour.plate("belt").thickness_mm, 60.0, 0.001,
			"and the belt she was given")
		ok(restored.is_custom, "marked as a player's design")

	DirAccess.remove_absolute(path)


func test_a_saved_design_is_weighed_the_same_as_the_one_that_was_saved() -> void:
	# The end of the loop that matters: what comes back off disk has to behave like the
	# ship the designer showed, or the numbers a player designed against were a lie.
	var design: ShipSpec = TestShips.load_ship("uss_iowa").duplicate_spec(true)
	design.armour.plate("belt").thickness_mm = 420.0
	design.armour.plate("belt").lower_edge_thickness_mm = 60.0
	design.beam_m = 35.0
	design.invalidate_hull()

	var restored: ShipSpec = _round_trip(design)
	var config: Dictionary = JsonLoader.load_dict("res://data/config/structure.json")
	var arch: Dictionary = JsonLoader.load_dict("res://data/config/naval_architecture.json")
	var materials: ArmourMaterials = ArmourMaterials.load_from("res://data/materials/armor.json")

	var before: DesignAnalysis = NavalArchitect.analyse(design,
		ShipStructureBuilder.build(design, config), materials, TestWeapons.armory(), arch)
	var after: DesignAnalysis = NavalArchitect.analyse(restored,
		ShipStructureBuilder.build(restored, config), materials, TestWeapons.armory(), arch)

	almost(after.full_displacement_t, before.full_displacement_t, 1.0,
		"she weighs the same coming back")
	almost(after.gm_m, before.gm_m, 0.01, "and is as stable")
	almost(after.estimated_speed_kn, before.estimated_speed_kn, 0.01, "and as fast")
	almost(after.group_tonnes("Armour"), before.group_tonnes("Armour"), 1.0,
		"and carries the same armour")
