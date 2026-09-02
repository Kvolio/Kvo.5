extends SimTest

## The RNG underpins every probabilistic outcome in the simulation, so this suite
## pins its exact output. The reference values below were computed independently
## from the algorithm specification, not captured from this implementation — if a
## refactor changes them, every saved replay in existence has silently become
## unreplayable, and that must fail loudly.

const SEED: int = 12345
const EXPECTED_FIRST_FIVE: Array[int] = [642936810, 488989537, 2827329717, 3608621377, 1653553526]
const EXPECTED_INITIAL_STATE: Array[int] = [3283241497, 1479306245, 1928920485, 2011234701]


func suite_name() -> String:
	return "DeterministicRng"


func test_mul32_matches_true_32_bit_product() -> void:
	eq(DeterministicRng.mul32(0xFFFFFFFF, 0x01000193), 4278189677, "FNV prime against all-ones")
	eq(DeterministicRng.mul32(123456789, 2654435761), 2146089093, "arbitrary 32x32 product")
	eq(DeterministicRng.mul32(0, 0x9E3779B9), 0, "zero product")
	eq(DeterministicRng.mul32(1, 0x9E3779B9), 0x9E3779B9, "identity product")


func test_mul32_never_leaves_the_safe_integer_range() -> void:
	# The whole point of the split multiply: a naive (a * b) & MASK would overflow
	# int64 for operands this large before the mask could be applied.
	for a: int in [0xFFFFFFFF, 0x80000000, 0x7FFFFFFF]:
		for b: int in [0xFFFFFFFF, 0x21F0AAAD, 0x735A2D97]:
			var result: int = DeterministicRng.mul32(a, b)
			between(float(result), 0.0, 4294967295.0, "mul32(%d, %d) stays in 32-bit range" % [a, b])


func test_seeding_produces_the_specified_state() -> void:
	var rng: DeterministicRng = DeterministicRng.new(SEED)
	arrays_equal(rng.get_state(), EXPECTED_INITIAL_STATE, "SplitMix32 seeding of xorshift128")


func test_output_sequence_is_pinned() -> void:
	var rng: DeterministicRng = DeterministicRng.new(SEED)
	for i: int in EXPECTED_FIRST_FIVE.size():
		eq(rng.next_u32(), EXPECTED_FIRST_FIVE[i], "xorshift128 output #%d" % i)


func test_same_seed_reproduces_the_same_sequence() -> void:
	var a: DeterministicRng = DeterministicRng.new(9001)
	var b: DeterministicRng = DeterministicRng.new(9001)
	for i: int in 500:
		if a.next_u32() != b.next_u32():
			fail("sequences diverged at draw %d" % i)
			return
	ok(true, "500 draws identical for identical seeds")


func test_different_seeds_diverge_immediately() -> void:
	var a: DeterministicRng = DeterministicRng.new(1)
	var b: DeterministicRng = DeterministicRng.new(2)
	var same: int = 0
	for _i: int in 64:
		if a.next_u32() == b.next_u32():
			same += 1
	lt(float(same), 4.0, "adjacent seeds must not produce near-identical streams")


func test_floats_stay_in_the_half_open_unit_interval() -> void:
	var rng: DeterministicRng = DeterministicRng.new(77)
	var lowest: float = 1.0
	var highest: float = 0.0
	for _i: int in 20000:
		var v: float = rng.next_float()
		if v < 0.0 or v >= 1.0:
			fail("next_float() returned %f, outside [0, 1)" % v)
			return
		lowest = minf(lowest, v)
		highest = maxf(highest, v)
	lt(lowest, 0.01, "distribution reaches the low end")
	gt(highest, 0.99, "distribution reaches the high end")


