extends SimTest

## The generated internal geometry: what is where, and therefore what is behind what.
##
## This is where "a magazine against the shell plating is more vulnerable than one
## behind a belt, a void and a machinery space" either becomes true or does not. The
## tracer that follows is only as good as the arrangement it walks through.


func suite_name() -> String:
	return "Ship structure"


static func _config() -> Dictionary:
	return JsonLoader.load_dict("res://data/config/structure.json")


func _structure(spec_id: String) -> ShipStructureTemplate:
	return TestShips.structure(spec_id)


func _faces_in_zone(t: ShipStructureTemplate, zone: String) -> Array[GeometryPrimitives.Face]:
	var out: Array[GeometryPrimitives.Face] = []
	for face: GeometryPrimitives.Face in t.faces:
		if face.zone == zone:
			out.append(face)
	return out


# ----------------------------------------------------------------- geometry --

func test_vertical_levels_are_ordered_and_plausible() -> void:
	var t: ShipStructureTemplate = _structure("uss_iowa")
	lt(t.keel_z, 0.0, "the keel is below the waterline")
	gt(t.main_deck_z, 0.0, "the main deck is above it")
	between(t.armour_deck_z, 0.0, t.main_deck_z, "the armoured deck lies between them")
	gt(t.superstructure_top_z, t.main_deck_z, "the superstructure is above the main deck")
	# The keel sits at the HYDROSTATIC draft — the one that makes the enclosed volume
	# match her displacement — not at the reported figure, which for many ships is
	# measured to the propellers rather than to the moulded hull.
	var spec: ShipSpec = TestShips.load_ship("uss_iowa")
	almost(t.keel_z, -spec.hydrostatic_draft(), 0.01, "keel is at the hydrostatic draft")
	between(spec.hydrostatic_draft() / spec.draft_m, 0.85, 1.05,
		"which for Iowa is close to her reported draft")
	between(t.main_deck_z, 5.0, 10.0, "freeboard is a plausible seven metres or so")


func test_the_citadel_covers_every_main_battery_turret() -> void:
	# The citadel exists to cover the magazines, and the magazines are under the
	# turrets. A turret outside it would have its shell rooms unprotected.
	for spec_id: String in ["uss_iowa", "ijn_yamato", "bismarck", "uss_baltimore"]:
		var spec: ShipSpec = TestShips.load_ship(spec_id)
		var t: ShipStructureTemplate = _structure(spec_id)
		for mount: MountDef in spec.main_battery.mounts:
			between(mount.station, t.citadel_aft, t.citadel_fore,
				"%s turret %s is inside the citadel" % [spec_id, mount.mount_id])


func test_a_battleship_has_the_armour_zones_her_data_describes() -> void:
	var t: ShipStructureTemplate = _structure("uss_iowa")
	for zone: String in ["belt", "deckMain", "turretFace", "turretRoof", "barbette",
			"conningTower", "bulkheadFore", "torpedoBulkhead"]:
		gt(float(_faces_in_zone(t, zone).size()), 0.0, "Iowa has %s armour" % zone)

	# Both sides, not just one.
	eq(_faces_in_zone(t, "belt").size(), 2, "a belt on each beam")
	almost(_faces_in_zone(t, "belt")[0].thickness_mm, 307.0, 0.1, "at her stated thickness")


func test_an_inclined_belt_is_actually_inclined() -> void:
	# Iowa's belt leans 19 degrees. That is what gives it more effective thickness
	# against a flat trajectory and less against a plunging one, and it is expressed
	# by tilting the plate's normal rather than by a modifier anywhere downstream.
	var belt: GeometryPrimitives.Face = _faces_in_zone(_structure("uss_iowa"), "belt")[0]
	gt(absf(belt.normal.z), 0.2, "the normal is tilted out of the horizontal")

	# A shell approaches from OUTSIDE, so it travels against the plate's outward
	# normal in the horizontal, and downwards.
	var inboard: float = -signf(belt.normal.y)

	# A horizontal shell from abeam meets it at the belt's own inclination.
	var flat: Vector3 = Vector3(0.0, inboard, 0.0)
	almost(rad_to_deg(belt.obliquity_to(flat)), 19.0, 1.0, "19 degrees to a flat trajectory")

	# A shell plunging at 19 degrees strikes the same plate square on.
	var plunging: Vector3 = Vector3(0.0, inboard * cos(deg_to_rad(19.0)),
		-sin(deg_to_rad(19.0))).normalized()
	lt(rad_to_deg(belt.obliquity_to(plunging)), 3.0,
		"but a plunging shell meets it nearly square, which is the whole trade")


