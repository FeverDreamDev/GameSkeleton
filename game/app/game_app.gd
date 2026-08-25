class_name GameApp
extends Node

## Persistent integration shell for the test game. Addons keep their reusable contracts; this
## node is the game-specific place that connects boot, menus, saves, cutscenes, streamed terrain,
## the persistent FPS player, and the restartable RT renderer.

const SAVE_SCHEMA_VERSION := 2
const GraphicsOptionsDialogScript := preload("res://game/app/graphics_options_dialog.gd")
const DEFAULT_LEVEL_ID := &"terrain_test"
const DEFAULT_SPAWN_ID := &"default"
const INTRO_CUTSCENE_ID := &"intro_blank"
const SAVEABLE_GROUP := &"saveable"
const PHASE_INTRO_PENDING := &"intro_pending"
const PHASE_LEVEL_PENDING := &"level_pending"
const PHASE_GAMEPLAY := &"gameplay"
const MASTER_BOOTSTRAP_FLAG := &"app_master_bootstrap_complete"
const MASTER_READY_EVENT := &"app_master_flow_ready"
const MASTER_FAILED_EVENT := &"app_master_flow_failed"

@export_group("Systems")
@export_node_path("FlowSystem") var flow_system_path: NodePath = ^"FlowSystem"
@export_node_path("ShaderWarmup") var shader_warmup_path: NodePath = ^"ShaderWarmup"
@export_node_path("RTSceneManager") var rt_manager_path: NodePath = ^"RTSceneManager"
@export_node_path("Player") var player_path: NodePath = ^"PersistentActors/Player"

@export_group("Containers")
@export_node_path("Node") var world_root_path: NodePath = ^"WorldRoot"
@export_node_path("Node") var persistent_actors_path: NodePath = ^"PersistentActors"
@export_node_path("Node") var cutscene_root_path: NodePath = ^"CutsceneRoot"

@export_group("Content")
@export_file("*.tres") var flow_database_path: String = "res://game/app/flow_database.tres"
@export_file("*.tscn") var rt_warmup_fixture_path: String = "res://game/warmup/rt_fixture.tscn"

@export_group("Timeouts")
@export_range(1.0, 60.0, 0.5) var rt_start_timeout_seconds: float = 20.0
@export_range(1.0, 60.0, 0.5) var terrain_collision_timeout_seconds: float = 15.0

var flow_system: FlowSystem
var shader_warmup: ShaderWarmup
var rt_manager: RTSceneManager
var player: Player
var world_root: Node
var persistent_actors: Node
var cutscene_root: Node

var _boot_screen: BootScreen
var _main_menu: MainMenu
var _pause_menu: PauseMenu
var _graphics_dialog

var _operation_in_progress: bool = false
var _boot_complete: bool = false
var _suppress_pause_resume: bool = false
var _last_rt_failure: String = ""
var _master_recovery_requested: bool = false

# Graphics settings are session-scoped by design. Native RT still exercises the shared present
# path; reduced presets opt into FSR through RTSceneManager.
var _rt_quality: int = RTSceneManager.RTQualityPreset.NATIVE
var _smaa_enabled: bool = true
var _smaa_quality: int = RTSceneManager.SMAAQuality.HIGH
var _retro_post_enabled: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_resolve_nodes()
	if not _wire_systems():
		return
	_reset_player_for_new_run()
	_refresh_player_control()
	_boot.call_deferred()


func _resolve_nodes() -> void:
	flow_system = get_node_or_null(flow_system_path) as FlowSystem
	shader_warmup = get_node_or_null(shader_warmup_path) as ShaderWarmup
	rt_manager = get_node_or_null(rt_manager_path) as RTSceneManager
	player = get_node_or_null(player_path) as Player
	world_root = get_node_or_null(world_root_path)
	persistent_actors = get_node_or_null(persistent_actors_path)
	cutscene_root = get_node_or_null(cutscene_root_path)


