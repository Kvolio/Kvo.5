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
const COMPONENT_FLIGHT_DECK: String = "flight_deck"

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

	# The weather deck, in three parts: an armoured stretch over the citadel and thin
	# plating fore and aft of it. Armour was worked over the vitals, not from stem to
	# stern — carrying it the whole length was thousands of tonnes on a battleship, and
	# it also meant a shell landing on the forecastle met deck armour that was never
	# there. The ends are plating, and the tracer treats them as such.
	var deck_material: String = spec.armour.plate("deckWeather").material_id
	var deck_mm: float = spec.armour.thickness_mm("deckWeather")
	var plating: float = _plating_thickness(spec)
	var deck_sections: Array = []
	if deck_mm > 0.0:
		var mid: float = (t.citadel_fore + t.citadel_aft) * 0.5 * spec.length_m
		var half: float = (t.citadel_fore - t.citadel_aft) * 0.5 * spec.length_m
		deck_sections.append([mid, half, maxf(deck_mm, plating), deck_material, true])
		# Forward of the citadel, then aft of it.
		var fore_half: float = (0.5 - t.citadel_fore) * 0.5 * spec.length_m
		var aft_half: float = (t.citadel_aft + 0.5) * 0.5 * spec.length_m
		deck_sections.append([mid + half + fore_half, fore_half, plating, "structural_steel", false])
		deck_sections.append([mid - half - aft_half, aft_half, plating, "structural_steel", false])
	else:
		deck_sections.append([0.0, spec.length_m * 0.5, plating, "structural_steel", false])

	for section: Array in deck_sections:
		if float(section[1]) <= 0.01:
			continue
		# Width follows the hull's mean beam over the stretch, not the widest section.
		var station_centre: float = float(section[0]) / spec.length_m
		var station_half: float = float(section[1]) / spec.length_m
		var mean_half_beam: float = 0.0
		for i: int in 5:
			mean_half_beam += hull.half_beam_at(
				station_centre + lerpf(-station_half, station_half, float(i) / 4.0))
		mean_half_beam /= 5.0
		t.add_face(GeometryPrimitives.make_face(
			0, GeometryPrimitives.FaceKind.ARMOR if bool(section[4]) else GeometryPrimitives.FaceKind.HULL,
			"deckWeather",
			Vector3(float(section[0]), 0.0, t.main_deck_z), Vector3.UP, Vector3(1.0, 0.0, 0.0),
			float(section[1]), mean_half_beam,
			float(section[2]), str(section[3])))

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
	# Decks span the citadel, but the hull narrows towards its ends, so the plate area
	# follows the AVERAGE half-beam rather than the widest section. Using the maximum
	# added several thousand tonnes of deck armour that was never fitted.
	var citadel_mean_beam: float = 0.0
	for i: int in 9:
		citadel_mean_beam += hull.half_beam_at(
			lerpf(t.citadel_aft, t.citadel_fore, float(i) / 8.0))
	citadel_mean_beam /= 9.0

	# --- main belt -----------------------------------------------------------
	#
	# A belt is not a slab. It carries its full thickness over the strake around the
	# waterline, where it has to stop a shell arriving directly, and tapers away below
	# that, where its job is only to catch shells that fell short and travelled on
	# underwater. Building it as one full-thickness plate was worth thousands of tonnes
	# of armour no ship ever carried, and — worse — meant a hit low on the belt met the
	# full plate. The taper is recorded per ship; where a scheme does not state one,
	# `lower_edge_thickness_mm` defaults to the full thickness and this emits one plate
	# exactly as before.
	var belt_bottom: float = -spec.draft_m * float(
		_hull_config.get("beltBottomDraftFraction", 0.55))
	var belt: ArmourSchemeDef.Plate = spec.armour.plate("belt")
	if belt.is_armoured():
		# The belt's top edge meets the armoured deck, because between them they ARE the
		# citadel: a box of vertical plate closed by a horizontal one. Running the belt
		# on up to the main deck made it a storey taller than the box it encloses, which
		# was the single largest source of phantom armour weight. What covers the side
		# above the armoured deck is the upper belt, where the design has one, and thin
		# plating where it does not.
		var belt_top: float = t.armour_deck_z
		var belt_height: float = belt_top - belt_bottom
		# How much of the belt, measured down from the top, is at full thickness.
		var full_fraction: float = clampf(
			float(_hull_config.get("beltFullThicknessFraction", 0.45)), 0.05, 1.0)
		var strakes: Array = []
		if belt.is_tapered():
			var full_height: float = belt_height * full_fraction
			strakes.append([belt_top - full_height * 0.5, full_height, belt.thickness_mm])
			# The tapering strake is one plate at its MEAN thickness. Its weight and its
			# average resistance are both right; resolving the true wedge would mean a
			# thickness that varies across a single face, which no other plate needs.
			var taper_height: float = belt_height - full_height
			strakes.append([belt_bottom + taper_height * 0.5, taper_height,
				(belt.thickness_mm + belt.lower_edge_thickness_mm) * 0.5])
		else:
			strakes.append([(belt_top + belt_bottom) * 0.5, belt_height, belt.thickness_mm])

		for side: int in [-1, 1]:
			# An inclined belt leans inboard at the top, which is why it presents more
			# effective thickness to a flat trajectory and LESS to a plunging one.
			# Tilting the normal is all that takes; no special case downstream.
			var normal: Vector3 = Vector3(
				0.0,
				float(side) * cos(belt.inclination_rad),
				sin(belt.inclination_rad)).normalized()
			for strake: Array in strakes:
				t.add_face(GeometryPrimitives.make_face(
					0, GeometryPrimitives.FaceKind.ARMOR, "belt",
					Vector3(citadel_x, citadel_half_beam * 0.97 * float(side),
						float(strake[0])),
					normal, Vector3(1.0, 0.0, 0.0),
					citadel_half, float(strake[1]) * 0.5,
					float(strake[2]), belt.material_id))

	# --- upper belt ----------------------------------------------------------
	var upper: ArmourSchemeDef.Plate = spec.armour.plate("upperBelt")
	if upper.is_armoured():
		# Starts where the main belt stops, so the two together cover the side without
		# a gap and without overlapping.
		var upper_bottom: float = t.armour_deck_z
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
	_add_deck(t, spec, "deckMain", t.armour_deck_z, citadel_x, citadel_half, citadel_mean_beam)
	_add_deck(t, spec, "deckSplinter",
		t.armour_deck_z - t.draft_m * float(_hull_config.get("splinterDeckDraftFraction", 0.18)),
		citadel_x, citadel_half, citadel_mean_beam)

	# --- transverse bulkheads closing the citadel ----------------------------
	_add_bulkhead(t, spec, "bulkheadFore", t.citadel_fore, hull, belt_bottom)
	_add_bulkhead(t, spec, "bulkheadAft", t.citadel_aft, hull, belt_bottom)

	# --- torpedo bulkhead ----------------------------------------------------
	# The holding bulkhead runs from the bottom up to where the main belt takes over.
	# The two together cover the side from keel to armoured deck, and the joint between
	# them is a real weak point rather than a modelling artefact — Yamato's data says so
	# in as many words. Running it all the way to the waterline instead overlapped the
	# belt and, on a ship whose lower belt IS her holding bulkhead, doubled the heaviest
	# plate she carried below water.
	var torpedo: ArmourSchemeDef.Plate = spec.armour.plate("torpedoBulkhead")
	if torpedo.is_armoured() and spec.armour.has_torpedo_defence():
		var inboard: float = maxf(citadel_half_beam - spec.armour.torpedo_defence_depth_m, 1.0)
		var tb_top: float = minf(belt_bottom, -0.5)
		var tb_height: float = maxf(tb_top - t.keel_z, 1.0)
		for side: int in [-1, 1]:
			t.add_face(GeometryPrimitives.make_face(
				0, GeometryPrimitives.FaceKind.ARMOR, "torpedoBulkhead",
				Vector3(citadel_x, inboard * float(side), tb_top - tb_height * 0.5),
				Vector3(0.0, float(side), 0.0), Vector3(1.0, 0.0, 0.0),
				citadel_half, tb_height * 0.5,
				torpedo.thickness_mm, torpedo.material_id))

	# --- conning tower -------------------------------------------------------
	var conning: ArmourSchemeDef.Plate = spec.armour.plate("conningTower")
	if conning.is_armoured():
		var ct_size: float = clampf(spec.beam_m * 0.22, 2.0, 8.0)
		var ct_centre: Vector3 = Vector3(
			spec.length_m * 0.06, 0.0,
			t.main_deck_z + (t.superstructure_top_z - t.main_deck_z) * 0.45)
		_add_cylinder_armour(t, "conningTower", ct_centre,
			Vector3(ct_size, ct_size, ct_size * 1.2),
			conning.thickness_mm, conning.material_id, true)


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


