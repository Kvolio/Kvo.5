class_name GeometryPrimitives
extends RefCounted

## The two shapes a ship's internals are built from, and how a shell's path is
## intersected against them.
##
## Deliberately only two. Everything inside a ship — armour plates, shell plating,
## decks, bulkheads, compartments, turrets, machinery — reduces to either an ORIENTED
## RECTANGLE (a surface a shell can pass through) or an AXIS-ALIGNED BOX (a volume a
## shell can be inside). That keeps the tracer to two exact intersection routines
## instead of a special case per part, and it means adding a new kind of internal
## structure never touches the tracer.
##
## Crucially, a face and a volume are NOT the same thing and are not
## interchangeable. A compartment boundary is a volume edge; it is only an armour
## barrier if a plate has been placed there. That distinction is the whole reason a
## shell can cross six compartments and stop at the first plate.

enum FaceKind {
	ARMOR,      ## a real armour plate: resolved through the penetration model
	STRUCTURE,  ## plating, ordinary decks and bulkheads: resists little, but breaches and spalls
	HULL,       ## the outer envelope: entry and exit
}

enum VolumeKind {
	COMPARTMENT,
	COMPONENT,
}


## A finite plane a shell can strike.
##
## Stored as a centre, a normal and two in-plane axes with half-extents, which makes
## the ray test a plane solve plus two interval checks — and which lets a plate be
## inclined simply by tilting its normal, so an inclined belt needs no special code.
class Face extends RefCounted:
	var index: int = 0
	var kind: FaceKind = FaceKind.STRUCTURE
	var zone: String = ""

	var centre: Vector3 = Vector3.ZERO
	var normal: Vector3 = Vector3.RIGHT
	var axis_u: Vector3 = Vector3.FORWARD
	var axis_v: Vector3 = Vector3.UP
	var half_u: float = 1.0
	var half_v: float = 1.0

	var thickness_mm: float = 0.0
	var material_id: String = "structural_steel"

	## Accumulated deformation from earlier non-penetrating hits, 0-1. Raised by the
	## damage model; degrades this plate's resistance to later hits.
	var deformation: float = 0.0

	func area_m2() -> float:
		return 4.0 * half_u * half_v

	## Angle between an incoming direction and this plate's normal, in radians.
	##
	## Zero means a perpendicular strike; larger means a more glancing one. This is
	## the single most important quantity in the penetration model, because effective
	## thickness scales with its secant.
	func obliquity_to(direction: Vector3) -> float:
		var cosine: float = absf(direction.normalized().dot(normal))
		return acos(clampf(cosine, 0.0, 1.0))


## A box a shell can enter, cross and leave.
class Volume extends RefCounted:
	var index: int = 0
	var kind: VolumeKind = VolumeKind.COMPARTMENT
	var role: String = ""
	var label: String = ""
	var minimum: Vector3 = Vector3.ZERO
	var maximum: Vector3 = Vector3.ONE

	func centre() -> Vector3:
		return (minimum + maximum) * 0.5

	func size() -> Vector3:
		return maximum - minimum

	func volume_m3() -> float:
		var s: Vector3 = size()
		return maxf(s.x, 0.0) * maxf(s.y, 0.0) * maxf(s.z, 0.0)

	func contains(point: Vector3) -> bool:
		return (point.x >= minimum.x and point.x <= maximum.x
			and point.y >= minimum.y and point.y <= maximum.y
			and point.z >= minimum.z and point.z <= maximum.z)


## Ray against an oriented rectangle.
##
## Returns the distance along the ray, or -1.0 if it misses. `direction` need not be
## normalised, but distances are then in units of its length; the tracer always
## passes a unit vector.
static func ray_face(origin: Vector3, direction: Vector3, face: Face) -> float:
	var denominator: float = direction.dot(face.normal)
	if absf(denominator) < 1e-9:
		return -1.0  # travelling parallel to the plate: no strike, however close
	var t: float = (face.centre - origin).dot(face.normal) / denominator
	if t < 0.0:
		return -1.0  # behind the muzzle
	var offset: Vector3 = (origin + direction * t) - face.centre
	if absf(offset.dot(face.axis_u)) > face.half_u:
		return -1.0
	if absf(offset.dot(face.axis_v)) > face.half_v:
		return -1.0
	return t


## Ray against an axis-aligned box, by the slab method.
##
## Returns [t_enter, t_exit], or an empty array on a miss. A ray starting inside the
## box gives a negative t_enter, which the tracer treats as "already inside" rather
## than as a miss — the case that arises the moment a shell bursts in a compartment
## and its fragments start from within.
static func ray_volume(origin: Vector3, direction: Vector3, volume: Volume) -> Array:
	var t_near: float = -INF
	var t_far: float = INF

	for axis: int in 3:
		var d: float = direction[axis]
		var o: float = origin[axis]
		var lo: float = volume.minimum[axis]
		var hi: float = volume.maximum[axis]
		if absf(d) < 1e-9:
			if o < lo or o > hi:
				return []  # parallel to this slab and outside it
			continue
		var t1: float = (lo - o) / d
		var t2: float = (hi - o) / d
		if t1 > t2:
			var swap: float = t1
			t1 = t2
			t2 = swap
		t_near = maxf(t_near, t1)
		t_far = minf(t_far, t2)
		if t_near > t_far:
			return []

	if t_far < 0.0:
		return []  # the whole box is behind the origin
	return [t_near, t_far]


## Build a face from a centre, an outward normal and two in-plane axes.
##
## The axes are orthonormalised against the normal so a caller cannot accidentally
## produce a skewed "rectangle" that the intersection test would then misreport.
static func make_face(
	index: int, kind: FaceKind, zone: String,
	centre: Vector3, normal: Vector3, axis_u: Vector3,
	half_u: float, half_v: float,
	thickness_mm: float = 0.0, material_id: String = "structural_steel"
) -> Face:
	var face: Face = Face.new()
	face.index = index
	face.kind = kind
	face.zone = zone
	face.centre = centre
	face.normal = normal.normalized()
	var u: Vector3 = (axis_u - face.normal * axis_u.dot(face.normal))
	if u.length_squared() < 1e-12:
		u = face.normal.cross(Vector3.UP)
		if u.length_squared() < 1e-12:
			u = face.normal.cross(Vector3.RIGHT)
	face.axis_u = u.normalized()
	face.axis_v = face.normal.cross(face.axis_u).normalized()
	face.half_u = maxf(half_u, 0.0)
	face.half_v = maxf(half_v, 0.0)
	face.thickness_mm = thickness_mm
	face.material_id = material_id
	return face


static func make_volume(
	index: int, kind: VolumeKind, role: String, label: String,
	minimum: Vector3, maximum: Vector3
) -> Volume:
	var volume: Volume = Volume.new()
	volume.index = index
	volume.kind = kind
	volume.role = role
	volume.label = label
	volume.minimum = Vector3(minf(minimum.x, maximum.x), minf(minimum.y, maximum.y), minf(minimum.z, maximum.z))
	volume.maximum = Vector3(maxf(minimum.x, maximum.x), maxf(minimum.y, maximum.y), maxf(minimum.z, maximum.z))
	return volume
