extends SimTest

## Fighting a ship: immunity zones, target selection, station keeping, and fleets.


func suite_name() -> String:
	return "Tactics"


func _world(seed_value: int = 9) -> SimWorld:
	return TestShips.armed_world(seed_value)


# -- immunity zones ------------------------------------------------------------

func test_a_battleship_has_an_immunity_zone_against_a_battleship_gun() -> void:
	# Close in the belt is beaten; far out the deck is; in between there may be a band
	# where neither is, and that band is what her armour was designed to produce. It is
	# found by asking the same penetration model the tracer asks, at the ranges in the
	# gun's own table — not from a rule.
	var world: SimWorld = _world()
	var iowa: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var yamato: ShipEntity = world.add_ship(TestShips.load_ship("ijn_yamato"),
		Vector2(0.0, 20000.0), PI, 1)

	var zone: ImmunityZone = world.immunity_zone(iowa, yamato)
	ok(zone != null, "a zone should be computed for Iowa against the 46 cm gun")
	gt(zone.belt_mm, 250.0, "her belt should be read off her own armour scheme")
	gt(zone.deck_mm, 100.0, "and her armour deck likewise")
	ok(zone.inner_m >= 0.0 and zone.outer_m > 0.0, "both edges should be real ranges")
	if zone.exists():
		lt(zone.inner_m, zone.outer_m, "the inner edge must lie inside the outer")
		lt(zone.outer_m, 45000.0, "and the outer edge inside any gun's reach")


func test_a_destroyer_has_no_immunity_zone_against_anything_serious() -> void:
	var world: SimWorld = _world()
	var fletcher: ShipEntity = world.add_ship(TestShips.fletcher(), Vector2.ZERO, 0.0, 0)
	var iowa: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, 15000.0), PI, 1)
	var zone: ImmunityZone = world.immunity_zone(fletcher, iowa)
	ok(zone != null, "a zone is still computed")
	not_ok(zone.exists(),
		"but there is no range at which a destroyer is safe from a 16-inch gun, and "
		+ "saying so is the honest answer rather than a special case")


func test_thicker_armour_widens_the_zone() -> void:
	# The designer's whole promise, checked: armour is not a number that makes a ship
	# better, it is plate that changes where she can fight.
	var world: SimWorld = _world()
	var thin: ShipSpec = TestShips.iowa().duplicate_spec(true)
	var thick: ShipSpec = TestShips.iowa().duplicate_spec(true)
	thin.spec_id = "test_thin"
	thick.spec_id = "test_thick"
	thin.armour.plate("belt").thickness_mm = 200.0
	thin.armour.plate("deckMain").thickness_mm = 80.0
	thick.armour.plate("belt").thickness_mm = 420.0
	thick.armour.plate("deckMain").thickness_mm = 190.0

	var enemy: ShipEntity = world.add_ship(TestShips.load_ship("ijn_yamato"),
		Vector2(0.0, 20000.0), PI, 1)
	var lightly: ShipEntity = world.add_ship(thin, Vector2.ZERO, 0.0, 0)
	var heavily: ShipEntity = world.add_ship(thick, Vector2(500.0, 0.0), 0.0, 0)

	var poor: ImmunityZone = world.immunity_zone(lightly, enemy)
	var good: ImmunityZone = world.immunity_zone(heavily, enemy)
	gt(good.width_m(), poor.width_m(),
		"more plate should buy more range to fight in (%.0f m vs %.0f m)" % [
			good.width_m(), poor.width_m()])
	le(good.inner_m, poor.inner_m + 1.0,
		"a thicker belt should be beaten at shorter range, not longer")


func test_the_zone_is_cached_per_design_pair() -> void:
	var world: SimWorld = _world()
	var a: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var b: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, 9000.0), PI, 0)
	var enemy: ShipEntity = world.add_ship(TestShips.load_ship("ijn_yamato"),
		Vector2(0.0, 20000.0), PI, 1)
	var first: ImmunityZone = world.immunity_zone(a, enemy)
	var second: ImmunityZone = world.immunity_zone(b, enemy)
	ok(first == second,
		"two ships of the same design facing the same gun should share one answer, "
		+ "because walking a whole range table through the penetration model is not free")


# -- target selection ----------------------------------------------------------

func test_the_ai_shoots_at_contacts_and_not_at_ships() -> void:
	# The restriction the whole AI rests on. A captain who could read `world.ships`
	# would never lose a target in the dark and could never be surprised.
	var world: SimWorld = _world()
	world.detection_config["conditions"] = {"night": true, "visibilityFactor": 1.0}
	var captain: ShipEntity = world.add_ship(TestShips.load_ship("ijn_kagero"),
		Vector2.ZERO, 0.0, 0)
	captain.ai_controlled = true
	var unseen: ShipEntity = world.add_ship(TestShips.load_ship("ijn_kagero"),
		Vector2(0.0, 30000.0), PI, 1)

	world.step_many(300)
	eq(captain.target_id, 0,
		"a ship she cannot see is a ship she cannot engage")
	ok(unseen.id != 0, "the enemy is there — she simply does not know it")

	# Inside three kilometres she is visible even on a dark night — which is exactly
	# the range the Solomons night actions were fought at, and for this reason.
	unseen.position = Vector2(0.0, 2600.0)
	world.step_many(60 * 60)
	eq(captain.target_id, unseen.id, "once held and classified, she engages")


