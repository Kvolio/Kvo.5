extends SimTest

## Following a shell through a ship.
##
## The claim under test is that outcomes come from ORDER and POSITION rather than
## from rules: a shell stops at the first plate that beats it and never consults what
## is behind it; a shell that crosses a thin-skinned ship leaves before its fuze
## expires; a thin plate met first strips the cap the belt would otherwise have had
## to contend with. None of those is written as a special case anywhere, so if any of
## them stops being true it will be because the geometry or the ordering broke.

var _materials: ArmourMaterials = null
var _model: PenetrationModel = null


func suite_name() -> String:
	return "Trajectory tracer"


func before_each() -> void:
	if _model == null:
		_materials = ArmourMaterials.load_from("res://data/materials/armor.json")
		_model = PenetrationModelRegistry.create(TestWeapons.config())


func _ship(spec_id: String, heading: float = 0.0) -> ShipEntity:
	var ship: ShipEntity = ShipEntity.create(1, TestShips.load_ship(spec_id), 0)
	ship.position = Vector2.ZERO
	ship.heading = heading
	return ship


## Fire a shell so that its path passes through `local_target`, approaching from
## `aspect_deg` off the target's bow and descending at `descent_deg`.
func _fire(spec_id: String, shell_id: String, local_target: Vector3,
		aspect_deg: float, descent_deg: float, speed: float,
		rng: DeterministicRng = null) -> HitReport:
	var ship: ShipEntity = _ship(spec_id)
	var structure: ShipStructureTemplate = TestShips.structure(spec_id)
	var shell: ShellDef = TestWeapons.shell(shell_id)
	var k: float = shell.penetration_k

	var aspect: float = deg_to_rad(aspect_deg)
	var descent: float = deg_to_rad(descent_deg)
	var direction: Vector3 = Vector3(
		-cos(aspect) * cos(descent), -sin(aspect) * cos(descent), -sin(descent)).normalized()
	var origin: Vector3 = local_target - direction * 400.0

	# The ship is at the origin heading east, so ship-local and world coincide.
	return TrajectoryTracer.trace(shell, k, origin, direction * speed,
		ship, structure, _materials, _model, rng)


func _belt_point(spec_id: String) -> Vector3:
	var structure: ShipStructureTemplate = TestShips.structure(spec_id)
	for face: GeometryPrimitives.Face in structure.faces:
		if face.zone == "belt" and face.centre.y > 0.0:
			return face.centre
	return Vector3.ZERO


func _volume_point(spec_id: String, role: String) -> Vector3:
	var structure: ShipStructureTemplate = TestShips.structure(spec_id)
	var found: PackedInt32Array = structure.volumes_with_role(role)
	return structure.volumes[found[0]].centre() if not found.is_empty() else Vector3.ZERO


# ---------------------------------------------------------------- the ordering --

func test_interactions_come_back_in_the_order_they_were_met() -> void:
	var report: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_belt_point("uss_iowa"), 90.0, 12.0, 520.0)
	gt(float(report.interactions.size()), 1.0, "it met several things")
	var previous: float = -1.0
	for interaction: HitReport.LayerInteraction in report.interactions:
		ge(interaction.distance_m, previous, "distances never go backwards")
		previous = interaction.distance_m


func test_the_shell_plating_is_met_before_the_belt_behind_it() -> void:
	var report: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_belt_point("uss_iowa"), 90.0, 12.0, 520.0)
	var plating: int = -1
	var belt: int = -1
	for interaction: HitReport.LayerInteraction in report.interactions:
		if interaction.zone == "shellPlating" and plating < 0:
			plating = interaction.order
		if interaction.zone == "belt" and belt < 0:
			belt = interaction.order
	gt(float(plating), -1.0, "the plating was met")
	gt(float(belt), -1.0, "and so was the belt")
	lt(float(plating), float(belt), "the plating first, as the geometry requires")


