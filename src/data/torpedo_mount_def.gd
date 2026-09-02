class_name TorpedoMountDef
extends RefCounted

## One bank of tubes.
##
## Beam-mounted banks train through a limited arc to their own side; centreline banks
## can fire to either beam but not ahead or astern. That constraint is why a destroyer
## torpedo attack is made by turning ACROSS the target's course rather than by
## charging straight at her — the tubes cannot be brought to bear head-on.

var mount_id: String = ""
var station: float = 0.0
var lateral: float = 0.0
var tubes: int = 4
var rest_bearing: float = 0.0
var train_min: float = -deg_to_rad(75.0)
var train_max: float = deg_to_rad(75.0)


func local_position(length_m: float, beam_m: float) -> Vector2:
	return Vector2(station * length_m, lateral * beam_m * 0.5)


func can_bear(relative_bearing: float) -> bool:
	var offset: float = SimUnits.angle_delta(rest_bearing, relative_bearing)
	return offset >= train_min and offset <= train_max


static func parse(data: Dictionary, index: int = 0) -> TorpedoMountDef:
	var mount: TorpedoMountDef = TorpedoMountDef.new()
	mount.mount_id = str(data.get("id", "TT%d" % index))
	mount.station = clampf(float(data.get("station", 0.0)), -0.5, 0.5)
	mount.lateral = clampf(float(data.get("lateral", 0.0)), -1.0, 1.0)
	mount.tubes = maxi(int(data.get("tubes", 4)), 1)
	mount.rest_bearing = deg_to_rad(float(data.get("restBearingDeg", 0.0)))
	var limits: Array = data.get("trainLimitsDeg", [-75.0, 75.0]) as Array
	if limits.size() >= 2:
		mount.train_min = deg_to_rad(float(limits[0]))
		mount.train_max = deg_to_rad(float(limits[1]))
	return mount
