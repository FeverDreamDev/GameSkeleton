@tool
class_name FlowEventEntryNode
extends FlowGraphNode

@export var event_id: StringName = &""
@export var one_shot: bool = false


func type_id() -> StringName:
	return &"event_entry"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Event: %s" % event_id if not event_id.is_empty() else "Event Entry"


func input_ports() -> Array[StringName]:
	return [] as Array[StringName]


func is_entry_node() -> bool:
	return true


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if event_id.is_empty():
		issues.append(_missing_id_issue("event_id", &"event_entry_missing_event", graph_id))
	return issues
