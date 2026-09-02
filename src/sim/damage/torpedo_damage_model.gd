class_name TorpedoDamageModel
extends RefCounted

## What a torpedo does when it reaches a ship.
##
## A torpedo is NOT a projectile that penetrates. It detonates against the hull and
## the blast works its way inboard, being absorbed by whatever is in the way. That
## difference is why torpedo defence is modelled here as real layered structure —
## an expansion void to let the gas bubble vent, a liquid layer to spread the shock,
## a holding bulkhead to stop what is left — rather than as a percentage taken off a
## damage number.
##
## The consequence is the one that matters: an identical warhead against a
## battleship with a five-metre system and against a destroyer with none produces
## completely different results, because in one case the blast is spent in voids and
## fuel before it reaches anything vital, and in the other it opens her from keel to
## upper deck. Nothing says so; it falls out of walking the layers.
##
## Everything the blast reaches is opened to the sea. That is the torpedo's real
## weapon: not the wreckage, but the flooding that follows.

const RNG_STREAM: String = "torpedo"

## Bound on the inboard walk. A blast that has crossed this many layers has run out
## of ship.
const MAX_LAYERS: int = 48


## Detonate against a ship and apply everything that follows.
##
## `impact_world` is where it struck, `direction_world` the way it was running.
static func resolve(
	torpedo: TorpedoDef, impact_world: Vector3, direction_world: Vector3,
	ship: ShipEntity, template: ShipStructureTemplate, state: ShipStructureState,
	torpedo_config: Dictionary, damage_config: Dictionary, rng: DeterministicRng
) -> HitReport:
	var report: HitReport = HitReport.new()
	report.shell_name = torpedo.display_name
	report.shell_id = torpedo.torpedo_id
	report.calibre_mm = torpedo.diameter_m * 1000.0
	report.mass_kg = torpedo.mass_kg
	report.burster_charge_kg = torpedo.warhead_kg
	report.target_id = ship.id
	report.hit_above_water = false
	report.detonated = true
	report.termination = HitReport.Termination.DETONATED

	var basis: Basis = TrajectoryTracer.ship_basis(ship.heading, ship.list_angle, ship.trim_angle)
	var inverse: Basis = basis.transposed()
	var ship_origin: Vector3 = Vector3(ship.position.x, ship.position.y, 0.0)
	var origin: Vector3 = inverse * (impact_world - ship_origin)
	var direction: Vector3 = (inverse * direction_world).normalized()

	report.impact_local = origin
	report.impact_world = Vector2(impact_world.x, impact_world.y)
	report.detonation_local = origin

	var coupling: Dictionary = torpedo_config.get("coupling", {}) as Dictionary
	var energy: float = torpedo.warhead_energy(torpedo_config) \
		* float(coupling.get("hullCouplingFraction", 0.22))
	report.detonation_energy_j = energy

	var damage: DamageReport = DamageReport.new()
	damage.integrity_before = SurvivabilityEvaluator.assess(
		ship, template, state, damage_config).integrity

	# The walk inboard establishes how DEEP the blast got — that is what the torpedo
	# defence system is for. How WIDE it is comes from the warhead, and is applied
	# afterwards as a volume rather than as the single line the ray traced.
	var depth: float = _walk_inboard(
		report, damage, torpedo, origin, direction, energy,
		ship, template, state, torpedo_config, basis, ship_origin)

	_apply_effects(damage, report, torpedo, origin, direction, depth,
		ship, template, state, torpedo_config, energy)

	SurvivabilityEvaluator.apply_component_effects(ship, template, state)
	damage.integrity_after = SurvivabilityEvaluator.assess(
		ship, template, state, damage_config).integrity
	damage.catastrophic = state.catastrophic
	damage.catastrophe_reason = state.catastrophe_reason
	report.damage = damage
	return report


