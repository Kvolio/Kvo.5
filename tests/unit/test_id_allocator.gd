extends SimTest

## Entity IDs are the universal tie-break for ordering decisions, so they must be
## monotonic, never recycled, and stable across a save/load.


func suite_name() -> String:
	return "IdAllocator"


func test_ids_are_monotonic_and_start_above_zero() -> void:
	var alloc: IdAllocator = IdAllocator.new()
	eq(alloc.allocate(), 1, "first id")
	eq(alloc.allocate(), 2, "second id")
	eq(alloc.allocate(), 3, "third id")
	ne(IdAllocator.INVALID_ID, 1, "0 is reserved as the invalid/world id")


func test_ids_are_never_reused_after_a_round_trip() -> void:
	var alloc: IdAllocator = IdAllocator.new()
	for _i: int in 10:
		alloc.allocate()
	var saved: Dictionary = alloc.serialize()

	var restored: IdAllocator = IdAllocator.new()
	restored.deserialize(saved)
	eq(restored.allocate(), 11, "a reloaded battle continues the id sequence")


func test_start_value_is_clamped_above_the_invalid_id() -> void:
	eq(IdAllocator.new(0).allocate(), 1, "0 would collide with the world/invalid id")
	eq(IdAllocator.new(-5).allocate(), 1, "negative starts are clamped")
	eq(IdAllocator.new(500).allocate(), 500, "explicit start honoured")