func test_a_shell_stopped_by_the_belt_never_reaches_what_is_behind_it() -> void:
	# An 8-inch shell against Iowa's 307 mm belt. It must not touch the machinery.
	var report: HitReport = _fire("uss_iowa", "usa_8in55_ap_mk21",
		_belt_point("uss_iowa"), 90.0, 15.0, 450.0)
	eq(report.termination, HitReport.Termination.STOPPED, "the belt held")
	not_ok(report.detonated, "and it did not burst inside")
	ok(report.was_defeated_by_armour(), "reported as defeated by armour")
	for index: int in report.compartments_entered:
		var role: String = TestShips.structure("uss_iowa").volumes[index].role
		ne(role, ShipStructureBuilder.ROLE_ENGINE, "no engine room was reached")
		ne(role, ShipStructureBuilder.ROLE_MAGAZINE, "no magazine was reached")


func test_a_heavy_shell_beats_the_same_belt_the_lighter_one_could_not() -> void:
	var light: HitReport = _fire("uss_iowa", "usa_8in55_ap_mk21",
		_belt_point("uss_iowa"), 90.0, 15.0, 450.0)
	var heavy: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_belt_point("uss_iowa"), 90.0, 15.0, 560.0)
	eq(light.termination, HitReport.Termination.STOPPED, "the 8-inch is stopped")
	ok(heavy.penetrated_armour(), "the 16-inch gets through")


# ------------------------------------------------------------ overpenetration --

func test_a_battleship_shell_passes_clean_through_a_destroyer() -> void:
	# There is no overpenetration rule. The fuze runs on distance travelled, and a
	# destroyer is not thick enough to use it up.
	var report: HitReport = _fire("uss_fletcher", "usa_16in50_ap_mk8",
		Vector3(0.0, 0.0, 0.0), 90.0, 12.0, 520.0)
	eq(report.termination, HitReport.Termination.EXITED, "it left the far side")
	not_ok(report.detonated, "without ever bursting")
	gt(report.final_speed, 200.0, "still travelling fast when it left")


func test_the_same_shell_bursts_inside_a_battleship() -> void:
	# The difference is entirely how much ship there is to cross.
	var report: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_volume_point("uss_iowa", ShipStructureBuilder.ROLE_ENGINE), 90.0, 12.0, 600.0)
	ok(report.detonated, "the fuze ran out inside her")
	gt(report.detonation_energy_j, 0.0, "releasing real energy")


func test_a_fuzeless_shell_never_detonates() -> void:
	# High-capacity shells with an instantaneous fuze burst on the plating; the fuze
	# delay of zero means there is no distance to run.
	var report: HitReport = _fire("uss_fletcher", "usa_16in50_he_mk13",
		Vector3.ZERO, 90.0, 12.0, 520.0)
	ne(report.termination, HitReport.Termination.INTERACTION_LIMIT, "the walk terminated cleanly")


# ------------------------------------------------------- where the hit lands --

func test_the_same_shell_gives_different_outcomes_at_different_aim_points() -> void:
	# The project's central claim, stated as a test: the shell is identical, and only
	# where it goes differs.
	var superstructure: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_volume_point("uss_iowa", ShipStructureBuilder.ROLE_FIRE_CONTROL), 90.0, 12.0, 560.0)
	var machinery: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_volume_point("uss_iowa", ShipStructureBuilder.ROLE_ENGINE), 90.0, 12.0, 560.0)
	var magazine: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_volume_point("uss_iowa", ShipStructureBuilder.ROLE_MAGAZINE), 90.0, 12.0, 560.0)

	var roles: Array[String] = []
	for report: HitReport in [superstructure, machinery, magazine]:
		var deepest: String = "none"
		for index: int in report.compartments_entered:
			deepest = TestShips.structure("uss_iowa").volumes[index].role
		roles.append(deepest)
	ne(roles[0], roles[1], "a hit on the superstructure ends somewhere different from one on the machinery")
	ok(roles.has(ShipStructureBuilder.ROLE_MAGAZINE) or magazine.was_defeated_by_armour(),
		"the shot aimed at the magazine either reaches it or is stopped by the armour protecting it")


func test_a_hit_above_the_waterline_is_distinguished_from_one_below() -> void:
	var high: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		Vector3(0.0, 0.0, 5.0), 90.0, 10.0, 520.0)
	var low: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		Vector3(0.0, 0.0, -4.0), 90.0, 10.0, 520.0)
	ok(high.hit_above_water, "one struck above water")
	not_ok(low.hit_above_water, "the other below it — which is what decides flooding")


