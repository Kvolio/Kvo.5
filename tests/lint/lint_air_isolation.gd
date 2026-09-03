extends SimTest

## Structural enforcement of the aircraft isolation boundary.
##
## The architecture says aircraft never touch the naval core: bombs are ordinary
## projectiles, aerial torpedoes are ordinary torpedoes, carrier facilities are ordinary
## compartments and components, and `HitResolver` contains no aircraft branch. That is
## easy to say and easy to lose — one `if projectile.is_bomb()` in the tracer and the
## claim is gone, without any test failing.
##
## So it is checked here, mechanically, on every run: nothing under `src/sim/` outside
## `src/sim/air/` may name an aircraft type, and the damage chain may not mention
## aircraft at all. The other half of the claim — that the naval suite passes with the
## module unregistered — is not asserted by grepping; it is asserted by the fact that
## no other suite in this project registers the module, and by
## `test_no_naval_suite_registers_the_air_module` below.

const SIM_ROOT: String = "res://src/sim"
const AIR_ROOT: String = "res://src/sim/air"
const TEST_ROOT: String = "res://tests"

## Names that belong to the air module and must not appear in the naval core.
const AIR_TYPES: Array[String] = [
	"AirModule", "AirGroup", "AircraftDef", "CarrierOperations",
	"air_module", "air_group", "aircraft_def", "carrier_operations",
]

## The damage chain in particular. If one of these files ever learns what an aircraft
## is, the causality chain has stopped being about physics and started being about
## which system dropped the ordnance.
const DAMAGE_CHAIN: Array[String] = [
	"res://src/sim/damage/hit_resolver.gd",
	"res://src/sim/damage/damage_resolver.gd",
	"res://src/sim/damage/hit_report.gd",
	"res://src/sim/geometry/trajectory_tracer.gd",
	"res://src/sim/systems/projectile_system.gd",
	"res://src/sim/systems/torpedo_system.gd",
]

var _naval_scripts: Array[String] = []


func suite_name() -> String:
	return "lint: aircraft isolation (src/sim)"


func before_each() -> void:
	if _naval_scripts.is_empty():
		for path: String in _collect_scripts(SIM_ROOT):
			if not path.begins_with(AIR_ROOT):
				_naval_scripts.append(path)


func test_the_naval_core_is_populated_and_the_air_module_exists() -> void:
	ok(not _naval_scripts.is_empty(), "expected naval scripts under %s" % SIM_ROOT)
	ok(not _collect_scripts(AIR_ROOT).is_empty(),
		"expected the air module to exist under %s — this lint is meaningless without it"
			% AIR_ROOT)


func test_the_naval_core_never_names_an_aircraft_type() -> void:
	for path: String in _naval_scripts:
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i: int in lines.size():
			var line: String = lines[i]
			var code: String = line
			var comment: int = code.find("#")
			if comment >= 0:
				code = code.substr(0, comment)
			for type_name: String in AIR_TYPES:
				if code.contains(type_name):
					fail("%s:%d names `%s` — the naval core must not know the air "
						% [path, i + 1, type_name]
						+ "module exists; register it and step it through a duck-typed hook")


func test_the_damage_chain_never_mentions_aircraft_at_all() -> void:
	# Stricter than the rule above, comments included: a comment in the tracer that
	# talks about bombs is a sign somebody was about to special-case one.
	var words: Array[String] = ["aircraft", "airgroup", "air_group", "carrier op", "sortie"]
	for path: String in DAMAGE_CHAIN:
		if not FileAccess.file_exists(path):
			continue
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i: int in lines.size():
			# "anti-aircraft" is a gun, not an aeroplane. The damage chain is entitled
			# to know that a non-penetrating hit sweeps a ship's AA mounts away; what it
			# may not know is that anything was flying.
			var lowered: String = lines[i].to_lower().replace("anti-aircraft", "flak") \
				.replace("antiaircraft", "flak").replace("anti aircraft", "flak")
			for word: String in words:
				if lowered.contains(word):
					fail("%s:%d mentions `%s` — bombs and aerial torpedoes must arrive "
						% [path, i + 1, word]
						+ "at the damage chain indistinguishable from a shell")


func test_a_world_has_no_modules_until_one_is_registered() -> void:
	# The behavioural half of the claim, in one line: an unregistered module is not
	# merely inert, it is absent.
	var world: SimWorld = SimWorld.create(1, TestShips.config())
	eq(world.module_count(), 0,
		"a plain world must carry no modules, so every naval test in this project runs "
		+ "with the air module unregistered whether it thinks about it or not")


func test_no_naval_suite_registers_the_air_module() -> void:
	# The isolation requirement is that the naval suite passes with the module
	# unregistered. That is worth nothing if a naval suite quietly registers it, so the
	# only suite allowed to is the one that tests the module itself.
	for path: String in _collect_scripts(TEST_ROOT):
		if path.ends_with("test_air_module.gd") or path.ends_with("lint_air_isolation.gd"):
			continue
		var text: String = FileAccess.get_file_as_string(path)
		not_ok(text.contains("AirModule.register"),
			"%s registers the air module — the naval suite must run without it" % path)


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
