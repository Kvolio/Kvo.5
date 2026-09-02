class_name ShipStructureBuilder
extends RefCounted

## Turns a ship design into the internal geometry a shell is traced through.
##
## This is the single most consequential piece of the project, because it decides
## what is behind what. A magazine placed directly against the shell plating is more
## vulnerable than one sitting behind a belt, a void and a machinery space — and that
## has to be true because of where they are, not because of a modifier.
##
## The same generator runs for a historical preset and for a player design. There is
## no separate path, which is what makes a custom ship fight on exactly the terms a
## real one does.
##
## Everything it produces is either an oriented rectangle or an axis-aligned box, so
## the tracer needs only two intersection routines. See GeometryPrimitives.

const ROLE_MAGAZINE: String = "magazine"
const ROLE_BOILER: String = "boiler_room"
const ROLE_ENGINE: String = "engine_room"
const ROLE_FUEL: String = "fuel"
const ROLE_VOID: String = "void"
const ROLE_BULGE: String = "torpedo_bulge"
const ROLE_STEERING: String = "steering_gear"
const ROLE_FIRE_CONTROL: String = "fire_control"
const ROLE_CREW: String = "crew"
const ROLE_HANGAR: String = "hangar"
const ROLE_STORES: String = "stores"

const COMPONENT_TURRET: String = "turret"
const COMPONENT_ENGINE: String = "engine"
const COMPONENT_BOILER: String = "boiler"
const COMPONENT_SHAFT: String = "shaft"
const COMPONENT_RUDDER: String = "rudder"
const COMPONENT_DIRECTOR: String = "director"
const COMPONENT_RADAR: String = "radar"
const COMPONENT_ELEVATOR: String = "elevator"

## Longitudinal segments used for the shell plating. Enough that the taper of a fine
## bow is followed rather than approximated by a single flat plate.
const HULL_SEGMENTS: int = 12

var _config: Dictionary = {}
var _hull_config: Dictionary = {}
var _citadel_config: Dictionary = {}
var _compartment_config: Dictionary = {}


static func build(spec: ShipSpec, config: Dictionary) -> ShipStructureTemplate:
	var builder: ShipStructureBuilder = ShipStructureBuilder.new()
	builder._config = config
	builder._hull_config = config.get("hull", {}) as Dictionary
	builder._citadel_config = config.get("citadel", {}) as Dictionary
	builder._compartment_config = config.get("compartments", {}) as Dictionary
	return builder._build(spec)


func _build(spec: ShipSpec) -> ShipStructureTemplate:
	var t: ShipStructureTemplate = ShipStructureTemplate.new()
	t.spec_id = spec.spec_id
	t.length_m = spec.length_m
	t.beam_m = spec.beam_m
	t.draft_m = spec.hydrostatic_draft()

	# Vertical levels. Depth is expressed as a multiple of draft, so freeboard — and
	# with it how much belt stands above water — follows from the ship's own draft.
	# Built from the hydrostatic draft rather than the reported one, so the enclosed
	# volume matches the ship's displacement. See ShipSpec.hydrostatic_draft().
	var draft: float = spec.hydrostatic_draft()
	var depth: float = draft * float(_hull_config.get("depthToDraftRatio", 1.65))
	t.keel_z = -draft
	t.main_deck_z = depth - draft
	t.armour_deck_z = t.main_deck_z - draft * float(_hull_config.get("armourDeckDraftFraction", 0.35))
	t.superstructure_top_z = t.main_deck_z + spec.length_m * float(
		_hull_config.get("superstructureHeightFraction", 0.045))

	_resolve_citadel(t, spec)
	_build_hull_faces(t, spec)
	_build_armour_faces(t, spec)
	_build_turrets_and_barbettes(t, spec)
	_build_compartments(t, spec)
	_build_components(t, spec)
	t.seal()
	return t


