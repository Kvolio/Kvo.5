class_name MovementSystem
extends RefCounted

## Ship motion: thrust against resistance, rudder against inertia.
##
## Nothing here is per-class. A destroyer answers the helm quickly and a battleship
## does not, because one is 2,000 tonnes and the other 45,000; a ship that has lost
## two shafts slows down because it has less power to push the same resistance. The
## spec's requirement that "a battleship should not turn like a destroyer" is met by
## not having a knob that says so.
##
## THE MODEL
##
## Surge. Resistance is R = c*v^2, so at the design point P = R*v = c*v^3 and the
## drag coefficient c falls straight out of the ship's own power and top speed.
## Thrust from a fixed-power plant is T = P/v, which is singular at rest, so it is
## capped at a bollard-pull ceiling. Net force over mass (plus added mass — the
## water a hull drags along with it) gives acceleration.
##
## Yaw. A rudder produces a turn rate proportional to speed: v/R_turn at full
## rudder, where R_turn comes from the ship's tactical diameter. A ship dead in the
## water cannot steer, and that falls out of the v term rather than being a special
## case. The hull does not reach that rate instantly — it is approached at a bounded
## angular acceleration derived from the ship's own yaw response time, which is what
## makes a battleship feel heavy.

const MIN_TURN_SPEED: float = 0.05  ## m/s below which rudder produces no yaw

var _surge_added_mass: float = 1.08
var _bollard_factor: float = 1.2
var _astern_fraction: float = 0.35
var _astern_resistance: float = 2.5
var _min_thrust_speed: float = 0.5
var _turn_speed_loss: float = 0.35
var _asymmetry_gain: float = 0.35


## Configured from data/config/physics.json. Passing the values in rather than
## reading a global keeps the system constructible in a test without an autoload.
func configure(config: Dictionary) -> void:
	var hydro: Dictionary = config.get("hydrodynamics", {}) as Dictionary
	_surge_added_mass = float(hydro.get("surgeAddedMassFactor", _surge_added_mass))
	_bollard_factor = float(hydro.get("bollardThrustFactor", _bollard_factor))
	_astern_fraction = float(hydro.get("asternPowerFraction", _astern_fraction))
	_astern_resistance = float(hydro.get("asternResistanceMultiplier", _astern_resistance))
	_min_thrust_speed = float(hydro.get("minimumThrustSpeed", _min_thrust_speed))

	var manoeuvre: Dictionary = config.get("manoeuvring", {}) as Dictionary
	_turn_speed_loss = float(manoeuvre.get("turnSpeedLossAtFullRudder", _turn_speed_loss))
	_asymmetry_gain = float(manoeuvre.get("shaftAsymmetryYawGain", _asymmetry_gain))


func step(ships: Array[ShipEntity], dt: float) -> void:
	for ship: ShipEntity in ships:
		if not ship.is_afloat():
			continue
		_step_rudder(ship, dt)
		_step_surge(ship, dt)
		_step_yaw(ship, dt)
		_integrate(ship, dt)


## The rudder moves towards its ordered angle at a finite rate.
##
## A jammed rudder stays where it is — a wrecked steering gear leaves the ship
## circling, which is how more than one real battle ended.
func _step_rudder(ship: ShipEntity, dt: float) -> void:
	if ship.rudder_jammed:
		return
	var limit: float = ship.spec.max_rudder_rad
	var target: float = clampf(ship.rudder_order, -limit, limit)
	# Damaged steering gear swings the rudder more slowly as well as less far.
	var rate: float = ship.spec.rudder_rate_rad_s * maxf(ship.rudder_effectiveness, 0.05)
	ship.rudder_angle = move_toward(ship.rudder_angle, target, rate * dt)


