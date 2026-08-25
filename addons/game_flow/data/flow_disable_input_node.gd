@tool
class_name FlowDisableInputNode
extends FlowGraphNode

## Logical ownership id. Input stays disabled until the matching lease is enabled/released.
@export var lease_id: StringName = &"game_flow"


func type_id() -> StringName:
	return &"disable_input"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Lock Player Controls"


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if lease_id.is_empty():
		issues.append(_missing_id_issue("lease_id", &"disable_input_missing_lease", graph_id))
	return issues
