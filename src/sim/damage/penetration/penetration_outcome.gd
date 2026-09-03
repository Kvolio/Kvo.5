class_name PenetrationOutcome
extends RefCounted

## What happened when a projectile met a plate.
##
## Deliberately NOT a boolean. "Did it get through" is the least interesting part of
## an armour interaction: what matters downstream is how fast the shell is still
## going, whether it is still in one piece, whether its cap survived to help against
## the next plate, whether its fuze has started running, and what came off the back
## of the plate. A model that returned only true or false would make every one of
## those unrecoverable, and would make a more sophisticated model impossible to
## substitute later without changing every caller.

enum Result {
	PENETRATED,  ## through, intact, still carrying velocity
	PARTIAL,     ## the plate is holed but the shell broke up going through
	STOPPED,     ## the plate held
	RICOCHET,    ## deflected off without biting in
	SHATTERED,   ## the shell broke up on the face; the plate may or may not be holed
}

enum Cap {
	NONE,      ## never had one
	INTACT,    ## armour-piercing cap still fitted
	STRIPPED,  ## torn off by an earlier plate — markedly worse against face-hardened armour
}

enum Fuze {
	UNARMED,
	ARMED,
	TRIGGERED,
	FAILED,
}

var result: Result = Result.STOPPED

# -- projectile state after the interaction -----------------------------------
var remaining_velocity: Vector3 = Vector3.ZERO
var remaining_energy: float = 0.0
var projectile_integrity: float = 1.0   ## 0 = broken up, 1 = intact
var cap_status: Cap = Cap.NONE
var yaw_deg: float = 0.0                ## how far the shell has been turned off its axis
var fuze_state: Fuze = Fuze.UNARMED

# -- what the plate did -------------------------------------------------------
var obliquity_deg: float = 0.0
var normalization_deg: float = 0.0
var effective_thickness_mm: float = 0.0
var penetration_capability_mm: float = 0.0
var plate_deformation_added: float = 0.0

# -- what came off the back of it ---------------------------------------------
var spall_mass_kg: float = 0.0
var spall_cone_deg: float = 0.0

## Free-form notes from whichever model produced this, shown in the debug overlay.
var diagnostics: String = ""


## Did anything get past this plate — the shell itself, its fragments, or spall?
func anything_got_through() -> bool:
	return result == Result.PENETRATED or result == Result.PARTIAL or spall_mass_kg > 0.0


## Is the projectile still a coherent, fuzed shell capable of bursting deeper in?
func projectile_survives() -> bool:
	return result == Result.PENETRATED and projectile_integrity > 0.5


## Ratio of capability to what the plate actually presented. Above 1 the shell had
## the energy to get through; the marginal band around 1 is where it becomes a matter
## of chance.
func penetration_ratio() -> float:
	if effective_thickness_mm <= 0.0:
		return INF
	return penetration_capability_mm / effective_thickness_mm


static func result_to_string(value: Result) -> String:
	match value:
		Result.PENETRATED: return "PENETRATION"
		Result.PARTIAL: return "PARTIAL PENETRATION"
		Result.STOPPED: return "NO PENETRATION"
		Result.RICOCHET: return "RICOCHET"
		Result.SHATTERED: return "SHATTER"
		_: return "?"


func to_dict() -> Dictionary:
	return {
		"result": result_to_string(result),
		"obliquityDeg": obliquity_deg,
		"normalizationDeg": normalization_deg,
		"effectiveThicknessMm": effective_thickness_mm,
		"penetrationCapabilityMm": penetration_capability_mm,
		"remainingVelocityMs": remaining_velocity.length(),
		"remainingEnergyJ": remaining_energy,
		"projectileIntegrity": projectile_integrity,
		"capStatus": ["none", "intact", "stripped"][int(cap_status)],
		"fuzeState": ["unarmed", "armed", "triggered", "failed"][int(fuze_state)],
		"spallMassKg": spall_mass_kg,
		"diagnostics": diagnostics,
	}
