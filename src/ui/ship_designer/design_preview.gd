extends Node2D

## The design, drawn from above, using the same renderer the battle uses.
##
## Deliberately not a second drawing of the ship. `ShipRenderer` reads a `SimWorld`, so
## the preview builds a world containing exactly one ship and hands it over — which
## means what the designer shows IS what the battle will show, and both are projections
## of the geometry a shell will be traced against. Widen the beam here and the outline
## changes because the hull changed, not because a preview was told to redraw.
##
## The structure template is rebuilt on every edit. It is cached per design id, so the
## cache has to be dropped as well, or the ship would keep the upperworks she had three
## edits ago.

const RENDERER: String = "res://src/view/ship_renderer.gd"

var _world: SimWorld = null
var _renderer: Node2D = null
var _spec: ShipSpec = null
var _zoom: float = 1.0


func _ready() -> void:
	var script: Script = load(RENDERER) as Script
	if script == null:
		return
	_renderer = script.new() as Node2D
	if _renderer != null:
		add_child(_renderer)


## Show a design, rebuilding everything that depends on its geometry.
func show_design(spec: ShipSpec, armory: Armory) -> void:
	_spec = spec
	# The projection is cached per design id and this design has just changed under the
	# same id, so the cached one is a picture of a ship that no longer exists.
	ShipDetail.forget(spec.spec_id)

	_world = SimWorld.create(1, {
		"sim": GameConfig.get_dict("sim"),
		"physics": GameConfig.get_dict("physics"),
		"ballistics": GameConfig.get_dict("ballistics"),
		"structure": GameConfig.get_dict("structure"),
	})
	if armory != null:
		_world.set_armory(armory)
	_world.add_ship(spec, Vector2.ZERO, 0.0, 0)
	# Turrets are built by set_armory only for ships already present, so a ship added
	# afterwards needs them built too.
	if armory != null:
		_world.ships[0].build_turrets(armory)
		_world.ships[0].build_torpedo_launchers(armory)

	if _renderer != null:
		_renderer.set("world", _world)
	queue_redraw()


## Fit the ship to a viewport of the given size, leaving a margin.
func frame_to(size: Vector2) -> void:
	if _spec == null or size.x <= 0.0:
		return
	_zoom = clampf((size.x * 0.86) / maxf(_spec.length_m, 1.0), 0.05, 40.0)
	position = size * 0.5
	scale = Vector2(_zoom, _zoom)
	if _renderer != null:
		# The renderer sizes line widths and detail thresholds by zoom, and its idea of
		# zoom has to match the one actually applied or a hairline becomes a slab.
		_renderer.call("set_zoom", _zoom)
	queue_redraw()


func apparent_length_px() -> float:
	return 0.0 if _spec == null else _spec.length_m * _zoom
