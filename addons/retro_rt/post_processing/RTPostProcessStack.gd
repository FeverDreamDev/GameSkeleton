extends RefCounted
class_name RTPostProcessStack

const RESOLVE_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/scene_resolve.gdshader"
const PANINI_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/panini_project.gdshader"
const PRESENT_SHADER_PATH := "res://addons/retro_rt/post_processing/shaders/retro_present.gdshader"
const VIEWPORT_OWNER_META := &"__rt_post_process_owner"
const PANINI_DISTANCE := 1.0
const PANINI_MIN_HORIZONTAL_FOV := 1.0
const PANINI_MAX_HORIZONTAL_FOV := 175.0
## Center sampling ratio the Panini capture is sized for: source texels per
## output pixel along the horizontal axis at screen center, where 1.0 means the
## projection magnifies nothing at all. See [method panini_capture_size].
const PANINI_MIN_CAPTURE_SHARPNESS := 0.25
const PANINI_MAX_CAPTURE_SHARPNESS := 1.0
const PANINI_DEFAULT_CAPTURE_SHARPNESS := 0.5
## Hard per-axis ceiling on the capture. Sharpness already bounds the request;
## this only keeps a pathological output size from asking for a target no driver
## will allocate.
const PANINI_MAX_CAPTURE_AXIS := 8192

