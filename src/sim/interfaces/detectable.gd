class_name Detectable
extends RefCounted

## The contract for something that can be seen, and the description of how it is seen.
##
## `SimEntity` has already spent GDScript's single inheritance, so this is a contract
## rather than a base class. It is not left to trust: `Detectable.require(entity)`
## asserts that an entity really does implement it, and the detection system calls that
## when an entity is registered. A missing method fails loudly at registration instead
## of quietly never being detected in the middle of a battle.
##
## What a Detectable must provide:
##
##   detection_signature() -> Detectable.Signature
##
## and that is all. Everything else detection needs it gets from `SimEntity`.

const REQUIRED_METHOD: StringName = &"detection_signature"


## How visible something is, and from how far away it can be seen at all.
##
## The horizon is the part that surprises people. A ship is not detected at some
## nominal "spotting range" — she is detected when her upperworks rise above the
## curve of the earth as seen from the observer's own masthead, which is why the
## masts are sighted long before the hull, why a destroyer sees a battleship well
## before the battleship sees her, and why the tallest thing on a warship was so often
## the thing men were standing in.
class Signature extends RefCounted:
	## Height of the highest thing worth sighting, metres above the waterline. Sets
	## both how far this entity can see and how far away it can be seen.
	var height_m: float = 10.0

	## Broadside silhouette area, m². What decides whether a contact at the horizon
	## resolves into a ship or stays a smudge.
	var silhouette_m2: float = 1000.0

	## Radar return, as an area in m². A proxy rather than a real cross-section: it
	## scales with size and is not claimed to be more than that.
	var radar_area_m2: float = 1000.0

	## Set while she is firing. A gun flash at night is visible far beyond anything
	## else about her, and it is how most night actions actually opened.
	var firing: bool = false

	## Set while she is burning. A fire aboard is a beacon, and it is why a damaged
	## ship at night was so much easier to finish.
	var burning: float = 0.0


## Assert that `entity` really implements the contract. Called where entities enter the
## detection plot, so a module that forgets fails at registration and not in battle.
static func require(entity: SimEntity) -> bool:
	if entity == null:
		return false
	assert(entity.has_method(REQUIRED_METHOD),
		"%s must implement %s() to be detectable" % [entity, REQUIRED_METHOD])
	return entity.has_method(REQUIRED_METHOD)
