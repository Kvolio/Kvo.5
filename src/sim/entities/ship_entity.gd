class_name ShipEntity
extends RefCounted

## A ship in the world: what it is (`spec`), where it is, and what state it is in.
##
## Movement state lives here; the physics that changes it lives in MovementSystem.
## Damage state is added by Stage 4 and consumed here through the `*_fraction`
## fields, which is how "one shaft destroyed" becomes "slower" without the movement
## code knowing anything about shells.

enum Status {
	ACTIVE,        ## fighting
	MISSION_KILL,  ## afloat, but can no longer meaningfully fight
	DESTROYED,     ## sunk, capsized, blown up or broken in half
}

var id: int = 0
var spec: ShipSpec = null
var team: int = 0
var display_name: String = ""

# -- kinematics (world frame, SI) --------------------------------------------
var position: Vector2 = Vector2.ZERO
var heading: float = 0.0        ## radians; 0 points along +X
var speed: float = 0.0          ## m/s along the heading; negative is sternway
var yaw_rate: float = 0.0       ## rad/s, positive to starboard

# -- steering ----------------------------------------------------------------
var rudder_angle: float = 0.0   ## radians, actual rudder position
var rudder_order: float = 0.0   ## radians, ordered rudder position
var throttle: float = 0.0       ## -1 (full astern) .. +1 (full ahead)

# -- attitude ----------------------------------------------------------------
## Set by the flooding model in Stage 4. Kept here rather than there because the
## trajectory tracer needs it: a listing ship really does present more deck and
## less belt to an incoming shell.
var list_angle: float = 0.0     ## radians, positive to starboard
var trim_angle: float = 0.0     ## radians, positive bow-down

# -- condition ---------------------------------------------------------------
var status: Status = Status.ACTIVE

## Fraction of design shaft power still available. Driven by engine, boiler and
## shaft damage from Stage 4 onward.
var propulsion_fraction: float = 1.0

## Net port/starboard thrust imbalance in [-1, 1]; negative means the port side is
## pushing harder. A lost shaft on one side makes a ship crab, and this is how.
var shaft_asymmetry: float = 0.0

## Rudder authority remaining, 0 (destroyed) to 1 (undamaged).
var rudder_effectiveness: float = 1.0

## When the steering gear is wrecked the rudder jams where it stands.
var rudder_jammed: bool = false


static func create(p_id: int, p_spec: ShipSpec, p_team: int = 0) -> ShipEntity:
	var ship: ShipEntity = ShipEntity.new()
	ship.id = p_id
	ship.spec = p_spec
	ship.team = p_team
	ship.display_name = p_spec.display_name
	return ship


func hull() -> HullGeometry:
	return spec.hull()


func is_afloat() -> bool:
	return status != Status.DESTROYED


func can_manoeuvre() -> bool:
	return status != Status.DESTROYED and propulsion_fraction > 0.0


## Speed the ship can still reach, given propulsion damage.
##
## Resistance rises with the cube of speed, so top speed scales with the CUBE ROOT
## of available power. Losing half the plant costs only about a fifth of the speed —
## which is why a battleship with two of four shafts gone is still making 26 knots,
## and is the sort of result that should come from physics rather than a table.
func effective_max_speed() -> float:
	if propulsion_fraction <= 0.0:
		return 0.0
	return spec.max_speed_ms * pow(propulsion_fraction, 1.0 / 3.0)


## Fastest sternway the ship can make. See maxSternwayFraction in
## data/config/physics.json for why this is a stated limit rather than a derived one.
func max_sternway_speed() -> float:
	return effective_max_speed() * spec.max_sternway_fraction


func velocity() -> Vector2:
	return Vector2(cos(heading), sin(heading)) * speed


func speed_knots() -> float:
	return SimUnits.ms_to_knots(speed)


func heading_degrees() -> float:
	return rad_to_deg(SimUnits.normalise_angle(heading))


## Compass bearing in degrees, 0 = north, increasing clockwise.
##
## Screen space has +Y downward, so a heading of 0 radians points east/right. The
## conversion is kept in one place so the UI and the tactical overlays cannot drift
## apart on it.
func compass_bearing() -> float:
	return fposmod(rad_to_deg(heading) + 90.0, 360.0)


func hash_into(hasher: StateHasher) -> void:
	hasher.write_int(id)
	hasher.write_vec2(position)
	hasher.write_float(heading)
	hasher.write_float(speed)
	hasher.write_float(yaw_rate)
	hasher.write_float(rudder_angle)
	hasher.write_float(rudder_order)
	hasher.write_float(throttle)
	hasher.write_float(list_angle)
	hasher.write_float(trim_angle)
	hasher.write_float(propulsion_fraction)
	hasher.write_float(shaft_asymmetry)
	hasher.write_float(rudder_effectiveness)
	hasher.write_int(int(status))


func serialize() -> Dictionary:
	return {
		"id": id,
		"specId": spec.spec_id,
		"team": team,
		"name": display_name,
		"position": Serializer.vec2_to_array(position),
		"heading": heading,
		"speed": speed,
		"yawRate": yaw_rate,
		"rudderAngle": rudder_angle,
		"rudderOrder": rudder_order,
		"throttle": throttle,
		"listAngle": list_angle,
		"trimAngle": trim_angle,
		"status": int(status),
		"propulsionFraction": propulsion_fraction,
		"shaftAsymmetry": shaft_asymmetry,
		"rudderEffectiveness": rudder_effectiveness,
		"rudderJammed": rudder_jammed,
	}


func deserialize(data: Dictionary) -> void:
	id = int(data.get("id", id))
	team = int(data.get("team", team))
	display_name = str(data.get("name", display_name))
	position = Serializer.array_to_vec2(data.get("position"), position)
	heading = float(data.get("heading", heading))
	speed = float(data.get("speed", speed))
	yaw_rate = float(data.get("yawRate", yaw_rate))
	rudder_angle = float(data.get("rudderAngle", rudder_angle))
	rudder_order = float(data.get("rudderOrder", rudder_order))
	throttle = float(data.get("throttle", throttle))
	list_angle = float(data.get("listAngle", list_angle))
	trim_angle = float(data.get("trimAngle", trim_angle))
	status = int(data.get("status", int(status))) as Status
	propulsion_fraction = float(data.get("propulsionFraction", propulsion_fraction))
	shaft_asymmetry = float(data.get("shaftAsymmetry", shaft_asymmetry))
	rudder_effectiveness = float(data.get("rudderEffectiveness", rudder_effectiveness))
	rudder_jammed = bool(data.get("rudderJammed", rudder_jammed))