var _owner: Node
var _root_viewport: Viewport
var _root_state: Dictionary = {}
var _root_disable_3d := false
var _owns_root_viewport := false
var _root_state_captured := false
var _container: Node
var _scene_viewport: SubViewport
var _internal_camera: Camera3D
## Resolves the scene capture: coverage decode plus environment reconstruction.
var _resolve_viewport: SubViewport
## Persistent native-output Panini target. It remains allocated while bypassed,
## but stops updating and the present pass reads the resolve target directly.
var _panini_viewport: SubViewport
## Whether the rendering server's per-viewport timers are armed. See
## [method set_pass_profiling_enabled].
var _pass_profiling_enabled := false
var _resolve_material: ShaderMaterial
var _panini_material: ShaderMaterial
var _present_material: ShaderMaterial
var _final_layer: CanvasLayer
var _final_rect: ColorRect
var _output_size := Vector2i.ZERO
## Size of the 3D capture and its resolve. Equal to the output size unless the
## Panini pass is active, in which case it is sized for that projection.
var _capture_size := Vector2i.ZERO
var _capture_resize_count := 0
var _source_camera_instance_id := 0
var _settings: Dictionary = {}
var _active := false
var _scene_capture_frames := 0
var _resolve_frames := 0
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
var _panini_contract_capture_size := Vector2i.ZERO
var _panini_contract_display_fov := 0.0
var _panini_capture_sharpness := PANINI_DEFAULT_CAPTURE_SHARPNESS
var _panini_capture_ceiling_fov := 0.0
var _panini_property_camera_instance_id := 0
var _panini_camera_has_enabled_property := false
var _panini_camera_has_display_fov_property := false
var _panini_camera_has_max_display_fov_property := false


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
	_resolve_frames = 0
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
		"resolve_shader": load(RESOLVE_SHADER_PATH) as Shader,
		"panini_shader": load(PANINI_SHADER_PATH) as Shader,
		"present_shader": load(PRESENT_SHADER_PATH) as Shader,
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
	_scene_viewport = _make_viewport("SceneCapture", _output_size)
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

	# One pass turns the capture into the visible image: coverage decode plus the
	# environment reconstruction behind everything geometry did not cover.
	_resolve_material = ShaderMaterial.new()
	_record_explicit_allocation()
	_resolve_material.shader = resources["resolve_shader"]
	_resolve_material.set_shader_parameter(&"scene_texture", _scene_viewport.get_texture())
	_resolve_viewport = _make_canvas_pass("SceneResolve", _output_size, _resolve_material)

	# Panini works on the finished opaque perceptual image from resolve.
	_panini_material = ShaderMaterial.new()
	_record_explicit_allocation()
	_panini_material.shader = resources["panini_shader"]
	_panini_material.set_shader_parameter(
		&"source_texture", _resolve_viewport.get_texture())
	_panini_viewport = _make_canvas_pass(
		"PaniniProjection", _output_size, _panini_material)
	_panini_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_present_material = ShaderMaterial.new()
	_record_explicit_allocation()
	_present_material.shader = resources["present_shader"]
	# _apply_present_source() rebinds this to the Panini target while that pass
	# is active; otherwise it stays the resolve target.
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

	# Every owned target stores scene-linear radiance between passes; the resolve
	# shader decodes coverage on that assumption and has no sRGB fallback branch.
	# Forward+ honors this, so a refusal is a broken platform assumption rather
	# than a supported configuration, and it fails here instead of silently
	# shifting every colour in the frame.
	for target: SubViewport in [_scene_viewport, _resolve_viewport, _panini_viewport]:
		if not target.use_hdr_2d:
			shutdown()
			return (
				"The platform did not honor HDR 2D on the '%s' scene-radiance target."
				% target.name)

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
	# Sample the root now so a settings change delivered in the same frame as a
	# window resize does not first allocate targets for the stale output size.
	var next_output_size := _output_size
	if _root_viewport != null and is_instance_valid(_root_viewport):
		var visible_size := Vector2i(_root_viewport.get_visible_rect().size)
		if visible_size.x > 0 and visible_size.y > 0:
			next_output_size = visible_size
	if next_output_size != _output_size:
		_resize(next_output_size)
	_present_material.set_shader_parameter(&"grade_enabled", bool(settings.get("enabled", settings.get("retro_post_enabled", true))))
	var environment := settings.get("environment", {}) as Dictionary
	var environment_mode := int(environment.get("mode", 0))
	var fallback: Color = environment.get("fallback_linear", Color.BLACK)
	var inverse_basis: Basis = environment.get("inverse_sky_basis", Basis.IDENTITY)
	var recover_opaque_coverage := (
		bool(settings.get("recover_opaque_coverage_from_rgb", false)))
	var panorama: Texture2D
	if environment_mode == 1:
		panorama = environment.get("panorama") as Texture2D
	# Resolve is the only pass that reads SceneCapture, so it is the only one
	# that reconstructs the environment and decodes coverage. Panini and present
	# consume an already-composited image.
	_resolve_material.set_shader_parameter(
		&"recover_opaque_coverage_from_rgb", recover_opaque_coverage)
	_resolve_material.set_shader_parameter(&"environment_mode", environment_mode)
	_resolve_material.set_shader_parameter(
		&"environment_flat_linear", Vector3(fallback.r, fallback.g, fallback.b))
	_resolve_material.set_shader_parameter(&"environment_panorama", panorama)
	_resolve_material.set_shader_parameter(&"environment_basis_x", inverse_basis.x)
	_resolve_material.set_shader_parameter(&"environment_basis_y", inverse_basis.y)
	_resolve_material.set_shader_parameter(&"environment_basis_z", inverse_basis.z)
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
	_resolve_frames += 1
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
	_resolve_viewport = null
	_panini_viewport = null
	_final_layer = null
	_final_rect = null
	_resolve_material = null
	_panini_material = null
	_present_material = null
	_root_state = {}
	_source_camera_instance_id = 0
	_output_size = Vector2i.ZERO
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
	_panini_contract_capture_size = Vector2i.ZERO
	_panini_contract_display_fov = 0.0
	_panini_capture_ceiling_fov = 0.0
	_capture_size = Vector2i.ZERO
	_capture_resize_count = 0
	_panini_property_camera_instance_id = 0
	_panini_camera_has_enabled_property = false
	_panini_camera_has_display_fov_property = false
	_panini_camera_has_max_display_fov_property = false


