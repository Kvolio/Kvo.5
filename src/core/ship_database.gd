extends Node

## Registry of every ship design available (autoload `ShipDatabase`).
##
## Scans res://data/ships/ for the historical presets and user://ships/ for the
## player's own designs, and returns both as ShipSpec objects the combat engine
## cannot tell apart. Adding a ship is adding a file — no code change, which is the
## whole point of the data-driven requirement (spec §4).
##
## Load order is alphabetical by path so the registry is built identically on every
## machine.

const PRESET_DIR: String = "res://data/ships"
const USER_DIR: String = "user://ships"

var _specs: Dictionary = {}
var _order: Array[String] = []


func _ready() -> void:
	reload()


func reload() -> void:
	_specs.clear()
	_order.clear()
	_load_directory(PRESET_DIR, false)
	_load_directory(USER_DIR, true)


func _load_directory(dir_path: String, custom: bool) -> void:
	for path: String in JsonLoader.list_json_files(dir_path):
		var spec: ShipSpec = ShipSpecLoader.load_from_file(path)
		if spec == null:
			continue
		spec.is_custom = custom
		if _specs.has(spec.spec_id):
			# A player design deliberately overrides a preset of the same id, which is
			# how "my improved Iowa" works. Anything else is a genuine clash.
			if not custom:
				push_warning("ShipDatabase: duplicate ship id '%s' in %s" % [spec.spec_id, path])
		else:
			_order.append(spec.spec_id)
		_specs[spec.spec_id] = spec


## A fresh copy, so callers can modify a design without corrupting the registry.
func get_spec(spec_id: String) -> ShipSpec:
	var spec: ShipSpec = _specs.get(spec_id) as ShipSpec
	return spec.duplicate_spec() if spec != null else null


func has_spec(spec_id: String) -> bool:
	return _specs.has(spec_id)


## Every design id, in load order.
func spec_ids() -> Array[String]:
	return _order.duplicate()


func specs_of_type(ship_type: String) -> Array[String]:
	var out: Array[String] = []
	for spec_id: String in _order:
		if (_specs[spec_id] as ShipSpec).ship_type == ship_type:
			out.append(spec_id)
	return out


func count() -> int:
	return _order.size()


## Write a design to user://ships/ so it can be imported into any battle.
func save_custom(spec_id: String, document: Dictionary) -> bool:
	if not DirAccess.dir_exists_absolute(USER_DIR):
		DirAccess.make_dir_recursive_absolute(USER_DIR)
	var path: String = USER_DIR.path_join("%s.json" % spec_id)
	if not JsonLoader.save_dict(path, document):
		return false
	reload()
	return true
