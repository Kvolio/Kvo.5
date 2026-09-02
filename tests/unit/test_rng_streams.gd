extends SimTest

## Named streams exist so that adding a random draw in one system cannot change the
## outcome of another. That property is the whole reason the abstraction is here, so
## it is asserted directly.


func suite_name() -> String:
	return "RngStreams"


func test_streams_are_stable_by_name_not_creation_order() -> void:
	var a: RngStreams = RngStreams.new(4242)
	var first_gunnery: int = a.stream("gunnery").next_u32()
	var first_fire: int = a.stream("fire").next_u32()

	# Same master seed, streams touched in the opposite order.
	var b: RngStreams = RngStreams.new(4242)
	eq(b.stream("fire").next_u32(), first_fire, "fire stream unaffected by access order")
	eq(b.stream("gunnery").next_u32(), first_gunnery, "gunnery stream unaffected by access order")


func test_adding_draws_to_one_stream_does_not_disturb_another() -> void:
	var baseline: RngStreams = RngStreams.new(77)
	var expected: Array[int] = []
	for _i: int in 10:
		expected.append(baseline.stream("gunnery").next_u32())

	# Simulate a later code change that introduces many extra rolls elsewhere.
	var perturbed: RngStreams = RngStreams.new(77)
	for _i: int in 1000:
		perturbed.stream("flooding").next_u32()
	for i: int in 10:
		eq(perturbed.stream("gunnery").next_u32(), expected[i],
			"gunnery draw %d is insulated from the flooding stream" % i)


func test_distinct_names_give_distinct_streams() -> void:
	var streams: RngStreams = RngStreams.new(1)
	var collisions: int = 0
	for _i: int in 32:
		if streams.stream("alpha").next_u32() == streams.stream("beta").next_u32():
			collisions += 1
	lt(float(collisions), 3.0, "differently named streams must not run in lockstep")


func test_distinct_master_seeds_give_distinct_streams() -> void:
	var a: RngStreams = RngStreams.new(100)
	var b: RngStreams = RngStreams.new(101)
	ne(a.stream("gunnery").next_u32(), b.stream("gunnery").next_u32(),
		"the master seed must reach every derived stream")


func test_stream_names_are_sorted_not_insertion_ordered() -> void:
	var streams: RngStreams = RngStreams.new(9)
	streams.stream("zulu")
	streams.stream("alpha")
	streams.stream("mike")
	arrays_equal(streams.stream_names(), ["alpha", "mike", "zulu"],
		"stream_names() must be sorted so serialisation order is history-independent")


func test_serialisation_round_trip_resumes_every_stream() -> void:
	var original: RngStreams = RngStreams.new(2718)
	for _i: int in 25:
		original.stream("gunnery").next_u32()
		original.stream("fire").next_u32()
	var expected_gunnery: int = original.stream("gunnery").next_u32()
	var expected_fire: int = original.stream("fire").next_u32()

	# Re-run to the same point, then save/restore and confirm the next draws match.
	var source: RngStreams = RngStreams.new(2718)
	for _i: int in 25:
		source.stream("gunnery").next_u32()
		source.stream("fire").next_u32()
	var saved: Dictionary = source.serialize()

	var restored: RngStreams = RngStreams.new(0)
	restored.deserialize(saved)
	eq(restored.get_master_seed(), 2718, "master seed survives the round trip")
	eq(restored.stream("gunnery").next_u32(), expected_gunnery, "gunnery resumes mid-sequence")
	eq(restored.stream("fire").next_u32(), expected_fire, "fire resumes mid-sequence")
