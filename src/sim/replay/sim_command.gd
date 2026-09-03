class_name SimCommand
extends RefCounted

## An instruction entering the simulation from outside it — a player order, a
## scenario script, a headless test.
##
## This is the ONLY channel through which external intent may change sim state.
## AI decisions are computed inside the sim from state the sim already has, so they
## are reproduced by re-running rather than recorded. That distinction is what makes
## a battle replayable from seed + initial state + this command log alone.

var tick: int = 0          ## tick at which the command takes effect
var entity_id: int = 0     ## 0 = world-level command
var type: StringName = &""
var params: Dictionary = {}
var seq: int = 0           ## submission order; final tie-break for total ordering


func _init(
	p_type: StringName = &"",
	p_tick: int = 0,
	p_entity_id: int = 0,
	p_params: Dictionary = {}
) -> void:
	type = p_type
	tick = p_tick
	entity_id = p_entity_id
	params = p_params


func to_dict() -> Dictionary:
	return {
		"tick": tick,
		"entityId": entity_id,
		"type": String(type),
		"params": params,
		"seq": seq,
	}


static func from_dict(data: Dictionary) -> SimCommand:
	var cmd: SimCommand = SimCommand.new(
		StringName(str(data.get("type", ""))),
		int(data.get("tick", 0)),
		int(data.get("entityId", 0)),
		data.get("params", {}) as Dictionary
	)
	cmd.seq = int(data.get("seq", 0))
	return cmd
