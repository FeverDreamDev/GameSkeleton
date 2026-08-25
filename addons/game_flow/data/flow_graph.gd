@tool
class_name FlowGraph
extends Resource

## Serializable execution graph. It contains no GraphEdit/GraphNode controls or scene references.

const FORMAT_VERSION := 1

enum Kind {
	MASTER,
	SUBGRAPH,
}

@export var format_version: int = FORMAT_VERSION
@export var kind: Kind = Kind.MASTER
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var nodes: Array[FlowGraphNode] = []
@export var connections: Array[FlowGraphConnection] = []

@export_group("Editor View")
@export var editor_scroll_offset: Vector2 = Vector2.ZERO
@export_range(0.25, 4.0, 0.05) var editor_zoom: float = 1.0

var _node_index: Dictionary = {}
var _indexed: bool = false
var _indexed_node_count: int = -1


#region Lookup

func rebuild_index() -> void:
	_node_index.clear()
	for node: FlowGraphNode in nodes:
		if node != null and not node.node_id.is_empty():
			_node_index[node.node_id] = node
	_indexed = true
	_indexed_node_count = nodes.size()


func invalidate_index() -> void:
	_indexed = false


func get_node(node_id: StringName) -> FlowGraphNode:
	_ensure_index()
	return _node_index.get(node_id)


func has_node(node_id: StringName) -> bool:
	_ensure_index()
	return _node_index.has(node_id)


func node_ids() -> Array[StringName]:
	_ensure_index()
	var out: Array[StringName] = []
	for node_id: StringName in _node_index:
		out.append(node_id)
	out.sort_custom(func(a: StringName, b: StringName) -> bool:
		return String(a).naturalnocasecmp_to(String(b)) < 0)
	return out


func entry_nodes() -> Array[FlowGraphNode]:
	var out: Array[FlowGraphNode] = []
	for node: FlowGraphNode in nodes:
		if node != null and node.enabled and node.is_entry_node():
			out.append(node)
	return out


func outgoing_connections(
		from_node_id: StringName,
		from_port_id: StringName = &""
) -> Array[FlowGraphConnection]:
	var out: Array[FlowGraphConnection] = []
	for connection: FlowGraphConnection in connections:
		if connection == null or not connection.enabled:
			continue
		if connection.from_node_id != from_node_id:
			continue
		if not from_port_id.is_empty() and connection.from_port_id != from_port_id:
			continue
		out.append(connection)
	out.sort_custom(func(a: FlowGraphConnection, b: FlowGraphConnection) -> bool:
		if a.order != b.order:
			return a.order < b.order
		return String(a.connection_id).naturalnocasecmp_to(String(b.connection_id)) < 0)
	return out


func incoming_connections(
		to_node_id: StringName,
		to_port_id: StringName = &""
) -> Array[FlowGraphConnection]:
	var out: Array[FlowGraphConnection] = []
	for connection: FlowGraphConnection in connections:
		if connection == null or not connection.enabled:
			continue
		if connection.to_node_id != to_node_id:
			continue
		if not to_port_id.is_empty() and connection.to_port_id != to_port_id:
			continue
		out.append(connection)
	out.sort_custom(func(a: FlowGraphConnection, b: FlowGraphConnection) -> bool:
		if a.order != b.order:
			return a.order < b.order
		return String(a.connection_id).naturalnocasecmp_to(String(b.connection_id)) < 0)
	return out


func subgraph_exit_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for node: FlowGraphNode in nodes:
		if node is FlowSubgraphExitNode:
			var exit_node := node as FlowSubgraphExitNode
			if not exit_node.exit_id.is_empty() and not out.has(exit_node.exit_id):
				out.append(exit_node.exit_id)
	return out


func _ensure_index() -> void:
	if not _indexed or _indexed_node_count != nodes.size():
		rebuild_index()

#endregion


#region Validation

