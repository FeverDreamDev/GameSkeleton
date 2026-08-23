@tool
@icon("res://addons/procedural_terrain_grass/icons/terrain_grass_3d.svg")
class_name TerrainGrass3D
extends Node3D

## Streamed procedural terrain with textureless shell grass.
##
## Add one of these to a scene, point [member streaming_target] at the node the
## world should stream around (or leave it empty to follow the active
## [Camera3D]) and run. Chunks are generated, masked and meshed in the
## background as the target moves.
##
## Appearance properties apply the moment they change. Generation, collision,
## LOD geometry and performance properties are read when the runtime starts;
## call [method rebuild] after changing those at runtime.

const SYSTEM_GROUP := &"procedural_terrain_grass_system"
const TerrainSettingsScript = preload("res://addons/procedural_terrain_grass/core/terrain_settings.gd")
const TerrainManagerScript = preload("res://addons/procedural_terrain_grass/core/terrain_manager.gd")
const TerrainGeneratorScript = preload("res://addons/procedural_terrain_grass/core/terrain_generator.gd")
const GrassInteractionManagerScript = preload("res://addons/procedural_terrain_grass/core/grass_interaction_manager.gd")
const TerrainShader = preload("res://addons/procedural_terrain_grass/shaders/terrain.gdshader")
const GrassShader = preload("res://addons/procedural_terrain_grass/shaders/grass_shell.gdshader")

## Maximum simultaneous interactors the grass shader can accept.
const MAX_SHADER_INTERACTORS := 8

## Emitted once a chunk's terrain mesh and collision shape are live.
signal chunk_loaded(coord: Vector2i, chunk)
## Emitted when a chunk leaves the streaming radius and is freed.
signal chunk_unloaded(coord: Vector2i)
## Emitted when a chunk's grass shell meshes have been rebuilt and published.
signal grass_rebuilt(coord: Vector2i)

@export_category("Target")
## Node the world streams around. Falls back to the viewport's active Camera3D.
@export var streaming_target: Node3D
## Begin streaming automatically as soon as a target is available.
@export var auto_start: bool = true

# Changing any of these takes effect on the next rebuild(), but they also feed
# the height preview sample_height() serves before the runtime exists, so each
# one drops that cache.
@export_category("Terrain Generation")
@export var terrain_seed: int = 1337:
	set(value):
		terrain_seed = value
		_preview_noise = null
@export_range(4.0, 1024.0, 1.0, "or_greater") var chunk_size: float = 32.0:
	set(value):
		chunk_size = value
		_preview_noise = null
		update_configuration_warnings()
@export_range(4, 256, 1, "or_greater") var chunk_resolution: int = 32:
	set(value):
		chunk_resolution = value
		_preview_noise = null
		update_configuration_warnings()
@export_range(0.00001, 1.0, 0.00001, "or_greater") var noise_frequency: float = 0.008:
	set(value):
		noise_frequency = value
		_preview_noise = null
@export_range(1, 12, 1) var noise_octaves: int = 4:
	set(value):
		noise_octaves = value
		_preview_noise = null
@export_range(1.0, 4.0, 0.01) var noise_lacunarity: float = 2.0:
	set(value):
		noise_lacunarity = value
		_preview_noise = null
@export_range(0.0, 1.0, 0.01) var noise_gain: float = 0.5:
	set(value):
		noise_gain = value
		_preview_noise = null
@export_range(0.0, 1024.0, 0.1, "or_greater") var height_amplitude: float = 14.0:
	set(value):
		height_amplitude = value
		_preview_noise = null

@export_category("Terrain Appearance")
## Optional shared material used by every streamed terrain chunk. Leave this
## empty for the add-on's standalone terrain shader; assign the canonical
## Blinn-Phong material when integrating with Retro RT.
@export var terrain_material_override: ShaderMaterial:
	set(value):
		terrain_material_override = value
		_mark_visuals_dirty()
