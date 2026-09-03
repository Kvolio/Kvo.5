extends Control

## The ship designer.
##
## Every control here edits a `ShipSpec`, and after every edit the design is weighed
## again from scratch: `NavalArchitect.analyse()` rebuilds her structure, sums the plate
## that is actually on her, and works out what she displaces, how stable she is and how
## fast she will go. Nothing in this screen knows that armour costs speed. It knows how
## to change a number and how to ask what the ship became.
##
## That is the whole design of it. A designer that applied a penalty for armour would be
## a designer whose numbers could be argued with; one that weighs the plate can only be
## argued with about the plate.
##
## The validator warns and never fixes. A player may build something absurd — the
## simulation then shows them what happens — so findings are reasons, not refusals.

signal closed()
signal battle_requested(spec: ShipSpec)

const PANEL_WIDTH: float = 470.0
const SHIP_TYPES: Array[String] = ["battleship", "carrier", "cruiser", "destroyer"]

var _spec: ShipSpec = null
var _analysis: DesignAnalysis = null
var _findings: Array[DesignValidator.Finding] = []

var _armory: Armory = null
var _materials: ArmourMaterials = null
var _arch_config: Dictionary = {}
var _structure_config: Dictionary = {}

var _preview: Node2D = null
var _preview_frame: Control = null
var _tabs: TabContainer = null
var _readouts: Dictionary = {}
var _findings_column: VBoxContainer = null
var _weights_column: VBoxContainer = null
var _name_edit: LineEdit = null
var _status: Label = null
var _rebuild_queued: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_arch_config = GameConfig.get_dict("naval_architecture")
	_structure_config = GameConfig.get_dict("structure")
	_materials = ArmourMaterials.load_from("res://data/materials/armor.json")
	_armory = Armory.load_from("res://data/guns", "res://data/ammo",
		GameConfig.get_dict("ballistics"))

	_spec = ShipDatabase.get_spec_for_editing("uss_iowa")
	if _spec == null:
		var ids: Array[String] = ShipDatabase.spec_ids()
		if not ids.is_empty():
			_spec = ShipDatabase.get_spec_for_editing(ids[0])
	_begin_new_design()

	_build_layout()
	_rebuild()


## A design starts as a copy of something, with a new identity, so that saving it never
## overwrites the preset it was based on.
func _begin_new_design() -> void:
	if _spec == null:
		return
	_spec.spec_id = "custom_%s" % _spec.spec_id
	_spec.display_name = "New %s" % _spec.display_name
	_spec.is_custom = true


# ------------------------------------------------------------------- layout --

func _build_layout() -> void:
	var background: ColorRect = ColorRect.new()
	background.color = ViewPalette.SEA_DEEP
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var split: HBoxContainer = UiKit.row(0)
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	_preview_frame = Control.new()
	_preview_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_frame.clip_contents = true
	split.add_child(_preview_frame)
	_preview_frame.resized.connect(_frame_preview)

	_preview = (load("res://src/ui/ship_designer/design_preview.gd") as Script).new() as Node2D
	_preview_frame.add_child(_preview)

	var side: PanelContainer = UiKit.panel()
	side.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	split.add_child(side)

	var column: VBoxContainer = UiKit.column(6)
	side.add_child(column)
	_build_identity(column)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_tabs)
	_build_hull_tab()
	_build_propulsion_tab()
	_build_armour_tab()
	_build_weapons_tab()
	_build_layout_tab()

	# The analysis does NOT live in a tab. It is the point of the screen: every slider
	# on every tab exists to move these numbers, and a consequence you have to go and
	# look for is a consequence the designer failed to show you.
	_build_analysis(column)
	_build_footer(column)


