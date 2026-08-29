extends SceneTree

## Headless CPU-side contract smoke for the shared Panini pass.
##
## godot --headless --path . --rendering-method forward_plus \
##   --script res://addons/retro_rt/tests/panini_projection_smoke.gd

const PaniniShader := preload(
	"res://addons/retro_rt/post_processing/shaders/panini_project.gdshader")

var _failures: PackedStringArray = []


func _initialize() -> void:
	_test_manager_default()
	_test_upscaling_presets()
	_test_temporal_upscaling_availability()
	_test_viewport_contract_declares_fsr_sharpness()
	_test_capture_contract_matrix()
	_test_analytic_bounds_match_full_scan()
	_test_capture_sizing()
	_test_invalid_contracts()
	_test_shader_contract()
	if _failures.is_empty():
		print("panini_projection_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("panini_projection_smoke: %s" % failure)
	quit(1)


func _test_manager_default() -> void:
	var manager := RTSceneManager.new()
	_check(not manager.post_panini_enabled,
		"the reusable RT manager defaults Panini off")
	_check(manager.upscaling_quality == RTSceneManager.UpscalingQuality.NATIVE,
		"the reusable RT manager defaults temporal reconstruction to Native")
	manager.free()


func _test_upscaling_presets() -> void:
	var manager := RTSceneManager.new()
	var presets := [
		[RTSceneManager.UpscalingQuality.NATIVE, 1.0, &"native"],
		[RTSceneManager.UpscalingQuality.QUALITY, 0.67, &"quality"],
		[RTSceneManager.UpscalingQuality.BALANCED, 0.59, &"balanced"],
		[RTSceneManager.UpscalingQuality.PERFORMANCE, 0.5, &"performance"],
	]
	for entry in presets:
		manager.set_upscaling_quality(int(entry[0]))
		_check(is_equal_approx(manager.get_upscaling_scale(), float(entry[1])),
			"%s uses the standard FSR2 scale" % String(entry[2]))
		_check(manager.get_upscaling_quality_name() == entry[2],
			"%s exposes the canonical quality name" % String(entry[2]))
	manager.free()


## This suite is the headless one, so it is also the place where the availability
## check has to be honest about where it is running. `--rendering-method
## forward_plus` still reports `forward_plus` on the dummy server, and the
## viewport contract cannot catch that -- `scaling_3d_mode` is a stored property
## that reads back whatever was written to it, so an FSR2 request "succeeds"
## here whether or not an upscaler exists. The RenderingDevice is the difference.
func _test_temporal_upscaling_availability() -> void:
	var has_device := RenderingServer.get_rendering_device() != null
	_check(RTSceneManager.temporal_upscaling_available() == has_device,
		"temporal upscaling is reported available only where a RenderingDevice exists")
	if not has_device:
		_check(not RTSceneManager.temporal_upscaling_available(),
			"a headless/dummy renderer does not report FSR2 as available")


## Godot runs RCAS with `fsr_sharpness` whenever FSR2 is the scaling mode, so an
## undeclared value means the project default silently sharpens the capture.
## Both helpers must set it, both failure checks must catch a drifted value, and
## the capture/restore pair must round-trip it like every other owned property.
func _test_viewport_contract_declares_fsr_sharpness() -> void:
	var viewport := SubViewport.new()
	viewport.fsr_sharpness = 1.75
	var captured := RTVisualContract.capture_viewport_state(viewport)
	_check(captured.has("fsr_sharpness")
		and is_equal_approx(float(captured["fsr_sharpness"]), 1.75),
		"the captured viewport state carries the authored FSR sharpness")

	RTVisualContract.apply_native_viewport_state(viewport, Vector2i(320, 200), true)
	_check(is_equal_approx(viewport.fsr_sharpness, RTVisualContract.FSR_SHARPNESS),
		"the native contract pins FSR sharpness")
	_check(RTVisualContract.native_viewport_failure(
		viewport, Vector2i(320, 200), true).is_empty(),
		"the native contract accepts its own FSR sharpness")
	viewport.fsr_sharpness = RTVisualContract.FSR_SHARPNESS + 0.5
	_check(not RTVisualContract.native_viewport_failure(
		viewport, Vector2i(320, 200), true).is_empty(),
		"the native contract rejects a drifted FSR sharpness")

	RTVisualContract.apply_fsr2_scene_viewport_state(
		viewport, Vector2i(320, 200), 0.5, true)
	_check(is_equal_approx(viewport.fsr_sharpness, RTVisualContract.FSR_SHARPNESS),
		"the FSR2 contract pins the RCAS sharpness it actually uses")
	_check(RTVisualContract.fsr2_scene_viewport_failure(
		viewport, Vector2i(320, 200), 0.5, true).is_empty(),
		"the FSR2 contract accepts its own RCAS sharpness")
	viewport.fsr_sharpness = RTVisualContract.FSR_SHARPNESS + 0.5
	_check(not RTVisualContract.fsr2_scene_viewport_failure(
		viewport, Vector2i(320, 200), 0.5, true).is_empty(),
		"the FSR2 contract rejects a drifted RCAS sharpness")

	RTVisualContract.restore_viewport_state(viewport, captured)
	_check(is_equal_approx(viewport.fsr_sharpness, 1.75),
		"teardown restores the authored FSR sharpness")
	viewport.free()


func _test_capture_contract_matrix() -> void:
	var outputs := [
		Vector2i(1600, 1200),
		Vector2i(2560, 1440),
		Vector2i(3440, 1440),
		Vector2i(3840, 1080),
	]
	for output: Vector2i in outputs:
		for fov in [120.0, 130.0, 140.0]:
			var contract := RTPostProcessStack.debug_panini_capture_contract(
				fov, output)
			var label := "%s at %.1f degrees" % [output, fov]
			_check(bool(contract.get("valid", false)),
				"capture contract is valid for %s" % label)
			_check(int(contract.get("perimeter_samples", 0))
				== 2 * output.x + 2 * output.y,
				"capture contract covers every border texel center and logical corner for %s" % label)
			_check(int(contract.get("invalid_samples", -1)) == 0,
				"capture contract has no pre-clamp invalid sample for %s" % label)
			var uv_min: Vector2 = contract.get("source_uv_min", Vector2(-1.0, -1.0))
			var uv_max: Vector2 = contract.get("source_uv_max", Vector2(2.0, 2.0))
			_check(uv_min.x >= 0.0 and uv_min.y >= 0.0
				and uv_max.x <= 1.0 and uv_max.y <= 1.0,
				"mapped perimeter remains inside the source for %s" % label)
			var mapped_min: Vector2 = contract.get("mapped_rect_min", Vector2.ZERO)
			var mapped_max: Vector2 = contract.get("mapped_rect_max", Vector2.ZERO)
			_check((mapped_min + mapped_max).length() < 0.0001,
				"inverse mapping stays symmetric for %s" % label)
			var capture_fov := float(contract.get("capture_vertical_fov", 0.0))
			_check(capture_fov > 0.0 and capture_fov < 179.0,
				"capture vertical FOV stays finite for %s" % label)
			var capture_hfov := float(contract.get("capture_horizontal_fov", 0.0))
			_check(capture_hfov > 0.0 and capture_hfov < 179.0,
				"capture horizontal FOV stays finite for %s" % label)
			var expected_center_y := tan(deg_to_rad(fov) * 0.5) \
				/ (float(output.x) / float(output.y))
			_check(is_equal_approx(
				float(contract.get("panini_extent_y", 0.0)), expected_center_y),
				"vertical center extent preserves perspective FOV for %s" % label)
	var wide_140 := RTPostProcessStack.debug_panini_capture_contract(
		140.0, Vector2i(2560, 1440))
	var wide_center_vertical_fov := rad_to_deg(2.0 * atan(
		float(wide_140.get("panini_extent_y", 0.0))))
	_check(absf(wide_center_vertical_fov - 114.19) < 0.05,
		"16:9 at 140 horizontal preserves the approximately 114.19-degree center vertical FOV")


## The contract derives its capture bounds from the closed-form corner extremum
## instead of scanning the border. That substitution is only legal because the
## mapping is monotonic in both axes, so pin it against an exhaustive scan of
## every border texel center the runtime would otherwise have visited.
func _test_analytic_bounds_match_full_scan() -> void:
	for output: Vector2i in [
		Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3440, 1440)
	]:
		for fov in [120.0, 125.5, 130.0, 137.25, 140.0]:
			var contract := RTPostProcessStack.debug_panini_capture_contract(
				fov, output)
			var extent_x := float(contract.get("panini_extent_x", 0.0))
			var extent_y := float(contract.get("panini_extent_y", 0.0))
			var scanned := Vector2.ZERO
			for point: Vector2 in RTPostProcessStack._panini_perimeter_points(output):
				var mapped := RTPostProcessStack._panini_inverse_rectilinear(
					point, extent_x, extent_y)
				scanned.x = maxf(scanned.x, absf(mapped.x))
				scanned.y = maxf(scanned.y, absf(mapped.y))
			var reported: Vector2 = contract.get("mapped_rect_max", Vector2.ZERO)
			_check(is_equal_approx(reported.x, scanned.x)
				and is_equal_approx(reported.y, scanned.y),
				"closed-form bounds equal the full border scan for %s at %.2f degrees"
					% [output, fov])


