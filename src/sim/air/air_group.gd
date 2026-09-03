class_name AirGroup
extends SimEntity

## A flight of aircraft in the air, flown as one.
##
## The entity is the GROUP, not the aeroplane. A carrier strike is six or eight groups,
## not ninety separate objects, which keeps the entity count sane and — more to the
## point — matches how carrier air was actually controlled: squadrons launched, flew,
## attacked and were shot at as units, and no admiral ever manoeuvred an individual
## Dauntless. Losses come off `count`; a group whose count reaches zero is gone.
##
## A SimEntity, so the spatial index, the detection plot and anything else that works
## on entities handles it without knowing what it is.

enum Mission {
	FORMING,    ## on deck or joining up overhead
	OUTBOUND,   ## on the way to the target
	ATTACKING,  ## in the attack, and at its most vulnerable
	RETURNING,  ## on the way home
	LANDING,    ## in the circuit
	PATROL,     ## combat air patrol over the fleet
	GONE,       ## shot down, ditched, or landed on
}

var definition: AircraftDef = null

## Aircraft still flying. This IS the group's strength: AA fire and fighters take
## aircraft off it, and a group's weight of attack is proportional to what is left.
var count: int = 0

var altitude_m: float = 0.0
var heading: float = 0.0
var speed_ms: float = 0.0
var mission: int = Mission.FORMING

## The carrier she flew from, and the ship she is going for.
var home_id: int = 0
var target_id: int = 0

## Endurance, in seconds of flying left. A group that runs out ditches, which is a real
## and common way for carrier aircraft to be lost — the Marianas turkey shoot cost the
## Japanese more aircraft to fuel exhaustion and deck crashes than to fighters.
var endurance_s: float = 0.0

## Ordnance still aboard. A group that has attacked is no longer a threat, and that
## distinction matters to the AA gunners and the fighters both.
var armed: bool = true

## Seconds spent in the attack run so far, so a torpedo group's long straight approach
## really is the most dangerous part of its flight.
var attack_seconds: float = 0.0


static func create(entity_id: int, aircraft: AircraftDef, p_team: int, p_count: int,
		origin: Vector2, home: int) -> AirGroup:
	var group: AirGroup = AirGroup.new()
	group.id = entity_id
	group.team = p_team
	group.definition = aircraft
	group.count = p_count
	group.position = origin
	group.home_id = home
	group.display_name = "%s x%d" % [aircraft.display_name, p_count]
	group.speed_ms = aircraft.cruise_speed_ms
	group.altitude_m = aircraft.ceiling_m * 0.4
	group.armed = aircraft.is_strike()
	# Endurance from the combat radius: out and back at cruise, with a little in hand.
	group.endurance_s = aircraft.combat_radius_m * 2.2 / maxf(aircraft.cruise_speed_ms, 1.0)
	return group


func is_alive() -> bool:
	return count > 0 and mission != Mission.GONE


func velocity() -> Vector2:
	return Vector2(cos(heading), sin(heading)) * speed_ms


func spatial_layer() -> int:
	return SpatialIndex.Layer.AIRCRAFT


func spatial_radius() -> float:
	return 200.0


## Aircraft in the air are seen a very long way off, because height is what sets a
## horizon and they have a great deal of it. A group at 4000 m is over the horizon of a
## ship's masthead at some 250 km, which is why radar picket destroyers existed.
func detection_signature() -> Detectable.Signature:
	var signature: Detectable.Signature = Detectable.Signature.new()
	signature.height_m = altitude_m
	signature.silhouette_m2 = float(count) * 40.0
	signature.radar_area_m2 = float(count) * 60.0
	return signature


## Take losses. Returns how many were shot down.
func lose(aircraft: int) -> int:
	var taken: int = mini(maxi(aircraft, 0), count)
	count -= taken
	if count <= 0:
		mission = Mission.GONE
	display_name = "%s x%d" % [definition.display_name, count]
	return taken


func is_strike() -> bool:
	return definition != null and definition.is_strike() and armed


func hash_into(hasher: StateHasher) -> void:
	hasher.write_int(id)
	hasher.write_int(count)
	hasher.write_vec2(position)
	hasher.write_float(altitude_m)
	hasher.write_int(mission)


func serialize() -> Dictionary:
	return {
		"id": id, "team": team, "aircraft": definition.aircraft_id if definition else "",
		"count": count, "position": Serializer.vec2_to_array(position),
		"altitudeM": altitude_m, "heading": heading, "mission": mission,
		"homeId": home_id, "targetId": target_id, "armed": armed,
		"enduranceS": endurance_s,
	}
