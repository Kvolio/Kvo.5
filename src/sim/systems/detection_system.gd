class_name DetectionSystem
extends RefCounted

## Finding the enemy, which for most of a naval action is the hard part.
##
## The single most important number here is not a spotting range in anybody's data
## file. It is the horizon. A lookout does not fail to see a battleship at 25 km
## because she is small — he fails because she is below the curve of the earth. The
## distance to the horizon goes as the square root of the observer's height, and both
## ships get their own, which is why:
##
##   * the masts are sighted long before the hull, and a ship first appears as a smudge
##   * a destroyer with a 25 m mast sees a battleship's 50 m foretop at some 43 km,
##     while the battleship sees the destroyer's own masts at the same 43 km — the
##     geometry is symmetric even though the ships are not
##   * running away below the horizon really does work, and it is how ships escaped
##
## Everything else — visibility, night, radar, gun flashes, a ship on fire — moves the
## detection range around inside or outside that limit. Nothing about it is stated per
## ship: the height comes from the superstructure the design actually produced.

## Both coefficients are the standard horizon approximations: 3570*sqrt(h) metres for
## the eye, 4120*sqrt(h) for centimetric radar, which the atmosphere bends downwards.
const DEFAULT_HORIZON_COEFFICIENT: float = 3570.0
const DEFAULT_RADAR_HORIZON_COEFFICIENT: float = 4120.0

const RNG_STREAM: String = "detection"


## One sweep of every team's lookouts and sets.
##
## Ordered: teams ascending, then observers ascending by id, then targets ascending by
## id. Nothing here may depend on the order entities happen to sit in a container.
static func step(world: SimWorld, dt: float) -> void:
	if world.contacts == null or world.detection_config.is_empty():
		return
	var plot_config: Dictionary = world.detection_config.get("plot", {}) as Dictionary
	var seen: Dictionary = {}

	for observer: ShipEntity in world.ships:
		if not observer.is_alive():
			continue
		var reach: float = maximum_reach(observer, world)
		if reach <= 0.0:
			continue
		var candidates: PackedInt32Array = world.spatial.query_radius(
			observer.position, reach, SpatialIndex.Layer.SHIP)
		for target_id: int in candidates:
			if target_id == observer.id:
				continue
			var target: ShipEntity = world.get_ship(target_id)
			if target == null or not target.is_alive() or target.team == observer.team:
				continue
			# A contact already made by another ship of the same team this pass does
			# not need making again — but a BETTER method does replace a worse one,
			# because a radar plot beats a smudge on the horizon.
			var method: int = detect(observer, target, world)
			if method == ContactPlot.Method.NONE:
				continue
			var key: int = ContactPlot.pass_key(observer.team, target_id)
			var existing: ContactPlot.Contact = world.contacts.contact(observer.team, target_id)
			if seen.has(key) and existing != null and _rank(existing.method) >= _rank(method):
				continue
			var estimate: Vector2 = estimated_position(observer, target, method, world)
			var contact: ContactPlot.Contact = world.contacts.sight(
				observer.team, target, method, estimate, world.clock.tick)
			_classify(contact, target, method, dt, plot_config)
			seen[key] = true

	world.contacts.age(dt, float(plot_config.get("forgetSeconds", 180.0)), seen)


