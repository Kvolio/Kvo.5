extends SimTest

## Contract tests for the spatial-query abstraction.
##
## Every implementation must satisfy every assertion here, and the equivalence tests at
## the bottom go further: the two must return BYTE-IDENTICAL results over randomised
## workloads. The point of the abstraction is that swapping the implementation cannot
## change a single query result, and therefore cannot change a single battle — an
## acceleration structure that is merely almost right produces a subtly different naval
## action, which is indistinguishable from a correct one until it matters.


func suite_name() -> String:
	return "SpatialIndex contract"


## Every implementation under test.
func _indexes() -> Array[SpatialIndex]:
	return [BruteForceIndex.new(), SpatialHashIndex.new()]


func _populate(index: SpatialIndex) -> void:
	index.insert(3, Vector2(0, 0), 10.0, SpatialIndex.Layer.SHIP)
	index.insert(1, Vector2(100, 0), 10.0, SpatialIndex.Layer.SHIP)
	index.insert(2, Vector2(0, 100), 10.0, SpatialIndex.Layer.TORPEDO)
	index.insert(5, Vector2(1000, 1000), 50.0, SpatialIndex.Layer.ISLAND)
	index.insert(4, Vector2(50, 50), 5.0, SpatialIndex.Layer.PROJECTILE)


func test_results_are_sorted_by_id_regardless_of_insertion_order() -> void:
	for index: SpatialIndex in _indexes():
		_populate(index)
		var hits: PackedInt32Array = index.query_radius(Vector2(50, 50), 200.0)
		arrays_equal(hits, [1, 2, 3, 4],
			"query results must be ascending by id, not insertion or storage order")


func test_radius_query_uses_entity_radius() -> void:
	for index: SpatialIndex in _indexes():
		index.insert(1, Vector2(100, 0), 10.0, SpatialIndex.Layer.SHIP)
		# Query circle of 85 plus entity radius of 10 reaches 95 — just short.
		arrays_equal(index.query_radius(Vector2.ZERO, 85.0), [], "just out of reach")
		# 91 + 10 = 101 — now overlapping.
		arrays_equal(index.query_radius(Vector2.ZERO, 91.0), [1], "entity radius counts")


func test_layer_mask_filters() -> void:
	for index: SpatialIndex in _indexes():
		_populate(index)
		arrays_equal(index.query_radius(Vector2(50, 50), 500.0, SpatialIndex.Layer.SHIP),
			[1, 3], "ships only")
		arrays_equal(index.query_radius(Vector2(50, 50), 500.0, SpatialIndex.Layer.TORPEDO),
			[2], "torpedoes only")
		arrays_equal(
			index.query_radius(Vector2(50, 50), 500.0,
				SpatialIndex.Layer.SHIP | SpatialIndex.Layer.PROJECTILE),
			[1, 3, 4], "combined mask")


func test_aabb_query() -> void:
	for index: SpatialIndex in _indexes():
		_populate(index)
		arrays_equal(index.query_aabb(Rect2(-20, -20, 140, 40)), [1, 3],
			"rectangle spanning the two ships on the x axis")
		arrays_equal(index.query_aabb(Rect2(5000, 5000, 10, 10)), [], "empty region")


func test_segment_query_finds_entities_the_line_passes_near() -> void:
	for index: SpatialIndex in _indexes():
		index.insert(1, Vector2(50, 5), 10.0, SpatialIndex.Layer.SHIP)
		index.insert(2, Vector2(50, 40), 10.0, SpatialIndex.Layer.SHIP)
		# The line y=0 passes 5 from entity 1's edge (radius 10) and 30 from
		# entity 2's edge (40 away, radius 10).
		arrays_equal(index.query_segment(Vector2(0, 0), Vector2(100, 0)), [1],
			"only the entity the segment actually crosses")
		arrays_equal(index.query_segment(Vector2(0, 0), Vector2(100, 0), 25.0), [1],
			"25 of padding still falls 5 short of entity 2")
		arrays_equal(index.query_segment(Vector2(0, 0), Vector2(100, 0), 35.0), [1, 2],
			"35 of padding reaches entity 2")


func test_segment_query_does_not_extend_past_the_endpoints() -> void:
	for index: SpatialIndex in _indexes():
		index.insert(1, Vector2(500, 0), 10.0, SpatialIndex.Layer.SHIP)
		arrays_equal(index.query_segment(Vector2(0, 0), Vector2(100, 0)), [],
			"a segment is not an infinite ray — line of sight must stop where it stops")


