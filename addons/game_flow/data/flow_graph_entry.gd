@tool
class_name FlowGraphEntry
extends Resource

## A stable registry id mapped to one graph Resource.
##
## Story rules and save data refer to graph_id, never to a res:// path. The graph may therefore be
## moved or split into another resource without invalidating authored subgraph calls or saves.

@export var graph_id: StringName = &""
@export var graph: FlowGraph
@export var display_name: String = ""


func label() -> String:
	if not display_name.is_empty():
		return display_name
	if graph != null and not graph.display_name.is_empty():
		return graph.display_name
	return String(graph_id)
