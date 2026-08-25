@tool
class_name FlowNodeDescriptor
extends Resource

## Editor-palette metadata for one built-in [FlowGraphNode] script.
##
## This descriptor creates the authored Resource only. It does not provide execution behavior;
## [FlowGraphRunner] implements the stable built-in type IDs. Game-specific behavior belongs in a
## **Run Game Action** step, not an arbitrary node subclass.

@export var type_id: StringName = &""
@export var display_name: String = ""
@export var category: String = ""
@export_multiline var description: String = ""
@export var node_script: Script


func is_valid() -> bool:
	if type_id.is_empty() or node_script == null or not node_script.can_instantiate():
		return false
	return create_node() != null


func create_node() -> FlowGraphNode:
	if node_script == null or not node_script.can_instantiate():
		return null
	return node_script.new() as FlowGraphNode
