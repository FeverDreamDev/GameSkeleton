@tool
extends CompositorEffect
class_name RTLightingEffect

## Full-resolution one-bounce RT compositor. The shader is imported as an
## RDShaderFile so pipeline creation remains renderer-owned and cached.

const RT_SHADER_PATH := "res://addons/retro_rt/shaders/rt_shadow_reflect.glsl"
const RT_SHADER_VERSION_NATIVE := &"native"
const POSITION_STRIDE := 16
const UV_STRIDE := 8
const INDEX_STRIDE := 4
const INSTANCE_RECORD_SIZE := 64
const MATERIAL_RECORD_SIZE := 128
const MAX_LIGHT_RECORDS := 256
# std140 FrameData is mat4 + 16 vec4 = 20 vec4. Keep in step with the FrameData
# block in rt_shadow_reflect.glsl; a mismatch fails loudly in _update_frame_ubo.
const FRAME_UBO_FLOATS := 80

const PROFILE_TLAS_BEGIN := "RetroRT/TLAS begin"
const PROFILE_TLAS_END := "RetroRT/TLAS end"
const PROFILE_DISPATCH_BEGIN := "RetroRT/Dispatch begin"
const PROFILE_DISPATCH_END := "RetroRT/Dispatch end"

var _shutdown_started := false
var snapshot_bridge
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var hit_sbt: RID
var hit_sbt_range: int = -1
var tlas: RID
var sampler: RID
var atlas_sampler: RID
var frame_ubo: RID
var position_buffer: RID
var normal_buffer: RID
var uv_buffer: RID
var index_storage_buffer: RID
var geometry_buffer: RID
var instance_buffer: RID
var material_buffer: RID
var light_buffer: RID
var triangle_surface_buffer: RID
var instance_material_buffer: RID
var receiver_light_start_buffer: RID
var receiver_light_count_buffer: RID
var receiver_light_index_buffer: RID
var albedo_atlas_texture: RID
var normal_atlas_texture: RID
var environment_texture: RID
var _albedo_atlas_resource: Texture2D
var _normal_atlas_resource: Texture2D
var _environment_resource: Texture2D
var _initialized := false
var _failed := false
var _last_tlas_revision := -1
var _last_instance_revision := -1
var _last_material_revision := -1
var _last_light_revision := -1
var _last_environment_revision := -1
var _last_receiver_light_revision := -1
var _environment_texture_bindings := 0
var _instance_buffer_capacity := 0
var _material_buffer_capacity := 0
var _instance_material_buffer_capacity := 0
var _light_buffer_capacity := 0
var _receiver_light_start_capacity := 0
var _receiver_light_count_capacity := 0
var _receiver_light_index_capacity := 0
var _mesh_vertex_bases: PackedInt32Array = []
var _mesh_vertex_counts: PackedInt32Array = []
var _mesh_index_counts: PackedInt32Array = []
var _mesh_index_buffers: Array[RID] = []
var _gpu_instances: Array[RDAccelerationStructureInstance] = []
var _active_gpu_instances: Array[RDAccelerationStructureInstance] = []
var _instance_values_cache := PackedFloat32Array()
var _frame_values_cache := PackedFloat32Array()
var _cached_uniform_set := RID()
var _cached_uniform_color := RID()
var _cached_uniform_depth := RID()
var _cached_uniform_normal_roughness := RID()
var _cached_uniform_specular := RID()
var _cached_uniform_tlas := RID()
var _cached_uniform_environment := RID()
var _last_profiled_timestamp_frame := -1
var _profiling_active := false
var _profile_mutex := Mutex.new()
var _profile := {
	"blas_builds": 0,
	"tlas_builds": 0,
	"tlas_instances": 0,
	"instance_uploads": 0,
	"material_uploads": 0,
	"light_uploads": 0,
	"receiver_light_uploads": 0,
	"texture_atlas_uploads": 0,
	"texture_atlas_bytes": 0,
	"albedo_atlas_width": 0,
	"albedo_atlas_height": 0,
	"normal_atlas_width": 0,
	"normal_atlas_height": 0,
	"environment_texture_bindings": 0,
	"environment_revision": 0,
	"environment_mode": 0,
	"environment_panorama_width": 0,
	"environment_panorama_height": 0,
	"environment_panorama_bytes": 0,
	"uniform_set_rebuilds": 0,
	"tlas_cpu_seconds": 0.0,
	"dispatch_cpu_seconds": 0.0,
	"tlas_gpu_seconds": 0.0,
	"dispatch_gpu_seconds": 0.0,
	"ray_tracing_full_resolution": Vector2i.ZERO,
	"ray_tracing_resolution": Vector2i.ZERO,
	"ray_tracing_dispatched_pixels": 0,
	"ray_tracing_width": 0,
	"ray_tracing_height": 0,
	"ray_tracing_dispatch_pixels": 0,
	"ray_tracing_resolution_method": &"native",
}


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_SKY
	access_resolved_color = false
	access_resolved_depth = false
	needs_normal_roughness = true
	needs_separate_specular = true
	needs_motion_vectors = false
	enabled = true
	rd = RenderingServer.get_rendering_device()


