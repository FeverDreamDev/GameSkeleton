extends SceneTree

## Recovery routing and menu/pause lifecycle coverage for GameApp. Run with:
## godot --path . --rendering-method forward_plus --script res://game/tests/app_recovery_smoke.gd

const TEST_SAVE_DIRECTORY := "res://.godot/app_recovery_smoke_saves"
const TEST_SLOTS: Array[StringName] = [
	&"autosave", &"slot_1", &"slot_2", &"slot_3", &"slot_4", &"slot_5",
]

var _failures: PackedStringArray = []
var _previous_save_directory: String
var _cutscenes_started: Array[StringName] = []
var _levels_entered: Array[StringName] = []
var _save_requests: Array[StringName] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	_previous_save_directory = UISave.directory
	UISave.directory = TEST_SAVE_DIRECTORY
	_clear_test_saves()

	var shell_scene := load("res://game/app/main.tscn") as PackedScene
	_check(shell_scene != null, "main.tscn loads")
	if shell_scene == null:
		_finish()
		return
	var app := shell_scene.instantiate() as GameApp
	_check(app != null, "main.tscn instantiates GameApp")
	if app == null:
		_finish()
		return
	app.rt_start_timeout_seconds = 5.0
	app.terrain_collision_timeout_seconds = 15.0
	root.add_child(app)

	app.flow_system.cutscene_started.connect(
		func(id: StringName) -> void: _cutscenes_started.append(id))
	app.flow_system.level_entered.connect(
		func(id: StringName, _spawn: StringName) -> void: _levels_entered.append(id))
	app.flow_system.save_requested.connect(
		func(reason: StringName) -> void: _save_requests.append(reason))

	_check(await _wait_for(
		func() -> bool: return FlowSystem.get_mode() == FlowSystem.Mode.MENU,
		20.0), "boot reaches MENU")
	_check(not paused, "the main menu does not leave the SceneTree paused")
	_check(UISystem.is_cursor_visible(), "the main menu owns a visible cursor")

	# Establish one current graph-based run. All later menu and pause loads use snapshots written by
	# that graph.
	app.call("_on_new_game_pressed")
	_check(await _wait_for(_stable_gameplay.bind(app), 35.0),
		"New Game reaches stable gameplay through the master graph")
	_check(_cutscenes_started == [&"intro_blank"],
		"the master graph plays intro_blank exactly once")
	_check(_levels_entered == [&"terrain_test"],
		"the master graph enters terrain_test exactly once")
	var gameplay_payload := UISave.load_slot(UISave.autosave_id)
	_check(gameplay_payload.get("flow_graph", {}) is Dictionary
		and not (gameplay_payload.get("flow_graph", {}) as Dictionary).is_empty(),
		"the graph-owned gameplay autosave contains a current graph snapshot")
	_check(bool(gameplay_payload.get("world_active", false)),
		"the gameplay snapshot records that its world must be reconstructed before resume")

	# Pause -> Save keeps the world frozen, then cancel restores gameplay and capture.
	app.call("_open_pause_menu")
	await process_frame
	var pause_menu := app.get("_pause_menu") as PauseMenu
	_check(pause_menu != null, "Escape path creates a PauseMenu")
	_check(paused, "PauseMenu freezes the SceneTree")
	_check(FlowSystem.get_mode() == FlowSystem.Mode.PAUSED,
		"PauseMenu changes flow mode to PAUSED")
	_check(UISystem.is_cursor_visible(), "PauseMenu releases the mouse cursor")
	if pause_menu != null:
		pause_menu.settings_requested.emit()
	await process_frame
	var graphics_dialog := app.get("_graphics_dialog") as GraphicsOptionsDialog
	var upscaling_selector := (
		graphics_dialog.get("_upscaling_selector") as OptionButton
		if graphics_dialog != null else null)
	_check(graphics_dialog != null and upscaling_selector != null,
		"Pause Settings opens Graphics options with the upscaling quality selector")
	# A settings dialog runs while the SceneTree is frozen, so nothing that
	# applies a graphics change may depend on gameplay _process resuming first.
	if upscaling_selector != null:
		upscaling_selector.item_selected.emit(
			upscaling_selector.get_item_index(
				RTSceneManager.UpscalingQuality.PERFORMANCE))
	_check(paused and app.rt_manager != null
		and app.rt_manager.upscaling_quality
			== RTSceneManager.UpscalingQuality.PERFORMANCE,
		"a graphics change applies immediately while gameplay processing is paused")
	var player_view := app.player.get_node_or_null("ViewRoot") as PlayerCamera
	_check(player_view != null and player_view.camera != null
		and is_equal_approx(
			player_view.camera.fov, RTPaniniCamera3D.HORIZONTAL_FOV),
		"the fixed display angle is unaffected by the settings dialog")
	if graphics_dialog != null:
		graphics_dialog.dismiss()
	await process_frame
	_check(paused and app.get("_pause_menu") == pause_menu,
		"closing Graphics options leaves its owning PauseMenu and freeze intact")
	if pause_menu != null:
		pause_menu.save_requested.emit()
	await process_frame
	var save_browser := _find_modal(SaveBrowser) as SaveBrowser
	_check(save_browser != null and save_browser.mode == SaveBrowser.Mode.SAVE,
		"Pause Save opens the save browser in SAVE mode")
	if save_browser != null:
		save_browser.call("_on_row_toggled", true, &"slot_3")
		save_browser.call("_on_action_pressed")
	await process_frame
	await process_frame
	_check(UISave.has_slot(&"slot_3"), "Pause Save writes the chosen slot")
	_check(paused, "saving from pause leaves gameplay frozen")
	_dismiss_modals_except(pause_menu)
	# A player dismisses the "Game Saved" acknowledgement before closing Pause. Let those queued
	# dialogs leave the modal layer first so the resume refresh observes the same lifecycle.
	await process_frame
	await process_frame
	if pause_menu != null and is_instance_valid(pause_menu):
		pause_menu.dismiss()
	_check(await _wait_for(_stable_gameplay.bind(app), 5.0),
		"canceling PauseMenu restores gameplay")
	_check(not paused, "resuming clears SceneTree.paused")
	_check(await _wait_for(
		func() -> bool: return app.player.input_enabled,
		2.0), "resuming restores FPS input ownership after modal teardown")
	# Windows refuses MOUSE_MODE_CAPTURED to a background test window. When the runner has focus we
	# can verify the OS-facing cursor state too; otherwise input ownership proves the same app path.
	if _can_assert_mouse_capture():
		_check(await _wait_for(
			func() -> bool: return not UISystem.is_cursor_visible(),
			2.0), "resuming recaptures the FPS cursor after modal teardown")

	# Save & Quit must never exit when the graph is temporarily not snapshot-safe. Simulate that
	# window with FlowSystem's busy state and drive the actual closing PauseMenu action.
	app.call("_open_pause_menu")
	await process_frame
	pause_menu = app.get("_pause_menu") as PauseMenu
	app.flow_system.call("_set_busy", true)
	if pause_menu != null:
		pause_menu.call("_resolve", true, PauseMenu.ID_SAVE_AND_QUIT, false)
	app.flow_system.call("_set_busy", false)
	await process_frame
	await process_frame
	var restored_pause := app.get("_pause_menu") as PauseMenu
	_check(restored_pause != null and is_instance_valid(restored_pause),
		"failed Save & Quit restores a live PauseMenu instead of quitting")
	_check(paused, "failed Save & Quit keeps gameplay safely paused")
	_dismiss_modals_except(restored_pause)
	await process_frame
	await process_frame
	if restored_pause != null and is_instance_valid(restored_pause):
		restored_pause.dismiss()
	_check(await _wait_for(_stable_gameplay.bind(app), 5.0),
		"canceling the restored PauseMenu returns to gameplay")

	# Pause -> Load dismisses both stacked dialogs without an accidental resume race.
	app.call("_open_pause_menu")
	await process_frame
	pause_menu = app.get("_pause_menu") as PauseMenu
	if pause_menu != null:
		pause_menu.load_requested.emit()
	await process_frame
	var load_browser := _find_modal(SaveBrowser) as SaveBrowser
	_check(load_browser != null and load_browser.mode == SaveBrowser.Mode.LOAD,
		"Pause Load opens the save browser in LOAD mode")
	var cutscene_count_before_pause_load := _cutscenes_started.size()
	if load_browser != null:
		load_browser.call("_on_row_toggled", true, &"slot_3")
		load_browser.call("_on_action_pressed")
	_check(await _wait_for(_stable_gameplay.bind(app), 35.0),
		"Pause Load returns to stable gameplay")
	_check(_cutscenes_started.size() == cutscene_count_before_pause_load,
		"Pause Load resumes the saved graph without restarting the master sequence")
	_check(not paused, "Pause Load thaws the SceneTree")
	_check(app.get("_pause_menu") == null, "Pause Load clears the stale PauseMenu reference")
	_check(app.player.input_enabled, "Pause Load restores FPS input ownership")
	_check(not FlowPresent.has_modal(), "Pause Load removes its stacked dialogs")
	if _can_assert_mouse_capture():
		_check(not UISystem.is_cursor_visible(), "Pause Load restores mouse capture")

	# Return to Main Menu must stop the persistent world without leaving pause state behind.
	app.call("_open_pause_menu")
	await process_frame
	pause_menu = app.get("_pause_menu") as PauseMenu
	if pause_menu != null:
		pause_menu.call("_resolve", true, PauseMenu.ID_MAIN_MENU, false)
	_check(await _wait_for(_stable_menu.bind(app), 10.0),
		"Pause Return to Main Menu reaches a stable menu")
	_check(not paused, "Return to Main Menu clears SceneTree.paused")
	_check(UISystem.is_cursor_visible(), "Return to Main Menu shows the cursor")
	_check(app.flow_system.current_level() == null, "Return to Main Menu frees the streamed level")
	_check(not app.player.visible, "Return to Main Menu hides the persistent player")
	_check(app.rt_manager.get_active_rt_backend() == &"none",
		"Return to Main Menu stops RT")

	# Continue must ignore unreadable files and choose the newest readable slot.
	await create_timer(1.05, true).timeout
	_check(UISave.save_slot(&"slot_4", gameplay_payload) == OK,
		"newest current-graph Continue fixture writes")
	_write_corrupt_slot(&"slot_5")
	_check(UISave.newest_slot() == &"slot_4",
		"UISave chooses the newest readable slot and ignores corrupt rows")
	var cutscenes_before_continue := _cutscenes_started.size()
	app.call("_on_continue_pressed")
	_check(await _wait_for(_stable_gameplay.bind(app), 35.0),
		"Continue restores its selected graph snapshot")
	_check(_cutscenes_started.size() == cutscenes_before_continue,
		"Continue does not restart the master graph")

	# A second New Game resets the static event bus. The graph must request its two checkpoints and
	# one entered-level autosave exactly once each, while the entered event is
	# recorded once rather than once per prior run.
	app.call("_return_to_main_menu")
	_check(await _wait_for(_stable_menu.bind(app), 10.0),
		"Continue run returns to menu before the second New Game")
	var save_count_before_second_run := _save_requests.size()
	app.call("_on_new_game_pressed")
	_check(await _wait_for(_stable_gameplay.bind(app), 35.0),
		"the second New Game reaches stable gameplay")
	_check(_save_requests.size() == save_count_before_second_run + 3,
		"the second New Game routes two checkpoints and one entered-level autosave")
	var entered_history_count := 0
	for item: Dictionary in FlowEvents.history():
		if StringName(item.get("id", "")) == &"entered_terrain_test":
			entered_history_count += 1
	_check(entered_history_count == 1,
		"the reset FlowEvents bus records one entered_terrain_test event")

	# Exercise the application's supported teardown path before freeing the test
	# tree. This also keeps the dummy headless renderer from observing managed
	# instances after their materials have already left the scene tree.
	app.call("_return_to_main_menu")
	_check(await _wait_for(_stable_menu.bind(app), 10.0),
		"the second run tears down cleanly through Return to Main Menu")
	app.queue_free()
	await process_frame
	_finish()


