class_name ImmunityZone
extends RefCounted

## The band of range in which a ship cannot be penetrated by a given gun.
##
## Close in, a shell arrives flat and fast and goes through the belt. Far out, it
## arrives slowly but steeply and comes through the deck. Between the two there may be
## a band where it does neither, and that band is the single most important tactical
## fact about an armoured ship: it is what her armour was designed to produce, it is
## what her captain fought to stay inside, and it is why "close the range" and "open the
## range" are both sometimes the right order.
##
## Nothing here is a rule or a table. The zone is found by asking the SAME penetration
## model the trajectory tracer asks, at each range in the gun's own range table, and
## seeing what it answers. So a design nobody has ever drawn gets a real immunity zone
## from its own plate, and if the penetration model is replaced the zone moves with it.
##
## Two documented simplifications, both the ones the historical calculation made:
## the target is taken beam-on, which is the worst case for her and therefore the
## honest one to design against; and the armour deck is taken as the plate that decides
## a plunging hit. The weather deck's job is to strip the cap and start the fuze rather
## than to stop the shell, and the tracer models that properly when the shot is real.

## Ranges at or beyond which the zone is reported as open-ended.
const NO_LIMIT: float = -1.0

var inner_m: float = 0.0     ## inside this, the belt is beaten
var outer_m: float = 0.0     ## beyond this, the deck is beaten
var belt_mm: float = 0.0
var deck_mm: float = 0.0
var gun_id: String = ""
var shell_id: String = ""


## True where there is any range at all at which she is safe from this gun.
func exists() -> bool:
	return outer_m > inner_m


func width_m() -> float:
	return maxf(outer_m - inner_m, 0.0)


func contains(range_m: float) -> bool:
	return exists() and range_m >= inner_m and range_m <= outer_m


func describe() -> String:
	if not exists():
		return "no immunity zone against %s" % gun_id
	return "immune from %.1f to %.1f km against %s" % [
		inner_m / 1000.0, outer_m / 1000.0, gun_id]


## Work out the zone this ship's armour gives her against one gun firing one shell.
##
## Samples the gun's own range table, so the ranges considered are exactly the ranges
## the gun can actually reach, with the striking velocity and descent angle the
## ballistics solved rather than a formula for them.
static func compute(armour: ArmourSchemeDef, table: RangeTable, shell: ShellDef,
		model: PenetrationModel, materials: ArmourMaterials) -> ImmunityZone:
	var zone: ImmunityZone = ImmunityZone.new()
	if armour == null or table == null or shell == null or model == null:
		return zone
	zone.gun_id = table.gun_id
	zone.shell_id = table.shell_id

	var belt: ArmourSchemeDef.Plate = armour.plate("belt")
	var deck: ArmourSchemeDef.Plate = armour.plate("deckMain")
	zone.belt_mm = belt.thickness_mm
	zone.deck_mm = deck.thickness_mm

	# The belt is beaten from zero out to the last range at which it is beaten; the
	# deck from the first range at which it is beaten out to maximum. Walking the table
	# once and recording those two crossings is all the zone is.
	var belt_limit: float = 0.0
	var deck_limit: float = table.maximum_range()

	for entry: RangeTable.Entry in table.entries:
		if entry.range_m <= 0.0:
			continue
		if _beats(belt, entry, shell, model, materials, false):
			belt_limit = maxf(belt_limit, entry.range_m)
		if _beats(deck, entry, shell, model, materials, true):
			deck_limit = minf(deck_limit, entry.range_m)

	zone.inner_m = belt_limit
	zone.outer_m = deck_limit
	return zone


## Does this shell, arriving as the range table says it does, get through this plate?
##
## Asked of the configured penetration model, with a context built exactly as the
## tracer builds one — so the answer here and the answer when a shell really arrives
## are the same answer.
static func _beats(plate: ArmourSchemeDef.Plate, entry: RangeTable.Entry, shell: ShellDef,
		model: PenetrationModel, materials: ArmourMaterials, horizontal: bool) -> bool:
	if plate == null or not plate.is_armoured():
		return true

	var context: ArmorInteractionContext = ArmorInteractionContext.new()
	context.mass_kg = shell.mass_kg
	context.diameter_m = shell.diameter_m
	context.is_armour_piercing = shell.is_armour_piercing()
	context.penetration_k = shell.penetration_k
	context.integrity = 1.0
	context.cap_status = PenetrationOutcome.Cap.INTACT if shell.cap == ShellDef.Cap.APC \
		else PenetrationOutcome.Cap.NONE
	context.thickness_mm = plate.thickness_mm
	context.zone = plate.zone

	if materials != null:
		context.material_quality = materials.quality(plate.material_id)
		context.face_hardened = materials.is_face_hardened(plate.material_id)

	# The shell falls in the x-z plane, descending at the table's descent angle. A
	# vertical belt's normal is horizontal; an armour deck's is vertical. The belt's own
	# inclination tilts its normal, which is exactly the trade an inclined belt makes:
	# more effective thickness against a flat trajectory, less against a plunging one.
	var descent: float = entry.descent_angle
	context.velocity = Vector3(cos(descent), 0.0, -sin(descent)) * entry.striking_velocity
	if horizontal:
		context.plate_normal = Vector3(0.0, 0.0, 1.0)
	else:
		context.plate_normal = Vector3(cos(plate.inclination_rad), 0.0, sin(plate.inclination_rad))

	var outcome: PenetrationOutcome = model.evaluate(context)
	return outcome.result == PenetrationOutcome.Result.PENETRATED \
		or outcome.result == PenetrationOutcome.Result.PARTIAL
