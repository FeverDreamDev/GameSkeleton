extends SceneTree

var _failures: PackedStringArray = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	var level_scene := load("res://game/levels/terrain_test.tscn") as PackedScene
	var player_scene := load("res://player/player.tscn") as PackedScene
	_check(level_scene != null, "terrain_test.tscn loads")
	_check(player_scene != null, "player.tscn loads")
	if level_scene == null or player_scene == null:
		_finish()
		return

	var player := player_scene.instantiate() as Player
	player.integrated_mode = true
	player.capture_mouse_on_ready = false
	root.add_child(player)

	var level := level_scene.instantiate() as TerrainTestLevel
	root.add_child(level)
	await process_frame

	var used_spawn: StringName = await level.place_player_at_spawn(player, &"default", 15.0)
	_check(used_spawn == &"default", "default spawn collision becomes ready")
	var terrain := level.get_terrain()
	var player_xz := Vector2(player.global_position.x, player.global_position.z)
	_check(terrain.is_position_ready(player_xz), "player stands over a ready terrain chunk")

	var chunk = terrain.get_chunk(terrain.world_to_chunk(player_xz))
	_check(chunk != null and chunk.terrain_ready, "spawn chunk publishes terrain geometry")
	if chunk != null and chunk.terrain_ready:
		var terrain_mesh: MeshInstance3D = chunk.terrain_mesh_instance
		_check(terrain_mesh.is_in_group(&"retro_rt_managed"), "terrain mesh opts into RT management")
		_check(terrain_mesh.is_in_group(&"retro_rt_receiver_only"), "terrain mesh is receiver-only")
		_check(
			terrain_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"terrain mesh does not cast shadows")
		var material := terrain_mesh.material_override as ShaderMaterial
		_check(material != null, "terrain mesh has a ShaderMaterial override")
		if material != null:
			_check(
				material.shader != null
				and material.shader.resource_path == "res://addons/retro_rt/shaders/BlinnPhong.gdshader",
				"terrain uses canonical Blinn-Phong shader")
			_check(material.get_shader_parameter(&"vertex_color_enabled") == true,
				"terrain Blinn-Phong material consumes generated vertex colors")

	var proxy := player.get_node("MeshInstance3D") as MeshInstance3D
	var proxy_mesh_id := proxy.mesh.get_instance_id()
	var standing_scale_y := proxy.scale.y
	player.apply_stance(true, player.crouch_height)
	_check(proxy.mesh.get_instance_id() == proxy_mesh_id, "crouch keeps the RT proxy mesh immutable")
	_check(proxy.scale.y < standing_scale_y, "crouch scales the RT proxy transform")
	_check(proxy.is_in_group(&"retro_rt_managed"), "player shadow proxy opts into RT management")
	_check(
		proxy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,
		"player proxy is shadow-only")

	for _frame in 30:
		await physics_frame
	_check(terrain.get_active_interactor_count() >= 1, "player registers as a grass interactor")

	var reflector_material := level.get_node("TestReflector/MeshInstance3D").material_override as ShaderMaterial
	_check(reflector_material != null, "reflective test prop has a material")
	if reflector_material != null:
		_check(reflector_material.get_shader_parameter(&"mirror_enabled") == true,
			"reflective test prop enables RT mirror rays")
		_check(float(reflector_material.get_shader_parameter(&"reflection_strength")) > 0.0,
			"reflective test prop has non-zero reflection strength")

	level.queue_free()
	player.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("terrain_player_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("terrain_player_smoke: %s" % failure)
	quit(1)
