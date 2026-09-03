extends Node2D

## Aircraft over the battlefield.
##
## Finds the air module by asking the world for one that can answer `air_groups()`, and
## draws nothing at all when there is none. That is the view's side of the isolation
## boundary: a build with `src/sim/air/` deleted still renders a battle, and this file
## is the only one in `src/view/` that has ever heard of an aeroplane.
##
## A group is drawn as what it is — a formation, not a dot — with its strength shown by
## how many marks are in it, so watching a squadron thin out under flak is something you
## can see rather than something you have to read.

const MARK_SIZE: float = 7.0
const SPREAD: float = 26.0
const MAX_MARKS: int = 12

var world: SimWorld = null
var zoom: float = 1.0

var _module: Object = null


func set_zoom(value: float) -> void:
	zoom = maxf(value, 0.00001)


func _draw() -> void:
	if world == null:
		return
	if _module == null:
		_module = world.module_providing(&"air_groups")
	if _module == null:
		return

	for group: Variant in _module.call("air_groups"):
		var air: AirGroup = group as AirGroup
		if air == null or not air.is_alive():
			continue
		_draw_group(air)


func _draw_group(group: AirGroup) -> void:
	var colour: Color = ViewPalette.team_colour(group.team)
	# A group in its attack run is the thing worth looking at on the whole plot.
	if group.mission == AirGroup.Mission.ATTACKING:
		colour = colour.lerp(ViewPalette.DANGER, 0.55)
	elif not group.armed and group.definition.is_strike():
		colour = colour.darkened(0.35)

	var scale: float = 1.0 / zoom
	var marks: int = mini(group.count, MAX_MARKS)
	var forward: Vector2 = Vector2(cos(group.heading), sin(group.heading))
	var across: Vector2 = Vector2(-forward.y, forward.x)

	for i: int in marks:
		# A shallow vee, which is what a formation of aircraft looks like from above and
		# what the marks on a plot always were.
		var rank: float = float(i / 2)
		var side: float = 1.0 if i % 2 == 0 else -1.0
		var at: Vector2 = group.position \
			+ (across * side * rank - forward * rank) * SPREAD * scale
		_draw_aircraft(at, forward, colour, MARK_SIZE * scale)


## One aircraft: a short line for the fuselage and a longer one for the wings. At the
## scale a battlefield is drawn at an aircraft is a couple of pixels, and anything more
## detailed would be invisible and expensive at the same time.
func _draw_aircraft(at: Vector2, forward: Vector2, colour: Color, size: float) -> void:
	var across: Vector2 = Vector2(-forward.y, forward.x)
	draw_line(at - forward * size * 0.6, at + forward * size * 0.6, colour, size * 0.22)
	draw_line(at - across * size * 0.5, at + across * size * 0.5, colour, size * 0.18)
