extends SceneTree

## Headless probe for the raster fallback -- what runs instead of hardware ray
## tracing on an adapter that cannot ray trace, and what the player gets when
## they turn RT off in the Graphics dialog.
##
## Headless Forward+ has no RenderingDevice, so the manager always selects the
## fallback here. That is the point: this is the one test that can assert the
## fallback's contract on any machine, with or without a ray-tracing GPU.
##
##   godot --headless --path . --rendering-method forward_plus \
##     --script res://addons/retro_rt/tests/raster_fallback_smoke.gd

const BLINN_PHONG_SHADER_PATH := "res://addons/retro_rt/shaders/BlinnPhong.gdshader"

var _failures := PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _build_world() -> Dictionary:
	var world := Node3D.new()
	world.name = "RasterFallbackWorld"
	root.add_child(world)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.56, 0.7, 0.85)
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_exposure = 1.0
	# Authored off, exactly as a scene targeting hardware RT would leave it. The
	# manager owning the switch is what lets one scene serve both pipelines.
	environment.ssr_enabled = false
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	world.add_child(world_environment)

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	camera.position = Vector3(0.0, 2.0, 6.0)
	world.add_child(camera)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	# Under hardware RT this checkbox is repurposed as the RT-shadow toggle and
	# the native shadow map is suppressed. Under the fallback it has to keep
	# meaning what it says, or the scene renders unshadowed.
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	world.add_child(sun)

	var material := ShaderMaterial.new()
	material.shader = load(BLINN_PHONG_SHADER_PATH) as Shader
	material.set_shader_parameter(&"diffuse_color", Color(0.3, 0.5, 0.25))

	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "Caster"
	mesh_node.mesh = BoxMesh.new()
	mesh_node.material_override = material
	mesh_node.add_to_group(&"retro_rt_managed")
	world.add_child(mesh_node)

	var manager := RTSceneManager.new()
	manager.name = "RTSceneManager"
	manager.auto_start = false
	manager.geometry_root_path = NodePath("..")
	manager.world_environment_path = NodePath("../WorldEnvironment")
	manager.fog_enabled = true
	manager.fog_begin = 20.0
	manager.fog_end = 80.0
	world.add_child(manager)

	return {
		"world": world,
		"manager": manager,
		"environment": environment,
		"material": material,
		"sun": sun,
	}


func _run() -> void:
	_check(not RTSceneManager.hardware_rt_supported(),
		"headless Forward+ reports no hardware ray tracing, so the fallback is under test")

	var scene := _build_world()
	var manager: RTSceneManager = scene["manager"]
	var environment: Environment = scene["environment"]
	var material: ShaderMaterial = scene["material"]
	var sun: DirectionalLight3D = scene["sun"]
	await process_frame

	var started: bool = await manager.start_rt()
	_check(started, "the raster fallback starts")
	if not started:
		_finish()
		return
	_check(manager.get_active_rt_backend() == &"raster",
		"the active backend reports as raster rather than hardware or none")

	# Under hardware RT the manager suppresses this so the RT pass can own
	# shadows. Leaving it alone is what the fallback's shadows are.
	_check(sun.shadow_enabled,
		"the authored shadow toggle is left alone, so native shadow maps render")
	_check(environment.ssr_enabled,
		"the manager turns Environment SSR on, which is the fallback's reflection source")

	# Distance fog reaches managed surfaces through the material rather than the
	# compositor here. Without it, terrain fades at the streaming boundary and the
	# props standing on it do not.
	#
	# The push itself is a RenderingServer override, and headless runs the dummy
	# renderer, which stores nothing and reads back null for every material param.
	# So this asserts the two halves the manager actually controls: that the
	# material was found at all, and that the values handed to it are the
	# manager's own fog rather than the shader defaults. That BlinnPhong then
	# applies them is covered by ground_layer_smoke's uniform and drift checks.
	var raster_materials: Array = manager.get(&"_material_sources")
	_check(raster_materials.has(material),
		"the fallback finds the managed BlinnPhong material to push fog to")
	var fog := manager.get_distance_fog()
	_check(bool(fog.get("enabled", false)), "the manager reports its fog as enabled")
	_check(is_equal_approx(float(fog.get("begin", 0.0)), 20.0)
			and is_equal_approx(float(fog.get("end", 0.0)), 80.0),
		"the fog handed to managed materials is the manager's authored range")
	_check((fog.get("color", Color.BLACK) as Color) != Color.BLACK,
		"the fog colour resolves from the environment background rather than staying black")

	# The post stack is renderer-independent and is most of what the fallback
	# still owns, so a fallback frame has to present through the same chain.
	var profile := manager.get_profile_snapshot()
	_check(int(profile.get("post_persistent_buffer_bytes", 0)) > 0,
		"the shared post stack is configured and sized under the fallback")
	_check(String(profile.get("active_backend", "")) == "raster",
		"the profile snapshot reports the raster backend")

	# Turning the toggle back on cannot produce hardware RT here, and must say so
	# rather than silently claiming it did.
	var enabled_result: bool = await manager.set_ray_tracing_enabled(true)
	_check(enabled_result, "asking for RT on a machine without it still brings a pipeline up")
	_check(manager.get_active_rt_backend() == &"raster",
		"asking for RT without an adapter for it stays honestly on the fallback")

	manager.stop_rt()
	await process_frame
	_check(not environment.ssr_enabled,
		"stopping restores the authored SSR value instead of leaving the scene changed")
	_check(manager.get_active_rt_backend() == &"none",
		"a stopped manager reports no backend")

	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("raster_fallback_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("raster_fallback_smoke: %s" % failure)
	quit(1)
