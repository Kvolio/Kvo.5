class_name IdAllocator
extends RefCounted

## Monotonic entity-ID source.
##
## IDs are the tie-breaker for every ordering decision in the simulation (spatial
## query results, target selection, event dispatch), so they must be assigned in a
## reproducible order and must survive a save/load round trip. Never reuse an ID:
## a recycled ID would let a destroyed ship's identity be inherited by a later
## spawn and quietly corrupt replay logs.

const INVALID_ID: int = 0

var _next: int = 1


func _init(start_at: int = 1) -> void:
	_next = maxi(start_at, 1)


func allocate() -> int:
	var id: int = _next
	_next += 1
	return id


func peek_next() -> int:
	return _next


func serialize() -> Dictionary:
	return {"next": _next}


func deserialize(data: Dictionary) -> void:
	_next = maxi(int(data.get("next", 1)), 1)