@export var terrain_low_color: Color = Color("536b3c")
@export var terrain_high_color: Color = Color("827651")
@export var terrain_steep_color: Color = Color("665f55")
@export var terrain_height_color_min: float = -10.0
@export var terrain_height_color_max: float = 16.0
@export_range(0.0, 1.0, 0.01) var terrain_steep_normal_y: float = 0.82
@export_range(0.0, 1.0, 0.01) var terrain_roughness: float = 0.95:
	set(value):
		terrain_roughness = value
		_mark_visuals_dirty()
@export_range(0.0, 1.0, 0.01) var terrain_specular: float = 0.05:
	set(value):
		terrain_specular = value
		_mark_visuals_dirty()

@export_category("Retro RT Integration")
## Only meshes in this group are collected by RTSceneManager. The generated
## ground joins it; the deforming shell-grass mesh deliberately does not.
@export var terrain_mesh_group: StringName
## Receiver-only terrain is rasterized and lit by RT, but omitted from both
## shadow and reflection traversal. It can receive a shadow without creating
## one, and its streamed topology never becomes a secondary-ray occluder.
@export var terrain_receiver_only_group: StringName

@export_category("Streaming")
@export_range(1.0, 4096.0, 1.0, "or_greater") var terrain_load_distance: float = 96.0
@export_range(1.0, 4096.0, 1.0, "or_greater") var terrain_unload_distance: float = 128.0
@export_range(0.01, 10.0, 0.01, "or_greater") var stream_update_interval: float = 0.20
@export_range(0.01, 10.0, 0.01, "or_greater") var lod_update_interval: float = 0.10

@export_category("Grass Appearance")
@export var grass_enabled: bool = true
@export_range(0.01, 10.0, 0.01, "or_greater") var grass_height: float = 0.6:
	set(value):
		grass_height = value
		_mark_visuals_dirty()
@export_range(1.0, 128.0, 1.0, "or_greater") var grass_density: float = 16.0:
	set(value):
		grass_density = value
		_mark_visuals_dirty()
@export_range(0.0, 90.0, 0.5) var max_grass_slope_degrees: float = 38.0
@export_range(0.0, 4096.0, 1.0, "or_greater") var grass_prefetch_distance: float = 96.0
@export_range(0.0, 0.1, 0.001) var root_offset: float = 0.006:
	set(value):
		root_offset = value
		_mark_visuals_dirty()
@export var grass_base_color: Color = Color(0.11, 0.24, 0.06):
	set(value):
		grass_base_color = value
		_mark_visuals_dirty()
@export var grass_tip_color: Color = Color(0.32, 0.52, 0.12):
	set(value):
		grass_tip_color = value
		_mark_visuals_dirty()
@export var grass_color_noise_enabled: bool = true:
	set(value):
		grass_color_noise_enabled = value
		_mark_visuals_dirty()
@export var grass_color_noise_seed: int = 7331:
	set(value):
		grass_color_noise_seed = value
		_mark_visuals_dirty()
@export_range(0.1, 256.0, 0.1, "or_greater") var grass_color_noise_patch_size: float = 6.0:
	set(value):
		grass_color_noise_patch_size = value
		_mark_visuals_dirty()
@export_range(0.0, 1.0, 0.01) var grass_color_noise_strength: float = 0.18:
	set(value):
		grass_color_noise_strength = value
		_mark_visuals_dirty()
@export var grass_color_noise_low_tint: Color = Color(0.84, 0.94, 0.76):
	set(value):
		grass_color_noise_low_tint = value
		_mark_visuals_dirty()
@export var grass_color_noise_high_tint: Color = Color(1.12, 1.04, 0.82):
	set(value):
		grass_color_noise_high_tint = value
		_mark_visuals_dirty()
@export_range(0.0, 0.5, 0.01) var grass_color_noise_detail_strength: float = 0.03:
	set(value):
		grass_color_noise_detail_strength = value
		_mark_visuals_dirty()

