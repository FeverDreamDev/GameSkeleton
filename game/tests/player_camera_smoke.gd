extends SceneTree

## Focused contract coverage. Run with:
## godot --headless --path . --script res://game/tests/player_camera_smoke.gd

var _failures: PackedStringArray = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	_test_panini_camera_capability()
	_test_player_camera_session_fov()
	_finish()


func _test_panini_camera_capability() -> void:
	var camera := RTPaniniCamera3D.new()
	_check(camera.projection == Camera3D.PROJECTION_PERSPECTIVE,
		"Panini camera uses perspective projection")
	_check(camera.keep_aspect == Camera3D.KEEP_WIDTH,
		"Panini camera keeps width so Camera3D.fov is horizontal")
	_check(is_equal_approx(
		camera.display_horizontal_fov, RTPaniniCamera3D.DEFAULT_HORIZONTAL_FOV),
		"Panini camera starts at the 130 degree default")

	camera.set_display_horizontal_fov(136.0)
	_check(is_equal_approx(camera.display_horizontal_fov, 136.0)
		and is_equal_approx(camera.fov, 136.0),
		"display and inherited FOV stay synchronized")
	camera.set_display_horizontal_fov(NAN)
	_check(is_equal_approx(camera.display_horizontal_fov, 136.0),
		"NaN is rejected without replacing the previous FOV")
	camera.set_display_horizontal_fov(INF)
	_check(is_equal_approx(camera.display_horizontal_fov, 136.0),
		"infinity is rejected without replacing the previous FOV")
	camera.set_display_horizontal_fov(100.0)
	_check(is_equal_approx(camera.fov, RTPaniniCamera3D.MIN_HORIZONTAL_FOV),
		"finite FOV values clamp to the supported minimum")
	camera.set_display_horizontal_fov(180.0)
	_check(is_equal_approx(camera.fov, RTPaniniCamera3D.MAX_HORIZONTAL_FOV),
		"finite FOV values clamp to the supported maximum")
	camera.free()


func _test_player_camera_session_fov() -> void:
	var player_scene := load("res://player/player.tscn") as PackedScene
	_check(player_scene != null, "player scene loads")
	if player_scene == null:
		return
	var player := player_scene.instantiate() as Player
	_check(player != null, "player scene instantiates")
	if player == null:
		return
	player.capture_mouse_on_ready = false
	root.add_child(player)

	var view := player.get_node_or_null("ViewRoot") as PlayerCamera
	_check(view != null, "player exposes its camera controller")
	if view == null:
		player.free()
		return
	_check(view.camera is RTPaniniCamera3D and view.camera.panini_enabled,
		"FPS camera opts into the reusable Panini capability")
	_check(is_equal_approx(view.get_effective_horizontal_fov(), 130.0),
		"player camera starts at 130 degrees horizontally")

	view.set_base_horizontal_fov(136.0)
	view.reset_view()
	_check(is_equal_approx(view.base_horizontal_fov, 136.0)
		and is_equal_approx(view.get_effective_horizontal_fov(), 136.0),
		"reset preserves and reapplies the session base FOV")
	view.apply_view(0.2)
	_check(is_equal_approx(view.get_effective_horizontal_fov(), 136.0),
		"restoring look pitch preserves the session base FOV")
	view.set_base_horizontal_fov(NAN)
	_check(is_equal_approx(view.base_horizontal_fov, 136.0),
		"the player-facing FOV API rejects NaN without changing its session value")
	view.set_base_horizontal_fov(INF)
	_check(is_equal_approx(view.base_horizontal_fov, 136.0),
		"the player-facing FOV API rejects infinity without changing its session value")

	view.dynamic_fov_enabled = false
	view.fov_transition_speed = log(2.0)
	view.camera.set_display_horizontal_fov(140.0)
	view.set_base_horizontal_fov(130.0, false)
	view.call("_handle_dynamic_fov", 1.0)
	_check(is_equal_approx(view.get_effective_horizontal_fov(), 135.0),
		"disabled sprint FOV still eases a deferred base-FOV change in degree space")

	view.dynamic_fov_enabled = true
	view.fov_transition_speed = 8.0
	view.set_base_horizontal_fov(120.0)
	player.is_sprinting = true
	player.velocity = Vector3(0.0, 0.0, player.sprint_speed)
	view.call("_handle_dynamic_fov", 10.0)
	_check(is_equal_approx(view.get_effective_horizontal_fov(), 130.0),
		"a 120-degree base sprints to 130 degrees")

	view.set_base_horizontal_fov(135.0)
	view.call("_handle_dynamic_fov", 10.0)
	_check(is_equal_approx(view.get_effective_horizontal_fov(), 140.0),
		"a 135-degree base sprints to the 140-degree cap")

	view.set_base_horizontal_fov(140.0)
	view.call("_handle_dynamic_fov", 10.0)
	_check(is_equal_approx(view.get_effective_horizontal_fov(), 140.0),
		"a 140-degree base remains at the cap while sprinting")

	view.set_base_horizontal_fov(130.0)
	view.call("_handle_dynamic_fov", 10.0)
	player.is_sprinting = false
	view.call("_handle_dynamic_fov", 10.0)
	_check(is_equal_approx(view.get_effective_horizontal_fov(), 130.0),
		"releasing sprint returns the effective FOV to the session base")

	player.is_sprinting = true
	view.call("_handle_dynamic_fov", 10.0)
	view.dynamic_fov_enabled = false
	view.call("_handle_dynamic_fov", 10.0)
	_check(is_equal_approx(view.get_effective_horizontal_fov(), 130.0),
		"disabling dynamic FOV while boosted returns to the session base")

	view.dynamic_fov_enabled = true
	view.fov_transition_speed = 2.75
	var smoothed_results: Array[float] = []
	for fps in [30, 60, 144]:
		view.set_base_horizontal_fov(120.0)
		player.is_sprinting = true
		player.velocity = Vector3(0.0, 0.0, player.sprint_speed)
		_simulate_dynamic_fov(view, 1.0, fps)
		smoothed_results.append(view.get_effective_horizontal_fov())
	var expected_after_one_second := 130.0 - 10.0 * exp(-view.fov_transition_speed)
	for result in smoothed_results:
		_check(absf(result - expected_after_one_second) < 0.0001,
			"degree-space sprint smoothing matches the analytic one-second result")
	_check(absf(smoothed_results[0] - smoothed_results[1]) < 0.0001
		and absf(smoothed_results[1] - smoothed_results[2]) < 0.0001,
		"sprint smoothing is equivalent at 30, 60, and 144 FPS")

	player.free()


func _simulate_dynamic_fov(view: PlayerCamera, seconds: float, fps: int) -> void:
	var delta := 1.0 / float(fps)
	for _frame in range(roundi(seconds * float(fps))):
		view.call("_handle_dynamic_fov", delta)


func _finish() -> void:
	if _failures.is_empty():
		print("player_camera_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("player_camera_smoke: %s" % failure)
	quit(1)
