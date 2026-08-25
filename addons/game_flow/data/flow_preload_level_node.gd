@tool
class_name FlowPreloadLevelNode
extends FlowGraphNode

@export var level_id: StringName = &""


func type_id() -> StringName:
	return &"preload_level"


func display_title() -> String:
	if not title_override.is_empty():
		return title_override
	return "Prepare Level: %s" % _friendly_name(level_id) \
			if not level_id.is_empty() else "Prepare Level"


func validation_issues(
		database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if level_id.is_empty():
		issues.append(_missing_id_issue("level_id", &"preload_level_missing_id", graph_id))
	elif database != null and database.get_level(level_id) == null:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"preload_level_unknown_id",
			"Level '%s' could not be found in the Game Flow library." % level_id,
			graph_id,
			node_id
		))
	return issues
