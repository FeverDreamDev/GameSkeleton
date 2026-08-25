class_name FlowGraphRunner
extends Node

## Concurrent, explicit-state executor for [FlowGraph] resources.
##
## The runner never awaits in its central pump. Timers, events, subgraphs and external actions
## park only their owning token, then callbacks put that token back on the deterministic ready
## queue. This is what allows story, ambience, secrets and encounters to wait independently.

signal telemetry(event: Dictionary)
signal active_changed(active: bool)
signal save_stability_changed()

const SNAPSHOT_VERSION := 1
const MAX_IMMEDIATE_STEPS := 512

const STATUS_READY := &"ready"
const STATUS_TIMER := &"timer"
const STATUS_EVENT := &"event"
const STATUS_ACTION := &"action"
const STATUS_SUBGRAPH := &"subgraph"

var _instances: Dictionary = {}
var _tokens: Dictionary = {}
var _ready_tokens: Array[StringName] = []
var _event_inbox: Array[Dictionary] = []
var _event_waiters: Dictionary = {}
var _event_entries: Dictionary = {}
var _timer_handles: Dictionary = {}
var _action_handles: Dictionary = {}
## One FlowSystem lease key may have several token owners. The outer lease is acquired once and
## released only after the final owning token enables input, finishes, or is cancelled.
var _owned_input_leases: Dictionary = {}
## Request Save continuations remain in the normal ready queue so snapshots restore them as ready,
## but the live scheduler holds them until the host has synchronously handled save_requested.
var _held_ready_tokens: Dictionary = {}
var _save_barriers: Array[Dictionary] = []
var _save_request_in_flight: bool = false

var _master_instance_id: StringName = &""
var _next_instance_number: int = 1
var _next_token_number: int = 1
var _generation: int = 1
var _active: bool = false
var _suspended: bool = false
var _pumping: bool = false
var _pump_scheduled: bool = false
var _random_generator := RandomNumberGenerator.new()
var _random_float_source: Callable = Callable()


func _init() -> void:
	_random_generator.randomize()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


#region Public lifecycle

func start_master(graph_id: StringName = &"") -> bool:
	cancel_all()
	var resolved_id := graph_id
	var database := _database()
	if resolved_id.is_empty() and database != null:
		resolved_id = database.master_graph_id
	if resolved_id.is_empty():
		return false
	if not _database_graphs_are_valid(database):
		return false

	var graph := _load_graph(resolved_id)
	if graph == null:
		push_error("FlowGraphRunner: cannot start unknown master graph '%s'." % resolved_id)
		return false
	if int(graph.kind) != 0:
		push_error("FlowGraphRunner: graph '%s' is not marked as a master graph." % resolved_id)
		return false

	_master_instance_id = _create_instance(resolved_id, graph)
	if _master_instance_id.is_empty():
		return false
	_set_active(true)

	var starts: Array[FlowGraphNode] = []
	for node: FlowGraphNode in _nodes_of_type(graph, &"game_start"):
		if node.enabled:
			starts.append(node)
	if starts.is_empty():
		push_error("FlowGraphRunner: Main Game Graph '%s' has no When Game Starts step." % resolved_id)
		cancel_all()
		return false
	for node: FlowGraphNode in starts:
		_spawn_token(_master_instance_id, node.node_id)
	_schedule_pump()
	return true


func cancel_all() -> void:
	_generation += 1
	for handle: Variant in _action_handles.values():
		if handle is FlowActionHandle and not handle.is_finished():
			handle.cancel("run_reset")
	for lease_key: StringName in _owned_input_leases.keys():
		FlowSystem.release_gameplay_input(lease_key)

	_instances.clear()
	_tokens.clear()
	_ready_tokens.clear()
	_event_inbox.clear()
	_event_waiters.clear()
	_event_entries.clear()
	_timer_handles.clear()
	_action_handles.clear()
	_owned_input_leases.clear()
	_held_ready_tokens.clear()
	_save_barriers.clear()
	_save_request_in_flight = false
	_master_instance_id = &""
	_next_instance_number = 1
	_next_token_number = 1
	_suspended = false
	_pump_scheduled = false
	_set_active(false)
	save_stability_changed.emit()


func suspend() -> void:
	_suspended = true


func resume() -> void:
	if not _active:
		return
	_suspended = false
	_recreate_timers()
	_schedule_pump()


func is_active() -> bool:
	return _active


func is_suspended() -> bool:
	return _suspended


func is_snapshot_safe() -> bool:
	if _pumping or not _action_handles.is_empty() or not _event_inbox.is_empty():
		return false
	# Event payloads may contain live Nodes (for example FlowTrigger3D's source/body). They are
	# deliberately transient, so a save waits until the immediate path has either consumed that
	# payload or reached a suspension point, where the runner clears it.
	for token: Dictionary in _tokens.values():
		if not (token["event_data"] as Dictionary).is_empty():
			return false
	return true


## Overrides random sampling with a transient callable returning a number in the [0, 1] range.
## This is intended for deterministic tests and seeded game-owned random services. The callable is
## runtime context only and is never included in graph Resources or snapshots.
func set_random_float_source(source: Callable) -> void:
	_random_float_source = source


func clear_random_float_source() -> void:
	_random_float_source = Callable()


## Provides deterministic built-in sampling without installing a custom callable.
func set_random_seed(seed_value: int) -> void:
	_random_generator.seed = seed_value

#endregion


#region Event ingress

## Called by the runner's one wildcard bus subscription. Wait tokens do not create their own
## subscriptions, which makes reset/rebind deterministic and keeps event lookup O(waiters).
func accept_event(event_id: StringName, data: Dictionary) -> void:
	if not _active or event_id.is_empty():
		return
	_event_inbox.append({
		"event_id": event_id,
		"data": data,
	})
	if not _suspended:
		_schedule_pump()