func _build_identity(column: VBoxContainer) -> void:
	var line: HBoxContainer = UiKit.row()
	column.add_child(line)
	line.add_child(UiKit.label("Name", 12, ViewPalette.TEXT_DIM))

	_name_edit = LineEdit.new()
	_name_edit.text = _spec.display_name
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(func(text: String) -> void:
		_spec.display_name = text
		# The id follows the name so two designs cannot silently overwrite each other,
		# but it stays a filename: lower case, no spaces.
		_spec.spec_id = "custom_%s" % text.to_lower().replace(" ", "_")
	)
	line.add_child(_name_edit)

	UiKit.option_row(column, "Type", SHIP_TYPES, SHIP_TYPES.find(_spec.ship_type),
		func(index: int) -> void:
			_spec.ship_type = SHIP_TYPES[index]
			_queue_rebuild())

	var presets: Array[String] = ShipDatabase.spec_ids()
	var names: Array[String] = ["Start from an existing design..."]
	for spec_id: String in presets:
		var preset: ShipSpec = ShipDatabase.get_spec(spec_id)
		names.append(preset.display_name if preset != null else spec_id)
	UiKit.option_row(column, "Based on", names, 0,
		func(index: int) -> void:
			if index <= 0:
				return   # the placeholder
			_spec = ShipDatabase.get_spec_for_editing(presets[index - 1])
			_begin_new_design()
			_name_edit.text = _spec.display_name
			_rebuild_editors()
			_queue_rebuild())


func _build_footer(column: VBoxContainer) -> void:
	_status = UiKit.label("", 11, ViewPalette.TEXT_DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)

	var line: HBoxContainer = UiKit.row()
	column.add_child(line)
	line.add_child(UiKit.button("Save design", _save))
	line.add_child(UiKit.button("Put her in a battle",
		func() -> void: battle_requested.emit(_spec)))
	line.add_child(UiKit.spacer())
	line.add_child(UiKit.button("Back", func() -> void: closed.emit()))


# --------------------------------------------------------------------- tabs --

func _tab(title: String) -> VBoxContainer:
	var column: VBoxContainer = UiKit.column(4)
	var page: ScrollContainer = UiKit.scroll(column)
	page.name = title
	_tabs.add_child(page)
	return column


