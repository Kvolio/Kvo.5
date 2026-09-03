extends SimTest

## Armour penetration, checked against published penetration tables.
##
## The model is asked the question a gunnery table answers: at this range, how much
## vertical armour can this shell defeat? That is found by searching for the
## thickness at which the model flips from stopping the shell to letting it through,
## which exercises normalization, obliquity and the ballistic limit together rather
## than testing the bare formula in isolation.
##
## With no RNG supplied the model returns its central prediction — the 50% ballistic
## limit — which is precisely the quantity published tables report.

const MATERIALS_PATH: String = "res://data/materials/armor.json"

var _model: PenetrationModel = null
var _materials: ArmourMaterials = null


func suite_name() -> String:
	return "Penetration"


func before_each() -> void:
	if _model == null:
		_model = PenetrationModelRegistry.create(TestWeapons.config())
		_materials = ArmourMaterials.load_from(MATERIALS_PATH)


## A shell arriving at `speed` and descending at `descent_deg` onto a vertical plate.
func _context(shell_id: String, speed: float, descent_deg: float,
		thickness_mm: float, material: String = "usa_class_a") -> ArmorInteractionContext:
	var shell: ShellDef = TestWeapons.shell(shell_id)
	var context: ArmorInteractionContext = ArmorInteractionContext.new()
	context.mass_kg = shell.mass_kg
	context.diameter_m = shell.diameter_m
	context.penetration_k = shell.penetration_k
	context.is_armour_piercing = shell.is_armour_piercing()
	context.cap_status = (PenetrationOutcome.Cap.INTACT if shell.cap == ShellDef.Cap.APC
		else PenetrationOutcome.Cap.NONE)

	# Vertical plate; the shell descends onto it, so obliquity is the descent angle.
	var descent: float = deg_to_rad(descent_deg)
	context.plate_normal = Vector3(0.0, 1.0, 0.0)
	context.velocity = Vector3(0.0, -cos(descent), -sin(descent)) * speed
	context.thickness_mm = thickness_mm
	context.material_quality = _materials.quality(material)
	context.face_hardened = _materials.is_face_hardened(material)
	return context


## Thickest vertical plate this shell defeats under these conditions, by search.
func _defeated_thickness(shell_id: String, speed: float, descent_deg: float,
		material: String = "usa_class_a") -> float:
	var low: float = 1.0
	var high: float = 1500.0
	for _i: int in 40:
		var mid: float = (low + high) * 0.5
		var outcome: PenetrationOutcome = _model.evaluate(
			_context(shell_id, speed, descent_deg, mid, material))
		if outcome.result == PenetrationOutcome.Result.PENETRATED:
			low = mid
		else:
			high = mid
	return low


# -------------------------------------------------- against published tables --

func test_iowa_penetration_matches_her_published_table() -> void:
	# USS Iowa, 16"/50 Mark 7 firing AP Mark 8, against face-hardened side armour.
	# Range, striking velocity (m/s), descent angle, published penetration (mm).
	var reference: Array = [
		[18288.0, 522.0, 15.3, 509.0],
		[27432.0, 469.0, 29.1, 380.0],
		[32004.0, 467.0, 37.1, 329.0],
	]
	for entry: Array in reference:
		var defeated: float = _defeated_thickness("usa_16in50_ap_mk8",
			entry[1] as float, entry[2] as float)
		var published: float = entry[3] as float
		# 15% covers the difference between a De Marre fit and the fuller model the
		# published tables were computed with.
		almost(defeated, published, published * 0.15,
			"16-inch penetration at %.0f m" % entry[0])


func test_yamato_penetration_matches_her_published_table() -> void:
	# A second gun, from a different navy, with a differently shaped shell — which is
	# what shows the model generalises rather than having been fitted to one weapon.
	var reference: Array = [
		[20000.0, 541.0, 15.8, 566.0],
		[30000.0, 492.0, 29.5, 417.0],
	]
	for entry: Array in reference:
		var defeated: float = _defeated_thickness("jpn_46cm45_ap_t91",
			entry[1] as float, entry[2] as float)
		var published: float = entry[3] as float
		almost(defeated, published, published * 0.15,
			"46 cm penetration at %.0f m" % entry[0])


func test_penetration_falls_off_with_range() -> void:
	var near: float = _defeated_thickness("usa_16in50_ap_mk8", 600.0, 8.0)
	var far: float = _defeated_thickness("usa_16in50_ap_mk8", 460.0, 32.0)
	gt(near, far * 1.5, "a shell arriving faster and flatter beats far more plate")


func test_a_bigger_gun_beats_more_armour() -> void:
	var sixteen: float = _defeated_thickness("usa_16in50_ap_mk8", 500.0, 20.0)
	var eight: float = _defeated_thickness("usa_8in55_ap_mk21", 500.0, 20.0)
	# Roughly the ratio of their sectional densities, which is what carries a
	# projectile through plate: 1,225 kg behind 406 mm against 152 kg behind 203 mm.
	gt(sixteen, eight * 1.9, "a 16-inch shell beats about twice what an 8-inch does")


