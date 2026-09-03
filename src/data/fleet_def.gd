class_name FleetDef
extends RefCounted

## A force: divisions of ships, each in a formation.
##
## Fleets are data for the same reason ships are. A scenario names a fleet file, the
## file names ship files, and adding a new order of battle is adding a file — no engine
## code knows that Task Force 38 exists.

class Unit extends RefCounted:
	var spec_id: String = ""
	var display_name: String = ""
	var count: int = 1


class Division extends RefCounted:
	var division_id: String = ""
	var display_name: String = ""
	var shape: int = FormationSystem.Shape.COLUMN
	var spacing_m: float = 700.0
	## Where this division forms up, relative to the fleet's own position and heading:
	## +x ahead, +y to starboard. A screen ten kilometres ahead of the battle line is
	## stated here rather than computed, because where a division is stationed is a
	## decision somebody made.
	var station_m: Vector2 = Vector2.ZERO
	var units: Array[Unit] = []

	func total_ships() -> int:
		var total: int = 0
		for unit: Unit in units:
			total += unit.count
		return total


var fleet_id: String = ""
var display_name: String = ""
var nation: String = ""
var team: int = 0
var divisions: Array[Division] = []
var notes: String = ""


func total_ships() -> int:
	var total: int = 0
	for division: Division in divisions:
		total += division.total_ships()
	return total


static func parse(data: Dictionary, source_path: String = "") -> FleetDef:
	var fleet: FleetDef = FleetDef.new()
	fleet.fleet_id = str(data.get("id", source_path.get_file().get_basename()))
	fleet.display_name = str(data.get("name", fleet.fleet_id))
	fleet.nation = str(data.get("nation", ""))
	fleet.team = int(data.get("team", 0))
	fleet.notes = str(data.get("notes", ""))

	for entry: Variant in data.get("divisions", []) as Array:
		var source: Dictionary = entry as Dictionary
		var division: Division = Division.new()
		division.division_id = str(source.get("id", "division"))
		division.display_name = str(source.get("name", division.division_id))
		division.shape = FormationSystem.shape_from_string(str(source.get("formation", "column")))
		division.spacing_m = float(source.get("spacingM", 700.0))
		division.station_m = Serializer.array_to_vec2(source.get("stationM"), Vector2.ZERO)
		for ship_entry: Variant in source.get("ships", []) as Array:
			var ship: Dictionary = ship_entry as Dictionary
			var unit: Unit = Unit.new()
			unit.spec_id = str(ship.get("spec", ""))
			unit.display_name = str(ship.get("name", ""))
			unit.count = maxi(int(ship.get("count", 1)), 1)
			if not unit.spec_id.is_empty():
				division.units.append(unit)
		fleet.divisions.append(division)
	return fleet
