@tool
extends RefCounted
class_name RTSoftwareTracer

## Main-thread owner for the Compatibility/Web fragment-shader RT backend.
##
## The manager supplies the same immutable snapshots used by the hardware
## compositor. This class builds CPU BVHs, publishes them through ordinary
## sampled ImageTextures, and installs renderer-only material overrides. It
## never mutates the authored material properties stored on scene nodes.

const ATLAS_WIDTH := 1024
const MAX_ATLAS_HEIGHT := 4096
const MAX_ATLAS_TEXELS := ATLAS_WIDTH * MAX_ATLAS_HEIGHT
const MAX_EXACT_FLOAT_INTEGER := 1 << 24
const MAX_TOTAL_LIGHTS := 256
const SOFTWARE_SHADER_PATH := "res://addons/retro_rt/shaders/BlinnPhongSoftware.gdshader"
const SOFTWARE_VALIDATION_SHADER_PATH := "res://addons/retro_rt/shaders/BlinnPhongSoftwareValidation.gdshader"
const SOFTWARE_VALIDATION_ARGUMENT := "--validate-software-atlas-headers"
const RT_INSTANCE_ID_PARAMETER := &"rt_instance_id"
const RT_RECEIVER_LAYERS_PARAMETER := &"rt_receiver_layers"
const RT_RECEIVER_LIGHT_START_PARAMETER := &"rt_receiver_light_start"
const RT_RECEIVER_LIGHT_COUNT_PARAMETER := &"rt_receiver_light_count"

const GEOMETRY_MAGIC := 47010.0
const INSTANCE_MAGIC := 47011.0
const SHADING_MAGIC := 47012.0
const ATLAS_VERSION := 3.0
const MATERIAL_TEXEL_STRIDE := 8
const TRIANGLE_TEXEL_STRIDE := 8
const TLAS_MASK_BITS := 0x03
const TLAS_LEAF_BIT := 0x04

const PUBLIC_MATERIAL_PARAMETERS: Array[StringName] = [
	&"ambient_light",
	&"diffuse_color",
	&"emission_color",
	&"specular_color",
	&"shininess",
	&"direct_specular_intensity",
	&"mirror_enabled",
	&"reflection_strength",
	&"reflection_shadows_enabled",
	&"albedo_texture",
	&"normal_texture",
	&"vertex_color_enabled",
	&"triplanar_enabled",
	&"triplanar_world_space",
	&"triplanar_scale",
	&"triplanar_offset",
	&"triplanar_sharpness",
]

var _owner_node: Node
var _bvh: RefCounted
var _software_shader: Shader
var _material_sources: Array[ShaderMaterial] = []
var _primary_material_records: Array[Dictionary] = []
var _managed_instances: Array[Dictionary] = []
var _material_clones: Array[ShaderMaterial] = []
var _material_clone_by_source_id: Dictionary = {}
var _override_records: Array[Dictionary] = []

var _geometry_texture: ImageTexture
var _instance_texture: ImageTexture
var _shading_texture: ImageTexture
var _albedo_texture: Texture2D
var _normal_texture: Texture2D
var _environment_texture: Texture2D
var _geometry_height := 0
var _instance_height := 0
var _shading_height := 0
var _texture_atlas_bytes := 0
var _environment_texture_bytes := 0
var _textures_dirty := false

var _blas: Dictionary = {}
var _tlas: Dictionary = {}
var _receiver_light_starts := PackedInt32Array()
var _receiver_light_counts := PackedInt32Array()
var _receiver_light_indices := PackedInt32Array()
var _cached_instance_layers := PackedInt32Array()
var _max_lights_per_receiver := 16
var _receiver_light_revision := -1

var _geometry_layout := Vector4i.ZERO
var _geometry_counts := Vector4i.ZERO
var _instance_layout := Vector4i.ZERO
var _instance_count := 0
var _shading_layout := Vector4i.ZERO
var _shading_counts := Vector4i.ZERO
var _frame_settings := Vector4.ZERO
var _miss_color := Color.BLACK
var _fog_params := Vector4(0.0, 1.0, 1.0, 0.0)
# Analytic ground layer, the only thing a reflection ray has to resolve the
# ground against: streamed terrain is receiver-only and shell grass is
# unmanaged, so neither is in the BVH. See RTSceneManager.configure_ground_layer.
var _ground_texture: Texture2D
var _ground_params := Vector4.ZERO
var _ground_bounds := Vector4.ZERO
var _ground_ambient := Color.BLACK
var _ground_grass := Vector4.ZERO
var _ground_sun_direction := Vector3.UP
var _ground_sun_radiance := Color.BLACK
var _ground_sun_enabled := false
var _environment_mode := 0
var _environment_inverse_basis := Basis.IDENTITY
var _environment_revision := -1
var _frame_uniforms_dirty := false
var _primary_instance_parameters_dirty := false
var _material_parameters_dirty := false

var _topology_revision := -1
var _tlas_revision := -1
var _instance_revision := -1
var _material_revision := -1
var _light_revision := -1
var _settings_revision := -1

var _initialized := false
var _profile: Dictionary = {
	"backend": "software",
	"blas_builds": 0,
	"tlas_builds": 0,
	"atlas_uploads": 0,
	"geometry_uploads": 0,
	"instance_uploads": 0,
	"shading_uploads": 0,
	"texture_atlas_bytes": 0,
	"environment_texture_bytes": 0,
	"environment_updates": 0,
	"environment_revision": 0,
	"environment_mode": 0,
	"environment_panorama_width": 0,
	"environment_panorama_height": 0,
	"texture_bytes": 0,
	"blas_nodes": 0,
	"tlas_nodes": 0,
	"triangles": 0,
	"max_receiver_lights": 0,
	"last_update_usec": 0,
	"peak_update_usec": 0,
	"blas_build_usec": 0,
	"tlas_build_usec": 0,
}


