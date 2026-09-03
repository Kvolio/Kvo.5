extends Control

## Building a battle: who is in it, where they start, and what the weather is doing.
##
## A scenario is a file, and this screen edits one. It deliberately does not know how to
## start a battle — it emits the scenario and lets `AppRoot` do that — because the
## battle is built by `ScenarioIo.build()` and by nothing else, which is what lets a
## replay reproduce it.
##
## The weather controls are the interesting ones. Sea state, darkness and visibility are
## not flavour: they are written into the simulation's own config, so a night action is
## fought by ships whose rangefinders genuinely do not work and whose lookouts genuinely
## cannot see. Setting them here and watching the same two fleets produce a completely
## different battle is the point of the screen.

signal closed()
signal fight_requested(scenario: ScenarioDef)

const PANEL_WIDTH: float = 480.0

var _scenario: ScenarioDef = null
var _scenarios: Dictionary = {}
var _order: Array[String] = []

var _summary: Label = null
var _force_rows: VBoxContainer = null
var _fleet_ids: Array[String] = []
var _name_edit: LineEdit = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var background: ColorRect = ColorRect.new()
	background.color = ViewPalette.SEA_DEEP
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	_scenarios = ScenarioIo.load_all()
	for scenario_id: String in Serializer.sorted_keys(_scenarios):
		_order.append(scenario_id)
	_fleet_ids = _load_fleet_ids()
	if not _order.is_empty():
		_scenario = ScenarioDef.parse((_scenarios[_order[0]] as ScenarioDef).to_document())

	_build()
	_refresh()


static func _load_fleet_ids() -> Array[String]:
	var out: Array[String] = []
	for path: String in JsonLoader.list_json_files(FleetIo.FLEET_DIR):
		out.append(path.get_file().get_basename())
	out.sort()
	return out


func _build() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 16)
	add_child(margin)

	var columns: HBoxContainer = UiKit.row(16)
	margin.add_child(columns)

	# -- the action ------------------------------------------------------------
	var left: PanelContainer = UiKit.panel()
	left.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	left.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	columns.add_child(left)
	var settings: VBoxContainer = UiKit.column(6)
	left.add_child(UiKit.scroll(settings))

	settings.add_child(UiKit.heading("Scenario"))
	var names: Array[String] = []
	for scenario_id: String in _order:
		names.append((_scenarios[scenario_id] as ScenarioDef).display_name)
	UiKit.option_row(settings, "Start from", names, 0, _on_preset_chosen)

	var name_row: HBoxContainer = UiKit.row(6)
	name_row.add_child(UiKit.label("Name", 12, ViewPalette.TEXT_DIM))
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(260.0, 0.0)
	_name_edit.text_changed.connect(func(text: String) -> void:
		if _scenario != null:
			_scenario.display_name = text)
	name_row.add_child(_name_edit)
	settings.add_child(name_row)

	settings.add_child(UiKit.heading("Weather and light"))
	UiKit.slider_row(settings, "Sea state", 0.0, 8.0, 1.0, _scenario.sea_state,
		func(value: float) -> void: _set_sea_state(value))
	UiKit.slider_row(settings, "Visibility", 0.1, 1.0, 0.05, _scenario.visibility_factor,
		func(value: float) -> void: _set_visibility(value))
	UiKit.option_row(settings, "Time of day", ["Day", "Night"],
		1 if _scenario.night else 0, _on_light_chosen)

	settings.add_child(UiKit.heading("Victory"))
	UiKit.option_row(settings, "Condition",
		["Annihilation", "Survival", "Points"], int(_scenario.victory), _on_victory_chosen)
	UiKit.slider_row(settings, "Time limit", 5.0, 90.0, 5.0,
		_scenario.time_limit_s / 60.0,
		func(value: float) -> void: _scenario.time_limit_s = value * 60.0, "min")

	settings.add_child(UiKit.heading("Seed"))
	# The seed is the whole of what makes two runs of the same scenario differ. Moving
	# it by one produces a different battle from the same ships in the same places,
	# which is the cheapest way there is to find out whether an outcome was luck.
	UiKit.slider_row(settings, "Seed", 1.0, 99999.0, 1.0, float(_scenario.seed_value),
		func(value: float) -> void: _scenario.seed_value = int(value))

	# -- the forces ------------------------------------------------------------
	var right: PanelContainer = UiKit.panel()
	right.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	right.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	columns.add_child(right)
	var forces: VBoxContainer = UiKit.column(6)
	right.add_child(UiKit.scroll(forces))
	forces.add_child(UiKit.heading("Forces"))
	_force_rows = UiKit.column(10)
	forces.add_child(_force_rows)

	# -- the strip along the bottom -------------------------------------------
	var footer: PanelContainer = UiKit.panel()
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_top = -64.0
	footer.offset_left = 16.0
	footer.offset_right = -16.0
	footer.offset_bottom = -16.0
	add_child(footer)

	var actions: HBoxContainer = UiKit.row(10)
	_summary = UiKit.label("", 12, ViewPalette.TEXT_DIM)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.custom_minimum_size = Vector2(520.0, 0.0)
	actions.add_child(_summary)
	actions.add_child(UiKit.spacer())
	actions.add_child(UiKit.button("Save", _on_save, 110.0))
	actions.add_child(UiKit.button("Fight this", _on_fight, 130.0))
	actions.add_child(UiKit.button("Back", func() -> void: closed.emit(), 110.0))
	footer.add_child(actions)