func _render_callback(effect_callback_type_value: int, render_data: RenderData) -> void:
	var bridge = snapshot_bridge
	if _shutdown_started or _failed or effect_callback_type_value != EFFECT_CALLBACK_TYPE_POST_SKY or rd == null or bridge == null:
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	if buffers.get_view_count() != 1:
		_fail("Multiview/XR render buffers are outside the single-view RT contract.")
		return
	var full_size := buffers.get_internal_size()
	if full_size.x <= 0 or full_size.y <= 0:
		return
	var snapshot: Dictionary = bridge.get_snapshot()
	if snapshot.is_empty():
		return
	var profiling_enabled := bool(snapshot.get("profiling_enabled", false))
	_profiling_active = profiling_enabled
	if profiling_enabled:
		_consume_gpu_timestamps()
	if not _initialized and not _initialize_resources(snapshot):
		return
	if not _update_instances(snapshot, profiling_enabled):
		return
	if not _update_dynamic_buffers(snapshot):
		return
	var scene_data := render_data.get_render_scene_data()
	if scene_data == null:
		return

	_update_frame_ubo(scene_data, full_size, snapshot)
	if _failed:
		return

	var color := buffers.get_color_layer(0)
	var depth := buffers.get_depth_layer(0)
	var normal_roughness := buffers.get_texture_slice("forward_clustered", "normal_roughness", 0, 0, 1, 1)
	var specular := buffers.get_texture_slice("forward_clustered", "specular", 0, 0, 1, 1)
	if not color.is_valid() or not depth.is_valid() or not normal_roughness.is_valid() or not specular.is_valid():
		_fail("Forward+ resolved color/depth/normal/specular textures are unavailable at POST_SKY.")
		return

	var uniform_set := _get_uniform_set(color, depth, normal_roughness, specular)
	if not uniform_set.is_valid():
		_fail("Unable to bind the resolved Forward+ buffers as RT uniforms.")
		return

	var dispatch_started_usec := Time.get_ticks_usec() if profiling_enabled else 0
	if profiling_enabled:
		rd.capture_timestamp(PROFILE_DISPATCH_BEGIN)

	var ray_list := rd.raytracing_list_begin()
	rd.raytracing_list_bind_raytracing_pipeline(ray_list, pipeline)
	rd.raytracing_list_bind_uniform_set(ray_list, uniform_set, 0)
	rd.raytracing_list_trace_rays(ray_list, 0, hit_sbt, full_size.x, full_size.y, 1)
	rd.raytracing_list_end()

	_set_profile_facts({
		"ray_tracing_full_resolution": full_size,
		"ray_tracing_resolution": full_size,
		"ray_tracing_dispatched_pixels": full_size.x * full_size.y,
		"ray_tracing_width": full_size.x,
		"ray_tracing_height": full_size.y,
		"ray_tracing_dispatch_pixels": full_size.x * full_size.y,
		"ray_tracing_resolution_method": &"native",
	})

	if profiling_enabled:
		rd.capture_timestamp(PROFILE_DISPATCH_END)
		_set_profile_values({"dispatch_cpu_seconds": float(Time.get_ticks_usec() - dispatch_started_usec) / 1000000.0})

func _initialize_resources(snapshot: Dictionary) -> bool:
	if rd == null or not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		_fail("Ray-tracing pipeline support is unavailable on the active RenderingDevice.")
		return false
	var shader_file := load(RT_SHADER_PATH) as RDShaderFile
	if shader_file == null:
		_fail("Unable to load imported RT shader: %s" % RT_SHADER_PATH)
		return false
	var spirv := shader_file.get_spirv(RT_SHADER_VERSION_NATIVE)
	if spirv == null or spirv.bytecode_raygen.is_empty() or spirv.bytecode_miss.is_empty() or spirv.bytecode_closest_hit.is_empty():
		_fail("The imported RT shader is missing raygen, miss, or closest-hit bytecode: %s" % shader_file.base_error)
		return false
	shader = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		_fail("RenderingDevice rejected the RT shader SPIR-V.")
		return false
	var raygen := RDPipelineShader.new()
	raygen.shader = shader
	var miss_shader := RDPipelineShader.new()
	miss_shader.shader = shader
	var hit_group := RDHitGroup.new()
	var closest_hit := RDPipelineShader.new()
	closest_hit.shader = shader
	hit_group.closest_hit_shader = closest_hit
	pipeline = rd.raytracing_pipeline_create([raygen], [miss_shader], [hit_group], 1)
	if not pipeline.is_valid() or not rd.raytracing_pipeline_is_valid(pipeline):
		_fail("RenderingDevice rejected the RT pipeline.")
		return false
	hit_sbt = rd.hit_sbt_create(pipeline, 1)
	if not hit_sbt.is_valid():
		_fail("Unable to create the RT hit shader binding table.")
		return false
	hit_sbt_range = rd.hit_sbt_range_alloc(hit_sbt, 1)
	if hit_sbt_range <= 0 or rd.hit_sbt_range_update(hit_sbt, hit_sbt_range, 0, PackedInt32Array([0])) != OK:
		_fail("Unable to initialize the RT hit shader binding table.")
		return false
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = rd.sampler_create(sampler_state)
	if not sampler.is_valid():
		_fail("Unable to create the RT nearest sampler.")
		return false
	var atlas_sampler_state := RDSamplerState.new()
	atlas_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	atlas_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	atlas_sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	atlas_sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	atlas_sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	atlas_sampler = rd.sampler_create(atlas_sampler_state)
	if not atlas_sampler.is_valid():
		_fail("Unable to create the RT atlas sampler.")
		return false
	if not _initialize_texture_atlases(snapshot):
		return false
	if not _update_environment_texture(snapshot, true):
		return false
	if not _build_geometry(snapshot):
		return false
	frame_ubo = rd.uniform_buffer_create(FRAME_UBO_FLOATS * 4)
	if not frame_ubo.is_valid():
		_fail("Unable to allocate the RT frame UBO.")
		return false
	_frame_values_cache.resize(FRAME_UBO_FLOATS)
	_initialized = true
	var ready := _update_instances(snapshot, bool(snapshot.get("profiling_enabled", false)))
	if ready:
		var bridge = snapshot_bridge
		if bridge != null:
			bridge.mark_ready()
	return ready


func _initialize_texture_atlases(snapshot: Dictionary) -> bool:
	var albedo_resource = snapshot.get("albedo_atlas")
	var normal_resource = snapshot.get("normal_atlas")
	if not albedo_resource is Texture2D or not normal_resource is Texture2D:
		_fail("The RT texture atlases are missing from the render snapshot.")
		return false
	_albedo_atlas_resource = albedo_resource as Texture2D
	_normal_atlas_resource = normal_resource as Texture2D
	# Request an sRGB view for color data so sampling returns linear radiance.
	# Normal data deliberately uses the atlas' linear UNORM view.
	albedo_atlas_texture = RenderingServer.texture_get_rd_texture(_albedo_atlas_resource.get_rid(), true)
	normal_atlas_texture = RenderingServer.texture_get_rd_texture(_normal_atlas_resource.get_rid(), false)
	if not albedo_atlas_texture.is_valid() or not normal_atlas_texture.is_valid():
		_fail("Unable to access the RT texture atlases through RenderingDevice.")
		return false
	var albedo_format := rd.texture_get_format(albedo_atlas_texture)
	var normal_format := rd.texture_get_format(normal_atlas_texture)
	# Static resource facts remain useful even when timed profiling is disabled.
	# Store them once under the same mutex used by public profile snapshots.
	_profile_mutex.lock()
	_profile["texture_atlas_uploads"] = 2
	_profile["texture_atlas_bytes"] = int(snapshot.get("texture_atlas_bytes", 0))
	_profile["albedo_atlas_width"] = albedo_format.width
	_profile["albedo_atlas_height"] = albedo_format.height
	_profile["normal_atlas_width"] = normal_format.width
	_profile["normal_atlas_height"] = normal_format.height
	_profile_mutex.unlock()
	return true


