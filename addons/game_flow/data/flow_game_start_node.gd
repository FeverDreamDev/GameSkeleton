@tool
class_name FlowGameStartNode
extends FlowGraphNode


func type_id() -> StringName:
	return &"game_start"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Game Start"


func input_ports() -> Array[StringName]:
	return [] as Array[StringName]


func is_entry_node() -> bool:
	return true
