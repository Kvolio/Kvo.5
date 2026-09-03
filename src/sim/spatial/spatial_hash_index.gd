class_name SpatialHashIndex
extends SpatialIndex

## Spatial index with a uniform grid behind it.
##
## A drop-in for `BruteForceIndex`, and the reason the interface was written in Stage 0
## rather than being extracted now. Nothing in the simulation depends on which one it
## has: detection, projectile broadphase, torpedo interaction and the AI all go through
## `SpatialIndex`, and `test_spatial_index.gd` runs the same contract against both.
##
## The equivalence test is stricter than the contract. It asserts that the two return
## BYTE-IDENTICAL results over randomised workloads and that a whole battle fought with
## one is bit for bit the battle fought with the other — because an acceleration
## structure that is merely almost right produces a subtly different naval action, and
## a subtly different naval action is indistinguishable from a correct one until it
## matters.
##
## Entities that straddle several cells are stored in every cell they touch and
## de-duplicated on the way out, rather than being stored once by centre and searched
## for with a padded query. A battleship is 270 m long and a query radius of a
## kilometre is common, so "how far might a big entity reach into my cell" has no small
## answer — and getting it wrong loses hits rather than costing time, which is the
## worse failure.

## Side of a grid cell, metres. A few hundred metres puts a handful of ships in a cell
## at fleet-action densities while keeping a 20 km detection sweep to a few hundred cell
## lookups rather than a scan of everything afloat.
const DEFAULT_CELL_SIZE: float = 500.0

## How many cells a query may walk before it is cheaper to look at everything. Set from
## the measurement rather than from taste: a battlefield holds tens to low hundreds of
## entities, and touching a thousand mostly-empty dictionary entries to avoid a hundred
## distance checks is not a trade worth making.
const CELL_BUDGET: int = 400

var _cell_size: float = DEFAULT_CELL_SIZE

## Entity records, by id. The authority on what is in the index; the grid is only an
## acceleration structure over it.
var _positions: Dictionary = {}
var _radii: Dictionary = {}
var _layers: Dictionary = {}

## cell key -> PackedInt32Array of ids. Keys are packed from the cell coordinates.
var _cells: Dictionary = {}
## id -> the cell keys it currently occupies, so a move can leave them cleanly.
var _occupied: Dictionary = {}


func _init(cell_size: float = DEFAULT_CELL_SIZE) -> void:
	_cell_size = maxf(cell_size, 1.0)


func cell_size() -> float:
	return _cell_size


func insert(id: int, position: Vector2, radius: float, layer: int) -> void:
	if _positions.has(id):
		_unlink(id)
	_positions[id] = position
	_radii[id] = radius
	_layers[id] = layer
	_link(id, position, radius)


func update(id: int, position: Vector2, radius: float) -> void:
	if not _positions.has(id):
		return
	_unlink(id)
	_positions[id] = position
	_radii[id] = radius
	_link(id, position, radius)


func remove(id: int) -> void:
	if not _positions.has(id):
		return
	_unlink(id)
	_positions.erase(id)
	_radii.erase(id)
	_layers.erase(id)


func has(id: int) -> bool:
	return _positions.has(id)


func clear() -> void:
	_positions.clear()
	_radii.clear()
	_layers.clear()
	_cells.clear()
	_occupied.clear()


func size() -> int:
	return _positions.size()


# -- queries -------------------------------------------------------------------