func test_fire_is_spread_across_the_enemy_line() -> void:
	# Concentrating a division on one enemy is sound; concentrating a fleet on one
	# destroyer is not.
	var world: SimWorld = _world()
	var blue: Array[ShipEntity] = []
	for i: int in 4:
		var ship: ShipEntity = world.add_ship(
			TestShips.iowa(), Vector2(float(i) * 900.0, 0.0), 0.0, 0)
		ship.ai_controlled = true
		blue.append(ship)
	var red: Array[ShipEntity] = []
	for i: int in 3:
		red.append(world.add_ship(TestShips.iowa(), Vector2(float(i) * 900.0, 15000.0), PI, 1))

	world.step_many(60 * 60)
	var engaged: Dictionary = {}
	for ship: ShipEntity in blue:
		if ship.target_id != 0:
			engaged[ship.target_id] = true
	ge(float(engaged.size()), 2.0,
		"four battleships facing three should not all pile onto one (%d targets)" % engaged.size())


func test_the_guns_are_not_shifted_the_moment_a_better_target_appears() -> void:
	# Shifting target throws away a gunnery solution that took minutes and several
	# salvos to build, so it is a deliberate order taken on a timer rather than a
	# reflex. Without this, ships shifted several times a minute as contacts came and
	# went, every plot was reopened before it could settle, and a twenty-five-minute
	# fleet action produced fifteen hundred shells and not one hit.
	var world: SimWorld = _world()
	var captain: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	captain.ai_controlled = true
	var first: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, 17000.0), PI, 1)
	world.step_many(60 * 60)
	eq(captain.target_id, first.id, "she should have settled on the only contact")

	# A far better target: a carrier, and much closer. She should still not shift while
	# the guns are on a solution — the review comes round on its own time.
	var carrier: ShipEntity = world.add_ship(
		TestShips.load_ship("ijn_shokaku"), Vector2(3000.0, 6000.0), PI, 1)
	captain.ai.seconds_on_target = 0.0
	world.step_many(60 * 25)
	eq(captain.target_id, first.id,
		"a much better target should not interrupt a solution in progress")
	ok(carrier.id != 0, "the carrier is held as a contact all the same")

	# And once the review does come round, she takes it. Stickiness that never lets go
	# would be worse than none at all.
	world.step_many(60 * 60)
	eq(captain.target_id, carrier.id,
		"but when the guns are reviewed she shifts to the target worth shifting for")


func test_a_badly_hurt_ship_breaks_off() -> void:
	var world: SimWorld = _world()
	var captain: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	captain.ai_controlled = true
	world.add_ship(TestShips.iowa(), Vector2(0.0, 12000.0), PI, 1)
	world.step_many(60 * 40)

	# Her main battery is shot away. Nothing is assigned to her condition directly —
	# integrity is DERIVED and any value written to it would be undone by the next
	# reassessment — so she is wrecked in the only way that means anything: the guns
	# themselves are destroyed, and the survivability evaluator draws its own
	# conclusion.
	TestShips.wreck_components(world, captain, ShipStructureBuilder.COMPONENT_TURRET, 0.0)
	world.step_many(180)

	ok(captain.is_afloat(), "she is still afloat — this is a mission kill, not a sinking")
	eq(captain.status, ShipEntity.Status.MISSION_KILL,
		"a battleship with no main battery cannot fight")
	eq(captain.ai.posture, AiSystem.Posture.DISENGAGE,
		"and a ship that cannot fight is more use afloat tomorrow than sunk today")
	eq(captain.target_id, 0, "she stops engaging")


# -- formations ----------------------------------------------------------------

func test_ships_close_on_their_stations() -> void:
	var world: SimWorld = _world()
	var members: Array[ShipEntity] = []
	for i: int in 3:
		# Deliberately scattered, so the test measures station keeping rather than
		# the placement.
		members.append(world.add_ship(TestShips.fletcher(),
			Vector2(float(i) * -300.0, float(i) * 1800.0), 0.0, 0))
	for ship: ShipEntity in members:
		MovementSystem.set_steady_speed(ship, SimUnits.knots_to_ms(20.0))
	var formation: FormationSystem.Formation = world.add_formation(
		"line", 0, members, FormationSystem.Shape.COLUMN, 600.0)

	var guide: ShipEntity = world.get_ship(formation.guide_id)
	var before: float = members[2].position.distance_to(
		guide.position + formation.station_offset(2).rotated(guide.heading))
	world.step_many(60 * 420)
	var after: float = members[2].position.distance_to(
		guide.position + formation.station_offset(2).rotated(guide.heading))

	lt(after, before * 0.25,
		"the last ship in the column should close her station (%.0f m -> %.0f m)" % [
			before, after])