## The citadel exists to cover the magazines and the machinery between them, so its
## extent is derived from where the main battery actually sits rather than assumed.
func _resolve_citadel(t: ShipStructureTemplate, spec: ShipSpec) -> void:
	var margin: float = float(_citadel_config.get("marginBeyondEndTurrets", 0.06))
	var limit: float = float(_citadel_config.get("maxHalfLength", 0.42))
	var minimum: float = float(_citadel_config.get("minHalfLength", 0.18))

	var fore: float = minimum
	var aft: float = -minimum
	if spec.has_main_battery():
		for mount: MountDef in spec.main_battery.mounts:
			fore = maxf(fore, mount.station + margin)
			aft = minf(aft, mount.station - margin)
	t.citadel_fore = clampf(fore, minimum, limit)
	t.citadel_aft = clampf(aft, -limit, -minimum)


# ------------------------------------------------------------------ hull skin --

func _build_hull_faces(t: ShipStructureTemplate, spec: ShipSpec) -> void:
	var hull: HullGeometry = spec.hull()

	for i: int in HULL_SEGMENTS:
		var station_a: float = lerpf(-0.5, 0.5, float(i) / float(HULL_SEGMENTS))
		var station_b: float = lerpf(-0.5, 0.5, float(i + 1) / float(HULL_SEGMENTS))
		var mid: float = (station_a + station_b) * 0.5
		var half_beam: float = hull.half_beam_at(mid)
		if half_beam <= 0.01:
			continue

		var x_mid: float = mid * spec.length_m
		var segment_length: float = (station_b - station_a) * spec.length_m
		# Outward normal follows the hull's taper, so a shell striking the fine bow
		# meets it at a glancing angle exactly as it would in reality.
		var slope: float = (hull.half_beam_at(station_b) - hull.half_beam_at(station_a)) / maxf(segment_length, 0.01)
		var height: float = t.main_deck_z - t.keel_z
		var z_mid: float = (t.main_deck_z + t.keel_z) * 0.5

		for side: int in [-1, 1]:
			var normal: Vector3 = Vector3(-slope * float(side), float(side), 0.0).normalized()
			t.add_face(GeometryPrimitives.make_face(
				0, GeometryPrimitives.FaceKind.HULL, "shellPlating",
				Vector3(x_mid, half_beam * float(side), z_mid),
				normal, Vector3(1.0, 0.0, 0.0),
				segment_length * 0.5, height * 0.5,
				_plating_thickness(spec), "structural_steel"))

	# Weather deck and bottom, spanning the whole ship.
	var deck_material: String = spec.armour.plate("deckWeather").material_id
	var deck_mm: float = spec.armour.thickness_mm("deckWeather")
	t.add_face(GeometryPrimitives.make_face(
		0, GeometryPrimitives.FaceKind.ARMOR if deck_mm > 0.0 else GeometryPrimitives.FaceKind.HULL,
		"deckWeather",
		Vector3(0.0, 0.0, t.main_deck_z), Vector3.UP, Vector3(1.0, 0.0, 0.0),
		spec.length_m * 0.5, spec.beam_m * 0.5,
		maxf(deck_mm, _plating_thickness(spec)),
		deck_material if deck_mm > 0.0 else "structural_steel"))

	t.add_face(GeometryPrimitives.make_face(
		0, GeometryPrimitives.FaceKind.HULL, "bottomPlating",
		Vector3(0.0, 0.0, t.keel_z), Vector3.DOWN, Vector3(1.0, 0.0, 0.0),
		spec.length_m * 0.5, spec.beam_m * 0.5,
		_plating_thickness(spec) * 1.4, "structural_steel"))


## Shell plating thickness. Not armour, but not nothing: it is what a shell has to
## hole to get in, what strips an AP cap, and what floods when it is opened.
func _plating_thickness(spec: ShipSpec) -> float:
	return clampf(spec.length_m * 0.09, 8.0, 30.0)


# --------------------------------------------------------------------- armour --

