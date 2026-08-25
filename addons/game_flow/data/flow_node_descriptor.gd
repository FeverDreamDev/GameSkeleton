@tool
class_name FlowNodeDescriptor
extends Resource

## Palette/runtime registration metadata for one concrete FlowGraphNode script.

enum PersistencePolicy {
	## Completes synchronously and leaves no in-flight state to save.
	INSTANT,
	## Wait state is represented explicitly and can be restored from a runner snapshot.
	RESUMABLE,
	## Saving must wait until the node's transient external operation has settled.
	SAVE_BLOCKING,
}

@export var type_id: StringName = &""
@export var display_name: String = ""
@export var category: String = ""
@export_multiline var description: String = ""
@export var node_script: Script
@export var persistence_policy: PersistencePolicy = PersistencePolicy.SAVE_BLOCKING
## Optional logical serialization lane for operations that may not overlap.
@export var exclusivity_group: StringName = &""


func is_valid() -> bool:
	if type_id.is_empty() or node_script == null or not node_script.can_instantiate():
		return false
	return create_node() != null


func create_node() -> FlowGraphNode:
	if node_script == null or not node_script.can_instantiate():
		return null
	return node_script.new() as FlowGraphNode
