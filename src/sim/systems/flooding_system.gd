class_name FloodingSystem
extends RefCounted

## Water coming in, and what that does to the ship.
##
## Torricelli: water enters a hole at a rate set by the hole's area and its depth
## below the surface, `Q = Cd · A · sqrt(2gh)`. That single relationship carries most
## of the behaviour worth having. Damage low down is far worse than damage high up.
## And as a ship floods she settles deeper, which increases `h` on every hole she
## already has — so flooding accelerates itself, which is exactly how a damaged ship
## that looked stable half an hour ago suddenly goes.
##
## Flooding is LOCAL. One opened compartment floods one compartment. It spreads only
## through boundaries that damage has actually opened, which is what makes
## subdivision worth anything and why a torpedo hit is survivable at all.

const RNG_STREAM: String = "flooding"


static func step(ship: ShipEntity, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, dt: float,
		rng: DeterministicRng) -> void:
	var flooding: Dictionary = config.get("flooding", {}) as Dictionary
	var permeability: Dictionary = (config.get("compartments", {}) as Dictionary) \
		.get("permeability", {}) as Dictionary
	var discharge: float = float(flooding.get("dischargeCoefficient", 0.62))

	# How much deeper she is already sitting. Every hole gets this much more head.
	var sinkage: float = _sinkage(ship, template, state, permeability)

	for i: int in state.compartments.size():
		var compartment: ShipStructureState.CompartmentState = state.compartments[i]
		if compartment == null or not compartment.breached or compartment.flood >= 1.0:
			continue
		if compartment.breach_area_m2 <= 0.0:
			continue

		var head: float = compartment.breach_depth_m + sinkage
		if head <= 0.0:
			continue
		var inflow: float = discharge * compartment.breach_area_m2 \
			* sqrt(2.0 * SimUnits.GRAVITY * head)

		var volume: GeometryPrimitives.Volume = template.volumes[i]
		var permeable: float = float(permeability.get(volume.role, permeability.get("default", 0.9)))
		var capacity: float = maxf(volume.volume_m3() * permeable, 0.1)
		compartment.flood = clampf(compartment.flood + (inflow * dt) / capacity, 0.0, 1.0)

		# Water puts fires out. Not a consolation: a flooded machinery space is as
		# useless as a burning one.
		if compartment.flood > 0.5:
			compartment.fire = 0.0

	_spread(template, state, flooding, dt, rng)


## Spread through boundaries that damage has opened.
##
## A compartment full to the deckhead pushes into a neighbour whose boundary has been
## wrecked or opened. An intact bulkhead holds, which is the whole point of having one.
static func _spread(template: ShipStructureTemplate, state: ShipStructureState,
		flooding: Dictionary, dt: float, rng: DeterministicRng) -> void:
	var chance: float = float(
		flooding.get("spreadChancePerSecondThroughDamagedBoundary", 0.05)) * dt
	if chance <= 0.0:
		return

	for i: int in state.compartments.size():
		var source: ShipStructureState.CompartmentState = state.compartments[i]
		if source == null or source.flood < 0.95:
			continue
		var origin: GeometryPrimitives.Volume = template.volumes[i]
		for j: int in state.compartments.size():
			if j == i:
				continue
			var target: ShipStructureState.CompartmentState = state.compartments[j]
			if target == null or target.breached or target.flood >= 1.0:
				continue
			var neighbour: GeometryPrimitives.Volume = template.volumes[j]
			if not _adjacent(origin, neighbour):
				continue
			# Only a damaged boundary lets water through.
			if target.wreckage < 0.15 and source.wreckage < 0.15:
				continue
			if rng.chance(chance):
				target.breached = true
				target.breach_area_m2 = maxf(target.breach_area_m2, 0.35)
				target.breach_depth_m = maxf(target.breach_depth_m,
					maxf(-neighbour.centre().z, 0.5))


## Two compartments share a boundary if their boxes touch.
static func _adjacent(a: GeometryPrimitives.Volume, b: GeometryPrimitives.Volume) -> bool:
	const TOLERANCE: float = 0.35
	return (a.minimum.x <= b.maximum.x + TOLERANCE and b.minimum.x <= a.maximum.x + TOLERANCE
		and a.minimum.y <= b.maximum.y + TOLERANCE and b.minimum.y <= a.maximum.y + TOLERANCE
		and a.minimum.z <= b.maximum.z + TOLERANCE and b.minimum.z <= a.maximum.z + TOLERANCE)


## Extra draft from the water already aboard, in metres.
##
## Added to the head over every hole, which is the mechanism by which a flooding ship
## floods faster the more she has taken.
static func _sinkage(ship: ShipEntity, template: ShipStructureTemplate,
		state: ShipStructureState, permeability: Dictionary) -> float:
	var water: float = state.flooded_volume(template, permeability)
	if water <= 0.0:
		return 0.0
	var waterplane: float = maxf(ship.spec.hull().waterplane_area(), 1.0)
	return water / waterplane
