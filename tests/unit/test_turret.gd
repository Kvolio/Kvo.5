extends SimTest

## Gun mounts: where they can point, how long they take to get there, and how long
## they take to load.
##
## These numbers are why manoeuvre matters in a gun action. A battleship turret trains
## at four degrees a second and reloads in thirty, so a ship that has to check fire and
## swing her main battery across the deck to answer a new threat loses a minute of
## shooting. Nothing about that is arbitrary — it comes out of the gun data.


func suite_name() -> String:
	return "Turret"


func _iowa_turret(mount_index: int = 0) -> Turret:
	var spec: ShipSpec = TestShips.iowa()
	var gun: GunDef = TestWeapons.gun(spec.main_battery.gun_id)
	return Turret.create(spec.main_battery.mounts[mount_index], gun)


## Iowa's after turret: rest bearing astern, so its blind arc covers the bow.
func _iowa_after_turret() -> Turret:
	var spec: ShipSpec = TestShips.iowa()
	var gun: GunDef = TestWeapons.gun(spec.main_battery.gun_id)
	for mount: MountDef in spec.main_battery.mounts:
		if absf(mount.rest_bearing - PI) < 0.1:
			return Turret.create(mount, gun)
	return null


func _step(turret: Turret, seconds: float) -> void:
	var dt: float = 1.0 / 60.0
	for _i: int in int(seconds / dt):
		turret.step(dt)


# --------------------------------------------------------------------- train --

func test_a_turret_trains_at_its_guns_rate() -> void:
	# Iowa's 16-inch mountings train at 4 degrees a second, so 90 degrees is 22 seconds.
	var turret: Turret = _iowa_turret()
	turret.order_lay(deg_to_rad(90.0), 0.0)

	_step(turret, 10.0)
	almost(rad_to_deg(turret.bearing), 40.0, 1.0, "40 degrees round after ten seconds")
	_step(turret, 15.0)
	almost(rad_to_deg(turret.bearing), 90.0, 0.5, "on the ordered bearing after twenty-five")


func test_a_turret_elevates_at_its_guns_rate() -> void:
	var turret: Turret = _iowa_turret()
	turret.order_lay(0.0, deg_to_rad(30.0))
	_step(turret, 1.0)
	almost(rad_to_deg(turret.elevation), 12.0, 1.0, "12 degrees a second")
	_step(turret, 4.0)
	almost(rad_to_deg(turret.elevation), 30.0, 0.3, "settles at the ordered elevation")


func test_elevation_is_clamped_to_the_guns_limits() -> void:
	var turret: Turret = _iowa_turret()
	turret.order_lay(0.0, deg_to_rad(80.0))   # far beyond a 45-degree mounting
	_step(turret, 20.0)
	almost(turret.elevation, turret.gun.max_elevation_rad, 0.001, "stops at maximum elevation")

	turret.order_lay(0.0, deg_to_rad(-40.0))
	_step(turret, 20.0)
	almost(turret.elevation, turret.gun.min_elevation_rad, 0.001, "and at maximum depression")


func test_a_turret_swings_within_its_arc_not_through_its_blind_zone() -> void:
	# Trained 100 degrees to port and ordered 100 to starboard, the SHORTER angular
	# path is the 160 degrees across the stern — but the training stops are in the
	# way, so a real mount must take the 200 degrees across the bow instead.
	#
	# A naive shortest-angle rotation gets this exactly wrong, and gets it wrong in
	# the flattering direction: the turret arrives sooner than it possibly could.
	var turret: Turret = _iowa_turret()
	turret.train_offset = deg_to_rad(-100.0)
	turret.bearing = deg_to_rad(-100.0)
	turret.order_lay(deg_to_rad(100.0), 0.0)
	_step(turret, 5.0)
	gt(rad_to_deg(SimUnits.angle_delta(deg_to_rad(-100.0), turret.bearing)), 0.0,
		"swinging towards the bow, not away from it")
	lt(absf(rad_to_deg(turret.bearing)), 100.0, "and is closer to dead ahead than it started")

	# 200 degrees at 4 degrees a second is 50 seconds. It must not arrive in 40.
	_step(turret, 35.0)
	lt(rad_to_deg(turret.train_offset), 100.0, "still short of the ordered bearing at 40 seconds")
	_step(turret, 15.0)
	almost(rad_to_deg(turret.train_offset), 100.0, 1.0, "and arrives at about fifty")


