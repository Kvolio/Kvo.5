extends SceneTree

## Headless test runner.
##
##   godot --headless --path . --script res://tests/run_tests.gd
##   godot --headless --path . --script res://tests/run_tests.gd -- --filter=rng
##
## Exits non-zero if anything failed, so CI and the per-stage gate can rely on it.

const TEST_DIRS: Array[String] = [
	"res://tests/lint",
	"res://tests/unit",
	"res://tests/integration",
]


func _initialize() -> void:
	var filter: String = _parse_filter()
	var suite_paths: Array[String] = _discover(filter)

	if suite_paths.is_empty():
		print("No test suites found%s." % ("" if filter.is_empty() else " matching filter '%s'" % filter))
		quit(1)
		return

	var total_tests: int = 0
	var total_assertions: int = 0
	var all_failures: Array[String] = []
	var suites_failed: int = 0

	print("\n=== Naval Battle Sandbox — test run ===\n")

	for path: String in suite_paths:
		var script: Variant = load(path)
		if script == null:
			all_failures.append("%s :: could not be loaded" % path)
			suites_failed += 1
			continue
		var instance: Variant = (script as GDScript).new()
		if not (instance is SimTest):
			all_failures.append("%s :: does not extend SimTest" % path)
			suites_failed += 1
			continue

		var suite: SimTest = instance as SimTest
		var result: Dictionary = suite.run_all()
		var failures: Array = result["failures"] as Array
		total_tests += int(result["tests"])
		total_assertions += int(result["assertions"])

		var marker: String = "ok  " if failures.is_empty() else "FAIL"
		print("  [%s] %-46s %3d tests, %4d assertions" % [
			marker, result["suite"], int(result["tests"]), int(result["assertions"])
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
		quit(0)
		return

	print("FAILED — %d of %d suites, %d failed assertions" % [
		suites_failed, suite_paths.size(), all_failures.size()
	])
	print("")
	for failure: String in all_failures:
		print("  x %s" % failure)
	print("---------------------------------------------------------------\n")
	quit(1)


func _parse_filter() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			return arg.trim_prefix("--filter=")
	return ""


## Suites are collected directory by directory and sorted within each, so lint
## runs before unit tests and unit before integration — a structural violation is
## reported before the behavioural fallout it causes.
func _discover(filter: String) -> Array[String]:
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
			paths.append(dir_path.path_join(file_name))
	return paths
