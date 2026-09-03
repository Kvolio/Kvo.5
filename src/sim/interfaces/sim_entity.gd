class_name SimEntity
extends RefCounted

## Anything the world holds a position for.
##
## This exists so that the optional air module can put aircraft into the same spatial
## index, the same detection plot and the same formation logic as ships without any of
## those systems learning what an aircraft is. Ships and aircraft are both SimEntity;
## nothing above this line knows there is a difference.
##
## GDScript has single inheritance and no interfaces, and this class spends it. The
## other contracts the architecture calls for — `Damageable`, `Detectable`,
## `OrdnanceSource` — are therefore documented contracts rather than base classes, and
## are ASSERTED at the point where an entity is registered rather than assumed. See
## `detectable.gd` for the pattern.

var id: int = 0
var team: int = 0
var display_name: String = ""

## World position on the z = 0 plane. Height, where an entity has one, belongs to the
## entity: a shell and an aircraft both carry it, and neither is a ship.
var position: Vector2 = Vector2.ZERO


## Still in the game. A sunk ship and a shot-down aircraft both answer false, and every
## system that iterates entities is expected to ask.
func is_alive() -> bool:
	return true


## Velocity in the world frame, m/s. Detection, fire control and formation keeping all
## need it and none of them should care how the entity arrives at it.
func velocity() -> Vector2:
	return Vector2.ZERO


## Which spatial layer this entity belongs in.
func spatial_layer() -> int:
	return SpatialIndex.Layer.SHIP


## Radius used for spatial queries, in metres.
func spatial_radius() -> float:
	return 1.0
