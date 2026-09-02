class_name ShipSpec
extends RefCounted

## The simulation's view of a ship design — everything the physics needs, and
## nothing about where it came from.
##
## This is the seam between the data layer and the simulation. A historical preset
## loaded from data/ships/ and a player design from the ship designer both arrive
## here as the same object, which is what stops the combat engine from ever needing
## to know the difference (spec §4).
##
## Everything is SI: metres, m/s, kg, watts, radians. Conversion from the knots and
## shaft horsepower that the data files are authored in happens once, at load.

const DEFAULT_TACTICAL_DIAMETER_LENGTHS: float = 4.5
const DEFAULT_MAX_RUDDER_DEG: float = 35.0
const DEFAULT_RUDDER_RATE_DEG_S: float = 3.0
const DEFAULT_YAW_RESPONSE_S: float = 12.0

# -- identity ----------------------------------------------------------------
var spec_id: String = "unnamed"
var display_name: String = "Unnamed"
var ship_class: String = ""
var nation: String = ""
var ship_type: String = "destroyer"   ## battleship | carrier | cruiser | destroyer
var year: int = 1942
var is_custom: bool = false

# -- hull --------------------------------------------------------------------
var length_m: float = 100.0
var beam_m: float = 10.0
var draft_m: float = 4.0
var displacement_t: float = 2000.0
var hull_form_id: String = "destroyer"
var hull_profile: PackedVector2Array = PackedVector2Array()
var vertical_fullness: float = 0.8

# -- propulsion --------------------------------------------------------------
var max_speed_ms: float = 15.0
var propulsion_power_w: float = 1.0e7
var shafts: int = 2
var boilers: int = 4
var machinery_type: String = "steam_turbine"
var astern_power_fraction: float = 0.35
var max_sternway_fraction: float = 0.30

# -- manoeuvring -------------------------------------------------------------
var tactical_diameter_lengths: float = DEFAULT_TACTICAL_DIAMETER_LENGTHS
var max_rudder_rad: float = deg_to_rad(DEFAULT_MAX_RUDDER_DEG)
var rudder_rate_rad_s: float = deg_to_rad(DEFAULT_RUDDER_RATE_DEG_S)
var yaw_response_time_s: float = DEFAULT_YAW_RESPONSE_S

# -- armament ----------------------------------------------------------------
var main_battery: BatteryDef = null
var secondary_battery: BatteryDef = null

## Anti-aircraft outfit, summarised as barrel counts. Air attack is resolved
## statistically in Stage 7 rather than by tracking individual mounts.
var anti_air: Array = []

## Torpedo tubes. Most ships have none; the ones that do are defined by them.
var torpedo_battery: TorpedoBatteryDef = null

# -- protection --------------------------------------------------------------
var armour: ArmourSchemeDef = null

# -- aviation (carriers) -----------------------------------------------------
var aviation: Dictionary = {}

# -- crew --------------------------------------------------------------------
var crew: int = 300

## Built lazily from the dimensions and hull form; shared by every ship of the design.
var _hull: HullGeometry = null


## Fill in any manoeuvring figure the data file left unspecified.
##
## Response time scales with length rather than defaulting to a constant: the time a
## hull takes to answer the helm is a function of its size, and a 270 m battleship
## that inherited a destroyer's response time would feel wrong in a way no amount of
## rudder tuning could fix. Called once at load; an explicit value in the data always
## wins.
func derive_defaults() -> void:
	if yaw_response_time_s <= 0.0:
		yaw_response_time_s = clampf(length_m / 20.0, 3.0, 25.0)
	if tactical_diameter_lengths <= 0.0:
		tactical_diameter_lengths = DEFAULT_TACTICAL_DIAMETER_LENGTHS
	if max_rudder_rad <= 0.0:
		max_rudder_rad = deg_to_rad(DEFAULT_MAX_RUDDER_DEG)
	if rudder_rate_rad_s <= 0.0:
		rudder_rate_rad_s = deg_to_rad(DEFAULT_RUDDER_RATE_DEG_S)


