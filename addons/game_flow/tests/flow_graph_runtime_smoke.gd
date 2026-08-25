extends SceneTree

## Focused, in-memory graph runtime integration test.
##
## Run with:
## godot --headless --path . --script res://addons/game_flow/tests/flow_graph_runtime_smoke.gd

const ActionHandleScript := preload("res://addons/game_flow/core/flow_action_handle.gd")
const EventsScript := preload("res://addons/game_flow/core/flow_events.gd")
const PersistenceScript := preload("res://addons/game_flow/core/flow_persistence.gd")
const StateScript := preload("res://addons/game_flow/core/flow_state.gd")
const SystemScript := preload("res://addons/game_flow/core/flow_system.gd")

const DatabaseScript := preload("res://addons/game_flow/data/flow_database.gd")
const LevelEntryScript := preload("res://addons/game_flow/data/flow_level_entry.gd")
const CutsceneEntryScript := preload("res://addons/game_flow/data/flow_cutscene_entry.gd")
const GraphScript := preload("res://addons/game_flow/data/flow_graph.gd")
const GraphConnectionScript := preload("res://addons/game_flow/data/flow_graph_connection.gd")
const GraphEntryScript := preload("res://addons/game_flow/data/flow_graph_entry.gd")
const GameStartNodeScript := preload("res://addons/game_flow/data/flow_game_start_node.gd")
const EventEntryNodeScript := preload("res://addons/game_flow/data/flow_event_entry_node.gd")
const ParallelNodeScript := preload("res://addons/game_flow/data/flow_parallel_node.gd")
const RandomNodeScript := preload("res://addons/game_flow/data/flow_random_node.gd")
const RandomBranchScript := preload("res://addons/game_flow/data/flow_random_branch.gd")
const DisableInputNodeScript := preload("res://addons/game_flow/data/flow_disable_input_node.gd")
const EnableInputNodeScript := preload("res://addons/game_flow/data/flow_enable_input_node.gd")
const WaitTimerNodeScript := preload("res://addons/game_flow/data/flow_wait_timer_node.gd")
const WaitEventNodeScript := preload("res://addons/game_flow/data/flow_wait_event_node.gd")
const IfNodeScript := preload("res://addons/game_flow/data/flow_if_node.gd")
const ConditionScript := preload("res://addons/game_flow/data/flow_condition.gd")
const PlayCutsceneNodeScript := preload("res://addons/game_flow/data/flow_play_cutscene_node.gd")
const LoadLevelNodeScript := preload("res://addons/game_flow/data/flow_load_level_node.gd")
const RequestSaveNodeScript := preload("res://addons/game_flow/data/flow_request_save_node.gd")
const CallSubgraphNodeScript := preload("res://addons/game_flow/data/flow_call_subgraph_node.gd")
const SubgraphEntryNodeScript := preload("res://addons/game_flow/data/flow_subgraph_entry_node.gd")
const SubgraphExitNodeScript := preload("res://addons/game_flow/data/flow_subgraph_exit_node.gd")
const InvokeActionNodeScript := preload("res://addons/game_flow/data/flow_invoke_action_node.gd")
const EndNodeScript := preload("res://addons/game_flow/data/flow_end_node.gd")

const MASTER_GRAPH_ID := &"runtime_smoke_master"
const SUBGRAPH_ID := &"runtime_smoke_subgraph"
const ACTION_ID := &"runtime_smoke.record"
const WAIT_EVENT_ID := &"runtime_smoke.release_event"
const CUTSCENE_ID := &"runtime_smoke_cutscene"
const LEVEL_ID := &"runtime_smoke_level"
const LEVEL_SPAWN_ID := &"smoke_spawn"
const SAVE_REASON := &"runtime_smoke_checkpoint"
const SHARED_INPUT_LEASE_ID := &"shared_parallel_control"

const CUTSCENE_SCENE_PATH := "res://addons/game_flow/tests/fixtures/runtime_smoke_cutscene.tscn"
const LEVEL_SCENE_PATH := "res://addons/game_flow/tests/fixtures/runtime_smoke_level.tscn"

const MARKER_FALSE_BRANCH := &"if_false"
const MARKER_TIMER := &"timer"
const MARKER_EVENT_TRUE := &"event_true"
const MARKER_EVENT_FALSE := &"unexpected_event_false"
const MARKER_EVENT_ENTRY := &"event_entry"
const MARKER_OPERATION_COMPLETE := &"operation_complete"
const MARKER_OPERATION_FAILED := &"unexpected_operation_failed"
const MARKER_SUBGRAPH := &"subgraph"
const MARKER_SUBGRAPH_PARENT := &"subgraph_parent"
const MARKER_SUBGRAPH_FAILED := &"unexpected_subgraph_failed"
const MARKER_FALSE_TRUE := &"unexpected_false_true"
const RANDOM_COMMON_END := &"random_common_end"
const RANDOM_RARE_END := &"random_rare_end"

