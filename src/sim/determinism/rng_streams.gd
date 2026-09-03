class_name RngStreams
extends RefCounted

## Named, independent random streams derived from one master seed.
##
## Why streams at all: if every system drew from a single generator, adding a new
## consumer anywhere (say, a fire-spread roll) would shift every subsequent draw and
## silently change the outcome of every saved battle. With named streams, gunnery
## dispersion is unaffected by how many times the fire system rolled this tick.
##
## Stream seeds are derived as splitmix32(master_seed ^ fnv1a(name)), so the names
## are what identify a stream — never registration order.

var _master_seed: int = 0
var _streams: Dictionary = {}


func _init(master_seed: int = 0) -> void:
	_master_seed = master_seed & DeterministicRng.MASK32


func get_master_seed() -> int:
	return _master_seed


## Fetch (creating on first use) the stream with this name.
func stream(name: String) -> DeterministicRng:
	var existing: Variant = _streams.get(name)
	if existing != null:
		return existing as DeterministicRng
	var derived: int = DeterministicRng.splitmix32(
		(_master_seed ^ DeterministicRng.hash_string(name)) & DeterministicRng.MASK32
	)
	var rng: DeterministicRng = DeterministicRng.new(derived)
	_streams[name] = rng
	return rng


## Stream names in sorted order.
##
## Callers must never iterate `_streams` directly: Dictionary iteration follows
## insertion order, which depends on which systems happened to run first, and that
## would make serialization order (and therefore checksums) history-dependent.
func stream_names() -> Array[String]:
	var names: Array[String] = []
	for key: Variant in _streams.keys():  # determinism-ok: collected then sorted below
		names.append(str(key))
	names.sort()
	return names


func serialize() -> Dictionary:
	var states: Dictionary = {}
	for name: String in stream_names():
		states[name] = (_streams[name] as DeterministicRng).get_state()
	return {"masterSeed": _master_seed, "streams": states}


func deserialize(data: Dictionary) -> void:
	_master_seed = int(data.get("masterSeed", 0)) & DeterministicRng.MASK32
	_streams.clear()
	var states: Dictionary = data.get("streams", {}) as Dictionary
	var names: Array = states.keys()
	names.sort()
	for key: Variant in names:
		var name: String = str(key)
		var rng: DeterministicRng = stream(name)
		var raw: Array = states[key] as Array
		var words: Array[int] = []
		for value: Variant in raw:
			words.append(int(value))
		rng.set_state(words)