func _drain_event_inbox() -> void:
	while not _event_inbox.is_empty():
		var envelope: Dictionary = _event_inbox.pop_front()
		var event_id: StringName = envelope["event_id"]
		var data: Dictionary = envelope["data"]

		# Existing waits get first claim; new entry activations are queued behind them.
		var waiters: Array = (_event_waiters.get(event_id, []) as Array).duplicate()
		_event_waiters.erase(event_id)
		for raw_token_id: Variant in waiters:
			var token_id := StringName(raw_token_id)
			if not _tokens.has(token_id):
				continue
			var token: Dictionary = _tokens[token_id]
			if token["status"] != STATUS_EVENT:
				continue
			token["event_data"] = data
			token["wait"] = {}
			_emit_token_event(token_id, &"resumed", {"reason": "event", "event_id": event_id})
			_advance_from_port(token_id, &"out")

		var entries: Array = (_event_entries.get(event_id, []) as Array).duplicate()
		for raw_entry: Variant in entries:
			var entry: Dictionary = raw_entry
			var instance_id: StringName = entry["instance_id"]
			if not _instances.has(instance_id):
				continue
			var node := _node_for_instance(instance_id, entry["node_id"])
			if node == null:
				continue
			if bool(node.one_shot):
				var flag := _entry_once_flag(_instances[instance_id]["graph_id"], node.node_id)
				if FlowState.has_flag(flag):
					continue
				# Marked at scheduling time so two same-frame reports cannot start it twice.
				FlowState.set_flag(flag)
			_spawn_token(instance_id, node.node_id, {}, data)

#endregion


#region Pump and token execution

func _schedule_pump() -> void:
	if _suspended or _pump_scheduled or _pumping or not is_inside_tree():
		return
	if _event_inbox.is_empty() and not _has_runnable_ready_token():
		return
	_pump_scheduled = true
	_pump.call_deferred()


func _pump() -> void:
	_pump_scheduled = false
	if _suspended or _pumping:
		return
	_pumping = true
	var steps := 0
	while not _suspended:
		var token_id := _pop_runnable_ready_token()
		if token_id.is_empty():
			if _event_inbox.is_empty():
				break
			_drain_event_inbox()
			continue
		if not _tokens.has(token_id):
			continue
		var token: Dictionary = _tokens[token_id]
		if token["status"] != STATUS_READY:
			continue

		steps += 1
		if steps > MAX_IMMEDIATE_STEPS:
			_fail_token(token_id, "more than %d immediate graph steps; probable zero-time cycle" % MAX_IMMEDIATE_STEPS)
			break
		_step_token(token_id)

		# Event activations are materialized after the current step and appended after the current
		# path's already-queued successor, preserving non-reentrant action ordering.
		if not _event_inbox.is_empty():
			_drain_event_inbox()

	_pumping = false
	save_stability_changed.emit()
	FlowSystem.notify_graph_save_stability_changed()
	_try_dispatch_save_barrier()
	if not _suspended and (not _event_inbox.is_empty() or _has_runnable_ready_token()):
		_schedule_pump()


func _has_runnable_ready_token() -> bool:
	for token_id: StringName in _ready_tokens:
		if not _held_ready_tokens.has(token_id):
			return true
	return false


func _pop_runnable_ready_token() -> StringName:
	var remaining := _ready_tokens.size()
	while remaining > 0:
		remaining -= 1
		var token_id: StringName = _ready_tokens.pop_front()
		if _held_ready_tokens.has(token_id):
			_ready_tokens.append(token_id)
			continue
		return token_id
	return &""


func _step_token(token_id: StringName) -> void:
	var token: Dictionary = _tokens[token_id]
	var node := _node_for_instance(token["instance_id"], token["node_id"])
	if node == null:
		_fail_token(token_id, "current node '%s' no longer exists" % token["node_id"])
		return
	if not node.enabled:
		if node.output_ports().has(&"out"):
			_advance_from_port(token_id, &"out")
		else:
			_finish_token(token_id)
		return

	var type_id: StringName = node.type_id()
	_emit_token_event(token_id, &"entered", {"type_id": type_id})
	match type_id:
		&"game_start", &"event_entry", &"subgraph_entry", &"parallel":
			_advance_from_port(token_id, &"out")

		&"end":
			_finish_token(token_id)

		&"if":
			var condition_ok: bool = node.condition != null and node.condition.evaluate({
				"event_data": token["event_data"],
				"locals": token["locals"],
			})
			_advance_from_port(token_id, &"true" if condition_ok else &"false")

		&"random":
			var selected_port := _choose_random_port(token, node)
			if selected_port.is_empty():
				_fail_token(token_id, "random node '%s' has no connected output with a valid weight" \
						% node.node_id)
				return
			_advance_from_port(token_id, selected_port)

		&"set_flag":
			FlowState.set_flag(node.flag_id, node.flag_value)
			_advance_from_port(token_id, &"out")

		&"set_value":
			if not FlowState.try_set_value(node.value_key, node.value):
				_fail_token(token_id, "value for '%s' is not persistable" % node.value_key)
				return
			_advance_from_port(token_id, &"out")

		&"wait_timer":
			_begin_timer_wait(token_id, node.seconds)

		&"wait_event":
			_begin_event_wait(token_id, node.event_id)

		&"emit_event":
			var payload: Dictionary = node.data
			if payload.is_empty():
				payload = token["event_data"]
			FlowEvents.emit(node.event_id, payload)
			_advance_from_port(token_id, &"out")

		&"preload_level":
			FlowSystem.preload_level(node.level_id)
			_advance_from_port(token_id, &"out")

		&"play_cutscene":
			_begin_action_wait(token_id, FlowSystem.queue_cutscene(node.cutscene_id, node.context))

		&"load_level":
			_begin_action_wait(token_id, FlowSystem.queue_level_transition(
				node.level_id, node.spawn_id, node.transition_data))

		&"request_save":
			# Commit, but hold, every successor. The host snapshots those ready continuations and
			# returns from save_requested before any of them can enter a cutscene/load/custom action.
			if not _advance_from_port(token_id, &"out", node.reason):
				_queue_save_barrier(node.reason, [])

		&"disable_input":
			_acquire_token_input_lease(
				token_id, token["instance_id"], node.lease_id)
			_advance_from_port(token_id, &"out")

		&"enable_input":
			_release_token_input_lease(
				token_id, token["instance_id"], node.lease_id)
			_advance_from_port(token_id, &"out")

		&"call_subgraph":
			_begin_subgraph_call(token_id, node)

		&"subgraph_exit":
			_complete_subgraph(token["instance_id"], node.exit_id)

		&"invoke_action":
			var context := {
				"graph_id": _instances[token["instance_id"]]["graph_id"],
				"graph_instance_id": token["instance_id"],
				"token_id": token_id,
				"node_id": node.node_id,
				"locals": token["locals"],
				"event_data": token["event_data"],
			}
			_begin_action_wait(token_id, FlowSystem.invoke_action(node.action_id, node.arguments, context))

		_:
			_fail_token(token_id, "unknown node type '%s'" % type_id)


