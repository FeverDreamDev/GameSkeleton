@tool
class_name FlowSubgraphExitNode
extends FlowGraphNode

@export var exit_id: StringName = &"completed"


func type_id() -> StringName:
	return &"subgraph_exit"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Exit: %s" % exit_id if not exit_id.is_empty() else "Subgraph Exit"


func output_ports() -> Array[StringName]:
	return [] as Array[StringName]


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if exit_id.is_empty():
		issues.append(_missing_id_issue("exit_id", &"subgraph_exit_missing_id", graph_id))
	elif exit_id == &"failed":
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"subgraph_exit_reserved_id",
			"subgraph exit id 'failed' is reserved for call-resolution failures",
			graph_id,
			node_id
		))
	return issues
