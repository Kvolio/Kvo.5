class_name AirModule
extends RefCounted

## Carrier aviation, as an OPTIONAL module.
##
## Nothing in `src/sim/**` outside this directory mentions an aircraft. The module
## registers itself with the world, is stepped through a duck-typed `step_module()`
## call that names no type, and reaches into the naval core only through the same
## public interfaces anything else uses:
##
##   * aircraft are `SimEntity`s and go in the ordinary spatial index
##   * bombs are ordinary `Projectile`s, resolved by the ordinary trajectory tracer
##     against the ordinary penetration model
##   * aerial torpedoes are ordinary `Torpedo`s, run by the ordinary torpedo system
##   * a carrier's flight deck, hangar and elevators are ordinary compartments and
##     components, wrecked by the ordinary damage chain
##
## `HitResolver` therefore contains no aircraft branch, and cannot acquire one: a bomb
## arrives at a ship as a projectile with a mass, a velocity and a fuze, and there is
## nowhere for the tracer to ask where it came from. The isolation test asserts that the
## whole naval suite passes with this module unregistered, which is the claim that
## matters — the architecture is only worth something if it is checked.
##
## Air combat and anti-aircraft fire are resolved between GROUPS, statistically. That is
## a real abstraction and it is stated rather than hidden: what decided a carrier battle
## was whether the fighters reached the bombers before the bombers reached the ships,
## and no admiral ever manoeuvred an individual Dauntless.

const RNG_STREAM: String = "air"
const AIRCRAFT_DIR: String = "res://data/aircraft"

var config: Dictionary = {}
var aircraft: Dictionary = {}

## Groups in the air, in ascending id order — the same invariant the ship list keeps,
## and for the same reason.
var groups: Array[AirGroup] = []

var _combat_accumulator: float = 0.0
var _aa_accumulator: float = 0.0
var _direction_accumulator: float = 0.0

## Nation-and-role pairs already reported as having no aircraft, so the warning is
## given once rather than three times a minute for the length of a battle.
var _missing_reported: Dictionary = {}

## How often carriers reconsider what to fly. A deck cycle is minutes long; asking every
## tick would be all cost and no effect.
const DIRECTION_INTERVAL_S: float = 20.0


## Build the module and register it with a world.
##
## The world takes it as an opaque object with a `step_module()` method. It cannot name
## this class, and that is the whole design: a build with `src/sim/air/` deleted still
## compiles, and a battle that never calls this function never loads an aircraft.
static func register(world: SimWorld, air_config: Dictionary,
		directory: String = AIRCRAFT_DIR) -> AirModule:
	var module: AirModule = AirModule.new()
	module.config = air_config
	module.aircraft = AircraftDef.load_all(directory)
	world.register_module(module)
	return module


func get_aircraft(aircraft_id: String) -> AircraftDef:
	return aircraft.get(aircraft_id) as AircraftDef


func aircraft_ids() -> Array[String]:
	return Serializer.sorted_keys(aircraft)


# -- launching -----------------------------------------------------------------

## What this carrier can still do. A straight read of her own damaged structure.
func capability(world: SimWorld, carrier: ShipEntity) -> CarrierOperations.Capability:
	return CarrierOperations.assess(carrier, world.structure_for(carrier),
		carrier.structure_state, config)


