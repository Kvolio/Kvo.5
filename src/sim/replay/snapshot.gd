class_name Snapshot
extends RefCounted

## A complete picture of a battle, taken and put back.
##
## One serializer, three jobs: saving a battle in progress, rewinding a replay, and —
## the reason it can be trusted — the test that restores a snapshot, re-simulates from
## it, and requires the same checksum as the straight-through run. Anything that affects
## how the battle evolves and is not captured here shows up in that test as a
## divergence, which is a great deal better than showing up as a subtly different battle
## three minutes later.
##
## "Complete" is meant literally and includes the parts that are easy to forget: the
## position of every random number stream, the id allocator's counter, shells and
## torpedoes already in the air, each side's contact plot, each ship's gunnery solution
## and her captain's intentions. A snapshot that restored the ships but not the plots
## would produce a battle that looked identical for thirty seconds and then diverged.

const SCHEMA_VERSION: int = 1


## Take a snapshot of everything that decides what happens next.
static func capture(world: SimWorld) -> Dictionary:
	var ships: Array = []
	for ship: ShipEntity in world.ships:
		ships.append(ship.serialize())

	var projectiles: Array = []
	for projectile: Projectile in world.projectiles:
		if projectile.active:
			projectiles.append(projectile.serialize())

	var torpedoes: Array = []
	for torpedo: Torpedo in world.torpedoes:
		if torpedo.active:
			torpedoes.append(torpedo.serialize())

	var formations: Array = []
	for formation: FormationSystem.Formation in world.formations:
		formations.append(formation.serialize())

	return {
		"schemaVersion": SCHEMA_VERSION,
		"seed": world.get_seed(),
		"tick": world.clock.tick,
		"clock": world.clock.serialize(),
		"ids": world.ids.serialize(),
		"rng": world.rng.serialize(),
		"seaState": world.sea_state,
		"mapSize": Serializer.vec2_to_array(world.map_size),
		"ships": ships,
		"projectiles": projectiles,
		"torpedoes": torpedoes,
		"formations": formations,
		"contacts": [] if world.contacts == null else world.contacts.serialize(),
	}


## Put a battle back exactly as it was.
##
## The ships must already exist — a snapshot carries their state, not their designs,
## because a design is a file and duplicating it into every save would mean a save that
## disagreed with the ship it was of. `world` is expected to have been built from the
## same scenario; `ScenarioIo` is what guarantees that.
static func restore(world: SimWorld, data: Dictionary) -> bool:
	if int(data.get("schemaVersion", 0)) != SCHEMA_VERSION:
		push_error("Snapshot: schema v%d; this build understands v%d" % [
			int(data.get("schemaVersion", 0)), SCHEMA_VERSION])
		return false

	world.clock.deserialize(data.get("clock", {}) as Dictionary)
	world.rng.deserialize(data.get("rng", {}) as Dictionary)
	world.sea_state = float(data.get("seaState", world.sea_state))
	world.map_size = Serializer.array_to_vec2(data.get("mapSize"), world.map_size)

	var ship_data: Array = data.get("ships", []) as Array
	for entry: Variant in ship_data:
		var row: Dictionary = entry as Dictionary
		var ship: ShipEntity = world.get_ship(int(row.get("id", 0)))
		if ship == null:
			push_warning("Snapshot: no ship with id %d to restore into" % int(row.get("id", 0)))
			continue
		ship.deserialize(row)
		world.spatial.update(ship.id, ship.position, ship.spatial_radius())
	world.reassess_all()

	_restore_projectiles(world, data.get("projectiles", []) as Array)
	_restore_torpedoes(world, data.get("torpedoes", []) as Array)
	_restore_formations(world, data.get("formations", []) as Array)
	_restore_contacts(world, data.get("contacts", []) as Array)

	# The id allocator is restored LAST, on purpose. Putting shells and torpedoes back
	# goes through the ordinary spawn path, which allocates ids as it does so; setting
	# the counter first and then letting that happen would leave it several dozen ahead
	# of where the battle actually was, and the next shell fired would carry an id the
	# recording never issued. That is a one-line ordering mistake and it makes a
	# restored battle diverge on its first salvo.
	world.ids.deserialize(data.get("ids", {}) as Dictionary)
	return true


static func _restore_projectiles(world: SimWorld, rows: Array) -> void:
	for projectile: Projectile in world.projectiles:
		world.retire_projectile(projectile)
	world.projectiles.clear()
	if world.armory == null:
		return
	for entry: Variant in rows:
		var row: Dictionary = entry as Dictionary
		var shell: ShellDef = world.armory.get_shell(str(row.get("shell", "")))
		if shell == null:
			continue
		var gun: GunDef = world.armory.get_gun(str(row.get("gun", "")))
		var projectile: Projectile = world.spawn_projectile(shell, gun,
			Serializer.array_to_vec3(row.get("origin")),
			Serializer.array_to_vec3(row.get("velocity")),
			int(row.get("shooterId", 0)), int(row.get("targetId", 0)),
			int(row.get("team", 0)), StringName(str(row.get("battery", "main"))))
		# The pool hands back an id from the allocator; the snapshot's own id is the
		# one that matters, because a shell in the air has to keep its identity across
		# a save or the hit it produces belongs to a different projectile.
		projectile.id = int(row.get("id", projectile.id))
		projectile.position = Serializer.array_to_vec3(row.get("position"))
		projectile.time_alive = float(row.get("timeAlive", 0.0))


static func _restore_torpedoes(world: SimWorld, rows: Array) -> void:
	for torpedo: Torpedo in world.torpedoes:
		world.retire_torpedo(torpedo)
	world.torpedoes.clear()
	if world.armory == null:
		return
	for entry: Variant in rows:
		var row: Dictionary = entry as Dictionary
		var definition: TorpedoDef = world.armory.get_torpedo(str(row.get("torpedo", "")))
		if definition == null:
			continue
		var torpedo: Torpedo = world.spawn_torpedo(definition,
			Serializer.array_to_vec2(row.get("origin")),
			float(row.get("heading", 0.0)), float(row.get("speedMs", 20.0)),
			int(row.get("shooterId", 0)), int(row.get("targetId", 0)),
			int(row.get("team", 0)))
		torpedo.id = int(row.get("id", torpedo.id))
		torpedo.position = Serializer.array_to_vec2(row.get("position"))
		torpedo.distance_run = float(row.get("distanceRun", 0.0))


static func _restore_formations(world: SimWorld, rows: Array) -> void:
	world.formations.clear()
	for entry: Variant in rows:
		var row: Dictionary = entry as Dictionary
		var formation: FormationSystem.Formation = FormationSystem.Formation.new()
		formation.formation_id = str(row.get("id", ""))
		formation.team = int(row.get("team", 0))
		formation.guide_id = int(row.get("guideId", 0))
		formation.shape = int(row.get("shape", FormationSystem.Shape.COLUMN))
		formation.spacing_m = float(row.get("spacingM", 700.0))
		for member: Variant in row.get("members", []) as Array:
			formation.members.append(int(member))
		world.formations.append(formation)


static func _restore_contacts(world: SimWorld, rows: Array) -> void:
	if world.contacts == null:
		return
	world.contacts.clear()
	for entry: Variant in rows:
		world.contacts.restore(entry as Dictionary)
