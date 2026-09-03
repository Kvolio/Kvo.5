class_name ProjectileSystem
extends RefCounted

## Shells in flight: integrating them, and finding what they hit.
##
## Hit detection is a SWEPT test, not a point test. At 500 m/s a shell covers eight
## metres in a tick, which is comfortably more than a destroyer's beam — a point test
## would let shells pass straight through ships between samples, and would do it more
## often the faster and closer the shot. So each tick's movement is treated as the
## segment it is, and the trajectory tracer resolves the segment against the ship.
##
## The tracer is also the hit test. There is no separate "did it hit" pass that could
## disagree with the "what did it hit" pass: if the traced path enters the hull within
## this tick's step, that is a hit, and the report explaining it already exists.

## A shell still in the air after this long has been fired at nothing.
const MAX_FLIGHT_SECONDS: float = 180.0


static func step(world: SimWorld, dt: float) -> void:
	var solver: BallisticSolver = world.armory.solver()
	var survivors: Array[Projectile] = []

	for projectile: Projectile in world.projectiles:
		if not projectile.active:
			continue
		if _advance(world, projectile, solver, dt):
			survivors.append(projectile)
		else:
			world.retire_projectile(projectile)
	world.projectiles = survivors


## Returns false when the projectile is finished with.
static func _advance(world: SimWorld, projectile: Projectile,
		solver: BallisticSolver, dt: float) -> bool:
	var from: Vector3 = projectile.position
	var stepped: Array = solver.step(projectile.position, projectile.velocity,
		projectile.drag_over_mass, dt)
	var to: Vector3 = stepped[0]
	projectile.time_alive += dt

	var hit: bool = _check_ships(world, projectile, from, to)
	if hit:
		return false

	# Reaching the water. Interpolating to the crossing puts the splash where the
	# shell actually landed rather than up to eight metres past it, which matters
	# when the player is judging a straddle by eye.
	if to.z <= 0.0 and from.z > 0.0:
		var span: float = from.z - to.z
		var t: float = 0.0 if span <= 0.0 else from.z / span
		var splash: Vector3 = from.lerp(to, t)
		world.report_fall_of_shot(projectile, Vector2(splash.x, splash.y))
		world.events.emit_event(&"shell_splash", projectile.shooter_id, projectile.target_id,
			SimEvent.Severity.INFO, {
				"position": Serializer.vec2_to_array(Vector2(splash.x, splash.y)),
				"calibreMm": projectile.shell.diameter_m * 1000.0,
			})
		return false

	if projectile.time_alive > MAX_FLIGHT_SECONDS:
		return false

	projectile.position = to
	projectile.velocity = stepped[1]
	return true


## Trace against every ship whose bounding volume this step's segment crosses.
static func _check_ships(world: SimWorld, projectile: Projectile,
		from: Vector3, to: Vector3) -> bool:
	var step_length: float = from.distance_to(to)
	if step_length <= 0.0:
		return false

	var ground_from: Vector2 = Vector2(from.x, from.y)
	var ground_to: Vector2 = Vector2(to.x, to.y)
	var candidates: PackedInt32Array = world.spatial.query_segment(
		ground_from, ground_to, 0.0, SpatialIndex.Layer.SHIP)

	for ship_id: int in candidates:
		if ship_id == projectile.shooter_id:
			continue  # a shell cannot hit the gun that fired it
		var ship: ShipEntity = world.get_ship(ship_id)
		if ship == null or not ship.is_afloat():
			continue
		var structure: ShipStructureTemplate = world.structure_for(ship)
		if structure == null:
			continue
		# One slab test against the hull's bounding box before paying for a full
		# trace. A shell crossing a battleship's 270 m bounding circle spends some
		# thirty ticks inside it and only enters the hull on one of them; without this
		# every one of those ticks would cost several hundred ray tests.
		if not _may_enter_this_step(from, projectile.velocity, ship, structure, step_length):
			continue

		var report: HitReport = TrajectoryTracer.trace(
			projectile.shell, projectile.penetration_k, from, projectile.velocity,
			ship, structure, world.materials, world.penetration_model,
			world.rng.stream("penetration"))

		# The tracer follows an infinite ray, so a reported entry beyond this tick's
		# step is something the shell has not reached yet.
		if report.interactions.is_empty() or report.entry_distance_m > step_length:
			continue

		report.projectile_id = projectile.id
		report.shooter_id = projectile.shooter_id
		report.range_m = projectile.travelled_m()
		report.time_of_flight = projectile.time_alive
		world.record_hit(report, ship)
		return true

	return false


## Could this step's segment put the shell inside the hull's bounding box?
##
## One slab test standing in front of a full trace. A shell crossing a battleship's
## 270 m bounding circle spends some thirty ticks inside it and enters the hull on at
## most one of them; without this cheap rejection, every one of those ticks would pay
## for several hundred ray tests against faces and compartments it never reaches.
static func _may_enter_this_step(from: Vector3, velocity: Vector3, ship: ShipEntity,
		structure: ShipStructureTemplate, step_length: float) -> bool:
	if structure.bounds == null:
		return true
	var basis: Basis = TrajectoryTracer.ship_basis(ship.heading, ship.list_angle, ship.trim_angle)
	var inverse: Basis = basis.transposed()
	var origin: Vector3 = inverse * (from - Vector3(ship.position.x, ship.position.y, 0.0))
	var direction: Vector3 = (inverse * velocity).normalized()
	var span: Array = GeometryPrimitives.ray_volume(origin, direction, structure.bounds)
	if span.is_empty():
		return false
	# A negative entry distance means the shell is already inside the box.
	return float(span[0]) <= step_length