## The rectilinear target spends exactly its declared multiple of the native
## frame and uses the projection-optimal aspect, so FSR2 replaces source-density
## supersampling without paying for frustum the Panini mapping never reads.
func _test_capture_sizing() -> void:
	var outputs := [
		Vector2i(1920, 1080),
		Vector2i(2560, 1440),
		Vector2i(3440, 1440),
		Vector2i(1600, 1200),
	]
	var multiplier := RTPostProcessStack.PANINI_TARGET_PIXEL_MULTIPLIER
	for output: Vector2i in outputs:
		for fov in [120.0, 130.0, 140.0]:
			var capture := RTPostProcessStack.panini_capture_size(output, fov)
			var label := "%s at %.0f degrees" % [output, fov]
			_check(capture.x >= 2 and capture.y >= 2,
				"capture size is allocatable for %s" % label)
			var native_pixels := int(output.x) * int(output.y)
			var capture_pixels := int(capture.x) * int(capture.y)
			var budget := float(native_pixels) * multiplier
			_check(float(capture_pixels) <= budget,
				"capture never exceeds its declared pixel budget for %s" % label)
			_check(float(capture_pixels) / budget > 0.995,
				"capture uses essentially the full declared budget for %s" % label)
			var required := RTPostProcessStack.panini_required_tangents(fov, output)
			_check(absf(float(capture.x) / float(capture.y)
				- required.x / required.y) < 0.002,
				"capture uses the projection-optimal aspect for %s" % label)
			var contract := RTPostProcessStack.debug_panini_capture_contract(
				fov, output, capture)
			_check(bool(contract.get("valid", false)),
				"the pixel-budget capture yields a valid contract for %s" % label)
			var ratio := _center_sampling_ratio(contract, output, capture)
			_check(ratio.x > 0.0 and ratio.y > ratio.x,
				"the budgeted target retains finite center sampling for %s" % label)
			var uv_min: Vector2 = contract.get("source_uv_min", Vector2.ZERO)
			var uv_max: Vector2 = contract.get("source_uv_max", Vector2.ONE)
			_check(uv_min.x < 0.002 and uv_max.x > 0.998,
				"the projection samples the whole capture width for %s" % label)
			# The multiplier is only allowed to buy sharpness, never frame time.
			# Both ratios must scale by its square root against a one-frame target.
			var single := RTPostProcessStack.panini_capture_size(output, fov, 1.0)
			var single_contract := RTPostProcessStack.debug_panini_capture_contract(
				fov, output, single)
			var single_ratio := _center_sampling_ratio(
				single_contract, output, single)
			var expected := sqrt(multiplier)
			_check(absf(ratio.x / maxf(single_ratio.x, 0.00001) - expected) < 0.01
				and absf(ratio.y / maxf(single_ratio.y, 0.00001) - expected) < 0.01,
				"the target multiplier raises both center ratios by its square root for %s"
					% label)
	# An unsupported ceiling reports no capture so the caller can stay rectilinear.
	for fov in [NAN, INF, 0.0, 180.0]:
		_check(RTPostProcessStack.panini_capture_size(
			Vector2i(1920, 1080), fov) == Vector2i.ZERO,
			"ceiling FOV %.3f yields no projected capture" % fov)


