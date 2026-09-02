class_name DamageResolver
extends RefCounted

## Turns a resolved hit into what actually broke.
##
## THE RULE THIS CLASS EXISTS TO ENFORCE: a clean non-penetration costs ZERO
## structural integrity. Not a small fraction — zero. A belt that stops a shell has
## done its job, and the ship is structurally exactly as sound as she was a moment
## earlier. What such a hit can still do is real and often serious — spall behind the
## plate, concussion through it, and the wholesale removal of unarmoured equipment
## near the impact — but every one of those is a modelled mechanism with a cause.
##
## There is no per-shell damage number anywhere in here. Energy released inside a
## compartment wrecks a volume of ship; a hull opened below the waterline admits
## water; fragments break equipment they reach. Structural integrity is then derived
## from those conditions by SurvivabilityEvaluator, never accumulated here.

const RNG_STREAM: String = "damage"


static func resolve(
	report: HitReport, ship: ShipEntity, template: ShipStructureTemplate,
	state: ShipStructureState, config: Dictionary, rng: DeterministicRng
) -> DamageReport:
	var damage: DamageReport = DamageReport.new()
	var before: SurvivabilityEvaluator.Condition = SurvivabilityEvaluator.assess(
		ship, template, state, config)
	damage.integrity_before = before.integrity

	for interaction: HitReport.LayerInteraction in report.interactions:
		match interaction.kind:
			HitReport.InteractionKind.ARMOR, HitReport.InteractionKind.STRUCTURE:
				_resolve_plate(damage, interaction, ship, template, state, config, rng)
			HitReport.InteractionKind.COMPONENT:
				_resolve_component_strike(damage, interaction, template, state, config)
			_:
				pass

	if report.detonated:
		_resolve_detonation(damage, report, ship, template, state, config, rng)

	SurvivabilityEvaluator.apply_component_effects(ship, template, state)
	var after: SurvivabilityEvaluator.Condition = SurvivabilityEvaluator.assess(
		ship, template, state, config)
	damage.integrity_after = after.integrity
	damage.catastrophic = state.catastrophic
	damage.catastrophe_reason = state.catastrophe_reason
	report.damage = damage
	return damage


# ------------------------------------------------------------------- plates --

static func _resolve_plate(
	damage: DamageReport, interaction: HitReport.LayerInteraction,
	ship: ShipEntity, template: ShipStructureTemplate, state: ShipStructureState,
	config: Dictionary, rng: DeterministicRng
) -> void:
	var outcome: PenetrationOutcome = interaction.outcome
	if outcome == null:
		return
	var non_penetration: Dictionary = config.get("nonPenetration", {}) as Dictionary

	# A plate that has been hit before resists less. This accumulates whether or not
	# the shell got through.
	state.add_deformation(interaction.primitive_index,
		outcome.plate_deformation_added * float(non_penetration.get("plateDeformationTransfer", 1.0)))

	var defeated: bool = (outcome.result == PenetrationOutcome.Result.STOPPED
		or outcome.result == PenetrationOutcome.Result.RICOCHET
		or outcome.result == PenetrationOutcome.Result.SHATTERED)

	if defeated:
		# ---- ZERO structural integrity. Everything below is a separate mechanism. --
		damage.add_effect(&"armour_held", interaction.zone, 0.0,
			"%s defeated the shell; no structural damage" % interaction.zone,
			interaction.primitive_index)
		_apply_spall(damage, interaction, template, state, config)
		_apply_shock(damage, interaction, template, state, config)
		_wreck_exposed_equipment(damage, interaction, template, state, config)
		_local_casualties(damage, interaction, template, state, config,
			float(non_penetration.get("crewCasualtiesPerMegajoule", 0.09)))
		return

	# The shell got through. If it opened the hull at or below the waterline, the sea
	# comes in — and that is decided by geometry, not by which plate it was.
	if interaction.depth_below_waterline > 0.0:
		_open_hull(damage, interaction, ship, template, state, interaction.local_point,
			ship.spec.length_m * 0.004)


## Fragments off the inner face of a plate, whether or not it was beaten.
static func _apply_spall(damage: DamageReport, interaction: HitReport.LayerInteraction,
		template: ShipStructureTemplate, state: ShipStructureState, config: Dictionary) -> void:
	var outcome: PenetrationOutcome = interaction.outcome
	if outcome.spall_mass_kg <= 0.0:
		return
	var non_penetration: Dictionary = config.get("nonPenetration", {}) as Dictionary
	var energy: float = outcome.spall_mass_kg * float(non_penetration.get("spallEnergyPerKg", 900000.0))
	# Fragments travel a short way behind the plate and break what they reach.
	var radius: float = clampf(outcome.spall_mass_kg * 1.6, 1.0, 12.0)
	var hurt: int = _damage_components_near(damage, template, state, config,
		interaction.local_point, radius, clampf(energy / 4.0e6, 0.05, 0.9), true)
	damage.add_effect(&"spall", interaction.zone, outcome.spall_mass_kg,
		"%.1f kg of fragments off the back of the plate, %d fitting%s hit"
			% [outcome.spall_mass_kg, hurt, "" if hurt == 1 else "s"],
		interaction.primitive_index)