var _failures: int = 0
var _host: Node
var _system
var _database
var _provider_counts: Dictionary = {}
var _provider_contexts: Array[Dictionary] = []
var _entered_counts: Dictionary = {}
var _input_changes: Array[bool] = []
var _same_event_order: Array[StringName] = []
var _cutscene_started_ids: Array[StringName] = []
var _cutscene_finished_rows: Array[Dictionary] = []
var _load_started_ids: Array[StringName] = []
var _level_entered_rows: Array[Dictionary] = []
var _save_request_reasons: Array[StringName] = []
var _save_request_snapshots: Array[Dictionary] = []
var _save_request_quiescent: Array[bool] = []
var _save_request_successor_counts: Array[int] = []
var _arbiter_active_transitions: int = 0
var _install_world_calls: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	EventsScript.reset()
	StateScript.reset()
	_database = _build_database()

	_test_structured_validation()
	_test_runtime_object_rejection()
	await _install_runtime()

	_check(not SystemScript.has_active_graph(),
		"a configured master graph remains opt-in")
	SystemScript.register_action(ACTION_ID, _record_action)
	await _test_stale_timer_generation_guards()
	_reset_observations()
	StateScript.reset()
	StateScript.set_flag(&"route_true")
	SystemScript.set_mode(SystemScript.Mode.GAMEPLAY)
	var started := SystemScript.start_master_graph()
	_check(started, "the in-memory master graph starts explicitly")
	if started:
		await _exercise_runtime_and_restore()

	await _cleanup()
	if _failures == 0:
		print("Flow graph runtime smoke: PASS")
		quit()
	else:
		push_error("Flow graph runtime smoke: %d failure(s)" % _failures)
		quit(1)


func _build_database():
	var database := DatabaseScript.new()
	var master = _build_master_graph()
	var subgraph = _build_subgraph()
	database.graphs.append(_graph_entry(MASTER_GRAPH_ID, master))
	database.graphs.append(_graph_entry(SUBGRAPH_ID, subgraph))
	database.cutscenes.append(_cutscene_entry())
	database.levels.append(_level_entry())
	database.master_graph_id = MASTER_GRAPH_ID
	database.rebuild_index()
	return database