func _wire_systems() -> bool:
	var missing: PackedStringArray = []
	if flow_system == null:
		missing.append("FlowSystem")
	if player == null:
		missing.append("persistent Player")
	if world_root == null:
		missing.append("WorldRoot")
	if persistent_actors == null:
		missing.append("PersistentActors")
	if cutscene_root == null:
		missing.append("CutsceneRoot")
	if not missing.is_empty():
		push_error("GameApp cannot start; missing: %s." % ", ".join(missing))
		return false

	if flow_system.database == null and ResourceLoader.exists(flow_database_path):
		flow_system.database = ResourceLoader.load(flow_database_path) as FlowDatabase
	if flow_system.database == null:
		push_error("GameApp cannot start without a FlowDatabase at %s." % flow_database_path)
		return false

	# FlowSystem resolves its exported paths in its own _ready. Assigning the concrete references
	# too makes the shell resilient to a scene being reorganized without updating those paths.
	flow_system.world_container = world_root
	flow_system.persistent_actors = persistent_actors
	flow_system.cutscene_container = cutscene_root
	flow_system.install_world = _install_world

	flow_system.mode_changed.connect(_on_flow_mode_changed)
	flow_system.busy_changed.connect(_on_flow_busy_changed)
	flow_system.gameplay_input_changed.connect(_on_gameplay_input_changed)
	flow_system.save_requested.connect(_on_flow_save_requested)
	flow_system.load_progress_changed.connect(_on_level_load_progress)

	if rt_manager != null:
		rt_manager.rt_ready.connect(_on_rt_ready)
		rt_manager.rt_failed.connect(_on_rt_failed)
		rt_manager.rt_quality_changed.connect(_on_rt_quality_changed)
		rt_manager.distance_fog_changed.connect(_on_distance_fog_changed)
		_apply_graphics_preferences()
	return true


#region Boot

func _boot() -> void:
	FlowSystem.set_mode(FlowSystem.Mode.BOOT)
	_boot_screen = BootScreen.new()
	_boot_screen.window_title = "Game Skeleton"
	UISystem.show_screen(_boot_screen, false)
	await get_tree().process_frame

	_boot_screen.set_status("Loading game data")
	_boot_screen.set_detail("Validating game flow")
	_boot_screen.set_progress(0.04)
	for problem: String in flow_system.database.validate():
		push_warning("FlowDatabase: %s" % problem)

	if shader_warmup != null:
		_boot_screen.set_status("Compiling shaders")
		_boot_screen.set_detail("")
		shader_warmup.progress_changed.connect(_on_shader_warmup_progress)
		var report: Dictionary = await shader_warmup.run()
		if shader_warmup.progress_changed.is_connected(_on_shader_warmup_progress):
			shader_warmup.progress_changed.disconnect(_on_shader_warmup_progress)
		_boot_screen.set_detail("%d warmed, %d skipped (%s)" % [
			int(report.get("warmed", 0)),
			int(report.get("skipped", 0)),
			String(report.get("reason", "complete")),
		])
	else:
		_boot_screen.set_status("Shader warmup unavailable")
		_boot_screen.set_progress(0.72)
	await get_tree().process_frame

	await _warm_rt_backend()
	_boot_screen.set_status("Ready")
	_boot_screen.set_detail(_renderer_summary())
	_boot_screen.set_progress(1.0)
	await get_tree().create_timer(0.12, true).timeout

	_boot_complete = true
	FlowSystem.set_mode(FlowSystem.Mode.MENU)
	_show_main_menu()


func _on_shader_warmup_progress(current: int, total: int, label: String) -> void:
	if _boot_screen == null or not is_instance_valid(_boot_screen):
		return
	var ratio := 1.0 if total <= 0 else clampf(float(current) / float(total), 0.0, 1.0)
	_boot_screen.set_progress(0.08 + ratio * 0.64)
	_boot_screen.set_detail(label)


func _warm_rt_backend() -> void:
	if rt_manager == null:
		_boot_screen.set_status("Ray tracing unavailable")
		_boot_screen.set_detail("No RTSceneManager in the app shell")
		_boot_screen.set_progress(0.96)
		return
	if not ResourceLoader.exists(rt_warmup_fixture_path):
		push_warning("GameApp: RT warmup fixture is missing: %s" % rt_warmup_fixture_path)
		_boot_screen.set_status("Ray tracing warmup skipped")
		_boot_screen.set_detail("Warmup fixture missing")
		_boot_screen.set_progress(0.96)
		return

	_boot_screen.set_status("Preparing ray tracing")
	_boot_screen.set_detail("AUTO: hardware first, software fallback")
	_boot_screen.set_progress(0.78)

	var fixture_scene := ResourceLoader.load(rt_warmup_fixture_path) as PackedScene
	var fixture := fixture_scene.instantiate() if fixture_scene != null else null
	if fixture == null:
		push_warning("GameApp: could not instantiate RT warmup fixture.")
		_boot_screen.set_progress(0.96)
		return
	world_root.add_child(fixture)
	await get_tree().process_frame

	var result := await _start_rt_bounded(rt_start_timeout_seconds)
	if bool(result.get("ok", false)):
		_boot_screen.set_detail("%s backend ready" % _rt_backend_display())
	else:
		_boot_screen.set_detail("RT warmup continued without a backend: %s" % String(result.get("reason", "unknown")))
	_boot_screen.set_progress(0.94)

	rt_manager.stop_rt()
	world_root.remove_child(fixture)
	fixture.queue_free()
	await get_tree().process_frame
	_boot_screen.set_progress(0.97)

#endregion


#region Menus and input

