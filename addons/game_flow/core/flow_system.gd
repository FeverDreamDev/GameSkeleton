class_name FlowSystem
extends Node

## The runtime shell of the flow system: what mode the game is in, where the world lives, and the
## orchestration of the two things that change it -- entering a level and playing a cutscene.
##
## Placed in the persistent main scene beside [UISystem], and follows the same convention as it: a
## plain [Node] that claims a [member instance] in [method Node._enter_tree], with a static facade
## in front of it so callers never chase a node path. This project has no autoloads on purpose --
## [code]--check-only --script[/code] does not register autoload names, and every script here is
## meant to parse standalone.
##
## Like [UISystem], every static entry point no-ops with nothing in the tree rather than crashing,
## so a level scene opened on its own still runs.
##
## What this file does not do is decide anything about the story. It provides the verbs; the
## [FlowGraphRunner] executes the authored graph and decides when they are used.

#region Signals

signal mode_changed(old_mode: Mode, new_mode: Mode)
## Raised whenever a transition or cutscene starts or completely settles. UI and input adapters
## use this instead of polling [method is_busy], especially because GAMEPLAY is entered before a
## transition's reveal has finished.
signal busy_changed(busy: bool)

signal load_started(level_id: StringName)
signal load_progress_changed(progress: float)
signal level_entered(level_id: StringName, spawn_id: StringName)
signal load_failed(level_id: StringName)

signal cutscene_started(cutscene_id: StringName)
signal cutscene_finished(cutscene_id: StringName, skipped: bool)

## Raised when the flow wants the game to autosave. The game listens and forwards to its own save
## code -- this addon never touches disk, because [UISave] already owns that job.
signal save_requested(reason: StringName)

## Raised when gameplay input should be taken away or handed back. The player controller listens.
## Deliberately not "disable the player node": a cutscene usually still wants the body simulating
## and animating, just not steering.
signal gameplay_input_changed(enabled: bool)

## Structured token telemetry for the in-game debug window and a future editor debugger bridge.
signal graph_telemetry(event: Dictionary)

#endregion

#region Mode

enum Mode {
	## Before anything has been decided -- boot, shader warmup, first frames.
	BOOT,
	## A menu is up and there is no live run.
	MENU,
	## Normal play.
	GAMEPLAY,
	## A cutscene owns the camera.
	CUTSCENE,
	## A level is being swapped. Nothing may be saved and nothing else may start.
	TRANSITION,
	## The game is frozen behind a menu.
	PAUSED,
}

#endregion

#region Configuration

static var instance: FlowSystem

## Every graph, level, cutscene and custom-action definition. Validated at startup in debug builds.
@export var database: FlowDatabase

@export_group("Containers")
## Where levels are instanced. In this project that is the existing [code]LevelRoot[/code].
@export var world_container_path: NodePath
## Where things that outlive a level live -- the player, most obviously.
@export var persistent_actors_path: NodePath
## Where cutscene scenes are instanced.
@export var cutscene_container_path: NodePath

@export_group("Transitions")
@export var cover_duration: float = 0.4
@export var reveal_duration: float = 0.5

#endregion

#region State

var world_container: Node
var persistent_actors: Node
var cutscene_container: Node

var graph_runner: FlowGraphRunner
var operation_arbiter: FlowOperationArbiter

## Supplied by the game. Given a loaded level scene, put it in the world and place the player:
## [code]func(scene: PackedScene, entry: FlowLevelEntry, spawn_id: StringName, data: Dictionary)
## -> StringName[/code], returning the spawn actually used.
##
## The addon owns the sequence -- cover, load, install, reveal -- and the game owns the one step
## that needs to know about players and save payloads. Duplicating that step in here would mean two
## code paths that can disagree about what a level swap is.
var install_world: Callable

var _mode: Mode = Mode.BOOT
## True from the moment a transition or cutscene starts until it has completely finished. Guards
## against two of them running at once, which is how a world gets freed twice.
var _busy: bool = false
var _input_enabled: bool = true
var _input_manual_enabled: bool = true
var _input_leases: Dictionary = {}
var _pending_save: StringName = &""