func _update_environment_texture(snapshot: Dictionary, force: bool = false) -> bool:
	var revision := int(snapshot.get("environment_revision", -1))
	if not force and revision == _last_environment_revision:
		return true
	var environment: Dictionary = snapshot.get("environment", {})
	if environment.is_empty():
		_fail("The hardware RT snapshot is missing its revisioned environment descriptor.")
		return false
	var mode := int(environment.get("mode", 0))
	var next_texture := albedo_atlas_texture
	var next_resource: Texture2D
	if mode == 1:
		var panorama_value: Variant = environment.get("panorama")
		if not panorama_value is Texture2D:
			_fail("PANORAMA reflection mode requires a valid linear panorama texture.")
			return false
		next_resource = panorama_value as Texture2D
		next_texture = RenderingServer.texture_get_rd_texture(next_resource.get_rid(), false)
		if not next_texture.is_valid():
			_fail("Unable to access the reflection panorama through RenderingDevice.")
			return false
		var panorama_format := rd.texture_get_format(next_texture)
		if (
				panorama_format.format != RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
				and panorama_format.format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		):
			_fail("The reflection panorama must upload as a linear float texture.")
			return false
	elif mode != 0:
		_fail("Unknown hardware RT environment mode %d." % mode)
		return false

	_environment_resource = next_resource
	environment_texture = next_texture
	_last_environment_revision = revision
	_environment_texture_bindings += 1
	_cached_uniform_set = RID()
	_set_profile_facts({
		"environment_texture_bindings": _environment_texture_bindings,
		"environment_revision": revision,
		"environment_mode": mode,
		"environment_panorama_width": int(environment.get("width", 0)),
		"environment_panorama_height": int(environment.get("height", 0)),
		"environment_panorama_bytes": int(environment.get("bytes", 0)),
	})
	return true


