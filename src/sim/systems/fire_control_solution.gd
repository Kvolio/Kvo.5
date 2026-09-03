class_name FireControlSolution
extends RefCounted

## What one ship believes about one target — which is never quite what is true.
##
## Until now gunnery read the target's exact position and velocity, so the only error
## left in the system was the dispersion of the guns themselves. That produces about
## three times the historical hit rate at long range, and it produces it for the wrong
## reason: real ships did not miss because their guns scattered, they missed because
## their SOLUTION was wrong. A battleship's pattern at 20 km was some 300 m long; her
## range error could easily be twice that, and a perfectly tight salvo fired at the
## wrong range simply lands somewhere else entirely.
##
## So the error lives here, in the plot, where it can be wrong in the four distinct
## ways a real plot was wrong:
##
##   range_error_m       what ranging got wrong, and what the plot's own lag adds to it
##   ballistic_bias      wind aloft, air density, powder temperature, barrel wear —
##                       drawn once and held, because it does not vary shot to shot
##   spot_correction_m   what the spotting officer has taken back off again
##   pointing error      stabilisation residual and ship motion, fresh every salvo
##
## Each behaves differently over time, and that is the whole point. Measurement error
## averages down as the ship keeps ranging. Ballistic bias never averages down but is
## absorbed wholesale by the first correction that straddles. Pointing error does
## neither, so it sets the floor. And plot lag is zero only while the target holds her
## course — a ship that turns invalidates every plot solving on her, not by a rule
## that says so, but because the range rate the plot is integrating is now the range
## rate of a course the target is no longer on.
##
## The visible consequence is the ladder: open fire, miss, spot the fall of shot,
## correct, straddle. It is also why checking fire is expensive, why a manoeuvring
## target is hard, and why radar changed everything.

## Stream name for every draw the plot makes. Separate from "gunnery" so that adding
## fire-control error cannot shift where an already-aimed salvo scatters — the two are
## independent sources of error and they stay independent in the random number stream
## as well as in the model.
const RNG_STREAM: String = "fire_control"


## How long the splashes of one salvo are gathered before they are corrected for. A
## salvo's shells land within a fraction of a second of one another; anything arriving
## later than this belongs to the next one.
const FALL_OF_SHOT_WINDOW_S: float = 1.0


## The ship's fire-control installation, resolved once from her design.
class Fit extends RefCounted:
	var rangefinder_base_m: float = 4.0
	var directors: int = 1
	var radar_set: String = "none"
	var radar_range_sigma_m: float = 0.0
	var radar_bearing_sigma_rad: float = 0.0
	var radar_max_range_m: float = 0.0
	var radar_blind_range_m: float = 0.0
	var stabilised: bool = true

	func has_radar() -> bool:
		return radar_max_range_m > 0.0

	## Radar cannot range through its own sea return close in, nor past its horizon.
	func radar_bears(range_m: float) -> bool:
		return has_radar() and range_m <= radar_max_range_m and range_m >= radar_blind_range_m


# -- the plot ------------------------------------------------------------------
var target_id: int = 0

## Plot range minus true range. Positive means the plot believes the target further
## away than she is, so the salvo falls OVER.
var range_error_m: float = 0.0
var bearing_error_rad: float = 0.0

## The plot's estimate of the target's course and speed. Converges towards the truth
## while she holds it, and lags behind the moment she does not.
var course_estimate: float = 0.0
var speed_estimate: float = 0.0

## Fractional error in turning range into elevation. Held for the engagement.
var ballistic_bias: float = 0.0

## What spotting has taken back off the range, in metres. This is the number the
## gunnery officer is actually moving when he calls "up four hundred".
var spot_correction_m: float = 0.0

## Drawn once per direction cycle and shared by every mount in the salvo, because
## they are all laid by the same director. Both are ANGLES: a director that is a
## fiftieth of a degree off is a fiftieth of a degree off whatever the range, and what
## that costs in metres is decided by the gun's range table, not by the range. It is
## why a laying error throws a shell further off at ten kilometres than at twenty-five.
var pointing_elevation_rad: float = 0.0
var pointing_bearing_rad: float = 0.0

var tracking_seconds: float = 0.0
var salvos_spotted: int = 0
var last_spot_m: float = 0.0
var opened: bool = false

