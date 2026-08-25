@tool
class_name FlowClearFlagNode
extends FlowGraphNode

@export var flag_id: StringName = &""


func type_id() -> StringName:
	return &"clear_flag"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Clear Story Flag: %s" % _friendly_name(flag_id) \
			if not flag_id.is_empty() else "Clear Story Flag"


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if flag_id.is_empty():
		issues.append(_missing_id_issue("flag_id", &"clear_flag_missing_flag", graph_id))
	return issues
