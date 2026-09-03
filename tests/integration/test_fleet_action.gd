extends SimTest

## Two fleets, from their own files, fighting each other end to end.
##
## Every piece built in Stage 7 has a unit test, and every one of them passed while the
## whole thing did nothing: two task groups closed for twenty-five minutes, fired
## fifteen hundred shells and scored not one hit. Nothing was broken — they were simply
## engaging at thirty kilometres, where the hit rate really is zero, and shifting target
## often enough that no plot ever settled.
##
## That is exactly the class of failure a suite of unit tests cannot see, so this suite
## asserts the thing that actually matters: put two fleets in contact and a battle
## happens. Ships find each other, open fire, hit, and sink.
##
## It is the most expensive suite in the project — five minutes of a seventeen-ship
## action, run once and shared across the tests below, plus a shorter second run for the
## determinism check. That is the price of asserting an outcome rather than a mechanism.

const RNG_SEED: int = 20260903
const MINUTES: float = 5.0


func suite_name() -> String:
	return "Integration: fleet action"


class Outcome extends RefCounted:
	var world: SimWorld = null
	var shells: int = 0
	var hits: int = 0
	var torpedoes: int = 0
	var lost: int = 0


static var _cached: Outcome = null


## Run once and share, because eight minutes of a seventeen-ship action is not cheap
## and every test below is asking a different question about the same battle.
func _battle() -> Outcome:
	if _cached != null:
		return _cached

	var outcome: Outcome = Outcome.new()
	var world: SimWorld = SimWorld.create(RNG_SEED, TestShips.config())
	world.set_armory(TestWeapons.armory())
	outcome.world = world

	var lookup: Callable = func(spec_id: String) -> ShipSpec:
		return TestShips.load_ship(spec_id)
	for entry: Array in [
			["usn_fast_carrier_task_group", Vector2(-9000.0, -5000.0), 25.0, 0],
			["ijn_mobile_force", Vector2(9000.0, 5000.0), 205.0, 1]]:
		var fleet: FleetDef = FleetIo.load_from_file(
			"res://data/fleets/%s.json" % entry[0])
		fleet.team = int(entry[3])
		for ship: ShipEntity in FleetIo.deploy(world, fleet, entry[1] as Vector2,
				deg_to_rad(float(entry[2])), lookup):
			MovementSystem.order_speed(ship, SimUnits.knots_to_ms(24.0))

	var afloat_at_start: int = world.ships.size()
	for _i: int in int(MINUTES * 60.0 * 60.0):
		world.step()
		for event: SimEvent in world.events.events_this_tick():
			match event.type:
				&"salvo_fired":
					outcome.shells += int(event.data.get("barrels", 0))
				&"shell_hit":
					outcome.hits += 1
				&"torpedoes_fired":
					outcome.torpedoes += 1

	for ship: ShipEntity in world.ships:
		if not ship.is_afloat():
			outcome.lost += 1
	outcome.lost = maxi(outcome.lost, afloat_at_start - world.active_ships().size())
	_cached = outcome
	return outcome


func test_both_fleets_deploy_and_form_up() -> void:
	var outcome: Outcome = _battle()
	eq(outcome.world.ships.size(), 17,
		"ten American ships and seven Japanese, from two files naming nothing but "
		+ "ship ids")
	# Counted from the files rather than asserted as a number: a single carrier keeps
	# no station on herself, so only divisions of more than one ship become formations.
	var expected: int = 0
	for fleet_id: String in ["usn_fast_carrier_task_group", "ijn_mobile_force"]:
		var fleet: FleetDef = FleetIo.load_from_file(
			"res://data/fleets/%s.json" % fleet_id)
		for division: FleetDef.Division in fleet.divisions:
			if division.total_ships() > 1:
				expected += 1
	eq(outcome.world.formations.size(), expected,
		"and each division of more than one ship keeping station")


func test_each_side_builds_a_picture_of_the_other() -> void:
	var outcome: Outcome = _battle()
	gt(float(outcome.world.contacts.contacts_for(0).size()), 3.0,
		"blue should hold most of the Japanese force")
	gt(float(outcome.world.contacts.contacts_for(1).size()), 3.0,
		"and red most of the American")


func test_the_action_is_actually_fought() -> void:
	var outcome: Outcome = _battle()
	gt(float(outcome.shells), 400.0, "a great many shells")
	gt(float(outcome.hits), 15.0, "and enough of them arriving to be a battle")

	# The figure that matters. Fire that never connects is the failure this suite
	# exists to catch, and a rate this far below one percent means something has gone
	# wrong with the plot rather than that the gunnery is difficult.
	var rate: float = 100.0 * float(outcome.hits) / maxf(float(outcome.shells), 1.0)
	between(rate, 1.0, 25.0,
		"hits should be hard but not impossible — %.1f%% of shells arrived" % rate)


func test_ships_are_lost() -> void:
	var outcome: Outcome = _battle()
	gt(float(outcome.lost), 0.0,
		"five minutes of a fleet action should cost somebody a ship")


func test_the_destroyers_spend_their_torpedoes() -> void:
	var outcome: Outcome = _battle()
	gt(float(outcome.torpedoes), 0.0,
		"the screens should get their salvos away — it is the only thing a destroyer "
		+ "can do to a battleship")


func test_the_whole_fleet_action_is_reproducible() -> void:
	# The determinism contract, on the largest thing the simulation does. Seventeen
	# ships, two AIs choosing targets and courses, detection, gunnery, torpedoes and
	# damage, all from one seed.
	var checksums: Array[int] = []
	for _run: int in 2:
		var world: SimWorld = SimWorld.create(RNG_SEED, TestShips.config())
		world.set_armory(TestWeapons.armory())
		var lookup: Callable = func(spec_id: String) -> ShipSpec:
			return TestShips.load_ship(spec_id)
		for entry: Array in [
				["usn_fast_carrier_task_group", Vector2(-9000.0, -5000.0), 25.0, 0],
				["ijn_mobile_force", Vector2(9000.0, 5000.0), 205.0, 1]]:
			var fleet: FleetDef = FleetIo.load_from_file(
				"res://data/fleets/%s.json" % entry[0])
			fleet.team = int(entry[3])
			for ship: ShipEntity in FleetIo.deploy(world, fleet, entry[1] as Vector2,
					deg_to_rad(float(entry[2])), lookup):
				MovementSystem.order_speed(ship, SimUnits.knots_to_ms(24.0))
		world.step_many(60 * 45)
		checksums.append(world.checksum())
	eq(checksums[0], checksums[1],
		"a seventeen-ship action must replay bit for bit from the same seed")
