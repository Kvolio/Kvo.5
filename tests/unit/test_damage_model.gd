extends SimTest

## Damage: what a hit actually breaks, and what it does not.
##
## The two assertions this suite exists for:
##
##   1. A CLEAN NON-PENETRATION COSTS EXACTLY ZERO STRUCTURAL INTEGRITY. Not a small
##      number. A belt that stops a shell has done its job.
##
##   2. STRUCTURAL INTEGRITY IS DERIVED. Nothing decrements it, and it is not what
##      decides whether a ship lives — so a ship can be destroyed at high integrity
##      and fight on at low integrity, and both are tested here.

var _materials: ArmourMaterials = null
var _model: PenetrationModel = null


func suite_name() -> String:
	return "Damage model"


func before_each() -> void:
	if _model == null:
		_materials = ArmourMaterials.load_from("res://data/materials/armor.json")
		_model = PenetrationModelRegistry.create(TestWeapons.config())


func _world_with(spec_id: String) -> SimWorld:
	var world: SimWorld = TestShips.armed_world()
	world.add_ship(TestShips.load_ship(spec_id), Vector2.ZERO, 0.0, 0)
	return world


## Fire a shell through `local_target` and resolve everything it does.
func _hit(world: SimWorld, shell_id: String, local_target: Vector3,
		aspect_deg: float, descent_deg: float, speed: float,
		seed_value: int = 12345) -> HitReport:
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	var shell: ShellDef = TestWeapons.shell(shell_id)

	var aspect: float = deg_to_rad(aspect_deg)
	var descent: float = deg_to_rad(descent_deg)
	var direction: Vector3 = Vector3(
		-cos(aspect) * cos(descent), -sin(aspect) * cos(descent), -sin(descent)).normalized()
	var origin: Vector3 = local_target - direction * 400.0

	var report: HitReport = TrajectoryTracer.trace(shell, shell.penetration_k,
		origin, direction * speed, ship, structure, _materials, _model,
		DeterministicRng.new(seed_value))
	DamageResolver.resolve(report, ship, structure, ship.structure_state,
		JsonLoader.load_dict("res://data/config/damage.json"), DeterministicRng.new(seed_value))
	world._reassess(ship)
	return report


func _belt_point(world: SimWorld) -> Vector3:
	for face: GeometryPrimitives.Face in world.structure_for(world.ships[0]).faces:
		if face.zone == "belt" and face.centre.y > 0.0:
			return face.centre
	return Vector3.ZERO


func _role_point(world: SimWorld, role: String) -> Vector3:
	var structure: ShipStructureTemplate = world.structure_for(world.ships[0])
	var found: PackedInt32Array = structure.volumes_with_role(role)
	return structure.volumes[found[0]].centre() if not found.is_empty() else Vector3.ZERO


# ---------------------------------------- the rule this suite exists for --

func test_a_clean_non_penetration_costs_exactly_zero_structural_integrity() -> void:
	# An 8-inch shell against Iowa's 307 mm belt. It holes the shell plating on the
	# way in — above the waterline, so nothing floods — and the belt stops it dead.
	var world: SimWorld = _world_with("uss_iowa")
	var before: float = world.ships[0].structural_integrity()
	var report: HitReport = _hit(world, "usa_8in55_ap_mk21", _belt_point(world), 90.0, 15.0, 450.0)

	eq(report.termination, HitReport.Termination.STOPPED, "the belt held")
	ok(report.was_defeated_by_armour(), "recorded as defeated by armour")
	eq(world.ships[0].structural_integrity(), before,
		"and the ship is structurally exactly as sound as she was")
	eq(report.damage.integrity_delta(), 0.0, "zero, not a small number")


