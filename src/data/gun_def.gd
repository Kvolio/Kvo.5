class_name GunDef
extends RefCounted

## A naval gun: what it fires, how far it can elevate, how fast it can shoot, and how
## tightly it groups.
##
## The gun and the shell are separate definitions on purpose. The same 5"/38 fires
## anti-aircraft common and armour-piercing; the same 2,700 lb Mark 8 shell is fired
## by both the 16"/45 and the 16"/50 at different velocities. Keeping them apart
## means adding a new loadout is a data edit, not a new gun.

var gun_id: String = ""
var display_name: String = ""
var nation: String = ""
var calibre_m: float = 0.1
var barrel_length_calibres: float = 45.0
var rate_of_fire_rpm: float = 2.0

var min_elevation_rad: float = 0.0
var max_elevation_rad: float = deg_to_rad(45.0)
var elevation_rate_rad_s: float = deg_to_rad(10.0)
var traverse_rate_rad_s: float = deg_to_rad(4.0)

## Height of the gun axis above the waterline. Gives flat trajectories a usable short
## range instead of putting the shell in the water on its first step.
var muzzle_height_m: float = 12.0

## One standard deviation as a fraction of range. Range dispersion always exceeds
## deflection: a salvo lands in a long thin ellipse along the line of fire, which is
## why straddles are common and hits are not.
var range_sigma: float = 0.003
var deflection_sigma: float = 0.0008

var ammunition: Array[String] = []
var notes: String = ""


func seconds_per_round() -> float:
	return 60.0 / maxf(rate_of_fire_rpm, 0.01)


## Barrel length in metres, from the naval convention of expressing it in calibres.
func barrel_length_m() -> float:
	return calibre_m * barrel_length_calibres


func can_elevate_to(elevation_rad: float) -> bool:
	return elevation_rad >= min_elevation_rad and elevation_rad <= max_elevation_rad


func default_ammunition() -> String:
	return ammunition[0] if not ammunition.is_empty() else ""


static func parse(data: Dictionary, source_path: String = "<memory>") -> GunDef:
	if data.is_empty():
		push_error("GunDef: empty document (%s)" % source_path)
		return null
	var gun: GunDef = GunDef.new()
	gun.gun_id = str(data.get("id", source_path.get_file().get_basename()))
	gun.display_name = str(data.get("name", gun.gun_id))
	gun.nation = str(data.get("nation", ""))
	gun.calibre_m = float(data.get("calibreMm", 100.0)) * SimUnits.MM_TO_M
	gun.barrel_length_calibres = float(data.get("barrelLengthCalibres", 45.0))
	gun.rate_of_fire_rpm = float(data.get("rateOfFireRpm", 2.0))
	gun.muzzle_height_m = float(data.get("muzzleHeightM", 12.0))

	var elevation: Dictionary = data.get("elevation", {}) as Dictionary
	gun.min_elevation_rad = deg_to_rad(float(elevation.get("minDeg", 0.0)))
	gun.max_elevation_rad = deg_to_rad(float(elevation.get("maxDeg", 45.0)))
	gun.elevation_rate_rad_s = deg_to_rad(float(elevation.get("rateDegPerSec", 10.0)))
	gun.traverse_rate_rad_s = deg_to_rad(float(data.get("traverseRateDegPerSec", 4.0)))

	var dispersion: Dictionary = data.get("dispersion", {}) as Dictionary
	# Authored as percentages because that is how gunnery trials report them.
	gun.range_sigma = float(dispersion.get("rangeSigmaPercent", 0.3)) * 0.01
	gun.deflection_sigma = float(dispersion.get("deflectionSigmaPercent", 0.08)) * 0.01

	for entry: Variant in data.get("ammunition", []) as Array:
		gun.ammunition.append(str(entry))
	gun.notes = str(data.get("notes", ""))
	return gun
