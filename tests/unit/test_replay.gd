extends SimTest

## Scenarios, snapshots and replays.
##
## The two tests that matter are the round trips: a recorded battle must replay to the
## same checksum, and a battle restored from a snapshot must evolve exactly as the
## original did. Both are specifications rather than checks — anything that affects how
## a battle unfolds and is not captured shows up here as a divergence instead of as a
## subtly different battle three minutes later.


func suite_name() -> String:
	return "Replay and scenarios"


func _specs() -> Callable:
	return func(spec_id: String) -> ShipSpec: return TestShips.load_ship(spec_id)


func _scenario(scenario_id: String = "battleship_duel") -> ScenarioDef:
	var scenario: ScenarioDef = ScenarioIo.load_from_file(
		"res://data/scenarios/%s.json" % scenario_id)
	assert(scenario != null)
	return scenario


func _build(scenario: ScenarioDef) -> SimWorld:
	return ScenarioIo.build(scenario, TestShips.config(), TestWeapons.armory(), _specs())


# -- scenarios -----------------------------------------------------------------

func test_every_scenario_loads_and_names_things_that_exist() -> void:
	var scenarios: Dictionary = ScenarioIo.load_all()
	gt(float(scenarios.size()), 2.0, "there should be scenarios to fight")
	for scenario_id: String in Serializer.sorted_keys(scenarios):
		var scenario: ScenarioDef = scenarios[scenario_id]
		gt(float(scenario.forces.size()), 1.0, "%s needs at least two sides" % scenario_id)
		ge(float(scenario.team_count()), 2.0, "%s needs at least two teams" % scenario_id)
		gt(scenario.time_limit_s, 0.0, "%s needs a clock" % scenario_id)
		for force: ScenarioDef.Force in scenario.forces:
			if not force.fleet_id.is_empty():
				ok(FileAccess.file_exists("res://data/fleets/%s.json" % force.fleet_id),
					"%s names fleet '%s'" % [scenario_id, force.fleet_id])
			for entry: Variant in force.ships:
				var spec_id: String = str((entry as Dictionary).get("spec", ""))
				ok(FileAccess.file_exists("res://data/ships/%s.json" % spec_id),
					"%s names ship '%s'" % [scenario_id, spec_id])


func test_a_scenario_round_trips_through_a_document() -> void:
	for scenario_id: String in ["carrier_action", "night_destroyer_action"]:
		var original: ScenarioDef = _scenario(scenario_id)
		var reparsed: ScenarioDef = ScenarioDef.parse(original.to_document())
		eq(reparsed.scenario_id, original.scenario_id, "%s keeps its id" % scenario_id)
		eq(reparsed.seed_value, original.seed_value, "and its seed")
		eq(reparsed.night, original.night, "and whether it is dark")
		almost(reparsed.sea_state, original.sea_state, 0.001, "and the sea it is fought in")
		eq(reparsed.forces.size(), original.forces.size(), "and every force")
		for i: int in original.forces.size():
			eq(reparsed.forces[i].team, original.forces[i].team, "with the same sides")
			eq(reparsed.forces[i].fleet_id, original.forces[i].fleet_id, "and the same fleets")
			almost(reparsed.forces[i].heading_rad, original.forces[i].heading_rad, 0.0001,
				"on the same courses")


func test_the_weather_reaches_the_systems_that_care() -> void:
	# A scenario does not hand the weather to the systems separately; it writes it into
	# the config they already read, so a battle fought at night is one whose detection
	# config says night.
	var night: ScenarioDef = _scenario("night_destroyer_action")
	var config: Dictionary = ScenarioIo.configure(night, TestShips.config())
	var detection: Dictionary = (config["detection"] as Dictionary)["conditions"]
	var gunnery: Dictionary = (config["fire_control"] as Dictionary)["conditions"]
	ok(bool(detection["night"]), "a night action should be dark to the lookouts")
	not_ok(bool(gunnery["opticalUsable"]),
		"and the rangefinders should be useless, which is why radar decided these")

	var day: Dictionary = ScenarioIo.configure(_scenario("battleship_duel"), TestShips.config())
	ok(bool((day["fire_control"] as Dictionary)["conditions"]["opticalUsable"]),
		"a clear day should not")