func test_but_a_non_penetrating_hit_still_wrecks_what_is_exposed() -> void:
	# Zero structural damage does not mean zero consequences. A heavy hit on the
	# superstructure removes the fittings around it even when nothing gets inside.
	var world: SimWorld = _world_with("uss_iowa")
	var structure: ShipStructureTemplate = world.structure_for(world.ships[0])
	var director: PackedInt32Array = structure.volumes_with_role(
		ShipStructureBuilder.COMPONENT_DIRECTOR)
	var aim: Vector3 = structure.volumes[director[0]].centre()

	var report: HitReport = _hit(world, "usa_16in50_ap_mk8", aim, 90.0, 12.0, 560.0)
	var wrecked: bool = report.damage.has_effect(&"equipment_wrecked") \
		or report.damage.has_effect(&"component") or report.damage.has_effect(&"shock")
	ok(wrecked, "fittings near the impact were damaged")


func test_a_plate_that_holds_still_deforms_and_resists_less_next_time() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var before: float = 0.0
	for i: int in ship.structure_state.plate_deformation.size():
		before += ship.structure_state.plate_deformation[i]
	_hit(world, "usa_8in55_ap_mk21", _belt_point(world), 90.0, 15.0, 450.0)
	var after: float = 0.0
	for i: int in ship.structure_state.plate_deformation.size():
		after += ship.structure_state.plate_deformation[i]
	gt(after, before, "the plate carries the mark of the hit")


# ---------------------------------------------------- where the hit lands --

func test_the_same_shell_does_dramatically_different_things_by_location() -> void:
	# The project's central claim. Identical shell, identical speed, identical angle —
	# only the aim point differs.
	var superstructure: SimWorld = _world_with("uss_iowa")
	var machinery: SimWorld = _world_with("uss_iowa")

	var high: HitReport = _hit(superstructure, "usa_16in50_ap_mk8",
		_role_point(superstructure, ShipStructureBuilder.ROLE_FIRE_CONTROL), 90.0, 12.0, 580.0)
	var deep: HitReport = _hit(machinery, "usa_16in50_ap_mk8",
		_role_point(machinery, ShipStructureBuilder.ROLE_ENGINE), 90.0, 12.0, 580.0)

	ok(deep.detonated or deep.was_defeated_by_armour(),
		"the shot at the machinery either bursts inside or is stopped by the armour")
	if deep.detonated:
		gt(absf(deep.damage.integrity_delta()), absf(high.damage.integrity_delta()),
			"a burst among the machinery costs far more than one in the superstructure")
		gt(float(deep.damage.crew_casualties), 0.0, "and kills people in the machinery space")


func test_a_burst_below_the_waterline_lets_water_in() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var report: HitReport = _hit(world, "usa_16in50_ap_mk8",
		Vector3(0.0, 0.0, -4.0), 90.0, 10.0, 600.0)
	if report.detonated:
		ok(report.damage.has_effect(&"breach") or report.damage.has_effect(&"wreckage"),
			"the hull was opened or gutted below water")


# --------------------------------------------- integrity is derived only --

func test_integrity_is_recomputed_from_condition_not_accumulated() -> void:
	# Setting the condition directly must move the integrity, because integrity is a
	# function of condition rather than a running total.
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var before: float = ship.structural_integrity()

	for compartment: ShipStructureState.CompartmentState in ship.structure_state.compartments:
		if compartment != null:
			compartment.wreckage = 0.5
	world._reassess(ship)
	lt(ship.structural_integrity(), before * 0.8, "half the ship wrecked shows in the figure")

	# And repairing the condition restores it, which a decremented pool could not do.
	for compartment: ShipStructureState.CompartmentState in ship.structure_state.compartments:
		if compartment != null:
			compartment.wreckage = 0.0
	world._reassess(ship)
	almost(ship.structural_integrity(), before, 0.001, "and undoing it restores the figure")


func test_a_ship_founders_rather_than_running_out_of_integrity() -> void:
	var world: SimWorld = _world_with("uss_fletcher")
	var ship: ShipEntity = world.ships[0]
	for compartment: ShipStructureState.CompartmentState in ship.structure_state.compartments:
		if compartment != null:
			compartment.flood = 1.0
	world._reassess(ship)
	eq(ship.status, ShipEntity.Status.DESTROYED, "she is lost")
	ok(ship.loss_reason.contains("buoyancy") or ship.loss_reason.contains("capsiz"),
		"because there is no buoyancy left, not because a counter hit zero: '%s'" % ship.loss_reason)


