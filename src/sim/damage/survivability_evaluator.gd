class_name SurvivabilityEvaluator
extends RefCounted

## Works out what condition a ship is in, and whether she is still in the fight.
##
## TWO SEPARATE QUESTIONS, deliberately answered separately.
##
## `structural_integrity()` produces the single headline number the UI, the scenario
## victory rules and the designer's survivability estimate all want. It is RECOMPUTED
## from the ship's condition every time that condition changes. Nothing decrements it,
## and no shell contributes to it directly.
##
## `evaluate()` decides whether the ship is fighting, out of action, or gone — and it
## reads the CONDITIONS, not the number. A ship founders because there is no reserve
## buoyancy left; she capsizes because the heeling moment beat her righting arm; she
## is a mission kill because her main battery is wrecked. None of those is "integrity
## reached zero", which is why a 70%-integrity ship can be combat-dead and a
## 30%-integrity ship can fight on.

## What the ship's condition adds up to.
class Condition extends RefCounted:
	var integrity: float = 1.0
	var reserve_buoyancy: float = 1.0
	var list_deg: float = 0.0
	var trim_deg: float = 0.0
	var flooded_volume_m3: float = 0.0
	var flooded_fraction: float = 0.0
	var wrecked_fraction: float = 0.0
	var fire_fraction: float = 0.0
	var breach_area_m2: float = 0.0
	var main_barrels_fraction: float = 1.0
	var propulsion_fraction: float = 1.0
	var has_steering: bool = true
	var has_fire_control: bool = true
	var status: ShipEntity.Status = ShipEntity.Status.ACTIVE
	var reason: String = ""


## Measure everything, derive the integrity, and decide the status.
static func assess(ship: ShipEntity, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary) -> Condition:
	var condition: Condition = Condition.new()
	var integrity_config: Dictionary = config.get("integrity", {}) as Dictionary
	var stability: Dictionary = config.get("stability", {}) as Dictionary
	var compartment_config: Dictionary = config.get("compartments", {}) as Dictionary
	var permeability: Dictionary = compartment_config.get("permeability", {}) as Dictionary
	var contribution: Dictionary = compartment_config.get("structuralContribution", {}) as Dictionary

	var total_volume: float = 0.0
	var weighted_total: float = 0.0
	var wrecked_weighted: float = 0.0
	var flooded: float = 0.0
	var burning: float = 0.0
	var heel_moment: float = 0.0
	var trim_moment: float = 0.0

	for i: int in state.compartments.size():
		var compartment: ShipStructureState.CompartmentState = state.compartments[i]
		if compartment == null:
			continue
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		var size: float = volume.volume_m3()
		var weight: float = float(contribution.get(volume.role, contribution.get("default", 0.8)))
		total_volume += size
		weighted_total += size * weight
		wrecked_weighted += size * weight * compartment.wreckage
		burning += size * compartment.fire
		condition.breach_area_m2 += compartment.breach_area_m2

		if compartment.flood > 0.0:
			var permeable: float = float(permeability.get(volume.role, permeability.get("default", 0.9)))
			var water: float = size * permeable * compartment.flood
			flooded += water
			# Water sitting off the centreline heels the ship; water forward or aft
			# trims her. Both fall out of where the flooded compartments are.
			heel_moment += water * volume.centre().y
			trim_moment += water * volume.centre().x

	condition.flooded_volume_m3 = flooded
	condition.flooded_fraction = 0.0 if total_volume <= 0.0 else flooded / total_volume
	condition.wrecked_fraction = 0.0 if weighted_total <= 0.0 else wrecked_weighted / weighted_total
	condition.fire_fraction = 0.0 if total_volume <= 0.0 else burning / total_volume

	# Reserve buoyancy is the watertight volume standing ABOVE the waterline — the
	# difference between what the hull encloses and what she already displaces. It is
	# not "volume not yet flooded": a ship floats on her freeboard, and she goes down
	# when the water aboard exceeds it, typically at something under half her volume
	# rather than at all of it.
	var displaced: float = ship.spec.displacement_t * SimUnits.TONNE_TO_KG / SimUnits.SEAWATER_DENSITY
	var reserve_volume: float = maxf(total_volume - displaced, total_volume * 0.05)
	condition.reserve_buoyancy = clampf(1.0 - flooded / reserve_volume, 0.0, 1.0)

	_compute_attitude(condition, ship, flooded, heel_moment, trim_moment, stability)

	# --- the derived headline number ----------------------------------------
	# Breach area is compared against the ship's own plating area, not against her
	# length: an area over a length is dimensionally meaningless, and it made a hole
	# of a given size count for ten times as much on a destroyer as it should. Half
	# the waterplane area is a serviceable proxy for how much shell plating there is
	# to hole.
	var plating_area: float = maxf(ship.spec.hull().waterplane_area() * 0.5, 1.0)
	var breach_fraction: float = clampf(condition.breach_area_m2 / plating_area, 0.0, 1.0)
	condition.integrity = clampf(1.0
		- float(integrity_config.get("wreckageWeight", 0.55)) * condition.wrecked_fraction
		- float(integrity_config.get("breachWeight", 0.15)) * breach_fraction
		- float(integrity_config.get("floodingWeight", 0.18)) * condition.flooded_fraction
		- float(integrity_config.get("fireWeight", 0.07)) * condition.fire_fraction
		- float(integrity_config.get("girderWeight", 0.05)) * state.girder_damage,
		0.0, 1.0)

	_measure_fighting_ability(condition, ship, template, state)
	_decide_status(condition, state, config)
	return condition


