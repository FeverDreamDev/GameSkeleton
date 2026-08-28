extends SceneTree

## Focused integration probe for streamed receiver-only topology. It asserts
## that terrain chunks can unload/reload without a full RT topology sync or a
## BLAS/TLAS rebuild, and that tombstoned slots are reused.
##
## The receiver registry exists only under hardware RT -- the raster fallback
## keeps no scene representation to register anything into -- so this test needs
## a real ray-tracing adapter and skips itself with a clear message on a machine
## that has none. The Panini sub-mode is pipeline-independent but rides on the
## same live scene, so it skips with it.
##
##   godot --path . --rendering-method forward_plus --resolution 2560x1440 \
##     --script res://addons/retro_rt/tests/receiver_registry_smoke.gd
##   ... -- --panini

var _failures := PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	if not RTSceneManager.hardware_rt_supported():
		print("receiver_registry_smoke: SKIP (no hardware ray tracing on this machine)")
		print("  %s" % RTSceneManager.hardware_rt_unavailable_reason())
		quit(0)
		return
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
	# Freeze the sky for the same reason the player is frozen below: everything
	# except the receiver stream has to hold still, or a legitimate TLAS revision
	# masks the receiver-registry regressions this probe exists to catch.
	var day_night := level.get_day_night()
	day_night.set_time_running(false)
	day_night.set_wind_speed(0.0)

	# Let the initial radius finish committing before taking capacity baselines;
	# otherwise later completions look like growth caused by the distant stream.
	for _frame in 120:
		await process_frame
	player.velocity = Vector3.ZERO
	player.process_mode = Node.PROCESS_MODE_DISABLED

	# This authored local light is deliberately present before RT starts. Hardware
	# removes it from the private carrier layer at the RenderingServer only, while
	# both backends must keep its authored mask in the RT receiver candidate lists.
	var caster_mesh := level.get_node("TestCaster/MeshInstance3D") as MeshInstance3D
	var local_light := OmniLight3D.new()
	local_light.name = "LocalOmniProbe"
	local_light.omni_range = 8.0
	local_light.light_energy = 2.0
	var authored_light_mask := local_light.light_cull_mask
	world.add_child(local_light)
	local_light.global_position = caster_mesh.global_position + Vector3(0.0, 2.0, 0.0)

	var manager := RTSceneManager.new()
	manager.name = "RTSceneManager"
	manager.auto_start = false
	manager.ray_tracing_enabled = true
	var panini_requested := OS.get_cmdline_user_args().has("--panini")
	manager.post_panini_enabled = panini_requested
	manager.profiling_enabled = true
	manager.geometry_root_path = NodePath("..")
	manager.world_environment_path = NodePath("")
	world.add_child(manager)
	await process_frame
	var started: bool = await manager.start_rt()
	_check(started, "hardware RT starts")
	if not started:
		_finish()
		return
	await process_frame

	# Exercise a true grow, then tombstone reuse, before the terrain stream. This
	# covers hardware SSBO/GPU-slot growth.
	#
	# Let generation settle first. The slot assertions below are exact counts over
	# a fifteen-frame window, so a terrain chunk publishing inside that window
	# reads as the probe having grown an extra slot. That made this test sensitive
	# to anything that changes generation timing -- widening grass prefetch was
	# enough to trip it -- which is a property of the test, not of the registry it
	# is checking.
	var settle := 0
	while settle < 2000 and not level.get_terrain().is_generation_idle():
		settle += 1
		await process_frame
	_check(level.get_terrain().is_generation_idle(),
		"terrain generation settles before the slot probe")
	await _check_local_light_updates(manager, local_light, caster_mesh, authored_light_mask)

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
	_check(manager.get_active_rt_backend() == &"hardware",
		"the hardware backend remains active without rt_failed")
	_check(int(after.get("receiver_only_unregistrations", 0)) > before_unregistrations,
		"old receiver chunks unregister incrementally")
	_check(int(after.get("receiver_only_registrations", 0)) > before_registrations,
		"new receiver chunks register incrementally")
	_check(int(after.get("topology_sync_starts", -2)) == before_topology_syncs,
		"receiver streaming does not start a full topology sync")
	_check(int(after.get("tlas_revision", -2)) == before_tlas_revision,
		"receiver streaming does not dirty TLAS topology")
	_check(int(after.get("blas_builds", -2)) == before_blas_builds,
		"receiver streaming does not rebuild the BLAS")
	_check(int(after.get("tlas_builds", -2)) == before_tlas_builds,
		"receiver streaming does not rebuild the TLAS")
	var after_active := int(after.get("active_managed_instances", 1 << 30))
	_check(
		int(after.get("stable_instance_slots", 1 << 30))
			<= maxi(before_slots, after_active) + 2,
		"tombstoned receiver slots are reused")
	print("receiver_registry_smoke profile: %s" % after)

	# The post camera preserves the authored camera mask exactly, and hardware RT
	# requires its reserved carrier bit in it. Call the validator directly so the
	# negative case does not install an expected failure overlay or emit an
	# expected push_error in routine CI.
	var camera := root.get_camera_3d()
	_check(camera != null, "the managed viewport keeps an active camera")
	if camera != null:
		var camera_mask := camera.cull_mask
		_check((camera_mask & RTSceneManager.RT_CARRIER_LAYER_MASK) != 0,
			"the authored camera includes the hardware carrier layer")
		camera.cull_mask = camera_mask & ~RTSceneManager.RT_CARRIER_LAYER_MASK
		var camera_failure := String(manager.call("_runtime_scene_contract_failure"))
		_check(
			camera_failure.contains("cull_mask must include render layer 20"),
			"hardware RT rejects a camera that omits the carrier layer")
		camera.cull_mask = camera_mask
	_check(bool(after.get("post_internal_camera_visual_state_matches", false)),
		"the internal post camera satisfies the authored/capture camera contract")
	if panini_requested:
		_check(bool(after.get("post_panini_enabled", false)),
			"the eligible FPS camera activates the requested Panini pass")
		_check(bool(after.get("post_panini_bounds_valid", false)),
			"the Panini perimeter maps inside the conservative capture")
		_check(int(after.get("post_panini_invalid_samples", -1)) == 0,
			"the exact Panini perimeter has no pre-clamp invalid sample")
		var post_output_size: Vector2i = after.get("post_output_size", Vector2i.ZERO)
		_check(int(after.get("post_panini_perimeter_samples", 0))
			== 2 * post_output_size.x + 2 * post_output_size.y,
			"Panini bounds cover every output border texel center plus logical corners")
		_check(float(after.get("post_panini_capture_horizontal_fov", 0.0))
			> float(after.get("post_panini_display_horizontal_fov", 180.0)),
			"Panini reports the conservative horizontal capture overscan")
		_check(after.get("post_panini_sample_mode", &"invalid")
			== &"catmull_rom_or_box",
			"Panini reports its Catmull-Rom or box adaptive sampling contract")
		_check(after.get("post_present_source", &"invalid") == &"panini",
			"presentation reads the projected native-output target")
		_check(after.get("post_panini_viewport_size", Vector2i.ZERO)
			== after.get("post_output_size", Vector2i.ONE),
			"the Panini target remains in the native output domain")
		_check(int(after.get("post_panini_frames", 0)) > 0,
			"the active Panini target renders frames")
		_check(int(after.get("post_panini_buffer_bytes", 0)) > 0,
			"Panini reports its persistent target memory independently")
		_check(not bool(after.get(
			"post_internal_camera_source_visual_state_exact", true)),
			"Panini reports its intentional private-camera capture override")
		_check(after.get("post_panini_source_stage", &"invalid") == &"scene_resolve",
			"Panini reads the scene resolve target")
		if camera != null:
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			await process_frame
			var bypass_profile := manager.get_profile_snapshot()
			_check(not bool(bypass_profile.get("post_panini_enabled", true))
				and bypass_profile.get("post_panini_bypass_reason", &"invalid")
					== &"non_perspective_camera",
				"a non-perspective source directly bypasses Panini")
			_check(bypass_profile.get("post_present_source", &"invalid")
				== &"scene_resolve",
				"the ineligible-camera bypass keeps the correct upstream source")
			_check(int(bypass_profile.get("post_per_frame_allocation_count", -1)) == 0,
				"camera eligibility changes allocate no post resources")
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.keep_aspect = Camera3D.KEEP_WIDTH
			camera.fov = float(after.get("post_panini_display_horizontal_fov", 130.0))
			await process_frame
			var restored_panini := manager.get_profile_snapshot()
			_check(bool(restored_panini.get("post_panini_enabled", false)),
				"restoring perspective reuses the persistent Panini target")
			camera.h_offset = 0.1
			await process_frame
			var offset_bypass := manager.get_profile_snapshot()
			_check(not bool(offset_bypass.get("post_panini_enabled", true))
				and offset_bypass.get("post_panini_bypass_reason", &"invalid")
					== &"camera_offset_unsupported",
				"a shifted asymmetric camera safely bypasses the symmetric mapping")
			camera.h_offset = 0.0
			await process_frame
			_check(bool(manager.get_profile_snapshot().get("post_panini_enabled", false)),
				"clearing the camera offset reuses the persistent Panini target")
	else:
		_check(not bool(after.get("post_panini_enabled", true)),
			"the reusable manager keeps Panini directly bypassed by default")
		_check(after.get("post_present_source", &"invalid") == &"scene_resolve",
			"the Native bypass presents resolve directly")
	_check(local_light.light_cull_mask == authored_light_mask,
		"RT renderer overrides never mutate the authored local-light mask")

	manager.stop_rt()
	_check(local_light.light_cull_mask == authored_light_mask,
		"stopping RT preserves the authored local-light mask")
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


