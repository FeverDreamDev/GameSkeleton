@tool
class_name FlowIfNode
extends FlowGraphNode

const TRUE_PORT := &"true"
const FALSE_PORT := &"false"

@export var condition: FlowCondition


func type_id() -> StringName:
	return &"if"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "If / Else"


func output_ports() -> Array[StringName]:
	return [TRUE_PORT, FALSE_PORT] as Array[StringName]


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	if condition == null:
		return [FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"if_missing_condition",
			"IF node has no condition",
			graph_id,
			node_id
		)] as Array[FlowValidationIssue]
	return condition.validation_issues(graph_id, node_id)
