class_name TrajectoryTracer
extends RefCounted

## Follows a projectile through a ship, layer by layer, in the order it actually
## meets them.
##
## NOT a grid march. Every plate, bulkhead, compartment and component is intersected
## against the shell's real path, the results are sorted by distance, and each is
## resolved in turn with the projectile's state carried forward. That ordering is the
## whole point: a shell stops at the first plate that beats it, and what lies behind
## that plate is never consulted. Reverse two layers and you have changed the ship.
##
##     transform into ship-local space (heading, list and trim)
##     -> intersect against every primitive
##     -> sort by distance
##     -> resolve each in turn, updating velocity, integrity, cap and fuze
##     -> on a ricochet, re-trace from the deflection point
##     -> terminate on stop, shatter, detonation or exit
##
## Two behaviours that are usually special-cased fall out of this for free:
##
##   * OVERPENETRATION. The fuze runs on distance travelled since arming, so a shell
##     that crosses a thin-skinned destroyer and leaves the far side before the fuze
##     expires simply does very little. No rule says so.
##
##   * DECAPPING. A thin plate met before the belt strips the armour-piercing cap,
##     and the belt then sees an uncapped shell. That is just two layers resolved in
##     order.

## Safety bounds. Neither should be reached by a real shell; they exist so a
## degenerate geometry cannot spin.
const MAX_EVENTS: int = 96
const MAX_DIRECTION_CHANGES: int = 6

## Nudge past a surface just resolved, so it is not immediately re-detected.
const SURFACE_EPSILON: float = 0.01


class Event extends RefCounted:
	var t: float = 0.0
	var is_face: bool = false
	var index: int = 0
	var entering: bool = true


## World-to-ship rotation for a hull at this heading, list and trim.
##
## List matters more than it looks: a ship heeled 15 degrees presents noticeably more
## deck and less belt to an incoming shell, so a flooding ship becomes progressively
## easier to hurt. Getting that for free is why the tracer works in ship-local space
## rather than approximating in the world frame.
static func ship_basis(heading: float, list: float, trim: float) -> Basis:
	return (Basis(Vector3(0.0, 0.0, 1.0), heading)
		* Basis(Vector3(0.0, 1.0, 0.0), trim)
		* Basis(Vector3(1.0, 0.0, 0.0), list))


## Trace a projectile into a ship. Returns a report describing everything it met.
##
## `origin` and `velocity` are in world space, with z as height above the waterline.
## The report's `interactions` list is empty if the path misses the hull entirely.
static func trace(
	shell: ShellDef, penetration_k: float,
	origin: Vector3, velocity: Vector3,
	ship: ShipEntity, structure: ShipStructureTemplate,
	materials: ArmourMaterials, model: PenetrationModel,
	rng: DeterministicRng = null
) -> HitReport:
	var report: HitReport = HitReport.new()
	report.shell_id = shell.shell_id
	report.shell_name = shell.display_name
	report.calibre_mm = shell.diameter_m * 1000.0
	report.mass_kg = shell.mass_kg
	report.burster_charge_kg = shell.bursting_charge_kg
	report.target_id = ship.id
	report.striking_velocity = velocity.length()
	report.impact_velocity = velocity

	var horizontal: float = Vector2(velocity.x, velocity.y).length()
	report.descent_angle_deg = rad_to_deg(atan2(-velocity.z, maxf(horizontal, 0.0001)))

	var basis: Basis = ship_basis(ship.heading, ship.list_angle, ship.trim_angle)
	var inverse: Basis = basis.transposed()   # a rotation basis: transpose is its inverse
	var ship_origin: Vector3 = Vector3(ship.position.x, ship.position.y, 0.0)

	var position: Vector3 = inverse * (origin - ship_origin)
	var direction: Vector3 = (inverse * velocity).normalized()
	var speed: float = velocity.length()

	# Aspect: which way the shell is coming from, relative to the target's bow. Zero
	# is dead ahead, 90 is on the beam — and a shell on the beam meets the belt
	# square while one fine on the bow meets it at a glancing angle.
	report.aspect_deg = absf(rad_to_deg(atan2(-direction.y, -direction.x)))

	var state: _State = _State.new()
	state.speed = speed
	state.integrity = 1.0
	state.cap = (PenetrationOutcome.Cap.INTACT if shell.cap == ShellDef.Cap.APC
		else PenetrationOutcome.Cap.NONE)
	state.fuze = PenetrationOutcome.Fuze.UNARMED

	_walk(report, shell, penetration_k, position, direction, state,
		ship, structure, basis, ship_origin, materials, model, rng)

	report.final_speed = state.speed
	report.path_length_m = maxf(state.travelled - state.entry_travelled, 0.0)
	if report.termination == HitReport.Termination.NONE:
		report.termination = HitReport.Termination.EXITED
	return report


