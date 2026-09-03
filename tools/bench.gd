extends SceneTree

## Rough timings for the simulation's hot paths. Not a benchmark suite — a way to
## find out which part of a slow tick is actually slow before optimising the wrong one.
func _initialize() -> void:
	var cfg := {
		"sim": JsonLoader.load_dict("res://data/config/sim.json"),
		"physics": JsonLoader.load_dict("res://data/config/physics.json"),
		"ballistics": JsonLoader.load_dict("res://data/config/ballistics.json"),
		"structure": JsonLoader.load_dict("res://data/config/structure.json"),
	}
	var armory := Armory.load_from("res://data/guns", "res://data/ammo", cfg["ballistics"])
	var solver := armory.solver()
	var shell := armory.get_shell("usa_16in50_ap_mk8")

	var t0 := Time.get_ticks_usec()
	var pos := Vector3(0, 0, 1000); var vel := Vector3(400, 0, 100)
	for i in 200000:
		var r: Array = solver.step(pos, vel, shell.drag_over_mass(), 1.0/60.0)
		pos = r[0]; vel = r[1]
		if pos.z < 0.0: pos = Vector3(0, 0, 1000); vel = Vector3(400, 0, 100)
	print("200k RK4 projectile steps      : %6.1f ms" % ((Time.get_ticks_usec()-t0)/1000.0))

	var spec := ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	var t1 := Time.get_ticks_usec()
	var structure := ShipStructureBuilder.build(spec, cfg["structure"])
	print("build Iowa structure           : %6.1f ms  (%s)" % [
		(Time.get_ticks_usec()-t1)/1000.0, structure.describe()])

	var materials := ArmourMaterials.load_from("res://data/materials/armor.json")
	var model := PenetrationModelRegistry.create(cfg["ballistics"])
	var ship := ShipEntity.create(1, spec, 0)
	var t2 := Time.get_ticks_usec()
	for i in 300:
		TrajectoryTracer.trace(shell, shell.penetration_k,
			Vector3(0, 400, 2), Vector3(0, -520, -60), ship, structure, materials, model, null)
	print("300 full traces                : %6.1f ms" % ((Time.get_ticks_usec()-t2)/1000.0))

	var world := SimWorld.create(1, cfg)
	world.set_armory(armory)
	var a := world.add_ship(spec, Vector2.ZERO, 0.0, 0)
	var b := world.add_ship(ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json"),
		Vector2(0, 18000), PI, 1)
	a.target_id = b.id; b.target_id = a.id
	MovementSystem.order_speed(a, 10.0); MovementSystem.order_speed(b, 10.0)
	world.step_many(3600)   # settle, get shells flying
	var t3 := Time.get_ticks_usec()
	world.step_many(6000)   # 100 simulated seconds
	var ms := (Time.get_ticks_usec()-t3)/1000.0
	print("6000 ticks, 2-ship gun action  : %6.1f ms  (%.3f ms/tick, %d shells aloft)" % [
		ms, ms/6000.0, world.projectiles.size()])
	print("  -> 400 s of action would take : %6.1f s" % (ms/6000.0*24000.0/1000.0))
	quit(0)
