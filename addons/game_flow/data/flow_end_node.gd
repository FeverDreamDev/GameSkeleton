@tool
class_name FlowEndNode
extends FlowGraphNode


func type_id() -> StringName:
	return &"end"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "End"


func output_ports() -> Array[StringName]:
	return [] as Array[StringName]