var _action_providers: Dictionary = {}

var _current_cutscene: FlowCutscene
var _current_cutscene_id: StringName = &""
var _loading_level: StringName = &""

#endregion

#region Lifecycle

func _enter_tree() -> void:
	# Claimed here rather than in _ready so siblings can already use the facade from their own
	# _ready, which is the same trick UISystem uses.
	if instance == null:
		instance = self

func _exit_tree() -> void:
	if graph_runner != null:
		FlowEvents.unsubscribe_any(graph_runner.accept_event)
		graph_runner.cancel_all()
	if operation_arbiter != null:
		operation_arbiter.cancel_all("system_exit")
	if instance == self:
		instance = null
	# A preload nobody consumed is a threaded request still holding its scene, with nothing left in
	# the tree that could ever fetch it. Leaving one outstanding shows up as a leaked instance at
	# exit -- which is exactly what preloading the next level and then quitting from the menu does.
	FlowLoader.reset()

func _ensure_operation_arbiter() -> void:
	if operation_arbiter != null:
		return
	operation_arbiter = FlowOperationArbiter.new()
	operation_arbiter.name = "FlowOperationArbiter"
	operation_arbiter.configure(
		Callable(self, &"_execute_queued_operation"),
		Callable(self, &"_can_execute_queued_operation")
	)
	operation_arbiter.changed.connect(_on_operation_arbiter_changed)
	operation_arbiter.idle.connect(_flush_pending_save)
	add_child(operation_arbiter)

func _ready() -> void:
	# This node has to keep answering while the tree is frozen, or a flow action could be started
	# by a pause menu and never finish.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_operation_arbiter()

	world_container = get_node_or_null(world_container_path)
	persistent_actors = get_node_or_null(persistent_actors_path)
	cutscene_container = get_node_or_null(cutscene_container_path)

	if world_container == null:
		push_warning("FlowSystem: no world container; level transitions will not work.")

	graph_runner = FlowGraphRunner.new()
	graph_runner.name = "FlowGraphRunner"
	add_child(graph_runner)
	graph_runner.telemetry.connect(_on_graph_telemetry)
	graph_runner.save_stability_changed.connect(_flush_pending_save)
	_connect_graph_runner()

	_report_database_problems()

## The graph runtime is the one wildcard flow listener. [method FlowEvents.reset] deliberately
## clears every subscription, so run reset reconnects it here before gameplay can emit again.
func _connect_graph_runner() -> void:
	if graph_runner != null:
		FlowEvents.subscribe_any(graph_runner.accept_event)

## Says every problem in the database out loud at startup. A level that points at a scene which is
## no longer there is much easier to fix now than as a silent failed transition three rooms later.
func _report_database_problems() -> void:
	if database == null:
		push_warning("FlowSystem: no FlowDatabase assigned; no game-flow graph can run.")
		return
	if not OS.is_debug_build():
		return
	for problem: String in database.validate():
		push_warning("FlowDatabase: %s" % problem)

#endregion

#region Mode

static func get_mode() -> Mode:
	return instance._mode if instance != null else Mode.BOOT

static func set_mode(mode: Mode) -> void:
	if instance != null:
		instance._set_mode(mode)

static func is_gameplay_active() -> bool:
	return instance != null and instance._mode == Mode.GAMEPLAY

## Whether it is safe to serialise right now.
##
## A save taken while the old world is being freed, or while the player is mid-placement, would
## record a half-swapped game, so anything unstable defers instead. See [method request_save].
##
## Paused counts as stable on purpose: the world is whole, it is just frozen, and saving from the
## pause menu is the most ordinary thing a player does. What is refused is a world in pieces.
static func is_stable_for_save() -> bool:
	if instance == null or instance._busy:
		return false
	if instance.operation_arbiter != null and not instance.operation_arbiter.is_idle():
		return false
	if instance.graph_runner != null and not instance.graph_runner.is_snapshot_safe():
		return false
	return instance._mode == Mode.GAMEPLAY or instance._mode == Mode.PAUSED