## Returns an empty string on success, otherwise a user-facing failure reason.
func initialize(
		owner: Node,
		snapshot: Dictionary,
		material_sources: Array[ShaderMaterial],
		managed_instances: Array[Dictionary],
		software_max_lights: int,
		_retro_settings: Dictionary = {}) -> String:
	shutdown()
	_reset_profile()
	var started := Time.get_ticks_usec()
	_owner_node = owner
	_material_sources = material_sources.duplicate()
	_primary_material_records = (snapshot.get("material_records", []) as Array).duplicate(true)
	_managed_instances = managed_instances.duplicate()
	_max_lights_per_receiver = clampi(software_max_lights, 1, 32)

	if _owner_node == null or not is_instance_valid(_owner_node):
		return _initialize_failed("The software RT backend has no valid owner node.")
	if snapshot.is_empty():
		return _initialize_failed("The software RT backend received an empty scene snapshot.")
	if _material_sources.is_empty() or _managed_instances.is_empty():
		return _initialize_failed("The software RT backend requires managed materials and geometry instances.")
	var atlas_error := _capture_shared_texture_atlases(snapshot)
	if not atlas_error.is_empty():
		return _initialize_failed(atlas_error)
	var environment_error := _consume_environment_snapshot(snapshot)
	if not environment_error.is_empty():
		return _initialize_failed(environment_error)

	var software_shader_path := (
		SOFTWARE_VALIDATION_SHADER_PATH
		if (
			OS.get_cmdline_args().has(SOFTWARE_VALIDATION_ARGUMENT)
			or OS.get_cmdline_user_args().has(SOFTWARE_VALIDATION_ARGUMENT)
		)
		else SOFTWARE_SHADER_PATH
	)
	_software_shader = load(software_shader_path) as Shader
	if _software_shader == null:
		return _initialize_failed("Could not load %s." % software_shader_path)
	_bvh = RTSoftwareBVH.new()
	if _bvh == null or not _bvh.has_method("build_blas") or not _bvh.has_method("build_tlas"):
		return _initialize_failed("RTSoftwareBVH does not expose the required build API.")

	var mesh_records: Array = snapshot.get("mesh_records", [])
	_blas = _bvh.call("build_blas", mesh_records) as Dictionary
	if not bool(_blas.get("ok", false)):
		return _initialize_failed(String(_blas.get("error", "Software BLAS construction failed.")))
	_profile["blas_builds"] = 1
	_profile["blas_build_usec"] = int(round(float(_blas.get("build_seconds", 0.0)) * 1000000.0))
	_profile["blas_nodes"] = (_blas.get("nodes", []) as Array).size()
	_profile["triangles"] = (_blas.get("triangles", []) as Array).size()

	var error := _build_and_upload_geometry_atlas()
	if not error.is_empty():
		return _initialize_failed(error)
	error = _consume_receiver_light_lists(snapshot)
	if not error.is_empty():
		return _initialize_failed(error)
	error = _rebuild_tlas(snapshot)
	if not error.is_empty():
		return _initialize_failed(error)
	error = _build_and_upload_instance_atlas(snapshot)
	if not error.is_empty():
		return _initialize_failed(error)
	error = _build_and_upload_shading_atlas(snapshot)
	if not error.is_empty():
		return _initialize_failed(error)
	error = _create_material_clones()
	if not error.is_empty():
		return _initialize_failed(error)
	error = _capture_and_apply_overrides()
	if not error.is_empty():
		return _initialize_failed(error)
	_topology_revision = int(snapshot.get("topology_revision", 0))
	_tlas_revision = int(snapshot.get("tlas_revision", 0))
	_instance_revision = int(snapshot.get("instance_revision", 0))
	_material_revision = int(snapshot.get("material_revision", 0))
	_light_revision = int(snapshot.get("light_revision", 0))
	_environment_revision = int(snapshot.get("environment_revision", 0))
	_settings_revision = int(snapshot.get("settings_revision", 0))
	_receiver_light_revision = int(snapshot.get("receiver_light_revision", _light_revision))
	# RTSceneManager owns the renderer instance identity and installs it before
	# this backend starts. The software tracer owns only its additional receiver
	# metadata instance uniforms.
	_initialized = true
	_update_texture_byte_profile()
	var elapsed := Time.get_ticks_usec() - started
	_profile["last_update_usec"] = elapsed
	_profile["peak_update_usec"] = elapsed
	return ""


## Applies revisioned scene changes. Topology changes deliberately require a
## complete backend reinitialization so BLASes remain immutable.
func update(snapshot: Dictionary, _retro_settings: Dictionary = {}) -> String:
	if not _initialized:
		return "The software RT backend is not initialized."
	var started := Time.get_ticks_usec()
	if int(snapshot.get("topology_revision", -1)) != _topology_revision:
		return "Runtime topology changes require reinitializing the software RT backend."
	var atlas_error := _validate_shared_texture_atlases(snapshot)
	if not atlas_error.is_empty():
		return atlas_error

	var next_tlas_revision := int(snapshot.get("tlas_revision", 0))
	var next_instance_revision := int(snapshot.get("instance_revision", 0))
	var next_material_revision := int(snapshot.get("material_revision", 0))
	var next_light_revision := int(snapshot.get("light_revision", 0))
	var next_environment_revision := int(snapshot.get("environment_revision", 0))
	var next_settings_revision := int(snapshot.get("settings_revision", 0))
	var layers_changed := not _packed_int_arrays_equal(
		snapshot.get("instance_layers", PackedInt32Array()), _cached_instance_layers)
	var shared_lists := _has_shared_receiver_light_lists(snapshot)
	if shared_lists and not snapshot.has("receiver_light_revision"):
		return "Shared software receiver-light lists require receiver_light_revision."
	var next_receiver_light_revision := int(snapshot.get(
		"receiver_light_revision", next_light_revision))
	var lists_changed := (
		next_receiver_light_revision != _receiver_light_revision
		if shared_lists
		else next_light_revision != _light_revision or layers_changed
	)
	var tlas_changed := next_tlas_revision != _tlas_revision
	var instance_changed := next_instance_revision != _instance_revision
	var material_changed := next_material_revision != _material_revision
	var light_changed := next_light_revision != _light_revision
	var environment_changed := next_environment_revision != _environment_revision
	var packed_settings_changed := Vector4(
		float(snapshot.get("bias", 0.001)),
		float(snapshot.get("max_distance", 10000.0)),
		float(_max_lights_per_receiver),
		ATLAS_VERSION) != _frame_settings
	var error := ""
	if environment_changed:
		error = _consume_environment_snapshot(snapshot)
		if not error.is_empty():
			return error

	if lists_changed:
		error = _consume_receiver_light_lists(snapshot)
		if not error.is_empty():
			return error
	if tlas_changed:
		error = _rebuild_tlas(snapshot)
		if not error.is_empty():
			return error
	if tlas_changed or instance_changed or lists_changed:
		error = _build_and_upload_instance_atlas(snapshot)
		if not error.is_empty():
			return error
	if lists_changed or material_changed or light_changed or packed_settings_changed:
		error = _build_and_upload_shading_atlas(snapshot)
		if not error.is_empty():
			return error
	if instance_changed or lists_changed:
		_primary_instance_parameters_dirty = true
	if material_changed:
		_primary_material_records = (snapshot.get("material_records", []) as Array).duplicate(true)
		_material_parameters_dirty = true

	var next_fog := Vector4(
		float(snapshot.get("fog_begin", 0.0)),
		float(snapshot.get("fog_end", 1.0)),
		float(snapshot.get("fog_curve", 1.0)),
		1.0 if bool(snapshot.get("fog_enabled", false)) else 0.0)
	# A lighting term, not part of the packed material settings that rebuild the
	# shading atlas, so it does not force one.
	var next_ground_texture: Texture2D = snapshot.get("ground_map")
	var next_ground_params: Vector4 = snapshot.get("ground_params", Vector4.ZERO)
	var next_ground_bounds: Vector4 = snapshot.get("ground_bounds", Vector4.ZERO)
	var next_ground_ambient: Color = snapshot.get("ground_ambient", Color.BLACK)
	var next_ground_grass: Vector4 = snapshot.get("ground_grass", Vector4.ZERO)
	var next_ground_sun_direction: Vector3 = snapshot.get("ground_sun_direction", Vector3.UP)
	var next_ground_sun_radiance: Color = snapshot.get("ground_sun_radiance", Color.BLACK)
	var next_ground_sun_enabled := bool(snapshot.get("ground_sun_enabled", false))
	if (next_ground_texture != _ground_texture
			or next_ground_params != _ground_params
			or next_ground_bounds != _ground_bounds
			or next_ground_ambient != _ground_ambient
			or next_ground_grass != _ground_grass
			or next_ground_sun_direction != _ground_sun_direction
			or next_ground_sun_radiance != _ground_sun_radiance
			or next_ground_sun_enabled != _ground_sun_enabled):
		_ground_texture = next_ground_texture
		_ground_params = next_ground_params
		_ground_bounds = next_ground_bounds
		_ground_ambient = next_ground_ambient
		_ground_grass = next_ground_grass
		_ground_sun_direction = next_ground_sun_direction
		_ground_sun_radiance = next_ground_sun_radiance
		_ground_sun_enabled = next_ground_sun_enabled
		_frame_uniforms_dirty = true
	if next_fog != _fog_params:
		# Deliberately not part of packed_settings_changed: fog is a post-lighting
		# composite, and that flag rebuilds the whole shading atlas.
		_fog_params = next_fog
		_frame_uniforms_dirty = true

	_tlas_revision = next_tlas_revision
	_instance_revision = next_instance_revision
	_material_revision = next_material_revision
	_light_revision = next_light_revision
	_environment_revision = next_environment_revision
	_settings_revision = next_settings_revision
	_receiver_light_revision = next_receiver_light_revision
	if _textures_dirty:
		_bind_atlases_to_materials()
	_sync_dirty_shader_state()
	_update_texture_byte_profile()
	var elapsed := Time.get_ticks_usec() - started
	_profile["last_update_usec"] = elapsed
	_profile["peak_update_usec"] = maxi(int(_profile["peak_update_usec"]), elapsed)
	return ""


