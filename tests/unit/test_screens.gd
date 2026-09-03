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
	"res://src/ui/scenario_editor/scenario_editor.gd",
	"res://src/ui/app_root.gd",
]

## The inspection surfaces. Built without a world so that "shows nothing gracefully" is
## checked too — a panel that only works once a battle is running is a panel that
## crashes the first time somebody opens it on the menu.
const PANELS: Array[String] = [
	"res://src/ui/combat_log.gd",
	"res://src/ui/ship_inspector.gd",
	"res://src/ui/debug_overlay.gd",
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


func test_every_inspection_panel_constructs_with_no_battle_to_show() -> void:
	for path: String in PANELS:
		var panel: Node = _build(path)
		ok(panel != null, "%s should construct" % path)
		if panel == null:
			continue
		gt(float(panel.get_child_count()), 0.0, "%s should build a layout" % path)
		# Refreshing with no world at all must be safe: these are opened from a
		# keystroke and there is no guarantee a battle is running.
		if panel.has_method("refresh"):
			panel.call("refresh")
		_tear_down(panel)


func test_the_inspection_surfaces_describe_a_real_battle() -> void:
	# Built without a scene tree, so what is checked is the FORMATTING — the part that
	# reads the causal chain and turns it into sentences. That is the part that breaks
	# when a field is renamed, and it breaks silently, because a panel that shows
	# nothing looks much like a panel with nothing to show.
	var world: SimWorld = TestShips.armed_world(31)
	var a: ShipEntity = world.add_ship(TestShips.iowa(), Vector2.ZERO, 0.0, 0)
	var b: ShipEntity = world.add_ship(TestShips.iowa(), Vector2(0.0, 15000.0), PI, 1)
	a.target_id = b.id
	b.target_id = a.id
	MovementSystem.set_steady_speed(a, SimUnits.knots_to_ms(20.0))
	MovementSystem.set_steady_speed(b, SimUnits.knots_to_ms(20.0))
	for _i: int in 60 * 240:
		world.step()
		if not world.recent_hits.is_empty():
			break
	gt(float(world.recent_hits.size()), 0.0, "the duel should produce a hit to describe")

	# The combat log turns events into sentences.
	var described: int = 0
	for event: SimEvent in world.events.history():
		var line: String = CombatLogText.describe(world, event)
		if line.is_empty():
			continue
		described += 1
		not_ok(line.begins_with("salvo_fired"),
			"an event the log has no sentence for should be obvious, not silent")
	gt(float(described), 5.0, "most of what happened should have a line")

	# The debug overlay renders the whole causal chain of the last hit.
	var report: HitReport = world.recent_hits[world.recent_hits.size() - 1]
	var chain: Array[String] = DebugOverlayText.describe(report)
	gt(float(chain.size()), 6.0, "the chain should have several lines")
	var joined: String = "\n".join(chain)
	ok(joined.contains("Terminated:"), "and say how the shell finished")
	ok(joined.contains("m/s"), "with the velocities it actually had")
	gt(float(report.interactions.size()), 0.0,
		"which is the tracer's own record, not a reconstruction of it")


func test_the_scenario_editor_edits_a_copy_and_not_the_file() -> void:
	var editor: Node = _build("res://src/ui/scenario_editor/scenario_editor.gd")
	ok(editor != null, "the scenario editor should construct")
	if editor == null:
		return
	var edited: ScenarioDef = editor.get("_scenario") as ScenarioDef
	ok(edited != null, "and start on a scenario")

	var original: ScenarioDef = ScenarioIo.load_from_file(
		"res://data/scenarios/%s.json" % edited.scenario_id)
	ok(original != null, "which came from a file")
	edited.sea_state = 7.0
	edited.night = true
	var reloaded: ScenarioDef = ScenarioIo.load_from_file(
		"res://data/scenarios/%s.json" % original.scenario_id)
	almost(reloaded.sea_state, original.sea_state, 0.001,
		"editing the scenario must not touch the preset it was started from")
	not_ok(reloaded.night, "in any respect")
	_tear_down(editor)


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
