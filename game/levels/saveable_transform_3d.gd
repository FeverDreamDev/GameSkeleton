class_name SaveableTransform3D
extends Node3D

## Minimal scene-relative save contract used by the integration level's movable
## reflector. Production levels can use the same `saveable` group and methods
## for doors, pickups, switches, and other local state.


func save_state() -> Dictionary:
	return {
		"transform": transform,
		"visible": visible,
	}


func load_state(state: Dictionary) -> void:
	var saved_transform: Variant = state.get("transform")
	if saved_transform is Transform3D:
		transform = saved_transform
	visible = bool(state.get("visible", visible))