## Range a strike on deck and send it off.
##
## Returns null where she cannot fly: no serviceable elevator, a wrecked deck, a fire
## in the hangar, or too much list. Every one of those is read from damage the naval
## core did without knowing it was stopping a strike.
func launch(world: SimWorld, carrier: ShipEntity, aircraft_id: String, count: int,
		target_id: int = 0) -> AirGroup:
	var definition: AircraftDef = get_aircraft(aircraft_id)
	if definition == null or carrier == null:
		return null
	var state: CarrierOperations.Capability = capability(world, carrier)
	if not state.can_launch:
		world.events.emit_event(&"strike_cancelled", carrier.id, 0,
			SimEvent.Severity.NOTABLE, {"reason": state.reason})
		return null

	var spot: int = CarrierOperations.deck_spot(state, config)
	var flying: int = clampi(count, 1, maxi(spot, 1))
	var group: AirGroup = AirGroup.create(
		world.ids.allocate(), definition, carrier.team, flying, carrier.position, carrier.id)
	group.target_id = target_id
	group.mission = AirGroup.Mission.OUTBOUND if target_id != 0 else AirGroup.Mission.PATROL
	group.heading = carrier.heading
	groups.append(group)
	world.spatial.insert(group.id, group.position, group.spatial_radius(),
		SpatialIndex.Layer.AIRCRAFT)
	world.events.emit_event(&"strike_launched", carrier.id, target_id,
		SimEvent.Severity.NOTABLE, {
			"aircraft": definition.display_name, "count": flying,
			"role": definition.role, "deckCondition": state.deck_condition,
		})
	return group


# -- the tick ------------------------------------------------------------------

## Called by the world through a duck-typed hook. The world does not know what this is.
func step_module(world: SimWorld, dt: float) -> void:
	_direct_carriers(world, dt)
	if groups.is_empty():
		return
	_fly(world, dt)

	_combat_accumulator += dt
	var combat: Dictionary = config.get("combat", {}) as Dictionary
	var combat_round: float = maxf(float(combat.get("roundSeconds", 20.0)), dt)
	while _combat_accumulator >= combat_round:
		_combat_accumulator -= combat_round
		_resolve_air_combat(world)

	_aa_accumulator += dt
	var anti_air: Dictionary = config.get("antiAir", {}) as Dictionary
	var aa_round: float = maxf(float(anti_air.get("roundSeconds", 5.0)), dt)
	while _aa_accumulator >= aa_round:
		_aa_accumulator -= aa_round
		_resolve_anti_air(world)

	_retire(world)


## Carriers decide what to fly.
##
## Reads the team's contact plot, exactly as the surface AI does and for the same
## reason: a carrier that could read `world.ships` would launch at ships nobody had
## found, and finding the enemy first is the whole of carrier warfare.
##
## A carrier keeps fighters up and sends one strike at a time. Sending one strike at a
## time is not a simplification for its own sake — a deck can only range so many
## aircraft, so a bigger effort goes in waves, which is exactly why a carrier caught
## between waves was so vulnerable.
func _direct_carriers(world: SimWorld, dt: float) -> void:
	_direction_accumulator += dt
	if _direction_accumulator < DIRECTION_INTERVAL_S:
		return
	_direction_accumulator = 0.0
	if world.contacts == null:
		return

	for carrier: ShipEntity in world.ships:
		if not carrier.spec.is_carrier() or not carrier.ai_controlled or not carrier.is_afloat():
			continue
		if not capability(world, carrier).can_launch:
			continue

		# Fighters over the fleet first. A strike sent out with no patrol behind it is
		# how a carrier loses her deck while her own aircraft are away.
		if _airborne(carrier.id, AircraftDef.Role.FIGHTER) == null:
			var fighter: AircraftDef = _pick(carrier.spec.nation, AircraftDef.Role.FIGHTER)
			if fighter != null:
				launch(world, carrier, fighter.aircraft_id, fighter.group_size, 0)
				continue

		if _strike_airborne(carrier.id):
			continue
		var target: ContactPlot.Contact = _strike_target(world, carrier)
		if target == null:
			continue
		# Torpedo bombers against a ship worth a torpedo; dive bombers otherwise.
		var role: int = AircraftDef.Role.TORPEDO_BOMBER
		if target.ship_type == "destroyer":
			role = AircraftDef.Role.DIVE_BOMBER
		var strike: AircraftDef = _pick(carrier.spec.nation, role)
		if strike == null:
			strike = _pick(carrier.spec.nation, AircraftDef.Role.DIVE_BOMBER)
		if strike != null:
			launch(world, carrier, strike.aircraft_id, strike.group_size, target.entity_id)