## Draft the hull must actually sit at to displace its stated tonnage.
##
## Reported drafts and reported displacements often disagree, because published
## draft figures frequently include the propellers, a skeg or a sonar dome rather
## than the moulded hull — Fletcher's quoted 5.28 m against 2,500 tonnes implies a
## block coefficient of 0.34, which no destroyer has. Displacement is the sounder
## number of the two, so the internal geometry is built from the draft that
## reproduces it. The reported draft is kept for grounding and for display.
func hydrostatic_draft() -> float:
	var waterplane: float = hull().waterplane_area()
	if waterplane <= 0.0 or vertical_fullness <= 0.0:
		return draft_m
	var displaced_volume: float = displacement_t * SimUnits.TONNE_TO_KG / SimUnits.SEAWATER_DENSITY
	var derived: float = displaced_volume / (waterplane * vertical_fullness)
	# Guard against a wildly inconsistent data file producing absurd geometry.
	return clampf(derived, draft_m * 0.5, draft_m * 1.5)


func mass_kg() -> float:
	return displacement_t * SimUnits.TONNE_TO_KG


func hull() -> HullGeometry:
	if _hull == null:
		_hull = HullGeometry.create(length_m, beam_m, draft_m, hull_profile)
	return _hull


## Steady turning-circle radius at full rudder, in metres.
func turning_radius_m() -> float:
	return length_m * tactical_diameter_lengths * 0.5


## Resistance coefficient c in R = c * v^2, solved from the ship's own design point.
##
## At design speed the plant is delivering all its power against resistance, so
## P = R * v = c * v^3 and therefore c = P / v^3. Solving it this way means no ship
## needs a hand-authored drag figure: it falls out of the power and speed that are
## already in the data, and stays consistent for a player design that has never
## existed.
func resistance_coefficient() -> float:
	var v: float = maxf(max_speed_ms, 0.1)
	return propulsion_power_w / (v * v * v)


func duplicate_spec() -> ShipSpec:
	var copy: ShipSpec = ShipSpec.new()
	copy.spec_id = spec_id
	copy.display_name = display_name
	copy.ship_class = ship_class
	copy.nation = nation
	copy.ship_type = ship_type
	copy.year = year
	copy.is_custom = is_custom
	copy.length_m = length_m
	copy.beam_m = beam_m
	copy.draft_m = draft_m
	copy.displacement_t = displacement_t
	copy.hull_form_id = hull_form_id
	copy.hull_profile = hull_profile.duplicate()
	copy.vertical_fullness = vertical_fullness
	copy.max_speed_ms = max_speed_ms
	copy.propulsion_power_w = propulsion_power_w
	copy.shafts = shafts
	copy.boilers = boilers
	copy.machinery_type = machinery_type
	copy.astern_power_fraction = astern_power_fraction
	copy.max_sternway_fraction = max_sternway_fraction
	copy.tactical_diameter_lengths = tactical_diameter_lengths
	copy.max_rudder_rad = max_rudder_rad
	copy.rudder_rate_rad_s = rudder_rate_rad_s
	copy.yaw_response_time_s = yaw_response_time_s
	copy.crew = crew
	# Armament and armour are immutable descriptions shared between every ship of a
	# design; only the mutable per-ship state lives on ShipEntity, so these are shared
	# by reference rather than deep-copied.
	copy.main_battery = main_battery
	copy.secondary_battery = secondary_battery
	copy.anti_air = anti_air
	copy.torpedo_battery = torpedo_battery
	copy.armour = armour
	copy.aviation = aviation
	return copy


func has_main_battery() -> bool:
	return main_battery != null and not main_battery.is_empty()


func has_secondary_battery() -> bool:
	return secondary_battery != null and not secondary_battery.is_empty()


func has_torpedoes() -> bool:
	return torpedo_battery != null and not torpedo_battery.is_empty()


func is_carrier() -> bool:
	return ship_type == "carrier" and not aviation.is_empty()
