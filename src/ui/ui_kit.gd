class_name UiKit
extends RefCounted

## Shared widgets for the interface.
##
## The project builds its UI in code rather than as scenes, so that the layout lives
## next to the logic that fills it in. The cost of that choice is that styling wants to
## drift between screens; this is where it does not. Every panel, label and row in the
## HUD and in the ship designer comes from here, so the designer looks like the battle
## it feeds.
##
## Colours come from ViewPalette, which the plot also uses — one scheme for the whole
## application rather than one per screen.

const LABEL_WIDTH: float = 150.0


static func panel() -> PanelContainer:
	var box: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = ViewPalette.PANEL_BG
	style.border_color = ViewPalette.PANEL_EDGE
	style.set_border_width_all(1)
	style.set_content_margin_all(8)
	box.add_theme_stylebox_override("panel", style)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	return box


static func label(text: String, size: int = 12, colour: Color = ViewPalette.TEXT_PRIMARY) -> Label:
	var node: Label = Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", colour)
	return node


static func heading(text: String) -> Label:
	var node: Label = label(text, 15, ViewPalette.TEXT_PRIMARY)
	node.add_theme_constant_override("line_spacing", 6)
	return node


static func column(separation: int = 4) -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	return box


static func row(separation: int = 6) -> HBoxContainer:
	var box: HBoxContainer = HBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	return box


static func spacer() -> Control:
	var node: Control = Control.new()
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return node


## A name on the left and a value on the right, the value returned so a caller can keep
## it and update it. The readout pattern used by every panel in the game.
static func value_row(parent: Node, name: String, width: float = LABEL_WIDTH) -> Label:
	var line: HBoxContainer = row()
	parent.add_child(line)
	var name_label: Label = label(name, 12, ViewPalette.TEXT_DIM)
	name_label.custom_minimum_size = Vector2(width, 0.0)
	line.add_child(name_label)
	var value: Label = label("", 12)
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(value)
	return value


## A labelled slider with a live numeric readout.
##
## Returned rather than wired to a property, because a design's fields are not
## independent: moving the beam changes the displacement, the stability and the speed,
## and the caller is what knows how to recompute all of that.
static func slider_row(parent: Node, name: String, minimum: float, maximum: float,
		step: float, value: float, on_change: Callable, suffix: String = "") -> HSlider:
	var line: HBoxContainer = row()
	parent.add_child(line)

	var name_label: Label = label(name, 12, ViewPalette.TEXT_DIM)
	name_label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	line.add_child(name_label)

	var slider: HSlider = HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(140.0, 0.0)
	line.add_child(slider)

	var readout: Label = label("", 12)
	readout.custom_minimum_size = Vector2(84.0, 0.0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(readout)

	var format: Callable = func(v: float) -> void:
		readout.text = ("%.2f %s" % [v, suffix]) if step < 1.0 else ("%.0f %s" % [v, suffix])
	format.call(value)
	slider.value_changed.connect(func(v: float) -> void:
		format.call(v)
		on_change.call(v))
	return slider


static func option_row(parent: Node, name: String, options: Array[String], selected: int,
		on_change: Callable) -> OptionButton:
	var line: HBoxContainer = row()
	parent.add_child(line)

	var name_label: Label = label(name, 12, ViewPalette.TEXT_DIM)
	name_label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	line.add_child(name_label)

	var option: OptionButton = OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for text: String in options:
		option.add_item(text)
	if selected >= 0 and selected < options.size():
		option.select(selected)
	option.item_selected.connect(func(index: int) -> void: on_change.call(index))
	line.add_child(option)
	return option


static func button(text: String, on_press: Callable, width: float = 0.0) -> Button:
	var node: Button = Button.new()
	node.text = text
	if width > 0.0:
		node.custom_minimum_size = Vector2(width, 0.0)
	node.pressed.connect(on_press)
	return node


static func scroll(child: Control) -> ScrollContainer:
	var box: ScrollContainer = ScrollContainer.new()
	box.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(child)
	return box


## Colour for a validator finding, so severity reads at a glance.
static func severity_colour(severity: DesignValidator.Severity) -> Color:
	match severity:
		DesignValidator.Severity.SERIOUS:
			return ViewPalette.HOSTILE
		DesignValidator.Severity.WARNING:
			return ViewPalette.MISSION_KILL
		_:
			return ViewPalette.TEXT_DIM
