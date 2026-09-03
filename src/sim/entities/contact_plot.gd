class_name ContactPlot
extends RefCounted

## What each side knows is out there — which is not the same as what is out there.
##
## Held per TEAM rather than per ship, because that is what a flagship's plot was:
## every lookout and every set in the formation reporting into one picture, and the
## whole formation manoeuvring on it. It is also the thing that makes the AI honest.
## An AI that reads `world.ships` is playing with the lid off; an AI that reads this
## can be surprised, can lose a target in the dark, and can shoot at a contact that
## turned away four minutes ago and is no longer there.
##
## A contact is carried forward on its last known course after it is lost, which is
## exactly the interval in which the plot is most confidently wrong.

enum Method {
	NONE,
	VISUAL,     ## seen, within the horizon and the visibility
	RADAR,      ## held on a set — works at night, and that is the whole point
	GUN_FLASH,  ## she fired, and the flash carried past the horizon
	FIRE_GLOW,  ## she is burning
}


class Contact extends RefCounted:
	var entity_id: int = 0
	var team: int = 0                       ## the team HOLDING the contact
	var estimated_position: Vector2 = Vector2.ZERO
	var estimated_course: float = 0.0
	var estimated_speed: float = 0.0
	var method: int = Method.NONE
	var first_seen_tick: int = 0
	var last_seen_tick: int = 0
	var held_seconds: float = 0.0
	var stale_seconds: float = 0.0
	var classified: bool = false
	var ship_type: String = ""

	## Held long enough, and well enough, to open fire on.
	func is_firm(firm_seconds: float) -> bool:
		return held_seconds >= firm_seconds and method != Method.GUN_FLASH

	## Currently being observed, as against carried forward on dead reckoning.
	func is_live() -> bool:
		return stale_seconds <= 0.0

	func serialize() -> Dictionary:
		return {
			"entityId": entity_id,
			"team": team,
			"position": Serializer.vec2_to_array(estimated_position),
			"course": estimated_course,
			"speed": estimated_speed,
			"method": method,
			"heldSeconds": held_seconds,
			"staleSeconds": stale_seconds,
			"classified": classified,
			"shipType": ship_type,
		}


## team -> { entity_id -> Contact }. Lookup only; every iteration that can decide an
## outcome goes through a sorted key array, as the determinism rules require.
var _by_team: Dictionary = {}


func clear() -> void:
	_by_team.clear()


## The contact this team holds on this entity, or null.
func contact(team: int, entity_id: int) -> Contact:
	var held: Variant = _by_team.get(team)
	if held == null:
		return null
	return (held as Dictionary).get(entity_id) as Contact


func has_contact(team: int, entity_id: int) -> bool:
	return contact(team, entity_id) != null


## Everything this team holds, in ascending entity-id order.
func contacts_for(team: int) -> Array[Contact]:
	var out: Array[Contact] = []
	var held: Variant = _by_team.get(team)
	if held == null:
		return out
	var dictionary: Dictionary = held as Dictionary
	for key: int in Serializer.sorted_int_keys(dictionary):
		out.append(dictionary[key] as Contact)
	return out


## Record or refresh an observation.
func sight(team: int, entity: SimEntity, method: int, estimated_position: Vector2,
		tick: int) -> Contact:
	var held: Dictionary = _by_team.get(team, {}) as Dictionary
	var existing: Contact = held.get(entity.id) as Contact
	if existing == null:
		existing = Contact.new()
		existing.entity_id = entity.id
		existing.team = team
		existing.first_seen_tick = tick
		existing.estimated_position = estimated_position
		existing.estimated_course = entity.velocity().angle()
		existing.estimated_speed = entity.velocity().length()
		held[entity.id] = existing
		_by_team[team] = held

	existing.method = method
	existing.last_seen_tick = tick
	existing.stale_seconds = 0.0
	existing.estimated_position = estimated_position
	return existing


## Move the picture on by `dt`: hold what is still being seen, dead-reckon what is
## not, and forget what has been stale too long.
##
## Dead reckoning is not a nicety. A contact carried forward on a course the target has
## since left is the most dangerous kind of information there is, and a plot that
## simply dropped a contact the moment it was lost would never produce that mistake.
func age(dt: float, forget_seconds: float, seen_this_pass: Dictionary) -> void:
	for team: int in Serializer.sorted_int_keys(_by_team):
		var held: Dictionary = _by_team[team] as Dictionary
		var drop: Array[int] = []
		for entity_id: int in Serializer.sorted_int_keys(held):
			var entry: Contact = held[entity_id] as Contact
			var key: int = _pair_key(team, entity_id)
			if seen_this_pass.has(key):
				entry.held_seconds += dt
				continue
			entry.stale_seconds += dt
			entry.held_seconds = 0.0
			if entry.stale_seconds >= forget_seconds:
				drop.append(entity_id)
				continue
			entry.estimated_position += Vector2(
				cos(entry.estimated_course), sin(entry.estimated_course)) * entry.estimated_speed * dt
		for entity_id: int in drop:
			held.erase(entity_id)


static func _pair_key(team: int, entity_id: int) -> int:
	return team * 1000000 + entity_id


## Key for the seen-this-pass set the detection system fills in.
static func pass_key(team: int, entity_id: int) -> int:
	return _pair_key(team, entity_id)


## Put one contact back from a snapshot. Restoring the plot matters as much as
## restoring the ships: a battle whose plots were rebuilt from scratch would have both
## sides re-finding an enemy they had been tracking for ten minutes.
func restore(row: Dictionary) -> void:
	var contact: Contact = Contact.new()
	contact.entity_id = int(row.get("entityId", 0))
	contact.team = int(row.get("team", 0))
	contact.estimated_position = Serializer.array_to_vec2(row.get("position"))
	contact.estimated_course = float(row.get("course", 0.0))
	contact.estimated_speed = float(row.get("speed", 0.0))
	contact.method = int(row.get("method", Method.NONE))
	contact.held_seconds = float(row.get("heldSeconds", 0.0))
	contact.stale_seconds = float(row.get("staleSeconds", 0.0))
	contact.classified = bool(row.get("classified", false))
	contact.ship_type = str(row.get("shipType", ""))
	var held: Dictionary = _by_team.get(contact.team, {}) as Dictionary
	held[contact.entity_id] = contact
	_by_team[contact.team] = held


func hash_into(hasher: StateHasher) -> void:
	for team: int in Serializer.sorted_int_keys(_by_team):
		var held: Dictionary = _by_team[team] as Dictionary
		for entity_id: int in Serializer.sorted_int_keys(held):
			var entry: Contact = held[entity_id] as Contact
			hasher.write_int(team)
			hasher.write_int(entity_id)
			hasher.write_vec2(entry.estimated_position)
			hasher.write_int(entry.method)


func serialize() -> Array:
	var out: Array = []
	for team: int in Serializer.sorted_int_keys(_by_team):
		var held: Dictionary = _by_team[team] as Dictionary
		for entity_id: int in Serializer.sorted_int_keys(held):
			out.append((held[entity_id] as Contact).serialize())
	return out