func get_profile_snapshot() -> Dictionary:
	var data_hdr_requested := _resolve_viewport != null and _resolve_viewport.use_hdr_2d
	var data_rgba := _resolve_viewport != null and _resolve_viewport.transparent_bg
	# Two owned capture-size color targets (scene capture, resolve) plus the
	# persistent output-size Panini target. Forward+ honors use_hdr_2d, so every
	# one of them is RGBA16F.
	var bytes_per_target_pixel := 8
	var panini_buffer_bytes := (
		_output_size.x * _output_size.y * bytes_per_target_pixel
		if _panini_viewport != null else 0)
	var persistent_bytes := (
		_capture_size.x * _capture_size.y * bytes_per_target_pixel * 2)
	persistent_bytes += panini_buffer_bytes
	var pass_timings := _measured_pass_timings()
	return {
		"post_pass_gpu_ms": pass_timings,
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
		# Presentation is always root-native. The 3D capture and its resolve are
		# the only stages that leave that domain, and only to give the Panini
		# projection the source density it samples at.
		"post_native_size": _output_size,
		"post_output_size": _output_size,
		"post_render_size": _capture_size,
		"post_rendered_pixels": _capture_size.x * _capture_size.y,
		"post_capture_size": _capture_size,
		"post_capture_pixel_ratio": (
			float(_capture_size.x * _capture_size.y)
			/ maxf(float(_output_size.x * _output_size.y), 1.0)),
		"post_capture_resize_count": _capture_resize_count,
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
		"post_resolve_frames": _resolve_frames,
		"post_panini_frames": _panini_frames,
		"post_panini_requested": _panini_requested,
		"post_panini_camera_capable": _panini_camera_capable,
		"post_panini_camera_enabled": _panini_camera_enabled,
		"post_panini_eligible": _panini_eligible,
		"post_panini_enabled": _panini_active,
		"post_panini_bypass_reason": _panini_bypass_reason,
		"post_panini_projection": &"classic_d1_s0",
		"post_panini_sample_mode": &"catmull_rom_or_tent",
		"post_panini_sample_taps_min": 6,
		"post_panini_sample_taps_max": 9,
		"post_panini_output_domain": &"native",
		"post_panini_target_persistent": _panini_viewport != null,
		"post_panini_buffer_bytes": panini_buffer_bytes,
		"post_panini_viewport_size": (
			_panini_viewport.size if _panini_viewport != null else Vector2i.ZERO),
		"post_panini_source_size": _capture_size,
		"post_panini_capture_sharpness": _panini_capture_sharpness,
		"post_panini_capture_ceiling_fov": _panini_capture_ceiling_fov,
		"post_panini_center_texels_per_pixel": _panini_center_sampling_ratio(),
		"post_panini_source_stage": &"scene_resolve",
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
			&"panini" if _panini_active else &"scene_resolve"),
	}


## Turns on the rendering server's own per-viewport GPU/CPU timers for every pass
## this stack owns, plus the root that presents them.
##
## The resolve, Panini and present passes are 2D canvas draws inside SubViewports, so a
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
		[&"scene_resolve", _resolve_viewport],
	]
	entries.append([&"panini", _panini_viewport])
	entries.append([&"root_present", _root_viewport])
	return entries


func get_debug_stage_images() -> Dictionary:
	# Validation-only readback seam. Normal runtime never calls this method.
	return {
		"scene": (
			_scene_viewport.get_texture().get_image()
			if _scene_viewport != null else null),
		"resolve": (
			_resolve_viewport.get_texture().get_image()
			if _resolve_viewport != null else null),
		# Null while directly bypassed; the persistent target may never have drawn.
		"panini": (
			_panini_viewport.get_texture().get_image()
			if _panini_active and _panini_viewport != null else null),
	}


func get_output_size() -> Vector2i:
	return _output_size


func get_render_size() -> Vector2i:
	return _output_size


