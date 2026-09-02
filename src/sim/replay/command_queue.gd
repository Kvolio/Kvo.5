class_name CommandQueue
extends RefCounted

## Pending external commands, plus the durable log of everything ever submitted.
##
## `take_due(tick)` returns commands in a *total* order — (tick, entityId, seq) —
## rather than relying on the sort being stable. Godot's `sort_custom` makes no
## stability guarantee, so a comparator that left ties unresolved would be free to
## reorder two commands issued to different ships on the same tick, and that is
## enough to change a battle.

var _pending: Array[SimCommand] = []
var _log: Array[SimCommand] = []
var _seq: int = 0
var _recording: bool = true


func _init(recording: bool = true) -> void:
	_recording = recording


func submit(command: SimCommand) -> SimCommand:
	command.seq = _seq
	_seq += 1
	_pending.append(command)
	if _recording:
		_log.append(command)
	return command


func submit_new(
	type: StringName, tick: int, entity_id: int = 0, params: Dictionary = {}
) -> SimCommand:
	return submit(SimCommand.new(type, tick, entity_id, params))


## Total order over commands. Never leaves two distinct commands "equal".
static func _compare(a: SimCommand, b: SimCommand) -> bool:
	if a.tick != b.tick:
		return a.tick < b.tick
	if a.entity_id != b.entity_id:
		return a.entity_id < b.entity_id
	return a.seq < b.seq


## Remove and return every command scheduled at or before `tick`, in total order.
## Commands scheduled in the past (a late arrival) are included rather than dropped,
## so a stalled UI thread cannot silently lose an order.
func take_due(tick: int) -> Array[SimCommand]:
	var due: Array[SimCommand] = []
	var remaining: Array[SimCommand] = []
	for command: SimCommand in _pending:
		if command.tick <= tick:
			due.append(command)
		else:
			remaining.append(command)
	_pending = remaining
	due.sort_custom(_compare)
	return due


func pending_count() -> int:
	return _pending.size()


## Everything submitted this session, in submission order — the replay log.
func log_entries() -> Array[SimCommand]:
	return _log


func serialize_log() -> Array:
	var out: Array = []
	for command: SimCommand in _log:
		out.append(command.to_dict())
	return out


## Load a recorded log for replay. Commands are re-queued as pending so the sim can
## consume them tick by tick exactly as it did during recording.
func load_log(entries: Array) -> void:
	_pending.clear()
	_log.clear()
	_seq = 0
	for entry: Variant in entries:
		var command: SimCommand = SimCommand.from_dict(entry as Dictionary)
		_pending.append(command)
		_log.append(command)
		_seq = maxi(_seq, command.seq + 1)


func clear() -> void:
	_pending.clear()
	_log.clear()
	_seq = 0
