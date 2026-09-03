extends SceneTree

## What a big action costs, and where.
##
## Not a benchmark suite — a way of finding out which part of a slow tick is actually
## slow before optimising the wrong one, and of checking that an acceleration structure
## actually accelerates something.

const SHIPS_PER_SIDE: int = 30
const SECONDS: float = 60.0


func _initialize() -> void:
	var config: Dictionary = {}
	for name: String in ["sim", "physics", "ballistics", "structure", "damage",
			"torpedo", "fire_control", "detection", "ai"]:
		config[name] = JsonLoader.load_dict("res://data/config/%s.json" % name)
	var armory: Armory = Armory.load_from("res://data/guns", "res://data/ammo",
		config["ballistics"] as Dictionary)

	print("%d ships a side, %.0f simulated seconds\n" % [SHIPS_PER_SIDE, SECONDS])
	print("%-8s %10s %12s %12s %10s" % ["index", "ms total", "ms/tick", "x realtime", "checksum"])
	for index_name: String in ["brute", "hash"]:
		var sim: Dictionary = (config["sim"] as Dictionary).duplicate(true)
		sim["spatial"] = {"index": index_name, "cellSizeM": 500.0}
		var run_config: Dictionary = config.duplicate(true)
		run_config["sim"] = sim
		_run(index_name, run_config, armory)
	quit()


func _run(index_name: String, config: Dictionary, armory: Armory) -> void:
	var world: SimWorld = SimWorld.create(20260908, config)
	world.set_armory(armory)
	var line: Array[String] = ["uss_iowa", "uss_baltimore", "uss_cleveland",
		"uss_fletcher", "uss_gearing"]
	for team: int in 2:
		for i: int in SHIPS_PER_SIDE:
			var spec: ShipSpec = ShipSpecLoader.load_from_file(
				"res://data/ships/%s.json" % line[i % line.size()])
			var across: float = float(i / 5) * 1400.0
			var along: float = float(i % 5) * 900.0
			var ship: ShipEntity = world.add_ship(spec,
				Vector2((-14000.0 if team == 0 else 14000.0) + along,
					-6000.0 + across),
				0.0 if team == 0 else PI, team)
			ship.ai_controlled = true
			MovementSystem.order_speed(ship, SimUnits.knots_to_ms(24.0))

	var ticks: int = int(SECONDS * 60.0)
	var started: int = Time.get_ticks_usec()
	world.step_many(ticks)
	var elapsed_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	print("%-8s %10.0f %12.3f %12.1f %10d" % [index_name, elapsed_ms,
		elapsed_ms / float(ticks), (SECONDS * 1000.0) / maxf(elapsed_ms, 0.001),
		world.checksum()])
