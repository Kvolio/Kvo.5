extends SimTest

## Torpedoes: running, aiming, and what a warhead does when it arrives.
##
## The claim under test is that torpedo defence is real layered structure rather than
## a damage-reduction number. The same warhead against a battleship with a five-metre
## system and against a destroyer with none must produce completely different results
## because in one case the blast is spent in voids and fuel before it reaches anything
## vital — not because a battleship has a smaller multiplier.

var _torpedo_config: Dictionary = {}
var _damage_config: Dictionary = {}


func suite_name() -> String:
	return "Torpedoes"


func before_each() -> void:
	if _torpedo_config.is_empty():
		_torpedo_config = JsonLoader.load_dict("res://data/config/torpedo.json")
		_damage_config = JsonLoader.load_dict("res://data/config/damage.json")


func _world_with(spec_id: String) -> SimWorld:
	var world: SimWorld = TestShips.armed_world()
	world.add_ship(TestShips.load_ship(spec_id), Vector2.ZERO, 0.0, 0)
	return world


## Put a torpedo into a ship's side at the given station, and report what it did.
func _strike(world: SimWorld, torpedo_id: String, station: float,
		seed_value: int = 4242) -> HitReport:
	var ship: ShipEntity = world.ships[0]
	var torpedo: TorpedoDef = world.armory.get_torpedo(torpedo_id)
	var template: ShipStructureTemplate = world.structure_for(ship)
	# Struck on the starboard beam, running in towards the centreline.
	#
	# Depth is set for the target, as it would be in practice: a torpedo running at
	# five metres passes clean under a destroyer drawing under four, which is a real
	# phenomenon and is tested separately. Here the intent is that it hits.
	var beam: float = ship.hull().half_beam_at(station)
	var depth: float = minf(torpedo.run_depth_m, ship.spec.hydrostatic_draft() * 0.6)
	var impact: Vector3 = Vector3(station * ship.spec.length_m, beam, -depth)
	var report: HitReport = TorpedoDamageModel.resolve(torpedo, impact, Vector3(0.0, -1.0, 0.0),
		ship, template, ship.structure_state, _torpedo_config, _damage_config,
		DeterministicRng.new(seed_value))
	world._reassess(ship)
	return report


func _roles_reached(world: SimWorld, report: HitReport) -> Array[String]:
	var template: ShipStructureTemplate = world.structure_for(world.ships[0])
	var roles: Array[String] = []
	for index: int in report.compartments_entered:
		roles.append(template.volumes[index].role)
	return roles


# --------------------------------------------------------- the defence system --

func test_a_torpedo_defence_system_stops_the_blast_short_of_the_machinery() -> void:
	# Yamato's five-metre system: bulge, liquid layer, holding bulkhead. The blast
	# should be spent before it reaches anything that matters.
	var world: SimWorld = _world_with("ijn_yamato")
	var report: HitReport = _strike(world, "usa_mk15", 0.0)
	var roles: Array[String] = _roles_reached(world, report)

	not_ok(roles.has(ShipStructureBuilder.ROLE_ENGINE), "no engine room opened")
	not_ok(roles.has(ShipStructureBuilder.ROLE_MAGAZINE), "no magazine opened")
	eq(world.ships[0].status, ShipEntity.Status.ACTIVE, "and she fights on")


