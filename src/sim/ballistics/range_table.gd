class_name RangeTable
extends RefCounted

## Precomputed trajectories for one gun/shell pairing.
##
## Real warships fought with printed range tables, and for the same reason this
## simulation builds one: solving a trajectory takes hundreds of integration steps,
## and a fire-control system needs an answer every time it lays a gun. Solving each
## elevation once at load and interpolating afterwards turns that into two array
## lookups.
##
## It also gives the debug overlay real numbers to show — time of flight, striking
## velocity and descent angle at any range — because they are what the table was
## built out of rather than something reconstructed afterwards.

## One solved elevation.
class Entry extends RefCounted:
	var elevation: float = 0.0          ## radians
	var range_m: float = 0.0
	var time_of_flight: float = 0.0
	var striking_velocity: float = 0.0  ## m/s
	var descent_angle: float = 0.0      ## radians below horizontal
	var apex_altitude: float = 0.0


## What a fire-control system needs to lay a gun on a target at a given range.
class FiringSolution extends RefCounted:
	var valid: bool = false
	var elevation: float = 0.0
	var range_m: float = 0.0
	var time_of_flight: float = 0.0
	var striking_velocity: float = 0.0
	var descent_angle: float = 0.0
	var apex_altitude: float = 0.0


var gun_id: String = ""
var shell_id: String = ""
var entries: Array[Entry] = []

var _max_range: float = 0.0
var _max_range_index: int = 0


func maximum_range() -> float:
	return _max_range


func minimum_range() -> float:
	return entries[0].range_m if not entries.is_empty() else 0.0


## Build the table by solving one trajectory per elevation step.
##
## Only the rising branch is kept for lookups. Beyond the elevation of maximum range
## a higher angle gives a SHORTER range, so a naive search would find the high-angle
## solution and report a plunging shell where a flat one was wanted.
static func build(
	solver: BallisticSolver, gun: GunDef, shell: ShellDef, config: Dictionary
) -> RangeTable:
	var table: RangeTable = RangeTable.new()
	table.gun_id = gun.gun_id
	table.shell_id = shell.shell_id

	var integration: Dictionary = config.get("integration", {}) as Dictionary
	var dt: float = float(integration.get("rangeTableStepSeconds", 0.25))
	var step_rad: float = deg_to_rad(float(integration.get("rangeTableElevationStepDeg", 0.5)))
	var max_seconds: float = float(integration.get("maxFlightSeconds", 400.0))
	var drag_over_mass: float = shell.drag_over_mass()

	var elevation: float = maxf(gun.min_elevation_rad, 0.0)
	while elevation <= gun.max_elevation_rad + 1e-6:
		var flight: BallisticSolver.TrajectoryResult = solver.solve_flight_from_height(
			shell.muzzle_velocity_ms, elevation, drag_over_mass,
			gun.muzzle_height_m, dt, max_seconds)
		if flight.valid:
			var entry: Entry = Entry.new()
			entry.elevation = elevation
			entry.range_m = flight.range_m()
			entry.time_of_flight = flight.time_of_flight
			entry.striking_velocity = flight.striking_velocity()
			entry.descent_angle = flight.descent_angle()
			entry.apex_altitude = flight.apex_altitude
			table.entries.append(entry)
			if entry.range_m > table._max_range:
				table._max_range = entry.range_m
				table._max_range_index = table.entries.size() - 1
		elevation += step_rad

	return table


## Elevation and impact conditions for a target at `target_range`.
##
## Returns an invalid solution when the range is beyond the gun's reach; callers must
## check, because "out of range" is a normal answer in a naval action and not an error.
func solve_for_range(target_range: float) -> FiringSolution:
	var solution: FiringSolution = FiringSolution.new()
	if entries.is_empty():
		return solution
	if target_range > _max_range:
		return solution

	if target_range <= entries[0].range_m:
		# Inside the flattest trajectory the gun has. Report its minimum elevation
		# rather than failing: a target this close is hit by pointing at it.
		_fill(solution, entries[0], target_range)
		return solution

	# Binary search the rising branch.
	var low: int = 0
	var high: int = _max_range_index
	while high - low > 1:
		var mid: int = (low + high) / 2
		if entries[mid].range_m <= target_range:
			low = mid
		else:
			high = mid

	var a: Entry = entries[low]
	var b: Entry = entries[high]
	var span: float = b.range_m - a.range_m
	var t: float = 0.0 if absf(span) < 1e-6 else (target_range - a.range_m) / span

	solution.valid = true
	solution.range_m = target_range
	solution.elevation = lerpf(a.elevation, b.elevation, t)
	solution.time_of_flight = lerpf(a.time_of_flight, b.time_of_flight, t)
	solution.striking_velocity = lerpf(a.striking_velocity, b.striking_velocity, t)
	solution.descent_angle = lerpf(a.descent_angle, b.descent_angle, t)
	solution.apex_altitude = lerpf(a.apex_altitude, b.apex_altitude, t)
	return solution


## How far the fall of shot moves for a radian of elevation, at this range.
##
## The number that decides what a laying error is actually worth, and it is not
## constant: on the flat early part of the trajectory a gun's elevation buys range
## fast, and far out near maximum range it buys almost none. That is why a tenth of a
## degree of director wander throws a shell further off at ten kilometres than at
## twenty-five — the opposite of what a "percentage of range" error would say, and the
## reason this is read off the gun's own table rather than assumed.
func range_gradient(target_range: float) -> float:
	if entries.size() < 2:
		return 0.0
	var index: int = 0
	for i: int in _max_range_index:
		if entries[i].range_m <= target_range:
			index = i
		else:
			break
	var a: Entry = entries[index]
	var b: Entry = entries[mini(index + 1, _max_range_index)]
	var d_elevation: float = b.elevation - a.elevation
	if absf(d_elevation) < 1e-9:
		return 0.0
	return absf((b.range_m - a.range_m) / d_elevation)


func _fill(solution: FiringSolution, entry: Entry, target_range: float) -> void:
	solution.valid = true
	solution.range_m = target_range
	solution.elevation = entry.elevation
	solution.time_of_flight = entry.time_of_flight * (target_range / maxf(entry.range_m, 1.0))
	solution.striking_velocity = entry.striking_velocity
	solution.descent_angle = entry.descent_angle
	solution.apex_altitude = entry.apex_altitude
