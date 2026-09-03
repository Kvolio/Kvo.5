class_name ScenarioDef
extends RefCounted

## A battle, described as data.
##
## A scenario names files and nothing else: fleets by id, ships by id, and the weather
## and the seed that decide how it goes. That is what makes it the unit a replay is
## built on — a recorded battle carries its scenario id, its seed and the player's
## orders, and replaying it means building the same world from the same file and
## feeding it the same orders. If a scenario carried the ships themselves, a replay
## would eventually disagree with the ship it was of.

class Force extends RefCounted:
	var team: int = 0
	var display_name: String = ""
	## Either a fleet id, or a list of individual ships. A fleet brings its own
	## divisions and formations; a list is for the small actions where every ship is
	## placed by hand.
	var fleet_id: String = ""
	var ships: Array = []              ## [{spec, name, positionM, headingDeg}]
	var position: Vector2 = Vector2.ZERO
	var heading_rad: float = 0.0
	var speed_knots: float = 20.0
	var player_controlled: bool = false


enum Victory {
	ANNIHILATION,   ## fight until one side has nothing left afloat and fighting
	SURVIVAL,       ## one side has only to last the clock out
	POINTS,         ## whoever has sunk more by the time limit
}

var scenario_id: String = ""
var display_name: String = ""
var description: String = ""
var seed_value: int = 0
var map_size: Vector2 = Vector2(60000.0, 60000.0)

# -- conditions ---------------------------------------------------------------
## Sea state costs pointing accuracy and costs it worst to the smallest ships; night
## and visibility decide what can be seen and how well the fall of shot can be spotted.
## All three reach the simulation by being written into its config, so a scenario is
## fought with the numbers it names.
var sea_state: float = 2.0
var night: bool = false
var visibility_factor: float = 1.0

var forces: Array[Force] = []
var victory: Victory = Victory.ANNIHILATION
var time_limit_s: float = 3600.0
var notes: String = ""


func team_count() -> int:
	var teams: Dictionary = {}
	for force: Force in forces:
		teams[force.team] = true
	return teams.size()


static func victory_from_string(text: String) -> Victory:
	match text.to_lower():
		"annihilation": return Victory.ANNIHILATION
		"survival": return Victory.SURVIVAL
		"points": return Victory.POINTS
	push_warning("ScenarioDef: unknown victory condition '%s'" % text)
	return Victory.ANNIHILATION


static func victory_to_string(value: Victory) -> String:
	match value:
		Victory.SURVIVAL: return "survival"
		Victory.POINTS: return "points"
	return "annihilation"


static func parse(data: Dictionary, source_path: String = "") -> ScenarioDef:
	var scenario: ScenarioDef = ScenarioDef.new()
	scenario.scenario_id = str(data.get("id", source_path.get_file().get_basename()))
	scenario.display_name = str(data.get("name", scenario.scenario_id))
	scenario.description = str(data.get("description", ""))
	scenario.seed_value = int(data.get("seed", 1))
	scenario.map_size = Serializer.array_to_vec2(data.get("mapSizeM"), scenario.map_size)
	scenario.notes = str(data.get("notes", ""))

	var conditions: Dictionary = data.get("conditions", {}) as Dictionary
	scenario.sea_state = float(conditions.get("seaState", 2.0))
	scenario.night = bool(conditions.get("night", false))
	scenario.visibility_factor = float(conditions.get("visibilityFactor", 1.0))

	var victory_data: Dictionary = data.get("victory", {}) as Dictionary
	scenario.victory = victory_from_string(str(victory_data.get("type", "annihilation")))
	scenario.time_limit_s = float(victory_data.get("timeLimitS", 3600.0))

	for entry: Variant in data.get("forces", []) as Array:
		var row: Dictionary = entry as Dictionary
		var force: Force = Force.new()
		force.team = int(row.get("team", 0))
		force.display_name = str(row.get("name", "Force %d" % force.team))
		force.fleet_id = str(row.get("fleet", ""))
		force.ships = (row.get("ships", []) as Array).duplicate(true)
		force.position = Serializer.array_to_vec2(row.get("positionM"), Vector2.ZERO)
		force.heading_rad = deg_to_rad(float(row.get("headingDeg", 0.0)))
		force.speed_knots = float(row.get("speedKn", 20.0))
		force.player_controlled = bool(row.get("player", false))
		scenario.forces.append(force)
	return scenario


func to_document() -> Dictionary:
	var force_data: Array = []
	for force: Force in forces:
		var row: Dictionary = {
			"team": force.team,
			"name": force.display_name,
			"positionM": Serializer.vec2_to_array(force.position),
			"headingDeg": rad_to_deg(force.heading_rad),
			"speedKn": force.speed_knots,
		}
		if not force.fleet_id.is_empty():
			row["fleet"] = force.fleet_id
		if not force.ships.is_empty():
			row["ships"] = force.ships.duplicate(true)
		if force.player_controlled:
			row["player"] = true
		force_data.append(row)

	return {
		"schemaVersion": 1,
		"id": scenario_id,
		"name": display_name,
		"description": description,
		"seed": seed_value,
		"mapSizeM": Serializer.vec2_to_array(map_size),
		"conditions": {
			"seaState": sea_state, "night": night, "visibilityFactor": visibility_factor,
		},
		"forces": force_data,
		"victory": {
			"type": victory_to_string(victory), "timeLimitS": time_limit_s,
		},
		"notes": notes,
	}
