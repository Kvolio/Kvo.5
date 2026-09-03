extends SimTest

## Every screen builds without falling over.
##
## The interface is built in code, so a screen that parses can still fail the moment it
## is asked to construct itself — a missing autoload, a signal connected to a method
## that has been renamed, a control that needs a size before it has one. None of that
## shows up in a parse check, and all of it shows up here.
##
## This does not test that a screen is USABLE. Nothing headless can. That is what
## `tools/screenshot.sh --screen=designer` is for, and there is no substitute for
## opening the picture.

const SCREENS: Array[String] = [
	"res://src/ui/main_menu.gd",
	"res://src/ui/ship_designer/ship_designer.gd",
	"res://src/ui/app_root.gd",
]


func suite_name() -> String:
	return "Screens"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## Build a screen and make it ready, by hand.
##
## The headless runner does its work inside `SceneTree._initialize()`, and at that point
## the root window is not yet inside the tree — so adding a child does not trigger
## `_enter_tree` or `_ready`, and a screen added to it just sits there having built
## nothing. Measured rather than assumed: `root.is_inside_tree()` is false.
##
## So readiness is driven explicitly, and recursively: a screen builds its children
## during its own `_ready`, and those children have scripts of their own that have not
## run yet. Recursing after the fact reaches them, and cannot run anything twice,
## because nothing that existed beforehand is visited again.
##
## It has to be a direct call. `propagate_notification(NOTIFICATION_READY)` was the
## obvious way and does nothing at all here — measured, not assumed: the notification
## is a no-op for a node whose tree has not started, and the screen came back with no
## children and `is_node_ready()` still false.
func _build(path: String) -> Node:
	var script: Script = load(path) as Script
	if script == null:
		return null
	var node: Node = script.new() as Node
	if node == null:
		return null
	_tree().root.add_child(node)
	_make_ready(node)
	return node


func _make_ready(node: Node) -> void:
	if node.has_method("_ready"):
		node.call("_ready")
	for child: Node in node.get_children():
		_make_ready(child)


func _tear_down(node: Node) -> void:
	if node == null:
		return
	_tree().root.remove_child(node)
	node.free()


func test_every_screen_constructs_and_tears_down() -> void:
	for path: String in SCREENS:
		var screen: Node = _build(path)
		ok(screen != null, "%s builds" % path.get_file())
		if screen == null:
			continue
		gt(float(screen.get_child_count()), 0.0,
			"%s put something on the screen" % path.get_file())
		_tear_down(screen)


func test_the_designer_starts_on_a_design_it_did_not_take_from_the_roster() -> void:
	# A design opens as a COPY with a new identity, so that saving it can never
	# overwrite the preset it was based on.
	var designer: Node = _build("res://src/ui/ship_designer/ship_designer.gd")
	ok(designer != null, "the designer builds")
	if designer == null:
		return
	var spec: ShipSpec = designer.get("_spec") as ShipSpec
	ok(spec != null, "with a design loaded")
	if spec != null:
		ok(spec.is_custom, "marked as the player's")
		ok(not ShipDatabase.has_spec(spec.spec_id),
			"under an id no preset is using: %s" % spec.spec_id)
	_tear_down(designer)


func test_the_designer_weighs_the_design_it_is_showing() -> void:
	var designer: Node = _build("res://src/ui/ship_designer/ship_designer.gd")
	if designer == null:
		return
	var analysis: DesignAnalysis = designer.get("_analysis") as DesignAnalysis
	ok(analysis != null, "an analysis exists before anything is touched")
	if analysis != null:
		gt(analysis.full_displacement_t, 0.0, "she weighs something")
		gt(analysis.estimated_speed_kn, 0.0, "and has a speed")
		gt(float(analysis.groups.size()), 3.0, "and a weight statement")
	_tear_down(designer)


func test_editing_armour_through_the_designer_makes_her_heavier_and_slower() -> void:
	# The designer's whole claim, exercised through the screen rather than the model:
	# change a number here and the ship that comes back is a different ship.
	var designer: Node = _build("res://src/ui/ship_designer/ship_designer.gd")
	if designer == null:
		return
	var before: DesignAnalysis = designer.get("_analysis") as DesignAnalysis
	var light_speed: float = before.estimated_speed_kn
	var light_armour: float = before.group_tonnes("Armour")

	var spec: ShipSpec = designer.get("_spec") as ShipSpec
	spec.armour.plate("belt").thickness_mm *= 2.0
	spec.armour.plate("belt").lower_edge_thickness_mm *= 2.0
	designer.call("_rebuild")

	var after: DesignAnalysis = designer.get("_analysis") as DesignAnalysis
	gt(after.group_tonnes("Armour"), light_armour, "twice the belt is more armour")
	lt(after.estimated_speed_kn, light_speed, "and the ship carrying it is slower")
	_tear_down(designer)


# ------------------------------------------------------------- the §44 loop --

func test_a_design_can_be_taken_from_the_designer_into_a_battle() -> void:
	# Build a ship, take her out, watch her get shot at. The point of the whole thing,
	# and the one path that crosses every layer: designer to spec to battle to renderer.
	var root: Node = _build("res://src/ui/app_root.gd")
	ok(root != null, "the application root builds")
	if root == null:
		return

	root.call("show_designer")
	var designer: Node = root.get("_screen") as Node
	ok(designer != null and designer.has_method("_rebuild"), "the designer is up")
	if designer == null:
		_tear_down(root)
		return
	_make_ready(designer)

	var design: ShipSpec = designer.get("_spec") as ShipSpec
	ok(design != null, "with a design on it")
	if design == null:
		_tear_down(root)
		return
	design.display_name = "Test Flagship"
	designer.emit_signal("battle_requested", design)

	var battle: Node = root.get("_screen") as Node
	ok(battle != null and battle != designer, "which swapped the screen for a battle")
	if battle != null:
		_make_ready(battle)
		var world: SimWorld = battle.get("world") as SimWorld
		ok(world != null, "and the battle has a simulation")
		if world != null:
			var found: bool = false
			for ship: ShipEntity in world.ships:
				if ship.display_name.contains("Test Flagship"):
					found = true
			ok(found, "with the player's own design in the line")
	_tear_down(root)