func _check_local_light_updates(
		manager: RTSceneManager,
		light: OmniLight3D,
		caster_mesh: MeshInstance3D,
		authored_light_mask: int) -> void:
	var near_snapshot: Dictionary = manager.get("_current_snapshot")
	var light_index := _snapshot_light_index(near_snapshot, light.name)
	var caster_index := _snapshot_instance_index(near_snapshot, "TestCaster/MeshInstance3D")
	_check(light_index >= 0, "the local omni is published to RT")
	_check(caster_index >= 0, "the managed TestCaster is published as an RT receiver")
	if light_index >= 0:
		var light_records: Array = (near_snapshot.get("light", {}) as Dictionary).get("records", [])
		var record: Dictionary = light_records[light_index]
		_check(int(record.get("type", -1)) == 1, "the local light keeps its omni RT type")
		_check(int(record.get("cull_mask", 0)) == (authored_light_mask & ((1 << 20) - 1)),
			"the RT snapshot keeps the omni's authored cull mask")
	if caster_index >= 0:
		var instance_layers: PackedInt32Array = near_snapshot.get(
			"instance_layers", PackedInt32Array())
		_check(
			caster_index < instance_layers.size()
			and instance_layers[caster_index] == caster_mesh.layers,
			"the RT snapshot keeps the receiver's authored layers")
	_check(_snapshot_has_candidate(near_snapshot, caster_index, light_index),
		"the nearby omni reaches the managed receiver through RT")

	var near_position := light.global_position
	var before_far := manager.get_profile_snapshot()
	light.global_position = Vector3(100000.0, 100000.0, 100000.0)
	var far_snapshot: Dictionary
	for _frame in 30:
		await process_frame
		far_snapshot = manager.get("_current_snapshot")
		light_index = _snapshot_light_index(far_snapshot, light.name)
		caster_index = _snapshot_instance_index(far_snapshot, "TestCaster/MeshInstance3D")
		if not _snapshot_has_candidate(far_snapshot, caster_index, light_index):
			break
	var after_far := manager.get_profile_snapshot()
	_check(not _snapshot_has_candidate(far_snapshot, caster_index, light_index),
		"moving the omni away removes it from the receiver's RT candidates")
	_check(int(after_far.get("light_influence_updates", 0))
			> int(before_far.get("light_influence_updates", 0)),
		"moving a local light records an influence update")
	_check(int(after_far.get("receiver_light_list_rebuilds", 0))
			> int(before_far.get("receiver_light_list_rebuilds", 0)),
		"moving a local light rebuilds the receiver lists")
	_check(int(after_far.get("receiver_light_revision", 0))
			> int(before_far.get("receiver_light_revision", 0)),
		"moving a local light advances the receiver-list revision")

	light.global_position = near_position
	var restored_snapshot: Dictionary
	for _frame in 30:
		await process_frame
		restored_snapshot = manager.get("_current_snapshot")
		light_index = _snapshot_light_index(restored_snapshot, light.name)
		caster_index = _snapshot_instance_index(
			restored_snapshot, "TestCaster/MeshInstance3D")
		if _snapshot_has_candidate(restored_snapshot, caster_index, light_index):
			break
	var after_restore := manager.get_profile_snapshot()
	_check(_snapshot_has_candidate(restored_snapshot, caster_index, light_index),
		"moving the omni back restores its RT receiver contribution")
	_check(int(after_restore.get("light_influence_updates", 0))
			> int(after_far.get("light_influence_updates", 0)),
		"restoring a local light records another influence update")
	_check(int(after_restore.get("receiver_light_list_rebuilds", 0))
			> int(after_far.get("receiver_light_list_rebuilds", 0)),
		"restoring a local light rebuilds the receiver lists again")
	_check(light.light_cull_mask == authored_light_mask,
		"local-light movement leaves the authored cull mask unchanged")


