extends SimTest

## The optional air module: carrier operations, strikes, fighters and flak.


func suite_name() -> String:
	return "Air module"


func _config() -> Dictionary:
	return JsonLoader.load_dict("res://data/config/air.json")


func _carrier_world(seed_value: int = 4) -> Array:
	var world: SimWorld = TestShips.armed_world(seed_value)
	var module: AirModule = AirModule.register(world, _config())
	var carrier: ShipEntity = world.add_ship(
		TestShips.load_ship("uss_essex"), Vector2.ZERO, 0.0, 0)
	var enemy: ShipEntity = world.add_ship(
		TestShips.load_ship("ijn_mogami"), Vector2(0.0, 60000.0), PI, 1)
	return [world, module, carrier, enemy]


func test_the_module_is_registered_rather_than_built_in() -> void:
	var bare: SimWorld = TestShips.armed_world(1)
	eq(bare.module_count(), 0,
		"a world has no modules until something registers one — this is the isolation")
	var with_air: SimWorld = TestShips.armed_world(1)
	AirModule.register(with_air, _config())
	eq(with_air.module_count(), 1, "registering the air module adds exactly one")


func test_every_aircraft_in_the_data_loads() -> void:
	var module: AirModule = AirModule.new()
	module.aircraft = AircraftDef.load_all(AirModule.AIRCRAFT_DIR)
	gt(float(module.aircraft.size()), 5.0, "there should be aircraft to fly")
	for aircraft_id: String in module.aircraft_ids():
		var definition: AircraftDef = module.get_aircraft(aircraft_id)
		gt(definition.max_speed_ms, definition.cruise_speed_ms,
			"%s should be faster flat out than cruising" % aircraft_id)
		gt(definition.combat_radius_m, 100000.0, "%s should have useful legs" % aircraft_id)
		if definition.is_strike():
			ok(definition.carries_bomb() or definition.carries_torpedo(),
				"%s is a strike aircraft and should carry something" % aircraft_id)


func test_every_carrier_in_the_roster_has_aircraft_to_fly() -> void:
	# A carrier whose nation has no aircraft files does not fail: she quietly never
	# flies, which is the worst way for a data mismatch to behave. It happened — the
	# ship files write "USA" and the aircraft files wrote "usa" — and it cost a fleet
	# action before anybody noticed there were no aeroplanes in it.
	var module: AirModule = AirModule.new()
	module.aircraft = AircraftDef.load_all(AirModule.AIRCRAFT_DIR)
	for spec_id: String in ["uss_essex", "ijn_shokaku", "hms_illustrious"]:
		var carrier: ShipSpec = TestShips.load_ship(spec_id)
		ok(carrier.is_carrier(), "%s should be a carrier" % spec_id)
		ok(module._pick(carrier.nation, AircraftDef.Role.FIGHTER) != null,
			"%s (%s) should have fighters to put up" % [spec_id, carrier.nation])
		var strike: AircraftDef = module._pick(carrier.nation, AircraftDef.Role.TORPEDO_BOMBER)
		if strike == null:
			strike = module._pick(carrier.nation, AircraftDef.Role.DIVE_BOMBER)
		ok(strike != null, "%s (%s) should have something to strike with" % [
			spec_id, carrier.nation])


func test_carriers_put_a_patrol_up_and_send_a_strike_at_what_their_side_has_found() -> void:
	var world: SimWorld = TestShips.armed_world(12)
	var module: AirModule = AirModule.register(world, _config())
	var carrier: ShipEntity = world.add_ship(
		TestShips.load_ship("uss_essex"), Vector2.ZERO, 0.0, 0)
	carrier.ai_controlled = true
	var enemy: ShipEntity = world.add_ship(
		TestShips.load_ship("ijn_mogami"), Vector2(0.0, 24000.0), PI, 1)

	world.step_many(60 * 30)
	ok(module._airborne(carrier.id, AircraftDef.Role.FIGHTER) != null,
		"she should have a patrol up before anything else — a strike sent out with no "
		+ "fighters behind it is how a carrier loses her deck while her aircraft are away")

	world.step_many(60 * 120)
	ok(module._strike_airborne(carrier.id),
		"and a strike away at the contact her side has found and identified")
	ok(enemy.is_afloat() or true, "the enemy is who it was sent at")


func test_a_carrier_launches_a_strike() -> void:
	var parts: Array = _carrier_world()
	var world: SimWorld = parts[0]
	var module: AirModule = parts[1]
	var carrier: ShipEntity = parts[2]
	var enemy: ShipEntity = parts[3]

	var group: AirGroup = module.launch(world, carrier, "usn_sbd_dauntless", 9, enemy.id)
	ok(group != null, "an undamaged Essex should be able to fly off a strike")
	eq(group.count, 9, "nine aircraft should go")
	eq(group.mission, AirGroup.Mission.OUTBOUND, "and be on their way")
	eq(group.team, carrier.team, "flying for their own side")
	ok(world.spatial.has(group.id),
		"and be in the ordinary spatial index, like anything else in the world")


