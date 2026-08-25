@tool
class_name FlowGraphNode
extends Resource

## Runtime-safe authored node data shared by the runner and editor.
##
## Subclasses expose stable logical port ids. Editor slot indexes, GraphNode instances and other
## presentation state never cross this boundary.

const INPUT_PORT := &"in"
const OUTPUT_PORT := &"out"

@export var node_id: StringName = &""
@export var editor_position: Vector2 = Vector2.ZERO
@export var title_override: String = ""
@export_multiline var comment: String = ""
@export var enabled: bool = true


## Stable registration id used by the runtime executor and editor palette.
func type_id() -> StringName:
	return &"base"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Flow Node"


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
	return String(port_id).replace("_", " ").capitalize()


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
		"%s is empty" % property_label,
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
		"%s is not persistence-safe: %s" % [property_name, FlowPersistence.format_problems(problems)],
		graph_id,
		node_id
	)] as Array[FlowValidationIssue]