## Mutable projectile state carried through the walk.
class _State extends RefCounted:
	var speed: float = 0.0
	var integrity: float = 1.0
	var cap: PenetrationOutcome.Cap = PenetrationOutcome.Cap.NONE
	var fuze: PenetrationOutcome.Fuze = PenetrationOutcome.Fuze.UNARMED
	var yaw_deg: float = 0.0
	var travelled: float = 0.0        ## absolute, from the ray origin
	var entry_travelled: float = 0.0  ## where the hull was entered, for relative reporting
	var fuze_run_remaining: float = INF
	var open_compartments: Array[int] = []
	var entered_hull: bool = false


static func _walk(
	report: HitReport, shell: ShellDef, penetration_k: float,
	position: Vector3, direction: Vector3, state: _State,
	ship: ShipEntity, structure: ShipStructureTemplate,
	basis: Basis, ship_origin: Vector3,
	materials: ArmourMaterials, model: PenetrationModel, rng: DeterministicRng
) -> void:
	var direction_changes: int = 0
	var events_resolved: int = 0

	# Collected and sorted ONCE per direction. While the shell travels straight the
	# parametric distances stay valid, so there is nothing to recompute between
	# layers — only a ricochet, which changes the ray, forces a fresh pass.
	while direction_changes <= MAX_DIRECTION_CHANGES:
		var events: Array[Event] = _collect_events(position, direction, structure)
		var base_travelled: float = state.travelled
		var deflected: bool = false
		var last_t: float = 0.0

		for event: Event in events:
			if event.t <= last_t + SURFACE_EPSILON:
				continue
			events_resolved += 1
			if events_resolved > MAX_EVENTS:
				report.termination = HitReport.Termination.INTERACTION_LIMIT
				return

			var advance: float = event.t - last_t

			# The fuze runs on distance, so if it expires before the next thing the
			# shell would have met, it bursts where it is — in the middle of a
			# compartment, which is exactly where a well-fuzed AP shell should burst.
			if state.fuze == PenetrationOutcome.Fuze.ARMED and advance > state.fuze_run_remaining:
				var burst_at: Vector3 = position + direction * (last_t + state.fuze_run_remaining)
				state.travelled += state.fuze_run_remaining
				_detonate(report, shell, state, burst_at, basis, ship_origin)
				return

			_rebase(state, advance)
			last_t = event.t
			state.travelled = base_travelled + event.t
			var point: Vector3 = position + direction * event.t

			if event.is_face:
				var face: GeometryPrimitives.Face = structure.faces[event.index]
				if not state.entered_hull:
					state.entered_hull = true
					state.entry_travelled = state.travelled
					report.entry_distance_m = state.travelled
					report.impact_local = point
					var entry_world: Vector3 = basis * point + ship_origin
					report.impact_world = Vector2(entry_world.x, entry_world.y)
					report.hit_above_water = point.z >= 0.0

				var interaction: HitReport.LayerInteraction = _resolve_face(
					report, shell, penetration_k, face, point, direction, state,
					basis, ship_origin, materials, model, rng, shell.mass_kg, state.travelled)
				var outcome: PenetrationOutcome = interaction.outcome
				if outcome == null:
					continue
				report.deepest_penetration_mm = maxf(
					report.deepest_penetration_mm, outcome.penetration_capability_mm)

				match outcome.result:
					PenetrationOutcome.Result.STOPPED:
						report.termination = HitReport.Termination.STOPPED
						return
					PenetrationOutcome.Result.SHATTERED:
						report.termination = HitReport.Termination.SHATTERED
						return
					PenetrationOutcome.Result.RICOCHET:
						# Re-trace from the deflection point: a ricochet inside a ship
						# really can go on to hit something else.
						direction = outcome.remaining_velocity.normalized()
						state.speed = outcome.remaining_velocity.length()
						position = point + direction * SURFACE_EPSILON
						direction_changes += 1
						deflected = true
					_:
						state.speed = outcome.remaining_velocity.length()
						if state.speed <= 1.0:
							report.termination = HitReport.Termination.STOPPED
							return
						state.cap = outcome.cap_status
						state.integrity = outcome.projectile_integrity
						state.yaw_deg = outcome.yaw_deg
						if (state.fuze == PenetrationOutcome.Fuze.UNARMED
								and outcome.fuze_state == PenetrationOutcome.Fuze.ARMED):
							state.fuze = PenetrationOutcome.Fuze.ARMED
							# Fuze delay is a time; what the walk needs is the distance
							# it buys at the speed the shell is now making.
							state.fuze_run_remaining = shell.fuze_delay_s * state.speed
						elif outcome.fuze_state == PenetrationOutcome.Fuze.FAILED:
							state.fuze = PenetrationOutcome.Fuze.FAILED

				if deflected:
					break
			else:
				_resolve_volume(report, structure, event, point, state,
					basis, ship_origin, state.travelled)

		if deflected:
			continue

		# Nothing left in front of it. If it entered the ship at all and did not
		# burst, it has gone out the other side.
		if state.entered_hull and not report.detonated:
			var exit: HitReport.LayerInteraction = HitReport.LayerInteraction.new()
			exit.kind = HitReport.InteractionKind.HULL_EXIT
			exit.label = "Left the hull without detonating"
			exit.distance_m = maxf(state.travelled - state.entry_travelled, 0.0)
			exit.speed_before = state.speed
			exit.speed_after = state.speed
			report.add(exit)
			report.termination = HitReport.Termination.EXITED
		return


