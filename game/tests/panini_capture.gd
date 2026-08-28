extends Node

## Acceptance harness for the complete FPS Panini path. It boots the real
## application, enters the terrain level, validates Native and reduced
## presentation contracts, writes a capture, and leaves a native CanvasLayer
## status marker visible above the projected scene.

const APP_SCENE := preload("res://game/app/main.tscn")
const CAPTURE_PATH := "res://.godot/panini_capture.png"

var _app: GameApp
var _failures := PackedStringArray()
var _status_label: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_status_overlay()
	_run.call_deferred()


func _build_status_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 200
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(12.0, 12.0)
	panel.custom_minimum_size = Vector2(310.0, 34.0)
	layer.add_child(panel)
	_status_label = Label.new()
	_status_label.text = "PANINI CHECK: RUNNING"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(_status_label)


func _wait_for(predicate: Callable, frames: int) -> bool:
	for _frame in frames:
		if bool(predicate.call()):
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	# The acceptance run stays inside the project cache so sandboxed CI never
	# depends on the host profile.
	UISave.directory = "res://.godot/panini_capture_saves"
	_app = APP_SCENE.instantiate() as GameApp
	if OS.get_cmdline_user_args().has("--force-raster"):
		# The present path is pipeline-independent, so the acceptance sweep is
		# worth running against the fallback too on a machine that can ray trace.
		# Set on the shell rather than the manager: GameApp reasserts its session
		# choice onto the manager before every world's RT start, so anything set
		# directly on the manager here would be overwritten.
		_app.set("_rt_enabled", false)
	add_child(_app)
	_check(await _wait_for(
		func() -> bool: return FlowSystem.get_mode() == FlowSystem.Mode.MENU,
		3600), "application reaches the main menu")
	if not _failures.is_empty():
		await _finish()
		return

	_app.call("_on_new_game_pressed")
	_check(await _wait_for(
		func() -> bool:
			return (
				FlowSystem.get_mode() == FlowSystem.Mode.GAMEPLAY
				and not FlowSystem.is_busy()),
		7200), "application reaches the terrain gameplay state")
	if not _failures.is_empty():
		await _finish()
		return

	_check(RenderingServer.get_current_rendering_method() == "forward_plus",
		"the run uses the Forward+ renderer")
	var capture_backend := _app.rt_manager.get_active_rt_backend()
	_check(capture_backend == &"hardware" or capture_backend == &"raster",
		"the run brings up a pipeline to capture through")
	print("panini_capture backend: %s" % capture_backend)

	# Exercise every player-facing endpoint in the active renderer, including
	# a fresh full-perimeter containment contract at each angle.
	for fov: float in [120.0, 130.0, 140.0]:
		_app.call("_on_graphics_horizontal_fov_changed", fov)
		_check(await _wait_for(
			func() -> bool:
				var profile := _app.rt_manager.get_profile_snapshot()
				return (
					is_equal_approx(float(profile.get(
						"post_panini_display_horizontal_fov", 0.0)), fov)
					and bool(profile.get("post_panini_bounds_valid", false))
					and int(profile.get("post_panini_invalid_samples", -1)) == 0),
			30), "%d degree FOV is contained in the capture" % roundi(fov))

	var native_profile := _app.rt_manager.get_profile_snapshot()
	_check(bool(native_profile.get("post_panini_enabled", false)),
		"FPS camera activates Panini")
	_check(native_profile.get("post_panini_projection", &"invalid") == &"classic_d1_s0",
		"classic D=1/S=0 projection is active")
	_check(is_equal_approx(float(native_profile.get(
		"post_panini_display_horizontal_fov", 0.0)), 140.0),
		"140 degree horizontal FOV reaches the renderer")
	_check(bool(native_profile.get("post_panini_bounds_valid", false))
		and int(native_profile.get("post_panini_invalid_samples", -1)) == 0,
		"capture overscan contains every Panini perimeter sample")
	_check(native_profile.get("post_panini_source_stage", &"invalid") == &"scene_resolve",
		"Panini reads the scene resolve target")
	_check(int(native_profile.get("post_panini_buffer_bytes", 0)) > 0,
		"Panini reports its persistent native-size buffer bytes")
	_check(native_profile.get("post_panini_sample_mode", &"invalid") == &"catmull_rom_or_tent",
		"the stack uses the Catmull-Rom or tent Panini filter")
	# Grade and posterization are independently toggled downstream to catch
	# accidental pass fusion or source rebinding.
	_app.call("_on_graphics_retro_post_toggled", false)
	for _frame in 2:
		await get_tree().process_frame
	var grade_off_profile := _app.rt_manager.get_profile_snapshot()
	_check(not bool(grade_off_profile.get("post_retro_grade_enabled", true))
		and bool(grade_off_profile.get("post_panini_enabled", false)),
		"retro grade bypass leaves Panini active")
	_app.call("_on_graphics_retro_post_toggled", true)
	_app.rt_manager.post_posterize_enabled = true
	for _frame in 2:
		await get_tree().process_frame
	var posterize_profile := _app.rt_manager.get_profile_snapshot()
	_check(bool(posterize_profile.get("post_retro_grade_enabled", false))
		and bool(posterize_profile.get("post_posterize_enabled", false))
		and bool(posterize_profile.get("post_panini_enabled", false)),
		"grade and posterization remain downstream of Panini")
	_app.rt_manager.post_posterize_enabled = false
	# Sample a later unchanged frame for the steady-state allocation assertion.
	for _frame in 3:
		await get_tree().process_frame
	var steady_profile := _app.rt_manager.get_profile_snapshot()
	_check(steady_profile.get("post_panini_viewport_size", Vector2i.ZERO)
		== steady_profile.get("post_output_size", Vector2i.ONE),
		"Panini and the native UI share the output pixel domain")
	_check(int(steady_profile.get("post_per_frame_allocation_count", -1)) == 0,
		"steady-state presentation allocates no post resources")

	# The 3D capture is sized for the camera's declared FOV ceiling precisely so
	# that a smoothed sprint transition never reallocates it. Sprint here and
	# confirm the count holds while the display angle is actually moving.
	var capture_resizes := int(steady_profile.get("post_capture_resize_count", -1))
	var capture_size: Vector2i = steady_profile.get("post_capture_size", Vector2i.ZERO)
	_check(capture_resizes > 0 and capture_size.x > 0 and capture_size.y > 0,
		"the projection reports a sized 3D capture")
	var source_camera := _app.get_viewport().get_camera_3d()
	_check(source_camera != null and source_camera.has_method(
		&"set_display_horizontal_fov"),
		"the acceptance run can drive the source camera's display FOV")
	if source_camera != null and source_camera.has_method(
			&"set_display_horizontal_fov"):
		var angles := {}
		for step in 40:
			# The same shape PlayerCamera's exponential sprint ease produces: many
			# distinct angles, none of them the value the capture was sized for.
			source_camera.call(
				&"set_display_horizontal_fov", 130.0 + 0.25 * float(step))
			await get_tree().process_frame
			var frame_profile := _app.rt_manager.get_profile_snapshot()
			angles[snappedf(float(frame_profile.get(
				"post_panini_display_horizontal_fov", 0.0)), 0.01)] = true
			_check(bool(frame_profile.get("post_panini_bounds_valid", false)),
				"the capture contains the projection at every eased angle")
		var sprint_profile := _app.rt_manager.get_profile_snapshot()
		_check(angles.size() > 20,
			"the sweep actually moved the display FOV across distinct angles")
		_check(int(sprint_profile.get("post_capture_resize_count", -1))
			== capture_resizes,
			"a moving display FOV never resizes the 3D capture")
		_check(int(sprint_profile.get("post_per_frame_allocation_count", -1)) == 0,
			"a moving display FOV allocates no post resources")

	await _finish(steady_profile)


