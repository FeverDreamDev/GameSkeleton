extends SceneTree

## Headless CPU-side contract smoke for the shared Panini pass.
##
## godot --headless --path . --rendering-method gl_compatibility \
##   --script res://addons/retro_rt/tests/panini_projection_smoke.gd

const PaniniShader := preload(
	"res://addons/retro_rt/post_processing/shaders/panini_project.gdshader")

var _failures: PackedStringArray = []


func _initialize() -> void:
	_test_manager_default()
	_test_capture_contract_matrix()
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
	manager.free()


func _test_capture_contract_matrix() -> void:
	var outputs := [
		Vector2i(1600, 1200),
		Vector2i(2560, 1440),
		Vector2i(3440, 1440),
		Vector2i(3840, 1080),
	]
	var scales := [1.0, 0.85, 0.75, 0.5]
	for output: Vector2i in outputs:
		for scale: float in scales:
			var render := Vector2i(
				maxi(2, ceili(float(output.x) * scale)),
				maxi(2, ceili(float(output.y) * scale)))
			for fov in [120.0, 130.0, 140.0]:
				var contract := RTPostProcessStack.debug_panini_capture_contract(
					fov, output, render)
				var label := "%s -> %s at %.1f degrees" % [output, render, fov]
				_check(bool(contract.get("valid", false)),
					"capture contract is valid for %s" % label)
				_check(int(contract.get("perimeter_samples", 0))
					== 2 * output.x + 2 * output.y,
					"capture contract samples every border texel center and logical corner for %s" % label)
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
		140.0, Vector2i(2560, 1440), Vector2i(2560, 1440))
	var wide_center_vertical_fov := rad_to_deg(2.0 * atan(
		float(wide_140.get("panini_extent_y", 0.0))))
	_check(absf(wide_center_vertical_fov - 114.19) < 0.05,
		"16:9 at 140 horizontal preserves the approximately 114.19-degree center vertical FOV")


func _test_invalid_contracts() -> void:
	for fov in [NAN, INF, 0.0, 180.0]:
		var contract := RTPostProcessStack.debug_panini_capture_contract(
			fov, Vector2i(2560, 1440), Vector2i(2560, 1440))
		_check(not bool(contract.get("valid", true)),
			"invalid display FOV %.3f is rejected" % fov)
	var empty := RTPostProcessStack.debug_panini_capture_contract(
		130.0, Vector2i.ZERO, Vector2i(2560, 1440))
	_check(not bool(empty.get("valid", true)), "an empty output is rejected")


func _test_shader_contract() -> void:
	_check(PaniniShader != null, "the Panini canvas shader loads")
	if PaniniShader == null:
		return
	var code := PaniniShader.code
	_check(code.contains("dFdx") and code.contains("dFdy"),
		"the projection filter is derivative-aware")
	_check(code.contains("if (footprint <= 1.0)"),
		"the non-minified path performs one bilinear sample")
	_check(code.contains("panini_extent_y"),
		"the shader receives a distinct vertical center extent")
	_check(not code.contains("textureGather") and not code.contains("compute"),
		"the projection shader stays inside the WebGL2 canvas contract")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
