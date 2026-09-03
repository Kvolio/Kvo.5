class_name BruteForceIndex
extends SpatialIndex

## Reference spatial index: linear scan, no acceleration structure.
##
## This is the correctness oracle. `SpatialHashIndex` (Stage 9) is tested by
## asserting it returns byte-identical results to this class over randomised
## workloads, so any acceleration bug shows up as a diff rather than as a subtly
## different battle.

var _ids: PackedInt32Array = PackedInt32Array()
var _positions: PackedVector2Array = PackedVector2Array()
var _radii: PackedFloat32Array = PackedFloat32Array()
var _layers: PackedInt32Array = PackedInt32Array()
var _slot_of_id: Dictionary = {}


func insert(id: int, position: Vector2, radius: float, layer: int) -> void:
	if _slot_of_id.has(id):
		update(id, position, radius)
		return
	_slot_of_id[id] = _ids.size()
	_ids.append(id)
	_positions.append(position)
	_radii.append(radius)
	_layers.append(layer)


func update(id: int, position: Vector2, radius: float) -> void:
	var slot: Variant = _slot_of_id.get(id)
	if slot == null:
		return
	var i: int = int(slot)
	_positions[i] = position
	_radii[i] = radius


func remove(id: int) -> void:
	var slot: Variant = _slot_of_id.get(id)
	if slot == null:
		return
	var i: int = int(slot)
	var last: int = _ids.size() - 1
	if i != last:
		# Swap-remove. Safe for determinism only because every query sorts its
		# output by ID before returning; internal order is never observable.
		_ids[i] = _ids[last]
		_positions[i] = _positions[last]
		_radii[i] = _radii[last]
		_layers[i] = _layers[last]
		_slot_of_id[_ids[i]] = i
	_ids.resize(last)
	_positions.resize(last)
	_radii.resize(last)
	_layers.resize(last)
	_slot_of_id.erase(id)


func has(id: int) -> bool:
	return _slot_of_id.has(id)


func clear() -> void:
	_ids.clear()
	_positions.clear()
	_radii.clear()
	_layers.clear()
	_slot_of_id.clear()


func size() -> int:
	return _ids.size()


func query_radius(centre: Vector2, radius: float, layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in _ids.size():
		if (_layers[i] & layer_mask) == 0:
			continue
		var reach: float = radius + _radii[i]
		if centre.distance_squared_to(_positions[i]) <= reach * reach:
			out.append(_ids[i])
	out.sort()
	return out


func query_aabb(rect: Rect2, layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in _ids.size():
		if (_layers[i] & layer_mask) == 0:
			continue
		var r: float = _radii[i]
		if rect.grow(r).has_point(_positions[i]):
			out.append(_ids[i])
	out.sort()
	return out


func query_segment(a: Vector2, b: Vector2, pad: float = 0.0, layer_mask: int = LAYER_ALL) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in _ids.size():
		if (_layers[i] & layer_mask) == 0:
			continue
		var reach: float = _radii[i] + pad
		if SpatialIndex.distance_point_to_segment(_positions[i], a, b) <= reach:
			out.append(_ids[i])
	out.sort()
	return out
