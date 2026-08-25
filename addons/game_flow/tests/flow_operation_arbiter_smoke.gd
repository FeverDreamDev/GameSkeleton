extends SceneTree

## Focused scheduling/cancellation test for FlowOperationArbiter.
##
## Run with:
## godot --headless --path . --script res://addons/game_flow/tests/flow_operation_arbiter_smoke.gd

const ActionHandleScript := preload("res://addons/game_flow/core/flow_action_handle.gd")
const ArbiterScript := preload("res://addons/game_flow/core/flow_operation_arbiter.gd")
const DatabaseScript := preload("res://addons/game_flow/data/flow_database.gd")
const SystemScript := preload("res://addons/game_flow/core/flow_system.gd")

var _failures: int = 0
var _host: Node
var _arbiter
var _allow_execution: bool = true
var _call_order: Array[StringName] = []
var _executor_handles: Array = []
var _changed_count: int = 0
var _idle_count: int = 0
var _save_requests: Array[StringName] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_host = Node.new()
	get_root().add_child(_host)
	_arbiter = ArbiterScript.new()
	_host.add_child(_arbiter)
	_arbiter.changed.connect(_on_changed)
	_arbiter.idle.connect(_on_idle)
	_arbiter.configure(_execute_operation, _can_execute)

	await _test_fifo()
	await _test_readiness_notification()
	await _test_generation_cancellation()
	await _test_flow_system_save_flush()

	_host.free()
	if _failures == 0:
		print("Flow operation arbiter smoke: PASS")
		quit()
	else:
		push_error("Flow operation arbiter smoke: %d failure(s)" % _failures)
		quit(1)


func _test_fifo() -> void:
	var first = _arbiter.enqueue(&"first", {"ordinal": 1})
	var second = _arbiter.enqueue(&"second", {"ordinal": 2})
	var third = _arbiter.enqueue(&"third", {"ordinal": 3})
	await _frames(2)

	_check(_call_order == [&"first"], "only the FIFO head starts")
	_check(_arbiter.is_active() and _arbiter.queued_count() == 2,
		"one executor is active while later operations remain queued")
	_check(not first.is_finished() and not second.is_finished() and not third.is_finished(),
		"public handles remain pending until their executors finish")

	(_executor_handles[0] as FlowActionHandle).resolve(true, {"ordinal": 1})
	await _frames(2)
	_check(first.succeeded() and first.result_data().get("ordinal") == 1,
		"executor completion resolves the matching public handle")
	_check(_call_order == [&"first", &"second"], "second operation starts after first completion")

	(_executor_handles[1] as FlowActionHandle).resolve(true)
	await _frames(2)
	_check(second.succeeded() and _call_order == [&"first", &"second", &"third"],
		"third operation starts after second completion")

	(_executor_handles[2] as FlowActionHandle).resolve(false, {"reason": "expected_failure"})
	await _frames(1)
	_check(third.is_finished() and not third.succeeded(),
		"executor failure is forwarded to the public handle")
	_check(_arbiter.is_idle(), "arbiter becomes idle after the FIFO drains")
	_check(_idle_count == 1, "idle is emitted once for the completed busy interval")


func _test_readiness_notification() -> void:
	_allow_execution = false
	var call_count_before := _call_order.size()
	var blocked = _arbiter.enqueue(&"blocked")
	await _frames(2)
	_check(_call_order.size() == call_count_before and _arbiter.queued_count() == 1,
		"a readiness gate leaves the FIFO head queued without polling")

	_arbiter.notify_ready()
	await _frames(2)
	_check(_call_order.size() == call_count_before,
		"a readiness notification does not bypass a closed gate")

	_allow_execution = true
	_arbiter.notify_ready()
	await _frames(2)
	_check(_call_order.back() == &"blocked" and _arbiter.is_active(),
		"an external readiness notification starts the queued operation")
	(_executor_handles.back() as FlowActionHandle).resolve(true)
	await _frames(1)
	_check(blocked.succeeded() and _arbiter.is_idle(),
		"the readiness-gated operation completes normally")