func test_high_explosive_barely_penetrates_at_all() -> void:
	# The defining difference between shell types, and it comes from the data rather
	# than from a branch: HE carries a much lower penetration coefficient.
	var ap: float = _defeated_thickness("usa_16in50_ap_mk8", 500.0, 15.0)
	var he: float = _defeated_thickness("usa_16in50_he_mk13", 500.0, 15.0)
	lt(he, ap * 0.6, "the high-capacity shell is not an armour-piercing shell")


# ------------------------------------------------------------- interactions --

func test_obliquity_costs_penetration() -> void:
	var square: PenetrationOutcome = _model.evaluate(_context("usa_16in50_ap_mk8", 500.0, 0.0, 400.0))
	var angled: PenetrationOutcome = _model.evaluate(_context("usa_16in50_ap_mk8", 500.0, 45.0, 400.0))
	gt(angled.effective_thickness_mm, square.effective_thickness_mm * 1.2,
		"the same plate presents more thickness to an angled hit")
	gt(angled.obliquity_deg, 40.0, "and the obliquity is reported")


func test_a_capped_shell_normalizes_against_thin_plate_but_not_thick() -> void:
	# A cap bites and turns the shell towards the normal — an effect that is strong
	# against plate thinner than the shell's calibre and vanishes against plate
	# thicker than it.
	var thin: PenetrationOutcome = _model.evaluate(_context("usa_16in50_ap_mk8", 500.0, 40.0, 80.0))
	var thick: PenetrationOutcome = _model.evaluate(_context("usa_16in50_ap_mk8", 500.0, 40.0, 500.0))
	gt(thin.normalization_deg, 8.0, "substantial normalization against thin plate")
	lt(thick.normalization_deg, 2.0, "almost none against plate thicker than the shell")


func test_a_shell_that_lost_its_cap_does_worse_against_face_hardened_plate() -> void:
	# The payoff of decapping, and the reason a thin outer plate can matter far more
	# than its thickness suggests.
	var capped: ArmorInteractionContext = _context("usa_16in50_ap_mk8", 500.0, 15.0, 350.0)
	var stripped: ArmorInteractionContext = _context("usa_16in50_ap_mk8", 500.0, 15.0, 350.0)
	stripped.cap_status = PenetrationOutcome.Cap.STRIPPED
	gt(_model.evaluate(stripped).effective_thickness_mm,
		_model.evaluate(capped).effective_thickness_mm * 1.15,
		"the same plate is harder to beat once the cap is gone")


func test_a_thin_plate_strips_the_cap() -> void:
	var outcome: PenetrationOutcome = _model.evaluate(
		_context("usa_16in50_ap_mk8", 600.0, 10.0, 40.0))
	eq(outcome.result, PenetrationOutcome.Result.PENETRATED, "it goes straight through")
	eq(outcome.cap_status, PenetrationOutcome.Cap.STRIPPED, "but leaves its cap behind")


func test_a_glancing_hit_ricochets() -> void:
	var outcome: PenetrationOutcome = _model.evaluate(
		_context("usa_8in55_ap_mk21", 450.0, 80.0, 200.0))
	eq(outcome.result, PenetrationOutcome.Result.RICOCHET, "skids off rather than biting in")
	gt(outcome.remaining_velocity.length(), 200.0, "and carries on with most of its speed")
	ne(outcome.diagnostics, "", "with the reason recorded")


func test_a_ricochet_deflects_away_from_the_plate() -> void:
	# The tracer re-traces from the deflection point, so the outgoing direction has to
	# be right or a ricochet inside a ship would go nowhere sensible.
	var context: ArmorInteractionContext = _context("usa_8in55_ap_mk21", 450.0, 80.0, 200.0)
	var outcome: PenetrationOutcome = _model.evaluate(context)
	if outcome.result != PenetrationOutcome.Result.RICOCHET:
		fail("expected a ricochet to test the deflection")
		return
	gt(outcome.remaining_velocity.normalized().dot(context.plate_normal), 0.0,
		"the shell leaves on the side of the plate it arrived from")


func test_a_massive_overmatch_drives_through_even_at_a_glancing_angle() -> void:
	# A 16-inch shell against a destroyer's splinter plating does not bounce off,
	# whatever the angle.
	var outcome: PenetrationOutcome = _model.evaluate(
		_context("usa_16in50_ap_mk8", 600.0, 80.0, 13.0, "usa_sts"))
	eq(outcome.result, PenetrationOutcome.Result.PENETRATED,
		"overmatch beats obliquity")


