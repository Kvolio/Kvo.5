class_name MountDef
extends RefCounted

## Where a gun mount sits on a ship and which way it can point.
##
## Position is stored in NORMALISED hull coordinates — station from -0.5 at the stern
## to +0.5 at the bow, lateral as a fraction of half-beam — so a mount layout scales
## with the hull it is on. That matters for the ship designer: stretch a hull and the
## turrets stay in sensible places instead of ending up in the water.
##
## Train limits are relative to the mount's rest bearing, which is how real turret
## arcs are specified. An after turret rests at 180 degrees and trains 150 either
## side of that, so it cannot fire forward past its own superstructure — and that
## constraint is what makes crossing the T worth doing.

var mount_id: String = ""
var station: float = 0.0        ## -0.5 (stern) .. +0.5 (bow)
var lateral: float = 0.0        ## -1 (port) .. +1 (starboard), fraction of half-beam
var guns: int = 1
var rest_bearing: float = 0.0   ## radians, relative to the bow
var train_min: float = -deg_to_rad(150.0)  ## radians relative to rest bearing
var train_max: float = deg_to_rad(150.0)


## Position in ship-local metres. +X forward, +Y to starboard.
func local_position(length_m: float, beam_m: float) -> Vector2:
	return Vector2(station * length_m, lateral * beam_m * 0.5)


## Can the mount train onto this bearing? Bearing is relative to the ship's bow,
## positive to starboard.
func can_bear(relative_bearing: float) -> bool:
	var offset: float = SimUnits.angle_delta(rest_bearing, relative_bearing)
	return offset >= train_min and offset <= train_max


## Nearest bearing the mount can actually reach. Used to keep a turret trained as far
## round as it can go while a target is passing through its blind arc, so it is
## already close when the target comes back into arc.
func clamp_bearing(relative_bearing: float) -> float:
	var offset: float = SimUnits.angle_delta(rest_bearing, relative_bearing)
	return SimUnits.wrap_signed(rest_bearing + clampf(offset, train_min, train_max))


## Half-width of the blind arc astern of the mount's rest bearing, in radians.
func blind_arc() -> float:
	return TAU - (train_max - train_min)


func duplicate() -> MountDef:
	var copy: MountDef = MountDef.new()
	copy.mount_id = mount_id
	copy.station = station
	copy.lateral = lateral
	copy.guns = guns
	copy.rest_bearing = rest_bearing
	copy.train_min = train_min
	copy.train_max = train_max
	return copy


static func parse(data: Dictionary, index: int = 0) -> MountDef:
	var mount: MountDef = MountDef.new()
	mount.mount_id = str(data.get("id", "M%d" % index))
	mount.station = clampf(float(data.get("station", 0.0)), -0.5, 0.5)
	mount.lateral = clampf(float(data.get("lateral", 0.0)), -1.0, 1.0)
	mount.guns = maxi(int(data.get("guns", 1)), 1)
	mount.rest_bearing = deg_to_rad(float(data.get("restBearingDeg", 0.0)))
	var limits: Array = data.get("trainLimitsDeg", [-150.0, 150.0]) as Array
	if limits.size() >= 2:
		mount.train_min = deg_to_rad(float(limits[0]))
		mount.train_max = deg_to_rad(float(limits[1]))
	return mount
