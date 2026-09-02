class_name DeterministicRng
extends RefCounted

## Deterministic pseudo-random generator for the simulation core.
##
## Godot's global `randi()` / `randf()` / `RandomNumberGenerator` are banned inside
## `res://src/sim/**` (see tests/lint/lint_determinism.gd) because their state is
## process-global and their implementation is not pinned across engine versions.
##
## This is xorshift128 with every intermediate masked to 32 bits. That matters:
## a 64-bit generator written in GDScript would rely on signed int64 overflow
## wrapping, which is not something we should bet reproducibility on. Every
## operation here stays inside the exactly-representable range, so the output
## sequence is identical on any platform Godot runs on.
##
## Period is 2^128 - 1. Seeding is SplitMix32 so that adjacent seeds (0, 1, 2 ...)
## still produce well-separated streams.

const MASK32: int = 0xFFFFFFFF
const U32_SCALE: float = 1.0 / 4294967296.0

## Number of uniforms summed by `next_gaussian()`. 12 makes the variance exactly 1.
const IRWIN_HALL_N: int = 12

var _x: int = 0
var _y: int = 0
var _z: int = 0
var _w: int = 0


func _init(seed_value: int = 0) -> void:
	seed_rng(seed_value)


## 32-bit multiply that cannot overflow int64.
##
## A direct `(a * b) & MASK32` would compute a full 64-bit product first; with both
## operands up to 2^32 that exceeds the signed int64 range. Splitting the left
## operand into 16-bit halves keeps every partial product under 2^48.
static func mul32(a: int, b: int) -> int:
	var a_lo: int = a & 0xFFFF
	var a_hi: int = (a >> 16) & 0xFFFF
	return ((a_lo * b) + (((a_hi * b) & 0xFFFF) << 16)) & MASK32


## SplitMix32 finalizer — used for seeding and for deriving stream seeds.
static func splitmix32(value: int) -> int:
	var z: int = (value + 0x9E3779B9) & MASK32
	z = mul32(z ^ (z >> 16), 0x21F0AAAD)
	z = mul32(z ^ (z >> 15), 0x735A2D97)
	return (z ^ (z >> 15)) & MASK32


## Stable 32-bit FNV-1a string hash.
##
## Deliberately not `String.hash()`: that is an engine implementation detail and
## may change between Godot versions, which would silently re-seed every stream
## and break replay compatibility of saved battles.
static func hash_string(text: String) -> int:
	var h: int = 0x811C9DC5
	for i: int in text.length():
		h = mul32(h ^ (text.unicode_at(i) & MASK32), 0x01000193)
	return h & MASK32


func seed_rng(seed_value: int) -> void:
	var s: int = seed_value & MASK32
	_x = splitmix32(s)
	_y = splitmix32(_x)
	_z = splitmix32(_y)
	_w = splitmix32(_z)
	# xorshift128 degenerates to all-zeroes if the whole state is zero.
	if _x == 0 and _y == 0 and _z == 0 and _w == 0:
		_x = 0x9E3779B9


## Raw generator step. Range [0, 2^32).
func next_u32() -> int:
	var t: int = _x
	t = (t ^ ((t << 11) & MASK32)) & MASK32
	t = t ^ (t >> 8)
	_x = _y
	_y = _z
	_z = _w
	var w: int = _w
	w = w ^ (w >> 19)
	_w = (w ^ t) & MASK32
	return _w


## Uniform float in [0, 1).
func next_float() -> float:
	return float(next_u32()) * U32_SCALE


## Uniform float in [min_value, max_value).
func next_range(min_value: float, max_value: float) -> float:
	return min_value + (max_value - min_value) * next_float()


## Uniform integer in [0, bound). Rejection-sampled, so the distribution is exactly
## uniform rather than modulo-biased — which matters when the same call decides
## e.g. which of 3 magazines a fragment reaches.
func next_int(bound: int) -> int:
	if bound <= 1:
		return 0
	var limit: int = (0x100000000 / bound) * bound
	var value: int = next_u32()
	while value >= limit:
		value = next_u32()
	return value % bound


## Uniform integer in [min_value, max_value] inclusive.
func next_int_range(min_value: int, max_value: int) -> int:
	if max_value <= min_value:
		return min_value
	return min_value + next_int(max_value - min_value + 1)


## Approximately standard-normal deviate, via the Irwin-Hall construction.
##
## Box-Muller would need `log()` and `cos()`. Those are not required by IEEE-754 to
## be correctly rounded, so two platforms can legitimately disagree in the last bit
## and diverge a replay. Summing 12 uniforms uses only addition, is naturally
## truncated at +/-6 sigma (real gun dispersion patterns are truncated too), and is
## bit-identical anywhere.
func next_gaussian() -> float:
	var total: float = 0.0
	for _i: int in IRWIN_HALL_N:
		total += next_float()
	return total - 6.0


func next_gaussian_scaled(mean: float, std_dev: float) -> float:
	return mean + std_dev * next_gaussian()


## True with probability `p`.
func chance(p: float) -> bool:
	if p <= 0.0:
		return false
	if p >= 1.0:
		return true
	return next_float() < p


## Uniform point inside the unit circle (rejection sampled — no transcendentals).
func next_in_unit_circle() -> Vector2:
	while true:
		var x: float = next_float() * 2.0 - 1.0
		var y: float = next_float() * 2.0 - 1.0
		if x * x + y * y <= 1.0:
			return Vector2(x, y)
	return Vector2.ZERO


## State is exposed as plain ints (not PackedInt32Array) because the words are
## unsigned 32-bit and would round-trip through int32 as negative numbers, which
## makes saved replay files needlessly confusing to read and diff.
func get_state() -> Array[int]:
	return [_x, _y, _z, _w]


func set_state(state: Array[int]) -> void:
	assert(state.size() == 4, "DeterministicRng state must have exactly 4 words")
	_x = state[0] & MASK32
	_y = state[1] & MASK32
	_z = state[2] & MASK32
	_w = state[3] & MASK32


func clone() -> DeterministicRng:
	var copy: DeterministicRng = DeterministicRng.new()
	copy.set_state(get_state())
	return copy