## The SubViewport every 3D pass actually renders into.
##
## Exposed because the root Viewport has [code]disable_3d[/code] set, so anything
## that has to reach the real 3D render target -- renderer visibility statistics,
## occlusion culling, variable rate shading -- addresses this one or addresses
## nothing. Callers configure the render target; they must not reparent it, resize
## it or replace its world, all of which this stack owns and re-asserts.
func get_scene_viewport() -> SubViewport:
	return _scene_viewport


## Size of the 3D capture, which is what every 3D pass -- raster and ray tracing
## alike -- actually renders at. Equal to the output size unless the Panini pass
## is active and has sized it for its own sampling requirement.
func get_capture_size() -> Vector2i:
	return _capture_size


func get_debug_contract_snapshot() -> Dictionary:
	# Validation-only seam for confirming that presentation and every source
	# texture stay in their intended pixel domains after a resize.
	return {
		"output_size": _output_size,
		"render_size": _output_size,
		"scene_viewport_size": _scene_viewport.size if _scene_viewport else Vector2i.ZERO,
		"resolve_viewport_size": (
			_resolve_viewport.size if _resolve_viewport else Vector2i.ZERO),
		"panini_viewport_size": (
			_panini_viewport.size if _panini_viewport else Vector2i.ZERO),
		"panini_buffer_bytes": (
			_output_size.x * _output_size.y * 8 if _panini_viewport else 0),
		"final_presentation_size": (
			Vector2i(_final_rect.size) if _final_rect else Vector2i.ZERO),
		# The present pass has no source-texel-domain uniform; its source is
		# always 1:1 with the rect it covers.
		"resolve_uniform_size": _shader_viewport_size(_resolve_material),
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
		"panini_sample_mode": &"catmull_rom_or_tent",
		"panini_sample_taps_min": 6,
		"panini_sample_taps_max": 9,
		"panini_bounds_valid": _panini_bounds_valid(),
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
	# Every target the stack owns carries scene radiance between passes, so all of
	# them are RGBA16F. Only the root presentation target stays LDR.
	RTVisualContract.apply_native_viewport_state(viewport, size, true)
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
	viewport.transparent_bg = true
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
	RTVisualContract.apply_native_viewport_state(
		_panini_viewport, _output_size, true)
	_panini_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if _panini_active else SubViewport.UPDATE_DISABLED)
	# While bypassed the capture is the output. While active, _resolve_panini_state()
	# re-derives it for the new output on this same frame, so leaving it alone here
	# avoids shrinking and regrowing a large target inside one resize.
	if not _panini_active:
		_apply_capture_size(_output_size)
	_apply_present_source()
	_resize_last_usec = Time.get_ticks_usec() - resize_started
	_resize_peak_usec = maxi(_resize_peak_usec, _resize_last_usec)
	_resize_count += 1


## Sizes the 3D capture and its resolve. Every other stage stays at the output
## size; only these two follow the projection's sampling requirement.
func _apply_capture_size(capture_size: Vector2i) -> void:
	var next := Vector2i(maxi(capture_size.x, 1), maxi(capture_size.y, 1))
	if next == _capture_size:
		return
	_capture_size = next
	# Root/final presentation is deliberately LDR, but these carry scene radiance.
	RTVisualContract.apply_native_viewport_state(_scene_viewport, _capture_size, true)
	RTVisualContract.apply_native_viewport_state(_resolve_viewport, _capture_size, true)
	# Describes the resolve source texel domain, and the Panini source domain.
	# The present pass deliberately has no such uniform: its source is always 1:1
	# with the rect it covers.
	_resolve_material.set_shader_parameter(&"viewport_size", Vector2(_capture_size))
	_panini_material.set_shader_parameter(&"source_size", Vector2(_capture_size))
	# The corner rays are screen points in the capture, not the output.
	_apply_camera_rays()
	_capture_resize_count += 1