func test_the_same_warhead_guts_a_ship_with_no_defence_system() -> void:
	var protected: SimWorld = _world_with("ijn_yamato")
	var unprotected: SimWorld = _world_with("uss_fletcher")
	var against_destroyer: HitReport = _strike(unprotected, "usa_mk15", 0.0)
	_strike(protected, "usa_mk15", 0.0)
	gt(float(against_destroyer.compartments_entered.size()), 0.0,
		"the destroyer is opened up")

	# The difference shows over the following minutes, because the torpedo's weapon is
	# the flooding rather than the wreckage. Let the sea do its work.
	TestShips.run_seconds(protected, 400.0)
	TestShips.run_seconds(unprotected, 400.0)

	# An eighth of the ship, not a hair. The exact figure moves whenever the internal
	# geometry changes — it is derived from real volumes, which is the point — so the
	# threshold is set where the claim is unambiguous rather than where the numbers
	# happened to land when it was written.
	gt(protected.ships[0].structural_integrity(),
		unprotected.ships[0].structural_integrity() + 0.12,
		"the protected ship is in far better shape from an identical warhead")
	lt(protected.ships[0].condition.flooded_fraction,
		unprotected.ships[0].condition.flooded_fraction,
		"and has taken proportionally less water")


func test_a_heavier_warhead_reaches_deeper_into_the_same_ship() -> void:
	# 490 kg against 375 kg, into identical ships. Nothing scales damage by warhead
	# directly — the bigger charge simply has more energy left after the voids.
	var light: SimWorld = _world_with("uss_baltimore")
	var heavy: SimWorld = _world_with("uss_baltimore")
	var small: HitReport = _strike(light, "usa_mk15", 0.0)
	var large: HitReport = _strike(heavy, "jpn_type93", 0.0)
	ge(float(large.compartments_entered.size()), float(small.compartments_entered.size()),
		"the Long Lance reaches at least as far")
	gt(absf(large.damage.integrity_delta()), absf(small.damage.integrity_delta()),
		"and does more when it gets there")


func test_a_liquid_layer_absorbs_more_than_an_empty_one() -> void:
	# The reason ships ran with their outboard tanks deliberately full.
	var absorption: Dictionary = _torpedo_config.get("absorption", {}) as Dictionary
	gt(float(absorption.get("megajoulesPerMetreOfLiquid", 0.0)),
		float(absorption.get("megajoulesPerMetreOfVoid", 0.0)) * 2.0,
		"fuel disperses a shock far better than air")


# ------------------------------------------------------------------- effects --

func test_a_torpedo_opens_the_ship_to_the_sea() -> void:
	# The flooding is the weapon, not the wreckage.
	var world: SimWorld = _world_with("uss_baltimore")
	var report: HitReport = _strike(world, "jpn_type93", 0.0)
	ok(report.damage.has_effect(&"flooding"), "compartments were opened")

	var opened: int = 0
	for compartment: ShipStructureState.CompartmentState in world.ships[0].structure_state.compartments:
		if compartment != null and compartment.breached:
			opened += 1
	gt(float(opened), 0.0, "and they are taking water")


func test_a_hit_aft_wrecks_the_steering() -> void:
	# The classic torpedo mission kill: structurally sound, fully buoyant, and unable
	# to steer. The steering gear sits right aft, outside the citadel, which is
	# exactly why a hit there is so much more than its size suggests.
	var world: SimWorld = _world_with("uss_baltimore")
	var ship: ShipEntity = world.ships[0]
	_strike(world, "jpn_type93", -0.44)
	not_ok(ship.condition.has_steering, "she cannot steer")
	eq(ship.status, ShipEntity.Status.MISSION_KILL, "which is enough on its own")
	gt(ship.structural_integrity(), 0.6, "though she is structurally in reasonable shape")


func test_a_hit_on_the_machinery_costs_speed() -> void:
	var world: SimWorld = _world_with("uss_baltimore")
	var ship: ShipEntity = world.ships[0]
	var full_speed: float = ship.effective_max_speed()
	_strike(world, "jpn_type93", -0.05)
	lt(ship.effective_max_speed(), full_speed, "she has lost power")


func test_a_hit_amidships_strains_the_hull_girder() -> void:
	var world: SimWorld = _world_with("uss_fletcher")
	var ship: ShipEntity = world.ships[0]
	_strike(world, "jpn_type93", 0.0)
	gt(ship.structure_state.girder_damage, 0.0, "the hull itself is strained")