func _build_master_graph():
	var graph := GraphScript.new()
	graph.kind = GraphScript.Kind.MASTER
	graph.display_name = "Runtime Smoke Master"

	var start := GameStartNodeScript.new()
	start.node_id = &"start"
	var same_event_entry := EventEntryNodeScript.new()
	same_event_entry.node_id = &"same_event_entry"
	same_event_entry.event_id = WAIT_EVENT_ID
	same_event_entry.one_shot = true
	var same_event_action = _action_node(&"same_event_action", MARKER_EVENT_ENTRY)
	var same_event_end = _end_node(&"same_event_end")
	var fork := ParallelNodeScript.new()
	fork.node_id = &"fork"

	var timer_disable := DisableInputNodeScript.new()
	timer_disable.node_id = &"timer_disable"
	timer_disable.lease_id = SHARED_INPUT_LEASE_ID
	var timer_wait := WaitTimerNodeScript.new()
	timer_wait.node_id = &"timer_wait"
	timer_wait.seconds = 0.35
	var timer_action = _action_node(&"timer_action", MARKER_TIMER)
	var timer_enable := EnableInputNodeScript.new()
	timer_enable.node_id = &"timer_enable"
	timer_enable.lease_id = SHARED_INPUT_LEASE_ID
	var timer_end = _end_node(&"timer_end")

	var event_disable := DisableInputNodeScript.new()
	event_disable.node_id = &"event_disable"
	event_disable.lease_id = SHARED_INPUT_LEASE_ID
	var event_wait := WaitEventNodeScript.new()
	event_wait.node_id = &"event_wait"
	event_wait.event_id = WAIT_EVENT_ID
	var event_if := IfNodeScript.new()
	event_if.node_id = &"event_if"
	event_if.condition = _flag_condition(&"route_true")
	var event_true = _action_node(&"event_true", MARKER_EVENT_TRUE)
	var event_false = _action_node(&"event_false", MARKER_EVENT_FALSE)
	var event_enable := EnableInputNodeScript.new()
	event_enable.node_id = &"event_enable"
	event_enable.lease_id = SHARED_INPUT_LEASE_ID
	var event_end = _end_node(&"event_end")

	var call_subgraph := CallSubgraphNodeScript.new()
	call_subgraph.node_id = &"call_subgraph"
	call_subgraph.subgraph_id = SUBGRAPH_ID
	call_subgraph.exit_ids = [&"completed"] as Array[StringName]
	var subgraph_parent_action = _action_node(
		&"subgraph_parent_action", MARKER_SUBGRAPH_PARENT)
	var subgraph_failed_action = _action_node(
		&"subgraph_failed_action", MARKER_SUBGRAPH_FAILED)
	var subgraph_end = _end_node(&"subgraph_end")
	var subgraph_failed_end = _end_node(&"subgraph_failed_end")

	# A second IF takes the false port immediately. The event branch above later proves the true
	# port from the same FlowState-backed condition source after snapshot restoration.
	var false_probe := IfNodeScript.new()
	false_probe.node_id = &"false_probe"
	false_probe.condition = _flag_condition(&"route_false")
	var false_true = _action_node(&"false_true", MARKER_FALSE_TRUE)
	var false_action = _action_node(&"false_action", MARKER_FALSE_BRANCH)
	var false_probe_end = _end_node(&"false_probe_end")

	# The injected sample of 0.999 falls in the final 1% branch. This proves authored weighting,
	# stable named ports, deterministic runtime injection, and exactly-one-output traversal.
	var random := RandomNodeScript.new()
	random.node_id = &"random_probe"
	random.branches = [
		_random_branch(&"common", 99.0),
		_random_branch(&"rare", 1.0),
	]
	var random_common_end = _end_node(RANDOM_COMMON_END)
	var random_rare_end = _end_node(RANDOM_RARE_END)

	var play_cutscene := PlayCutsceneNodeScript.new()
	play_cutscene.node_id = &"operation_cutscene"
	play_cutscene.cutscene_id = CUTSCENE_ID
	play_cutscene.context = {"fixture": "runtime_smoke"}
	var load_level := LoadLevelNodeScript.new()
	load_level.node_id = &"operation_load_level"
	load_level.level_id = LEVEL_ID
	load_level.spawn_id = LEVEL_SPAWN_ID
	load_level.transition_data = {"fixture": "runtime_smoke"}
	var request_save := RequestSaveNodeScript.new()
	request_save.node_id = &"operation_request_save"
	request_save.reason = SAVE_REASON
	var operation_complete = _action_node(
		&"operation_complete_action", MARKER_OPERATION_COMPLETE)
	var operation_failed = _action_node(
		&"operation_failed_action", MARKER_OPERATION_FAILED)
	var operation_end = _end_node(&"operation_end")
	var operation_failed_end = _end_node(&"operation_failed_end")

	for node in [
		start, same_event_entry, same_event_action, same_event_end, fork,
		timer_disable, timer_wait, timer_action, timer_enable, timer_end,
		event_disable, event_wait, event_if, event_true, event_false, event_enable, event_end,
		call_subgraph, subgraph_parent_action, subgraph_failed_action,
		subgraph_end, subgraph_failed_end,
		false_probe, false_true, false_action, false_probe_end,
		random, random_common_end, random_rare_end,
		play_cutscene, load_level, request_save, operation_complete, operation_failed,
		operation_end, operation_failed_end,
	]:
		graph.nodes.append(node)

	_wire(graph, &"start_fork", &"start", &"out", &"fork")
	_wire(graph, &"same_event_entry_action", &"same_event_entry", &"out", &"same_event_action")
	_wire(graph, &"same_event_action_end", &"same_event_action", &"completed", &"same_event_end")
	_wire(graph, &"same_event_action_failed_end", &"same_event_action", &"failed", &"same_event_end")

	_wire(graph, &"fork_timer", &"fork", &"out", &"timer_disable", 0)
	_wire(graph, &"timer_disable_wait", &"timer_disable", &"out", &"timer_wait")
	_wire(graph, &"timer_wait_action", &"timer_wait", &"out", &"timer_action")
	_wire(graph, &"timer_action_enable", &"timer_action", &"completed", &"timer_enable")
	_wire(graph, &"timer_action_failed_enable", &"timer_action", &"failed", &"timer_enable")
	_wire(graph, &"timer_enable_end", &"timer_enable", &"out", &"timer_end")

	_wire(graph, &"fork_event", &"fork", &"out", &"event_disable", 1)
	_wire(graph, &"event_disable_wait", &"event_disable", &"out", &"event_wait")
	_wire(graph, &"event_wait_if", &"event_wait", &"out", &"event_if")
	_wire(graph, &"event_if_true", &"event_if", &"true", &"event_true")
	_wire(graph, &"event_if_false", &"event_if", &"false", &"event_false")
	_wire(graph, &"event_true_enable", &"event_true", &"completed", &"event_enable")
	_wire(graph, &"event_true_failed_enable", &"event_true", &"failed", &"event_enable")
	_wire(graph, &"event_false_enable", &"event_false", &"completed", &"event_enable")
	_wire(graph, &"event_false_failed_enable", &"event_false", &"failed", &"event_enable")
	_wire(graph, &"event_enable_end", &"event_enable", &"out", &"event_end")

	_wire(graph, &"fork_subgraph", &"fork", &"out", &"call_subgraph", 2)
	_wire(graph, &"subgraph_complete", &"call_subgraph", &"completed", &"subgraph_parent_action")
	_wire(graph, &"subgraph_parent_end", &"subgraph_parent_action", &"completed", &"subgraph_end")
	_wire(graph, &"subgraph_parent_failed_end", &"subgraph_parent_action", &"failed", &"subgraph_end")
	_wire(graph, &"subgraph_failed", &"call_subgraph", &"failed", &"subgraph_failed_action")
	_wire(graph, &"subgraph_failed_end", &"subgraph_failed_action", &"completed", &"subgraph_failed_end")
	_wire(graph, &"subgraph_failed_failed_end", &"subgraph_failed_action", &"failed", &"subgraph_failed_end")

	_wire(graph, &"fork_false_probe", &"fork", &"out", &"false_probe", 3)
	_wire(graph, &"false_probe_wrong", &"false_probe", &"true", &"false_true")
	_wire(graph, &"false_probe_expected", &"false_probe", &"false", &"false_action")
	_wire(graph, &"false_true_end", &"false_true", &"completed", &"false_probe_end")
	_wire(graph, &"false_true_failed_end", &"false_true", &"failed", &"false_probe_end")
	_wire(graph, &"false_action_end", &"false_action", &"completed", &"false_probe_end")
	_wire(graph, &"false_action_failed_end", &"false_action", &"failed", &"false_probe_end")

	_wire(graph, &"fork_random", &"fork", &"out", &"random_probe", 5)
	_wire(graph, &"random_common", &"random_probe", &"common", RANDOM_COMMON_END)
	_wire(graph, &"random_rare", &"random_probe", &"rare", RANDOM_RARE_END)

	_wire(graph, &"fork_operations", &"fork", &"out", &"operation_cutscene", 4)
	_wire(graph, &"operation_cutscene_load", &"operation_cutscene", &"completed", &"operation_load_level")
	_wire(graph, &"operation_cutscene_failed", &"operation_cutscene", &"failed", &"operation_failed_action")
	_wire(graph, &"operation_load_save", &"operation_load_level", &"completed", &"operation_request_save")
	_wire(graph, &"operation_load_failed", &"operation_load_level", &"failed", &"operation_failed_action")
	_wire(graph, &"operation_save_complete", &"operation_request_save", &"out", &"operation_complete_action")
	_wire(graph, &"operation_complete_end", &"operation_complete_action", &"completed", &"operation_end")
	_wire(graph, &"operation_complete_failed_end", &"operation_complete_action", &"failed", &"operation_end")
	_wire(graph, &"operation_failed_end", &"operation_failed_action", &"completed", &"operation_failed_end")
	_wire(graph, &"operation_failed_failed_end", &"operation_failed_action", &"failed", &"operation_failed_end")
	return graph


