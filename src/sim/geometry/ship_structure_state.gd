class_name ShipStructureState
extends RefCounted

## The mutable condition of one ship: what is flooded, what is burning, what is
## wrecked, and who is left alive.
##
## Deliberately separate from `ShipStructureTemplate`, which is the immutable geometry
## shared by every ship of a design. A twelve-destroyer squadron traces against one
## copy of the same arrangement but each has her own damage — and without that split
## a hit on one Fletcher would deform the plating of all of them.
##
## Nothing here is a health pool. These are conditions, and structural integrity is
## computed FROM them (see SurvivabilityEvaluator) rather than being one of them.

## What has happened to one compartment.
class CompartmentState extends RefCounted:
	var flood: float = 0.0        ## 0-1, fraction of floodable volume taken by water
	var fire: float = 0.0         ## 0-1 intensity
	var wreckage: float = 0.0     ## 0-1, how much of it has been destroyed
	var breached: bool = false    ## opened to the sea or to an adjacent flooded space
	var breach_area_m2: float = 0.0
	## How far below the waterline the opening is. Water enters at a rate set by the
	## square root of this, which is why damage low down is so much worse than damage
	## high up — and why a ship settling deeper floods progressively faster.
	var breach_depth_m: float = 0.0
	var crew: int = 0
	var ammunition: float = 0.0   ## 0-1, magazines only

	func is_intact() -> bool:
		return wreckage < 0.05 and not breached and flood <= 0.0 and fire <= 0.0


## What has happened to one component.
##
## `state` is DERIVED from `condition`, not stored alongside it. The same reasoning as
## structural integrity: two fields that are supposed to agree eventually will not,
## and a turret reported operational because its state was never updated while its
## condition sat at zero is exactly that bug.
class ComponentState extends RefCounted:
	## Thresholds, loaded once from data/config/damage.json. Shared, because they are
	## a property of the model rather than of any one component.
	static var damaged_below: float = 0.70
	static var disabled_below: float = 0.35
	static var destroyed_below: float = 0.05

	var condition: float = 1.0    ## 1 untouched, 0 destroyed

	## 0 operational, 1 damaged, 2 disabled, 3 destroyed — matching Turret.State.
	var state: int:
		get:
			if condition < destroyed_below:
				return 3
			if condition < disabled_below:
				return 2
			if condition < damaged_below:
				return 1
			return 0

	func is_operational() -> bool:
		return state <= 1

	static func configure(config: Dictionary) -> void:
		var thresholds: Dictionary = config.get("components", {}) as Dictionary
		damaged_below = float(thresholds.get("damagedBelow", 0.70))
		disabled_below = float(thresholds.get("disabledBelow", 0.35))
		destroyed_below = float(thresholds.get("destroyedBelow", 0.05))


var compartments: Array[CompartmentState] = []
var components: Array[ComponentState] = []

## Accumulated deformation per face of the template, from hits that did not get
## through. A plate that has been hit before resists less.
var plate_deformation: PackedFloat32Array = PackedFloat32Array()

var crew_total: int = 0
var crew_alive: int = 0

## Damage to the hull girder itself, 0-1. Reached only by very severe local damage or
## by a torpedo breaking a ship's back; at 1 the hull fails as a beam.
var girder_damage: float = 0.0

## Set when something happened that ends the ship outright, with the reason kept for
## the combat log and the post-action inspection.
var catastrophic: bool = false
var catastrophe_reason: String = ""


static func create(template: ShipStructureTemplate, spec: ShipSpec, config: Dictionary
) -> ShipStructureState:
	var state: ShipStructureState = ShipStructureState.new()
	state.crew_total = spec.crew
	state.crew_alive = spec.crew
	state.plate_deformation.resize(template.faces.size())

	var crew_shares: Dictionary = config.get("crew", {}) as Dictionary
	var totals: Dictionary = {}
	for volume: GeometryPrimitives.Volume in template.volumes:
		if volume.kind == GeometryPrimitives.VolumeKind.COMPARTMENT:
			totals[volume.role] = float(totals.get(volume.role, 0.0)) + 1.0

	for volume: GeometryPrimitives.Volume in template.volumes:
		if volume.kind == GeometryPrimitives.VolumeKind.COMPONENT:
			state.components.append(ComponentState.new())
			state.compartments.append(null)
			continue
		var compartment: CompartmentState = CompartmentState.new()
		# Spread the ship's company over the compartments that hold people, so that a
		# hit into a manned machinery space costs more lives than one into a void.
		var share: float = float(crew_shares.get(volume.role, crew_shares.get("default", 0.02)))
		var count: float = maxf(float(totals.get(volume.role, 1.0)), 1.0)
		compartment.crew = int(round(float(spec.crew) * share / count))
		if volume.role == ShipStructureBuilder.ROLE_MAGAZINE:
			compartment.ammunition = 1.0
		state.compartments.append(compartment)
		state.components.append(null)
	return state


## Compartment state for a template volume index, or null if that index is a component.
func compartment(index: int) -> CompartmentState:
	if index < 0 or index >= compartments.size():
		return null
	return compartments[index]


func component(index: int) -> ComponentState:
	if index < 0 or index >= components.size():
		return null
	return components[index]


func deformation_of(face_index: int) -> float:
	if face_index < 0 or face_index >= plate_deformation.size():
		return 0.0
	return plate_deformation[face_index]


