class_name AircraftDef
extends RefCounted

## One type of carrier aircraft.
##
## Lives in `src/data/` with the other typed definitions rather than in `src/sim/air/`,
## because the data layer is shared: a ship's file, a gun's file and an aircraft's file
## are all loaded and validated the same way. What is isolated is the SIMULATION of
## aircraft, which is entirely under `src/sim/air/` and can be left unregistered.

enum Role {
	FIGHTER,
	DIVE_BOMBER,
	TORPEDO_BOMBER,
	SCOUT,
}

var aircraft_id: String = ""
var display_name: String = ""
var nation: String = ""
var year: int = 1942
var role: Role = Role.FIGHTER

var max_speed_ms: float = 100.0
var cruise_speed_ms: float = 70.0
var combat_radius_m: float = 400000.0
var ceiling_m: float = 8000.0
var crew: int = 1

## Defensive and offensive machine guns, summarised. Air combat is resolved between
## GROUPS rather than between individual aircraft, so what matters is how much fire a
## group can put out and take, not which gun is where.
var guns: int = 2
var gun_calibre_mm: float = 7.7

## 0 to 1. Agility decides who wins a turning fight; toughness decides how much fire an
## aircraft absorbs before it goes down. The Zero's pairing of the highest agility in
## the set with the lowest toughness is the whole story of the design.
var agility: float = 0.5
var toughness: float = 0.6

## How many aircraft a squadron puts up as one group.
var group_size: int = 9

## What it carries. Bombs are ordinary shells and aerial torpedoes are ordinary
## torpedoes — the naval core resolves both without knowing an aircraft was involved.
var bomb_id: String = ""
var torpedo_id: String = ""

## How the attack is delivered. A dive bomber's accuracy comes from the steepness of
## its dive; a torpedo bomber's survival comes from how briefly it has to fly straight.
var release_altitude_m: float = 500.0
var release_speed_ms: float = 60.0
var release_range_m: float = 800.0
var dive_angle_rad: float = deg_to_rad(65.0)

var notes: String = ""


func is_strike() -> bool:
	return role == Role.DIVE_BOMBER or role == Role.TORPEDO_BOMBER


func carries_torpedo() -> bool:
	return not torpedo_id.is_empty()


func carries_bomb() -> bool:
	return not bomb_id.is_empty()


static func role_from_string(text: String) -> Role:
	match text.to_lower():
		"fighter": return Role.FIGHTER
		"dive_bomber": return Role.DIVE_BOMBER
		"torpedo_bomber": return Role.TORPEDO_BOMBER
		"scout": return Role.SCOUT
	push_warning("AircraftDef: unknown role '%s'; treating as a fighter" % text)
	return Role.FIGHTER


static func parse(data: Dictionary, source_path: String = "") -> AircraftDef:
	var definition: AircraftDef = AircraftDef.new()
	definition.aircraft_id = str(data.get("id", source_path.get_file().get_basename()))
	definition.display_name = str(data.get("name", definition.aircraft_id))
	definition.nation = str(data.get("nation", ""))
	definition.year = int(data.get("year", 1942))
	definition.role = role_from_string(str(data.get("role", "fighter")))

	definition.max_speed_ms = SimUnits.knots_to_ms(float(data.get("maxSpeedKn", 200.0)))
	definition.cruise_speed_ms = SimUnits.knots_to_ms(float(data.get("cruiseSpeedKn", 140.0)))
	definition.combat_radius_m = float(data.get("combatRadiusKm", 400.0)) * 1000.0
	definition.ceiling_m = float(data.get("ceilingM", 8000.0))
	definition.crew = int(data.get("crew", 1))

	definition.guns = int(data.get("guns", 2))
	definition.gun_calibre_mm = float(data.get("gunCalibreMm", 7.7))
	definition.agility = clampf(float(data.get("agility", 0.5)), 0.0, 1.0)
	definition.toughness = clampf(float(data.get("toughness", 0.6)), 0.0, 1.0)
	definition.group_size = maxi(int(data.get("groupSize", 9)), 1)

	definition.bomb_id = str(data.get("bombId", ""))
	definition.torpedo_id = str(data.get("torpedoId", ""))
	definition.release_altitude_m = float(data.get("releaseAltitudeM", 500.0))
	definition.release_speed_ms = SimUnits.knots_to_ms(float(data.get("releaseSpeedKn", 120.0)))
	definition.release_range_m = float(data.get("releaseRangeM", 800.0))
	definition.dive_angle_rad = deg_to_rad(float(data.get("diveAngleDeg", 65.0)))
	definition.notes = str(data.get("notes", ""))
	return definition


static func load_all(directory: String) -> Dictionary:
	var out: Dictionary = {}
	for path: String in JsonLoader.list_json_files(directory):
		var definition: AircraftDef = parse(JsonLoader.load_dict(path), path)
		out[definition.aircraft_id] = definition
	return out
