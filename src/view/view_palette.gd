class_name ViewPalette
extends RefCounted

## Colours for the tactical display.
##
## Kept in one place so every overlay, panel and marker agrees. The scheme is a
## military plot: desaturated blues for the sea, cool cyan for own forces, warm
## amber-red for hostiles, and pure white reserved for the current selection so it is
## never ambiguous which ship is being commanded.

const SEA_DEEP: Color = Color(0.043, 0.086, 0.145)
const SEA_SHALLOW: Color = Color(0.086, 0.169, 0.231)
const SEA_CREST: Color = Color(0.239, 0.361, 0.427)

const GRID: Color = Color(0.35, 0.55, 0.65, 0.10)
const GRID_MAJOR: Color = Color(0.40, 0.62, 0.72, 0.18)
const MAP_EDGE: Color = Color(0.85, 0.35, 0.25, 0.45)

const FRIENDLY: Color = Color(0.42, 0.82, 0.92)
const HOSTILE: Color = Color(0.95, 0.55, 0.28)
const NEUTRAL: Color = Color(0.72, 0.75, 0.78)
const SELECTED: Color = Color(1.0, 1.0, 1.0)

const HULL_FILL_ALPHA: float = 0.30
const WAKE: Color = Color(0.80, 0.88, 0.94, 0.30)

const TEXT_PRIMARY: Color = Color(0.90, 0.93, 0.95)
const TEXT_DIM: Color = Color(0.62, 0.68, 0.72)
const PANEL_BG: Color = Color(0.055, 0.086, 0.118, 0.88)
const PANEL_EDGE: Color = Color(0.30, 0.42, 0.50, 0.55)

const DESTROYED: Color = Color(0.45, 0.45, 0.48)
const MISSION_KILL: Color = Color(0.85, 0.78, 0.35)


## Team colour. Team 0 is the player's side by convention.
static func team_colour(team: int) -> Color:
	match team:
		0:
			return FRIENDLY
		1:
			return HOSTILE
		_:
			return NEUTRAL


## Colour for a ship, taking its condition into account: a wreck is grey whichever
## side it belonged to, and a mission-killed ship is marked as still afloat but out
## of the fight.
static func ship_colour(team: int, status: ShipEntity.Status) -> Color:
	match status:
		ShipEntity.Status.DESTROYED:
			return DESTROYED
		ShipEntity.Status.MISSION_KILL:
			return team_colour(team).lerp(MISSION_KILL, 0.55)
		_:
			return team_colour(team)
