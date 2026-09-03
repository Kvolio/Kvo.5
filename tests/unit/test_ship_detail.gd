extends SimTest

## The plan-view detail drawn at high zoom.
##
## Rendering cannot be judged by assertions — that is what `tools/screenshot.sh` is for
## — but the geometry underneath it can, and the failures that actually happened here
## were geometric rather than aesthetic: polygons that would not triangulate, and
## detail that came from somewhere other than the ship's own structure.
##
## The property worth protecting is that last one. The detail is a projection of the
## template the trajectory tracer intersects, so a design nobody has seen renders
## correctly for the same reason a shell hits it correctly.

var _config: Dictionary = {}
var _structure_config: Dictionary = {}


func suite_name() -> String:
	return "Ship detail"


func before_each() -> void:
	if _config.is_empty():
		_config = JsonLoader.load_dict("res://data/config/view.json")
		_structure_config = JsonLoader.load_dict("res://data/config/structure.json")


func _detail(spec_id: String) -> ShipDetail:
	var spec: ShipSpec = TestShips.load_ship(spec_id)
	return ShipDetail.for_ship(spec, TestShips.structure(spec_id), _config)


# ------------------------------------------------------------ gunhouse shape --

func test_every_turret_plan_is_a_polygon_that_can_actually_be_drawn() -> void:
	# The bug this exists for: a polygon Godot cannot triangulate draws nothing at all
	# and reports one error per frame per turret. Silent on screen, deafening in a log.
	var plans: Dictionary = (_config.get("turret", {}) as Dictionary).get("plans", {}) as Dictionary
	gt(float(plans.size()), 0.0, "there are turret plans configured")
	for name: String in plans.keys():
		var polygon: PackedVector2Array = ShipDetail.gunhouse_plan(
			plans[name] as Dictionary, 12.8, 11.2)
		ge(float(polygon.size()), 3.0, "%s has enough points to be a polygon" % name)
		ok(not Geometry2D.triangulate_polygon(polygon).is_empty(),
			"%s triangulates, so it will be drawn" % name)


func test_a_gunhouse_is_narrower_at_the_face_than_at_the_body() -> void:
	# The whole claim about turret shape. A gunhouse whose face is as wide as its body
	# is a rectangle, and a rectangle with sticks does not read as a turret.
	var plans: Dictionary = (_config.get("turret", {}) as Dictionary).get("plans", {}) as Dictionary
	for name: String in plans.keys():
		var polygon: PackedVector2Array = ShipDetail.gunhouse_plan(
			plans[name] as Dictionary, 12.8, 11.2)
		var forward_most: float = -1.0e9
		for point: Vector2 in polygon:
			forward_most = maxf(forward_most, point.x)

		var face_half: float = 0.0
		var widest: float = 0.0
		for point: Vector2 in polygon:
			widest = maxf(widest, absf(point.y))
			if is_equal_approx(point.x, forward_most):
				face_half = maxf(face_half, absf(point.y))
		gt(face_half, 0.0, "%s has a face plate of some width" % name)
		lt(face_half, widest, "%s is narrower across the face than across the body" % name)


func test_a_gunhouse_scales_with_the_size_it_is_given() -> void:
	var plan: Dictionary = ShipDetail.plan_for(_config, "USA")
	var small: PackedVector2Array = ShipDetail.gunhouse_plan(plan, 4.0, 3.5)
	var large: PackedVector2Array = ShipDetail.gunhouse_plan(plan, 12.8, 11.2)
	var small_span: float = 0.0
	var large_span: float = 0.0
	for i: int in small.size():
		small_span = maxf(small_span, absf(small[i].y))
		large_span = maxf(large_span, absf(large[i].y))
	gt(large_span, small_span * 2.0, "a 16-inch turret dwarfs a 5-inch mount")


func test_an_unknown_nation_still_gets_a_usable_plan() -> void:
	var plan: Dictionary = ShipDetail.plan_for(_config, "Ruritania")
	var polygon: PackedVector2Array = ShipDetail.gunhouse_plan(plan, 12.8, 11.2)
	ok(not Geometry2D.triangulate_polygon(polygon).is_empty(),
		"a design from nowhere in particular is still drawn")


# ------------------------------------------------- detail comes from the ship --

func test_detail_blocks_are_the_ships_own_structure_above_her_main_deck() -> void:
	# Not a list of names: anything standing above the main deck is drawn, which is what
	# makes a custom design render its own upperworks without being told about them.
	var template: ShipStructureTemplate = TestShips.structure("uss_iowa")
	var detail: ShipDetail = _detail("uss_iowa")
	gt(float(detail.blocks.size()), 3.0, "Iowa has a deckhouse, towers and funnels")

	for block: ShipDetail.Block in detail.blocks:
		ge(block.height_z, template.main_deck_z - 0.01,
			"nothing below the main deck is drawn from above")
		ge(float(block.polygon.size()), 3.0, "every block is a polygon")
		ok(not Geometry2D.triangulate_polygon(block.polygon).is_empty(),
			"and one that can be drawn")


func test_blocks_are_ordered_so_the_bridge_draws_over_its_deckhouse() -> void:
	var previous: float = -1.0e9
	for block: ShipDetail.Block in _detail("uss_iowa").blocks:
		ge(block.height_z, previous, "blocks come back lowest first")
		previous = block.height_z


## Total plan area of everything drawn above the main deck.
func _topside_area(spec_id: String) -> float:
	var total: float = 0.0
	for block: ShipDetail.Block in _detail(spec_id).blocks:
		var twice: float = 0.0
		for i: int in block.polygon.size():
			var a: Vector2 = block.polygon[i]
			var b: Vector2 = block.polygon[(i + 1) % block.polygon.size()]
			twice += a.x * b.y - b.x * a.y
		total += absf(twice) * 0.5
	return total


func test_a_destroyer_has_far_less_to_show_than_a_battleship() -> void:
	# Every ship gets the same ARRANGEMENT — a deckhouse, a bridge, funnels, an after
	# control position — because every ship had one. What differs is how much of her
	# there is, and that falls out of her dimensions rather than from a rule about
	# classes.
	gt(_topside_area("uss_iowa"), _topside_area("uss_fletcher") * 5.0,
		"an Iowa's upperworks dwarf a Fletcher's")
	gt(_topside_area("uss_fletcher"), 0.0, "but a destroyer has some")


func test_deck_seams_span_the_hull_at_every_station() -> void:
	var spec: ShipSpec = TestShips.load_ship("uss_iowa")
	for line: PackedVector2Array in _detail("uss_iowa").deck_lines:
		eq(line.size(), 2, "a seam is a single line")
		almost(line[0].y, -line[1].y, 0.001, "and it is symmetric about the centreline")
		lt(absf(line[0].x), spec.length_m * 0.5 + 0.1, "drawn within her length")


func test_the_projection_is_cached_per_design() -> void:
	# Templates are immutable, so the projection is too. Rebuilding it every frame for
	# every ship would be the most expensive thing the renderer did.
	ok(_detail("uss_iowa") == _detail("uss_iowa"), "the same design gives the same object")
	ok(_detail("uss_iowa") != _detail("uss_fletcher"), "different designs do not share one")
