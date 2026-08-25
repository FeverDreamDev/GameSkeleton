@tool
class_name FlowPlayCutsceneNode
extends FlowGraphNode

const COMPLETED_PORT := &"completed"
const FAILED_PORT := &"failed"

@export var cutscene_id: StringName = &""
@export var context: Dictionary = {}


func type_id() -> StringName:
	return &"play_cutscene"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Play Cutscene: %s" % _friendly_name(cutscene_id) \
			if not cutscene_id.is_empty() else "Play Cutscene"


func output_ports() -> Array[StringName]:
	return [COMPLETED_PORT, FAILED_PORT] as Array[StringName]


func is_blocking_node() -> bool:
	return true


func validation_issues(
		database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if cutscene_id.is_empty():
		issues.append(_missing_id_issue("cutscene_id", &"play_cutscene_missing_id", graph_id))
	elif database != null and database.get_cutscene(cutscene_id) == null:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"play_cutscene_unknown_id",
			"Cutscene '%s' could not be found in the Game Flow library." % cutscene_id,
			graph_id,
			node_id
		))
	issues.append_array(_persistence_issues(
		context, "context", &"play_cutscene_unsafe_context", graph_id))
	return issues