## Splashes seen since the last correction. A salvo is spotted as a PATTERN, not as
## a stream of individual shells — the spotting officer calls the centre of the group
## over or short, once. Correcting on every splash separately would apply a battery's
## worth of corrections for one salvo and drive the plot into oscillation.
var _fall_sum_m: float = 0.0
var _fall_range_sum_m: float = 0.0
var _fall_count: int = 0
var _fall_age_s: float = 0.0


# -- installation --------------------------------------------------------------

## Resolve a ship's fire-control fit from her design and the configured defaults.
##
## A ship's data file may state her rangefinder base, her director count and her radar
## outright; where it does not, the radar is filled in by year. Year is the honest
## default because it is the part that is true of everybody — which navy got a working
## set first is a per-ship fact, and per-ship facts belong in the ship's own file.
static func fit_for(spec: ShipSpec, config: Dictionary) -> Fit:
	var fit: Fit = Fit.new()
	var data: Dictionary = spec.fire_control
	var rangefinder: Dictionary = config.get("rangefinder", {}) as Dictionary
	var radar: Dictionary = config.get("radar", {}) as Dictionary
	var sets: Dictionary = radar.get("sets", {}) as Dictionary

	fit.rangefinder_base_m = float(data.get("rangefinderBaseM",
		rangefinder.get("defaultBaseM", 4.0)))
	fit.directors = maxi(int(data.get("directors", 2 if spec.ship_type != "destroyer" else 1)), 0)
	fit.stabilised = bool(data.get("stabilised", true))

	var set_name: String = str(data.get("radar", ""))
	if set_name.is_empty():
		set_name = _default_radar_for_year(spec.year, radar)
	if not sets.has(set_name):
		set_name = "none"
	fit.radar_set = set_name

	var set_data: Dictionary = sets.get(set_name, {}) as Dictionary
	fit.radar_range_sigma_m = float(set_data.get("rangeSigmaM", 0.0))
	fit.radar_bearing_sigma_rad = float(set_data.get("bearingSigmaRad", 0.0))
	fit.radar_max_range_m = float(set_data.get("maxRangeM", 0.0))
	fit.radar_blind_range_m = float(set_data.get("blindRangeM", 0.0))
	return fit


static func _default_radar_for_year(year: int, radar_config: Dictionary) -> String:
	var table: Array = radar_config.get("defaultSetByYear", []) as Array
	for entry: Variant in table:
		var row: Dictionary = entry as Dictionary
		if year >= int(row.get("from", 0)):
			return str(row.get("set", "none"))
	return "none"


# -- opening the plot ----------------------------------------------------------

## Pick up a new target. Everything the plot believes is drawn wrong here, and has to
## be worked right by tracking and by spotting.
func open(shooter: ShipEntity, target: ShipEntity, fit: Fit, config: Dictionary,
		rng: DeterministicRng) -> void:
	var plot: Dictionary = config.get("plot", {}) as Dictionary
	var ballistic: Dictionary = config.get("ballistic", {}) as Dictionary

	target_id = target.id
	tracking_seconds = 0.0
	salvos_spotted = 0
	spot_correction_m = 0.0
	last_spot_m = 0.0

	var los: Vector2 = target.position - shooter.position
	var range_m: float = maxf(los.length(), 1.0)

	# The first range is a single measurement, so it carries the full instrument error.
	range_error_m = rng.next_gaussian() * measurement_range_sigma(range_m, fit, config)
	bearing_error_rad = rng.next_gaussian() * measurement_bearing_sigma(range_m, fit, config)

	# Course and speed by eye. Estimating an enemy's course from her aspect at 20 km is
	# a genuinely hard judgement, and getting it wrong by twenty degrees was routine.
	course_estimate = SimUnits.normalise_angle(
		target.heading + rng.next_gaussian() * float(plot.get("initialCourseSigmaRad", 0.35)))
	speed_estimate = maxf(
		target.speed + rng.next_gaussian() * float(plot.get("initialSpeedSigmaMs", 2.2)), 0.0)

	ballistic_bias = rng.next_gaussian() * float(ballistic.get("biasSigmaFraction", 0.0045))
	pointing_elevation_rad = 0.0
	pointing_bearing_rad = 0.0
	_clear_fall_of_shot()
	opened = true


# -- tracking ------------------------------------------------------------------