## Grows/tombstones primary receiver bindings without rebuilding the immutable
## software BLAS/TLAS. RTSceneManager keeps traversal masks at zero for every
## slot introduced through this path.
func sync_receiver_instances(
		snapshot: Dictionary,
		material_sources: Array[ShaderMaterial],
		managed_instances: Array[Dictionary]) -> String:
	if not _initialized:
		return "The software RT backend is not initialized."
	if managed_instances.size() < _managed_instances.size():
		return "The receiver-only registry cannot shrink stable software instance slots."
	if material_sources.size() < _material_sources.size():
		return "The receiver-only registry cannot shrink the software material table."
	_material_sources = material_sources.duplicate()
	_primary_material_records = (
		snapshot.get("material_records", []) as Array).duplicate(true)
	_managed_instances = managed_instances.duplicate()

	while _material_clones.size() < _material_sources.size():
		var material_index := _material_clones.size()
		var source := _material_sources[material_index]
		if source == null or not is_instance_valid(source):
			return "Managed software RT material %d is no longer valid." % material_index
		var clone := ShaderMaterial.new()
		clone.shader = _software_shader
		clone.resource_name = "%s (Software RT)" % source.resource_name
		_material_clones.append(clone)
		_material_clone_by_source_id[source.get_instance_id()] = material_index

	while _override_records.size() < _managed_instances.size():
		var append_error := _append_override_record(_override_records.size())
		if not append_error.is_empty():
			return append_error
	for instance_index in mini(_override_records.size(), _managed_instances.size()):
		if bool(_managed_instances[instance_index].get("receiver_tombstone", false)):
			var record := _override_records[instance_index].duplicate(true)
			record["node"] = null
			_override_records[instance_index] = record
		elif _managed_mesh_node(_override_records[instance_index]) == null:
			# A streamed receiver reused a tombstoned stable slot. Build its clone
			# bindings in a temporary tail record, then move that record into place.
			var replace_error := _append_override_record(instance_index)
			if not replace_error.is_empty():
				return replace_error
			var replacement: Dictionary = _override_records.pop_back()
			_override_records[instance_index] = replacement

	var list_error := _consume_receiver_light_lists(snapshot)
	if not list_error.is_empty():
		return list_error
	_material_parameters_dirty = true
	_frame_uniforms_dirty = true
	_bind_atlases_to_materials()
	_sync_dirty_shader_state()
	reassert_overrides()
	return ""


## Reapplies renderer-only state after ordinary gameplay nodes have processed.
func reassert_overrides() -> void:
	if not _initialized:
		return
	for record in _override_records:
		var node := _managed_mesh_node(record)
		if node == null or not node.get_instance().is_valid():
			continue
		var instance_rid := node.get_instance()
		RenderingServer.instance_geometry_set_material_override(instance_rid, RID())
		var clone_indices: PackedInt32Array = record["clone_indices"]
		for surface in clone_indices.size():
			var clone_index := clone_indices[surface]
			if clone_index >= 0 and clone_index < _material_clones.size():
				RenderingServer.instance_set_surface_override_material(
					instance_rid, surface, _material_clones[clone_index].get_rid())
	_sync_dirty_shader_state()
	_sync_live_primary_material_parameters()


func shutdown() -> void:
	_restore_overrides()
	_geometry_texture = null
	_instance_texture = null
	_shading_texture = null
	_albedo_texture = null
	_normal_texture = null
	_environment_texture = null
	_geometry_height = 0
	_instance_height = 0
	_shading_height = 0
	_texture_atlas_bytes = 0
	_environment_texture_bytes = 0
	_textures_dirty = false
	_material_clones.clear()
	_material_clone_by_source_id.clear()
	_override_records.clear()
	_material_sources.clear()
	_primary_material_records.clear()
	_managed_instances.clear()
	_receiver_light_starts.clear()
	_receiver_light_counts.clear()
	_receiver_light_indices.clear()
	_cached_instance_layers.clear()
	_receiver_light_revision = -1
	_geometry_layout = Vector4i.ZERO
	_geometry_counts = Vector4i.ZERO
	_instance_layout = Vector4i.ZERO
	_instance_count = 0
	_shading_layout = Vector4i.ZERO
	_shading_counts = Vector4i.ZERO
	_frame_settings = Vector4.ZERO
	_miss_color = Color.BLACK
	_fog_params = Vector4(0.0, 1.0, 1.0, 0.0)
	_ground_texture = null
	_ground_params = Vector4.ZERO
	_ground_bounds = Vector4.ZERO
	_ground_ambient = Color.BLACK
	_ground_grass = Vector4.ZERO
	_ground_sun_direction = Vector3.UP
	_ground_sun_radiance = Color.BLACK
	_ground_sun_enabled = false
	_environment_mode = 0
	_environment_inverse_basis = Basis.IDENTITY
	_environment_revision = -1
	_frame_uniforms_dirty = false
	_primary_instance_parameters_dirty = false
	_material_parameters_dirty = false
	_blas.clear()
	_tlas.clear()
	_bvh = null
	_software_shader = null
	_owner_node = null
	_initialized = false
	_topology_revision = -1
	_tlas_revision = -1
	_instance_revision = -1
	_material_revision = -1
	_light_revision = -1
	_settings_revision = -1


func get_profile_snapshot() -> Dictionary:
	return _profile.duplicate(true)


func _reset_profile() -> void:
	_profile = {
		"backend": "software",
		"blas_builds": 0,
		"tlas_builds": 0,
		"atlas_uploads": 0,
		"geometry_uploads": 0,
		"instance_uploads": 0,
		"shading_uploads": 0,
		"texture_atlas_bytes": 0,
		"environment_texture_bytes": 0,
		"environment_updates": 0,
		"environment_revision": 0,
		"environment_mode": 0,
		"environment_panorama_width": 0,
		"environment_panorama_height": 0,
		"texture_bytes": 0,
		"blas_nodes": 0,
		"tlas_nodes": 0,
		"triangles": 0,
		"max_receiver_lights": 0,
		"last_update_usec": 0,
		"peak_update_usec": 0,
		"blas_build_usec": 0,
		"tlas_build_usec": 0,
	}


func _consume_environment_snapshot(snapshot: Dictionary) -> String:
	var environment: Dictionary = snapshot.get("environment", {})
	if environment.is_empty():
		return "The software RT snapshot is missing its revisioned environment descriptor."
	var mode := int(environment.get("mode", 0))
	var panorama: Texture2D
	if mode == 1:
		var panorama_value: Variant = environment.get("panorama")
		if not panorama_value is Texture2D:
			return "PANORAMA reflection mode requires a valid linear panorama texture."
		panorama = panorama_value as Texture2D
		if (
				panorama == null
				or not is_instance_valid(panorama)
				or panorama.get_width() != int(environment.get("width", 0))
				or panorama.get_height() != int(environment.get("height", 0))
		):
			return "The software RT reflection panorama dimensions are invalid."
	elif mode != 0:
		return "Unknown software RT environment mode %d." % mode

	_environment_texture = panorama
	_environment_texture_bytes = int(environment.get("bytes", 0))
	_environment_mode = mode
	_miss_color = environment.get("fallback_linear", Color.BLACK)
	_environment_inverse_basis = environment.get("inverse_sky_basis", Basis.IDENTITY)
	_environment_revision = int(snapshot.get(
		"environment_revision", environment.get("revision", 0)))
	_textures_dirty = true
	_frame_uniforms_dirty = true
	_profile["environment_updates"] = int(_profile.get("environment_updates", 0)) + 1
	_profile["environment_revision"] = _environment_revision
	_profile["environment_mode"] = mode
	_profile["environment_panorama_width"] = int(environment.get("width", 0))
	_profile["environment_panorama_height"] = int(environment.get("height", 0))
	_profile["environment_texture_bytes"] = _environment_texture_bytes
	return ""