## Concussion through intact armour. Delicate equipment suffers even when the plate
## holds — this is why a heavy non-penetrating hit can still blind a ship.
static func _apply_shock(damage: DamageReport, interaction: HitReport.LayerInteraction,
		template: ShipStructureTemplate, state: ShipStructureState, config: Dictionary) -> void:
	var non_penetration: Dictionary = config.get("nonPenetration", {}) as Dictionary
	var megajoules: float = interaction.energy_before / 1.0e6
	if megajoules <= 0.5:
		return
	var radius: float = minf(megajoules * float(non_penetration.get("shockRadiusPerMegajoule", 0.9)),
		float(non_penetration.get("shockMaxRadiusM", 25.0)))
	var severity: float = float(non_penetration.get("shockComponentDamage", 0.30)) \
		* clampf(megajoules / 100.0, 0.05, 1.0)
	var hurt: int = _damage_components_near(damage, template, state, config,
		interaction.local_point, radius, severity, true)
	if hurt > 0:
		damage.add_effect(&"shock", interaction.zone, severity,
			"%.0f MJ of concussion through the plate shook %d fitting%s"
				% [megajoules, hurt, "" if hurt == 1 else "s"],
			interaction.primitive_index)


## Unarmoured fittings near the impact: anti-aircraft mounts, rangefinders, optics,
## radar, boats. A non-penetrating hit is very good at removing these, which is how a
## ship can be untouched structurally and half-blind.
static func _wreck_exposed_equipment(damage: DamageReport, interaction: HitReport.LayerInteraction,
		template: ShipStructureTemplate, state: ShipStructureState, config: Dictionary) -> void:
	if interaction.local_point.z < template.main_deck_z:
		return  # below the weather deck there is nothing exposed to wreck
	var non_penetration: Dictionary = config.get("nonPenetration", {}) as Dictionary
	var hurt: int = _damage_components_near(damage, template, state, config,
		interaction.local_point,
		float(non_penetration.get("exposedEquipmentRadiusM", 18.0)),
		float(non_penetration.get("exposedEquipmentDamage", 0.75)), false)
	if hurt > 0:
		damage.add_effect(&"equipment_wrecked", interaction.zone, float(hurt),
			"%d exposed fitting%s destroyed above deck" % [hurt, "" if hurt == 1 else "s"],
			interaction.primitive_index)


# --------------------------------------------------------------- detonation --

static func _resolve_detonation(
	damage: DamageReport, report: HitReport, ship: ShipEntity,
	template: ShipStructureTemplate, state: ShipStructureState,
	config: Dictionary, rng: DeterministicRng
) -> void:
	var detonation: Dictionary = config.get("detonation", {}) as Dictionary
	var energy: float = report.detonation_energy_j
	var megajoules: float = energy / 1.0e6
	var wreckable: float = energy / maxf(
		float(detonation.get("energyPerWreckedCubicMetre", 2.2e6)), 1.0)

	var compartment_index: int = report.detonation_compartment
	if compartment_index < 0:
		compartment_index = _compartment_at(template, state, report.detonation_local)

	var wrecked: float = _wreck_compartment(damage, template, state, config,
		compartment_index, wreckable, report.detonation_local)

	# A burst does not stop politely at a bulkhead.
	var spill: float = (wreckable - wrecked) \
		+ wreckable * float(detonation.get("adjacentCompartmentFraction", 0.30))
	if spill > 0.0:
		_wreck_neighbours(damage, template, state, config, report.detonation_local,
			compartment_index, spill)

	_detonation_casualties(damage, template, state, config, compartment_index, megajoules)

	# Fire. What is in the compartment matters far more than how big the shell was.
	var fire_chance: float = minf(
		megajoules * float(detonation.get("fireChancePerMegajoule", 0.0045)),
		float(detonation.get("maxFireChance", 0.85)))
	var compartment: ShipStructureState.CompartmentState = state.compartment(compartment_index)
	if compartment != null and compartment.flood < 0.5 and rng.chance(fire_chance):
		compartment.fire = maxf(compartment.fire, clampf(megajoules / 120.0, 0.15, 1.0))
		damage.add_effect(&"fire", template.volumes[compartment_index].label,
			compartment.fire, "fire started by the burst", compartment_index)

	# Opened the hull, if it burst near the shell plating below water.
	if report.detonation_local.z < 0.0:
		_open_hull(damage, null, ship, template, state, report.detonation_local,
			megajoules * float(detonation.get("breachRadiusPerMegajoule", 0.011)))

	_check_magazine(damage, template, state, config, compartment_index, megajoules, rng)


