extends Control

## The battle in words, in the order it happened.
##
## Reads `SimEventBus.history()` and nothing else. Events are an OUTPUT of the
## simulation and never an input to it — a replay re-runs from a seed and a command log
## — so the log can carry as much detail as it likes without costing reproducibility
## anything, which is why it is allowed to be chatty and the simulation is not.
##
## Ordinary events are dimmed, the ones that decide a battle are not. A line that says a
## magazine has gone up should not look like a line that says a salvo was fired.

const MAX_LINES: int = 120
const PANEL_WIDTH: float = 420.0

var world: SimWorld = null

var _lines: VBoxContainer = null
var _scroll: ScrollContainer = null
var _last_seen: int = 0
var _shown: Array[Label] = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	var panel: PanelContainer = UiKit.panel()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var column: VBoxContainer = UiKit.column(2)
	column.add_child(UiKit.heading("Combat log"))
	_lines = UiKit.column(1)
	_scroll = UiKit.scroll(_lines)
	_scroll.custom_minimum_size = Vector2(PANEL_WIDTH, 190.0)
	column.add_child(_scroll)
	panel.add_child(column)
	custom_minimum_size = Vector2(PANEL_WIDTH + 16.0, 220.0)


## Take everything that has happened since the last refresh.
##
## The bus keeps a bounded history, so a long battle is read incrementally rather than
## re-formatted from the beginning every frame.
func refresh() -> void:
	if world == null or _lines == null:
		return
	var history: Array[SimEvent] = world.events.history()
	for event: SimEvent in history:
		if event.seq <= _last_seen:
			continue
		_last_seen = event.seq
		var text: String = CombatLogText.describe(world, event)
		if text.is_empty():
			continue
		_append(text, event)
	if _scroll != null:
		await get_tree().process_frame
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _append(text: String, event: SimEvent) -> void:
	var line: Label = UiKit.label("%s  %s" % [_clock(event.tick), text], 11,
		_colour(event.severity))
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.custom_minimum_size = Vector2(PANEL_WIDTH - 20.0, 0.0)
	_lines.add_child(line)
	_shown.append(line)
	while _shown.size() > MAX_LINES:
		var oldest: Label = _shown.pop_front()
		oldest.queue_free()


static func _clock(tick: int) -> String:
	var seconds: int = int(float(tick) / 60.0)
	return "T+%02d:%02d" % [seconds / 60, seconds % 60]


static func _colour(severity: SimEvent.Severity) -> Color:
	match severity:
		SimEvent.Severity.CRITICAL:
			return ViewPalette.DANGER
		SimEvent.Severity.NOTABLE:
			return ViewPalette.TEXT_PRIMARY
	return ViewPalette.TEXT_DIM


