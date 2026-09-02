class_name ArmorInteractionContext
extends RefCounted

## Everything a penetration model needs to know about one projectile meeting one
## plate. Assembled by the tracer; consumed by whichever model is configured.
##
## The context is deliberately wider than De Marre needs — yaw, integrity, cap state,
## nose form — because those are exactly the terms a more sophisticated model would
## want, and a context that omitted them would have to be widened (and every caller
## rebuilt) the moment one was written.

# -- projectile ---------------------------------------------------------------
var mass_kg: float = 1.0
var diameter_m: float = 0.1
var velocity: Vector3 = Vector3.ZERO
var is_armour_piercing: bool = true
var penetration_k: float = 1380.0
var integrity: float = 1.0
var cap_status: PenetrationOutcome.Cap = PenetrationOutcome.Cap.NONE
var yaw_deg: float = 0.0
var fuze_state: PenetrationOutcome.Fuze = PenetrationOutcome.Fuze.UNARMED

# -- plate --------------------------------------------------------------------
var thickness_mm: float = 0.0
var plate_normal: Vector3 = Vector3.RIGHT
var material_quality: float = 1.0
var face_hardened: bool = false
var plate_deformation: float = 0.0
var zone: String = ""

# -- context ------------------------------------------------------------------
## Stream to draw from where the model is probabilistic. A ballistic limit is a 50%
## point rather than a wall, so near it the outcome really is a roll — and it has to
## be a reproducible one.
var rng: DeterministicRng = null


func speed() -> float:
	return velocity.length()


func kinetic_energy() -> float:
	var v: float = speed()
	return 0.5 * mass_kg * v * v


func diameter_mm() -> float:
	return diameter_m * 1000.0


## Plate thickness as a fraction of the shell's calibre.
##
## The single most useful ratio in armour work. Below about 0.5 a shell tends to
## overmatch the plate and punch through almost regardless of angle; above about 1.0
## the plate dominates and glancing hits skid off.
func thickness_to_calibre() -> float:
	return thickness_mm / maxf(diameter_mm(), 0.001)


## Angle between the shell's path and the plate's normal, in radians. Zero is a
## square hit.
func obliquity() -> float:
	var direction: Vector3 = velocity.normalized()
	return acos(clampf(absf(direction.dot(plate_normal.normalized())), 0.0, 1.0))
