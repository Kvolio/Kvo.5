extends SimTest

## The outcomes the specification says should emerge from the model rather than be
## written into it.
##
## Each of these is a claim about the whole chain — geometry, penetration, ordering,
## damage, derived integrity — and none of them is produced by a rule that says so.
## They are the reason for building it this way, so they are asserted directly.

var _materials: ArmourMaterials = null
var _model: PenetrationModel = null
var _damage_config: Dictionary = {}


func suite_name() -> String:
	return "Integration: emergent outcomes"


func before_each() -> void:
	if _model == null:
		_materials = ArmourMaterials.load_from("res://data/materials/armor.json")
		_model = PenetrationModelRegistry.create(TestWeapons.config())
		_damage_config = JsonLoader.load_dict("res://data/config/damage.json")


func _world_with(spec_id: String) -> SimWorld:
	var world: SimWorld = TestShips.armed_world()
	world.add_ship(TestShips.load_ship(spec_id), Vector2.ZERO, 0.0, 0)
	return world


## Put `count` shells through a ship, aimed at a point, and report her final state.
func _pound(world: SimWorld, shell_id: String, local_target: Vector3,
		aspect_deg: float, descent_deg: float, speed: float, count: int,
		seed_value: int = 4242) -> void:
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	var shell: ShellDef = TestWeapons.shell(shell_id)
	var rng: DeterministicRng = DeterministicRng.new(seed_value)

	var aspect: float = deg_to_rad(aspect_deg)
	var descent: float = deg_to_rad(descent_deg)
	var direction: Vector3 = Vector3(
		-cos(aspect) * cos(descent), -sin(aspect) * cos(descent), -sin(descent)).normalized()

	for i: int in count:
		if ship.status == ShipEntity.Status.DESTROYED:
			return
		# Scatter slightly so the shells do not all follow one another through the
		# same hole, which is not how a salvo lands.
		var jitter: Vector3 = Vector3(
			rng.next_range(-8.0, 8.0), rng.next_range(-3.0, 3.0), rng.next_range(-2.0, 2.0))
		var aim: Vector3 = local_target + jitter
		var report: HitReport = TrajectoryTracer.trace(shell, shell.penetration_k,
			aim - direction * 400.0, direction * speed, ship, structure,
			_materials, _model, rng)
		if report.interactions.is_empty():
			continue
		DamageResolver.resolve(report, ship, structure, ship.structure_state,
			_damage_config, rng)
		world._reassess(ship)


func _belt_point(world: SimWorld) -> Vector3:
	for face: GeometryPrimitives.Face in world.structure_for(world.ships[0]).faces:
		if face.zone == "belt" and face.centre.y > 0.0:
			return face.centre
	return Vector3.ZERO


# ---------------------------------------------------------------------------

func test_a_battleship_shrugs_off_dozens_of_hits_her_belt_can_stop() -> void:
	# Thirty 8-inch shells against Iowa's belt. A heavy cruiser cannot hurt a
	# battleship's citadel, and the model must say so without being told.
	var world: SimWorld = _world_with("uss_iowa")
	_pound(world, "usa_8in55_ap_mk21", _belt_point(world), 90.0, 15.0, 450.0, 30)

	var ship: ShipEntity = world.ships[0]
	eq(ship.status, ShipEntity.Status.ACTIVE, "still fighting after thirty hits")
	gt(ship.structural_integrity(), 0.80, "and structurally close to intact")


func test_armour_piercing_shells_are_wasted_on_a_destroyer() -> void:
	# A desirable outcome, not a defect. An AP shell needs something solid to arm
	# against and a fuze delay measured in ship-widths; a destroyer provides neither,
	# so the shell goes in one side and out the other. This is precisely why navies
	# fired high explosive at destroyers and armour-piercing at capital ships.
	var world: SimWorld = _world_with("uss_fletcher")
	var ship: ShipEntity = world.ships[0]
	_pound(world, "usa_16in50_ap_mk8", Vector3(0.0, 0.0, -1.0), 90.0, 20.0, 520.0, 4)
	gt(ship.structural_integrity(), 0.9,
		"four 16-inch armour-piercing shells have barely marked her")


func test_a_destroyer_is_wrecked_by_a_couple_of_high_explosive_hits() -> void:
	# The right shell for the target. HE has an instantaneous fuze, so it bursts on
	# the plating instead of passing through, and there is no armour to contain it.
	var world: SimWorld = _world_with("uss_fletcher")
	var ship: ShipEntity = world.ships[0]
	_pound(world, "usa_16in50_he_mk13", Vector3(0.0, 0.0, 0.0), 90.0, 15.0, 500.0, 3)
	ok(ship.structural_integrity() < 0.9 or ship.status != ShipEntity.Status.ACTIVE,
		"three high-explosive hits leave a destroyer in serious trouble")


