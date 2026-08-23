class_name FlowDirector
extends Node

## Turns events into consequences.
##
## It listens to every event, looks the id up in the [FlowDatabase], checks the conditions, and
## runs the event's actions one at a time. Routing is a hash lookup rather than a [code]match[/code]
## chain, so a story with three hundred events costs the same per event as one with three.
##
## Actions run through a queue rather than immediately. That is what makes "a trigger fires while a
## cutscene is playing" ordinary instead of a bug: the second event waits its turn rather than
## starting a second transition on top of the first.
##
## Created and owned by [FlowSystem]; there is no reason to make one yourself.

## Events routed in a single drain before the director assumes it is in a loop. A chain longer than
## this is a story that emits itself, not a story.
const MAX_CHAIN := 256

## Frames to wait for the flow to become free before giving up on an action.
const BUSY_FRAME_BUDGET := 1800

var _queue: Array[Dictionary] = []
var _running: bool = false
var _current_action: String = ""

func _ready() -> void:
	# Actions have to keep running while a pause menu is up, or a save requested just before the
	# player paused would never be written.
	process_mode = Node.PROCESS_MODE_ALWAYS

#region Routing

## Every event passes through here. Most do nothing: an event with no entry in the database is
## normal and silent, which is what lets content emit events before the rules for them exist.
func on_event(event_id: StringName, data: Dictionary) -> void:
	var system := FlowSystem.instance
	if system == null or system.database == null:
		return

	var definition := system.database.get_event(event_id)
	if definition == null:
		return

	if not definition.can_run():
		FlowEvents.log_line("event %s ignored: %s" % [event_id, definition.blocked_reason()])
		return

	# Spent at queue time, not at run time. Two triggers reporting the same event on one frame
	# would otherwise both pass the check and queue the consequence twice.
	if definition.one_shot:
		FlowState.set_flag(definition.one_shot_flag())

	_queue.append({"event": definition, "data": data})
	if not _running:
		_drain()

#endregion

#region The queue

func _drain() -> void:
	if _running:
		return
	_running = true

	var processed := 0
	while not _queue.is_empty():
		processed += 1
		if processed > MAX_CHAIN:
			push_error("FlowDirector: %d events in one chain; something is emitting itself. Dropping %d queued."
					% [MAX_CHAIN, _queue.size()])
			_queue.clear()
			break
		var item: Dictionary = _queue.pop_front()
		await _run_event(item["event"], item["data"])

	_current_action = ""
	_running = false

func _run_event(definition: FlowEvent, data: Dictionary) -> void:
	FlowEvents.log_line("event: %s" % definition.event_id)
	for action: FlowAction in definition.actions:
		if action == null:
			continue
		_current_action = action.describe()
		FlowEvents.log_line("  %s" % _current_action)
		await _run_action(action, data)

func _run_action(action: FlowAction, data: Dictionary) -> void:
	match action.type:
		FlowAction.Type.SET_FLAG:
			FlowState.set_flag(action.target_id, action.flag_value)

		FlowAction.Type.CLEAR_FLAG:
			FlowState.clear_flag(action.target_id)

		FlowAction.Type.SET_VALUE:
			FlowState.set_value(action.target_id, action.resolve_value())

		FlowAction.Type.EMIT_EVENT:
			# Lands back in on_event and joins the queue behind the event that raised it, so a
			# chain runs in the order it was written rather than depth-first.
			FlowEvents.emit(action.target_id, action.data if not action.data.is_empty() else data)

		FlowAction.Type.PLAY_CUTSCENE:
			if await _wait_until_free():
				await FlowSystem.play_cutscene(action.target_id, action.data)

		FlowAction.Type.LOAD_LEVEL:
			if await _wait_until_free():
				await FlowSystem.transition_to_level(action.target_id, action.spawn_id, action.data)

		FlowAction.Type.PRELOAD_LEVEL:
			FlowSystem.preload_level(action.target_id)

		FlowAction.Type.REQUEST_SAVE:
			FlowSystem.request_save(action.target_id)

		FlowAction.Type.SET_INPUT:
			FlowSystem.set_gameplay_input(action.flag_value)

		FlowAction.Type.WAIT:
			if action.number > 0.0:
				var tree := get_tree()
				if tree != null:
					# process_always, so a wait does not stall behind a pause menu forever.
					await tree.create_timer(action.number, true).timeout

		_:
			push_warning("FlowDirector: unhandled action type %d." % action.type)

## Holds until no other major flow action is running.
##
## The queue already serialises everything the director starts, but the game can start a transition
## directly -- New Game and Load both do. Without this an action arriving mid-load would be refused
## and silently lost.
func _wait_until_free() -> bool:
	if not FlowSystem.is_busy():
		return true
	var tree := get_tree()
	if tree == null:
		return false
	for frame in BUSY_FRAME_BUDGET:
		await tree.process_frame
		if not FlowSystem.is_busy():
			return true
	push_error("FlowDirector: gave up waiting for the flow to settle; dropping an action.")
	return false

#endregion

#region Inspection

func queue_size() -> int:
	return _queue.size()

func is_running() -> bool:
	return _running

func current_action_text() -> String:
	return _current_action

## The event ids waiting their turn, for the debug window.
func queued_events() -> Array[StringName]:
	var out: Array[StringName] = []
	for item: Dictionary in _queue:
		var definition: FlowEvent = item["event"]
		out.append(definition.event_id)
	return out

## Drops everything waiting. Called when a run ends.
func clear_queue() -> void:
	_queue.clear()
	_current_action = ""

#endregion
