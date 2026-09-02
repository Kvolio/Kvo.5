extends Node

## Tunable-constant registry (autoload `GameConfig`).
##
## Loads every file in res://data/config/ and exposes it under the file's stem, so
## `data/config/sim.json` is reachable as `GameConfig.get_number("sim.tick.rateHz")`.
##
## Simulation code reads its constants from here rather than declaring them inline.
## That is what makes the model tunable after the fact (spec §45) — and it is also
## why the config must be loaded before any sim is constructed, never mutated while
## a battle is running, and captured into a saved battle so a reload reproduces it.

const CONFIG_DIR: String = "res://data/config"

var _sections: Dictionary = {}
var _loaded: bool = false


func _ready() -> void:
	load_all()


func load_all() -> void:
	_sections.clear()
	for path: String in JsonLoader.list_json_files(CONFIG_DIR):
		var stem: String = path.get_file().get_basename()
		_sections[stem] = JsonLoader.load_dict(path)
	_loaded = true


func is_loaded() -> bool:
	return _loaded


## Look up a dotted path such as "sim.tick.rateHz". Returns `default` if any
## segment is missing, so a partially-written config degrades instead of crashing.
func get_value(path: String, default: Variant = null) -> Variant:
	if not _loaded:
		load_all()
	var parts: PackedStringArray = path.split(".", false)
	if parts.is_empty():
		return default
	var cursor: Variant = _sections
	for part: String in parts:
		if cursor is Dictionary and (cursor as Dictionary).has(part):
			cursor = (cursor as Dictionary)[part]
		else:
			return default
	return cursor


func get_number(path: String, default: float = 0.0) -> float:
	var value: Variant = get_value(path, null)
	if value == null:
		return default
	if value is float or value is int:
		return float(value)
	return default


func get_int(path: String, default: int = 0) -> int:
	var value: Variant = get_value(path, null)
	if value == null:
		return default
	if value is float or value is int:
		return int(value)
	return default


func get_bool(path: String, default: bool = false) -> bool:
	var value: Variant = get_value(path, null)
	if value is bool:
		return value as bool
	return default


func get_dict(path: String) -> Dictionary:
	var value: Variant = get_value(path, null)
	return value as Dictionary if value is Dictionary else {}


func get_array(path: String) -> Array:
	var value: Variant = get_value(path, null)
	return value as Array if value is Array else []


## Section names present, sorted.
func section_names() -> Array[String]:
	return Serializer.sorted_keys(_sections)


## Snapshot of the whole config, for embedding in a saved battle so that a reload
## reproduces the numbers the battle was actually fought with.
func snapshot() -> Dictionary:
	return _sections.duplicate(true)


func restore(snapshot_data: Dictionary) -> void:
	_sections = snapshot_data.duplicate(true)
	_loaded = true
