class_name HullGeometry
extends RefCounted

## The ship's plan-view shape, generated from its dimensions and a hull form.
##
## Ships are geometry, not stats. This class is where that starts: the outline it
## produces is what gets drawn, what a shell's trajectory is intersected against,
## and what the compartment layout is fitted inside. Change a design's beam in the
## ship designer and the silhouette, the target area presented to an enemy, and the
## internal volume available all change together, because they are all read from
## here.
##
## Local coordinates: +X is forward (bow), +Y is to starboard. The origin sits at
## midships on the centreline. Units are metres.
##
## A "hull form" is a normalised half-beam profile — a list of
## [station, half_beam_fraction] control points where station runs from -0.5 at the
## stern to +0.5 at the bow and half_beam_fraction is a fraction of maximum beam.
## The same profile scales to any hull, so a fine destroyer bow stays a fine bow at
## any length.

## Stations sampled per side when building the outline. Enough to keep a bow
## looking like a bow at close zoom without making intersection tests expensive.
const OUTLINE_STATIONS: int = 24

var length: float = 100.0
var beam: float = 10.0
var draft: float = 4.0

## Sorted [station, half_beam_fraction] control points.
var _profile: PackedVector2Array = PackedVector2Array()
var _outline: PackedVector2Array = PackedVector2Array()
var _bounding_radius: float = 0.0
var _waterplane_area: float = 0.0


static func default_profile() -> PackedVector2Array:
	# A generic warship, matching data/hullforms/heavy_cruiser.json: a waterplane
	# coefficient near 0.71, which is the middle of the real warship range. Only used
	# when a design supplies no hull form of its own; every ship in data/ships/ names
	# one explicitly.
	return PackedVector2Array([
		Vector2(-0.5000, 0.3800), Vector2(-0.4417, 0.5152), Vector2(-0.3833, 0.6237),
		Vector2(-0.3250, 0.7240), Vector2(-0.2667, 0.8193), Vector2(-0.2083, 0.9110),
		Vector2(-0.1500, 1.0000), Vector2(0.1000, 1.0000), Vector2(0.1667, 0.8487),
		Vector2(0.2333, 0.6943), Vector2(0.3000, 0.5359), Vector2(0.3667, 0.3720),
		Vector2(0.4333, 0.1994), Vector2(0.5000, 0.0000),
	])


static func create(
	p_length: float, p_beam: float, p_draft: float,
	p_profile: PackedVector2Array = PackedVector2Array()
) -> HullGeometry:
	var hull: HullGeometry = HullGeometry.new()
	hull.length = maxf(p_length, 1.0)
	hull.beam = maxf(p_beam, 0.5)
	hull.draft = maxf(p_draft, 0.1)
	hull._profile = p_profile if p_profile.size() >= 2 else default_profile()
	hull._rebuild()
	return hull


func _rebuild() -> void:
	_build_outline()
	_bounding_radius = 0.0
	for point: Vector2 in _outline:
		_bounding_radius = maxf(_bounding_radius, point.length())
	_waterplane_area = _compute_polygon_area(_outline)


## Half-beam in metres at a normalised station in [-0.5, 0.5].
##
## Linear interpolation between control points. Deliberately not a spline: linear
## segments make the outline's intersection tests exact and cheap, and a hull form
## is authored with enough control points that the difference is invisible.
func half_beam_at(station: float) -> float:
	var s: float = clampf(station, -0.5, 0.5)
	var count: int = _profile.size()
	if count == 0:
		return 0.0
	if s <= _profile[0].x:
		return _profile[0].y * beam * 0.5
	if s >= _profile[count - 1].x:
		return _profile[count - 1].y * beam * 0.5
	for i: int in range(count - 1):
		var a: Vector2 = _profile[i]
		var b: Vector2 = _profile[i + 1]
		if s >= a.x and s <= b.x:
			var span: float = b.x - a.x
			var t: float = 0.0 if span <= 0.0 else (s - a.x) / span
			return lerpf(a.y, b.y, t) * beam * 0.5
	return 0.0


