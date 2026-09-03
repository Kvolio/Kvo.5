extends SimTest

## The command log is one of the four inputs a replay is reconstructed from, so its
## ordering has to be a total order — not "sorted, ties resolved by luck".


func suite_name() -> String:
	return "CommandQueue"


func test_commands_are_released_on_their_scheduled_tick() -> void:
	var queue: CommandQueue = CommandQueue.new()
	queue.submit_new(&"set_speed", 10, 1)
	queue.submit_new(&"set_heading", 20, 1)

	eq(queue.take_due(5).size(), 0, "nothing due yet")
	eq(queue.take_due(10).size(), 1, "first command due")
	eq(queue.take_due(15).size(), 0, "already consumed")
	eq(queue.take_due(20).size(), 1, "second command due")
	eq(queue.pending_count(), 0, "queue drained")


func test_ordering_is_total_tick_then_entity_then_sequence() -> void:
	var queue: CommandQueue = CommandQueue.new()
	# Deliberately submitted out of order.
	queue.submit_new(&"c", 5, 9)
	queue.submit_new(&"a", 5, 2)
	queue.submit_new(&"b", 5, 2)
	queue.submit_new(&"d", 3, 100)

	var due: Array[SimCommand] = queue.take_due(5)
	var order: Array[String] = []
	for command: SimCommand in due:
		order.append(String(command.type))
	arrays_equal(order, ["d", "a", "b", "c"],
		"earlier tick first, then ascending entity id, then submission order")


func test_late_commands_are_not_silently_dropped() -> void:
	var queue: CommandQueue = CommandQueue.new()
	queue.submit_new(&"fire", 3, 1)
	# The sim has already advanced past tick 3 when the order is drained.
	var due: Array[SimCommand] = queue.take_due(50)
	eq(due.size(), 1, "a command scheduled in the past is still delivered, not discarded")


func test_log_records_every_submission_in_order() -> void:
	var queue: CommandQueue = CommandQueue.new()
	queue.submit_new(&"a", 1, 1)
	queue.submit_new(&"b", 2, 1)
	queue.take_due(99)
	eq(queue.log_entries().size(), 2, "consuming a command does not erase it from the log")
	eq(String(queue.log_entries()[0].type), "a", "log is in submission order")


func test_recording_can_be_disabled() -> void:
	var queue: CommandQueue = CommandQueue.new(false)
	queue.submit_new(&"a", 1, 1)
	eq(queue.log_entries().size(), 0, "a non-recording queue keeps no log")
	eq(queue.pending_count(), 1, "but still queues the command")


func test_log_round_trip_reproduces_the_pending_queue() -> void:
	var original: CommandQueue = CommandQueue.new()
	original.submit_new(&"set_speed", 10, 1, {"knots": 27.5})
	original.submit_new(&"engage", 12, 2, {"targetId": 4})
	var serialised: Array = original.serialize_log()

	var replayed: CommandQueue = CommandQueue.new()
	replayed.load_log(serialised)
	eq(replayed.pending_count(), 2, "loaded commands are queued for replay")

	var due: Array[SimCommand] = replayed.take_due(12)
	eq(due.size(), 2, "both released by tick 12")
	eq(String(due[0].type), "set_speed", "order preserved")
	almost(float((due[0].params as Dictionary)["knots"]), 27.5, 0.0001, "params preserved exactly")
	eq(int((due[1].params as Dictionary)["targetId"]), 4, "second command params preserved")


func test_sequence_continues_after_loading_a_log() -> void:
	var queue: CommandQueue = CommandQueue.new()
	queue.load_log([
		{"type": "a", "tick": 1, "entityId": 1, "params": {}, "seq": 7},
	])
	var appended: SimCommand = queue.submit_new(&"b", 1, 1)
	gt(float(appended.seq), 7.0, "new commands must sort after the loaded ones")
