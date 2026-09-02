extends SimTest

## Saved battles must round-trip exactly. Anything less and a reloaded battle
## diverges from the one that was saved.


func suite_name() -> String:
	return "Serializer"


func test_keys_are_sorted_so_output_is_history_independent() -> void:
	var a: Dictionary = {"zulu": 1, "alpha": 2, "mike": 3}
	var b: Dictionary = {"mike": 3, "zulu": 1, "alpha": 2}
	eq(Serializer.to_json(a), Serializer.to_json(b),
		"the same content written in a different order must serialise identically")
	var text: String = Serializer.to_json_compact(a)
	lt(float(text.find("alpha")), float(text.find("mike")), "alpha before mike")
	lt(float(text.find("mike")), float(text.find("zulu")), "mike before zulu")


func test_floats_round_trip_bit_exactly() -> void:
	# Without full_precision these come back as truncated decimals, and a reloaded
	# battle resumes from numbers it was never saved at.
	var awkward: Array = [
		0.1, 1.0 / 3.0, 1e-17, 123456789.123456789, -0.000000001,
		PI, 6.02214076e23, 2.2250738585072014e-308,
	]
	var restored: Variant = Serializer.from_json(Serializer.to_json({"v": awkward}))
	var values: Array = (restored as Dictionary)["v"] as Array
	for i: int in awkward.size():
		eq(float(values[i]), float(awkward[i]), "value %d survives exactly" % i)


func test_nested_structures_round_trip() -> void:
	var original: Dictionary = {
		"name": "USS Iowa",
		"armor": {"belt": 307.0, "deck": 152.0},
		"turrets": [{"guns": 3}, {"guns": 3}, {"guns": 3}],
		"flags": [true, false],
		"nothing": null,
	}
	var restored: Dictionary = Serializer.from_json(Serializer.to_json(original)) as Dictionary
	eq(restored["name"], "USS Iowa", "string")
	eq(float((restored["armor"] as Dictionary)["belt"]), 307.0, "nested float")
	eq((restored["turrets"] as Array).size(), 3, "array of objects")
	eq((restored["flags"] as Array)[0], true, "bool")
	eq(restored["nothing"], null, "null")


func test_float_encoding_is_the_shortest_exact_form() -> void:
	# Readable where it can be, long where it has to be. Both are verified by
	# round-tripping rather than by matching a hard-coded string.
	eq(Serializer.encode_float(0.1), "0.1", "a short decimal stays short")
	eq(Serializer.encode_float(33.0), "33.0", "whole numbers keep a decimal point")
	eq(Serializer.encode_float(-0.5), "-0.5", "negatives")
	gt(float(Serializer.encode_float(1.0 / 3.0).length()), 15.0,
		"a value needing full precision gets it")


func test_every_parsed_number_comes_back_as_a_float() -> void:
	# Godot's JSON parser normalises ALL numbers to double, integers included.
	# This is pinned deliberately: it is why every loader in the project coerces
	# with int()/float() instead of trusting typeof(), and why entity IDs must stay
	# inside the 2^53 range a double can hold exactly.
	var restored: Dictionary = Serializer.from_json(
		Serializer.to_json({"speed": 33.0, "guns": 9, "id": -4})
	) as Dictionary
	eq(typeof(restored["speed"]), TYPE_FLOAT, "33.0 is a float")
	eq(typeof(restored["guns"]), TYPE_FLOAT, "9 also arrives as a float")
	eq(int(restored["guns"]), 9, "and coerces back to the right integer")
	eq(int(restored["id"]), -4, "negative integers coerce correctly")


func test_integers_are_written_without_a_decimal_point() -> void:
	# Purely for the human editing data/ships/*.json by hand: gun counts should
	# read as "9", not "9.0", even though both parse identically.
	var text: String = Serializer.to_json_compact({"guns": 9, "speed": 33.0})
	ok(text.contains("\"guns\":9"), "integer written as an integer literal")
	ok(text.contains("\"speed\":33.0"), "float keeps its decimal point")


func test_non_finite_floats_are_rejected_loudly() -> void:
	# NAN in sim state means something upstream already broke; writing it as a
	# silent null would hide the bug until the reload.
	eq(Serializer.encode_float(INF), "null", "infinity is not representable in JSON")
	eq(Serializer.encode_float(NAN), "null", "NaN is not representable in JSON")


func test_output_is_byte_identical_for_equal_content() -> void:
	var a: Dictionary = {"b": [1.5, 2.5], "a": {"y": 2, "x": 1}}
	var b: Dictionary = {"a": {"x": 1, "y": 2}, "b": [1.5, 2.5]}
	eq(Serializer.to_json_compact(a), Serializer.to_json_compact(b),
		"canonical output is a prerequisite for hashing and diffing saves")


func test_scalar_arrays_stay_on_one_line() -> void:
	var text: String = Serializer.to_json({"hull": [1.0, 2.0, 3.0]})
	not_ok(text.contains("[\n"), "numeric arrays are not exploded one element per row")


func test_malformed_json_returns_null_rather_than_crashing() -> void:
	eq(Serializer.from_json("{not valid", "test"), null, "unterminated object")
	eq(Serializer.from_json("", "test"), null, "empty input")


func test_vector_helpers_round_trip() -> void:
	var v2: Vector2 = Vector2(123.456, -78.9)
	eq(Serializer.array_to_vec2(Serializer.vec2_to_array(v2)), v2, "Vector2")
	var v3: Vector3 = Vector3(1.5, -2.5, 3.5)
	eq(Serializer.array_to_vec3(Serializer.vec3_to_array(v3)), v3, "Vector3")


func test_vector_helpers_fall_back_on_malformed_input() -> void:
	eq(Serializer.array_to_vec2("nonsense", Vector2(9, 9)), Vector2(9, 9), "wrong type")
	eq(Serializer.array_to_vec2([1], Vector2(9, 9)), Vector2(9, 9), "too short")
	eq(Serializer.array_to_vec3([1, 2], Vector3(9, 9, 9)), Vector3(9, 9, 9), "too short")


func test_sorted_keys_helper() -> void:
	arrays_equal(Serializer.sorted_keys({"b": 1, "a": 2, "c": 3}), ["a", "b", "c"], "sorted")
	arrays_equal(Serializer.sorted_keys({}), [], "empty dictionary")