func _build_outline() -> void:
	_outline = PackedVector2Array()
	# Starboard side, stern to bow.
	for i: int in OUTLINE_STATIONS + 1:
		var station: float = lerpf(-0.5, 0.5, float(i) / float(OUTLINE_STATIONS))
		_outline.append(Vector2(station * length, half_beam_at(station)))
	# Port side, bow back to stern, skipping the shared bow and stern points.
	for i: int in range(OUTLINE_STATIONS - 1, 0, -1):
		var station: float = lerpf(-0.5, 0.5, float(i) / float(OUTLINE_STATIONS))
		_outline.append(Vector2(station * length, -half_beam_at(station)))


## Closed polygon in ship-local metres, counter-clockwise from the stern.
func outline_local() -> PackedVector2Array:
	return _outline


## The outline transformed into world space.
func outline_world(position: Vector2, heading: float) -> PackedVector2Array:
	var transform: Transform2D = Transform2D(heading, position)
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(_outline.size())
	for i: int in _outline.size():
		out[i] = transform * _outline[i]
	return out


## Radius of the smallest circle at the origin containing the hull. Used as the
## broadphase radius in the spatial index.
func bounding_radius() -> float:
	return _bounding_radius


## Waterplane area in square metres.
func waterplane_area() -> float:
	return _waterplane_area


## Waterplane coefficient: waterplane area over the length x beam rectangle.
## Around 0.68-0.75 for a warship. Feeds the naval-architecture weight and
## stability calculations in Stage 6.
func waterplane_coefficient() -> float:
	var box: float = length * beam
	return 0.0 if box <= 0.0 else _waterplane_area / box


## Second moment of area of the waterplane about the centreline, in m^4.
##
## This is the `I` in `BM = I / V`, and it is what makes beam the cheapest stability
## there is: it goes as the CUBE of the local beam, integrated along the length.
##
## Computed from the hull's own stations rather than from a form coefficient, because a
## single coefficient cannot describe both a destroyer's fine waterplane and a
## battleship's full one — and getting it from the real shape is what makes a design's
## stability follow from its hull form instead of from its type.
func waterplane_inertia() -> float:
	# I = integral of b^3/12 dx over the length, with b = 2y the full beam at a station.
	var samples: int = OUTLINE_STATIONS * 2
	var total: float = 0.0
	for i: int in samples + 1:
		var station: float = lerpf(-0.5, 0.5, float(i) / float(samples))
		var half: float = half_beam_at(station)
		# Trapezoid rule: the end samples count half.
		var weight: float = 0.5 if (i == 0 or i == samples) else 1.0
		total += weight * pow(2.0 * half, 3.0) / 12.0
	return total * (length / float(samples))


## Approximate submerged volume, and hence displacement, from the waterplane area.
## The vertical fullness factor accounts for the hull narrowing towards the keel.
func estimated_displacement_tonnes(vertical_fullness: float = 0.85) -> float:
	var volume: float = _waterplane_area * draft * vertical_fullness
	return volume * SimUnits.SEAWATER_DENSITY * SimUnits.KG_TO_TONNE


func contains_local(point: Vector2) -> bool:
	var station: float = point.x / length
	if station < -0.5 or station > 0.5:
		return false
	return absf(point.y) <= half_beam_at(station)


func contains_world(point: Vector2, position: Vector2, heading: float) -> bool:
	return contains_local(Transform2D(heading, position).affine_inverse() * point)


## Shoelace formula. Sign is discarded — winding order is a construction detail.
static func _compute_polygon_area(polygon: PackedVector2Array) -> float:
	var count: int = polygon.size()
	if count < 3:
		return 0.0
	var total: float = 0.0
	for i: int in count:
		var a: Vector2 = polygon[i]
		var b: Vector2 = polygon[(i + 1) % count]
		total += a.x * b.y - b.x * a.y
	return absf(total) * 0.5


static func profile_from_array(data: Array) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	for entry: Variant in data:
		if entry is Array and (entry as Array).size() >= 2:
			var pair: Array = entry as Array
			out.append(Vector2(float(pair[0]), float(pair[1])))
	return out