func _build_armour_faces(t: ShipStructureTemplate, spec: ShipSpec) -> void:
	var hull: HullGeometry = spec.hull()
	var citadel_mid: float = (t.citadel_fore + t.citadel_aft) * 0.5
	var citadel_half: float = (t.citadel_fore - t.citadel_aft) * 0.5 * spec.length_m
	var citadel_x: float = citadel_mid * spec.length_m
	var citadel_half_beam: float = hull.half_beam_at(citadel_mid)

	# --- main belt -----------------------------------------------------------
	var belt: ArmourSchemeDef.Plate = spec.armour.plate("belt")
	if belt.is_armoured():
		var belt_bottom: float = -spec.draft_m * float(_hull_config.get("beltBottomDraftFraction", 0.55))
		var belt_top: float = t.main_deck_z
		var belt_height: float = belt_top - belt_bottom
		for side: int in [-1, 1]:
			# An inclined belt leans inboard at the top, which is why it presents more
			# effective thickness to a flat trajectory and LESS to a plunging one.
			# Tilting the normal is all that takes; no special case downstream.
			var normal: Vector3 = Vector3(
				0.0,
				float(side) * cos(belt.inclination_rad),
				sin(belt.inclination_rad)).normalized()
			t.add_face(GeometryPrimitives.make_face(
				0, GeometryPrimitives.FaceKind.ARMOR, "belt",
				Vector3(citadel_x, citadel_half_beam * 0.97 * float(side),
					(belt_top + belt_bottom) * 0.5),
				normal, Vector3(1.0, 0.0, 0.0),
				citadel_half, belt_height * 0.5,
				belt.thickness_mm, belt.material_id))

	# --- upper belt ----------------------------------------------------------
	var upper: ArmourSchemeDef.Plate = spec.armour.plate("upperBelt")
	if upper.is_armoured():
		var upper_bottom: float = t.main_deck_z
		var upper_top: float = t.main_deck_z + (t.superstructure_top_z - t.main_deck_z) * 0.55
		for side: int in [-1, 1]:
			t.add_face(GeometryPrimitives.make_face(
				0, GeometryPrimitives.FaceKind.ARMOR, "upperBelt",
				Vector3(citadel_x, citadel_half_beam * 0.95 * float(side),
					(upper_top + upper_bottom) * 0.5),
				Vector3(0.0, float(side), 0.0), Vector3(1.0, 0.0, 0.0),
				citadel_half, (upper_top - upper_bottom) * 0.5,
				upper.thickness_mm, upper.material_id))

	# --- armoured decks ------------------------------------------------------
	_add_deck(t, spec, "deckMain", t.armour_deck_z, citadel_x, citadel_half, citadel_half_beam)
	_add_deck(t, spec, "deckSplinter",
		t.armour_deck_z - t.draft_m * float(_hull_config.get("splinterDeckDraftFraction", 0.18)),
		citadel_x, citadel_half, citadel_half_beam)

	# --- transverse bulkheads closing the citadel ----------------------------
	_add_bulkhead(t, spec, "bulkheadFore", t.citadel_fore, hull)
	_add_bulkhead(t, spec, "bulkheadAft", t.citadel_aft, hull)

	# --- torpedo bulkhead ----------------------------------------------------
	var torpedo: ArmourSchemeDef.Plate = spec.armour.plate("torpedoBulkhead")
	if torpedo.is_armoured() and spec.armour.has_torpedo_defence():
		var inboard: float = maxf(citadel_half_beam - spec.armour.torpedo_defence_depth_m, 1.0)
		for side: int in [-1, 1]:
			t.add_face(GeometryPrimitives.make_face(
				0, GeometryPrimitives.FaceKind.ARMOR, "torpedoBulkhead",
				Vector3(citadel_x, inboard * float(side), (t.keel_z + 0.0) * 0.5),
				Vector3(0.0, float(side), 0.0), Vector3(1.0, 0.0, 0.0),
				citadel_half, absf(t.keel_z) * 0.5,
				torpedo.thickness_mm, torpedo.material_id))

	# --- conning tower -------------------------------------------------------
	var conning: ArmourSchemeDef.Plate = spec.armour.plate("conningTower")
	if conning.is_armoured():
		var ct_size: float = clampf(spec.beam_m * 0.22, 2.0, 8.0)
		var ct_centre: Vector3 = Vector3(
			spec.length_m * 0.06, 0.0,
			t.main_deck_z + (t.superstructure_top_z - t.main_deck_z) * 0.45)
		_add_box_armour(t, "conningTower", ct_centre, Vector3(ct_size, ct_size, ct_size * 1.2),
			conning.thickness_mm, conning.material_id)


