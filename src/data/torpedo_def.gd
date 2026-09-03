class_name TorpedoDef
extends RefCounted

## A torpedo: what it carries, how fast it runs, and how far.
##
## The warhead is what matters. A 490 kg Type 93 does roughly twice the structural
## damage of a 280 kg G7a, and no amount of torpedo defence makes that difference go
## away — it only decides how much of the ship the blast reaches.

class Setting extends RefCounted:
	var speed_ms: float = 20.0
	var range_m: float = 5000.0


var torpedo_id: String = ""
var display_name: String = ""
var nation: String = ""
var diameter_m: float = 0.533
var mass_kg: float = 1500.0
var warhead_kg: float = 300.0
var explosive: String = "tnt"

## Speed/range pairs. Torpedoes were set before launch, trading one against the other.
var settings: Array[Setting] = []

## Steam torpedoes left a track a lookout could see and a ship could comb. Oxygen and
## electric ones did not, which is most of why the Type 93 was so feared.
var wakeless: bool = false

var run_depth_m: float = 5.0
var arming_distance_m: float = 350.0
var notes: String = ""


## The fastest setting that still reaches `range_m`, or the longest-legged one if
## nothing does. This is the choice a torpedo officer actually makes.
func setting_for_range(range_m: float) -> Setting:
	var best: Setting = null
	for setting: Setting in settings:
		if setting.range_m < range_m:
			continue
		if best == null or setting.speed_ms > best.speed_ms:
			best = setting
	if best != null:
		return best
	# Out of reach at every setting: use the longest-ranged one so the caller can see
	# how far short it falls.
	for setting: Setting in settings:
		if best == null or setting.range_m > best.range_m:
			best = setting
	return best


func maximum_range() -> float:
	var furthest: float = 0.0
	for setting: Setting in settings:
		furthest = maxf(furthest, setting.range_m)
	return furthest


## Total energy in the warhead, in joules.
func warhead_energy(config: Dictionary) -> float:
	var table: Dictionary = config.get("explosiveEnergyMjPerKg", {}) as Dictionary
	var per_kg: float = float(table.get(explosive, table.get("default", 4.8)))
	return warhead_kg * per_kg * 1.0e6


static func parse(data: Dictionary, source_path: String = "<memory>") -> TorpedoDef:
	if data.is_empty():
		push_error("TorpedoDef: empty document (%s)" % source_path)
		return null
	var torpedo: TorpedoDef = TorpedoDef.new()
	torpedo.torpedo_id = str(data.get("id", source_path.get_file().get_basename()))
	torpedo.display_name = str(data.get("name", torpedo.torpedo_id))
	torpedo.nation = str(data.get("nation", ""))
	torpedo.diameter_m = float(data.get("diameterMm", 533.0)) * SimUnits.MM_TO_M
	torpedo.mass_kg = float(data.get("massKg", 1500.0))
	torpedo.warhead_kg = float(data.get("warheadKg", 300.0))
	torpedo.explosive = str(data.get("explosive", "tnt"))
	torpedo.wakeless = bool(data.get("wakeless", false))
	torpedo.run_depth_m = float(data.get("runDepthM", 5.0))
	torpedo.arming_distance_m = float(data.get("armingDistanceM", 350.0))
	torpedo.notes = str(data.get("notes", ""))

	for entry: Variant in data.get("settings", []) as Array:
		var raw: Dictionary = entry as Dictionary
		var setting: Setting = Setting.new()
		setting.speed_ms = SimUnits.knots_to_ms(float(raw.get("speedKn", 30.0)))
		setting.range_m = float(raw.get("rangeM", 5000.0))
		torpedo.settings.append(setting)
	if torpedo.settings.is_empty():
		var fallback: Setting = Setting.new()
		fallback.speed_ms = SimUnits.knots_to_ms(30.0)
		fallback.range_m = 5000.0
		torpedo.settings.append(fallback)
	return torpedo
