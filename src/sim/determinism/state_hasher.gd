class_name StateHasher
extends RefCounted

## Incremental FNV-1a checksum over simulation state.
##
## Its job is divergence *detection*: two runs that should be identical are hashed
## every tick, and the first tick whose hashes differ localises the bug. Replay
## verification and the cross-platform determinism caveat in docs/DETERMINISM.md
## both rest on this.
##
## Floats are hashed from their exact IEEE-754 bits rather than a rounded decimal
## form, so a one-ulp drift is caught rather than smoothed over. The single
## normalisation is -0.0 -> 0.0, which compares equal everywhere and is never a
## real divergence.

const FNV_OFFSET_32: int = 0x811C9DC5
const FNV_PRIME_32: int = 0x01000193

var _h: int = FNV_OFFSET_32
var _scratch: PackedByteArray = PackedByteArray()


func _init() -> void:
	_scratch.resize(8)


func reset() -> void:
	_h = FNV_OFFSET_32


func value() -> int:
	return _h


func to_hex() -> String:
	return "%08x" % _h


func _mix_byte(b: int) -> void:
	_h = DeterministicRng.mul32(_h ^ (b & 0xFF), FNV_PRIME_32)


func write_int(v: int) -> void:
	for i: int in 8:
		_mix_byte((v >> (i * 8)) & 0xFF)


func write_bool(v: bool) -> void:
	_mix_byte(1 if v else 0)


func write_float(v: float) -> void:
	var normalised: float = 0.0 if v == 0.0 else v
	_scratch.encode_double(0, normalised)
	for i: int in 8:
		_mix_byte(_scratch[i])


func write_string(v: String) -> void:
	write_int(DeterministicRng.hash_string(v))


func write_vec2(v: Vector2) -> void:
	write_float(v.x)
	write_float(v.y)


func write_vec3(v: Vector3) -> void:
	write_float(v.x)
	write_float(v.y)
	write_float(v.z)
