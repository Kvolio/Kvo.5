extends Node

## What the game boots into, and the only place that knows which screen is up.
##
## Screens are plain scripts instantiated in code, the same way the HUD and the
## renderers are, so adding one is adding a file rather than editing a scene. Stage 8's
## scenario editor joins here.
##
## Each screen is created fresh when entered and freed when left. A battle carries a
## whole simulation with it and there is no reason to keep one alive underneath the
## designer — and the designer's whole job is to change ships out from under anything
## holding a reference to one.

const MENU: String = "res://src/ui/main_menu.gd"
const BATTLE: String = "res://src/view/battle_view.gd"
const DESIGNER: String = "res://src/ui/ship_designer/ship_designer.gd"
const CAPTURE: String = "res://src/view/screenshot_capture.gd"

## Which screen to open on. `--screen=designer` boots straight into the designer, which
## is how it gets screenshotted without anyone clicking through a menu.
const ARG_SCREEN: String = "--screen="

var _screen: Node = null
## A design sent straight from the designer into a battle, so "put her in a battle"
## does not depend on having saved her first.
var _pending_design: ShipSpec = null


func _ready() -> void:
	# Inert unless --screenshot is on the command line, and free to leave in. It lives
	# here rather than inside the battle so that any screen can be captured.
	var capture_script: Script = load(CAPTURE) as Script
	if capture_script != null:
		add_child(capture_script.new() as Node)

	match _requested_screen():
		"battle":
			show_battle()
		"designer":
			show_designer()
		_:
			show_menu()


## The screen named on the command line. A screenshot with no screen named wants the
## battle, because that is what every existing invocation of tools/screenshot.sh meant
## before there was a menu to land on.
func _requested_screen() -> String:
	var named: String = ""
	var screenshotting: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(ARG_SCREEN):
			named = arg.trim_prefix(ARG_SCREEN)
		elif arg.begins_with("--screenshot="):
			screenshotting = true
	if not named.is_empty():
		return named
	return "battle" if screenshotting else "menu"


func show_menu() -> void:
	var menu: Node = _swap_to(MENU)
	if menu == null:
		return
	menu.connect("battle_requested", show_battle)
	menu.connect("designer_requested", show_designer)


func show_battle() -> void:
	var battle: Node = _swap_to(BATTLE)
	if battle == null:
		return
	if _pending_design != null and battle.has_method("set_player_design"):
		battle.call("set_player_design", _pending_design)
		_pending_design = null
	# Escape returns to the menu; the battle emits it rather than reaching up here.
	if battle.has_signal("exit_requested"):
		battle.connect("exit_requested", show_menu)


func show_designer() -> void:
	var designer: Node = _swap_to(DESIGNER)
	if designer == null:
		return
	designer.connect("closed", show_menu)
	designer.connect("battle_requested", func(spec: ShipSpec) -> void:
		_pending_design = spec
		show_battle())


func _swap_to(path: String) -> Node:
	if _screen != null:
		remove_child(_screen)
		_screen.queue_free()
		_screen = null

	var script: Script = load(path) as Script
	if script == null:
		push_error("AppRoot: could not load screen %s" % path)
		return null
	_screen = script.new() as Node
	if _screen == null:
		push_error("AppRoot: %s is not a Node" % path)
		return null
	add_child(_screen)
	return _screen