func _capture_shared_texture_atlases(snapshot: Dictionary) -> String:
	var albedo_value: Variant = snapshot.get("albedo_atlas")
	var normal_value: Variant = snapshot.get("normal_atlas")
	if not (albedo_value is Texture2D) or not (normal_value is Texture2D):
		return "The software RT backend requires valid shared albedo and normal texture atlases."
	_albedo_texture = albedo_value as Texture2D
	_normal_texture = normal_value as Texture2D
	if (
		_albedo_texture == null
		or _normal_texture == null
		or not is_instance_valid(_albedo_texture)
		or not is_instance_valid(_normal_texture)
		or _albedo_texture.get_width() <= 0
		or _albedo_texture.get_height() <= 0
		or _normal_texture.get_width() <= 0
		or _normal_texture.get_height() <= 0
	):
		return "The software RT backend received an empty or invalid shared texture atlas."
	_texture_atlas_bytes = maxi(0, int(snapshot.get("texture_atlas_bytes", 0)))
	_profile["texture_atlas_bytes"] = _texture_atlas_bytes
	return ""


func _validate_shared_texture_atlases(snapshot: Dictionary) -> String:
	var next_albedo := snapshot.get("albedo_atlas") as Texture2D
	var next_normal := snapshot.get("normal_atlas") as Texture2D
	if (
		next_albedo == null
		or next_normal == null
		or next_albedo != _albedo_texture
		or next_normal != _normal_texture
		or int(snapshot.get("texture_atlas_bytes", -1)) != _texture_atlas_bytes
	):
		return "Runtime texture-atlas changes require reinitializing the software RT backend."
	return ""


func _initialize_failed(reason: String) -> String:
	shutdown()
	return reason


func _build_and_upload_geometry_atlas() -> String:
	var nodes: Array = _blas.get("nodes", [])
	var meshes: Array = _blas.get("meshes", [])
	var triangles: Array = _blas.get("triangles", [])
	var node_base := 2
	var mesh_base := node_base + nodes.size() * 3
	var triangle_base := mesh_base + meshes.size()
	var required_texels := triangle_base + triangles.size() * TRIANGLE_TEXEL_STRIDE
	if required_texels > MAX_ATLAS_TEXELS:
		return _atlas_capacity_error(&"geometry", required_texels)
	var texels: Array[Vector4] = []
	texels.resize(required_texels)
	texels[0] = Vector4(GEOMETRY_MAGIC, float(node_base), float(mesh_base), float(triangle_base))
	texels[1] = Vector4(float(nodes.size()), float(meshes.size()), float(triangles.size()), ATLAS_VERSION)
	var error := _validate_exact_indices([node_base, mesh_base, triangle_base, nodes.size(), meshes.size(), triangles.size()], "geometry atlas header")
	if not error.is_empty():
		return error

	for i in nodes.size():
		var node: Dictionary = nodes[i]
		var base := node_base + i * 3
		var escape := int(node.get("escape", -1))
		var start := int(node.get("start", 0))
		var count := int(node.get("count", 0))
		error = _validate_exact_indices([base, escape, start, count], "BLAS node %d" % i, true)
		if not error.is_empty():
			return error
		var bounds_min: Vector3 = node.get("min", Vector3.ZERO)
		var bounds_max: Vector3 = node.get("max", Vector3.ZERO)
		texels[base] = Vector4(bounds_min.x, bounds_min.y, bounds_min.z, float(escape))
		texels[base + 1] = Vector4(bounds_max.x, bounds_max.y, bounds_max.z, 1.0 if bool(node.get("leaf", false)) else 0.0)
		texels[base + 2] = Vector4(float(start), float(count), 0.0, 0.0)

	for i in meshes.size():
		var mesh: Dictionary = meshes[i]
		var root := int(mesh.get("root", -1))
		var node_count := int(mesh.get("node_count", 0))
		var surface_count := int(mesh.get("surface_count", 0))
		error = _validate_exact_indices([root, node_count, surface_count], "mesh record %d" % i, true)
		if not error.is_empty():
			return error
		texels[mesh_base + i] = Vector4(float(root), float(surface_count), float(node_count), 0.0)

	for i in triangles.size():
		var triangle: Dictionary = triangles[i]
		var base := triangle_base + i * TRIANGLE_TEXEL_STRIDE
		var v0: Vector3 = triangle.get("v0", Vector3.ZERO)
		var v1: Vector3 = triangle.get("v1", Vector3.ZERO)
		var v2: Vector3 = triangle.get("v2", Vector3.ZERO)
		var n0: Vector3 = triangle.get("n0", Vector3.UP)
		var n1: Vector3 = triangle.get("n1", Vector3.UP)
		var n2: Vector3 = triangle.get("n2", Vector3.UP)
		var uv0: Vector2 = triangle.get("uv0", Vector2.ZERO)
		var uv1: Vector2 = triangle.get("uv1", Vector2.ZERO)
		var uv2: Vector2 = triangle.get("uv2", Vector2.ZERO)
		var surface := int(triangle.get("surface", 0))
		var source_triangle := int(triangle.get("source_triangle", i))
		error = _validate_exact_indices([surface, source_triangle], "triangle record %d" % i)
		if not error.is_empty():
			return error
		texels[base] = Vector4(v0.x, v0.y, v0.z, float(surface))
		texels[base + 1] = Vector4(v1.x, v1.y, v1.z, float(source_triangle))
		texels[base + 2] = Vector4(v2.x, v2.y, v2.z, 0.0)
		texels[base + 3] = Vector4(n0.x, n0.y, n0.z, 0.0)
		texels[base + 4] = Vector4(n1.x, n1.y, n1.z, 0.0)
		texels[base + 5] = Vector4(n2.x, n2.y, n2.z, 0.0)
		texels[base + 6] = Vector4(uv0.x, uv0.y, uv1.x, uv1.y)
		texels[base + 7] = Vector4(uv2.x, uv2.y, 0.0, 0.0)
	var upload_error := _upload_atlas(&"geometry", texels)
	if upload_error.is_empty():
		_geometry_layout = Vector4i(node_base, mesh_base, triangle_base, 0)
		_geometry_counts = Vector4i(nodes.size(), meshes.size(), triangles.size(), int(ATLAS_VERSION))
		_frame_uniforms_dirty = true
	return upload_error


func _rebuild_tlas(snapshot: Dictionary) -> String:
	var transforms: Array[Transform3D] = snapshot.get("transforms", [])
	var instances: Array = snapshot.get("instances", [])
	var masks: PackedInt32Array = snapshot.get("instance_masks", PackedInt32Array())
	if transforms.size() != instances.size() or masks.size() != instances.size():
		return "Software TLAS inputs have inconsistent instance counts."
	_tlas = _bvh.call("build_tlas", _blas.get("meshes", []), instances, transforms, masks) as Dictionary
	if not bool(_tlas.get("ok", false)):
		return String(_tlas.get("error", "Software TLAS construction failed."))
	var node_count := (_tlas.get("nodes", []) as Array).size()
	if node_count > 4096:
		return "Software TLAS has %d nodes; the Compatibility/Web limit is 4096." % node_count
	_profile["tlas_builds"] = int(_profile["tlas_builds"]) + 1
	_profile["tlas_build_usec"] = int(round(float(_tlas.get("build_seconds", 0.0)) * 1000000.0))
	_profile["tlas_nodes"] = node_count
	return ""


func _has_shared_receiver_light_lists(snapshot: Dictionary) -> bool:
	return (
		snapshot.has("receiver_light_starts")
		and snapshot.has("receiver_light_counts")
		and snapshot.has("receiver_light_indices")
	)