## Charge distance covered against a running fuze.
##
## A no-op until the fuze is armed, which is what keeps the standoff distance the ray
## starts at from being billed against a fuze that had not started yet.
static func _rebase(state: _State, advanced: float) -> void:
	if state.fuze_run_remaining < INF:
		state.fuze_run_remaining -= advanced


## Every primitive the ray meets, sorted by distance.
##
## The sort is what makes this an ordered resolution rather than a march, and the
## tie-break on primitive index keeps two coincident surfaces — a deck and a
## compartment boundary at the same height, say — in a reproducible order.
static func _collect_events(origin: Vector3, direction: Vector3,
		structure: ShipStructureTemplate) -> Array[Event]:
	var events: Array[Event] = []

	for i: int in structure.faces.size():
		var t: float = GeometryPrimitives.ray_face(origin, direction, structure.faces[i])
		if t > 0.0:
			var event: Event = Event.new()
			event.t = t
			event.is_face = true
			event.index = i
			events.append(event)

	for i: int in structure.volumes.size():
		var span: Array = GeometryPrimitives.ray_volume(origin, direction, structure.volumes[i])
		if span.is_empty():
			continue
		for pair: Array in [[float(span[0]), true], [float(span[1]), false]]:
			if float(pair[0]) <= 0.0:
				continue
			var event: Event = Event.new()
			event.t = float(pair[0])
			event.is_face = false
			event.index = i
			event.entering = bool(pair[1])
			events.append(event)

	events.sort_custom(func(a: Event, b: Event) -> bool:
		if not is_equal_approx(a.t, b.t):
			return a.t < b.t
		if a.is_face != b.is_face:
			return a.is_face          # resolve a plate before the space behind it
		return a.index < b.index)
	return events


static func _resolve_face(
	report: HitReport, shell: ShellDef, penetration_k: float,
	face: GeometryPrimitives.Face, point: Vector3, direction: Vector3, state: _State,
	basis: Basis, ship_origin: Vector3,
	materials: ArmourMaterials, model: PenetrationModel, rng: DeterministicRng,
	mass_kg: float, reached: float
) -> HitReport.LayerInteraction:
	var interaction: HitReport.LayerInteraction = HitReport.LayerInteraction.new()
	interaction.kind = (HitReport.InteractionKind.ARMOR
		if face.kind == GeometryPrimitives.FaceKind.ARMOR
		else HitReport.InteractionKind.STRUCTURE)
	interaction.zone = face.zone
	interaction.label = face.zone
	interaction.primitive_index = face.index
	interaction.local_point = point
	var world: Vector3 = basis * point + ship_origin
	interaction.world_point = Vector2(world.x, world.y)
	interaction.depth_below_waterline = maxf(-point.z, 0.0)
	interaction.distance_m = maxf(reached - state.entry_travelled, 0.0)
	interaction.speed_before = state.speed
	interaction.energy_before = 0.5 * mass_kg * state.speed * state.speed
	interaction.integrity_before = state.integrity

	var context: ArmorInteractionContext = ArmorInteractionContext.new()
	context.mass_kg = mass_kg
	context.diameter_m = shell.diameter_m
	context.velocity = direction * state.speed
	context.is_armour_piercing = shell.is_armour_piercing()
	context.penetration_k = penetration_k
	context.integrity = state.integrity
	context.cap_status = state.cap
	context.yaw_deg = state.yaw_deg
	context.fuze_state = state.fuze
	context.thickness_mm = face.thickness_mm
	context.plate_normal = face.normal
	context.material_quality = materials.quality(face.material_id)
	context.face_hardened = materials.is_face_hardened(face.material_id)
	context.plate_deformation = face.deformation
	context.zone = face.zone
	context.rng = rng

	var outcome: PenetrationOutcome = model.evaluate(context)
	interaction.outcome = outcome
	interaction.speed_after = outcome.remaining_velocity.length()
	interaction.energy_after = outcome.remaining_energy
	interaction.integrity_after = outcome.projectile_integrity
	report.add(interaction)
	return interaction