@export_category("Wind")
@export var wind_enabled: bool = true:
	set(value):
		wind_enabled = value
		_mark_visuals_dirty()
@export var wind_direction: Vector2 = Vector2(1.0, 0.3):
	set(value):
		wind_direction = value
		_mark_visuals_dirty()
@export_range(0.0, 20.0, 0.05, "or_greater") var wind_speed: float = 2.4:
	set(value):
		wind_speed = value
		_mark_visuals_dirty()
@export_range(0.0, 1.0, 0.001, "or_greater") var wind_strength: float = 0.035:
	set(value):
		wind_strength = value
		_mark_visuals_dirty()

@export_category("Grass LOD")
@export_range(2, 64, 1) var near_shell_count: int = 16
@export_range(2, 64, 1) var medium_shell_count: int = 10
@export_range(2, 64, 1) var far_shell_count: int = 4
@export_range(0.1, 1.0, 0.01) var far_shell_top: float = 0.75
@export_range(0.0, 4096.0, 1.0, "or_greater") var lod_near_to_medium: float = 26.0
@export_range(0.0, 4096.0, 1.0, "or_greater") var lod_medium_to_near: float = 22.0
@export_range(0.0, 4096.0, 1.0, "or_greater") var lod_medium_to_far: float = 52.0
@export_range(0.0, 4096.0, 1.0, "or_greater") var lod_far_to_medium: float = 44.0
@export_range(0.0, 4096.0, 1.0, "or_greater") var lod_far_to_hidden: float = 86.0
@export_range(0.0, 4096.0, 1.0, "or_greater") var lod_hidden_to_far: float = 76.0

@export_category("Interaction and Masking")
@export var dynamic_interaction_enabled: bool = true:
	set(value):
		dynamic_interaction_enabled = value
		_mark_visuals_dirty()
@export var static_masking_enabled: bool = true
## How many interactors may bend grass at once. The grass shader has room for
## eight; the rest are dropped by score. (Range must be a literal here, but it
## is the same value as [constant MAX_SHADER_INTERACTORS].)
@export_range(1, 8, 1) var active_interactor_limit: int = 4
@export_range(0.1, 512.0, 0.1, "or_greater") var interactor_discovery_radius: float = 25.0
@export_range(0.01, 10.0, 0.01, "or_greater") var interactor_discovery_interval: float = 0.10
@export_range(0.05, 10.0, 0.05) var default_interactor_radius: float = 0.6
@export_range(0.0, 4.0, 0.05) var default_interactor_strength: float = 0.8
@export_range(0.0, 2.0, 0.01) var interaction_push_scale: float = 0.12:
	set(value):
		interaction_push_scale = value
		_mark_visuals_dirty()
@export_range(0.0, 4.0, 0.01) var flatten_response: float = 1.0:
	set(value):
		flatten_response = value
		_mark_visuals_dirty()
@export_range(0.0, 1.0, 0.01) var minimum_flatten: float = 0.3:
	set(value):
		minimum_flatten = value
		_mark_visuals_dirty()

@export_category("Collision")
@export_flags_3d_physics var terrain_collision_layer: int = 1
@export_flags_3d_physics var terrain_collision_mask: int = 1
@export_flags_3d_physics var blocker_query_mask: int = 1 << 7
@export_flags_3d_physics var interactor_query_mask: int = 1 << 8

@export_category("Performance")
@export_range(1, 32, 1) var max_worker_jobs: int = 2
@export_range(100, 100000, 100, "or_greater") var incremental_generation_budget_usec: int = 2000
@export_range(100, 100000, 100, "or_greater") var mask_query_budget_usec: int = 1000
@export_range(1, 8192, 1, "or_greater") var max_mask_cell_queries: int = 128
@export_range(1, 64, 1) var max_mesh_commits_per_frame: int = 2

