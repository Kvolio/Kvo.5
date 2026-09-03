class_name SimEvent
extends RefCounted

## One thing that happened in the simulation, at a known tick, in a known order.
##
## Events are an *output* of the simulation, never an input to it. Replay works by
## re-running the sim from a seed and a command log, so events never have to be
## reproduced from a file — which is what lets the combat log and debug overlay
## carry as much detail as they like without any cost to reproducibility.

enum Severity {
	INFO,      ## routine: a salvo fired, a shell splashed
	NOTABLE,   ## worth a combat-log line: a penetration, a component disabled
	CRITICAL,  ## magazine detonation, capsize, ship destroyed
}

var tick: int = 0
var seq: int = 0
var type: StringName = &""
var actor_id: int = 0
var target_id: int = 0
var severity: Severity = Severity.INFO
var data: Dictionary = {}


func _init(
	p_type: StringName = &"",
	p_tick: int = 0,
	p_actor_id: int = 0,
	p_target_id: int = 0,
	p_severity: Severity = Severity.INFO,
	p_data: Dictionary = {}
) -> void:
	type = p_type
	tick = p_tick
	actor_id = p_actor_id
	target_id = p_target_id
	severity = p_severity
	data = p_data


func to_dict() -> Dictionary:
	return {
		"tick": tick,
		"seq": seq,
		"type": String(type),
		"actorId": actor_id,
		"targetId": target_id,
		"severity": int(severity),
		"data": data,
	}
