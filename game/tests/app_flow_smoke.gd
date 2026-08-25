extends SceneTree

## End-to-end smoke coverage for the persistent app shell. Run with:
## godot --path . --rendering-method gl_compatibility --script res://game/tests/app_flow_smoke.gd

const TEST_SAVE_DIRECTORY_PREFIX := "res://.godot/app_flow_smoke_saves"
const MASTER_BOOTSTRAP_FLAG := &"app_master_bootstrap_complete"
const ROUND_TRIP_FLAG := &"app_flow_smoke_round_trip"
const ROUND_TRIP_VALUE := &"app_flow_smoke_value"
const ROUND_TRIP_SLOT := &"slot_2"
const INTRO_PENDING_SLOT := &"slot_3"
const LEVEL_PENDING_SLOT := &"slot_4"

var _failures: PackedStringArray = []
var _previous_save_directory: String
var _test_save_directory: String
var _cutscenes_started: Array[StringName] = []
var _cutscenes_finished: Array[StringName] = []
var _cutscenes_skipped: Array[bool] = []
var _cutscene_start_payloads: Array[Dictionary] = []
var _levels_entered: Array[StringName] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	_previous_save_directory = UISave.directory
	_test_save_directory = "%s_%d_%d" % [
		TEST_SAVE_DIRECTORY_PREFIX,
		OS.get_process_id(),
		Time.get_ticks_usec(),
	]
	UISave.directory = _test_save_directory
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

	app.flow_system.cutscene_started.connect(_on_cutscene_started)
	app.flow_system.cutscene_finished.connect(_on_cutscene_finished)
	app.flow_system.level_entered.connect(
		func(id: StringName, _spawn: StringName) -> void: _levels_entered.append(id))

	_check(await _wait_for(
		func() -> bool: return FlowSystem.get_mode() == FlowSystem.Mode.MENU,
		900), "boot reaches the main menu")
	_check(app.rt_manager.get_active_rt_backend() == &"none",
		"boot warmup stops RT before showing the menu")
	_check(app.flow_system.database.master_graph_id == &"main_game",
		"the application database selects the Main Game master graph")
	var master_graph := app.flow_system.database.get_master_graph()
	_check(master_graph != null
		and master_graph.resource_path == "res://game/flow/master_game_flow.tres",
		"the production master graph is application-owned outside addons")
	_check(app.flow_system.get_node_or_null("FlowGraphRunner") == app.flow_system.graph_runner,
		"FlowGraphRunner is the high-level flow executor")

	app.call("_on_new_game_pressed")
	_check(await _wait_for(
		func() -> bool: return _cutscenes_started.size() == 1,
		900), "New Game reaches the intro cutscene")
	var pre_intro_payload: Dictionary = (
		_cutscene_start_payloads[0] if not _cutscene_start_payloads.is_empty() else {})
	_check(not pre_intro_payload.is_empty(),
		"New Game autosave is readable when cutscene_started fires")
	_check(pre_intro_payload.get("version", 0) == 2, "initial save carries the game version")
	_check(pre_intro_payload.get("resume_phase", "") == "intro_pending",
		"cutscene_started observes the intro_pending recovery phase")
	_check(pre_intro_payload.get("flow", {}) is Dictionary,
		"initial save carries FlowState")
	_check(pre_intro_payload.get("flow_graph", {}) is Dictionary,
		"initial save carries the versioned GameFlow graph section")
	_check(not (pre_intro_payload.get("flow_graph", {}) as Dictionary).is_empty(),
		"initial save captures the active master-graph continuation")
	_check(not bool(pre_intro_payload.get("world_active", true)),
		"the pre-intro checkpoint records that no gameplay world is installed")

	_check(await _wait_for(
		func() -> bool:
			return (
				FlowSystem.get_mode() == FlowSystem.Mode.GAMEPLAY
				and not FlowSystem.is_busy()
				and not bool(app.get("_operation_in_progress"))
			),
		2400), "New Game reaches stable gameplay")
	_check(_cutscenes_started == [&"intro_blank"], "New Game plays intro_blank exactly once")
	_check(_cutscenes_finished == [&"intro_blank"] and _cutscenes_skipped == [false],
		"intro_blank completes normally before gameplay")
	_check(_levels_entered == [&"terrain_test"], "New Game enters terrain_test exactly once")
	var level := app.flow_system.current_level() as TerrainTestLevel
	_check(level != null,
		"terrain_test is installed under WorldRoot")
	_check(app.player.get_parent() == app.persistent_actors,
		"the FPS player remains a persistent actor")
	_check(level != null and level.find_children("*", "Player", true, false).is_empty(),
		"the streamed level does not create a second Player")
	_check(FlowState.has_flag(MASTER_BOOTSTRAP_FLAG),
		"the master graph records that application bootstrap completed")

	var gameplay_payload := UISave.load_slot(UISave.autosave_id)
	_check(gameplay_payload.get("resume_phase", "") == "gameplay",
		"entered_terrain_test overwrites the recovery save as gameplay")
	_check(gameplay_payload.get("player", {}) is Dictionary
		and not (gameplay_payload.get("player", {}) as Dictionary).is_empty(),
		"gameplay autosave captures the persistent player")
	_check(gameplay_payload.get("world", {}) is Dictionary,
		"gameplay autosave carries the world payload")
	_check(bool(gameplay_payload.get("world_active", false)),
		"gameplay autosave records that its streamed world must be restored")
	var gameplay_flow: Dictionary = gameplay_payload.get("flow", {})
	var gameplay_flags: Array = gameplay_flow.get(FlowState.KEY_FLAGS, [])
	_check(String(MASTER_BOOTSTRAP_FLAG) in gameplay_flags,
		"gameplay autosave persists the master bootstrap guard")

	_check(await _wait_for(
		func() -> bool:
			return int(app.rt_manager.get_profile_snapshot().get(
				"receiver_only_instances", 0)) > 0,
		1200), "streamed terrain registers at least one receiver-only RT instance")
	_assert_rt_receiver_contract(app)
	await _assert_quality_lifecycle(app)

	_check(await _wait_for(
		func() -> bool: return app.player.is_on_floor(),
		600), "the persistent player settles grounded on terrain")
	var view := app.player.get_node_or_null("ViewRoot") as PlayerCamera
	var reflector := level.get_node_or_null("TestReflector") as SaveableTransform3D
	_check(view != null, "persistent player exposes PlayerCamera for save/load")
	_check(reflector != null, "terrain_test exposes its authored TestReflector saveable")
	if view == null or reflector == null:
		app.queue_free()
		await process_frame
		_finish()
		return

	FlowState.set_flag(ROUND_TRIP_FLAG)
	FlowState.set_value(ROUND_TRIP_VALUE, {"marker": 73, "label": "round_trip"})
	app.player.velocity = Vector3.ZERO
	app.player.rotation.y = deg_to_rad(31.0)
	app.player.apply_stance(false, app.player.standing_height)
	view.apply_view(deg_to_rad(-17.0))
	var authored_reflector_transform := reflector.transform
	authored_reflector_transform.origin += Vector3(1.25, 0.4, -0.75)
	authored_reflector_transform.basis = Basis(Vector3.UP, deg_to_rad(23.0))
	reflector.transform = authored_reflector_transform
	reflector.visible = false
	await physics_frame

	var saved_player_transform := app.player.global_transform
	var saved_view_pitch := view.target_pitch
	_check(app.player.is_on_floor(), "round-trip save is captured from a grounded player pose")
	var round_trip_error := int(app.call(
		"_write_save", ROUND_TRIP_SLOT, &"app_flow_smoke"))
	_check(round_trip_error == OK, "round-trip save writes successfully")
	var round_trip_payload := UISave.load_slot(ROUND_TRIP_SLOT)
	var round_trip_flow: Dictionary = round_trip_payload.get("flow", {})
	var round_trip_world: Dictionary = round_trip_payload.get("world", {})
	_check(String(ROUND_TRIP_FLAG) in (round_trip_flow.get(FlowState.KEY_FLAGS, []) as Array),
		"round-trip save serializes custom FlowState flags")
	_check((round_trip_flow.get(FlowState.KEY_VALUES, {}) as Dictionary).get(
		String(ROUND_TRIP_VALUE), {}) == {"marker": 73, "label": "round_trip"},
		"round-trip save serializes custom FlowState values")
	_check(round_trip_world.has("TestReflector"),
		"round-trip save uses the reflector's level-relative node path")

	FlowState.clear_flag(ROUND_TRIP_FLAG)
	FlowState.erase_value(ROUND_TRIP_VALUE)
	app.player.global_position += Vector3(3.0, 4.0, -2.0)
	app.player.rotation.y = deg_to_rad(-52.0)
	view.apply_view(deg_to_rad(12.0))
	reflector.transform = Transform3D.IDENTITY
	reflector.visible = true
	app.call("_load_slot", ROUND_TRIP_SLOT)
	_check(await _wait_for(
		func() -> bool: return _stable_gameplay(app),
		2400), "loading the rich save returns to stable gameplay")
	_check(FlowState.has_flag(ROUND_TRIP_FLAG),
		"load restores custom FlowState flags")
	_check(FlowState.get_value(ROUND_TRIP_VALUE, {}) == {
		"marker": 73, "label": "round_trip"},
		"load restores custom FlowState values")
	_check(app.player.global_position.distance_to(saved_player_transform.origin) < 0.08,
		"load restores the grounded persistent-player position")
	_check(absf(wrapf(
		app.player.rotation.y - saved_player_transform.basis.get_euler().y,
		-PI, PI)) < 0.01,
		"load restores the persistent-player yaw")
	view = app.player.get_node_or_null("ViewRoot") as PlayerCamera
	_check(view != null and is_equal_approx(view.target_pitch, saved_view_pitch),
		"load restores the saved first-person view pitch")
	_check(await _wait_for(
		func() -> bool: return app.player.is_on_floor(),
		600), "restored player settles grounded after terrain collision is ready")
	level = app.flow_system.current_level() as TerrainTestLevel
	reflector = level.get_node_or_null("TestReflector") as SaveableTransform3D if level else null
	_check(reflector != null
		and reflector.transform.is_equal_approx(authored_reflector_transform)
		and not reflector.visible,
		"load restores TestReflector scene-relative transform and visibility")
	_check(_cutscenes_started == [&"intro_blank"],
		"a gameplay-phase rich load does not replay the intro")
	_check(_levels_entered == [&"terrain_test", &"terrain_test"],
		"a gameplay-phase rich load reinstalls the saved level once")

	_check(UISave.save_slot(INTRO_PENDING_SLOT, pre_intro_payload) == OK,
		"intro-pending recovery payload writes to an isolated slot")
	app.call("_load_slot", INTRO_PENDING_SLOT)
	_check(await _wait_for(
		func() -> bool: return _cutscenes_started.size() == 2,
		900), "intro_pending load reaches its replayed intro")
	if app.flow_system.is_playing_cutscene():
		FlowSystem.skip_cutscene()
	_check(await _wait_for(
		func() -> bool: return _stable_gameplay(app),
		3000), "intro_pending load replays the intro and reaches gameplay")
	_check(_cutscenes_started == [&"intro_blank", &"intro_blank"]
		and _cutscenes_finished == [&"intro_blank", &"intro_blank"]
		and _cutscenes_skipped == [false, true],
		"intro_pending routing replays and skips exactly one intro")
	_check(_levels_entered.size() == 3,
		"intro_pending routing installs terrain once after its intro")

	# Graph snapshots are authoritative continuations, so changing only their version-1 resume_phase
	# must not redirect them. Exercise level_pending through a genuine version-1 fixture instead.
	var level_pending_payload := {
		"version": 1,
		"resume_phase": "level_pending",
		"flow": (pre_intro_payload.get("flow", {}) as Dictionary).duplicate(true),
		"player": {},
		"world": {},
	}
	_check(UISave.save_slot(LEVEL_PENDING_SLOT, level_pending_payload) == OK,
		"level-pending recovery payload writes to an isolated slot")
	app.call("_load_slot", LEVEL_PENDING_SLOT)
	_check(await _wait_for(
		func() -> bool: return _stable_gameplay(app),
		2400), "level_pending load reaches gameplay")
	_check(_cutscenes_started.size() == 2,
		"level_pending routing does not replay the intro")
	_check(_levels_entered.size() == 4,
		"level_pending routing installs terrain exactly once")

	_write_corrupt_slot(&"slot_1")
	var corrupt_browser := SaveBrowser.new()
	corrupt_browser.mode = SaveBrowser.Mode.LOAD
	corrupt_browser.slot_chosen.connect(
		func(slot: StringName) -> void: app.call("_load_slot", slot))
	UISystem.show_modal(corrupt_browser)
	await process_frame
	corrupt_browser.call("_on_row_toggled", true, &"slot_1")
	var load_button := corrupt_browser.get("_action_button") as Button
	_check(load_button != null and not load_button.disabled,
		"Load remains actionable for an occupied corrupt slot")
	corrupt_browser.call("_on_action_pressed")
	await process_frame
	await process_frame
	var showed_corrupt_error := false
	for modal: Node in UISystem.instance.modal_root.get_children():
		if modal is UIDialog and (modal as UIDialog).dialog_title == "Load Failed":
			showed_corrupt_error = true
	_check(showed_corrupt_error,
		"choosing a corrupt row reaches GameApp and shows its Load Failed dialog")
	for modal: Node in UISystem.instance.modal_root.get_children():
		modal.queue_free()
	await process_frame

	app.call("_return_to_main_menu")
	await process_frame
	_check(FlowSystem.get_mode() == FlowSystem.Mode.MENU,
		"return to menu restores MENU flow mode")
	_check(app.flow_system.current_level() == null and app.world_root.get_child_count() == 0,
		"return to menu detaches and clears the streamed level")
	_check(app.rt_manager.get_active_rt_backend() == &"none"
		and not bool(app.rt_manager.get_profile_snapshot().get("rt_ready", true)),
		"return to menu stops RT and clears its ready state")
	_check(not app.player.visible
		and app.player.process_mode == Node.PROCESS_MODE_DISABLED
		and not app.player.input_enabled,
		"return to menu hides and disables the persistent player")
	var returned_view := app.player.get_node_or_null("ViewRoot") as PlayerCamera
	_check(returned_view != null and returned_view.camera != null
		and not returned_view.camera.current,
		"return to menu releases the gameplay camera")
	_check(UISystem.is_cursor_visible(), "return to menu restores the visible UI cursor")
	_check(UISystem.get_current_screen() is MainMenu,
		"return to menu presents the main menu screen")
	_check(FlowState.current_level.is_empty()
		and FlowState.current_spawn.is_empty()
		and FlowState.flags().is_empty(),
		"return to menu resets saved-run FlowState")

	app.queue_free()
	await process_frame
	_finish()


