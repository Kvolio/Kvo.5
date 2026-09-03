extends SimTest

## Structural enforcement of the determinism contract.
##
## Determinism is an architectural requirement, and requirements that live only in a
## design document decay. This suite reads every script under res://src/sim/** and
## fails the build on the constructs that would break reproducibility, so a
## regression is caught at commit time rather than as an unexplainable divergence
## three stages later.
##
## Escape hatch: append `# determinism-ok: <reason>` to a line to whitelist it. The
## reason is for the next reader; the marker is deliberately noisy so that reaching
## for it is a conscious act.

const SIM_ROOT: String = "res://src/sim"
const ALLOW_MARKER: String = "determinism-ok"

## Literal substrings that must not appear in simulation code.
const BANNED_CALLS: Array = [
	["randi(", "process-global RNG — use RngStreams.stream(name)"],
	["randf(", "process-global RNG — use RngStreams.stream(name)"],
	["randi_range(", "process-global RNG — use DeterministicRng.next_int_range()"],
	["randf_range(", "process-global RNG — use DeterministicRng.next_range()"],
	["randfn(", "process-global RNG — use DeterministicRng.next_gaussian_scaled()"],
	["randv(", "process-global RNG — use DeterministicRng"],
	["randomize(", "seeds the global RNG from the clock"],
	["rand_from_seed(", "engine RNG whose algorithm is not pinned across versions"],
	["RandomNumberGenerator", "engine RNG — state is not serialised into saves or replays"],
	["Time.", "wall-clock time cannot appear in simulation logic"],
	["OS.get_ticks_msec", "wall-clock time cannot appear in simulation logic"],
	["OS.get_ticks_usec", "wall-clock time cannot appear in simulation logic"],
	["OS.get_unix_time", "wall-clock time cannot appear in simulation logic"],
	["Engine.get_frames_drawn", "frame counters are render-rate dependent"],
	["Engine.get_process_frames", "frame counters are render-rate dependent"],
	["Engine.get_physics_frames", "frame counters are render-rate dependent"],
	["get_tree(", "the simulation core must not touch the scene tree"],
	["await ", "asynchronous resumption makes execution order unpredictable"],
]

## Node lifecycle methods have no business in a Node-free core.
const BANNED_LIFECYCLE: Array = [
	["func _process(", "the sim is stepped explicitly, never by the engine"],
	["func _physics_process(", "the sim is stepped explicitly, never by the engine"],
	["func _ready(", "Node lifecycle in a Node-free core"],
	["func _draw(", "rendering belongs in src/view"],
	["func _input(", "input belongs in src/ui"],
	["func _unhandled_input(", "input belongs in src/ui"],
]

## Base classes that would drag the simulation into the scene tree.
const BANNED_BASES: Array = [
	"Node", "Node2D", "Node3D", "CanvasItem", "CanvasLayer", "Control",
	"SceneTree", "MainLoop", "Window", "Viewport", "Area2D", "RigidBody2D",
	"CharacterBody2D", "StaticBody2D", "Sprite2D", "Camera2D", "Timer",
]

var _scripts: Array[String] = []


func suite_name() -> String:
	return "lint: determinism contract (src/sim)"


func before_each() -> void:
	if _scripts.is_empty():
		_scripts = _collect_scripts(SIM_ROOT)


# ------------------------------------------------------------------- tests --

func test_sim_tree_is_populated() -> void:
	ok(not _scripts.is_empty(), "expected to find GDScript files under %s" % SIM_ROOT)


func test_no_nondeterministic_calls() -> void:
	for path: String in _scripts:
		var lines: PackedStringArray = _code_lines(path)
		for i: int in lines.size():
			var line: String = lines[i]
			if line.is_empty():
				continue
			for entry: Array in BANNED_CALLS:
				if line.contains(entry[0] as String):
					fail("%s:%d uses `%s` — %s" % [path, i + 1, entry[0], entry[1]])


func test_no_node_lifecycle_methods() -> void:
	for path: String in _scripts:
		var lines: PackedStringArray = _code_lines(path)
		for i: int in lines.size():
			for entry: Array in BANNED_LIFECYCLE:
				if lines[i].contains(entry[0] as String):
					fail("%s:%d declares `%s` — %s" % [path, i + 1, entry[0], entry[1]])


func test_sim_core_is_node_free() -> void:
	for path: String in _scripts:
		var lines: PackedStringArray = _code_lines(path)
		for i: int in lines.size():
			var line: String = lines[i].strip_edges()
			if not line.begins_with("extends "):
				continue
			var base: String = line.trim_prefix("extends ").strip_edges()
			if BANNED_BASES.has(base):
				fail("%s:%d extends %s — res://src/sim must contain no Nodes" % [path, i + 1, base])


## Dictionary iteration is insertion-ordered in Godot. Iterating one to make a
## decision makes that decision depend on construction history, which is how an
## otherwise-deterministic simulation quietly stops being one.
func test_no_unordered_dictionary_iteration() -> void:
	var pattern: RegEx = RegEx.new()
	pattern.compile("\\bfor\\b.*\\.(keys|values)\\s*\\(\\s*\\)")
	for path: String in _scripts:
		var lines: PackedStringArray = _code_lines(path)
		for i: int in lines.size():
			if pattern.search(lines[i]) != null:
				fail(
					"%s:%d iterates a Dictionary directly — sort the keys first "
					% [path, i + 1]
					+ "(Serializer.sorted_keys) or mark the line `# %s: <reason>`" % ALLOW_MARKER
				)


# ------------------------------------------------------------------ helpers --

## Source lines with comments removed, and whitelisted lines blanked out.
func _code_lines(path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for raw: String in JsonLoader.load_text(path).split("\n"):
		if raw.contains(ALLOW_MARKER):
			out.append("")
		else:
			out.append(_strip_comment(raw))
	return out


## Remove a trailing `#` comment without being fooled by a `#` inside a string.
static func _strip_comment(line: String) -> String:
	var in_string: bool = false
	var quote: String = ""
	var i: int = 0
	while i < line.length():
		var c: String = line[i]
		if in_string:
			if c == "\\":
				i += 2
				continue
			if c == quote:
				in_string = false
		elif c == "\"" or c == "'":
			in_string = true
			quote = c
		elif c == "#":
			return line.substr(0, i)
		i += 1
	return line


static func _collect_scripts(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	if not DirAccess.dir_exists_absolute(dir_path):
		return out
	var files: Array = Array(DirAccess.get_files_at(dir_path))
	files.sort()
	for name: Variant in files:
		var file_name: String = str(name).trim_suffix(".remap")
		if file_name.ends_with(".gd"):
			out.append(dir_path.path_join(file_name))
	var dirs: Array = Array(DirAccess.get_directories_at(dir_path))
	dirs.sort()
	for name: Variant in dirs:
		out.append_array(_collect_scripts(dir_path.path_join(str(name))))
	return out
