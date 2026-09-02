class_name PenetrationModelRegistry
extends RefCounted

## Chooses the penetration model from configuration.
##
## The indirection is the point. `data/config/ballistics.json` names a model by id;
## everything downstream holds a PenetrationModel and never knows which one it has.
## Adding a fuller analytical model later means writing the class and registering it
## here — HitResolver, DamageResolver, the tracer and every HitReport consumer stay
## exactly as they are.

static func create(config: Dictionary) -> PenetrationModel:
	var penetration: Dictionary = config.get("penetration", {}) as Dictionary
	var model_id: String = str(penetration.get("model", "de_marre"))
	match model_id:
		"de_marre":
			return DeMarreModel.from_config(penetration)
		_:
			push_error("PenetrationModelRegistry: unknown model '%s'; falling back to de_marre"
				% model_id)
			return DeMarreModel.from_config(penetration)


## Model ids this build can construct.
static func available_models() -> Array[String]:
	return ["de_marre"]