func _apply_present_source() -> void:
	# Resolve is 1:1 with the capture and perceptual. Panini resamples it to the
	# output size; bypass binds it straight to present, which is only correct
	# because a bypassed capture is the output size.
	var pre_panini_source: Texture2D = _resolve_viewport.get_texture()
	_panini_material.set_shader_parameter(&"source_texture", pre_panini_source)
	_panini_material.set_shader_parameter(&"source_size", Vector2(_capture_size))
	var present_source: Texture2D = (
		_panini_viewport.get_texture() if _panini_active
		else pre_panini_source)
	_present_material.set_shader_parameter(&"source_texture", present_source)


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

	_apply_camera_rays()


## Frustum corner rays for the resolve pass's environment reconstruction.
## Camera3D.project_position() interprets its argument in the camera's own
## viewport, which is the capture -- not the output the projection presents to.
func _apply_camera_rays() -> void:
	if _internal_camera == null or _resolve_material == null:
		return
	var width := float(maxi(_capture_size.x, 1))
	var height := float(maxi(_capture_size.y, 1))
	_resolve_material.set_shader_parameter(
		&"camera_ray_top_left", _camera_ray(_internal_camera, Vector2.ZERO))
	_resolve_material.set_shader_parameter(
		&"camera_ray_top_right", _camera_ray(_internal_camera, Vector2(width, 0.0)))
	_resolve_material.set_shader_parameter(
		&"camera_ray_bottom_left", _camera_ray(_internal_camera, Vector2(0.0, height)))
	_resolve_material.set_shader_parameter(
		&"camera_ray_bottom_right", _camera_ray(_internal_camera, Vector2(width, height)))


func _resolve_panini_state(source_camera: Camera3D) -> void:
	_panini_requested = bool(_settings.get("post_panini_enabled", false))
	var requested_sharpness := float(_settings.get(
		"post_panini_capture_sharpness", PANINI_DEFAULT_CAPTURE_SHARPNESS))
	_panini_capture_sharpness = clampf(
		requested_sharpness if is_finite(requested_sharpness)
		else PANINI_DEFAULT_CAPTURE_SHARPNESS,
		PANINI_MIN_CAPTURE_SHARPNESS,
		PANINI_MAX_CAPTURE_SHARPNESS)
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

	# Size the capture from the widest angle this camera can request, not from
	# the live one. The live angle moves every frame while a sprint transition
	# eases, and the capture is a render target: following it would reallocate
	# mid-motion. A capture sized for the ceiling contains every narrower FOV,
	# so the only cost of the difference is sharpness the capture already paid
	# for. Sizing on the ceiling also keeps this decision free of the contract
	# below, which is what stops an invalid contract from oscillating the
	# capture between two sizes on alternating frames.
	_panini_capture_ceiling_fov = _read_panini_capture_ceiling(source_camera)
	# A camera that declares no ceiling keeps the plain output-sized capture. The
	# alternative -- sizing from the live angle -- is the reallocation this whole
	# mechanism exists to avoid, so the sharper capture stays a declared
	# capability rather than something inferred frame to frame.
	var desired_capture := _output_size
	if _panini_capture_ceiling_fov > 0.0:
		var projected := panini_capture_size(
			_output_size, _panini_capture_ceiling_fov, _panini_capture_sharpness)
		if projected.x > 0 and projected.y > 0:
			desired_capture = projected
	if desired_capture != _capture_size:
		_apply_capture_size(desired_capture)
		_apply_present_source()

	if (
		_panini_contract_output_size != _output_size
		or _panini_contract_capture_size != _capture_size
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
	_panini_camera_has_max_display_fov_property = false
	if camera == null:
		return
	for property: Dictionary in camera.get_property_list():
		var property_name := StringName(property.get("name", ""))
		if property_name == &"panini_enabled":
			_panini_camera_has_enabled_property = true
		elif property_name == &"display_horizontal_fov":
			_panini_camera_has_display_fov_property = true
		elif property_name == &"max_display_horizontal_fov":
			_panini_camera_has_max_display_fov_property = true


## The widest display FOV the source camera declares it will ever request, or 0
## when it declares none. Optional capability: a camera without it presents
## through an output-sized capture exactly as before.
func _read_panini_capture_ceiling(camera: Camera3D) -> float:
	if camera == null or not _panini_camera_has_max_display_fov_property:
		return 0.0
	var value: Variant = camera.get(&"max_display_horizontal_fov")
	if not (value is float or value is int):
		return 0.0
	var ceiling := float(value)
	if (
		not is_finite(ceiling)
		or ceiling < PANINI_MIN_HORIZONTAL_FOV
		or ceiling > PANINI_MAX_HORIZONTAL_FOV
	):
		return 0.0
	return ceiling


func _set_panini_active(enabled: bool) -> void:
	if _panini_active == enabled:
		return
	_panini_active = enabled
	if _panini_viewport != null:
		_panini_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED)
	# A bypassed frame presents the resolve target 1:1, so the capture has to
	# return to the output size with the pass. Every bypass reason funnels
	# through here, which is what keeps the projected capture from outliving the
	# projection and stretching the image across a camera change.
	if not enabled and _scene_viewport != null:
		_apply_capture_size(_output_size)
	if _panini_material != null and _present_material != null:
		_apply_present_source()


