class_name Projectile
extends RefCounted

## A shell in flight.
##
## Carries full three-dimensional state, because the two numbers that decide what
## happens when it arrives — how fast it is still going and how steeply it is falling
## — cannot be recovered from a plan-view straight line.
##
## Pooled rather than allocated. A fleet action puts hundreds of these in the air at
## once and retires them just as fast, and Stage 9's performance work assumes they are
## recycled rather than churned through the heap.

var id: int = 0
var shooter_id: int = 0
var target_id: int = 0
var team: int = 0

var shell: ShellDef = null
var penetration_k: float = 1380.0
var gun_id: String = ""

## Which of the ship's batteries fired it. Carried so the fall of shot corrects the
## plot that actually laid the gun: a ship's main battery director and her secondary
## director were separate installations solving separate problems, and letting a
## five-inch splash correct a sixteen-inch plot would ruin both.
var battery: StringName = &"main"

## World position, with z as height above the waterline.
var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO

var time_alive: float = 0.0
var drag_over_mass: float = 0.0
var active: bool = false

## Where it was fired from, for drawing the tracer and reporting the range.
var origin: Vector3 = Vector3.ZERO


func reset(p_id: int, p_shell: ShellDef, p_k: float, p_origin: Vector3, p_velocity: Vector3,
		p_shooter: int, p_target: int, p_team: int, p_gun: String,
		p_battery: StringName = &"main") -> void:
	id = p_id
	shell = p_shell
	penetration_k = p_k
	gun_id = p_gun
	battery = p_battery
	origin = p_origin
	position = p_origin
	velocity = p_velocity
	shooter_id = p_shooter
	target_id = p_target
	team = p_team
	time_alive = 0.0
	drag_over_mass = p_shell.drag_over_mass()
	active = true


func speed() -> float:
	return velocity.length()


func ground_position() -> Vector2:
	return Vector2(position.x, position.y)


func travelled_m() -> float:
	return Vector2(position.x - origin.x, position.y - origin.y).length()


func hash_into(hasher: StateHasher) -> void:
	hasher.write_int(id)
	hasher.write_vec3(position)
	hasher.write_vec3(velocity)
	hasher.write_float(time_alive)


func serialize() -> Dictionary:
	return {
		"id": id, "shooterId": shooter_id, "targetId": target_id, "team": team,
		"shell": shell.shell_id if shell != null else "", "gun": gun_id,
		"battery": String(battery),
		"position": Serializer.vec3_to_array(position),
		"velocity": Serializer.vec3_to_array(velocity),
		"origin": Serializer.vec3_to_array(origin),
		"timeAlive": time_alive,
	}
