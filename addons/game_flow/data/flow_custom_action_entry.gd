@tool
class_name FlowCustomActionEntry
extends Resource

## Optional authoring metadata for a game-provided action handler.
##
## The handler itself remains a transient Callable registered with FlowSystem at runtime. Keeping
## only its stable id and presentation metadata here makes custom actions searchable and lets graph
## validation catch typos without serializing executable objects. An unresolved action handle is
## save-blocking; a provider that resolves during its call completes immediately.

@export var action_id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""


func label() -> String:
	return display_name if not display_name.is_empty() else String(action_id)