func _build_subgraph():
	var graph := GraphScript.new()
	graph.kind = GraphScript.Kind.SUBGRAPH
	graph.display_name = "Runtime Smoke Sequence"

	var entry := SubgraphEntryNodeScript.new()
	entry.node_id = &"entry"
	var wait := WaitTimerNodeScript.new()
	wait.node_id = &"subgraph_wait"
	wait.seconds = 0.25
	var action = _action_node(&"subgraph_action", MARKER_SUBGRAPH)
	var exit := SubgraphExitNodeScript.new()
	exit.node_id = &"completed_exit"
	exit.exit_id = &"completed"

	for node in [entry, wait, action, exit]:
		graph.nodes.append(node)
	_wire(graph, &"entry_wait", &"entry", &"out", &"subgraph_wait")
	_wire(graph, &"wait_action", &"subgraph_wait", &"out", &"subgraph_action")
	_wire(graph, &"action_exit", &"subgraph_action", &"completed", &"completed_exit")
	_wire(graph, &"action_failed_exit", &"subgraph_action", &"failed", &"completed_exit")
	return graph


func _graph_entry(graph_id: StringName, graph):
	var entry := GraphEntryScript.new()
	entry.graph_id = graph_id
	entry.graph = graph
	return entry


func _cutscene_entry():
	var entry := CutsceneEntryScript.new()
	entry.cutscene_id = CUTSCENE_ID
	entry.scene_path = CUTSCENE_SCENE_PATH
	entry.blocks_input = true
	return entry


func _level_entry():
	var entry := LevelEntryScript.new()
	entry.level_id = LEVEL_ID
	entry.scene_path = LEVEL_SCENE_PATH
	entry.default_spawn = LEVEL_SPAWN_ID
	return entry


func _action_node(node_id: StringName, marker: StringName):
	var node := InvokeActionNodeScript.new()
	node.node_id = node_id
	node.action_id = ACTION_ID
	node.arguments = {"marker": marker}
	return node


func _end_node(node_id: StringName):
	var node := EndNodeScript.new()
	node.node_id = node_id
	return node


func _random_branch(port_id: StringName, weight: float):
	var branch := RandomBranchScript.new()
	branch.port_id = port_id
	branch.weight = weight
	return branch


func _flag_condition(flag_id: StringName):
	var condition := ConditionScript.new()
	condition.source = ConditionScript.Source.FLOW_STATE_FLAG
	condition.key = flag_id
	condition.operator = ConditionScript.Operator.IS_TRUE
	return condition


func _wire(
		graph,
		connection_id: StringName,
		from_node_id: StringName,
		from_port_id: StringName,
		to_node_id: StringName,
		order: int = 0
) -> void:
	var connection := GraphConnectionScript.new()
	connection.connection_id = connection_id
	connection.from_node_id = from_node_id
	connection.from_port_id = from_port_id
	connection.to_node_id = to_node_id
	connection.to_port_id = &"in"
	connection.order = order
	graph.connections.append(connection)