var _settings
var _terrain_manager: Node3D
var _interaction_manager: Node3D
var _terrain_material: ShaderMaterial
var _grass_material: ShaderMaterial
var _active_target: Node3D
var _runtime_epoch: int = 0
var _started: bool = false
var _missing_target_warned: bool = false
var _visuals_dirty: bool = true
var _registered_static: Dictionary = {}
var _registered_interactors: Dictionary = {}
var _preview_noise: FastNoiseLite
var _preview_snapshot: Dictionary = {}


func _ready() -> void:
	add_to_group(SYSTEM_GROUP)
	# The shader needs the system origin, and chunks are placed relative to it.
	set_notify_transform(true)
	if Engine.is_editor_hint():
		# Nothing streams in the editor; only configuration warnings and
		# sample_height() previews stay live.
		set_process(false)
		return
	_create_runtime()


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	_dispose_runtime()


func _notification(what: int) -> void:
	if what != NOTIFICATION_TRANSFORM_CHANGED:
		return
	# Chunk placement and the grass shader both key off the system origin, and
	# the preview noise caches it too.
	_preview_noise = null
	_mark_visuals_dirty()
	if Engine.is_editor_hint():
		update_configuration_warnings()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _terrain_manager == null:
		return
	_refresh_target()
	if _visuals_dirty:
		_apply_visual_settings()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not _has_supported_transform():
		warnings.append("TerrainGrass3D supports translation only. Rotation and non-unit scale must be removed.")
	for error in _configuration_errors():
		warnings.append(error)
	return warnings


## Starts streaming chunks around the current target. Does nothing until a
## target is available; [member auto_start] calls this for you.
func start_streaming() -> void:
	if _terrain_manager == null:
		return
	_refresh_target(false)
	if _active_target == null:
		if not _missing_target_warned:
			push_warning("TerrainGrass3D is waiting for an assigned target or active Camera3D.")
			_missing_target_warned = true
		return
	_terrain_manager.start_streaming()
	_started = true


## Suspends streaming. Already-loaded chunks stay in the scene.
func stop_streaming() -> void:
	if _terrain_manager != null:
		_terrain_manager.stop_streaming(false)
	_started = false


## Tears the runtime down and recreates it from the current inspector values.
## Required after changing generation, collision, LOD geometry or performance
## properties while the scene is running.
func rebuild() -> void:
	if Engine.is_editor_hint():
		return
	var restart := _started or auto_start
	_dispose_runtime()
	_create_runtime(restart)


## Terrain height in world space at [param world_xz]. Works before the runtime
## exists, so it is safe to use when placing props during scene setup.
func sample_height(world_xz: Vector2) -> float:
	if _terrain_manager != null:
		return _terrain_manager.sample_height(world_xz)
	var origin := _origin_position()
	var local_xz := world_xz - Vector2(origin.x, origin.z)
	if _preview_noise == null:
		_preview_snapshot = _build_settings().snapshot()
		_preview_noise = TerrainGeneratorScript.create_noise(_preview_snapshot)
	return TerrainGeneratorScript.sample_height(_preview_noise, local_xz.x, local_xz.y, _preview_snapshot) + origin.y


func world_to_chunk(world_xz: Vector2) -> Vector2i:
	if _terrain_manager != null:
		return _terrain_manager.world_to_chunk(world_xz)
	var origin := _origin_position()
	var local_xz := world_xz - Vector2(origin.x, origin.z)
	return Vector2i(floori(local_xz.x / chunk_size), floori(local_xz.y / chunk_size))


func get_chunk(coord: Vector2i):
	return _terrain_manager.get_chunk(coord) if _terrain_manager != null else null


func get_loaded_chunks() -> Array:
	return _terrain_manager.get_loaded_chunks() if _terrain_manager != null else []


