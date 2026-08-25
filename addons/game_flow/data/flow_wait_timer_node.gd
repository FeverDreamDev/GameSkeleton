@tool
class_name FlowWaitTimerNode
extends FlowGraphNode

@export_range(0.0, 86400.0, 0.01, "or_greater", "suffix:s") var seconds: float = 1.0


func type_id() -> StringName:
	return &"wait_timer"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	var amount := str(int(seconds)) if is_equal_approx(seconds, roundf(seconds)) \
			else String.num(seconds, 2).trim_suffix("0").trim_suffix(".")
	return "Wait %s %s" % [amount, "Second" if is_equal_approx(seconds, 1.0) else "Seconds"]


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
			"Time in Seconds must be greater than zero.",
			graph_id,
			node_id
		))
	return issues