## A transverse bulkhead closing one end of the armoured citadel.
##
## It spans the citadel's own envelope — from the belt's lower edge up to the armoured
## deck — because that is the box it closes. Running it all the way to the keel made it
## a full-depth slab of belt-grade plate across the ship, which is neither what was
## fitted nor what a shell entering the citadel actually has to get through.
func _add_bulkhead(t: ShipStructureTemplate, spec: ShipSpec, zone: String,
		station: float, hull: HullGeometry, belt_bottom: float) -> void:
	var plate: ArmourSchemeDef.Plate = spec.armour.plate(zone)
	if not plate.is_armoured():
		return
	var half_beam: float = hull.half_beam_at(station)
	var top: float = t.armour_deck_z
	var bottom: float = minf(belt_bottom, top - 1.0)
	t.add_face(GeometryPrimitives.make_face(
		0, GeometryPrimitives.FaceKind.ARMOR, zone,
		Vector3(station * spec.length_m, 0.0, (top + bottom) * 0.5),
		Vector3(signf(station), 0.0, 0.0), Vector3(0.0, 1.0, 0.0),
		half_beam, (top - bottom) * 0.5,
		plate.thickness_mm, plate.material_id))


## An armoured cylinder, approximated by four flat sides. Used for barbettes and
## conning towers.
##
## The four faces are sized so their total area equals the CYLINDER'S, not the box's.
## Four faces the full width of the trunk would give 4d of circumference where a
## cylinder has pi*d — 27% too much plate, which on three barbettes of 439 mm is over
## a thousand tonnes of armour a real ship never carried.
##
## `roofed` controls whether a top plate is fitted. A barbette has none: it is a trunk
## through the decks with a turret sitting on top of it, and giving it a floor and a
## ceiling of belt-thickness armour was most of why Iowa first came out 14,000 tonnes
## overweight.
func _add_cylinder_armour(t: ShipStructureTemplate, zone: String, centre: Vector3,
		size: Vector3, thickness_mm: float, material: String, roofed: bool = false) -> void:
	var half: Vector3 = size * 0.5
	# A quarter of the circumference per face, halved again for the half-extent.
	var arc_half: float = size.x * PI * 0.25 * 0.5
	var sides: Array = [
		[Vector3(1, 0, 0), Vector3(0, 1, 0), arc_half, half.z, half.x],
		[Vector3(-1, 0, 0), Vector3(0, 1, 0), arc_half, half.z, half.x],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), arc_half, half.z, half.y],
		[Vector3(0, -1, 0), Vector3(1, 0, 0), arc_half, half.z, half.y],
	]
	if roofed:
		sides.append([Vector3(0, 0, 1), Vector3(1, 0, 0), half.x * 0.886, half.y * 0.886, half.z])
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
			_add_cylinder_armour(t, "barbette",
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

	_build_superstructure(t, spec)

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


## Six thin STRUCTURE faces around a box. Not armour — it exists so a shell passing
## through unarmoured upperworks has something to interact with.
## The superstructure, as the several distinct things it actually is.
##
## One box amidships was the old model, and it was wrong in a way that mattered to more
## than the picture: a shell crossing the bridge, a shell going through a funnel uptake
## and a shell into the after control position are three different events, and a single
## slab could not tell them apart. Now a low deckhouse runs the length of it with a
## bridge tower, the funnels and an after tower standing on top — so what a shell meets
## depends on where it lands, which is the whole premise.
##
## The funnels are voids for damage purposes, because that is what they are: a hit
## through an uptake makes a hole in some thin plate and does very little else, which is
## why ships came home with funnels shot through.
func _build_superstructure(t: ShipStructureTemplate, spec: ShipSpec) -> void:
	var deck: float = t.main_deck_z
	var height: float = t.superstructure_top_z - deck

	# Where it goes is not a constant: it fills the gap the main battery leaves. Ships
	# were laid out that way round — the turrets and their magazines claim their places
	# first and the superstructure takes what is left between them — and deriving it the
	# same way means an unusual turret arrangement in the designer gets its bridge in the
	# right place instead of standing inside B turret.
	var span: Vector2 = _superstructure_span(spec)
	var centre_x: float = (span.x + span.y) * 0.5 * spec.length_m
	var half_length: float = (span.y - span.x) * 0.5 * spec.length_m * 0.5

	# A continuous deckhouse, wide and low, with everything else standing on it.
	_add_superstructure_block(t, ROLE_FIRE_CONTROL, "Superstructure deckhouse",
		spec, centre_x, half_length * 2.0, spec.beam_m * 0.5, deck, height * 0.42)

	# The bridge tower: forward, narrower, and the tallest thing aboard bar the masts.
	# It is where the directors and the radar sit, which is why losing it blinds a ship
	# without slowing her down.
	t.bridge_x = centre_x + half_length * 0.52
	_add_superstructure_block(t, ROLE_FIRE_CONTROL, "Bridge tower",
		spec, t.bridge_x, half_length * 0.72, spec.beam_m * 0.32,
		deck + height * 0.42, height * 0.58)

	# Funnels. How many is a real feature of a design rather than a drawing detail —
	# it follows the boiler arrangement — so it comes from the data where the data says.
	var funnels: int = maxi(spec.funnels, 1)
	for i: int in funnels:
		var offset: float = 0.0 if funnels == 1 else \
			lerpf(-0.30, 0.18, float(i) / float(funnels - 1))
		_add_superstructure_block(t, ROLE_VOID,
			"Funnel" if funnels == 1 else "Funnel %d" % (i + 1),
			spec, centre_x + half_length * offset, half_length * 0.34,
			spec.beam_m * 0.20, deck + height * 0.42, height * 0.50)

	# The after control position, from which she can still be fought if the bridge goes.
	t.after_superstructure_x = centre_x - half_length * 0.62
	_add_superstructure_block(t, ROLE_FIRE_CONTROL, "After superstructure",
		spec, t.after_superstructure_x, half_length * 0.56, spec.beam_m * 0.28,
		deck + height * 0.42, height * 0.38)


## The stations the superstructure runs between, as fractions of length.
##
## The widest gap between adjacent main-battery mounts, less the room the turrets
## themselves need to train. A ship with no main battery gets the middle of her length.
func _superstructure_span(spec: ShipSpec) -> Vector2:
	var default_span: Vector2 = Vector2(-0.07, 0.17)
	if not spec.has_main_battery() or spec.main_battery.mounts.size() < 2:
		return default_span

	var stations: Array[float] = []
	for mount: MountDef in spec.main_battery.mounts:
		stations.append(mount.station)
	stations.sort()

	# Turrets need room to train, so the superstructure cannot butt against one.
	var clearance: float = spec.beam_m * 0.42 / maxf(spec.length_m, 1.0)
	var best: Vector2 = default_span
	var best_width: float = 0.0
	for i: int in range(stations.size() - 1):
		var low: float = stations[i] + clearance
		var high: float = stations[i + 1] - clearance
		if high - low > best_width:
			best_width = high - low
			best = Vector2(low, high)
	return best if best_width > 0.08 else default_span


## One block of superstructure: a volume something can be inside, wrapped in the thin
## plating that makes a shell interact with it at all. Without faces here a shell would
## cross the bridge without touching anything, and a hit that should wreck the fire
## control would do literally nothing.
func _add_superstructure_block(t: ShipStructureTemplate, role: String, label: String,
		spec: ShipSpec, centre_x: float, length: float, width: float,
		base_z: float, height: float) -> void:
	var centre: Vector3 = Vector3(centre_x, 0.0, base_z + height * 0.5)
	var size: Vector3 = Vector3(length, width, height)
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPARTMENT, role, label,
		centre - size * 0.5, centre + size * 0.5))
	_add_light_enclosure(t, "superstructurePlating", centre, size,
		_plating_thickness(spec) * 0.6)


