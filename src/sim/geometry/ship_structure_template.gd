class_name ShipStructureTemplate
extends RefCounted

## The immutable internal geometry of a ship design: every plate, every compartment,
## every component, in ship-local coordinates.
##
## Shared by every ship of a design. Nothing here changes during a battle — plate
## deformation, flooding, fires and wrecked machinery all live in the per-ship
## `ShipStructureState`. That split is what keeps a twelve-destroyer squadron from
## building twelve identical copies of the same geometry, and it is what makes the
## tracer's inputs safe to read from anywhere.
##
## Coordinates: +X forward, +Y to starboard, +Z up. The origin is amidships on the
## centreline at the waterline, so `z` is height above the water and a negative `z`
## is below it — which is exactly the distinction flooding cares about.

var spec_id: String = ""

var faces: Array[GeometryPrimitives.Face] = []
var volumes: Array[GeometryPrimitives.Volume] = []

# -- derived levels, all in metres relative to the waterline ------------------
var keel_z: float = -5.0
var main_deck_z: float = 4.0
var armour_deck_z: float = 0.0
var superstructure_top_z: float = 8.0

## Where the bridge tower stands, in metres from amidships. Recorded because the
## directors and the radar sit ON it: a ship's main director is on top of her bridge,
## and placing the two independently put them beside each other on ships whose battery
## layout moved the superstructure.
var bridge_x: float = 0.0
var after_superstructure_x: float = 0.0
var length_m: float = 100.0
var beam_m: float = 12.0
var draft_m: float = 5.0

## Longitudinal extent of the armoured citadel, in station units (-0.5 .. +0.5).
var citadel_aft: float = -0.3
var citadel_fore: float = 0.3

## Local-space bounding box of the whole ship, as a volume the projectile system can
## ray-test against. One slab test rejects a shell that is merely passing nearby,
## which is most of them — without it, every tick a shell spends inside a ship's
## bounding circle would pay for a full trace against several hundred primitives.
var bounds: GeometryPrimitives.Volume = null

## Index of volumes by role, for the damage model to find magazines and machinery
## without walking every compartment.
var _by_role: Dictionary = {}

## Compartment adjacency, computed once. See neighbours().
var _adjacency: Array[PackedInt32Array] = []


## Which compartments touch which. Symmetric, so each pair is tested once.
func _build_adjacency() -> void:
	const TOLERANCE: float = 0.35
	_adjacency.clear()
	for _i: int in volumes.size():
		_adjacency.append(PackedInt32Array())
	for i: int in volumes.size():
		var a: GeometryPrimitives.Volume = volumes[i]
		if a.kind != GeometryPrimitives.VolumeKind.COMPARTMENT:
			continue
		for j: int in range(i + 1, volumes.size()):
			var b: GeometryPrimitives.Volume = volumes[j]
			if b.kind != GeometryPrimitives.VolumeKind.COMPARTMENT:
				continue
			if (a.minimum.x <= b.maximum.x + TOLERANCE and b.minimum.x <= a.maximum.x + TOLERANCE
					and a.minimum.y <= b.maximum.y + TOLERANCE and b.minimum.y <= a.maximum.y + TOLERANCE
					and a.minimum.z <= b.maximum.z + TOLERANCE and b.minimum.z <= a.maximum.z + TOLERANCE):
				_adjacency[i].append(j)
				_adjacency[j].append(i)


## Compartments sharing a boundary with this one.
##
## Precomputed, because adjacency is a property of the immutable geometry and does not
## change during a battle. Flooding and fire both ask this question every time they
## step, and computing it on the fly made them O(n^2) over a hundred-odd compartments
## per tick per ship — which measured as the single largest cost in a damaged fleet.
func neighbours(index: int) -> PackedInt32Array:
	if index < 0 or index >= _adjacency.size():
		return PackedInt32Array()
	return _adjacency[index]


## Recompute the bounding box and the compartment adjacency graph. Called once after
## the structure is built.
func seal() -> void:
	_build_adjacency()
	var minimum: Vector3 = Vector3(INF, INF, INF)
	var maximum: Vector3 = Vector3(-INF, -INF, -INF)
	for face: GeometryPrimitives.Face in faces:
		var extent: Vector3 = (face.axis_u.abs() * face.half_u) + (face.axis_v.abs() * face.half_v)
		minimum = minimum.min(face.centre - extent)
		maximum = maximum.max(face.centre + extent)
	for volume: GeometryPrimitives.Volume in volumes:
		minimum = minimum.min(volume.minimum)
		maximum = maximum.max(volume.maximum)
	if minimum.x > maximum.x:
		minimum = Vector3(-length_m * 0.5, -beam_m * 0.5, keel_z)
		maximum = Vector3(length_m * 0.5, beam_m * 0.5, superstructure_top_z)
	bounds = GeometryPrimitives.make_volume(
		-1, GeometryPrimitives.VolumeKind.COMPARTMENT, "bounds", "Hull bounds",
		minimum, maximum)


func add_face(face: GeometryPrimitives.Face) -> void:
	face.index = faces.size()
	faces.append(face)


func add_volume(volume: GeometryPrimitives.Volume) -> void:
	volume.index = volumes.size()
	volumes.append(volume)
	if not _by_role.has(volume.role):
		_by_role[volume.role] = PackedInt32Array()
	var list: PackedInt32Array = _by_role[volume.role]
	list.append(volume.index)
	_by_role[volume.role] = list


## Volume indices with the given role, ascending.
func volumes_with_role(role: String) -> PackedInt32Array:
	var found: Variant = _by_role.get(role)
	return found as PackedInt32Array if found != null else PackedInt32Array()


func roles() -> Array[String]:
	return Serializer.sorted_keys(_by_role)


func armour_faces() -> Array[GeometryPrimitives.Face]:
	var out: Array[GeometryPrimitives.Face] = []
	for face: GeometryPrimitives.Face in faces:
		if face.kind == GeometryPrimitives.FaceKind.ARMOR:
			out.append(face)
	return out


func total_internal_volume() -> float:
	var total: float = 0.0
	for volume: GeometryPrimitives.Volume in volumes:
		if volume.kind == GeometryPrimitives.VolumeKind.COMPARTMENT:
			total += volume.volume_m3()
	return total


## Thickest armour anywhere on the ship, for reporting and for the designer.
func maximum_armour_mm() -> float:
	var thickest: float = 0.0
	for face: GeometryPrimitives.Face in faces:
		if face.kind == GeometryPrimitives.FaceKind.ARMOR:
			thickest = maxf(thickest, face.thickness_mm)
	return thickest


## A short human summary, used by the inspector and the designer's validation panel.
func describe() -> String:
	var compartments: int = 0
	var components: int = 0
	for volume: GeometryPrimitives.Volume in volumes:
		if volume.kind == GeometryPrimitives.VolumeKind.COMPARTMENT:
			compartments += 1
		else:
			components += 1
	return "%d faces (%d armoured), %d compartments, %d components" % [
		faces.size(), armour_faces().size(), compartments, components]
