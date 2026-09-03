class_name TestWeapons
extends RefCounted

## Weapon fixtures for tests, loading the same data files the game loads.
##
## Deliberately does not use the WeaponDatabase autoload: the simulation is meant to
## be constructible without a scene tree, and a test suite that needed an autoload
## would be quietly proving the opposite.

const GUN_DIR: String = "res://data/guns"
const AMMO_DIR: String = "res://data/ammo"

static var _solver: BallisticSolver = null
static var _tables: Dictionary = {}
static var _armory: Armory = null


## Shared across the whole test run: building it re-reads every gun and shell, and
## its range-table cache is what keeps the ballistics suites quick.
static func armory() -> Armory:
	if _armory == null:
		_armory = Armory.load_from(GUN_DIR, AMMO_DIR, config())
	return _armory


static func config() -> Dictionary:
	return JsonLoader.load_dict("res://data/config/ballistics.json")


static func solver() -> BallisticSolver:
	if _solver == null:
		_solver = BallisticSolver.from_config(config())
	return _solver


static func gun(gun_id: String) -> GunDef:
	return GunDef.parse(JsonLoader.load_dict(GUN_DIR.path_join("%s.json" % gun_id)), gun_id)


static func shell(shell_id: String) -> ShellDef:
	return ShellDef.parse(JsonLoader.load_dict(AMMO_DIR.path_join("%s.json" % shell_id)), shell_id)


## Range tables are cached across tests: building one takes a few hundred
## trajectories, and several suites want the same pairings.
static func range_table(gun_id: String, shell_id: String) -> RangeTable:
	var key: String = "%s|%s" % [gun_id, shell_id]
	if _tables.has(key):
		return _tables[key] as RangeTable
	var table: RangeTable = RangeTable.build(solver(), gun(gun_id), shell(shell_id), config())
	_tables[key] = table
	return table


## Fire at a stated elevation and report where the shell lands.
static func fire(gun_id: String, shell_id: String, elevation_deg: float
) -> BallisticSolver.TrajectoryResult:
	var g: GunDef = gun(gun_id)
	var s: ShellDef = shell(shell_id)
	return solver().solve_flight_from_height(
		s.muzzle_velocity_ms, deg_to_rad(elevation_deg), s.drag_over_mass(),
		g.muzzle_height_m, 0.05, 400.0)