## How a target is detected, if at all. The best method available wins.
static func detect(observer: ShipEntity, target: ShipEntity, world: SimWorld) -> int:
	var config: Dictionary = world.detection_config
	var range_m: float = observer.position.distance_to(target.position)
	var signature: Detectable.Signature = target.detection_signature()

	if range_m <= radar_range(observer, target, world):
		return ContactPlot.Method.RADAR
	if range_m <= visual_range(observer, signature, config):
		return ContactPlot.Method.VISUAL

	# Past the point where she can be seen, two things still give her away.
	var horizon: float = optical_horizon(observer.sighting_height_m, signature.height_m, config)
	var glow: Dictionary = config.get("fireGlow", {}) as Dictionary
	if signature.burning >= float(glow.get("minimumFireFraction", 0.04)) \
			and range_m <= horizon * float(glow.get("rangeFactorOfHorizon", 1.6)):
		return ContactPlot.Method.FIRE_GLOW

	var flash: Dictionary = config.get("gunFlash", {}) as Dictionary
	if signature.firing:
		var conditions: Dictionary = config.get("conditions", {}) as Dictionary
		var factor: float = float(flash.get("dayRangeFactorOfHorizon", 1.05))
		if bool(conditions.get("night", false)):
			factor = float(flash.get("rangeFactorOfHorizon", 2.2))
		if range_m <= horizon * factor:
			return ContactPlot.Method.GUN_FLASH

	return ContactPlot.Method.NONE


## Distance at which the target's highest point rises above the observer's horizon.
static func optical_horizon(observer_height_m: float, target_height_m: float,
		config: Dictionary) -> float:
	var sighting: Dictionary = config.get("sighting", {}) as Dictionary
	var k: float = float(sighting.get("horizonCoefficientM", DEFAULT_HORIZON_COEFFICIENT))
	return k * (sqrt(maxf(observer_height_m, 0.0)) + sqrt(maxf(target_height_m, 0.0)))


## How far the eye can pick her out: the horizon, or the weather, whichever binds
## first — and at night it is neither, it is how little there is to see.
static func visual_range(observer: ShipEntity, signature: Detectable.Signature,
		config: Dictionary) -> float:
	var visual: Dictionary = config.get("visual", {}) as Dictionary
	var conditions: Dictionary = config.get("conditions", {}) as Dictionary

	var horizon: float = optical_horizon(observer.sighting_height_m, signature.height_m, config)

	# Bigger ships are picked up further out — but contrast against the sea does not
	# scale with size, so the exponent is well under a half.
	var reference: float = maxf(float(visual.get("referenceSilhouetteM2", 2500.0)), 1.0)
	var relative: float = maxf(signature.silhouette_m2, 1.0) / reference
	var size_factor: float = pow(relative, float(visual.get("silhouetteExponent", 0.35)))

	var weather: float = float(visual.get("meteorologicalRangeM", 40000.0))
	weather *= float(conditions.get("visibilityFactor", 1.0)) * size_factor
	if bool(conditions.get("night", false)):
		weather *= float(visual.get("nightFactor", 0.12))
	return minf(horizon, weather)


## How far the observer's set holds her: its own range, capped by the radar horizon.
##
## The horizon binds radar too, and that is why a set with a 40 km nominal range does
## not see a destroyer at 40 km — the destroyer is under the curve. It is also why
## aircraft were detected so much further out than ships.
static func radar_range(observer: ShipEntity, target: ShipEntity, world: SimWorld) -> float:
	var config: Dictionary = world.detection_config
	var sets: Dictionary = (config.get("radar", {}) as Dictionary).get("sets", {}) as Dictionary
	var set_name: String = radar_set_of(observer, world)
	if not sets.has(set_name) or set_name == "none":
		return 0.0
	var nominal: float = float((sets[set_name] as Dictionary).get("rangeM", 0.0))
	if nominal <= 0.0:
		return 0.0

	var sighting: Dictionary = config.get("sighting", {}) as Dictionary
	var k: float = float(sighting.get("radarHorizonCoefficientM", DEFAULT_RADAR_HORIZON_COEFFICIENT))
	var horizon: float = k * (sqrt(maxf(observer.sighting_height_m, 0.0))
		+ sqrt(maxf(target.detection_signature().height_m, 0.0)))
	return minf(nominal, horizon)


## Which search set the ship carries. Shares the fire-control fit, because the year and
## the installation that decided one decided the other.
static func radar_set_of(ship: ShipEntity, world: SimWorld) -> String:
	if ship.fire_control_fit == null:
		if world.fire_control_config.is_empty():
			return "none"
		ship.fire_control_fit = FireControlSolution.fit_for(ship.spec, world.fire_control_config)
	return ship.fire_control_fit.radar_set


