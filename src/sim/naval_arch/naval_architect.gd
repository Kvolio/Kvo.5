class_name NavalArchitect
extends RefCounted

## Weighs a design, works out where its centre of gravity is, and says how fast it
## will go.
##
## Armour is not estimated. It is weighed from the ACTUAL PLATE GEOMETRY the structure
## builder produced — every face, its area, its thickness, its material density — so
## there is no armour coefficient to fudge. A design either has the plate or it does
## not, and if it has it, it carries it.
##
## That single decision is what makes the ship designer meaningful. Thicken the belt
## and the displacement rises, the draft increases, the speed falls and the centre of
## gravity moves; nothing in the code connects those consequences to each other,
## because the arithmetic already does.

## Bunkerage as a fraction of full load, for designs whose sources give no standard
## displacement. Around a sixth is typical of a WWII warship.
static func fuel_config_fraction(config: Dictionary) -> float:
	return float((config.get("fuel", {}) as Dictionary).get("fractionOfFullLoad", 0.16))


static func analyse(spec: ShipSpec, template: ShipStructureTemplate,
		materials: ArmourMaterials, armory: Armory, config: Dictionary) -> DesignAnalysis:
	var analysis: DesignAnalysis = DesignAnalysis.new()
	analysis.stated_displacement_t = spec.displacement_t
	analysis.stated_speed_kn = SimUnits.ms_to_knots(spec.max_speed_ms)

	var draft: float = spec.hydrostatic_draft()
	analysis.depth_m = template.main_deck_z - template.keel_z
	analysis.freeboard_m = template.main_deck_z
	analysis.length_to_beam = spec.length_m / maxf(spec.beam_m, 0.1)
	analysis.draft_to_beam = draft / maxf(spec.beam_m, 0.1)

	_weigh_hull(analysis, spec, config)
	_weigh_superstructure(analysis, template, config)
	_weigh_armour(analysis, template, materials, config)
	_weigh_machinery(analysis, spec, config)
	_weigh_armament(analysis, spec, armory, config)
	_weigh_complement(analysis, spec, config)

	analysis.light_displacement_t = 0.0
	for group: DesignAnalysis.WeightGroup in analysis.groups:
		analysis.light_displacement_t += group.tonnes

	# Fuel is the weight group that changes most between conditions, and the one the
	# designer trades against everything else.
	#
	# It comes from the DATA — full load less standard displacement, which is what the
	# difference between those two figures means — and not from whatever is left over
	# once everything else has been weighed. Treating it as the remainder made the
	# computed displacement equal the stated one by construction, so the model could
	# never be wrong and thickening a belt cost nothing but bunkerage. Now armour added
	# to a design makes her heavier, and heavier means slower, which is the entire point
	# of weighing anything.
	var fuel_tonnes: float = maxf(spec.displacement_t - spec.standard_displacement_t, 0.0)
	if spec.standard_displacement_t <= 0.0:
		# No standard figure in the sources: fall back to a typical bunkerage fraction.
		fuel_tonnes = spec.displacement_t * float(fuel_config_fraction(config))
	var fuel_config: Dictionary = config.get("fuel", {}) as Dictionary
	analysis.fuel_t = fuel_tonnes
	analysis.add_group("Fuel and reserve feed water", fuel_tonnes,
		analysis.depth_m * float(fuel_config.get("verticalCentreFraction", 0.22)))

	analysis.full_displacement_t = analysis.light_displacement_t + fuel_tonnes
	analysis.buoyancy_t = spec.hull().waterplane_area() * draft * spec.vertical_fullness \
		* SimUnits.SEAWATER_DENSITY * SimUnits.KG_TO_TONNE

	# Tonnes per metre of immersion: what one metre deeper is worth in displacement.
	# A ship heavier than her drawn draft allows does not fail to float, she settles
	# until she displaces her own weight, so this is the honest way to report it.
	var per_metre: float = spec.hull().waterplane_area() \
		* SimUnits.SEAWATER_DENSITY * SimUnits.KG_TO_TONNE
	analysis.sinkage_m = 0.0 if per_metre <= 0.0 else maxf(
		(analysis.full_displacement_t - analysis.buoyancy_t) / per_metre, 0.0)

	_compute_stability(analysis, spec, draft, config)
	_estimate_speed(analysis, spec, config)
	_estimate_volumes(analysis, spec, template, config)
	return analysis


