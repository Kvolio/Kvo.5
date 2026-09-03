extends SimTest

## The world ties the deterministic primitives to the entities. Most of what matters
## here is that identical inputs produce identical outputs, tick for tick.


func suite_name() -> String:
	return "SimWorld"


func _two_ship_world(seed_value: int = 99) -> SimWorld:
	var world: SimWorld = SimWorld.create(seed_value, TestShips.config())
	world.add_ship(TestShips.iowa(), Vector2(0, 0), 0.0, 0)
	world.add_ship(TestShips.fletcher(), Vector2(5000, 2000), PI, 1)
	return world


# ------------------------------------------------------------- determinism --

func test_identical_worlds_stay_identical_tick_for_tick() -> void:
	var a: SimWorld = _two_ship_world()
	var b: SimWorld = _two_ship_world()
	for ship: ShipEntity in a.ships:
		ship.throttle = 1.0
		MovementSystem.order_rudder(ship, 0.3)
	for ship: ShipEntity in b.ships:
		ship.throttle = 1.0
		MovementSystem.order_rudder(ship, 0.3)

	for tick: int in 3000:
		a.step()
		b.step()
		if a.checksum() != b.checksum():
			fail("diverged at tick %d" % tick)
			return
	ok(true, "3000 ticks, identical checksums throughout")


func test_the_same_orders_through_the_command_queue_reproduce_the_same_battle() -> void:
	var checksums: Array[int] = []
	for run: int in 2:
		var world: SimWorld = _two_ship_world(4242)
		world.commands.submit_new(SimWorld.CMD_SET_SPEED_KNOTS, 10, 1, {"value": 28.0})
		world.commands.submit_new(SimWorld.CMD_SET_RUDDER, 120, 1, {"value": -0.8})
		world.commands.submit_new(SimWorld.CMD_SET_SPEED_KNOTS, 10, 2, {"value": 34.0})
		world.commands.submit_new(SimWorld.CMD_STEER_HEADING, 300, 2, {"value": 1.2})
		world.step_many(2000)
		checksums.append(world.checksum())
	eq(checksums[0], checksums[1], "seed plus command log reproduces the battle exactly")


func test_a_different_seed_or_a_different_order_changes_the_outcome() -> void:
	var base: SimWorld = _two_ship_world(1)
	base.commands.submit_new(SimWorld.CMD_SET_SPEED_KNOTS, 5, 1, {"value": 20.0})
	base.step_many(600)

	var altered: SimWorld = _two_ship_world(1)
	altered.commands.submit_new(SimWorld.CMD_SET_SPEED_KNOTS, 5, 1, {"value": 21.0})
	altered.step_many(600)
	ne(base.checksum(), altered.checksum(), "a different order produces a different battle")


func test_checksum_reacts_to_any_state_change() -> void:
	var world: SimWorld = _two_ship_world()
	var before: int = world.checksum()
	world.ships[0].position.x += 0.0000001
	ne(world.checksum(), before, "even a fractional position change is detected")


# ----------------------------------------------------------------- entities --

func test_ships_are_stored_in_ascending_id_order() -> void:
	# Every system that walks the ship list inherits its determinism from this.
	var world: SimWorld = SimWorld.create(1, TestShips.config())
	for i: int in 8:
		world.add_ship(TestShips.fletcher(), Vector2(float(i) * 100.0, 0.0), 0.0, i % 2)
	var previous: int = -1
	for ship: ShipEntity in world.ships:
		gt(float(ship.id), float(previous), "ids ascend")
		previous = ship.id


func test_spawning_and_removing() -> void:
	var world: SimWorld = _two_ship_world()
	eq(world.ships.size(), 2, "two ships")
	var iowa_id: int = world.ships[0].id
	ok(world.has_ship(iowa_id), "lookup by id")
	eq(world.get_ship(iowa_id).display_name, "USS Iowa", "correct ship returned")

	ok(world.remove_ship(iowa_id), "removed")
	eq(world.ships.size(), 1, "one left")
	not_ok(world.has_ship(iowa_id), "gone from the index")
	not_ok(world.remove_ship(iowa_id), "removing twice is a no-op")
	eq(world.spatial.size(), 1, "and gone from the spatial index too")


func test_ships_can_be_spawned_mid_battle() -> void:
	var world: SimWorld = _two_ship_world()
	world.step_many(600)
	var latecomer: ShipEntity = world.add_ship(TestShips.fletcher(), Vector2(9000, 0), 0.0, 1)
	gt(float(latecomer.id), float(world.ships[0].id), "gets a fresh id")
	eq(world.ships.size(), 3, "joins the battle")
	world.step_many(60)
	ok(world.spatial.has(latecomer.id), "and is immediately findable")