func _finish(profile: Dictionary = {}) -> void:
	var passed := _failures.is_empty()
	_status_label.text = "PANINI CHECK: %s" % ("PASS" if passed else "FAIL")
	_status_label.modulate = Color("006000") if passed else Color("c02020")
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var capture_bytes := 0
	var capture_error := ERR_CANT_CREATE
	if image != null:
		capture_bytes = image.save_png_to_buffer().size()
		capture_error = image.save_png(CAPTURE_PATH)
	_check(capture_error == OK, "capture encodes at %s" % CAPTURE_PATH)
	passed = _failures.is_empty()
	# The write can fail after the provisional label was drawn. Reassert the
	# authoritative result so the visible overlay and JSON never disagree.
	_status_label.text = "PANINI CHECK: %s" % ("PASS" if passed else "FAIL")
	_status_label.modulate = Color("006000") if passed else Color("c02020")
	await get_tree().process_frame

	var output_size: Vector2i = profile.get("post_output_size", Vector2i.ZERO)
	var report := {
		"event": "PANINI_CAPTURE",
		"ok": passed,
		"renderer": RenderingServer.get_current_rendering_method(),
		"rt_backend": String(_app.rt_manager.get_active_rt_backend()),
		"display_horizontal_fov": float(profile.get(
			"post_panini_display_horizontal_fov", 0.0)),
		"capture_horizontal_fov": float(profile.get(
			"post_panini_capture_horizontal_fov", 0.0)),
		"invalid_samples": int(profile.get("post_panini_invalid_samples", -1)),
		"output_size": [output_size.x, output_size.y],
		"source_stage": String(profile.get("post_panini_source_stage", &"invalid")),
		"capture_path": CAPTURE_PATH,
		"capture_bytes": capture_bytes,
		"failures": Array(_failures),
	}
	print("PANINI_CAPTURE %s" % JSON.stringify(report))
	if not passed:
		for failure in _failures:
			push_error("panini_capture: %s" % failure)
	get_tree().quit(0 if passed else 1)