func _step_surge(ship: ShipEntity, dt: float) -> void:
	var spec: ShipSpec = ship.spec
	var mass: float = spec.mass_kg() * _surge_added_mass
	if mass <= 0.0:
		return

	var drag_coefficient: float = spec.resistance_coefficient()
	var design_speed: float = maxf(spec.max_speed_ms, 0.1)
	var demand: float = clampf(ship.throttle, -1.0, 1.0)

	# Hard-over rudder costs a great deal of speed. Modelled as a reduction in the
	# power reaching the water rather than as a separate braking force, so the ship
	# settles at a genuinely lower equilibrium in a sustained turn instead of being
	# decelerated and then re-accelerated.
	#
	# The configured figure is a SPEED loss, because that is what sea trials report.
	# Speed goes as the cube root of power, so it has to be cubed on the way in:
	# a 35% speed loss is a 73% power loss, not a 35% one.
	var rudder_fraction: float = 0.0
	if spec.max_rudder_rad > 0.0:
		rudder_fraction = absf(ship.rudder_angle) / spec.max_rudder_rad
	var speed_penalty: float = 1.0 - _turn_speed_loss * rudder_fraction
	var turn_power_penalty: float = speed_penalty * speed_penalty * speed_penalty

	var power_fraction: float = absf(demand) * ship.propulsion_fraction * turn_power_penalty
	if demand < 0.0:
		power_fraction *= _effective_astern_power_fraction(spec)

	# Power-limited thrust, T = P/v, with the speed floored so it stays finite at
	# rest. The ceiling is bollard pull: the most the screws can push at zero way on.
	# Thrust scales as the 2/3 power of shaft power (thrust goes with RPM squared,
	# power with RPM cubed), so a part-power ceiling must use the same exponent —
	# scaling it linearly would make the cap bind at cruising speeds where it has no
	# business binding, and quietly cap the ship below her ordered speed.
	var thrust_speed: float = maxf(absf(ship.speed), _min_thrust_speed)
	var bollard_limit: float = drag_coefficient * design_speed * design_speed * _bollard_factor
	var thrust: float = minf(
		spec.propulsion_power_w * power_fraction / thrust_speed,
		bollard_limit * pow(power_fraction, 2.0 / 3.0)
	)
	thrust *= signf(demand)

	# Resistance always opposes motion, which is what makes a ship coast to a stop
	# when the throttle comes off rather than needing an explicit braking rule.
	# Driven stern-first the hull is not the shape it was designed to be and drags
	# much harder, so a ship gathering sternway also loses it quickly.
	var resistance: float = drag_coefficient * ship.speed * absf(ship.speed)
	if ship.speed < 0.0:
		resistance *= _astern_resistance

	var acceleration: float = (thrust - resistance) / mass
	var new_speed: float = ship.speed + acceleration * dt

	# Integrating a v^2 drag term explicitly can overshoot through zero on a large
	# step and leave a stopped ship oscillating. With the throttle off, a sign flip
	# just means the ship has stopped.
	if is_zero_approx(demand) and signf(new_speed) != signf(ship.speed) and not is_zero_approx(ship.speed):
		new_speed = 0.0

	ship.speed = clampf(new_speed, -ship.max_sternway_speed(), ship.effective_max_speed())


## Astern power fraction that actually produces the ship's stated sternway ceiling.
##
## The reversing turbines are rated at some 35% of ahead power, but a ship driven
## by them does NOT make 70% of her speed astern — real sternway is nearer 30%.
## What limits it is propeller thrust breakdown in reverse and the loads sternway
## puts on the rudder, neither of which this model simulates directly. Rather than
## invent a resistance figure large enough to hide that, the ceiling is stated in
## the data and the effective power fraction is solved backwards from it.
##
## From P/v = c*R*v^2 at equilibrium, v = v_design * (P_fraction/R)^(1/3), so a
## ceiling of `f` needs P_fraction = R * f^3.
func _effective_astern_power_fraction(spec: ShipSpec) -> float:
	var f: float = spec.max_sternway_fraction
	return _astern_resistance * f * f * f