func _choose_random_port(token: Dictionary, node: FlowRandomNode) -> StringName:
	var instance: Dictionary = _instances.get(token["instance_id"], {})
	if instance.is_empty():
		return &""
	var graph: FlowGraph = instance["graph"]
	var eligible: Array[FlowRandomBranch] = []
	var total_weight := 0.0
	for branch: FlowRandomBranch in node.branches:
		if branch == null or branch.port_id.is_empty():
			continue
		if not is_finite(branch.weight) or branch.weight <= 0.0:
			continue
		if _outgoing(graph, node.node_id, branch.port_id).is_empty():
			continue
		eligible.append(branch)
		total_weight += branch.weight
	if eligible.is_empty() or not is_finite(total_weight) or total_weight <= 0.0:
		return &""

	var target := _next_random_unit() * total_weight
	var cumulative := 0.0
	for branch: FlowRandomBranch in eligible:
		cumulative += branch.weight
		if target < cumulative:
			return branch.port_id
	# A source may explicitly return 1.0, and floating-point accumulation can also end a fraction
	# below total_weight. Both cases intentionally resolve to the final eligible output.
	return eligible[-1].port_id


func _next_random_unit() -> float:
	if _random_float_source.is_valid():
		var sampled: Variant = _random_float_source.call()
		if (sampled is int or sampled is float) and is_finite(float(sampled)):
			return clampf(float(sampled), 0.0, 1.0)
		push_warning("FlowGraphRunner: injected random source returned a non-finite/non-numeric value; using the built-in generator.")
	return _random_generator.randf()


func _advance_from_port(
		token_id: StringName,
		port_id: StringName,
		hold_for_save_reason: StringName = &""
) -> bool:
	if not _tokens.has(token_id):
		return false
	var token: Dictionary = _tokens[token_id]
	var instance: Dictionary = _instances.get(token["instance_id"], {})
	if instance.is_empty():
		_finish_token(token_id)
		return false
	var graph: FlowGraph = instance["graph"]
	var connections := _outgoing(graph, token["node_id"], port_id)
	_emit_token_event(token_id, &"completed", {"port_id": port_id})
	if connections.is_empty():
		_finish_token(token_id)
		return false

	var template_locals: Dictionary = token["locals"]
	var template_event_data: Dictionary = token["event_data"]
	var continuation_ids: Array[StringName] = []
	for connection: FlowGraphConnection in connections:
		_emit_token_event(token_id, &"traversed", {
			"port_id": port_id,
			"connection_id": connection.connection_id,
			"to_node_id": connection.to_node_id,
		})
	for index in connections.size():
		var connection: FlowGraphConnection = connections[index]
		if index == 0:
			token["node_id"] = connection.to_node_id
			token["status"] = STATUS_READY
			token["wait"] = {}
			_ready_tokens.append(token_id)
			continuation_ids.append(token_id)
		else:
			continuation_ids.append(_spawn_token(
				token["instance_id"],
				connection.to_node_id,
				template_locals.duplicate(true),
				template_event_data.duplicate()))
	if not hold_for_save_reason.is_empty():
		_queue_save_barrier(hold_for_save_reason, continuation_ids)
	return true


func _queue_save_barrier(reason: StringName, continuation_ids: Array[StringName]) -> void:
	for continuation_id: StringName in continuation_ids:
		_held_ready_tokens[continuation_id] = true
		_emit_token_event(continuation_id, &"waiting", {
			"reason": "save_checkpoint",
			"save_reason": reason,
		})
	_save_barriers.append({
		"reason": reason,
		"token_ids": continuation_ids.duplicate(),
	})


func _try_dispatch_save_barrier() -> void:
	if _save_request_in_flight or _save_barriers.is_empty() or _pumping or _suspended:
		return
	_save_request_in_flight = true
	var barrier: Dictionary = _save_barriers[0]
	FlowSystem.request_save(StringName(barrier.get("reason", "")))


## Called by FlowSystem only after every save_requested listener has returned. At that point the
## host's synchronous UISave write has observed the held successors, so execution may continue.
func notify_save_dispatched(_reason: StringName) -> void:
	if not _save_request_in_flight or _save_barriers.is_empty():
		return
	var barrier: Dictionary = _save_barriers.pop_front()
	for raw_token_id: Variant in barrier.get("token_ids", []):
		var token_id := StringName(raw_token_id)
		_held_ready_tokens.erase(token_id)
		if _tokens.has(token_id):
			_emit_token_event(token_id, &"resumed", {
				"reason": "save_checkpoint",
				"save_reason": barrier.get("reason", ""),
			})
	_save_request_in_flight = false
	_schedule_pump()


func _spawn_token(
		instance_id: StringName,
		node_id: StringName,
		locals: Dictionary = {},
		event_data: Dictionary = {}
) -> StringName:
	var token_id := StringName("token_%d" % _next_token_number)
	_next_token_number += 1
	_tokens[token_id] = {
		"token_id": token_id,
		"instance_id": instance_id,
		"node_id": node_id,
		"status": STATUS_READY,
		"locals": locals,
		"event_data": event_data,
		"wait": {},
	}
	_ready_tokens.append(token_id)
	_emit_token_event(token_id, &"created")
	return token_id


