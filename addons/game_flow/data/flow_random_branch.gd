@tool
class_name FlowRandomBranch
extends Resource

## One stable, weighted output exposed by a FlowRandomNode.
##
## `port_id` is authored data and is therefore safe to rename only when the graph's connections
## are migrated at the same time. The optional label is presentation-only.

## Port IDs are structural graph data. The dedicated Game Flow branch editor owns changes so it
## can migrate or remove attached execution wires in the same undo action.
@export_storage var port_id: StringName = &""
@export var label: String = ""
@export_range(0.0, 1000000.0, 0.01, "or_greater") var weight: float = 1.0


func display_label() -> String:
	return label if not label.is_empty() else String(port_id).replace("_", " ").capitalize()