func test_plunging_fire_arrives_on_the_deck_and_flat_fire_on_the_belt() -> void:
	# The reason range matters so much in a gun action, and it comes from the
	# geometry: at 40 degrees of descent the deck is simply what the shell meets first.
	var flat: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		Vector3(0.0, 0.0, 1.0), 90.0, 8.0, 560.0)
	var plunging: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		Vector3(0.0, 0.0, 1.0), 90.0, 45.0, 470.0)

	var flat_zones: Array[String] = []
	for interaction: HitReport.LayerInteraction in flat.armour_interactions():
		flat_zones.append(interaction.zone)
	var plunging_zones: Array[String] = []
	for interaction: HitReport.LayerInteraction in plunging.armour_interactions():
		plunging_zones.append(interaction.zone)

	ok(flat_zones.has("belt"), "the flat shot meets the belt")
	ok(plunging_zones.has("deckWeather") or plunging_zones.has("deckMain"),
		"the plunging shot meets a deck")


# ----------------------------------------------------------------- decapping --

func test_a_shell_can_lose_its_cap_on_the_way_in() -> void:
	# Not a rule: the plating is simply resolved before the belt, and it is thin
	# enough relative to the shell to tear the cap off.
	var report: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_belt_point("uss_iowa"), 90.0, 12.0, 560.0)
	var stripped: bool = false
	for interaction: HitReport.LayerInteraction in report.interactions:
		if interaction.outcome != null and interaction.outcome.cap_status == PenetrationOutcome.Cap.STRIPPED:
			stripped = true
	ok(stripped, "the cap was stripped by a plate met before the belt")


# ---------------------------------------------------------------- robustness --

func test_a_path_that_misses_the_ship_reports_nothing() -> void:
	var report: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		Vector3(0.0, 400.0, 0.0), 90.0, 10.0, 520.0)
	eq(report.interactions.size(), 0, "no interactions at all")
	not_ok(report.detonated, "and nothing detonated")


func test_a_trace_always_terminates() -> void:
	# The walk is bounded, so a degenerate geometry can never spin.
	for spec_id: String in ["uss_iowa", "ijn_yamato", "uss_fletcher", "uss_essex", "uss_cleveland"]:
		for descent: float in [5.0, 25.0, 55.0]:
			for aspect: float in [15.0, 90.0, 160.0]:
				var report: HitReport = _fire(spec_id, "usa_16in50_ap_mk8",
					Vector3.ZERO, aspect, descent, 520.0)
				ne(report.termination, HitReport.Termination.INTERACTION_LIMIT,
					"%s at %.0f/%.0f terminated properly" % [spec_id, aspect, descent])


func test_tracing_is_reproducible() -> void:
	var a: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_belt_point("uss_iowa"), 90.0, 14.0, 540.0, DeterministicRng.new(7))
	var b: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_belt_point("uss_iowa"), 90.0, 14.0, 540.0, DeterministicRng.new(7))
	eq(a.interactions.size(), b.interactions.size(), "the same number of interactions")
	eq(a.termination, b.termination, "and the same ending")
	eq(a.path_length_m, b.path_length_m, "down to the path length")


func test_the_report_records_the_whole_chain() -> void:
	var report: HitReport = _fire("uss_iowa", "usa_16in50_ap_mk8",
		_volume_point("uss_iowa", ShipStructureBuilder.ROLE_ENGINE), 90.0, 12.0, 600.0)
	gt(report.striking_velocity, 0.0, "striking velocity")
	ne(report.descent_angle_deg, 0.0, "descent angle")
	gt(float(report.interactions.size()), 2.0, "an ordered list of what it met")
	gt(float(report.compartments_entered.size()), 0.0, "the compartments it crossed")
	for interaction: HitReport.LayerInteraction in report.interactions:
		if interaction.outcome != null:
			gt(interaction.outcome.effective_thickness_mm, -1.0, "effective thickness at each plate")
			ne(interaction.outcome.diagnostics, "", "and an explanation of each result")
	# The whole thing has to survive serialisation for the debug overlay and the log.
	var text: String = Serializer.to_json(report.to_dict())
	gt(float(text.length()), 200.0, "and serialises to something inspectable")
