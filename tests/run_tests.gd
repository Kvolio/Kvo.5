extends SceneTree

## Headless test runner.
##
##   godot --headless --path . --script res://tests/run_tests.gd
##   godot --headless --path . --script res://tests/run_tests.gd -- --filter=rng
##   godot --headless --path . --script res://tests/run_tests.gd -- --exclude=gun_action
##
## Each suite reports how long it took, because a suite that has quietly become slow
## is usually a system that has quietly become slow.
##
## Exits non-zero if anything failed, so CI and the per-stage gate can rely on it.
##
## NOTE: after adding a script with a new `class_name`, run `--import` first, or the
## global class cache will not know the type and every suite referencing it fails to
## parse. `tools/test.sh` does both in order.

const TEST_DIRS: Array[String] = [
	"res://tests/lint",
	"res://tests/unit",
	"res://tests/integration",
]

## Safety net. A GDScript runtime error aborts the current call frame, so an
## unguarded failure inside _initialize() would skip quit() and leave a headless
## SceneTree spinning until CI's timeout killed it — reported as a hang rather than
## as the parse error it actually was. _process() turns that into a fast, explicit
## failure instead.
var _finished: bool = false


func _process(_delta: float) -> bool:
	if not _finished:
		push_error("Test runner aborted before completing — see the errors above.")
		printerr("\nRUNNER ABORTED: a suite failed to load or errored during discovery.\n")
		quit(2)
	return true


func _initialize() -> void:
	var filter: String = _parse_argument("--filter=")
	var exclude: String = _parse_argument("--exclude=")
	var suite_paths: Array[String] = _discover(filter, exclude)

	if suite_paths.is_empty():
		print("No test suites found%s." % ("" if filter.is_empty() else " matching filter '%s'" % filter))
		_finished = true
		quit(1)
		return

	var total_tests: int = 0
	var total_assertions: int = 0
	var all_failures: Array[String] = []
	var suites_failed: int = 0

	print("\n=== Naval Battle Sandbox — test run ===\n")

	for path: String in suite_paths:
		var script: Variant = load(path)
		if not (script is GDScript):
			all_failures.append("%s :: could not be loaded" % path)
			suites_failed += 1
			continue
		# A script that failed to parse still loads as a GDScript object; calling
		# new() on it raises a runtime error that would abort this whole function.
		if not (script as GDScript).can_instantiate():
			all_failures.append("%s :: failed to compile (see the parse errors above)" % path)
			suites_failed += 1
			continue
		var instance: Variant = (script as GDScript).new()
		if not (instance is SimTest):
			all_failures.append("%s :: does not extend SimTest" % path)
			suites_failed += 1
			continue

		var suite: SimTest = instance as SimTest
		var started: int = Time.get_ticks_msec()
		var result: Dictionary = suite.run_all()
		var elapsed: int = Time.get_ticks_msec() - started
		var failures: Array = result["failures"] as Array
		total_tests += int(result["tests"])
		total_assertions += int(result["assertions"])

		var marker: String = "ok  " if failures.is_empty() else "FAIL"
		print("  [%s] %-42s %3d tests, %5d assertions %7.1f s" % [
			marker, result["suite"], int(result["tests"]), int(result["assertions"]),
			float(elapsed) / 1000.0
		])
		if not failures.is_empty():
			suites_failed += 1
			for failure: Variant in failures:
				all_failures.append(str(failure))

	print("\n---------------------------------------------------------------")
	if all_failures.is_empty():
		print("PASSED — %d suites, %d tests, %d assertions" % [
			suite_paths.size(), total_tests, total_assertions
		])
		print("---------------------------------------------------------------\n")
		_finished = true
		quit(0)
		return

	print("FAILED — %d of %d suites, %d failed assertions" % [
		suites_failed, suite_paths.size(), all_failures.size()
	])
	print("")
	for failure: String in all_failures:
		print("  x %s" % failure)
	print("---------------------------------------------------------------\n")
	_finished = true
	quit(1)


func _parse_argument(prefix: String) -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return ""


## Suites are collected directory by directory and sorted within each, so lint
## runs before unit tests and unit before integration — a structural violation is
## reported before the behavioural fallout it causes.
func _discover(filter: String, exclude: String = "") -> Array[String]:
	var paths: Array[String] = []
	for dir_path: String in TEST_DIRS:
		if not DirAccess.dir_exists_absolute(dir_path):
			continue
		var names: Array = Array(DirAccess.get_files_at(dir_path))
		names.sort()
		for name: Variant in names:
			var file_name: String = str(name).trim_suffix(".remap")
			if not file_name.ends_with(".gd"):
				continue
			if not filter.is_empty() and not file_name.contains(filter):
				continue
			if not exclude.is_empty() and file_name.contains(exclude):
				continue
			paths.append(dir_path.path_join(file_name))
	return paths