## The best thing this carrier's team has found, within reach of her aircraft.
func _strike_target(world: SimWorld, carrier: ShipEntity) -> ContactPlot.Contact:
	var plot_config: Dictionary = (world.detection_config.get("plot", {}) as Dictionary)
	var firm: float = float(plot_config.get("firmSeconds", 12.0))
	var best: ContactPlot.Contact = null
	var best_score: float = 0.0
	for contact: ContactPlot.Contact in world.contacts.contacts_for(carrier.team):
		if not contact.is_firm(firm) or not contact.classified:
			continue
		var distance: float = contact.estimated_position.distance_to(carrier.position)
		# A carrier is the target every other carrier is looking for, and she is far
		# easier to sink than a battleship. That is why finding one mattered so much.
		var value: float = 2.0 if contact.ship_type == "carrier" else 1.0
		var score: float = value / (1.0 + distance / 100000.0)
		if score > best_score:
			best_score = score
			best = contact
	if best == null:
		return null
	# Only worth sending if they can get there and back. Matched case-insensitively,
	# like _pick(): the same "USA" against "usa" mismatch lives here too, and here it
	# would have been even quieter — a reach of zero simply means no target is ever in
	# range and no strike is ever sent.
	var nation: String = carrier.spec.nation.to_lower()
	var reach: float = 0.0
	for aircraft_id: String in aircraft_ids():
		var definition: AircraftDef = aircraft[aircraft_id]
		if definition.is_strike() and definition.nation.to_lower() == nation:
			reach = maxf(reach, definition.combat_radius_m)
	return best if best.estimated_position.distance_to(carrier.position) <= reach else null


## The best aircraft of a role this nation flies. Data-driven: adding an aircraft file
## is adding an aircraft, and the newest of a nation's types is the one she flies.
##
## Matched case-insensitively, and loudly. The ship files write "USA" and the aircraft
## files wrote "usa", so the first version of this matched nothing and every carrier in
## the game quietly declined to fly — no error, no empty deck, just no aircraft ever.
## A data mismatch that produces silence is worse than one that produces a crash, so a
## nation with no aircraft of a role now says so once.
func _pick(nation: String, role: int) -> AircraftDef:
	var wanted: String = nation.to_lower()
	var best: AircraftDef = null
	for aircraft_id: String in aircraft_ids():
		var definition: AircraftDef = aircraft[aircraft_id]
		if definition.nation.to_lower() != wanted or definition.role != role:
			continue
		if best == null or definition.year > best.year:
			best = definition
	if best == null:
		var key: String = "%s/%d" % [wanted, role]
		if not _missing_reported.has(key):
			_missing_reported[key] = true
			push_warning("AirModule: no aircraft of role %d for nation '%s' — her "
				% [role, nation] + "carriers will not be able to fly that mission")
	return best


func _airborne(home_id: int, role: int) -> AirGroup:
	for group: AirGroup in groups:
		if group.home_id == home_id and group.is_alive() and group.definition.role == role:
			return group
	return null


func _strike_airborne(home_id: int) -> bool:
	for group: AirGroup in groups:
		if group.home_id == home_id and group.is_alive() and group.definition.is_strike():
			return true
	return false


## Move every group, and let each mission run its course.
func _fly(world: SimWorld, dt: float) -> void:
	for group: AirGroup in groups:
		if not group.is_alive():
			continue
		group.endurance_s -= dt
		if group.endurance_s <= 0.0 and group.mission != AirGroup.Mission.LANDING:
			# Out of fuel a long way from anywhere. A common and unglamorous way for
			# carrier aircraft to be lost, and it cost the Japanese more than fighters
			# did at the Philippine Sea.
			world.events.emit_event(&"air_group_lost", group.id, 0,
				SimEvent.Severity.NOTABLE,
				{"aircraft": group.definition.display_name, "count": group.count,
				 "reason": "fuel exhausted"})
			group.lose(group.count)
			continue

		match group.mission:
			AirGroup.Mission.OUTBOUND:
				_fly_to_target(world, group, dt)
			AirGroup.Mission.ATTACKING:
				_attack(world, group, dt)
			AirGroup.Mission.PATROL:
				_patrol(world, group, dt)
			AirGroup.Mission.RETURNING, AirGroup.Mission.LANDING:
				_fly_home(world, group, dt)
		world.spatial.update(group.id, group.position, group.spatial_radius())


