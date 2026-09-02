extends Node2D

## Shells in flight, splashes, and hit flashes.
##
## Reads the simulation; never writes to it. Projectiles are drawn straight from the
## world's live list, and transient effects are spawned from the simulation's event
## stream — the same events the combat log reads, so what the player sees and what the
## log records cannot disagree.
##
## Effect lifetimes are measured in SIMULATED seconds rather than real ones. At ten
## times speed a splash that faded over two real seconds would hang in the water for
## twenty simulated ones and turn a fleet action into a field of foam.

const SPLASH_LIFE_S: float = 3.0
const HIT_LIFE_S: float = 1.2
const TRACER_LENGTH_S: float = 0.35
const MIN_TRACER_PIXELS: float = 3.0

## Splash radius as a multiple of calibre. A 16-inch shell throws a column of water
## tens of metres across; a 5-inch one barely marks the sea.
const SPLASH_RADIUS_PER_CALIBRE: float = 90.0


class Effect extends RefCounted:
	var position: Vector2 = Vector2.ZERO
	var life: float = 0.0
	var max_life: float = 1.0
	var radius: float = 10.0
	var colour: Color = Color.WHITE
	var is_hit: bool = false


var world: SimWorld = null

var _effects: Array[Effect] = []
var _zoom: float = 1.0


func set_zoom(zoom: float) -> void:
	_zoom = zoom


## Consume this frame's simulation events and age the effects already running.
func advance(simulated_seconds: float) -> void:
	if world != null:
		for event: SimEvent in world.events.drain():
			_spawn_from(event)

	var alive: Array[Effect] = []
	for effect: Effect in _effects:
		effect.life -= simulated_seconds
		if effect.life > 0.0:
			alive.append(effect)
	_effects = alive
	queue_redraw()


func _spawn_from(event: SimEvent) -> void:
	match event.type:
		&"shell_splash":
			var effect: Effect = Effect.new()
			effect.position = Serializer.array_to_vec2((event.data as Dictionary).get("position"))
			effect.max_life = SPLASH_LIFE_S
			effect.life = SPLASH_LIFE_S
			effect.radius = float((event.data as Dictionary).get("calibreMm", 200.0)) \
				* 0.001 * SPLASH_RADIUS_PER_CALIBRE
			effect.colour = ViewPalette.WAKE
			_effects.append(effect)
		&"shell_hit":
			var ship: ShipEntity = world.get_ship(event.target_id)
			if ship == null:
				return
			var effect: Effect = Effect.new()
			effect.position = ship.position
			effect.max_life = HIT_LIFE_S
			effect.life = HIT_LIFE_S
			effect.is_hit = true
			# A penetration reads differently from a shell that failed to get in, so
			# the player can see the difference without opening a panel.
			var data: Dictionary = event.data as Dictionary
			var penetrated: bool = bool(data.get("penetrated", false))
			effect.radius = 26.0 if penetrated else 14.0
			effect.colour = Color(1.0, 0.72, 0.35) if penetrated else Color(0.85, 0.88, 0.92)
			_effects.append(effect)
		_:
			pass


func _draw() -> void:
	if world == null:
		return
	_draw_shells()
	_draw_effects()


## Shells in the air, as short tracers along their line of flight.
##
## The tracer is drawn to the length the shell covers in a fixed slice of time, so a
## fast shell visibly streaks and a slow one crawls — and at fleet zoom, where a shell
## would be a fraction of a pixel, it is floored to something visible rather than
## disappearing.
func _draw_shells() -> void:
	for projectile: Projectile in world.projectiles:
		if not projectile.active:
			continue
		var head: Vector2 = projectile.ground_position()
		var velocity: Vector2 = Vector2(projectile.velocity.x, projectile.velocity.y)
		var length: float = maxf(velocity.length() * TRACER_LENGTH_S, MIN_TRACER_PIXELS / _zoom)
		var tail: Vector2 = head - velocity.normalized() * length

		var colour: Color = ViewPalette.team_colour(projectile.team)
		# Shells fade as they climb and brighten as they fall, which reads as height
		# without needing a separate altitude indicator.
		colour.a = clampf(0.45 + 0.55 * (1.0 - clampf(projectile.position.z / 4000.0, 0.0, 1.0)), 0.3, 1.0)
		var width: float = maxf(projectile.shell.diameter_m * 4.0, 1.5 / _zoom)
		draw_line(tail, head, colour, width, true)


func _draw_effects() -> void:
	for effect: Effect in _effects:
		var progress: float = 1.0 - clampf(effect.life / maxf(effect.max_life, 0.001), 0.0, 1.0)
		var colour: Color = effect.colour
		colour.a *= (1.0 - progress)

		if effect.is_hit:
			# A flash that shrinks as it fades.
			var radius: float = effect.radius * (1.0 - progress * 0.5)
			draw_circle(effect.position, radius, colour)
		else:
			# A splash column: a growing ring of foam.
			var radius: float = effect.radius * (0.35 + 0.65 * progress)
			draw_arc(effect.position, radius, 0.0, TAU, 24, colour, maxf(2.0 / _zoom, 1.0), true)
			var core: Color = colour
			core.a *= 0.45
			draw_circle(effect.position, radius * 0.45, core)
