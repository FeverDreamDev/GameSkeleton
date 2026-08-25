@tool
class_name FlowRequestSaveNode
extends FlowGraphNode

@export var reason: StringName = &"checkpoint"


func type_id() -> StringName:
	return &"request_save"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Request Save"


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if reason.is_empty():
		issues.append(_missing_id_issue("reason", &"request_save_missing_reason", graph_id))
	return issues
