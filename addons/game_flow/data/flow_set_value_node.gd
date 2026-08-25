@tool
class_name FlowSetValueNode
extends FlowGraphNode

@export var value_key: StringName = &""
@export var value: Variant = null


func type_id() -> StringName:
	return &"set_value"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Set Story Value: %s" % _friendly_name(value_key) \
			if not value_key.is_empty() else "Set Story Value"


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if value_key.is_empty():
		issues.append(_missing_id_issue("value_key", &"set_value_missing_key", graph_id))
	issues.append_array(_persistence_issues(
		value, "value", &"set_value_unsafe_value", graph_id))
	return issues
