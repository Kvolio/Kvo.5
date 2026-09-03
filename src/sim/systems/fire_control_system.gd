class_name FireControlSystem
extends RefCounted

## Gunnery direction: where to point the guns so a shell and a ship arrive at the
## same place at the same time.
##
## The hard part is not aiming at the target, it is aiming at where the target will
## be. A 16-inch shell fired at 30 km is in the air for the better part of a minute,
## during which a 30-knot ship moves nearly half a kilometre. Getting a hit means
## solving that intercept — and because the answer changes the range, which changes
## the time of flight, which changes the answer, it has to be iterated.
##
## Three or four passes converge to well inside dispersion. That convergence is also
## exactly why a manoeuvring target is hard to hit: the solution is computed for the
## course the target is on now, and a ship that turns after the salvo is fired is no
## longer where the solution said she would be. Nothing models "evasion" explicitly;
## it falls out of the lead being wrong.
##
## What this system solves is the intercept. What it solves it AGAINST is the ship's
## plot (`FireControlSolution`), not the target — the plot's estimate of where she is
## and what she is doing, which is wrong in four separate ways and only becomes less
## wrong through tracking and spotting. Passing a null plot means perfect information,
## and exists so a test can exercise the intercept geometry on its own.

## Iterations of the intercept solve. Each pass costs two array lookups.
const INTERCEPT_ITERATIONS: int = 4

## How closely a mount must be laid before it is allowed to fire.
const BEARING_TOLERANCE: float = deg_to_rad(1.0)
const ELEVATION_TOLERANCE: float = deg_to_rad(0.5)


## A complete gunnery solution for one mount against one target.
class Solution extends RefCounted:
	var valid: bool = false
	var reason: String = ""

	var aim_point: Vector2 = Vector2.ZERO      ## where the shell is sent
	var world_bearing: float = 0.0             ## radians, world frame
	var relative_bearing: float = 0.0          ## radians, relative to the ship's bow
	var elevation: float = 0.0
	var range_m: float = 0.0                   ## to the aim point, not the target
	var present_range_m: float = 0.0           ## to the target right now
	var time_of_flight: float = 0.0
	var striking_velocity: float = 0.0
	var descent_angle: float = 0.0
	var lead_m: float = 0.0                    ## how far ahead of the target it aims
	var solution_error_m: float = 0.0          ## how far the aim point misses the target by
	var bears: bool = false                    ## the mount can train onto it


## Solve for one mount firing at one target.
##
## `table` is the range table for the mount's gun and selected shell. The mount's own
## world position is used rather than the ship's centre: on a 270 m battleship the
## difference between A turret and Y turret is a real bearing offset at close range,
## and pretending both are amidships would put half the salvo consistently off.
static func solve(
	shooter: ShipEntity, turret: Turret, target: ShipEntity, table: RangeTable,
	plot: FireControlSolution = null
) -> Solution:
	var solution: Solution = Solution.new()
	if table == null:
		solution.reason = "no range table"
		return solution
	if not turret.is_operational():
		solution.reason = "mount out of action"
		return solution

	var origin: Vector2 = mount_world_position(shooter, turret)

	# The intercept is solved against what the ship BELIEVES, not against the target.
	# Where the two differ is the whole of the difference between this model and one
	# that hits three times too often.
	var believed_position: Vector2 = target.position
	var believed_velocity: Vector2 = target.velocity()
	if plot != null:
		believed_position = plot.estimated_target_position(origin, target)
		believed_velocity = plot.estimated_velocity()

	# The intercept is solved in the SHOOTER'S frame, against relative motion.
	#
	# A shell leaves a ship making twenty knots already carrying those twenty knots, and
	# over half a minute of flight that is nearly four hundred metres — as large as
	# every other error in the system put together. Real fire control compensated for
	# own-ship motion for exactly this reason, and the compensation and the inherited
	# velocity very nearly cancel: what is left is the intercept against the target's
	# motion RELATIVE to the firing ship. Solving it here and adding the ship's velocity
	# to the shell in GunnerySystem is the same statement made twice, once for the
	# gunlayer and once for the physics.
	var relative_velocity: Vector2 = believed_velocity - shooter.velocity()
	var aim: Vector2 = believed_position
	var range_solution: RangeTable.FiringSolution = null

	solution.present_range_m = origin.distance_to(target.position)

	for _i: int in INTERCEPT_ITERATIONS:
		var range_to_aim: float = origin.distance_to(aim)
		range_solution = table.solve_for_range(range_to_aim)
		if not range_solution.valid:
			solution.reason = "out of range"
			return solution
		# Straight-line extrapolation over the flight. A turning target is not
		# modelled, and that is correct: the gunnery officer cannot see the future
		# either, which is why a ship under fire turns.
		aim = believed_position + relative_velocity * range_solution.time_of_flight

	solution.lead_m = aim.distance_to(believed_position)

	# The plot has decided where to shoot. Laying the guns on it is a second, separate
	# source of error: the range table converts range to elevation for an atmosphere
	# that is not quite the one the shell will fly through, the spotting officer has
	# already moved the range by whatever his last correction was, and the director is
	# never perfectly steady. None of that changes where the target is believed to be —
	# it changes where the shell is sent.
	var bearing: float = (aim - origin).angle()
	var laid: float = origin.distance_to(aim)
	if plot != null:
		bearing += plot.pointing_bearing_rad
		laid = plot.laid_range(laid, table.range_gradient(laid))
		range_solution = table.solve_for_range(laid)
		if not range_solution.valid:
			solution.reason = "out of range"
			return solution

	solution.aim_point = origin + Vector2(cos(bearing), sin(bearing)) * laid
	solution.range_m = laid
	solution.solution_error_m = solution.aim_point.distance_to(target.position)
	solution.world_bearing = bearing
	solution.relative_bearing = SimUnits.angle_delta(shooter.heading, bearing)
	solution.elevation = range_solution.elevation
	solution.time_of_flight = range_solution.time_of_flight
	solution.striking_velocity = range_solution.striking_velocity
	solution.descent_angle = range_solution.descent_angle
	solution.bears = turret.mount.can_bear(solution.relative_bearing)
	solution.valid = true
	if not solution.bears:
		solution.reason = "target outside the mount's arc"
	return solution