## One direction cycle: re-range, let the plot drift by however wrong its estimate of
## the target's motion is, then let it converge a little further towards the truth.
func track(shooter: ShipEntity, target: ShipEntity, fit: Fit, config: Dictionary,
		dt: float, sea_state: float, rng: DeterministicRng) -> void:
	if not opened or target.id != target_id:
		open(shooter, target, fit, config, rng)
		return

	tracking_seconds += dt
	_age_fall_of_shot(dt, fit, config, rng)
	var plot: Dictionary = config.get("plot", {}) as Dictionary

	var los: Vector2 = target.position - shooter.position
	var range_m: float = maxf(los.length(), 1.0)
	var unit: Vector2 = los / range_m
	var cross: Vector2 = Vector2(-unit.y, unit.x)

	# 1. Drift. The plot integrates a range rate derived from the course and speed it
	#    believes the target is making. Where that belief is wrong, the error grows —
	#    and it grows fastest exactly when the target has just turned.
	var own_velocity: Vector2 = shooter.velocity()
	var true_relative: Vector2 = target.velocity() - own_velocity
	var believed_relative: Vector2 = estimated_velocity() - own_velocity
	range_error_m += (believed_relative.dot(unit) - true_relative.dot(unit)) * dt
	bearing_error_rad += ((believed_relative.dot(cross) - true_relative.dot(cross)) * dt) / range_m

	# 2. Ranging. A rangekeeper integrates successive ranges rather than jumping to
	#    each one, so measurement error averages down over a tracking run. Nothing else
	#    does: the ballistic bias below is untouched by any amount of ranging.
	var measurement: Dictionary = config.get("measurement", {}) as Dictionary
	var alpha: float = 1.0 - exp(-dt / maxf(float(measurement.get("filterSeconds", 20.0)), 0.1))
	var measured_range_error: float = rng.next_gaussian() * measurement_range_sigma(
		range_m, fit, config)
	var measured_bearing_error: float = rng.next_gaussian() * measurement_bearing_sigma(
		range_m, fit, config)
	range_error_m += (measured_range_error - range_error_m) * alpha
	bearing_error_rad += (measured_bearing_error - bearing_error_rad) * alpha

	# 3. Convergence, and the jitter that keeps it from ever being finished. The plot
	#    works out the target's course and speed from how her bearing and range have
	#    been changing, so it settles only while she lets it — and it settles into a
	#    BAND rather than onto a value, because what it is being fed is a pair of
	#    hand-followed pointers on noisy inputs. Without the second term the plot comes
	#    to rest exactly on a steady target and a four-minute action ends up more
	#    accurate than a gunnery trial.
	var beta: float = 1.0 - exp(-dt / settle_seconds(fit, shooter, config))
	var walk: float = sqrt(maxf(dt, 0.0))
	course_estimate = SimUnits.normalise_angle(
		course_estimate + SimUnits.angle_delta(course_estimate, target.heading) * beta
		+ rng.next_gaussian() * float(plot.get("courseJitterRadPerRootSecond", 0.01)) * walk)
	speed_estimate = maxf(speed_estimate + (target.speed - speed_estimate) * beta
		+ rng.next_gaussian() * float(plot.get("speedJitterMsPerRootSecond", 0.055)) * walk,
		0.0)

	# 4. This cycle's pointing error, shared by every mount the director lays.
	var pointing: Dictionary = config.get("pointing", {}) as Dictionary
	var motion: float = pointing_factor(fit, sea_state, config)
	pointing_elevation_rad = rng.next_gaussian() * float(
		pointing.get("elevationSigmaRad", 0.0009)) * motion
	pointing_bearing_rad = rng.next_gaussian() * float(
		pointing.get("bearingSigmaRad", 0.0009)) * motion


## How long the plot takes to settle, given what it is being fed.
func settle_seconds(fit: Fit, shooter: ShipEntity, config: Dictionary) -> float:
	var plot: Dictionary = config.get("plot", {}) as Dictionary
	var base: float = float(plot.get("settleSeconds", 55.0))
	if not fit.has_radar():
		base = float(plot.get("settleSecondsNoRadar", 95.0))
	# With the directors gone the guns are fought in local control: each mount solves
	# for itself, by eye, and the plot barely converges at all.
	if shooter.condition != null and not shooter.condition.has_fire_control:
		base *= float(plot.get("directorLossSettleFactor", 2.4))
	return maxf(base, 1.0)