## The furthest anything could possibly be detected from this ship, for the broadphase.
static func maximum_reach(observer: ShipEntity, world: SimWorld) -> float:
	var config: Dictionary = world.detection_config
	var sighting: Dictionary = config.get("sighting", {}) as Dictionary
	var flash: Dictionary = config.get("gunFlash", {}) as Dictionary
	# The tallest plausible target doubles the horizon term; taking the observer's own
	# height twice is a safe over-estimate and keeps the broadphase honest — a
	# candidate wrongly included is rejected below, one wrongly excluded is a ship that
	# simply never appears.
	var k: float = float(sighting.get("radarHorizonCoefficientM", DEFAULT_RADAR_HORIZON_COEFFICIENT))
	var horizon: float = k * sqrt(maxf(observer.sighting_height_m, 1.0)) * 2.0
	return horizon * maxf(float(flash.get("rangeFactorOfHorizon", 2.2)), 1.0)


## Where the plot puts her, which is not where she is.
##
## Radar gives an accurate range and a bearing whose quality depends on the set. The
## eye is the other way round: bearing is excellent, range is a guess. A gun flash in
## the dark gives a bearing and nothing else at all, so the range that goes with it is
## little better than a guess at how far away the enemy might be — and a plot built on
## those is why night actions were fought at ranges nobody intended.
static func estimated_position(observer: ShipEntity, target: ShipEntity, method: int,
		world: SimWorld) -> Vector2:
	var rng: DeterministicRng = world.rng.stream(RNG_STREAM)
	var los: Vector2 = target.position - observer.position
	var range_m: float = los.length()
	if range_m <= 0.0:
		return target.position

	var bearing_sigma: float = 0.0
	var range_sigma: float = 0.0
	var config: Dictionary = world.detection_config
	match method:
		ContactPlot.Method.RADAR:
			var radar: Dictionary = config.get("radar", {}) as Dictionary
			var sets: Dictionary = radar.get("sets", {}) as Dictionary
			var set_data: Dictionary = sets.get(radar_set_of(observer, world), {}) as Dictionary
			bearing_sigma = float(set_data.get("bearingSigmaRad", 0.01))
			range_sigma = float(radar.get("rangeSigmaM", 60.0))
		ContactPlot.Method.VISUAL:
			bearing_sigma = 0.004
			range_sigma = range_m * 0.06
		ContactPlot.Method.FIRE_GLOW:
			bearing_sigma = 0.008
			range_sigma = range_m * 0.12
		_:
			bearing_sigma = 0.012
			range_sigma = range_m * 0.30

	var bearing: float = los.angle() + rng.next_gaussian() * bearing_sigma
	var estimated: float = maxf(range_m + rng.next_gaussian() * range_sigma, 1.0)
	return observer.position + Vector2(cos(bearing), sin(bearing)) * estimated


## Telling a cruiser from a destroyer takes time and good light, and getting it wrong is
## how ships ended up engaging what they thought was something else.
static func _classify(contact: ContactPlot.Contact, target: ShipEntity, method: int,
		dt: float, plot_config: Dictionary) -> void:
	if contact.classified:
		return
	if method == ContactPlot.Method.GUN_FLASH:
		return
	if contact.held_seconds + dt >= float(plot_config.get("classifySeconds", 25.0)):
		contact.classified = true
		contact.ship_type = target.spec.ship_type


## Which method wins when two ships of the same team report the same target.
static func _rank(method: int) -> int:
	match method:
		ContactPlot.Method.RADAR:
			return 4
		ContactPlot.Method.VISUAL:
			return 3
		ContactPlot.Method.FIRE_GLOW:
			return 2
		ContactPlot.Method.GUN_FLASH:
			return 1
	return 0