func test_plate_that_holds_still_sheds_spall() -> void:
	# Which is how a non-penetrating hit wrecks equipment behind armour that was never
	# beaten.
	var outcome: PenetrationOutcome = _model.evaluate(
		_context("usa_8in55_ap_mk21", 480.0, 10.0, 400.0))
	eq(outcome.result, PenetrationOutcome.Result.STOPPED, "the plate holds")
	gt(outcome.spall_mass_kg, 0.0, "but throws fragments off its inner face")


func test_a_deformed_plate_resists_less() -> void:
	var fresh: ArmorInteractionContext = _context("usa_16in50_ap_mk8", 500.0, 15.0, 350.0)
	var battered: ArmorInteractionContext = _context("usa_16in50_ap_mk8", 500.0, 15.0, 350.0)
	battered.plate_deformation = 1.0
	lt(_model.evaluate(battered).effective_thickness_mm,
		_model.evaluate(fresh).effective_thickness_mm * 0.95,
		"repeated hits on the same plate really do open it up")


func test_material_quality_changes_the_answer() -> void:
	var american: PenetrationOutcome = _model.evaluate(
		_context("usa_16in50_ap_mk8", 500.0, 15.0, 400.0, "usa_class_a"))
	var japanese: PenetrationOutcome = _model.evaluate(
		_context("usa_16in50_ap_mk8", 500.0, 15.0, 400.0, "jpn_vh"))
	lt(japanese.effective_thickness_mm, american.effective_thickness_mm,
		"400 mm of Japanese VH resists less than 400 mm of US Class A")


func test_penetrating_a_plate_arms_the_fuze() -> void:
	var outcome: PenetrationOutcome = _model.evaluate(
		_context("usa_16in50_ap_mk8", 600.0, 10.0, 200.0))
	eq(outcome.result, PenetrationOutcome.Result.PENETRATED, "through")
	eq(outcome.fuze_state, PenetrationOutcome.Fuze.ARMED, "and the fuze is now running")


func test_a_stopped_shell_keeps_nothing() -> void:
	var outcome: PenetrationOutcome = _model.evaluate(
		_context("usa_8in55_ap_mk21", 400.0, 10.0, 600.0))
	eq(outcome.result, PenetrationOutcome.Result.STOPPED, "stopped dead")
	almost(outcome.remaining_velocity.length(), 0.0, 0.001, "with no velocity left")
	almost(outcome.remaining_energy, 0.0, 0.001, "and no energy")


func test_no_plate_means_no_obstruction() -> void:
	var outcome: PenetrationOutcome = _model.evaluate(
		_context("usa_16in50_ap_mk8", 500.0, 15.0, 0.0))
	eq(outcome.result, PenetrationOutcome.Result.PENETRATED, "passes through empty space")
	almost(outcome.remaining_velocity.length(), 500.0, 0.001, "entirely undisturbed")


# ------------------------------------------------------------- the interface --

func test_the_outcome_carries_enough_to_continue_to_the_next_plate() -> void:
	# A shell's journey through a ship is a sequence of these, so an outcome that
	# reported only a boolean would make the second plate unresolvable.
	var outcome: PenetrationOutcome = _model.evaluate(
		_context("usa_16in50_ap_mk8", 600.0, 10.0, 150.0))
	gt(outcome.remaining_velocity.length(), 0.0, "velocity")
	gt(outcome.remaining_energy, 0.0, "energy")
	gt(outcome.projectile_integrity, 0.0, "integrity")
	gt(outcome.penetration_capability_mm, 0.0, "what it was capable of")
	gt(outcome.effective_thickness_mm, 0.0, "what the plate presented")
	ne(outcome.diagnostics, "", "and an explanation for the debug overlay")


func test_the_registry_builds_the_configured_model() -> void:
	var model: PenetrationModel = PenetrationModelRegistry.create(TestWeapons.config())
	eq(model.model_id(), "de_marre", "the model named in the configuration")
	ok(model is PenetrationModel, "and it satisfies the interface")


func test_an_unknown_model_falls_back_rather_than_crashing() -> void:
	var model: PenetrationModel = PenetrationModelRegistry.create(
		{"penetration": {"model": "not_a_real_model"}})
	ok(model != null, "a usable model is still returned")


func test_the_marginal_band_is_probabilistic() -> void:
	# A ballistic limit is a 50% point, not a wall. Right at the limit, repeated
	# identical shots must not all give the same answer.
	var limit: float = _defeated_thickness("usa_16in50_ap_mk8", 500.0, 15.0)
	var rng: DeterministicRng = DeterministicRng.new(4242)
	var penetrations: int = 0
	for _i: int in 200:
		var context: ArmorInteractionContext = _context("usa_16in50_ap_mk8", 500.0, 15.0, limit)
		context.rng = rng
		if _model.evaluate(context).result == PenetrationOutcome.Result.PENETRATED:
			penetrations += 1
	between(float(penetrations), 60.0, 140.0, "roughly half get through at the limit")