func _finish_token(token_id: StringName) -> void:
	if not _tokens.has(token_id):
		return
	var instance_id: StringName = _tokens[token_id]["instance_id"]
	_remove_token(token_id)
	_maybe_fail_empty_subgraph(instance_id)


func _fail_token(token_id: StringName, reason: String) -> void:
	if not _tokens.has(token_id):
		return
	push_error("FlowGraphRunner: %s" % reason)
	_emit_token_event(token_id, &"failed", {"reason": reason})
	var instance_id: StringName = _tokens[token_id]["instance_id"]
	_remove_token(token_id)
	_maybe_fail_empty_subgraph(instance_id, reason)


func _remove_token(token_id: StringName) -> void:
	if not _tokens.has(token_id):
		return
	var token: Dictionary = _tokens[token_id]
	_release_all_token_input_leases(token_id)
	_held_ready_tokens.erase(token_id)
	var wait: Dictionary = token["wait"]
	if wait.get("kind", "") == "event":
		_remove_event_waiter(StringName(wait.get("event_id", "")), token_id)
	_ready_tokens.erase(token_id)
	_timer_handles.erase(token_id)
	_action_handles.erase(token_id)
	_tokens.erase(token_id)

#endregion


#region Waits and actions

func _begin_timer_wait(token_id: StringName, seconds: float) -> void:
	if seconds <= 0.0:
		_advance_from_port(token_id, &"out")
		return
	var token: Dictionary = _tokens[token_id]
	token["status"] = STATUS_TIMER
	token["event_data"] = {}
	token["wait"] = {
		"kind": "timer",
		"remaining": seconds,
		"started_msec": Time.get_ticks_msec(),
	}
	_emit_token_event(token_id, &"waiting", {"reason": "timer", "seconds": seconds})
	_create_timer(token_id, seconds)


func _create_timer(token_id: StringName, seconds: float) -> void:
	var tree := get_tree()
	if tree == null:
		_fail_token(token_id, "cannot create timer without a SceneTree")
		return
	var timer := tree.create_timer(maxf(seconds, 0.0001), true)
	_timer_handles[token_id] = timer
	timer.timeout.connect(_on_timer_timeout.bind(token_id, _generation), CONNECT_ONE_SHOT)


func _on_timer_timeout(token_id: StringName, generation: int) -> void:
	if generation != _generation or not _tokens.has(token_id):
		return
	var token: Dictionary = _tokens[token_id]
	if token["status"] != STATUS_TIMER:
		return
	_timer_handles.erase(token_id)
	token["wait"] = {}
	_emit_token_event(token_id, &"resumed", {"reason": "timer"})
	_advance_from_port(token_id, &"out")
	_schedule_pump()


func _begin_event_wait(token_id: StringName, event_id: StringName) -> void:
	if event_id.is_empty():
		_fail_token(token_id, "Wait For Event has an empty event id")
		return
	var token: Dictionary = _tokens[token_id]
	token["status"] = STATUS_EVENT
	token["event_data"] = {}
	token["wait"] = {"kind": "event", "event_id": event_id}
	if not _event_waiters.has(event_id):
		_event_waiters[event_id] = [] as Array[StringName]
	var waiters: Array[StringName] = _event_waiters[event_id]
	waiters.append(token_id)
	_emit_token_event(token_id, &"waiting", {"reason": "event", "event_id": event_id})


func _begin_action_wait(token_id: StringName, handle: FlowActionHandle) -> void:
	if handle == null:
		_complete_action(token_id, false, {"reason": "no_action_handle"})
		return
	var token: Dictionary = _tokens[token_id]
	token["status"] = STATUS_ACTION
	token["event_data"] = {}
	token["wait"] = {"kind": "action"}
	_action_handles[token_id] = handle
	_emit_token_event(token_id, &"waiting", {"reason": "action"})
	save_stability_changed.emit()
	if handle.is_finished():
		_complete_action(token_id, handle.succeeded(), handle.result_data())
	else:
		handle.completed.connect(_on_action_completed.bind(token_id, _generation), CONNECT_ONE_SHOT)


func _on_action_completed(
		success: bool,
		data: Dictionary,
		token_id: StringName,
		generation: int
) -> void:
	if generation != _generation:
		return
	_complete_action(token_id, success, data)


func _complete_action(token_id: StringName, success: bool, data: Dictionary) -> void:
	if not _tokens.has(token_id):
		return
	_action_handles.erase(token_id)
	var token: Dictionary = _tokens[token_id]
	token["wait"] = {}
	_emit_token_event(token_id, &"resumed", {"reason": "action", "success": success})
	if success:
		_advance_from_port(token_id, &"completed")
	elif not _advance_from_port(token_id, &"failed"):
		# _advance_from_port has already removed an unconnected token. Emit the useful failure line.
		push_error("FlowGraphRunner: action failed without a connected failure path: %s" % data)
	save_stability_changed.emit()
	FlowSystem.notify_graph_save_stability_changed()
	_schedule_pump()


func _remove_event_waiter(event_id: StringName, token_id: StringName) -> void:
	if not _event_waiters.has(event_id):
		return
	var waiters: Array = _event_waiters[event_id]
	waiters.erase(token_id)
	if waiters.is_empty():
		_event_waiters.erase(event_id)


func _recreate_timers() -> void:
	for raw_token_id: Variant in _tokens:
		var token_id := StringName(raw_token_id)
		var token: Dictionary = _tokens[token_id]
		if token["status"] != STATUS_TIMER or _timer_handles.has(token_id):
			continue
		var remaining := float((token["wait"] as Dictionary).get("remaining", 0.0))
		(token["wait"] as Dictionary)["started_msec"] = Time.get_ticks_msec()
		_create_timer(token_id, remaining)

#endregion


#region Subgraphs