func _build_geometry(snapshot: Dictionary) -> bool:
	var meshes: Array = snapshot.get("mesh_records", [])
	if meshes.is_empty():
		_fail("No mesh records were published to the RT render thread.")
		return false
	var position_bytes := PackedByteArray()
	var normal_bytes := PackedByteArray()
	var uv_bytes := PackedByteArray()
	var index_bytes := PackedByteArray()
	var triangle_surface_words := PackedInt32Array()
	var geometry_words := PackedInt32Array()
	_mesh_vertex_bases.clear()
	_mesh_vertex_counts.clear()
	_mesh_index_counts.clear()
	for record in meshes:
		var positions: PackedByteArray = record["positions"]
		var normals: PackedByteArray = record["normals"]
		var vertex_count: int = record["vertex_count"]
		var mesh_uvs: PackedByteArray = record.get("uvs", PackedByteArray())
		if mesh_uvs.is_empty():
			# Constant-only legacy records do not consume UVs, but keeping one vec2
			# per vertex preserves the shared vertex-base addressing contract.
			mesh_uvs.resize(vertex_count * UV_STRIDE)
		if mesh_uvs.size() != vertex_count * UV_STRIDE:
			_fail("An RT mesh UV buffer does not match its vertex count.")
			return false
		var indices: PackedByteArray = record["indices"]
		var triangle_surfaces: PackedInt32Array = record["triangle_surfaces"]
		var vertex_base := int(position_bytes.size() / float(POSITION_STRIDE))
		var normal_base := int(normal_bytes.size() / float(POSITION_STRIDE))
		var index_base := int(index_bytes.size() / float(INDEX_STRIDE))
		var triangle_surface_base := triangle_surface_words.size()
		position_bytes.append_array(positions)
		normal_bytes.append_array(normals)
		uv_bytes.append_array(mesh_uvs)
		index_bytes.append_array(indices)
		triangle_surface_words.append_array(triangle_surfaces)
		var index_count: int = record["index_count"]
		_mesh_vertex_bases.append(vertex_base)
		_mesh_vertex_counts.append(vertex_count)
		_mesh_index_counts.append(index_count)
		geometry_words.append(normal_base)
		geometry_words.append(index_base)
		geometry_words.append(triangle_surface_base)
		geometry_words.append(int(record["surface_count"]))
	var buffer_flags := RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT | RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT | RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
	position_buffer = rd.vertex_buffer_create(position_bytes.size(), position_bytes, buffer_flags)
	normal_buffer = rd.storage_buffer_create(normal_bytes.size(), normal_bytes)
	uv_buffer = rd.storage_buffer_create(uv_bytes.size(), uv_bytes)
	# Godot 4.7.1 does not accept an index-buffer RID in a storage-buffer
	# uniform. Keep a duplicate SSBO for raygen hit interpolation.
	index_storage_buffer = rd.storage_buffer_create(index_bytes.size(), index_bytes)
	var geometry_bytes := geometry_words.to_byte_array()
	geometry_buffer = rd.storage_buffer_create(geometry_bytes.size(), geometry_bytes)
	# Per instance: vec4 metadata + three padded normal-matrix columns = 64 bytes.
	_instance_buffer_capacity = max(
		INSTANCE_RECORD_SIZE, snapshot["instances"].size() * INSTANCE_RECORD_SIZE)
	instance_buffer = rd.storage_buffer_create(_instance_buffer_capacity)
	var material_bytes := _pack_materials(snapshot["material_records"])
	_material_buffer_capacity = max(MATERIAL_RECORD_SIZE, material_bytes.size())
	material_buffer = rd.storage_buffer_create(_material_buffer_capacity, material_bytes)
	_increment_profile("material_uploads")
	# The authoring cap can change live; reserve the full supported table once.
	_light_buffer_capacity = MAX_LIGHT_RECORDS * 64
	light_buffer = rd.storage_buffer_create(_light_buffer_capacity)
	var triangle_surface_bytes := triangle_surface_words.to_byte_array()
	triangle_surface_buffer = rd.storage_buffer_create(triangle_surface_bytes.size(), triangle_surface_bytes)
	var instance_material_words: PackedInt32Array = snapshot["instance_material_indices"]
	var instance_material_bytes := instance_material_words.to_byte_array()
	_instance_material_buffer_capacity = maxi(16, instance_material_bytes.size())
	instance_material_buffer = rd.storage_buffer_create(_instance_material_buffer_capacity)
	if (
			instance_material_buffer.is_valid()
			and not instance_material_bytes.is_empty()
			and rd.buffer_update(
				instance_material_buffer, 0,
				instance_material_bytes.size(), instance_material_bytes) != OK
	):
		_fail("Unable to initialize the RT instance-material table.")
		return false
	if not _upload_receiver_lights(snapshot):
		return false
	if not position_buffer.is_valid() or not normal_buffer.is_valid() or not uv_buffer.is_valid() or not index_storage_buffer.is_valid() or not geometry_buffer.is_valid() or not instance_buffer.is_valid() or not material_buffer.is_valid() or not light_buffer.is_valid() or not triangle_surface_buffer.is_valid() or not instance_material_buffer.is_valid() or not receiver_light_start_buffer.is_valid() or not receiver_light_count_buffer.is_valid() or not receiver_light_index_buffer.is_valid():
		_fail("Unable to allocate RT geometry, material, or light buffers.")
		return false
	_last_material_revision = int(snapshot["material_revision"])
	if not _upload_lights(snapshot):
		return false
	# The 4.7.1 BLAS validator compares an index buffer's global maximum index
	# against each geometry's vertex_count without respecting index_offset.
	# Therefore each shared mesh needs its own AS index buffer. The concatenated
	# index_storage_buffer above remains the raygen hit-shading read path.
	_mesh_index_buffers.clear()
	for i in meshes.size():
		var mesh_indices: PackedByteArray = meshes[i]["indices"]
		var mesh_index_buffer := rd.index_buffer_create(
			_mesh_index_counts[i],
			RenderingDevice.INDEX_BUFFER_FORMAT_UINT32,
			mesh_indices,
			false,
			RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT | RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT)
		if not mesh_index_buffer.is_valid():
			_fail("Unable to allocate an RT mesh index buffer.")
			return false
		_mesh_index_buffers.append(mesh_index_buffer)
	var geometries: Array = []
	_mesh_records_for_blas.clear()
	for i in meshes.size():
		var geometry := RDAccelerationStructureGeometry.new()
		geometry.flags = RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT
		geometry.vertex_buffer = position_buffer
		geometry.vertex_offset = _mesh_vertex_bases[i] * POSITION_STRIDE
		geometry.vertex_stride = POSITION_STRIDE
		geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
		geometry.vertex_count = _mesh_vertex_counts[i]
		geometry.index_buffer = _mesh_index_buffers[i]
		geometry.index_offset = 0
		geometry.index_count = _mesh_index_counts[i]
		geometries.append(geometry)
	var blas_flags := RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT
	for geometry in geometries:
		var blas := rd.blas_create([geometry], blas_flags)
		if not blas.is_valid():
			_fail("Unable to create an RT BLAS.")
			return false
		if rd.blas_build(blas) != OK:
			_fail("Unable to build an RT BLAS.")
			return false
		_mesh_records_for_blas.append(blas)
	_set_profile_values({"blas_builds": _mesh_records_for_blas.size()})
	tlas = rd.tlas_create(snapshot["instances"].size(), RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_BUILD_BIT)
	if not tlas.is_valid():
		_fail("Unable to create the RT TLAS.")
		return false
	_initialize_gpu_instances(snapshot)
	return true


var _mesh_records_for_blas: Array[RID] = []


func _pack_materials(materials: Array) -> PackedByteArray:
	var values := PackedFloat32Array()
	for material in materials:
		var diffuse: Color = material["diffuse"]
		var ambient: Color = material["ambient"]
		var emission: Color = material["emission"]
		var specular: Color = material["specular"]
		var flags := 0
		if bool(material.get("has_albedo", false)):
			flags |= 1
		if bool(material.get("has_normal", false)):
			flags |= 2
		if bool(material.get("triplanar_enabled", false)):
			flags |= 4
		if bool(material.get("triplanar_world_space", false)):
			flags |= 8
		var albedo_region := _material_region_vec4(material.get("albedo_region", Vector4.ZERO))
		var normal_region := _material_region_vec4(material.get("normal_region", Vector4.ZERO))
		var triplanar_scale: Vector3 = material.get("triplanar_scale", Vector3.ONE)
		var triplanar_offset: Vector3 = material.get("triplanar_offset", Vector3.ZERO)
		# Alpha lanes carry scalar values and packed flags. Mirror strength remains
		# per-pixel normal/roughness transport; only its reflected-shadow opt-in is
		# needed in this table.
		values.append_array([diffuse.r, diffuse.g, diffuse.b, float(material["shininess"])])
		values.append_array([ambient.r, ambient.g, ambient.b, float(material["direct_intensity"])])
		values.append_array([emission.r, emission.g, emission.b, 1.0 if bool(material.get("reflection_shadows_enabled", false)) else 0.0])
		values.append_array([specular.r, specular.g, specular.b, float(flags)])
		_append_vec4(values, albedo_region)
		_append_vec4(values, normal_region)
		values.append_array([triplanar_scale.x, triplanar_scale.y, triplanar_scale.z, float(material.get("triplanar_sharpness", 1.0))])
		values.append_array([triplanar_offset.x, triplanar_offset.y, triplanar_offset.z, 0.0])
	return values.to_byte_array()


func _material_region_vec4(value: Variant) -> Vector4:
	if value is Vector4:
		return value as Vector4
	if value is Rect2i:
		var region := value as Rect2i
		return Vector4(region.position.x, region.position.y, region.size.x, region.size.y)
	if value is Rect2:
		var region := value as Rect2
		return Vector4(region.position.x, region.position.y, region.size.x, region.size.y)
	return Vector4.ZERO


