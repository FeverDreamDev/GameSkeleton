extends Node

## Minimal Retro RT example scene. Everything here is ordinary Godot: the RT
## work is done by the RTSceneManager node beside this one, and the meshes just
## need materials running BlinnPhong.gdshader. This script only spins two of
## them so shadows and reflections are visibly moving.


@onready var doughnut: MeshInstance3D = $Doughnut
@onready var doughnut_2: MeshInstance3D = $Doughnut2



func _physics_process(delta: float) -> void:
	doughnut.rotate_y(rad_to_deg(.015 * delta))
	doughnut_2.rotate_y(rad_to_deg(.015 * delta))