func test_enough_torpedoes_break_a_destroyer_in_half() -> void:
	var world: SimWorld = _world_with("uss_fletcher")
	var ship: ShipEntity = world.ships[0]
	for i: int in 5:
		if ship.status == ShipEntity.Status.DESTROYED:
			break
		_strike(world, "jpn_type93", 0.0, 100 + i)
	eq(ship.status, ShipEntity.Status.DESTROYED, "she is lost")
	ne(ship.loss_reason, "", "with a stated reason: '%s'" % ship.loss_reason)


# ------------------------------------------------------------------- running --

func test_a_torpedo_runs_at_its_setting_and_expires_at_its_range() -> void:
	var world: SimWorld = TestShips.armed_world()
	var shooter: ShipEntity = world.add_ship(TestShips.load_ship("uss_fletcher"),
		Vector2.ZERO, 0.0, 0)
	var torpedo: TorpedoDef = world.armory.get_torpedo("usa_mk15")
	var setting: TorpedoDef.Setting = torpedo.settings[0]
	world.spawn_torpedo(torpedo, Vector2.ZERO, 0.0, setting.speed_ms,
		shooter.id, 0, 0)

	TestShips.run_seconds(world, 10.0)
	eq(world.torpedoes.size(), 1, "still running")
	almost(world.torpedoes[0].position.x, setting.speed_ms * 10.0, 5.0,
		"at the speed it was set to")

	TestShips.run_seconds(world, setting.range_m / setting.speed_ms + 5.0)
	eq(world.torpedoes.size(), 0, "and it runs out at the end of its range")


func test_a_torpedo_will_not_go_off_before_it_has_armed() -> void:
	var world: SimWorld = TestShips.armed_world()
	var shooter: ShipEntity = world.add_ship(TestShips.load_ship("uss_fletcher"),
		Vector2.ZERO, 0.0, 0)
	var victim: ShipEntity = world.add_ship(TestShips.load_ship("uss_baltimore"),
		Vector2(150.0, 0.0), PI * 0.5, 1)
	var torpedo: TorpedoDef = world.armory.get_torpedo("usa_mk15")
	world.spawn_torpedo(torpedo, Vector2.ZERO, 0.0, torpedo.settings[0].speed_ms,
		shooter.id, victim.id, 0)

	TestShips.run_seconds(world, 8.0)
	almost(victim.structural_integrity(), 1.0, 0.001,
		"a target inside the arming distance is not hurt")


func test_a_torpedo_set_too_deep_runs_under_a_shallow_ship() -> void:
	# A real phenomenon, and part of why a destroyer is a harder torpedo target than
	# a battleship quite apart from being smaller.
	var world: SimWorld = TestShips.armed_world()
	var shooter: ShipEntity = world.add_ship(TestShips.load_ship("uss_fletcher"),
		Vector2.ZERO, 0.0, 0)
	var victim: ShipEntity = world.add_ship(TestShips.load_ship("uss_fletcher"),
		Vector2(3000.0, 0.0), PI * 0.5, 1)
	lt(victim.spec.hydrostatic_draft(), 5.0, "she draws under five metres")

	var torpedo: TorpedoDef = world.armory.get_torpedo("usa_mk15")
	gt(torpedo.run_depth_m, victim.spec.hydrostatic_draft(), "and the torpedo runs deeper")
	world.spawn_torpedo(torpedo, Vector2.ZERO, 0.0, torpedo.settings[0].speed_ms,
		shooter.id, victim.id, 0)

	TestShips.run_seconds(world, 120.0)
	almost(victim.structural_integrity(), 1.0, 0.001, "it passes harmlessly underneath")


# -------------------------------------------------------------- fire control --