func _pack_lights(records: Array) -> PackedByteArray:
	var values := PackedFloat32Array()
	for record in records:
		var position: Vector3 = record["position"]
		var direction: Vector3 = record["direction"]
		var color: Color = record["color"]
		_append_vec4(values, Vector4(position.x, position.y, position.z, float(record["type"])))
		_append_vec4(values, Vector4(direction.x, direction.y, direction.z, float(record["range"])))
		_append_vec4(values, Vector4(color.r, color.g, color.b, float(record["attenuation"])))
		_append_vec4(values, Vector4(float(record["cone_cosine"]), float(record["cone_attenuation"]), 1.0 if record["rt_shadow"] else 0.0, float(record["cull_mask"])))
	return values.to_byte_array()


func _upload_lights(snapshot: Dictionary) -> bool:
	var light: Dictionary = snapshot["light"]
	var records: Array = light.get("records", [])
	var bytes := _pack_lights(records)
	if bytes.size() > _light_buffer_capacity:
		_fail("The active RT light table exceeds its fixed GPU capacity.")
		return false
	if not bytes.is_empty() and rd.buffer_update(light_buffer, 0, bytes.size(), bytes) != OK:
		_fail("Unable to upload the RT light table.")
		return false
	_last_light_revision = int(snapshot["light_revision"])
	_increment_profile("light_uploads")
	return true


func _upload_receiver_lights(snapshot: Dictionary) -> bool:
	var instance_count: int = snapshot["instances"].size()
	var starts: PackedInt32Array = snapshot.get("receiver_light_starts", PackedInt32Array())
	var counts: PackedInt32Array = snapshot.get("receiver_light_counts", PackedInt32Array())
	var indices: PackedInt32Array = snapshot.get("receiver_light_indices", PackedInt32Array())
	# Old snapshots are accepted during a live script reload by constructing the
	# exact uncullled list. New manager snapshots always publish compact ranges.
	if starts.is_empty() and counts.is_empty():
		starts.resize(instance_count)
		counts.resize(instance_count)
		var light_count: int = (snapshot["light"].get("records", []) as Array).size()
		indices.resize(instance_count * light_count)
		for instance_index in instance_count:
			starts[instance_index] = instance_index * light_count
			counts[instance_index] = light_count
			for light_index in light_count:
				indices[instance_index * light_count + light_index] = light_index
	if starts.size() != instance_count or counts.size() != instance_count:
		_fail("Hardware RT receiver-light ranges do not match the instance table.")
		return false
	for i in instance_count:
		var start := int(starts[i])
		var count := int(counts[i])
		if start < 0 or count < 0 or start + count > indices.size():
			_fail("Hardware RT receiver-light range %d is outside the compact index table." % i)
			return false
	var start_bytes := starts.to_byte_array()
	var count_bytes := counts.to_byte_array()
	var index_bytes := indices.to_byte_array()
	if index_bytes.is_empty():
		index_bytes = PackedInt32Array([0]).to_byte_array()
	receiver_light_start_buffer = _grow_storage_buffer(
		receiver_light_start_buffer, _receiver_light_start_capacity, start_bytes)
	_receiver_light_start_capacity = _grown_capacity(_receiver_light_start_capacity, start_bytes.size())
	receiver_light_count_buffer = _grow_storage_buffer(
		receiver_light_count_buffer, _receiver_light_count_capacity, count_bytes)
	_receiver_light_count_capacity = _grown_capacity(_receiver_light_count_capacity, count_bytes.size())
	receiver_light_index_buffer = _grow_storage_buffer(
		receiver_light_index_buffer, _receiver_light_index_capacity, index_bytes)
	_receiver_light_index_capacity = _grown_capacity(_receiver_light_index_capacity, index_bytes.size())
	if not receiver_light_start_buffer.is_valid() or not receiver_light_count_buffer.is_valid() or not receiver_light_index_buffer.is_valid():
		_fail("Unable to allocate hardware RT receiver-light buffers.")
		return false
	_last_receiver_light_revision = int(snapshot.get("receiver_light_revision", snapshot.get("light_revision", 0)))
	_increment_profile("receiver_light_uploads")
	return true


func _grown_capacity(current: int, required: int) -> int:
	var capacity := maxi(16, current)
	while capacity < maxi(1, required):
		capacity *= 2
	return capacity


func _grow_storage_buffer(current: RID, current_capacity: int, bytes: PackedByteArray) -> RID:
	var required := maxi(1, bytes.size())
	var next_capacity := _grown_capacity(current_capacity, required)
	if not current.is_valid() or next_capacity != current_capacity:
		var replacement := rd.storage_buffer_create(next_capacity)
		if not replacement.is_valid():
			return RID()
		if current.is_valid():
			rd.free_rid(current)
		_cached_uniform_set = RID()
		current = replacement
	if not bytes.is_empty() and rd.buffer_update(current, 0, bytes.size(), bytes) != OK:
		return RID()
	return current


func _update_dynamic_buffers(snapshot: Dictionary) -> bool:
	var material_revision := int(snapshot["material_revision"])
	if material_revision != _last_material_revision:
		var material_bytes := _pack_materials(snapshot["material_records"])
		var next_material_buffer := _grow_storage_buffer(
			material_buffer, _material_buffer_capacity, material_bytes)
		if not next_material_buffer.is_valid():
			_fail("Unable to update the RT material table.")
			return false
		material_buffer = next_material_buffer
		_material_buffer_capacity = _grown_capacity(
			_material_buffer_capacity, material_bytes.size())
		_last_material_revision = material_revision
		_increment_profile("material_uploads")
	if int(snapshot["light_revision"]) != _last_light_revision:
		if not _upload_lights(snapshot):
			return false
	if not _update_environment_texture(snapshot):
		return false
	var receiver_revision := int(snapshot.get("receiver_light_revision", snapshot.get("light_revision", 0)))
	if receiver_revision != _last_receiver_light_revision:
		return _upload_receiver_lights(snapshot)
	return true