func test_degenerate_segment_behaves_as_a_point_query() -> void:
	for index: SpatialIndex in _indexes():
		index.insert(1, Vector2(0, 0), 10.0, SpatialIndex.Layer.SHIP)
		arrays_equal(index.query_segment(Vector2(5, 0), Vector2(5, 0)), [1],
			"zero-length segment must not divide by zero")


func test_update_moves_an_entity() -> void:
	for index: SpatialIndex in _indexes():
		index.insert(1, Vector2(0, 0), 10.0, SpatialIndex.Layer.SHIP)
		arrays_equal(index.query_radius(Vector2(900, 0), 50.0), [], "not there yet")
		index.update(1, Vector2(900, 0), 10.0)
		arrays_equal(index.query_radius(Vector2(900, 0), 50.0), [1], "moved")
		arrays_equal(index.query_radius(Vector2(0, 0), 50.0), [], "and left the old cell")


func test_remove_and_size() -> void:
	for index: SpatialIndex in _indexes():
		_populate(index)
		eq(index.size(), 5, "populated")
		ok(index.has(3), "id 3 present")
		index.remove(3)
		not_ok(index.has(3), "id 3 removed")
		eq(index.size(), 4, "size decremented")
		arrays_equal(index.query_radius(Vector2(50, 50), 500.0), [1, 2, 4],
			"removal must not disturb the ordering of the survivors")
		index.remove(999)
		eq(index.size(), 4, "removing an absent id is a no-op")
		index.clear()
		eq(index.size(), 0, "cleared")


func test_swap_removal_keeps_every_remaining_entity_findable() -> void:
	# Swap-removal reorders internal storage. If any query leaked that order, this
	# is where it would show up.
	for index: SpatialIndex in _indexes():
		for i: int in range(1, 21):
			index.insert(i, Vector2(float(i) * 10.0, 0.0), 1.0, SpatialIndex.Layer.SHIP)
		for i: int in [5, 1, 20, 13]:
			index.remove(i)
		var expected: Array[int] = []
		for i: int in range(1, 21):
			if not [5, 1, 20, 13].has(i):
				expected.append(i)
		arrays_equal(index.query_radius(Vector2(100, 0), 10000.0), expected,
			"all survivors present, still ascending")


func test_reinserting_an_existing_id_updates_rather_than_duplicates() -> void:
	for index: SpatialIndex in _indexes():
		index.insert(1, Vector2(0, 0), 10.0, SpatialIndex.Layer.SHIP)
		index.insert(1, Vector2(500, 0), 10.0, SpatialIndex.Layer.SHIP)
		eq(index.size(), 1, "no duplicate slot")
		arrays_equal(index.query_radius(Vector2(500, 0), 20.0), [1], "position updated")


func test_point_to_segment_distance_helper() -> void:
	almost(SpatialIndex.distance_point_to_segment(Vector2(50, 10), Vector2(0, 0), Vector2(100, 0)),
		10.0, 0.0001, "perpendicular distance mid-segment")
	almost(SpatialIndex.distance_point_to_segment(Vector2(-30, 0), Vector2(0, 0), Vector2(100, 0)),
		30.0, 0.0001, "clamped to the start point")
	almost(SpatialIndex.distance_point_to_segment(Vector2(130, 0), Vector2(0, 0), Vector2(100, 0)),
		30.0, 0.0001, "clamped to the end point")
	almost(SpatialIndex.distance_point_to_segment(Vector2(3, 4), Vector2(0, 0), Vector2(0, 0)),
		5.0, 0.0001, "degenerate segment falls back to point distance")


# -- equivalence ---------------------------------------------------------------

## Ids, positions and radii spread across a battlefield-sized area, including negative
## coordinates: a battlefield is centred on the origin, so half of it is negative, and a
## grid that packed its cell keys naively would fold the two halves together.
func _randomised(index: SpatialIndex, rng: DeterministicRng, count: int) -> void:
	for i: int in count:
		var layer: int = [SpatialIndex.Layer.SHIP, SpatialIndex.Layer.PROJECTILE,
			SpatialIndex.Layer.TORPEDO, SpatialIndex.Layer.AIRCRAFT][rng.next_int(4)]
		index.insert(i + 1,
			Vector2(rng.next_range(-30000.0, 30000.0), rng.next_range(-30000.0, 30000.0)),
			rng.next_range(1.0, 300.0), layer)


