class_name FireSystem
extends RefCounted

## Fire: the mechanism by which a ship that survived the hit dies an hour later.
##
## Fires grow, spread through the ship, consume the structure they burn through, and
## kill the people fighting them. Where they start matters enormously — a fire in a
## void is an inconvenience, a fire in the aviation fuel stowage or next to a magazine
## is how carriers and battlecruisers were lost.
##
## Nothing here subtracts from a health pool. Fire consumes compartment structure, and
## structural integrity is derived from what is left.

const RNG_STREAM: String = "fire"


static func step(ship: ShipEntity, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, dt: float,
		rng: DeterministicRng) -> void:
	var fire_config: Dictionary = config.get("fire", {}) as Dictionary
	var crew_config: Dictionary = config.get("crew", {}) as Dictionary
	var growth: float = float(fire_config.get("growthRatePerSecond", 0.02)) * dt
	var burnout: float = float(fire_config.get("burnoutRatePerSecond", 0.006)) * dt
	var consumption: float = float(
		fire_config.get("structureConsumedPerSecondAtFullIntensity", 0.010)) * dt
	var casualty_rate: float = float(crew_config.get("fireCasualtyRatePerSecond", 0.012)) * dt
	var exhaustion: float = float(fire_config.get("fuelExhaustionRate", 1.0)) * dt

	var burning: Array[int] = []
	for i: int in state.compartments.size():
		var compartment: ShipStructureState.CompartmentState = state.compartments[i]
		if compartment == null or compartment.fire <= 0.0:
			continue
		if compartment.flood > 0.5:
			compartment.fire = 0.0
			continue
		burning.append(i)

		# Grows towards a full blaze while there is something left to burn, then dies
		# away as the compartment is consumed. Without the fuel term a fire would burn
		# at full intensity for ever in a space that no longer exists.
		var fuel: float = clampf(1.0 - compartment.wreckage, 0.0, 1.0)
		compartment.fire = clampf(
			compartment.fire + growth * fuel - burnout * compartment.fire
				- exhaustion * compartment.fire * (1.0 - fuel),
			0.0, 1.0)
		compartment.wreckage = clampf(
			compartment.wreckage + consumption * compartment.fire, 0.0, 1.0)
		if fuel <= 0.02:
			compartment.fire = 0.0

		var killed: int = int(round(float(compartment.crew) * casualty_rate * compartment.fire))
		if killed > 0:
			state.take_casualties(i, killed)

		_check_cook_off(template, state, fire_config, i, compartment, dt, rng)

	_spread(template, state, fire_config, burning, dt, rng)


## Ammunition next to a fire. Slower than a shell reaching a magazine, and just as
## final — this is how a ship that survived the hit is lost hours later.
static func _check_cook_off(template: ShipStructureTemplate, state: ShipStructureState,
		fire_config: Dictionary, index: int,
		compartment: ShipStructureState.CompartmentState, dt: float,
		rng: DeterministicRng) -> void:
	if compartment.ammunition <= 0.0 or state.catastrophic:
		return
	if template.volumes[index].role != ShipStructureBuilder.ROLE_MAGAZINE:
		return
	var chance: float = float(
		fire_config.get("magazineCookOffChancePerSecondAtFullIntensity", 0.020)) \
		* compartment.fire * compartment.ammunition * dt
	if rng.chance(chance):
		state.catastrophic = true
		state.catastrophe_reason = "magazine cooked off: fire reached the charges in %s" \
			% template.volumes[index].label
		compartment.ammunition = 0.0
		compartment.wreckage = 1.0


static func _spread(template: ShipStructureTemplate, state: ShipStructureState,
		fire_config: Dictionary, burning: Array[int], dt: float,
		rng: DeterministicRng) -> void:
	if burning.is_empty():
		return
	var base: float = float(fire_config.get("spreadChancePerSecond", 0.035)) * dt
	var fuel_multiplier: float = float(fire_config.get("fuelCompartmentSpreadMultiplier", 2.5))
	var hangar_multiplier: float = float(fire_config.get("hangarSpreadMultiplier", 3.0))
	var magazine_multiplier: float = float(fire_config.get("magazineSpreadMultiplier", 0.15))

	for source_index: int in burning:
		var source: ShipStructureState.CompartmentState = state.compartments[source_index]
		for j: int in template.neighbours(source_index):
			var target: ShipStructureState.CompartmentState = state.compartments[j]
			if target == null or target.fire > 0.0 or target.flood > 0.5:
				continue
			var neighbour: GeometryPrimitives.Volume = template.volumes[j]

			# What is in the compartment decides how readily it takes fire. Aviation
			# petrol and fuel oil are why a survivable hit becomes a lost ship.
			var chance: float = base * source.fire
			match neighbour.role:
				ShipStructureBuilder.ROLE_FUEL:
					chance *= fuel_multiplier
				ShipStructureBuilder.ROLE_HANGAR:
					chance *= hangar_multiplier
				ShipStructureBuilder.ROLE_MAGAZINE:
					# Flash-tight, and flooded on suspicion. Fire reaches a magazine
					# rarely, which is exactly what makes it decisive when it does.
					chance *= magazine_multiplier
				ShipStructureBuilder.ROLE_VOID, ShipStructureBuilder.ROLE_BULGE:
					chance *= 0.15
				_:
					pass
			if rng.chance(chance):
				target.fire = 0.12
