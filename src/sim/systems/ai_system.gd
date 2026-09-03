class_name AiSystem
extends RefCounted

## Fighting a ship: what to shoot at, and where to fight from.
##
## Two rules run through the whole of it.
##
## The first is that the AI decides from the team's CONTACT PLOT and never from
## `world.ships`. An AI that read the world directly would be playing with the lid off:
## it could never lose a target in the dark, never be surprised, never be drawn onto a
## contact that turned away four minutes ago and is not where the plot says. Every
## interesting thing a night action does to a fleet comes from that one restriction.
##
## The second is that the preferred fighting range is not a number in a config file. It
## is read off the ship's own immunity zone against the gun she is facing — computed by
## asking the penetration model, at the ranges in the enemy gun's own range table, what
## happens to her belt and her deck. So a heavily armoured ship closes to where she
## cannot be hurt, a thin-skinned one stays out at the edge of her reach, and a design
## nobody has ever drawn gets a doctrine from its own armour.
##
## Decisions are taken inside the simulation and are therefore not recorded: given the
## same seed and the same initial state they are re-derived identically, which is what
## lets a replay carry only the player's orders. The AI accordingly steers through
## MovementSystem directly rather than through the command queue, which is for intent
## arriving from OUTSIDE the simulation.

const RNG_STREAM: String = "ai"


enum Posture {
	HOLD,        ## nothing to fight
	ENGAGE,      ## a target, and a range she wants to fight it at
	CLOSE,       ## too far out to hurt anybody; get in
	DISENGAGE,   ## too badly hurt to go on
	EVADE,       ## torpedoes in the water
}


## One ship's tactical state. Lives on the ship so it serialises with her.
class State extends RefCounted:
	var posture: int = Posture.HOLD
	var preferred_range_m: float = 0.0
	var target_score: float = 0.0

	## Seconds since the guns were last shifted. Shifting target is a deliberate order
	## and a costly one — it throws away the gunnery solution — so it is reconsidered on
	## a timer rather than every decision cycle. Without this the score churns as
	## contacts come and go and ranges change, ships shift target several times a
	## minute, every plot is reopened before it can settle, and a fleet action produces
	## six hundred shells and no hits. Which it did.
	var seconds_on_target: float = 0.0
	var ordered_heading: float = 0.0
	var torpedoes_spent: bool = false
	var reason: String = ""

	func describe() -> String:
		return "%s at %.1f km — %s" % [posture_name(posture), preferred_range_m / 1000.0, reason]

	static func posture_name(posture: int) -> String:
		match posture:
			Posture.HOLD: return "holding"
			Posture.ENGAGE: return "engaging"
			Posture.CLOSE: return "closing"
			Posture.DISENGAGE: return "disengaging"
			Posture.EVADE: return "evading"
		return "unknown"


## One decision cycle for every ship the AI is fighting.
##
## Ships are taken in ascending id order and staggered across ticks by id, so the work
## spreads evenly and the order in which decisions are made never depends on anything
## but the ids.
static func step(world: SimWorld, dt: float, interval: int) -> void:
	if world.contacts == null:
		return
	for ship: ShipEntity in world.ships:
		if not ship.ai_controlled or not ship.is_afloat():
			continue
		if (world.clock.tick + ship.id) % interval != 0:
			continue
		if ship.ai == null:
			ship.ai = State.new()
		_decide(world, ship, dt * float(interval))


static func _decide(world: SimWorld, ship: ShipEntity, dt: float) -> void:
	var config: Dictionary = world.ai_config
	var state: State = ship.ai

	# Torpedoes already in the water outrank everything else. A ship that is still
	# working out her gunnery while a salvo runs towards her has her priorities wrong.
	var threat: Torpedo = _nearest_torpedo_threat(world, ship, config)
	if threat != null:
		state.posture = Posture.EVADE
		state.reason = "combing a torpedo track"
		_comb(world, ship, threat, config)
		return

	if _should_disengage(ship, config):
		state.posture = Posture.DISENGAGE
		state.reason = "too badly hurt to fight on"
		_break_off(world, ship)
		return

	state.seconds_on_target += dt
	var contact: ContactPlot.Contact = choose_target(world, ship)
	if contact == null:
		state.posture = Posture.HOLD
		state.reason = "no contact"
		ship.target_id = 0
		state.seconds_on_target = 0.0
		return

	if contact.entity_id != ship.target_id:
		state.seconds_on_target = 0.0
	ship.target_id = contact.entity_id
	state.preferred_range_m = preferred_range(world, ship, contact)
	_manoeuvre(world, ship, contact, state, config)
	_consider_torpedoes(world, ship, contact, state, config)