func _test_structured_validation() -> void:
	var valid_issues: Array = _database.validate_graphs()
	_check(valid_issues.is_empty(), "the in-memory master/subgraph contract validates")
	if not valid_issues.is_empty():
		for issue in valid_issues:
			push_error("Unexpected validation issue %s: %s" % [issue.code, issue.message])

	var broken := GraphScript.new()
	broken.kind = GraphScript.Kind.MASTER
	var first := GameStartNodeScript.new()
	first.node_id = &"duplicate"
	var second := GameStartNodeScript.new()
	second.node_id = &"duplicate"
	broken.nodes.append(first)
	broken.nodes.append(second)
	_wire(broken, &"broken_wire", &"duplicate", &"out", &"missing_target")
	var codes := _issue_codes(broken.validate_detailed(&"broken_runtime_fixture", _database))
	_check(codes.has(&"duplicate_node_id"), "validation reports duplicate stable node ids")
	_check(codes.has(&"connection_missing_target"), "validation reports broken connections")
	_check(codes.has(&"master_game_start_count"), "validation reports an invalid master entry contract")

	var empty_random_graph := GraphScript.new()
	empty_random_graph.kind = GraphScript.Kind.MASTER
	var empty_random_start := GameStartNodeScript.new()
	empty_random_start.node_id = &"start"
	var empty_random := RandomNodeScript.new()
	empty_random.node_id = &"empty_random"
	empty_random.branches.clear()
	empty_random_graph.nodes.assign([empty_random_start, empty_random])
	_wire(empty_random_graph, &"start_random", &"start", &"out", &"empty_random")
	var empty_random_codes := _issue_codes(
		empty_random_graph.validate_detailed(&"empty_random_fixture", _database))
	_check(empty_random_codes.has(&"random_missing_branches"),
		"validation rejects a Random node with no authored weights")
	_check(empty_random_codes.has(&"random_no_connected_output"),
		"validation rejects a Random node without a connected weighted output")

	var invalid_weight_graph := GraphScript.new()
	invalid_weight_graph.kind = GraphScript.Kind.MASTER
	var invalid_weight_start := GameStartNodeScript.new()
	invalid_weight_start.node_id = &"start"
	var invalid_random := RandomNodeScript.new()
	invalid_random.node_id = &"invalid_random"
	invalid_random.branches = [_random_branch(&"never", 0.0)]
	var invalid_weight_end = _end_node(&"end")
	invalid_weight_graph.nodes.assign([invalid_weight_start, invalid_random, invalid_weight_end])
	_wire(invalid_weight_graph, &"start_random", &"start", &"out", &"invalid_random")
	_wire(invalid_weight_graph, &"random_end", &"invalid_random", &"never", &"end")
	var invalid_weight_codes := _issue_codes(
		invalid_weight_graph.validate_detailed(&"invalid_weight_fixture", _database))
	_check(invalid_weight_codes.has(&"random_invalid_weight"),
		"validation rejects a non-positive Random branch weight")


func _test_runtime_object_rejection() -> void:
	var runtime_node := Node.new()
	var unsafe := {"event_source": runtime_node, "callback": runtime_node.queue_free}
	_check(not PersistenceScript.is_safe(unsafe),
		"the shared persistence boundary rejects runtime Objects and Callables")
	_check(not StateScript.can_store_value(unsafe),
		"FlowState exposes the same runtime-reference rejection")
	runtime_node.free()


func _install_runtime() -> void:
	_host = Node.new()
	_host.name = "FlowGraphRuntimeSmoke"
	get_root().add_child(_host)

	var world := Node.new()
	world.name = "World"
	_host.add_child(world)
	var actors := Node.new()
	actors.name = "Actors"
	_host.add_child(actors)
	var cutscenes := Node.new()
	cutscenes.name = "Cutscenes"
	_host.add_child(cutscenes)

	_system = SystemScript.new()
	_system.name = "FlowSystem"
	_system.database = _database
	_system.world_container_path = ^"../World"
	_system.persistent_actors_path = ^"../Actors"
	_system.cutscene_container_path = ^"../Cutscenes"
	_system.cover_duration = 0.0
	_system.reveal_duration = 0.0
	_system.install_world = _install_test_world
	_host.add_child(_system)
	_system.graph_runner.set_random_float_source(func() -> float: return 0.999)
	_system.graph_telemetry.connect(_on_graph_telemetry)
	_system.cutscene_started.connect(_on_cutscene_started)
	_system.cutscene_finished.connect(_on_cutscene_finished)
	_system.load_started.connect(_on_load_started)
	_system.level_entered.connect(_on_level_entered)
	_system.save_requested.connect(_on_save_requested)
	_system.operation_arbiter.changed.connect(_on_operation_arbiter_changed)
	_system.gameplay_input_changed.connect(
		func(enabled: bool) -> void: _input_changes.append(enabled))
	SystemScript.set_mode(SystemScript.Mode.GAMEPLAY)
	await process_frame


func _install_test_world(
		scene: PackedScene,
		entry,
		spawn_id: StringName,
		transition_data: Dictionary
) -> StringName:
	_install_world_calls += 1
	for child: Node in _system.world_container.get_children():
		_system.world_container.remove_child(child)
		child.free()
	var level := scene.instantiate()
	_system.world_container.add_child(level)
	if entry.level_id != LEVEL_ID or transition_data.get("fixture", "") != "runtime_smoke":
		return &""
	return spawn_id if not spawn_id.is_empty() else entry.default_spawn


func _test_stale_timer_generation_guards() -> void:
	StateScript.set_flag(&"route_true")
	var cancel_started := SystemScript.start_master_graph()
	_check(cancel_started, "the cancellation timer probe starts")
	if cancel_started:
		var cancel_waiting := await _wait_until(_initial_wait_shape_ready, 2.0)
		_check(cancel_waiting, "the cancellation probe reaches live timer waits")
		if cancel_waiting:
			var before_cancel := _provider_counts.duplicate(true)
			_system.graph_runner.cancel_all()
			await create_timer(0.45, true).timeout
			_check(
				_provider_counts == before_cancel
				and not SystemScript.has_active_graph()
				and _system.graph_runner.active_token_count() == 0,
				"stale timer callbacks after cancel do not advance graph state")

	_reset_observations()
	StateScript.reset()
	StateScript.set_flag(&"route_true")
	SystemScript.set_mode(SystemScript.Mode.GAMEPLAY)
	var reset_started := SystemScript.start_master_graph()
	_check(reset_started, "the run-reset timer probe starts")
	if reset_started:
		var reset_waiting := await _wait_until(_initial_wait_shape_ready, 2.0)
		_check(reset_waiting, "the run-reset probe reaches live timer waits")
		if reset_waiting:
			var before_reset := _provider_counts.duplicate(true)
			SystemScript.reset_run()
			await create_timer(0.45, true).timeout
			_check(
				_provider_counts == before_reset
				and not SystemScript.has_active_graph()
				and _system.graph_runner.active_token_count() == 0,
				"stale timer callbacks after run reset do not advance graph state")


