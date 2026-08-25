class_name FlowOperationArbiter
extends Node

## Deterministic, event-driven FIFO for mutually exclusive high-level operations.
##
## The arbiter owns scheduling and cancellation, while its executor Callable owns the operation's
## actual implementation. Readiness is checked through a second Callable and reconsidered only
## when [method notify_ready] is called; there is no process-frame polling.

## Emitted whenever active/queued state changes.
signal changed(active: bool, queued_count: int)
## Emitted once when the arbiter transitions from non-idle to idle.
signal idle()

var _executor: Callable
var _can_execute: Callable
var _queue: Array[Dictionary] = []
var _active_item: Dictionary = {}
var _executor_running: bool = false
var _pump_scheduled: bool = false
var _cancelling: bool = false
var _generation: int = 1
var _was_idle: bool = true
var _state_revision: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## Executor signature: `(kind: StringName, arguments: Dictionary) -> Variant`.
##
## It may be a coroutine and may resolve to bool, Dictionary, FlowActionHandle or null. The optional
## readiness Callable takes no arguments and returns bool.
func configure(executor: Callable, can_execute: Callable = Callable()) -> void:
	_executor = executor
	_can_execute = can_execute
	notify_ready()


func enqueue(kind: StringName, arguments: Dictionary = {}) -> FlowActionHandle:
	var handle := FlowActionHandle.new()
	if kind.is_empty():
		handle.resolve(false, {"reason": "empty_operation_kind"})
		return handle
	if _cancelling:
		handle.cancel("arbiter_cancelling")
		return handle

	_queue.append({
		"kind": kind,
		"arguments": arguments.duplicate(true),
		"handle": handle,
		"generation": _generation,
	})
	_emit_state_changed()
	_schedule_pump()
	return handle


## Reconsiders the front item after an external readiness change.
func notify_ready() -> void:
	_schedule_pump()


## Cancels queued and current public handles and invalidates their eventual executor completion.
##
## An already-running executor cannot be forcibly unwound, so it remains the sole active executor
## until it returns. Its stale result is discarded, and no newer item starts over it.
func cancel_all(reason: String = "run_reset") -> void:
	_generation += 1
	_cancelling = true
	for item: Dictionary in _queue:
		var queued_handle: FlowActionHandle = item["handle"]
		queued_handle.cancel(reason)
	_queue.clear()
	if not _active_item.is_empty():
		var active_handle: FlowActionHandle = _active_item["handle"]
		active_handle.cancel(reason)
	_cancelling = false
	_emit_state_changed()


func is_idle() -> bool:
	return not _executor_running and _queue.is_empty()


func is_active() -> bool:
	return _executor_running


func queued_count() -> int:
	return _queue.size()


func pending_count() -> int:
	return _queue.size() + (1 if _executor_running else 0)


func generation() -> int:
	return _generation


func _schedule_pump() -> void:
	if _pump_scheduled or _executor_running or _queue.is_empty():
		return
	_pump_scheduled = true
	call_deferred(&"_pump")


func _pump() -> void:
	_pump_scheduled = false
	if _executor_running or _queue.is_empty():
		return
	if _can_execute.is_valid() and not bool(_can_execute.call()):
		return

	var item: Dictionary = _queue.pop_front()
	var handle: FlowActionHandle = item["handle"]
	if int(item["generation"]) != _generation or handle.is_finished():
		_emit_state_changed()
		_schedule_pump()
		return
	_active_item = item
	_executor_running = true
	_emit_state_changed()
	# Signal observers are allowed to reset the run. Do not start an executor that was cancelled
	# re-entrantly while its new active state was being announced.
	if int(item["generation"]) != _generation or handle.is_finished():
		_active_item = {}
		_executor_running = false
		_emit_state_changed()
		_schedule_pump()
		return
	_run_active(item)


func _run_active(item: Dictionary) -> void:
	var success := false
	var result_data: Dictionary = {}
	if not _executor.is_valid():
		result_data = {"reason": "missing_operation_executor"}
	else:
		var result: Variant = await _executor.call(item["kind"], item["arguments"])
		if result is FlowActionHandle:
			var nested_handle := result as FlowActionHandle
			if not nested_handle.is_finished():
				await nested_handle.completed
			success = nested_handle.succeeded()
			result_data = nested_handle.result_data()
		elif result is Dictionary:
			var result_dictionary: Dictionary = result
			success = bool(result_dictionary.get("success", true))
			result_data = result_dictionary.duplicate(true)
		elif result is bool:
			success = result
		elif result == null:
			success = true
		else:
			success = true
			result_data = {"value": result}

	var handle: FlowActionHandle = item["handle"]
	var item_generation := int(item["generation"])
	_active_item = {}
	_executor_running = false
	# Resolve only after the executor is no longer active. A completion callback may enqueue more
	# work, but the next pump is deferred and therefore cannot overlap this call stack.
	if item_generation == _generation:
		handle.resolve(success, result_data)
	elif not handle.is_finished():
		handle.cancel("stale_operation")

	_emit_state_changed()
	_schedule_pump()


func _emit_state_changed() -> void:
	_state_revision += 1
	var revision := _state_revision
	var previously_idle := _was_idle
	var now_idle := is_idle()
	_was_idle = now_idle
	changed.emit(_executor_running, _queue.size())
	# A listener may enqueue or cancel synchronously. That nested state transition owns any idle
	# notification; suppress the stale outer notification in that case.
	if revision != _state_revision:
		return
	if now_idle and not previously_idle:
		idle.emit()
