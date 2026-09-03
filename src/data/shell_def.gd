class_name ShellDef
extends RefCounted

## A projectile type: what it weighs, how fast it leaves the barrel, how it flies,
## and what it does when it arrives.
##
## Shell behaviour is the single most important distinction in naval gunnery. An AP
## shell and an HE shell of the same calibre fired from the same gun produce
## completely different outcomes against the same target, and that difference lives
## here rather than in a branch in the damage code.

enum Kind { AP, SAP, HE, COMMON, AA }
enum Cap { NONE, APC, BALLISTIC }

var shell_id: String = ""
var display_name: String = ""
var kind: Kind = Kind.AP
var mass_kg: float = 1.0
var diameter_m: float = 0.1
var muzzle_velocity_ms: float = 800.0

## Multiplier on the shared drag curve. See data/config/ballistics.json.
var form_factor: float = 1.0

var bursting_charge_kg: float = 0.0

## Seconds from the fuze triggering to detonation. This is what puts a shell's burst
## deep in a ship's machinery rather than against the plate it hit, and what lets one
## pass clean through a destroyer without going off at all.
var fuze_delay_s: float = 0.0

var cap: Cap = Cap.NONE

## De Marre coefficient. NOTE THE DIRECTION: it is the velocity this shell NEEDS per
## unit of plate, so a HIGHER value means a WORSE penetrator.
var penetration_k: float = 1380.0
var confidence: String = "medium"
var notes: String = ""

## Precomputed (form factor x area) / mass — constant for the life of the shell and
## needed several times per integration step.
var _drag_over_mass: float = 0.0


func drag_over_mass() -> float:
	if _drag_over_mass <= 0.0:
		_drag_over_mass = BallisticSolver.drag_area_over_mass(diameter_m, mass_kg, form_factor)
	return _drag_over_mass


## Kinetic energy at the muzzle, in joules. Useful for sanity checks and the debug
## overlay: a 16-inch AP shell leaves the barrel with roughly 350 MJ.
func muzzle_energy() -> float:
	return 0.5 * mass_kg * muzzle_velocity_ms * muzzle_velocity_ms


## Mass per unit frontal area, kg/m^2. The classical measure of how well a projectile
## carries its velocity, and a strong predictor of penetration.
func sectional_density() -> float:
	var radius: float = diameter_m * 0.5
	return mass_kg / maxf(PI * radius * radius, 1e-9)


func is_armour_piercing() -> bool:
	return kind == Kind.AP or kind == Kind.SAP


static func kind_from_string(text: String) -> Kind:
	match text.to_lower():
		"ap": return Kind.AP
		"sap": return Kind.SAP
		"he": return Kind.HE
		"common": return Kind.COMMON
		"aa": return Kind.AA
		_:
			push_warning("ShellDef: unknown shell type '%s'; treating as HE" % text)
			return Kind.HE


static func cap_from_string(text: String) -> Cap:
	match text.to_lower():
		"apc": return Cap.APC
		"ballistic": return Cap.BALLISTIC
		_: return Cap.NONE


static func kind_to_string(value: Kind) -> String:
	match value:
		Kind.AP: return "AP"
		Kind.SAP: return "SAP"
		Kind.HE: return "HE"
		Kind.COMMON: return "Common"
		Kind.AA: return "AA"
		_: return "?"


static func parse(data: Dictionary, source_path: String = "<memory>") -> ShellDef:
	if data.is_empty():
		push_error("ShellDef: empty document (%s)" % source_path)
		return null
	var shell: ShellDef = ShellDef.new()
	shell.shell_id = str(data.get("id", source_path.get_file().get_basename()))
	shell.display_name = str(data.get("name", shell.shell_id))
	shell.kind = kind_from_string(str(data.get("type", "ap")))
	shell.mass_kg = float(data.get("massKg", 1.0))
	shell.diameter_m = float(data.get("diameterMm", 100.0)) * SimUnits.MM_TO_M
	shell.muzzle_velocity_ms = float(data.get("muzzleVelocityMs", 800.0))
	shell.form_factor = float(data.get("formFactor", 1.0))
	shell.bursting_charge_kg = float(data.get("burstingChargeKg", 0.0))
	shell.fuze_delay_s = float(data.get("fuzeDelaySeconds", 0.0))
	shell.cap = cap_from_string(str(data.get("capType", "none")))
	shell.penetration_k = float(data.get("penetrationK", 1380.0))
	shell.confidence = str(data.get("confidence", "medium"))
	shell.notes = str(data.get("notes", ""))
	return shell