func query_radius(centre: Vector2, radius: float, layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var seen: Dictionary = {}
	# The query circle grown by the largest entity radius in play, because an entity
	# whose centre is outside the circle can still overlap it.
	var reach: Rect2 = Rect2(centre - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
	for id: int in _candidates(reach, layer_mask, seen):
		var entity_radius: float = float(_radii[id])
		var span: float = radius + entity_radius
		if centre.distance_squared_to(_positions[id] as Vector2) <= span * span:
			out.append(id)
	out.sort()
	return out


func query_aabb(rect: Rect2, layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var seen: Dictionary = {}
	for id: int in _candidates(rect, layer_mask, seen):
		var entity_radius: float = float(_radii[id])
		if rect.grow(entity_radius).has_point(_positions[id] as Vector2):
			out.append(id)
	out.sort()
	return out


func query_segment(a: Vector2, b: Vector2, pad: float = 0.0,
		layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var seen: Dictionary = {}
	var bounds: Rect2 = Rect2(a, Vector2.ZERO).expand(b).grow(pad)
	for id: int in _candidates(bounds, layer_mask, seen):
		var reach: float = float(_radii[id]) + pad
		if SpatialIndex.distance_point_to_segment(_positions[id] as Vector2, a, b) <= reach:
			out.append(id)
	out.sort()
	return out


## Every id in the cells the rectangle touches, once each.
##
## Grown by the largest radius in the index so that a battleship whose centre is two
## cells away still turns up for a query that her hull reaches into. Tracking the
## largest radius rather than assuming one is what keeps that exact: a mixed fleet of
## destroyers and battleships would otherwise need a constant, and a constant would
## either be wasteful or wrong.
func _candidates(bounds: Rect2, layer_mask: int, seen: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var grown: Rect2 = bounds.grow(_largest_radius())
	var min_x: int = int(floor(grown.position.x / _cell_size))
	var min_y: int = int(floor(grown.position.y / _cell_size))
	var max_x: int = int(floor(grown.end.x / _cell_size))
	var max_y: int = int(floor(grown.end.y / _cell_size))

	# A query bigger than the grid is worth answering is answered by scanning instead.
	#
	# This is not a hedge, it is the measurement. A detection sweep asks for everything
	# within tens of kilometres — a radius comparable to the whole battlefield — and
	# walking a hundred by a hundred grid of mostly empty cells to answer it costs six
	# times what simply looking at every ship costs. Measured, not assumed: the first
	# version of this class had no fallback and made a sixty-ship action six times
	# SLOWER than brute force while returning identical results, which is the most
	# embarrassing kind of optimisation there is.
	#
	# Both paths are exact, so the answer does not depend on which one is taken.
	var spanned: int = (max_x - min_x + 1) * (max_y - min_y + 1)
	if spanned > CELL_BUDGET or spanned >= _positions.size() * 4:
		for id: int in _sorted_ids():
			if seen.has(id):
				continue
			seen[id] = true
			if (int(_layers[id]) & layer_mask) == 0:
				continue
			out.append(id)
		return out

	for cell_x: int in range(min_x, max_x + 1):
		for cell_y: int in range(min_y, max_y + 1):
			var bucket: Variant = _cells.get(_key(cell_x, cell_y))
			if bucket == null:
				continue
			for id: int in bucket as PackedInt32Array:
				if seen.has(id):
					continue
				seen[id] = true
				if (int(_layers[id]) & layer_mask) == 0:
					continue
				out.append(id)
	return out


## Ids in ascending order. Every query sorts its output anyway, but the scan path walks
## a Dictionary and the determinism rules say an outcome-affecting walk of one is sorted
## first — even where, as here, the sort at the end would have hidden it.
func _sorted_ids() -> Array[int]:
	return Serializer.sorted_int_keys(_positions)


var _largest: float = 0.0


## The largest radius currently in the index.
##
## Recomputed only when the entity that WAS the largest leaves, which for a naval action
## means almost never — ships are added at the start and radii do not change. Keeping a
## running maximum and never lowering it would be safe but would degrade to a brute-force
## scan the moment one large entity had ever existed.
func _largest_radius() -> float:
	return _largest


func _recompute_largest() -> void:
	_largest = 0.0
	for id: int in _radii.keys():  # determinism-ok: a maximum does not depend on order
		_largest = maxf(_largest, float(_radii[id]))


func _link(id: int, position: Vector2, radius: float) -> void:
	_largest = maxf(_largest, radius)
	var keys: PackedInt64Array = PackedInt64Array()
	var min_x: int = int(floor((position.x - radius) / _cell_size))
	var min_y: int = int(floor((position.y - radius) / _cell_size))
	var max_x: int = int(floor((position.x + radius) / _cell_size))
	var max_y: int = int(floor((position.y + radius) / _cell_size))
	for cell_x: int in range(min_x, max_x + 1):
		for cell_y: int in range(min_y, max_y + 1):
			var key: int = _key(cell_x, cell_y)
			var bucket: PackedInt32Array = _cells.get(key, PackedInt32Array())
			bucket.append(id)
			_cells[key] = bucket
			keys.append(key)
	_occupied[id] = keys


func _unlink(id: int) -> void:
	var keys: Variant = _occupied.get(id)
	if keys == null:
		return
	for key: int in keys as PackedInt64Array:
		var bucket: Variant = _cells.get(key)
		if bucket == null:
			continue
		var packed: PackedInt32Array = bucket as PackedInt32Array
		var at: int = packed.find(id)
		if at >= 0:
			packed.remove_at(at)
		if packed.is_empty():
			_cells.erase(key)
		else:
			_cells[key] = packed
	_occupied.erase(id)
	# The entity leaving may have been the largest one in the index.
	if _radii.has(id) and is_equal_approx(float(_radii[id]), _largest):
		_recompute_largest()


## Two cell coordinates as one key.
##
## The offset keeps negative coordinates distinct from positive ones — a battlefield is
## centred on the origin, so half of it has negative coordinates and a naive pack would
## collide the two halves.
static func _key(cell_x: int, cell_y: int) -> int:
	return (cell_x + 0x40000000) * 0x80000000 + (cell_y + 0x40000000)
