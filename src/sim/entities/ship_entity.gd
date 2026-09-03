class_name ShipEntity
extends SimEntity

## A ship in the world: what it is (`spec`), where it is, and what state it is in.
##
## Movement state lives here; the physics that changes it lives in MovementSystem.
## Damage state is added by Stage 4 and consumed here through the `*_fraction`
## fields, which is how "one shaft destroyed" becomes "slower" without the movement
## code knowing anything about shells.
##
## A SimEntity, which is what lets detection, formation keeping and the spatial index
## treat her and an aircraft as the same kind of thing without either of them knowing
## the other exists — see `src/sim/interfaces/sim_entity.gd`.

## How long a gun flash stays worth reporting.
const GUN_FLASH_SECONDS: float = 3.0


enum Status {
	ACTIVE,        ## fighting
	MISSION_KILL,  ## afloat, but can no longer meaningfully fight
	DESTROYED,     ## sunk, capsized, blown up or broken in half
}

## `id`, `team`, `position` and `display_name` are SimEntity's.
var spec: ShipSpec = null

# -- kinematics (world frame, SI) --------------------------------------------
var heading: float = 0.0        ## radians; 0 points along +X
var speed: float = 0.0          ## m/s along the heading; negative is sternway
var yaw_rate: float = 0.0       ## rad/s, positive to starboard

# -- steering ----------------------------------------------------------------
var rudder_angle: float = 0.0   ## radians, actual rudder position
var rudder_order: float = 0.0   ## radians, ordered rudder position
var throttle: float = 0.0       ## -1 (full astern) .. +1 (full ahead)

## A COURSE order, as against a rudder order. "Steer 090" is not "put the rudder over
## fifteen degrees": the first is held until she is on it and then held there, the
## second is obeyed until somebody says otherwise. Without the distinction a ship
## ordered onto a heading turns through it and goes on turning, which is a circle and
## not a course. A manual rudder order cancels the course order, exactly as putting the
## helm over by hand takes a ship off the gyro.
var ordered_heading: float = 0.0
var holds_heading: bool = false

# -- attitude ----------------------------------------------------------------
## Set by the flooding model in Stage 4. Kept here rather than there because the
## trajectory tracer needs it: a listing ship really does present more deck and
## less belt to an incoming shell.
var list_angle: float = 0.0     ## radians, positive to starboard
var trim_angle: float = 0.0     ## radians, positive bow-down

# -- armament ----------------------------------------------------------------
## Gun mounts, in the order the design lists them. Built by build_turrets().
var turrets: Array[Turret] = []

## Torpedo tubes. A ship that has fired hers has spent the only thing that made her
## dangerous to something much larger.
var torpedo_launchers: Array[TorpedoLauncher] = []

## The ship this one is shooting at, or 0 for none. Set by the player or the AI;
## never inferred inside the gunnery code, so a replay reproduces target changes.
var target_id: int = 0

## What her gunnery believes about that target, one plot per battery — because a main
## battery director and a secondary director were separate installations solving
## separate problems. It matters more than it sounds: the fall of shot corrects the
## plot that laid the gun, and a five-inch splash correcting a sixteen-inch plot would
## ruin both. Keyed by battery name; built when she first opens fire.
##
## Never quite the truth, which is what makes a hit at 20 km an achievement rather than
## an arithmetic result. See FireControlSolution.
var fire_control: Dictionary = {}

## Her fire-control installation, resolved once from her design.
var fire_control_fit: FireControlSolution.Fit = null

## Fought by the AI rather than by whoever put her here.
##
## Off by default, and deliberately: a ship added to a world holds the orders she was
## given until somebody says otherwise. A scenario, a fleet deployment or the battle
## view turns the AI on for the ships it wants fought automatically, and a test that
## sets a course and a target keeps them. Defaulting the other way would mean every
## test of movement or gunnery was quietly also a test of the AI.
var ai_controlled: bool = false

## Her captain's tactical state: what he is doing and why. Held on the ship so it
## serialises with her and so the inspector can show his reasoning.
var ai: AiSystem.State = null

## The formation she is stationed in, and where in it. Empty means she is manoeuvring
## independently — which is also what she does the moment there are torpedoes in the
## water, because station keeping is not worth dying for.
var formation_id: String = ""
var station_index: int = 0

# -- condition ---------------------------------------------------------------
var status: Status = Status.ACTIVE

## This ship's own damage: what is flooded, burning, wrecked, and who is left.
## Per-INSTANCE, unlike the geometry it refers to, which is shared by every ship of
## the design. Without that split a hit on one Fletcher would flood all of them.
var structure_state: ShipStructureState = null