func _consume_receiver_light_lists(snapshot: Dictionary) -> String:
	if not _has_shared_receiver_light_lists(snapshot):
		return _rebuild_receiver_light_lists(snapshot)
	var instances: Array = snapshot.get("instances", [])
	var layers: PackedInt32Array = snapshot.get("instance_layers", PackedInt32Array())
	var starts: PackedInt32Array = snapshot.get("receiver_light_starts", PackedInt32Array())
	var counts: PackedInt32Array = snapshot.get("receiver_light_counts", PackedInt32Array())
	var indices: PackedInt32Array = snapshot.get("receiver_light_indices", PackedInt32Array())
	var light_snapshot: Dictionary = snapshot.get("light", {})
	var lights: Array = light_snapshot.get("records", [])
	if lights.size() > MAX_TOTAL_LIGHTS:
		return "The software RT backend supports at most %d active lights (received %d)." % [MAX_TOTAL_LIGHTS, lights.size()]
	if layers.size() != instances.size() or starts.size() != instances.size() or counts.size() != instances.size():
		return "Shared software receiver-light-list inputs have inconsistent instance counts."
	if (indices.size() & 3) != 0:
		return "Shared software receiver-light indices must be padded to complete vec4 texels."
	var maximum := 0
	for instance_index in instances.size():
		var start := starts[instance_index]
		var count := counts[instance_index]
		if start < 0 or (start & 3) != 0 or count < 0 or start + count > indices.size():
			return "Shared receiver light range %d is invalid or is not vec4-aligned." % instance_index
		maximum = maxi(maximum, count)
		var matching_names := PackedStringArray()
		var seen := {}
		for receiver_offset in count:
			var light_index := indices[start + receiver_offset]
			if light_index < 0 or light_index >= lights.size():
				return "Shared receiver light range %d contains invalid light index %d." % [instance_index, light_index]
			if seen.has(light_index):
				return "Shared receiver light range %d contains duplicate light index %d." % [instance_index, light_index]
			seen[light_index] = true
			var light: Dictionary = lights[light_index]
			matching_names.append(String(light.get("path", light.get("name", "light %d" % light_index))))
		if count > _max_lights_per_receiver:
			var instance_name := _instance_display_name(instance_index)
			return "%s is affected by %d lights, exceeding software_max_lights_per_receiver (%d): %s" % [
				instance_name, count, _max_lights_per_receiver, ", ".join(matching_names)]
	_receiver_light_starts = starts.duplicate()
	_receiver_light_counts = counts.duplicate()
	_receiver_light_indices = indices.duplicate()
	_cached_instance_layers = layers.duplicate()
	_profile["max_receiver_lights"] = maximum
	_primary_instance_parameters_dirty = true
	return _validate_exact_indices(
		[_receiver_light_indices.size(), maximum], "shared receiver light lists")


func _rebuild_receiver_light_lists(snapshot: Dictionary) -> String:
	var instances: Array = snapshot.get("instances", [])
	var layers: PackedInt32Array = snapshot.get("instance_layers", PackedInt32Array())
	var light_snapshot: Dictionary = snapshot.get("light", {})
	var lights: Array = light_snapshot.get("records", [])
	if lights.size() > MAX_TOTAL_LIGHTS:
		return "The software RT backend supports at most %d active lights (received %d)." % [MAX_TOTAL_LIGHTS, lights.size()]
	if layers.size() != instances.size():
		return "Software light-list inputs have inconsistent instance counts."
	_receiver_light_starts.resize(instances.size())
	_receiver_light_counts.resize(instances.size())
	_receiver_light_indices.clear()
	var maximum := 0
	for instance_index in instances.size():
		while (_receiver_light_indices.size() & 3) != 0:
			_receiver_light_indices.append(-1)
		_receiver_light_starts[instance_index] = _receiver_light_indices.size()
		var matching_names := PackedStringArray()
		for light_index in lights.size():
			var light: Dictionary = lights[light_index]
			if (int(light.get("cull_mask", 0)) & layers[instance_index]) == 0:
				continue
			_receiver_light_indices.append(light_index)
			matching_names.append(String(light.get("path", light.get("name", "light %d" % light_index))))
		var count := _receiver_light_indices.size() - _receiver_light_starts[instance_index]
		_receiver_light_counts[instance_index] = count
		maximum = maxi(maximum, count)
		if count > _max_lights_per_receiver:
			var instance_name := "instance %d" % instance_index
			if instance_index < _managed_instances.size():
				var node := _managed_mesh_node(_managed_instances[instance_index])
				if node:
					instance_name = String(node.get_path())
			return "%s is affected by %d lights, exceeding software_max_lights_per_receiver (%d): %s" % [
				instance_name, count, _max_lights_per_receiver, ", ".join(matching_names)]
	while (_receiver_light_indices.size() & 3) != 0:
		_receiver_light_indices.append(-1)
	_profile["max_receiver_lights"] = maximum
	_cached_instance_layers = layers.duplicate()
	_primary_instance_parameters_dirty = true
	return _validate_exact_indices(
		[_receiver_light_indices.size(), maximum], "receiver light lists")


func _build_and_upload_instance_atlas(snapshot: Dictionary) -> String:
	var tlas_nodes: Array = _tlas.get("nodes", [])
	var instances: Array = snapshot.get("instances", [])
	var transforms: Array[Transform3D] = snapshot.get("transforms", [])
	var masks: PackedInt32Array = snapshot.get("instance_masks", PackedInt32Array())
	var layers: PackedInt32Array = snapshot.get("instance_layers", PackedInt32Array())
	if transforms.size() != instances.size() or masks.size() != instances.size() or layers.size() != instances.size():
		return "Software instance-atlas inputs have inconsistent counts."
	var node_base := 2
	var record_base := node_base + tlas_nodes.size() * 3
	var required_texels := record_base + instances.size() * 8
	if required_texels > MAX_ATLAS_TEXELS:
		return _atlas_capacity_error(&"instance", required_texels)
	var texels: Array[Vector4] = []
	texels.resize(required_texels)
	texels[0] = Vector4(INSTANCE_MAGIC, float(node_base), float(record_base), ATLAS_VERSION)
	texels[1] = Vector4(float(tlas_nodes.size()), float(instances.size()), float(_tlas.get("root", -1)), 0.0)
	var error := _validate_exact_indices([node_base, record_base, instances.size(), tlas_nodes.size(), int(_tlas.get("root", -1))], "instance atlas header", true)
	if not error.is_empty():
		return error

	for i in tlas_nodes.size():
		var node: Dictionary = tlas_nodes[i]
		var base := node_base + i * 3
		var escape := int(node.get("escape", -1))
		var start := int(node.get("start", 0))
		var count := int(node.get("count", 0))
		var mask := int(node.get("mask", 0))
		var leaf := bool(node.get("leaf", false))
		var kind_and_mask := (mask & TLAS_MASK_BITS) | (TLAS_LEAF_BIT if leaf else 0)
		error = _validate_exact_indices([base, escape, start, count, mask, kind_and_mask], "TLAS node %d" % i, true)
		if not error.is_empty():
			return error
		if mask <= 0 or (mask & ~TLAS_MASK_BITS) != 0:
			return "TLAS node %d has an invalid traversal-mask union (%d)." % [i, mask]
		var bounds_min: Vector3 = node.get("min", Vector3.ZERO)
		var bounds_max: Vector3 = node.get("max", Vector3.ZERO)
		texels[base] = Vector4(bounds_min.x, bounds_min.y, bounds_min.z, float(escape))
		texels[base + 1] = Vector4(bounds_max.x, bounds_max.y, bounds_max.z, float(kind_and_mask))
		texels[base + 2] = Vector4(float(start), float(count), float(node.get("mask", 0)), 0.0)

	for i in instances.size():
		var instance: Dictionary = instances[i]
		var transform := transforms[i]
		if absf(transform.basis.determinant()) <= 0.00000001:
			return "Software RT cannot invert the transform of %s." % _instance_display_name(i)
		var inverse := transform.affine_inverse()
		var normal_basis := transform.basis.inverse().transposed()
		var geometry := int(instance.get("geometry", -1))
		var material_base := int(instance.get("material_base", 0))
		var surface_count := int(instance.get("surface_count", 0))
		error = _validate_exact_indices([
			geometry, material_base, surface_count, masks[i], layers[i],
			_receiver_light_starts[i], _receiver_light_counts[i]], "instance record %d" % i, true)
		if not error.is_empty():
			return error
		var base := record_base + i * 8
		texels[base] = Vector4(float(geometry), float(material_base), float(layers[i]), float(masks[i]))
		texels[base + 1] = Vector4(float(_receiver_light_starts[i]), float(_receiver_light_counts[i]), float(surface_count), 0.0)
		texels[base + 2] = Vector4(inverse.basis.x.x, inverse.basis.x.y, inverse.basis.x.z, inverse.origin.x)
		texels[base + 3] = Vector4(inverse.basis.y.x, inverse.basis.y.y, inverse.basis.y.z, inverse.origin.y)
		texels[base + 4] = Vector4(inverse.basis.z.x, inverse.basis.z.y, inverse.basis.z.z, inverse.origin.z)
		texels[base + 5] = Vector4(normal_basis.x.x, normal_basis.x.y, normal_basis.x.z, 0.0)
		texels[base + 6] = Vector4(normal_basis.y.x, normal_basis.y.y, normal_basis.y.z, 0.0)
		texels[base + 7] = Vector4(normal_basis.z.x, normal_basis.z.y, normal_basis.z.z, 0.0)
	var upload_error := _upload_atlas(&"instance", texels)
	if upload_error.is_empty():
		_instance_layout = Vector4i(node_base, record_base, tlas_nodes.size(), int(_tlas.get("root", -1)))
		_instance_count = instances.size()
		_frame_uniforms_dirty = true
		_primary_instance_parameters_dirty = true
	return upload_error


