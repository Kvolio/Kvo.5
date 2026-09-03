class_name HitReport
extends RefCounted

## The complete causal record of one projectile meeting one ship.
##
## This is not debug decoration bolted onto a damage number — it IS the damage
## mechanism. The DamageResolver reads this to decide what broke; the debug overlay
## and the combat log render the same object. There is no separate path where a
## shell "does damage" without one of these existing to explain it.
##
## The chain it records is the project's central claim:
##
##     projectile -> impact -> armour interactions -> internal path
##                -> compartments -> components -> effects -> derived state
##
## Because every layer's before and after state is kept, a player asking "why did my
## ship die" can be shown the actual answer rather than a summary of it.

enum InteractionKind {
	ARMOR,              ## an armour plate, resolved through the penetration model
	STRUCTURE,          ## plating or an ordinary bulkhead
	COMPARTMENT_ENTER,
	COMPARTMENT_EXIT,
	COMPONENT,
	HULL_EXIT,          ## left the ship without detonating: overpenetration
}

enum Termination {
	NONE,
	DETONATED,          ## burst inside
	STOPPED,            ## a plate held
	SHATTERED,          ## broke up on a plate
	EXITED,             ## overpenetration
	INTERACTION_LIMIT,  ## safety stop; should not happen in practice
}


## One thing the shell met, with its state either side of the meeting.
class LayerInteraction extends RefCounted:
	var order: int = 0
	var kind: InteractionKind = InteractionKind.STRUCTURE
	var zone: String = ""
	var label: String = ""
	var primitive_index: int = -1

	var distance_m: float = 0.0        ## along the path from the point of impact
	var local_point: Vector3 = Vector3.ZERO
	var world_point: Vector2 = Vector2.ZERO
	var depth_below_waterline: float = 0.0

	var speed_before: float = 0.0
	var speed_after: float = 0.0
	var energy_before: float = 0.0
	var energy_after: float = 0.0
	var integrity_before: float = 1.0
	var integrity_after: float = 1.0

	## Present only for ARMOR and STRUCTURE interactions.
	var outcome: PenetrationOutcome = null

	func to_dict() -> Dictionary:
		var d: Dictionary = {
			"order": order,
			"kind": ["armour", "structure", "enterCompartment", "exitCompartment",
				"component", "hullExit"][int(kind)],
			"zone": zone,
			"label": label,
			"distanceM": distance_m,
			"speedBefore": speed_before,
			"speedAfter": speed_after,
			"energyBefore": energy_before,
			"energyAfter": energy_after,
		}
		if outcome != null:
			d["penetration"] = outcome.to_dict()
		return d


# -- what was fired -----------------------------------------------------------
var projectile_id: int = 0
var shooter_id: int = 0
var target_id: int = 0
var shell_id: String = ""
var shell_name: String = ""
var calibre_mm: float = 0.0
var mass_kg: float = 0.0
var range_m: float = 0.0
var time_of_flight: float = 0.0

# -- where and how it arrived -------------------------------------------------
var impact_world: Vector2 = Vector2.ZERO
var impact_local: Vector3 = Vector3.ZERO
var impact_velocity: Vector3 = Vector3.ZERO
var striking_velocity: float = 0.0
var descent_angle_deg: float = 0.0
var aspect_deg: float = 0.0        ## bearing of the shell relative to the target's bow
var hit_above_water: bool = true

# -- what it met, in order ----------------------------------------------------
var interactions: Array[LayerInteraction] = []
var compartments_entered: PackedInt32Array = PackedInt32Array()
var components_hit: PackedInt32Array = PackedInt32Array()

# -- how it ended -------------------------------------------------------------
var termination: Termination = Termination.NONE
var detonated: bool = false
var detonation_local: Vector3 = Vector3.ZERO
var detonation_compartment: int = -1
var detonation_energy_j: float = 0.0
var burster_charge_kg: float = 0.0
var path_length_m: float = 0.0

## Distance from the ray's origin to where it entered the hull. The projectile system
## uses it to confirm the entry falls inside THIS tick's step rather than somewhere
## the shell has not reached yet.
var entry_distance_m: float = INF
var final_speed: float = 0.0
var deepest_penetration_mm: float = 0.0

## Set by the DamageResolver in Stage 4. Kept on the report so the whole causal chain
## — from the plate that was struck to the integrity that was lost — lives in one
## object rather than being scattered across systems.
var damage: DamageReport = null


func add(interaction: LayerInteraction) -> void:
	interaction.order = interactions.size()
	interactions.append(interaction)


## Did the shell get through everything protecting the interior?
func penetrated_armour() -> bool:
	for interaction: LayerInteraction in interactions:
		if interaction.kind == InteractionKind.ARMOR and interaction.outcome != null:
			if interaction.outcome.result == PenetrationOutcome.Result.PENETRATED:
				return true
	return false


## Struck real armour and failed to get through it — the case that must cost a ship
## no structural integrity at all.
func was_defeated_by_armour() -> bool:
	if detonated:
		return false
	for interaction: LayerInteraction in interactions:
		if interaction.kind != InteractionKind.ARMOR or interaction.outcome == null:
			continue
		var result: PenetrationOutcome.Result = interaction.outcome.result
		if result == PenetrationOutcome.Result.STOPPED or result == PenetrationOutcome.Result.RICOCHET \
				or result == PenetrationOutcome.Result.SHATTERED:
			return true
	return false


## Total mass of fragments thrown off the inner faces of plates along the path.
func total_spall_kg() -> float:
	var total: float = 0.0
	for interaction: LayerInteraction in interactions:
		if interaction.outcome != null:
			total += interaction.outcome.spall_mass_kg
	return total


func armour_interactions() -> Array[LayerInteraction]:
	var out: Array[LayerInteraction] = []
	for interaction: LayerInteraction in interactions:
		if interaction.kind == InteractionKind.ARMOR:
			out.append(interaction)
	return out


static func termination_to_string(value: Termination) -> String:
	match value:
		Termination.DETONATED: return "detonated inside"
		Termination.STOPPED: return "stopped by armour"
		Termination.SHATTERED: return "shell shattered"
		Termination.EXITED: return "overpenetration"
		Termination.INTERACTION_LIMIT: return "interaction limit"
		_: return "none"


func to_dict() -> Dictionary:
	var layers: Array = []
	for interaction: LayerInteraction in interactions:
		layers.append(interaction.to_dict())
	return {
		"shell": shell_name,
		"calibreMm": calibre_mm,
		"rangeM": range_m,
		"strikingVelocityMs": striking_velocity,
		"descentAngleDeg": descent_angle_deg,
		"aspectDeg": aspect_deg,
		"impactLocal": Serializer.vec3_to_array(impact_local),
		"aboveWater": hit_above_water,
		"interactions": layers,
		"termination": termination_to_string(termination),
		"detonated": detonated,
		"pathLengthM": path_length_m,
		"damage": damage.to_dict() if damage != null else null,
	}