func _show_main_menu() -> void:
	FlowSystem.set_mode(FlowSystem.Mode.MENU)
	_main_menu = MainMenu.new()
	_main_menu.game_title = "Game Skeleton"
	_main_menu.subtitle = _renderer_summary()
	_main_menu.credits_bbcode = "[b]Game Skeleton[/b]\n\nProcedural terrain and grass, FPS controls, retro UI, game flow, save/load, shader warmup, Blinn-Phong lighting, and retro ray tracing."
	_main_menu.play_pressed.connect(_on_new_game_pressed)
	_main_menu.continue_pressed.connect(_on_continue_pressed)
	_main_menu.load_pressed.connect(_open_load_browser)
	_main_menu.options_pressed.connect(_open_graphics_options)
	_main_menu.quit_confirmed.connect(_quit_game)
	UISystem.show_screen(_main_menu, true)
	_refresh_player_control()


func _input(event: InputEvent) -> void:
	if not _boot_complete or not event.is_pressed():
		return
	if event is InputEventKey and event.echo:
		return
	if not event.is_action("ui_cancel") or FlowPresent.has_modal():
		return

	match FlowSystem.get_mode():
		FlowSystem.Mode.CUTSCENE:
			if flow_system.is_current_cutscene_skippable():
				FlowSystem.skip_cutscene()
				get_viewport().set_input_as_handled()
		FlowSystem.Mode.GAMEPLAY:
			if not FlowSystem.is_busy():
				_open_pause_menu()
				get_viewport().set_input_as_handled()


func _open_pause_menu() -> void:
	if _pause_menu != null and is_instance_valid(_pause_menu):
		return
	FlowSystem.set_gameplay_input(false)
	FlowSystem.set_mode(FlowSystem.Mode.PAUSED)
	_pause_menu = PauseMenu.new()
	_pause_menu.settings_requested.connect(_open_graphics_options)
	_pause_menu.save_requested.connect(_open_save_browser)
	_pause_menu.load_requested.connect(_open_load_browser)
	_pause_menu.main_menu_requested.connect(_on_return_to_menu_requested)
	_pause_menu.save_and_quit_requested.connect(_on_save_and_quit_requested)
	_pause_menu.resumed.connect(_on_pause_resumed)
	UISystem.show_modal(_pause_menu)
	_refresh_player_control()


func _on_pause_resumed() -> void:
	_pause_menu = null
	if _suppress_pause_resume:
		return
	FlowSystem.set_mode(FlowSystem.Mode.GAMEPLAY)
	FlowSystem.set_gameplay_input(true)
	_refresh_player_after_modal_teardown.call_deferred()


func _refresh_player_after_modal_teardown() -> void:
	# UIDialog emits its result immediately before queue_free(). A plain deferred refresh can still
	# run while that dialog is counted in ModalLayer, decide a modal owns input, and never get a
	# second chance. Cross one frame so the pause popup has actually left the tree first.
	await get_tree().process_frame
	_refresh_player_control()


func _open_graphics_options() -> void:
	if _graphics_dialog != null and is_instance_valid(_graphics_dialog):
		return
	_graphics_dialog = GraphicsOptionsDialogScript.new()
	_graphics_dialog.rendering_method = StringName(RenderingServer.get_current_rendering_method())
	_graphics_dialog.active_backend = rt_manager.get_active_rt_backend() if rt_manager != null else &"none"
	_graphics_dialog.quality_preset = _rt_quality
	_graphics_dialog.anti_aliasing_enabled = _smaa_enabled
	_graphics_dialog.smaa_quality = _smaa_quality
	_graphics_dialog.retro_post_enabled = _retro_post_enabled
	_graphics_dialog.quality_selected.connect(_on_graphics_quality_selected)
	_graphics_dialog.anti_aliasing_toggled.connect(_on_graphics_anti_aliasing_toggled)
	_graphics_dialog.smaa_quality_selected.connect(_on_graphics_smaa_quality_selected)
	_graphics_dialog.retro_post_toggled.connect(_on_graphics_retro_post_toggled)
	_graphics_dialog.finished.connect(_on_graphics_dialog_finished.unbind(1))
	UISystem.show_modal(_graphics_dialog)


func _on_graphics_dialog_finished() -> void:
	_graphics_dialog = null
	_refresh_player_control.call_deferred()


func _open_save_browser() -> void:
	var browser := SaveBrowser.new()
	browser.mode = SaveBrowser.Mode.SAVE
	browser.slot_chosen.connect(_on_manual_save_slot)
	browser.slot_delete_requested.connect(_on_delete_slot)
	UISystem.show_modal(browser)


func _open_load_browser() -> void:
	var browser := SaveBrowser.new()
	browser.mode = SaveBrowser.Mode.LOAD
	browser.slot_chosen.connect(_load_slot)
	browser.slot_delete_requested.connect(_on_delete_slot)
	UISystem.show_modal(browser)