func _add_deck(t: ShipStructureTemplate, spec: ShipSpec, zone: String, z: float,
		citadel_x: float, citadel_half: float, half_beam: float) -> void:
	var plate: ArmourSchemeDef.Plate = spec.armour.plate(zone)
	if not plate.is_armoured():
		return
	t.add_face(GeometryPrimitives.make_face(
		0, GeometryPrimitives.FaceKind.ARMOR, zone,
		Vector3(citadel_x, 0.0, z), Vector3.UP, Vector3(1.0, 0.0, 0.0),
		citadel_half, half_beam,
		plate.thickness_mm, plate.material_id))


func _add_bulkhead(t: ShipStructureTemplate, spec: ShipSpec, zone: String,
		station: float, hull: HullGeometry) -> void:
	var plate: ArmourSchemeDef.Plate = spec.armour.plate(zone)
	if not plate.is_armoured():
		return
	var half_beam: float = hull.half_beam_at(station)
	var top: float = t.armour_deck_z
	var bottom: float = t.keel_z
	t.add_face(GeometryPrimitives.make_face(
		0, GeometryPrimitives.FaceKind.ARMOR, zone,
		Vector3(station * spec.length_m, 0.0, (top + bottom) * 0.5),
		Vector3(signf(station), 0.0, 0.0), Vector3(0.0, 1.0, 0.0),
		half_beam, (top - bottom) * 0.5,
		plate.thickness_mm, plate.material_id))


## Six faces forming an armoured box. Used for conning towers and barbettes, where
## approximating a cylinder with four flat sides is well inside the accuracy of
## everything else in the chain.
func _add_box_armour(t: ShipStructureTemplate, zone: String, centre: Vector3,
		size: Vector3, thickness_mm: float, material: String) -> void:
	var half: Vector3 = size * 0.5
	var sides: Array = [
		[Vector3(1, 0, 0), Vector3(0, 1, 0), half.y, half.z, half.x],
		[Vector3(-1, 0, 0), Vector3(0, 1, 0), half.y, half.z, half.x],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), half.x, half.z, half.y],
		[Vector3(0, -1, 0), Vector3(1, 0, 0), half.x, half.z, half.y],
		[Vector3(0, 0, 1), Vector3(1, 0, 0), half.x, half.y, half.z],
		[Vector3(0, 0, -1), Vector3(1, 0, 0), half.x, half.y, half.z],
	]
	for entry: Array in sides:
		var normal: Vector3 = entry[0]
		t.add_face(GeometryPrimitives.make_face(
			0, GeometryPrimitives.FaceKind.ARMOR, zone,
			centre + normal * float(entry[4]), normal, entry[1] as Vector3,
			float(entry[2]), float(entry[3]), thickness_mm, material))


# --------------------------------------------------------- turrets and barbettes --