## Multiplier on pointing error from the sea and from what is left of the directors.
static func pointing_factor(fit: Fit, sea_state: float, config: Dictionary) -> float:
	var pointing: Dictionary = config.get("pointing", {}) as Dictionary
	var factor: float = 1.0
	if not fit.stabilised:
		factor *= float(pointing.get("unstabilisedFactor", 2.2))
	var per_step: float = float(pointing.get("seaStateFactorPerStep", 0.18))
	factor *= 1.0 + maxf(sea_state - 2.0, 0.0) * per_step
	return factor


# -- measurement error ---------------------------------------------------------

## Ranging error at this range, taking whichever instrument is better.
##
## Optical error grows with the SQUARE of the range and shrinks with the base length,
## because what a rangefinder measures is a parallax angle. Radar error is essentially
## flat. That crossover is the entire story of gunnery from 1942 onwards: a set that is
## worse than a good rangefinder at 8 km is far better than one at 25 km.
static func measurement_range_sigma(range_m: float, fit: Fit, config: Dictionary) -> float:
	var rangefinder: Dictionary = config.get("rangefinder", {}) as Dictionary
	var conditions: Dictionary = config.get("conditions", {}) as Dictionary
	var visibility: float = maxf(float(conditions.get("visibilityFactor", 1.0)), 0.01)

	var optical: float = INF
	if bool(conditions.get("opticalUsable", true)) and fit.rangefinder_base_m > 0.0:
		var angular: float = float(rangefinder.get("angularErrorRad", 2.0e-6))
		optical = range_m * range_m * angular / fit.rangefinder_base_m
		optical /= visibility
		optical = maxf(optical, float(rangefinder.get("minimumErrorM", 15.0)))

	var radar: float = INF
	if fit.radar_bears(range_m):
		radar = maxf(fit.radar_range_sigma_m, 1.0)

	if is_inf(optical) and is_inf(radar):
		# No instrument bears at all: ranging by eye off a known ship length. Very bad,
		# but a ship in that position still opens fire, and history says she should.
		return range_m * 0.08
	return minf(optical, radar)


static func measurement_bearing_sigma(range_m: float, fit: Fit, config: Dictionary) -> float:
	var rangefinder: Dictionary = config.get("rangefinder", {}) as Dictionary
	var conditions: Dictionary = config.get("conditions", {}) as Dictionary

	var optical: float = INF
	if bool(conditions.get("opticalUsable", true)):
		optical = float(rangefinder.get("bearingSigmaRad", 0.0006))
		optical /= maxf(float(conditions.get("visibilityFactor", 1.0)), 0.01)

	var radar: float = INF
	if fit.radar_bears(range_m):
		radar = maxf(fit.radar_bearing_sigma_rad, 0.0001)

	if is_inf(optical) and is_inf(radar):
		return 0.02
	return minf(optical, radar)


# -- what the plot hands the guns ----------------------------------------------

## Where the plot believes the target is, seen from `origin`.
func estimated_target_position(origin: Vector2, target: ShipEntity) -> Vector2:
	var los: Vector2 = target.position - origin
	var range_m: float = los.length()
	if range_m <= 0.0:
		return target.position
	var bearing: float = los.angle() + bearing_error_rad
	return origin + Vector2(cos(bearing), sin(bearing)) * maxf(range_m + range_error_m, 1.0)


## The course and speed the plot believes the target is making.
func estimated_velocity() -> Vector2:
	return Vector2(cos(course_estimate), sin(course_estimate)) * speed_estimate


## The range the guns are actually laid for, given a solved intercept range.
##
## The plot decides where to shoot; the range table then converts that into an
## elevation slightly wrongly, because the atmosphere the shell flies through is not
## the one the table was computed for. Spotting corrections move this number, and they
## move it without knowing which of the errors they are correcting — which is exactly
## why one correction can absorb all of them.
## `range_per_radian` is the gun's own dR/d(elevation) at this range, which is what
## turns the director's angular wander into metres on the water.
func laid_range(intercept_range_m: float, range_per_radian: float) -> float:
	return maxf(intercept_range_m * (1.0 + ballistic_bias) + spot_correction_m
		+ pointing_elevation_rad * range_per_radian, 1.0)


# -- spotting ------------------------------------------------------------------

## Note where one shell fell. Positive is over, negative is short.
##
## Shells are observed one at a time and corrected for as a group, because that is how
## it was done: the spotting officer watches the pattern, calls its centre over or
## short, and gives one correction for the salvo.
func observe_fall(error_m: float, range_m: float) -> void:
	_fall_sum_m += error_m
	_fall_range_sum_m += range_m
	_fall_count += 1