func _on_delete_slot(slot: StringName) -> void:
	var error := UISave.delete_slot(slot)
	if error != OK:
		_show_error("Delete Failed", UISave.last_error())
	if _main_menu != null and is_instance_valid(_main_menu):
		_main_menu.refresh_saves()


func _on_return_to_menu_requested() -> void:
	_pause_menu = null
	_return_to_main_menu()


func _return_to_main_menu() -> void:
	if _operation_in_progress:
		return
	_operation_in_progress = true
	_clear_world()
	FlowSystem.reset_run()
	_reset_player_for_new_run()
	_operation_in_progress = false
	_show_main_menu()


func _quit_game() -> void:
	get_tree().quit()


func _on_save_and_quit_requested() -> void:
	_pause_menu = null
	var error := _write_save(UISave.autosave_id, &"save_and_quit")
	if error != OK:
		var message := "Game Flow is finishing a non-resumable action. Try again in a moment." \
				if error == ERR_BUSY else UISave.last_error()
		_restore_pause_after_failed_save_and_quit.call_deferred(message)
		return
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit()


func _restore_pause_after_failed_save_and_quit(message: String) -> void:
	# The selected PauseMenu button closes its dialog after emitting. Cross that teardown before
	# putting a fresh pause owner behind the error, so a failed write can never silently quit or
	# leave gameplay stuck in PAUSED with no menu.
	await get_tree().process_frame
	if FlowSystem.get_mode() == FlowSystem.Mode.PAUSED:
		_open_pause_menu()
	_show_error("Save & Quit Failed", message)

#endregion


#region New game and load

func _on_new_game_pressed() -> void:
	if _operation_in_progress:
		return
	_operation_in_progress = true
	_master_recovery_requested = false
	_clear_world()
	FlowSystem.reset_run()
	_reset_player_for_new_run()
	FlowState.current_level = DEFAULT_LEVEL_ID
	FlowState.current_spawn = DEFAULT_SPAWN_ID
	_bind_master_flow_events()
	await UISystem.close_screen(true)
	_main_menu = null
	# The master graph now owns checkpoints, the intro, the initial level transition, and the
	# entered-level autosave. GAMEPLAY is used here as a stable pre-world orchestration mode so a
	# graph Request Save can quiesce and write its resumable continuation before the intro starts.
	FlowSystem.set_mode(FlowSystem.Mode.GAMEPLAY)
	if FlowSystem.start_master_graph():
		return
	_show_error("New Game Failed", "The Main Game flow graph could not be started.")
	await _recover_to_main_menu()


func _on_continue_pressed() -> void:
	var slot := UISave.newest_slot()
	if slot.is_empty():
		_show_error("Continue", "There is no readable save to continue.")
		return
	_load_slot(slot)


func _load_slot(slot: StringName) -> void:
	if _operation_in_progress:
		return
	var payload := UISave.load_slot(slot)
	if payload.is_empty():
		_show_error("Load Failed", UISave.last_error())
		return
	var validation_error := _validate_save_payload(payload)
	if not validation_error.is_empty():
		_show_error("Load Failed", validation_error)
		return

	_operation_in_progress = true
	_master_recovery_requested = false
	if _pause_menu != null and is_instance_valid(_pause_menu):
		_suppress_pause_resume = true
		_pause_menu.dismiss()
		_suppress_pause_resume = false
		_pause_menu = null

	await UISystem.close_screen(true)
	_main_menu = null
	# A load can be requested over live gameplay. Stop RT and remove that world before reset_run()
	# changes the mode to MENU and de-currents its camera; otherwise the still-running RT manager
	# observes a level with no active Camera3D during an intro or the next transition's cover.
	_clear_world()
	FlowSystem.reset_run()
	_bind_master_flow_events()
	var saved_flow: Dictionary = payload["flow"]
	# Restored before instancing by contract: a level's _ready may depend on story flags.
	FlowState.from_dict(saved_flow)
	var graph_state: Dictionary = payload.get("flow_graph", {}) if payload.get("flow_graph", {}) is Dictionary else {}
	var restored_graph := not graph_state.is_empty()
	if restored_graph and not FlowSystem.restore_graph_state(graph_state, true):
		_show_error("Load Failed", "The saved Game Flow graph state no longer matches this build.")
		await _recover_to_main_menu()
		return
	var level_id := FlowState.current_level
	var spawn_id := FlowState.current_spawn
	var resume_phase := StringName(str(payload.get("resume_phase", PHASE_GAMEPLAY)))

	# A version-2 graph snapshot is authoritative about pre-world choreography. If it was captured
	# at either save barrier, resume the graph without pre-installing the level; its saved token will
	# continue with the intro or load exactly once. Gameplay snapshots still restore their streamed
	# world through install_world before tokens and event entries are resumed.
	if restored_graph:
		var world_was_active := bool(payload.get(
			"world_active", resume_phase == PHASE_GAMEPLAY))
		if world_was_active:
			if not await FlowSystem.transition_to_level(level_id, spawn_id, payload):
				await _recover_to_main_menu()
				return
			FlowSystem.resume_graph()
			_operation_in_progress = false
			_refresh_player_control()
		else:
			FlowSystem.set_mode(FlowSystem.Mode.GAMEPLAY)
			FlowSystem.resume_graph()
		return

	# Version-1 and transitional graphless saves retain their old recovery contract. Once their
	# intro/level recovery is complete, seed the bootstrap guard before activating the master graph
	# so When Game Starts activates its event listeners without replaying completed content.
	if resume_phase == PHASE_INTRO_PENDING:
		if not await FlowSystem.play_cutscene(INTRO_CUTSCENE_ID, {"loaded_slot": slot}):
			await _recover_to_main_menu()
			return
		var phase_error := _write_save(slot, &"intro_complete", false, PHASE_LEVEL_PENDING)
		if phase_error != OK:
			_show_error("Load Failed", UISave.last_error())
			await _recover_to_main_menu()
			return
		payload["resume_phase"] = String(PHASE_LEVEL_PENDING)

	if not await FlowSystem.transition_to_level(level_id, spawn_id, payload):
		await _recover_to_main_menu()
		return
	FlowState.set_flag(MASTER_BOOTSTRAP_FLAG)
	if not FlowSystem.start_master_graph():
		_show_error("Load Failed", "The Main Game flow graph could not be activated after recovery.")
		await _recover_to_main_menu()
		return
	_operation_in_progress = false
	_refresh_player_control()