func _initialize_gpu_instances(snapshot: Dictionary) -> void:
	_gpu_instances.clear()
	_active_gpu_instances.clear()
	var instance_list: Array = snapshot["instances"]
	_instance_values_cache.resize(instance_list.size() * 16)
	for i in instance_list.size():
		var source: Dictionary = instance_list[i]
		var instance := RDAccelerationStructureInstance.new()
		instance.blas = _mesh_records_for_blas[int(source["geometry"])]
		instance.id = i
		instance.mask = 0
		instance.hit_sbt_range = hit_sbt_range
		_gpu_instances.append(instance)


func _sync_gpu_instance_slots(snapshot: Dictionary) -> bool:
	var instance_list: Array = snapshot["instances"]
	if instance_list.size() < _gpu_instances.size():
		_fail("The RT instance registry cannot shrink stable GPU slots at runtime.")
		return false
	while _gpu_instances.size() < instance_list.size():
		var instance_index := _gpu_instances.size()
		var source: Dictionary = instance_list[instance_index]
		var geometry_index := int(source.get("geometry", -1))
		if geometry_index < 0 or geometry_index >= _mesh_records_for_blas.size():
			_fail("Receiver-only GPU slot %d references invalid geometry %d." % [
				instance_index, geometry_index])
			return false
		var instance := RDAccelerationStructureInstance.new()
		instance.blas = _mesh_records_for_blas[geometry_index]
		instance.id = instance_index
		instance.mask = 0
		instance.hit_sbt_range = hit_sbt_range
		_gpu_instances.append(instance)
	return true


func _update_instances(snapshot: Dictionary, profiling_enabled: bool) -> bool:
	var tlas_revision := int(snapshot.get("tlas_revision", snapshot.get("transform_revision", -1)))
	var instance_revision := int(snapshot.get("instance_revision", tlas_revision))
	var rebuild_tlas := tlas_revision != _last_tlas_revision
	var upload_instances := instance_revision != _last_instance_revision
	if not rebuild_tlas and not upload_instances:
		return true
	if not tlas.is_valid() or _mesh_records_for_blas.is_empty():
		_fail("RT acceleration structures are not initialized.")
		return false
	var transform_list: Array = snapshot["transforms"]
	var instance_list: Array = snapshot["instances"]
	if not _sync_gpu_instance_slots(snapshot):
		return false
	_instance_values_cache.resize(instance_list.size() * 16)
	var instance_masks: PackedInt32Array = snapshot["instance_masks"]
	var instance_layers: PackedInt32Array = snapshot["instance_layers"]
	if transform_list.size() != instance_list.size() or instance_masks.size() != instance_list.size() or instance_layers.size() != instance_list.size() or _gpu_instances.size() != instance_list.size():
		_fail("RT transform and instance snapshots are inconsistent.")
		return false

	var masks_changed := false
	for i in instance_list.size():
		var source: Dictionary = instance_list[i]
		var object_to_world: Transform3D = transform_list[i]
		var gpu_instance := _gpu_instances[i]
		var transform_changed := _last_instance_revision < 0 or gpu_instance.transform != object_to_world
		if rebuild_tlas:
			var next_mask := int(instance_masks[i])
			masks_changed = masks_changed or gpu_instance.mask != next_mask
			gpu_instance.transform = object_to_world
			gpu_instance.mask = next_mask
		if upload_instances:
			var value_base := i * 16
			_instance_values_cache[value_base + 0] = float(source["geometry"])
			_instance_values_cache[value_base + 1] = float(source["material_base"])
			_instance_values_cache[value_base + 2] = float(source["surface_count"])
			_instance_values_cache[value_base + 3] = float(instance_layers[i])
			if transform_changed:
				var normal_basis := object_to_world.basis.inverse().transposed()
				_set_cached_vec4(value_base + 4, Vector4(normal_basis.x.x, normal_basis.x.y, normal_basis.x.z, 0.0))
				_set_cached_vec4(value_base + 8, Vector4(normal_basis.y.x, normal_basis.y.y, normal_basis.y.z, 0.0))
				_set_cached_vec4(value_base + 12, Vector4(normal_basis.z.x, normal_basis.z.y, normal_basis.z.z, 0.0))

	if upload_instances:
		var instance_bytes := _instance_values_cache.to_byte_array()
		var next_instance_buffer := _grow_storage_buffer(
			instance_buffer, _instance_buffer_capacity, instance_bytes)
		if not next_instance_buffer.is_valid():
			_fail("Unable to upload the RT instance table.")
			return false
		instance_buffer = next_instance_buffer
		_instance_buffer_capacity = _grown_capacity(
			_instance_buffer_capacity, instance_bytes.size())
		var mapping_words: PackedInt32Array = snapshot["instance_material_indices"]
		var mapping_bytes := mapping_words.to_byte_array()
		var next_mapping_buffer := _grow_storage_buffer(
			instance_material_buffer,
			_instance_material_buffer_capacity,
			mapping_bytes)
		if not next_mapping_buffer.is_valid():
			_fail("Unable to upload the RT instance-material table.")
			return false
		instance_material_buffer = next_mapping_buffer
		_instance_material_buffer_capacity = _grown_capacity(
			_instance_material_buffer_capacity, mapping_bytes.size())
		_last_instance_revision = instance_revision
		if profiling_enabled:
			_increment_profile("instance_uploads")

	if rebuild_tlas:
		if masks_changed or _active_gpu_instances.is_empty():
			_active_gpu_instances.clear()
			for gpu_instance in _gpu_instances:
				if gpu_instance.mask != 0:
					_active_gpu_instances.append(gpu_instance)
			# Some Vulkan drivers reject a zero-instance build. A single mask-zero
			# placeholder is equivalent and is only retained for the all-hidden case.
			if _active_gpu_instances.is_empty() and not _gpu_instances.is_empty():
				_active_gpu_instances.append(_gpu_instances[0])
		var tlas_started_usec := Time.get_ticks_usec() if profiling_enabled else 0
		if profiling_enabled:
			rd.capture_timestamp(PROFILE_TLAS_BEGIN)
		if rd.tlas_build(tlas, _active_gpu_instances) != OK:
			_fail("Unable to rebuild the RT TLAS.")
			return false
		if profiling_enabled:
			rd.capture_timestamp(PROFILE_TLAS_END)
			var tlas_cpu_seconds := float(Time.get_ticks_usec() - tlas_started_usec) / 1000000.0
			var visible_tlas_instances := 0
			for gpu_instance in _active_gpu_instances:
				if gpu_instance.mask != 0:
					visible_tlas_instances += 1
			_increment_profile("tlas_builds")
			_set_profile_values({
				"tlas_instances": visible_tlas_instances,
				"tlas_cpu_seconds": tlas_cpu_seconds,
			})
		_last_tlas_revision = tlas_revision
	return true