func test_a_destroyer_has_essentially_no_armour() -> void:
	var t: ShipStructureTemplate = _structure("uss_fletcher")
	eq(_faces_in_zone(t, "belt").size(), 0, "no belt at all")
	lt(t.maximum_armour_mm(), 30.0, "nothing thicker than splinter plating anywhere")
	gt(float(t.volumes.size()), 20.0, "but she is still fully compartmented")


# ------------------------------------------------------------- compartments --

func test_magazines_sit_under_the_turrets_they_serve() -> void:
	var spec: ShipSpec = TestShips.load_ship("uss_iowa")
	var t: ShipStructureTemplate = _structure("uss_iowa")
	var magazines: PackedInt32Array = t.volumes_with_role(ShipStructureBuilder.ROLE_MAGAZINE)
	gt(float(magazines.size()), 0.0, "she has magazines")

	for index: int in magazines:
		var magazine: GeometryPrimitives.Volume = t.volumes[index]
		var station: float = magazine.centre().x / spec.length_m
		var nearest: float = 999.0
		for mount: MountDef in spec.main_battery.mounts:
			nearest = minf(nearest, absf(station - mount.station))
		lt(nearest, 0.08, "every magazine is beneath a turret")


func test_magazines_and_machinery_are_below_the_armoured_deck() -> void:
	# The point of an armoured deck is that the things worth protecting are under it.
	var t: ShipStructureTemplate = _structure("uss_iowa")
	for role: String in [ShipStructureBuilder.ROLE_MAGAZINE, ShipStructureBuilder.ROLE_ENGINE,
			ShipStructureBuilder.ROLE_BOILER]:
		for index: int in t.volumes_with_role(role):
			le(t.volumes[index].centre().z, t.armour_deck_z,
				"%s is beneath the armoured deck" % t.volumes[index].label)


func test_machinery_alternates_so_one_hit_cannot_stop_the_ship() -> void:
	var t: ShipStructureTemplate = _structure("uss_iowa")
	gt(float(t.volumes_with_role(ShipStructureBuilder.ROLE_BOILER).size()), 1.0, "several boiler rooms")
	gt(float(t.volumes_with_role(ShipStructureBuilder.ROLE_ENGINE).size()), 1.0, "and several engine rooms")


func test_steering_gear_is_right_aft_and_outside_the_citadel() -> void:
	# Which is exactly why a torpedo aft so often ends a ship's day without sinking her.
	var spec: ShipSpec = TestShips.load_ship("uss_iowa")
	var t: ShipStructureTemplate = _structure("uss_iowa")
	var steering: PackedInt32Array = t.volumes_with_role(ShipStructureBuilder.ROLE_STEERING)
	gt(float(steering.size()), 0.0, "she has a steering gear compartment")
	for index: int in steering:
		lt(t.volumes[index].centre().x / spec.length_m, t.citadel_aft,
			"it is abaft the armoured citadel")


func test_torpedo_protection_produces_outboard_voids() -> void:
	var t: ShipStructureTemplate = _structure("ijn_yamato")
	gt(float(t.volumes_with_role(ShipStructureBuilder.ROLE_BULGE).size()), 0.0,
		"a ship with a torpedo defence system has bulge compartments")
	var fletcher: ShipStructureTemplate = _structure("uss_fletcher")
	eq(fletcher.volumes_with_role(ShipStructureBuilder.ROLE_BULGE).size(), 0,
		"a destroyer with none has no bulge at all")


