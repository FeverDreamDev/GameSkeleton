@tool
class_name FlowParallelNode
extends FlowGraphNode

## Every enabled connection leaving `out` receives an independent execution token.


func type_id() -> StringName:
	return &"parallel"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Start Multiple Paths"