func test_a_scenario_builds_the_same_world_twice() -> void:
	var scenario: ScenarioDef = _scenario("night_destroyer_action")
	var a: SimWorld = _build(scenario)
	var b: SimWorld = _build(scenario)
	eq(a.ships.size(), b.ships.size(), "the same ships")
	eq(a.checksum(), b.checksum(), "in the same state")
	a.step_many(60 * 30)
	b.step_many(60 * 30)
	eq(a.checksum(), b.checksum(), "and the same battle thirty seconds in")


# -- snapshots -----------------------------------------------------------------

func test_a_snapshot_restored_re_simulates_identically() -> void:
	# The specification of "complete". Run a battle to the halfway point, snapshot it,
	# run it to the end, then build a fresh world from the same scenario, restore the
	# snapshot into it and run the second half again. The two must agree exactly.
	var scenario: ScenarioDef = _scenario("battleship_duel")
	var straight: SimWorld = _build(scenario)
	straight.step_many(60 * 60)
	var snapshot: Dictionary = Snapshot.capture(straight)
	var mid_checksum: int = straight.checksum()
	straight.step_many(60 * 60)
	var final_checksum: int = straight.checksum()

	var restored: SimWorld = _build(scenario)
	ok(Snapshot.restore(restored, snapshot), "the snapshot should restore")
	eq(restored.checksum(), mid_checksum,
		"a restored battle is the battle it was taken from")
	restored.step_many(60 * 60)
	eq(restored.checksum(), final_checksum,
		"and evolves the same way — anything not captured shows up here")


func test_a_snapshot_carries_the_things_that_are_easy_to_forget() -> void:
	var scenario: ScenarioDef = _scenario("battleship_duel")
	var world: SimWorld = _build(scenario)
	world.step_many(60 * 90)
	var snapshot: Dictionary = Snapshot.capture(world)

	gt(float((snapshot["ships"] as Array).size()), 1.0, "the ships")
	ok((snapshot["rng"] as Dictionary).size() > 0,
		"the position of every random number stream — without it the very next "
		+ "dispersion draw is a different one")
	ok(snapshot.has("ids"), "the id allocator, so a restored shell is not given an id "
		+ "that already belongs to something")
	var first_ship: Dictionary = (snapshot["ships"] as Array)[0]
	ok(first_ship.has("structure"), "each ship's own damage")
	ok(first_ship.has("fireControl"), "and her gunnery solution — a battle whose plots "
		+ "were rebuilt would have both sides re-finding an enemy they had been "
		+ "tracking for ten minutes")


func test_shells_in_the_air_survive_a_snapshot() -> void:
	var scenario: ScenarioDef = _scenario("battleship_duel")
	var world: SimWorld = _build(scenario)
	# Run until there is something in the air worth saving.
	for _i: int in 60 * 240:
		world.step()
		if world.projectiles.size() >= 3:
			break
	gt(float(world.projectiles.size()), 2.0, "there should be shells in flight")

	var aloft: int = world.projectiles.size()
	var snapshot: Dictionary = Snapshot.capture(world)
	var restored: SimWorld = _build(scenario)
	ok(Snapshot.restore(restored, snapshot), "the snapshot should restore")
	eq(restored.projectiles.size(), aloft,
		"a shell in the air is part of the battle and has to survive a save")
	eq(restored.checksum(), world.checksum(), "with its own position and velocity")


# -- replays -------------------------------------------------------------------