# -- editing -------------------------------------------------------------------

func _on_preset_chosen(index: int) -> void:
	if index < 0 or index >= _order.size():
		return
	# Edited on a COPY. The presets in data/ are read-only as far as this screen is
	# concerned, exactly as the ship designer treats the historical roster.
	_scenario = ScenarioDef.parse((_scenarios[_order[index]] as ScenarioDef).to_document())
	_refresh()


func _set_sea_state(value: float) -> void:
	_scenario.sea_state = value
	_refresh()


func _set_visibility(value: float) -> void:
	_scenario.visibility_factor = value
	_refresh()


func _on_light_chosen(index: int) -> void:
	_scenario.night = index == 1
	_refresh()


func _on_victory_chosen(index: int) -> void:
	_scenario.victory = index as ScenarioDef.Victory
	_refresh()


func _on_save() -> void:
	if _scenario == null:
		return
	# A saved scenario gets its own id, so saving an edited Denmark Strait does not
	# overwrite the one in data/.
	if not _scenario.scenario_id.begins_with("custom_"):
		_scenario.scenario_id = "custom_%s" % _scenario.display_name.to_snake_case()
	ScenarioIo.save(_scenario)
	_refresh()


func _on_fight() -> void:
	if _scenario != null:
		fight_requested.emit(_scenario)


# -- display -------------------------------------------------------------------

func _refresh() -> void:
	if _scenario == null or _summary == null:
		return
	if _name_edit != null and _name_edit.text != _scenario.display_name:
		_name_edit.text = _scenario.display_name

	for child: Node in _force_rows.get_children():
		child.queue_free()

	var total: int = 0
	for i: int in _scenario.forces.size():
		var force: ScenarioDef.Force = _scenario.forces[i]
		var block: VBoxContainer = UiKit.column(3)
		block.add_child(UiKit.label("%s (team %d)" % [force.display_name, force.team], 13))

		if not force.fleet_id.is_empty() and not _fleet_ids.is_empty():
			var selected: int = maxi(_fleet_ids.find(force.fleet_id), 0)
			UiKit.option_row(block, "Fleet", _fleet_ids, selected,
				func(index: int) -> void: _set_fleet(i, index))
			var fleet: FleetDef = FleetIo.load_from_file(
				"res://data/fleets/%s.json" % force.fleet_id)
			if fleet != null:
				total += fleet.total_ships()
				block.add_child(UiKit.label("%d ships in %d divisions" % [
					fleet.total_ships(), fleet.divisions.size()], 11, ViewPalette.TEXT_DIM))
		else:
			var listed: int = 0
			for entry: Variant in force.ships:
				listed += 1
			total += listed
			block.add_child(UiKit.label("%d ships, placed by the file" % listed, 11,
				ViewPalette.TEXT_DIM))

		UiKit.slider_row(block, "Course", 0.0, 355.0, 5.0,
			rad_to_deg(SimUnits.normalise_angle(force.heading_rad) + TAU) if force.heading_rad < 0.0
				else rad_to_deg(force.heading_rad),
			func(value: float) -> void: _set_course(i, value), "deg")
		UiKit.slider_row(block, "Speed", 5.0, 35.0, 1.0, force.speed_knots,
			func(value: float) -> void: _scenario.forces[i].speed_knots = value, "kn")
		UiKit.slider_row(block, "Distance", 3.0, 40.0, 1.0,
			force.position.length() / 1000.0,
			func(value: float) -> void: _set_distance(i, value), "km")
		_force_rows.add_child(block)

	var separation: float = 0.0
	if _scenario.forces.size() >= 2:
		separation = _scenario.forces[0].position.distance_to(_scenario.forces[1].position)
	_summary.text = ("%s — %d ships, sea state %.0f, %s, visibility %.0f%%. " % [
		_scenario.display_name, total, _scenario.sea_state,
		"night" if _scenario.night else "day", _scenario.visibility_factor * 100.0]
		+ "They start %.0f km apart; %s." % [separation / 1000.0, _reach_note(separation)])


## What the opening separation actually means, in the terms the simulation uses. A
## scenario editor that let you set a number without saying what it does to the battle
## would be a form, not a tool.
static func _reach_note(separation_m: float) -> String:
	if separation_m > 34000.0:
		return "beyond radar, so the first job is finding each other"
	if separation_m > 20000.0:
		return "within radar but out of sight, and out of range of most guns"
	if separation_m > 12000.0:
		return "in sight and in range of the heavy guns"
	return "close enough for everything, including torpedoes"


func _set_fleet(force_index: int, fleet_index: int) -> void:
	if fleet_index >= 0 and fleet_index < _fleet_ids.size():
		_scenario.forces[force_index].fleet_id = _fleet_ids[fleet_index]
		_refresh()


func _set_course(force_index: int, degrees: float) -> void:
	_scenario.forces[force_index].heading_rad = deg_to_rad(degrees)
	_refresh()


## Move a force in or out along the bearing she already sits on, so the two sides stay
## opposed and only the range between them changes.
func _set_distance(force_index: int, kilometres: float) -> void:
	var force: ScenarioDef.Force = _scenario.forces[force_index]
	var bearing: float = force.position.angle() if force.position.length_squared() > 1.0 \
		else force.heading_rad + PI
	force.position = Vector2(cos(bearing), sin(bearing)) * kilometres * 1000.0
	_refresh()
