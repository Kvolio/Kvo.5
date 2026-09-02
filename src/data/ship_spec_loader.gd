class_name ShipSpecLoader
extends RefCounted

## Turns a ship JSON document into the ShipSpec the simulation runs on.
##
## This is the only place that knows the on-disk ship schema. A historical preset from
## data/ships/ and a player design from the ship designer go through exactly this
## path, which is what makes them indistinguishable to the combat engine (spec §4).
##
## Every number is coerced with int()/float() rather than trusted from typeof():
## Godot's JSON parser returns all numbers as doubles, integers included.
##
## Fields the simulation has not reached yet (armament, armour scheme, internal
## layout) are simply absent from the parse rather than stubbed, so a data file that
## already carries them is not rejected and does not silently half-load.

const CURRENT_SCHEMA_VERSION: int = 1
const HULL_FORM_DIR: String = "res://data/hullforms"

## Full-load displacement is what a ship fights at, so it is preferred over standard
## when both are given.
static func parse(data: Dictionary, source_path: String = "<memory>") -> ShipSpec:
	if data.is_empty():
		push_error("ShipSpecLoader: empty ship document (%s)" % source_path)
		return null

	var version: int = int(data.get("schemaVersion", 0))
	if version > CURRENT_SCHEMA_VERSION:
		push_error("ShipSpecLoader: %s is schema v%d; this build understands up to v%d"
			% [source_path, version, CURRENT_SCHEMA_VERSION])
		return null

	var spec: ShipSpec = ShipSpec.new()
	spec.spec_id = str(data.get("id", source_path.get_file().get_basename()))
	spec.display_name = str(data.get("name", spec.spec_id))
	spec.ship_class = str(data.get("class", ""))
	spec.nation = str(data.get("nation", ""))
	spec.ship_type = str(data.get("type", "destroyer"))
	spec.year = int(data.get("year", 1942))
	spec.is_custom = bool(data.get("custom", false))
	spec.crew = int(data.get("crew", 0))

	_parse_hull(spec, data.get("hull", {}) as Dictionary, source_path)
	_parse_propulsion(spec, data.get("propulsion", {}) as Dictionary)
	_parse_manoeuvring(spec, data.get("manoeuvring", {}) as Dictionary)

	spec.derive_defaults()
	return spec


static func _parse_hull(spec: ShipSpec, hull: Dictionary, source_path: String) -> void:
	spec.length_m = float(hull.get("lengthM", spec.length_m))
	spec.beam_m = float(hull.get("beamM", spec.beam_m))
	spec.draft_m = float(hull.get("draftM", spec.draft_m))

	var full_load: float = float(hull.get("displacementFullT", 0.0))
	var standard: float = float(hull.get("displacementStandardT", 0.0))
	if full_load > 0.0:
		spec.displacement_t = full_load
	elif standard > 0.0:
		spec.displacement_t = standard
	else:
		push_warning("ShipSpecLoader: %s gives no displacement; keeping the default" % source_path)

	spec.hull_form_id = str(hull.get("form", spec.hull_form_id))
	var form: Dictionary = load_hull_form(spec.hull_form_id)
	spec.hull_profile = HullGeometry.profile_from_array(form.get("profile", []) as Array)
	spec.vertical_fullness = float(form.get("verticalFullness", spec.vertical_fullness))


static func _parse_propulsion(spec: ShipSpec, propulsion: Dictionary) -> void:
	# Data files are authored in the units their sources use — shaft horsepower and
	# knots — and converted once, here, so the simulation only ever sees SI.
	if propulsion.has("powerShp"):
		spec.propulsion_power_w = SimUnits.shp_to_watts(float(propulsion["powerShp"]))
	elif propulsion.has("powerKw"):
		spec.propulsion_power_w = float(propulsion["powerKw"]) * 1000.0

	if propulsion.has("maxSpeedKn"):
		spec.max_speed_ms = SimUnits.knots_to_ms(float(propulsion["maxSpeedKn"]))

	spec.shafts = int(propulsion.get("shafts", spec.shafts))
	spec.astern_power_fraction = float(
		propulsion.get("asternPowerFraction", spec.astern_power_fraction))
	spec.max_sternway_fraction = float(
		propulsion.get("maxSternwayFraction", spec.max_sternway_fraction))


static func _parse_manoeuvring(spec: ShipSpec, manoeuvring: Dictionary) -> void:
	spec.tactical_diameter_lengths = float(
		manoeuvring.get("tacticalDiameterLengths", spec.tactical_diameter_lengths))
	if manoeuvring.has("maxRudderDeg"):
		spec.max_rudder_rad = deg_to_rad(float(manoeuvring["maxRudderDeg"]))
	if manoeuvring.has("rudderRateDegPerSec"):
		spec.rudder_rate_rad_s = deg_to_rad(float(manoeuvring["rudderRateDegPerSec"]))
	# Left at zero on purpose when unspecified: derive_defaults() then scales it from
	# the ship's length rather than applying a one-size-fits-all constant.
	spec.yaw_response_time_s = float(manoeuvring.get("yawResponseTimeS", 0.0))


static var _hull_form_cache: Dictionary = {}


## Hull forms are shared by many ships and never change at runtime, so they are read
## once and cached.
static func load_hull_form(form_id: String) -> Dictionary:
	if _hull_form_cache.has(form_id):
		return _hull_form_cache[form_id] as Dictionary
	var path: String = HULL_FORM_DIR.path_join("%s.json" % form_id)
	var form: Dictionary = JsonLoader.load_dict(path)
	if form.is_empty():
		push_warning("ShipSpecLoader: unknown hull form '%s'; using the generic warship form"
			% form_id)
	_hull_form_cache[form_id] = form
	return form


static func load_from_file(path: String) -> ShipSpec:
	return parse(JsonLoader.load_dict(path), path)
