class_name SimEventBus
extends RefCounted

## Ordered event queue owned by SimWorld.
##
## Deliberately NOT a Godot signal hub. Signal dispatch order depends on connection
## order, which depends on which systems happened to be constructed first — an
## invisible way for outcomes to become order-dependent. Here events go into an
## array in emission order and are read back in that same order, by everyone.
##
## In-simulation systems that need to react to an event read `events_this_tick()`
## at their own point in the fixed system order. Presentation code calls `drain()`.

const DEFAULT_HISTORY_LIMIT: int = 4096

var _seq: int = 0
var _current_tick: int = 0
var _this_tick: Array[SimEvent] = []
var _pending: Array[SimEvent] = []
var _history: Array[SimEvent] = []
var _history_limit: int = DEFAULT_HISTORY_LIMIT


func _init(history_limit: int = DEFAULT_HISTORY_LIMIT) -> void:
	_history_limit = history_limit


## Called by SimWorld at the top of each tick.
func begin_tick(tick: int) -> void:
	_current_tick = tick
	_this_tick.clear()


func emit_event(
	type: StringName,
	actor_id: int = 0,
	target_id: int = 0,
	severity: SimEvent.Severity = SimEvent.Severity.INFO,
	data: Dictionary = {}
) -> SimEvent:
	var event: SimEvent = SimEvent.new(type, _current_tick, actor_id, target_id, severity, data)
	event.seq = _seq
	_seq += 1
	_this_tick.append(event)
	_pending.append(event)
	_history.append(event)
	if _history.size() > _history_limit:
		_history = _history.slice(_history.size() - _history_limit)
	return event


## Events emitted so far during the current tick, in emission order.
func events_this_tick() -> Array[SimEvent]:
	return _this_tick


## Take everything not yet consumed by presentation. Does not touch history.
func drain() -> Array[SimEvent]:
	var out: Array[SimEvent] = _pending.duplicate()
	_pending.clear()
	return out


## Recent events, oldest first, capped at the history limit.
func history() -> Array[SimEvent]:
	return _history


func clear() -> void:
	_this_tick.clear()
	_pending.clear()
	_history.clear()
	_seq = 0
