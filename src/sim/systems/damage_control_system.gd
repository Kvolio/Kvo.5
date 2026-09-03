class_name DamageControlSystem
extends RefCounted

## The crew fighting to save the ship.
##
## The important property is that effort is FINITE and is spread across every
## emergency at once. Two fires are each fought half as well as one would be; five
## are barely fought at all. That is how severe damage overwhelms a crew — not by a
## threshold that switches damage control off, but by there being too much of it,
## which is what actually happened aboard ships that were lost to damage they had
## initially contained.
##
## Casualties compound it directly: fewer people means fewer parties means each
## emergency gets less attention, so a ship that has been badly hurt is worse at
## coping with the next hit than she was with the last.

const RNG_STREAM: String = "damage_control"


## One thing the crew is trying to deal with.
class Emergency extends RefCounted:
	var compartment: int = -1
	var component: int = -1
	var priority: float = 0.0
	var kind: StringName = &""


static func step(ship: ShipEntity, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, dt: float) -> void:
	var control: Dictionary = config.get("damageControl", {}) as Dictionary
	if control.is_empty() or ship.status == ShipEntity.Status.DESTROYED:
		return

	var emergencies: Array[Emergency] = _survey(ship, template, state, control)
	if emergencies.is_empty():
		return

	# Parties available scale with the crew still alive. A ship that has taken heavy
	# casualties fights her fires with fewer people, which is exactly when she has
	# most of them to fight.
	var parties: float = float(control.get("basePartiesPerThousandCrew", 3.0)) \
		* (float(state.crew_alive) / 1000.0)
	if parties <= 0.0:
		return

	# Highest priority first, then spread what there is. Nothing is abandoned outright
	# — it is simply attended to badly, which is the honest model of being swamped.
	emergencies.sort_custom(func(a: Emergency, b: Emergency) -> bool:
		if not is_equal_approx(a.priority, b.priority):
			return a.priority > b.priority
		return a.compartment < b.compartment)

	var effort_each: float = clampf(parties / float(emergencies.size()), 0.0, 1.0)
	for emergency: Emergency in emergencies:
		_attend(emergency, template, state, control, effort_each * dt)


## Everything currently wrong with the ship that a party could work on.
static func _survey(ship: ShipEntity, template: ShipStructureTemplate,
		state: ShipStructureState, control: Dictionary) -> Array[Emergency]:
	var priority: Dictionary = control.get("priority", {}) as Dictionary
	var flood_limit: float = float(control.get("cannotWorkAboveFloodLevel", 0.85))
	var fire_limit: float = float(control.get("cannotWorkAboveFireLevel", 0.90))
	var out: Array[Emergency] = []

	for i: int in state.compartments.size():
		var compartment: ShipStructureState.CompartmentState = state.compartments[i]
		if compartment == null:
			continue
		var volume: GeometryPrimitives.Volume = template.volumes[i]

		if compartment.fire > 0.01 and compartment.fire < fire_limit:
			var emergency: Emergency = Emergency.new()
			emergency.compartment = i
			emergency.kind = &"fire"
			# A fire beside the shell rooms outranks everything else aboard.
			emergency.priority = (float(priority.get("fireNearMagazine", 100.0))
				if _near_magazine(template, i) else float(priority.get("fire", 60.0)))
			out.append(emergency)

		if (compartment.flood > 0.01 and compartment.flood < flood_limit) \
				or compartment.breach_area_m2 > 0.0:
			var emergency: Emergency = Emergency.new()
			emergency.compartment = i
			emergency.kind = &"flooding"
			if volume.role == ShipStructureBuilder.ROLE_MAGAZINE:
				emergency.priority = float(priority.get("magazineFlooding", 90.0))
			elif volume.centre().z < 0.0:
				emergency.priority = float(priority.get("floodingBelowWaterline", 50.0))
			else:
				emergency.priority = float(priority.get("flooding", 30.0))
			out.append(emergency)

	# Repairs come last, and only for things that are not beyond saving.
	for i: int in state.components.size():
		var component: ShipStructureState.ComponentState = state.components[i]
		if component == null or component.state == 0 or component.state == 3:
			continue
		var emergency: Emergency = Emergency.new()
		emergency.component = i
		emergency.kind = &"repair"
		emergency.priority = float(priority.get("componentRepair", 10.0))
		out.append(emergency)
	return out


static func _attend(emergency: Emergency, template: ShipStructureTemplate,
		state: ShipStructureState, control: Dictionary, effort: float) -> void:
	match emergency.kind:
		&"fire":
			var compartment: ShipStructureState.CompartmentState = state.compartment(emergency.compartment)
			if compartment != null:
				compartment.fire = maxf(compartment.fire
					- float(control.get("fireSuppressionPerSecond", 0.030)) * effort, 0.0)
		&"flooding":
			var compartment: ShipStructureState.CompartmentState = state.compartment(emergency.compartment)
			if compartment == null:
				return
			# Shore and plug first. Pumping against an open hole is wasted work, and
			# the model says so: the sealing rate gates the pumping.
			compartment.breach_area_m2 = maxf(compartment.breach_area_m2
				- float(control.get("breachSealingM2PerSecond", 0.008)) * effort, 0.0)
			if compartment.breach_area_m2 <= 0.0:
				compartment.breached = false
				compartment.flood = maxf(compartment.flood
					- float(control.get("floodPumpingPerSecond", 0.010)) * effort, 0.0)
		&"repair":
			var component: ShipStructureState.ComponentState = state.component(emergency.component)
			if component != null:
				component.condition = clampf(component.condition
					+ float(control.get("componentRepairPerSecond", 0.004)) * effort, 0.0, 1.0)
		_:
			pass


static func _near_magazine(template: ShipStructureTemplate, index: int) -> bool:
	var centre: Vector3 = template.volumes[index].centre()
	for magazine: int in template.volumes_with_role(ShipStructureBuilder.ROLE_MAGAZINE):
		if template.volumes[magazine].centre().distance_to(centre) < 18.0:
			return true
	return false
