class_name DeMarreModel
extends PenetrationModel

## De Marre's naval penetration formula, with the behaviours that make an armour
## interaction interesting layered on top of it.
##
##     V_limit = K * T^0.7 * d^0.75 / sqrt(W)
##
## evaluated in the imperial units the formula is published in — feet per second,
## inches, pounds. Converting at the boundary rather than rewriting the constants
## means K here is the same K a gunnery manual quotes, and can be checked against one.
##
## Fitted against published penetration tables it reproduces the 16-inch and 46 cm
## figures to within about 6-10% across combat ranges. That is what an empirical fit
## of this age is worth, and it is why this is one implementation behind an interface
## rather than the model.
##
## Everything below the bare formula — normalization, ricochet, shatter, the marginal
## band, cap stripping, spall — is configured in data/config/ballistics.json. None of
## it is a law of physics; it is this model's account of what happens, and another
## model is free to disagree.

const KG_TO_LB: float = 2.2046226218
const M_TO_INCH: float = 39.3700787402
const MS_TO_FPS: float = 3.2808398950

var _thickness_exponent: float = 0.7
var _diameter_exponent: float = 0.75
var _max_norm_capped: float = deg_to_rad(14.0)
var _max_norm_uncapped: float = deg_to_rad(5.0)

var _critical_angle: float = deg_to_rad(72.0)
var _angle_reduction: float = deg_to_rad(18.0)
var _min_critical_angle: float = deg_to_rad(45.0)
var _overmatch_ratio: float = 2.5
var _ricochet_velocity_retained: float = 0.72
var _ricochet_integrity_cost: float = 0.25

var _shatter_min_ratio: float = 0.55
var _shatter_min_velocity: float = 450.0
var _shatter_margin_low: float = 0.85
var _shatter_margin_high: float = 1.35
var _shatter_face_hardened_only: bool = true
var _shatter_probability: float = 0.35

var _marginal_width: float = 0.12
var _partial_below: float = 0.88

var _cap_strip_ratio: float = 0.25
var _cap_stripped_penalty: float = 0.75

var _spall_energy_fraction: float = 0.55
var _spall_mass_fraction: float = 0.06
var _spall_cone: float = deg_to_rad(25.0)

var _deformation_weakening: float = 0.30


static func from_config(config: Dictionary) -> DeMarreModel:
	var model: DeMarreModel = DeMarreModel.new()
	var c: Dictionary = config.get("de_marre", {}) as Dictionary
	model._thickness_exponent = float(c.get("thicknessExponent", 0.7))
	model._diameter_exponent = float(c.get("diameterExponent", 0.75))

	var norm: Dictionary = c.get("normalization", {}) as Dictionary
	model._max_norm_capped = deg_to_rad(float(norm.get("maxDegreesCapped", 14.0)))
	model._max_norm_uncapped = deg_to_rad(float(norm.get("maxDegreesUncapped", 5.0)))

	var ric: Dictionary = c.get("ricochet", {}) as Dictionary
	model._critical_angle = deg_to_rad(float(ric.get("criticalAngleDeg", 72.0)))
	model._angle_reduction = deg_to_rad(float(ric.get("angleReductionPerCalibreRatio", 18.0)))
	model._min_critical_angle = deg_to_rad(float(ric.get("minimumCriticalAngleDeg", 45.0)))
	model._overmatch_ratio = float(ric.get("overmatchRatioIgnoringAngle", 2.5))
	model._ricochet_velocity_retained = float(ric.get("velocityRetained", 0.72))
	model._ricochet_integrity_cost = float(ric.get("integrityCost", 0.25))

	var sh: Dictionary = c.get("shatter", {}) as Dictionary
	model._shatter_min_ratio = float(sh.get("minPlateToCalibreRatio", 0.55))
	model._shatter_min_velocity = float(sh.get("minVelocityMs", 450.0))
	model._shatter_margin_low = float(sh.get("marginLow", 0.85))
	model._shatter_margin_high = float(sh.get("marginHigh", 1.35))
	model._shatter_face_hardened_only = bool(sh.get("faceHardenedOnly", true))
	model._shatter_probability = float(sh.get("probability", 0.35))

	var band: Dictionary = c.get("marginalBand", {}) as Dictionary
	model._marginal_width = float(band.get("width", 0.12))
	model._partial_below = float(band.get("partialPenetrationBelow", 0.88))

	var cap: Dictionary = c.get("capStripping", {}) as Dictionary
	model._cap_strip_ratio = float(cap.get("maxPlateToCalibreRatio", 0.25))
	model._cap_stripped_penalty = float(cap.get("penaltyAgainstFaceHardened", 0.75))

	var spall: Dictionary = c.get("spall", {}) as Dictionary
	model._spall_energy_fraction = float(spall.get("energyFractionForSpall", 0.55))
	model._spall_mass_fraction = float(spall.get("massFractionOfShell", 0.06))
	model._spall_cone = deg_to_rad(float(spall.get("coneAngleDeg", 25.0)))

	model._deformation_weakening = float(c.get("deformationWeakening", 0.30))
	return model