## Whether a major flow action is in progress.
static func is_busy() -> bool:
	return instance != null and instance._busy

static func mode_name() -> String:
	return Mode.keys()[get_mode()] as String

func _set_mode(mode: Mode) -> void:
	if _mode == mode:
		return
	var previous := _mode
	_mode = mode
	FlowEvents.log_line("mode: %s -> %s" % [Mode.keys()[previous], Mode.keys()[mode]])
	mode_changed.emit(previous, mode)

func _set_busy(value: bool) -> void:
	if _busy == value:
		return
	_busy = value
	busy_changed.emit(value)
	if not value and operation_arbiter != null:
		operation_arbiter.notify_ready()

#endregion

#region Input ownership

## Turns gameplay input on or off. Everything that wants to take control away goes through here, so
## there is one answer to "why can't I move" rather than one per system.
static func set_gameplay_input(enabled: bool) -> void:
	if instance != null:
		instance._set_gameplay_input(enabled)

## Acquires an owner-scoped gameplay-input lock. Re-acquiring the same key is idempotent.
static func acquire_gameplay_input(owner: StringName) -> void:
	if instance != null:
		instance._acquire_gameplay_input(owner)

## Releases one owner-scoped gameplay-input lock.
static func release_gameplay_input(owner: StringName) -> void:
	if instance != null:
		instance._release_gameplay_input(owner)

static func is_gameplay_input_enabled() -> bool:
	return instance == null or instance._input_enabled

func _set_gameplay_input(enabled: bool) -> void:
	if _input_manual_enabled == enabled:
		return
	_input_manual_enabled = enabled
	_refresh_gameplay_input_state()

func _acquire_gameplay_input(owner: StringName) -> void:
	if owner.is_empty() or _input_leases.has(owner):
		return
	_input_leases[owner] = true
	_refresh_gameplay_input_state()

func _release_gameplay_input(owner: StringName) -> void:
	if not _input_leases.has(owner):
		return
	_input_leases.erase(owner)
	_refresh_gameplay_input_state()

func _refresh_gameplay_input_state() -> void:
	var enabled := _input_manual_enabled and _input_leases.is_empty()
	if _input_enabled == enabled:
		return
	_input_enabled = enabled
	gameplay_input_changed.emit(enabled)

#endregion

#region Levels

## Swaps the world for [param level_id], arriving at [param spawn_id]. Await it.
##
## Returns false and leaves the game where it was if the level is unknown, fails to load, or
## another major action is already running. Authored game flow should use a Load Level node; this
## direct verb exists for host integration such as restoring older save formats.
static func transition_to_level(
		level_id: StringName,
		spawn_id: StringName = &"",
		transition_data: Dictionary = {}
) -> bool:
	if instance == null:
		push_error("FlowSystem.transition_to_level(): no FlowSystem in the tree.")
		return false
	return await instance._transition_to_level(level_id, spawn_id, transition_data)

## Starts loading a level in the background without installing it, so the transition that follows
## costs nothing. Safe to call repeatedly.
static func preload_level(level_id: StringName) -> void:
	if instance == null:
		return
	var entry := instance.get_level_entry(level_id)
	if entry == null:
		push_warning("FlowSystem.preload_level(): unknown level_id '%s'." % level_id)
		return
	FlowLoader.preload_scene(entry.scene_path)

## The event id announced when [param level_id] is entered. Derived rather than authored so it
## cannot drift out of sync with the registry.
static func entered_event_for(level_id: StringName) -> StringName:
	return StringName("entered_%s" % level_id)

func get_level_entry(level_id: StringName) -> FlowLevelEntry:
	return database.get_level(level_id) if database != null else null

func get_cutscene_entry(cutscene_id: StringName) -> FlowCutsceneEntry:
	return database.get_cutscene(cutscene_id) if database != null else null