func _exercise_runtime_and_restore() -> void:
	var initial_ready := await _wait_until(_initial_wait_shape_ready, 2.0)
	_check(initial_ready,
		"parallel paths settle into timer, event, and active-subgraph waits")
	if not initial_ready:
		return

	_check(
		_cutscene_started_ids == [CUTSCENE_ID]
		and _cutscene_finished_rows.size() == 1
		and _cutscene_finished_rows[0].get("cutscene_id", &"") == CUTSCENE_ID
		and not bool(_cutscene_finished_rows[0].get("skipped", true)),
		"Play Cutscene traverses FlowSystem and completes through its graph port")
	_check(
		_load_started_ids == [LEVEL_ID]
		and _level_entered_rows.size() == 1
		and _level_entered_rows[0].get("level_id", &"") == LEVEL_ID
		and _level_entered_rows[0].get("spawn_id", &"") == LEVEL_SPAWN_ID
		and _install_world_calls == 1,
		"Load Level traverses FlowSystem, installs the fixture world, and completes")
	_check(_arbiter_active_transitions == 2,
		"the cutscene and level verbs each execute through the operation arbiter")
	_check(
		_count(MARKER_OPERATION_COMPLETE) == 1
		and _count(MARKER_OPERATION_FAILED) == 0,
		"the authored cutscene/load sequence follows only completed ports")
	_check(
		_save_request_reasons == [SAVE_REASON]
		and _save_request_quiescent == [true],
		"Request Save emits exactly once after the scheduler reaches save-safe quiescence")
	_check(
		_save_request_snapshots.size() == 1
		and not _save_request_snapshots[0].is_empty()
		and _save_request_successor_counts == [0]
		and not _snapshot_contains_node(
			_save_request_snapshots[0], &"operation_request_save"),
		"Request Save snapshots its held successor before that successor executes")

	_check(_count(MARKER_FALSE_BRANCH) == 1 and _count(MARKER_FALSE_TRUE) == 0,
		"FlowState-backed IF takes the false output exactly once")
	_check(_entered(RANDOM_COMMON_END) == 0 and _entered(RANDOM_RARE_END) == 1,
		"Random chooses exactly one weighted output from the injected deterministic sample")
	_check(not SystemScript.is_gameplay_input_enabled(),
		"overlapping graph input leases disable gameplay input")

	var snapshot := SystemScript.graph_state_to_dict()
	_check(not snapshot.is_empty(), "a waiting graph produces a runtime snapshot")
	_check(PersistenceScript.is_safe(snapshot), "the runtime snapshot contains no live references")
	_check((snapshot.get("instances", []) as Array).size() == 2,
		"the snapshot records the master and active subgraph instances")
	var lease_rows: Array = snapshot.get("input_leases", [])
	_check(
		lease_rows.size() == 1
		and lease_rows[0] is Dictionary
		and ((lease_rows[0] as Dictionary).get("owners", []) as Array).size() == 2,
		"one named input lease records both independent parallel token owners")
	var snapshot_statuses := _snapshot_status_counts(snapshot)
	_check(int(snapshot_statuses.get("timer", 0)) == 2,
		"the snapshot records both independent timer waits")
	_check(int(snapshot_statuses.get("event", 0)) == 1,
		"the snapshot records the event wait")
	_check(int(snapshot_statuses.get("subgraph", 0)) == 1,
		"the snapshot records the structured parent subgraph wait")

	_test_restore_rejections(snapshot)

	var before_restore_counts := _provider_counts.duplicate()
	var save_file_snapshot := _json_round_trip_snapshot(snapshot)
	_check(not save_file_snapshot.is_empty(),
		"the graph snapshot survives the native JSON save-file boundary")
	var restored := SystemScript.restore_graph_state(save_file_snapshot, true)
	_check(restored, "the snapshot restores successfully")
	_check(_system.graph_runner.is_suspended(), "restored execution remains suspended on request")
	_check(not SystemScript.is_gameplay_input_enabled(),
		"restored input leases re-establish disabled input")
	_check(_system.graph_runner.active_token_count() == 4,
		"restore recreates each waiting token exactly once")

	# Let the abandoned pre-restore timers expire. Their generation callbacks must be inert, while
	# restored timers remain paused until resume().
	await create_timer(0.45, true).timeout
	_check(_provider_counts == before_restore_counts,
		"cancelled timers and suspended restored timers do not advance paths")
	_check(_system.graph_runner.active_token_count() == 4,
		"suspension preserves all restored waits")

	SystemScript.resume_graph()
	var independent_paths_done := await _wait_until(_timer_and_subgraph_finished, 2.0)
	_check(independent_paths_done,
		"restored timer and subgraph paths resume independently")
	_check(_count(MARKER_TIMER) == 1, "the restored main timer continues exactly once")
	_check(_count(MARKER_SUBGRAPH) == 1,
		"the restored subgraph body continues exactly once")
	_check(_count(MARKER_SUBGRAPH_PARENT) == 1,
		"the structured subgraph exit resumes its parent exactly once")
	_check(_count(MARKER_SUBGRAPH_FAILED) == 0,
		"the structured call does not take its failure output")
	_check(not SystemScript.is_gameplay_input_enabled(),
		"releasing the timer lease leaves input disabled while the event lease remains")
	_check(_system.graph_runner.active_token_count() == 1,
		"only the restored event waiter remains active")

	# Emitting twice in one turn must consume the saved wait only once.
	EventsScript.emit(WAIT_EVENT_ID, {"source_id": "runtime_smoke"})
	EventsScript.emit(WAIT_EVENT_ID, {"source_id": "duplicate_same_turn"})
	var event_done := await _wait_until(_all_paths_finished, 2.0)
	_check(event_done, "the restored event wait resumes and finishes")
	_check(_count(MARKER_EVENT_TRUE) == 1 and _count(MARKER_EVENT_FALSE) == 0,
		"FlowState-backed IF takes the true output once after event restore")
	_check(_count(MARKER_EVENT_ENTRY) == 1,
		"the same event activates its one-shot Event Entry exactly once")
	_check(_waiter_precedes_same_event_entry(),
		"an existing waiter resumes before the same-event Event Entry activates")
	_check(SystemScript.is_gameplay_input_enabled(),
		"input returns only after the final overlapping lease is released")

	_check(_entered(&"timer_wait") == 1,
		"restoring a timer wait does not re-enter its authored node")
	_check(_entered(&"event_wait") == 1,
		"restoring an event wait does not re-enter its authored node")
	_check(_entered(&"call_subgraph") == 1 and _entered(&"subgraph_wait") == 1,
		"restoring a subgraph call does not duplicate its call or entry path")
	_check(_provider_total() == 7,
		"all expected custom actions execute once with no duplicate or failure action")
	_check(_provider_contexts_are_structured(),
		"custom action providers receive stable graph/token/node context")


