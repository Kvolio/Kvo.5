class_name Armory
extends RefCounted

## Guns, shells and their range tables, in a form the simulation can hold directly.
##
## Lives in src/sim rather than behind the autoload because the simulation has to be
## constructible without a scene tree — that is what makes battles testable headless
## and reproducible. `WeaponDatabase` is a thin autoload wrapper around one of these
## for the game; tests build their own.
##
## Range tables are built on first request. Solving every gun against every shell it
## can fire would be wasted work: a destroyer action never needs Yamato's table.

var _guns: Dictionary = {}
var _shells: Dictionary = {}
var _gun_order: Array[String] = []
var _shell_order: Array[String] = []
var _torpedoes: Dictionary = {}
var _torpedo_order: Array[String] = []
var _range_tables: Dictionary = {}
var _solver: BallisticSolver = null
var _ballistics_config: Dictionary = {}


static func load_from(gun_dir: String, ammo_dir: String, ballistics_config: Dictionary,
		torpedo_dir: String = "res://data/torpedoes") -> Armory:
	var armory: Armory = Armory.new()
	armory._ballistics_config = ballistics_config
	armory._solver = BallisticSolver.from_config(ballistics_config)

	for path: String in JsonLoader.list_json_files(ammo_dir):
		var shell: ShellDef = ShellDef.parse(JsonLoader.load_dict(path), path)
		if shell != null:
			armory._shells[shell.shell_id] = shell
			armory._shell_order.append(shell.shell_id)

	for path: String in JsonLoader.list_json_files(torpedo_dir):
		var torpedo: TorpedoDef = TorpedoDef.parse(JsonLoader.load_dict(path), path)
		if torpedo != null:
			armory._torpedoes[torpedo.torpedo_id] = torpedo
			armory._torpedo_order.append(torpedo.torpedo_id)

	for path: String in JsonLoader.list_json_files(gun_dir):
		var gun: GunDef = GunDef.parse(JsonLoader.load_dict(path), path)
		if gun == null:
			continue
		armory._guns[gun.gun_id] = gun
		armory._gun_order.append(gun.gun_id)
		for shell_id: String in gun.ammunition:
			if not armory._shells.has(shell_id):
				push_warning("Armory: gun '%s' lists unknown shell '%s'" % [gun.gun_id, shell_id])
	return armory


func get_torpedo(torpedo_id: String) -> TorpedoDef:
	return _torpedoes.get(torpedo_id) as TorpedoDef


func torpedo_ids() -> Array[String]:
	return _torpedo_order.duplicate()


func solver() -> BallisticSolver:
	return _solver


func get_gun(gun_id: String) -> GunDef:
	return _guns.get(gun_id) as GunDef


func get_shell(shell_id: String) -> ShellDef:
	return _shells.get(shell_id) as ShellDef


func has_gun(gun_id: String) -> bool:
	return _guns.has(gun_id)


func gun_ids() -> Array[String]:
	return _gun_order.duplicate()


func shell_ids() -> Array[String]:
	return _shell_order.duplicate()


func gun_count() -> int:
	return _gun_order.size()


func shell_count() -> int:
	return _shell_order.size()


## The range table for a gun/shell pairing, solved on first request and cached.
func range_table(gun_id: String, shell_id: String) -> RangeTable:
	var key: String = "%s|%s" % [gun_id, shell_id]
	var cached: Variant = _range_tables.get(key)
	if cached != null:
		return cached as RangeTable

	var gun: GunDef = get_gun(gun_id)
	var shell: ShellDef = get_shell(shell_id)
	if gun == null or shell == null:
		push_error("Armory: cannot build a range table for '%s'" % key)
		return null

	var table: RangeTable = RangeTable.build(_solver, gun, shell, _ballistics_config)
	_range_tables[key] = table
	return table


## Force every table to be built. Not used in play, but useful for a loading screen
## and for measuring the cost.
func precompute_all_range_tables() -> int:
	var built: int = 0
	for gun_id: String in _gun_order:
		for shell_id: String in (get_gun(gun_id) as GunDef).ammunition:
			if _shells.has(shell_id):
				range_table(gun_id, shell_id)
				built += 1
	return built