func model_id() -> String:
	return "de_marre"


## Plate this projectile could just defeat at normal incidence, in millimetres.
##
##     T = ( V * sqrt(W) / (K * d^0.75) ) ^ (1 / 0.7)
func penetration_capability_mm(context: ArmorInteractionContext) -> float:
	var v_fps: float = context.speed() * MS_TO_FPS
	if v_fps <= 0.0 or context.penetration_k <= 0.0:
		return 0.0
	var w_lb: float = context.mass_kg * KG_TO_LB
	var d_in: float = context.diameter_m * M_TO_INCH
	var numerator: float = v_fps * sqrt(w_lb)
	var denominator: float = context.penetration_k * pow(d_in, _diameter_exponent)
	if denominator <= 0.0:
		return 0.0
	var t_in: float = pow(numerator / denominator, 1.0 / _thickness_exponent)
	# Damaged shells do not penetrate like intact ones.
	return t_in * 25.4 * clampf(context.integrity, 0.0, 1.0)


## Velocity needed to just defeat a given effective thickness.
func limit_velocity_ms(context: ArmorInteractionContext, effective_mm: float) -> float:
	var t_in: float = (effective_mm / 25.4)
	var w_lb: float = context.mass_kg * KG_TO_LB
	var d_in: float = context.diameter_m * M_TO_INCH
	if w_lb <= 0.0:
		return INF
	var v_fps: float = (context.penetration_k * pow(t_in, _thickness_exponent)
		* pow(d_in, _diameter_exponent)) / sqrt(w_lb)
	return v_fps / MS_TO_FPS


