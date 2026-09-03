extends Control

## One ship, opened up: her compartments, her armour, and what has happened to each.
##
## The plan is drawn from the SAME `ShipStructureTemplate` the trajectory tracer
## intersects, so what the player sees is what a shell will meet. A second drawing of a
## ship's insides would be a second thing to keep in step, and it would lose the
## argument with the tracer every time.
##
## Reads state; writes nothing. Compartments are coloured by what is wrong with them,
## which makes the shape of the damage legible at a glance: a line of flooded spaces
## down one side is a torpedo hit, a burning cluster amidships is a fire in the
## machinery, and a wrecked magazine is the reason the ship is not there any more.

const PANEL_WIDTH: float = 360.0
const PLAN_HEIGHT: float = 170.0

var world: SimWorld = null
var ship_id: int = 0

var _plan: Control = null
var _fields: Dictionary = {}
var _components: VBoxContainer = null
var _title: Label = null


func _ready() -> void:
	var panel: PanelContainer = UiKit.panel()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var column: VBoxContainer = UiKit.column(4)
	_title = UiKit.heading("Ship inspector")
	column.add_child(_title)

	_plan = Control.new()
	_plan.custom_minimum_size = Vector2(PANEL_WIDTH - 24.0, PLAN_HEIGHT)
	_plan.draw.connect(_draw_plan)
	column.add_child(_plan)

	for field: String in ["Integrity", "Reserve buoyancy", "List", "Trim", "Flooded",
			"On fire", "Breach area", "Crew", "Main battery", "Propulsion"]:
		_fields[field] = UiKit.value_row(column, field, 150.0)

	column.add_child(UiKit.heading("Components"))
	_components = UiKit.column(1)
	column.add_child(UiKit.scroll(_components))
	panel.add_child(column)
	custom_minimum_size = Vector2(PANEL_WIDTH, 520.0)


func show_ship(entity_id: int) -> void:
	ship_id = entity_id
	refresh()


func refresh() -> void:
	var ship: ShipEntity = null if world == null else world.get_ship(ship_id)
	visible = ship != null
	if ship == null:
		return
	_title.text = "%s — %s" % [ship.display_name, ship.spec.display_name]

	var condition: SurvivabilityEvaluator.Condition = ship.condition
	if condition != null:
		_set_field("Integrity", "%.0f%%" % (condition.integrity * 100.0))
		_set_field("Reserve buoyancy", "%.0f%%" % (condition.reserve_buoyancy * 100.0))
		_set_field("List", "%.1f deg" % condition.list_deg)
		_set_field("Trim", "%.1f deg" % condition.trim_deg)
		_set_field("Flooded", "%.0f m3" % condition.flooded_volume_m3)
		_set_field("On fire", "%.0f%%" % (condition.fire_fraction * 100.0))
		_set_field("Breach area", "%.1f m2" % condition.breach_area_m2)
		_set_field("Main battery", "%.0f%%" % (condition.main_barrels_fraction * 100.0))
		_set_field("Propulsion", "%.0f%%" % (condition.propulsion_fraction * 100.0))
	if ship.structure_state != null:
		_set_field("Crew", "%d of %d" % [ship.structure_state.crew_alive,
			ship.structure_state.crew_total])

	_refresh_components(ship)
	if _plan != null:
		_plan.queue_redraw()


## Named `_set_field` rather than `_set`, because `Object._set` is a virtual with a
## different signature and overriding it by accident is a parse error that reads as if
## the file were unrelated to the mistake. The same trap caught this project once
## already, in the ship designer.
func _set_field(field: String, text: String) -> void:
	var label: Label = _fields.get(field) as Label
	if label != null:
		label.text = text


func _refresh_components(ship: ShipEntity) -> void:
	for child: Node in _components.get_children():
		child.queue_free()
	if ship.structure_state == null:
		return
	var template: ShipStructureTemplate = world.structure_for(ship)
	for i: int in ship.structure_state.components.size():
		var state: ShipStructureState.ComponentState = ship.structure_state.components[i]
		if state == null or state.condition >= 0.999:
			continue   # only what is damaged; an undamaged ship should show a short list
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		var row: HBoxContainer = UiKit.row(6)
		row.add_child(UiKit.label(volume.label, 11, ViewPalette.TEXT_DIM))
		row.add_child(UiKit.spacer())
		row.add_child(UiKit.label("%.0f%%" % (state.condition * 100.0), 11,
			_condition_colour(state.condition)))
		_components.add_child(row)
	if _components.get_child_count() == 0:
		_components.add_child(UiKit.label("nothing damaged", 11, ViewPalette.TEXT_DIM))


static func _condition_colour(condition: float) -> Color:
	if condition < 0.05:
		return ViewPalette.DANGER
	if condition < 0.35:
		return ViewPalette.BURNING
	return ViewPalette.MISSION_KILL


## The plan view: every compartment in the design, coloured by its condition.
##
## Drawn in ship-local metres and scaled to the panel, so a destroyer and a battleship
## are both legible and both drawn from their own geometry rather than from a picture.
func _draw_plan() -> void:
	var ship: ShipEntity = null if world == null else world.get_ship(ship_id)
	if ship == null or ship.structure_state == null:
		return
	var template: ShipStructureTemplate = world.structure_for(ship)
	var size: Vector2 = _plan.size
	var length: float = maxf(ship.spec.length_m, 1.0)
	var beam: float = maxf(ship.spec.beam_m, 1.0)

	# Fit the hull to the panel, keeping her proportions: a ship eight times as long as
	# she is wide should look it.
	var scale: float = minf(size.x / (length * 1.05), size.y / (beam * 1.6))
	var centre: Vector2 = size * 0.5

	# Her actual waterline shape, from the same hull geometry everything else uses.
	var outline: PackedVector2Array = PackedVector2Array()
	for point: Vector2 in ship.hull().outline_local():
		outline.append(centre + Vector2(point.x, point.y) * scale)
	if outline.size() > 2:
		_plan.draw_colored_polygon(outline, Color(0.10, 0.16, 0.20, 0.9))
		_plan.draw_polyline(outline + PackedVector2Array([outline[0]]),
			ViewPalette.PANEL_EDGE, 1.0)

	for i: int in template.volumes.size():
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		if volume.kind != GeometryPrimitives.VolumeKind.COMPARTMENT:
			continue
		var state: ShipStructureState.CompartmentState = ship.structure_state.compartment(i)
		var rect: Rect2 = Rect2(
			centre + Vector2(volume.minimum.x, volume.minimum.y) * scale,
			Vector2(volume.maximum.x - volume.minimum.x,
				volume.maximum.y - volume.minimum.y) * scale)
		_plan.draw_rect(rect, _compartment_colour(state), true)
		_plan.draw_rect(rect, Color(0.0, 0.0, 0.0, 0.35), false, 1.0)


## What is wrong with a compartment, in the order that decides how she is lost.
static func _compartment_colour(state: ShipStructureState.CompartmentState) -> Color:
	if state == null:
		return Color(0.15, 0.20, 0.24, 0.6)
	if state.wreckage > 0.5:
		return ViewPalette.WRECKED
	if state.fire > 0.05:
		return ViewPalette.BURNING.lerp(ViewPalette.DANGER, clampf(state.fire, 0.0, 1.0))
	if state.flood > 0.05:
		return ViewPalette.FLOODED.darkened(1.0 - clampf(state.flood, 0.0, 1.0) * 0.5)
	if state.breached:
		return ViewPalette.DANGER.darkened(0.4)
	return ViewPalette.INTACT.darkened(0.45)