func _advance(group: AirGroup, towards: Vector2, dt: float, speed: float) -> float:
	var offset: Vector2 = towards - group.position
	var distance: float = offset.length()
	if distance <= 0.001:
		return 0.0
	group.heading = offset.angle()
	group.speed_ms = speed
	group.position += offset / distance * minf(speed * dt, distance)
	return distance


func _fly_to_target(world: SimWorld, group: AirGroup, dt: float) -> void:
	var target: ShipEntity = world.get_ship(group.target_id)
	if target == null or not target.is_afloat():
		group.mission = AirGroup.Mission.RETURNING
		return
	var distance: float = _advance(group, target.position, dt, group.definition.cruise_speed_ms)
	if distance <= group.definition.release_range_m * 3.0:
		group.mission = AirGroup.Mission.ATTACKING
		group.attack_seconds = 0.0
		# Dive bombers push over from height; torpedo aircraft go down to the water.
		group.altitude_m = group.definition.release_altitude_m


func _patrol(world: SimWorld, group: AirGroup, dt: float) -> void:
	var home: ShipEntity = world.get_ship(group.home_id)
	if home == null or not home.is_afloat():
		group.mission = AirGroup.Mission.RETURNING
		return
	# A slow orbit over the fleet. Combat air patrol is not going anywhere; it is
	# waiting to be pointed at something, which _resolve_air_combat does.
	group.heading = SimUnits.normalise_angle(group.heading + dt * 0.05)
	group.position = home.position + Vector2(cos(group.heading), sin(group.heading)) * 6000.0
	group.speed_ms = group.definition.cruise_speed_ms


func _fly_home(world: SimWorld, group: AirGroup, dt: float) -> void:
	var home: ShipEntity = world.get_ship(group.home_id)
	if home == null or not home.is_afloat():
		home = _nearest_friendly_carrier(world, group)
	if home == null:
		# Nowhere to land. She ditches when her fuel runs out, and the tick above will
		# see to it — there is no need for a rule that says an aircraft with no deck
		# is lost, because it already follows.
		group.mission = AirGroup.Mission.RETURNING
		return
	group.home_id = home.id
	var distance: float = _advance(group, home.position, dt, group.definition.cruise_speed_ms)
	if distance > 2000.0:
		return

	group.mission = AirGroup.Mission.LANDING
	var state: CarrierOperations.Capability = capability(world, home)
	if not state.can_recover:
		# Her deck is gone and she cannot take them back. They circle until the fuel
		# runs out, which is exactly what happened to Hiryu's and Soryu's aircraft.
		return
	world.events.emit_event(&"air_group_recovered", home.id, group.id,
		SimEvent.Severity.INFO,
		{"aircraft": group.definition.display_name, "count": group.count})
	group.mission = AirGroup.Mission.GONE


func _nearest_friendly_carrier(world: SimWorld, group: AirGroup) -> ShipEntity:
	var best: ShipEntity = null
	var best_distance: float = INF
	for ship: ShipEntity in world.ships:
		if ship.team != group.team or not ship.spec.is_carrier() or not ship.is_afloat():
			continue
		var distance: float = ship.position.distance_to(group.position)
		if distance < best_distance:
			best_distance = distance
			best = ship
	return best


# -- the attack ----------------------------------------------------------------

## Press home the attack, and put the ordnance in the water or in the ship.
##
## The bombs and torpedoes created here are ordinary ones. Once released they belong to
## the naval core entirely: the tracer decides what a bomb goes through and the torpedo
## system runs the torpedo, and neither has any way of asking whether an aircraft was
## involved.
func _attack(world: SimWorld, group: AirGroup, dt: float) -> void:
	var target: ShipEntity = world.get_ship(group.target_id)
	if target == null or not target.is_afloat():
		group.mission = AirGroup.Mission.RETURNING
		group.armed = false
		return

	group.attack_seconds += dt
	var distance: float = _advance(group, target.position, dt, group.definition.max_speed_ms)
	if distance > group.definition.release_range_m:
		return

	var rng: DeterministicRng = world.rng.stream(RNG_STREAM)
	if group.definition.carries_torpedo():
		_drop_torpedoes(world, group, target, rng)
	elif group.definition.carries_bomb():
		_drop_bombs(world, group, target, rng)

	group.armed = false
	group.mission = AirGroup.Mission.RETURNING


