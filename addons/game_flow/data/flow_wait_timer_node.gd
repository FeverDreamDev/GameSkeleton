@tool
class_name FlowWaitTimerNode
extends FlowGraphNode

@export_range(0.0, 86400.0, 0.01, "or_greater", "suffix:s") var seconds: float = 1.0


func type_id() -> StringName:
	return &"wait_timer"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Wait %.2fs" % seconds


func is_blocking_node() -> bool:
	return true


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if not is_finite(seconds) or seconds <= 0.0:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"wait_timer_non_positive",
			"wait duration must be greater than zero",
			graph_id,
			node_id
		))
	return issues
