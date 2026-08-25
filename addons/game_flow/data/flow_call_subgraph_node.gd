@tool
class_name FlowCallSubgraphNode
extends FlowGraphNode

@export var subgraph_id: StringName = &""
## Stable named output ports expected from the called graph's FlowSubgraphExitNodes.
@export var exit_ids: Array[StringName] = [&"completed"]


func type_id() -> StringName:
	return &"call_subgraph"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Call: %s" % subgraph_id if not subgraph_id.is_empty() else "Call Subgraph"


func output_ports() -> Array[StringName]:
	var ports: Array[StringName] = []
	for exit_id: StringName in exit_ids:
		if not exit_id.is_empty() and not ports.has(exit_id):
			ports.append(exit_id)
	if not ports.has(&"failed"):
		ports.append(&"failed")
	return ports


func is_blocking_node() -> bool:
	return true


func validation_issues(
		database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if subgraph_id.is_empty():
		issues.append(_missing_id_issue("subgraph_id", &"call_subgraph_missing_graph", graph_id))
	elif database != null and database.get_graph(subgraph_id) == null:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"call_subgraph_unknown_graph",
			"subgraph '%s' is not registered" % subgraph_id,
			graph_id,
			node_id
		))
	var seen := {}
	for exit_id: StringName in exit_ids:
		if exit_id.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"call_subgraph_empty_exit",
				"call subgraph has an empty exit port",
				graph_id,
				node_id
			))
		elif exit_id == &"failed":
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"call_subgraph_reserved_exit",
				"exit id 'failed' is reserved for call-resolution failures",
				graph_id,
				node_id
			))
		elif seen.has(exit_id):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"call_subgraph_duplicate_exit",
				"call subgraph repeats exit '%s'" % exit_id,
				graph_id,
				node_id
			))
		else:
			seen[exit_id] = true
	if exit_ids.is_empty():
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"call_subgraph_no_exits",
			"call subgraph exposes no exit ports",
			graph_id,
			node_id
		))
	return issues