func test_next_int_respects_its_bound_and_covers_it() -> void:
	var rng: DeterministicRng = DeterministicRng.new(4242)
	var counts: Array[int] = [0, 0, 0, 0, 0]
	for _i: int in 10000:
		var v: int = rng.next_int(5)
		if v < 0 or v >= 5:
			fail("next_int(5) returned %d" % v)
			return
		counts[v] += 1
	for i: int in 5:
		# Uniform expectation is 2000; a rejection-sampling bug shows up as a
		# lopsided bucket long before it reaches these bounds.
		between(float(counts[i]), 1700.0, 2300.0, "bucket %d roughly uniform" % i)


func test_next_int_handles_degenerate_bounds() -> void:
	var rng: DeterministicRng = DeterministicRng.new(5)
	eq(rng.next_int(1), 0, "bound of 1 is always 0")
	eq(rng.next_int(0), 0, "bound of 0 does not hang or error")
	eq(rng.next_int_range(7, 7), 7, "empty range returns its single value")
	between(float(rng.next_int_range(3, 6)), 3.0, 6.0, "inclusive range")


func test_gaussian_is_centred_with_unit_variance() -> void:
	var rng: DeterministicRng = DeterministicRng.new(31337)
	var n: int = 40000
	var sum: float = 0.0
	var sum_sq: float = 0.0
	for _i: int in n:
		var v: float = rng.next_gaussian()
		sum += v
		sum_sq += v * v
	var mean: float = sum / float(n)
	var variance: float = sum_sq / float(n) - mean * mean
	almost(mean, 0.0, 0.03, "Irwin-Hall mean")
	almost(variance, 1.0, 0.05, "Irwin-Hall variance")


func test_state_round_trip_resumes_the_exact_sequence() -> void:
	var rng: DeterministicRng = DeterministicRng.new(555)
	for _i: int in 37:
		rng.next_u32()
	var saved: Array[int] = rng.get_state()
	var expected: Array[int] = []
	for _i: int in 20:
		expected.append(rng.next_u32())

	var restored: DeterministicRng = DeterministicRng.new(0)
	restored.set_state(saved)
	for i: int in 20:
		eq(restored.next_u32(), expected[i], "resumed draw %d" % i)


func test_clone_is_independent() -> void:
	var rng: DeterministicRng = DeterministicRng.new(808)
	var copy: DeterministicRng = rng.clone()
	eq(copy.next_u32(), rng.next_u32(), "clone starts from the same state")
	copy.next_u32()
	ne(copy.get_state(), rng.get_state(), "advancing the clone does not advance the original")


func test_string_hash_is_pinned() -> void:
	# Not String.hash(): that is an engine internal and may change between Godot
	# versions, which would re-seed every named stream and invalidate saved battles.
	eq(DeterministicRng.hash_string("gunnery"), 270130473, "FNV-1a of 'gunnery'")
	eq(DeterministicRng.hash_string("penetration"), 1902449714, "FNV-1a of 'penetration'")
	eq(DeterministicRng.hash_string(""), 0x811C9DC5, "FNV-1a of the empty string is the offset basis")


func test_splitmix32_is_pinned() -> void:
	eq(DeterministicRng.splitmix32(0), 1684164658, "SplitMix32(0)")


func test_all_zero_seed_does_not_collapse_the_generator() -> void:
	var rng: DeterministicRng = DeterministicRng.new(0)
	var nonzero: bool = false
	for _i: int in 16:
		if rng.next_u32() != 0:
			nonzero = true
			break
	ok(nonzero, "xorshift128 must not lock at zero")


func test_unit_circle_samples_are_inside_the_circle() -> void:
	var rng: DeterministicRng = DeterministicRng.new(2024)
	for _i: int in 2000:
		var p: Vector2 = rng.next_in_unit_circle()
		le(p.length(), 1.0000001, "sample lies within the unit circle")


func test_chance_handles_certainties_without_consuming_draws() -> void:
	var rng: DeterministicRng = DeterministicRng.new(11)
	var before: Array[int] = rng.get_state()
	not_ok(rng.chance(0.0), "probability 0 is never true")
	ok(rng.chance(1.0), "probability 1 is always true")
	arrays_equal(rng.get_state(), before, "certain outcomes must not disturb the stream")
