class_name JsonLoader
extends RefCounted

## Loading helpers for the JSON data layer.
##
## Every ship, gun, shell, armour material and tuning constant lives in a JSON file
## outside the engine code (spec §4). This is the single place that reads them, so
## error reporting is consistent and the rest of the codebase never touches
## FileAccess directly.

## Read and parse one JSON file. Returns `{}` on any failure, after pushing an error.
static func load_dict(path: String) -> Dictionary:
	var text: String = load_text(path)
	if text.is_empty():
		return {}
	var parsed: Variant = Serializer.from_json(text, path)
	if parsed is Dictionary:
		return parsed as Dictionary
	push_error("%s: expected a JSON object at the top level, got %s" % [path, type_string(typeof(parsed))])
	return {}


static func load_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		push_error("File not found: %s" % path)
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Could not open %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


static func save_text(path: String, text: String) -> bool:
	var dir: String = path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(text)
	file.close()
	return true


static func save_dict(path: String, data: Dictionary) -> bool:
	return save_text(path, Serializer.to_json(data))


## All *.json files directly inside `dir_path`, sorted by filename.
##
## Sorted because load order determines ID assignment order for anything built at
## load time, and a filesystem's natural order is not reproducible across machines.
static func list_json_files(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir_path):
		return out
	for name: String in DirAccess.get_files_at(dir_path):
		# Exported Godot projects rename imported resources; .json is not imported,
		# but be tolerant of a stray .remap suffix from a stripped export.
		var clean: String = name.trim_suffix(".remap")
		if clean.to_lower().ends_with(".json"):
			out.append(dir_path.path_join(clean))
	var as_array: Array = Array(out)
	as_array.sort()
	return PackedStringArray(as_array)