func _validate_save_payload(payload: Dictionary) -> String:
	var version := int(payload.get("version", payload.get("schema", 0)))
	if version <= 0:
		return "The save is missing its game schema version."
	if version > SAVE_SCHEMA_VERSION:
		return "The save was written by a newer game schema (%d)." % version
	if not payload.get("flow") is Dictionary:
		return "The save has no valid flow state."
	if payload.has("flow_graph") and not payload.get("flow_graph") is Dictionary:
		return "The save has no valid graph execution state."
	var resume_phase := StringName(str(payload.get("resume_phase", "")))
	if resume_phase not in [PHASE_INTRO_PENDING, PHASE_LEVEL_PENDING, PHASE_GAMEPLAY]:
		return "The save has an unknown resume phase: %s." % resume_phase
	var flow_data: Dictionary = payload["flow"]
	var level_id := StringName(str(flow_data.get(FlowState.KEY_LEVEL, "")))
	if level_id.is_empty():
		return "The save does not name a level."
	if flow_system.get_level_entry(level_id) == null:
		return "The save names an unknown level: %s." % level_id
	return ""


func _recover_to_main_menu() -> void:
	_clear_world()
	FlowSystem.reset_run()
	_reset_player_for_new_run()
	_operation_in_progress = false
	_master_recovery_requested = false
	_show_main_menu()
	await get_tree().process_frame


func _bind_master_flow_events() -> void:
	FlowEvents.subscribe(MASTER_READY_EVENT, _on_master_flow_ready)
	FlowEvents.subscribe(MASTER_FAILED_EVENT, _on_master_flow_failed)


func _on_master_flow_ready(_event_id: StringName, _data: Dictionary) -> void:
	_master_recovery_requested = false
	_operation_in_progress = false
	_refresh_player_control()


func _on_master_flow_failed(_event_id: StringName, data: Dictionary) -> void:
	if _master_recovery_requested:
		return
	_master_recovery_requested = true
	push_error("GameApp: master flow failed during %s." % String(data.get("stage", "unknown")))
	_recover_to_main_menu.call_deferred()

#endregion


#region World installation



## Levels own their fog reach because only they know their streaming radius.
## A level without the hook simply never enables fog.
func _apply_level_distance_fog(level: Node) -> void:
	if rt_manager == null or level == null or not level.has_method("distance_fog_request"):
		return
	var request: Dictionary = level.call("distance_fog_request")
	rt_manager.configure_distance_fog(
		float(request.get("begin", 0.0)),
		float(request.get("end", 0.0)),
		float(request.get("curve", 1.0)),
		bool(request.get("enabled", false)))
	# configure_distance_fog stays silent when nothing changed, but a reinstalled
	# level always brings a fresh grass material at the shader defaults. Push
	# straight to the level so it is seeded either way.
	if level.has_method("apply_distance_fog"):
		level.call("apply_distance_fog", rt_manager.get_distance_fog())


func _on_distance_fog_changed(params: Dictionary) -> void:
	var level := flow_system.current_level() if flow_system != null else null
	if level != null and level.has_method("apply_distance_fog"):
		level.call("apply_distance_fog", params)