func test_a_formation_turns_together() -> void:
	# The reason a station is an offset in the GUIDE'S frame rather than a world
	# position: when she turns, every station turns with her, so a column turning
	# together is a turn and not a teleport.
	var world: SimWorld = _world()
	var members: Array[ShipEntity] = []
	for i: int in 3:
		members.append(world.add_ship(TestShips.fletcher(),
			Vector2(float(i) * -600.0, 0.0), 0.0, 0))
	for ship: ShipEntity in members:
		MovementSystem.set_steady_speed(ship, SimUnits.knots_to_ms(20.0))
	var formation: FormationSystem.Formation = world.add_formation(
		"line", 0, members, FormationSystem.Shape.COLUMN, 600.0)
	world.step_many(60 * 60)

	MovementSystem.steer_to_heading(members[0], deg_to_rad(90.0))
	world.step_many(60 * 480)

	var guide: ShipEntity = world.get_ship(formation.guide_id)
	almost(rad_to_deg(guide.heading), 90.0, 2.0,
		"the guide should hold the course she was ordered onto, not turn through it")
	almost(rad_to_deg(SimUnits.angle_delta(members[2].heading, guide.heading)), 0.0, 25.0,
		"the last ship should come round onto the guide's new course")
	lt(members[2].position.distance_to(
		guide.position + formation.station_offset(2).rotated(guide.heading)), 700.0,
		"and work her way back onto her station behind her — over several minutes, "
		+ "which is how long a column really takes to re-form after a big turn")


func test_a_formation_reforms_when_the_guide_is_lost() -> void:
	var world: SimWorld = _world()
	var members: Array[ShipEntity] = []
	for i: int in 3:
		members.append(world.add_ship(TestShips.fletcher(),
			Vector2(float(i) * -600.0, 0.0), 0.0, 0))
	var formation: FormationSystem.Formation = world.add_formation(
		"line", 0, members, FormationSystem.Shape.COLUMN, 600.0)
	eq(formation.guide_id, members[0].id, "the leader guides")

	members[0].status = ShipEntity.Status.DESTROYED
	world.step_many(30)
	eq(formation.guide_id, members[1].id,
		"the line should close up on the next ship rather than dissolving")


# -- fleets --------------------------------------------------------------------

func test_every_fleet_names_ships_that_exist() -> void:
	var fleets: Dictionary = FleetIo.load_all()
	gt(float(fleets.size()), 0.0, "there should be fleets to load")
	for fleet_id: String in Serializer.sorted_keys(fleets):
		var fleet: FleetDef = fleets[fleet_id]
		gt(float(fleet.total_ships()), 0.0, "%s should contain ships" % fleet_id)
		for division: FleetDef.Division in fleet.divisions:
			for unit: FleetDef.Unit in division.units:
				ok(ResourceLoader.exists("res://data/ships/%s.json" % unit.spec_id)
						or FileAccess.file_exists("res://data/ships/%s.json" % unit.spec_id),
					"%s names ship '%s', which should exist" % [fleet_id, unit.spec_id])


func test_deploying_a_fleet_forms_it_up() -> void:
	var world: SimWorld = _world()
	var fleet: FleetDef = FleetIo.load_from_file(
		"res://data/fleets/usn_fast_carrier_task_group.json")
	ok(fleet != null, "the task group should load")

	var deployed: Array[ShipEntity] = FleetIo.deploy(world, fleet, Vector2.ZERO, 0.0,
		func(spec_id: String) -> ShipSpec: return TestShips.load_ship(spec_id))
	eq(deployed.size(), fleet.total_ships(), "every ship in the file should be on the water")
	var divisions_in_company: int = 0
	for division: FleetDef.Division in fleet.divisions:
		if division.total_ships() > 1:
			divisions_in_company += 1
	eq(world.formations.size(), divisions_in_company,
		"each division of more than one ship should become a formation; a single "
		+ "carrier keeps no station on herself")

	for ship: ShipEntity in deployed:
		ok(ship.ai_controlled, "%s should be fought by the AI" % ship.display_name)
		eq(ship.team, fleet.team, "and belong to the fleet's side")

	# Ids ascend in deployment order, which is what makes a fleet action reproducible
	# from the same file.
	for i: int in deployed.size() - 1:
		lt(float(deployed[i].id), float(deployed[i + 1].id),
			"ships must be added in a fixed order")