func _wait_for(predicate: Callable, frame_budget: int) -> bool:
	for _frame in frame_budget:
		if bool(predicate.call()):
			return true
		await process_frame
	return bool(predicate.call())


func _stable_gameplay(app: GameApp) -> bool:
	return (
		FlowSystem.get_mode() == FlowSystem.Mode.GAMEPLAY
		and not FlowSystem.is_busy()
		and not bool(app.get("_operation_in_progress"))
	)


func _on_cutscene_started(id: StringName) -> void:
	_cutscenes_started.append(id)
	_cutscene_start_payloads.append(UISave.load_slot(UISave.autosave_id))


func _on_cutscene_finished(id: StringName, skipped: bool) -> void:
	_cutscenes_finished.append(id)
	_cutscenes_skipped.append(skipped)


func _assert_rt_receiver_contract(app: GameApp) -> void:
	var profile := app.rt_manager.get_profile_snapshot()
	_check(bool(profile.get("rt_ready", false)),
		"gameplay RT reports ready")
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		_check(profile.get("active_backend", &"none") == &"software",
			"Compatibility gameplay selects the software RT backend")
	var receiver_count := int(profile.get("receiver_only_instances", 0))
	_check(receiver_count > 0, "RT profile counts streamed receiver-only terrain")
	_check(int(profile.get("excluded_instances", 0)) >= receiver_count,
		"RT profile excludes all receiver-only instances from traversal masks")

	var instances: Array = app.rt_manager.get("_instances")
	var masks: PackedInt32Array = app.rt_manager.get("_snapshot_instance_masks")
	var live_receivers := 0
	var receiver_masks_are_zero := true
	for index in mini(instances.size(), masks.size()):
		var item: Dictionary = instances[index]
		if (
				bool(item.get("receiver_only", false))
				and not bool(item.get("receiver_tombstone", false))
		):
			live_receivers += 1
			receiver_masks_are_zero = receiver_masks_are_zero and masks[index] == 0
	_check(live_receivers == receiver_count,
		"receiver-only RT profile count matches live receiver records")
	_check(receiver_masks_are_zero,
		"every live receiver-only terrain record has traversal mask zero")


