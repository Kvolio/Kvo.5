class_name TorpedoBatteryDef
extends RefCounted

## A ship's torpedo tubes: what they fire, where they are, and whether she has reloads.

var torpedo_id: String = ""
var reload_seconds: float = 0.0
var mounts: Array[TorpedoMountDef] = []


func total_tubes() -> int:
	var total: int = 0
	for mount: TorpedoMountDef in mounts:
		total += mount.tubes
	return total


func is_empty() -> bool:
	return mounts.is_empty() or torpedo_id.is_empty()


## Only the Japanese carried reloads and the power handling to use them; everyone else
## got one salvo and then had to go home.
func has_reloads() -> bool:
	return reload_seconds > 0.0


static func parse(data: Dictionary) -> TorpedoBatteryDef:
	var battery: TorpedoBatteryDef = TorpedoBatteryDef.new()
	battery.torpedo_id = str(data.get("torpedo", ""))
	battery.reload_seconds = float(data.get("reloadSeconds", 0.0))
	var raw: Array = data.get("mounts", []) as Array
	for i: int in raw.size():
		battery.mounts.append(TorpedoMountDef.parse(raw[i] as Dictionary, i))
	return battery
