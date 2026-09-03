class_name BatteryDef
extends RefCounted

## A group of identical mounts firing the same gun: a main battery, or a secondary.

var gun_id: String = ""
var mounts: Array[MountDef] = []


func total_barrels() -> int:
	var total: int = 0
	for mount: MountDef in mounts:
		total += mount.guns
	return total


func is_empty() -> bool:
	return mounts.is_empty() or gun_id.is_empty()


## A copy that can be edited without touching the original. The designer needs this:
## a battery is only an immutable description of a design until somebody sets out to
## change it.
func duplicate() -> BatteryDef:
	var copy: BatteryDef = BatteryDef.new()
	copy.gun_id = gun_id
	for mount: MountDef in mounts:
		copy.mounts.append(mount.duplicate())
	return copy


static func parse(data: Dictionary) -> BatteryDef:
	var battery: BatteryDef = BatteryDef.new()
	battery.gun_id = str(data.get("gun", ""))
	var raw: Array = data.get("mounts", []) as Array
	for i: int in raw.size():
		battery.mounts.append(MountDef.parse(raw[i] as Dictionary, i))
	return battery
