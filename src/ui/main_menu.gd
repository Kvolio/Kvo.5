extends Control

## The front door.
##
## Until now the project booted straight into a battle, which was fine while a battle
## was the only thing there was. The designer needs somewhere to be reached from, and
## Stage 8's scenario editor will want the same door.

signal battle_requested()
signal designer_requested()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var background: ColorRect = ColorRect.new()
	background.color = ViewPalette.SEA_DEEP
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var centre: CenterContainer = CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	var panel: PanelContainer = UiKit.panel()
	panel.custom_minimum_size = Vector2(520.0, 0.0)
	centre.add_child(panel)

	var column: VBoxContainer = UiKit.column(10)
	panel.add_child(column)

	var title: Label = UiKit.label("Naval Battle Sandbox", 30)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var blurb: Label = UiKit.label(
		"Design a warship, put her in a battle, and find out why she survived or died. "
		+ "Damage is what a shell physically did, not a number subtracted from a bar.",
		12, ViewPalette.TEXT_DIM)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(blurb)

	column.add_child(_gap(12.0))
	column.add_child(UiKit.button("Battle", func() -> void: battle_requested.emit()))
	column.add_child(UiKit.button("Ship designer",
		func() -> void: designer_requested.emit()))
	column.add_child(_gap(8.0))

	var count: Label = UiKit.label(
		"%d designs in the roster." % ShipDatabase.count(), 11, ViewPalette.TEXT_DIM)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(count)


static func _gap(height: float) -> Control:
	var node: Control = Control.new()
	node.custom_minimum_size = Vector2(0.0, height)
	return node
