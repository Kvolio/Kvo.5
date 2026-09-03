class_name ArmourSchemeDef
extends RefCounted

## A ship's armour, zone by zone.
##
## Stage 3 turns this into actual geometry that a shell's path is intersected
## against. Here it is only the data: what each zone is made of, how thick, and how
## it is inclined.
##
## Inclination is measured from the vertical and is recorded per plate rather than
## assumed, because it cuts both ways. An inclined belt presents far more effective
## thickness to a flat trajectory at close range, and LESS to a shell plunging onto
## it from 30 km — which is exactly the trade the immunity-zone concept is about.

class Plate extends RefCounted:
	var zone: String = ""
	var thickness_mm: float = 0.0
	var material_id: String = "generic_homogeneous"
	var inclination_rad: float = 0.0
	var note: String = ""

	## Thickness at the plate's lower edge, where it tapers. Belts were thick at the
	## waterline and thin at the bottom, because the lower strake exists to stop shells
	## that fall short and travel on underwater rather than to resist a direct hit.
	## Defaults to the full thickness, so a scheme that states no taper is a slab.
	var lower_edge_thickness_mm: float = 0.0

	func is_armoured() -> bool:
		return thickness_mm > 0.0

	## True where the plate is meaningfully thinner at the bottom than at the top.
	func is_tapered() -> bool:
		return is_armoured() and lower_edge_thickness_mm < thickness_mm * 0.98

	func thickness_m() -> float:
		return thickness_mm * SimUnits.MM_TO_M

	func duplicate() -> Plate:
		var copy: Plate = Plate.new()
		copy.zone = zone
		copy.thickness_mm = thickness_mm
		copy.material_id = material_id
		copy.inclination_rad = inclination_rad
		copy.note = note
		copy.lower_edge_thickness_mm = lower_edge_thickness_mm
		return copy


## Zones every ship defines. Absent zones become zero-thickness plates rather than
## nulls, so the tracer never has to special-case a ship that has no upper belt.
const ZONES: Array[String] = [
	"belt", "upperBelt", "deckWeather", "deckMain", "deckSplinter",
	"turretFace", "turretSide", "turretRoof", "barbette", "conningTower",
	"bulkheadFore", "bulkheadAft", "torpedoBulkhead",
]

var plates: Dictionary = {}

## Depth of the layered underwater protection, outer plating to holding bulkhead.
var torpedo_defence_depth_m: float = 0.0
var torpedo_defence_layers: int = 1


func plate(zone: String) -> Plate:
	var found: Variant = plates.get(zone)
	if found != null:
		return found as Plate
	var empty: Plate = Plate.new()
	empty.zone = zone
	return empty


func thickness_mm(zone: String) -> float:
	return plate(zone).thickness_mm


## Total deck protection: weather deck, main armoured deck and splinter deck.
##
## Summed for reporting only. The tracer resolves each deck separately, because a
## shell that is stopped by the first one has done something very different from one
## that reaches the third.
func total_deck_mm() -> float:
	return thickness_mm("deckWeather") + thickness_mm("deckMain") + thickness_mm("deckSplinter")


func has_torpedo_defence() -> bool:
	return torpedo_defence_depth_m > 0.0


## A scheme that can be edited without touching the one it was copied from.
##
## The designer's whole job is to change these numbers. Sharing the plates by reference
## is safe only while nothing ever writes to them, and thickening the belt on a design
## based on Iowa would otherwise rewrite Iowa for the rest of the session.
func duplicate() -> ArmourSchemeDef:
	var copy: ArmourSchemeDef = ArmourSchemeDef.new()
	for zone: String in plates:
		copy.plates[zone] = (plates[zone] as Plate).duplicate()
	copy.torpedo_defence_depth_m = torpedo_defence_depth_m
	copy.torpedo_defence_layers = torpedo_defence_layers
	return copy


static func parse(armour: Dictionary, torpedo_defence: Dictionary) -> ArmourSchemeDef:
	var scheme: ArmourSchemeDef = ArmourSchemeDef.new()
	for zone: String in ZONES:
		var entry: Variant = armour.get(zone)
		var plate_def: Plate = Plate.new()
		plate_def.zone = zone
		if entry is Dictionary:
			var d: Dictionary = entry as Dictionary
			plate_def.thickness_mm = float(d.get("thicknessMm", 0.0))
			plate_def.material_id = str(d.get("material", "generic_homogeneous"))
			plate_def.inclination_rad = deg_to_rad(float(d.get("inclinationDeg", 0.0)))
			plate_def.note = str(d.get("_note", ""))
			plate_def.lower_edge_thickness_mm = float(
				d.get("lowerEdgeThicknessMm", plate_def.thickness_mm))
		scheme.plates[zone] = plate_def

	scheme.torpedo_defence_depth_m = float(torpedo_defence.get("depthM", 0.0))
	scheme.torpedo_defence_layers = maxi(int(torpedo_defence.get("layers", 1)), 1)
	return scheme