func evaluate(context: ArmorInteractionContext) -> PenetrationOutcome:
	var outcome: PenetrationOutcome = PenetrationOutcome.new()
	outcome.cap_status = context.cap_status
	outcome.fuze_state = context.fuze_state
	outcome.projectile_integrity = context.integrity
	outcome.yaw_deg = context.yaw_deg
	outcome.remaining_velocity = context.velocity

	var obliquity: float = context.obliquity()
	outcome.obliquity_deg = rad_to_deg(obliquity)

	if context.thickness_mm <= 0.0:
		# Nothing there. Passes straight through, undisturbed.
		outcome.result = PenetrationOutcome.Result.PENETRATED
		outcome.remaining_energy = context.kinetic_energy()
		outcome.diagnostics = "no plate"
		return outcome

	var ratio_to_calibre: float = context.thickness_to_calibre()

	# --- normalization -------------------------------------------------------
	# A capped shell bites and turns towards the normal. Strong against plate thinner
	# than the shell's calibre, negligible against plate thicker than it.
	var max_normalization: float = _max_norm_uncapped
	if context.cap_status == PenetrationOutcome.Cap.INTACT:
		max_normalization = _max_norm_capped
	var normalization: float = max_normalization * clampf(1.0 - ratio_to_calibre, 0.0, 1.0)
	normalization = minf(normalization, obliquity)
	outcome.normalization_deg = rad_to_deg(normalization)
	var effective_obliquity: float = maxf(obliquity - normalization, 0.0)

	# --- effective thickness -------------------------------------------------
	var quality: float = context.material_quality
	if context.face_hardened and context.cap_status == PenetrationOutcome.Cap.STRIPPED:
		# An uncapped shell does markedly worse against face-hardened plate. This is
		# the payoff of decapping, and it is why a thin outer plate can matter far
		# more than its thickness suggests.
		quality /= _cap_stripped_penalty
	quality *= (1.0 - _deformation_weakening * clampf(context.plate_deformation, 0.0, 1.0))

	# Secant of the effective obliquity, capped: beyond about 80 degrees the geometry
	# runs away, and a shell that far off square has ricocheted rather than met an
	# infinitely thick plate.
	var secant: float = 1.0 / maxf(cos(minf(effective_obliquity, deg_to_rad(80.0))), 0.17)
	var effective: float = context.thickness_mm * quality * secant
	outcome.effective_thickness_mm = effective

	var capability: float = penetration_capability_mm(context)
	outcome.penetration_capability_mm = capability
	var ratio: float = capability / maxf(effective, 0.001)

	# --- ricochet ------------------------------------------------------------
	var critical: float = maxf(
		_critical_angle - _angle_reduction * clampf(ratio_to_calibre, 0.0, 2.0),
		_min_critical_angle)
	if obliquity > critical and ratio < _overmatch_ratio:
		outcome.result = PenetrationOutcome.Result.RICOCHET
		outcome.projectile_integrity = maxf(context.integrity - _ricochet_integrity_cost, 0.0)
		# Deflected off the plate, keeping most of its speed. The tracer re-traces
		# from here, so a ricochet inside a ship really can go on to hit something.
		var direction: Vector3 = context.velocity.normalized()
		var normal: Vector3 = context.plate_normal.normalized()
		if direction.dot(normal) > 0.0:
			normal = -normal
		var reflected: Vector3 = direction - 2.0 * direction.dot(normal) * normal
		outcome.remaining_velocity = reflected * context.speed() * _ricochet_velocity_retained
		outcome.remaining_energy = 0.5 * context.mass_kg * outcome.remaining_velocity.length_squared()
		outcome.yaw_deg = context.yaw_deg + rad_to_deg(obliquity) * 0.3
		outcome.plate_deformation_added = 0.02
		outcome.diagnostics = "obliquity %.0f deg exceeds the %.0f deg critical angle" % [
			rad_to_deg(obliquity), rad_to_deg(critical)]
		_add_spall(context, outcome, 0.25)
		return outcome

	# --- shatter -------------------------------------------------------------
	# Fast shell, thick face-hardened plate, marginal energy: the plate wins by
	# breaking the projectile rather than by stopping it.
	var shatter_eligible: bool = (
		ratio_to_calibre >= _shatter_min_ratio
		and context.speed() >= _shatter_min_velocity
		and ratio >= _shatter_margin_low and ratio <= _shatter_margin_high
		and (context.face_hardened or not _shatter_face_hardened_only))
	if shatter_eligible and _roll(context, _shatter_probability):
		outcome.result = PenetrationOutcome.Result.SHATTERED
		outcome.projectile_integrity = 0.0
		outcome.remaining_velocity = Vector3.ZERO
		outcome.remaining_energy = 0.0
		outcome.fuze_state = PenetrationOutcome.Fuze.FAILED
		outcome.plate_deformation_added = 0.12
		outcome.diagnostics = "shell broke up on %.0f mm face-hardened plate at %.0f m/s" % [
			context.thickness_mm, context.speed()]
		_add_spall(context, outcome, 0.8)
		return outcome

	# --- penetration ---------------------------------------------------------
	# A ballistic limit is a 50% point, not a wall, so the band around it is decided
	# by a roll. Two identical shells can genuinely differ here.
	var penetrates: bool = false
	if ratio >= 1.0 + _marginal_width:
		penetrates = true
	elif ratio > 1.0 - _marginal_width:
		var probability: float = (ratio - (1.0 - _marginal_width)) / (2.0 * _marginal_width)
		penetrates = _roll(context, probability)

	if penetrates:
		outcome.result = PenetrationOutcome.Result.PENETRATED
		# Residual velocity from the energy left after paying the limit velocity.
		var limit: float = limit_velocity_ms(context, effective)
		var v: float = context.speed()
		var residual: float = 0.0
		if v > limit:
			residual = sqrt(maxf(v * v - limit * limit, 0.0))
		outcome.remaining_velocity = context.velocity.normalized() * residual
		outcome.remaining_energy = 0.5 * context.mass_kg * residual * residual
		outcome.projectile_integrity = context.integrity * clampf(0.75 + 0.25 * ratio, 0.0, 1.0)
		outcome.yaw_deg = context.yaw_deg + rad_to_deg(effective_obliquity) * 0.15
		outcome.plate_deformation_added = 0.05
		# Going through a plate is what starts the fuze running.
		if context.fuze_state == PenetrationOutcome.Fuze.UNARMED:
			outcome.fuze_state = PenetrationOutcome.Fuze.ARMED
		# A thin plate tears the cap off, and the shell meets the next one uncapped.
		if (context.cap_status == PenetrationOutcome.Cap.INTACT
				and ratio_to_calibre <= _cap_strip_ratio):
			outcome.cap_status = PenetrationOutcome.Cap.STRIPPED
			outcome.diagnostics = "penetrated; armour-piercing cap stripped by thin plate"
		else:
			outcome.diagnostics = "penetrated with %.0f mm to spare" % (capability - effective)
		_add_spall(context, outcome, 0.35)
		return outcome

	# --- holed but the shell broke up ---------------------------------------
	if ratio >= _partial_below:
		outcome.result = PenetrationOutcome.Result.PARTIAL
		outcome.projectile_integrity = context.integrity * 0.25
		outcome.remaining_velocity = context.velocity.normalized() * context.speed() * 0.2
		outcome.remaining_energy = 0.5 * context.mass_kg * outcome.remaining_velocity.length_squared()
		outcome.fuze_state = PenetrationOutcome.Fuze.FAILED
		outcome.plate_deformation_added = 0.15
		outcome.diagnostics = "plate holed; shell broke up passing through"
		_add_spall(context, outcome, 0.7)
		return outcome

	# --- the plate held ------------------------------------------------------
	outcome.result = PenetrationOutcome.Result.STOPPED
	outcome.remaining_velocity = Vector3.ZERO
	outcome.remaining_energy = 0.0
	outcome.projectile_integrity = 0.0
	outcome.plate_deformation_added = 0.08 * clampf(ratio, 0.0, 1.0)
	outcome.diagnostics = "%.0f mm effective defeated %.0f mm of capability" % [effective, capability]
	# Even a plate that holds sheds fragments off its inner face, and those fragments
	# are how a non-penetrating hit still wrecks equipment behind the armour.
	_add_spall(context, outcome, clampf(ratio / maxf(_spall_energy_fraction, 0.01), 0.0, 1.0) * 0.5)
	return outcome


## Fragments thrown off the back of the plate, scaled by how hard it was struck.
func _add_spall(context: ArmorInteractionContext, outcome: PenetrationOutcome, severity: float) -> void:
	if severity <= 0.01:
		return
	outcome.spall_mass_kg = context.mass_kg * _spall_mass_fraction * clampf(severity, 0.0, 1.0)
	outcome.spall_cone_deg = rad_to_deg(_spall_cone)


## Reproducible coin flip. Falls back to the deterministic threshold when no stream
## was supplied, so a test can ask for the model's central prediction.
func _roll(context: ArmorInteractionContext, probability: float) -> bool:
	if context.rng == null:
		return probability >= 0.5
	return context.rng.chance(probability)
