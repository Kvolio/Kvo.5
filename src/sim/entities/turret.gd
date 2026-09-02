class_name Turret
extends RefCounted

## A gun mount as it exists during a battle: where it is trained, how far it has
## elevated, and whether it is loaded.
##
## Turrets are slow. A battleship's main battery trains at a few degrees a second and
## takes half a minute to reload, so a ship that has to check fire and swing her
## turrets across the deck to answer a new threat pays a real price for it. Modelling
## that is what makes manoeuvre matter in a gun action rather than being decoration
## on top of a hit calculation.

enum State {
	OPERATIONAL,
	DAMAGED,    ## slower, but still fighting
	DISABLED,   ## out of action, repairable
	DESTROYED,  ## permanently gone
}

## How much a damaged mount is slowed and how much of its rate of fire it keeps.
const DAMAGED_RATE_FACTOR: float = 0.5

var mount: MountDef = null
var gun: GunDef = null
var battery: StringName = &"main"

## Ship-relative bearing the mount is trained to: signed, in (-PI, PI], negative to
## port. Derived from `train_offset`; kept as a field because the renderer and the
## gunnery solution both want it directly.
var bearing: float = 0.0

## Where the mount is trained, measured from its rest bearing and confined to
## [train_min, train_max].
##
## Training is a BOUNDED AXIS, not a circle, and that distinction is load-bearing. A
## turret trained hard to port and ordered hard to starboard must swing the long way
## round across the bow, because the short way lies through its own blind arc and the
## training stops are physically in the way. Working in offset space rather than in
## wrapped bearings makes that impossible to get wrong: there is nothing to wrap.
var train_offset: float = 0.0

var elevation: float = 0.0

var state: State = State.OPERATIONAL
var reload_remaining: float = 0.0
var selected_shell: String = ""
var rounds_fired: int = 0

## Desired lay, set by fire control each tick.
var ordered_bearing: float = 0.0
var ordered_elevation: float = 0.0
var has_orders: bool = false


static func create(p_mount: MountDef, p_gun: GunDef, p_battery: StringName = &"main") -> Turret:
	var turret: Turret = Turret.new()
	turret.mount = p_mount
	turret.gun = p_gun
	turret.battery = p_battery
	turret.bearing = SimUnits.wrap_signed(p_mount.rest_bearing)
	turret.train_offset = 0.0
	turret.ordered_bearing = p_mount.rest_bearing
	turret.selected_shell = p_gun.default_ammunition()
	return turret


func barrels() -> int:
	return mount.guns


func is_operational() -> bool:
	return state == State.OPERATIONAL or state == State.DAMAGED


## Fraction of nominal train, elevation and loading speed this mount still has.
func efficiency() -> float:
	match state:
		State.OPERATIONAL: return 1.0
		State.DAMAGED: return DAMAGED_RATE_FACTOR
		_: return 0.0


func order_lay(target_bearing: float, target_elevation: float) -> void:
	ordered_bearing = target_bearing
	ordered_elevation = target_elevation
	has_orders = true


func stand_down() -> void:
	# Return to the rest bearing rather than freezing where it stopped: that is what
	# a real mount does when it has nothing to shoot at, and it keeps the turret
	# pointing somewhere sensible for the next target.
	ordered_bearing = mount.rest_bearing
	ordered_elevation = 0.0
	has_orders = false


func step(dt: float) -> void:
	if reload_remaining > 0.0:
		# A damaged mount loads more slowly as well as training more slowly.
		reload_remaining = maxf(reload_remaining - dt * maxf(efficiency(), 0.0), 0.0)
	if not is_operational():
		return

	var rate: float = efficiency()
	# Clamped into the mount's arc, then approached linearly. No wrapping: the stops
	# make a turret's training an interval, and moving along an interval can never
	# pass through the blind arc the way a shortest-angle rotation would.
	var target_offset: float = clampf(
		SimUnits.angle_delta(mount.rest_bearing, ordered_bearing), mount.train_min, mount.train_max)
	train_offset = move_toward(train_offset, target_offset, gun.traverse_rate_rad_s * rate * dt)
	bearing = SimUnits.wrap_signed(mount.rest_bearing + train_offset)

	var elevation_target: float = clampf(
		ordered_elevation, gun.min_elevation_rad, gun.max_elevation_rad)
	elevation = move_toward(elevation, elevation_target, gun.elevation_rate_rad_s * rate * dt)


## Is the mount loaded, laid, and able to bear on its ordered target?
func is_ready_to_fire(bearing_tolerance: float, elevation_tolerance: float) -> bool:
	if not is_operational() or not has_orders or reload_remaining > 0.0:
		return false
	if not mount.can_bear(ordered_bearing):
		return false
	if absf(SimUnits.angle_delta(bearing, ordered_bearing)) > bearing_tolerance:
		return false
	return absf(elevation - ordered_elevation) <= elevation_tolerance


## Record a shot and start the reload clock.
func mark_fired() -> void:
	rounds_fired += barrels()
	reload_remaining = gun.seconds_per_round()


func hash_into(hasher: StateHasher) -> void:
	hasher.write_string(mount.mount_id)
	hasher.write_float(train_offset)
	hasher.write_float(elevation)
	hasher.write_float(reload_remaining)
	hasher.write_int(int(state))
	hasher.write_int(rounds_fired)


func serialize() -> Dictionary:
	return {
		"mountId": mount.mount_id,
		"trainOffset": train_offset,
		"elevation": elevation,
		"state": int(state),
		"reloadRemaining": reload_remaining,
		"shell": selected_shell,
		"roundsFired": rounds_fired,
	}


func deserialize(data: Dictionary) -> void:
	train_offset = clampf(float(data.get("trainOffset", 0.0)), mount.train_min, mount.train_max)
	bearing = SimUnits.wrap_signed(mount.rest_bearing + train_offset)
	elevation = float(data.get("elevation", elevation))
	state = int(data.get("state", int(state))) as State
	reload_remaining = float(data.get("reloadRemaining", 0.0))
	selected_shell = str(data.get("shell", selected_shell))
	rounds_fired = int(data.get("roundsFired", 0))