func _drop_bombs(world: SimWorld, group: AirGroup, target: ShipEntity,
		rng: DeterministicRng) -> void:
	if world.armory == null:
		return
	var shell: ShellDef = world.armory.get_shell(group.definition.bomb_id)
	if shell == null:
		return
	var attack: Dictionary = config.get("attack", {}) as Dictionary
	var steep: bool = group.definition.role == AircraftDef.Role.DIVE_BOMBER
	var accuracy: float = float(attack.get("diveAccuracyFraction", 0.06)) if steep \
		else float(attack.get("levelAccuracyFraction", 0.14))
	var spread: float = accuracy * group.definition.release_altitude_m

	# A bomb has no muzzle velocity. What it arrives with is what the dive and the fall
	# gave it, which is why release altitude decides what it can penetrate — and why a
	# dive bomber that pulls out high does far less than one that presses in.
	var dive: float = group.definition.dive_angle_rad
	var release_speed: float = group.definition.release_speed_ms
	var fall: float = sqrt(maxf(2.0 * SimUnits.GRAVITY * group.definition.release_altitude_m, 0.0))
	var speed: float = sqrt(release_speed * release_speed + fall * fall)

	for _i: int in group.count:
		var aim: Vector2 = target.position + Vector2(
			rng.next_gaussian() * spread, rng.next_gaussian() * spread)
		var bearing: float = (aim - group.position).angle()
		var origin: Vector3 = Vector3(
			aim.x - cos(bearing) * group.definition.release_altitude_m / tan(dive),
			aim.y - sin(bearing) * group.definition.release_altitude_m / tan(dive),
			group.definition.release_altitude_m)
		var velocity: Vector3 = Vector3(
			cos(bearing) * cos(dive), sin(bearing) * cos(dive), -sin(dive)) * speed
		world.spawn_projectile(shell, null, origin, velocity,
			group.id, target.id, group.team, &"bombs")

	world.events.emit_event(&"bombs_released", group.id, target.id,
		SimEvent.Severity.NOTABLE, {
			"aircraft": group.definition.display_name, "count": group.count,
			"bomb": shell.display_name,
			"releaseAltitudeM": group.definition.release_altitude_m,
		})


func _drop_torpedoes(world: SimWorld, group: AirGroup, target: ShipEntity,
		rng: DeterministicRng) -> void:
	if world.armory == null:
		return
	var definition: TorpedoDef = world.armory.get_torpedo(group.definition.torpedo_id)
	if definition == null:
		return
	var attack: Dictionary = config.get("attack", {}) as Dictionary
	var aim_sigma: float = float(attack.get("torpedoAimSigmaRad", 0.045))
	var spread: float = float(attack.get("torpedoSpreadRad", 0.03))
	var setting: TorpedoDef.Setting = definition.setting_for_range(
		group.position.distance_to(target.position))

	# Aim off for the target's motion. An aircrew's estimate of a ship's speed and
	# course is made in seconds while being shot at, so it is a rough one — which is
	# why torpedo attacks were pressed to short range and delivered from several
	# bearings at once.
	var flight: float = group.position.distance_to(target.position) / maxf(setting.speed_ms, 1.0)
	var lead: Vector2 = target.position + target.velocity() * flight
	var base: float = (lead - group.position).angle()

	for i: int in group.count:
		var offset: float = spread * (float(i) - float(group.count - 1) * 0.5)
		var heading: float = base + offset + rng.next_gaussian() * aim_sigma
		world.spawn_torpedo(definition, group.position, heading, setting.speed_ms,
			group.id, target.id, group.team)

	world.events.emit_event(&"aerial_torpedoes_released", group.id, target.id,
		SimEvent.Severity.CRITICAL, {
			"aircraft": group.definition.display_name, "count": group.count,
			"torpedo": definition.display_name,
		})


