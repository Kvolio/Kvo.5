class_name FormationSystem
extends RefCounted

## Ships keeping station on one another.
##
## A formation is defined as an offset in the GUIDE'S frame, not as a set of world
## positions, and everything good about it follows from that one choice. When the guide
## turns, every station turns with her, so a column turning together is a turn and not a
## teleport; a ship out of station closes it by steaming, at a speed she actually has;
## and a formation whose guide is sunk re-forms on the next ship in the line rather than
## dissolving, which is what a squadron did.
##
## Station keeping is deliberately not perfect. Ships settle onto their stations at a
## speed the movement model gives them, which means a fleet turn ripples down a column
## exactly as it should, and a destroyer screen ordered to a new course takes time to
## get back into line.

## How far off the guide's course a ship will steer to regain her station. Beyond this
## she has stopped being in the formation and started being somewhere else — but a ship
## a mile out of station really does put her helm over hard to rejoin, so it is not a
## small angle either.
const MAXIMUM_CORRECTION_RAD: float = deg_to_rad(60.0)


enum Shape {
	COLUMN,        ## line ahead: each ship follows the next, the classic battle line
	LINE_ABREAST,  ## side by side, for sweeping
	ECHELON,       ## staggered astern and to one side
	SCREEN,        ## an arc ahead of the guide, which is what a destroyer screen is
}


class Formation extends RefCounted:
	var formation_id: String = ""
	var team: int = 0
	var guide_id: int = 0
	var shape: int = Shape.COLUMN
	var spacing_m: float = 700.0
	var screen_arc_rad: float = deg_to_rad(120.0)

	## Members in station order, guide first. Kept as an array rather than a set
	## because the ORDER is the formation: station three is astern of station two.
	var members: PackedInt32Array = PackedInt32Array()

	func index_of(ship_id: int) -> int:
		for i: int in members.size():
			if members[i] == ship_id:
				return i
		return -1

	## Where station `index` sits, in the guide's own frame: +x ahead, +y to starboard.
	func station_offset(index: int) -> Vector2:
		if index <= 0:
			return Vector2.ZERO
		match shape:
			Shape.COLUMN:
				return Vector2(-spacing_m * float(index), 0.0)
			Shape.LINE_ABREAST:
				return Vector2(0.0, spacing_m * float(index))
			Shape.ECHELON:
				return Vector2(-spacing_m * float(index) * 0.7, spacing_m * float(index) * 0.7)
			Shape.SCREEN:
				# Spread evenly across an arc ahead of the guide. A screen is a fan,
				# not a line, because what it is doing is covering bearings.
				var count: int = maxi(members.size() - 1, 1)
				var step: float = screen_arc_rad / float(maxi(count - 1, 1))
				var angle: float = -screen_arc_rad * 0.5 + step * float(index - 1)
				if count == 1:
					angle = 0.0
				return Vector2(cos(angle), sin(angle)) * spacing_m
		return Vector2.ZERO

	func serialize() -> Dictionary:
		return {
			"id": formation_id, "team": team, "guideId": guide_id,
			"shape": shape, "spacingM": spacing_m,
			"members": Array(members),
		}


## Bring every formation's members back onto their stations.
static func step(world: SimWorld, dt: float) -> void:
	for formation: Formation in world.formations:
		_reform(world, formation)
		var guide: ShipEntity = world.get_ship(formation.guide_id)
		if guide == null or not guide.can_manoeuvre():
			continue
		for index: int in formation.members.size():
			var ship: ShipEntity = world.get_ship(formation.members[index])
			if ship == null or ship.id == formation.guide_id:
				continue
			if not ship.keeps_station():
				continue
			_keep_station(world, formation, guide, ship, index, dt)


## A formation whose guide is gone re-forms on the next ship still afloat.
##
## The station offsets are unchanged, so the new guide takes the old guide's place and
## the line closes up — which is what happened, and is why a battle line could lose its
## flagship without losing its formation.
static func _reform(world: SimWorld, formation: Formation) -> void:
	var guide: ShipEntity = world.get_ship(formation.guide_id)
	if guide != null and guide.can_manoeuvre():
		return
	for ship_id: int in formation.members:
		var candidate: ShipEntity = world.get_ship(ship_id)
		if candidate != null and candidate.can_manoeuvre():
			formation.guide_id = ship_id
			world.events.emit_event(&"formation_reformed", ship_id, 0,
				SimEvent.Severity.NOTABLE, {"formation": formation.formation_id})
			return


## Station keeping as it is actually done: course for the ACROSS-track error, speed for
## the ALONG-track error.
##
## Steering at the station point directly is the obvious implementation and it is
## wrong. A ship two cables astern of her station would turn round and steam back
## towards it, and a whole column that had just followed a turn would do it at once.
## Decomposing the error is what a real officer of the watch does: if you are astern of
## station you go faster, you do not turn round.
static func _keep_station(world: SimWorld, formation: Formation, guide: ShipEntity,
		ship: ShipEntity, index: int, _dt: float) -> void:
	var config: Dictionary = world.ai_config.get("formation", {}) as Dictionary
	var station: Vector2 = guide.position \
		+ formation.station_offset(index).rotated(guide.heading)
	var to_station: Vector2 = station - ship.position

	var ahead: Vector2 = Vector2(cos(guide.heading), sin(guide.heading))
	var abeam: Vector2 = Vector2(-ahead.y, ahead.x)
	var along: float = to_station.dot(ahead)
	var across: float = to_station.dot(abeam)

	# Course: the guide's, offset towards the station by however far off the line she
	# is. Bounded, because a ship correcting a mile of lateral error by steering ninety
	# degrees off is no longer in the formation at all.
	var lead: float = maxf(float(config.get("stationToleranceM", 250.0)) * 4.0, 1.0)
	var correction: float = clampf(across / lead, -1.0, 1.0) * MAXIMUM_CORRECTION_RAD
	MovementSystem.steer_to_heading(ship, SimUnits.normalise_angle(guide.heading + correction))

	# Speed: faster when astern of station, slower when ahead of it. This is the whole
	# of how a column closes up, and why it takes minutes rather than seconds.
	var gain: float = float(config.get("speedCorrectionGain", 0.35))
	var overtake: float = float(config.get("maximumOvertakeFraction", 1.25))
	var wanted: float = guide.speed + gain * along
	wanted = clampf(wanted, 0.0, minf(guide.speed * overtake + 2.0, ship.effective_max_speed()))
	MovementSystem.order_speed(ship, wanted)


## Build a formation and put the ships in it.
static func create(formation_id: String, team: int, members: Array[ShipEntity],
		shape: int, spacing_m: float) -> Formation:
	var formation: Formation = Formation.new()
	formation.formation_id = formation_id
	formation.team = team
	formation.shape = shape
	formation.spacing_m = spacing_m
	for i: int in members.size():
		var ship: ShipEntity = members[i]
		formation.members.append(ship.id)
		ship.formation_id = formation_id
		ship.station_index = i
	if not formation.members.is_empty():
		formation.guide_id = formation.members[0]
	return formation


static func shape_from_string(text: String) -> int:
	match text.to_lower():
		"column", "line_ahead": return Shape.COLUMN
		"line_abreast", "abreast": return Shape.LINE_ABREAST
		"echelon": return Shape.ECHELON
		"screen": return Shape.SCREEN
	push_warning("FormationSystem: unknown formation shape '%s'; using a column" % text)
	return Shape.COLUMN
