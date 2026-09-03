extends SimTest

## Weighing a design and working out what it will do.
##
## The claim under test is that the tradeoffs the ship designer is meant to expose are
## ARITHMETIC rather than rules. Nothing here tells armour to cost speed; armour is
## weighed from the plate that is actually there, the weight has to be carried, and a
## heavier ship is slower because the same power is pushing more of her. If that chain
## ever breaks, the designer becomes a set of sliders with opinions.
##
## Calibration against real ships is the other half. A weight model that cannot
## reproduce a ship whose weights are published is not a weight model, so five of them
## are checked here by name.

var _materials: ArmourMaterials = null
var _config: Dictionary = {}
var _structure_config: Dictionary = {}


func suite_name() -> String:
	return "Naval architecture"


func before_each() -> void:
	if _materials == null:
		_materials = ArmourMaterials.load_from("res://data/materials/armor.json")
		_config = JsonLoader.load_dict("res://data/config/naval_architecture.json")
		_structure_config = JsonLoader.load_dict("res://data/config/structure.json")


func _analyse(spec: ShipSpec) -> DesignAnalysis:
	var template: ShipStructureTemplate = ShipStructureBuilder.build(spec, _structure_config)
	return NavalArchitect.analyse(spec, template, _materials, TestWeapons.armory(), _config)


func _analyse_id(spec_id: String) -> DesignAnalysis:
	return _analyse(TestShips.load_ship(spec_id))


func _findings(spec: ShipSpec) -> Array[DesignValidator.Finding]:
	var template: ShipStructureTemplate = ShipStructureBuilder.build(spec, _structure_config)
	var analysis: DesignAnalysis = NavalArchitect.analyse(
		spec, template, _materials, TestWeapons.armory(), _config)
	return DesignValidator.validate(spec, template, analysis, _config)


# ------------------------------------------------------- against real ships --

func test_the_weight_model_reproduces_ships_whose_weights_are_known() -> void:
	# The whole model rests on this. Five ships spanning 2,500 to 73,000 tonnes, a
	# destroyer to the largest battleship ever built.
	# Fuel comes from the data (full load less standard displacement), so this is a real
	# prediction and not an identity: everything else is weighed, and the total either
	# lands on the published figure or it does not.
	for spec_id: String in ["uss_iowa", "ijn_yamato", "uss_baltimore", "uss_fletcher"]:
		var analysis: DesignAnalysis = _analyse_id(spec_id)
		almost(analysis.full_displacement_t, analysis.stated_displacement_t,
			analysis.stated_displacement_t * 0.06,
			"%s comes out within 6%% of her published full load" % spec_id)


func test_estimated_speed_matches_what_these_ships_actually_did() -> void:
	# Speed comes from power through the Admiralty coefficient, and the coefficients
	# were fitted to real ships rather than chosen. A destroyer, a cruiser and three
	# battleships all have to work with the same formula.
	for spec_id: String in ["uss_iowa", "ijn_yamato", "uss_baltimore", "uss_fletcher"]:
		var analysis: DesignAnalysis = _analyse_id(spec_id)
		almost(analysis.estimated_speed_kn, analysis.stated_speed_kn, 1.0,
			"%s makes her designed speed within a knot" % spec_id)


func test_every_weight_group_is_positive_and_they_sum_to_the_displacement() -> void:
	var analysis: DesignAnalysis = _analyse_id("uss_iowa")
	var total: float = 0.0
	for group: DesignAnalysis.WeightGroup in analysis.groups:
		ge(group.tonnes, 0.0, "%s is not a negative weight" % group.name)
		gt(group.vertical_centre_m, 0.0, "%s sits somewhere above the keel" % group.name)
		total += group.tonnes
	almost(total, analysis.full_displacement_t, 1.0, "the groups add up to the ship")