func _install_world(
		scene: PackedScene,
		entry: FlowLevelEntry,
		spawn_id: StringName,
		transition_data: Dictionary
) -> StringName:
	if rt_manager != null:
		rt_manager.stop_rt()
	_detach_world_children()
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.set_input_enabled(false)

	var level_node := scene.instantiate()
	var level := level_node as FlowLevel
	if level == null:
		push_error("GameApp: %s does not instantiate a FlowLevel root." % entry.scene_path)
		level_node.queue_free()
		return &""
	world_root.add_child(level)
	# Before RT starts, so the level's first rendered frame already has its fog.
	_apply_level_distance_fog(level)
	player.visible = true
	_set_player_camera_current(true)

	var saved_player: Dictionary = transition_data.get("player", {}) if transition_data.get("player", {}) is Dictionary else {}
	var resolved_spawn := spawn_id if not spawn_id.is_empty() else entry.default_spawn
	if not saved_player.is_empty() and saved_player.get("transform") is Transform3D:
		var saved_transform: Transform3D = saved_player["transform"]
		var collision_ready := true
		if level.has_method("wait_for_placement_position"):
			collision_ready = bool(await level.call(
				"wait_for_placement_position",
				saved_transform.origin,
				terrain_collision_timeout_seconds
			))
		if not collision_ready:
			push_warning("GameApp: terrain collision timed out at the saved player position.")
		_restore_player_state(saved_player)
		if level.has_method("bind_player"):
			level.call("bind_player", player)
	else:
		if level.has_method("place_player_at_spawn"):
			var placed: Variant = await level.call(
				"place_player_at_spawn",
				player,
				resolved_spawn,
				terrain_collision_timeout_seconds
			)
			if placed is StringName and not (placed as StringName).is_empty():
				resolved_spawn = placed
		else:
			resolved_spawn = await _place_player_at_flow_spawn(level, resolved_spawn)
		_apply_spawn_view(level, resolved_spawn)

	_restore_world_state(level, transition_data.get("world", {}))
	_refresh_player_control()

	if rt_manager != null:
		_apply_graphics_preferences()
		var rt_result := await _start_rt_bounded(rt_start_timeout_seconds)
		if not bool(rt_result.get("ok", false)):
			push_warning("GameApp: gameplay RT startup failed: %s" % String(rt_result.get("reason", "unknown")))
	return resolved_spawn


func _place_player_at_flow_spawn(level: FlowLevel, spawn_id: StringName) -> StringName:
	var spawn := level.resolve_spawn(spawn_id)
	if spawn == null:
		player.global_position = Vector3.ZERO
		player.velocity = Vector3.ZERO
		return &""
	player.global_position = spawn.global_position
	player.velocity = Vector3.ZERO
	if spawn.applies_facing:
		player.rotation.y = spawn.spawn_yaw()
	if level.has_method("bind_player"):
		level.call("bind_player", player)
	await get_tree().physics_frame
	return spawn.spawn_id


func _apply_spawn_view(level: FlowLevel, spawn_id: StringName) -> void:
	var view := _player_view()
	if view == null:
		return
	var spawn := level.get_spawn_point(spawn_id)
	if spawn != null and spawn.applies_facing:
		view.apply_view(spawn.look_pitch())
	else:
		view.reset_view()


func _clear_world() -> void:
	if rt_manager != null:
		rt_manager.stop_rt()
	_detach_world_children()
	_refresh_player_control()


func _detach_world_children() -> void:
	if world_root == null:
		return
	for child: Node in world_root.get_children():
		world_root.remove_child(child)
		child.queue_free()

#endregion


#region Saving

func _on_flow_save_requested(reason: StringName) -> void:
	var resume_phase := PHASE_GAMEPLAY
	if reason == &"new_game":
		resume_phase = PHASE_INTRO_PENDING
	elif reason == &"intro_complete":
		resume_phase = PHASE_LEVEL_PENDING
	var error := _write_save(UISave.autosave_id, reason, true, resume_phase)
	if error != OK:
		_show_error("Autosave Failed", UISave.last_error())
		if reason in [&"new_game", &"intro_complete"]:
			FlowEvents.emit(MASTER_FAILED_EVENT, {
				"stage": "checkpoint_save",
				"reason": String(reason),
			})


func _on_manual_save_slot(slot: StringName) -> void:
	var error := _write_save(slot, &"manual")
	if error != OK:
		var message := "Game Flow is finishing a non-resumable action. Try saving again in a moment." \
				if error == ERR_BUSY else UISave.last_error()
		_show_error.call_deferred("Save Failed", message)
	else:
		_show_message.call_deferred("Game Saved", "Saved to %s." % _slot_display_name(slot))