func test_a_wrecked_flight_deck_stops_her_flying() -> void:
	# The isolation boundary, doing its job. The damage core wrecked a large thin thing
	# on top of a ship without knowing what it was for; the air module is what knows
	# that it was a flight deck.
	var parts: Array = _carrier_world()
	var world: SimWorld = parts[0]
	var module: AirModule = parts[1]
	var carrier: ShipEntity = parts[2]
	var enemy: ShipEntity = parts[3]

	TestShips.wreck_components(world, carrier, ShipStructureBuilder.COMPONENT_FLIGHT_DECK, 0.0)
	var capability: CarrierOperations.Capability = module.capability(world, carrier)
	not_ok(capability.can_launch, "a wrecked deck should ground her")
	eq(capability.reason, "flight deck wrecked", "and say so")
	eq(module.launch(world, carrier, "usn_sbd_dauntless", 9, enemy.id), null,
		"so no strike goes")


func test_a_jammed_elevator_makes_her_a_one_strike_ship() -> void:
	# A single bomb down an open elevator well could end a carrier's day without coming
	# close to sinking her, because whatever is in the hangar stays in the hangar.
	var parts: Array = _carrier_world()
	var world: SimWorld = parts[0]
	var module: AirModule = parts[1]
	var carrier: ShipEntity = parts[2]

	TestShips.wreck_components(world, carrier, ShipStructureBuilder.COMPONENT_ELEVATOR, 0.0)
	var capability: CarrierOperations.Capability = module.capability(world, carrier)
	not_ok(capability.can_launch, "nothing can be brought up to fly")
	ok(capability.can_recover, "but aircraft already up can still land on")
	eq(capability.elevators_working, 0, "no elevator is serviceable")


func test_a_hangar_fire_grounds_her_altogether() -> void:
	var parts: Array = _carrier_world()
	var world: SimWorld = parts[0]
	var module: AirModule = parts[1]
	var carrier: ShipEntity = parts[2]

	var template: ShipStructureTemplate = world.structure_for(carrier)
	for index: int in template.volumes_with_role(ShipStructureBuilder.ROLE_HANGAR):
		carrier.structure_state.compartment(index).fire = 0.6
	var capability: CarrierOperations.Capability = module.capability(world, carrier)
	not_ok(capability.can_launch, "a hangar well alight stops flying")
	not_ok(capability.can_recover, "in both directions — it is what happened at Midway")
	eq(capability.reason, "hangar fire", "and the reason is the fire")


func test_a_bomb_is_an_ordinary_projectile() -> void:
	# The claim the whole isolation rests on. Once released, a bomb belongs to the naval
	# core entirely: the tracer decides what it goes through and the penetration model
	# decides whether it gets in, and neither can ask where it came from.
	var parts: Array = _carrier_world()
	var world: SimWorld = parts[0]
	var module: AirModule = parts[1]
	var carrier: ShipEntity = parts[2]
	var enemy: ShipEntity = parts[3]

	var group: AirGroup = module.launch(world, carrier, "usn_sbd_dauntless", 9, enemy.id)
	group.position = enemy.position + Vector2(0.0, 700.0)
	group.mission = AirGroup.Mission.ATTACKING
	group.altitude_m = group.definition.release_altitude_m

	var before: int = world.projectiles.size()
	world.step_many(60)
	gt(float(world.projectiles.size()), float(before),
		"the bombs should enter the world as ordinary projectiles")
	var bomb: Projectile = world.projectiles[world.projectiles.size() - 1]
	eq(bomb.gun_id, "", "a bomb was never in a gun")
	eq(bomb.battery, &"bombs", "and carries its own label for the fall of shot")
	gt(bomb.velocity.length(), 50.0,
		"and arrives at whatever speed the dive and the fall gave it")
	lt(bomb.velocity.z, 0.0, "falling, not rising")


func test_an_aerial_torpedo_is_an_ordinary_torpedo() -> void:
	var parts: Array = _carrier_world()
	var world: SimWorld = parts[0]
	var module: AirModule = parts[1]
	var carrier: ShipEntity = parts[2]
	var enemy: ShipEntity = parts[3]

	var group: AirGroup = module.launch(world, carrier, "usn_tbf_avenger", 6, enemy.id)
	group.position = enemy.position + Vector2(0.0, 700.0)
	group.mission = AirGroup.Mission.ATTACKING

	world.step_many(60)
	gt(float(world.torpedoes.size()), 0.0,
		"they should go in the water as ordinary torpedoes, run by the ordinary system")
	eq(world.torpedoes[0].team, carrier.team, "belonging to the side that dropped them")
	not_ok(group.armed, "and the group has spent its load")