func distance_to_chunk_aabb(world_xz: Vector2, coord: Vector2i) -> float:
	return _terrain_manager.distance_to_chunk_aabb(world_xz, coord) if _terrain_manager != null else INF


## True when every queued generation, masking and mesh-commit job has drained.
func is_generation_idle() -> bool:
	return _terrain_manager == null or _terrain_manager.is_generation_idle()


## True once the streamed chunk under [param world_xz] has both render geometry
## and a live HeightMapShape3D. Useful for placing a character without letting
## it fall through a chunk that is still being built.
func is_position_ready(world_xz: Vector2) -> bool:
	var chunk = get_chunk(world_to_chunk(world_xz))
	return (
		chunk != null
		and chunk.terrain_ready
		and chunk.terrain_collision != null
		and chunk.terrain_collision.shape != null
	)


## Waits until [method is_position_ready] succeeds or the timeout expires.
## The extra physics frame publishes the new shape to the physics server before
## the caller places a body on it.
func wait_for_position_ready(world_xz: Vector2, timeout_seconds: float = 10.0) -> bool:
	var deadline_usec := Time.get_ticks_usec() + int(maxf(timeout_seconds, 0.0) * 1_000_000.0)
	while not is_position_ready(world_xz):
		if timeout_seconds >= 0.0 and Time.get_ticks_usec() >= deadline_usec:
			return false
		await get_tree().process_frame
	await get_tree().physics_frame
	return true


## Snapshot of streaming counters, handy for an on-screen debug overlay.
func get_runtime_stats() -> Dictionary:
	if _terrain_manager == null:
		return {
			"loaded_chunks": 0,
			"queued_work": 0,
			"active_jobs": 0,
			"mask_queries": 0,
			"mesh_commits": 0,
			"generation_backend": "Not initialized",
			"active_interactors": 0,
		}
	return {
		"loaded_chunks": _terrain_manager.chunks.size(),
		"queued_work": _terrain_manager.queued_work_count(),
		"active_jobs": _terrain_manager.active_generation_job_count(),
		"mask_queries": _terrain_manager.mask_query_count,
		"mesh_commits": _terrain_manager.mesh_commit_count,
		"generation_backend": _terrain_manager.generation_backend_name(),
		"active_interactors": get_active_interactor_count(),
	}


func get_blocker_query_mask() -> int:
	return blocker_query_mask


func get_grass_material() -> ShaderMaterial:
	return _grass_material


func get_active_interactor_count() -> int:
	return _interaction_manager.get_active_count() if _interaction_manager != null else 0


## Registers any node as a static grass blocker. Nodes carrying a
## [TerrainGrassBlocker3D] register themselves; use this for arbitrary meshes
## or bodies that should carve grass away.
func register_static_grass_blocker(node: Node3D) -> void:
	if not is_instance_valid(node):
		return
	_registered_static[node.get_instance_id()] = weakref(node)
	if _interaction_manager != null:
		_interaction_manager.register_static_grass_blocker(node)


func unregister_static_grass_blocker(node: Node3D) -> void:
	if node == null:
		return
	_registered_static.erase(node.get_instance_id())
	if _interaction_manager != null:
		_interaction_manager.unregister_static_grass_blocker(node)


## Re-reads a registered blocker's bounds and rebuilds the grass it covers.
func notify_static_blocker_changed(node: Node3D) -> void:
	if _interaction_manager != null:
		_interaction_manager.notify_static_blocker_changed(node)


## Registers a node that should bend grass as it moves.
func register_grass_interactor(node: Node3D) -> void:
	if not is_instance_valid(node):
		return
	_registered_interactors[node.get_instance_id()] = weakref(node)
	if _interaction_manager != null:
		_interaction_manager.register_grass_interactor(node)


func unregister_grass_interactor(node: Node3D) -> void:
	if node == null:
		return
	_registered_interactors.erase(node.get_instance_id())
	if _interaction_manager != null:
		_interaction_manager.unregister_grass_interactor(node)