func _write_save(
		slot: StringName,
		reason: StringName,
		include_runtime: bool = true,
		resume_phase: StringName = PHASE_GAMEPLAY
) -> Error:
	if include_runtime and not FlowSystem.is_stable_for_save():
		push_warning("GameApp: refusing to save while Game Flow has non-resumable work in flight.")
		return ERR_BUSY
	var payload := {
		"version": SAVE_SCHEMA_VERSION,
		"resume_phase": String(resume_phase),
		"world_active": flow_system.current_level() != null,
		"flow": FlowState.to_dict(),
		"flow_graph": FlowSystem.graph_state_to_dict(),
		"player": _capture_player_state() if include_runtime else {},
		"world": _capture_world_state() if include_runtime else {},
	}
	var header := {
		UISave.KEY_LABEL: _current_level_label(),
		UISave.KEY_DETAIL: String(reason).replace("_", " ").capitalize(),
	}
	return UISave.save_slot(slot, payload, header)


func _capture_player_state() -> Dictionary:
	if player == null or flow_system.current_level() == null:
		return {}
	var view := _player_view()
	return {
		"transform": player.global_transform,
		"velocity": player.velocity,
		"crouching": player.is_crouching,
		"height": player.current_height,
		"view_pitch": view.target_pitch if view != null else 0.0,
	}


func _restore_player_state(state: Dictionary) -> void:
	var transform_value: Variant = state.get("transform")
	if transform_value is Transform3D:
		player.global_transform = transform_value
	var velocity_value: Variant = state.get("velocity")
	player.velocity = velocity_value if velocity_value is Vector3 else Vector3.ZERO
	var crouching := bool(state.get("crouching", false))
	var height := float(state.get("height", player.crouch_height if crouching else player.standing_height))
	player.apply_stance(crouching, height)
	var view := _player_view()
	if view != null:
		view.apply_view(float(state.get("view_pitch", 0.0)))


func _capture_world_state() -> Dictionary:
	var level := flow_system.current_level()
	if level == null:
		return {}
	var out := {}
	var paths: Array[String] = []
	var by_path := {}
	for node: Node in get_tree().get_nodes_in_group(SAVEABLE_GROUP):
		if node == level or not level.is_ancestor_of(node) or not node.has_method("save_state"):
			continue
		var path := String(level.get_path_to(node))
		paths.append(path)
		by_path[path] = node
	paths.sort()
	for path: String in paths:
		var saved: Variant = (by_path[path] as Node).call("save_state")
		if saved is Dictionary:
			out[path] = saved
	return out


func _restore_world_state(level: Node, raw_state: Variant) -> void:
	if not raw_state is Dictionary:
		return
	var state: Dictionary = raw_state
	for raw_path: Variant in state:
		var path := NodePath(str(raw_path))
		var node := level.get_node_or_null(path)
		if node != null and node.has_method("load_state") and state[raw_path] is Dictionary:
			node.call("load_state", state[raw_path])


func _current_level_label() -> String:
	var entry := flow_system.get_level_entry(FlowState.current_level)
	return entry.label() if entry != null else "New Game"


func _slot_display_name(slot: StringName) -> String:
	if slot == UISave.autosave_id:
		return "Autosave"
	return String(slot).replace("_", " ").capitalize()

#endregion


#region RT and graphics

func _start_rt_bounded(timeout_seconds: float) -> Dictionary:
	if rt_manager == null:
		return {"ok": false, "reason": "no_rt_manager"}
	var state := {"finished": false, "ok": false, "reason": ""}
	var ready_callback := func() -> void:
		state["finished"] = true
		state["ok"] = true
	var failed_callback := func(reason: String) -> void:
		state["finished"] = true
		state["reason"] = reason

	rt_manager.rt_ready.connect(ready_callback)
	rt_manager.rt_failed.connect(failed_callback)
	rt_manager.call_deferred("start_rt")
	var deadline := Time.get_ticks_msec() + int(maxf(timeout_seconds, 0.0) * 1000.0)
	while not bool(state["finished"]) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	if rt_manager.rt_ready.is_connected(ready_callback):
		rt_manager.rt_ready.disconnect(ready_callback)
	if rt_manager.rt_failed.is_connected(failed_callback):
		rt_manager.rt_failed.disconnect(failed_callback)
	if not bool(state["finished"]):
		state["reason"] = "timeout_after_%.1fs" % timeout_seconds
		rt_manager.stop_rt()
	return state


func _apply_graphics_preferences() -> void:
	if rt_manager == null:
		return
	rt_manager.set_rt_quality(_rt_quality)
	rt_manager.post_anti_aliasing_enabled = _smaa_enabled
	rt_manager.post_smaa_quality = _smaa_quality as RTSceneManager.SMAAQuality
	rt_manager.retro_post_enabled = _retro_post_enabled


func _on_graphics_quality_selected(preset: int) -> void:
	_rt_quality = preset
	_apply_graphics_preferences()


