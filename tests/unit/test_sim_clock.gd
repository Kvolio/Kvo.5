extends SimTest

## Time scaling must change how MANY ticks run, never how BIG a tick is. If it ever
## changed the step size, a battle fought at 10x would diverge from the same battle
## at 1x and every replay would be worthless.


func suite_name() -> String:
	return "SimClock"


func _clock() -> SimClock:
	var clock: SimClock = SimClock.new()
	clock.configure(JsonLoader.load_dict("res://data/config/sim.json"))
	return clock


func test_configured_from_data() -> void:
	var clock: SimClock = _clock()
	almost(clock.dt, 1.0 / 60.0, 1e-9, "60 Hz fixed timestep")
	almost(clock.time_scale, 1.0, 1e-9, "starts at normal speed")


func test_the_timestep_never_changes_with_the_time_scale() -> void:
	var clock: SimClock = _clock()
	var dt_at_normal: float = clock.dt
	for scale: float in [0.25, 0.5, 2.0, 5.0, 10.0]:
		clock.time_scale = scale
		clock.advance(0.016)
		eq(clock.dt, dt_at_normal, "dt is identical at %sx" % str(scale))


func test_faster_time_scales_ask_for_proportionally_more_ticks() -> void:
	var frame: float = 1.0 / 60.0
	var at_normal: int = _stepped_over(1.0, frame, 1.0)
	var at_double: int = _stepped_over(1.0, frame, 2.0)
	var at_quarter: int = _stepped_over(1.0, frame, 0.25)
	almost(float(at_normal), 60.0, 2.0, "one second at 1x is about 60 ticks")
	almost(float(at_double), 120.0, 3.0, "2x runs twice as many")
	almost(float(at_quarter), 15.0, 2.0, "0.25x runs a quarter as many")


func test_pausing_stops_time_entirely() -> void:
	var clock: SimClock = _clock()
	clock.time_scale = 0.0
	ok(clock.is_paused(), "reported as paused")
	eq(clock.advance(1.0), 0, "a whole second of real time produces no ticks")


func test_unpausing_does_not_replay_the_paused_interval() -> void:
	# Banking real time while paused would make the simulation lurch forward the
	# moment play resumed.
	var clock: SimClock = _clock()
	clock.time_scale = 0.0
	clock.advance(30.0)
	clock.time_scale = 1.0
	le(float(clock.advance(1.0 / 60.0)), 2.0, "resumes smoothly rather than fast-forwarding")


func test_catch_up_work_is_bounded() -> void:
	# A frame that stalls for a full second must not ask for a second of simulation
	# in one go — that makes the next frame worse still, and the frame after that
	# worse again. Better to run in slow motion.
	var clock: SimClock = _clock()
	clock.max_steps_per_frame = 40
	eq(clock.advance(10.0), 40, "clamped to the per-frame ceiling")
	le(float(clock.advance(1.0 / 60.0)), 2.0, "and the backlog is dropped, not banked")


func test_elapsed_time_follows_the_tick_count() -> void:
	var clock: SimClock = _clock()
	for _i: int in 120:
		clock.consume_tick()
	almost(clock.elapsed(), 2.0, 1e-6, "120 ticks at 60 Hz is two seconds")


func test_serialisation_round_trip() -> void:
	var clock: SimClock = _clock()
	clock.time_scale = 5.0
	for _i: int in 37:
		clock.consume_tick()
	var restored: SimClock = SimClock.new()
	restored.deserialize(clock.serialize())
	eq(restored.tick, 37, "tick count restored")
	almost(restored.dt, clock.dt, 1e-12, "timestep restored exactly")
	almost(restored.time_scale, 5.0, 1e-9, "time scale restored")


func _stepped_over(seconds: float, frame: float, scale: float) -> int:
	var clock: SimClock = _clock()
	clock.time_scale = scale
	var total: int = 0
	var elapsed: float = 0.0
	while elapsed < seconds:
		total += clock.advance(frame)
		elapsed += frame
	return total