func _build_turrets_and_barbettes(t: ShipStructureTemplate, spec: ShipSpec) -> void:
	if not spec.has_main_battery():
		return
	var face_plate: ArmourSchemeDef.Plate = spec.armour.plate("turretFace")
	var side_plate: ArmourSchemeDef.Plate = spec.armour.plate("turretSide")
	var roof_plate: ArmourSchemeDef.Plate = spec.armour.plate("turretRoof")
	var barbette: ArmourSchemeDef.Plate = spec.armour.plate("barbette")

	for mount: MountDef in spec.main_battery.mounts:
		var position: Vector2 = mount.local_position(spec.length_m, spec.beam_m)
		var width: float = clampf(spec.beam_m * 0.42, 3.0, 22.0)
		var height: float = clampf(width * 0.35, 1.5, 8.0)
		var centre: Vector3 = Vector3(position.x, position.y, t.main_deck_z + height * 0.5)

		# The turret is a component volume — something a shell can hit and wreck —
		# with its own armour faces around it. Face, sides and roof differ by a factor
		# of two or more on a real ship, and which one a shell strikes depends on where
		# the turret is trained, so they cannot be collapsed into one number.
		t.add_volume(GeometryPrimitives.make_volume(
			0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_TURRET,
			"Turret %s" % mount.mount_id,
			centre - Vector3(width * 0.6, width * 0.5, height * 0.5),
			centre + Vector3(width * 0.6, width * 0.5, height * 0.5)))

		var forward: Vector3 = Vector3(cos(mount.rest_bearing), sin(mount.rest_bearing), 0.0)
		if face_plate.is_armoured():
			t.add_face(GeometryPrimitives.make_face(
				0, GeometryPrimitives.FaceKind.ARMOR, "turretFace",
				centre + forward * width * 0.6, forward, Vector3(0, 0, 1),
				height * 0.5, width * 0.5, face_plate.thickness_mm, face_plate.material_id))
		if side_plate.is_armoured():
			for side: int in [-1, 1]:
				var side_normal: Vector3 = Vector3(-forward.y, forward.x, 0.0) * float(side)
				t.add_face(GeometryPrimitives.make_face(
					0, GeometryPrimitives.FaceKind.ARMOR, "turretSide",
					centre + side_normal * width * 0.5, side_normal, forward,
					width * 0.6, height * 0.5, side_plate.thickness_mm, side_plate.material_id))
			t.add_face(GeometryPrimitives.make_face(
				0, GeometryPrimitives.FaceKind.ARMOR, "turretSide",
				centre - forward * width * 0.6, -forward, Vector3(0, 0, 1),
				height * 0.5, width * 0.5, side_plate.thickness_mm, side_plate.material_id))
		if roof_plate.is_armoured():
			t.add_face(GeometryPrimitives.make_face(
				0, GeometryPrimitives.FaceKind.ARMOR, "turretRoof",
				centre + Vector3(0, 0, height * 0.5), Vector3.UP, forward,
				width * 0.6, width * 0.5, roof_plate.thickness_mm, roof_plate.material_id))

		# The barbette is the trunk down to the magazine. It is the route by which a
		# hit on a turret reaches the shell rooms, which is how more than one
		# battlecruiser was lost.
		if barbette.is_armoured():
			var trunk_top: float = t.main_deck_z
			var trunk_bottom: float = t.armour_deck_z - t.draft_m * 0.4
			_add_box_armour(t, "barbette",
				Vector3(position.x, position.y, (trunk_top + trunk_bottom) * 0.5),
				Vector3(width * 0.85, width * 0.85, trunk_top - trunk_bottom),
				barbette.thickness_mm, barbette.material_id)


# --------------------------------------------------------------- compartments --