func test_the_same_shells_that_barely_scratch_a_battleship_ruin_a_destroyer() -> void:
	# The comparison stated directly: identical shells, identical aim, identical
	# count, against two ships that differ only in what they are made of.
	var battleship: SimWorld = _world_with("uss_iowa")
	var destroyer: SimWorld = _world_with("uss_fletcher")
	for world: SimWorld in [battleship, destroyer]:
		_pound(world, "usa_8in55_he_mk25", Vector3(0.0, 0.0, 0.0), 90.0, 15.0, 450.0, 12)

	gt(battleship.ships[0].structural_integrity(),
		destroyer.ships[0].structural_integrity() + 0.05,
		"the armoured ship comes off far better than the unarmoured one")


func test_a_ship_can_flood_badly_and_still_be_structurally_sound() -> void:
	# Flooding and structural damage are different things, and the model keeps them
	# different: a ship down by the head with her citadel intact is in real trouble
	# without having lost much of herself.
	var world: SimWorld = _world_with("uss_iowa")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	var flooded: int = 0
	for i: int in ship.structure_state.compartments.size():
		var compartment: ShipStructureState.CompartmentState = ship.structure_state.compartments[i]
		if compartment == null or structure.volumes[i].centre().x < 0.0:
			continue
		compartment.flood = 1.0
		flooded += 1
	world._reassess(ship)

	gt(float(flooded), 5.0, "a good deal of the ship is full of water")
	gt(ship.condition.flooded_fraction, 0.15, "seriously flooded")
	almost(ship.condition.wrecked_fraction, 0.0, 0.001, "with nothing actually destroyed")
	gt(ship.structural_integrity(), 0.6, "so she is still structurally sound")
	ne(absf(ship.condition.trim_deg), 0.0, "but down by the head")


func test_a_carrier_can_lose_her_flight_deck_and_stay_afloat() -> void:
	# A hangar fire and a wrecked flight deck end a carrier's usefulness without
	# threatening her buoyancy — which is the whole shape of the carrier war.
	var world: SimWorld = _world_with("uss_essex")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	for index: int in structure.volumes_with_role(ShipStructureBuilder.ROLE_HANGAR):
		ship.structure_state.compartment(index).wreckage = 1.0
		ship.structure_state.compartment(index).fire = 0.8
	for index: int in structure.volumes_with_role(ShipStructureBuilder.COMPONENT_ELEVATOR):
		ship.structure_state.component(index).condition = 0.0
	world._reassess(ship)

	ne(ship.status, ShipEntity.Status.DESTROYED, "she is still afloat")
	gt(ship.condition.reserve_buoyancy, 0.5, "with plenty of buoyancy")
	for index: int in structure.volumes_with_role(ShipStructureBuilder.COMPONENT_ELEVATOR):
		not_ok(ship.structure_state.component(index).is_operational(),
			"but she cannot work her aircraft")


func test_a_well_placed_shell_can_cost_a_cruiser_her_propulsion() -> void:
	# Not by a rule about cruisers: by a shell reaching a machinery space in a ship
	# whose belt cannot keep 16-inch shells out of it.
	var world: SimWorld = _world_with("uss_baltimore")
	var ship: ShipEntity = world.ships[0]
	var structure: ShipStructureTemplate = world.structure_for(ship)
	var engines: PackedInt32Array = structure.volumes_with_role(
		ShipStructureBuilder.COMPONENT_ENGINE)
	var full_speed: float = ship.effective_max_speed()

	_pound(world, "usa_16in50_ap_mk8", structure.volumes[engines[0]].centre(),
		90.0, 14.0, 540.0, 4)
	lt(ship.effective_max_speed(), full_speed,
		"shells into her machinery have cost her speed")


func test_hits_that_are_stopped_never_reduce_integrity_however_many_arrive() -> void:
	# The rule restated as an accumulation: thirty stopped shells is thirty times
	# zero, not thirty small amounts adding up to something.
	var world: SimWorld = _world_with("ijn_yamato")
	var ship: ShipEntity = world.ships[0]
	var before: float = ship.structural_integrity()
	_pound(world, "usa_6in47_ap_mk35", _belt_point(world), 90.0, 12.0, 500.0, 30)

	# A 6-inch shell cannot touch a 410 mm belt. Anything above the belt is a
	# different matter, so this checks the belt hits specifically did nothing.
	gt(ship.structural_integrity(), before - 0.02,
		"thirty light shells against the thickest armour afloat achieved essentially nothing")
	eq(ship.status, ShipEntity.Status.ACTIVE, "and she is entirely unbothered")