func _center_sampling_ratio(
		contract: Dictionary, output: Vector2i, capture: Vector2i) -> Vector2:
	var tangent: Vector2 = contract.get("capture_tan_half_fov", Vector2.ONE)
	return Vector2(
		(float(contract.get("panini_extent_x", 0.0)) / tangent.x)
			* float(capture.x) / float(output.x),
		(float(contract.get("panini_extent_y", 0.0)) / tangent.y)
			* float(capture.y) / float(output.y))


func _test_invalid_contracts() -> void:
	for fov in [NAN, INF, 0.0, 180.0]:
		var contract := RTPostProcessStack.debug_panini_capture_contract(
			fov, Vector2i(2560, 1440))
		_check(not bool(contract.get("valid", true)),
			"invalid display FOV %.3f is rejected" % fov)
	var empty := RTPostProcessStack.debug_panini_capture_contract(
		130.0, Vector2i.ZERO)
	_check(not bool(empty.get("valid", true)), "an empty output is rejected")


func _test_shader_contract() -> void:
	_check(PaniniShader != null, "the Panini canvas shader loads")
	if PaniniShader == null:
		return
	var code := PaniniShader.code
	_check(code.contains("dFdx") and code.contains("dFdy"),
		"the projection filter is derivative-aware")
	_check(code.contains("if (footprint <= 1.0)"),
		"the magnified path is the Catmull-Rom branch")
	_check(code.contains("catmull_rom_sample"),
		"the magnified center reconstructs with Catmull-Rom, not one bilinear tap")
	_check(code.contains("CATMULL_ROM_FADE_START"),
		"Catmull-Rom fades to bilinear where the branches meet")
	_check(code.contains("panini_extent_y"),
		"the shader receives a distinct vertical center extent")
	# Not a portability rule any more, but a structural one: the whole post stack
	# is SubViewports rather than a second RenderingDevice pipeline, and a compute
	# pass here would mean standing one up just for the projection.
	#
	# Scanned with comments stripped, because the comment in the shader that
	# explains this rule names the thing it forbids.
	var executable := ""
	for line in code.split("\n"):
		var text: String = line.strip_edges()
		if not text.begins_with("//"):
			executable += text + "\n"
	_check(not executable.contains("compute"),
		"the projection shader stays a plain canvas fragment pass")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
