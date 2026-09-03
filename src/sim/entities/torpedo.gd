class_name Torpedo
extends RefCounted

## A torpedo running towards a ship.
##
## Straight-running: it goes where it was pointed at the speed it was set to, and has
## no idea where the target has gone since. That is the whole tactical problem of a
## torpedo attack — the weapon is aimed at where a ship WILL be if she holds her
## course, and a ship that turns after the tracks are seen is not there when they
## arrive.

var id: int = 0
var shooter_id: int = 0
var target_id: int = 0
var team: int = 0

var definition: TorpedoDef = null
var position: Vector2 = Vector2.ZERO
var heading: float = 0.0
var speed_ms: float = 20.0
var run_depth_m: float = 5.0

var distance_run: float = 0.0
var max_range_m: float = 5000.0
var active: bool = false

var origin: Vector2 = Vector2.ZERO


func reset(p_id: int, p_definition: TorpedoDef, p_origin: Vector2, p_heading: float,
		p_speed: float, p_range: float, p_shooter: int, p_target: int, p_team: int) -> void:
	id = p_id
	definition = p_definition
	origin = p_origin
	position = p_origin
	heading = p_heading
	speed_ms = p_speed
	max_range_m = p_range
	run_depth_m = p_definition.run_depth_m
	shooter_id = p_shooter
	target_id = p_target
	team = p_team
	distance_run = 0.0
	active = true


func velocity() -> Vector2:
	return Vector2(cos(heading), sin(heading)) * speed_ms


## Has it armed? A torpedo will not detonate before it has run clear of the ship that
## fired it, which is why a point-blank shot is wasted.
func is_armed() -> bool:
	return definition != null and distance_run >= definition.arming_distance_m


func is_spent() -> bool:
	return distance_run >= max_range_m


func hash_into(hasher: StateHasher) -> void:
	hasher.write_int(id)
	hasher.write_vec2(position)
	hasher.write_float(heading)
	hasher.write_float(distance_run)


func serialize() -> Dictionary:
	return {
		"id": id, "shooterId": shooter_id, "targetId": target_id, "team": team,
		"torpedo": definition.torpedo_id if definition != null else "",
		"position": Serializer.vec2_to_array(position),
		"origin": Serializer.vec2_to_array(origin),
		"heading": heading, "speedMs": speed_ms,
		"distanceRun": distance_run, "maxRangeM": max_range_m,
	}