## Hull structure by the cubic-number method: weight goes as length x beam x depth.
static func _weigh_hull(analysis: DesignAnalysis, spec: ShipSpec, config: Dictionary) -> void:
	var hull: Dictionary = config.get("hull", {}) as Dictionary
	var cubic_number: float = spec.length_m * spec.beam_m * analysis.depth_m
	var tonnes: float = float(hull.get("structureCoefficient", 105.0)) * cubic_number / 1000.0
	analysis.add_group("Hull structure", tonnes,
		analysis.depth_m * float(hull.get("structureVerticalCentreFraction", 0.48)))


## Bridge, funnels, masts and everything else standing above the main deck.
##
## Weighed from the superstructure's own geometry, like the armour, and for the same
## reason: it is the group that decides whether a ship is a steady gun platform. It is
## light — a couple of percent of displacement — but it sits higher above the keel than
## anything else aboard, so leaving it out put every ship's centre of gravity a metre
## and more too low and made them all read as improbably stiff. A destroyer suffered
## worst, because on her it is proportionally the largest thing above water.
static func _weigh_superstructure(analysis: DesignAnalysis, template: ShipStructureTemplate,
		config: Dictionary) -> void:
	var super_config: Dictionary = config.get("superstructure", {}) as Dictionary
	# Every compartment standing above the main deck: the deckhouse, the bridge tower,
	# the funnels and the after control position. Found by POSITION rather than by name,
	# so a design that arranges its upperworks differently is still weighed correctly.
	var volume: float = 0.0
	var moment: float = 0.0
	for block: GeometryPrimitives.Volume in template.volumes:
		if block.kind != GeometryPrimitives.VolumeKind.COMPARTMENT:
			continue
		if block.minimum.z < template.main_deck_z - 0.01:
			continue
		var block_volume: float = block.volume_m3()
		volume += block_volume
		moment += block_volume * block.centre().z
	var centre_z: float = template.main_deck_z if volume <= 0.0 else moment / volume

	# Plating first, from the enclosure the builder actually put there.
	var tonnes: float = 0.0
	for face: GeometryPrimitives.Face in template.faces:
		if face.zone != "superstructurePlating":
			continue
		tonnes += face.area_m2() * face.thickness_mm * SimUnits.MM_TO_M \
			* float(super_config.get("platingDensityKgM3", 7850.0)) * SimUnits.KG_TO_TONNE

	# Then what fills it: internal decks and bulkheads, the bridge, wiring, boats, masts
	# and funnel uptakes. A superstructure is mostly air, which is why this is per cubic
	# metre and why the number is small.
	tonnes += volume * float(super_config.get("fitOutTonnesPerM3", 0.075))
	tonnes *= float(super_config.get("internalStructureFactor", 2.6))
	analysis.add_group("Superstructure and upperworks", tonnes, centre_z - template.keel_z)