func _build_and_upload_shading_atlas(snapshot: Dictionary) -> String:
	var instance_materials: PackedInt32Array = snapshot.get("instance_material_indices", PackedInt32Array())
	var materials: Array = snapshot.get("material_records", [])
	var light_snapshot: Dictionary = snapshot.get("light", {})
	var lights: Array = light_snapshot.get("records", [])
	var map_texel_count := ceili(float(instance_materials.size()) / 4.0)
	var list_texel_count := ceili(float(_receiver_light_indices.size()) / 4.0)
	var map_base := 4
	var material_base := map_base + map_texel_count
	var light_base := material_base + materials.size() * MATERIAL_TEXEL_STRIDE
	var list_base := light_base + lights.size() * 4
	var required_texels := list_base + list_texel_count
	if required_texels > MAX_ATLAS_TEXELS:
		return _atlas_capacity_error(&"shading", required_texels)
	var texels: Array[Vector4] = []
	texels.resize(required_texels)
	var environment_snapshot: Dictionary = snapshot.get("environment", {})
	var miss: Color = environment_snapshot.get("fallback_linear", Color.BLACK)
	texels[0] = Vector4(SHADING_MAGIC, float(map_base), float(material_base), float(light_base))
	texels[1] = Vector4(float(list_base), float(instance_materials.size()), float(materials.size()), float(lights.size()))
	texels[2] = Vector4(float(snapshot.get("bias", 0.001)), float(snapshot.get("max_distance", 10000.0)), float(_max_lights_per_receiver), ATLAS_VERSION)
	texels[3] = Vector4(miss.r, miss.g, miss.b, miss.a)
	var error := _validate_exact_indices([
		map_base, material_base, light_base, list_base, instance_materials.size(),
		materials.size(), lights.size(), _receiver_light_indices.size()], "shading atlas header")
	if not error.is_empty():
		return error

	for texel_index in map_texel_count:
		var values := Vector4(-1.0, -1.0, -1.0, -1.0)
		for lane in 4:
			var source_index := texel_index * 4 + lane
			if source_index < instance_materials.size():
				var value := instance_materials[source_index]
				error = _validate_exact_indices([value], "instance-material index %d" % source_index)
				if not error.is_empty():
					return error
				values[lane] = float(value)
		texels[map_base + texel_index] = values

	for i in materials.size():
		var material: Dictionary = materials[i]
		var diffuse: Color = material.get("diffuse", Color.WHITE)
		var ambient: Color = material.get("ambient", Color.BLACK)
		var emission: Color = material.get("emission", Color.BLACK)
		var specular: Color = material.get("specular", Color.WHITE)
		var albedo_region: Vector4 = material.get("albedo_region", Vector4.ZERO)
		var normal_region: Vector4 = material.get("normal_region", Vector4.ZERO)
		var triplanar_scale: Vector3 = material.get("triplanar_scale", Vector3.ONE)
		var triplanar_offset: Vector3 = material.get("triplanar_offset", Vector3.ZERO)
		var flags := 0
		if bool(material.get("has_albedo", false)):
			flags |= 1
		if bool(material.get("has_normal", false)):
			flags |= 2
		if bool(material.get("triplanar_enabled", false)):
			flags |= 4
		if bool(material.get("triplanar_world_space", false)):
			flags |= 8
		var base := material_base + i * MATERIAL_TEXEL_STRIDE
		texels[base] = Vector4(diffuse.r, diffuse.g, diffuse.b, float(material.get("shininess", 40.0)))
		texels[base + 1] = Vector4(ambient.r, ambient.g, ambient.b, float(material.get("direct_intensity", 1.0)))
		texels[base + 2] = Vector4(
			emission.r,
			emission.g,
			emission.b,
			1.0 if bool(material.get("reflection_shadows_enabled", false)) else 0.0)
		texels[base + 3] = Vector4(specular.r, specular.g, specular.b, float(flags))
		texels[base + 4] = albedo_region
		texels[base + 5] = normal_region
		texels[base + 6] = Vector4(
			triplanar_scale.x,
			triplanar_scale.y,
			triplanar_scale.z,
			float(material.get("triplanar_sharpness", 1.0)))
		texels[base + 7] = Vector4(
			triplanar_offset.x, triplanar_offset.y, triplanar_offset.z, 0.0)

	for i in lights.size():
		var light: Dictionary = lights[i]
		var position: Vector3 = light.get("position", Vector3.ZERO)
		var direction: Vector3 = light.get("direction", Vector3.ZERO)
		var color: Color = light.get("color", Color.BLACK)
		var cull_mask := int(light.get("cull_mask", 0))
		error = _validate_exact_indices([int(light.get("type", -1)), cull_mask], "light record %d" % i, true)
		if not error.is_empty():
			return error
		var base := light_base + i * 4
		texels[base] = Vector4(position.x, position.y, position.z, float(light.get("type", -1)))
		texels[base + 1] = Vector4(direction.x, direction.y, direction.z, float(light.get("range", 0.0)))
		texels[base + 2] = Vector4(color.r, color.g, color.b, float(light.get("attenuation", 1.0)))
		texels[base + 3] = Vector4(float(light.get("cone_cosine", -1.0)), float(light.get("cone_attenuation", 1.0)), 1.0 if bool(light.get("rt_shadow", false)) else 0.0, float(cull_mask))

	for texel_index in list_texel_count:
		var values := Vector4(-1.0, -1.0, -1.0, -1.0)
		for lane in 4:
			var source_index := texel_index * 4 + lane
			if source_index < _receiver_light_indices.size():
				values[lane] = float(_receiver_light_indices[source_index])
		texels[list_base + texel_index] = values
	var upload_error := _upload_atlas(&"shading", texels)
	if upload_error.is_empty():
		_shading_layout = Vector4i(map_base, material_base, light_base, list_base)
		_shading_counts = Vector4i(
			instance_materials.size(), materials.size(), lights.size(), _max_lights_per_receiver)
		_frame_settings = Vector4(
			float(snapshot.get("bias", 0.001)),
			float(snapshot.get("max_distance", 10000.0)),
			float(_max_lights_per_receiver),
			ATLAS_VERSION)
		_miss_color = miss
		_frame_uniforms_dirty = true
	return upload_error


