extends SceneTree

## Measure hit rate against range, so fire-control quality can be calibrated against
## published figures rather than by inspection.
##
## Historical anchors this is aimed at:
##   ~5%  at 18-20 km  (radar-directed capital ship gunnery, WWII)
##   ~10-13% at 8-11 km (Washington vs Kirishima: ~9 of 75 at 7-8 km)
##   1-3% for optical fire at long range (Jutland, early-war night actions)

const RANGES: Array[float] = [8000.0, 12000.0, 18000.0, 24000.0]
const SEEDS: Array[int] = [11, 23, 37, 51]
const SECONDS: float = 240.0


static var _armory: Armory = null


## A zigzag: the standard wartime precaution, and the thing that makes a firing
## solution so much harder to hold than a range exercise suggests.
const ZIGZAG_PERIOD_S: float = 40.0
const ZIGZAG_AMPLITUDE_DEG: float = 25.0


func _initialize() -> void:
	var config: Dictionary = _config()
	_armory = Armory.load_from("res://data/guns", "res://data/ammo",
		config["ballistics"] as Dictionary)
	for manoeuvring: bool in [false, true]:
		print("\n%s" % ("MANOEUVRING TARGET (zigzagging, as in action)" if manoeuvring
			else "STEADY TARGET (a range exercise, not a battle)"))
		_sweep(config, manoeuvring)
	quit()


func _sweep(config: Dictionary, manoeuvring: bool) -> void:
	print("range_km  shells   hits   rate    first_hit_s  mean_err_m")
	for range_m: float in RANGES:
		var shells: int = 0
		var hits: int = 0
		var first_hit: float = -1.0
		var error_sum: float = 0.0
		var error_n: int = 0
		for seed_value: int in SEEDS:
			var result: Dictionary = _run(range_m, seed_value, config, manoeuvring)
			shells += int(result["shells"])
			hits += int(result["hits"])
			error_sum += float(result["errorSum"])
			error_n += int(result["errorN"])
			var t: float = float(result["firstHit"])
			if t >= 0.0 and (first_hit < 0.0 or t < first_hit):
				first_hit = t
		var rate: float = 0.0 if shells == 0 else 100.0 * float(hits) / float(shells)
		var mean_err: float = 0.0 if error_n == 0 else error_sum / float(error_n)
		print("%8.1f  %6d  %5d  %5.2f%%  %11.1f  %9.0f" % [
			range_m / 1000.0, shells, hits, rate, first_hit, mean_err])


func _run(range_m: float, seed_value: int, config: Dictionary,
		manoeuvring: bool) -> Dictionary:
	var world: SimWorld = SimWorld.create(seed_value, config)
	world.set_armory(_armory)

	var shooter_spec: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	var target_spec: ShipSpec = ShipSpecLoader.load_from_file("res://data/ships/uss_iowa.json")
	var shooter: ShipEntity = world.add_ship(shooter_spec, Vector2.ZERO, 0.0, 0)
	var target: ShipEntity = world.add_ship(target_spec, Vector2(0.0, range_m), 0.0, 1)
	MovementSystem.order_speed(shooter, SimUnits.knots_to_ms(25.0))
	MovementSystem.order_speed(target, SimUnits.knots_to_ms(25.0))
	shooter.target_id = target.id

	var shells: int = 0
	var hits: int = 0
	var first_hit: float = -1.0
	var error_sum: float = 0.0
	var error_n: int = 0
	var ticks: int = int(SECONDS * 60.0)

	for tick: int in ticks:
		if manoeuvring:
			# Both ships zigzag. The shooter's own alterations matter too: her plot is
			# solving from her own motion as well as the target's.
			var phase: float = float(tick) / 60.0 / ZIGZAG_PERIOD_S
			var leg: float = deg_to_rad(ZIGZAG_AMPLITUDE_DEG) * signf(sin(phase * TAU))
			MovementSystem.steer_to_heading(target, leg)
			MovementSystem.steer_to_heading(shooter, -leg)
		world.step()
		for event: SimEvent in world.events.events_this_tick():
			# Main battery only. The secondaries fire far faster and hit far more often
			# at short range, and averaging them together would flatter the model into
			# a hit rate no battleship's main armament ever achieved.
			if event.type == &"salvo_fired" and event.actor_id == shooter.id \
					and float(event.data.get("calibreMm", 0.0)) >= 200.0:
				shells += int(event.data.get("barrels", 0))
			elif event.type == &"shell_hit" and event.actor_id == shooter.id \
					and float(event.data.get("calibreMm", 0.0)) >= 200.0:
				hits += 1
				if first_hit < 0.0:
					first_hit = world.clock.elapsed()
		var plot: FireControlSolution = shooter.main_plot()
		if plot != null and plot.opened:
			error_sum += absf(plot.range_error_m + plot.ballistic_bias * range_m
				+ plot.spot_correction_m)
			error_n += 1
		# What is being measured is fire control, not survivability. A target that sinks
		# after three salvos would report the hit rate of the OPENING of an action —
		# before any spotting correction has been made — and call it the hit rate. So
		# she is put back on her feet and the run continues.
		#
		# The shooter's PLOT is put back too, and that part is not optional. A target
		# who goes down for one tick makes the fire-control system shut the solution,
		# exactly as checking fire does, and the next cycle opens a fresh one with a
		# fresh set of errors. Left alone, the probe would spend most of a long run
		# measuring opening salvos and would under-report the hit rate by a factor of
		# three. This was found by noticing that a straight duel between the same two
		# ships scored four times what the probe said.
		if not target.is_afloat():
			target.status = ShipEntity.Status.ACTIVE
			target.loss_reason = ""
			target.structure_state = ShipStructureState.create(
				world.structure_for(target), target.spec, world._structure_config)
			target.list_angle = 0.0
			target.trim_angle = 0.0
			MovementSystem.order_speed(target, SimUnits.knots_to_ms(25.0))
			for battery: StringName in [&"main", &"secondary"]:
				var held: FireControlSolution = shooter.plot_for(battery)
				if held != null:
					held.opened = true

	return {
		"shells": shells, "hits": hits, "firstHit": first_hit,
		"errorSum": error_sum, "errorN": error_n,
	}


func _config() -> Dictionary:
	return {
		"sim": JsonLoader.load_dict("res://data/config/sim.json"),
		"physics": JsonLoader.load_dict("res://data/config/physics.json"),
		"ballistics": JsonLoader.load_dict("res://data/config/ballistics.json"),
		"structure": JsonLoader.load_dict("res://data/config/structure.json"),
		"damage": JsonLoader.load_dict("res://data/config/damage.json"),
		"torpedo": JsonLoader.load_dict("res://data/config/torpedo.json"),
		"fire_control": JsonLoader.load_dict("res://data/config/fire_control.json"),
	}
