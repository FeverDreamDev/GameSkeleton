@tool
class_name FlowGraphNode
extends Resource

## Runtime-safe authored node data shared by the runner and editor.
##
## Subclasses expose stable logical port ids. Editor slot indexes, GraphNode instances and other
## presentation state never cross this boundary.

const INPUT_PORT := &"in"
const OUTPUT_PORT := &"out"

## Maintained by the graph editor. These remain serialized but are intentionally hidden from the
## author-facing Inspector so a designer cannot accidentally break connections or canvas layout.
@export_storage var node_id: StringName = &""
@export_storage var editor_position: Vector2 = Vector2.ZERO
@export var title_override: String = ""
@export_multiline var comment: String = ""
@export var enabled: bool = true


## Stable registration id used by the runtime executor and editor palette.
func type_id() -> StringName:
	return &"base"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Game Flow Step"


## Stable logical input port ids, in display order.
func input_ports() -> Array[StringName]:
	return [INPUT_PORT] as Array[StringName]


## Stable logical output port ids, in display order.
func output_ports() -> Array[StringName]:
	return [OUTPUT_PORT] as Array[StringName]


func has_input_port(port_id: StringName) -> bool:
	return input_ports().has(port_id)


func has_output_port(port_id: StringName) -> bool:
	return output_ports().has(port_id)


func port_label(port_id: StringName) -> String:
	match port_id:
		&"in":
			return "Enter"
		&"out":
			return "Next"
		&"true":
			return "Yes"
		&"false":
			return "No"
		&"completed":
			return "Finished"
		&"failed":
			return "Failed"
	return String(port_id).replace("_", " ").capitalize()


## Turns a stable authored name into presentation text without changing the saved ID.
func _friendly_name(authored_name: StringName) -> String:
	return String(authored_name).replace("_", " ").capitalize()


## Entry nodes are event sources and are roots for reachability validation.
func is_entry_node() -> bool:
	return false


func is_terminal_node() -> bool:
	return output_ports().is_empty()


## A wait or async action breaks an otherwise immediate execution cycle.
func is_blocking_node() -> bool:
	return false


## Property-level problems supplied by a concrete node. Structural connection checks live on
## FlowGraph, while cross-resource checks may use the database passed here.
func validation_issues(
		_database: FlowDatabase,
		_graph_id: StringName
) -> Array[FlowValidationIssue]:
	return [] as Array[FlowValidationIssue]


func _missing_id_issue(
		property_label: String,
		issue_code: StringName,
		graph_id: StringName
) -> FlowValidationIssue:
	return FlowValidationIssue.make(
		FlowValidationIssue.Severity.ERROR,
		issue_code,
		"%s is required" % _friendly_property_name(property_label),
		graph_id,
		node_id
	)


func _persistence_issues(
		value: Variant,
		property_name: String,
		issue_code: StringName,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var problems := FlowPersistence.validate(value, "%s.%s" % [type_id(), property_name])
	if problems.is_empty():
		return [] as Array[FlowValidationIssue]
	return [FlowValidationIssue.make(
		FlowValidationIssue.Severity.ERROR,
		issue_code,
		"%s contains something that cannot be saved: %s" % [
			_friendly_property_name(property_name), FlowPersistence.format_problems(problems)],
		graph_id,
		node_id
	)] as Array[FlowValidationIssue]


func _friendly_property_name(property_name: String) -> String:
	match property_name:
		"event_id":
			return "Event Name"
		"subgraph_id":
			return "Subgraph"
		"exit_id":
			return "Result Name"
		"flag_id":
			return "Story Flag"
		"value_key":
			return "Story Value Name"
		"level_id":
			return "Level"
		"cutscene_id":
			return "Cutscene"
		"action_id":
			return "Game Action"
		"lease_id":
			return "Control Lock Name"
		"reason":
			return "Save Label"
		"data":
			return "Event Details"
		"context":
			return "Cutscene Details"
		"transition_data":
			return "Level Transition Details"
		"arguments":
			return "Action Settings"
	return property_name.replace("_", " ").capitalize()
