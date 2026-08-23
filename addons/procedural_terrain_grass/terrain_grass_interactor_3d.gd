@tool
@icon("res://addons/procedural_terrain_grass/icons/terrain_grass_interactor_3d.svg")
class_name TerrainGrassInteractor3D
extends Node3D

## Bends grass around a moving node.
##
## Add one as a child of a character, vehicle or physics body. The parent is
## what gets registered, so the interactor follows whatever it hangs beneath.
## The terrain system uploads the highest-scoring few interactors to the grass
## shader each frame; [member priority] is what keeps the player in that set.

const TerrainGrassBinding = preload("res://addons/procedural_terrain_grass/core/terrain_grass_binding.gd")

## Radius of the bend, in metres.
@export_range(0.05, 10.0, 0.05, "or_greater") var radius: float = 0.55
## How hard the grass is pushed aside and flattened inside the radius.
@export_range(0.0, 4.0, 0.05) var strength: float = 1.0
## Interactors are ranked by priority first, then by distance to the streaming
## target. Give the player a high value so it is never displaced.
@export var priority: int = 0
## Terrain system to attach to. Only needed when a scene holds more than one
## TerrainGrass3D; otherwise the single system is found automatically.
@export_node_path("Node3D") var terrain_system_path: NodePath

var _terrain_system: Node
var _registered_node: Node3D


# Binding happens on every tree entry rather than in _ready, so an interactor
# that is removed and re-added later rejoins the system instead of going inert.
func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		_register_with_manager.call_deferred()


func _exit_tree() -> void:
	if is_instance_valid(_terrain_system) and is_instance_valid(_registered_node):
		_terrain_system.unregister_grass_interactor(_registered_node)
	_terrain_system = null
	_registered_node = null


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if get_parent() != null and not (get_parent() is Node3D):
		warnings.append(
			"TerrainGrassInteractor3D registers its parent, so it should be a child of a Node3D."
		)
	return warnings


func _register_with_manager() -> void:
	# The deferred call can land after the node left the tree again.
	if not is_inside_tree():
		return
	_terrain_system = TerrainGrassBinding.resolve_system(self, terrain_system_path, "TerrainGrassInteractor3D")
	if not is_instance_valid(_terrain_system):
		return
	# Registering the parent means the interactor tracks the body it is attached
	# to; standing alone it just tracks itself.
	_registered_node = get_parent() as Node3D
	if not is_instance_valid(_registered_node):
		_registered_node = self
	_terrain_system.register_grass_interactor(_registered_node)