func test_the_intercept_leads_a_moving_target() -> void:
	var world: SimWorld = TestShips.armed_world()
	var shooter: ShipEntity = world.add_ship(TestShips.load_ship("uss_fletcher"),
		Vector2.ZERO, 0.0, 0)
	var target: ShipEntity = world.add_ship(TestShips.load_ship("uss_baltimore"),
		Vector2(4000.0, 0.0), PI * 0.5, 1)
	MovementSystem.set_steady_speed(target, SimUnits.knots_to_ms(25.0))
	TestShips.run_seconds(world, 2.0)

	var torpedo: TorpedoDef = world.armory.get_torpedo("usa_mk15")
	var solution: TorpedoFireControl.Solution = TorpedoFireControl.solve(
		shooter, shooter.torpedo_launchers[0], target, torpedo)
	ok(solution.valid, "a solution exists")
	gt(solution.run_time, 40.0, "the run takes a while")
	gt(solution.aim_point.distance_to(target.position), 400.0,
		"so the tubes are aimed well ahead of her")


func test_a_target_that_outruns_the_torpedo_cannot_be_hit() -> void:
	# The quadratic has no positive root, and that is a real tactical fact rather
	# than a solver failure.
	var world: SimWorld = TestShips.armed_world()
	var shooter: ShipEntity = world.add_ship(TestShips.load_ship("uss_fletcher"),
		Vector2.ZERO, 0.0, 0)
	var target: ShipEntity = world.add_ship(TestShips.load_ship("uss_fletcher"),
		Vector2(6000.0, 0.0), 0.0, 1)
	# Running directly away at a speed the slow long-range setting cannot match.
	MovementSystem.set_steady_speed(target, SimUnits.knots_to_ms(36.0))
	TestShips.run_seconds(world, 2.0)

	var torpedo: TorpedoDef = world.armory.get_torpedo("usa_mk15")
	var solution: TorpedoFireControl.Solution = TorpedoFireControl.solve(
		shooter, shooter.torpedo_launchers[0], target, torpedo)
	not_ok(solution.valid, "no interception is possible")
	ne(solution.reason, "", "and the reason says so: '%s'" % solution.reason)


func test_most_navies_get_one_salvo_and_the_japanese_get_reloads() -> void:
	var fletcher: ShipSpec = TestShips.load_ship("uss_fletcher")
	var kagero: ShipSpec = TestShips.load_ship("ijn_kagero")
	not_ok(fletcher.torpedo_battery.has_reloads(),
		"a Fletcher fires her tubes once and then has nothing left")
	ok(kagero.torpedo_battery.has_reloads(),
		"a Kagero can reload, which is why a Japanese destroyer stayed dangerous")


func test_firing_empties_the_tubes() -> void:
	var world: SimWorld = TestShips.armed_world()
	var shooter: ShipEntity = world.add_ship(TestShips.load_ship("uss_fletcher"),
		Vector2.ZERO, 0.0, 0)
	var target: ShipEntity = world.add_ship(TestShips.load_ship("uss_baltimore"),
		Vector2(0.0, 4000.0), 0.0, 1)
	shooter.target_id = target.id
	MovementSystem.set_steady_speed(target, SimUnits.knots_to_ms(20.0))

	var loaded: int = shooter.tubes_loaded()
	gt(float(loaded), 5.0, "she starts with a full outfit")

	TestShips.run_seconds(world, 20.0)   # let the tubes train round
	world.commands.submit_new(SimWorld.CMD_FIRE_TORPEDOES, world.clock.tick, shooter.id)
	world.step()
	gt(float(world.torpedoes.size()), 0.0, "torpedoes are in the water")
	lt(float(shooter.tubes_loaded()), float(loaded), "and the tubes are emptier")


func test_torpedo_running_is_reproducible() -> void:
	var results: Array[float] = []
	for _run: int in 2:
		var world: SimWorld = _world_with("uss_baltimore")
		_strike(world, "jpn_type93", 0.05, 777)
		TestShips.run_seconds(world, 120.0)
		results.append(world.ships[0].structural_integrity())
	eq(results[0], results[1], "identical outcome from identical inputs")