## The level currently installed, or null.
##
## Nodes already queued for deletion are skipped. The game supplies the install step, and a level
## released with [method Node.queue_free] alone stays in the container until the end of the frame --
## long enough to be mistaken for the level that just arrived.
func current_level() -> Node:
	if world_container == null:
		return null
	for child in world_container.get_children():
		if not child.is_queued_for_deletion():
			return child
	return null

func _transition_to_level(
		level_id: StringName,
		spawn_id: StringName,
		transition_data: Dictionary
) -> bool:
	if _busy:
		# The graph runtime queues rather than calling into a busy system; a direct caller is refused
		# outright, because two transitions running at once free the world twice.
		push_warning("FlowSystem: refusing to enter '%s' while another flow action is running." % level_id)
		return false

	var entry := get_level_entry(level_id)
	if entry == null:
		FlowPresent.show_error("Load Failed", "There is no level called '%s' in the flow database." % level_id)
		load_failed.emit(level_id)
		return false
	if not install_world.is_valid():
		push_error("FlowSystem: no install_world handler; the game has not finished wiring up.")
		load_failed.emit(level_id)
		return false

	var previous_input := _input_manual_enabled
	var transition_input_lease := &"__flow_transition"
	_set_busy(true)
	_acquire_gameplay_input(transition_input_lease)
	_loading_level = level_id
	var previous_mode := _mode
	_set_mode(Mode.TRANSITION)
	FlowEvents.log_line("loading: %s" % level_id)
	load_started.emit(level_id)

	await FlowPresent.cover(cover_duration)

	# Told while it is still whole, before anything starts pulling it apart.
	var outgoing := current_level() as FlowLevel
	if outgoing != null:
		outgoing.on_level_exiting()

	var scene := await FlowLoader.load_scene(entry.scene_path, _on_load_progress)
	if scene == null:
		_loading_level = &""
		_set_mode(previous_mode)
		load_failed.emit(level_id)
		FlowPresent.show_error("Load Failed", "Could not load level '%s':\n\n%s" % [level_id, entry.scene_path])
		await FlowPresent.reveal(reveal_duration)
		_set_busy(false)
		_release_gameplay_input(transition_input_lease)
		_set_gameplay_input(previous_input)
		return false

	var used_spawn: Variant = await install_world.call(scene, entry, spawn_id, transition_data)
	var resolved: StringName = used_spawn if used_spawn is StringName else spawn_id

	FlowState.current_level = level_id
	FlowState.current_spawn = resolved
	_loading_level = &""

	var installed := current_level() as FlowLevel
	if installed != null:
		if installed.level_id != level_id:
			push_warning("FlowLevel in %s calls itself '%s' but the registry calls it '%s'."
					% [entry.scene_path, installed.level_id, level_id])
		installed.on_level_entered(resolved, transition_data)

	_set_mode(Mode.GAMEPLAY)
	FlowEvents.log_line("entered: %s at %s" % [level_id, resolved if not resolved.is_empty() else &"default"])
	level_entered.emit(level_id, resolved)

	# Arriving somewhere is itself a story event. A When Event Happens step can react to the derived
	# entered_<level_id> id without adding a bespoke hook to the level scene.
	FlowEvents.emit(entered_event_for(level_id), {"level_id": level_id, "spawn_id": resolved})

	await FlowPresent.reveal(reveal_duration)
	_set_busy(false)
	_release_gameplay_input(transition_input_lease)
	# A successful transition always hands control to the newly installed gameplay world. The
	# previous value only belongs to the scene we left (MENU commonly keeps it false); failures
	# restore it above because the caller is still in that previous mode.
	_set_gameplay_input(true)

	# Warmed only once the player is settled, so the background thread is not competing with the
	# frames that matter most.
	for next_id: StringName in entry.preload_next:
		preload_level(next_id)

	_flush_pending_save()
	return true

func _on_load_progress(value: float) -> void:
	load_progress_changed.emit(value)

#endregion

#region Cutscenes

