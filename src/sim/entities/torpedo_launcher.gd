class_name TorpedoLauncher
extends RefCounted

## A bank of tubes as it exists during a battle: trained, loaded, or empty.
##
## Most navies carried no reloads at all. A destroyer that has fired her tubes has
## spent the only thing that made her dangerous to a battleship, and the decision of
## when to fire them is the single biggest one her captain makes.

enum State { READY, RELOADING, EMPTY, DESTROYED }

var mount: TorpedoMountDef = null
var definition: TorpedoDef = null
var battery: TorpedoBatteryDef = null

var bearing: float = 0.0
var train_offset: float = 0.0
var state: State = State.READY
var tubes_loaded: int = 0
var reload_remaining: float = 0.0
var salvos_fired: int = 0

var ordered_bearing: float = 0.0
var has_orders: bool = false


static func create(p_mount: TorpedoMountDef, p_definition: TorpedoDef,
		p_battery: TorpedoBatteryDef) -> TorpedoLauncher:
	var launcher: TorpedoLauncher = TorpedoLauncher.new()
	launcher.mount = p_mount
	launcher.definition = p_definition
	launcher.battery = p_battery
	launcher.bearing = SimUnits.wrap_signed(p_mount.rest_bearing)
	launcher.ordered_bearing = launcher.bearing
	launcher.tubes_loaded = p_mount.tubes
	return launcher


func is_operational() -> bool:
	return state != State.DESTROYED


func can_fire() -> bool:
	return state == State.READY and tubes_loaded > 0


func order_train(relative_bearing: float) -> void:
	ordered_bearing = relative_bearing
	has_orders = true


func stand_down() -> void:
	ordered_bearing = mount.rest_bearing
	has_orders = false


## Train towards the ordered bearing, and tick any reload.
##
## Training is a bounded axis within the mount's stops, exactly as for a gun turret:
## a bank cannot swing through the ship to reach the other beam.
func step(dt: float, train_rate: float) -> void:
	if reload_remaining > 0.0:
		reload_remaining = maxf(reload_remaining - dt, 0.0)
		if reload_remaining <= 0.0:
			tubes_loaded = mount.tubes
			state = State.READY
	if not is_operational():
		return
	var target: float = clampf(
		SimUnits.angle_delta(mount.rest_bearing, ordered_bearing),
		mount.train_min, mount.train_max)
	train_offset = move_toward(train_offset, target, train_rate * dt)
	bearing = SimUnits.wrap_signed(mount.rest_bearing + train_offset)


## Fire everything in the tubes. Returns how many went.
func fire() -> int:
	if not can_fire():
		return 0
	var fired: int = tubes_loaded
	tubes_loaded = 0
	salvos_fired += 1
	if battery != null and battery.has_reloads():
		state = State.RELOADING
		reload_remaining = battery.reload_seconds
	else:
		state = State.EMPTY
	return fired


func hash_into(hasher: StateHasher) -> void:
	hasher.write_float(train_offset)
	hasher.write_int(int(state))
	hasher.write_int(tubes_loaded)
	hasher.write_float(reload_remaining)


func serialize() -> Dictionary:
	return {
		"mountId": mount.mount_id, "trainOffset": train_offset,
		"state": int(state), "tubesLoaded": tubes_loaded,
		"reloadRemaining": reload_remaining, "salvosFired": salvos_fired,
	}
