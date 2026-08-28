extends RefCounted
class_name RTPostProcessStack

const EDGE_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/smaa_edge.gdshader"
const WEIGHTS_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/smaa_weights.gdshader"
const RESOLVE_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/smaa_neighborhood.gdshader"
const EASU_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/fsr_easu.gdshader"
const PANINI_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/panini_project.gdshader"
const PRESENT_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/retro_present.gdshader"
# Sharpener selection for the present pass, matching retro_present.gdshader.
const SHARPEN_NONE := 0
const SHARPEN_CAS := 1
const SHARPEN_RCAS := 2
const AREA_TEXTURE_PATH := "res://addons/retro_rt/post_processing/smaa/AreaTexDX10.dds"
const SEARCH_TEXTURE_PATH := "res://addons/retro_rt/post_processing/smaa/SearchTex.dds"
const VIEWPORT_OWNER_META := &"__rt_post_process_owner"
const PANINI_DISTANCE := 1.0
const PANINI_MIN_HORIZONTAL_FOV := 1.0
const PANINI_MAX_HORIZONTAL_FOV := 175.0

var _owner: Node
var _root_viewport: Viewport
var _root_state: Dictionary = {}
var _root_disable_3d := false
var _owns_root_viewport := false
var _root_state_captured := false
var _container: Node
var _scene_viewport: SubViewport
var _internal_camera: Camera3D
var _edge_viewport: SubViewport
var _blend_viewport: SubViewport
var _resolve_viewport: SubViewport
# Allocated only while the render size differs from the output size. Native is a
# true FSR bypass and owns no upscale buffer at all.
var _easu_viewport: SubViewport
## Persistent native-output Panini target. It remains allocated while bypassed,
## but stops updating and the present pass reads resolve/EASU directly.
var _panini_viewport: SubViewport
## Whether the rendering server's per-viewport timers are armed. See
## [method set_pass_profiling_enabled].
var _pass_profiling_enabled := false
var _edge_material: ShaderMaterial
var _blend_material: ShaderMaterial
var _resolve_material: ShaderMaterial
var _easu_material: ShaderMaterial
var _panini_material: ShaderMaterial
var _present_material: ShaderMaterial
# Cached so entering the FSR path never loads a resource mid-frame.
var _easu_shader: Shader
var _final_layer: CanvasLayer
var _final_rect: ColorRect
var _output_size := Vector2i.ZERO
var _render_size := Vector2i.ZERO
var _requested_render_scale := 1.0
var _source_camera_instance_id := 0
var _settings: Dictionary = {}
var _active := false
var _scene_capture_frames := 0
var _edge_frames := 0
var _blend_frames := 0
var _resolve_frames := 0
var _easu_frames := 0
var _panini_frames := 0
var _resize_count := 0
var _resize_last_usec := 0
var _resize_peak_usec := 0
var _explicit_allocation_events := 0
var _initialization_allocation_count := 0
var _last_frame_allocation_count := 0
var _peak_frame_allocation_count := 0
var _pending_frame_allocation_count := 0

var _panini_active := false
var _panini_requested := false
var _panini_camera_enabled := false
var _panini_camera_capable := false
var _panini_eligible := false
var _panini_bypass_reason: StringName = &"manager_disabled"
var _panini_display_horizontal_fov := 0.0
var _panini_capture_horizontal_fov := 0.0
var _panini_capture_vertical_fov := 0.0
var _panini_capture_tan_half_fov := Vector2.ONE
var _panini_mapped_rect_min := Vector2.ZERO
var _panini_mapped_rect_max := Vector2.ZERO
var _panini_source_uv_min := Vector2.ZERO
var _panini_source_uv_max := Vector2.ONE
var _panini_perimeter_samples := 0
var _panini_invalid_samples := 0
var _panini_contract_output_size := Vector2i.ZERO
var _panini_contract_render_size := Vector2i.ZERO
var _panini_contract_display_fov := 0.0
var _panini_cached_perimeter_size := Vector2i.ZERO
var _panini_cached_perimeter := PackedVector2Array()
var _panini_property_camera_instance_id := 0
var _panini_camera_has_enabled_property := false
var _panini_camera_has_display_fov_property := false


func _reservation_is_current() -> bool:
	if not _owns_root_viewport or _root_viewport == null or not is_instance_valid(_root_viewport):
		return false
	if not _root_viewport.has_meta(VIEWPORT_OWNER_META):
		return false
	var reservation: Variant = _root_viewport.get_meta(VIEWPORT_OWNER_META)
	return reservation is WeakRef and (reservation as WeakRef).get_ref() == self


func reserve(owner: Node) -> String:
	var root_viewport := owner.get_viewport() if owner else null
	if _reservation_is_current():
		if _owner == owner and _root_viewport == root_viewport:
			return ""
		shutdown()
	elif _owner != null or _root_viewport != null or _owns_root_viewport:
		shutdown()
	if owner == null or root_viewport == null:
		return "The shared post stack requires an owner inside a Viewport."

	var existing_reservation: Variant = (
		root_viewport.get_meta(VIEWPORT_OWNER_META)
		if root_viewport.has_meta(VIEWPORT_OWNER_META) else null)
	var existing_stack: Object
	if existing_reservation is WeakRef:
		existing_stack = (existing_reservation as WeakRef).get_ref()
	elif existing_reservation is Object and is_instance_valid(existing_reservation):
		existing_stack = existing_reservation
	if existing_stack != null and existing_stack != self:
		return (
			"The root Viewport already has an active RT post stack. "
			+ "Use exactly one RTSceneManager per Viewport.")

	_owner = owner
	_root_viewport = root_viewport
	_root_viewport.set_meta(VIEWPORT_OWNER_META, weakref(self))
	_owns_root_viewport = true
	return ""


