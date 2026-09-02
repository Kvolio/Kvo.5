extends Node

## Application-level signal hub (autoload `AppBus`).
##
## This is presentation-layer plumbing: scene transitions, UI notifications, the
## debug-mode toggle. It is emphatically NOT the simulation's event channel — that
## is `SimEventBus`, which is an ordered queue precisely because signal dispatch
## order is not deterministic.
##
## Nothing under res://src/sim/** may reference this node.

signal scene_change_requested(scene_path: String)
signal debug_mode_toggled(enabled: bool)
signal combat_log_toggled(enabled: bool)
signal notification_posted(text: String, severity: int)

var debug_mode: bool = false:
	set(value):
		if debug_mode != value:
			debug_mode = value
			debug_mode_toggled.emit(value)

var combat_log_visible: bool = true:
	set(value):
		if combat_log_visible != value:
			combat_log_visible = value
			combat_log_toggled.emit(value)


func request_scene(scene_path: String) -> void:
	scene_change_requested.emit(scene_path)


func notify(text: String, severity: int = 0) -> void:
	notification_posted.emit(text, severity)