## Follow the blast inboard, spending energy on every layer it crosses.
##
## Returns how far in it got before running out. That distance is the entire measure
## of a torpedo defence system: a deep one spends the blast in voids and fuel before
## it reaches anything vital, and a ship with none has it arrive in her machinery.
static func _walk_inboard(
	report: HitReport, damage: DamageReport, torpedo: TorpedoDef,
	origin: Vector3, direction: Vector3, energy: float,
	ship: ShipEntity, template: ShipStructureTemplate, state: ShipStructureState,
	config: Dictionary, basis: Basis, ship_origin: Vector3
) -> float:
	var absorption: Dictionary = config.get("absorption", {}) as Dictionary
	var per_mm: float = float(absorption.get("megajoulesPerMillimetreOfPlate", 1.1)) * 1.0e6
	var remaining: float = energy
	var depth_reached: float = 0.0
	var order: int = 0

	# Every primitive the blast path crosses, in the order it meets them.
	var events: Array = []
	for i: int in template.faces.size():
		var t: float = GeometryPrimitives.ray_face(origin, direction, template.faces[i])
		if t >= 0.0:
			events.append([t, true, i, true])
	for i: int in template.volumes.size():
		var span: Array = GeometryPrimitives.ray_volume(origin, direction, template.volumes[i])
		if span.is_empty():
			continue
		var enter: float = maxf(float(span[0]), 0.0)
		var exit: float = float(span[1])
		if exit <= 0.0:
			continue
		events.append([enter, false, i, true])
		events.append([exit, false, i, false])
	events.sort_custom(func(a: Array, b: Array) -> bool:
		if not is_equal_approx(float(a[0]), float(b[0])):
			return float(a[0]) < float(b[0])
		if bool(a[1]) != bool(b[1]):
			return bool(a[1])
		return int(a[2]) < int(b[2]))

	var open_since: Dictionary = {}
	for event: Array in events:
		if order >= MAX_LAYERS or remaining <= 0.0:
			break
		var t: float = float(event[0])
		var is_face: bool = bool(event[1])
		var index: int = int(event[2])
		var entering: bool = bool(event[3])
		var point: Vector3 = origin + direction * t

		if is_face:
			# Plating and bulkheads absorb by thickness and by how good the steel is.
			var face: GeometryPrimitives.Face = template.faces[index]
			var quality: float = 1.0
			if face.kind == GeometryPrimitives.FaceKind.ARMOR:
				quality = 1.35   # a holding bulkhead is doing exactly this job
			var cost: float = face.thickness_mm * per_mm * quality
			var absorbed: float = minf(cost, remaining)
			remaining -= absorbed

			var interaction: HitReport.LayerInteraction = HitReport.LayerInteraction.new()
			interaction.kind = (HitReport.InteractionKind.ARMOR
				if face.kind == GeometryPrimitives.FaceKind.ARMOR
				else HitReport.InteractionKind.STRUCTURE)
			interaction.zone = face.zone
			interaction.label = face.zone
			interaction.primitive_index = index
			interaction.local_point = point
			interaction.distance_m = t
			interaction.depth_below_waterline = maxf(-point.z, 0.0)
			interaction.energy_before = remaining + absorbed
			interaction.energy_after = remaining
			report.add(interaction)
			state.add_deformation(index, 0.4)
			depth_reached = maxf(depth_reached, t)
			order += 1
			continue

		var volume: GeometryPrimitives.Volume = template.volumes[index]
		if volume.kind == GeometryPrimitives.VolumeKind.COMPONENT:
			continue

		if entering:
			open_since[index] = t
			continue

		# Leaving a compartment: charge the blast for the distance it crossed. A void
		# is cheap to cross, a full fuel tank is expensive — which is the entire
		# reason ships ran with their outboard tanks deliberately full.
		var enter_t: float = float(open_since.get(index, t))
		var crossed: float = maxf(t - enter_t, 0.0)
		var per_metre: float = _absorption_for(volume.role, absorption)
		var absorbed_here: float = minf(crossed * per_metre * 1.0e6, remaining)
		remaining -= absorbed_here

		var entry: HitReport.LayerInteraction = HitReport.LayerInteraction.new()
		entry.kind = HitReport.InteractionKind.COMPARTMENT_ENTER
		entry.zone = volume.role
		entry.label = volume.label
		entry.primitive_index = index
		entry.local_point = origin + direction * enter_t
		entry.distance_m = enter_t
		entry.depth_below_waterline = maxf(-entry.local_point.z, 0.0)
		entry.energy_before = remaining + absorbed_here
		entry.energy_after = remaining
		report.add(entry)

		depth_reached = maxf(depth_reached, t)
		order += 1

	report.path_length_m = depth_reached
	return depth_reached


static func _absorption_for(role: String, absorption: Dictionary) -> float:
	match role:
		ShipStructureBuilder.ROLE_VOID, ShipStructureBuilder.ROLE_BULGE:
			return float(absorption.get("megajoulesPerMetreOfVoid", 8.0))
		ShipStructureBuilder.ROLE_FUEL:
			return float(absorption.get("megajoulesPerMetreOfLiquid", 34.0))
		ShipStructureBuilder.ROLE_ENGINE, ShipStructureBuilder.ROLE_BOILER:
			return float(absorption.get("megajoulesPerMetreOfMachinery", 20.0))
		_:
			return float(absorption.get("megajoulesPerMetreDefault", 14.0))