# -- what to shoot at ----------------------------------------------------------

## Pick a target from the plot.
##
## Scored rather than nearest-first, and deliberately sticky: shifting target throws
## away a gunnery solution that may have taken three minutes and four salvos to build,
## so a new contact has to be clearly better before the guns are shifted. Without that
## hysteresis ships dither between equally good targets and never hit anything, which
## is a failure mode real fire-control doctrine had strong words about.
static func choose_target(world: SimWorld, ship: ShipEntity) -> ContactPlot.Contact:
	var config: Dictionary = (world.ai_config.get("targeting", {}) as Dictionary)
	var plot_config: Dictionary = (world.detection_config.get("plot", {}) as Dictionary)
	var firm_seconds: float = float(plot_config.get("firmSeconds", 12.0))

	# A target she is already solving on is held until the guns have had a fair run at
	# it. This is not inertia for its own sake: every shift reopens the plot, and a plot
	# that is reopened every twenty seconds never gets past its opening salvo.
	var held: ContactPlot.Contact = world.contacts.contact(ship.team, ship.target_id) \
		if ship.target_id != 0 else null
	if held != null and held.is_firm(firm_seconds) and ship.ai != null \
			and ship.ai.seconds_on_target < float(config.get("reviewSeconds", 45.0)):
		var target: ShipEntity = world.get_ship(held.entity_id)
		if target != null and target.is_afloat():
			return held

	var engaged: Dictionary = _engagement_counts(world, ship.team)
	var reach: float = _maximum_gun_range(world, ship)
	var best: ContactPlot.Contact = null
	var best_score: float = 0.0
	var current_score: float = 0.0

	for contact: ContactPlot.Contact in world.contacts.contacts_for(ship.team):
		if not contact.is_firm(firm_seconds):
			continue
		var score: float = _score(ship, contact, engaged, config, reach)
		if contact.entity_id == ship.target_id:
			current_score = score
		if score > best_score:
			best_score = score
			best = contact
		# Ties go to the lower id. Stated rather than left to the iteration order,
		# because contacts_for() is already id-ordered and a future change to it must
		# not silently change which ship a fleet action concentrates on.
	if best == null:
		return null

	var hysteresis: float = float(config.get("switchHysteresis", 1.25))
	if ship.target_id != 0 and current_score > 0.0 and best_score < current_score * hysteresis:
		ship.ai.target_score = current_score
		return world.contacts.contact(ship.team, ship.target_id)
	ship.ai.target_score = best_score
	return best


static func _score(ship: ShipEntity, contact: ContactPlot.Contact, engaged: Dictionary,
		config: Dictionary, reach: float) -> float:
	var values: Dictionary = config.get("valueByType", {}) as Dictionary
	var value: float = float(values.get("default", 0.6))
	if contact.classified and values.has(contact.ship_type):
		value = float(values[contact.ship_type])

	var range_m: float = ship.position.distance_to(contact.estimated_position)
	var scale: float = maxf(float(config.get("rangeScaleM", 12000.0)), 1.0)
	var score: float = value / (1.0 + range_m / scale)

	if not contact.classified:
		score *= float(config.get("unclassifiedPenalty", 0.55))

	# A target she cannot reach is not a target. Laying the guns on something beyond
	# their range means standing the mounts down every cycle and, worse, holding a
	# solution on a ship that is never shot at — an Essex was found engaging a cruiser
	# thirty-seven kilometres away with five-inch guns that reach sixteen.
	if reach > 0.0 and range_m > reach:
		score *= float(config.get("outOfReachPenalty", 0.08))

	# Spreading fire across the enemy line is sound; concentrating a fleet on one
	# destroyer is not.
	var already: int = int(engaged.get(contact.entity_id, 0))
	if contact.entity_id == ship.target_id:
		already = maxi(already - 1, 0)
	score /= 1.0 + float(already) * float(config.get("concentrationPenalty", 0.35))
	return score