func _apply_panini_capture_contract(display_horizontal_fov: float) -> void:
	# The bounds themselves are closed-form. The perimeter is only the diagnostic
	# dataset behind invalid_samples, and that path cannot be reached from a
	# contract whose capture was derived from these same bounds, so it is built
	# on demand rather than cached across frames.
	var contract := debug_panini_capture_contract(
		display_horizontal_fov, _output_size, _capture_size)
	_panini_contract_output_size = _output_size
	_panini_contract_capture_size = _capture_size
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


## Rectilinear half-tangents the projection must be able to read for this output
## and FOV, already inset by the half-texel margin. Both extrema are analytic;
## see the derivation in [method _panini_capture_contract].
## Returns a zero vector for an unsupported FOV or an empty output.
static func panini_required_tangents(
		display_horizontal_fov: float,
		output_size: Vector2i) -> Vector2:
	if (
		output_size.x < 1
		or output_size.y < 1
		or not is_finite(display_horizontal_fov)
		or display_horizontal_fov < PANINI_MIN_HORIZONTAL_FOV
		or display_horizontal_fov > PANINI_MAX_HORIZONTAL_FOV
	):
		return Vector2.ZERO
	var half_horizontal := deg_to_rad(display_horizontal_fov) * 0.5
	var output_aspect := float(output_size.x) / float(output_size.y)
	var corner := _panini_inverse_rectilinear(
		Vector2.ONE,
		panini_extent_x(display_horizontal_fov),
		tan(half_horizontal) / output_aspect)
	if not is_finite(corner.x) or not is_finite(corner.y):
		return Vector2.ZERO
	# Keep the mapped perimeter at least half a source texel inside the capture.
	# The margin uses the output size rather than the capture size: a capture is
	# never smaller than the output, so its own half-texel inset is narrower and
	# this stays the conservative choice at any capture resolution.
	return Vector2(
		absf(corner.x) / maxf(1.0 - 1.0 / float(maxi(output_size.x, 2)), 0.5),
		absf(corner.y) / maxf(1.0 - 1.0 / float(maxi(output_size.y, 2)), 0.5))


## Horizontal Panini-plane extent reached by a display FOV. With D=1 this is
## 2*tan(fov/4), the closed form the shader inverts.
static func panini_extent_x(display_horizontal_fov: float) -> float:
	var half_horizontal := deg_to_rad(display_horizontal_fov) * 0.5
	return (
		(PANINI_DISTANCE + 1.0) * sin(half_horizontal)
		/ (PANINI_DISTANCE + cos(half_horizontal)))


