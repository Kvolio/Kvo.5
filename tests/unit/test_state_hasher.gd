extends SimTest

## The per-tick checksum is how a divergence is localised to the tick that caused
## it. It has to be sensitive to small changes and insensitive to nothing.


func suite_name() -> String:
	return "StateHasher"


func test_identical_input_gives_identical_hash() -> void:
	var a: StateHasher = StateHasher.new()
	var b: StateHasher = StateHasher.new()
	for h: StateHasher in [a, b]:
		h.write_int(42)
		h.write_float(3.14159)
		h.write_string("Bismarck")
		h.write_vec2(Vector2(100.5, -200.25))
	eq(a.value(), b.value(), "same writes, same hash")


func test_a_one_ulp_float_difference_is_detected() -> void:
	# This is the entire purpose: catch drift too small to see in a printout.
	var a: StateHasher = StateHasher.new()
	var b: StateHasher = StateHasher.new()
	a.write_float(1.0)
	b.write_float(1.0000000000000002)
	ne(a.value(), b.value(), "the smallest representable difference must change the hash")


func test_field_order_matters() -> void:
	var a: StateHasher = StateHasher.new()
	a.write_int(1)
	a.write_int(2)
	var b: StateHasher = StateHasher.new()
	b.write_int(2)
	b.write_int(1)
	ne(a.value(), b.value(), "hashing is order-sensitive")


func test_negative_zero_is_normalised() -> void:
	# -0.0 and 0.0 compare equal and are not a real divergence, but their bit
	# patterns differ. Normalising avoids a permanent false positive.
	var a: StateHasher = StateHasher.new()
	var b: StateHasher = StateHasher.new()
	a.write_float(0.0)
	b.write_float(-0.0)
	eq(a.value(), b.value(), "-0.0 must not read as a divergence")


func test_type_confusion_is_detected() -> void:
	var a: StateHasher = StateHasher.new()
	a.write_int(1)
	var b: StateHasher = StateHasher.new()
	b.write_float(1.0)
	ne(a.value(), b.value(), "an integer 1 and a float 1.0 are different state")


func test_bool_and_reset() -> void:
	var h: StateHasher = StateHasher.new()
	h.write_bool(true)
	var with_true: int = h.value()
	h.reset()
	h.write_bool(false)
	ne(h.value(), with_true, "true and false hash differently")
	h.reset()
	eq(h.value(), StateHasher.FNV_OFFSET_32, "reset returns to the offset basis")


func test_hash_stays_in_32_bit_range() -> void:
	var h: StateHasher = StateHasher.new()
	for i: int in 1000:
		h.write_int(i)
		h.write_float(float(i) * 1.37)
	between(float(h.value()), 0.0, 4294967295.0, "hash remains an unsigned 32-bit value")
	eq(h.to_hex().length(), 8, "hex form is eight digits")