## Armour, weighed plate by plate from the geometry.
##
## No coefficient, no estimate. This is the number that makes protection cost
## something, and it has to come from what is actually there.
static func _weigh_armour(analysis: DesignAnalysis, template: ShipStructureTemplate,
		materials: ArmourMaterials, config: Dictionary) -> void:
	var armour_config: Dictionary = config.get("armour", {}) as Dictionary
	var allowance: float = float(armour_config.get("fittingAllowance", 1.08))
	var tonnes: float = 0.0
	var moment: float = 0.0

	for face: GeometryPrimitives.Face in template.faces:
		if face.kind != GeometryPrimitives.FaceKind.ARMOR or face.thickness_mm <= 0.0:
			continue
		var volume: float = face.area_m2() * face.thickness_mm * SimUnits.MM_TO_M
		var mass: float = volume * materials.density(face.material_id) * SimUnits.KG_TO_TONNE
		tonnes += mass
		# Height above the keel, for the centre of gravity.
		moment += mass * (face.centre.z - template.keel_z)

	tonnes *= allowance
	var centre: float = (analysis.depth_m * float(armour_config.get("verticalCentreFraction", 0.52))
		if tonnes <= 0.0 else (moment * allowance) / tonnes)
	analysis.add_group("Armour", tonnes, centre)


static func _weigh_machinery(analysis: DesignAnalysis, spec: ShipSpec, config: Dictionary) -> void:
	var machinery: Dictionary = config.get("machinery", {}) as Dictionary
	var specific: Dictionary = machinery.get("specificPowerKwPerTonne", {}) as Dictionary
	var per_tonne: float = float(specific.get(spec.machinery_type, specific.get("default", 25.0)))

	# Lighter ships got markedly more power per tonne of plant: a destroyer's machinery
	# was optimised for weight above everything, while a battleship's carried
	# redundancy, huge reduction gears and subdivided armoured spaces. Without this
	# scaling a Fletcher's engines come out at 56% of her displacement.
	var reference: float = float(machinery.get("referenceDisplacementT", 57540.0))
	var exponent: float = float(machinery.get("displacementExponent", 0.256))
	if spec.displacement_t > 0.0 and reference > 0.0:
		per_tonne *= pow(reference / spec.displacement_t, exponent)

	var tonnes: float = (spec.propulsion_power_w / 1000.0) / maxf(per_tonne, 1.0)
	analysis.add_group("Machinery", tonnes,
		analysis.depth_m * float(machinery.get("verticalCentreFraction", 0.30)))


## Guns, mountings, hoists and their ammunition. Armour is excluded — it is weighed
## from the plate geometry instead, and counting it twice would make every armoured
## turret cost double.
static func _weigh_armament(analysis: DesignAnalysis, spec: ShipSpec, armory: Armory,
		config: Dictionary) -> void:
	var armament: Dictionary = config.get("armament", {}) as Dictionary
	var per_cubed: float = float(armament.get("barrelTonnesPerCalibreCubed", 1.8))
	var mounting: float = float(armament.get("mountingFactor", 3.5))
	var ammunition: Dictionary = armament.get("ammunitionTonnesPerBarrel", {}) as Dictionary
	var ammunition_per_cubed: float = float(ammunition.get("perCalibreCubed", 0.9))

	var tonnes: float = 0.0
	for battery: BatteryDef in [spec.main_battery, spec.secondary_battery]:
		if battery == null or battery.is_empty():
			continue
		var gun: GunDef = armory.get_gun(battery.gun_id) if armory != null else null
		if gun == null:
			continue
		var calibre_mm: float = gun.calibre_m * 1000.0
		# Gun weight goes as the cube of calibre. This is why a 16-inch battery costs
		# so enormously much more than a 14-inch one for two inches of shell.
		var cubed: float = pow(calibre_mm, 3.0) / 1.0e6
		var barrels: float = float(battery.total_barrels())
		tonnes += barrels * cubed * per_cubed * mounting
		tonnes += barrels * cubed * ammunition_per_cubed

	if spec.has_torpedoes():
		tonnes += float(spec.torpedo_battery.total_tubes()) \
			* float(armament.get("torpedoMountTonnesPerTube", 3.2))

	# Anti-aircraft outfits are summarised as barrel counts in the data, so they are
	# weighed from calibre in the same way.
	for entry: Variant in spec.anti_air:
		var mount: Dictionary = entry as Dictionary
		var calibre: float = float(mount.get("calibreMm", 20.0))
		tonnes += float(mount.get("count", 0)) * pow(calibre, 3.0) / 1.0e6 * per_cubed * mounting

	analysis.add_group("Armament", tonnes,
		analysis.depth_m * float(armament.get("verticalCentreFraction", 0.80)))