func test_both_indexes_answer_every_radius_query_identically() -> void:
	var brute: SpatialIndex = BruteForceIndex.new()
	var hashed: SpatialIndex = SpatialHashIndex.new()
	_randomised(brute, DeterministicRng.new(4242), 400)
	_randomised(hashed, DeterministicRng.new(4242), 400)

	var rng: DeterministicRng = DeterministicRng.new(77)
	for _i: int in 120:
		var centre: Vector2 = Vector2(
			rng.next_range(-32000.0, 32000.0), rng.next_range(-32000.0, 32000.0))
		var radius: float = rng.next_range(50.0, 8000.0)
		var mask: int = [SpatialIndex.LAYER_ALL, SpatialIndex.Layer.SHIP,
			SpatialIndex.Layer.SHIP | SpatialIndex.Layer.TORPEDO][rng.next_int(3)]
		arrays_equal(hashed.query_radius(centre, radius, mask),
			brute.query_radius(centre, radius, mask),
			"radius query at %s r=%.0f mask=%d must agree" % [centre, radius, mask])


func test_both_indexes_answer_every_segment_query_identically() -> void:
	# The one the projectile broadphase uses on every shell on every tick, and the one
	# where a disagreement would silently lose hits rather than cost time.
	var brute: SpatialIndex = BruteForceIndex.new()
	var hashed: SpatialIndex = SpatialHashIndex.new()
	_randomised(brute, DeterministicRng.new(99), 300)
	_randomised(hashed, DeterministicRng.new(99), 300)

	var rng: DeterministicRng = DeterministicRng.new(1234)
	for _i: int in 120:
		var a: Vector2 = Vector2(
			rng.next_range(-30000.0, 30000.0), rng.next_range(-30000.0, 30000.0))
		var b: Vector2 = a + Vector2(rng.next_range(-4000.0, 4000.0),
			rng.next_range(-4000.0, 4000.0))
		arrays_equal(hashed.query_segment(a, b, 0.0, SpatialIndex.Layer.SHIP),
			brute.query_segment(a, b, 0.0, SpatialIndex.Layer.SHIP),
			"segment query %s -> %s must agree" % [a, b])


func test_both_indexes_agree_after_things_move_and_leave() -> void:
	# Entities are updated every tick and removed when they are spent, so the grid's
	# bookkeeping is exercised far harder than its queries.
	var brute: SpatialIndex = BruteForceIndex.new()
	var hashed: SpatialIndex = SpatialHashIndex.new()
	_randomised(brute, DeterministicRng.new(7), 200)
	_randomised(hashed, DeterministicRng.new(7), 200)

	var rng: DeterministicRng = DeterministicRng.new(31)
	for step: int in 300:
		var id: int = rng.next_int(200) + 1
		if step % 7 == 0:
			brute.remove(id)
			hashed.remove(id)
		else:
			var to: Vector2 = Vector2(
				rng.next_range(-30000.0, 30000.0), rng.next_range(-30000.0, 30000.0))
			var radius: float = rng.next_range(1.0, 300.0)
			brute.update(id, to, radius)
			hashed.update(id, to, radius)
	eq(hashed.size(), brute.size(), "the same entities should remain")
	arrays_equal(hashed.query_radius(Vector2.ZERO, 60000.0),
		brute.query_radius(Vector2.ZERO, 60000.0),
		"and a sweep of the whole battlefield should return the same list")


func test_a_whole_battle_is_the_same_battle_with_either_index() -> void:
	# The assertion that actually matters. Two identical actions, one fought with each
	# index, must end bit for bit the same — because if they do not, the index is a
	# balance change dressed as an optimisation.
	var checksums: Array[int] = []
	for use_hash: bool in [false, true]:
		var world: SimWorld = SimWorld.create(20260907, TestShips.config())
		if use_hash:
			world.spatial = SpatialHashIndex.new()
		world.set_armory(TestWeapons.armory())
		var a: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
		var b: ShipEntity = world.add_ship(
			TestShips.iowa(), Vector2(0.0, 16000.0), PI, 1)
		a.target_id = b.id
		b.target_id = a.id
		MovementSystem.set_steady_speed(a, SimUnits.knots_to_ms(22.0))
		MovementSystem.set_steady_speed(b, SimUnits.knots_to_ms(22.0))
		world.step_many(60 * 150)
		checksums.append(world.checksum())
	eq(checksums[1], checksums[0],
		"the same battle, whichever index found the targets")