func _snapshot_light_index(snapshot: Dictionary, light_name: StringName) -> int:
	var light_records: Array = (snapshot.get("light", {}) as Dictionary).get("records", [])
	for index in light_records.size():
		var record: Dictionary = light_records[index]
		if StringName(record.get("name", &"")) == light_name:
			return index
	return -1


func _snapshot_instance_index(snapshot: Dictionary, path_suffix: String) -> int:
	var instances: Array = snapshot.get("instances", [])
	for index in instances.size():
		var record: Dictionary = instances[index]
		if String(record.get("path", "")).ends_with(path_suffix):
			return index
	return -1


func _snapshot_has_candidate(
		snapshot: Dictionary, instance_index: int, light_index: int) -> bool:
	if instance_index < 0 or light_index < 0:
		return false
	var starts: PackedInt32Array = snapshot.get(
		"receiver_light_starts", PackedInt32Array())
	var counts: PackedInt32Array = snapshot.get(
		"receiver_light_counts", PackedInt32Array())
	var indices: PackedInt32Array = snapshot.get(
		"receiver_light_indices", PackedInt32Array())
	if instance_index >= starts.size() or instance_index >= counts.size():
		return false
	var start := starts[instance_index]
	var count := counts[instance_index]
	for offset in count:
		if start + offset < indices.size() and indices[start + offset] == light_index:
			return true
	return false


func _finish() -> void:
	if _failures.is_empty():
		print("receiver_registry_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("receiver_registry_smoke: %s" % failure)
	quit(1)
