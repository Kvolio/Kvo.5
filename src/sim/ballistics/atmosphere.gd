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

## Resolution of the resampled lookup, in metres. The ISA varies smoothly enough that
## 50 m steps are exact to well inside the precision of the tabulated data itself.
const SAMPLE_STEP_M: float = 50.0
const SAMPLE_CEILING_M: float = 20000.0

var _altitudes: PackedFloat64Array = PackedFloat64Array()
var _densities: PackedFloat64Array = PackedFloat64Array()
var _sound_speeds: PackedFloat64Array = PackedFloat64Array()

# Uniformly resampled copies. `sample()` is called four times per projectile per tick
# — several million times in a fleet action — so it indexes an evenly spaced array
# rather than scanning the irregular one. Measured at roughly a third of the cost.
var _fast_density: PackedFloat64Array = PackedFloat64Array()
var _fast_sound: PackedFloat64Array = PackedFloat64Array()


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
	atmosphere._resample()
	return atmosphere


## Build the evenly spaced lookup from the irregular source table.
func _resample() -> void:
	var count: int = int(SAMPLE_CEILING_M / SAMPLE_STEP_M) + 1
	_fast_density.resize(count)
	_fast_sound.resize(count)
	for i: int in count:
		var altitude: float = float(i) * SAMPLE_STEP_M
		_fast_density[i] = _interpolate(_densities, altitude)
		_fast_sound[i] = _interpolate(_sound_speeds, altitude)


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


## Density and speed of sound together — the trajectory loop always needs both.
##
## Indexes the evenly spaced table directly instead of searching. This is the single
## hottest lookup in the simulation: four calls per projectile per tick, and a fleet
## action puts hundreds of projectiles in the air.
func sample(altitude: float) -> Vector2:
	var last: int = _fast_density.size() - 1
	if altitude <= 0.0:
		return Vector2(_fast_density[0], _fast_sound[0])
	var scaled: float = altitude / SAMPLE_STEP_M
	var index: int = int(scaled)
	if index >= last:
		return Vector2(_fast_density[last], _fast_sound[last])
	var t: float = scaled - float(index)
	return Vector2(
		_fast_density[index] + (_fast_density[index + 1] - _fast_density[index]) * t,
		_fast_sound[index] + (_fast_sound[index + 1] - _fast_sound[index]) * t)


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
