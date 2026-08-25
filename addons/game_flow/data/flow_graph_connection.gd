@tool
class_name FlowGraphConnection
extends Resource

## One execution-wire connection between stable logical node/port ids.
##
## GraphEdit slot indexes are presentation details and must never be stored here. [member order]
## makes fan-out deterministic when several connections leave the same output port.

@export var connection_id: StringName = &""
@export var from_node_id: StringName = &""
@export var from_port_id: StringName = &"out"
@export var to_node_id: StringName = &""
@export var to_port_id: StringName = &"in"
@export var order: int = 0
@export var enabled: bool = true


func is_complete() -> bool:
	return (
		not connection_id.is_empty()
		and not from_node_id.is_empty()
		and not from_port_id.is_empty()
		and not to_node_id.is_empty()
		and not to_port_id.is_empty()
	)


func matches(other: FlowGraphConnection) -> bool:
	return (
		other != null
		and from_node_id == other.from_node_id
		and from_port_id == other.from_port_id
		and to_node_id == other.to_node_id
		and to_port_id == other.to_port_id
	)


func describe() -> String:
	return "%s.%s -> %s.%s" % [from_node_id, from_port_id, to_node_id, to_port_id]