## How many of this team's ships are already engaging each contact.
static func _engagement_counts(world: SimWorld, team: int) -> Dictionary:
	var counts: Dictionary = {}
	for other: ShipEntity in world.ships:
		if other.team != team or other.target_id == 0 or not other.is_afloat():
			continue
		counts[other.target_id] = int(counts.get(other.target_id, 0)) + 1
	return counts


# -- where to fight from -------------------------------------------------------

## The range this ship wants to fight this enemy at.
##
## Read off BOTH immunity zones, because the decision has two halves and a ship that
## considered only her own armour would get it badly wrong. Two battle lines each
## holding the middle of their own zone will sit at twenty-five kilometres firing at
## each other for half an hour and hit nothing, which is exactly what the first version
## of this function produced: fourteen hundred shells, no hits. Real commanders closed,
## and they closed because a long-range gunnery duel achieves nothing.
##
## So the wanted range is the one where SHE cannot be hurt and HE can. Where no such
## range exists — and against a heavy enough gun there often is none — being able to
## hurt him wins, and closing is what makes that true, because accuracy improves as the
## range falls far faster than protection does.
##
## Sampled rather than solved. The two zones are intervals and the interval algebra is
## fiddly and easy to get subtly wrong; walking a few dozen ranges and scoring each is
## obviously correct and costs nothing at a decision every tenth of a second.
static func preferred_range(world: SimWorld, ship: ShipEntity,
		contact: ContactPlot.Contact) -> float:
	var manoeuvre: Dictionary = world.ai_config.get("manoeuvre", {}) as Dictionary
	var own_max: float = _maximum_gun_range(world, ship)
	var fallback: float = own_max * float(manoeuvre.get("fallbackRangeFraction", 0.5))

	var enemy: ShipEntity = world.get_ship(contact.entity_id)
	if enemy == null or not contact.classified:
		return fallback

	var mine: ImmunityZone = world.immunity_zone(ship, enemy)      # where he cannot hurt her
	var his: ImmunityZone = world.immunity_zone(enemy, ship)       # where she cannot hurt him
	if mine == null and his == null:
		return fallback

	var safety: float = float(manoeuvre.get("immunityWeight", 2.0))
	var lethality: float = float(manoeuvre.get("lethalityWeight", 3.0))
	var closeness: float = float(manoeuvre.get("closingWeight", 1.0))
	var floor_m: float = float(manoeuvre.get("minimumRangeM", 4000.0))
	if ship.spec.has_torpedoes():
		# A ship with torpedoes has a reason to be close that a gun ship does not.
		floor_m = float(manoeuvre.get("minimumTorpedoRangeM", 2500.0))

	var best: float = fallback
	var best_score: float = -INF
	var steps: int = 40
	for i: int in steps + 1:
		var range_m: float = lerpf(floor_m, own_max, float(i) / float(steps))
		var score: float = closeness * (1.0 - range_m / maxf(own_max, 1.0))
		if mine != null and mine.contains(range_m):
			score += safety
		if his == null or not his.contains(range_m):
			score += lethality
		if score > best_score:
			best_score = score
			best = range_m
	return best


static func _maximum_gun_range(world: SimWorld, ship: ShipEntity) -> float:
	var best: float = 0.0
	if world.armory == null:
		return 20000.0
	for turret: Turret in ship.main_battery_turrets():
		var table: RangeTable = world.armory.range_table(turret.gun.gun_id, turret.selected_shell)
		if table != null:
			best = maxf(best, table.maximum_range())
	return best if best > 0.0 else 20000.0