func _begin_subgraph_call(token_id: StringName, node: FlowGraphNode) -> void:
	var graph := _load_graph(node.subgraph_id)
	if graph == null:
		_complete_action(token_id, false, {"reason": "unknown_subgraph", "graph_id": node.subgraph_id})
		return
	if int(graph.kind) != 1:
		_complete_action(token_id, false, {"reason": "not_a_subgraph", "graph_id": node.subgraph_id})
		return

	var parent: Dictionary = _tokens[token_id]
	parent["status"] = STATUS_SUBGRAPH
	parent["event_data"] = {}
	parent["wait"] = {"kind": "subgraph"}
	var child_id := _create_instance(
		node.subgraph_id,
		graph,
		token_id,
		parent["instance_id"],
		node.node_id)
	parent["wait"]["child_instance_id"] = child_id
	var entries: Array[FlowGraphNode] = []
	for entry: FlowGraphNode in _nodes_of_type(graph, &"subgraph_entry"):
		if entry.enabled:
			entries.append(entry)
	if entries.size() != 1:
		_cancel_instance(child_id)
		_complete_action(token_id, false, {"reason": "invalid_subgraph_entry", "graph_id": node.subgraph_id})
		return
	_spawn_token(child_id, (entries[0] as FlowGraphNode).node_id, parent["locals"].duplicate(true))
	_emit_token_event(token_id, &"waiting", {"reason": "subgraph", "graph_id": node.subgraph_id})


func _complete_subgraph(instance_id: StringName, exit_id: StringName) -> void:
	if not _instances.has(instance_id):
		return
	var instance: Dictionary = _instances[instance_id]
	var parent_token_id: StringName = instance["parent_token_id"]
	_cancel_instance(instance_id)
	if not _tokens.has(parent_token_id):
		return
	var parent: Dictionary = _tokens[parent_token_id]
	parent["wait"] = {}
	_emit_token_event(parent_token_id, &"resumed", {"reason": "subgraph", "exit_id": exit_id})
	if not _advance_from_port(parent_token_id, exit_id):
		# A named subgraph exit without a matching caller output is a runtime content error.
		push_error("FlowGraphRunner: subgraph exit '%s' has no matching caller connection." % exit_id)
	_schedule_pump()


func _maybe_fail_empty_subgraph(instance_id: StringName, reason: String = "subgraph ended without an exit") -> void:
	if not _instances.has(instance_id):
		return
	var instance: Dictionary = _instances[instance_id]
	if StringName(instance["parent_token_id"]).is_empty():
		return
	for token: Dictionary in _tokens.values():
		if token["instance_id"] == instance_id:
			return
	var parent_token_id: StringName = instance["parent_token_id"]
	_cancel_instance(instance_id)
	if _tokens.has(parent_token_id):
		_complete_action(parent_token_id, false, {"reason": reason})


func _create_instance(
		graph_id: StringName,
		graph: FlowGraph,
		parent_token_id: StringName = &"",
		parent_instance_id: StringName = &"",
		parent_node_id: StringName = &""
) -> StringName:
	var instance_id := StringName("graph_%d" % _next_instance_number)
	_next_instance_number += 1
	_instances[instance_id] = {
		"instance_id": instance_id,
		"graph_id": graph_id,
		"graph": graph,
		"parent_token_id": parent_token_id,
		"parent_instance_id": parent_instance_id,
		"parent_node_id": parent_node_id,
	}
	_index_instance_entries(instance_id)
	return instance_id


func _cancel_instance(instance_id: StringName) -> void:
	if not _instances.has(instance_id):
		return
	var child_ids: Array[StringName] = []
	for raw_id: Variant in _instances:
		var id := StringName(raw_id)
		if id != instance_id and _instances[id]["parent_instance_id"] == instance_id:
			child_ids.append(id)
	for child_id in child_ids:
		_cancel_instance(child_id)

	var token_ids: Array[StringName] = []
	for raw_token_id: Variant in _tokens:
		var token_id := StringName(raw_token_id)
		if _tokens[token_id]["instance_id"] == instance_id:
			token_ids.append(token_id)
	for token_id in token_ids:
		_remove_token(token_id)

	for lease_key: StringName in _owned_input_leases.keys():
		var lease: Dictionary = _owned_input_leases[lease_key]
		if StringName(lease.get("instance_id", "")) == instance_id:
			_owned_input_leases.erase(lease_key)
			FlowSystem.release_gameplay_input(lease_key)

	_instances.erase(instance_id)
	_rebuild_entry_index()

#endregion


#region Snapshot

func to_dict() -> Dictionary:
	if not _active:
		return {}
	if not is_snapshot_safe():
		return {}
	# Convert pending event notifications into explicit ready tokens/wait continuations first.
	_drain_event_inbox()

	var instance_rows: Array[Dictionary] = []
	for raw_instance_id: Variant in _instances:
		var instance_id := StringName(raw_instance_id)
		var instance: Dictionary = _instances[instance_id]
		instance_rows.append({
			"instance_id": String(instance_id),
			"graph_id": String(instance["graph_id"]),
			"graph_format_version": (instance["graph"] as FlowGraph).format_version,
			"parent_token_id": String(instance["parent_token_id"]),
			"parent_instance_id": String(instance["parent_instance_id"]),
			"parent_node_id": String(instance["parent_node_id"]),
		})

	var token_rows: Array[Dictionary] = []
	for raw_token_id: Variant in _tokens:
		var token_id := StringName(raw_token_id)
		var token: Dictionary = _tokens[token_id]
		var cloned := FlowPersistence.try_clone(token["locals"], "flow_graph.tokens.%s.locals" % token_id)
		if not bool(cloned.get("ok", false)):
			push_error("FlowGraphRunner: token '%s' locals are not persistable: %s" % [
				token_id, cloned.get("problems", [])])
			return {}
		var wait: Dictionary = (token["wait"] as Dictionary).duplicate(true)
		if token["status"] == STATUS_TIMER:
			var elapsed := float(Time.get_ticks_msec() - int(wait.get("started_msec", Time.get_ticks_msec()))) / 1000.0
			wait["remaining"] = maxf(0.0, float(wait.get("remaining", 0.0)) - elapsed)
		wait.erase("started_msec")
		token_rows.append({
			"token_id": String(token_id),
			"instance_id": String(token["instance_id"]),
			"node_id": String(token["node_id"]),
			"node_type_id": String(_node_for_instance(token["instance_id"], token["node_id"]).type_id()),
			"status": String(token["status"]),
			"locals": cloned["value"],
			"wait": wait,
		})

	var leases: Array[Dictionary] = []
	for lease_key: StringName in _owned_input_leases:
		var lease: Dictionary = _owned_input_leases[lease_key]
		var owner_strings: Array[String] = []
		for owner_token_id: StringName in lease.get("owners", []):
			owner_strings.append(String(owner_token_id))
		leases.append({
			"key": String(lease_key),
			"instance_id": String(lease.get("instance_id", "")),
			"owners": owner_strings,
		})

	var ready_strings: Array[String] = []
	for token_id in _ready_tokens:
		ready_strings.append(String(token_id))
	return {
		"version": SNAPSHOT_VERSION,
		"master_graph_id": String(
			_instances[_master_instance_id]["graph_id"] if _instances.has(_master_instance_id) else &""),
		"master_instance_id": String(_master_instance_id),
		"next_instance_number": _next_instance_number,
		"next_token_number": _next_token_number,
		"instances": instance_rows,
		"tokens": token_rows,
		"ready": ready_strings,
		"input_leases": leases,
	}