func _test_generation_cancellation() -> void:
	var active = _arbiter.enqueue(&"old_active")
	var queued = _arbiter.enqueue(&"old_queued")
	await _frames(2)
	var stale_executor: FlowActionHandle = _executor_handles.back()
	var previous_generation: int = _arbiter.generation()

	_arbiter.cancel_all("test_reset")
	_check(_arbiter.generation() == previous_generation + 1,
		"cancel_all advances the operation generation")
	_check(active.is_finished() and not active.succeeded()
			and active.result_data().get("reason") == "test_reset",
		"cancel_all cancels the active public handle synchronously")
	_check(queued.is_finished() and not queued.succeeded()
			and queued.result_data().get("reason") == "test_reset",
		"cancel_all cancels queued public handles synchronously")
	_check(not _arbiter.is_idle(),
		"the arbiter remains occupied until the stale physical executor returns")

	var replacement = _arbiter.enqueue(&"replacement")
	await _frames(2)
	_check(_call_order.back() == &"old_active",
		"new-generation work cannot overlap the stale executor")

	stale_executor.resolve(true, {"must_not_escape": true})
	await _frames(2)
	_check(_call_order.back() == &"replacement" and not (&"old_queued" in _call_order),
		"stale completion is discarded and cancelled queued work never executes")
	_check(active.result_data().get("reason") == "test_reset",
		"stale completion cannot overwrite the cancellation result")

	(_executor_handles.back() as FlowActionHandle).resolve(true)
	await _frames(1)
	_check(replacement.succeeded() and _arbiter.is_idle(),
		"new-generation work completes after stale cleanup")
	_check(_idle_count == 3,
		"idle marks each fully settled busy interval, including cancellation cleanup")
	_check(_changed_count > 0, "changed reports scheduling state transitions")


func _test_flow_system_save_flush() -> void:
	var system = SystemScript.new()
	system.database = DatabaseScript.new()
	system.world_container_path = NodePath(".")
	_host.add_child(system)
	await _frames(2)
	SystemScript.set_mode(SystemScript.Mode.GAMEPLAY)
	# Keep this integration check independent of level/cutscene fixtures while still entering through
	# FlowSystem's public queue API and its real save-stability hooks.
	system.operation_arbiter.configure(_execute_operation, _can_execute)
	system.save_requested.connect(_on_save_requested)

	var call_count_before := _call_order.size()
	var queued = SystemScript.queue_cutscene(&"save_flush_probe")
	await _frames(2)
	_check(_call_order.size() == call_count_before + 1
			and _call_order.back() == &"cutscene",
		"FlowSystem's public cutscene queue delegates to the arbiter")
	_check(not SystemScript.is_stable_for_save(),
		"an active queued operation makes FlowSystem unstable for saving")

	SystemScript.request_save(&"after_exclusive_operation")
	_check(SystemScript.pending_save() == &"after_exclusive_operation"
			and _save_requests.is_empty(),
		"a save request is deferred while the arbiter is occupied")

	(_executor_handles.back() as FlowActionHandle).resolve(true)
	await _frames(2)
	_check(queued.succeeded(), "FlowSystem forwards the arbiter's operation result")
	_check(_save_requests == [&"after_exclusive_operation"]
			and SystemScript.pending_save().is_empty(),
		"arbiter settlement flushes FlowSystem's pending save event-driven")

	system.queue_free()
	await _frames(2)


func _execute_operation(kind: StringName, _arguments: Dictionary):
	_call_order.append(kind)
	var handle = ActionHandleScript.new()
	_executor_handles.append(handle)
	return handle


func _can_execute() -> bool:
	return _allow_execution


func _on_changed(_active: bool, _queued_count: int) -> void:
	_changed_count += 1


func _on_idle() -> void:
	_idle_count += 1


func _on_save_requested(reason: StringName) -> void:
	_save_requests.append(reason)


func _frames(count: int) -> void:
	for _index: int in count:
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS: ", label)
		return
	_failures += 1
	push_error("  FAIL: %s" % label)