## Wreck as much of one compartment as the energy allows. Returns the volume consumed.
static func _wreck_compartment(damage: DamageReport, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, index: int, available: float,
		point: Vector3) -> float:
	var compartment: ShipStructureState.CompartmentState = state.compartment(index)
	if compartment == null or available <= 0.0:
		return 0.0
	var volume: GeometryPrimitives.Volume = template.volumes[index]
	var remaining_volume: float = volume.volume_m3() * (1.0 - compartment.wreckage)
	var consumed: float = minf(available, remaining_volume)
	compartment.wreckage = clampf(
		compartment.wreckage + consumed / maxf(volume.volume_m3(), 1.0), 0.0, 1.0)

	# Anything installed in a compartment goes with it.
	_damage_components_near(damage, template, state, config, volume.centre(),
		volume.size().length() * 0.5, compartment.wreckage, false)

	damage.add_effect(&"wreckage", volume.label, compartment.wreckage,
		"%.0f cubic metres destroyed" % consumed, index)
	return consumed


static func _wreck_neighbours(damage: DamageReport, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, point: Vector3,
		skip: int, available: float) -> void:
	var neighbours: PackedInt32Array = _compartments_near(template, point, 14.0, skip)
	if neighbours.is_empty():
		return
	var share: float = available / float(neighbours.size())
	for index: int in neighbours:
		_wreck_compartment(damage, template, state, config, index, share, point)


static func _detonation_casualties(damage: DamageReport, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, index: int, megajoules: float) -> void:
	var crew_config: Dictionary = config.get("crew", {}) as Dictionary
	var compartment: ShipStructureState.CompartmentState = state.compartment(index)
	if compartment == null:
		return
	var killed: int = int(round(megajoules
		* float(crew_config.get("casualtiesPerMegajouleInCompartment", 0.055))))
	killed = mini(killed, compartment.crew)
	if killed <= 0:
		return
	damage.crew_casualties += state.take_casualties(index, killed)
	damage.add_effect(&"casualties", template.volumes[index].label, float(killed),
		"%d of the compartment's people killed" % killed, index)


## Ammunition reached. The most consequential single event in a gun action.
static func _check_magazine(damage: DamageReport, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, index: int,
		megajoules: float, rng: DeterministicRng) -> void:
	var compartment: ShipStructureState.CompartmentState = state.compartment(index)
	if compartment == null or compartment.ammunition <= 0.0:
		return
	if template.volumes[index].role != ShipStructureBuilder.ROLE_MAGAZINE:
		return
	# Probability rises with the energy delivered among the charges. Stage 5 adds
	# flash protection and cook-off from fire; this is the direct route.
	var scale: float = float((config.get("detonation", {}) as Dictionary)
		.get("magazineIgnitionEnergyScale", 400.0))
	var chance: float = clampf(megajoules / maxf(scale, 1.0), 0.0, 0.9) * compartment.ammunition
	if not rng.chance(chance):
		damage.add_effect(&"magazine_threatened", template.volumes[index].label, chance,
			"burst among the charges but no ignition", index)
		return
	state.catastrophic = true
	state.catastrophe_reason = "magazine detonation in %s" % template.volumes[index].label
	compartment.ammunition = 0.0
	compartment.wreckage = 1.0
	# A ship lost this way goes in under a minute, usually with a handful of survivors.
	var fraction: float = float((config.get("crew", {}) as Dictionary)
		.get("magazineDetonationCasualtyFraction", 0.80))
	var lost: int = int(round(float(state.crew_alive) * clampf(fraction, 0.0, 1.0)))
	state.crew_alive = maxi(state.crew_alive - lost, 0)
	damage.crew_casualties += lost
	damage.catastrophic = true
	damage.catastrophe_reason = state.catastrophe_reason
	damage.add_effect(&"magazine_detonation", template.volumes[index].label, 1.0,
		"AMMUNITION DETONATION", index)


# ------------------------------------------------------------------ helpers --

