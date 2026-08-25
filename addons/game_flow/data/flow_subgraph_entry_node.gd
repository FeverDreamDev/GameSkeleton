@tool
class_name FlowSubgraphEntryNode
extends FlowGraphNode


func type_id() -> StringName:
	return &"subgraph_entry"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Subgraph Starts Here"


func input_ports() -> Array[StringName]:
	return [] as Array[StringName]


func is_entry_node() -> bool:
	return true
