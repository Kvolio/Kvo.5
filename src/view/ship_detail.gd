class_name ShipDetail
extends RefCounted

## Plan-view detail for a ship, projected from her structure template.
##
## The renderer's rule is that there is no separate art which can disagree with the
## simulation, and this is how that survives contact with wanting a ship to LOOK like
## something. Every block drawn here is a volume the trajectory tracer already
## intersects — the superstructure, the directors, the radar, the barbettes. Nothing is
## invented for the picture. Draw a custom design and it renders its own detail, because
## the detail is its geometry.
##
## Built once per ship class and cached: a template is immutable, so the projection is
## too. Only the turrets are computed per frame, because they turn.

## One block of superstructure or one piece of equipment, in ship-local plan view.
class Block extends RefCounted:
	var polygon: PackedVector2Array = PackedVector2Array()
	var height_z: float = 0.0        ## top of the block, for draw ordering
	var is_equipment: bool = false   ## equipment is drawn brighter than structure


var blocks: Array[Block] = []
var deck_lines: Array[PackedVector2Array] = []

static var _cache: Dictionary = {}


## Projection for a ship class, built once and reused.
static func for_ship(spec: ShipSpec, template: ShipStructureTemplate,
		config: Dictionary) -> ShipDetail:
	var cached: Variant = _cache.get(spec.spec_id)
	if cached != null:
		return cached as ShipDetail
	var detail: ShipDetail = ShipDetail.new()
	detail._build(spec, template, config)
	_cache[spec.spec_id] = detail
	return detail


## Drop the cache. Only needed when a design is edited in the designer and rebuilt
## under the same id.
static func forget(spec_id: String) -> void:
	_cache.erase(spec_id)


func _build(spec: ShipSpec, template: ShipStructureTemplate, config: Dictionary) -> void:
	var detail_config: Dictionary = config.get("detail", {}) as Dictionary

	# Everything standing above the main deck, flattened to its footprint. That rule —
	# rather than a list of names — is what makes this work for a design nobody has seen:
	# put a deckhouse on a custom ship and it appears, because being above the main deck
	# is what "you can see it from above" means.
	#
	# Sorted by height so the bridge tower draws over the deckhouse it stands on.
	for volume: GeometryPrimitives.Volume in template.volumes:
		var is_component: bool = volume.kind == GeometryPrimitives.VolumeKind.COMPONENT
		if is_component:
			if not _is_visible_topside(volume.role):
				continue
		elif volume.kind != GeometryPrimitives.VolumeKind.COMPARTMENT:
			continue
		if volume.minimum.z < template.main_deck_z - 0.01:
			continue   # below decks: nothing to see from above
		blocks.append(_block_from(volume, is_component))

	blocks.sort_custom(func(a: Block, b: Block) -> bool: return a.height_z < b.height_z)

	# Deck seams. Purely a reading aid, but they give the eye a sense of scale that a
	# flat silhouette does not, and they follow the real hull outline.
	var count: int = maxi(int(detail_config.get("deckLineCount", 9)), 0)
	var hull: HullGeometry = spec.hull()
	for i: int in range(1, count):
		var station: float = lerpf(-0.5, 0.5, float(i) / float(count))
		var half: float = hull.half_beam_at(station)
		if half <= 0.1:
			continue
		var x: float = station * spec.length_m
		deck_lines.append(PackedVector2Array([Vector2(x, -half), Vector2(x, half)]))


## Which fittings are worth drawing from above. Engines and shafts are inside the ship
## and would only be clutter; directors, radar and elevators are on top of her.
static func _is_visible_topside(role: String) -> bool:
	return role == ShipStructureBuilder.COMPONENT_DIRECTOR \
		or role == ShipStructureBuilder.COMPONENT_RADAR \
		or role == ShipStructureBuilder.COMPONENT_ELEVATOR


static func _block_from(volume: GeometryPrimitives.Volume, is_equipment: bool) -> Block:
	var block: Block = Block.new()
	block.polygon = PackedVector2Array([
		Vector2(volume.minimum.x, volume.minimum.y),
		Vector2(volume.maximum.x, volume.minimum.y),
		Vector2(volume.maximum.x, volume.maximum.y),
		Vector2(volume.minimum.x, volume.maximum.y),
	])
	block.height_z = volume.maximum.z
	block.is_equipment = is_equipment
	return block


# ------------------------------------------------------------------- turrets --

## The plan outline of a gunhouse, in turret-local metres: +x forward towards the face,
## +y to starboard, origin on the axis of rotation.
##
## A turret in plan is not a rectangle. The face plate is narrower than the body because
## the sides converge on it, and the rear is cut away — which is why a real gunhouse
## reads as a gunhouse and a four-point trapezoid reads as a box with sticks. The
## proportions come from `data/config/view.json` and describe a SHAPE: they are fractions
## of the gunhouse's own size and carry no ship statistics.
static func gunhouse_plan(plan: Dictionary, length: float, width: float) -> PackedVector2Array:
	var half_width: float = width * 0.5
	var face_half: float = half_width * float(plan.get("faceHalfWidth", 0.62))
	var rear_half: float = half_width * float(plan.get("rearHalfWidth", 0.84))
	# Measured aft from the face, as a fraction of the gunhouse's length.
	var shoulder: float = length * float(plan.get("shoulderAt", 0.34))
	var rear_corner: float = length * float(plan.get("rearCornerAt", 0.88))

	# The axis of rotation sits about a third of the way back from the face, which is
	# where a real turret's roller path is and why the gunhouse overhangs its barbette
	# aft rather than symmetrically.
	var face_x: float = length * 0.62
	return PackedVector2Array([
		Vector2(face_x, -face_half),
		Vector2(face_x, face_half),
		Vector2(face_x - shoulder, half_width),
		Vector2(face_x - rear_corner, half_width),
		Vector2(face_x - length, rear_half),
		Vector2(face_x - length, -rear_half),
		Vector2(face_x - rear_corner, -half_width),
		Vector2(face_x - shoulder, -half_width),
	])


## The plan named for a nation, falling back to the default.
static func plan_for(config: Dictionary, nation: String) -> Dictionary:
	var turret_config: Dictionary = config.get("turret", {}) as Dictionary
	var plans: Dictionary = turret_config.get("plans", {}) as Dictionary
	var by_nation: Dictionary = turret_config.get("nationPlans", {}) as Dictionary
	var name: String = str(by_nation.get(nation, turret_config.get("defaultPlan", "hexagonal")))
	return plans.get(name, plans.get("hexagonal", {})) as Dictionary