func _build_hull_tab() -> void:
	var column: VBoxContainer = _tab("Hull")
	column.add_child(UiKit.label(
		"Dimensions decide almost everything else: displacement, stability, how much "
		+ "plate a given belt costs, and how much power she needs for a given speed.",
		11, ViewPalette.TEXT_DIM))
	(column.get_child(0) as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	UiKit.slider_row(column, "Length", 60.0, 300.0, 1.0, _spec.length_m,
		func(v: float) -> void:
			_spec.length_m = v
			_invalidate_hull(), "m")
	UiKit.slider_row(column, "Beam", 8.0, 42.0, 0.1, _spec.beam_m,
		func(v: float) -> void:
			_spec.beam_m = v
			_invalidate_hull(), "m")
	UiKit.slider_row(column, "Draft", 2.0, 14.0, 0.1, _spec.draft_m,
		func(v: float) -> void:
			_spec.draft_m = v
			_invalidate_hull(), "m")
	UiKit.slider_row(column, "Full displacement", 1000.0, 80000.0, 100.0,
		_spec.displacement_t,
		func(v: float) -> void:
			_spec.displacement_t = v
			_invalidate_hull(), "t")
	UiKit.slider_row(column, "Standard displacement", 0.0, 70000.0, 100.0,
		_spec.standard_displacement_t,
		func(v: float) -> void:
			_spec.standard_displacement_t = v
			_queue_rebuild(), "t")
	UiKit.slider_row(column, "Crew", 50.0, 3500.0, 10.0, float(_spec.crew),
		func(v: float) -> void:
			_spec.crew = int(v)
			_queue_rebuild(), "")


func _build_propulsion_tab() -> void:
	var column: VBoxContainer = _tab("Engines")
	UiKit.slider_row(column, "Shaft power", 5000.0, 250000.0, 1000.0,
		_spec.propulsion_power_w / SimUnits.SHP_TO_W,
		func(v: float) -> void:
			_spec.propulsion_power_w = v * SimUnits.SHP_TO_W
			_queue_rebuild(), "shp")
	UiKit.slider_row(column, "Design speed", 15.0, 40.0, 0.1,
		SimUnits.ms_to_knots(_spec.max_speed_ms),
		func(v: float) -> void:
			_spec.max_speed_ms = SimUnits.knots_to_ms(v)
			_queue_rebuild(), "kn")
	UiKit.slider_row(column, "Shafts", 1.0, 4.0, 1.0, float(_spec.shafts),
		func(v: float) -> void:
			_spec.shafts = int(v)
			_queue_rebuild(), "")
	UiKit.slider_row(column, "Boilers", 0.0, 16.0, 1.0, float(_spec.boilers),
		func(v: float) -> void:
			_spec.boilers = int(v)
			_queue_rebuild(), "")
	UiKit.slider_row(column, "Funnels", 1.0, 3.0, 1.0, float(maxi(_spec.funnels, 1)),
		func(v: float) -> void:
			_spec.funnels = int(v)
			_queue_rebuild(), "")

	var machinery: Array[String] = ["steam_turbine", "diesel", "gas_turbine", "nuclear"]
	UiKit.option_row(column, "Machinery", machinery,
		maxi(machinery.find(_spec.machinery_type), 0),
		func(index: int) -> void:
			_spec.machinery_type = machinery[index]
			_queue_rebuild())
	column.add_child(UiKit.label(
		"Speed goes as the cube root of power, so the last few knots cost enormously "
		+ "more than the first. Machinery weight scales with ship size as well as power.",
		11, ViewPalette.TEXT_DIM))
	(column.get_child(column.get_child_count() - 1) as Label).autowrap_mode = \
		TextServer.AUTOWRAP_WORD_SMART


func _build_armour_tab() -> void:
	var column: VBoxContainer = _tab("Armour")
	column.add_child(UiKit.label(
		"Every millimetre here is weighed from the plate it puts on the ship. Thicken "
		+ "the belt and she gets heavier, sits deeper and goes slower — nothing applies "
		+ "a penalty, the arithmetic simply follows.", 11, ViewPalette.TEXT_DIM))
	(column.get_child(0) as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	for zone: String in ArmourSchemeDef.ZONES:
		var plate: ArmourSchemeDef.Plate = _spec.armour.plate(zone)
		_spec.armour.plates[zone] = plate   # materialise absent zones so they can be edited
		UiKit.slider_row(column, _zone_name(zone), 0.0, 700.0, 1.0, plate.thickness_mm,
			func(v: float) -> void:
				var edited: ArmourSchemeDef.Plate = _spec.armour.plate(zone)
				# A taper is a fraction of the plate, so it follows the plate rather
				# than being left behind at its old absolute value.
				var taper: float = 1.0
				if edited.thickness_mm > 0.0:
					taper = edited.lower_edge_thickness_mm / edited.thickness_mm
				edited.thickness_mm = v
				edited.lower_edge_thickness_mm = v * clampf(taper, 0.0, 1.0)
				_invalidate_hull(), "mm")

	UiKit.slider_row(column, "Torpedo defence depth", 0.0, 8.0, 0.1,
		_spec.armour.torpedo_defence_depth_m,
		func(v: float) -> void:
			_spec.armour.torpedo_defence_depth_m = v
			_invalidate_hull(), "m")


static func _zone_name(zone: String) -> String:
	# "deckMain" reads as "Deck main"; the panel wants "Main deck".
	match zone:
		"deckWeather": return "Weather deck"
		"deckMain": return "Armour deck"
		"deckSplinter": return "Splinter deck"
		"bulkheadFore": return "Fore bulkhead"
		"bulkheadAft": return "Aft bulkhead"
		"torpedoBulkhead": return "Torpedo bulkhead"
		"upperBelt": return "Upper belt"
		"turretFace": return "Turret face"
		"turretSide": return "Turret side"
		"turretRoof": return "Turret roof"
		"conningTower": return "Conning tower"
		_: return zone.capitalize()


func _build_weapons_tab() -> void:
	var column: VBoxContainer = _tab("Weapons")
	if _spec.has_main_battery():
		column.add_child(UiKit.heading("Main battery"))
		var guns: Array[String] = _armory.gun_ids()
		UiKit.option_row(column, "Gun", guns,
			maxi(guns.find(_spec.main_battery.gun_id), 0),
			func(index: int) -> void:
				_spec.main_battery.gun_id = guns[index]
				_invalidate_hull())
		for i: int in _spec.main_battery.mounts.size():
			var mount: MountDef = _spec.main_battery.mounts[i]
			UiKit.slider_row(column, "%s station" % mount.mount_id, -0.48, 0.48, 0.01,
				mount.station,
				func(v: float) -> void:
					mount.station = v
					_invalidate_hull(), "")
			UiKit.slider_row(column, "%s guns" % mount.mount_id, 1.0, 4.0, 1.0,
				float(mount.guns),
				func(v: float) -> void:
					mount.guns = int(v)
					_invalidate_hull(), "")
	else:
		column.add_child(UiKit.label("She carries no main battery.", 12,
			ViewPalette.TEXT_DIM))

	if _spec.has_torpedoes():
		column.add_child(UiKit.heading("Torpedoes"))
		for mount: TorpedoMountDef in _spec.torpedo_battery.mounts:
			UiKit.slider_row(column, "%s tubes" % mount.mount_id, 1.0, 8.0, 1.0,
				float(mount.tubes),
				func(v: float) -> void:
					mount.tubes = int(v)
					_queue_rebuild(), "")


func _build_layout_tab() -> void:
	var column: VBoxContainer = _tab("Layout")
	column.add_child(UiKit.label(
		"Internal arrangement is generated from where the guns are: the citadel covers "
		+ "the magazines and the machinery between them, magazines sit under the "
		+ "turrets they feed, and the superstructure takes the gap the battery leaves. "
		+ "Move a turret and the whole layout follows it.",
		11, ViewPalette.TEXT_DIM))
	(column.get_child(0) as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_weights_column = UiKit.column(2)
	column.add_child(UiKit.heading("Weight statement"))
	column.add_child(_weights_column)

	column.add_child(UiKit.heading("Volumes"))
	_readouts["machinery_volume"] = UiKit.value_row(column, "Machinery needs")
	_readouts["available_volume"] = UiKit.value_row(column, "Machinery spaces give")


## The permanent strip under the tabs: what the design currently is, and what is wrong
## with it. Refreshed after every edit.
func _build_analysis(parent: VBoxContainer) -> void:
	var frame: PanelContainer = UiKit.panel()
	parent.add_child(frame)

	var column: VBoxContainer = UiKit.column(2)
	frame.add_child(column)
	column.add_child(UiKit.heading("As designed"))

	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	column.add_child(grid)
	for field: String in ["displacement", "speed", "stated", "gm", "sinkage", "kg",
			"armour_fraction", "freeboard"]:
		_readouts[field] = _compact_row(grid, _readout_name(field))

	_findings_column = UiKit.column(5)
	var findings_scroll: ScrollContainer = UiKit.scroll(_findings_column)
	findings_scroll.custom_minimum_size = Vector2(0.0, 150.0)
	column.add_child(findings_scroll)


## Two of these fit side by side, so eight numbers take four rows instead of eight.
func _compact_row(grid: GridContainer, name: String) -> Label:
	var line: HBoxContainer = UiKit.row(4)
	grid.add_child(line)
	var name_label: Label = UiKit.label(name, 11, ViewPalette.TEXT_DIM)
	name_label.custom_minimum_size = Vector2(112.0, 0.0)
	line.add_child(name_label)
	var value: Label = UiKit.label("", 11)
	line.add_child(value)
	return value


static func _readout_name(field: String) -> String:
	match field:
		"displacement": return "Weighs"
		"stated": return "vs stated"
		"sinkage": return "Sits deeper"
		"speed": return "Speed"
		"gm": return "GM"
		"kg": return "KG"
		"armour_fraction": return "Armour"
		"freeboard": return "Freeboard"
		_: return field.capitalize()


# ------------------------------------------------------------------ rebuild --

## Rebuilt on the next frame rather than on the keystroke.
##
## Dragging a slider fires a change every frame, and each rebuild regenerates the whole
## structure — several hundred plates and compartments — and weighs it. Coalescing to
## one rebuild per frame is the difference between a designer that responds and one that
## fights the mouse.
func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


## Dimensions changed, so the cached hull has to go with them.
func _invalidate_hull() -> void:
	_spec.invalidate_hull()
	_queue_rebuild()


func _rebuild() -> void:
	_rebuild_queued = false
	if _spec == null:
		return
	_spec.derive_defaults()

	var template: ShipStructureTemplate = ShipStructureBuilder.build(_spec, _structure_config)
	_analysis = NavalArchitect.analyse(_spec, template, _materials, _armory, _arch_config)
	_findings = DesignValidator.validate(_spec, template, _analysis, _arch_config)

	if _preview != null:
		_preview.call("show_design", _spec, _armory)
		_frame_preview()
	_refresh_readouts()


func _frame_preview() -> void:
	if _preview != null and _preview_frame != null:
		_preview.call("frame_to", _preview_frame.size)


## The editors describe the design that was loaded, so swapping design rebuilds them.
func _rebuild_editors() -> void:
	if _tabs == null:
		return
	for child: Node in _tabs.get_children():
		_tabs.remove_child(child)
		child.queue_free()
	_readouts.clear()
	_build_hull_tab()
	_build_propulsion_tab()
	_build_armour_tab()
	_build_weapons_tab()
	_build_layout_tab()


func _refresh_readouts() -> void:
	if _analysis == null:
		return
	_set_readout("displacement", "%.0f t" % _analysis.full_displacement_t)
	_set_readout("stated", "%+.1f%%" % (_analysis.overweight_fraction() * 100.0))
	_set_readout("sinkage", "%.2f m" % _analysis.sinkage_m)
	_set_readout("speed", "%.1f kn of %.1f" % [_analysis.estimated_speed_kn,
		_analysis.stated_speed_kn])
	_set_readout("gm", "%.2f m" % _analysis.gm_m)
	_set_readout("kg", "%.2f m" % _analysis.kg_m)
	_set_readout("armour_fraction", "%.0f%% of her" %
		(_analysis.group_fraction("Armour") * 100.0))
	_set_readout("freeboard", "%.1f m" % _analysis.freeboard_m)
	_set_readout("machinery_volume", "%.0f m3" % _analysis.machinery_volume_m3)
	_set_readout("available_volume", "%.0f m3" % _analysis.available_volume_m3)

	if _weights_column != null:
		for child: Node in _weights_column.get_children():
			_weights_column.remove_child(child)
			child.queue_free()
		for group: DesignAnalysis.WeightGroup in _analysis.groups:
			var value: Label = UiKit.value_row(_weights_column, group.name, 200.0)
			value.text = "%7.0f t   (%.1f%%)" % [group.tonnes,
				100.0 * group.tonnes / maxf(_analysis.full_displacement_t, 1.0)]

	_refresh_findings()


func _set_readout(field: String, text: String) -> void:
	var readout: Label = _readouts.get(field) as Label
	if readout != null:
		readout.text = text


func _refresh_findings() -> void:
	if _findings_column == null:
		return
	for child: Node in _findings_column.get_children():
		_findings_column.remove_child(child)
		child.queue_free()

	if _findings.is_empty():
		_findings_column.add_child(UiKit.label(
			"Nothing to report. She is a plausible ship.", 12, ViewPalette.FRIENDLY))
		return

	for finding: DesignValidator.Finding in _findings:
		var entry: VBoxContainer = UiKit.column(1)
		_findings_column.add_child(entry)
		entry.add_child(UiKit.label(finding.summary, 12,
			UiKit.severity_colour(finding.severity)))
		var detail: Label = UiKit.label(finding.detail, 11, ViewPalette.TEXT_DIM)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		entry.add_child(detail)


# --------------------------------------------------------------------- save --

func _save() -> void:
	if _spec == null:
		return
	if ShipIO.save(_spec):
		_status.text = "Saved as %s. She is now in the roster and can be put into any battle." \
			% _spec.spec_id
		_status.add_theme_color_override("font_color", ViewPalette.FRIENDLY)
	else:
		_status.text = "Could not write the design to user://ships/."
		_status.add_theme_color_override("font_color", ViewPalette.HOSTILE)
