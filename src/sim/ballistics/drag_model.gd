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

var _machs: PackedFloat64Array = PackedFloat64Array()
var _coefficients: PackedFloat64Array = PackedFloat64Array()


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
	return model


func coefficient_at(mach: float) -> float:
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
