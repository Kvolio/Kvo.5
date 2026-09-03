class_name FleetIo
extends RefCounted

## Loading fleets, and putting them on the water.
##
## Deployment is the interesting half. Ships are added in a fixed order — divisions in
## the order the file lists them, units in the order the division lists them — because
## entity ids are allocated as ships are added and the whole simulation's determinism
## rests on those ids. A fleet that deployed in a different order would be a different
## battle from the same file.

const FLEET_DIR: String = "res://data/fleets"


static func load_from_file(path: String) -> FleetDef:
	var data: Dictionary = JsonLoader.load_dict(path)
	if data.is_empty():
		push_error("FleetIo: could not load %s" % path)
		return null
	return FleetDef.parse(data, path)


static func load_all(directory: String = FLEET_DIR) -> Dictionary:
	var out: Dictionary = {}
	for path: String in JsonLoader.list_json_files(directory):
		var fleet: FleetDef = load_from_file(path)
		if fleet != null:
			out[fleet.fleet_id] = fleet
	return out


## Put a fleet on the water at `origin`, steering `heading`, and form it up.
##
## Returns every ship added, in the order they were added. Each division becomes a
## formation, so the ships hold station on one another from the first tick rather than
## being scattered into a line by the AI over the next several minutes.
static func deploy(world: SimWorld, fleet: FleetDef, origin: Vector2, heading: float,
		specs: Callable) -> Array[ShipEntity]:
	var deployed: Array[ShipEntity] = []
	for division: FleetDef.Division in fleet.divisions:
		var members: Array[ShipEntity] = []
		var station: Vector2 = origin + division.station_m.rotated(heading)

		# The stations are laid out before any ship is placed, so a division starts the
		# battle already in the shape the file asks for rather than being dragged into
		# it by the station-keeping over the next several minutes.
		var layout: FormationSystem.Formation = FormationSystem.Formation.new()
		layout.shape = division.shape
		layout.spacing_m = division.spacing_m
		layout.members.resize(division.total_ships())

		var index: int = 0
		for unit: FleetDef.Unit in division.units:
			for copy: int in unit.count:
				var spec: ShipSpec = specs.call(unit.spec_id) as ShipSpec
				if spec == null:
					push_warning("FleetIo: %s names unknown ship '%s'" % [
						fleet.fleet_id, unit.spec_id])
					continue
				var name_override: String = unit.display_name
				if unit.count > 1 and not name_override.is_empty():
					name_override = "%s %d" % [name_override, copy + 1]
				var berth: Vector2 = station + layout.station_offset(index).rotated(heading)
				var ship: ShipEntity = world.add_ship(
					spec, berth, heading, fleet.team, name_override)
				# A ship deployed as part of a fleet is fought by the AI. The player's
				# own ship is added separately and keeps her orders.
				ship.ai_controlled = true
				members.append(ship)
				deployed.append(ship)
				index += 1
		if members.size() > 1:
			world.add_formation("%s.%s" % [fleet.fleet_id, division.division_id],
				fleet.team, members, division.shape, division.spacing_m)
	return deployed