## Last assessment of her condition. Recomputed by the damage systems, read by the
## UI and the AI. Structural integrity lives here as a DERIVED figure.
var condition: SurvivabilityEvaluator.Condition = null

## Why she was lost, once she is.
var loss_reason: String = ""

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

# -- being found ---------------------------------------------------------------
## Height of the highest thing worth sighting, metres above the waterline. Taken from
## the structure her design produced, so it is the ship's own upperworks and not a
## number somebody typed. Set when she is added to the world.
var sighting_height_m: float = 10.0

## Seconds since she last fired a gun, or -1 if she has not. A gun flash carries far
## past the horizon at night and is how most night actions actually opened, so it is
## tracked rather than inferred.
var firing_seconds_ago: float = -1.0


static func create(p_id: int, p_spec: ShipSpec, p_team: int = 0) -> ShipEntity:
	var ship: ShipEntity = ShipEntity.new()
	ship.id = p_id
	ship.spec = p_spec
	ship.team = p_team
	ship.display_name = p_spec.display_name
	return ship


func hull() -> HullGeometry:
	return spec.hull()


## Structural integrity, 0-1.
##
## A DERIVED summary of the ship's condition, not a health pool: nothing subtracts
## from it, and it is not what decides whether she survives. See
## SurvivabilityEvaluator.
func structural_integrity() -> float:
	return 1.0 if condition == null else condition.integrity


func list_degrees() -> float:
	return 0.0 if condition == null else condition.list_deg


func crew_alive() -> int:
	return spec.crew if structure_state == null else structure_state.crew_alive


## Build the ship's gun mounts from her design.
##
## Separate from create() because it needs the armoury to resolve gun definitions,
## and a movement-only test has no reason to load one.
func build_turrets(armory: Armory) -> void:
	turrets.clear()
	_add_battery(armory, spec.main_battery, &"main")
	_add_battery(armory, spec.secondary_battery, &"secondary")


## Build the ship's torpedo tubes. Separate from the guns because most ships have none.
func build_torpedo_launchers(armory: Armory) -> void:
	torpedo_launchers.clear()
	if not spec.has_torpedoes():
		return
	var definition: TorpedoDef = armory.get_torpedo(spec.torpedo_battery.torpedo_id)
	if definition == null:
		push_warning("ShipEntity: %s has no definition for torpedo '%s'"
			% [display_name, spec.torpedo_battery.torpedo_id])
		return
	for mount: TorpedoMountDef in spec.torpedo_battery.mounts:
		torpedo_launchers.append(TorpedoLauncher.create(mount, definition, spec.torpedo_battery))


## Torpedoes still in the tubes.
func tubes_loaded() -> int:
	var total: int = 0
	for launcher: TorpedoLauncher in torpedo_launchers:
		if launcher.is_operational():
			total += launcher.tubes_loaded
	return total


func _add_battery(armory: Armory, battery: BatteryDef, label: StringName) -> void:
	if battery == null or battery.is_empty():
		return
	var gun: GunDef = armory.get_gun(battery.gun_id)
	if gun == null:
		push_warning("ShipEntity: %s has no definition for gun '%s'" % [display_name, battery.gun_id])
		return
	for mount: MountDef in battery.mounts:
		turrets.append(Turret.create(mount, gun, label))


func main_battery_turrets() -> Array[Turret]:
	var out: Array[Turret] = []
	for turret: Turret in turrets:
		if turret.battery == &"main":
			out.append(turret)
	return out


func operational_main_barrels() -> int:
	var count: int = 0
	for turret: Turret in turrets:
		if turret.battery == &"main" and turret.is_operational():
			count += turret.barrels()
	return count


func is_afloat() -> bool:
	return status != Status.DESTROYED


# -- SimEntity and Detectable --------------------------------------------------

func is_alive() -> bool:
	return status != Status.DESTROYED


func spatial_layer() -> int:
	return SpatialIndex.Layer.SHIP


func spatial_radius() -> float:
	return hull().bounding_radius()


## What she looks like to somebody trying to find her.
##
## Every figure is measured off the design rather than stated in her data file: the
## height that sets her horizon is the top of the superstructure the structure builder
## actually put on her, and the silhouette is the side of the hull and upperworks she
## really presents. A ship drawn in the designer is therefore as findable as her shape
## says she should be, with nothing to fill in and nothing to get out of step.
func detection_signature() -> Detectable.Signature:
	var signature: Detectable.Signature = Detectable.Signature.new()
	signature.height_m = sighting_height_m
	signature.silhouette_m2 = spec.length_m * (sighting_height_m * 0.45 + spec.draft_m * 0.2)
	signature.radar_area_m2 = signature.silhouette_m2
	signature.firing = firing_seconds_ago >= 0.0 and firing_seconds_ago < GUN_FLASH_SECONDS
	signature.burning = 0.0 if condition == null else condition.fire_fraction
	return signature


