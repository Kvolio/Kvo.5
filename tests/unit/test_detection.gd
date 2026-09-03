extends SimTest

## Finding the enemy.
##
## The tests that matter here are the ones about the horizon, because the horizon is
## what actually decided when a sighting happened and it is a piece of geometry rather
## than a number in anybody's data file.


func suite_name() -> String:
	return "Detection"


func _world(seed_value: int = 5) -> SimWorld:
	return TestShips.armed_world(seed_value)


func _config() -> Dictionary:
	return JsonLoader.load_dict("res://data/config/detection.json")


func test_the_horizon_goes_as_the_square_root_of_height() -> void:
	var config: Dictionary = _config()
	var low: float = DetectionSystem.optical_horizon(9.0, 0.0, config)
	var high: float = DetectionSystem.optical_horizon(36.0, 0.0, config)
	almost(high / low, 2.0, 0.01,
		"quadrupling the observer's height should double her horizon (%.0f m, %.0f m)" % [
			low, high])
	# The standard figure: a lookout 30 m up sees about 19.5 km of sea.
	almost(DetectionSystem.optical_horizon(30.0, 0.0, config), 19550.0, 300.0,
		"a 30 m masthead should see the horizon at about 19.5 km")


func test_both_ships_heights_count_towards_the_sighting() -> void:
	# Why the masts are sighted long before the hull, and why a destroyer sees a
	# battleship at the same distance the battleship sees her: the geometry is
	# symmetric even though the ships are not.
	var config: Dictionary = _config()
	var alone: float = DetectionSystem.optical_horizon(25.0, 0.0, config)
	var pair: float = DetectionSystem.optical_horizon(25.0, 45.0, config)
	gt(pair, alone, "a tall target should be visible beyond the observer's own horizon")
	almost(pair, DetectionSystem.optical_horizon(45.0, 25.0, config), 1.0,
		"the sighting range should not depend on which ship is called the observer")


func test_a_ship_below_the_horizon_is_not_seen() -> void:
	var world: SimWorld = _world()
	var watcher: ShipEntity = world.add_ship(TestShips.fletcher(), Vector2.ZERO, 0.0, 0)
	var far: float = DetectionSystem.optical_horizon(
		watcher.sighting_height_m, 60.0, world.detection_config) * 3.0
	var hidden: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(far, 0.0), PI, 1)
	world.step_many(120)
	not_ok(world.contacts.has_contact(watcher.team, hidden.id),
		"a battleship three horizons away should not be seen")

	# Bring her over the horizon and she appears.
	hidden.position = Vector2(
		DetectionSystem.optical_horizon(watcher.sighting_height_m,
			hidden.sighting_height_m, world.detection_config) * 0.5, 0.0)
	world.step_many(120)
	ok(world.contacts.has_contact(watcher.team, hidden.id),
		"a battleship well inside the horizon should be seen")


func test_a_ship_is_taller_than_her_hull_and_is_seen_further_for_it() -> void:
	var world: SimWorld = _world()
	var iowa: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var fletcher: ShipEntity = world.add_ship(TestShips.fletcher(), Vector2(1000.0, 0.0), 0.0, 1)
	gt(iowa.sighting_height_m, fletcher.sighting_height_m,
		"a battleship's foretop stands higher than a destroyer's (%.0f m vs %.0f m)" % [
			iowa.sighting_height_m, fletcher.sighting_height_m])
	gt(iowa.sighting_height_m, iowa.spec.draft_m,
		"sighting height is measured above the waterline, not from the keel")


func test_radar_sees_at_night_when_the_eye_cannot() -> void:
	# The reason the US Navy stopped losing night actions.
	var world: SimWorld = _world()
	world.detection_config["conditions"] = {"night": true, "visibilityFactor": 1.0}
	world.fire_control_config["conditions"] = {"visibilityFactor": 0.15, "opticalUsable": false}

	var radar_ship: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var blind: ShipEntity = world.add_ship(TestShips.load_ship("ijn_kagero"),
		Vector2(0.0, 12000.0), PI, 1)
	# The Kagero of 1941 has no set; the Iowa of 1943 has one.
	world.step_many(180)

	ok(world.contacts.has_contact(radar_ship.team, blind.id),
		"a ship with radar should hold a contact at 12 km on a dark night")
	not_ok(world.contacts.has_contact(blind.team, radar_ship.id),
		"a ship without one should see nothing at that range in the dark")