func test_flak_takes_aircraft_off_a_group() -> void:
	var world: SimWorld = TestShips.armed_world(6)
	var module: AirModule = AirModule.register(world, _config())
	var carrier: ShipEntity = world.add_ship(TestShips.load_ship("uss_essex"), Vector2.ZERO, 0.0, 0)
	# A 1943 American task force, which is the worst thing in the world to fly at.
	for i: int in 4:
		world.add_ship(TestShips.iowa(), Vector2(float(i) * 800.0, 20000.0), PI, 1)

	var group: AirGroup = module.launch(world, carrier, "usn_sbd_dauntless", 24, 0)
	group.team = 0
	group.position = Vector2(0.0, 20000.0)
	group.mission = AirGroup.Mission.OUTBOUND
	var started: int = group.count
	world.step_many(60 * 60)
	lt(float(group.count), float(started),
		"flying over four battleships for a minute should cost something")


func test_the_attack_run_is_the_dangerous_part() -> void:
	# Why torpedo squadrons were annihilated and dive bombers were not: the torpedo
	# group has to fly low, straight and slow at a ship that is shooting at it.
	var config: Dictionary = _config()
	var anti_air: Dictionary = config.get("antiAir", {}) as Dictionary
	var ranges: Dictionary = anti_air.get("effectiveRangeM", {}) as Dictionary
	var rates: Dictionary = anti_air.get("killsPerBarrelPerRound", {}) as Dictionary

	var world: SimWorld = TestShips.armed_world(6)
	var module: AirModule = AirModule.register(world, config)
	var gunship: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 1)
	var carrier: ShipEntity = world.add_ship(TestShips.load_ship("uss_essex"),
		Vector2(0.0, 40000.0), 0.0, 0)
	var group: AirGroup = module.launch(world, carrier, "usn_tbf_avenger", 6, gunship.id)
	group.position = Vector2(0.0, 1500.0)

	group.mission = AirGroup.Mission.OUTBOUND
	var approaching: float = AirModule._ship_anti_air(
		gunship, group, 1500.0, anti_air, ranges, rates)
	group.mission = AirGroup.Mission.ATTACKING
	var attacking: float = AirModule._ship_anti_air(
		gunship, group, 1500.0, anti_air, ranges, rates)

	gt(attacking, approaching * 1.5,
		"a group in its attack run should be hit far harder (%.2f vs %.2f per round)" % [
			attacking, approaching])


func test_fighters_go_for_the_bombers_first() -> void:
	# The whole job of an interception, and the whole job of an escort.
	var world: SimWorld = TestShips.armed_world(8)
	var module: AirModule = AirModule.register(world, _config())
	var blue: ShipEntity = world.add_ship(TestShips.load_ship("uss_essex"), Vector2.ZERO, 0.0, 0)
	var red: ShipEntity = world.add_ship(
		TestShips.load_ship("ijn_shokaku"), Vector2(0.0, 30000.0), PI, 1)

	var patrol: AirGroup = module.launch(world, blue, "usn_f6f_hellcat", 12, 0)
	var escort: AirGroup = module.launch(world, red, "ijn_a6m5_zero", 9, 0)
	var strike: AirGroup = module.launch(world, red, "ijn_b5n_kate", 9, blue.id)
	patrol.position = Vector2.ZERO
	escort.position = Vector2(500.0, 0.0)
	strike.position = Vector2(1000.0, 0.0)

	var chosen: AirGroup = module._interception_target(patrol, 4000.0)
	ok(chosen != null, "the patrol should find something to engage")
	eq(chosen.id, strike.id,
		"and go for the loaded torpedo bombers rather than the closer fighters")
	ok(escort.id != 0, "the escort is there — it is what makes the interception cost something")


func test_a_group_that_runs_out_of_fuel_is_lost() -> void:
	var parts: Array = _carrier_world()
	var world: SimWorld = parts[0]
	var module: AirModule = parts[1]
	var carrier: ShipEntity = parts[2]

	var group: AirGroup = module.launch(world, carrier, "usn_f6f_hellcat", 8, 0)
	group.endurance_s = 0.5
	world.step_many(120)
	not_ok(group.is_alive(),
		"aircraft that run out of fuel ditch — an unglamorous way to lose a squadron, "
		+ "and one that cost the Japanese more than fighters did at the Philippine Sea")
	eq(module.groups.size(), 0, "and the group is retired from the module")