## Steer for the range she wants while showing as much of her broadside as she can.
##
## Candidate headings are scored rather than solved for, because the two goals really
## do conflict: the heading that closes the range fastest is bow-on, and bow-on is the
## heading that masks most of her guns. Which way that trade falls is the whole of
## naval tactics, and `unmaskWeight` is where it is stated.
static func _manoeuvre(world: SimWorld, ship: ShipEntity, contact: ContactPlot.Contact,
		state: State, config: Dictionary) -> void:
	var manoeuvre: Dictionary = config.get("manoeuvre", {}) as Dictionary
	var to_target: Vector2 = contact.estimated_position - ship.position
	var range_m: float = to_target.length()
	if range_m <= 1.0:
		return
	var bearing: float = to_target.angle()
	var tolerance: float = float(manoeuvre.get("rangeToleranceM", 900.0))
	var wanted: float = state.preferred_range_m

	state.posture = Posture.ENGAGE
	state.reason = "holding %.1f km" % (wanted / 1000.0)
	if range_m > wanted + tolerance:
		state.posture = Posture.CLOSE
		state.reason = "closing to %.1f km" % (wanted / 1000.0)

	var options: Array = manoeuvre.get("headingOptionsDeg", [0, 45, 90, 135, 180]) as Array
	var unmask_weight: float = float(manoeuvre.get("unmaskWeight", 0.55))
	var barrels_total: float = maxf(float(ship.operational_main_barrels()), 1.0)

	var best_heading: float = ship.heading
	var best_value: float = -INF
	for option: Variant in options:
		var heading: float = SimUnits.normalise_angle(bearing + deg_to_rad(float(option)))
		# Where this heading takes the range over the next minute, against where she
		# wants it. Steering straight at the enemy closes fastest and masks most of her
		# guns; steering across him opens the broadside and holds the range. The whole
		# of naval tactics is that trade, and `unmaskWeight` is where it is stated.
		var closing: float = cos(deg_to_rad(float(option)))
		var projected: float = maxf(range_m - closing * ship.speed * 60.0, 0.0)
		var range_error: float = absf(projected - wanted) / maxf(wanted, 1.0)

		var relative: float = SimUnits.angle_delta(heading, bearing)
		var bearing_fraction: float = float(
			FireControlSystem.barrels_bearing(ship.turrets, relative)) / barrels_total

		var value: float = -range_error + unmask_weight * bearing_fraction
		if value > best_value:
			best_value = value
			best_heading = heading

	state.ordered_heading = best_heading
	MovementSystem.steer_to_heading(ship, best_heading)
	# Flat out while closing; a little in hand once she is where she wants to be, so
	# she can hold the range in both directions rather than only in one.
	var speed: float = ship.effective_max_speed()
	if state.posture == Posture.ENGAGE:
		speed *= float(manoeuvre.get("engagedSpeedFraction", 0.82))
	MovementSystem.order_speed(ship, speed)


# -- breaking off and evading --------------------------------------------------

static func _should_disengage(ship: ShipEntity, config: Dictionary) -> bool:
	if ship.condition == null:
		return false
	var manoeuvre: Dictionary = config.get("manoeuvre", {}) as Dictionary
	if ship.status == ShipEntity.Status.MISSION_KILL:
		return true
	if ship.condition.integrity < float(manoeuvre.get("disengageIntegrity", 0.45)):
		return true
	return ship.condition.flooded_fraction > float(
		manoeuvre.get("disengageFloodedFraction", 0.25))


## Turn away from the nearest enemy and run. Nothing clever: a ship in this state is
## trying to survive, and her captain has stopped trying to win.
static func _break_off(world: SimWorld, ship: ShipEntity) -> void:
	var away: Vector2 = Vector2.ZERO
	for contact: ContactPlot.Contact in world.contacts.contacts_for(ship.team):
		var offset: Vector2 = ship.position - contact.estimated_position
		var distance: float = maxf(offset.length(), 1.0)
		away += offset / (distance * distance)
	if away.length_squared() <= 0.0:
		return
	ship.target_id = 0
	MovementSystem.steer_to_heading(ship, away.angle())
	MovementSystem.order_speed(ship, ship.effective_max_speed())


