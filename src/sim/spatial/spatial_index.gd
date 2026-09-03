class_name SpatialIndex
extends RefCounted

## Spatial-query interface used by detection, AI, projectile proximity, torpedo
## interaction and effects.
##
## Nothing in the simulation may depend on a concrete implementation. Stage 0 ships
## `BruteForceIndex` (obviously correct, O(n) per query); Stage 9 substitutes
## `SpatialHashIndex` with no caller changes.
##
## CONTRACT — every implementation must honour this, and `test_spatial_index.gd`
## asserts it for all of them:
##   1. Query results are IDs sorted ascending. Not distance order, not insertion
##      order. An unordered result would leak the container's internal layout into
##      target selection and make outcomes implementation-dependent — exactly the
##      failure mode a swappable index invites.
##   2. Results are exact, not conservative. An index that returns extra candidates
##      "for the caller to filter" would give different answers per implementation.
##   3. Entities are treated as circles (position, radius) on the z=0 plane.

## Bit flags. Combine with `|` to build a query mask.
enum Layer {
	SHIP = 1,
	PROJECTILE = 2,
	TORPEDO = 4,
	AIRCRAFT = 8,
	ISLAND = 16,
}

const LAYER_ALL: int = 0x7FFFFFFF


func insert(_id: int, _position: Vector2, _radius: float, _layer: int) -> void:
	push_error("SpatialIndex.insert() is abstract")


func update(_id: int, _position: Vector2, _radius: float) -> void:
	push_error("SpatialIndex.update() is abstract")


func remove(_id: int) -> void:
	push_error("SpatialIndex.remove() is abstract")


func has(_id: int) -> bool:
	push_error("SpatialIndex.has() is abstract")
	return false


func clear() -> void:
	push_error("SpatialIndex.clear() is abstract")


func size() -> int:
	push_error("SpatialIndex.size() is abstract")
	return 0


## All entities whose circle overlaps the query circle. IDs ascending.
func query_radius(_centre: Vector2, _radius: float, _layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	push_error("SpatialIndex.query_radius() is abstract")
	return PackedInt32Array()


## All entities whose circle overlaps the rectangle. IDs ascending.
func query_aabb(_rect: Rect2, _layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	push_error("SpatialIndex.query_aabb() is abstract")
	return PackedInt32Array()


## All entities whose circle (grown by `pad`) is crossed by segment a->b.
## Used for line-of-sight blocking and projectile broadphase. IDs ascending.
func query_segment(_a: Vector2, _b: Vector2, _pad: float = 0.0, _layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	push_error("SpatialIndex.query_segment() is abstract")
	return PackedInt32Array()


## Shortest distance from point `p` to segment a->b. Shared by implementations so
## every index agrees on segment tests to the last bit.
static func distance_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq <= 0.0:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
