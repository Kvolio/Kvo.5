class_name SimUnits
extends RefCounted

## Unit conversions and physical constants.
##
## The simulation works in SI throughout — metres, metres per second, kilograms,
## seconds, radians — and converts only at the presentation boundary. Mixing knots
## and metres inside the physics is how sign and scale errors hide.

const KNOTS_TO_MS: float = 0.5144444444444445
const MS_TO_KNOTS: float = 1.9438444924406046
const TONNE_TO_KG: float = 1000.0
const KG_TO_TONNE: float = 0.001
const METRE_TO_YARD: float = 1.0936132983377078
const MM_TO_M: float = 0.001
const INCH_TO_MM: float = 25.4
const MM_TO_INCH: float = 1.0 / 25.4
const LB_TO_KG: float = 0.45359237
const FPS_TO_MS: float = 0.3048
const SHP_TO_W: float = 745.6998715822702
const NAUTICAL_MILE_M: float = 1852.0

const GRAVITY: float = 9.80665           ## m/s^2
const SEAWATER_DENSITY: float = 1025.0   ## kg/m^3
const AIR_DENSITY_SEA_LEVEL: float = 1.225  ## kg/m^3


static func knots_to_ms(knots: float) -> float:
	return knots * KNOTS_TO_MS


static func ms_to_knots(ms: float) -> float:
	return ms * MS_TO_KNOTS


static func tonnes_to_kg(tonnes: float) -> float:
	return tonnes * TONNE_TO_KG


static func shp_to_watts(shp: float) -> float:
	return shp * SHP_TO_W


## Signed shortest angular difference from `from` to `to`, in radians (-PI, PI].
##
## Hand-rolled rather than using `angle_difference()` so the arithmetic is visible
## and identical everywhere: heading errors feed the steering loop every tick, and
## a branch difference here would show up as a course divergence.
static func angle_delta(from: float, to: float) -> float:
	var diff: float = fposmod(to - from + PI, TAU) - PI
	return diff


## Wrap an angle into [0, TAU).
static func normalise_angle(angle: float) -> float:
	return fposmod(angle, TAU)