## The nearest torpedo running towards this ship, if her lookouts can see the wake.
##
## Read straight off the world's torpedoes rather than through the contact plot, and
## bounded by a wake-spotting range instead: a torpedo track is not a ship and is not
## reported into a fleet's plot — it is seen, from the ship it is running at, or it is
## not seen at all. That is why the first warning was so often the explosion.
static func _nearest_torpedo_threat(world: SimWorld, ship: ShipEntity,
		config: Dictionary) -> Torpedo:
	var torpedo_config: Dictionary = config.get("torpedoes", {}) as Dictionary
	var spotting: float = float(torpedo_config.get("trackSpottingRangeM", 4500.0))
	var best: Torpedo = null
	var best_distance: float = spotting

	for torpedo: Torpedo in world.torpedoes:
		if not torpedo.active or torpedo.team == ship.team:
			continue
		var offset: Vector2 = ship.position - torpedo.position
		var distance: float = offset.length()
		if distance > best_distance:
			continue
		# Only one running towards her. A torpedo already past is not a threat, and
		# turning away from it would be worse than useless.
		if cos(SimUnits.angle_delta(torpedo.heading, offset.angle())) < 0.55:
			continue
		best_distance = distance
		best = torpedo
	return best


## Comb the tracks: turn towards them so she presents her bow rather than her side.
##
## The single most effective thing a captain can do about torpedoes already in the
## water, and it works for a reason that needs no special case anywhere else in the
## simulation — a ship end-on is a target a tenth as wide, and the torpedo's own run
## against her hull is resolved by the same geometry as everything else.
static func _comb(world: SimWorld, ship: ShipEntity, threat: Torpedo,
		config: Dictionary) -> void:
	var torpedo_config: Dictionary = config.get("torpedoes", {}) as Dictionary
	var towards: float = (threat.position - ship.position).angle()
	# Turn the short way onto the track, offset slightly so she is not run down by the
	# torpedo she is combing.
	var offset: float = deg_to_rad(float(torpedo_config.get("combTurnDeg", 20.0)))
	var delta: float = SimUnits.angle_delta(towards, ship.heading)
	var heading: float = SimUnits.normalise_angle(
		towards + (offset if delta >= 0.0 else -offset))
	ship.ai.ordered_heading = heading
	MovementSystem.steer_to_heading(ship, heading)
	MovementSystem.order_speed(ship, ship.effective_max_speed())


# -- torpedoes -----------------------------------------------------------------

## Spend the salvo, or hold it.
##
## A destroyer gets one salvo and the decision of when to spend it is the biggest one
## her captain makes. Firing at extreme range gives the target minutes to turn away,
## and history is full of salvos that missed for exactly that reason — so she holds
## until she is well inside the run, and until her tubes actually bear.
static func _consider_torpedoes(world: SimWorld, ship: ShipEntity,
		contact: ContactPlot.Contact, state: State, config: Dictionary) -> void:
	if ship.torpedo_launchers.is_empty() or state.torpedoes_spent:
		return
	if ship.tubes_loaded() <= 0:
		state.torpedoes_spent = true
		return
	if world.armory == null or ship.spec.torpedo_battery == null:
		return
	var definition: TorpedoDef = world.armory.get_torpedo(ship.spec.torpedo_battery.torpedo_id)
	if definition == null:
		return

	var torpedo_config: Dictionary = config.get("torpedoes", {}) as Dictionary
	var fraction: float = float(torpedo_config.get("firingRangeFraction", 0.55))
	var range_m: float = ship.position.distance_to(contact.estimated_position)
	if range_m > definition.maximum_range() * fraction:
		return

	var target: ShipEntity = world.get_ship(contact.entity_id)
	if target == null or not target.is_afloat():
		return
	# Do the tubes actually bear? Asked of the same solver the player's order uses, so
	# the AI cannot fire a salvo the player could not.
	var bears: bool = false
	for launcher: TorpedoLauncher in ship.torpedo_launchers:
		var solution: TorpedoFireControl.Solution = TorpedoFireControl.solve(
			ship, launcher, target, definition)
		if solution.valid and solution.bears and launcher.can_fire():
			bears = true
			break
	if not bears:
		return

	# Fired directly rather than through the command queue. The queue is for intent
	# arriving from OUTSIDE the simulation, and it is what a replay carries: an AI
	# order recorded there would be re-derived by the AI *and* replayed from the log,
	# and the ship would empty her tubes twice.
	world.fire_torpedoes(ship)
	state.torpedoes_spent = true
	state.reason = "torpedo salvo away at %.1f km" % (range_m / 1000.0)