## Forces every chunk overlapping [param world_bounds] to re-run static masking.
func invalidate_grass_region(world_bounds: AABB) -> void:
	if _terrain_manager != null:
		_terrain_manager.invalidate_grass_region(world_bounds)


func get_active_interactor_data() -> Array[Vector4]:
	return _interaction_manager.get_active_interactor_data() if _interaction_manager != null else []


func _create_runtime(start_when_ready: bool = auto_start) -> void:
	var errors := _configuration_errors()
	if not _has_supported_transform():
		errors.append("TerrainGrass3D cannot start with rotation or non-unit scale.")
	if not errors.is_empty():
		for error in errors:
			push_error(error)
		return
	_runtime_epoch += 1
	var epoch := _runtime_epoch
	_settings = _build_settings()
	_create_materials()

	_terrain_manager = TerrainManagerScript.new()
	_terrain_manager.name = "_TerrainManager"
	_terrain_manager.settings = _settings
	_terrain_manager.terrain_material = _terrain_material
	_terrain_manager.grass_material = _grass_material
	_terrain_manager.grass_enabled = _settings.grass_enabled
	_terrain_manager.static_masking_enabled = _settings.static_masking_enabled
	_terrain_manager.chunk_loaded.connect(_on_chunk_loaded)
	_terrain_manager.chunk_unloaded.connect(_on_chunk_unloaded)
	_terrain_manager.grass_rebuilt.connect(_on_grass_rebuilt)
	add_child(_terrain_manager)

	_interaction_manager = GrassInteractionManagerScript.new()
	_interaction_manager.name = "_GrassInteractionManager"
	_interaction_manager.settings = _settings
	_interaction_manager.terrain_manager = _terrain_manager
	_interaction_manager.grass_material = _grass_material
	_interaction_manager.dynamic_interaction_enabled = _settings.dynamic_interaction_enabled
	add_child(_interaction_manager)
	_terrain_manager.interaction_manager = _interaction_manager

	_replay_registrations()
	_refresh_target(false)
	_apply_visual_settings()
	if start_when_ready:
		_start_after_physics_frame(epoch)


func _start_after_physics_frame(epoch: int) -> void:
	await get_tree().physics_frame
	if epoch == _runtime_epoch and is_inside_tree():
		start_streaming()


func _dispose_runtime() -> void:
	_runtime_epoch += 1
	_started = false
	_active_target = null
	if is_instance_valid(_terrain_manager):
		_terrain_manager.shutdown()
		remove_child(_terrain_manager)
		_terrain_manager.queue_free()
	if is_instance_valid(_interaction_manager):
		remove_child(_interaction_manager)
		_interaction_manager.queue_free()
	_terrain_manager = null
	_interaction_manager = null
	_terrain_material = null
	_grass_material = null
	_settings = null


func _refresh_target(allow_autostart: bool = true) -> void:
	var next_target := streaming_target if is_instance_valid(streaming_target) else get_viewport().get_camera_3d()
	if next_target == _active_target:
		return
	_active_target = next_target
	if _terrain_manager != null:
		_terrain_manager.target = _active_target
	if _interaction_manager != null:
		_interaction_manager.target = _active_target
	if _active_target != null:
		_missing_target_warned = false
		if allow_autostart and auto_start and not _started:
			start_streaming()


func _create_materials() -> void:
	if terrain_material_override != null:
		_terrain_material = terrain_material_override
	else:
		_terrain_material = ShaderMaterial.new()
		_terrain_material.shader = TerrainShader
	_grass_material = ShaderMaterial.new()
	_grass_material.shader = GrassShader
	var empty_interactors: Array[Vector4] = []
	empty_interactors.resize(MAX_SHADER_INTERACTORS)
	_grass_material.set_shader_parameter("grass_interactors", empty_interactors)


func _mark_visuals_dirty() -> void:
	_visuals_dirty = true


