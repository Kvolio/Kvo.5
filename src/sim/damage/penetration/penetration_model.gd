class_name PenetrationModel
extends RefCounted

## Interface for armour penetration.
##
## The whole simulation depends on this and never on a concrete model. De Marre is
## what ships today; it is a serviceable empirical fit, not the last word, and the
## point of this seam is that replacing it with a fuller analytical treatment means
## adding a class and changing one line of configuration — not touching HitResolver,
## DamageResolver, the tracer, or anything that reads a HitReport.
##
## An implementation must:
##   * return a PenetrationOutcome, never a boolean;
##   * fill in enough state that the projectile can carry on to the NEXT plate —
##     velocity, integrity, cap status, fuze state — because a shell's journey
##     through a ship is a sequence of these, not one lookup;
##   * take all its coefficients from configuration rather than embedding them;
##   * be reproducible: any randomness must come from the context's RNG stream.


## Identifier matching the key in data/config/ballistics.json.
func model_id() -> String:
	push_error("PenetrationModel.model_id() is abstract")
	return "abstract"


## Resolve one projectile meeting one plate.
func evaluate(_context: ArmorInteractionContext) -> PenetrationOutcome:
	push_error("PenetrationModel.evaluate() is abstract")
	return PenetrationOutcome.new()


## Thickness of plate this projectile could just defeat at normal incidence, in mm.
##
## Not used by the simulation, which asks `evaluate` for a full outcome — but the
## debug overlay, the ship designer's immunity-zone display and the tests against
## published penetration tables all want the bare number.
func penetration_capability_mm(_context: ArmorInteractionContext) -> float:
	push_error("PenetrationModel.penetration_capability_mm() is abstract")
	return 0.0
