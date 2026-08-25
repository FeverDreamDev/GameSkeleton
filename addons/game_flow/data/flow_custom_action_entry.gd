@tool
class_name FlowCustomActionEntry
extends Resource

## Optional authoring metadata for a game-provided action handler.
##
## The handler itself remains a transient Callable registered with FlowSystem at runtime. Keeping
## only its stable id and presentation metadata here makes custom actions searchable and lets graph
## validation catch typos without serializing executable objects.

@export var action_id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
## RESUMABLE is reserved for a future provider snapshot protocol. V1 Invoke Action execution is
## save-blocking unless its provider resolves synchronously.
@export var persistence_policy: FlowNodeDescriptor.PersistencePolicy = \
		FlowNodeDescriptor.PersistencePolicy.SAVE_BLOCKING
@export var exclusivity_group: StringName = &""


func label() -> String:
	return display_name if not display_name.is_empty() else String(action_id)