func configure(owner: Node, settings: Dictionary) -> String:
	if _active or _root_state_captured or _container != null:
		shutdown()
	var requested_viewport := owner.get_viewport() if owner else null
	if not (
			_reservation_is_current()
			and _owner == owner
			and _root_viewport == requested_viewport
	):
		shutdown()
		var reservation_error := reserve(owner)
		if not reservation_error.is_empty():
			return reservation_error
	_scene_capture_frames = 0
	_edge_frames = 0
	_blend_frames = 0
	_resolve_frames = 0
	_easu_frames = 0
	_panini_frames = 0
	_resize_count = 0
	_resize_last_usec = 0
	_resize_peak_usec = 0
	_explicit_allocation_events = 0
	_initialization_allocation_count = 0
	_last_frame_allocation_count = 0
	_peak_frame_allocation_count = 0
	_pending_frame_allocation_count = 0
	_settings = settings.duplicate()
	var size := Vector2i(_root_viewport.get_visible_rect().size)
	if size.x < 1 or size.y < 1:
		shutdown()
		return "The shared post stack requires a non-empty native viewport."
	var resources := {
		"edge_shader": load(EDGE_SHADER_PATH) as Shader,
		"weights_shader": load(WEIGHTS_SHADER_PATH) as Shader,
		"resolve_shader": load(RESOLVE_SHADER_PATH) as Shader,
		"easu_shader": load(EASU_SHADER_PATH) as Shader,
		"panini_shader": load(PANINI_SHADER_PATH) as Shader,
		"present_shader": load(PRESENT_SHADER_PATH) as Shader,
		"area": load(AREA_TEXTURE_PATH) as Texture2D,
		"search": load(SEARCH_TEXTURE_PATH) as Texture2D,
	}
	for key in resources:
		if resources[key] == null:
			shutdown()
			return "Could not load shared post resource '%s'." % key

	_root_state = RTVisualContract.capture_viewport_state(_root_viewport)
	_root_disable_3d = _root_viewport.disable_3d
	_root_state_captured = true
	RTVisualContract.apply_native_viewport_state(_root_viewport, size)
	var contract_failure := RTVisualContract.native_viewport_failure(
			_root_viewport, size)
	if not contract_failure.is_empty():
		shutdown()
		return (
			"The platform could not apply the shared viewport contract: %s."
			% contract_failure)

	_container = Node.new()
	_record_explicit_allocation()
	_container.name = "__RTPostProcessStack"
	_container.set_meta(&"__rt_internal", true)
	_owner.add_child(_container, false, Node.INTERNAL_MODE_FRONT)

	_output_size = size
	_requested_render_scale = _get_requested_render_scale(_settings)
	_render_size = _scaled_render_size(_output_size, _requested_render_scale)
	_scene_viewport = _make_viewport("SceneCapture", _render_size)
	# Hardware RT needs a transparent capture: managed pixels carry ID transport
	# rather than colour, and the shared present reconstructs the environment
	# behind every uncovered texel from the immutable snapshot.
	#
	# The raster fallback has no transport to hide, and Godot refuses to run
	# screen-space reflections into a transparent viewport -- silently, with a
	# warning -- which would leave the fallback with no reflections at all. So it
	# captures opaque and lets the viewport draw its own sky; coverage then reads
	# 1 everywhere and the present composites nothing behind it.
	_scene_viewport.transparent_bg = not bool(_settings.get("scene_capture_opaque", false))
	_scene_viewport.use_hdr_2d = true
	_scene_viewport.world_3d = _root_viewport.world_3d
	_container.add_child(_scene_viewport)
	RenderingServer.viewport_set_disable_2d(_scene_viewport.get_viewport_rid(), true)
	_internal_camera = Camera3D.new()
	_record_explicit_allocation()
	_internal_camera.name = "SceneCaptureCamera"
	_internal_camera.set_meta(&"__rt_internal", true)
	# _sync_camera assigns this camera's transform every frame from _process, which
	# is outside the physics tick that project-wide physics interpolation expects.
	# Interpolating a mirror of an already-interpolated camera would only make it
	# lag the source, so drive it directly.
	_internal_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_scene_viewport.add_child(_internal_camera)

	_edge_material = ShaderMaterial.new()
	_record_explicit_allocation()
	_edge_material.shader = resources["edge_shader"]
	_edge_material.set_shader_parameter(&"scene_texture", _scene_viewport.get_texture())
	_edge_viewport = _make_canvas_pass("SMAAEdges", _render_size, _edge_material)

	_blend_material = ShaderMaterial.new()
	_record_explicit_allocation()
	_blend_material.shader = resources["weights_shader"]
	_blend_material.set_shader_parameter(&"edges_texture", _edge_viewport.get_texture())
	_blend_material.set_shader_parameter(&"area_texture", resources["area"])
	_blend_material.set_shader_parameter(&"search_texture", resources["search"])
	_blend_viewport = _make_canvas_pass("SMAABlendWeights", _render_size, _blend_material)

	# SMAA now completes at the internal render size instead of being fused into
	# the native-resolution present pass. That is what lets EASU receive a truly
	# anti-aliased image, which FSR 1 requires, and what lets CAS/RCAS read a
	# neighborhood of the post-SMAA result at all.
	_resolve_material = ShaderMaterial.new()
	_record_explicit_allocation()
	_resolve_material.shader = resources["resolve_shader"]
	_resolve_material.set_shader_parameter(&"scene_texture", _scene_viewport.get_texture())
	_resolve_material.set_shader_parameter(&"blend_texture", _blend_viewport.get_texture())
	_resolve_viewport = _make_canvas_pass("SMAAResolve", _render_size, _resolve_material)

	# Panini works on the finished opaque perceptual image. At Native that image
	# comes from resolve; reduced presets rebind this source to native-size EASU.
	_panini_material = ShaderMaterial.new()
	_record_explicit_allocation()
	_panini_material.shader = resources["panini_shader"]
	_panini_material.set_shader_parameter(
		&"source_texture", _resolve_viewport.get_texture())
	_panini_viewport = _make_canvas_pass(
		"PaniniProjection", _output_size, _panini_material)
	_panini_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_easu_shader = resources["easu_shader"]
	_present_material = ShaderMaterial.new()
	_record_explicit_allocation()
	_present_material.shader = resources["present_shader"]
	# _resize() binds the real source and sharpener; at Native that stays the
	# resolve target, and no EASU viewport is created.
	_present_material.set_shader_parameter(
		&"source_texture", _resolve_viewport.get_texture())
	_final_layer = CanvasLayer.new()
	_record_explicit_allocation()
	_final_layer.name = "RTFinalPost"
	_final_layer.layer = -100
	_final_rect = ColorRect.new()
	_record_explicit_allocation()
	_final_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_final_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_final_rect.material = _present_material
	_final_layer.add_child(_final_rect)
	_container.add_child(_final_layer)

	_active = true
	_resize(size)
	update(settings)
	_sync_camera()
	_initialization_allocation_count = _explicit_allocation_events
	# Initialization owns these objects for the stack lifetime; they are not a
	# runtime-frame allocation. Runtime update() calls accumulate separately.
	_pending_frame_allocation_count = 0
	# Switch only after every capture/pass resource is valid, preventing a blank
	# root viewport during partial initialization.
	_root_viewport.disable_3d = true
	return ""


func initialize(owner: Node, settings: Dictionary) -> String:
	return configure(owner, settings)


