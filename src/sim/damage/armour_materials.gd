class_name ArmourMaterials
extends RefCounted

## Armour plate materials and their quality factors.
##
## The quality factor scales a plate's resistance relative to US Class A at 1.00.
## These are the most contested numbers in the project — wartime and post-war
## assessments disagree, national test methods differed, and plate quality varied
## between batches — which is exactly why they live in data and carry confidence
## markers. See docs/SOURCES.md.

const FALLBACK_QUALITY: float = 0.95

var _materials: Dictionary = {}


static func load_from(path: String) -> ArmourMaterials:
	var registry: ArmourMaterials = ArmourMaterials.new()
	registry._materials = JsonLoader.load_dict(path).get("materials", {}) as Dictionary
	if registry._materials.is_empty():
		push_error("ArmourMaterials: no materials loaded from %s" % path)
	return registry


func has(material_id: String) -> bool:
	return _materials.has(material_id)


func _entry(material_id: String) -> Dictionary:
	var found: Variant = _materials.get(material_id)
	if found == null:
		push_warning("ArmourMaterials: unknown material '%s'" % material_id)
		return {}
	return found as Dictionary


## Resistance relative to US Class A.
func quality(material_id: String) -> float:
	return float(_entry(material_id).get("qualityFactor", FALLBACK_QUALITY))


## Face-hardened plate is markedly better against uncapped shells, which it tends to
## shatter, and markedly worse against a capped shell that can punch the hard face
## through. Homogeneous plate has no such asymmetry, which is why decks, bulkheads
## and torpedo protection are made of it.
func is_face_hardened(material_id: String) -> bool:
	return bool(_entry(material_id).get("faceHardened", false))


func density(material_id: String) -> float:
	return float(_entry(material_id).get("densityKgM3", 7850.0))


func display_name(material_id: String) -> String:
	return str(_entry(material_id).get("name", material_id))


func confidence(material_id: String) -> String:
	return str(_entry(material_id).get("confidence", "unknown"))


func material_ids() -> Array[String]:
	return Serializer.sorted_keys(_materials)
