class_name DragModel
extends RefCounted

## Drag coefficient as a function of Mach number.
##
## One curve shape is shared by every shell, and each shell scales it by its own
## form factor. That split is deliberate and physical: the transonic drag rise is a
## property of moving through air, while how much drag a particular projectile
## suffers depends on how sharply pointed it is and how good its ballistic cap was.
## Making the form factor per-shell is what lets a Type 91 with its long fine ogive
## out-range an American shell of higher sectional density, which it genuinely did.

## Resolution of the resampled lookup. The transonic rise is the sharpest feature in
## the curve and 0.01 Mach follows it closely.
const SAMPLE_STEP_MACH: float = 0.01
const SAMPLE_CEILING_MACH: float = 8.0

var _machs: PackedFloat64Array = PackedFloat64Array()
var _coefficients: PackedFloat64Array = PackedFloat64Array()

## Uniformly resampled copy, indexed rather than searched. See Atmosphere.sample().
var _fast: PackedFloat64Array = PackedFloat64Array()


static func from_config(config: Dictionary) -> DragModel:
	var model: DragModel = DragModel.new()
	var drag: Dictionary = config.get("drag", {}) as Dictionary
	for entry: Variant in drag.get("coefficientVsMach", []) as Array:
		if entry is Array and (entry as Array).size() >= 2:
			var pair: Array = entry as Array
			model._machs.append(float(pair[0]))
			model._coefficients.append(float(pair[1]))
	if model._machs.size() < 2:
		push_error("DragModel: curve missing or too short; using a flat coefficient")
		model._machs = PackedFloat64Array([0.0, 10.0])
		model._coefficients = PackedFloat64Array([0.30, 0.30])
	model._resample()
	return model


func _resample() -> void:
	var count: int = int(SAMPLE_CEILING_MACH / SAMPLE_STEP_MACH) + 1
	_fast.resize(count)
	for i: int in count:
		_fast[i] = _interpolate(float(i) * SAMPLE_STEP_MACH)


func _interpolate(mach: float) -> float:
	var count: int = _machs.size()
	if mach <= _machs[0]:
		return _coefficients[0]
	if mach >= _machs[count - 1]:
		return _coefficients[count - 1]
	for i: int in range(count - 1):
		if mach <= _machs[i + 1]:
			var span: float = _machs[i + 1] - _machs[i]
			var t: float = 0.0 if span <= 0.0 else (mach - _machs[i]) / span
			return lerpf(_coefficients[i], _coefficients[i + 1], t)
	return _coefficients[count - 1]


func coefficient_at(mach: float) -> float:
	var last: int = _fast.size() - 1
	if mach <= 0.0:
		return _fast[0]
	var scaled: float = mach / SAMPLE_STEP_MACH
	var index: int = int(scaled)
	if index >= last:
		return _fast[last]
	var t: float = scaled - float(index)
	return _fast[index] + (_fast[index + 1] - _fast[index]) * t
