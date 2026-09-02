class_name SimTest
extends RefCounted

## Zero-dependency test-suite base class.
##
## The project takes no runtime dependencies, so there is no GUT/gdUnit here.
## Subclass this, add methods named `test_*`, and the runner finds them.
##
## Test methods run in ALPHABETICAL order, not declaration order: `get_method_list()`
## reflects script layout, and a suite whose results depended on the order its
## methods happened to be written in would be a poor guardian of a simulation whose
## whole premise is order-independence.

var failures: Array[String] = []
var assertion_count: int = 0
var _current_test: String = ""


## Override: human-readable suite name.
func suite_name() -> String:
	return "unnamed suite"


## Override: run before each test method.
func before_each() -> void:
	pass


## Override: run after each test method.
func after_each() -> void:
	pass


func _test_method_names() -> Array[String]:
	var names: Array[String] = []
	for method: Dictionary in get_method_list():
		var name: String = str(method.get("name", ""))
		if name.begins_with("test_") and not names.has(name):
			names.append(name)
	names.sort()
	return names


func run_all() -> Dictionary:
	failures.clear()
	assertion_count = 0
	var names: Array[String] = _test_method_names()
	for name: String in names:
		_current_test = name
		before_each()
		call(name)
		after_each()
	return {
		"suite": suite_name(),
		"tests": names.size(),
		"assertions": assertion_count,
		"failures": failures.duplicate(),
	}


func _record(message: String) -> void:
	failures.append("%s :: %s — %s" % [suite_name(), _current_test, message])


# ---------------------------------------------------------------- assertions --

func fail(message: String) -> void:
	assertion_count += 1
	_record(message)


func ok(condition: bool, message: String) -> bool:
	assertion_count += 1
	if not condition:
		_record(message)
		return false
	return true


func not_ok(condition: bool, message: String) -> bool:
	return ok(not condition, message)


func eq(actual: Variant, expected: Variant, message: String) -> bool:
	assertion_count += 1
	if actual != expected:
		_record("%s (expected %s, got %s)" % [message, str(expected), str(actual)])
		return false
	return true


func ne(actual: Variant, unexpected: Variant, message: String) -> bool:
	assertion_count += 1
	if actual == unexpected:
		_record("%s (expected anything but %s)" % [message, str(unexpected)])
		return false
	return true


func almost(actual: float, expected: float, epsilon: float, message: String) -> bool:
	assertion_count += 1
	if absf(actual - expected) > epsilon:
		_record("%s (expected %f +/- %f, got %f)" % [message, expected, epsilon, actual])
		return false
	return true


func gt(actual: float, bound: float, message: String) -> bool:
	assertion_count += 1
	if not (actual > bound):
		_record("%s (expected > %f, got %f)" % [message, bound, actual])
		return false
	return true


func ge(actual: float, bound: float, message: String) -> bool:
	assertion_count += 1
	if not (actual >= bound):
		_record("%s (expected >= %f, got %f)" % [message, bound, actual])
		return false
	return true


func lt(actual: float, bound: float, message: String) -> bool:
	assertion_count += 1
	if not (actual < bound):
		_record("%s (expected < %f, got %f)" % [message, bound, actual])
		return false
	return true


func le(actual: float, bound: float, message: String) -> bool:
	assertion_count += 1
	if not (actual <= bound):
		_record("%s (expected <= %f, got %f)" % [message, bound, actual])
		return false
	return true


func between(actual: float, low: float, high: float, message: String) -> bool:
	assertion_count += 1
	if actual < low or actual > high:
		_record("%s (expected within [%f, %f], got %f)" % [message, low, high, actual])
		return false
	return true


func arrays_equal(actual: Variant, expected: Variant, message: String) -> bool:
	assertion_count += 1
	var a: Array = Array(actual)
	var b: Array = Array(expected)
	if a.size() != b.size():
		_record("%s (size %d != %d: %s vs %s)" % [message, a.size(), b.size(), str(a), str(b)])
		return false
	for i: int in a.size():
		if a[i] != b[i]:
			_record("%s (differ at index %d: %s vs %s)" % [message, i, str(a), str(b)])
			return false
	return true
