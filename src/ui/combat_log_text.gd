class_name CombatLogText
extends RefCounted

## Turning what happened into sentences.
##
## Separated from the panel that shows them because formatting is not a widget: the
## same text serves the on-screen log, a headless dump of a battle and any future
## export, and three versions of it would eventually disagree about what happened.
## It is also the half worth testing, and testing it needs no scene tree.


## One event as a sentence.
##
## Static, and taking the world only to name ships, so the same formatting serves the
## on-screen log, a headless dump and any future export without three versions of it
## drifting apart.
static func describe(world: SimWorld, event: SimEvent) -> String:
	var actor: String = _name(world, event.actor_id)
	var target: String = _name(world, event.target_id)
	var data: Dictionary = event.data

	match event.type:
		&"ship_spawned":
			return "%s joins the action" % str(data.get("name", actor))
		&"salvo_fired":
			return "%s fires %d %s at %s (%.1f km)" % [actor, int(data.get("barrels", 0)),
				str(data.get("gun", "guns")), target, float(data.get("rangeM", 0.0)) / 1000.0]
		&"shell_hit":
			var how: String = "penetrating" if bool(data.get("penetrated", false)) \
				else "without penetrating"
			var burst: String = " and bursts inside" if bool(data.get("detonated", false)) else ""
			return "%s hits %s with a %s, %s%s" % [actor, target,
				str(data.get("shell", "shell")), how, burst]
		&"shell_splash":
			return ""    # far too many to be worth a line each
		&"torpedoes_fired":
			return "%s fires %d torpedoes at %s" % [actor, int(data.get("count", 0)), target]
		&"torpedo_hit":
			return "TORPEDO HIT on %s" % target
		&"ship_destroyed", &"ship_lost":
			return "%s is lost — %s" % [actor, str(data.get("reason", "sunk"))]
		&"mission_kill":
			return "%s can no longer fight — %s" % [actor, str(data.get("reason", ""))]
		&"magazine_detonation":
			return "MAGAZINE DETONATION aboard %s" % actor
		&"fire_started":
			return "Fire aboard %s in %s" % [actor, str(data.get("compartment", "a compartment"))]
		&"flooding":
			return "%s is flooding in %s" % [actor, str(data.get("compartment", ""))]
		&"formation_reformed":
			return "%s takes the guide of %s" % [actor, str(data.get("formation", ""))]
		&"strike_launched":
			return "%s flies off %d %s" % [actor, int(data.get("count", 0)),
				str(data.get("aircraft", "aircraft"))]
		&"strike_cancelled":
			return "%s cannot fly — %s" % [actor, str(data.get("reason", ""))]
		&"bombs_released":
			return "%d %s bomb %s" % [int(data.get("count", 0)),
				str(data.get("aircraft", "aircraft")), target]
		&"aerial_torpedoes_released":
			return "%d %s drop torpedoes on %s" % [int(data.get("count", 0)),
				str(data.get("aircraft", "aircraft")), target]
		&"air_combat":
			return "%s meet %s — %d and %d shot down" % [
				str(data.get("attacker", "fighters")), str(data.get("defender", "aircraft")),
				int(data.get("attackerLost", 0)), int(data.get("defenderLost", 0))]
		&"aircraft_shot_down":
			return "Flak brings down %d %s" % [int(data.get("lost", 0)),
				str(data.get("aircraft", "aircraft"))]
		&"air_group_lost":
			return "%s are lost — %s" % [str(data.get("aircraft", "aircraft")),
				str(data.get("reason", ""))]
		&"air_group_recovered":
			return "%d %s land on %s" % [int(data.get("count", 0)),
				str(data.get("aircraft", "aircraft")), actor]
	# Anything the simulation emits that has no sentence yet still gets a line, because
	# a silent event is one nobody notices has stopped happening.
	return "%s: %s" % [String(event.type), actor]


static func _name(world: SimWorld, entity_id: int) -> String:
	if entity_id == 0 or world == null:
		return "—"
	var ship: ShipEntity = world.get_ship(entity_id)
	return ship.display_name if ship != null else "#%d" % entity_id
