extends Node

## Autoload wrapper around the simulation's Armory.
##
## The registry itself lives in res://src/sim/weapons/armory.gd so that a battle can
## be built and run with no scene tree at all. This node exists only to give the game
## and the UI a convenient place to reach it from.

const GUN_DIR: String = "res://data/guns"
const AMMO_DIR: String = "res://data/ammo"

var _armory: Armory = null


func _ready() -> void:
	reload()


func reload() -> void:
	_armory = Armory.load_from(GUN_DIR, AMMO_DIR, GameConfig.get_dict("ballistics"))


## The registry itself. Hand this to SimWorld rather than reaching back through the
## autoload from inside the simulation.
func armory() -> Armory:
	if _armory == null:
		reload()
	return _armory
