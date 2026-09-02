class_name DamageReport
extends RefCounted

## What a hit actually did to the ship, derived from its HitReport.
##
## Stage 4 fills this in. It exists here so that HitReport can carry the complete
## chain in one object from the outset, rather than having the effects live somewhere
## else and be correlated back afterwards.
##
## Note what is absent: there is no "damage" field that a shell contributes to a
## health pool. Structural integrity is recomputed from the ship's condition, and
## `integrity_delta` below is the OBSERVED change that resulted — a report of what
## happened, not the mechanism by which it happened.

class Effect extends RefCounted:
	var kind: StringName = &""      ## fire, flooding, spall, shock, casualties, explosion, breach
	var target_index: int = -1      ## compartment or component
	var label: String = ""
	var magnitude: float = 0.0
	var note: String = ""

	func to_dict() -> Dictionary:
		return {"kind": String(kind), "label": label, "magnitude": magnitude, "note": note}


var effects: Array[Effect] = []
var crew_casualties: int = 0
var integrity_before: float = 1.0
var integrity_after: float = 1.0
var buoyancy_delta: float = 0.0
var component_transitions: Array[String] = []
var catastrophic: bool = false
var catastrophe_reason: String = ""


func add_effect(kind: StringName, label: String, magnitude: float, note: String = "",
		target_index: int = -1) -> Effect:
	var effect: Effect = Effect.new()
	effect.kind = kind
	effect.label = label
	effect.magnitude = magnitude
	effect.note = note
	effect.target_index = target_index
	effects.append(effect)
	return effect


func integrity_delta() -> float:
	return integrity_after - integrity_before


func has_effect(kind: StringName) -> bool:
	for effect: Effect in effects:
		if effect.kind == kind:
			return true
	return false


func to_dict() -> Dictionary:
	var list: Array = []
	for effect: Effect in effects:
		list.append(effect.to_dict())
	return {
		"effects": list,
		"crewCasualties": crew_casualties,
		"integrityBefore": integrity_before,
		"integrityAfter": integrity_after,
		"componentTransitions": component_transitions,
		"catastrophic": catastrophic,
		"catastropheReason": catastrophe_reason,
	}