func _assert_quality_lifecycle(app: GameApp) -> void:
	var native_profile := app.rt_manager.get_profile_snapshot()
	_check(app.rt_manager.get_rt_quality_scale() == 1.0
		and not bool(native_profile.get("post_fsr_active", true))
		and native_profile.get("post_upscale_method", &"invalid") == &"none",
		"Native quality is a true FSR bypass")
	_check(native_profile.get("post_easu_viewport_size", Vector2i.ONE) == Vector2i.ZERO,
		"Native quality owns no EASU target")

	app.call("_on_graphics_quality_selected", RTSceneManager.RTQualityPreset.QUALITY)
	await process_frame
	await process_frame
	var quality_profile := app.rt_manager.get_profile_snapshot()
	_check(is_equal_approx(app.rt_manager.get_rt_quality_scale(), 0.85),
		"Quality preset requests the approved 0.85 RT scale")
	_check(bool(quality_profile.get("post_fsr_active", false))
		and quality_profile.get("post_upscale_method", &"none") == &"fsr1_easu_rcas",
		"Quality preset activates the FSR 1 EASU/RCAS path")
	_check(quality_profile.get("post_easu_viewport_size", Vector2i.ZERO) != Vector2i.ZERO,
		"Quality preset allocates an EASU target")

	app.call("_on_graphics_quality_selected", RTSceneManager.RTQualityPreset.NATIVE)
	await process_frame
	await process_frame
	var restored_profile := app.rt_manager.get_profile_snapshot()
	_check(not bool(restored_profile.get("post_fsr_active", true))
		and restored_profile.get("post_upscale_method", &"invalid") == &"none",
		"switching back to Native bypasses FSR again")
	_check(restored_profile.get("post_easu_viewport_size", Vector2i.ONE) == Vector2i.ZERO,
		"switching back to Native releases the EASU target")


func _clear_test_saves() -> void:
	if _test_save_directory.is_empty():
		return
	for slot: StringName in UISave.slot_ids():
		for suffix in ["", ".tmp", ".bak"]:
			var path := ProjectSettings.globalize_path(UISave.slot_path(slot) + suffix)
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
	var directory_path := ProjectSettings.globalize_path(_test_save_directory)
	if DirAccess.dir_exists_absolute(directory_path):
		DirAccess.remove_absolute(directory_path)


func _write_corrupt_slot(slot: StringName) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_test_save_directory))
	var file := FileAccess.open(ProjectSettings.globalize_path(UISave.slot_path(slot)), FileAccess.WRITE)
	if file != null:
		file.store_string("{ definitely not a save file")
		file.close()


func _finish() -> void:
	_clear_test_saves()
	UISave.directory = _previous_save_directory
	if _failures.is_empty():
		print("app_flow_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("app_flow_smoke: %s" % failure)
	quit(1)