func _test_restore_rejections(snapshot: Dictionary) -> void:
	var version_zero := snapshot.duplicate(true)
	version_zero["version"] = 0
	_check(_restore_is_rejected_cleanly(version_zero),
		"restore rejects an obsolete snapshot version without retaining partial state")

	var future_version := snapshot.duplicate(true)
	future_version["version"] = int(snapshot.get("version", 1)) + 1
	_check(_restore_is_rejected_cleanly(future_version),
		"restore rejects a future snapshot version without retaining partial state")

	var missing_graph_id := snapshot.duplicate(true)
	var graph_rows: Array = missing_graph_id.get("instances", [])
	if not graph_rows.is_empty() and graph_rows[0] is Dictionary:
		(graph_rows[0] as Dictionary).erase("graph_id")
	_check(_restore_is_rejected_cleanly(missing_graph_id),
		"restore rejects a missing graph id instead of guessing a graph")

	var missing_node_id := snapshot.duplicate(true)
	var missing_node_rows: Array = missing_node_id.get("tokens", [])
	if not missing_node_rows.is_empty() and missing_node_rows[0] is Dictionary:
		(missing_node_rows[0] as Dictionary).erase("node_id")
	_check(_restore_is_rejected_cleanly(missing_node_id),
		"restore rejects a missing node id instead of guessing a node")

	var changed_node_type := snapshot.duplicate(true)
	var changed_type_rows: Array = changed_node_type.get("tokens", [])
	if not changed_type_rows.is_empty() and changed_type_rows[0] is Dictionary:
		(changed_type_rows[0] as Dictionary)["node_type_id"] = "changed_fixture_type"
	_check(_restore_is_rejected_cleanly(changed_node_type),
		"restore rejects a changed node type id instead of guessing compatibility")


func _restore_is_rejected_cleanly(snapshot: Dictionary) -> bool:
	var restored := SystemScript.restore_graph_state(snapshot, true)
	return (
		not restored
		and not SystemScript.has_active_graph()
		and _system.graph_runner.active_token_count() == 0
	)


func _json_round_trip_snapshot(snapshot: Dictionary) -> Dictionary:
	var json_value: Variant = JSON.from_native(snapshot, false)
	var json_text := JSON.stringify(json_value)
	var parsed: Variant = JSON.parse_string(json_text)
	var restored: Variant = JSON.to_native(parsed, false)
	return restored as Dictionary if restored is Dictionary else {}


func _record_action(arguments: Dictionary, context: Dictionary) -> Dictionary:
	var marker := StringName(str(arguments.get("marker", "")))
	_provider_counts[marker] = _count(marker) + 1
	_provider_contexts.append({
		"marker": marker,
		"graph_id": context.get("graph_id", &""),
		"graph_instance_id": context.get("graph_instance_id", &""),
		"token_id": context.get("token_id", &""),
		"node_id": context.get("node_id", &""),
	})
	return {"success": true, "marker": String(marker)}


func _on_graph_telemetry(event: Dictionary) -> void:
	var state := StringName(event.get("state", &""))
	var node_id := StringName(event.get("node_id", &""))
	if (
		state == &"resumed"
		and node_id == &"event_wait"
		and StringName(event.get("reason", &"")) == &"event"
	):
		_same_event_order.append(&"waiter_resumed")
	elif state == &"entered" and node_id == &"same_event_entry":
		_same_event_order.append(&"event_entry_entered")
	if state != &"entered":
		return
	_entered_counts[node_id] = _entered(node_id) + 1