## World position of a mount, from its normalised position on the hull.
static func mount_world_position(ship: ShipEntity, turret: Turret) -> Vector2:
	var local: Vector2 = turret.mount.local_position(ship.spec.length_m, ship.spec.beam_m)
	return ship.position + local.rotated(ship.heading)


## One mount that is laid, loaded, bearing, and the solution it is laid on.
class ReadyMount extends RefCounted:
	var turret: Turret = null
	var solution: Solution = null


## Lay every mount on the ship's current target, and report which are ready to fire.
##
## Mounts that cannot bear are trained as far round as their stops allow rather than
## left where they were, so they are already close when the ship's turn brings the
## target into arc.
##
## The solution is returned with the mount rather than being recomputed at the moment
## of firing: solving an intercept means four passes over a range table, and doing it
## twice for the same shot is pure waste.
static func direct_battery(
	shooter: ShipEntity, turrets: Array[Turret], target: ShipEntity, armory: Armory,
	plot: FireControlSolution = null
) -> Array[ReadyMount]:
	var ready: Array[ReadyMount] = []
	if target == null or not target.is_afloat():
		for turret: Turret in turrets:
			turret.stand_down()
		return ready

	for turret: Turret in turrets:
		if not turret.is_operational():
			continue
		var table: RangeTable = armory.range_table(turret.gun.gun_id, turret.selected_shell)
		var solution: Solution = solve(shooter, turret, target, table, plot)
		if not solution.valid:
			turret.stand_down()
			continue
		turret.order_lay(solution.relative_bearing, solution.elevation)
		if solution.bears and turret.is_ready_to_fire(BEARING_TOLERANCE, ELEVATION_TOLERANCE):
			var entry: ReadyMount = ReadyMount.new()
			entry.turret = turret
			entry.solution = solution
			ready.append(entry)
	return ready


## Advance every mount's training, elevation and reload.
static func step_turrets(turrets: Array[Turret], dt: float) -> void:
	for turret: Turret in turrets:
		turret.step(dt)


## Fraction of a ship's barrels that can currently bear on a bearing.
##
## This is what makes heading matter: a ship running directly away from an enemy can
## bring only her after turrets to bear, and one that turns to open her broadside
## roughly doubles her weight of fire. Used by the AI in Stage 7 to decide how to
## fight, and shown on the tactical display.
static func barrels_bearing(turrets: Array[Turret], relative_bearing: float) -> int:
	var count: int = 0
	for turret: Turret in turrets:
		if turret.is_operational() and turret.mount.can_bear(relative_bearing):
			count += turret.barrels()
	return count