func update(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	if not _active:
		return
	var next_scale := _get_requested_render_scale(_settings)
	# Sample the root now so a quality change delivered in the same frame as a
	# window resize does not first allocate targets for the stale output size.
	var next_output_size := _output_size
	if _root_viewport != null and is_instance_valid(_root_viewport):
		var visible_size := Vector2i(_root_viewport.get_visible_rect().size)
		if visible_size.x > 0 and visible_size.y > 0:
			next_output_size = visible_size
	var next_render_size := _scaled_render_size(next_output_size, next_scale)
	if (
		next_output_size != _output_size
		or next_scale != _requested_render_scale
		or next_render_size != _render_size
	):
		_requested_render_scale = next_scale
		_resize(next_output_size)
	var aa_enabled := bool(settings.get("post_anti_aliasing_enabled", settings.get("anti_aliasing_enabled", true)))
	var quality := clampi(int(settings.get("post_smaa_quality", settings.get("quality", 2))), 0, 2)
	_record_explicit_allocation()
	var contract := RTVisualContract.new()
	contract.quality = quality
	var preset := contract.get_smaa_preset()
	_edge_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if aa_enabled else SubViewport.UPDATE_DISABLED
	_blend_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if aa_enabled else SubViewport.UPDATE_DISABLED
	_edge_material.set_shader_parameter(&"threshold", preset["threshold"])
	_blend_material.set_shader_parameter(&"max_search_steps", preset["max_search_steps"])
	_blend_material.set_shader_parameter(&"max_diagonal_steps", preset["max_diagonal_steps"])
	_blend_material.set_shader_parameter(&"diagonal_detection_enabled", preset["diagonal_detection_enabled"])
	_blend_material.set_shader_parameter(&"corner_detection_enabled", preset["corner_detection_enabled"])
	_blend_material.set_shader_parameter(&"corner_rounding", preset["corner_rounding"])
	# AA is a real two-pass bypass plus a resolve-pass branch; the present pass
	# never knows whether SMAA ran.
	_resolve_material.set_shader_parameter(&"aa_enabled", aa_enabled)
	_present_material.set_shader_parameter(&"grade_enabled", bool(settings.get("enabled", settings.get("retro_post_enabled", true))))
	_present_material.set_shader_parameter(
		&"cas_sharpness", _get_cas_sharpness(_settings))
	_present_material.set_shader_parameter(
		&"fsr_sharpness", _get_fsr_sharpness(_settings))
	# CAS can be toggled without a resize, so re-resolve the sharpener here too.
	_present_material.set_shader_parameter(&"sharpen_mode", _sharpen_mode())
	var environment := settings.get("environment", {}) as Dictionary
	var environment_mode := int(environment.get("mode", 0))
	var fallback: Color = environment.get("fallback_linear", Color.BLACK)
	var inverse_basis: Basis = environment.get("inverse_sky_basis", Basis.IDENTITY)
	var scene_input_linear := _scene_viewport.use_hdr_2d
	var recover_opaque_coverage := (
		bool(settings.get("recover_opaque_coverage_from_rgb", false)))
	var panorama: Texture2D
	if environment_mode == 1:
		panorama = environment.get("panorama") as Texture2D
	# Only the two passes that read SceneCapture reconstruct the environment and
	# decode coverage. The present pass consumes an already-composited image.
	for post_material in [_edge_material, _resolve_material]:
		post_material.set_shader_parameter(&"scene_input_is_linear", scene_input_linear)
		post_material.set_shader_parameter(
			&"recover_opaque_coverage_from_rgb",
			recover_opaque_coverage)
		post_material.set_shader_parameter(&"environment_mode", environment_mode)
		post_material.set_shader_parameter(
			&"environment_flat_linear", Vector3(fallback.r, fallback.g, fallback.b))
		post_material.set_shader_parameter(&"environment_panorama", panorama)
		post_material.set_shader_parameter(&"environment_basis_x", inverse_basis.x)
		post_material.set_shader_parameter(&"environment_basis_y", inverse_basis.y)
		post_material.set_shader_parameter(&"environment_basis_z", inverse_basis.z)
	for parameter in [&"brightness", &"contrast", &"saturation", &"black_point", &"color_balance", &"posterize_enabled", &"posterize_levels", &"posterize_strength"]:
		var manager_name := StringName("post_" + String(parameter))
		if settings.has(parameter) or settings.has(manager_name):
			_present_material.set_shader_parameter(parameter, settings.get(parameter, settings.get(manager_name)))
	# A settings dialog may run while the SceneTree is paused. Re-evaluate the
	# source camera synchronously so enabling/disabling Panini changes the bound
	# presentation source in this call rather than waiting for _process.
	_sync_camera()


func process_frame() -> String:
	# update() can run earlier in RTSceneManager's same frame when settings or an
	# environment revision changes. Consume its explicit Resource construction
	# here so the per-frame metric does not incorrectly stay hard-coded at zero.
	_last_frame_allocation_count = _pending_frame_allocation_count
	_pending_frame_allocation_count = 0
	_peak_frame_allocation_count = maxi(
		_peak_frame_allocation_count, _last_frame_allocation_count)
	if not _active:
		return "The shared post stack is not active."
	if not _reservation_is_current():
		return "The shared post stack no longer owns its root Viewport."
	var next_size := Vector2i(_root_viewport.get_visible_rect().size)
	if next_size.x < 1 or next_size.y < 1:
		return "The root viewport became empty."
	RTVisualContract.apply_native_viewport_state(_root_viewport, next_size)
	var contract_failure := RTVisualContract.native_viewport_failure(
		_root_viewport, next_size)
	if not contract_failure.is_empty():
		return (
			"The platform stopped honoring the shared viewport contract: %s."
			% contract_failure)
	if next_size != _output_size:
		_resize(next_size)
	_sync_camera()
	_scene_capture_frames += 1
	# SMAAResolve always runs; with AA off it degrades to a 1:1 texel decode.
	_resolve_frames += 1
	if _edge_viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		_edge_frames += 1
		_blend_frames += 1
	if _easu_viewport != null:
		_easu_frames += 1
	if _panini_active:
		_panini_frames += 1
	# Include any future explicit allocations added directly to process_frame().
	_last_frame_allocation_count += _pending_frame_allocation_count
	_pending_frame_allocation_count = 0
	_peak_frame_allocation_count = maxi(
		_peak_frame_allocation_count, _last_frame_allocation_count)
	return ""


func shutdown() -> void:
	var owns_current_reservation := _reservation_is_current()
	if (
			owns_current_reservation
			and _root_state_captured
			and _root_viewport
			and is_instance_valid(_root_viewport)
	):
		_root_viewport.disable_3d = _root_disable_3d
		RTVisualContract.restore_viewport_state(_root_viewport, _root_state)
	if owns_current_reservation:
		_root_viewport.remove_meta(VIEWPORT_OWNER_META)
	if _container and is_instance_valid(_container):
		if _container.is_inside_tree():
			var container_parent := _container.get_parent()
			if container_parent:
				container_parent.remove_child(_container)
			_container.free()
		else:
			_container.free()
	_active = false
	_owns_root_viewport = false
	_root_state_captured = false
	_owner = null
	_root_viewport = null
	_root_state = {}
	_root_disable_3d = false
	_container = null
	_scene_viewport = null
	_internal_camera = null
	_edge_viewport = null
	_blend_viewport = null
	_resolve_viewport = null
	_easu_viewport = null
	_panini_viewport = null
	_final_layer = null
	_final_rect = null
	_edge_material = null
	_blend_material = null
	_resolve_material = null
	_easu_material = null
	_panini_material = null
	_easu_shader = null
	_present_material = null
	_root_state = {}
	_source_camera_instance_id = 0
	_output_size = Vector2i.ZERO
	_render_size = Vector2i.ZERO
	_requested_render_scale = 1.0
	_panini_active = false
	_panini_requested = false
	_panini_camera_enabled = false
	_panini_camera_capable = false
	_panini_eligible = false
	_panini_bypass_reason = &"manager_disabled"
	_panini_display_horizontal_fov = 0.0
	_panini_capture_horizontal_fov = 0.0
	_panini_capture_vertical_fov = 0.0
	_panini_capture_tan_half_fov = Vector2.ONE
	_panini_mapped_rect_min = Vector2.ZERO
	_panini_mapped_rect_max = Vector2.ZERO
	_panini_source_uv_min = Vector2.ZERO
	_panini_source_uv_max = Vector2.ONE
	_panini_perimeter_samples = 0
	_panini_invalid_samples = 0
	_panini_contract_output_size = Vector2i.ZERO
	_panini_contract_render_size = Vector2i.ZERO
	_panini_contract_display_fov = 0.0
	_panini_cached_perimeter_size = Vector2i.ZERO
	_panini_cached_perimeter = PackedVector2Array()
	_panini_property_camera_instance_id = 0
	_panini_camera_has_enabled_property = false
	_panini_camera_has_display_fov_property = false


func get_profile_snapshot() -> Dictionary:
	var data_hdr_requested := (
		_edge_viewport != null
		and _blend_viewport != null
		and _resolve_viewport != null
		and _edge_viewport.use_hdr_2d
		and _blend_viewport.use_hdr_2d
		and _resolve_viewport.use_hdr_2d)
	var data_rgba := (
		_edge_viewport != null
		and _blend_viewport != null
		and _resolve_viewport != null
		and _edge_viewport.transparent_bg
		and _blend_viewport.transparent_bg
		and _resolve_viewport.transparent_bg)
	# Four owned render-size color targets (scene, edges, weights, resolve), one
	# persistent native-size Panini target, plus the native-size EASU target only
	# while the FSR path is active. Forward+ honors use_hdr_2d, so every one of
	# them is RGBA16F.
	var bytes_per_target_pixel := 8
	var panini_buffer_bytes := (
		_output_size.x * _output_size.y * bytes_per_target_pixel
		if _panini_viewport != null else 0)
	var persistent_bytes := (
		_render_size.x * _render_size.y * bytes_per_target_pixel * 4)
	persistent_bytes += panini_buffer_bytes
	if _easu_viewport != null:
		persistent_bytes += _output_size.x * _output_size.y * bytes_per_target_pixel
	var pass_timings := _measured_pass_timings()
	var sharpen_mode := _sharpen_mode() if _active else SHARPEN_NONE
	var sharpen_name: StringName = &"none"
	if sharpen_mode == SHARPEN_CAS:
		sharpen_name = &"cas"
	elif sharpen_mode == SHARPEN_RCAS:
		sharpen_name = &"rcas"
	return {
		"post_pass_gpu_ms": pass_timings,
		"post_anti_aliasing_enabled": bool(_settings.get("post_anti_aliasing_enabled", true)),
		"post_smaa_quality": int(_settings.get("post_smaa_quality", 2)),
		"post_smaa_quality_name": RTVisualContract.quality_name(int(_settings.get("post_smaa_quality", 2))),
		"post_input_transfer": (
			&"scene_linear" if (_scene_viewport != null and _scene_viewport.use_hdr_2d)
			else &"srgb_to_scene_linear"),
		"post_output_transfer": &"explicit_scene_linear_to_srgb",
		"post_retro_grade_enabled": bool(
			_settings.get("enabled", _settings.get("retro_post_enabled", true))),
		"post_posterize_enabled": bool(_settings.get("posterize_enabled", false)),
		"post_environment_revision": int((_settings.get("environment", {}) as Dictionary).get("revision", 0)),
		"post_environment_composite": true,
		"post_recovers_hardware_opaque_coverage": (
			bool(_settings.get("recover_opaque_coverage_from_rgb", false))),
		# Output remains root-native. All ray tracing and SMAA source sampling use
		# the independently rounded internal render size.
		"post_native_size": _output_size,
		"post_output_size": _output_size,
		"post_render_size": _render_size,
		"post_requested_render_scale": _requested_render_scale,
		"post_effective_render_scale": Vector2(
			float(_render_size.x) / float(maxi(_output_size.x, 1)),
			float(_render_size.y) / float(maxi(_output_size.y, 1))),
		"post_resolution_method": (
			&"native" if _render_size == _output_size else &"internal_subviewport"),
		"post_rendered_pixels": _render_size.x * _render_size.y,
		"post_smaa_viewport_size": _render_size,
		"post_final_presentation_size": (
			Vector2i(_final_rect.size) if _final_rect != null else Vector2i.ZERO),
		"post_internal_camera_active": (
			_internal_camera != null and _internal_camera.is_current()),
		"post_internal_camera_source_instance_id": _source_camera_instance_id,
		"post_internal_camera_compositor_is_null": (
			_internal_camera == null or _internal_camera.compositor == null),
		"post_internal_camera_environment_matches": _camera_environment_matches(),
		"post_internal_camera_attributes_matches": _camera_attributes_match(),
		"post_internal_camera_visual_state_matches": _camera_visual_state_matches(),
		"post_internal_camera_source_visual_state_exact": (
			_camera_source_visual_state_exact()),
		"post_internal_camera_capture_override": _panini_active,
		"post_persistent_buffer_bytes": persistent_bytes,
		"post_data_viewports_hdr": data_hdr_requested,
		"post_data_viewports_hdr_requested": data_hdr_requested,
		"post_data_viewports_rgba": data_rgba,
		"post_scene_viewport_hdr": (
			_scene_viewport != null and _scene_viewport.use_hdr_2d),
		"post_scene_viewport_hdr_requested": (
			_scene_viewport != null and _scene_viewport.use_hdr_2d),
		# Instrumented explicit Node/Resource construction since the preceding
		# process_frame(), including update() work consumed by the current frame.
		# Normal frames reuse every post object, so this is expected to remain 0.
		"post_per_frame_allocation_count": _last_frame_allocation_count,
		"post_per_frame_allocation_peak": _peak_frame_allocation_count,
		"post_initialization_allocation_count": _initialization_allocation_count,
		"post_explicit_allocation_events": _explicit_allocation_events,
		"post_pending_allocation_count": _pending_frame_allocation_count,
		"post_resize_count": _resize_count,
		"post_resize_last_usec": _resize_last_usec,
		"post_resize_peak_usec": _resize_peak_usec,
		"post_scene_capture_frames": _scene_capture_frames,
		"post_edge_frames": _edge_frames,
		"post_blend_frames": _blend_frames,
		"post_resolve_frames": _resolve_frames,
		"post_easu_frames": _easu_frames,
		"post_panini_frames": _panini_frames,
		# FSR 1 is the only upscaler; there is no bilinear reconstruction path.
		# Native bypasses it entirely and allocates no upscale target.
		"post_fsr_active": _active and _fsr_required(),
		"post_upscale_method": (
			&"fsr1_easu_rcas" if _active and _fsr_required() else &"none"),
		"post_fsr_input_size": _render_size if _active and _fsr_required() else Vector2i.ZERO,
		"post_fsr_output_size": _output_size if _active and _fsr_required() else Vector2i.ZERO,
		"post_fsr_sharpness": _get_fsr_sharpness(_settings),
		"post_easu_viewport_size": (
			_easu_viewport.size if _easu_viewport != null else Vector2i.ZERO),
		"post_panini_requested": _panini_requested,
		"post_panini_camera_capable": _panini_camera_capable,
		"post_panini_camera_enabled": _panini_camera_enabled,
		"post_panini_eligible": _panini_eligible,
		"post_panini_enabled": _panini_active,
		"post_panini_bypass_reason": _panini_bypass_reason,
		"post_panini_projection": &"classic_d1_s0",
		"post_panini_sample_mode": &"catmull_rom_or_box",
		"post_panini_sample_taps_min": 4,
		"post_panini_sample_taps_max": 6,
		"post_panini_output_domain": &"native",
		"post_panini_target_persistent": _panini_viewport != null,
		"post_panini_buffer_bytes": panini_buffer_bytes,
		"post_panini_viewport_size": (
			_panini_viewport.size if _panini_viewport != null else Vector2i.ZERO),
		"post_panini_source_size": _output_size,
		"post_panini_source_stage": (
			&"fsr_easu" if _easu_viewport != null else &"smaa_resolve"),
		"post_panini_display_horizontal_fov": _panini_display_horizontal_fov,
		"post_panini_capture_horizontal_fov": _panini_capture_horizontal_fov,
		"post_panini_capture_vertical_fov": _panini_capture_vertical_fov,
		"post_panini_capture_tan_half_fov": _panini_capture_tan_half_fov,
		"post_panini_mapped_rect_min": _panini_mapped_rect_min,
		"post_panini_mapped_rect_max": _panini_mapped_rect_max,
		"post_panini_source_uv_min": _panini_source_uv_min,
		"post_panini_source_uv_max": _panini_source_uv_max,
		"post_panini_perimeter_samples": _panini_perimeter_samples,
		"post_panini_invalid_samples": _panini_invalid_samples,
		"post_panini_bounds_valid": _panini_bounds_valid(),
		"post_present_source": (
			&"panini" if _panini_active
			else (&"fsr_easu" if _easu_viewport != null else &"smaa_resolve")),
		"post_sharpen_mode": sharpen_name,
		"post_cas_enabled": _active and _cas_enabled(),
		"post_cas_sharpness": _get_cas_sharpness(_settings),
	}


## Turns on the rendering server's own per-viewport GPU/CPU timers for every pass
## this stack owns, plus the root that presents them.
##
## The SMAA and present passes are 2D canvas draws inside SubViewports, so a
## CompositorEffect cannot bracket them with [method RenderingDevice.capture_timestamp]
## the way the ray dispatch is bracketed -- there is no render-thread hook to hang
## the markers on. This is the only mechanism that can attribute their cost, and
## it is the same one the editor's own frame profiler uses.
##
## Measurement is not free, so this follows [code]profiling_enabled[/code] rather
## than being left on.
func set_pass_profiling_enabled(enabled: bool) -> void:
	if _pass_profiling_enabled == enabled:
		return
	_pass_profiling_enabled = enabled
	for entry in _profiled_viewports():
		var viewport: Viewport = entry[1]
		if viewport != null and viewport.get_viewport_rid().is_valid():
			RenderingServer.viewport_set_measure_render_time(
				viewport.get_viewport_rid(), enabled)


## Named GPU milliseconds per owned pass, empty while profiling is off.
func _measured_pass_timings() -> Dictionary:
	if not _pass_profiling_enabled:
		return {}
	var timings: Dictionary = {}
	for entry in _profiled_viewports():
		var viewport: Viewport = entry[1]
		if viewport == null or not viewport.get_viewport_rid().is_valid():
			continue
		timings[entry[0]] = (
			RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid()))
	return timings