## Plays [param cutscene_id] and returns when it has finished or been skipped. Await it. Authored
## game flow should use a Play Cutscene node; this direct verb exists for host integration and
## recovery.
static func play_cutscene(cutscene_id: StringName, context: Dictionary = {}) -> bool:
	if instance == null:
		push_error("FlowSystem.play_cutscene(): no FlowSystem in the tree.")
		return false
	return await instance._play_cutscene(cutscene_id, context)

## Asks the running cutscene to cut to its end. Safe to call when nothing is playing.
static func skip_cutscene() -> void:
	if instance == null or instance._current_cutscene == null:
		return
	if not instance.is_current_cutscene_skippable():
		return
	instance._current_cutscene.request_skip()

func is_playing_cutscene() -> bool:
	return _current_cutscene != null and is_instance_valid(_current_cutscene)

func is_current_cutscene_skippable() -> bool:
	var entry := get_cutscene_entry(_current_cutscene_id)
	return entry == null or entry.skippable

func current_cutscene_id() -> StringName:
	return _current_cutscene_id

func _play_cutscene(cutscene_id: StringName, context: Dictionary) -> bool:
	if _busy:
		push_warning("FlowSystem: refusing to play '%s' while another flow action is running." % cutscene_id)
		return false

	var entry := get_cutscene_entry(cutscene_id)
	if entry == null:
		push_error("FlowSystem: there is no cutscene called '%s' in the flow database." % cutscene_id)
		return false
	if cutscene_container == null:
		push_error("FlowSystem: no cutscene container; '%s' cannot play." % cutscene_id)
		return false

	var cutscene_input_lease := &"__flow_cutscene"
	_set_busy(true)
	var previous_mode := _mode
	_set_mode(Mode.CUTSCENE)
	if entry.blocks_input:
		_acquire_gameplay_input(cutscene_input_lease)

	var scene := await FlowLoader.load_scene(entry.scene_path)
	if scene == null:
		_finish_cutscene_state(previous_mode, cutscene_input_lease if entry.blocks_input else &"")
		FlowPresent.show_error("Cutscene Failed", "Could not load cutscene '%s'." % cutscene_id)
		return false

	var node := scene.instantiate()
	var cutscene := node as FlowCutscene
	if cutscene == null:
		push_error("FlowSystem: the root of %s is not a FlowCutscene." % entry.scene_path)
		node.queue_free()
		_finish_cutscene_state(previous_mode, cutscene_input_lease if entry.blocks_input else &"")
		return false

	_current_cutscene = cutscene
	_current_cutscene_id = cutscene_id
	cutscene_container.add_child(cutscene)

	FlowEvents.log_line("cutscene: %s" % cutscene_id)
	cutscene_started.emit(cutscene_id)
	cutscene.begin(context)

	# A cutscene is allowed to finish inside begin(). Awaiting a signal that has already been
	# emitted would wait forever, which is what the resolved flag on FlowCutscene guards against.
	if not cutscene.is_finished():
		await cutscene.finished

	var skipped := cutscene.was_skipped
	# Detached before it is freed, for the same reason a level is: queue_free() defers, and until it
	# lands the container still reports a cutscene that is over.
	cutscene_container.remove_child(cutscene)
	cutscene.queue_free()
	_current_cutscene = null
	_current_cutscene_id = &""

	FlowEvents.log_line("cutscene %s: %s" % [cutscene_id, "skipped" if skipped else "finished"])
	cutscene_finished.emit(cutscene_id, skipped)

	_finish_cutscene_state(previous_mode, cutscene_input_lease if entry.blocks_input else &"")
	_flush_pending_save()
	return true

## Hands control back after a cutscene, however it ended. Returns to GAMEPLAY rather than to
## whatever came before when the cutscene was entered from play, so a cutscene cannot strand the
## game in TRANSITION.
func _finish_cutscene_state(previous_mode: Mode, input_lease: StringName) -> void:
	_set_mode(Mode.GAMEPLAY if previous_mode == Mode.CUTSCENE or previous_mode == Mode.GAMEPLAY else previous_mode)
	_set_busy(false)
	if not input_lease.is_empty():
		_release_gameplay_input(input_lease)