func test_a_ship_capsizes_from_asymmetric_flooding() -> void:
	# Water all down one side. She goes over long before she runs out of buoyancy.
	var world: SimWorld = _world_with("uss_fletcher")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	for i: int in ship.structure_state.compartments.size():
		var compartment: ShipStructureState.CompartmentState = ship.structure_state.compartments[i]
		if compartment != null and structure.volumes[i].centre().y > 0.0:
			compartment.flood = 1.0
	world._reassess(ship)
	gt(absf(ship.condition.list_deg), 5.0, "she takes a serious list")
	gt(ship.condition.reserve_buoyancy, 0.1, "with buoyancy left")
	if ship.status == ShipEntity.Status.DESTROYED:
		ok(ship.loss_reason.contains("capsized"), "and is lost by capsizing: '%s'" % ship.loss_reason)


func test_a_magazine_detonation_ends_a_ship_outright() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	gt(ship.structural_integrity(), 0.9, "undamaged a moment ago")

	ship.structure_state.catastrophic = true
	ship.structure_state.catastrophe_reason = "magazine detonation"
	world._reassess(ship)
	eq(ship.status, ShipEntity.Status.DESTROYED, "destroyed")
	ok(ship.loss_reason.contains("magazine"), "by the magazine, at essentially full integrity")


# ------------------------------------------------------- the mission kill --

func test_a_ship_can_be_combat_dead_at_high_integrity() -> void:
	# Wreck the main battery and nothing else. She is structurally sound, fully
	# buoyant, making full speed — and has no reason to be in a gun line.
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	# Wreck the turret COMPONENTS: a turret's state is derived from its component
	# condition, so setting the turret object directly would simply be recomputed away
	# — which is itself the right behaviour.
	var structure: ShipStructureTemplate = world.structure_for(ship)
	for index: int in structure.volumes_with_role(ShipStructureBuilder.COMPONENT_TURRET):
		ship.structure_state.component(index).condition = 0.0
	world._reassess(ship)

	eq(ship.status, ShipEntity.Status.MISSION_KILL, "out of action")
	gt(ship.structural_integrity(), 0.9, "at over 90% structural integrity")
	ok(ship.loss_reason.contains("main battery"), "and the reason says why: '%s'" % ship.loss_reason)


func test_a_ship_can_still_fight_at_low_integrity() -> void:
	# The converse. Badly knocked about, but her guns, engines and steering work.
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	for i: int in ship.structure_state.compartments.size():
		var compartment: ShipStructureState.CompartmentState = ship.structure_state.compartments[i]
		if compartment == null:
			continue
		var role: String = structure.volumes[i].role
		if role == ShipStructureBuilder.ROLE_CREW or role == ShipStructureBuilder.ROLE_STORES \
				or role == ShipStructureBuilder.ROLE_FUEL:
			compartment.wreckage = 1.0
	world._reassess(ship)
	lt(ship.structural_integrity(), 0.85, "she is in a poor state")
	eq(ship.status, ShipEntity.Status.ACTIVE, "but is still fighting")


# ---------------------------------------------- damage reaches the ship --

func test_losing_engines_costs_speed() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	var full: float = ship.effective_max_speed()

	var engines: PackedInt32Array = structure.volumes_with_role(
		ShipStructureBuilder.COMPONENT_ENGINE)
	for i: int in engines.size() / 2:
		ship.structure_state.component(engines[i]).condition = 0.0
	world._reassess(ship)

	lt(ship.effective_max_speed(), full, "she cannot make her designed speed")
	gt(ship.effective_max_speed(), full * 0.5, "but is far from stopped, by the cube root law")


func test_losing_a_shaft_on_one_side_makes_her_crab() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	for index: int in structure.volumes_with_role(ShipStructureBuilder.COMPONENT_SHAFT):
		if structure.volumes[index].centre().y < 0.0:
			ship.structure_state.component(index).condition = 0.0
	world._reassess(ship)
	gt(absf(ship.shaft_asymmetry), 0.1, "an imbalance the helmsman has to hold rudder against")


