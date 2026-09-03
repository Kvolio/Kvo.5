class_name ReplayIo
extends RefCounted

## Replays on disk.
##
## Written through the project's own canonical serializer rather than `JSON.stringify`,
## for the reason documented in `Serializer`: Godot's encoder does not round-trip
## doubles even with full precision requested, and a replay whose floats came back
## slightly different would diverge on the first tick and blame the simulation.

const REPLAY_DIR: String = "user://replays"
const EXTENSION: String = ".replay.json"


static func save(recorder: ReplayRecorder, world: SimWorld, name: String) -> String:
	if not DirAccess.dir_exists_absolute(REPLAY_DIR):
		DirAccess.make_dir_recursive_absolute(REPLAY_DIR)
	var path: String = REPLAY_DIR.path_join("%s%s" % [name, EXTENSION])
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("ReplayIo: could not write %s" % path)
		return ""
	file.store_string(Serializer.to_json(recorder.to_document(world)))
	file.close()
	return path


static func load_from_file(path: String) -> ReplayRecorder:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("ReplayIo: could not read %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		push_error("ReplayIo: %s is not a replay" % path)
		return null
	var recorder: ReplayRecorder = ReplayRecorder.from_document(parsed as Dictionary)
	if recorder.header.schema_version != ReplayRecorder.SCHEMA_VERSION:
		push_error("ReplayIo: %s is schema v%d; this build understands v%d" % [
			path, recorder.header.schema_version, ReplayRecorder.SCHEMA_VERSION])
		return null
	return recorder


static func list_saved() -> Array[String]:
	var out: Array[String] = []
	if not DirAccess.dir_exists_absolute(REPLAY_DIR):
		return out
	var names: Array = Array(DirAccess.get_files_at(REPLAY_DIR))
	names.sort()
	for name: Variant in names:
		if str(name).ends_with(EXTENSION):
			out.append(REPLAY_DIR.path_join(str(name)))
	return out