func test_a_gun_flash_gives_a_ship_away_past_the_horizon() -> void:
	# How most night actions actually opened, and why opening fire is a decision.
	var world: SimWorld = _world()
	world.detection_config["conditions"] = {"night": true, "visibilityFactor": 1.0}
	var watcher: ShipEntity = world.add_ship(TestShips.load_ship("ijn_kagero"),
		Vector2.ZERO, 0.0, 0)
	var firing: ShipEntity = world.add_ship(TestShips.load_ship("ijn_yamato"),
		Vector2(0.0, 26000.0), PI, 1)

	world.step_many(60)
	var quiet: bool = world.contacts.has_contact(watcher.team, firing.id)
	firing.firing_seconds_ago = 0.0
	world.step_many(30)
	var flashed: bool = world.contacts.has_contact(watcher.team, firing.id)

	not_ok(quiet, "a darkened ship at 26 km should not be seen on a dark night")
	ok(flashed, "her gun flash should be")
	var contact: ContactPlot.Contact = world.contacts.contact(watcher.team, firing.id)
	eq(contact.method, ContactPlot.Method.GUN_FLASH, "and it should be recorded as a flash")
	not_ok(contact.is_firm(0.0),
		"a flash is a bearing and a guess, not a target — it should never be firm")


func test_a_burning_ship_is_a_beacon() -> void:
	var world: SimWorld = _world()
	world.detection_config["conditions"] = {"night": true, "visibilityFactor": 1.0}
	var watcher: ShipEntity = world.add_ship(TestShips.load_ship("ijn_kagero"),
		Vector2.ZERO, 0.0, 0)
	var burning: ShipEntity = world.add_ship(TestShips.load_ship("ijn_mogami"),
		Vector2(0.0, 22000.0), PI, 1)
	world.step_many(60)
	not_ok(world.contacts.has_contact(watcher.team, burning.id),
		"a darkened cruiser at 22 km should not be seen")

	burning.condition.fire_fraction = 0.4
	world.step_many(60)
	ok(world.contacts.has_contact(watcher.team, burning.id),
		"a cruiser well alight should be, which is why a damaged ship at night was so "
		+ "much easier to finish than to find")


func test_a_contact_is_carried_forward_and_then_forgotten() -> void:
	# Dead reckoning is not a nicety. A contact carried forward on a course the target
	# has since left is the most dangerous kind of information there is, and a plot that
	# dropped a contact the instant it was lost could never produce that mistake.
	var world: SimWorld = _world()
	world.detection_config["plot"]["forgetSeconds"] = 20.0
	var watcher: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var seen: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, 14000.0), 0.0, 1)
	MovementSystem.set_steady_speed(seen, SimUnits.knots_to_ms(30.0))
	world.step_many(240)
	ok(world.contacts.has_contact(watcher.team, seen.id), "she should be held first")

	var held: Vector2 = world.contacts.contact(watcher.team, seen.id).estimated_position
	# She vanishes: over the horizon in one step.
	seen.position = Vector2(0.0, 400000.0)
	world.step_many(600)   # ten seconds of dead reckoning at thirty knots
	var contact: ContactPlot.Contact = world.contacts.contact(watcher.team, seen.id)
	ok(contact != null, "the contact should be carried forward, not dropped at once")
	gt(contact.estimated_position.distance_to(held), 100.0,
		"and carried forward on her last known course")
	not_ok(contact.is_live(), "while being marked as no longer observed")

	world.step_many(20 * 60)
	not_ok(world.contacts.has_contact(watcher.team, seen.id),
		"a contact stale for longer than the forget time should be dropped")


func test_the_plot_is_per_team_and_ordered_by_id() -> void:
	var world: SimWorld = _world()
	var blue: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var red_a: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, 9000.0), PI, 1)
	var red_b: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(600.0, 9000.0), PI, 1)
	world.step_many(120)

	var contacts: Array[ContactPlot.Contact] = world.contacts.contacts_for(blue.team)
	eq(contacts.size(), 2, "blue should hold both red ships")
	lt(float(contacts[0].entity_id), float(contacts[1].entity_id),
		"contacts must come back in ascending id order, or targeting is not deterministic")
	eq(world.contacts.contacts_for(9).size(), 0, "a team with no ships holds no contacts")
	ok(world.contacts.has_contact(red_a.team, blue.id),
		"and red should hold blue, reported by whichever of her ships saw her")
	ok(red_b.id != 0, "both red ships exist")
