@tool
class_name FlowEnableInputNode
extends FlowGraphNode

@export var lease_id: StringName = &"game_flow"


func type_id() -> StringName:
	return &"enable_input"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Enable Input"


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if lease_id.is_empty():
		issues.append(_missing_id_issue("lease_id", &"enable_input_missing_lease", graph_id))
	return issues