func _update_frame_ubo(
		scene_data: RenderSceneData,
		full_size: Vector2i,
		snapshot: Dictionary) -> void:
	var projection: Projection = scene_data.get_view_projection(0)
	var inverse_projection := projection.inverse()
	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var light: Dictionary = snapshot["light"]
	var environment: Dictionary = snapshot["environment"]
	_set_frame_projection(0, inverse_projection)
	var camera_position := camera_transform.origin
	_set_frame_vec4(16, Vector4(camera_position.x, camera_position.y, camera_position.z, 1.0))
	_set_frame_vec4(20, Vector4(camera_transform.basis.x.x, camera_transform.basis.x.y, camera_transform.basis.x.z, 0.0))
	_set_frame_vec4(24, Vector4(camera_transform.basis.y.x, camera_transform.basis.y.y, camera_transform.basis.y.z, 0.0))
	_set_frame_vec4(28, Vector4(camera_transform.basis.z.x, camera_transform.basis.z.y, camera_transform.basis.z.z, 0.0))
	_set_frame_vec4(32, Vector4(full_size.x, full_size.y, 0.0, 0.0))
	_set_frame_vec4(36, Vector4(float(snapshot["bias"]), float(snapshot["max_distance"]), 0.0, 0.0))
	var light_records: Array = light.get("records", [])
	var material_records: Array = snapshot["material_records"]
	var instance_records: Array = snapshot["instances"]
	_set_frame_vec4(40, Vector4(light_records.size(), material_records.size(), instance_records.size(), 0.0))
	var fallback: Color = environment.get("fallback_linear", Color.BLACK)
	_set_frame_vec4(44, Vector4(fallback.r, fallback.g, fallback.b, 1.0))
	var inverse_sky_basis: Basis = environment.get("inverse_sky_basis", Basis.IDENTITY)
	_set_frame_vec4(48, Vector4(
		inverse_sky_basis.x.x, inverse_sky_basis.x.y, inverse_sky_basis.x.z, 0.0))
	_set_frame_vec4(52, Vector4(
		inverse_sky_basis.y.x, inverse_sky_basis.y.y, inverse_sky_basis.y.z, 0.0))
	_set_frame_vec4(56, Vector4(
		inverse_sky_basis.z.x, inverse_sky_basis.z.y, inverse_sky_basis.z.z, 0.0))
	_set_frame_vec4(60, Vector4(
		float(environment.get("mode", 0)),
		float(environment.get("width", 0)),
		float(environment.get("height", 0)),
		0.0))
	_set_frame_vec4(64, Vector4(
		float(snapshot.get("fog_begin", 0.0)),
		float(snapshot.get("fog_end", 1.0)),
		float(snapshot.get("fog_curve", 1.0)),
		1.0 if bool(snapshot.get("fog_enabled", false)) else 0.0))
	# The cloud layer a sky system pushed through configure_cloud_layer(). Zero
	# by default, which the canonical dnc_cloud_shadow() reads as no layer.
	_set_frame_vec4(68, snapshot.get("cloud_params", Vector4.ZERO))
	_set_frame_vec4(72, snapshot.get("cloud_motion", Vector4.ZERO))
	var cloud_sun: Vector3 = snapshot.get("cloud_sun_direction", Vector3.UP)
	_set_frame_vec4(76, Vector4(cloud_sun.x, cloud_sun.y, cloud_sun.z, 0.0))
	var bytes := _frame_values_cache.to_byte_array()
	if rd.buffer_update(frame_ubo, 0, bytes.size(), bytes) != OK:
		_fail("Unable to update the RT frame UBO.")

func _set_frame_projection(offset: int, projection: Projection) -> void:
	_set_frame_vec4(offset + 0, projection.x)
	_set_frame_vec4(offset + 4, projection.y)
	_set_frame_vec4(offset + 8, projection.z)
	_set_frame_vec4(offset + 12, projection.w)


func _set_frame_vec4(offset: int, value: Vector4) -> void:
	_frame_values_cache[offset + 0] = value.x
	_frame_values_cache[offset + 1] = value.y
	_frame_values_cache[offset + 2] = value.z
	_frame_values_cache[offset + 3] = value.w


func _set_cached_vec4(offset: int, value: Vector4) -> void:
	_instance_values_cache[offset + 0] = value.x
	_instance_values_cache[offset + 1] = value.y
	_instance_values_cache[offset + 2] = value.z
	_instance_values_cache[offset + 3] = value.w


func _append_vec4(values: PackedFloat32Array, value: Vector4) -> void:
	values.append(value.x)
	values.append(value.y)
	values.append(value.z)
	values.append(value.w)


func _get_uniform_set(
		color: RID,
		depth: RID,
		normal_roughness: RID,
		specular: RID) -> RID:
	var inputs_unchanged := (
		color == _cached_uniform_color
		and depth == _cached_uniform_depth
		and normal_roughness == _cached_uniform_normal_roughness
		and specular == _cached_uniform_specular
		and tlas == _cached_uniform_tlas
		and environment_texture == _cached_uniform_environment)
	if inputs_unchanged and _cached_uniform_set.is_valid() and rd.uniform_set_is_valid(_cached_uniform_set):
		return _cached_uniform_set
	if rd.texture_get_format(specular).format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
		_fail("Unexpected Forward+ separate-specular format; expected R16G16B16A16_SFLOAT.")
		return RID()
	if rd.texture_get_format(color).format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
		_fail("Unexpected Forward+ color format; expected R16G16B16A16_SFLOAT.")
		return RID()
	_cached_uniform_set = _make_uniform_set(color, depth, normal_roughness, specular)
	if _cached_uniform_set.is_valid():
		_cached_uniform_color = color
		_cached_uniform_depth = depth
		_cached_uniform_normal_roughness = normal_roughness
		_cached_uniform_specular = specular
		_cached_uniform_tlas = tlas
		_cached_uniform_environment = environment_texture
		_increment_profile("uniform_set_rebuilds")
	return _cached_uniform_set