func validate_detailed(
		graph_id: StringName = &"",
		database: FlowDatabase = null
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	var node_map := {}
	var entry_count := 0

	if format_version <= 0 or format_version > FORMAT_VERSION:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"unsupported_graph_version",
			"This graph was saved in an unsupported format (version %d; supported version %d)." % [format_version, FORMAT_VERSION],
			graph_id
		))
	if kind not in [Kind.MASTER, Kind.SUBGRAPH]:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"invalid_graph_kind",
			"Choose either Main Game Graph or Reusable Subgraph as the graph kind.",
			graph_id
		))

	for node: FlowGraphNode in nodes:
		if node == null:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"empty_node_slot",
				"This graph contains a missing step. Remove the empty entry and add the step again.",
				graph_id
			))
			continue
		if node.node_id.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"node_missing_id",
				"'%s' is missing its internal identity. Delete it and add the step again." % node.display_title(),
				graph_id
			))
		elif node_map.has(node.node_id):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"duplicate_node_id",
				"Two steps share the same internal identity. Duplicate one of them again to repair it.",
				graph_id,
				node.node_id
			))
		else:
			node_map[node.node_id] = node
		if node.is_entry_node() and node.enabled:
			entry_count += 1
		if not FlowNodeCatalog.has_type(node.type_id()):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"unknown_node_type",
				"'%s' is not a built-in GameFlow step. Put game-specific behavior in Run Game Action." \
						% node.display_title(),
				graph_id,
				node.node_id
			))
		issues.append_array(node.validation_issues(database, graph_id))

	if nodes.is_empty():
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"empty_graph",
			"This graph is empty. Add a starting step from the palette.",
			graph_id
		))
	elif entry_count == 0:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"graph_missing_entry",
			"This graph has no active starting step.",
			graph_id
		))

	_validate_connections(graph_id, node_map, issues)
	_validate_unconnected_outputs(graph_id, issues)
	_validate_graph_node_contracts(graph_id, issues)
	_validate_reachability(graph_id, node_map, issues)
	_validate_immediate_cycles(graph_id, node_map, issues)
	rebuild_index()
	return issues


func _validate_unconnected_outputs(
		graph_id: StringName,
		issues: Array[FlowValidationIssue]
) -> void:
	for node: FlowGraphNode in nodes:
		if node == null or not node.enabled or node.node_id.is_empty():
			continue
		var connected_output_count := 0
		for port_id: StringName in node.output_ports():
			if outgoing_connections(node.node_id, port_id).is_empty():
				issues.append(FlowValidationIssue.make(
					FlowValidationIssue.Severity.WARNING,
					&"unconnected_output_port",
					"'%s' has no wire connected to its '%s' outcome." % [
						node.display_title(), node.port_label(port_id)],
					graph_id,
					node.node_id,
					&"",
					"",
					port_id
				))
			else:
				connected_output_count += 1
		if node.type_id() == &"random" and connected_output_count == 0:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"random_no_connected_output",
				"Choose Random Path needs a wire connected to at least one outcome.",
				graph_id,
				node.node_id
			))


func _validate_graph_node_contracts(
		graph_id: StringName,
		issues: Array[FlowValidationIssue]
) -> void:
	var game_start_count := 0
	var subgraph_entry_count := 0
	var exit_nodes := {}
	for node: FlowGraphNode in nodes:
		if node is FlowGameStartNode and node.enabled:
			game_start_count += 1
		elif node is FlowSubgraphEntryNode and node.enabled:
			subgraph_entry_count += 1
		elif node is FlowSubgraphExitNode:
			var exit_node := node as FlowSubgraphExitNode
			if exit_node.exit_id.is_empty():
				continue
			if exit_nodes.has(exit_node.exit_id):
				issues.append(FlowValidationIssue.make(
					FlowValidationIssue.Severity.ERROR,
					&"duplicate_subgraph_exit",
					"Two Finish Subgraph steps return the same result '%s'." % exit_node.port_label(exit_node.exit_id),
					graph_id,
					exit_node.node_id
				))
			else:
				exit_nodes[exit_node.exit_id] = true
	if kind == Kind.MASTER and game_start_count != 1:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"master_game_start_count",
			"The Main Game Graph needs exactly one active When Game Starts step (found %d)." % game_start_count,
			graph_id
		))
	if kind == Kind.MASTER and subgraph_entry_count > 0:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"master_has_subgraph_entry",
			"Subgraph Starts Here belongs only in a Reusable Subgraph, not the Main Game Graph.",
			graph_id
		))
	if kind == Kind.SUBGRAPH and subgraph_entry_count != 1:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"subgraph_entry_count",
			"A Reusable Subgraph needs exactly one active Subgraph Starts Here step (found %d)." % subgraph_entry_count,
			graph_id
		))
	if kind == Kind.SUBGRAPH and game_start_count > 0:
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"subgraph_has_game_start",
			"When Game Starts belongs only in the Main Game Graph, not a Reusable Subgraph.",
			graph_id
		))