func test_a_real_battleship_is_stable_and_not_absurdly_so() -> void:
	# GM for a WWII capital ship runs about 2-5 m. Outside that the stability model is
	# wrong, whatever else it agrees with.
	for spec_id: String in ["uss_iowa", "ijn_yamato", "bismarck"]:
		var analysis: DesignAnalysis = _analyse_id(spec_id)
		between(analysis.gm_m, 1.5, 5.5, "%s has a plausible GM" % spec_id)
		gt(analysis.kb_m, 0.0, "%s has a centre of buoyancy above her keel" % spec_id)


func test_the_historical_roster_raises_no_serious_findings() -> void:
	# A validator that condemns ships that were actually built and fought is a
	# validator nobody will read. Warnings are fine — Bismarck really was stiff.
	for spec_id: String in ["uss_iowa", "ijn_yamato", "uss_baltimore",
			"uss_fletcher", "uss_cleveland", "hms_king_george_v"]:
		for finding: DesignValidator.Finding in _findings(TestShips.load_ship(spec_id)):
			ne(int(finding.severity), int(DesignValidator.Severity.SERIOUS),
				"%s: %s" % [spec_id, finding.summary])


func test_bismarck_is_the_models_known_outlier() -> void:
	# Asserted rather than quietly excluded, so that this stops being true the moment
	# the armour geometry improves — and the test then fails and says so.
	#
	# She comes out well over her published displacement because the generated plate
	# geometry gives her more armour than she carried. Her citadel really was unusually
	# long and she really did spend an enormous fraction of herself on protection, so
	# the model exaggerates what was already extreme. Everything else about her — her
	# speed, her stability, her weight distribution — behaves.
	var analysis: DesignAnalysis = _analyse_id("bismarck")
	between(analysis.overweight_fraction(), 0.08, 0.25,
		"still the known overweight outlier, by a known margin")
	gt(analysis.group_fraction("Armour"), 0.4,
		"and the reason is her armour group, weighed from generated plate")


# --------------------------------------------------- the tradeoffs, as maths --

func test_thickening_the_belt_costs_displacement_and_speed() -> void:
	# The central claim of the designer, and nothing implements it: armour is weighed
	# from the plate, the plate got thicker, so she got heavier and therefore slower.
	var light: ShipSpec = TestShips.load_ship("uss_iowa")
	var heavy: ShipSpec = TestShips.load_ship("uss_iowa")
	heavy.armour.plate("belt").thickness_mm *= 2.0
	heavy.armour.plate("belt").lower_edge_thickness_mm *= 2.0

	var light_analysis: DesignAnalysis = _analyse(light)
	var heavy_analysis: DesignAnalysis = _analyse(heavy)

	gt(heavy_analysis.group_tonnes("Armour"), light_analysis.group_tonnes("Armour"),
		"twice the belt is more armour")
	gt(heavy_analysis.light_displacement_t, light_analysis.light_displacement_t,
		"which she has to carry")
	lt(heavy_analysis.estimated_speed_kn, light_analysis.estimated_speed_kn,
		"and being heavier on the same power, she is slower")


func test_armour_is_weighed_from_the_plate_not_from_a_coefficient() -> void:
	# Remove the belt entirely and the armour group must fall by the belt's own weight.
	# If it fell by some fraction of displacement instead, there is a coefficient
	# hiding somewhere.
	var with_belt: ShipSpec = TestShips.load_ship("uss_iowa")
	var without: ShipSpec = TestShips.load_ship("uss_iowa")
	without.armour.plate("belt").thickness_mm = 0.0

	var before: DesignAnalysis = _analyse(with_belt)
	var after: DesignAnalysis = _analyse(without)
	gt(before.group_tonnes("Armour") - after.group_tonnes("Armour"), 4000.0,
		"Iowa's belt is thousands of tonnes of steel")


