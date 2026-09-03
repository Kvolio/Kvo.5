class_name TorpedoFireControl
extends RefCounted

## Aiming torpedoes.
##
## Unlike gunnery, this has a closed-form answer: a torpedo runs in a straight line at
## constant speed, so the intercept is a quadratic. Solving it exactly rather than
## iterating is not just cheaper, it makes the failure case meaningful — when the
## quadratic has no positive root, the target is simply outrunning the torpedo, and
## that is a real tactical fact rather than a convergence problem.

## One torpedo firing solution.
class Solution extends RefCounted:
	var valid: bool = false
	var reason: String = ""
	var bearing: float = 0.0            ## world frame
	var relative_bearing: float = 0.0   ## relative to the firing ship's bow
	var aim_point: Vector2 = Vector2.ZERO
	var run_time: float = 0.0
	var run_distance: float = 0.0
	var speed_ms: float = 0.0
	var bears: bool = false


## Where to point a bank of tubes to intercept a ship holding her course.
static func solve(shooter: ShipEntity, launcher: TorpedoLauncher, target: ShipEntity,
		torpedo: TorpedoDef) -> Solution:
	var solution: Solution = Solution.new()
	if torpedo == null or not launcher.is_operational():
		solution.reason = "no tubes"
		return solution

	var local: Vector2 = launcher.mount.local_position(shooter.spec.length_m, shooter.spec.beam_m)
	var origin: Vector2 = shooter.position + local.rotated(shooter.heading)
	var offset: Vector2 = target.position - origin
	var straight_range: float = offset.length()

	# Pick the fastest setting that still reaches. This is the choice a torpedo
	# officer actually makes: speed gives the target less time to comb the tracks,
	# range lets you shoot from outside her guns.
	var setting: TorpedoDef.Setting = torpedo.setting_for_range(straight_range)
	if setting == null:
		solution.reason = "no usable setting"
		return solution
	solution.speed_ms = setting.speed_ms

	# |offset + target_velocity * t| = speed * t
	var velocity: Vector2 = target.velocity()
	var a: float = velocity.length_squared() - setting.speed_ms * setting.speed_ms
	var b: float = 2.0 * offset.dot(velocity)
	var c: float = offset.length_squared()

	var time: float = -1.0
	if absf(a) < 1e-6:
		# Target running at exactly torpedo speed: the quadratic degenerates.
		if absf(b) > 1e-6:
			time = -c / b
	else:
		var discriminant: float = b * b - 4.0 * a * c
		if discriminant < 0.0:
			solution.reason = "target is outrunning the torpedo"
			return solution
		var root: float = sqrt(discriminant)
		# Smallest positive root: the earliest interception.
		for candidate: float in [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]:
			if candidate > 0.0 and (time < 0.0 or candidate < time):
				time = candidate

	if time <= 0.0:
		solution.reason = "no interception possible on this course"
		return solution

	solution.run_time = time
	solution.run_distance = setting.speed_ms * time
	if solution.run_distance > setting.range_m:
		solution.reason = "interception lies beyond the torpedo's run"
		return solution

	solution.aim_point = target.position + velocity * time
	solution.bearing = (solution.aim_point - origin).angle()
	solution.relative_bearing = SimUnits.angle_delta(shooter.heading, solution.bearing)
	solution.bears = launcher.mount.can_bear(solution.relative_bearing)
	solution.valid = true
	if not solution.bears:
		solution.reason = "target outside the tubes' arc"
	return solution


## Train every bank on the target and report those ready to fire.
static func direct(shooter: ShipEntity, target: ShipEntity, torpedo: TorpedoDef,
		train_rate: float, dt: float) -> Array[TorpedoLauncher]:
	var ready: Array[TorpedoLauncher] = []
	for launcher: TorpedoLauncher in shooter.torpedo_launchers:
		if target == null or not target.is_afloat():
			launcher.stand_down()
			launcher.step(dt, train_rate)
			continue
		var solution: Solution = solve(shooter, launcher, target, torpedo)
		if solution.valid:
			launcher.order_train(solution.relative_bearing)
		else:
			launcher.stand_down()
		launcher.step(dt, train_rate)
		if (solution.valid and solution.bears and launcher.can_fire()
				and absf(SimUnits.angle_delta(launcher.bearing, solution.relative_bearing))
					< deg_to_rad(3.0)):
			ready.append(launcher)
	return ready