func _on_graphics_anti_aliasing_toggled(enabled: bool) -> void:
	_smaa_enabled = enabled
	_apply_graphics_preferences()


func _on_graphics_smaa_quality_selected(quality: int) -> void:
	_smaa_quality = quality
	_apply_graphics_preferences()


func _on_graphics_retro_post_toggled(enabled: bool) -> void:
	_retro_post_enabled = enabled
	_apply_graphics_preferences()


func _on_rt_quality_changed(preset: int, _requested_scale: float) -> void:
	_rt_quality = preset


func _on_rt_ready() -> void:
	_last_rt_failure = ""
	if _graphics_dialog != null and is_instance_valid(_graphics_dialog):
		_graphics_dialog.set_active_backend(rt_manager.get_active_rt_backend())


func _on_rt_failed(reason: String) -> void:
	_last_rt_failure = reason
	if _graphics_dialog != null and is_instance_valid(_graphics_dialog):
		_graphics_dialog.set_active_backend(&"none")


func _rt_backend_display() -> String:
	if rt_manager == null:
		return "No RT"
	var backend := rt_manager.get_active_rt_backend()
	return String(backend).replace("_", " ").capitalize()


func _renderer_summary() -> String:
	var method := String(RenderingServer.get_current_rendering_method()).replace("_", " ").capitalize()
	if rt_manager != null and rt_manager.get_active_rt_backend() != &"none":
		return "%s - %s RT" % [method, _rt_backend_display()]
	return "%s - AUTO RT" % method

#endregion


#region Flow and player presentation

func _on_flow_mode_changed(_old_mode: FlowSystem.Mode, _new_mode: FlowSystem.Mode) -> void:
	_refresh_player_control()


func _on_flow_busy_changed(_busy: bool) -> void:
	_refresh_player_control()


func _on_gameplay_input_changed(_enabled: bool) -> void:
	_refresh_player_control()


func _on_level_load_progress(progress: float) -> void:
	if _boot_screen != null and is_instance_valid(_boot_screen):
		_boot_screen.set_progress(progress)


func _refresh_player_control() -> void:
	if player == null or flow_system == null:
		return
	var mode := FlowSystem.get_mode()
	var has_world := flow_system.current_level() != null
	var can_control := (
		has_world
		and mode == FlowSystem.Mode.GAMEPLAY
		and not FlowSystem.is_busy()
		and FlowSystem.is_gameplay_input_enabled()
		and not get_tree().paused
		and not FlowPresent.has_modal()
	)
	# A newly installed/restored body stays suspended until the transition cover
	# has completely revealed. Cutscenes still simulate the body without input;
	# a pause dialog freezes it through SceneTree.paused.
	var should_simulate := has_world and (
		mode == FlowSystem.Mode.CUTSCENE
		or mode == FlowSystem.Mode.PAUSED
		or (mode == FlowSystem.Mode.GAMEPLAY and not FlowSystem.is_busy())
	)
	player.process_mode = Node.PROCESS_MODE_INHERIT if should_simulate else Node.PROCESS_MODE_DISABLED
	player.visible = has_world
	player.set_input_enabled(can_control)
	_set_reticle_visible(can_control)
	_set_player_camera_current(has_world and mode not in [FlowSystem.Mode.BOOT, FlowSystem.Mode.MENU, FlowSystem.Mode.CUTSCENE])
	UISystem.set_cursor_visible(not can_control)


func _reset_player_for_new_run() -> void:
	if player == null:
		return
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.visible = false
	player.velocity = Vector3.ZERO
	player.global_transform = Transform3D.IDENTITY
	player.apply_stance(false, player.standing_height)
	player.set_input_enabled(false)
	var view := _player_view()
	if view != null:
		view.reset_view()
	_set_reticle_visible(false)
	_set_player_camera_current(false)


func _player_view() -> PlayerCamera:
	return player.get_node_or_null("ViewRoot") as PlayerCamera if player != null else null


func _set_reticle_visible(value: bool) -> void:
	if player == null:
		return
	var reticle_layer := player.get_node_or_null("ReticleUI") as CanvasLayer
	if reticle_layer != null:
		reticle_layer.visible = value


func _set_player_camera_current(value: bool) -> void:
	var view := _player_view()
	if view != null and view.camera != null:
		view.camera.current = value

#endregion


#region Dialog helpers

func _show_error(title: String, message: String) -> void:
	if UISystem.instance == null:
		push_error("%s: %s" % [title, message])
		return
	var dialog := UIDialog.message(title, message if not message.is_empty() else "Something went wrong.", "OK")
	dialog.icon_color = Color("c02020")
	dialog.open_sound = UIAudio.ERROR
	UISystem.show_modal(dialog)


func _show_message(title: String, message: String) -> void:
	if UISystem.instance != null:
		UISystem.show_modal(UIDialog.message(title, message, "OK"))

#endregion
