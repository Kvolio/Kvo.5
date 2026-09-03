extends Control

## Tactical HUD: simulation controls and the selected ship's state.
##
## Built in code rather than as a .tscn so the layout lives next to the logic that
## fills it in, and so a panel gains a row when the simulation gains a system rather
## than needing a scene edit as well.
##
## Reads the simulation; never writes to it. Orders go through SimWorld's command
## queue, which is what keeps a battle reproducible from its command log.

signal time_scale_requested(scale: float)
signal pause_toggled()

const TIME_SCALES: Array[float] = [0.25, 0.5, 1.0, 2.0, 5.0, 10.0]
const PANEL_WIDTH: float = 300.0

var world: SimWorld = null
var selected_id: int = 0

var _status_label: Label = null
var _ship_panel: PanelContainer = null
var _ship_labels: Dictionary = {}
var _scale_buttons: Array[Button] = []
var _pause_button: Button = null
var _help_label: Label = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_top_bar()
	_build_ship_panel()
	_build_help()


func _build_top_bar() -> void:
	var bar: PanelContainer = _panel()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = 44.0
	add_child(bar)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bar.add_child(row)

	_pause_button = Button.new()
	_pause_button.custom_minimum_size = Vector2(84.0, 0.0)
	_pause_button.pressed.connect(func() -> void: pause_toggled.emit())
	row.add_child(_pause_button)

	for scale: float in TIME_SCALES:
		var button: Button = Button.new()
		button.text = ("%.2fx" % scale) if scale < 1.0 else ("%dx" % int(scale))
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(52.0, 0.0)
		button.pressed.connect(func() -> void: time_scale_requested.emit(scale))
		row.add_child(button)
		_scale_buttons.append(button)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", ViewPalette.TEXT_DIM)
	row.add_child(_status_label)


func _build_ship_panel() -> void:
	_ship_panel = _panel()
	_ship_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_ship_panel.offset_left = -PANEL_WIDTH - 12.0
	_ship_panel.offset_right = -12.0
	_ship_panel.offset_top = 56.0
	_ship_panel.offset_bottom = 300.0
	_ship_panel.visible = false
	add_child(_ship_panel)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	_ship_panel.add_child(column)

	var title: Label = Label.new()
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", ViewPalette.TEXT_PRIMARY)
	column.add_child(title)
	_ship_labels["title"] = title

	# Stages 2-5 add turret, flooding, fire and compartment rows to this list; the
	# panel grows without needing a scene edit.
	for field: String in ["class", "status", "speed", "heading", "rudder", "propulsion", "position"]:
		var row: HBoxContainer = HBoxContainer.new()
		column.add_child(row)

		var name_label: Label = Label.new()
		name_label.text = field.capitalize()
		name_label.custom_minimum_size = Vector2(96.0, 0.0)
		name_label.add_theme_color_override("font_color", ViewPalette.TEXT_DIM)
		name_label.add_theme_font_size_override("font_size", 12)
		row.add_child(name_label)

		var value_label: Label = Label.new()
		value_label.add_theme_color_override("font_color", ViewPalette.TEXT_PRIMARY)
		value_label.add_theme_font_size_override("font_size", 12)
		row.add_child(value_label)
		_ship_labels[field] = value_label


func _build_help() -> void:
	var panel: PanelContainer = _panel()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = 12.0
	panel.offset_top = -100.0
	panel.offset_right = 460.0
	panel.offset_bottom = -12.0
	add_child(panel)

	_help_label = Label.new()
	_help_label.add_theme_color_override("font_color", ViewPalette.TEXT_DIM)
	_help_label.add_theme_font_size_override("font_size", 11)
	_help_label.text = """Left click  select ship      Right drag  pan      Wheel  zoom
Space  pause        1-6  time scale        F  frame all ships
W / S  speed        A / D  rudder          X  rudder amidships
L  combat log       I  ship inspector      G  why the last shell did that
F5 / F9  save and reload the battle        Esc  back to the menu"""
	panel.add_child(_help_label)


## Shared with the ship designer, so the two screens look like one application.
static func _panel() -> PanelContainer:
	return UiKit.panel()


func refresh() -> void:
	if world == null:
		return
	_refresh_top_bar()
	_refresh_ship_panel()


func _refresh_top_bar() -> void:
	var paused: bool = world.clock.is_paused()
	_pause_button.text = "Resume" if paused else "Pause"
	for i: int in _scale_buttons.size():
		_scale_buttons[i].button_pressed = not paused and is_equal_approx(world.clock.time_scale, TIME_SCALES[i])

	var seconds: float = world.clock.elapsed()
	_status_label.text = "T+%02d:%02d   tick %d   %d ships" % [
		int(seconds) / 60, int(seconds) % 60, world.clock.tick, world.ships.size(),
	]


func _refresh_ship_panel() -> void:
	var ship: ShipEntity = world.get_ship(selected_id) if selected_id != 0 else null
	_ship_panel.visible = ship != null
	if ship == null:
		return

	(_ship_labels["title"] as Label).text = ship.display_name
	_set_field("class", "%s  %s  %d" % [ship.spec.ship_class, ship.spec.nation, ship.spec.year])
	_set_field("status", _status_text(ship))
	_set_field("speed", "%.1f kn  (max %.1f)" % [
		ship.speed_knots(), SimUnits.ms_to_knots(ship.effective_max_speed())])
	_set_field("heading", "%03.0f deg" % ship.compass_bearing())
	_set_field("rudder", _rudder_text(ship))
	_set_field("propulsion", "%d%%%s" % [
		int(round(ship.propulsion_fraction * 100.0)),
		"  asymmetric" if absf(ship.shaft_asymmetry) > 0.01 else "",
	])
	_set_field("position", "%.1f, %.1f km" % [ship.position.x / 1000.0, ship.position.y / 1000.0])


static func _status_text(ship: ShipEntity) -> String:
	match ship.status:
		ShipEntity.Status.DESTROYED:
			return "SUNK"
		ShipEntity.Status.MISSION_KILL:
			return "OUT OF ACTION"
		_:
			return "Operational"


static func _rudder_text(ship: ShipEntity) -> String:
	var degrees: float = rad_to_deg(ship.rudder_angle)
	var side: String = "amidships"
	if degrees > 0.5:
		side = "starboard"
	elif degrees < -0.5:
		side = "port"
	var text: String = "%.0f deg %s" % [absf(degrees), side]
	if ship.rudder_jammed:
		text += "  JAMMED"
	elif ship.rudder_effectiveness < 0.99:
		text += "  (%d%% authority)" % int(round(ship.rudder_effectiveness * 100.0))
	return text


func _set_field(field: String, text: String) -> void:
	var label: Label = _ship_labels.get(field) as Label
	if label != null:
		label.text = text