func _validate_connections(
		graph_id: StringName,
		node_map: Dictionary,
		issues: Array[FlowValidationIssue]
) -> void:
	var connection_ids := {}
	var edge_keys := {}
	for connection: FlowGraphConnection in connections:
		if connection == null:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"empty_connection_slot",
				"This graph contains a missing wire. Disconnect and reconnect the affected steps.",
				graph_id
			))
			continue
		if connection.connection_id.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"connection_missing_id",
				"A wire is missing its internal identity. Disconnect and reconnect it.",
				graph_id
			))
		elif connection_ids.has(connection.connection_id):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"duplicate_connection_id",
				"Two wires share the same internal identity. Disconnect and reconnect one of them.",
				graph_id,
				&"",
				connection.connection_id
			))
		else:
			connection_ids[connection.connection_id] = true

		var from_node: FlowGraphNode = node_map.get(connection.from_node_id)
		var to_node: FlowGraphNode = node_map.get(connection.to_node_id)
		if from_node == null:
			issues.append(_connection_issue(
				graph_id, connection, &"connection_missing_source",
				"A wire starts at a step that no longer exists. Remove the broken wire."))
		elif not from_node.has_output_port(connection.from_port_id):
			issues.append(_connection_issue(
				graph_id, connection, &"connection_missing_source_port",
				"A wire starts from an outcome that no longer exists. Reconnect the wire.",
				FlowValidationIssue.Severity.ERROR, connection.from_port_id))
		if to_node == null:
			issues.append(_connection_issue(
				graph_id, connection, &"connection_missing_target",
				"A wire points to a step that no longer exists. Remove the broken wire."))
		elif not to_node.has_input_port(connection.to_port_id):
			issues.append(_connection_issue(
				graph_id, connection, &"connection_missing_target_port",
				"A wire points to an entrance that no longer exists. Reconnect the wire.",
				FlowValidationIssue.Severity.ERROR, connection.to_port_id))

		var edge_key := "%s\u001f%s\u001f%s\u001f%s" % [
			connection.from_node_id, connection.from_port_id,
			connection.to_node_id, connection.to_port_id,
		]
		if edge_keys.has(edge_key):
			issues.append(_connection_issue(
				graph_id, connection, &"duplicate_connection",
				"The same two outcomes are connected by more than one wire.",
				FlowValidationIssue.Severity.WARNING))
		else:
			edge_keys[edge_key] = true


func _validate_reachability(
		graph_id: StringName,
		node_map: Dictionary,
		issues: Array[FlowValidationIssue]
) -> void:
	var reached := {}
	var pending: Array[StringName] = []
	for node: FlowGraphNode in nodes:
		if node != null and node.enabled and node.is_entry_node() and not node.node_id.is_empty():
			reached[node.node_id] = true
			pending.append(node.node_id)
	while not pending.is_empty():
		var current_id := pending.pop_front()
		for connection: FlowGraphConnection in outgoing_connections(current_id):
			if not node_map.has(connection.to_node_id) or reached.has(connection.to_node_id):
				continue
			reached[connection.to_node_id] = true
			pending.append(connection.to_node_id)
	for node: FlowGraphNode in nodes:
		if node == null or node.node_id.is_empty() or reached.has(node.node_id):
			continue
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.WARNING,
			&"unreachable_node",
			"This step can never run because no starting path reaches it.",
			graph_id,
			node.node_id
		))


func _validate_immediate_cycles(
		graph_id: StringName,
		node_map: Dictionary,
		issues: Array[FlowValidationIssue]
) -> void:
	var state := {}
	for node_id: StringName in node_map:
		if int(state.get(node_id, 0)) != 0:
			continue
		var cycle_node := _visit_immediate_cycle(node_id, node_map, state)
		if not cycle_node.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"immediate_execution_cycle",
				"This loop can run forever without waiting. Add a timer, event wait, or other waiting step.",
				graph_id,
				cycle_node
			))
			return


func _visit_immediate_cycle(
		node_id: StringName,
		node_map: Dictionary,
		state: Dictionary
) -> StringName:
	state[node_id] = 1
	var node: FlowGraphNode = node_map.get(node_id)
	if node != null and not node.is_blocking_node():
		for connection: FlowGraphConnection in outgoing_connections(node_id):
			if not node_map.has(connection.to_node_id):
				continue
			var next_state := int(state.get(connection.to_node_id, 0))
			if next_state == 1:
				return connection.to_node_id
			if next_state == 0:
				var found := _visit_immediate_cycle(connection.to_node_id, node_map, state)
				if not found.is_empty():
					return found
	state[node_id] = 2
	return &""


func _connection_issue(
		graph_id: StringName,
		connection: FlowGraphConnection,
	code: StringName,
	message: String,
	severity: FlowValidationIssue.Severity = FlowValidationIssue.Severity.ERROR,
	port_id: StringName = &""
) -> FlowValidationIssue:
	return FlowValidationIssue.make(
		severity,
		code,
		message,
		graph_id,
		&"",
		connection.connection_id,
		"",
		port_id
	)

#endregion
