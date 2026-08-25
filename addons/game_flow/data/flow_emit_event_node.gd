@tool
class_name FlowEmitEventNode
extends FlowGraphNode

@export var event_id: StringName = &""
@export var data: Dictionary = {}


func type_id() -> StringName:
	return &"emit_event"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Send Event: %s" % _friendly_name(event_id) \
			if not event_id.is_empty() else "Send Event"


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if event_id.is_empty():
		issues.append(_missing_id_issue("event_id", &"emit_event_missing_event", graph_id))
	issues.append_array(_persistence_issues(
		data, "data", &"emit_event_unsafe_data", graph_id))
	return issues