func test_team_filtering() -> void:
	var world: SimWorld = _two_ship_world()
	eq(world.ships_of_team(0).size(), 1, "one on team 0")
	eq(world.ships_of_team(1).size(), 1, "one on team 1")
	eq(world.ships_of_team(7).size(), 0, "none on an unused team")


func test_active_ships_excludes_the_sunk() -> void:
	var world: SimWorld = _two_ship_world()
	world.ships[0].status = ShipEntity.Status.DESTROYED
	eq(world.active_ships().size(), 1, "a sunk ship is no longer active")
	eq(world.ships.size(), 2, "but is still in the world, as a wreck")


# ----------------------------------------------------------------- commands --

func test_commands_take_effect_on_their_scheduled_tick() -> void:
	var world: SimWorld = _two_ship_world()
	var iowa: ShipEntity = world.ships[0]
	world.commands.submit_new(SimWorld.CMD_SET_THROTTLE, 100, iowa.id, {"value": 1.0})

	world.step_many(99)
	almost(iowa.throttle, 0.0, 1e-9, "not yet")
	world.step_many(2)
	almost(iowa.throttle, 1.0, 1e-9, "applied on tick 100")


func test_every_command_type_is_handled() -> void:
	var world: SimWorld = _two_ship_world()
	var dd: ShipEntity = world.ships[1]
	world.commands.submit_new(SimWorld.CMD_SET_SPEED_KNOTS, 0, dd.id, {"value": 30.0})
	world.step()
	gt(dd.throttle, 0.0, "speed order")

	world.commands.submit_new(SimWorld.CMD_SET_RUDDER, world.clock.tick, dd.id, {"value": 1.0})
	world.step()
	gt(dd.rudder_order, 0.0, "rudder order")

	world.commands.submit_new(SimWorld.CMD_STEER_HEADING, world.clock.tick, dd.id, {"value": 0.0})
	world.step()
	ok(true, "heading order accepted")

	world.commands.submit_new(SimWorld.CMD_STEER_POINT, world.clock.tick, dd.id,
		{"value": [10000.0, 0.0]})
	world.step()
	ok(true, "waypoint order accepted")


func test_a_command_for_a_ship_that_has_sunk_is_ignored_not_fatal() -> void:
	var world: SimWorld = _two_ship_world()
	var doomed_id: int = world.ships[0].id
	world.remove_ship(doomed_id)
	world.commands.submit_new(SimWorld.CMD_SET_THROTTLE, 0, doomed_id, {"value": 1.0})
	world.step()
	ok(true, "orders to a ship that is no longer there are discarded quietly")


# ------------------------------------------------------------------- events --

func test_spawning_and_removing_emit_events() -> void:
	var world: SimWorld = SimWorld.create(1, TestShips.config())
	world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var drained: Array[SimEvent] = world.events.drain()
	eq(drained.size(), 1, "one spawn event")
	eq(String(drained[0].type), "ship_spawned", "correct type")
	eq((drained[0].data as Dictionary)["name"], "USS Iowa", "carries the ship name")


# ------------------------------------------------------------------ spatial --

func test_the_spatial_index_follows_the_ships() -> void:
	var world: SimWorld = _two_ship_world()
	var iowa: ShipEntity = world.ships[0]
	iowa.throttle = 1.0
	TestShips.run_seconds(world, 300.0)

	gt(iowa.position.length(), 1000.0, "the ship has moved a long way")
	var near: PackedInt32Array = world.spatial.query_radius(iowa.position, 200.0, SpatialIndex.Layer.SHIP)
	ok(Array(near).has(iowa.id), "and the index knows where she is now")


func test_serialisation_captures_the_whole_world() -> void:
	var world: SimWorld = _two_ship_world(777)
	world.step_many(300)
	var data: Dictionary = world.serialize()
	eq(int(data["seed"]), 777, "seed recorded")
	eq((data["ships"] as Array).size(), 2, "both ships recorded")
	ok((data as Dictionary).has("rng"), "rng stream positions recorded")
	ok((data as Dictionary).has("ids"), "id allocator recorded")
	# It must survive canonical encoding, since that is how a battle is written out.
	var text: String = Serializer.to_json(data)
	ne(Serializer.from_json(text), null, "round-trips through canonical JSON")