## Label/viewport pairs in execution order. The root is last because it presents
## what the others produced.
func _profiled_viewports() -> Array:
	var entries: Array = [
		[&"scene", _scene_viewport],
		[&"smaa_edges", _edge_viewport],
		[&"smaa_weights", _blend_viewport],
		[&"smaa_resolve", _resolve_viewport],
	]
	if _easu_viewport != null:
		entries.append([&"fsr_easu", _easu_viewport])
	entries.append([&"panini", _panini_viewport])
	entries.append([&"root_present", _root_viewport])
	return entries


func get_debug_stage_images() -> Dictionary:
	# Validation-only readback seam. Normal runtime never calls this method.
	return {
		"scene": (
			_scene_viewport.get_texture().get_image()
			if _scene_viewport != null else null),
		"edges": (
			_edge_viewport.get_texture().get_image()
			if _edge_viewport != null else null),
		"weights": (
			_blend_viewport.get_texture().get_image()
			if _blend_viewport != null else null),
		"resolve": (
			_resolve_viewport.get_texture().get_image()
			if _resolve_viewport != null else null),
		# Null at Native, where no EASU target exists.
		"easu": (
			_easu_viewport.get_texture().get_image()
			if _easu_viewport != null else null),
		# Null while directly bypassed; the persistent target may never have drawn.
		"panini": (
			_panini_viewport.get_texture().get_image()
			if _panini_active and _panini_viewport != null else null),
	}


func get_output_size() -> Vector2i:
	return _output_size


func get_render_size() -> Vector2i:
	return _render_size


