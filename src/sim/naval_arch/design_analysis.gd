class_name DesignAnalysis
extends RefCounted

## What a ship design actually weighs, how stable she is, and how fast she will go.
##
## This is what makes armour expensive. Every millimetre of plate is weighed from the
## real geometry, the weight has to be carried by a hull, and a heavier hull needs
## more power to push it — so the tradeoffs the specification asks for are not
## scripted anywhere. They are the arithmetic.
##
## The same analysis runs over a historical preset and a player design, which is how
## the designer's numbers can be trusted: they are checked against ships whose real
## weight breakdowns are known.

## One line of the weight statement.
class WeightGroup extends RefCounted:
	var name: String = ""
	var tonnes: float = 0.0
	var vertical_centre_m: float = 0.0   ## above the keel

	func moment() -> float:
		return tonnes * vertical_centre_m


var groups: Array[WeightGroup] = []

# -- displacement ------------------------------------------------------------
var light_displacement_t: float = 0.0    ## everything but fuel
var full_displacement_t: float = 0.0
var stated_displacement_t: float = 0.0
var buoyancy_t: float = 0.0              ## what the hull can actually carry at its draft
var fuel_t: float = 0.0                  ## bunkerage: full load less standard displacement
var sinkage_m: float = 0.0               ## how much deeper than drawn she actually floats

# -- stability ---------------------------------------------------------------
var kg_m: float = 0.0                    ## centre of gravity above the keel
var kb_m: float = 0.0                    ## centre of buoyancy above the keel
var bm_m: float = 0.0                    ## metacentric radius
var gm_m: float = 0.0                    ## metacentric height: KB + BM - KG

# -- performance -------------------------------------------------------------
var estimated_speed_kn: float = 0.0
var stated_speed_kn: float = 0.0
var machinery_volume_m3: float = 0.0
var available_volume_m3: float = 0.0

# -- geometry ----------------------------------------------------------------
var depth_m: float = 0.0
var freeboard_m: float = 0.0
var length_to_beam: float = 0.0
var draft_to_beam: float = 0.0


func add_group(name: String, tonnes: float, vertical_centre: float) -> WeightGroup:
	var group: WeightGroup = WeightGroup.new()
	group.name = name
	group.tonnes = maxf(tonnes, 0.0)
	group.vertical_centre_m = vertical_centre
	groups.append(group)
	return group


func group_tonnes(name: String) -> float:
	for group: WeightGroup in groups:
		if group.name == name:
			return group.tonnes
	return 0.0


## Share of the ship's displacement spent on a weight group. The number a designer
## actually argues about: a battleship spends around a third of herself on armour.
func group_fraction(name: String) -> float:
	return 0.0 if full_displacement_t <= 0.0 else group_tonnes(name) / full_displacement_t


## How far the computed weight is from the displacement the design claims.
##
## Positive means she weighs more than she is supposed to and will float deeper than
## drawn — the commonest way a real design went wrong.
func overweight_fraction() -> float:
	if stated_displacement_t <= 0.0:
		return 0.0
	return (full_displacement_t - stated_displacement_t) / stated_displacement_t


func describe() -> String:
	return ("%.0f t full load, GM %.2f m, %.1f kn estimated against %.1f stated"
		% [full_displacement_t, gm_m, estimated_speed_kn, stated_speed_kn])