static func _resolve_volume(
	report: HitReport, structure: ShipStructureTemplate, event: Event, point: Vector3,
	state: _State, basis: Basis, ship_origin: Vector3, reached: float
) -> void:
	var volume: GeometryPrimitives.Volume = structure.volumes[event.index]
	var is_component: bool = volume.kind == GeometryPrimitives.VolumeKind.COMPONENT

	# Leaving a compartment is bookkeeping, not an event worth a line in the report.
	if not event.entering and not is_component:
		state.open_compartments.erase(event.index)
		return
	if not event.entering:
		return

	var interaction: HitReport.LayerInteraction = HitReport.LayerInteraction.new()
	interaction.kind = (HitReport.InteractionKind.COMPONENT if is_component
		else HitReport.InteractionKind.COMPARTMENT_ENTER)
	interaction.zone = volume.role
	interaction.label = volume.label
	interaction.primitive_index = event.index
	interaction.local_point = point
	var world: Vector3 = basis * point + ship_origin
	interaction.world_point = Vector2(world.x, world.y)
	interaction.depth_below_waterline = maxf(-point.z, 0.0)
	interaction.distance_m = maxf(reached - state.entry_travelled, 0.0)
	interaction.speed_before = state.speed
	interaction.speed_after = state.speed
	# Compartments and components do not slow a shell measurably, but the energy it is
	# carrying when it passes through them is exactly what decides what breaks — so it
	# has to be recorded here as well as at the plates.
	var energy: float = 0.5 * report.mass_kg * state.speed * state.speed
	interaction.energy_before = energy
	interaction.energy_after = energy
	interaction.integrity_before = state.integrity
	interaction.integrity_after = state.integrity
	report.add(interaction)

	if is_component:
		if not Array(report.components_hit).has(event.index):
			report.components_hit.append(event.index)
	else:
		state.open_compartments.append(event.index)
		if not Array(report.compartments_entered).has(event.index):
			report.compartments_entered.append(event.index)


static func _detonate(report: HitReport, shell: ShellDef, state: _State,
		point: Vector3, basis: Basis, ship_origin: Vector3) -> void:
	report.detonated = true
	report.termination = HitReport.Termination.DETONATED
	report.detonation_local = point
	report.detonation_compartment = (state.open_compartments[state.open_compartments.size() - 1]
		if not state.open_compartments.is_empty() else -1)
	# What the burst releases: the remaining kinetic energy of the shell plus the
	# chemical energy of its bursting charge. Which of the two dominates is the
	# difference between an AP shell and an HE one.
	var kinetic: float = 0.5 * shell.mass_kg * state.speed * state.speed
	report.detonation_energy_j = kinetic + shell.bursting_charge_kg * 4.6e6

	var interaction: HitReport.LayerInteraction = HitReport.LayerInteraction.new()
	interaction.kind = HitReport.InteractionKind.COMPARTMENT_ENTER
	interaction.label = "Detonation"
	interaction.zone = "detonation"
	interaction.local_point = point
	var world: Vector3 = basis * point + ship_origin
	interaction.world_point = Vector2(world.x, world.y)
	interaction.distance_m = maxf(state.travelled - state.entry_travelled, 0.0)
	interaction.speed_before = state.speed
	interaction.speed_after = 0.0
	interaction.energy_before = kinetic
	interaction.energy_after = 0.0
	report.add(interaction)