## The SubViewport every 3D pass actually renders into.
##
## Exposed because the root Viewport has [code]disable_3d[/code] set, so anything
## that has to reach the real 3D render target -- renderer visibility statistics,
## occlusion culling, variable rate shading -- addresses this one or addresses
## nothing. Callers configure the render target; they must not reparent it, resize
## it or replace its world, all of which this stack owns and re-asserts.
func get_scene_viewport() -> SubViewport:
	return _scene_viewport


func get_debug_contract_snapshot() -> Dictionary:
	# Validation-only seam for confirming that presentation and every SMAA source
	# texture stay in their intended pixel domains after a quality switch.
	return {
		"output_size": _output_size,
		"render_size": _render_size,
		"scene_viewport_size": _scene_viewport.size if _scene_viewport else Vector2i.ZERO,
		"edge_viewport_size": _edge_viewport.size if _edge_viewport else Vector2i.ZERO,
		"blend_viewport_size": _blend_viewport.size if _blend_viewport else Vector2i.ZERO,
		"resolve_viewport_size": (
			_resolve_viewport.size if _resolve_viewport else Vector2i.ZERO),
		# Zero at Native: the upscale target is not allocated there at all.
		"easu_viewport_size": _easu_viewport.size if _easu_viewport else Vector2i.ZERO,
		"panini_viewport_size": (
			_panini_viewport.size if _panini_viewport else Vector2i.ZERO),
		"panini_buffer_bytes": (
			_output_size.x * _output_size.y * 8 if _panini_viewport else 0),
		"final_presentation_size": (
			Vector2i(_final_rect.size) if _final_rect else Vector2i.ZERO),
		"edge_uniform_size": _shader_viewport_size(_edge_material),
		"blend_uniform_size": _shader_viewport_size(_blend_material),
		"resolve_uniform_size": _shader_viewport_size(_resolve_material),
		# The present pass has no source-texel-domain uniform; its source is
		# always 1:1 with the rect. These two are the FSR reconstruction domain.
		"easu_uniform_input_size": _shader_vector2i_parameter(
			_easu_material, &"easu_input_size"),
		"easu_uniform_output_size": _shader_vector2i_parameter(
			_easu_material, &"easu_output_size"),
		"panini_uniform_source_size": _shader_vector2i_parameter(
			_panini_material, &"source_size"),
		"panini_active": _panini_active,
		"panini_requested": _panini_requested,
		"panini_eligible": _panini_eligible,
		"panini_bypass_reason": _panini_bypass_reason,
		"panini_display_horizontal_fov": _panini_display_horizontal_fov,
		"panini_capture_horizontal_fov": _panini_capture_horizontal_fov,
		"panini_capture_vertical_fov": _panini_capture_vertical_fov,
		"panini_capture_tan_half_fov": _panini_capture_tan_half_fov,
		"panini_source_uv_min": _panini_source_uv_min,
		"panini_source_uv_max": _panini_source_uv_max,
		"panini_perimeter_samples": _panini_perimeter_samples,
		"panini_invalid_samples": _panini_invalid_samples,
		"panini_sample_mode": &"catmull_rom_or_box",
		"panini_sample_taps_min": 4,
		"panini_sample_taps_max": 6,
		"panini_bounds_valid": _panini_bounds_valid(),
		"fsr_active": _active and _fsr_required(),
		"sharpen_mode": _sharpen_mode() if _active else SHARPEN_NONE,
		"internal_camera_current": (
			_internal_camera != null and _internal_camera.is_current()),
		"internal_camera_source_instance_id": _source_camera_instance_id,
		"internal_camera_compositor_is_null": (
			_internal_camera == null or _internal_camera.compositor == null),
		"internal_camera_environment_matches": _camera_environment_matches(),
		"internal_camera_attributes_matches": _camera_attributes_match(),
		"internal_camera_visual_state_matches": _camera_visual_state_matches(),
		"internal_camera_source_visual_state_exact": (
			_camera_source_visual_state_exact()),
	}


func _make_viewport(viewport_name: String, size: Vector2i) -> SubViewport:
	var viewport := SubViewport.new()
	_record_explicit_allocation()
	viewport.name = viewport_name
	viewport.transparent_bg = false
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	RTVisualContract.apply_native_viewport_state(viewport, size)
	return viewport


func _make_canvas_pass(pass_name: String, size: Vector2i, material: Material) -> SubViewport:
	var viewport := _make_viewport(pass_name, size)
	viewport.disable_3d = true
	# Every canvas pass is one full-rect ColorRect running a blend_disabled shader
	# that assigns all four channels of COLOR, so it defines every texel of its
	# target before anything reads it -- including the first frame after an
	# allocation or a resize. Clearing first is a second full-target write for
	# nothing, and at 2560x1440 RGBA16F these are 28 MB each.
	#
	# The scene capture keeps its clear: it is a real 3D render into a transparent
	# target, where uncovered pixels are the point.
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	# The SMAA blend pass stores a real directional weight in alpha, so the
	# target has to be RGBA rather than RGB-only.
	viewport.transparent_bg = true
	# Edge/blend textures are numerical data, and Forward+ honors this as
	# RGBA16F. Quantizing them to 8 bits would quantize the weights.
	viewport.use_hdr_2d = true
	var rect := ColorRect.new()
	_record_explicit_allocation()
	rect.name = "Pass"
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = material
	viewport.add_child(rect)
	_container.add_child(viewport)
	return viewport


func _record_explicit_allocation() -> void:
	_explicit_allocation_events += 1
	_pending_frame_allocation_count += 1


func _resize(output_size: Vector2i) -> void:
	var resize_started := Time.get_ticks_usec()
	_output_size = output_size
	_render_size = _scaled_render_size(_output_size, _requested_render_scale)
	var aa_enabled := bool(_settings.get("post_anti_aliasing_enabled", true))
	for viewport in [
		_scene_viewport, _edge_viewport, _blend_viewport, _resolve_viewport
	]:
		RTVisualContract.apply_native_viewport_state(viewport, _render_size)
	# Root/final presentation is deliberately LDR, but SMAA intermediate values
	# are numerical data and use HDR 2D wherever the renderer supports it.
	_scene_viewport.use_hdr_2d = true
	_edge_viewport.use_hdr_2d = true
	_blend_viewport.use_hdr_2d = true
	_resolve_viewport.use_hdr_2d = true
	RTVisualContract.apply_native_viewport_state(_panini_viewport, _output_size)
	_panini_viewport.use_hdr_2d = true
	_panini_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if _panini_active else SubViewport.UPDATE_DISABLED)
	# Applying native state sizes a SubViewport and defaults it to UPDATE_ALWAYS.
	# Restore the two real AA bypass states after every resize. SMAAResolve keeps
	# updating either way: with AA off it becomes an exact 1:1 texel decode, and
	# it is still the FSR/present source.
	_edge_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if aa_enabled else SubViewport.UPDATE_DISABLED)
	_blend_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if aa_enabled else SubViewport.UPDATE_DISABLED)
	# These three uniforms describe the SMAA source texture texel domain, which
	# is the internal render size on every preset. The present pass deliberately
	# has no such uniform: its source is always 1:1 with the rect it covers.
	_edge_material.set_shader_parameter(&"viewport_size", Vector2(_render_size))
	_blend_material.set_shader_parameter(&"viewport_size", Vector2(_render_size))
	_resolve_material.set_shader_parameter(&"viewport_size", Vector2(_render_size))
	_panini_material.set_shader_parameter(&"source_size", Vector2(_output_size))
	# Owns the whole FSR lifecycle, because this is the single place both sizes
	# are recomputed.
	_update_fsr_targets()
	_resize_last_usec = Time.get_ticks_usec() - resize_started
	_resize_peak_usec = maxi(_resize_peak_usec, _resize_last_usec)
	_resize_count += 1


## FSR 1 runs if and only if the internal render size differs from the native
## output size. Native is therefore a true bypass: no EASU, no RCAS, and no
## upscale buffer allocated at all.
func _fsr_required() -> bool:
	return _render_size != _output_size


func _get_cas_sharpness(settings: Dictionary) -> float:
	var value := float(settings.get(
		"post_cas_sharpness", settings.get("cas_sharpness", 0.15)))
	if value != value:
		return 0.0
	return clampf(value, 0.0, 1.0)


## RCAS attenuation in stops, per the reference FsrRcasCon: 0.0 is maximum
## sharpness and 2.0 the minimum. The shader applies exp2(-value).
func _get_fsr_sharpness(settings: Dictionary) -> float:
	var value := float(settings.get(
		"post_fsr_sharpness", settings.get("fsr_sharpness", 0.5)))
	if value != value:
		return 0.5
	return clampf(value, 0.0, 2.0)


