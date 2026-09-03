extends SimTest

## The hull outline is what gets drawn, what shells are intersected against, and
## what the internal layout is fitted inside. If it is wrong, everything downstream
## is wrong in a way that looks like a damage-model bug.


func suite_name() -> String:
	return "HullGeometry"


func test_outline_spans_the_full_length_and_beam() -> void:
	var hull: HullGeometry = HullGeometry.create(200.0, 20.0, 8.0)
	var min_x: float = INF
	var max_x: float = -INF
	var max_y: float = 0.0
	for point: Vector2 in hull.outline_local():
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		max_y = maxf(max_y, absf(point.y))
	almost(min_x, -100.0, 0.01, "stern at half length aft")
	almost(max_x, 100.0, 0.01, "bow at half length forward")
	almost(max_y, 10.0, 0.2, "maximum half-beam reaches the design beam")


func test_bow_is_a_point_and_the_stern_is_not() -> void:
	# A warship has a fine stem and a much fuller stern. Getting these the wrong way
	# round would make every ship look and behave as though it were sailing backwards.
	var hull: HullGeometry = HullGeometry.create(200.0, 20.0, 8.0)
	almost(hull.half_beam_at(0.5), 0.0, 0.01, "bow comes to a point")
	gt(hull.half_beam_at(-0.5), 2.0, "stern carries real width")
	lt(hull.half_beam_at(-0.5), 8.0, "but is still narrower than midships")
	almost(hull.half_beam_at(0.0), 10.0, 0.3, "widest at midships")


func test_half_beam_is_symmetric_and_clamped_outside_the_hull() -> void:
	var hull: HullGeometry = HullGeometry.create(100.0, 10.0, 4.0)
	eq(hull.half_beam_at(2.0), hull.half_beam_at(0.5), "stations forward of the bow clamp")
	eq(hull.half_beam_at(-2.0), hull.half_beam_at(-0.5), "stations aft of the stern clamp")


func test_containment() -> void:
	var hull: HullGeometry = HullGeometry.create(200.0, 20.0, 8.0)
	ok(hull.contains_local(Vector2(0.0, 0.0)), "origin is inside")
	ok(hull.contains_local(Vector2(0.0, 9.0)), "just inside the beam at midships")
	not_ok(hull.contains_local(Vector2(0.0, 11.0)), "outside the beam")
	not_ok(hull.contains_local(Vector2(150.0, 0.0)), "beyond the bow")
	not_ok(hull.contains_local(Vector2(90.0, 9.0)), "wide of the fine bow, though within the box")


func test_world_transform_follows_position_and_heading() -> void:
	var hull: HullGeometry = HullGeometry.create(100.0, 10.0, 4.0)
	var origin: Vector2 = Vector2(1000.0, 500.0)
	ok(hull.contains_world(origin, origin, 0.0), "own position is inside")
	# Heading east: a point 40 m ahead is inside; 40 m abeam is not.
	ok(hull.contains_world(origin + Vector2(40.0, 0.0), origin, 0.0), "ahead, heading east")
	not_ok(hull.contains_world(origin + Vector2(0.0, 40.0), origin, 0.0), "abeam, heading east")
	# Turn the ship 90 degrees and the same two points swap.
	ok(hull.contains_world(origin + Vector2(0.0, 40.0), origin, PI * 0.5), "ahead, heading south")
	not_ok(hull.contains_world(origin + Vector2(40.0, 0.0), origin, PI * 0.5), "abeam, heading south")


func test_bounding_radius_covers_the_whole_outline() -> void:
	var hull: HullGeometry = HullGeometry.create(200.0, 20.0, 8.0)
	var radius: float = hull.bounding_radius()
	for point: Vector2 in hull.outline_local():
		le(point.length(), radius + 0.001, "every outline point is within the bounding radius")
	almost(radius, 100.0, 1.0, "dominated by half the length, as it should be for a ship")


func test_waterplane_coefficient_is_realistic() -> void:
	# Warship waterplane coefficients sit around 0.70-0.75. A value outside that band
	# means the hull form control points are wrong, and every derived volume,
	# displacement and stability figure built on them would be wrong too.
	var hull: HullGeometry = HullGeometry.create(200.0, 20.0, 8.0)
	between(hull.waterplane_coefficient(), 0.66, 0.80, "default form is warship-shaped")


func test_waterplane_coefficient_is_scale_invariant() -> void:
	# The same hull form at any size must have the same fullness — that is what makes
	# a hull form reusable across a 115 m destroyer and a 270 m battleship.
	var small: HullGeometry = HullGeometry.create(100.0, 10.0, 4.0)
	var large: HullGeometry = HullGeometry.create(300.0, 35.0, 11.0)
	almost(small.waterplane_coefficient(), large.waterplane_coefficient(), 0.001,
		"fullness is a property of the form, not the size")


func test_displacement_estimate_is_in_the_right_order() -> void:
	# An Iowa-sized box: 270 x 33 x 11.6 m. Real full-load displacement is about
	# 57,500 tonnes, and a waterplane-derived estimate should land near it.
	var hull: HullGeometry = HullGeometry.create(270.4, 33.0, 11.6,
		HullGeometry.profile_from_array(
			(JsonLoader.load_dict("res://data/hullforms/battleship.json").get("profile", []) as Array)
		))
	var estimate: float = hull.estimated_displacement_tonnes(0.85)
	between(estimate, 45000.0, 70000.0, "battleship-scale displacement from geometry alone")


func test_finer_hull_forms_displace_less_in_the_same_box() -> void:
	var box: Array = [200.0, 20.0, 8.0]
	var battleship_profile: PackedVector2Array = HullGeometry.profile_from_array(
		JsonLoader.load_dict("res://data/hullforms/battleship.json").get("profile", []) as Array)
	var destroyer_profile: PackedVector2Array = HullGeometry.profile_from_array(
		JsonLoader.load_dict("res://data/hullforms/destroyer.json").get("profile", []) as Array)
	var full: HullGeometry = HullGeometry.create(box[0], box[1], box[2], battleship_profile)
	var fine: HullGeometry = HullGeometry.create(box[0], box[1], box[2], destroyer_profile)
	gt(full.waterplane_area(), fine.waterplane_area(),
		"a destroyer form is finer than a battleship form of identical dimensions")


func test_degenerate_dimensions_are_clamped_rather_than_dividing_by_zero() -> void:
	var hull: HullGeometry = HullGeometry.create(0.0, 0.0, 0.0)
	gt(hull.length, 0.0, "length clamped")
	gt(hull.beam, 0.0, "beam clamped")
	gt(hull.bounding_radius(), 0.0, "still produces a usable outline")
