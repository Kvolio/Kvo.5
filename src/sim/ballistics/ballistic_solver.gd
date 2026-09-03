class_name BallisticSolver
extends RefCounted

## Exterior ballistics: a shell's flight through real air, in three dimensions.
##
## This is what makes the whole armour model possible. A shell arriving at 20 km has
## lost a third of its muzzle velocity and is falling at 15 degrees; at 35 km it is
## falling at 45 and will strike deck armour rather than the belt. Neither fact can
## be recovered from a 2D straight line, and both decide whether a ship survives —
## which is why the battlefield is drawn top-down but the projectiles are simulated
## in full 3D, with z the height above the sea.
##
## Integration is Runge-Kutta 4 throughout. It is stable enough that a quarter-second
## step costs under half a metre over 33 km, so range tables can be built cheaply at
## load, while shells in flight use the simulation tick for smooth motion and swept
## hit tests — and the two agree to well inside a shell's dispersion.

const GRAVITY: float = SimUnits.GRAVITY

var _atmosphere: Atmosphere = null
var _drag: DragModel = null


static func from_config(config: Dictionary) -> BallisticSolver:
	var solver: BallisticSolver = BallisticSolver.new()
	solver._atmosphere = Atmosphere.from_config(config)
	solver._drag = DragModel.from_config(config)
	return solver


func atmosphere() -> Atmosphere:
	return _atmosphere


## Drag deceleration plus gravity, in m/s^2.
##
## `drag_area_over_mass` is (form factor x cross-sectional area) / mass, precomputed
## per shell because it never changes during a flight and this runs several times per
## step per projectile.
func acceleration(position: Vector3, velocity: Vector3, drag_area_over_mass: float) -> Vector3:
	var speed: float = velocity.length()
	if speed <= 0.0:
		return Vector3(0.0, 0.0, -GRAVITY)
	var air: Vector2 = _atmosphere.sample(position.z)
	var density: float = air.x
	var sound_speed: float = maxf(air.y, 1.0)
	var cd: float = _drag.coefficient_at(speed / sound_speed)
	# F_drag = 0.5 * rho * v^2 * Cd * A, opposing motion. Dividing by mass and
	# folding one factor of v into the direction gives -k * |v| * v.
	var k: float = 0.5 * density * cd * drag_area_over_mass
	return -velocity * (k * speed) - Vector3(0.0, 0.0, GRAVITY)


## One RK4 step. Returns the new [position, velocity].
func step(position: Vector3, velocity: Vector3, drag_area_over_mass: float, dt: float) -> Array:
	var k1_v: Vector3 = velocity
	var k1_a: Vector3 = acceleration(position, velocity, drag_area_over_mass)

	var k2_v: Vector3 = velocity + k1_a * (dt * 0.5)
	var k2_a: Vector3 = acceleration(position + k1_v * (dt * 0.5), k2_v, drag_area_over_mass)

	var k3_v: Vector3 = velocity + k2_a * (dt * 0.5)
	var k3_a: Vector3 = acceleration(position + k2_v * (dt * 0.5), k3_v, drag_area_over_mass)

	var k4_v: Vector3 = velocity + k3_a * dt
	var k4_a: Vector3 = acceleration(position + k3_v * dt, k4_v, drag_area_over_mass)

	var new_position: Vector3 = position + (k1_v + 2.0 * k2_v + 2.0 * k3_v + k4_v) * (dt / 6.0)
	var new_velocity: Vector3 = velocity + (k1_a + 2.0 * k2_a + 2.0 * k3_a + k4_a) * (dt / 6.0)
	return [new_position, new_velocity]


## Cross-sectional area times form factor, divided by mass. Precompute once per shell.
static func drag_area_over_mass(diameter_m: float, mass_kg: float, form_factor: float) -> float:
	var radius: float = diameter_m * 0.5
	var area: float = PI * radius * radius
	return (area * form_factor) / maxf(mass_kg, 0.001)


## Fire a shell at a given elevation and follow it until it returns to sea level.
##
## Returns a TrajectoryResult. The impact state is interpolated to the exact moment
## z crosses zero rather than reported at the step that overshot it, so the striking
## velocity and descent angle the penetration model receives are the real ones and
## not an artefact of the step size.
func solve_flight(
	muzzle_velocity: float, elevation_rad: float, drag_over_mass: float,
	dt: float, max_seconds: float
) -> TrajectoryResult:
	return solve_flight_from_height(muzzle_velocity, elevation_rad, drag_over_mass, 0.0, dt, max_seconds)


## As solve_flight, but launched from a gun standing `muzzle_height` above the water.
##
## Not a detail: a gun at zero elevation firing from sea level would put its shell in
## the water on the first step, so without a launch height the flat end of every range
## table degenerates and short-range gunnery has no solution at all.
func solve_flight_from_height(
	muzzle_velocity: float, elevation_rad: float, drag_over_mass: float,
	muzzle_height: float, dt: float, max_seconds: float
) -> TrajectoryResult:
	var result: TrajectoryResult = TrajectoryResult.new()
	var position: Vector3 = Vector3(0.0, 0.0, muzzle_height)
	var velocity: Vector3 = Vector3(cos(elevation_rad), 0.0, sin(elevation_rad)) * muzzle_velocity
	var time: float = 0.0
	result.apex_altitude = muzzle_height

	while time < max_seconds:
		var previous_position: Vector3 = position
		var previous_velocity: Vector3 = velocity
		var stepped: Array = step(position, velocity, drag_over_mass, dt)
		position = stepped[0]
		velocity = stepped[1]
		time += dt
		result.apex_altitude = maxf(result.apex_altitude, position.z)

		if position.z < 0.0 and time > dt:
			# Linear interpolation on altitude between the bracketing states. The arc
			# is very nearly straight over a quarter second, and this removes the
			# step-size dependence from the impact conditions entirely.
			var span: float = previous_position.z - position.z
			var t: float = 0.0 if span <= 0.0 else previous_position.z / span
			result.impact_position = previous_position.lerp(position, t)
			result.impact_velocity = previous_velocity.lerp(velocity, t)
			result.time_of_flight = time - dt + dt * t
			result.valid = true
			return result

	# Ran out of flight time: a shell fired near vertical, or a broken configuration.
	result.valid = false
	result.time_of_flight = time
	result.impact_position = position
	result.impact_velocity = velocity
	return result


## One completed trajectory.
class TrajectoryResult extends RefCounted:
	var valid: bool = false
	var impact_position: Vector3 = Vector3.ZERO
	var impact_velocity: Vector3 = Vector3.ZERO
	var time_of_flight: float = 0.0
	var apex_altitude: float = 0.0

	## Horizontal distance travelled, in metres.
	func range_m() -> float:
		return Vector2(impact_position.x, impact_position.y).length()

	## Speed at the moment of impact.
	func striking_velocity() -> float:
		return impact_velocity.length()

	## Angle below horizontal at impact, in radians. This is what decides whether a
	## shell strikes the belt or plunges onto the deck.
	func descent_angle() -> float:
		var horizontal: float = Vector2(impact_velocity.x, impact_velocity.y).length()
		return atan2(-impact_velocity.z, maxf(horizontal, 0.0001))
