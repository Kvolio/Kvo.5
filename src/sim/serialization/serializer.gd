class_name Serializer
extends RefCounted

## Canonical JSON encoding for saved ships, scenarios, battles and replays.
##
## Godot's own `JSON.stringify()` is not used for writing, for two reasons found by
## measurement rather than assumption:
##
##   1. `full_precision = true` still emits only ~15 significant digits in Godot
##      4.4, so 1.0/3.0 does NOT survive a round trip. A battle reloaded from such a
##      file resumes from numbers it was never saved at, and diverges from the run
##      that produced it. `String.num(v, 17)` does round-trip exactly, and is what
##      this encoder uses.
##   2. Key order follows Dictionary insertion order, so the same state written
##      twice can produce different bytes — which makes files undiffable and any
##      hash-of-the-JSON meaningless.
##
## Reading still uses Godot's parser: parsing is correctly rounded and is not where
## the precision was being lost. Note one parser behaviour the whole data layer is
## built around — it returns EVERY number as a double, integers included. Loaders
## must therefore coerce with int()/float() rather than switch on typeof(), and any
## integer that has to survive a round trip must stay inside the 2^53 a double holds
## exactly (entity IDs and tick counts are nowhere near that).
##
## Output is canonical: sorted keys, shortest exactly-round-tripping float form,
## floats always carrying a decimal point so they never reparse as integers.

const INDENT: String = "  "

## Decimal places tried, in order. The first that round-trips exactly wins, so
## ordinary values stay readable ("0.1", not "0.10000000000000001") while awkward
## ones get the digits they need.
const PRECISION_LADDER: Array = [6, 10, 14, 17]


static func to_json(data: Variant) -> String:
	return _write(data, INDENT, 0)


static func to_json_compact(data: Variant) -> String:
	return _write(data, "", 0)


## Parse JSON text. Returns `null` and pushes an error on malformed input; callers
## decide whether that is fatal.
static func from_json(text: String, context: String = "<json>") -> Variant:
	var json: JSON = JSON.new()
	var err: Error = json.parse(text)
	if err != OK:
		push_error("%s: JSON parse error at line %d: %s" % [
			context, json.get_error_line(), json.get_error_message()
		])
		return null
	return json.data


## Shortest decimal string that parses back to exactly this double.
static func encode_float(value: float) -> String:
	if is_nan(value) or is_inf(value):
		# Not representable in JSON, and in a physics simulation it means something
		# upstream has already gone wrong. Fail loudly rather than write a value
		# that will silently reload as null.
		push_error("Serializer: refusing to encode non-finite float (%s)" % str(value))
		return "null"
	for decimals: int in PRECISION_LADDER:
		var candidate: String = _tidy_float(String.num(value, decimals))
		if candidate.to_float() == value:
			return candidate
	return _tidy_float(String.num(value, 17))


## Trim redundant trailing zeros, then guarantee a decimal point so the value
## reparses as a float rather than an int.
static func _tidy_float(text: String) -> String:
	var out: String = text
	if out.contains("."):
		out = out.rstrip("0")
		if out.ends_with("."):
			out += "0"
	else:
		out += ".0"
	return out


static func _write(value: Variant, indent_unit: String, depth: int) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if bool(value) else "false"
		TYPE_INT:
			return str(int(value))
		TYPE_FLOAT:
			return encode_float(float(value))
		TYPE_STRING, TYPE_STRING_NAME:
			# Delegated: escaping is fiddly and Godot's writer is correct for it.
			return JSON.stringify(String(value))
		TYPE_DICTIONARY:
			return _write_dict(value as Dictionary, indent_unit, depth)
		TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
			return _write_array(Array(value), indent_unit, depth)
		TYPE_VECTOR2:
			return _write_array(vec2_to_array(value as Vector2), indent_unit, depth)
		TYPE_VECTOR3:
			return _write_array(vec3_to_array(value as Vector3), indent_unit, depth)
		_:
			push_error("Serializer: unsupported type %s" % type_string(typeof(value)))
			return "null"


static func _write_dict(data: Dictionary, indent_unit: String, depth: int) -> String:
	if data.is_empty():
		return "{}"
	var parts: PackedStringArray = PackedStringArray()
	for key: String in sorted_keys(data):
		parts.append("%s%s%s" % [
			JSON.stringify(key),
			": " if not indent_unit.is_empty() else ":",
			_write(data[key], indent_unit, depth + 1),
		])
	return _join_block(parts, "{", "}", indent_unit, depth)


static func _write_array(data: Array, indent_unit: String, depth: int) -> String:
	if data.is_empty():
		return "[]"
	var parts: PackedStringArray = PackedStringArray()
	var scalars_only: bool = true
	for element: Variant in data:
		var t: int = typeof(element)
		if t == TYPE_DICTIONARY or t == TYPE_ARRAY:
			scalars_only = false
		parts.append(_write(element, indent_unit, depth + 1))

	# A hull polygon, an RNG state, an armour profile: arrays of plain numbers read
	# far better on one line than exploded one element per row.
	if scalars_only:
		var separator: String = ", " if not indent_unit.is_empty() else ","
		return "[" + separator.join(parts) + "]"
	return _join_block(parts, "[", "]", indent_unit, depth)


## Wrap pre-encoded members in brackets, indenting one per line when pretty-printing
## and packing them tight when not.
static func _join_block(
	parts: PackedStringArray, open_token: String, close_token: String,
	indent_unit: String, depth: int
) -> String:
	if indent_unit.is_empty():
		return open_token + ",".join(parts) + close_token
	var pad: String = indent_unit.repeat(depth + 1)
	var indented: PackedStringArray = PackedStringArray()
	for part: String in parts:
		indented.append(pad + part)
	return "%s\n%s\n%s%s" % [
		open_token, ",\n".join(indented), indent_unit.repeat(depth), close_token
	]


static func vec2_to_array(v: Vector2) -> Array:
	return [v.x, v.y]


static func array_to_vec2(a: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if a is Array and (a as Array).size() >= 2:
		var arr: Array = a as Array
		return Vector2(float(arr[0]), float(arr[1]))
	return fallback


static func vec3_to_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func array_to_vec3(a: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		var arr: Array = a as Array
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return fallback


## Sorted keys of a Dictionary as Strings.
##
## Use this anywhere a Dictionary must be walked in an outcome-affecting way.
## Iterating `dict.keys()` directly is insertion-ordered and therefore depends on
## construction history.
static func sorted_keys(d: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for k: Variant in d.keys():  # determinism-ok: collected then sorted below
		keys.append(str(k))
	keys.sort()
	return keys