## Draft, list and trim from where the water actually is.
static func _compute_attitude(condition: Condition, ship: ShipEntity, flooded: float,
		heel_moment: float, trim_moment: float, stability: Dictionary) -> void:
	if flooded <= 0.0:
		return
	var water_mass: float = flooded * SimUnits.SEAWATER_DENSITY
	var total_mass: float = ship.spec.mass_kg() + water_mass
	# Until the ship designer computes a real metacentric height in Stage 6, GM is
	# taken as a fraction of beam — the usual first approximation for a warship.
	var gm: float = ship.spec.beam_m * float(stability.get("metacentricHeightFactor", 0.055))
	var righting: float = total_mass * maxf(gm, 0.01)
	if righting > 0.0:
		var heel_lever: float = heel_moment * SimUnits.SEAWATER_DENSITY
		condition.list_deg = rad_to_deg(asin(clampf(heel_lever / righting, -1.0, 1.0)))
		# Longitudinal stability is far greater than transverse, which is why ships
		# heel dramatically and trim gently.
		var trim_righting: float = total_mass * maxf(ship.spec.length_m * 0.25, 1.0)
		condition.trim_deg = rad_to_deg(asin(clampf(
			(trim_moment * SimUnits.SEAWATER_DENSITY) / trim_righting, -1.0, 1.0)))


static func _measure_fighting_ability(condition: Condition, ship: ShipEntity,
		template: ShipStructureTemplate, state: ShipStructureState) -> void:
	var total_barrels: int = 0
	var live_barrels: int = 0
	for turret: Turret in ship.turrets:
		if turret.battery != &"main":
			continue
		total_barrels += turret.barrels()
		if turret.is_operational():
			live_barrels += turret.barrels()
	condition.main_barrels_fraction = (1.0 if total_barrels == 0
		else float(live_barrels) / float(total_barrels))

	condition.propulsion_fraction = ship.propulsion_fraction
	condition.has_steering = ship.rudder_effectiveness > 0.05 and not ship.rudder_jammed

	# Fire control is the directors and the radar together. Losing one director is a
	# serious degradation, not the end of the action: ships carried a second, and a
	# battery can still be fought in local control from the turrets. Only when there
	# is nothing left to lay the guns with does this become a mission kill.
	var directors: Array[ShipStructureState.ComponentState] = state.components_with_role(
		template, ShipStructureBuilder.COMPONENT_DIRECTOR)
	var radars: Array[ShipStructureState.ComponentState] = state.components_with_role(
		template, ShipStructureBuilder.COMPONENT_RADAR)
	condition.has_fire_control = directors.is_empty() and radars.is_empty()
	for component: ShipStructureState.ComponentState in (directors + radars):
		if component.is_operational():
			condition.has_fire_control = true
			break