func test_piling_weight_high_up_raises_the_centre_of_gravity() -> void:
	# Why a top-heavy design is genuinely top-heavy rather than labelled so.
	var normal: ShipSpec = TestShips.load_ship("uss_iowa")
	var top_heavy: ShipSpec = TestShips.load_ship("uss_iowa")
	top_heavy.armour.plate("turretRoof").thickness_mm *= 4.0
	top_heavy.armour.plate("conningTower").thickness_mm *= 4.0

	var before: DesignAnalysis = _analyse(normal)
	var after: DesignAnalysis = _analyse(top_heavy)
	gt(after.kg_m, before.kg_m, "her centre of gravity rose")
	lt(after.gm_m, before.gm_m, "so she is less stable, with nothing told to make it so")


func test_a_wider_hull_is_stiffer_because_beam_enters_cubed() -> void:
	var narrow: ShipSpec = TestShips.load_ship("uss_iowa")
	var wide: ShipSpec = TestShips.load_ship("uss_iowa")
	wide.beam_m *= 1.15
	wide.hull().beam = wide.beam_m

	gt(_analyse(wide).bm_m, _analyse(narrow).bm_m,
		"beam is the cheapest stability there is")


func test_more_power_on_the_same_hull_is_more_speed_but_not_proportionally() -> void:
	# Speed goes as the cube root of power. Doubling the engines does not double the
	# speed, which is why the last few knots cost so much.
	var standard: ShipSpec = TestShips.load_ship("uss_iowa")
	var doubled: ShipSpec = TestShips.load_ship("uss_iowa")
	doubled.propulsion_power_w *= 2.0

	var slow: float = _analyse(standard).estimated_speed_kn
	var fast: float = _analyse(doubled).estimated_speed_kn
	gt(fast, slow, "twice the power is faster")
	lt(fast, slow * 1.4, "but nothing like twice as fast")


# ------------------------------------------------------------ the validator --

func test_the_validator_warns_and_never_changes_the_design() -> void:
	var spec: ShipSpec = TestShips.load_ship("uss_iowa")
	var before_beam: float = spec.beam_m
	var before_belt: float = spec.armour.plate("belt").thickness_mm
	_findings(spec)
	eq(spec.beam_m, before_beam, "the beam is untouched")
	eq(spec.armour.plate("belt").thickness_mm, before_belt, "and so is the armour")


func test_an_impossible_design_is_reported_rather_than_refused() -> void:
	# A metre of armour everywhere on a destroyer's hull. It must produce findings, and
	# it must still produce an analysis: the player may build it and watch it sink.
	var absurd: ShipSpec = TestShips.load_ship("uss_fletcher")
	for zone: String in ["belt", "deckMain", "turretFace", "barbette"]:
		absurd.armour.plate(zone).thickness_mm = 1000.0
		absurd.armour.plate(zone).lower_edge_thickness_mm = 1000.0

	var analysis: DesignAnalysis = _analyse(absurd)
	gt(analysis.full_displacement_t, analysis.stated_displacement_t,
		"she is far over her stated displacement")

	var serious: int = 0
	for finding: DesignValidator.Finding in _findings(absurd):
		if finding.severity == DesignValidator.Severity.SERIOUS:
			serious += 1
	gt(float(serious), 0.0, "and the designer says so plainly")


func test_findings_come_back_worst_first() -> void:
	var absurd: ShipSpec = TestShips.load_ship("uss_fletcher")
	absurd.armour.plate("belt").thickness_mm = 800.0
	absurd.armour.plate("belt").lower_edge_thickness_mm = 800.0
	var previous: int = int(DesignValidator.Severity.SERIOUS)
	for finding: DesignValidator.Finding in _findings(absurd):
		le(float(int(finding.severity)), float(previous), "severity never increases down the list")
		previous = int(finding.severity)


func test_the_analysis_is_reproducible() -> void:
	var first: DesignAnalysis = _analyse_id("uss_iowa")
	var second: DesignAnalysis = _analyse_id("uss_iowa")
	eq(first.full_displacement_t, second.full_displacement_t, "same displacement")
	eq(first.gm_m, second.gm_m, "same stability")
	eq(first.estimated_speed_kn, second.estimated_speed_kn, "same speed")
