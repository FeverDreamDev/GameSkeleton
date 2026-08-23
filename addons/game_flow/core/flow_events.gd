class_name FlowEvents
extends RefCounted

## The global event bus. Gameplay objects report what happened here and never decide what it means.
##
## Static, like [UISave], and for the same reason: this project has no autoloads, because
## [code]--check-only --script[/code] does not register autoload names and every script here is
## meant to parse standalone. Nothing in this file touches the scene tree.
##
## Listeners are keyed by event id, so an emit wakes only the handlers for that one event instead
## of every listener in the game. [method subscribe_any] exists for the two things that
## legitimately want all of them -- the director and the debug log.
##
## Handlers take [code](event_id: StringName, data: Dictionary)[/code]. That is one fixed
## signature on purpose; a handler that wants neither can drop them with
## [method Callable.unbind], exactly as it would for a signal.

#region Constants

## Shared payload for events that carry nothing. [code]const[/code] dictionaries are read-only in
## GDScript, so a listener cannot reach in and corrupt the instance every other bare emit shares.
const NO_DATA := {}

## How many recent events [method history] keeps. Recorded in debug builds only.
const HISTORY_LIMIT := 64

#endregion

#region State

## Event id -> [code]Array[Callable][/code]. Keyed rather than a single list, so the cost of an
## emit is one hash lookup plus the handlers that actually asked for it.
static var _listeners: Dictionary = {}
static var _any_listeners: Array[Callable] = []
static var _history: Array[Dictionary] = []

#endregion

#region Emitting

## Announces that [param event_id] happened. Never blocks and never fails: an event with no
## listeners is a normal, silent no-op, which is what lets content ship events before anything
## consumes them.
static func emit(event_id: StringName, data: Dictionary = NO_DATA) -> void:
	if event_id.is_empty():
		push_warning("FlowEvents.emit(): refusing an event with no id.")
		return

	if OS.is_debug_build():
		_record(event_id, data)

	var bucket: Variant = _listeners.get(event_id)
	if bucket != null:
		_dispatch(bucket, event_id, data)
	if not _any_listeners.is_empty():
		_dispatch(_any_listeners, event_id, data)

## Iterates a copy, because a handler is allowed to emit, subscribe or unsubscribe while it runs --
## a story event whose consequence is another story event is the normal case, not an edge one.
##
## Callables whose object has been freed are dropped as they are found, so a level that went away
## cannot leave handlers behind for the next one to trip over.
static func _dispatch(listeners: Array, event_id: StringName, data: Dictionary) -> void:
	var stale: Array[Callable] = []
	for callback: Callable in listeners.duplicate():
		if callback.is_valid():
			callback.call(event_id, data)
		else:
			stale.append(callback)
	for callback in stale:
		listeners.erase(callback)

#endregion

#region Subscribing

## Registers [param callback] for one event id. Subscribing twice is a no-op rather than a double
## call, so a node that re-registers after a reload does not fire everything twice.
static func subscribe(event_id: StringName, callback: Callable) -> void:
	if event_id.is_empty() or not callback.is_valid():
		push_warning("FlowEvents.subscribe(): ignoring an empty id or a dead callable.")
		return
	if not _listeners.has(event_id):
		_listeners[event_id] = [] as Array[Callable]
	var bucket: Array[Callable] = _listeners[event_id]
	if not bucket.has(callback):
		bucket.append(callback)

## Registers [param callback] for every event. Meant for the flow director and the debug log; a
## gameplay object wanting one event should use [method subscribe] so it is not woken by traffic
## it does not care about.
static func subscribe_any(callback: Callable) -> void:
	if not callback.is_valid():
		push_warning("FlowEvents.subscribe_any(): ignoring a dead callable.")
		return
	if not _any_listeners.has(callback):
		_any_listeners.append(callback)

static func unsubscribe(event_id: StringName, callback: Callable) -> void:
	var bucket: Variant = _listeners.get(event_id)
	if bucket == null:
		return
	bucket.erase(callback)
	# An id nobody listens to any more should not keep costing a dictionary entry.
	if bucket.is_empty():
		_listeners.erase(event_id)

static func unsubscribe_any(callback: Callable) -> void:
	_any_listeners.erase(callback)

static func is_subscribed(event_id: StringName, callback: Callable) -> bool:
	var bucket: Variant = _listeners.get(event_id)
	return bucket != null and bucket.has(callback)

## How many handlers [param event_id] currently has, wildcard listeners excluded.
static func listener_count(event_id: StringName) -> int:
	var bucket: Variant = _listeners.get(event_id)
	return 0 if bucket == null else bucket.size()

## Ids with at least one handler. For the debug window, and for a test that wants to prove a
## teardown actually tore down.
static func known_events() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in _listeners:
		out.append(id)
	return out

#endregion

#region Lifecycle

## Drops every subscription and the history. Called when a run ends -- static state outlives the
## scene tree, so without this a second New Game would stack a second set of handlers on the first.
static func reset() -> void:
	_listeners.clear()
	_any_listeners.clear()
	_history.clear()

#endregion

#region Debug

static func _record(event_id: StringName, data: Dictionary) -> void:
	_history.append({
		"id": event_id,
		"data": data,
		"msec": Time.get_ticks_msec(),
	})
	if _history.size() > HISTORY_LIMIT:
		_history.remove_at(0)

## The last [constant HISTORY_LIMIT] events, oldest first. Always empty in a release build.
static func history() -> Array[Dictionary]:
	return _history.duplicate()

#endregion

#region Logging

## One high-level line, debug builds only. Deliberately not wired into [method emit]: the point of
## the flow log is the handful of decisions that were taken, not every signal that passed through.
static func log_line(text: String) -> void:
	if OS.is_debug_build():
		print("[FLOW] ", text)

#endregion