## Size of the private 3D capture, given the widest display FOV the source
## camera can request and a target center sharpness.
##
## Two independent decisions live here.
##
## The aspect is the ratio of the two required half-tangents, which is the
## sharpness optimum rather than a convenience. Capture width is proportional to
## sqrt(aspect) at a fixed pixel count while the horizontal capture tangent is
## flat until the aspect passes that ratio and grows linearly after it, so the
## horizontal center ratio peaks exactly there. It is also the only aspect that
## wastes no frustum: an output-aspect capture at 130 degrees renders 41 percent
## of its width outside anything the projection can sample.
##
## The scale is then chosen so the horizontal center ratio equals `sharpness`
## exactly, because with that aspect the ratio reduces to the linear scale
## itself. Sharpness 1.0 therefore means the screen center is reconstructed one
## source texel per output pixel and the projection magnifies nothing at all.
## The vertical axis lands above the horizontal by a factor that depends only on
## the projection and the output aspect -- about 1.68x on 16:9 -- and cannot be
## traded away while pixels stay square.
##
## Returns [code]Vector2i.ZERO[/code] when the ceiling FOV has no valid capture,
## which is the caller's signal to present rectilinear at the output size.
static func panini_capture_size(
		output_size: Vector2i,
		ceiling_horizontal_fov: float,
		sharpness: float) -> Vector2i:
	var required := panini_required_tangents(ceiling_horizontal_fov, output_size)
	var extent_x := panini_extent_x(ceiling_horizontal_fov)
	if (
		required.x <= 0.0
		or required.y <= 0.0
		or not is_finite(extent_x)
		or extent_x <= 0.0
	):
		return Vector2i.ZERO
	var clamped_sharpness := clampf(
		sharpness if is_finite(sharpness) else PANINI_DEFAULT_CAPTURE_SHARPNESS,
		PANINI_MIN_CAPTURE_SHARPNESS,
		PANINI_MAX_CAPTURE_SHARPNESS)
	# The aspect is the contract here, not the individual dimensions: a capture
	# whose aspect drifts off this ratio pays for width the projection cannot
	# sample. Clamp the driving axis, then derive the other from the clamped
	# value so the ratio survives both limits.
	var aspect := required.x / required.y
	var width := float(output_size.x) * (required.x / extent_x) * clamped_sharpness
	width = clampf(width, 2.0, float(PANINI_MAX_CAPTURE_AXIS))
	if width / aspect > float(PANINI_MAX_CAPTURE_AXIS):
		width = float(PANINI_MAX_CAPTURE_AXIS) * aspect
	return Vector2i(
		maxi(roundi(width), 2),
		maxi(roundi(width / aspect), 2))


## Validation seam for the CPU half of the projection contract. Runtime calls it
## only after the FOV or either size domain changes; tests can exercise
## aspect/FOV boundaries without constructing a renderer or reading back a
## framebuffer. Passing the output size as the capture size describes the
## unscaled 1:1 capture.
static func debug_panini_capture_contract(
		display_horizontal_fov: float,
		output_size: Vector2i,
		capture_size: Vector2i = Vector2i.ZERO) -> Dictionary:
	var capture := capture_size if capture_size.x > 0 and capture_size.y > 0 else output_size
	if (
		output_size.x < 1
		or output_size.y < 1
		or capture.x < 1
		or capture.y < 1
		or not is_finite(display_horizontal_fov)
		or display_horizontal_fov < PANINI_MIN_HORIZONTAL_FOV
		or display_horizontal_fov > PANINI_MAX_HORIZONTAL_FOV
	):
		return {"valid": false}
	# _panini_perimeter_points() emits every border texel center plus the four
	# logical corners, which is exactly this count for any output of at least one
	# texel per axis. Reporting it arithmetically is what lets the points
	# themselves stay unbuilt on the ordinary path.
	var perimeter_samples := 2 * output_size.x + 2 * output_size.y
	return _panini_capture_contract(
		display_horizontal_fov, output_size, capture, perimeter_samples)


