class_name TorpedoSystem
extends RefCounted

## Torpedoes running, and what happens when one arrives.
##
## Two things here are worth more than they look.
##
## A torpedo runs at a SET DEPTH. If that depth is greater than the target's draft it
## passes harmlessly underneath — which happened often enough in the real war to be
## worth modelling, and which is why a destroyer is a much harder torpedo target than
## a battleship quite apart from being smaller.
##
## And a torpedo is aimed at where a ship WILL be if she holds her course. Nothing
## models evasion; a ship that turns when the tracks are sighted simply is not there
## when they arrive.

const RNG_STREAM: String = "torpedo"


static func step(world: SimWorld, dt: float) -> void:
	if world.torpedoes.is_empty():
		return
	var survivors: Array[Torpedo] = []
	for torpedo: Torpedo in world.torpedoes:
		if not torpedo.active:
			continue
		if _advance(world, torpedo, dt):
			survivors.append(torpedo)
		else:
			world.retire_torpedo(torpedo)
	world.torpedoes = survivors


## Returns false when the torpedo is finished with.
static func _advance(world: SimWorld, torpedo: Torpedo, dt: float) -> bool:
	var from: Vector2 = torpedo.position
	var to: Vector2 = from + torpedo.velocity() * dt
	torpedo.distance_run += from.distance_to(to)

	if torpedo.is_armed() and _check_ships(world, torpedo, from, to):
		return false

	if torpedo.is_spent():
		world.events.emit_event(&"torpedo_spent", torpedo.shooter_id, torpedo.target_id,
			SimEvent.Severity.INFO, {"position": Serializer.vec2_to_array(to)})
		return false

	torpedo.position = to
	return true


static func _check_ships(world: SimWorld, torpedo: Torpedo, from: Vector2, to: Vector2) -> bool:
	var candidates: PackedInt32Array = world.spatial.query_segment(
		from, to, 0.0, SpatialIndex.Layer.SHIP)
	for ship_id: int in candidates:
		if ship_id == torpedo.shooter_id:
			continue
		var ship: ShipEntity = world.get_ship(ship_id)
		if ship == null or not ship.is_afloat():
			continue

		# Set too deep, and it runs under her. A shallow-draft destroyer is a genuinely
		# awkward torpedo target for exactly this reason.
		if ship.spec.hydrostatic_draft() < torpedo.run_depth_m:
			continue

		var impact: Vector2 = _hull_entry(ship, from, to)
		if impact == Vector2.INF:
			continue

		var rng: DeterministicRng = world.rng.stream(RNG_STREAM)
		var reliability: float = float((world.torpedo_config.get("running", {}) as Dictionary)
			.get("detonationProbability", 0.85))
		if not rng.chance(reliability):
			world.events.emit_event(&"torpedo_dud", torpedo.shooter_id, ship.id,
				SimEvent.Severity.NOTABLE, {
					"torpedo": torpedo.definition.display_name,
					"position": Serializer.vec2_to_array(impact),
				})
			return true

		var report: HitReport = TorpedoDamageModel.resolve(
			torpedo.definition,
			Vector3(impact.x, impact.y, -torpedo.run_depth_m),
			Vector3(cos(torpedo.heading), sin(torpedo.heading), 0.0),
			ship, world.structure_for(ship), ship.structure_state,
			world.torpedo_config, world.damage_config, rng)
		report.shooter_id = torpedo.shooter_id
		report.range_m = torpedo.distance_run
		world.record_torpedo_hit(report, ship)
		return true
	return false


## Where the run first crosses the ship's hull outline, or Vector2.INF if it misses.
##
## Tested against the real outline rather than a bounding circle, so a torpedo aimed
## at the fine bow of a destroyer can genuinely miss ahead of her.
static func _hull_entry(ship: ShipEntity, from: Vector2, to: Vector2) -> Vector2:
	var outline: PackedVector2Array = ship.hull().outline_world(ship.position, ship.heading)
	var count: int = outline.size()
	var nearest: Vector2 = Vector2.INF
	var nearest_distance: float = INF

	for i: int in count:
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % count]
		var crossing: Variant = Geometry2D.segment_intersects_segment(from, to, a, b)
		if crossing == null:
			continue
		var point: Vector2 = crossing as Vector2
		var distance: float = from.distance_to(point)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = point
	return nearest