func _cas_enabled() -> bool:
	return (
		bool(_settings.get("post_cas_enabled", _settings.get("cas_enabled", false)))
		and _get_cas_sharpness(_settings) > 0.0)


func _sharpen_mode() -> int:
	# RCAS is part of FSR and never runs at Native. CAS is the Native-only
	# optional sharpener and is never stacked on top of RCAS.
	if _fsr_required():
		return SHARPEN_RCAS
	return SHARPEN_CAS if _cas_enabled() else SHARPEN_NONE


func _update_fsr_targets() -> void:
	if _fsr_required():
		if _easu_viewport == null:
			_easu_material = ShaderMaterial.new()
			_record_explicit_allocation()
			_easu_material.shader = _easu_shader
			_easu_material.set_shader_parameter(
				&"source_texture", _resolve_viewport.get_texture())
			_easu_viewport = _make_canvas_pass(
				"FSREASU", _output_size, _easu_material)
		else:
			# Already on the FSR path; resize in place rather than reallocating.
			RTVisualContract.apply_native_viewport_state(_easu_viewport, _output_size)
			_easu_viewport.use_hdr_2d = true
		# Both EASU constants are refreshed whenever either dimension moves, so a
		# window resize and a quality switch are equally safe.
		_easu_material.set_shader_parameter(&"easu_input_size", Vector2(_render_size))
		_easu_material.set_shader_parameter(&"easu_output_size", Vector2(_output_size))
		_apply_present_source()
		return

	if _easu_viewport == null:
		_apply_present_source()
		return

	# Leaving the FSR path. Rebind the present pass before the upscale target
	# leaves the tree, so no ViewportTexture is left dangling and no frame is
	# presented from a freed target.
	var retired := _easu_viewport
	_easu_viewport = null
	_easu_material = null
	_apply_present_source()
	var retired_parent := retired.get_parent()
	if retired_parent != null:
		retired_parent.remove_child(retired)
	retired.queue_free()


func _apply_present_source() -> void:
	# Every branch entering Panini is already native-size and perceptual: resolve
	# at Native, EASU at a reduced preset. Bypass binds that source straight to
	# present; the active path inserts the persistent native-size projection.
	var pre_panini_source: Texture2D = (
		_easu_viewport.get_texture() if _easu_viewport != null
		else _resolve_viewport.get_texture())
	_panini_material.set_shader_parameter(&"source_texture", pre_panini_source)
	_panini_material.set_shader_parameter(&"source_size", Vector2(_output_size))
	var present_source: Texture2D = (
		_panini_viewport.get_texture() if _panini_active
		else pre_panini_source)
	_present_material.set_shader_parameter(&"source_texture", present_source)
	_present_material.set_shader_parameter(&"sharpen_mode", _sharpen_mode())


func _sync_camera() -> void:
	var source_camera := _root_viewport.get_camera_3d()
	_source_camera_instance_id = (
		source_camera.get_instance_id() if source_camera != null else 0)
	if source_camera == null:
		_resolve_panini_state(null)
		if _internal_camera != null and _internal_camera.is_current():
			_internal_camera.clear_current(false)
		return

	# Copy only the authored camera state needed to reproduce its view. In
	# particular, never copy Camera3D.compositor: hardware RT is installed on the
	# shared World3D scenario by RTSceneManager and must stay authoritative.
	_internal_camera.global_transform = source_camera.global_transform
	_internal_camera.projection = source_camera.projection
	_internal_camera.fov = source_camera.fov
	_internal_camera.size = source_camera.size
	_internal_camera.frustum_offset = source_camera.frustum_offset
	_internal_camera.h_offset = source_camera.h_offset
	_internal_camera.v_offset = source_camera.v_offset
	_internal_camera.near = source_camera.near
	_internal_camera.far = source_camera.far
	_internal_camera.keep_aspect = source_camera.keep_aspect
	_internal_camera.cull_mask = source_camera.cull_mask
	_internal_camera.environment = source_camera.environment
	_internal_camera.attributes = source_camera.attributes
	# The authored camera keeps its display projection. Only the private camera
	# may widen to the conservative rectilinear frustum Panini needs as input.
	_resolve_panini_state(source_camera)
	if not _internal_camera.is_current():
		_internal_camera.make_current()

	var width := float(maxi(_render_size.x, 1))
	var height := float(maxi(_render_size.y, 1))
	var top_left := _camera_ray(_internal_camera, Vector2.ZERO)
	var top_right := _camera_ray(_internal_camera, Vector2(width, 0.0))
	var bottom_left := _camera_ray(_internal_camera, Vector2(0.0, height))
	var bottom_right := _camera_ray(_internal_camera, Vector2(width, height))
	for post_material in [_edge_material, _resolve_material]:
		post_material.set_shader_parameter(&"camera_ray_top_left", top_left)
		post_material.set_shader_parameter(&"camera_ray_top_right", top_right)
		post_material.set_shader_parameter(&"camera_ray_bottom_left", bottom_left)
		post_material.set_shader_parameter(&"camera_ray_bottom_right", bottom_right)


func _resolve_panini_state(source_camera: Camera3D) -> void:
	_panini_requested = bool(_settings.get("post_panini_enabled", false))
	_cache_panini_camera_properties(source_camera)
	_panini_camera_capable = (
		source_camera != null
		and _panini_camera_has_enabled_property
		and (
			_panini_camera_has_display_fov_property
			or source_camera.has_method(&"get_display_horizontal_fov")))
	_panini_camera_enabled = false
	_panini_eligible = false

	if source_camera == null:
		_panini_bypass_reason = &"no_source_camera"
		_set_panini_active(false)
		return
	if not _panini_requested:
		_panini_bypass_reason = &"manager_disabled"
		_set_panini_active(false)
		return
	if not _panini_camera_capable:
		_panini_bypass_reason = &"camera_unsupported"
		_set_panini_active(false)
		return

	_panini_camera_enabled = bool(source_camera.get(&"panini_enabled"))
	if not _panini_camera_enabled:
		_panini_bypass_reason = &"camera_disabled"
		_set_panini_active(false)
		return
	if source_camera.projection != Camera3D.PROJECTION_PERSPECTIVE:
		_panini_bypass_reason = &"non_perspective_camera"
		_set_panini_active(false)
		return
	# The inverse mapping and conservative bounds are intentionally symmetric.
	# Reject shifted frusta instead of silently sampling rays that do not match
	# their projection center. The FPS camera uses the normal zero-offset path.
	if (
		not is_zero_approx(source_camera.h_offset)
		or not is_zero_approx(source_camera.v_offset)
	):
		_panini_bypass_reason = &"camera_offset_unsupported"
		_set_panini_active(false)
		return

	var display_fov_variant: Variant
	if source_camera.has_method(&"get_display_horizontal_fov"):
		display_fov_variant = source_camera.call(&"get_display_horizontal_fov")
	else:
		display_fov_variant = source_camera.get(&"display_horizontal_fov")
	if not (display_fov_variant is float or display_fov_variant is int):
		_panini_bypass_reason = &"invalid_display_fov"
		_set_panini_active(false)
		return
	var display_fov := float(display_fov_variant)
	if (
		not is_finite(display_fov)
		or display_fov < PANINI_MIN_HORIZONTAL_FOV
		or display_fov > PANINI_MAX_HORIZONTAL_FOV
	):
		_panini_bypass_reason = &"invalid_display_fov"
		_set_panini_active(false)
		return

	if (
		_panini_contract_output_size != _output_size
		or _panini_contract_render_size != _render_size
		or not is_equal_approx(_panini_contract_display_fov, display_fov)
	):
		_apply_panini_capture_contract(display_fov)
	if not _panini_mapping_inside_source():
		_panini_bypass_reason = &"capture_bounds_invalid"
		_set_panini_active(false)
		return

	# Camera3D.fov follows keep_aspect. The authored RTPaniniCamera3D remains
	# KEEP_WIDTH with the requested horizontal display FOV; the capture switches
	# to KEEP_HEIGHT with the independently derived conservative vertical FOV.
	_internal_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_internal_camera.fov = _panini_capture_vertical_fov
	_panini_eligible = true
	_panini_bypass_reason = &"none"
	_set_panini_active(true)