## Subdivide the hull into watertight boxes and give each one a job.
##
## Roles are assigned from POSITION, not from a list. Magazines end up under the
## turrets because that is where a turret's ammunition has to be; machinery ends up
## amidships between them; the outboard strip below the waterline becomes torpedo
## protection where the design has any and fuel where it does not. Do the same thing
## to a player's design and the same reasoning applies, which is what makes a badly
## laid out custom ship genuinely badly laid out rather than merely labelled so.
func _build_compartments(t: ShipStructureTemplate, spec: ShipSpec) -> void:
	var hull: HullGeometry = spec.hull()
	var stations: int = maxi(int(_compartment_config.get("longitudinalStations", 14)), 4)
	var lanes: int = maxi(int(_compartment_config.get("transverseLanes", 3)), 1)

	# Deck boundaries: hold (below water), lower (waterline to armour deck), upper
	# (armour deck to main deck). The armour deck is the divide that matters, since
	# it is what a plunging shell must beat to reach the machinery.
	var deck_bounds: Array[float] = [t.keel_z, 0.0, t.armour_deck_z, t.main_deck_z]
	var turret_stations: Array[float] = []
	if spec.has_main_battery():
		for mount: MountDef in spec.main_battery.mounts:
			turret_stations.append(mount.station)

	var machinery_index: int = 0
	for i: int in stations:
		var station_a: float = lerpf(-0.5, 0.5, float(i) / float(stations))
		var station_b: float = lerpf(-0.5, 0.5, float(i + 1) / float(stations))
		var mid: float = (station_a + station_b) * 0.5
		var half_beam: float = hull.half_beam_at(mid)
		if half_beam <= 0.3:
			continue

		var inside_citadel: bool = mid >= t.citadel_aft and mid <= t.citadel_fore
		var outboard_width: float = half_beam / float(lanes)
		if spec.armour.has_torpedo_defence():
			outboard_width = minf(spec.armour.torpedo_defence_depth_m, half_beam * 0.5)

		for lane: int in lanes:
			var y_min: float = 0.0
			var y_max: float = 0.0
			if lanes == 1:
				y_min = -half_beam
				y_max = half_beam
			elif lane == 0:
				y_min = -half_beam
				y_max = -half_beam + outboard_width
			elif lane == lanes - 1:
				y_min = half_beam - outboard_width
				y_max = half_beam
			else:
				y_min = -half_beam + outboard_width
				y_max = half_beam - outboard_width
			var is_outboard: bool = (lanes > 1 and (lane == 0 or lane == lanes - 1))

			for deck: int in 3:
				var role: String = _role_for(
					spec, t, mid, is_outboard, deck, inside_citadel,
					turret_stations, machinery_index)
				if role == ROLE_BOILER or role == ROLE_ENGINE:
					machinery_index += 1
				t.add_volume(GeometryPrimitives.make_volume(
					0, GeometryPrimitives.VolumeKind.COMPARTMENT, role,
					"%s %d%s" % [role.capitalize(), i, ["P", "C", "S"][mini(lane, 2)]],
					Vector3(station_a * spec.length_m, y_min, deck_bounds[deck]),
					Vector3(station_b * spec.length_m, y_max, deck_bounds[deck + 1])))

	# Superstructure: where the bridge, directors and radar live. Unarmoured, exposed,
	# and the reason a non-penetrating hit can still blind a ship.
	var super_half: float = spec.length_m * 0.12
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPARTMENT, ROLE_FIRE_CONTROL, "Superstructure",
		Vector3(-super_half + spec.length_m * 0.05, -spec.beam_m * 0.25, t.main_deck_z),
		Vector3(super_half + spec.length_m * 0.05, spec.beam_m * 0.25, t.superstructure_top_z)))

	if spec.is_carrier():
		_add_hangar(t, spec)


func _role_for(
	spec: ShipSpec, t: ShipStructureTemplate, station: float, is_outboard: bool,
	deck: int, inside_citadel: bool, turret_stations: Array[float], machinery_index: int
) -> String:
	# Steering gear sits right aft, below the waterline, outside the citadel —
	# which is precisely why a torpedo aft is so often a mission kill.
	if station < t.citadel_aft - 0.02 and deck == 0:
		return ROLE_STEERING if station < -0.40 else ROLE_STORES

	if not inside_citadel:
		return ROLE_STORES if deck == 0 else ROLE_CREW

	if is_outboard:
		if deck == 0:
			return ROLE_BULGE if spec.armour.has_torpedo_defence() else ROLE_FUEL
		return ROLE_FUEL if deck == 1 else ROLE_CREW

	if deck >= 2:
		return ROLE_CREW

	# Magazines go under the turrets they serve.
	for turret_station: float in turret_stations:
		if absf(station - turret_station) < 0.055:
			return ROLE_MAGAZINE

	# Everything else amidships is machinery, alternating boiler and engine rooms the
	# way a real unit-machinery layout does, so a single hit cannot take out the whole
	# plant.
	return ROLE_BOILER if machinery_index % 2 == 0 else ROLE_ENGINE


func _add_hangar(t: ShipStructureTemplate, spec: ShipSpec) -> void:
	var hangar_length: float = float(spec.aviation.get("hangarLengthM", spec.length_m * 0.7))
	var hangar_width: float = float(spec.aviation.get("hangarWidthM", spec.beam_m * 0.7))
	var hangar_height: float = float(spec.aviation.get("hangarHeightM", 5.0))
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPARTMENT, ROLE_HANGAR, "Hangar",
		Vector3(-hangar_length * 0.5, -hangar_width * 0.5, t.main_deck_z),
		Vector3(hangar_length * 0.5, hangar_width * 0.5, t.main_deck_z + hangar_height)))