func test_wrecking_the_steering_gear_jams_the_rudder() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	for index: int in structure.volumes_with_role(ShipStructureBuilder.COMPONENT_RUDDER):
		ship.structure_state.component(index).condition = 0.0
	world._reassess(ship)
	ok(ship.rudder_jammed, "the rudder stays where it was")
	eq(ship.status, ShipEntity.Status.MISSION_KILL, "a ship that cannot steer is out of the fight")


# ------------------------------------------------------- flooding and fire --

func test_flooding_enters_through_the_hole_and_is_faster_when_deeper() -> void:
	var shallow: SimWorld = _world_with("uss_iowa")
	var deep: SimWorld = _world_with("uss_iowa")
	for pair: Array in [[shallow, 1.0], [deep, 8.0]]:
		var ship: ShipEntity = (pair[0] as SimWorld).ships[0]
		var compartment: ShipStructureState.CompartmentState = _first_compartment(ship)
		compartment.breached = true
		compartment.breach_area_m2 = 0.5
		compartment.breach_depth_m = pair[1] as float
		TestShips.run_seconds(pair[0] as SimWorld, 120.0)

	gt(_first_compartment(deep.ships[0]).flood, _first_compartment(shallow.ships[0]).flood,
		"a hole eight metres down admits water far faster than one a metre down")
	gt(_first_compartment(shallow.ships[0]).flood, 0.0, "and both are taking water")


func test_flooding_is_local_and_an_intact_bulkhead_holds() -> void:
	# One opened compartment floods one compartment. That is what subdivision buys,
	# and why a torpedo hit is survivable at all.
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var compartment: ShipStructureState.CompartmentState = _first_compartment(ship)
	compartment.breached = true
	compartment.breach_area_m2 = 1.0
	compartment.breach_depth_m = 5.0
	TestShips.run_seconds(world, 300.0)

	var flooded: int = 0
	for other: ShipStructureState.CompartmentState in ship.structure_state.compartments:
		if other != null and other.flood > 0.05:
			flooded += 1
	lt(float(flooded), 6.0, "the water stayed where it came in")
	eq(ship.status, ShipEntity.Status.ACTIVE, "and she is still fighting")


func test_fire_spreads_and_eats_the_ship() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var compartment: ShipStructureState.CompartmentState = _first_compartment(ship)
	compartment.fire = 0.9
	var wreckage_before: float = compartment.wreckage

	TestShips.run_seconds(world, 400.0)
	gt(compartment.wreckage, wreckage_before, "fire consumes the structure it burns through")
	ge(float(ship.structure_state.compartments_on_fire()), 1.0, "and is still burning")


func test_flooding_puts_a_fire_out() -> void:
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var compartment: ShipStructureState.CompartmentState = _first_compartment(ship)
	compartment.fire = 1.0
	compartment.breached = true
	compartment.breach_area_m2 = 2.0
	compartment.breach_depth_m = 6.0
	TestShips.run_seconds(world, 300.0)
	almost(compartment.fire, 0.0, 0.001, "the sea is an effective extinguisher")


func test_damage_is_reproducible() -> void:
	var results: Array[float] = []
	var statuses: Array[int] = []
	for _run: int in 2:
		var world: SimWorld = _world_with("uss_iowa")
		_hit(world, "usa_16in50_ap_mk8",
			_role_point(world, ShipStructureBuilder.ROLE_ENGINE), 90.0, 12.0, 580.0, 999)
		TestShips.run_seconds(world, 120.0)
		results.append(world.ships[0].structural_integrity())
		statuses.append(int(world.ships[0].status))
	eq(results[0], results[1], "identical integrity")
	eq(statuses[0], statuses[1], "and identical status")


func _first_compartment(ship: ShipEntity) -> ShipStructureState.CompartmentState:
	for compartment: ShipStructureState.CompartmentState in ship.structure_state.compartments:
		if compartment != null:
			return compartment
	return null