## Once a salvo's splashes have all been seen, correct the plot by their mean.
##
## The spotter does not measure the error, he judges it against the sea from a long
## way off, so what comes back is noisy — which is why fire converges over several
## salvos rather than solving in one, and why the third or fourth salvo is the
## dangerous one.
func _age_fall_of_shot(dt: float, fit: Fit, config: Dictionary,
		rng: DeterministicRng) -> void:
	if _fall_count <= 0:
		return
	_fall_age_s += dt
	if _fall_age_s < FALL_OF_SHOT_WINDOW_S:
		return

	var spotting: Dictionary = config.get("spotting", {}) as Dictionary
	var observed: float = _fall_sum_m / float(_fall_count)
	var range_m: float = _fall_range_sum_m / float(_fall_count)
	var factor: float = spotting_factor(fit, range_m, config)
	var sigma: float = maxf(
		range_m * float(spotting.get("observationSigmaFraction", 0.0035)) * factor,
		float(spotting.get("minimumObservationM", 25.0)))
	var judged: float = observed + rng.next_gaussian() * sigma
	spot_correction_m -= judged * float(spotting.get("correctionFraction", 0.55))
	salvos_spotted += 1
	last_spot_m = judged
	_clear_fall_of_shot()


func _clear_fall_of_shot() -> void:
	_fall_sum_m = 0.0
	_fall_range_sum_m = 0.0
	_fall_count = 0
	_fall_age_s = 0.0


## How hard the fall of shot is to judge. Radar ranging on the splashes themselves is
## far better than an eye; no radar and no light at all is close to hopeless.
static func spotting_factor(fit: Fit, range_m: float, config: Dictionary) -> float:
	var spotting: Dictionary = config.get("spotting", {}) as Dictionary
	var conditions: Dictionary = config.get("conditions", {}) as Dictionary
	if fit.radar_bears(range_m):
		return float(spotting.get("radarSpottingFactor", 0.45))
	if not bool(conditions.get("opticalUsable", true)):
		return float(spotting.get("blindSpottingFactor", 2.5))
	return 1.0 / maxf(float(conditions.get("visibilityFactor", 1.0)), 0.05)


## How well this plot is solving, 0 to 1. Read by the HUD and by the AI, which is
## allowed to know its own gunnery is not yet on, exactly as a captain would.
func quality(range_m: float) -> float:
	if not opened or range_m <= 0.0:
		return 0.0
	var total: float = absf(range_error_m + ballistic_bias * range_m + spot_correction_m)
	return clampf(1.0 - total / maxf(range_m * 0.02, 50.0), 0.0, 1.0)


func hash_into(hasher: StateHasher) -> void:
	hasher.write_int(target_id)
	hasher.write_float(range_error_m)
	hasher.write_float(bearing_error_rad)
	hasher.write_float(course_estimate)
	hasher.write_float(speed_estimate)
	hasher.write_float(spot_correction_m)
	hasher.write_float(pointing_elevation_rad)


func deserialize(data: Dictionary) -> void:
	target_id = int(data.get("targetId", 0))
	range_error_m = float(data.get("rangeErrorM", 0.0))
	bearing_error_rad = float(data.get("bearingErrorRad", 0.0))
	course_estimate = float(data.get("courseEstimate", 0.0))
	speed_estimate = float(data.get("speedEstimate", 0.0))
	ballistic_bias = float(data.get("ballisticBias", 0.0))
	spot_correction_m = float(data.get("spotCorrectionM", 0.0))
	pointing_elevation_rad = float(data.get("pointingElevationRad", 0.0))
	pointing_bearing_rad = float(data.get("pointingBearingRad", 0.0))
	tracking_seconds = float(data.get("trackingSeconds", 0.0))
	salvos_spotted = int(data.get("salvosSpotted", 0))
	opened = bool(data.get("opened", true))
	_clear_fall_of_shot()


func serialize() -> Dictionary:
	return {
		"targetId": target_id,
		"pointingElevationRad": pointing_elevation_rad,
		"pointingBearingRad": pointing_bearing_rad,
		"opened": opened,
		"rangeErrorM": range_error_m,
		"bearingErrorRad": bearing_error_rad,
		"courseEstimate": course_estimate,
		"speedEstimate": speed_estimate,
		"ballisticBias": ballistic_bias,
		"spotCorrectionM": spot_correction_m,
		"trackingSeconds": tracking_seconds,
		"salvosSpotted": salvos_spotted,
	}