#endregion

#region Queued exclusive operations

## Queues a level transition for graph execution. Unlike the direct API, simultaneous
## requests wait their turn rather than racing FlowSystem's world-swap mutex.
static func queue_level_transition(
		level_id: StringName,
		spawn_id: StringName = &"",
		transition_data: Dictionary = {}
) -> FlowActionHandle:
	if instance == null:
		return _failed_handle("no_flow_system")
	return instance._queue_operation(&"level", {
		"level_id": level_id,
		"spawn_id": spawn_id,
		"data": transition_data,
	})

## Queues a cutscene for graph execution.
static func queue_cutscene(cutscene_id: StringName, context: Dictionary = {}) -> FlowActionHandle:
	if instance == null:
		return _failed_handle("no_flow_system")
	return instance._queue_operation(&"cutscene", {
		"cutscene_id": cutscene_id,
		"context": context,
	})

func _queue_operation(kind: StringName, arguments: Dictionary) -> FlowActionHandle:
	if operation_arbiter == null:
		return _failed_handle("flow_not_ready")
	return operation_arbiter.enqueue(kind, arguments)

func _can_execute_queued_operation() -> bool:
	return not _busy

func _execute_queued_operation(kind: StringName, arguments: Dictionary) -> bool:
	match kind:
		&"level":
			return await _transition_to_level(
				arguments["level_id"], arguments["spawn_id"], arguments["data"])
		&"cutscene":
			return await _play_cutscene(arguments["cutscene_id"], arguments["context"])
		_:
			push_error("FlowSystem: unknown queued operation '%s'." % kind)
	return false

func _on_operation_arbiter_changed(_active: bool, _queued_count: int) -> void:
	_flush_pending_save()

func _cancel_operation_queue() -> void:
	if operation_arbiter != null:
		operation_arbiter.cancel_all("run_reset")

static func _failed_handle(reason: String) -> FlowActionHandle:
	var handle := FlowActionHandle.new()
	handle.resolve(false, {"reason": reason})
	return handle

#endregion

#region Graph runtime and custom actions

static func start_master_graph(graph_id: StringName = &"") -> bool:
	return instance != null and instance.graph_runner != null and instance.graph_runner.start_master(graph_id)

static func has_active_graph() -> bool:
	return instance != null and instance.graph_runner != null and instance.graph_runner.is_active()

static func suspend_graph() -> void:
	if instance != null and instance.graph_runner != null:
		instance.graph_runner.suspend()

static func resume_graph() -> void:
	if instance != null and instance.graph_runner != null:
		instance.graph_runner.resume()

static func graph_state_to_dict() -> Dictionary:
	return instance.graph_runner.to_dict() if instance != null and instance.graph_runner != null else {}

static func restore_graph_state(state: Dictionary, keep_suspended: bool = true) -> bool:
	if instance == null or instance.graph_runner == null:
		return state.is_empty()
	return instance.graph_runner.restore_from_dict(state, keep_suspended)

## Registers a transient game-owned handler. The Callable never enters a graph Resource or save.
## Handlers receive (arguments, context) and return FlowActionHandle, bool, Dictionary or null.
static func register_action(action_id: StringName, handler: Callable) -> void:
	if instance == null or action_id.is_empty() or not handler.is_valid():
		return
	instance._action_providers[action_id] = handler

static func unregister_action(action_id: StringName, handler: Callable = Callable()) -> void:
	if instance == null or not instance._action_providers.has(action_id):
		return
	if handler.is_valid() and instance._action_providers[action_id] != handler:
		return
	instance._action_providers.erase(action_id)