func _upload_atlas(kind: StringName, texels: Array[Vector4]) -> String:
	var required_height := maxi(1, ceili(float(texels.size()) / float(ATLAS_WIDTH)))
	var retained_height := 0
	match kind:
		&"geometry":
			retained_height = _geometry_height
		&"instance":
			retained_height = _instance_height
		&"shading":
			retained_height = _shading_height
		_:
			return "Unknown software RT atlas kind: %s." % kind
	# Atlas capacity only grows. This keeps ImageTexture RIDs stable when a
	# moving/hidden instance or a light-list change temporarily needs less data.
	var height := maxi(1, retained_height)
	while height < required_height:
		height <<= 1
	if height > MAX_ATLAS_HEIGHT:
		return "%s atlas requires %d rows; the Compatibility/Web limit is %d (%d x %d RGBAF)." % [
			String(kind).capitalize(), required_height, MAX_ATLAS_HEIGHT, ATLAS_WIDTH, MAX_ATLAS_HEIGHT]
	var floats := PackedFloat32Array()
	floats.resize(ATLAS_WIDTH * height * 4)
	for i in texels.size():
		var value := texels[i]
		var offset := i * 4
		floats[offset] = value.x
		floats[offset + 1] = value.y
		floats[offset + 2] = value.z
		floats[offset + 3] = value.w
	var image := Image.create_from_data(ATLAS_WIDTH, height, false, Image.FORMAT_RGBAF, floats.to_byte_array())
	if image == null or image.is_empty():
		return "Godot could not create the %s RGBAF atlas image." % kind

	match kind:
		&"geometry":
			if _geometry_texture and _geometry_height == height:
				_geometry_texture.update(image)
			else:
				_geometry_texture = ImageTexture.create_from_image(image)
				_textures_dirty = true
			_geometry_height = height
			_profile["geometry_uploads"] = int(_profile["geometry_uploads"]) + 1
		&"instance":
			if _instance_texture and _instance_height == height:
				_instance_texture.update(image)
			else:
				_instance_texture = ImageTexture.create_from_image(image)
				_textures_dirty = true
			_instance_height = height
			_profile["instance_uploads"] = int(_profile["instance_uploads"]) + 1
		&"shading":
			if _shading_texture and _shading_height == height:
				_shading_texture.update(image)
			else:
				_shading_texture = ImageTexture.create_from_image(image)
				_textures_dirty = true
			_shading_height = height
			_profile["shading_uploads"] = int(_profile["shading_uploads"]) + 1
	_profile["atlas_uploads"] = int(_profile["atlas_uploads"]) + 1
	return ""


func _atlas_capacity_error(kind: StringName, texel_count: int) -> String:
	return "%s atlas requires %d texels; the Compatibility/Web limit is %d (%d x %d RGBAF)." % [
		String(kind).capitalize(), texel_count, MAX_ATLAS_TEXELS, ATLAS_WIDTH, MAX_ATLAS_HEIGHT]


func _validate_exact_indices(values: Array, context: String, allow_negative_one: bool = false) -> String:
	for value_variant in values:
		var value := int(value_variant)
		if value == -1 and allow_negative_one:
			continue
		if value < 0 or value >= MAX_EXACT_FLOAT_INTEGER:
			return "%s contains index %d, outside the exact RGBAF integer range [0, %d)." % [context, value, MAX_EXACT_FLOAT_INTEGER]
	return ""


func _create_material_clones() -> String:
	_material_clones.clear()
	_material_clone_by_source_id.clear()
	for i in _material_sources.size():
		var source := _material_sources[i]
		if source == null or not is_instance_valid(source):
			return "Managed software RT material %d is no longer valid." % i
		var clone := ShaderMaterial.new()
		clone.shader = _software_shader
		clone.resource_name = "%s (Software RT)" % source.resource_name
		_material_clones.append(clone)
		_material_clone_by_source_id[source.get_instance_id()] = i
	_sync_material_parameters()
	_bind_atlases_to_materials()
	_sync_frame_uniforms()
	return ""


func _sync_material_parameters() -> void:
	for i in mini(_material_sources.size(), _material_clones.size()):
		var source := _material_sources[i]
		var clone := _material_clones[i]
		if source == null or clone == null or not is_instance_valid(source):
			continue
		for parameter in PUBLIC_MATERIAL_PARAMETERS:
			var source_value: Variant = source.get_shader_parameter(parameter)
			# NIL means the authored resource is using the shader declaration
			# default. Clear any prior clone override too, which matters when a
			# live value is programmatically reverted to its default.
			if source_value == null:
				if clone.get_shader_parameter(parameter) != null:
					clone.set_shader_parameter(parameter, null)
				continue
			if clone.get_shader_parameter(parameter) != source_value:
				clone.set_shader_parameter(parameter, source_value)
		var has_albedo := source.get_shader_parameter(&"albedo_texture") is Texture2D
		var has_normal := source.get_shader_parameter(&"normal_texture") is Texture2D
		clone.set_shader_parameter(
			&"swrt_compatibility_output",
			RenderingServer.get_current_rendering_method() == "gl_compatibility")
		if clone.get_shader_parameter(&"rt_has_albedo_texture") != has_albedo:
			clone.set_shader_parameter(&"rt_has_albedo_texture", has_albedo)
		if clone.get_shader_parameter(&"rt_has_normal_texture") != has_normal:
			clone.set_shader_parameter(&"rt_has_normal_texture", has_normal)
		if clone.render_priority != source.render_priority:
			clone.render_priority = source.render_priority
		var current_material_id: Variant = clone.get_shader_parameter(&"rt_material_id")
		if not current_material_id is int or current_material_id != i + 1:
			clone.set_shader_parameter(&"rt_material_id", i + 1)
		if i < _primary_material_records.size():
			var primary_record: Dictionary = _primary_material_records[i]
			var primary_diffuse: Color = primary_record.get("diffuse", Color.WHITE)
			var primary_ambient: Color = primary_record.get("ambient", Color.BLACK)
			var primary_emission: Color = primary_record.get("emission", Color.BLACK)
			var primary_specular: Color = primary_record.get("specular", Color.WHITE)
			var primary_values := {
				&"swrt_primary_shininess": float(primary_record.get("shininess", 40.0)),
				&"swrt_primary_diffuse_color": Vector3(
					primary_diffuse.r, primary_diffuse.g, primary_diffuse.b),
				&"swrt_primary_ambient_color": Vector3(
					primary_ambient.r, primary_ambient.g, primary_ambient.b),
				&"swrt_primary_emission_color": Vector3(
					primary_emission.r, primary_emission.g, primary_emission.b),
				&"swrt_primary_specular_color": Vector3(
					primary_specular.r, primary_specular.g, primary_specular.b),
				&"swrt_primary_direct_specular_intensity": float(primary_record.get("direct_intensity", 1.0)),
				&"swrt_primary_reflection_shadows_enabled": bool(primary_record.get("reflection_shadows_enabled", false)),
			}
			for parameter in primary_values:
				if clone.get_shader_parameter(parameter) != primary_values[parameter]:
					clone.set_shader_parameter(parameter, primary_values[parameter])
	_material_parameters_dirty = false


func _sync_live_primary_material_parameters() -> void:
	# Mirror enable/strength deliberately do not participate in the manager's
	# terminal-hit material revision: the hardware backend transports them in
	# its raster buffers. Keep the equivalent software raster uniforms live with
	# a tiny per-frame sync while all atlas-backed parameters remain revisioned.
	for i in mini(_material_sources.size(), _material_clones.size()):
		var source := _material_sources[i]
		var clone := _material_clones[i]
		if source == null or clone == null or not is_instance_valid(source):
			continue
		for parameter in [&"mirror_enabled", &"reflection_strength"]:
			var source_value: Variant = source.get_shader_parameter(parameter)
			if clone.get_shader_parameter(parameter) != source_value:
				clone.set_shader_parameter(parameter, source_value)
		# Material priority is renderer state rather than part of the RT material
		# table, but it remains authored and can be changed independently.
		if clone.render_priority != source.render_priority:
			clone.render_priority = source.render_priority


