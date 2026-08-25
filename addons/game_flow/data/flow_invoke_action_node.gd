@tool
class_name FlowInvokeActionNode
extends FlowGraphNode

const COMPLETED_PORT := &"completed"
const FAILED_PORT := &"failed"

## Stable id resolved through the game's action executor registry at runtime.
@export var action_id: StringName = &""
@export var arguments: Dictionary = {}


func type_id() -> StringName:
	return &"invoke_action"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Run Game Action: %s" % _friendly_name(action_id) \
			if not action_id.is_empty() else "Run Game Action"


func output_ports() -> Array[StringName]:
	return [COMPLETED_PORT, FAILED_PORT] as Array[StringName]


func is_blocking_node() -> bool:
	return true


func validation_issues(
		database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if action_id.is_empty():
		issues.append(_missing_id_issue("action_id", &"invoke_action_missing_id", graph_id))
	elif database != null and database.has_custom_action_catalog() \
			and database.get_custom_action(action_id) == null:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"invoke_action_unknown_id",
			"Game Action '%s' could not be found in the Game Flow library." % action_id,
			graph_id,
			node_id
		))
	issues.append_array(_persistence_issues(
		arguments, "arguments", &"invoke_action_unsafe_arguments", graph_id))
	return issues
