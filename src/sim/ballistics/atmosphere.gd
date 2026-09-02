class_name Atmosphere
extends RefCounted

## Air density and speed of sound against altitude.
##
## Not a decoration on the ballistics. A 16-inch shell fired for 35 km reaches an
## apex above 6 km, where the air is barely half as thick as at sea level; treating
## the atmosphere as uniform shortens long-range trajectories by kilometres.
##
## Tabulated and interpolated rather than computed from the exponential barometric
## formula, for two reasons: the ISA is itself defined piecewise, and it keeps exp()
## out of the innermost loop of the simulation. Transcendental functions are not
## required by IEEE-754 to be correctly rounded, so they are exactly where two
## platforms would first disagree about where a shell landed.

var _altitudes: PackedFloat64Array = PackedFloat64Array()
var _densities: PackedFloat64Array = PackedFloat64Array()
var _sound_speeds: PackedFloat64Array = PackedFloat64Array()


static func from_config(config: Dictionary) -> Atmosphere:
	var atmosphere: Atmosphere = Atmosphere.new()
	var table: Dictionary = config.get("atmosphere", {}) as Dictionary
	atmosphere._altitudes = _to_floats(table.get("altitudeM", []))
	atmosphere._densities = _to_floats(table.get("densityKgM3", []))
	atmosphere._sound_speeds = _to_floats(table.get("speedOfSoundMs", []))
	if atmosphere._altitudes.size() < 2:
		push_error("Atmosphere: table missing or too short; falling back to sea level only")
		atmosphere._altitudes = PackedFloat64Array([0.0, 20000.0])
		atmosphere._densities = PackedFloat64Array([1.225, 1.225])
		atmosphere._sound_speeds = PackedFloat64Array([340.3, 340.3])
	return atmosphere


static func _to_floats(source: Variant) -> PackedFloat64Array:
	var out: PackedFloat64Array = PackedFloat64Array()
	if source is Array:
		for value: Variant in source as Array:
			out.append(float(value))
	return out


func density_at(altitude: float) -> float:
	return _interpolate(_densities, altitude)


func speed_of_sound_at(altitude: float) -> float:
	return _interpolate(_sound_speeds, altitude)


## Both values at once — the trajectory loop always needs both, and this halves the
## table search.
func sample(altitude: float) -> Vector2:
	var count: int = _altitudes.size()
	if altitude <= _altitudes[0]:
		return Vector2(_densities[0], _sound_speeds[0])
	if altitude >= _altitudes[count - 1]:
		return Vector2(_densities[count - 1], _sound_speeds[count - 1])
	for i: int in range(count - 1):
		if altitude <= _altitudes[i + 1]:
			var span: float = _altitudes[i + 1] - _altitudes[i]
			var t: float = 0.0 if span <= 0.0 else (altitude - _altitudes[i]) / span
			return Vector2(
				lerpf(_densities[i], _densities[i + 1], t),
				lerpf(_sound_speeds[i], _sound_speeds[i + 1], t)
			)
	return Vector2(_densities[count - 1], _sound_speeds[count - 1])


func _interpolate(values: PackedFloat64Array, altitude: float) -> float:
	var count: int = _altitudes.size()
	if altitude <= _altitudes[0]:
		return values[0]
	if altitude >= _altitudes[count - 1]:
		return values[count - 1]
	for i: int in range(count - 1):
		if altitude <= _altitudes[i + 1]:
			var span: float = _altitudes[i + 1] - _altitudes[i]
			var t: float = 0.0 if span <= 0.0 else (altitude - _altitudes[i]) / span
			return lerpf(values[i], values[i + 1], t)
	return values[count - 1]