func _make_uniform_set(
		color: RID,
		depth: RID,
		normal_roughness: RID,
		specular: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE, 0, [tlas]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 1, [frame_ubo]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [color]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, [specular]))
	uniforms.append(_sampler_uniform(4, depth))
	uniforms.append(_sampler_uniform(5, normal_roughness))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6, [position_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 7, [normal_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 8, [index_storage_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 9, [geometry_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 10, [instance_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 11, [material_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 12, [light_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 13, [triangle_surface_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 14, [instance_material_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 15, [uv_buffer]))
	uniforms.append(_atlas_sampler_uniform(16, albedo_atlas_texture))
	uniforms.append(_atlas_sampler_uniform(17, normal_atlas_texture))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 18, [receiver_light_start_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 19, [receiver_light_count_buffer]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 20, [receiver_light_index_buffer]))
	uniforms.append(_sampler_uniform(21, environment_texture))
	return UniformSetCacheRD.get_cache(shader, 0, uniforms)

func _uniform(kind: RenderingDevice.UniformType, binding: int, ids: Array) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = kind
	uniform.binding = binding
	for item in ids:
		uniform.add_id(item)
	return uniform


func _sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform


func _atlas_sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(atlas_sampler)
	uniform.add_id(texture)
	return uniform


func _consume_gpu_timestamps() -> void:
	var timestamp_frame := rd.get_captured_timestamps_frame()
	if timestamp_frame == _last_profiled_timestamp_frame:
		return
	_last_profiled_timestamp_frame = timestamp_frame
	var tlas_begin := -1
	var dispatch_begin := -1
	var tlas_gpu_seconds := -1.0
	var dispatch_gpu_seconds := -1.0
	for i in rd.get_captured_timestamps_count():
		var marker_name := rd.get_captured_timestamp_name(i)
		var gpu_usec := rd.get_captured_timestamp_gpu_time(i)
		match marker_name:
			PROFILE_TLAS_BEGIN:
				tlas_begin = gpu_usec
			PROFILE_TLAS_END:
				if tlas_begin >= 0 and gpu_usec >= tlas_begin:
					# Godot 4.7's Vulkan driver converts query ticks to nanoseconds.
					tlas_gpu_seconds = float(gpu_usec - tlas_begin) / 1000000000.0
			PROFILE_DISPATCH_BEGIN:
				dispatch_begin = gpu_usec
			PROFILE_DISPATCH_END:
				if dispatch_begin >= 0 and gpu_usec >= dispatch_begin:
					dispatch_gpu_seconds = float(gpu_usec - dispatch_begin) / 1000000000.0
	var updates := {}
	if tlas_gpu_seconds >= 0.0:
		updates["tlas_gpu_seconds"] = tlas_gpu_seconds
	if dispatch_gpu_seconds >= 0.0:
		updates["dispatch_gpu_seconds"] = dispatch_gpu_seconds
	if not updates.is_empty():
		_set_profile_values(updates)


func _increment_profile(key: String) -> void:
	if not _profiling_active:
		return
	_profile_mutex.lock()
	_profile[key] = int(_profile.get(key, 0)) + 1
	_profile_mutex.unlock()


func _set_profile_values(values: Dictionary) -> void:
	if not _profiling_active:
		return
	_profile_mutex.lock()
	for key in values:
		_profile[key] = values[key]
	_profile_mutex.unlock()


func _set_profile_facts(values: Dictionary) -> void:
	_profile_mutex.lock()
	for key in values:
		_profile[key] = values[key]
	_profile_mutex.unlock()


func get_profile_snapshot() -> Dictionary:
	_profile_mutex.lock()
	var result := _profile.duplicate()
	_profile_mutex.unlock()
	return result

func shutdown() -> void:
	if _shutdown_started:
		return

	_shutdown_started = true
	enabled = false
	snapshot_bridge = null

	var local_rd := rd
	var native_hit_sbt := hit_sbt
	var native_hit_sbt_range := hit_sbt_range
	var resources: Array[RID] = []

	# Objects which depend on acceleration structures / pipelines first.
	for resource in [
		tlas,
		native_hit_sbt,
	]:
		if resource.is_valid():
			resources.append(resource)

	for blas in _mesh_records_for_blas:
		if blas.is_valid():
			resources.append(blas)

	for mesh_index_buffer in _mesh_index_buffers:
		if mesh_index_buffer.is_valid():
			resources.append(mesh_index_buffer)

	# Buffers, samplers, RT pipeline and shader.
	for resource in [
		frame_ubo,
		position_buffer,
		normal_buffer,
		uv_buffer,
		index_storage_buffer,
		geometry_buffer,
		instance_buffer,
		material_buffer,
		light_buffer,
		triangle_surface_buffer,
		instance_material_buffer,
		receiver_light_start_buffer,
		receiver_light_count_buffer,
		receiver_light_index_buffer,
		sampler,
		atlas_sampler,
		pipeline,
		shader,
	]:
		if resource.is_valid():
			resources.append(resource)

	_initialized = false
	_environment_resource = null
	environment_texture = RID()
	_mesh_records_for_blas.clear()
	_mesh_index_buffers.clear()

	# Do not capture self in this lambda. The effect Resource may be destroyed
	# before the render thread executes it.
	RenderingServer.call_on_render_thread(func() -> void:
		if local_rd == null:
			return

		# Release the allocated SBT range before releasing the SBT RID.
		if native_hit_sbt.is_valid() and native_hit_sbt_range > 0:
			local_rd.hit_sbt_range_free(
				native_hit_sbt,
				native_hit_sbt_range
			)

		for resource in resources:
			if resource.is_valid():
				local_rd.free_rid(resource)
	)

func _fail(reason: String) -> void:
	_failed = true
	push_error(reason)
	var bridge = snapshot_bridge
	if bridge != null:
		bridge.report_failure(reason)