func _cache_panini_camera_properties(camera: Camera3D) -> void:
	var instance_id := camera.get_instance_id() if camera != null else 0
	if instance_id == _panini_property_camera_instance_id:
		return
	_panini_property_camera_instance_id = instance_id
	_panini_camera_has_enabled_property = false
	_panini_camera_has_display_fov_property = false
	if camera == null:
		return
	for property: Dictionary in camera.get_property_list():
		var property_name := StringName(property.get("name", ""))
		if property_name == &"panini_enabled":
			_panini_camera_has_enabled_property = true
		elif property_name == &"display_horizontal_fov":
			_panini_camera_has_display_fov_property = true


func _set_panini_active(enabled: bool) -> void:
	if _panini_active == enabled:
		return
	_panini_active = enabled
	if _panini_viewport != null:
		_panini_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED)
	if _panini_material != null and _present_material != null:
		_apply_present_source()


func _apply_panini_capture_contract(display_horizontal_fov: float) -> void:
	# Border coordinates depend only on the native output dimensions. Cache the
	# complete scan perimeter so a smoothed sprint transition recomputes the
	# nonlinear mapping without allocating thousands of points every frame.
	if _panini_cached_perimeter_size != _output_size:
		_panini_cached_perimeter_size = _output_size
		_panini_cached_perimeter = _panini_perimeter_points(_output_size)
	var contract := _debug_panini_capture_contract_with_perimeter(
		display_horizontal_fov,
		_output_size,
		_render_size,
		_panini_cached_perimeter)
	_panini_contract_output_size = _output_size
	_panini_contract_render_size = _render_size
	_panini_contract_display_fov = display_horizontal_fov
	_panini_display_horizontal_fov = display_horizontal_fov
	_panini_capture_horizontal_fov = float(contract.get("capture_horizontal_fov", 0.0))
	_panini_capture_vertical_fov = float(contract.get("capture_vertical_fov", 0.0))
	_panini_capture_tan_half_fov = contract.get(
		"capture_tan_half_fov", Vector2.ONE) as Vector2
	_panini_mapped_rect_min = contract.get("mapped_rect_min", Vector2.ZERO) as Vector2
	_panini_mapped_rect_max = contract.get("mapped_rect_max", Vector2.ZERO) as Vector2
	_panini_source_uv_min = contract.get("source_uv_min", Vector2.ZERO) as Vector2
	_panini_source_uv_max = contract.get("source_uv_max", Vector2.ONE) as Vector2
	_panini_perimeter_samples = int(contract.get("perimeter_samples", 0))
	_panini_invalid_samples = int(contract.get("invalid_samples", 0))
	_panini_material.set_shader_parameter(
		&"panini_extent_x", float(contract.get("panini_extent_x", 1.0)))
	_panini_material.set_shader_parameter(
		&"panini_extent_y", float(contract.get("panini_extent_y", 1.0)))
	_panini_material.set_shader_parameter(
		&"capture_tan_half_fov", _panini_capture_tan_half_fov)
	_panini_material.set_shader_parameter(&"source_size", Vector2(_output_size))


## Validation seam for the CPU half of the projection contract. Runtime calls it
## only after FOV or either size domain changes; tests can exercise aspect/FOV
## boundaries without constructing a renderer or reading back a framebuffer.
static func debug_panini_capture_contract(
		display_horizontal_fov: float,
		output_size: Vector2i,
		render_size: Vector2i) -> Dictionary:
	return _debug_panini_capture_contract_with_perimeter(
		display_horizontal_fov,
		output_size,
		render_size,
		_panini_perimeter_points(output_size))


static func _debug_panini_capture_contract_with_perimeter(
		display_horizontal_fov: float,
		output_size: Vector2i,
		render_size: Vector2i,
		perimeter: PackedVector2Array) -> Dictionary:
	if (
		output_size.x < 1
		or output_size.y < 1
		or render_size.x < 1
		or render_size.y < 1
		or perimeter.is_empty()
		or not is_finite(display_horizontal_fov)
		or display_horizontal_fov < PANINI_MIN_HORIZONTAL_FOV
		or display_horizontal_fov > PANINI_MAX_HORIZONTAL_FOV
	):
		return {"valid": false}

	var half_horizontal := deg_to_rad(display_horizontal_fov) * 0.5
	var panini_extent_x := (
		(PANINI_DISTANCE + 1.0) * sin(half_horizontal)
		/ (PANINI_DISTANCE + cos(half_horizontal)))
	var output_aspect := float(output_size.x) / float(output_size.y)
	var panini_extent_y := tan(half_horizontal) / output_aspect
	# The mapping's extrema over the output rectangle are closed-form, so finding
	# them needs no scan. mapped.x = tan(phi) is odd and strictly increasing in
	# output_ndc.x across the supported |phi| < 90 degrees, and
	# mapped.y = output_ndc.y * extent_y * (D + cos phi) / ((D + 1) * cos phi) is
	# linear in output_ndc.y and strictly increasing in |phi|. Both extrema land
	# on the four logical corners, which are members of the perimeter set, so
	# this returns exactly what a full border scan returns. Evaluating it
	# directly is what keeps a smoothed sprint FOV, which moves every frame, off
	# a multi-millisecond per-frame scan of every border texel center.
	var mapped_corner := _panini_inverse_rectilinear(
		Vector2.ONE, panini_extent_x, panini_extent_y)
	if not is_finite(mapped_corner.x) or not is_finite(mapped_corner.y):
		return {
			"valid": false,
			"perimeter_samples": perimeter.size(),
			"invalid_samples": perimeter.size(),
		}
	var mapped_max := mapped_corner
	var mapped_min := -mapped_corner

	var mapped_abs_x := absf(mapped_corner.x)
	var mapped_abs_y := absf(mapped_corner.y)
	# Keep the mapped perimeter at least half a source texel inside the capture.
	# EASU preserves normalized coordinates, so the source projection's aspect is
	# the internal render aspect even though Panini itself runs at native output.
	var horizontal_margin := maxf(
		1.0 - 1.0 / float(maxi(render_size.x, 2)), 0.5)
	var vertical_margin := maxf(
		1.0 - 1.0 / float(maxi(render_size.y, 2)), 0.5)
	var render_aspect := float(render_size.x) / float(render_size.y)
	var required_tan_x := mapped_abs_x / horizontal_margin
	var required_tan_y := mapped_abs_y / vertical_margin
	var capture_tan_y := maxf(required_tan_y, required_tan_x / render_aspect)
	var capture_tan_x := capture_tan_y * render_aspect
	var capture_tangent := Vector2(capture_tan_x, capture_tan_y)
	var capture_horizontal_fov := rad_to_deg(2.0 * atan(capture_tan_x))
	var capture_vertical_fov := rad_to_deg(2.0 * atan(capture_tan_y))

	var source_uv_min := Vector2(
		0.5 + 0.5 * mapped_min.x / capture_tan_x,
		0.5 - 0.5 * mapped_max.y / capture_tan_y)
	var source_uv_max := Vector2(
		0.5 + 0.5 * mapped_max.x / capture_tan_x,
		0.5 - 0.5 * mapped_min.y / capture_tan_y)
	# Count raw coordinates before the shader's final defensive clamp. The safe
	# range is inset by half an internal capture texel so a valid contract cannot
	# expose an unrendered border even after reduced-resolution reconstruction.
	var safe_uv_min := Vector2(
		0.5 / float(render_size.x), 0.5 / float(render_size.y))
	var safe_uv_max := Vector2.ONE - safe_uv_min
	var bounds_inside_safe := (
		source_uv_min.x >= safe_uv_min.x - 0.000001
		and source_uv_min.y >= safe_uv_min.y - 0.000001
		and source_uv_max.x <= safe_uv_max.x + 0.000001
		and source_uv_max.y <= safe_uv_max.y + 0.000001)
	# The extrema above bound the whole perimeter by construction, so valid
	# extrema prove every finite sample is inside the source. Only the
	# exceptional invalid-contract path scans the perimeter, and it does so to
	# retain an exact diagnostic count rather than to find the bounds.
	var invalid_samples := 0
	if not bounds_inside_safe:
		for point: Vector2 in perimeter:
			var mapped := _panini_inverse_rectilinear(
				point, panini_extent_x, panini_extent_y)
			var raw_uv := Vector2(
				0.5 + 0.5 * mapped.x / capture_tan_x,
				0.5 - 0.5 * mapped.y / capture_tan_y)
			if (
				not is_finite(raw_uv.x)
				or not is_finite(raw_uv.y)
				or raw_uv.x < safe_uv_min.x - 0.000001
				or raw_uv.y < safe_uv_min.y - 0.000001
				or raw_uv.x > safe_uv_max.x + 0.000001
				or raw_uv.y > safe_uv_max.y + 0.000001
			):
				invalid_samples += 1
	var valid := (
		is_finite(capture_horizontal_fov)
		and capture_horizontal_fov > 0.0
		and capture_horizontal_fov < 179.0
		and is_finite(capture_vertical_fov)
		and capture_vertical_fov > 0.0
		and capture_vertical_fov < 179.0
		and invalid_samples == 0
		and source_uv_min.x >= -0.00001
		and source_uv_min.y >= -0.00001
		and source_uv_max.x <= 1.00001
		and source_uv_max.y <= 1.00001)
	return {
		"valid": valid,
		"display_horizontal_fov": display_horizontal_fov,
		"output_aspect": output_aspect,
		"render_aspect": render_aspect,
		"panini_extent_x": panini_extent_x,
		"panini_extent_y": panini_extent_y,
		"capture_horizontal_fov": capture_horizontal_fov,
		"capture_vertical_fov": capture_vertical_fov,
		"capture_tan_half_fov": capture_tangent,
		"mapped_rect_min": mapped_min,
		"mapped_rect_max": mapped_max,
		"source_uv_min": source_uv_min,
		"source_uv_max": source_uv_max,
		"perimeter_samples": perimeter.size(),
		"invalid_samples": invalid_samples,
	}


