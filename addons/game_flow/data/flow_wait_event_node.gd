@tool
class_name FlowWaitEventNode
extends FlowGraphNode

@export var event_id: StringName = &""


func type_id() -> StringName:
	return &"wait_event"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Wait: %s" % event_id if not event_id.is_empty() else "Wait For Event"


func is_blocking_node() -> bool:
	return true


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if event_id.is_empty():
		issues.append(_missing_id_issue("event_id", &"wait_event_missing_event", graph_id))
	return issues