func test_a_recorded_battle_replays_to_the_same_checksum() -> void:
	var scenario: ScenarioDef = _scenario("battleship_duel")
	var world: SimWorld = _build(scenario)
	var recorder: ReplayRecorder = ReplayRecorder.start(
		world, scenario.scenario_id, TestShips.config())

	# A few orders from outside, so the log has something in it. This is the only
	# route by which anything outside the simulation may change it, which is what
	# makes four kilobytes enough to describe a battle.
	world.commands.submit_new(SimWorld.CMD_SET_SPEED_KNOTS, 60, world.ships[0].id,
		{"value": 18.0})
	world.commands.submit_new(SimWorld.CMD_STEER_HEADING, 600, world.ships[0].id,
		{"value": deg_to_rad(40.0)})
	world.commands.submit_new(SimWorld.CMD_SET_SPEED_KNOTS, 1800, world.ships[1].id,
		{"value": 30.0})

	for _i: int in 60 * 120:
		world.step()
		recorder.observe(world)
	recorder.stop()
	var recorded: int = world.checksum()
	var document: Dictionary = recorder.to_document(world)

	var playback: ReplayRecorder = ReplayRecorder.from_document(document)
	eq(playback.header.seed_value, scenario.seed_value, "the replay carries the seed")
	eq(playback.commands.size(), 3, "and every order that was given")

	var replayed: SimWorld = _build(scenario)
	var diverged: int = playback.replay_into(replayed)
	eq(diverged, -1, "a replay must not diverge; tick %d is where it did" % diverged)
	eq(replayed.checksum(), recorded, "and must end in the same state")


func test_a_replay_notices_when_it_diverges() -> void:
	# The checksums are not decoration. A replay that quietly produced a different
	# battle would be worse than no replay at all, so this asserts that the mechanism
	# catches a deliberate corruption.
	var scenario: ScenarioDef = _scenario("battleship_duel")
	var world: SimWorld = _build(scenario)
	var recorder: ReplayRecorder = ReplayRecorder.start(
		world, scenario.scenario_id, TestShips.config())
	for _i: int in 60 * 30:
		world.step()
		recorder.observe(world)
	recorder.stop()
	var document: Dictionary = recorder.to_document(world)

	var playback: ReplayRecorder = ReplayRecorder.from_document(document)
	# One order that was never given during the recording.
	playback.commands.append(SimCommand.new(
		SimWorld.CMD_SET_RUDDER, 120, 1, {"value": 1.0}).to_dict())

	var replayed: SimWorld = _build(scenario)
	var diverged: int = playback.replay_into(replayed)
	gt(float(diverged), 0.0,
		"an order that was not in the recording must show up as a divergence")


func test_a_replay_survives_a_trip_through_a_file() -> void:
	var scenario: ScenarioDef = _scenario("battleship_duel")
	var world: SimWorld = _build(scenario)
	var recorder: ReplayRecorder = ReplayRecorder.start(
		world, scenario.scenario_id, TestShips.config())
	world.commands.submit_new(SimWorld.CMD_SET_SPEED_KNOTS, 30, world.ships[0].id,
		{"value": 22.0})
	for _i: int in 60 * 45:
		world.step()
		recorder.observe(world)
	recorder.stop()
	var recorded: int = world.checksum()

	var path: String = ReplayIo.save(recorder, world, "test_round_trip")
	ok(not path.is_empty(), "the replay should be written")
	var loaded: ReplayRecorder = ReplayIo.load_from_file(path)
	ok(loaded != null, "and read back")

	var replayed: SimWorld = _build(scenario)
	eq(loaded.replay_into(replayed), -1, "a replay off disk must not diverge either")
	eq(replayed.checksum(), recorded, "and must end in the same state")
	DirAccess.remove_absolute(path)


func test_rewinding_means_restoring_the_nearest_snapshot() -> void:
	var scenario: ScenarioDef = _scenario("battleship_duel")
	var config: Dictionary = TestShips.config()
	# Snapshot often, so a short battle has several to choose between.
	var sim: Dictionary = (config["sim"] as Dictionary).duplicate(true)
	sim["replay"] = {"snapshotIntervalTicks": 600, "checksumIntervalTicks": 60}
	config["sim"] = sim

	var world: SimWorld = ScenarioIo.build(scenario, config, TestWeapons.armory(), _specs())
	var recorder: ReplayRecorder = ReplayRecorder.start(world, scenario.scenario_id, config)
	for _i: int in 60 * 60:
		world.step()
		recorder.observe(world)

	ge(float(recorder.snapshots.size()), 3.0, "a minute should give several snapshots")
	var nearest: Dictionary = recorder.snapshot_at(2000)
	ok(not nearest.is_empty(), "there should be a snapshot at or before tick 2000")
	le(float(int(nearest.get("tick", 0))), 2000.0, "and it must not be from the future")
	ge(float(int(nearest.get("tick", 0))), 1800.0, "but should be the nearest one")