func _stable_gameplay(app: GameApp) -> bool:
	return (
		FlowSystem.get_mode() == FlowSystem.Mode.GAMEPLAY
		and not FlowSystem.is_busy()
		and not bool(app.get("_operation_in_progress"))
		and app.flow_system.current_level() != null
	)


func _stable_menu(app: GameApp) -> bool:
	return (
		FlowSystem.get_mode() == FlowSystem.Mode.MENU
		and not FlowSystem.is_busy()
		and not bool(app.get("_operation_in_progress"))
		and app.flow_system.current_level() == null
	)


func _wait_for(predicate: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await process_frame
	return bool(predicate.call())


func _can_assert_mouse_capture() -> bool:
	# Dummy/headless DisplayServer backends intentionally refuse MOUSE_MODE_CAPTURED. A background
	# desktop window can refuse it too, so OS cursor state is only meaningful in this focused case.
	return DisplayServer.get_name().to_lower() != "headless" and DisplayServer.window_is_focused()


func _find_modal(script_type: Variant) -> Node:
	if UISystem.instance == null or UISystem.instance.modal_root == null:
		return null
	for modal: Node in UISystem.instance.modal_root.get_children():
		if is_instance_of(modal, script_type):
			return modal
	return null


func _dismiss_modals_except(exception: Node) -> void:
	if UISystem.instance == null or UISystem.instance.modal_root == null:
		return
	for modal: Node in UISystem.instance.modal_root.get_children():
		if modal == exception:
			continue
		if modal is UIDialog:
			(modal as UIDialog).dismiss()
		else:
			modal.queue_free()


func _write_corrupt_slot(slot: StringName) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_SAVE_DIRECTORY))
	var file := FileAccess.open(ProjectSettings.globalize_path(UISave.slot_path(slot)), FileAccess.WRITE)
	if file != null:
		file.store_string("{ definitely not a save file")
		file.close()


func _clear_test_saves() -> void:
	for slot: StringName in TEST_SLOTS:
		for suffix in ["", ".tmp", ".bak"]:
			var path := ProjectSettings.globalize_path(UISave.slot_path(slot) + suffix)
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
	var directory_path := ProjectSettings.globalize_path(TEST_SAVE_DIRECTORY)
	if DirAccess.dir_exists_absolute(directory_path):
		DirAccess.remove_absolute(directory_path)


func _finish() -> void:
	_clear_test_saves()
	UISave.directory = _previous_save_directory
	if _failures.is_empty():
		print("app_recovery_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("app_recovery_smoke: %s" % failure)
	quit(1)