func _sync_frame_uniforms() -> void:
	for clone in _material_clones:
		if clone == null:
			continue
		clone.set_shader_parameter(&"swrt_geometry_layout", _geometry_layout)
		clone.set_shader_parameter(&"swrt_geometry_counts", _geometry_counts)
		clone.set_shader_parameter(&"swrt_instance_layout", _instance_layout)
		clone.set_shader_parameter(&"swrt_instance_count", _instance_count)
		clone.set_shader_parameter(&"swrt_shading_layout", _shading_layout)
		clone.set_shader_parameter(&"swrt_shading_counts", _shading_counts)
		clone.set_shader_parameter(&"swrt_frame_settings", _frame_settings)
		clone.set_shader_parameter(&"swrt_miss_color", _miss_color)
		clone.set_shader_parameter(&"swrt_fog_params", _fog_params)
		clone.set_shader_parameter(&"swrt_ground_params", _ground_params)
		clone.set_shader_parameter(&"swrt_ground_bounds", _ground_bounds)
		clone.set_shader_parameter(&"swrt_ground_ambient", _ground_ambient)
		clone.set_shader_parameter(&"swrt_ground_grass", _ground_grass)
		clone.set_shader_parameter(&"swrt_ground_sun_direction", Vector4(
			_ground_sun_direction.x,
			_ground_sun_direction.y,
			_ground_sun_direction.z,
			1.0 if _ground_sun_enabled else 0.0))
		clone.set_shader_parameter(&"swrt_ground_sun_radiance", _ground_sun_radiance)
		clone.set_shader_parameter(&"swrt_environment_mode", _environment_mode)
		clone.set_shader_parameter(&"swrt_environment_basis_x", _environment_inverse_basis.x)
		clone.set_shader_parameter(&"swrt_environment_basis_y", _environment_inverse_basis.y)
		clone.set_shader_parameter(&"swrt_environment_basis_z", _environment_inverse_basis.z)
	_frame_uniforms_dirty = false


func _sync_primary_instance_parameters() -> void:
	if (
			_override_records.size() != _cached_instance_layers.size()
			or _override_records.size() != _receiver_light_starts.size()
			or _override_records.size() != _receiver_light_counts.size()
	):
		return
	for record in _override_records:
		var node := _managed_mesh_node(record)
		if node == null or not node.get_instance().is_valid():
			continue
		var instance_index := int(record["instance_index"])
		var instance_rid := node.get_instance()
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RT_RECEIVER_LAYERS_PARAMETER, _cached_instance_layers[instance_index])
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RT_RECEIVER_LIGHT_START_PARAMETER, _receiver_light_starts[instance_index])
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RT_RECEIVER_LIGHT_COUNT_PARAMETER, _receiver_light_counts[instance_index])
	_primary_instance_parameters_dirty = false


func _sync_dirty_shader_state() -> void:
	if _material_parameters_dirty:
		_sync_material_parameters()
	if _frame_uniforms_dirty:
		_sync_frame_uniforms()
	if _primary_instance_parameters_dirty:
		_sync_primary_instance_parameters()


func _bind_atlases_to_materials() -> void:
	for clone in _material_clones:
		if clone == null:
			continue
		clone.set_shader_parameter(&"swrt_geometry_atlas", _geometry_texture)
		clone.set_shader_parameter(&"swrt_instance_atlas", _instance_texture)
		clone.set_shader_parameter(&"swrt_shading_atlas", _shading_texture)
		clone.set_shader_parameter(&"swrt_albedo_atlas", _albedo_texture)
		clone.set_shader_parameter(&"swrt_normal_atlas", _normal_texture)
		clone.set_shader_parameter(&"swrt_environment_panorama", _environment_texture)
		clone.set_shader_parameter(&"swrt_ground_map", _ground_texture)
	_textures_dirty = false


func _capture_and_apply_overrides() -> String:
	_override_records.clear()
	for instance_index in _managed_instances.size():
		var append_error := _append_override_record(instance_index)
		if not append_error.is_empty():
			return append_error
	_initialized = true
	reassert_overrides()
	return ""


func _append_override_record(instance_index: int) -> String:
	var item: Dictionary = _managed_instances[instance_index]
	if bool(item.get("receiver_tombstone", false)):
		_override_records.append({
			"node": null,
			"instance_index": instance_index,
			"surface_overrides": [],
			"clone_indices": PackedInt32Array(),
			"instance_id_value": 0,
		})
		return ""
	var node := _managed_mesh_node(item)
	if node == null or not node.get_instance().is_valid():
		return "Managed software RT instance %d is no longer valid." % instance_index
	var surface_count := int(item.get(
		"surface_count", node.mesh.get_surface_count() if node.mesh else 0))
	var original_surfaces: Array[Material] = []
	var clone_indices := PackedInt32Array()
	clone_indices.resize(surface_count)
	for surface in surface_count:
		original_surfaces.append(node.get_surface_override_material(surface))
		var active := node.get_active_material(surface) as ShaderMaterial
		if active == null or not _material_clone_by_source_id.has(active.get_instance_id()):
			return "Could not map %s surface %d to a software RT material clone." % [
				node.get_path(), surface]
		clone_indices[surface] = int(
			_material_clone_by_source_id[active.get_instance_id()])
	_override_records.append({
		"node": node,
		"instance_index": instance_index,
		"material_override": node.material_override,
		"surface_overrides": original_surfaces,
		"clone_indices": clone_indices,
		# This uniform is owned by the RT implementation. RTSceneManager also
		# restores it to the authored/default value during backend teardown.
		"instance_id_value": 0,
	})
	return ""


func _restore_overrides() -> void:
	for record in _override_records:
		var node := _managed_mesh_node(record)
		if node == null or not node.get_instance().is_valid():
			continue
		var instance_rid := node.get_instance()
		var surfaces: Array = record.get("surface_overrides", [])
		for surface in surfaces.size():
			var material := surfaces[surface] as Material
			RenderingServer.instance_set_surface_override_material(
				instance_rid, surface, material.get_rid() if material else RID())
		var overall := record.get("material_override") as Material
		RenderingServer.instance_geometry_set_material_override(
			instance_rid, overall.get_rid() if overall else RID())
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RT_INSTANCE_ID_PARAMETER, record.get("instance_id_value", 0))
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RT_RECEIVER_LAYERS_PARAMETER, 0)
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RT_RECEIVER_LIGHT_START_PARAMETER, 0)
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RT_RECEIVER_LIGHT_COUNT_PARAMETER, 0)


func _instance_display_name(index: int) -> String:
	if index >= 0 and index < _managed_instances.size():
		var node := _managed_mesh_node(_managed_instances[index])
		if node:
			return String(node.get_path())
	return "instance %d" % index


func _managed_mesh_node(item: Dictionary) -> MeshInstance3D:
	# `as` raises "Trying to cast a freed object" before is_instance_valid() can
	# guard it, so the stored Variant is validated before it is cast. Deleting a
	# managed mesh is routine while the editor preview is installed.
	var node_value: Variant = item.get("node")
	if not is_instance_valid(node_value):
		return null
	return node_value as MeshInstance3D


func _packed_int_arrays_equal(left: PackedInt32Array, right: PackedInt32Array) -> bool:
	if left.size() != right.size():
		return false
	for i in left.size():
		if left[i] != right[i]:
			return false
	return true


func _update_texture_byte_profile() -> void:
	_profile["texture_atlas_bytes"] = _texture_atlas_bytes
	_profile["environment_texture_bytes"] = _environment_texture_bytes
	_profile["texture_bytes"] = (
		ATLAS_WIDTH * (_geometry_height + _instance_height + _shading_height) * 16
		+ _texture_atlas_bytes
		+ _environment_texture_bytes
	)