static func _weigh_complement(analysis: DesignAnalysis, spec: ShipSpec, config: Dictionary) -> void:
	var complement: Dictionary = config.get("complement", {}) as Dictionary
	analysis.add_group("Crew, stores and provisions",
		float(spec.crew) * float(complement.get("tonnesPerPerson", 0.18)),
		analysis.depth_m * float(complement.get("verticalCentreFraction", 0.62)))


## GM = KB + BM - KG, all measured from the keel.
##
## KG comes from the weight groups rather than being assumed, which is what makes a
## top-heavy design genuinely top-heavy: pile armour on the turrets and the centre of
## gravity rises until she is a bad gun platform, and nothing had to be told to do that.
static func _compute_stability(analysis: DesignAnalysis, spec: ShipSpec, draft: float,
		config: Dictionary) -> void:
	var stability: Dictionary = config.get("stability", {}) as Dictionary
	var total: float = 0.0
	var moment: float = 0.0
	for group: DesignAnalysis.WeightGroup in analysis.groups:
		total += group.tonnes
		moment += group.moment()
	analysis.kg_m = 0.0 if total <= 0.0 else moment / total

	analysis.kb_m = draft * float(stability.get("kbDraftFraction", 0.53))

	# BM = I / V. A wider ship has vastly more of it, since beam enters cubed — which
	# is why beam is the cheapest stability there is and why it costs speed.
	#
	# The inertia is integrated over the hull's real stations, not taken from a form
	# coefficient. One coefficient cannot describe a destroyer's fine waterplane and a
	# battleship's full one at once, and assuming a single value made every ship but the
	# one it was fitted to read as far stiffer than she was.
	var inertia: float = spec.hull().waterplane_inertia()
	var displaced_volume: float = maxf(
		analysis.full_displacement_t * SimUnits.TONNE_TO_KG / SimUnits.SEAWATER_DENSITY, 1.0)
	analysis.bm_m = inertia / displaced_volume
	analysis.gm_m = analysis.kb_m + analysis.bm_m - analysis.kg_m


## Speed from power via the Admiralty coefficient.
static func _estimate_speed(analysis: DesignAnalysis, spec: ShipSpec, config: Dictionary) -> void:
	var speed: Dictionary = config.get("speed", {}) as Dictionary
	var coefficients: Dictionary = speed.get("admiraltyCoefficient", {}) as Dictionary
	var coefficient: float = float(coefficients.get(spec.ship_type, coefficients.get("default", 270.0)))
	# A finer hull does better than its type alone suggests.
	coefficient += float(speed.get("lengthToBeamBonusPerUnit", 6.0)) \
		* maxf(analysis.length_to_beam - 8.0, 0.0)

	var shp: float = spec.propulsion_power_w / SimUnits.SHP_TO_W
	var displacement: float = maxf(analysis.full_displacement_t, 1.0)
	var knots_cubed: float = shp * coefficient / pow(displacement, 2.0 / 3.0)
	analysis.estimated_speed_kn = pow(maxf(knots_cubed, 0.0), 1.0 / 3.0)


static func _estimate_volumes(analysis: DesignAnalysis, spec: ShipSpec,
		template: ShipStructureTemplate, config: Dictionary) -> void:
	var machinery: Dictionary = config.get("machinery", {}) as Dictionary
	analysis.machinery_volume_m3 = (spec.propulsion_power_w / 1000.0) \
		* float(machinery.get("spacePerKwM3", 0.055))
	var available: float = 0.0
	for role: String in [ShipStructureBuilder.ROLE_ENGINE, ShipStructureBuilder.ROLE_BOILER]:
		for index: int in template.volumes_with_role(role):
			available += template.volumes[index].volume_m3()
	analysis.available_volume_m3 = available