func _on_cutscene_started(cutscene_id: StringName) -> void:
	_cutscene_started_ids.append(cutscene_id)


func _on_cutscene_finished(cutscene_id: StringName, skipped: bool) -> void:
	_cutscene_finished_rows.append({"cutscene_id": cutscene_id, "skipped": skipped})


func _on_load_started(level_id: StringName) -> void:
	_load_started_ids.append(level_id)


func _on_level_entered(level_id: StringName, spawn_id: StringName) -> void:
	_level_entered_rows.append({"level_id": level_id, "spawn_id": spawn_id})


func _on_save_requested(reason: StringName) -> void:
	_save_request_reasons.append(reason)
	_save_request_successor_counts.append(_count(MARKER_OPERATION_COMPLETE))
	_save_request_quiescent.append(
		SystemScript.is_stable_for_save()
		and _system.operation_arbiter.is_idle()
		and _system.graph_runner.is_snapshot_safe())
	_save_request_snapshots.append(SystemScript.graph_state_to_dict())


func _on_operation_arbiter_changed(active: bool, _queued_count: int) -> void:
	if active:
		_arbiter_active_transitions += 1


func _initial_wait_shape_ready() -> bool:
	if _system == null or _system.graph_runner == null:
		return false
	var counts := _debug_status_counts()
	return (
		_system.graph_runner.active_token_count() == 4
		and int(counts.get("timer", 0)) == 2
		and int(counts.get("event", 0)) == 1
		and int(counts.get("subgraph", 0)) == 1
		and _count(MARKER_FALSE_BRANCH) == 1
		and _count(MARKER_OPERATION_COMPLETE) == 1
	)


func _timer_and_subgraph_finished() -> bool:
	return (
		_count(MARKER_TIMER) == 1
		and _count(MARKER_SUBGRAPH) == 1
		and _count(MARKER_SUBGRAPH_PARENT) == 1
		and _system.graph_runner.active_token_count() == 1
	)


func _all_paths_finished() -> bool:
	return _count(MARKER_EVENT_TRUE) == 1 and _system.graph_runner.active_token_count() == 0


func _debug_status_counts() -> Dictionary:
	var counts := {}
	for row: Dictionary in _system.graph_runner.debug_snapshot():
		var status := String(row.get("status", ""))
		counts[status] = int(counts.get(status, 0)) + 1
	return counts


func _snapshot_status_counts(snapshot: Dictionary) -> Dictionary:
	var counts := {}
	for raw: Variant in snapshot.get("tokens", []):
		if not raw is Dictionary:
			continue
		var status := String((raw as Dictionary).get("status", ""))
		counts[status] = int(counts.get(status, 0)) + 1
	return counts


func _provider_contexts_are_structured() -> bool:
	if _provider_contexts.size() != 7:
		return false
	for context: Dictionary in _provider_contexts:
		if StringName(context.get("graph_id", &"")).is_empty():
			return false
		if StringName(context.get("graph_instance_id", &"")).is_empty():
			return false
		if StringName(context.get("token_id", &"")).is_empty():
			return false
		if StringName(context.get("node_id", &"")).is_empty():
			return false
	return true


func _waiter_precedes_same_event_entry() -> bool:
	var waiter_index := _same_event_order.find(&"waiter_resumed")
	var entry_index := _same_event_order.find(&"event_entry_entered")
	return waiter_index >= 0 and entry_index >= 0 and waiter_index < entry_index


func _snapshot_contains_node(snapshot: Dictionary, node_id: StringName) -> bool:
	for raw_row: Variant in snapshot.get("tokens", []):
		if raw_row is Dictionary and StringName(str(
				(raw_row as Dictionary).get("node_id", ""))) == node_id:
			return true
	return false


func _reset_observations() -> void:
	_provider_counts.clear()
	_provider_contexts.clear()
	_entered_counts.clear()
	_input_changes.clear()
	_same_event_order.clear()
	_cutscene_started_ids.clear()
	_cutscene_finished_rows.clear()
	_load_started_ids.clear()
	_level_entered_rows.clear()
	_save_request_reasons.clear()
	_save_request_snapshots.clear()
	_save_request_quiescent.clear()
	_save_request_successor_counts.clear()
	_arbiter_active_transitions = 0
	_install_world_calls = 0


func _issue_codes(issues: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for issue in issues:
		if issue != null:
			out.append(issue.code)
	return out


func _count(marker: StringName) -> int:
	return int(_provider_counts.get(marker, 0))


func _entered(node_id: StringName) -> int:
	return int(_entered_counts.get(node_id, 0))


func _provider_total() -> int:
	var total := 0
	for count: Variant in _provider_counts.values():
		total += int(count)
	return total


func _wait_until(predicate: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await process_frame
	return bool(predicate.call())


func _cleanup() -> void:
	SystemScript.unregister_action(ACTION_ID, _record_action)
	if _system != null and is_instance_valid(_system):
		_system.graph_runner.cancel_all()
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
		await process_frame
	EventsScript.reset()
	StateScript.reset()


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS: ", label)
		return
	_failures += 1
	push_error("  FAIL: %s" % label)
