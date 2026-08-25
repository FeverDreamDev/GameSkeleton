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

var _queue: Array[Dictionary] = []
var _running: bool = false
var _current_action: String = ""
var _generation: int = 1

## Set by FlowSystem. Graph events and waits share this single event-facing facade.
var graph_runner: FlowGraphRunner

func _ready() -> void:
	# Actions have to keep running while a pause menu is up, or a save requested just before the
	# player paused would never be written.
	process_mode = Node.PROCESS_MODE_ALWAYS

#region Routing

## Every event passes through here. Most do nothing: an event with no entry in the database is
## normal and silent, which is what lets content emit events before the rules for them exist.
func on_event(event_id: StringName, data: Dictionary) -> void:
	if graph_runner != null:
		graph_runner.accept_event(event_id, data)

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
	var generation := _generation

	var processed := 0
	while not _queue.is_empty() and generation == _generation:
		processed += 1
		if processed > MAX_CHAIN:
			push_error("FlowDirector: %d events in one chain; something is emitting itself. Dropping %d queued."
					% [MAX_CHAIN, _queue.size()])
			_queue.clear()
			break
		var item: Dictionary = _queue.pop_front()
		await _run_event(item["event"], item["data"], generation)

	if generation == _generation:
		_current_action = ""
		_running = false

func _run_event(definition: FlowEvent, data: Dictionary, generation: int) -> void:
	FlowEvents.log_line("event: %s" % definition.event_id)
	for action: FlowAction in definition.actions:
		if generation != _generation:
			return
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
			var cutscene_handle := FlowSystem.queue_cutscene(action.target_id, action.data)
			if not cutscene_handle.is_finished():
				await cutscene_handle.completed

		FlowAction.Type.LOAD_LEVEL:
			var level_handle := FlowSystem.queue_level_transition(
				action.target_id, action.spawn_id, action.data)
			if not level_handle.is_finished():
				await level_handle.completed

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
	_generation += 1
	_queue.clear()
	_current_action = ""
	_running = false

#endregion
