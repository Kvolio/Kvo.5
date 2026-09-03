class_name GunnerySystem
extends RefCounted

## Firing: turning a laid, loaded gun into shells in the air.
##
## Dispersion is applied by perturbing the AIM POINT rather than the gun angles,
## because that is how gunnery trials measure it — a salvo lands in a pattern on the
## water, long and thin along the line of fire. Range error always dwarfs deflection
## error, which is why straddles are common and hits are not, and why a ship under
## fire that changes range is so much harder to hit than one that changes bearing.
##
## Every barrel draws its own error. A triple turret puts three shells in the air, and
## they land in three different places.

## Stream name for gunnery draws. Named so that adding a random roll to, say, the fire
## system can never shift where a salvo lands.
const RNG_STREAM: String = "gunnery"


## Fire every mount that is ready, and return the projectiles created.
static func fire_ready_mounts(
	world: SimWorld, shooter: ShipEntity, ready: Array[FireControlSystem.ReadyMount],
	target: ShipEntity
) -> Array[Projectile]:
	var fired: Array[Projectile] = []
	if target == null or not target.is_afloat():
		return fired

	var rng: DeterministicRng = world.rng.stream(RNG_STREAM)
	for entry: FireControlSystem.ReadyMount in ready:
		var turret: Turret = entry.turret
		var solution: FireControlSystem.Solution = entry.solution
		var table: RangeTable = world.armory.range_table(turret.gun.gun_id, turret.selected_shell)

		var muzzle: Vector2 = FireControlSystem.mount_world_position(shooter, turret)
		for _barrel: int in turret.barrels():
			var projectile: Projectile = _fire_one(
				world, shooter, turret, target, solution, table, muzzle, rng)
			if projectile != null:
				fired.append(projectile)

		turret.mark_fired()
		# She has shown herself. At night a gun flash carries well past the horizon,
		# and this is what the detection sweep reads to notice it.
		shooter.firing_seconds_ago = 0.0
		world.events.emit_event(&"salvo_fired", shooter.id, target.id,
			SimEvent.Severity.INFO, {
				"mount": turret.mount.mount_id,
				"battery": String(turret.battery),
				"calibreMm": turret.gun.calibre_m * 1000.0,
				"gun": turret.gun.display_name,
				"shell": turret.selected_shell,
				"barrels": turret.barrels(),
				"rangeM": solution.range_m,
			})
	return fired


static func _fire_one(
	world: SimWorld, shooter: ShipEntity, turret: Turret, target: ShipEntity,
	solution: FireControlSystem.Solution, table: RangeTable, muzzle: Vector2,
	rng: DeterministicRng
) -> Projectile:
	var shell: ShellDef = world.armory.get_shell(turret.selected_shell)
	if shell == null:
		return null

	# Scatter the aim point: along the line of fire for range error, across it for
	# deflection. The ellipse this produces is the salvo pattern.
	var along: Vector2 = Vector2(cos(solution.world_bearing), sin(solution.world_bearing))
	var across: Vector2 = Vector2(-along.y, along.x)
	var range_error: float = rng.next_gaussian() * turret.gun.range_sigma * solution.range_m
	var deflection_error: float = rng.next_gaussian() * turret.gun.deflection_sigma * solution.range_m
	var aim: Vector2 = solution.aim_point + along * range_error + across * deflection_error

	# Re-solve for the scattered point, so the shell really is fired at a slightly
	# wrong range rather than merely drawn landing at one.
	var offset: Vector2 = aim - muzzle
	var scattered: RangeTable.FiringSolution = table.solve_for_range(offset.length())
	if not scattered.valid:
		return null

	var bearing: float = offset.angle()
	var elevation: float = scattered.elevation
	var velocity: Vector3 = Vector3(
		cos(bearing) * cos(elevation), sin(bearing) * cos(elevation), sin(elevation)
	) * shell.muzzle_velocity_ms

	# The shell leaves a moving ship and takes her motion with it. Twenty knots over
	# half a minute of flight is nearly four hundred metres, which is why fire control
	# solves the intercept against RELATIVE motion — the two are the same compensation
	# seen from either end, and leaving out both would have been self-consistent while
	# leaving out one is simply wrong.
	var own: Vector2 = shooter.velocity()
	velocity += Vector3(own.x, own.y, 0.0)

	var origin: Vector3 = Vector3(muzzle.x, muzzle.y, turret.gun.muzzle_height_m)
	return world.spawn_projectile(shell, turret.gun, origin, velocity,
		shooter.id, target.id, shooter.team, turret.battery)