## Every output border texel center plus the four logical viewport corners.
## The corners are deliberately additional samples: canvas fragment centers do
## not reach normalized 0/1, while resize/crop math still needs those limits.
static func _panini_perimeter_points(output_size: Vector2i) -> PackedVector2Array:
	var points := PackedVector2Array()
	var width := output_size.x
	var height := output_size.y
	if width < 1 or height < 1:
		return points
	if width == 1 or height == 1:
		for y in height:
			for x in width:
				points.append(Vector2(
					(2.0 * (float(x) + 0.5) / float(width)) - 1.0,
					(2.0 * (float(y) + 0.5) / float(height)) - 1.0))
	else:
		var top_y := (1.0 / float(height)) - 1.0
		var bottom_y := 1.0 - (1.0 / float(height))
		for x in width:
			var center_x := (2.0 * (float(x) + 0.5) / float(width)) - 1.0
			points.append(Vector2(center_x, top_y))
			points.append(Vector2(center_x, bottom_y))
		for y in range(1, height - 1):
			var center_y := (2.0 * (float(y) + 0.5) / float(height)) - 1.0
			points.append(Vector2((1.0 / float(width)) - 1.0, center_y))
			points.append(Vector2(1.0 - (1.0 / float(width)), center_y))
	points.append(Vector2(-1.0, -1.0))
	points.append(Vector2(1.0, -1.0))
	points.append(Vector2(-1.0, 1.0))
	points.append(Vector2(1.0, 1.0))
	return points


static func _panini_inverse_rectilinear(
		output_ndc: Vector2,
		panini_extent_x: float,
		panini_extent_y: float) -> Vector2:
	var panini_x := output_ndc.x * panini_extent_x
	var panini_y := output_ndc.y * panini_extent_y
	# Closed-form inverse of x_p=2*tan(phi/2) for D=1.
	var phi := 2.0 * atan(0.5 * panini_x)
	var cos_phi := maxf(cos(phi), 0.00001)
	var panini_scale := (PANINI_DISTANCE + 1.0) / (PANINI_DISTANCE + cos_phi)
	var tan_theta := panini_y / panini_scale
	return Vector2(tan(phi), tan_theta / cos_phi)


func _panini_mapping_inside_source() -> bool:
	return (
		is_finite(_panini_capture_vertical_fov)
		and is_finite(_panini_capture_horizontal_fov)
		and _panini_capture_horizontal_fov > 0.0
		and _panini_capture_horizontal_fov < 179.0
		and _panini_capture_vertical_fov > 0.0
		and _panini_capture_vertical_fov < 179.0
		and _panini_invalid_samples == 0
		and _panini_source_uv_min.x >= -0.00001
		and _panini_source_uv_min.y >= -0.00001
		and _panini_source_uv_max.x <= 1.00001
		and _panini_source_uv_max.y <= 1.00001)


func _panini_bounds_valid() -> bool:
	return _panini_eligible and _panini_mapping_inside_source()


func _camera_ray(camera: Camera3D, screen_point: Vector2) -> Vector3:
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return -camera.global_transform.basis.z
	# Unlike four normalized corner vectors, points projected onto one common
	# depth plane remain correct under asymmetric/frustum projection when the
	# shader interpolates them across the screen.
	return camera.project_position(screen_point, 1.0) - camera.global_position


func _get_requested_render_scale(settings: Dictionary) -> float:
	var requested := float(settings.get(
		"rt_render_scale", settings.get("render_scale", 1.0)))
	# Treat malformed/NaN input as Native. The public manager rejects invalid
	# presets, but this keeps the post stack safe as a standalone component.
	if requested != requested or requested <= 0.0:
		return 1.0
	return clampf(requested, 0.01, 1.0)


func _scaled_render_size(output_size: Vector2i, scale: float) -> Vector2i:
	return Vector2i(
		maxi(2, ceili(float(output_size.x) * scale)),
		maxi(2, ceili(float(output_size.y) * scale)))


func _source_camera() -> Camera3D:
	if _root_viewport == null or not is_instance_valid(_root_viewport):
		return null
	return _root_viewport.get_camera_3d()


func _camera_environment_matches() -> bool:
	var source := _source_camera()
	return (
		_internal_camera != null
		and source != null
		and _internal_camera.environment == source.environment)


func _camera_attributes_match() -> bool:
	var source := _source_camera()
	return (
		_internal_camera != null
		and source != null
		and _internal_camera.attributes == source.attributes)


func _camera_visual_state_matches() -> bool:
	var source := _source_camera()
	if _internal_camera == null or source == null:
		return false
	var expected_fov := (
		_panini_capture_vertical_fov if _panini_active else source.fov)
	var expected_keep_aspect := (
		Camera3D.KEEP_HEIGHT if _panini_active else source.keep_aspect)
	return (
		_internal_camera.global_transform.is_equal_approx(source.global_transform)
		and _internal_camera.projection == source.projection
		and is_equal_approx(_internal_camera.fov, expected_fov)
		and is_equal_approx(_internal_camera.size, source.size)
		and _internal_camera.frustum_offset.is_equal_approx(source.frustum_offset)
		and is_equal_approx(_internal_camera.h_offset, source.h_offset)
		and is_equal_approx(_internal_camera.v_offset, source.v_offset)
		and is_equal_approx(_internal_camera.near, source.near)
		and is_equal_approx(_internal_camera.far, source.far)
		and _internal_camera.keep_aspect == expected_keep_aspect
		and _internal_camera.cull_mask == source.cull_mask
		and _camera_environment_matches()
		and _camera_attributes_match())


func _camera_source_visual_state_exact() -> bool:
	var source := _source_camera()
	if _internal_camera == null or source == null:
		return false
	return (
		_internal_camera.global_transform.is_equal_approx(source.global_transform)
		and _internal_camera.projection == source.projection
		and is_equal_approx(_internal_camera.fov, source.fov)
		and is_equal_approx(_internal_camera.size, source.size)
		and _internal_camera.frustum_offset.is_equal_approx(source.frustum_offset)
		and is_equal_approx(_internal_camera.h_offset, source.h_offset)
		and is_equal_approx(_internal_camera.v_offset, source.v_offset)
		and is_equal_approx(_internal_camera.near, source.near)
		and is_equal_approx(_internal_camera.far, source.far)
		and _internal_camera.keep_aspect == source.keep_aspect
		and _internal_camera.cull_mask == source.cull_mask
		and _camera_environment_matches()
		and _camera_attributes_match())


func _shader_viewport_size(material: ShaderMaterial) -> Vector2i:
	return _shader_vector2i_parameter(material, &"viewport_size")


func _shader_vector2i_parameter(
		material: ShaderMaterial, parameter: StringName) -> Vector2i:
	if material == null:
		return Vector2i.ZERO
	var value: Variant = material.get_shader_parameter(parameter)
	if not (value is Vector2 or value is Vector2i):
		return Vector2i.ZERO
	return Vector2i(value)