func restore_from_dict(state: Dictionary, keep_suspended: bool = true) -> bool:
	cancel_all()
	if state.is_empty():
		return true
	var snapshot_problems := FlowPersistence.validate(state, "flow_graph")
	if not snapshot_problems.is_empty():
		return _reject_restore("snapshot contains unsafe data: %s" % \
				FlowPersistence.format_problems(snapshot_problems))
	if not _database_graphs_are_valid(_database()):
		return false
	var snapshot_version := int(state.get("version", 0))
	if snapshot_version <= 0 or snapshot_version > SNAPSHOT_VERSION:
		return _reject_restore("unsupported graph snapshot version %d" % snapshot_version)

	_suspended = true
	_next_instance_number = maxi(1, int(state.get("next_instance_number", 1)))
	_next_token_number = maxi(1, int(state.get("next_token_number", 1)))
	_master_instance_id = StringName(str(state.get("master_instance_id", "")))

	var rows: Variant = state.get("instances", [])
	if not rows is Array:
		return _reject_restore("snapshot instances must be an Array")
	var seen_instance_ids := {}
	for raw_row: Variant in rows:
		if not raw_row is Dictionary:
			return _reject_restore("snapshot contains a non-Dictionary graph instance")
		var row: Dictionary = raw_row
		var instance_id := StringName(str(row.get("instance_id", "")))
		var graph_id := StringName(str(row.get("graph_id", "")))
		var graph := _load_graph(graph_id)
		if instance_id.is_empty() or seen_instance_ids.has(instance_id):
			return _reject_restore("snapshot has an empty or duplicate graph instance id '%s'" % instance_id)
		if graph == null:
			return _reject_restore("saved graph instance cannot resolve '%s'" % graph_id)
		var saved_graph_version := int(row.get("graph_format_version", graph.format_version))
		if saved_graph_version != graph.format_version:
			return _reject_restore("graph '%s' changed schema version (%d -> %d)" % [
				graph_id, saved_graph_version, graph.format_version])
		seen_instance_ids[instance_id] = true
		_instances[instance_id] = {
			"instance_id": instance_id,
			"graph_id": graph_id,
			"graph": graph,
			"parent_token_id": StringName(str(row.get("parent_token_id", ""))),
			"parent_instance_id": StringName(str(row.get("parent_instance_id", ""))),
			"parent_node_id": StringName(str(row.get("parent_node_id", ""))),
		}
	if _master_instance_id.is_empty() or not _instances.has(_master_instance_id):
		return _reject_restore("snapshot does not resolve its master graph instance")
	var master_instance: Dictionary = _instances[_master_instance_id]
	if (master_instance["graph"] as FlowGraph).kind != FlowGraph.Kind.MASTER:
		return _reject_restore("snapshot root graph '%s' is not a master graph" % master_instance["graph_id"])
	var saved_master_graph_id := StringName(str(state.get("master_graph_id", master_instance["graph_id"])))
	if saved_master_graph_id != master_instance["graph_id"]:
		return _reject_restore("snapshot master graph id does not match its root instance")

	var token_rows: Variant = state.get("tokens", [])
	if not token_rows is Array:
		return _reject_restore("snapshot tokens must be an Array")
	var seen_token_ids := {}
	for raw_row: Variant in token_rows:
		if not raw_row is Dictionary:
			return _reject_restore("snapshot contains a non-Dictionary token")
		var row: Dictionary = raw_row
		var token_id := StringName(str(row.get("token_id", "")))
		var instance_id := StringName(str(row.get("instance_id", "")))
		var node_id := StringName(str(row.get("node_id", "")))
		var status := StringName(str(row.get("status", "")))
		var resolved_node := _node_for_instance(instance_id, node_id)
		if token_id.is_empty() or seen_token_ids.has(token_id):
			return _reject_restore("snapshot has an empty or duplicate token id '%s'" % token_id)
		if not _instances.has(instance_id) or resolved_node == null:
			return _reject_restore("saved token '%s' has an unknown graph node" % token_id)
		var saved_type_id := StringName(str(row.get("node_type_id", resolved_node.type_id())))
		if saved_type_id != resolved_node.type_id():
			return _reject_restore("saved token '%s' changed node type ('%s' -> '%s')" % [
				token_id, saved_type_id, resolved_node.type_id()])
		if status not in [STATUS_READY, STATUS_TIMER, STATUS_EVENT, STATUS_SUBGRAPH]:
			return _reject_restore("saved token '%s' has unsupported status '%s'" % [token_id, status])
		var locals_value: Variant = row.get("locals", {})
		var wait_value: Variant = row.get("wait", {})
		if not locals_value is Dictionary or not wait_value is Dictionary:
			return _reject_restore("saved token '%s' has invalid locals or wait state" % token_id)
		var wait: Dictionary = (wait_value as Dictionary).duplicate(true)
		if not _validate_restored_wait(token_id, status, wait):
			return false
		seen_token_ids[token_id] = true
		_tokens[token_id] = {
			"token_id": token_id,
			"instance_id": instance_id,
			"node_id": node_id,
			"status": status,
			"locals": (locals_value as Dictionary).duplicate(true),
			"event_data": {},
			"wait": wait,
		}
		if status == STATUS_EVENT:
			var event_id := StringName(str((_tokens[token_id]["wait"] as Dictionary).get("event_id", "")))
			if not _event_waiters.has(event_id):
				_event_waiters[event_id] = [] as Array[StringName]
			(_event_waiters[event_id] as Array).append(token_id)

	var ready_value: Variant = state.get("ready", [])
	if not ready_value is Array:
		return _reject_restore("snapshot ready queue must be an Array")
	var seen_ready := {}
	for raw_ready: Variant in ready_value:
		var token_id := StringName(str(raw_ready))
		if seen_ready.has(token_id) or not _tokens.has(token_id) \
				or _tokens[token_id]["status"] != STATUS_READY:
			return _reject_restore("snapshot has an invalid or duplicate ready token '%s'" % token_id)
		seen_ready[token_id] = true
		_ready_tokens.append(token_id)
	for raw_token_id: Variant in _tokens:
		var token_id := StringName(raw_token_id)
		if _tokens[token_id]["status"] == STATUS_READY and not seen_ready.has(token_id):
			return _reject_restore("ready token '%s' is missing from the ready queue" % token_id)

	if not _validate_restored_relationships():
		return false

	var leases_value: Variant = state.get("input_leases", [])
	if not leases_value is Array:
		return _reject_restore("snapshot input leases must be an Array")
	for raw_lease: Variant in leases_value:
		if not raw_lease is Dictionary:
			return _reject_restore("snapshot contains an invalid input lease")
		var lease: Dictionary = raw_lease
		var key := StringName(str(lease.get("key", "")))
		var instance_id := StringName(str(lease.get("instance_id", "")))
		if key.is_empty() or _owned_input_leases.has(key) or not _instances.has(instance_id):
			return _reject_restore("snapshot contains an unresolved or duplicate input lease '%s'" % key)
		var owners: Array[StringName] = []
		var raw_owners: Variant = lease.get("owners", [])
		if not raw_owners is Array:
			return _reject_restore("snapshot input lease '%s' has invalid owners" % key)
		for raw_owner: Variant in raw_owners:
			var owner_token_id := StringName(str(raw_owner))
			if owner_token_id.is_empty() or owners.has(owner_token_id) \
					or not _tokens.has(owner_token_id) \
					or _tokens[owner_token_id]["instance_id"] != instance_id:
				return _reject_restore("snapshot input lease '%s' has an unresolved owner" % key)
			owners.append(owner_token_id)
		if owners.is_empty():
			return _reject_restore("snapshot input lease '%s' has no owners" % key)
		_owned_input_leases[key] = {
			"instance_id": instance_id,
			"owners": owners,
		}
		FlowSystem.acquire_gameplay_input(key)

	_rebuild_entry_index()
	_set_active(true)
	_suspended = keep_suspended
	if not _suspended:
		resume()
	return true