# ---------------------------------------------------------------------- arcs --

func test_a_forward_turret_cannot_fire_astern() -> void:
	var turret: Turret = _iowa_turret()
	ok(turret.mount.can_bear(0.0), "dead ahead")
	ok(turret.mount.can_bear(deg_to_rad(90.0)), "abeam to starboard")
	ok(turret.mount.can_bear(deg_to_rad(-90.0)), "abeam to port")
	not_ok(turret.mount.can_bear(PI), "dead astern is blanked by the ship's own superstructure")


func test_an_after_turret_cannot_fire_ahead() -> void:
	var turret: Turret = _iowa_after_turret()
	ok(turret != null, "Iowa has an after turret")
	ok(turret.mount.can_bear(PI), "dead astern")
	ok(turret.mount.can_bear(deg_to_rad(90.0)), "abeam")
	not_ok(turret.mount.can_bear(0.0), "dead ahead is blanked")


func test_every_mount_has_a_blind_arc() -> void:
	# A mount that could train through 360 degrees would be a mount with no ship
	# around it.
	var turret: Turret = _iowa_turret()
	gt(turret.mount.blind_arc(), deg_to_rad(30.0), "a real blind arc exists")


func test_a_turret_trains_as_far_as_its_stops_allow() -> void:
	# Ordered onto a target in its blind arc, a mount goes to its stop and waits
	# there, so it is already close when the ship's turn brings the target into arc.
	var turret: Turret = _iowa_turret()
	turret.order_lay(deg_to_rad(179.0), 0.0)
	_step(turret, 60.0)
	almost(rad_to_deg(turret.bearing), 150.0, 1.0, "hard against the training stop")
	not_ok(turret.is_ready_to_fire(deg_to_rad(1.0), deg_to_rad(0.5)),
		"but not permitted to fire, because it still cannot bear")


func test_standing_down_returns_a_turret_to_its_rest_bearing() -> void:
	var turret: Turret = _iowa_turret()
	turret.order_lay(deg_to_rad(120.0), deg_to_rad(20.0))
	_step(turret, 40.0)
	turret.stand_down()
	_step(turret, 60.0)
	almost(rad_to_deg(turret.bearing), 0.0, 1.0, "back fore and aft")
	almost(rad_to_deg(turret.elevation), 0.0, 0.5, "and depressed")
	not_ok(turret.has_orders, "with no orders standing")


# -------------------------------------------------------------------- loading --

func test_reload_takes_the_guns_stated_time() -> void:
	# Iowa's 16-inch guns fire twice a minute: thirty seconds a round.
	var turret: Turret = _iowa_turret()
	turret.order_lay(0.0, 0.0)
	_step(turret, 5.0)
	ok(turret.is_ready_to_fire(deg_to_rad(1.0), deg_to_rad(0.5)), "loaded and laid")

	turret.mark_fired()
	not_ok(turret.is_ready_to_fire(deg_to_rad(1.0), deg_to_rad(0.5)), "empty immediately after firing")
	_step(turret, 20.0)
	not_ok(turret.is_ready_to_fire(deg_to_rad(1.0), deg_to_rad(0.5)), "still loading after twenty seconds")
	_step(turret, 12.0)
	ok(turret.is_ready_to_fire(deg_to_rad(1.0), deg_to_rad(0.5)), "ready again after thirty")