func test_internal_volume_is_consistent_with_displacement() -> void:
	# A hull that displaces 57,000 tonnes has to enclose roughly that much water.
	for spec_id: String in ["uss_iowa", "uss_baltimore", "uss_fletcher"]:
		var spec: ShipSpec = TestShips.load_ship(spec_id)
		var t: ShipStructureTemplate = _structure(spec_id)
		var displaced_volume: float = spec.displacement_t * 1000.0 / SimUnits.SEAWATER_DENSITY
		between(t.total_internal_volume() / displaced_volume, 0.5, 3.0,
			"%s encloses a volume consistent with her displacement" % spec_id)


# ----------------------------------------------------------------- components --

func test_machinery_components_exist_and_match_the_ships_plant() -> void:
	var spec: ShipSpec = TestShips.load_ship("uss_iowa")
	var t: ShipStructureTemplate = _structure("uss_iowa")
	eq(t.volumes_with_role(ShipStructureBuilder.COMPONENT_ENGINE).size(), spec.shafts,
		"one engine per shaft")
	eq(t.volumes_with_role(ShipStructureBuilder.COMPONENT_SHAFT).size(), spec.shafts,
		"and one shaft each")
	eq(t.volumes_with_role(ShipStructureBuilder.COMPONENT_BOILER).size(), spec.boilers,
		"boilers as her data states")
	eq(t.volumes_with_role(ShipStructureBuilder.COMPONENT_RUDDER).size(), 1, "a steering gear")


func test_turrets_exist_as_components_with_their_own_armour() -> void:
	var spec: ShipSpec = TestShips.load_ship("uss_iowa")
	var t: ShipStructureTemplate = _structure("uss_iowa")
	eq(t.volumes_with_role(ShipStructureBuilder.COMPONENT_TURRET).size(),
		spec.main_battery.mounts.size(), "one component per main turret")
	# Face armour is far thicker than the roof, and which a shell meets depends on
	# where it came from — so they cannot be collapsed into one number.
	gt(_faces_in_zone(t, "turretFace")[0].thickness_mm,
		_faces_in_zone(t, "turretRoof")[0].thickness_mm * 2.0,
		"the face is more than twice the roof")


func test_directors_and_radar_are_high_and_unprotected() -> void:
	# Losing them does not sink a ship or slow her; it stops her shooting straight.
	var t: ShipStructureTemplate = _structure("uss_iowa")
	for role: String in [ShipStructureBuilder.COMPONENT_DIRECTOR, ShipStructureBuilder.COMPONENT_RADAR]:
		var found: PackedInt32Array = t.volumes_with_role(role)
		gt(float(found.size()), 0.0, "%s exists" % role)
		gt(t.volumes[found[0]].centre().z, t.main_deck_z, "%s is above the main deck" % role)


func test_a_carrier_has_a_hangar_and_lifts() -> void:
	var t: ShipStructureTemplate = _structure("uss_essex")
	gt(float(t.volumes_with_role(ShipStructureBuilder.ROLE_HANGAR).size()), 0.0, "a hangar")
	gt(float(t.volumes_with_role(ShipStructureBuilder.COMPONENT_ELEVATOR).size()), 1.0, "and lifts")


func test_every_ship_in_the_roster_builds_without_degenerate_geometry() -> void:
	for path: String in JsonLoader.list_json_files("res://data/ships"):
		var spec: ShipSpec = ShipSpecLoader.load_from_file(path)
		var t: ShipStructureTemplate = ShipStructureBuilder.build(spec, _config())
		gt(float(t.faces.size()), 10.0, "%s has faces" % spec.spec_id)
		gt(float(t.volumes.size()), 10.0, "%s has volumes" % spec.spec_id)
		for face: GeometryPrimitives.Face in t.faces:
			gt(face.area_m2(), 0.0, "%s: every face has area" % spec.spec_id)
			almost(face.normal.length(), 1.0, 1e-6, "%s: normals are unit length" % spec.spec_id)
		for volume: GeometryPrimitives.Volume in t.volumes:
			gt(volume.volume_m3(), 0.0, "%s: every volume is non-empty" % spec.spec_id)