func _validate_restored_wait(
		token_id: StringName,
		status: StringName,
		wait: Dictionary
) -> bool:
	match status:
		STATUS_READY:
			if not wait.is_empty():
				return _reject_restore("ready token '%s' unexpectedly has wait state" % token_id)
		STATUS_TIMER:
			var remaining_value: Variant = wait.get("remaining")
			var remaining := float(remaining_value) if remaining_value is int or remaining_value is float else -1.0
			if wait.get("kind", "") != "timer" or remaining < 0.0 or not is_finite(remaining):
				return _reject_restore("timer token '%s' has an invalid wait descriptor" % token_id)
			wait["remaining"] = remaining
		STATUS_EVENT:
			var event_id := StringName(str(wait.get("event_id", "")))
			if wait.get("kind", "") != "event" or event_id.is_empty():
				return _reject_restore("event token '%s' has an invalid wait descriptor" % token_id)
			wait["event_id"] = event_id
		STATUS_SUBGRAPH:
			var child_id := StringName(str(wait.get("child_instance_id", "")))
			if wait.get("kind", "") != "subgraph" or child_id.is_empty():
				return _reject_restore("subgraph token '%s' has an invalid wait descriptor" % token_id)
			wait["child_instance_id"] = child_id
	return true


func _validate_restored_relationships() -> bool:
	for raw_instance_id: Variant in _instances:
		var instance_id := StringName(raw_instance_id)
		var instance: Dictionary = _instances[instance_id]
		var parent_token_id := StringName(instance["parent_token_id"])
		var parent_instance_id := StringName(instance["parent_instance_id"])
		if instance_id == _master_instance_id:
			if not parent_token_id.is_empty() or not parent_instance_id.is_empty():
				return _reject_restore("master graph instance cannot have a parent")
			continue
		if (instance["graph"] as FlowGraph).kind != FlowGraph.Kind.SUBGRAPH:
			return _reject_restore("child graph instance '%s' is not a subgraph" % instance_id)
		if not _instances.has(parent_instance_id) or not _tokens.has(parent_token_id):
			return _reject_restore("subgraph instance '%s' has an unresolved parent" % instance_id)
		var parent_token: Dictionary = _tokens[parent_token_id]
		var parent_wait: Dictionary = parent_token["wait"]
		if parent_token["instance_id"] != parent_instance_id \
				or parent_token["status"] != STATUS_SUBGRAPH \
				or StringName(parent_wait.get("child_instance_id", &"")) != instance_id \
				or parent_token["node_id"] != instance["parent_node_id"]:
			return _reject_restore("subgraph instance '%s' does not match its caller token" % instance_id)

	for raw_token_id: Variant in _tokens:
		var token_id := StringName(raw_token_id)
		var token: Dictionary = _tokens[token_id]
		if token["status"] != STATUS_SUBGRAPH:
			continue
		var child_id := StringName((token["wait"] as Dictionary).get("child_instance_id", &""))
		if not _instances.has(child_id) or _instances[child_id]["parent_token_id"] != token_id:
			return _reject_restore("subgraph token '%s' does not resolve its child instance" % token_id)
	return true


