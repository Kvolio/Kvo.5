extends SimTest

## Events must come back in exactly the order they were emitted — the combat log,
## the debug overlay and any in-tick system reaction all depend on it.


func suite_name() -> String:
	return "SimEventBus"


func test_events_are_returned_in_emission_order() -> void:
	var bus: SimEventBus = SimEventBus.new()
	bus.begin_tick(10)
	bus.emit_event(&"salvo_fired", 1, 2)
	bus.emit_event(&"shell_impact", 1, 2)
	bus.emit_event(&"component_disabled", 2, 0)

	var drained: Array[SimEvent] = bus.drain()
	eq(drained.size(), 3, "all three events drained")
	eq(String(drained[0].type), "salvo_fired", "first")
	eq(String(drained[1].type), "shell_impact", "second")
	eq(String(drained[2].type), "component_disabled", "third")


func test_sequence_numbers_are_monotonic_across_ticks() -> void:
	var bus: SimEventBus = SimEventBus.new()
	bus.begin_tick(1)
	var a: SimEvent = bus.emit_event(&"a")
	bus.begin_tick(2)
	var b: SimEvent = bus.emit_event(&"b")
	eq(a.seq, 0, "first event seq")
	eq(b.seq, 1, "seq continues across tick boundaries")
	eq(a.tick, 1, "event carries the tick it was emitted on")
	eq(b.tick, 2, "second event tick")


func test_events_this_tick_is_scoped_to_the_current_tick() -> void:
	var bus: SimEventBus = SimEventBus.new()
	bus.begin_tick(1)
	bus.emit_event(&"old")
	eq(bus.events_this_tick().size(), 1, "one event this tick")
	bus.begin_tick(2)
	eq(bus.events_this_tick().size(), 0, "cleared at the tick boundary")
	bus.emit_event(&"new")
	eq(bus.events_this_tick().size(), 1, "new tick accumulates its own")


func test_draining_does_not_consume_history() -> void:
	var bus: SimEventBus = SimEventBus.new()
	bus.begin_tick(1)
	bus.emit_event(&"a")
	bus.emit_event(&"b")
	eq(bus.drain().size(), 2, "first drain returns everything pending")
	eq(bus.drain().size(), 0, "second drain returns nothing new")
	eq(bus.history().size(), 2, "history survives draining — the combat log reads it later")


func test_history_is_capped_and_keeps_the_most_recent() -> void:
	var bus: SimEventBus = SimEventBus.new(4)
	bus.begin_tick(1)
	for i: int in 10:
		bus.emit_event(&"e", i)
	var history: Array[SimEvent] = bus.history()
	eq(history.size(), 4, "history bounded")
	eq(history[0].actor_id, 6, "oldest retained is the 7th emitted")
	eq(history[3].actor_id, 9, "newest retained is the last emitted")


func test_event_payload_survives() -> void:
	var bus: SimEventBus = SimEventBus.new()
	bus.begin_tick(5)
	var event: SimEvent = bus.emit_event(
		&"penetration", 7, 9, SimEvent.Severity.CRITICAL, {"plate": "main_belt", "mm": 320.0}
	)
	eq(event.severity, SimEvent.Severity.CRITICAL, "severity retained")
	var dict: Dictionary = event.to_dict()
	eq(dict["actorId"], 7, "actor serialised")
	eq(dict["targetId"], 9, "target serialised")
	eq((dict["data"] as Dictionary)["plate"], "main_belt", "payload serialised")


func test_clear_resets_everything() -> void:
	var bus: SimEventBus = SimEventBus.new()
	bus.begin_tick(1)
	bus.emit_event(&"a")
	bus.clear()
	eq(bus.history().size(), 0, "history cleared")
	eq(bus.drain().size(), 0, "pending cleared")
	bus.begin_tick(1)
	eq(bus.emit_event(&"b").seq, 0, "sequence restarts")