# -- air combat ----------------------------------------------------------------

## Fighters against everything else.
##
## Scored between groups rather than between aircraft: how much fire each side can
## bring, how well each side can turn, and how much punishment each side can take.
## A loaded bomber fights badly, which is why bombers jettisoned when jumped.
func _resolve_air_combat(world: SimWorld) -> void:
	var combat: Dictionary = config.get("combat", {}) as Dictionary
	var reach: float = float(combat.get("engagementRangeM", 4000.0))
	var rng: DeterministicRng = world.rng.stream(RNG_STREAM)

	for attacker: AirGroup in groups:
		if not attacker.is_alive() or attacker.definition.role != AircraftDef.Role.FIGHTER:
			continue
		var victim: AirGroup = _interception_target(attacker, reach)
		if victim == null:
			continue
		var attacker_losses: int = _combat_losses(victim, attacker, combat, rng)
		var victim_losses: int = _combat_losses(attacker, victim, combat, rng)
		if attacker_losses == 0 and victim_losses == 0:
			continue
		attacker.lose(attacker_losses)
		victim.lose(victim_losses)
		world.events.emit_event(&"air_combat", attacker.id, victim.id,
			SimEvent.Severity.NOTABLE, {
				"attacker": attacker.definition.display_name,
				"defender": victim.definition.display_name,
				"attackerLost": attacker_losses, "defenderLost": victim_losses,
				"attackerLeft": attacker.count, "defenderLeft": victim.count,
			})


## Who this fighter group goes for. Strike aircraft first, and the nearest of those:
## the whole point of an interception is to reach the bombers before they reach the
## ships, and an escort's job is to make that cost something.
func _interception_target(fighter: AirGroup, reach: float) -> AirGroup:
	var best: AirGroup = null
	var best_score: float = 0.0
	for other: AirGroup in groups:
		if other.team == fighter.team or not other.is_alive():
			continue
		var distance: float = other.position.distance_to(fighter.position)
		if distance > reach:
			continue
		var score: float = (2.0 if other.is_strike() else 1.0) / (1.0 + distance / reach)
		if score > best_score:
			best_score = score
			best = other
	return best


## How many of `victim` the `shooter` group brings down in one round.
static func _combat_losses(shooter: AirGroup, victim: AirGroup, combat: Dictionary,
		rng: DeterministicRng) -> int:
	var base: float = float(combat.get("baseKillsPerRound", 0.9))
	var strength: float = float(shooter.count) / 9.0
	var agility: float = pow(
		maxf(shooter.definition.agility, 0.01) / maxf(victim.definition.agility, 0.01),
		float(combat.get("agilityWeight", 1.6)))
	var toughness: float = pow(
		maxf(1.0 - victim.definition.toughness, 0.05),
		float(combat.get("toughnessWeight", 1.4)) * 0.5) * 2.0
	var expected: float = base * strength * agility * toughness

	# Guns matter, but not linearly: six half-inch guns are not three times two.
	expected *= sqrt(maxf(float(shooter.definition.guns), 1.0) / 4.0)
	if shooter.is_strike():
		expected *= float(combat.get("bomberPenalty", 0.35))

	expected = clampf(expected, 0.0, float(victim.count))
	# Whole aircraft: the integer part, plus the fraction as a chance. Without this a
	# small expected value would round to nothing and a weak group could never score.
	var whole: int = int(floor(expected))
	if rng.next_float() < expected - float(whole):
		whole += 1
	return mini(whole, victim.count)


# -- anti-aircraft fire --------------------------------------------------------

