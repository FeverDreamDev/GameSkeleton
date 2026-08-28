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
	_check(not bool(native_profile.get("post_fsr_active", true))
		and native_profile.get("post_panini_source_stage", &"invalid") == &"smaa_resolve",
		"Native remains a true EASU bypass upstream of Panini")
	_check(int(native_profile.get("post_panini_buffer_bytes", 0)) > 0,
		"Panini reports its persistent native-size buffer bytes")
	_check(native_profile.get("post_panini_sample_mode", &"invalid") == &"catmull_rom_or_box",
		"the stack uses the portable Catmull-Rom or box Panini filter")
	# Restore what the scene authored rather than hardcoding off, so the rest of
	# the run keeps presenting the sharpening the application actually ships.
	var authored_cas: bool = _app.rt_manager.post_cas_enabled
	_app.rt_manager.post_cas_enabled = true
	for _frame in 2:
		await get_tree().process_frame
	var cas_profile := _app.rt_manager.get_profile_snapshot()
	_check(cas_profile.get("post_sharpen_mode", &"invalid") == &"cas"
		and bool(cas_profile.get("post_panini_enabled", false)),
		"CAS remains downstream of Native Panini when enabled")
	_app.rt_manager.post_cas_enabled = authored_cas

	for preset: int in [
		RTSceneManager.RTQualityPreset.QUALITY,
		RTSceneManager.RTQualityPreset.BALANCED,
	]:
		_app.call("_on_graphics_quality_selected", preset)
		_check(await _wait_for(
			func() -> bool:
				var profile := _app.rt_manager.get_profile_snapshot()
				return (
					int(profile.get("rt_quality_preset", -1)) == preset
					and bool(profile.get("post_fsr_active", false))
					and bool(profile.get("post_panini_enabled", false))
					and profile.get("post_panini_source_stage", &"invalid") == &"fsr_easu"),
			60), "reduced quality %d keeps EASU before Panini" % preset)

	_app.call("_on_graphics_quality_selected", RTSceneManager.RTQualityPreset.PERFORMANCE)
	_check(await _wait_for(
		func() -> bool:
			var profile := _app.rt_manager.get_profile_snapshot()
			return (
				int(profile.get("rt_quality_preset", -1))
					== RTSceneManager.RTQualityPreset.PERFORMANCE
				and bool(profile.get("post_fsr_active", false))
				and int(profile.get("post_easu_frames", 0)) > 0
				and int(profile.get("post_panini_frames", 0)) > 0),
		120), "Performance renders EASU followed by Panini")

	# SMAA off plus all three quality levels must leave Panini active and in the
	# same perceptual/native domain. Grade and posterization are independently
	# toggled downstream to catch accidental pass fusion or source rebinding.
	_app.call("_on_graphics_anti_aliasing_toggled", false)
	for _frame in 2:
		await get_tree().process_frame
	var smaa_off_profile := _app.rt_manager.get_profile_snapshot()
	_check(not bool(smaa_off_profile.get("post_anti_aliasing_enabled", true))
		and bool(smaa_off_profile.get("post_panini_enabled", false)),
		"SMAA bypass still feeds Panini")
	_app.call("_on_graphics_anti_aliasing_toggled", true)
	for quality: int in [
		RTSceneManager.SMAAQuality.LOW,
		RTSceneManager.SMAAQuality.MEDIUM,
		RTSceneManager.SMAAQuality.HIGH,
	]:
		_app.call("_on_graphics_smaa_quality_selected", quality)
		for _frame in 2:
			await get_tree().process_frame
		var smaa_profile := _app.rt_manager.get_profile_snapshot()
		_check(bool(smaa_profile.get("post_anti_aliasing_enabled", false))
			and int(smaa_profile.get("post_smaa_quality", -1)) == quality
			and bool(smaa_profile.get("post_panini_enabled", false)),
			"SMAA quality %d remains upstream of Panini" % quality)

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
	# The quality transition intentionally creates the EASU target once. Sample a
	# later unchanged frame for the steady-state allocation assertion.
	for _frame in 3:
		await get_tree().process_frame
	var reduced_profile := _app.rt_manager.get_profile_snapshot()
	_check(reduced_profile.get("post_panini_source_stage", &"invalid") == &"fsr_easu",
		"reduced quality feeds native-size EASU into Panini")
	_check(reduced_profile.get("post_sharpen_mode", &"invalid") == &"rcas",
		"RCAS remains downstream of Panini")
	_check(reduced_profile.get("post_panini_viewport_size", Vector2i.ZERO)
		== reduced_profile.get("post_output_size", Vector2i.ONE),
		"Panini and the native UI share the output pixel domain")
	_check(int(reduced_profile.get("post_per_frame_allocation_count", -1)) == 0,
		"steady-state presentation allocates no post resources")

	await _finish(reduced_profile)


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
