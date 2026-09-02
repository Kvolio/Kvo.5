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
	var bears: bool = false                    ## the mount can train onto it


## Solve for one mount firing at one target.
##
## `table` is the range table for the mount's gun and selected shell. The mount's own
## world position is used rather than the ship's centre: on a 270 m battleship the
## difference between A turret and Y turret is a real bearing offset at close range,
## and pretending both are amidships would put half the salvo consistently off.
static func solve(
	shooter: ShipEntity, turret: Turret, target: ShipEntity, table: RangeTable
) -> Solution:
	var solution: Solution = Solution.new()
	if table == null:
		solution.reason = "no range table"
		return solution
	if not turret.is_operational():
		solution.reason = "mount out of action"
		return solution

	var origin: Vector2 = mount_world_position(shooter, turret)
	var target_velocity: Vector2 = target.velocity()
	var aim: Vector2 = target.position
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
		aim = target.position + target_velocity * range_solution.time_of_flight

	solution.aim_point = aim
	solution.range_m = origin.distance_to(aim)
	solution.lead_m = aim.distance_to(target.position)
	solution.world_bearing = (aim - origin).angle()
	solution.relative_bearing = SimUnits.angle_delta(shooter.heading, solution.world_bearing)
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


## Lay every mount on the ship's current target, and report which are ready to fire.
##
## Mounts that cannot bear are trained as far round as their stops allow rather than
## left where they were, so they are already close when the ship's turn brings the
## target into arc.
static func direct_battery(
	shooter: ShipEntity, turrets: Array[Turret], target: ShipEntity, armory: Armory
) -> Array[Turret]:
	var ready: Array[Turret] = []
	if target == null or not target.is_afloat():
		for turret: Turret in turrets:
			turret.stand_down()
		return ready

	for turret: Turret in turrets:
		if not turret.is_operational():
			continue
		var table: RangeTable = armory.range_table(turret.gun.gun_id, turret.selected_shell)
		var solution: Solution = solve(shooter, turret, target, table)
		if not solution.valid:
			turret.stand_down()
			continue
		turret.order_lay(solution.relative_bearing, solution.elevation)
		if solution.bears and turret.is_ready_to_fire(BEARING_TOLERANCE, ELEVATION_TOLERANCE):
			ready.append(turret)
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
