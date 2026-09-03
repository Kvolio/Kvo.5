class_name ShipIO
extends RefCounted

## Turning a ship design back into the document it was loaded from.
##
## The designer's save path, and the exact inverse of `ShipSpecLoader.parse()`. The
## schema is the same one `data/ships/*.json` uses — that is the point, and it is what
## §4 asks for: the engine cannot tell a player's design from a historical preset,
## because there is nothing to tell apart.
##
## Units are converted back on the way out. The simulation works in SI throughout, but
## the data files are authored in the units their sources use — shaft horsepower, knots,
## degrees — and a saved design that came out in metres per second would be a document
## no one could read next to the presets.
##
## What keeps this honest is `tests/unit/test_ship_io.gd`, which round-trips all
## seventeen presets: load, serialize, re-parse, and require the two specs to agree
## field for field. A serializer that quietly drops a field is the same bug as a copy
## that quietly drops a field, and the roster is a much better test of it than any
## document written by hand.

const SCHEMA_VERSION: int = 1


static func to_document(spec: ShipSpec) -> Dictionary:
	var document: Dictionary = {
		"schemaVersion": SCHEMA_VERSION,
		"id": spec.spec_id,
		"name": spec.display_name,
		"type": spec.ship_type,
		"year": spec.year,
		"crew": spec.crew,
		"hull": _hull(spec),
		"propulsion": _propulsion(spec),
		"manoeuvring": _manoeuvring(spec),
		"armament": _armament(spec),
		"armour": _armour(spec.armour),
	}
	# Optional identity fields are written only when they say something, so a design
	# built from scratch does not carry a row of empty strings.
	if not spec.ship_class.is_empty():
		document["class"] = spec.ship_class
	if not spec.nation.is_empty():
		document["nation"] = spec.nation
	if spec.is_custom:
		document["custom"] = true
	if spec.armour != null and spec.armour.has_torpedo_defence():
		document["torpedoDefence"] = {
			"depthM": spec.armour.torpedo_defence_depth_m,
			"layers": spec.armour.torpedo_defence_layers,
		}
	if not spec.aviation.is_empty():
		document["aviation"] = spec.aviation.duplicate(true)
	return document


static func _hull(spec: ShipSpec) -> Dictionary:
	var hull: Dictionary = {
		"form": spec.hull_form_id,
		"lengthM": spec.length_m,
		"beamM": spec.beam_m,
		"draftM": spec.draft_m,
		"displacementFullT": spec.displacement_t,
	}
	# Standard displacement is what makes fuel a figure rather than a residual, so it
	# is written whenever the design has one.
	if spec.standard_displacement_t > 0.0:
		hull["displacementStandardT"] = spec.standard_displacement_t
	return hull


static func _propulsion(spec: ShipSpec) -> Dictionary:
	return {
		"powerShp": spec.propulsion_power_w / SimUnits.SHP_TO_W,
		"maxSpeedKn": SimUnits.ms_to_knots(spec.max_speed_ms),
		"shafts": spec.shafts,
		"boilers": spec.boilers,
		"funnels": spec.funnels,
		"machineryType": spec.machinery_type,
		"asternPowerFraction": spec.astern_power_fraction,
		"maxSternwayFraction": spec.max_sternway_fraction,
	}


static func _manoeuvring(spec: ShipSpec) -> Dictionary:
	return {
		"tacticalDiameterLengths": spec.tactical_diameter_lengths,
		"maxRudderDeg": rad_to_deg(spec.max_rudder_rad),
		"rudderRateDegPerSec": rad_to_deg(spec.rudder_rate_rad_s),
		# Written explicitly even though the loader can derive it from length. A saved
		# design should reproduce the ship that was saved, not the ship the defaults
		# would have produced from her dimensions.
		"yawResponseTimeS": spec.yaw_response_time_s,
	}


static func _armament(spec: ShipSpec) -> Dictionary:
	var armament: Dictionary = {}
	if spec.main_battery != null:
		armament["main"] = _battery(spec.main_battery)
	if spec.secondary_battery != null:
		armament["secondary"] = _battery(spec.secondary_battery)
	if not spec.anti_air.is_empty():
		armament["antiAir"] = spec.anti_air.duplicate(true)
	if spec.torpedo_battery != null:
		armament["torpedoes"] = _torpedoes(spec.torpedo_battery)
	return armament


static func _battery(battery: BatteryDef) -> Dictionary:
	var mounts: Array = []
	for mount: MountDef in battery.mounts:
		mounts.append({
			"id": mount.mount_id,
			"station": mount.station,
			"lateral": mount.lateral,
			"guns": mount.guns,
			"restBearingDeg": rad_to_deg(mount.rest_bearing),
			"trainLimitsDeg": [rad_to_deg(mount.train_min), rad_to_deg(mount.train_max)],
		})
	return {"gun": battery.gun_id, "mounts": mounts}


static func _torpedoes(battery: TorpedoBatteryDef) -> Dictionary:
	var mounts: Array = []
	for mount: TorpedoMountDef in battery.mounts:
		mounts.append({
			"id": mount.mount_id,
			"station": mount.station,
			"lateral": mount.lateral,
			"tubes": mount.tubes,
			"restBearingDeg": rad_to_deg(mount.rest_bearing),
			"trainLimitsDeg": [rad_to_deg(mount.train_min), rad_to_deg(mount.train_max)],
		})
	return {
		"torpedo": battery.torpedo_id,
		"reloadSeconds": battery.reload_seconds,
		"mounts": mounts,
	}


static func _armour(scheme: ArmourSchemeDef) -> Dictionary:
	var armour: Dictionary = {}
	if scheme == null:
		return armour
	# Every zone, including the ones at zero: a scheme that says "no upper belt" is
	# making a statement about the design, and a reader comparing two designs wants to
	# see the zero rather than wonder whether it was forgotten.
	for zone: String in ArmourSchemeDef.ZONES:
		var plate: ArmourSchemeDef.Plate = scheme.plate(zone)
		var entry: Dictionary = {
			"thicknessMm": plate.thickness_mm,
			"material": plate.material_id,
		}
		if not is_zero_approx(plate.inclination_rad):
			entry["inclinationDeg"] = rad_to_deg(plate.inclination_rad)
		if plate.is_tapered():
			entry["lowerEdgeThicknessMm"] = plate.lower_edge_thickness_mm
		if not plate.note.is_empty():
			entry["_note"] = plate.note
		armour[zone] = entry
	return armour


## Write a design to `user://ships/`, where ShipDatabase will find it next time it
## reloads — which `save_custom` does for us.
static func save(spec: ShipSpec) -> bool:
	var document: Dictionary = to_document(spec)
	document["custom"] = true
	return ShipDatabase.save_custom(spec.spec_id, document)
