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
	_test_player_camera_fixed_fov()
	_finish()


## The display angle is fixed. The projection's target aspect, pixel budget and
## FSR2 render scale are all derived for exactly this angle, and the post stack
## sizes a render target from the camera's declared ceiling -- so a camera that
## could still move within a range would reintroduce the frustum the projection
## never samples.
func _test_panini_camera_capability() -> void:
	var camera := RTPaniniCamera3D.new()
	_check(camera.projection == Camera3D.PROJECTION_PERSPECTIVE,
		"Panini camera uses perspective projection")
	_check(camera.keep_aspect == Camera3D.KEEP_WIDTH,
		"Panini camera keeps width so Camera3D.fov is horizontal")
	_check(is_equal_approx(
		RTPaniniCamera3D.HORIZONTAL_FOV, 140.0),
		"the fixed display angle is 140 degrees")
	_check(is_equal_approx(camera.fov, RTPaniniCamera3D.HORIZONTAL_FOV)
		and is_equal_approx(
			camera.display_horizontal_fov, RTPaniniCamera3D.HORIZONTAL_FOV),
		"display and inherited FOV both report the fixed angle")
	_check(is_equal_approx(
		camera.max_display_horizontal_fov, RTPaniniCamera3D.HORIZONTAL_FOV),
		"the declared ceiling equals the live angle, so no frustum goes unsampled")

	# Scene files are data. An authored value left over from when this was
	# adjustable has to load without either failing or changing the angle.
	camera.set(&"display_horizontal_fov", 130.0)
	camera.set(&"max_display_horizontal_fov", 120.0)
	_check(is_equal_approx(
		camera.display_horizontal_fov, RTPaniniCamera3D.HORIZONTAL_FOV)
		and is_equal_approx(
			camera.max_display_horizontal_fov, RTPaniniCamera3D.HORIZONTAL_FOV),
		"an authored angle is discarded rather than applied")

	# The post stack discovers both by name through get_property_list(), so they
	# have to stay properties rather than becoming bare constants.
	var names := PackedStringArray()
	for property: Dictionary in camera.get_property_list():
		names.append(String(property.get("name", "")))
	_check(names.has("panini_enabled")
		and names.has("display_horizontal_fov")
		and names.has("max_display_horizontal_fov"),
		"the camera still advertises the full post-stack capability protocol")
	camera.free()


func _test_player_camera_fixed_fov() -> void:
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
	_check(is_equal_approx(view.camera.fov, RTPaniniCamera3D.HORIZONTAL_FOV),
		"the authored FPS camera renders at the fixed angle")

	# The view rig no longer owns an FOV at all: no session base, no sprint
	# transition, nothing that could move the angle between frames.
	var rig_properties := PackedStringArray()
	for property: Dictionary in view.get_property_list():
		rig_properties.append(String(property.get("name", "")))
	for removed in [
		"base_horizontal_fov", "dynamic_fov_enabled", "fov_transition_speed"
	]:
		_check(not rig_properties.has(removed),
			"the camera rig no longer exposes %s" % removed)
	_check(not view.has_method("set_base_horizontal_fov")
		and not view.has_method("_handle_dynamic_fov"),
		"the camera rig no longer drives a dynamic FOV")

	# Sprinting is the case that used to widen the angle, so it is the one worth
	# pinning: the projection contract now holds through it.
	player.is_sprinting = true
	player.velocity = Vector3(0.0, 0.0, player.sprint_speed)
	view.call("_process", 0.1)
	_check(is_equal_approx(view.camera.fov, RTPaniniCamera3D.HORIZONTAL_FOV),
		"sprinting does not move the display angle")

	view.reset_view()
	_check(is_equal_approx(view.camera.fov, RTPaniniCamera3D.HORIZONTAL_FOV),
		"reset preserves the fixed angle")
	view.apply_view(0.2)
	_check(is_equal_approx(view.camera.fov, RTPaniniCamera3D.HORIZONTAL_FOV),
		"restoring look pitch preserves the fixed angle")
	player.free()


func _finish() -> void:
	if _failures.is_empty():
		print("player_camera_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("player_camera_smoke: %s" % failure)
	quit(1)