func _step_yaw(ship: ShipEntity, dt: float) -> void:
	var spec: ShipSpec = ship.spec
	var target_rate: float = 0.0

	if absf(ship.speed) > MIN_TURN_SPEED:
		var turning_radius: float = maxf(spec.turning_radius_m(), 1.0)
		var full_rudder_rate: float = absf(ship.speed) / turning_radius
		var rudder_fraction: float = 0.0
		if spec.max_rudder_rad > 0.0:
			rudder_fraction = ship.rudder_angle / spec.max_rudder_rad
		target_rate = full_rudder_rate * rudder_fraction * ship.rudder_effectiveness
		# Making sternway reverses which way the rudder throws the stern.
		if ship.speed < 0.0:
			target_rate = -target_rate

		# An unbalanced pair of shafts turns the ship on its own — the reason a ship
		# that has lost a shaft crabs off course even with the rudder amidships.
		target_rate += full_rudder_rate * _asymmetry_gain * ship.shaft_asymmetry

	# Bounded angular acceleration, derived from the ship's own response time: the
	# rate it could reach at full rudder and full speed, spread over that many
	# seconds. Large ships take longer because their tactical diameter is larger in
	# absolute terms and their response time is longer.
	var reference_rate: float = spec.max_speed_ms / maxf(spec.turning_radius_m(), 1.0)
	var max_yaw_accel: float = reference_rate / maxf(spec.yaw_response_time_s, 0.1)
	ship.yaw_rate = move_toward(ship.yaw_rate, target_rate, max_yaw_accel * dt)


func _integrate(ship: ShipEntity, dt: float) -> void:
	ship.heading = SimUnits.normalise_angle(ship.heading + ship.yaw_rate * dt)
	ship.position += Vector2(cos(ship.heading), sin(ship.heading)) * ship.speed * dt


# ------------------------------------------------------------------- orders --

## Order a speed in m/s.
##
## Throttle is a fraction of POWER, and speed goes as the cube root of power, so the
## throttle needed for a given speed is the cube of the speed fraction. Half speed
## takes an eighth of the power — which is exactly why cruising at 15 knots gives a
## ship such enormous range compared with running at 30.
##
## An order for more than the ship can currently make simply becomes full ahead
## rather than an error, so a damaged ship still answers "make your best speed".
static func order_speed(ship: ShipEntity, target_ms: float) -> void:
	if target_ms >= 0.0:
		var ceiling: float = ship.effective_max_speed()
		if ceiling <= 0.0:
			ship.throttle = 0.0
			return
		var fraction: float = clampf(target_ms / ceiling, 0.0, 1.0)
		ship.throttle = fraction * fraction * fraction
		return
	# Astern obeys the same cube law, just against a much lower ceiling.
	var astern_ceiling: float = ship.max_sternway_speed()
	if astern_ceiling <= 0.0:
		ship.throttle = 0.0
		return
	var astern_fraction: float = clampf(absf(target_ms) / astern_ceiling, 0.0, 1.0)
	ship.throttle = -(astern_fraction * astern_fraction * astern_fraction)


## Order a rudder angle as a fraction of hard-over, -1 (hard a-port) to +1.
static func order_rudder(ship: ShipEntity, fraction: float) -> void:
	ship.rudder_order = clampf(fraction, -1.0, 1.0) * ship.spec.max_rudder_rad


## Steer towards a compass heading, easing off as the ship comes onto course.
##
## Proportional control with the gain expressed in headings rather than tuned
## numerically: full rudder while more than `full_rudder_error` off course, easing
## linearly inside that. Simple, stable at every ship size, and it does not
## overshoot the way a fixed gain does on a large ship.
static func steer_to_heading(ship: ShipEntity, target_heading: float,
		full_rudder_error: float = deg_to_rad(20.0)) -> void:
	var error: float = SimUnits.angle_delta(ship.heading, target_heading)
	order_rudder(ship, clampf(error / maxf(full_rudder_error, 0.01), -1.0, 1.0))


## Steer towards a world position.
static func steer_to_point(ship: ShipEntity, target: Vector2) -> void:
	var offset: Vector2 = target - ship.position
	if offset.length_squared() < 1.0:
		return
	steer_to_heading(ship, offset.angle())
