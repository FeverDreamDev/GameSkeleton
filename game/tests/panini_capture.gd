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

	# The display angle is fixed, so the containment contract is checked once at
	# that angle rather than swept across a range.
	_check(await _wait_for(
		func() -> bool:
			var profile := _app.rt_manager.get_profile_snapshot()
			return (
				is_equal_approx(float(profile.get(
					"post_panini_display_horizontal_fov", 0.0)),
					RTPaniniCamera3D.HORIZONTAL_FOV)
				and bool(profile.get("post_panini_bounds_valid", false))
				and int(profile.get("post_panini_invalid_samples", -1)) == 0),
		30), "the fixed display angle is contained in the capture")

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
	_check(bool(native_profile.get("post_scene_capture_opaque", false)),
		"the complete scene and sky are opaque before temporal reconstruction")
	_check(native_profile.get("post_environment_composite_stage", &"invalid")
		== &"scene_capture_before_fsr2",
		"sky/environment composition happens before FSR2")
	var output_size: Vector2i = native_profile.get("post_output_size", Vector2i.ZERO)
	var capture_target: Vector2i = native_profile.get(
		"post_capture_target_size", Vector2i.ZERO)
	_check(output_size.x > 0 and output_size.y > 0
		and capture_target.x > 0 and capture_target.y > 0,
		"the output and rectilinear FSR2 target are reported")
	# The target is deliberately larger than an output frame now. What must hold
	# is that it spends exactly its declared multiple and no more, because the
	# render-scale renormalization that keeps this free is derived from it.
	var target_multiplier := (
		float(capture_target.x * capture_target.y)
		/ maxf(float(output_size.x * output_size.y), 1.0))
	_check(absf(target_multiplier
		- RTPostProcessStack.PANINI_TARGET_PIXEL_MULTIPLIER) < 0.01,
		"the rectilinear target spends its declared pixel multiple")
	_check(is_equal_approx(float(native_profile.get(
		"post_panini_target_pixel_multiplier", 0.0)), target_multiplier),
		"the profile reports the achieved target multiplier")
	_check(bool(native_profile.get("post_fsr2_active", false)),
		"Native uses FSR2 as temporal anti-aliasing")

	# The projection's whole reason for the larger target: center magnification.
	# Both axes must beat what a one-output-frame target could reach.
	var center: Vector2 = native_profile.get(
		"post_panini_center_texels_per_pixel", Vector2.ZERO)
	var single_target := RTPostProcessStack.panini_capture_size(
		output_size, RTPaniniCamera3D.HORIZONTAL_FOV, 1.0)
	var single_contract := RTPostProcessStack.debug_panini_capture_contract(
		RTPaniniCamera3D.HORIZONTAL_FOV, output_size, single_target)
	var single_tangent: Vector2 = single_contract.get(
		"capture_tan_half_fov", Vector2.ONE)
	var single_center := Vector2(
		(float(single_contract.get("panini_extent_x", 0.0)) / single_tangent.x)
			* float(single_target.x) / float(output_size.x),
		(float(single_contract.get("panini_extent_y", 0.0)) / single_tangent.y)
			* float(single_target.y) / float(output_size.y))
	_check(center.x > single_center.x * 1.3 and center.y > single_center.y * 1.3,
		"the larger target measurably raises center source density")

	# What the target cannot buy back is answered downstream instead: center is
	# still magnified, and the present pass sharpens that at native resolution.
	_check(center.x < 1.0,
		"center is still magnified, which is what the present sharpener answers")
	_check(is_equal_approx(
		float(native_profile.get("post_present_sharpen_strength", 0.0)),
		RTPostProcessStack.PANINI_PRESENT_SHARPEN_STRENGTH),
		"the present pass sharpens the projected image")

	# The one global setting changes only the 3D/RT buffers. FSR2 target, Panini,
	# presentation, and UI remain fixed while all four standard modes are live.
	var quality_modes := [
		[RTSceneManager.UpscalingQuality.NATIVE, 1.0, &"native"],
		[RTSceneManager.UpscalingQuality.QUALITY, 0.67, &"quality"],
		[RTSceneManager.UpscalingQuality.BALANCED, 0.59, &"balanced"],
		[RTSceneManager.UpscalingQuality.PERFORMANCE, 0.5, &"performance"],
	]
	var quality_capture_resizes := int(native_profile.get(
		"post_capture_resize_count", -1))
	for entry in quality_modes:
		_app.call("_on_graphics_upscaling_quality_selected", int(entry[0]))
		for _frame in 3:
			await get_tree().process_frame
		var quality_profile := _app.rt_manager.get_profile_snapshot()
		var quality_target: Vector2i = quality_profile.get(
			"post_capture_target_size", Vector2i.ZERO)
		var internal: Vector2i = quality_profile.get(
			"post_internal_render_size", Vector2i.ZERO)
		_check(quality_profile.get("post_upscaling_quality_name", &"invalid")
			== entry[2], "%s preset reaches SceneCapture" % String(entry[2]))
		_check(is_equal_approx(float(quality_profile.get(
			"post_upscaling_requested_scale", 0.0)), float(entry[1])),
			"%s requests its canonical scale" % String(entry[2]))
		_check(quality_target == capture_target,
			"%s does not resize the FSR2 output target" % String(entry[2]))
		# The preset's number is authored against the native output frame, so the
		# scale that actually reaches the viewport is smaller by the square root
		# of the target multiplier. That renormalization is the whole reason the
		# larger target costs no frame time, so it is asserted rather than assumed.
		var expected_applied := float(entry[1]) / sqrt(target_multiplier)
		_check(absf(float(quality_profile.get(
			"post_upscaling_effective_scale", 0.0)) - expected_applied) < 0.005,
			"%s applies its target-relative scale" % String(entry[2]))
		_check(abs(internal.x - roundi(float(quality_target.x) * expected_applied)) <= 1
			and abs(internal.y - roundi(float(quality_target.y) * expected_applied)) <= 1,
			"%s scales the complete 3D/RT buffer" % String(entry[2]))
		# The cost the preset name promises: rendered 3D/RT pixels per output
		# pixel must stay at the preset's square regardless of the target size.
		var expected_pixel_ratio := float(entry[1]) * float(entry[1])
		_check(absf(float(quality_profile.get(
			"post_upscaling_output_pixel_ratio", 0.0)) - expected_pixel_ratio)
			< 0.01,
			"%s renders its promised share of a native frame" % String(entry[2]))
		_check(int(quality_profile.get("post_capture_resize_count", -1))
			== quality_capture_resizes,
			"%s changes history/scale without reallocating the Panini target"
				% String(entry[2]))

		# The reported scale has to survive an update() that changes something
		# else. Settings reach the stack through one dictionary, so a fog, grade
		# or environment change re-reads the upscaling block too -- and only the
		# viewport contract knows whether the renderer took FSR2. Re-deriving the
		# effective scale from the request alone would resurrect it here after a
		# fallback, and every reported 3D/RT resolution downstream would describe
		# a buffer that does not exist. Toggle the grade, which owns none of this.
		_app.call("_on_graphics_retro_post_toggled", false)
		await get_tree().process_frame
		_app.call("_on_graphics_retro_post_toggled", true)
		await get_tree().process_frame
		var settled := _app.rt_manager.get_profile_snapshot()
		var fsr2_live := bool(settled.get("post_fsr2_active", false))
		var expected_scale := expected_applied if fsr2_live else 1.0
		_check(absf(float(settled.get(
			"post_upscaling_effective_scale", 0.0)) - expected_scale) < 0.005,
			"%s keeps its effective scale across an unrelated settings update"
				% String(entry[2]))
		var settled_internal: Vector2i = settled.get(
			"post_internal_render_size", Vector2i.ZERO)
		_check(settled_internal == internal,
			"%s reports the same internal 3D/RT size after that update"
				% String(entry[2]))
		if not fsr2_live:
			_check(settled_internal == quality_target,
				"%s renders the full target when FSR2 is not active"
					% String(entry[2]))
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
