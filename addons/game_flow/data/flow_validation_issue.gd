@tool
class_name FlowValidationIssue
extends Resource

## One structured problem found while validating flow graph data.
##
## The runtime, editor plugin and command-line checks all share this type. It deliberately contains
## only stable logical ids -- never editor controls or live scene-tree objects.

enum Severity {
	INFO,
	WARNING,
	ERROR,
}

@export var severity: Severity = Severity.ERROR
@export var code: StringName = &""
@export_multiline var message: String = ""
@export var graph_id: StringName = &""
@export var graph_path: String = ""
@export var node_id: StringName = &""
@export var connection_id: StringName = &""
@export var port_id: StringName = &""


static func make(
		issue_severity: Severity,
		issue_code: StringName,
		issue_message: String,
		issue_graph_id: StringName = &"",
		issue_node_id: StringName = &"",
		issue_connection_id: StringName = &"",
		issue_graph_path: String = "",
		issue_port_id: StringName = &""
) -> FlowValidationIssue:
	var issue := FlowValidationIssue.new()
	issue.severity = issue_severity
	issue.code = issue_code
	issue.message = issue_message
	issue.graph_id = issue_graph_id
	issue.graph_path = issue_graph_path
	issue.node_id = issue_node_id
	issue.connection_id = issue_connection_id
	issue.port_id = issue_port_id
	return issue


func is_error() -> bool:
	return severity == Severity.ERROR


func severity_name() -> String:
	return Severity.keys()[severity] as String


func format_message() -> String:
	var location := PackedStringArray()
	if not graph_id.is_empty():
		location.append("graph '%s'" % graph_id)
	elif not graph_path.is_empty():
		location.append(graph_path)
	if not node_id.is_empty():
		location.append("node '%s'" % node_id)
	if not connection_id.is_empty():
		location.append("connection '%s'" % connection_id)
	if not port_id.is_empty():
		location.append("port '%s'" % port_id)
	return "%s: %s" % [", ".join(location), message] if not location.is_empty() else message