static func _panini_capture_contract(
		display_horizontal_fov: float,
		output_size: Vector2i,
		capture_size: Vector2i,
		perimeter_samples: int) -> Dictionary:

	var half_horizontal := deg_to_rad(display_horizontal_fov) * 0.5
	var extent_x := panini_extent_x(display_horizontal_fov)
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
		Vector2.ONE, extent_x, panini_extent_y)
	if not is_finite(mapped_corner.x) or not is_finite(mapped_corner.y):
		return {
			"valid": false,
			"perimeter_samples": perimeter_samples,
			"invalid_samples": perimeter_samples,
		}
	var mapped_max := mapped_corner
	var mapped_min := -mapped_corner

	var required := panini_required_tangents(display_horizontal_fov, output_size)
	# The capture's own aspect decides the frustum. panini_capture_size() picks
	# the aspect that leaves no unsampled width; any other capture, including the
	# plain output-aspect one, only widens the frustum past what is required.
	var capture_aspect := float(capture_size.x) / float(capture_size.y)
	var capture_tan_y := maxf(required.y, required.x / capture_aspect)
	var capture_tan_x := capture_tan_y * capture_aspect
	var capture_tangent := Vector2(capture_tan_x, capture_tan_y)
	var capture_horizontal_fov := rad_to_deg(2.0 * atan(capture_tan_x))
	var capture_vertical_fov := rad_to_deg(2.0 * atan(capture_tan_y))

	var source_uv_min := Vector2(
		0.5 + 0.5 * mapped_min.x / capture_tan_x,
		0.5 - 0.5 * mapped_max.y / capture_tan_y)
	var source_uv_max := Vector2(
		0.5 + 0.5 * mapped_max.x / capture_tan_x,
		0.5 - 0.5 * mapped_min.y / capture_tan_y)
	# Count raw coordinates before the shader's final defensive clamp. The inset
	# uses the output size, which is never larger than the capture, so a valid
	# contract cannot expose an unrendered border at any capture resolution.
	var safe_uv_min := Vector2(
		0.5 / float(output_size.x), 0.5 / float(output_size.y))
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
		for point: Vector2 in _panini_perimeter_points(output_size):
			var mapped := _panini_inverse_rectilinear(
				point, extent_x, panini_extent_y)
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
		"panini_extent_x": extent_x,
		"panini_extent_y": panini_extent_y,
		"capture_size": capture_size,
		"capture_aspect": capture_aspect,
		"required_tan_half_fov": required,
		"capture_horizontal_fov": capture_horizontal_fov,
		"capture_vertical_fov": capture_vertical_fov,
		"capture_tan_half_fov": capture_tangent,
		"mapped_rect_min": mapped_min,
		"mapped_rect_max": mapped_max,
		"source_uv_min": source_uv_min,
		"source_uv_max": source_uv_max,
		"perimeter_samples": perimeter_samples,
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


## Source texels the projection reads per output pixel at screen center, on both
## axes. This is the number the whole capture-sizing mechanism exists to raise:
## below 1.0 the center is a magnification of the capture, which is what reads as
## soft no matter how good the reconstruction filter is. Zero while bypassed.
func _panini_center_sampling_ratio() -> Vector2:
	if not _panini_active or _capture_size.x < 1 or _capture_size.y < 1:
		return Vector2.ZERO
	var extent_x := panini_extent_x(_panini_display_horizontal_fov)
	var half_horizontal := deg_to_rad(_panini_display_horizontal_fov) * 0.5
	var extent_y := (
		tan(half_horizontal) / (float(_output_size.x) / float(_output_size.y)))
	var tangent := Vector2(
		maxf(_panini_capture_tan_half_fov.x, 0.00001),
		maxf(_panini_capture_tan_half_fov.y, 0.00001))
	return Vector2(
		(extent_x / tangent.x) * float(_capture_size.x) / float(maxi(_output_size.x, 1)),
		(extent_y / tangent.y) * float(_capture_size.y) / float(maxi(_output_size.y, 1)))


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