## Open the hull to the sea. Water enters through the hole from here on.
static func _open_hull(damage: DamageReport, interaction: HitReport.LayerInteraction,
		ship: ShipEntity, template: ShipStructureTemplate, state: ShipStructureState,
		point: Vector3, radius: float) -> void:
	var index: int = _compartment_at(template, state, point)
	var compartment: ShipStructureState.CompartmentState = state.compartment(index)
	if compartment == null:
		return
	var area: float = PI * radius * radius
	compartment.breached = true
	compartment.breach_area_m2 += area
	# Deepest hole wins: it is the one doing the flooding.
	compartment.breach_depth_m = maxf(compartment.breach_depth_m, maxf(-point.z, 0.0))
	damage.add_effect(&"breach", template.volumes[index].label, area,
		"hull opened %.2f square metres, %.1f m below the waterline"
			% [area, maxf(-point.z, 0.0)], index)


static func _local_casualties(damage: DamageReport, interaction: HitReport.LayerInteraction,
		template: ShipStructureTemplate, state: ShipStructureState, config: Dictionary,
		per_megajoule: float) -> void:
	var index: int = _compartment_at(template, state, interaction.local_point)
	var compartment: ShipStructureState.CompartmentState = state.compartment(index)
	if compartment == null or compartment.crew <= 0:
		return
	var killed: int = mini(int(round((interaction.energy_before / 1.0e6) * per_megajoule)),
		compartment.crew)
	if killed <= 0:
		return
	damage.crew_casualties += state.take_casualties(index, killed)
	damage.add_effect(&"casualties", template.volumes[index].label, float(killed),
		"%d killed by the impact" % killed, index)


## A shell physically through a piece of equipment.
##
## The floor matters more than the scaling here. A rangefinder, a director or a
## generator that has had a shell go through it is wrecked whether the shell was five
## inches or sixteen; the energy term is what decides whether something as large as a
## turret is disabled or destroyed outright.
static func _resolve_component_strike(damage: DamageReport,
		interaction: HitReport.LayerInteraction, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary) -> void:
	var severity: float = clampf(0.40 + interaction.energy_before / 5.0e7, 0.40, 1.0)
	_damage_component(damage, template, state, config, interaction.primitive_index, severity, false)


## Damage every component within `radius` of a point. Returns how many were hurt.
static func _damage_components_near(damage: DamageReport, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, point: Vector3,
		radius: float, severity: float, apply_shock_vulnerability: bool) -> int:
	var hurt: int = 0
	for i: int in template.volumes.size():
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		if volume.kind != GeometryPrimitives.VolumeKind.COMPONENT:
			continue
		if volume.centre().distance_to(point) > radius:
			continue
		if _damage_component(damage, template, state, config, i, severity,
				apply_shock_vulnerability):
			hurt += 1
	return hurt


static func _damage_component(damage: DamageReport, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary, index: int,
		severity: float, apply_shock_vulnerability: bool) -> bool:
	var component: ShipStructureState.ComponentState = state.component(index)
	if component == null or component.condition <= 0.0:
		return false
	var volume: GeometryPrimitives.Volume = template.volumes[index]

	var amount: float = severity
	if apply_shock_vulnerability:
		# Radar and directors are delicate; a propeller shaft is a steel bar.
		var vulnerability: Dictionary = (config.get("components", {}) as Dictionary) \
			.get("shockVulnerability", {}) as Dictionary
		amount *= float(vulnerability.get(volume.role, vulnerability.get("default", 1.0)))

	var before: int = component.state
	component.condition = clampf(component.condition - amount, 0.0, 1.0)
	if component.state != before:
		damage.component_transitions.append("%s: %s" % [
			volume.label, ["operational", "damaged", "disabled", "destroyed"][component.state]])
		damage.add_effect(&"component", volume.label, component.condition,
			"now %s" % ["operational", "damaged", "disabled", "destroyed"][component.state], index)
	return true


## Index of the compartment containing a point, or -1.
static func _compartment_at(template: ShipStructureTemplate, state: ShipStructureState,
		point: Vector3) -> int:
	for i: int in template.volumes.size():
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		if volume.kind != GeometryPrimitives.VolumeKind.COMPARTMENT:
			continue
		if volume.contains(point):
			return i
	return -1


static func _compartments_near(template: ShipStructureTemplate, point: Vector3,
		radius: float, skip: int) -> PackedInt32Array:
	var found: PackedInt32Array = PackedInt32Array()
	for i: int in template.volumes.size():
		if i == skip:
			continue
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		if volume.kind != GeometryPrimitives.VolumeKind.COMPARTMENT:
			continue
		if volume.centre().distance_to(point) <= radius:
			found.append(i)
	return found