## The conditions that end a ship, and the conditions that end her usefulness.
static func _decide_status(condition: Condition, state: ShipStructureState,
		config: Dictionary) -> void:
	var stability: Dictionary = config.get("stability", {}) as Dictionary
	var mission: Dictionary = config.get("missionKill", {}) as Dictionary

	if state.catastrophic:
		condition.status = ShipEntity.Status.DESTROYED
		condition.reason = state.catastrophe_reason
		return
	if condition.reserve_buoyancy <= float(stability.get("founderReserveBuoyancyFraction", 0.02)):
		condition.status = ShipEntity.Status.DESTROYED
		condition.reason = "foundered: no reserve buoyancy left"
		return
	if absf(condition.list_deg) >= float(stability.get("capsizeListDeg", 35.0)):
		condition.status = ShipEntity.Status.DESTROYED
		condition.reason = "capsized at %.0f degrees of list" % absf(condition.list_deg)
		return
	if absf(condition.trim_deg) >= float(stability.get("trimCapsizeDeg", 20.0)):
		condition.status = ShipEntity.Status.DESTROYED
		condition.reason = "went down by the %s" % ("head" if condition.trim_deg > 0.0 else "stern")
		return
	if state.girder_damage >= 1.0:
		condition.status = ShipEntity.Status.DESTROYED
		condition.reason = "hull broke in two"
		return

	# --- mission kill: afloat, but no longer able to fight -------------------
	var reasons: Array[String] = []
	if condition.main_barrels_fraction < float(mission.get("mainBatteryBarrelsFraction", 0.25)):
		reasons.append("main battery destroyed")
	if condition.propulsion_fraction < float(mission.get("propulsionFraction", 0.15)):
		reasons.append("propulsion lost")
	if not condition.has_steering:
		reasons.append("steering lost")
	if not condition.has_fire_control:
		reasons.append("fire control lost")
	if condition.flooded_fraction > float(mission.get("floodedVolumeFraction", 0.45)):
		reasons.append("flooding beyond control")

	if not reasons.is_empty():
		condition.status = ShipEntity.Status.MISSION_KILL
		condition.reason = "; ".join(reasons)
		return

	condition.status = ShipEntity.Status.ACTIVE
	condition.reason = ""


## Push component condition back into the ship's handling and gunnery.
##
## This is where "one shaft destroyed" becomes "slower and crabbing to port". The
## movement code knows nothing about shells; it reads these fractions.
static func apply_component_effects(ship: ShipEntity, template: ShipStructureTemplate,
		state: ShipStructureState) -> void:
	# Propulsion is engines and boilers together: a ship with every engine intact and
	# no steam is going nowhere.
	var engines: Array[ShipStructureState.ComponentState] = state.components_with_role(
		template, ShipStructureBuilder.COMPONENT_ENGINE)
	var boilers: Array[ShipStructureState.ComponentState] = state.components_with_role(
		template, ShipStructureBuilder.COMPONENT_BOILER)
	var engine_fraction: float = _working_fraction(engines)
	var boiler_fraction: float = _working_fraction(boilers)
	var shafts: Array[ShipStructureState.ComponentState] = state.components_with_role(
		template, ShipStructureBuilder.COMPONENT_SHAFT)
	var shaft_fraction: float = _working_fraction(shafts)
	ship.propulsion_fraction = clampf(
		minf(engine_fraction, boiler_fraction) * shaft_fraction, 0.0, 1.0)

	# A shaft lost on one side and not the other makes the ship crab, and she needs
	# opposite rudder to hold a course.
	ship.shaft_asymmetry = _shaft_imbalance(template, state)

	var steering: Array[ShipStructureState.ComponentState] = state.components_with_role(
		template, ShipStructureBuilder.COMPONENT_RUDDER)
	if not steering.is_empty():
		var condition: float = steering[0].condition
		ship.rudder_effectiveness = clampf(condition, 0.0, 1.0)
		# A wrecked steering gear leaves the rudder wherever it happened to be.
		ship.rudder_jammed = condition <= 0.05

	# Turrets follow their component condition directly.
	var turret_indices: PackedInt32Array = template.volumes_with_role(
		ShipStructureBuilder.COMPONENT_TURRET)
	for i: int in mini(turret_indices.size(), ship.main_battery_turrets().size()):
		var component: ShipStructureState.ComponentState = state.component(turret_indices[i])
		if component != null:
			ship.main_battery_turrets()[i].state = component.state as Turret.State


static func _working_fraction(components: Array[ShipStructureState.ComponentState]) -> float:
	if components.is_empty():
		return 1.0
	var total: float = 0.0
	for component: ShipStructureState.ComponentState in components:
		total += clampf(component.condition, 0.0, 1.0)
	return total / float(components.size())


## Net port/starboard thrust imbalance in [-1, 1]; negative means port is pushing harder.
static func _shaft_imbalance(template: ShipStructureTemplate, state: ShipStructureState) -> float:
	var port: float = 0.0
	var starboard: float = 0.0
	var count: float = 0.0
	for index: int in template.volumes_with_role(ShipStructureBuilder.COMPONENT_SHAFT):
		var component: ShipStructureState.ComponentState = state.component(index)
		if component == null:
			continue
		count += 1.0
		if template.volumes[index].centre().y < 0.0:
			port += clampf(component.condition, 0.0, 1.0)
		else:
			starboard += clampf(component.condition, 0.0, 1.0)
	if count <= 0.0:
		return 0.0
	return clampf((starboard - port) / count, -1.0, 1.0)