func test_a_fast_firing_gun_reloads_far_quicker() -> void:
	var five_inch: GunDef = TestWeapons.gun("usa_5in38_mk12")
	var sixteen_inch: GunDef = TestWeapons.gun("usa_16in50_mk7")
	lt(five_inch.seconds_per_round(), sixteen_inch.seconds_per_round() * 0.2,
		"a 5-inch/38 fires fifteen rounds a minute against the 16-inch gun's two")


func test_firing_counts_barrels_not_mounts() -> void:
	var turret: Turret = _iowa_turret()
	eq(turret.barrels(), 3, "a triple turret")
	turret.mark_fired()
	eq(turret.rounds_fired, 3, "puts three shells in the air per salvo")


# --------------------------------------------------------------------- damage --

func test_a_damaged_mount_trains_and_loads_more_slowly() -> void:
	var healthy: Turret = _iowa_turret()
	var damaged: Turret = _iowa_turret()
	damaged.state = Turret.State.DAMAGED
	healthy.order_lay(deg_to_rad(90.0), 0.0)
	damaged.order_lay(deg_to_rad(90.0), 0.0)
	_step(healthy, 10.0)
	_step(damaged, 10.0)
	lt(damaged.bearing, healthy.bearing * 0.7, "trains at half speed")

	healthy.mark_fired()
	damaged.mark_fired()
	_step(healthy, 31.0)
	_step(damaged, 31.0)
	ok(healthy.reload_remaining <= 0.0, "the healthy mount has reloaded")
	gt(damaged.reload_remaining, 0.0, "the damaged one has not")


func test_a_destroyed_mount_does_nothing_at_all() -> void:
	var turret: Turret = _iowa_turret()
	turret.state = Turret.State.DESTROYED
	turret.order_lay(deg_to_rad(90.0), deg_to_rad(20.0))
	_step(turret, 60.0)
	almost(turret.bearing, 0.0, 0.0001, "does not train")
	almost(turret.elevation, 0.0, 0.0001, "does not elevate")
	not_ok(turret.is_operational(), "and is not counted as a working mount")
	not_ok(turret.is_ready_to_fire(deg_to_rad(1.0), deg_to_rad(0.5)), "nor able to fire")


func test_a_disabled_mount_may_come_back() -> void:
	# Disabled is repairable, destroyed is not. Stage 5's damage control depends on
	# the distinction.
	var turret: Turret = _iowa_turret()
	turret.state = Turret.State.DISABLED
	not_ok(turret.is_operational(), "out of action while disabled")
	turret.state = Turret.State.OPERATIONAL
	ok(turret.is_operational(), "and back in action once repaired")


# ------------------------------------------------------------------ mechanics --

func test_mount_positions_scale_with_the_hull() -> void:
	# Positions are stored normalised, so stretching a hull in the designer keeps the
	# turrets in sensible places instead of leaving them over the side.
	var mount: MountDef = TestShips.iowa().main_battery.mounts[0]
	var small: Vector2 = mount.local_position(100.0, 10.0)
	var large: Vector2 = mount.local_position(300.0, 30.0)
	almost(large.x / small.x, 3.0, 0.001, "station scales with length")
	almost(mount.local_position(270.0, 33.0).y, 0.0, 0.001, "a centreline turret stays on the centreline")


func test_serialisation_round_trip() -> void:
	var turret: Turret = _iowa_turret()
	turret.order_lay(deg_to_rad(45.0), deg_to_rad(10.0))
	_step(turret, 20.0)
	turret.mark_fired()

	var restored: Turret = _iowa_turret()
	restored.deserialize(turret.serialize())
	almost(restored.bearing, turret.bearing, 1e-9, "bearing restored exactly")
	almost(restored.elevation, turret.elevation, 1e-9, "elevation restored exactly")
	almost(restored.reload_remaining, turret.reload_remaining, 1e-9, "mid-reload state restored")
	eq(restored.rounds_fired, turret.rounds_fired, "rounds fired restored")