## The fleet shooting back.
##
## Every barrel that bears, from every ship in range, against every group in range.
## What makes a torpedo attack so much more expensive than a dive-bombing attack falls
## straight out of it: the torpedo group has to fly low, straight and slow towards the
## ship for the better part of a minute, and the multiplier for being in the attack run
## is applied for every second of it.
func _resolve_anti_air(world: SimWorld) -> void:
	var anti_air: Dictionary = config.get("antiAir", {}) as Dictionary
	var ranges: Dictionary = anti_air.get("effectiveRangeM", {}) as Dictionary
	var rates: Dictionary = anti_air.get("killsPerBarrelPerRound", {}) as Dictionary
	var rng: DeterministicRng = world.rng.stream(RNG_STREAM)

	for group: AirGroup in groups:
		if not group.is_alive():
			continue
		var expected: float = 0.0
		for ship: ShipEntity in world.ships:
			if ship.team == group.team or not ship.is_afloat():
				continue
			var distance: float = ship.position.distance_to(group.position)
			if distance > float(ranges.get("heavy", 11000.0)):
				continue
			expected += _ship_anti_air(ship, group, distance, anti_air, ranges, rates)
		if expected <= 0.0:
			continue

		var whole: int = int(floor(expected))
		if rng.next_float() < expected - float(whole):
			whole += 1
		var lost: int = group.lose(whole)
		if lost > 0:
			world.events.emit_event(&"aircraft_shot_down", 0, group.id,
				SimEvent.Severity.NOTABLE, {
					"aircraft": group.definition.display_name,
					"lost": lost, "left": group.count, "cause": "anti-aircraft fire",
				})


## One ship's expected kills against one group this round.
static func _ship_anti_air(ship: ShipEntity, group: AirGroup, distance: float,
		anti_air: Dictionary, ranges: Dictionary, rates: Dictionary) -> float:
	var expected: float = 0.0

	# Heavy AA is the dual-purpose secondary battery. It reaches furthest and hits
	# least, and from 1943 the proximity fuze roughly tripled what it achieved.
	if ship.spec.has_secondary_battery() and distance <= float(ranges.get("heavy", 11000.0)):
		var barrels: float = float(ship.spec.secondary_battery.total_barrels())
		var heavy: float = barrels * float(rates.get("heavy", 0.0022))
		if ship.spec.year >= int(anti_air.get("proximityFuzeFrom", 1943)):
			heavy *= float(anti_air.get("proximityFuzeFactor", 2.6))
		expected += heavy

	# The light and medium outfit, by calibre. The 40 mm band in the middle did most of
	# the killing; the 20 mm guns are last-ditch and often shot at aircraft that had
	# already released.
	for entry: Variant in ship.spec.anti_air:
		var mount: Dictionary = entry as Dictionary
		var calibre: float = float(mount.get("calibreMm", 20.0))
		var count: float = float(mount.get("count", 0))
		var band: String = "light" if calibre < 25.0 else "medium"
		if distance <= float(ranges.get(band, 2000.0)):
			expected += count * float(rates.get(band, 0.003))

	# Damage tells: a ship whose upperworks are wrecked has lost the guns that were on
	# them, and her crew with them.
	if ship.condition != null:
		expected *= clampf(ship.condition.integrity, 0.0, 1.0)
	expected *= ship.structure_state.crew_fraction() if ship.structure_state != null else 1.0

	# A group in its attack run is flying predictably and cannot dodge.
	if group.mission == AirGroup.Mission.ATTACKING:
		expected *= float(anti_air.get("attackRunMultiplier", 2.4))
	else:
		expected *= 1.0 - float(anti_air.get("agilityEvasion", 0.45)) * group.definition.agility
	return expected * float(group.count) / 9.0


# -- housekeeping --------------------------------------------------------------

func _retire(world: SimWorld) -> void:
	var survivors: Array[AirGroup] = []
	for group: AirGroup in groups:
		if group.is_alive():
			survivors.append(group)
		else:
			world.spatial.remove(group.id)
	groups = survivors


func hash_into(hasher: StateHasher) -> void:
	for group: AirGroup in groups:
		group.hash_into(hasher)


func serialize() -> Array:
	var out: Array = []
	for group: AirGroup in groups:
		out.append(group.serialize())
	return out
