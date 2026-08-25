@tool
class_name FlowLoadLevelNode
extends FlowGraphNode

const COMPLETED_PORT := &"completed"
const FAILED_PORT := &"failed"

@export var level_id: StringName = &""
@export var spawn_id: StringName = &""
@export var transition_data: Dictionary = {}


func type_id() -> StringName:
	return &"load_level"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Load: %s" % level_id if not level_id.is_empty() else "Load Level"


func output_ports() -> Array[StringName]:
	return [COMPLETED_PORT, FAILED_PORT] as Array[StringName]


func is_blocking_node() -> bool:
	return true


func validation_issues(
		database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if level_id.is_empty():
		issues.append(_missing_id_issue("level_id", &"load_level_missing_id", graph_id))
	elif database != null and database.get_level(level_id) == null:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"load_level_unknown_id",
			"level '%s' is not registered" % level_id,
			graph_id,
			node_id
		))
	issues.append_array(_persistence_issues(
		transition_data, "transition_data", &"load_level_unsafe_transition_data", graph_id))
	return issues