# ----------------------------------------------------------------- components --

## Machinery, steering and sensors, placed inside the compartments that house them.
##
## These are what a shell actually breaks. A hit that wrecks an engine room is a hit
## that destroyed the engines in it, and the speed loss follows from the engines being
## gone rather than from the compartment being labelled damaged.
func _build_components(t: ShipStructureTemplate, spec: ShipSpec) -> void:
	var engine_rooms: PackedInt32Array = t.volumes_with_role(ROLE_ENGINE)
	var boiler_rooms: PackedInt32Array = t.volumes_with_role(ROLE_BOILER)

	# One engine per shaft, spread through the engine rooms so losing one room does
	# not necessarily cost the whole plant.
	for i: int in maxi(spec.shafts, 1):
		if engine_rooms.is_empty():
			break
		var room: GeometryPrimitives.Volume = t.volumes[engine_rooms[i % engine_rooms.size()]]
		_add_component(t, COMPONENT_ENGINE, "Engine %d" % (i + 1), room, 0.5)

	for i: int in maxi(spec.boilers, 1):
		if boiler_rooms.is_empty():
			break
		var room: GeometryPrimitives.Volume = t.volumes[boiler_rooms[i % boiler_rooms.size()]]
		_add_component(t, COMPONENT_BOILER, "Boiler %d" % (i + 1), room, 0.45)

	# Shafts run aft from the engine rooms to the propellers, through the narrowest
	# part of the ship — which is why a hit right aft so often costs propulsion even
	# when the engines themselves are untouched.
	for i: int in maxi(spec.shafts, 1):
		var offset: float = 0.0
		if spec.shafts > 1:
			offset = (float(i) / float(spec.shafts - 1) - 0.5) * spec.beam_m * 0.5
		t.add_volume(GeometryPrimitives.make_volume(
			0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_SHAFT, "Shaft %d" % (i + 1),
			Vector3(-spec.length_m * 0.44, offset - 0.6, t.keel_z + 1.0),
			Vector3(-spec.length_m * 0.18, offset + 0.6, t.keel_z + 2.5)))

	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_RUDDER, "Steering gear",
		Vector3(-spec.length_m * 0.48, -spec.beam_m * 0.15, t.keel_z),
		Vector3(-spec.length_m * 0.40, spec.beam_m * 0.15, t.keel_z + 3.0)))

	# Directors and radar sit high and unarmoured. Losing them does not slow a ship
	# down or sink her; it stops her shooting straight, which is often decisive.
	var director_z: float = t.superstructure_top_z - 1.0
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_DIRECTOR, "Main director",
		Vector3(spec.length_m * 0.02, -2.0, director_z - 2.0),
		Vector3(spec.length_m * 0.06, 2.0, director_z)))
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_RADAR, "Radar",
		Vector3(spec.length_m * 0.02, -1.5, director_z),
		Vector3(spec.length_m * 0.05, 1.5, director_z + 2.0)))

	if spec.is_carrier():
		var elevators: int = maxi(int(spec.aviation.get("elevators", 2)), 1)
		for i: int in elevators:
			var x: float = lerpf(-0.3, 0.3, float(i) / maxf(float(elevators - 1), 1.0)) * spec.length_m
			t.add_volume(GeometryPrimitives.make_volume(
				0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_ELEVATOR,
				"Elevator %d" % (i + 1),
				Vector3(x - 6.0, -5.0, t.main_deck_z),
				Vector3(x + 6.0, 5.0, t.main_deck_z + 1.0)))


## Place a component inside a compartment, filling the given fraction of it.
func _add_component(t: ShipStructureTemplate, role: String, label: String,
		room: GeometryPrimitives.Volume, fill: float) -> void:
	var centre: Vector3 = room.centre()
	var half: Vector3 = room.size() * 0.5 * fill
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPONENT, role, label,
		centre - half, centre + half))