func _add_light_enclosure(t: ShipStructureTemplate, zone: String, centre: Vector3,
		size: Vector3, thickness_mm: float) -> void:
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
			0, GeometryPrimitives.FaceKind.STRUCTURE, zone,
			centre + normal * float(entry[4]), normal, entry[1] as Vector3,
			float(entry[2]), float(entry[3]), thickness_mm, "structural_steel"))


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
	# Fore and after directors. Warships carried both precisely so that one hit could
	# not blind them, and a battery can still be fought in local control from the
	# turrets afterwards — which is why losing one is a serious degradation rather
	# than the end of the action.
	# They sit ON the towers, not at fixed stations of their own: a main director is on
	# top of the bridge and the after one on the after control position. Placing them
	# independently left them standing beside the superstructure on any ship whose
	# battery layout moved it.
	var director_z: float = t.superstructure_top_z - 1.0
	var reach: float = maxf(spec.length_m * 0.02, 2.0)
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_DIRECTOR, "Forward director",
		Vector3(t.bridge_x - reach, -2.0, director_z - 2.0),
		Vector3(t.bridge_x + reach, 2.0, director_z)))
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_DIRECTOR, "After director",
		Vector3(t.after_superstructure_x - reach, -2.0, t.main_deck_z + 2.0),
		Vector3(t.after_superstructure_x + reach, 2.0, t.main_deck_z + 5.0)))
	t.add_volume(GeometryPrimitives.make_volume(
		0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_RADAR, "Radar",
		Vector3(t.bridge_x - reach * 0.7, -1.5, director_z),
		Vector3(t.bridge_x + reach * 0.7, 1.5, director_z + 2.0)))

	if spec.is_carrier():
		# The flight deck is an ordinary component, wrecked by ordinary means. The
		# damage core knows only that a large thin thing on top of the ship has been
		# broken; that this stops her flying is something only the air module knows,
		# and it reads it from here.
		var deck_length: float = float(spec.aviation.get("flightDeckLengthM", spec.length_m * 0.95))
		var deck_width: float = float(spec.aviation.get("flightDeckWidthM", spec.beam_m * 0.85))
		t.add_volume(GeometryPrimitives.make_volume(
			0, GeometryPrimitives.VolumeKind.COMPONENT, COMPONENT_FLIGHT_DECK, "Flight deck",
			Vector3(-deck_length * 0.5, -deck_width * 0.5, t.main_deck_z),
			Vector3(deck_length * 0.5, deck_width * 0.5, t.main_deck_z + 0.4)))

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