func _apply_visual_settings() -> void:
	_visuals_dirty = false
	if _terrain_material != null:
		if terrain_material_override != null:
			# The palette remains baked into ARRAY_COLOR. White diffuse preserves
			# it while the assigned canonical material supplies Blinn-Phong light.
			_terrain_material.set_shader_parameter("diffuse_color", Color.WHITE)
			_terrain_material.set_shader_parameter("vertex_color_enabled", true)
			# Preserve the old roughness/specular controls by translating them to
			# their closest Blinn-Phong counterparts.
			var roughness := maxf(terrain_roughness, 0.001)
			var shininess := clampf(2.0 / (roughness * roughness) - 2.0, 1.0, 256.0)
			_terrain_material.set_shader_parameter("shininess", shininess)
			_terrain_material.set_shader_parameter(
				"direct_specular_intensity", clampf(terrain_specular * 2.0, 0.0, 2.0))
			_terrain_material.set_shader_parameter("mirror_enabled", false)
			_terrain_material.set_shader_parameter("reflection_strength", 0.0)
			_terrain_material.set_shader_parameter("reflection_shadows_enabled", false)
		else:
			_terrain_material.set_shader_parameter("u_roughness", terrain_roughness)
			_terrain_material.set_shader_parameter("u_specular", terrain_specular)
	if _grass_material != null:
		var direction := wind_direction.normalized()
		if direction.is_zero_approx():
			direction = Vector2.RIGHT
		_grass_material.set_shader_parameter("u_base_color", grass_base_color)
		_grass_material.set_shader_parameter("u_tip_color", grass_tip_color)
		_grass_material.set_shader_parameter("u_density", grass_density)
		_grass_material.set_shader_parameter("u_max_height", grass_height)
		_grass_material.set_shader_parameter("u_root_offset", root_offset)
		_grass_material.set_shader_parameter("u_wind_direction", direction)
		_grass_material.set_shader_parameter("u_wind_speed", wind_speed)
		_grass_material.set_shader_parameter("u_wind_strength", wind_strength)
		_grass_material.set_shader_parameter("u_wind_enabled", wind_enabled)
		_grass_material.set_shader_parameter("u_interaction_enabled", dynamic_interaction_enabled)
		_grass_material.set_shader_parameter("u_color_noise_enabled", grass_color_noise_enabled)
		_grass_material.set_shader_parameter("u_color_noise_seed", grass_color_noise_seed)
		_grass_material.set_shader_parameter("u_color_noise_patch_size", grass_color_noise_patch_size)
		_grass_material.set_shader_parameter("u_color_noise_strength", grass_color_noise_strength)
		_grass_material.set_shader_parameter("u_color_noise_low_tint", grass_color_noise_low_tint)
		_grass_material.set_shader_parameter("u_color_noise_high_tint", grass_color_noise_high_tint)
		_grass_material.set_shader_parameter("u_color_noise_detail_strength", grass_color_noise_detail_strength)
		_grass_material.set_shader_parameter("u_interaction_push_scale", interaction_push_scale)
		_grass_material.set_shader_parameter("u_flatten_response", flatten_response)
		_grass_material.set_shader_parameter("u_min_flatten", minimum_flatten)
		var origin := _origin_position()
		_grass_material.set_shader_parameter("u_system_origin_xz", Vector2(origin.x, origin.z))
	if _interaction_manager != null:
		_interaction_manager.dynamic_interaction_enabled = dynamic_interaction_enabled
	if _terrain_manager != null:
		_terrain_manager.set_grass_cull_height(grass_height)


func _build_settings():
	var result = TerrainSettingsScript.new()
	for property in TerrainSettingsScript.MIRRORED_PROPERTIES:
		result.set(property, get(property))
	return result


