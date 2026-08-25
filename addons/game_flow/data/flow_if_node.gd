@tool
class_name FlowIfNode
extends FlowGraphNode

const TRUE_PORT := &"true"
const FALSE_PORT := &"false"

@export var condition: FlowCondition


func type_id() -> StringName:
	return &"if"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Check: %s" % condition.describe() if condition != null else "Check Condition"


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
			"Choose a condition for this Check Condition step.",
			graph_id,
			node_id
		)] as Array[FlowValidationIssue]
	return condition.validation_issues(graph_id, node_id)