static func invoke_action(
		action_id: StringName,
		arguments: Dictionary,
		context: Dictionary
) -> FlowActionHandle:
	if instance == null or not instance._action_providers.has(action_id):
		return _failed_handle("unknown_action:%s" % action_id)
	var handler: Callable = instance._action_providers[action_id]
	if not handler.is_valid():
		instance._action_providers.erase(action_id)
		return _failed_handle("dead_action_provider:%s" % action_id)
	var result: Variant = handler.call(arguments, context)
	if result is FlowActionHandle:
		return result
	var handle := FlowActionHandle.new()
	if result is bool:
		handle.resolve(result)
	elif result is Dictionary:
		var result_data: Dictionary = result
		handle.resolve(bool(result_data.get("success", true)), result_data)
	elif result == null:
		handle.resolve(true)
	else:
		handle.resolve(true, {"value": result})
	return handle

static func notify_graph_save_stability_changed() -> void:
	if instance != null:
		instance._flush_pending_save()

func _on_graph_telemetry(event: Dictionary) -> void:
	graph_telemetry.emit(event)

#endregion

#region Saving

## Asks the game to save, deferring until the flow is stable.
##
## This addon never writes anything. It raises [signal save_requested] and the game forwards it to
## whatever save system it already has.
static func request_save(reason: StringName) -> void:
	if instance != null:
		instance._request_save(reason)

## Whether a save is waiting for the flow to settle.
static func pending_save() -> StringName:
	return instance._pending_save if instance != null else &""

func _request_save(reason: StringName) -> void:
	if is_stable_for_save():
		FlowEvents.log_line("save requested: %s" % reason)
		_dispatch_save_request(reason)
		return
	# Only the most recent reason is kept. Two autosaves queued behind one transition are one
	# autosave; the player does not want the older of them.
	_pending_save = reason
	FlowEvents.log_line("save deferred (%s): flow is %s" % [reason, Mode.keys()[_mode]])

func _flush_pending_save() -> void:
	if _pending_save.is_empty() or not is_stable_for_save():
		return
	var reason := _pending_save
	_pending_save = &""
	FlowEvents.log_line("save requested: %s (deferred)" % reason)
	_dispatch_save_request(reason)


func _dispatch_save_request(reason: StringName) -> void:
	save_requested.emit(reason)
	# A graph Request Save is a checkpoint barrier. Its ready successor is allowed to execute only
	# after the host's synchronous save listener has returned and observed that continuation.
	if graph_runner != null:
		graph_runner.notify_save_dispatched(reason)

#endregion

#region Run lifecycle

## Wipes everything a finished run left behind.
##
## All of this state is static, so it outlives the scene tree: without this, a second New Game
## inherits the first one's story flags and stacks a second set of event handlers on top.
static func reset_run() -> void:
	if instance != null:
		instance._reset_run()

func _reset_run() -> void:
	if graph_runner != null:
		graph_runner.cancel_all()
	_cancel_operation_queue()
	FlowState.reset()
	FlowLoader.reset()
	FlowEvents.reset()
	# FlowEvents.reset() dropped the graph runtime's subscription along with everything else.
	_connect_graph_runner()

	_pending_save = &""
	_set_busy(false)
	_current_cutscene = null
	_current_cutscene_id = &""
	_loading_level = &""
	_input_leases.clear()
	_input_manual_enabled = true
	_set_gameplay_input(true)
	_refresh_gameplay_input_state()
	_set_mode(Mode.MENU)

#endregion

#region Debug

## A snapshot for the debug window, in display order.
func debug_snapshot() -> Dictionary:
	return {
		"mode": Mode.keys()[_mode],
		"busy": _busy,
		"level": FlowState.current_level,
		"spawn": FlowState.current_spawn,
		"loading": _loading_level,
		"cutscene": _current_cutscene_id,
		"exclusive_active": operation_arbiter != null and operation_arbiter.is_active(),
		"exclusive_queued": operation_arbiter.queued_count() if operation_arbiter != null else 0,
		"pending_save": _pending_save,
		"input": _input_enabled,
		"flags": FlowState.flags(),
		"values": FlowState.values(),
		"graph_active": graph_runner != null and graph_runner.is_active(),
		"graph_suspended": graph_runner != null and graph_runner.is_suspended(),
		"graph_tokens": graph_runner.debug_snapshot() if graph_runner != null else [],
	}

#endregion