func _configuration_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if chunk_size <= 0.0 or chunk_resolution < 2:
		errors.append("Chunk size must be positive and chunk resolution must be at least 2.")
	if terrain_height_color_max <= terrain_height_color_min:
		errors.append("Terrain height color maximum must be greater than its minimum.")
	if terrain_unload_distance < terrain_load_distance:
		errors.append("Terrain unload distance must be greater than or equal to load distance.")
	errors.append_array(_lod_threshold_errors())
	if active_interactor_limit < 1 or active_interactor_limit > MAX_SHADER_INTERACTORS:
		errors.append("Active interactor limit must be between 1 and the shader maximum of %d." % MAX_SHADER_INTERACTORS)
	if max_worker_jobs < 1 or incremental_generation_budget_usec < 1 or mask_query_budget_usec < 1:
		errors.append("Generation worker and time budgets must be positive.")
	if max_mask_cell_queries < 1 or max_mesh_commits_per_frame < 1:
		errors.append("Mask-query and mesh-commit budgets must be positive.")
	if grass_density <= 0.0 or grass_color_noise_patch_size <= 0.0:
		errors.append("Grass density and color-noise patch size must be positive.")
	return errors


# Each LOD band steps down at one distance and back up at a shorter one, so the
# grass never flickers between two meshes on a boundary. Reporting the specific
# pair that is out of order is far more actionable than one combined message.
func _lod_threshold_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if lod_medium_to_near >= lod_near_to_medium:
		errors.append("Grass LOD: 'medium to near' must be closer than 'near to medium'.")
	if lod_far_to_medium >= lod_medium_to_far:
		errors.append("Grass LOD: 'far to medium' must be closer than 'medium to far'.")
	if lod_hidden_to_far >= lod_far_to_hidden:
		errors.append("Grass LOD: 'hidden to far' must be closer than 'far to hidden'.")
	if lod_near_to_medium >= lod_medium_to_far:
		errors.append("Grass LOD: 'near to medium' must be closer than 'medium to far'.")
	if lod_medium_to_far >= lod_far_to_hidden:
		errors.append("Grass LOD: 'medium to far' must be closer than 'far to hidden'.")
	if lod_medium_to_near >= lod_far_to_medium:
		errors.append("Grass LOD: 'medium to near' must be closer than 'far to medium'.")
	if lod_far_to_medium >= lod_hidden_to_far:
		errors.append("Grass LOD: 'far to medium' must be closer than 'hidden to far'.")
	return errors


func _has_supported_transform() -> bool:
	var basis := global_transform.basis if is_inside_tree() else transform.basis
	return basis.is_equal_approx(Basis.IDENTITY)


func _origin_position() -> Vector3:
	return global_position if is_inside_tree() else position


func _replay_registrations() -> void:
	_replay_registration_dictionary(_registered_static, &"register_static_grass_blocker")
	_replay_registration_dictionary(_registered_interactors, &"register_grass_interactor")


func _replay_registration_dictionary(source: Dictionary, method: StringName) -> void:
	var stale_ids: Array[int] = []
	for id_variant in source.keys():
		var instance_id := int(id_variant)
		var reference := source[instance_id] as WeakRef
		var node := reference.get_ref() as Node3D
		if not is_instance_valid(node):
			stale_ids.append(instance_id)
			continue
		# A rebuild can change the query mask, so blockers re-adopt it here
		# instead of keeping whatever layer the previous runtime handed them.
		if node is TerrainGrassBlocker3D:
			node.collision_layer = blocker_query_mask
		_interaction_manager.call(method, node)
	for instance_id in stale_ids:
		source.erase(instance_id)


func _on_chunk_loaded(coord: Vector2i, chunk) -> void:
	chunk_loaded.emit(coord, chunk)


func _on_chunk_unloaded(coord: Vector2i) -> void:
	chunk_unloaded.emit(coord)


func _on_grass_rebuilt(coord: Vector2i) -> void:
	grass_rebuilt.emit(coord)