## Open everything the blast reached, wreck it, and account for the rest.
static func _apply_effects(
	damage: DamageReport, report: HitReport, torpedo: TorpedoDef,
	origin: Vector3, direction: Vector3, depth: float,
	ship: ShipEntity, template: ShipStructureTemplate, state: ShipStructureState,
	config: Dictionary, energy: float
) -> void:
	var effects: Dictionary = config.get("effects", {}) as Dictionary
	var megajoules: float = energy / 1.0e6

	# The hole in the side. A 490 kg Type 93 opens something like twelve metres of it.
	var radius: float = megajoules * float(effects.get("breachRadiusPerMegajoule", 0.011))
	damage.add_effect(&"breach", "shell plating", PI * radius * radius,
		"torpedo opened roughly %.1f m of side, %.1f m below the waterline"
			% [radius * 2.0, maxf(-origin.z, 0.0)])

	# Everything inside the blast: a cylinder of the hole's radius, reaching as far
	# inboard as the defence system let it. This is the difference between a hit on a
	# battleship, where the cylinder is spent in her bulge, and one on a destroyer,
	# where it takes out a whole section of her.
	var reached: PackedInt32Array = _compartments_in_blast(
		template, origin, direction, radius, depth)
	for index: int in reached:
		if not Array(report.compartments_entered).has(index):
			report.compartments_entered.append(index)

	if reached.is_empty():
		damage.add_effect(&"armour_held", "torpedo defence system", 0.0,
			"the blast was contained outboard of any compartment")
		return

	# Everything the blast reached is open to the sea. This — not the wreckage — is
	# what actually sinks ships.
	var wreckable: float = megajoules * float(effects.get("wreckedCubicMetresPerMegajoule", 4.5))
	var share: float = wreckable / float(reached.size())
	var casualty_rate: float = float(effects.get("casualtiesPerMegajouleInCompartment", 0.30))

	for index: int in reached:
		var compartment: ShipStructureState.CompartmentState = state.compartment(index)
		if compartment == null:
			continue
		var volume: GeometryPrimitives.Volume = template.volumes[index]
		compartment.breached = true
		compartment.breach_area_m2 += PI * radius * radius / float(reached.size())
		compartment.breach_depth_m = maxf(compartment.breach_depth_m,
			maxf(-volume.centre().z, 1.0))
		compartment.wreckage = clampf(
			compartment.wreckage + share / maxf(volume.volume_m3(), 1.0), 0.0, 1.0)

		var killed: int = mini(int(round(megajoules * casualty_rate / float(reached.size()))),
			compartment.crew)
		if killed > 0:
			damage.crew_casualties += state.take_casualties(index, killed)
		damage.add_effect(&"flooding", volume.label, compartment.wreckage,
			"opened to the sea by the torpedo", index)

	# The shock springs the watertight boundaries of the compartments AROUND the ones
	# the blast reached. Those spaces are not open to the sea yet, but their bulkheads
	# will not hold, and over the following minutes the water works its way further
	# into the ship. Progressive flooding is what turns a contained hit into a lost
	# ship, and it is why a torpedo is so much more dangerous than its hole.
	var bulkhead_damage: float = float(effects.get("adjacentBulkheadDamage", 0.30))
	if bulkhead_damage > 0.0:
		var sprung: Array[int] = []
		for index: int in reached:
			for j: int in template.neighbours(index):
				if Array(reached).has(j) or sprung.has(j):
					continue
				var compartment: ShipStructureState.CompartmentState = state.compartment(j)
				if compartment == null:
					continue
				compartment.wreckage = clampf(compartment.wreckage + bulkhead_damage, 0.0, 1.0)
				sprung.append(j)
		if not sprung.is_empty():
			damage.add_effect(&"bulkheads_sprung", "adjacent compartments", float(sprung.size()),
				"%d watertight boundaries sprung by the shock" % sprung.size())

	# Machinery, shafts and steering near the blast. A hit right aft wrecks the
	# propellers and the steering gear without touching anything else, which is the
	# classic torpedo mission kill.
	var component_damage: float = megajoules * float(effects.get("componentDamagePerMegajoule", 0.012))
	var reach: float = float(effects.get("shaftDamageRadiusM", 22.0))
	for i: int in template.volumes.size():
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		if volume.kind != GeometryPrimitives.VolumeKind.COMPONENT:
			continue
		if volume.centre().distance_to(origin) > reach:
			continue
		var component: ShipStructureState.ComponentState = state.component(i)
		if component == null:
			continue
		var before: int = component.state
		component.condition = clampf(component.condition - component_damage, 0.0, 1.0)
		if component.state != before:
			damage.component_transitions.append("%s: %s" % [volume.label,
				["operational", "damaged", "disabled", "destroyed"][component.state]])
			damage.add_effect(&"component", volume.label, component.condition,
				"wrecked by the torpedo", i)

	# A torpedo under the middle of a ship strains the hull girder itself. Enough
	# hits in the same place and her back breaks.
	var station: float = origin.x / maxf(ship.spec.length_m, 1.0)
	if absf(station) < 0.25:
		state.girder_damage = clampf(state.girder_damage
			+ float(effects.get("girderDamagePerHitAmidships", 0.22)), 0.0, 1.0)
		damage.add_effect(&"girder", "hull girder", state.girder_damage,
			"the hull is strained amidships")


## Compartments inside the blast: within `radius` of the run line, and no further
## inboard than the blast actually got.
static func _compartments_in_blast(template: ShipStructureTemplate, origin: Vector3,
		direction: Vector3, radius: float, depth: float) -> PackedInt32Array:
	var found: PackedInt32Array = PackedInt32Array()
	for i: int in template.volumes.size():
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		if volume.kind != GeometryPrimitives.VolumeKind.COMPARTMENT:
			continue
		var offset: Vector3 = volume.centre() - origin
		var along: float = offset.dot(direction)
		if along < -radius or along > depth + radius:
			continue
		# Distance from the run line, allowing for the compartment's own size — a
		# large space is caught by a blast that only clips its edge.
		var perpendicular: float = (offset - direction * along).length()
		if perpendicular <= radius + volume.size().length() * 0.20:
			found.append(i)
	return found
