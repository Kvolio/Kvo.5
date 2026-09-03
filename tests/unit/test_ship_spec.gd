extends SimTest

## Copying a design.
##
## Dull until you notice what it costs to get wrong: every ship in a battle arrives
## through `ShipDatabase.get_spec()`, which returns a duplicate, so a field the copy
## forgets is a field the game never has. Two were being dropped — the standard
## displacement and the funnel count — and nothing noticed, because the test fixtures
## load specs straight from file and never go near the copy.
##
## So the check here is reflective rather than a list of fields. A test that names the
## fields it compares can be forgotten in exactly the same way as the function it is
## testing; one that asks the object what fields it has cannot.

func suite_name() -> String:
	return "Ship spec"


## Every script variable on a ShipSpec, except the lazily-built hull cache.
func _field_names(spec: ShipSpec) -> Array[String]:
	var names: Array[String] = []
	for entry: Dictionary in spec.get_property_list():
		if int(entry.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var name: String = str(entry.get("name", ""))
		if name.begins_with("_"):
			continue
		names.append(name)
	return names


func test_a_copy_carries_every_field_the_original_has() -> void:
	var original: ShipSpec = TestShips.load_ship("uss_iowa")
	var copy: ShipSpec = original.duplicate_spec()
	var names: Array[String] = _field_names(original)
	gt(float(names.size()), 20.0, "a ship has a lot of fields, and they are all checked")
	for name: String in names:
		ok(_same(original.get(name), copy.get(name)),
			"%s survives being copied" % name)


func test_a_deep_copy_carries_every_field_too() -> void:
	var original: ShipSpec = TestShips.load_ship("ijn_kagero")
	var copy: ShipSpec = original.duplicate_spec(true)
	for name: String in _field_names(original):
		ok(_same(original.get(name), copy.get(name)),
			"%s survives a deep copy" % name)


## Values that are objects cannot be compared with `==` meaningfully, so those are
## checked for presence and the rest for equality.
func _same(a: Variant, b: Variant) -> bool:
	if a is Object or b is Object:
		return (a == null) == (b == null)
	return a == b


func test_the_two_fields_that_were_being_dropped() -> void:
	# Named explicitly as well, because these two were the bug and a regression here
	# should say what it is rather than "some field".
	var iowa: ShipSpec = TestShips.load_ship("uss_iowa")
	gt(iowa.standard_displacement_t, 0.0, "Iowa's data gives a standard displacement")
	gt(float(iowa.funnels), 0.0, "and a funnel count")
	eq(iowa.duplicate_spec().standard_displacement_t, iowa.standard_displacement_t,
		"the copy keeps her bunkerage figure")
	eq(iowa.duplicate_spec().funnels, iowa.funnels, "and her funnels")


# ------------------------------------------------------- shallow versus deep --

func test_a_shallow_copy_shares_armour_and_a_deep_one_does_not() -> void:
	var original: ShipSpec = TestShips.load_ship("uss_iowa")
	ok(original.duplicate_spec().armour == original.armour,
		"a battle shares the armour scheme, because it only ever reads it")
	ok(original.duplicate_spec(true).armour != original.armour,
		"the designer gets its own, because it is about to write to it")


func test_editing_a_deep_copy_leaves_the_original_alone() -> void:
	# The bug this exists for: thicken a belt on a design based on Iowa and Iowa herself
	# would have got the thicker belt for the rest of the session.
	var original: ShipSpec = TestShips.load_ship("uss_iowa")
	var before: float = original.armour.plate("belt").thickness_mm

	var design: ShipSpec = original.duplicate_spec(true)
	design.armour.plate("belt").thickness_mm = 900.0
	design.main_battery.mounts[0].station = 0.4
	design.main_battery.gun_id = "something_else"

	eq(original.armour.plate("belt").thickness_mm, before, "Iowa's belt is untouched")
	ne(original.main_battery.mounts[0].station, 0.4, "and her turret has not moved")
	ne(original.main_battery.gun_id, "something_else", "nor changed gun")


func test_a_deep_copy_of_a_torpedo_ship_owns_her_tubes() -> void:
	var original: ShipSpec = TestShips.load_ship("ijn_kagero")
	ok(original.has_torpedoes(), "a Kagero is defined by her tubes")
	var design: ShipSpec = original.duplicate_spec(true)
	design.torpedo_battery.mounts[0].tubes = 99
	ne(original.torpedo_battery.mounts[0].tubes, 99, "the original keeps hers")


func test_a_deep_copy_of_a_ship_with_no_secondary_battery_still_works() -> void:
	# Most destroyers have no secondary battery and no aviation, so the deep copy has
	# to cope with the fields simply not being there.
	var original: ShipSpec = TestShips.load_ship("uss_fletcher")
	var design: ShipSpec = original.duplicate_spec(true)
	eq(design.spec_id, original.spec_id, "she copies at all")
	ok(design.armour != null, "with an armour scheme, even a nearly empty one")