func can_manoeuvre() -> bool:
	return status != Status.DESTROYED and propulsion_fraction > 0.0


## Is she still trying to hold her station?
##
## A ship evading torpedoes or breaking off has stopped caring about the formation, and
## saying so here is what keeps the formation system from steering her back into a
## torpedo salvo she has just turned to comb.
## The plot one of her batteries is solving on, or null if it has not opened one.
func plot_for(battery: StringName) -> FireControlSolution:
	return fire_control.get(battery) as FireControlSolution


## Her main battery's plot — what the HUD shows and what "her gunnery solution" means
## without further qualification.
func main_plot() -> FireControlSolution:
	return plot_for(&"main")


func keeps_station() -> bool:
	if formation_id.is_empty() or not can_manoeuvre():
		return false
	if ai == null:
		return true
	return ai.posture != AiSystem.Posture.EVADE and ai.posture != AiSystem.Posture.DISENGAGE


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
	hasher.write_int(target_id)
	for turret: Turret in turrets:
		turret.hash_into(hasher)
	for launcher: TorpedoLauncher in torpedo_launchers:
		launcher.hash_into(hasher)
	if structure_state != null:
		structure_state.hash_into(hasher)


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
		"targetId": target_id,
		"orderedHeading": ordered_heading,
		"holdsHeading": holds_heading,
		"aiControlled": ai_controlled,
		"formationId": formation_id,
		"stationIndex": station_index,
		"sightingHeightM": sighting_height_m,
		"firingSecondsAgo": firing_seconds_ago,
		"turrets": _serialize_turrets(),
		"torpedoLaunchers": _serialize_launchers(),
		"structure": {} if structure_state == null else structure_state.serialize(),
		"fireControl": _serialize_plots(),
		"ai": {} if ai == null else {
			"posture": ai.posture, "preferredRangeM": ai.preferred_range_m,
			"secondsOnTarget": ai.seconds_on_target,
			"torpedoesSpent": ai.torpedoes_spent,
		},
	}


func _serialize_launchers() -> Array:
	var out: Array = []
	for launcher: TorpedoLauncher in torpedo_launchers:
		out.append(launcher.serialize())
	return out


func _serialize_plots() -> Dictionary:
	var out: Dictionary = {}
	for battery: String in Serializer.sorted_keys(fire_control):
		out[battery] = (fire_control[StringName(battery)] as FireControlSolution).serialize()
	return out


func _serialize_turrets() -> Array:
	var out: Array = []
	for turret: Turret in turrets:
		out.append(turret.serialize())
	return out


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
	target_id = int(data.get("targetId", 0))
	ordered_heading = float(data.get("orderedHeading", ordered_heading))
	holds_heading = bool(data.get("holdsHeading", holds_heading))
	ai_controlled = bool(data.get("aiControlled", ai_controlled))
	formation_id = str(data.get("formationId", formation_id))
	station_index = int(data.get("stationIndex", station_index))
	sighting_height_m = float(data.get("sightingHeightM", sighting_height_m))
	firing_seconds_ago = float(data.get("firingSecondsAgo", firing_seconds_ago))

	var turret_data: Array = data.get("turrets", []) as Array
	for i: int in mini(turret_data.size(), turrets.size()):
		turrets[i].deserialize(turret_data[i] as Dictionary)

	var launcher_data: Array = data.get("torpedoLaunchers", []) as Array
	for i: int in mini(launcher_data.size(), torpedo_launchers.size()):
		torpedo_launchers[i].deserialize(launcher_data[i] as Dictionary)

	var structure: Dictionary = data.get("structure", {}) as Dictionary
	if structure_state != null and not structure.is_empty():
		structure_state.deserialize(structure)

	fire_control.clear()
	var plots: Dictionary = data.get("fireControl", {}) as Dictionary
	for battery: String in Serializer.sorted_keys(plots):
		var plot: FireControlSolution = FireControlSolution.new()
		plot.deserialize(plots[battery] as Dictionary)
		fire_control[StringName(battery)] = plot

	var ai_data: Dictionary = data.get("ai", {}) as Dictionary
	if ai_data.is_empty():
		ai = null
	else:
		ai = AiSystem.State.new()
		ai.posture = int(ai_data.get("posture", AiSystem.Posture.HOLD))
		ai.preferred_range_m = float(ai_data.get("preferredRangeM", 0.0))
		ai.seconds_on_target = float(ai_data.get("secondsOnTarget", 0.0))
		ai.torpedoes_spent = bool(ai_data.get("torpedoesSpent", false))