func _reject_restore(message: String) -> bool:
	push_error("FlowGraphRunner: restore rejected: %s." % message)
	cancel_all()
	return false

#endregion


#region Inspection

func debug_snapshot() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw_token_id: Variant in _tokens:
		var token_id := StringName(raw_token_id)
		var token: Dictionary = _tokens[token_id]
		var instance: Dictionary = _instances.get(token["instance_id"], {})
		out.append({
			"token_id": token_id,
			"graph_id": instance.get("graph_id", &""),
			"instance_id": token["instance_id"],
			"subgraph_stack": _instance_stack(token["instance_id"]),
			"node_id": token["node_id"],
			"status": token["status"],
			"wait": (token["wait"] as Dictionary).duplicate(true),
		})
	return out


func active_token_count() -> int:
	return _tokens.size()

#endregion


#region Helpers

func _database() -> FlowDatabase:
	return FlowSystem.instance.database if FlowSystem.instance != null else null


func _load_graph(graph_id: StringName) -> FlowGraph:
	var database := _database()
	if database == null:
		return null
	return database.get_graph(graph_id)


func _database_graphs_are_valid(database: FlowDatabase) -> bool:
	if database == null:
		push_error("FlowGraphRunner: no FlowDatabase is assigned.")
		return false
	var valid := true
	for issue: FlowValidationIssue in database.validate_graphs():
		if issue.is_error():
			push_error("FlowGraphRunner: graph activation blocked: %s" % issue.format_message())
			valid = false
	return valid


func _node_for_instance(instance_id: StringName, node_id: StringName) -> FlowGraphNode:
	var instance: Dictionary = _instances.get(instance_id, {})
	if instance.is_empty():
		return null
	return (instance["graph"] as FlowGraph).get_node(node_id)


func _instance_stack(instance_id: StringName) -> Array[StringName]:
	var reversed: Array[StringName] = []
	var current_id := instance_id
	var visited := {}
	while _instances.has(current_id) and not visited.has(current_id):
		visited[current_id] = true
		var instance: Dictionary = _instances[current_id]
		reversed.append(StringName(instance["graph_id"]))
		current_id = StringName(instance["parent_instance_id"])
	reversed.reverse()
	return reversed


func _nodes_of_type(graph: FlowGraph, type_id: StringName) -> Array[FlowGraphNode]:
	var out: Array[FlowGraphNode] = []
	for node: FlowGraphNode in graph.nodes:
		if node != null and node.type_id() == type_id:
			out.append(node)
	return out


func _outgoing(graph: FlowGraph, node_id: StringName, port_id: StringName) -> Array[FlowGraphConnection]:
	return graph.outgoing_connections(node_id, port_id)


func _index_instance_entries(instance_id: StringName) -> void:
	var instance: Dictionary = _instances[instance_id]
	var graph: FlowGraph = instance["graph"]
	for node: FlowGraphNode in _nodes_of_type(graph, &"event_entry"):
		if not node.enabled or node.event_id.is_empty():
			continue
		if not _event_entries.has(node.event_id):
			_event_entries[node.event_id] = []
		(_event_entries[node.event_id] as Array).append({
			"instance_id": instance_id,
			"node_id": node.node_id,
		})


func _rebuild_entry_index() -> void:
	_event_entries.clear()
	for raw_instance_id: Variant in _instances:
		_index_instance_entries(StringName(raw_instance_id))


func _entry_once_flag(graph_id: StringName, node_id: StringName) -> StringName:
	return StringName("flow_entry_%s_%s" % [graph_id, node_id])


func _acquire_token_input_lease(
		token_id: StringName,
		instance_id: StringName,
		authored_id: StringName
) -> void:
	var lease_key := _input_lease_key(instance_id, authored_id)
	if not _owned_input_leases.has(lease_key):
		_owned_input_leases[lease_key] = {
			"instance_id": instance_id,
			"owners": [] as Array[StringName],
		}
		FlowSystem.acquire_gameplay_input(lease_key)
	var lease: Dictionary = _owned_input_leases[lease_key]
	var owners: Array[StringName] = lease["owners"]
	if not owners.has(token_id):
		owners.append(token_id)


func _release_token_input_lease(
		token_id: StringName,
		instance_id: StringName,
		authored_id: StringName
) -> void:
	var lease_key := _input_lease_key(instance_id, authored_id)
	if not _owned_input_leases.has(lease_key):
		return
	var lease: Dictionary = _owned_input_leases[lease_key]
	var owners: Array[StringName] = lease["owners"]
	owners.erase(token_id)
	if owners.is_empty():
		_owned_input_leases.erase(lease_key)
		FlowSystem.release_gameplay_input(lease_key)


func _release_all_token_input_leases(token_id: StringName) -> void:
	for lease_key: StringName in _owned_input_leases.keys():
		var lease: Dictionary = _owned_input_leases[lease_key]
		var owners: Array[StringName] = lease["owners"]
		owners.erase(token_id)
		if owners.is_empty():
			_owned_input_leases.erase(lease_key)
			FlowSystem.release_gameplay_input(lease_key)


func _input_lease_key(instance_id: StringName, authored_id: StringName) -> StringName:
	var local_id := authored_id if not authored_id.is_empty() else &"default"
	return StringName("graph:%s:%s" % [instance_id, local_id])


func _emit_token_event(token_id: StringName, state: StringName, extra: Dictionary = {}) -> void:
	if not _tokens.has(token_id):
		return
	var token: Dictionary = _tokens[token_id]
	var instance: Dictionary = _instances.get(token["instance_id"], {})
	var event := {
		"state": state,
		"graph_id": instance.get("graph_id", &""),
		"graph_instance_id": token["instance_id"],
		"token_id": token_id,
		"node_id": token["node_id"],
	}
	for key: Variant in extra:
		event[key] = extra[key]
	telemetry.emit(event)


func _set_active(value: bool) -> void:
	if _active == value:
		return
	_active = value
	active_changed.emit(value)

#endregion
