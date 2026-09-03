class_name CarrierOperations
extends RefCounted

## What a carrier can still do, read off the state of her own structure.
##
## This is the isolation boundary, and it is worth being precise about where it runs.
## The damage core wrecks a flight deck, floods a hangar and jams an elevator as
## ordinary geometry — the same faces, volumes and components it uses for a boiler
## room, resolved by the same tracer and the same damage chain. It has no idea what any
## of them are FOR. Knowing that a jammed elevator means aircraft cannot be brought up
## from the hangar, and that a hangar fire means nothing flies at all, is the air
## module's business, and this file is where it looks.
##
## Which means: a carrier in a battle with the air module unregistered is still a ship
## whose flight deck can be wrecked. She simply has nobody to tell.

class Capability extends RefCounted:
	var can_launch: bool = true
	var can_recover: bool = true
	var deck_condition: float = 1.0     ## 0 wrecked, 1 clear
	var elevators_working: int = 0
	var hangar_fire: float = 0.0
	var hangar_flooded: float = 0.0
	var aircraft_capacity: int = 0
	var reason: String = ""

	func is_operational() -> bool:
		return can_launch or can_recover


## Assess a carrier. A ship that is not a carrier is reported as unable to fly, which
## is not a special case — it is the truth, and it means the module needs no test for
## ship type before asking.
static func assess(ship: ShipEntity, template: ShipStructureTemplate,
		state: ShipStructureState, config: Dictionary) -> Capability:
	var capability: Capability = Capability.new()
	if ship == null or not ship.spec.is_carrier() or state == null or template == null:
		capability.can_launch = false
		capability.can_recover = false
		capability.reason = "not a carrier"
		return capability
	if not ship.is_afloat():
		capability.can_launch = false
		capability.can_recover = false
		capability.reason = "sunk"
		return capability

	var carrier: Dictionary = config.get("carrier", {}) as Dictionary
	capability.aircraft_capacity = int(ship.spec.aviation.get("aircraft", 0))

	# The flight deck itself.
	var decks: Array[ShipStructureState.ComponentState] = state.components_with_role(
		template, ShipStructureBuilder.COMPONENT_FLIGHT_DECK)
	capability.deck_condition = 0.0 if decks.is_empty() else decks[0].condition
	if decks.is_empty():
		capability.deck_condition = 1.0

	# Elevators. Without one, whatever is in the hangar stays in the hangar — which is
	# why a single bomb down an open elevator well could end a carrier's day without
	# coming close to sinking her.
	for elevator: ShipStructureState.ComponentState in state.components_with_role(
			template, ShipStructureBuilder.COMPONENT_ELEVATOR):
		if elevator.is_operational():
			capability.elevators_working += 1

	# The hangar: fire in it, and water in it.
	for index: int in template.volumes_with_role(ShipStructureBuilder.ROLE_HANGAR):
		var compartment: ShipStructureState.CompartmentState = state.compartment(index)
		if compartment == null:
			continue
		capability.hangar_fire = maxf(capability.hangar_fire, compartment.fire)
		capability.hangar_flooded = maxf(capability.hangar_flooded, compartment.flood)

	var minimum_deck: float = float(carrier.get("minimumDeckCondition", 0.35))
	var minimum_elevators: int = int(carrier.get("minimumElevators", 1))
	var grounding_fire: float = float(carrier.get("hangarFireGrounding", 0.25))

	if capability.hangar_fire >= grounding_fire:
		capability.can_launch = false
		capability.can_recover = false
		capability.reason = "hangar fire"
		return capability
	if capability.deck_condition < minimum_deck:
		capability.can_launch = false
		capability.can_recover = false
		capability.reason = "flight deck wrecked"
		return capability
	if capability.elevators_working < minimum_elevators:
		# She can still land aircraft on and range whatever is already on deck; she
		# cannot bring anything up. A carrier in this state is a one-strike ship.
		capability.can_launch = false
		capability.reason = "no serviceable elevator"
		return capability
	# A listing carrier cannot operate aircraft long before she is in danger of
	# capsizing: an angled deck is not something a Dauntless can land on.
	if absf(ship.list_degrees()) > 12.0:
		capability.can_launch = false
		capability.can_recover = false
		capability.reason = "listing too far to fly"
		return capability

	capability.reason = "operational"
	return capability


## How many aircraft can be ranged on deck for one launch.
static func deck_spot(capability: Capability, config: Dictionary) -> int:
	var carrier: Dictionary = config.get("carrier", {}) as Dictionary
	var nominal: int = int(carrier.get("deckSpotAircraft", 24))
	return int(float(nominal) * clampf(capability.deck_condition, 0.0, 1.0))
