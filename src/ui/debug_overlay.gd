extends Control

## The causality chain, exactly as it happened, for the last shell that arrived.
##
## This is the payoff for `HitReport` being the damage MECHANISM rather than a log of
## it. Nothing here is reconstructed or estimated: every line is a `LayerInteraction`
## the trajectory tracer actually resolved, with the projectile's state before and
## after, and the penetration model's own reasoning where it had any.
##
## So a player who wants to know why a 16-inch shell failed against a cruiser can read
## the answer — the plate it met, the obliquity, the effective thickness against the
## capability, whether the cap survived, where it stopped — instead of being told it
## did 4,200 damage.

const PANEL_WIDTH: float = 440.0

var world: SimWorld = null

var _lines: VBoxContainer = null
var _title: Label = null
var _shown_projectile: int = -1


func _ready() -> void:
	var panel: PanelContainer = UiKit.panel()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var column: VBoxContainer = UiKit.column(3)
	_title = UiKit.heading("Debug: last hit")
	column.add_child(_title)
	_lines = UiKit.column(1)
	var scroll: ScrollContainer = UiKit.scroll(_lines)
	scroll.custom_minimum_size = Vector2(PANEL_WIDTH - 24.0, 420.0)
	column.add_child(scroll)
	panel.add_child(column)
	custom_minimum_size = Vector2(PANEL_WIDTH, 470.0)


func refresh() -> void:
	if world == null or world.recent_hits.is_empty():
		return
	var report: HitReport = world.recent_hits[world.recent_hits.size() - 1]
	if report.projectile_id == _shown_projectile:
		return
	_shown_projectile = report.projectile_id
	show_report(report)


## Render one report. Public so the same view serves a hit picked out of the log.
func show_report(report: HitReport) -> void:
	for child: Node in _lines.get_children():
		child.queue_free()
	_title.text = "%s -> %s" % [
		_name(report.shooter_id), _name(report.target_id)]

	for line: String in DebugOverlayText.describe(report):
		var indented: bool = line.begins_with("    ")
		_lines.add_child(UiKit.label(line, 10,
			ViewPalette.TEXT_DIM if indented else ViewPalette.TEXT_PRIMARY))


func _name(entity_id: int) -> String:
	var ship: ShipEntity = null if world == null else world.get_ship(entity_id)
	return ship.display_name if ship != null else "#%d" % entity_id
