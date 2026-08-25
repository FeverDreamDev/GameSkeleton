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
	return "Run Subgraph: %s" % _friendly_name(subgraph_id) \
			if not subgraph_id.is_empty() else "Run Subgraph"


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
			"Subgraph '%s' could not be found in the Game Flow library." % subgraph_id,
			graph_id,
			node_id
		))
	var seen := {}
	for exit_id: StringName in exit_ids:
		if exit_id.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"call_subgraph_empty_exit",
				"Run Subgraph has an empty result name.",
				graph_id,
				node_id
			))
		elif exit_id == &"failed":
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"call_subgraph_reserved_exit",
				"'Failed' is reserved for problems starting a subgraph. Choose another result name.",
				graph_id,
				node_id
			))
		elif seen.has(exit_id):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"call_subgraph_duplicate_exit",
				"Run Subgraph lists the result '%s' more than once." % exit_id,
				graph_id,
				node_id
			))
		else:
			seen[exit_id] = true
	if exit_ids.is_empty():
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"call_subgraph_no_exits",
			"Run Subgraph needs at least one possible result.",
			graph_id,
			node_id
		))
	return issues
