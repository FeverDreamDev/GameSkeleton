extends SceneTree

## Focused integration probe for streamed receiver-only topology. It asserts
## that terrain chunks can unload/reload without a full RT topology sync or a
## software BLAS/TLAS rebuild, and that tombstoned slots are reused.

var _failures := PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	var level_scene := load("res://game/levels/terrain_test.tscn") as PackedScene
	var player_scene := load("res://player/player.tscn") as PackedScene
	_check(level_scene != null, "terrain level loads")
	_check(player_scene != null, "player scene loads")
	if level_scene == null or player_scene == null:
		_finish()
		return

	var world := Node3D.new()
	world.name = "ReceiverRegistryWorld"
	root.add_child(world)
	var player := player_scene.instantiate() as Player
	player.integrated_mode = true
	player.capture_mouse_on_ready = false
	world.add_child(player)
	var level := level_scene.instantiate() as TerrainTestLevel
	world.add_child(level)
	await process_frame
	var spawn := await level.place_player_at_spawn(player, &"default", 15.0)
	_check(spawn == &"default", "initial terrain becomes ready")
	if spawn != &"default":
		_finish()
		return
	# The level now carries a day/night cycle whose cloud shadow casters are
	# traversable RT geometry. Moving traversable geometry legitimately dirties
	# the TLAS, which would mask the receiver-registry regressions this probe
	# exists to catch. Freeze the sky for the same reason the player is frozen
	# below: everything except the receiver stream has to hold still.
	var day_night := level.get_day_night()
	day_night.set_time_running(false)
	day_night.set_wind_speed(0.0)

	# Let the initial radius finish committing before taking capacity baselines;
	# otherwise later completions look like growth caused by the distant stream.
	for _frame in 120:
		await process_frame
	player.velocity = Vector3.ZERO
	player.process_mode = Node.PROCESS_MODE_DISABLED

	var manager := RTSceneManager.new()
	manager.name = "RTSceneManager"
	manager.auto_start = false
	manager.preview_in_editor = false
	var hardware_requested := OS.get_cmdline_user_args().has("--hardware")
	manager.rt_backend = (
		RTSceneManager.RTBackend.HARDWARE
		if hardware_requested else RTSceneManager.RTBackend.SOFTWARE)
	manager.profiling_enabled = true
	manager.geometry_root_path = NodePath("..")
	manager.world_environment_path = NodePath("")
	world.add_child(manager)
	await process_frame
	var started: bool = await manager.start_rt()
	var expected_backend: StringName = &"hardware" if hardware_requested else &"software"
	_check(started, "%s RT starts" % expected_backend)
	if not started:
		_finish()
		return
	await process_frame

	# Exercise a true grow, then tombstone reuse, before the terrain stream. This
	# covers hardware SSBO/GPU-slot growth as well as software clone registration.
	var initial_profile := manager.get_profile_snapshot()
	var initial_slots := int(initial_profile.get("stable_instance_slots", -1))
	var initial_tlas_revision := int(initial_profile.get("tlas_revision", -1))
	var initial_blas_builds := int(initial_profile.get("blas_builds", -1))
	var initial_tlas_builds := int(initial_profile.get("tlas_builds", -1))
	var initial_mesh_sources := int(initial_profile.get(
		"authored_managed_mesh_resources", -1))
	var probe_material := load(
		"res://game/materials/terrain_blinn_phong.tres") as ShaderMaterial
	_check(probe_material != null, "receiver probe material loads")
	var appended_receiver := _make_probe_receiver(probe_material, "AppendedReceiver")
	world.add_child(appended_receiver)
	for _frame in 6:
		await process_frame
	var grown_profile := manager.get_profile_snapshot()
	_check(int(grown_profile.get("stable_instance_slots", -2)) == initial_slots + 1,
		"receiver append grows exactly one stable slot")
	_check(int(grown_profile.get("tlas_revision", -2)) == initial_tlas_revision,
		"receiver append does not dirty TLAS topology")
	_check(int(grown_profile.get("blas_builds", -2)) == initial_blas_builds,
		"receiver append does not rebuild BLAS")
	_check(int(grown_profile.get("tlas_builds", -2)) == initial_tlas_builds,
		"receiver append does not rebuild TLAS")
	_check(int(grown_profile.get("authored_managed_mesh_resources", -2)) == initial_mesh_sources,
		"receiver meshes are not retained as BLAS sources")
	world.remove_child(appended_receiver)
	appended_receiver.queue_free()
	for _frame in 3:
		await process_frame
	var replacement_receiver := _make_probe_receiver(probe_material, "ReusedReceiver")
	world.add_child(replacement_receiver)
	for _frame in 6:
		await process_frame
	var reused_profile := manager.get_profile_snapshot()
	_check(int(reused_profile.get("stable_instance_slots", -2)) == initial_slots + 1,
		"a new receiver reuses the tombstoned slot")
	world.remove_child(replacement_receiver)
	replacement_receiver.queue_free()
	for _frame in 3:
		await process_frame

	var before := manager.get_profile_snapshot()
	var before_slots := int(before.get("stable_instance_slots", -1))
	var before_topology_syncs := int(before.get("topology_sync_starts", -1))
	var before_tlas_revision := int(before.get("tlas_revision", -1))
	var before_blas_builds := int(before.get("blas_builds", -1))
	var before_tlas_builds := int(before.get("tlas_builds", -1))
	var before_registrations := int(before.get("receiver_only_registrations", -1))
	var before_unregistrations := int(before.get("receiver_only_unregistrations", -1))

	var destination := Vector3(512.0, player.global_position.y, 512.0)
	var destination_ready: bool = await level.wait_for_placement_position(destination, 15.0)
	_check(destination_ready, "distant terrain becomes ready")
	# Keep the player (and its traversable shadow proxy) stationary. Streaming is
	# driven by the level's receiver-only anchor so any TLAS revision would be a
	# receiver registry regression rather than expected player motion.
	for _frame in 180:
		await process_frame

	var after := manager.get_profile_snapshot()
	_check(manager.get_active_rt_backend() == expected_backend,
		"%s backend remains active without rt_failed" % expected_backend)
	_check(int(after.get("receiver_only_unregistrations", 0)) > before_unregistrations,
		"old receiver chunks unregister incrementally")
	_check(int(after.get("receiver_only_registrations", 0)) > before_registrations,
		"new receiver chunks register incrementally")
	_check(int(after.get("topology_sync_starts", -2)) == before_topology_syncs,
		"receiver streaming does not start a full topology sync")
	_check(int(after.get("tlas_revision", -2)) == before_tlas_revision,
		"receiver streaming does not dirty TLAS topology")
	_check(int(after.get("blas_builds", -2)) == before_blas_builds,
		"receiver streaming does not rebuild software BLAS")
	_check(int(after.get("tlas_builds", -2)) == before_tlas_builds,
		"receiver streaming does not rebuild software TLAS")
	var after_active := int(after.get("active_managed_instances", 1 << 30))
	_check(
		int(after.get("stable_instance_slots", 1 << 30))
			<= maxi(before_slots, after_active) + 2,
		"tombstoned receiver slots are reused")
	print("receiver_registry_smoke profile: %s" % after)

	manager.stop_rt()
	world.queue_free()
	await process_frame
	_finish()


func _make_probe_receiver(material: ShaderMaterial, node_name: String) -> MeshInstance3D:
	var receiver := MeshInstance3D.new()
	receiver.name = node_name
	receiver.mesh = BoxMesh.new()
	receiver.material_override = material
	receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	receiver.add_to_group(&"retro_rt_managed")
	receiver.add_to_group(&"retro_rt_receiver_only")
	return receiver


func _finish() -> void:
	if _failures.is_empty():
		print("receiver_registry_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("receiver_registry_smoke: %s" % failure)
	quit(1)