func add_deformation(face_index: int, amount: float) -> void:
	if face_index < 0 or face_index >= plate_deformation.size():
		return
	plate_deformation[face_index] = clampf(plate_deformation[face_index] + amount, 0.0, 1.0)


func crew_fraction() -> float:
	return 0.0 if crew_total <= 0 else clampf(float(crew_alive) / float(crew_total), 0.0, 1.0)


## Kill `count` of a compartment's people, and the same number from the ship's total.
func take_casualties(compartment_index: int, count: int) -> int:
	var taken: int = mini(count, crew_alive)
	var target: CompartmentState = compartment(compartment_index)
	if target != null:
		taken = mini(taken, maxi(target.crew, 0) + taken)
		target.crew = maxi(target.crew - count, 0)
	crew_alive = maxi(crew_alive - taken, 0)
	return taken


## Total floodable volume standing under water, in cubic metres.
func flooded_volume(template: ShipStructureTemplate, permeability: Dictionary) -> float:
	var total: float = 0.0
	for i: int in compartments.size():
		var compartment_state: CompartmentState = compartments[i]
		if compartment_state == null or compartment_state.flood <= 0.0:
			continue
		var volume: GeometryPrimitives.Volume = template.volumes[i]
		var permeable: float = float(permeability.get(volume.role, permeability.get("default", 0.9)))
		total += volume.volume_m3() * permeable * compartment_state.flood
	return total


func compartments_on_fire() -> int:
	var count: int = 0
	for compartment_state: CompartmentState in compartments:
		if compartment_state != null and compartment_state.fire > 0.01:
			count += 1
	return count


func components_with_role(template: ShipStructureTemplate, role: String) -> Array[ComponentState]:
	var out: Array[ComponentState] = []
	for index: int in template.volumes_with_role(role):
		var found: ComponentState = component(index)
		if found != null:
			out.append(found)
	return out


func hash_into(hasher: StateHasher) -> void:
	hasher.write_int(crew_alive)
	hasher.write_float(girder_damage)
	hasher.write_bool(catastrophic)
	for compartment_state: CompartmentState in compartments:
		if compartment_state == null:
			continue
		hasher.write_float(compartment_state.flood)
		hasher.write_float(compartment_state.fire)
		hasher.write_float(compartment_state.wreckage)
		hasher.write_bool(compartment_state.breached)
		hasher.write_int(compartment_state.crew)
	for component_state: ComponentState in components:
		if component_state == null:
			continue
		hasher.write_float(component_state.condition)
	for value: float in plate_deformation:
		hasher.write_float(value)


## Restore from a snapshot.
##
## Written next to `serialize()` and kept symmetric with it deliberately: the pair is
## checked by re-simulating from a restored snapshot and requiring the same checksum as
## the straight-through run, so a field that is written and not read shows up as a
## divergence rather than as a subtly different battle three minutes later.
func deserialize(data: Dictionary) -> void:
	crew_total = int(data.get("crewTotal", crew_total))
	crew_alive = int(data.get("crewAlive", crew_alive))
	girder_damage = float(data.get("girderDamage", girder_damage))
	catastrophic = bool(data.get("catastrophic", catastrophic))
	catastrophe_reason = str(data.get("catastropheReason", catastrophe_reason))

	var compartment_data: Array = data.get("compartments", []) as Array
	for i: int in mini(compartment_data.size(), compartments.size()):
		var entry: Variant = compartment_data[i]
		var compartment_state: CompartmentState = compartments[i]
		if entry == null or compartment_state == null:
			continue
		var row: Dictionary = entry as Dictionary
		compartment_state.flood = float(row.get("flood", 0.0))
		compartment_state.fire = float(row.get("fire", 0.0))
		compartment_state.wreckage = float(row.get("wreckage", 0.0))
		compartment_state.breached = bool(row.get("breached", false))
		compartment_state.breach_area_m2 = float(row.get("breachAreaM2", 0.0))
		compartment_state.breach_depth_m = float(row.get("breachDepthM", 0.0))
		compartment_state.crew = int(row.get("crew", 0))
		compartment_state.ammunition = float(row.get("ammunition", 0.0))

	var component_data: Array = data.get("components", []) as Array
	for i: int in mini(component_data.size(), components.size()):
		var entry: Variant = component_data[i]
		if entry == null or components[i] == null:
			continue
		components[i].condition = float((entry as Dictionary).get("condition", 1.0))

	var deformation: Array = data.get("plateDeformation", []) as Array
	for i: int in mini(deformation.size(), plate_deformation.size()):
		plate_deformation[i] = float(deformation[i])


func serialize() -> Dictionary:
	var compartment_data: Array = []
	for compartment_state: CompartmentState in compartments:
		if compartment_state == null:
			compartment_data.append(null)
		else:
			compartment_data.append({
				"flood": compartment_state.flood, "fire": compartment_state.fire,
				"wreckage": compartment_state.wreckage, "breached": compartment_state.breached,
				"breachAreaM2": compartment_state.breach_area_m2,
				"breachDepthM": compartment_state.breach_depth_m,
				"crew": compartment_state.crew, "ammunition": compartment_state.ammunition,
			})
	var component_data: Array = []
	for component_state: ComponentState in components:
		component_data.append(null if component_state == null
			else {"condition": component_state.condition})
	return {
		"crewTotal": crew_total, "crewAlive": crew_alive,
		"girderDamage": girder_damage,
		"catastrophic": catastrophic, "catastropheReason": catastrophe_reason,
		"compartments": compartment_data, "components": component_data,
		"plateDeformation": Array(plate_deformation),
	}
