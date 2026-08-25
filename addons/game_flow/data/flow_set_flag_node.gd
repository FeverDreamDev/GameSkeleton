@tool
class_name FlowSetFlagNode
extends FlowGraphNode

@export var flag_id: StringName = &""
@export var flag_value: bool = true


func type_id() -> StringName:
	return &"set_flag"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Set Flag"


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if flag_id.is_empty():
		issues.append(_missing_id_issue("flag_id", &"set_flag_missing_flag", graph_id))
	return issues
