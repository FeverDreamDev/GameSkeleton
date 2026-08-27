@tool
extends Node
class_name RTSceneManager

## Main-thread owner for the shared hardware/software RT scene representation. Any active
## DirectionalLight3D, OmniLight3D, SpotLight3D, or AreaLight3D is published to
## the RT compositor. A light's native Shadow Enabled checkbox is repurposed as
## its RT-shadow toggle while native shadow-map rendering is suppressed.

signal rt_ready
signal rt_failed(reason: String)
signal rt_quality_changed(preset: int, requested_scale: float)
signal topology_sync_started
signal topology_sync_completed
## Emitted when the fog parameters or the environment background radiance change.
## Unmanaged forward geometry (shell grass and similar) subscribes to stay matched
## to the managed surfaces it sits on.
signal distance_fog_changed(params: Dictionary)

enum RTBackend {
	AUTO,
	HARDWARE,
	SOFTWARE,
}

enum RTEnvironmentMode {
	FLAT,
	PANORAMA,
}

enum SMAAQuality {
	LOW,
	MEDIUM,
	HIGH,
}

enum RTQualityPreset {
	NATIVE,
	QUALITY,
	BALANCED,
	PERFORMANCE,
}

## The live lights match the published snapshot.
const LIGHT_CHANGE_NONE := 0
## Light data the shader reads changed, but nothing the receiver/light culler
## reads did. The light buffer is re-uploaded; candidate lists are left alone.
const LIGHT_CHANGE_SHADING := 1
## A light changed in a way that can move it in or out of a receiver's candidate
## list, so the lists have to be rebuilt. Implies [constant LIGHT_CHANGE_SHADING].
const LIGHT_CHANGE_INFLUENCE := 2

## Frames the per-surface topology sweep takes to cover every receiver once.
const _TOPOLOGY_VALIDATION_FRAMES := 12


class SnapshotBridge:
	extends RefCounted

	var _mutex := Mutex.new()
	var _snapshot: Dictionary = {}
	var _active := false
	var _ready_pending := false
	var _failure := ""

	func activate() -> void:
		_mutex.lock()
		_active = true
		_ready_pending = false
		_failure = ""
		_snapshot = {}
		_mutex.unlock()

	func deactivate() -> void:
		_mutex.lock()
		_active = false
		_ready_pending = false
		_failure = ""
		_snapshot = {}
		_mutex.unlock()

	func publish(snapshot: Dictionary) -> void:
		_mutex.lock()
		if _active:
			_snapshot = snapshot
		_mutex.unlock()

	func get_snapshot() -> Dictionary:
		_mutex.lock()
		var result := _snapshot if _active else {}
		_mutex.unlock()
		return result

	func is_active() -> bool:
		_mutex.lock()
		var result := _active
		_mutex.unlock()
		return result

	func mark_ready() -> void:
		_mutex.lock()
		if _active:
			_ready_pending = true
		_mutex.unlock()

	func report_failure(reason: String) -> void:
		_mutex.lock()
		if _active and _failure.is_empty():
			_failure = reason
			_active = false
			_ready_pending = false
			_snapshot = {}
		_mutex.unlock()

	func take_ready() -> bool:
		_mutex.lock()
		var result := _active and _ready_pending
		_ready_pending = false
		_mutex.unlock()
		return result

	func take_failure() -> String:
		_mutex.lock()
		var result := _failure
		_failure = ""
		_mutex.unlock()
		return result

const MAX_SUPPORTED_LIGHTS := 256
const MAX_SUPPORTED_MATERIALS := 2047
const MAX_SUPPORTED_INSTANCES := 0x001ffffe
const RT_CARRIER_LAYER := 20
const RT_CARRIER_LAYER_MASK := 1 << (RT_CARRIER_LAYER - 1)
const RENDER_LAYER_MASK := (1 << 20) - 1
const RT_CARRIER_ENERGY := 1000000.0
const RT_MATERIAL_ID_PARAMETER := &"rt_material_id"
const RT_HAS_ALBEDO_PARAMETER := &"rt_has_albedo_texture"
const RT_HAS_NORMAL_PARAMETER := &"rt_has_normal_texture"
const RT_PIPELINE_ACTIVE_PARAMETER := &"rt_pipeline_active"
const RT_OVERRIDE_PROCESS_PRIORITY := 100000
const SCENARIO_OWNER_META := &"__rt_compositor_owner"
const MAP_ATLAS_MAX_SIZE := 4096
const ENVIRONMENT_PANORAMA_MAX_SIZE := Vector2i(512, 256)
const SKY_RADIANCE_SIZES := [32, 64, 128, 256, 512, 1024, 2048]
# Preloaded rather than named by path because this is an identity check, not a
# load: a material is managed only when it runs exactly this shader. A path
# string that drifted out of step with the add-on's location would reject every
# material at runtime and report it as the scene's fault; a preload that cannot
# resolve fails loudly at parse time instead.
const BLINN_PHONG_SHADER := preload("res://addons/retro_rt/shaders/BlinnPhong.gdshader")
const RECEIVER_BOUNDS_MARGIN := 0.0001
const EDITOR_PREVIEW_DEBOUNCE_FRAMES := 2
const EDITOR_PREVIEW_POLL_FRAMES := 30
# Backoff after a reported editor-preview failure. A scene that is temporarily
# outside the RT contract (a freshly added mesh with no managed material, for
# example) is repaired by ordinary editing, which exposes no signal, so the
# preview has to keep retrying without rebuilding several times a second.
const EDITOR_PREVIEW_RETRY_FRAMES := 120
const RT_QUALITY_SCALES := [1.0, 0.85, 0.75, 0.5]
const RT_QUALITY_NAMES := [&"native", &"quality", &"balanced", &"performance"]

@export_node_path("Node") var geometry_root_path: NodePath = NodePath("../")
@export_node_path("WorldEnvironment") var world_environment_path: NodePath = NodePath("../WorldEnvironment")
## Starts the runtime renderer from [method _ready]. Disable this when a loading
## coordinator needs to assemble procedural geometry before calling [method start_rt].
@export var auto_start: bool = true
## Runtime geometry is opt-in by default so ordinary raster-only meshes (shell
## grass, viewmodels, particles and other deformed surfaces) can share the same
## world without entering the rigid opaque RT contract. Set this to an empty
## name to retain the legacy scan-every-MeshInstance3D behavior.
@export var managed_geometry_group: StringName = &"retro_rt_managed"
## Managed nodes in this second group receive primary RT lighting and shadows,
## but never enter the hardware TLAS or software BVH. This is intended for
## streamed procedural receivers whose topology changes frequently.
@export var receiver_only_geometry_group: StringName = &"retro_rt_receiver_only"
## Upper bound for the asynchronous hardware-ready handshake. Synchronous
## resource construction still completes atomically, but a render thread that
## never acknowledges the first snapshot cannot leave boot waiting forever.
@export_range(1.0, 60.0, 0.5) var startup_timeout_seconds: float = 15.0
@export var preview_in_editor: bool = true:
	set(value):
		preview_in_editor = value
		if Engine.is_editor_hint() and is_inside_tree():
			if value:
				_schedule_editor_preview_sync()
			else:
				_teardown_editor_preview()
				set_process(false)
@export var rt_backend: RTBackend = RTBackend.AUTO
@export_range(1, MAX_SUPPORTED_LIGHTS, 1) var max_scene_lights: int = MAX_SUPPORTED_LIGHTS
@export_range(1, 32, 1) var software_max_lights_per_receiver: int = 16
@export var ray_origin_bias: float = 0.001
@export var ray_max_distance: float = 10000.0
## Steps the reflection ground march takes across the layer window. Zero turns
## the layer off outright, which makes a reflection miss resolve against the
## environment exactly as it did before the layer existed. Only a reflection
## ray that actually enters the window pays for these.
@export_range(0, 128, 1) var ground_march_steps: int = 32
@export var profiling_enabled: bool = false
@export_group("Distance Fog")

## Post-lighting distance fog applied identically by the hardware compositor, the
## software fragment path, and any unmanaged shader that subscribes to
## [signal distance_fog_changed]. Environment fog stays banned by
## [method _validate_environment]; this replaces it. The fog colour is not
## authorable: it is always the environment's linear background radiance, which
## is also what the post stack composites into uncovered pixels.
@export var fog_enabled: bool = false:
	set(value):
		fog_enabled = value
		_mark_fog_dirty()
@export_range(0.0, 4096.0, 0.5, "or_greater") var fog_begin: float = 32.0:
	set(value):
		fog_begin = maxf(value, 0.0)
		_mark_fog_dirty()
@export_range(0.0, 4096.0, 0.5, "or_greater") var fog_end: float = 64.0:
	set(value):
		fog_end = maxf(value, 0.0)
		_mark_fog_dirty()
## Exponent applied to the smoothstep ramp. 1.0 is the reference curve.
@export_range(0.25, 4.0, 0.01) var fog_curve: float = 1.0:
	set(value):
		fog_curve = clampf(value, 0.01, 8.0)
		_mark_fog_dirty()

@export_group("Quality")

var _rt_quality_preset: RTQualityPreset = RTQualityPreset.NATIVE
@export var rt_quality: RTQualityPreset = RTQualityPreset.NATIVE:
	get:
		return _rt_quality_preset
	set(value):
		_set_rt_quality_value(int(value))

@export_group("Post Processing")

@export var post_anti_aliasing_enabled: bool = true:
	set(value):
		post_anti_aliasing_enabled = value
		_update_post_settings()

@export var post_smaa_quality: SMAAQuality = SMAAQuality.HIGH:
	set(value):
		post_smaa_quality = value
		_update_post_settings()

## FSR 1 RCAS attenuation in stops, per the reference FsrRcasCon
## (con = exp2(-value)). The sense is inverted: 0.0 is maximum sharpness and 2.0
## the minimum. Applies only while a reduced quality preset is active; Native
## bypasses FSR entirely.
@export_range(0.0, 2.0, 0.01) var post_fsr_sharpness: float = 0.5:
	set(value):
		post_fsr_sharpness = value
		_update_post_settings()

## Optional FidelityFX CAS on the Native presentation. Off by default so Native
## stays the reference image. Reduced presets sharpen with RCAS as part of FSR
## and ignore this.
@export var post_cas_enabled: bool = false:
	set(value):
		post_cas_enabled = value
		_update_post_settings()

## Standard CAS 0..1 sharpness. 0.15 is a conservative starting point for this
## renderer's hard highlights and high-contrast geometry.
@export_range(0.0, 1.0, 0.01) var post_cas_sharpness: float = 0.15:
	set(value):
		post_cas_sharpness = value
		_update_post_settings()

@export var retro_post_enabled: bool = true:
	set(value):
		retro_post_enabled = value
		_update_post_settings()

@export_range(0.5, 1.5, 0.01) var post_brightness: float = 1.0:
	set(value):
		post_brightness = value
		_update_post_settings()

@export_range(0.5, 2.0, 0.01) var post_contrast: float = 1.12:
	set(value):
		post_contrast = value
		_update_post_settings()

@export_range(0.0, 2.0, 0.01) var post_saturation: float = 1.08:
	set(value):
		post_saturation = value
		_update_post_settings()


@export_range(0.0, 0.25, 0.001) var post_black_point: float = 0.005:
	set(value):
		post_black_point = value
		_update_post_settings()

@export var post_color_balance: Vector3 = Vector3(1.02, 1.0, 0.97):
	set(value):
		post_color_balance = value
		_update_post_settings()

@export var post_posterize_enabled: bool = false:
	set(value):
		post_posterize_enabled = value
		_update_post_settings()

@export_range(2.0, 256.0, 1.0) var post_posterize_levels: float = 256.0:
	set(value):
		post_posterize_levels = value
		_update_post_settings()

@export_range(0.0, 1.0, 0.01) var post_posterize_strength: float = 1.0:
	set(value):
		post_posterize_strength = value
		_update_post_settings()

var _snapshot_bridge := SnapshotBridge.new()
var _current_snapshot: Dictionary = {}
var _snapshot_revision := 0
var _topology_revision := 0
var _tlas_revision := 0
var _instance_revision := 0
var _material_revision := 0
var _light_revision := 0
var _environment_revision := 0
var _settings_revision := 0
var _receiver_light_revision := 0
var _snapshot_transforms: Array[Transform3D] = []
var _snapshot_instance_masks := PackedInt32Array()
var _snapshot_instance_layers := PackedInt32Array()
var _snapshot_light: Dictionary = {}
var _snapshot_environment: Dictionary = {}
var _snapshot_bias := 0.001
var _snapshot_max_distance := 10000.0
var _snapshot_max_lights := MAX_SUPPORTED_LIGHTS
var _snapshot_profiling_enabled := false
var _snapshot_fog := Vector4.ZERO
# Analytic ground layer pushed by a terrain system through
# configure_ground_layer(). Streamed terrain is registered receiver-only so
# chunk churn never rebuilds the TLAS, and shell grass is vertex-deformed and
# so outside the managed contract entirely. Neither can be traced, which leaves
# this heightfield as the only thing a reflection ray has to resolve the ground
# against. See rt_ground_shade in
# addons/retro_rt/shaders/rt_shadow_reflect.glsl.
var _ground_texture: ImageTexture
var _ground_params := Vector4.ZERO
var _ground_bounds := Vector4.ZERO
var _ground_ambient := Color.BLACK
var _ground_grass := Vector4.ZERO
var _ground_revision := 0
var _snapshot_ground_texture: ImageTexture
var _snapshot_ground_params := Vector4.ZERO
var _snapshot_ground_bounds := Vector4.ZERO
var _snapshot_ground_ambient := Color.BLACK
var _snapshot_ground_grass := Vector4.ZERO
var _snapshot_ground_revision := -1
var _snapshot_ground_sun_direction := Vector3.UP
var _snapshot_ground_sun_radiance := Color.BLACK
var _snapshot_ground_sun_enabled := false
# Reflection-miss radiance supplied by a sky system, replacing the flat colour
# without changing the visible background or the fog. See set_reflection_panorama().
var _reflection_override: ImageTexture
var _reflection_override_basis := Basis.IDENTITY
var _fog_signal_muted := false
var _receiver_light_starts := PackedInt32Array()
var _receiver_light_counts := PackedInt32Array()
var _receiver_light_indices := PackedInt32Array()
var _receiver_light_candidates: Array[PackedInt32Array] = []
var _instances: Array[Dictionary] = []
var _render_instances: Array[Dictionary] = []
## Bumped wherever [member _render_instances] is replaced or cleared. The registry
## is copy-on-write at every mutation site, so a published clone stays valid until
## this moves -- which is what lets [method _commit_current_snapshot] reuse one.
var _render_instances_revision := 0
var _published_instances: Array[Dictionary] = []
var _published_instances_revision := -1
var _mesh_records: Array[Dictionary] = []
var _mesh_sources: Array[Mesh] = []
var _material_records: Array[Dictionary] = []
var _material_sources: Array[ShaderMaterial] = []
var _material_by_id: Dictionary = {}
var _instance_material_indices := PackedInt32Array()
var _albedo_atlas: ImageTexture
var _normal_atlas: ImageTexture
var _albedo_atlas_size := Vector2i.ONE
var _normal_atlas_size := Vector2i.ONE
var _albedo_region_by_texture_id: Dictionary = {}
var _normal_region_by_texture_id: Dictionary = {}
var _managed_texture_sources: Array[Texture2D] = []
var _managed_environment_resources: Array[Resource] = []
var _environment_reflection_states: Dictionary = {}
var _environment_source: Environment
var _environment_source_id := 0
var _environment_source_kind: StringName = &"default_clear"
var _environment_dirty := true
var _environment_debounce_frames := 0
var _dynamic_sky_snapshot_warnings: Dictionary = {}
var _environment_panorama_bytes := 0
var _environment_panorama_uploads := 0
var _environment_bakes := 0
var _environment_bake_failures := 0
var _environment_panorama_source_canonicalizations := 0
var _environment_last_bake_usec := 0
var _environment_peak_bake_usec := 0
var _texture_atlas_bytes := 0
var _texture_atlas_uploads := 0
var _texture_content_dirty := false
var _lights: Array[Light3D] = []
## Scene paths for [member _lights], parallel and index-matched. Diagnostics only;
## resolved in [method _discover_lights] so the per-frame snapshot never walks the
## tree for a string it almost never prints.
var _light_paths: PackedStringArray = PackedStringArray()
var _light_shadow_states: Dictionary = {}
var _light_topology_dirty := false
var _topology_dirty := false
var _tree_signals_connected := false
var _carrier_light: DirectionalLight3D
var _rt_effect: RTLightingEffect
var _software_tracer: RTSoftwareTracer
var _post_stack: RTPostProcessStack
var _compositor: Compositor
var _previous_compositor: Compositor
var _scenario_world: World3D
var _scenario := RID()
var _owns_scenario := false
var _scenario_compositor_installed := false
var _failed := false
var _ready_emitted := false
var _manager_active := false
var _active_backend := -1
var _configured_backend := -1
var _configured_software_max_lights := 0
var _receiver_list_rebuilds := 0
var _receiver_candidates_recomputed := 0
var _receiver_light_total := 0
var _receiver_light_maximum := 0
var _light_shading_updates := 0
var _light_influence_updates := 0
var _receiver_rebuilds_skipped := 0
## Round-robin position for the per-surface topology sweep. See
## [method _should_validate_topology_this_frame].
var _topology_validation_cursor := 0
var _profile_poll_frames := 0
var _profile_snapshot_updates := 0
var _profile_last_update_usec := 0
var _profile_peak_update_usec := 0
var _editor_preview_active := false
var _editor_preview_error := ""
var _editor_preview_reported_error := ""
var _editor_preview_debounce_frames := 0
var _editor_preview_poll_frames := 0
var _lifecycle_busy := false
var _lifecycle_generation := 0
var _topology_sync_pending := false
var _topology_sync_in_progress := false
var _topology_sync_debounce_frames := 0
var _topology_sync_requests := 0
var _topology_sync_starts := 0
var _topology_sync_completions := 0
var _topology_sync_failures := 0
var _receiver_only_instance_count := 0
var _traversable_instance_count := 0
var _placeholder_geometry_active := false
var _receiver_only_registrations := 0
var _receiver_only_unregistrations := 0
var _failure_layer: CanvasLayer
func _ready() -> void:
	# Run after ordinary gameplay nodes so renderer-only material/shadow overrides
	# are the final state submitted for the frame.
	process_priority = RT_OVERRIDE_PROCESS_PRIORITY
	if Engine.is_editor_hint() and DisplayServer.get_name() == "headless":
		# Import, export, and other headless editor runs have no viewport to
		# preview into and must not pay for BVH construction.
		set_process(false)
		return
	# The editor scene viewport owns its camera, preview sun/environment, and
	# render lifecycle, so it previews through RTSoftwareTracer whatever
	# rt_backend requests: its overrides are renderer-only RenderingServer state
	# that restores cleanly, and a partially assembled scene therefore degrades
	# to ordinary raster instead of rendering the hardware visibility buffer as
	# garbage. The shared fullscreen post stack stays runtime-only; it disables
	# 3D on the root viewport, which would blank the editor viewport and its
	# gizmos.
	if Engine.is_editor_hint():
		_connect_scene_tree_signals()
		if preview_in_editor:
			_schedule_editor_preview_sync()
		else:
			set_process(false)
		return
	if auto_start:
		# Defer one call so sibling terrain/player coordinators finish their own
		# _ready() work before the first contract validation and collection pass.
		start_rt.call_deferred()


## Starts (or restarts after [method stop_rt]) the selected RT backend. Awaiting
## this method resolves only after the backend reports ready (true), fails, is
## stopped, or this start is superseded (false). Callers may also invoke it
## fire-and-forget and observe [signal rt_ready] / [signal rt_failed].
func start_rt() -> bool:
	if Engine.is_editor_hint() or not is_inside_tree():
		return false
	if _manager_active:
		return _ready_emitted and not _failed
	if _lifecycle_busy:
		return false
	_lifecycle_generation += 1
	var generation := _lifecycle_generation
	_lifecycle_busy = true
	_failed = false
	_remove_failure_layer()
	var initialized := await _start_rt_internal(generation)
	if generation == _lifecycle_generation:
		_lifecycle_busy = false
	else:
		return false
	if not initialized:
		return false
	return await _wait_for_rt_ready(generation)


## Stops RT and restores every renderer, material, light, compositor and root
## Viewport override owned by this manager. It is safe to call repeatedly.
func stop_rt() -> void:
	if Engine.is_editor_hint():
		return
	_lifecycle_generation += 1
	_lifecycle_busy = false
	_stop_rt_internal(true)


## Queues a topology-safe backend resynchronization. Procedural systems should
## call this after a managed node's mesh/material/group assignment changes in
## place; ordinary managed node additions/removals call it automatically.
func request_topology_sync() -> void:
	if Engine.is_editor_hint():
		_topology_dirty = true
		_schedule_editor_preview_sync()
		return
	_topology_dirty = true
	_topology_sync_requests += 1
	# A stopped manual-start manager simply collects the latest topology when
	# start_rt() is eventually called; a live manager must quiesce this frame so
	# a newly-added instance cannot render with a shared carrier material and a
	# stale instance table.
	if not _manager_active and not _lifecycle_busy:
		return
	_topology_sync_pending = true
	_topology_sync_debounce_frames = 0


func _start_rt_internal(generation: int) -> bool:
	_active_backend = _select_backend()
	_configured_backend = rt_backend
	_configured_software_max_lights = software_max_lights_per_receiver
	if not _validate_runtime():
		return false
	_post_stack = RTPostProcessStack.new()
	var post_reservation_error := _post_stack.reserve(self)
	if not post_reservation_error.is_empty():
		_fail(post_reservation_error)
		return false
	if _active_backend == RTBackend.HARDWARE:
		var scenario_reservation_error := _reserve_scenario_ownership()
		if not scenario_reservation_error.is_empty():
			_fail(scenario_reservation_error)
			return false
	# Newly-instantiated Sky/material/texture RIDs are submitted asynchronously.
	# Give the render server two bounded frames before the one initialization
	# panorama bake so runtime-created HDRIs do not produce a transient black
	# snapshot (and do not require a second corrective rebake/revision).
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or generation != _lifecycle_generation:
		return false
	if not _collect_scene():
		return false
	_connect_scene_tree_signals()
	_apply_renderer_overrides()
	if _active_backend == RTBackend.HARDWARE:
		_create_material_id_carrier()
		# The carrier is created after the first override pass so it cannot be
		# mistaken for an authored scene light. Reassert the hardware-only state.
		_apply_renderer_overrides()
		_install_compositor()
		if _failed:
			return false
		_publish_snapshot()
	else:
		_publish_snapshot()
		if _failed:
			return false
		_software_tracer = RTSoftwareTracer.new()
		var software_error := _software_tracer.initialize(
			self,
			_current_snapshot,
			_material_sources,
			_instances,
			software_max_lights_per_receiver)
		if not software_error.is_empty():
			_fail(software_error)
			return false
	var post_error := _post_stack.configure(self, _get_post_settings())
	if not post_error.is_empty():
		_fail(post_error)
		return false
	if _active_backend == RTBackend.SOFTWARE:
		_mark_rt_ready()
	_manager_active = true
	print("RT backend: %s" % get_active_rt_backend())
	return true


func _stop_rt_internal(clear_pending_sync: bool) -> void:
	_manager_active = false
	_ready_emitted = false
	_disconnect_mesh_signals()
	_detach_compositor()
	if _carrier_light:
		_carrier_light.visible = false
	_active_backend = -1
	_configured_backend = -1
	_configured_software_max_lights = 0
	_current_snapshot = {}
	_snapshot_bridge.deactivate()
	_failed = false
	_remove_failure_layer()
	if clear_pending_sync:
		_topology_sync_pending = false
		_topology_sync_in_progress = false
		_topology_sync_debounce_frames = 0


func _run_topology_sync() -> void:
	if _topology_sync_in_progress or _lifecycle_busy:
		return
	_topology_sync_pending = false
	_topology_sync_in_progress = true
	_topology_sync_starts += 1
	topology_sync_started.emit()
	_lifecycle_generation += 1
	var generation := _lifecycle_generation
	_stop_rt_internal(false)
	_lifecycle_busy = true
	var initialized := await _start_rt_internal(generation)
	if generation == _lifecycle_generation:
		_lifecycle_busy = false
	var succeeded := false
	if initialized and generation == _lifecycle_generation:
		succeeded = await _wait_for_rt_ready(generation)
	_topology_sync_in_progress = false
	if succeeded:
		_topology_sync_completions += 1
		topology_sync_completed.emit()
	else:
		_topology_sync_failures += 1


func _wait_for_rt_ready(generation: int) -> bool:
	# Hardware readiness is reported by the render-thread snapshot bridge on a
	# later frame. Generation checks make stop_rt() and a superseding restart
	# bounded wake-ups for every waiter without introducing a second timer here.
	var deadline_msec := Time.get_ticks_msec() + roundi(
		maxf(startup_timeout_seconds, 1.0) * 1000.0)
	while (
			is_inside_tree()
			and generation == _lifecycle_generation
			and _manager_active
			and not _failed
			and not _ready_emitted
	):
		if Time.get_ticks_msec() >= deadline_msec:
			_fail(
				"The %s RT backend did not report ready within %.1f seconds."
				% [get_active_rt_backend(), startup_timeout_seconds])
			break
		await get_tree().process_frame
	return (
		generation == _lifecycle_generation
		and _manager_active
		and not _failed
		and _ready_emitted
	)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		_process_editor_preview()
		return
	if _topology_sync_pending and not _topology_sync_in_progress:
		if _topology_sync_debounce_frames > 0:
			_topology_sync_debounce_frames -= 1
		elif not _lifecycle_busy:
			_run_topology_sync()
		return
	if _lifecycle_busy:
		return
	if not _manager_active or _failed:
		return
	if rt_backend != _configured_backend:
		_fail("Changing rt_backend at runtime requires reloading the scene.")
		return
	if software_max_lights_per_receiver != _configured_software_max_lights:
		_fail("Changing software_max_lights_per_receiver at runtime requires reloading the scene.")
		return
	var scene_contract_failure := _runtime_scene_contract_failure()
	if not scene_contract_failure.is_empty():
		_fail(scene_contract_failure)
		return
	if not _validate_environment_contract():
		return
	if _active_backend == RTBackend.HARDWARE:
		if not _scenario_reservation_is_current():
			_fail("The hardware RT manager no longer owns its World3D compositor scenario.")
			return
		var render_failure := _snapshot_bridge.take_failure()
		if not render_failure.is_empty():
			_fail(render_failure)
			return
		if _snapshot_bridge.take_ready():
			_mark_rt_ready()
	# Transform and property value changes do not all expose connectable signals
	# in Godot, so they are polled below without allocating replacement snapshot
	# containers unless a value actually differs. Tree topology does expose
	# signals, allowing the previous periodic find_children() scan to be removed.
	var profile_start := Time.get_ticks_usec() if profiling_enabled else 0
	if _topology_dirty:
		request_topology_sync()
		return
	if _light_topology_dirty:
		_light_topology_dirty = false
		_discover_lights(true)
	_poll_light_shadow_overrides()
	_publish_snapshot()
	if _software_tracer:
		var software_error := _software_tracer.update(_current_snapshot)
		if not software_error.is_empty():
			_fail(software_error)
			return
		_software_tracer.reassert_overrides()
	if _post_stack:
		# No-op unless the flag actually changed, so this is a bool compare per
		# frame. Armed here rather than at the profile read because the server
		# timers need to have been running for the frames being measured.
		_post_stack.set_pass_profiling_enabled(profiling_enabled)
		var post_error := _post_stack.process_frame()
		if not post_error.is_empty():
			_fail(post_error)
			return
	if profile_start != 0:
		var elapsed := Time.get_ticks_usec() - profile_start
		_profile_poll_frames += 1
		_profile_last_update_usec = elapsed
		_profile_peak_update_usec = maxi(_profile_peak_update_usec, elapsed)


func _exit_tree() -> void:
	_lifecycle_generation += 1
	_lifecycle_busy = false
	_manager_active = false
	if Engine.is_editor_hint():
		_teardown_editor_preview()
	else:
		_stop_rt_internal(true)
	_disconnect_scene_tree_signals()
	_disconnect_mesh_signals()
	_detach_compositor()


func _schedule_editor_preview_sync() -> void:
	if not Engine.is_editor_hint() or not preview_in_editor:
		return
	_editor_preview_debounce_frames = EDITOR_PREVIEW_DEBOUNCE_FRAMES
	_editor_preview_poll_frames = 0
	set_process(true)


func _process_editor_preview() -> void:
	if not preview_in_editor:
		_teardown_editor_preview()
		set_process(false)
		return
	if _editor_preview_debounce_frames > 0:
		_editor_preview_debounce_frames -= 1
		if _editor_preview_debounce_frames == 0:
			_build_editor_preview()
		return
	if _editor_preview_active:
		_update_editor_preview()
		return
	_editor_preview_poll_frames += 1
	var poll_interval := (
		EDITOR_PREVIEW_RETRY_FRAMES
		if not _editor_preview_error.is_empty()
		else EDITOR_PREVIEW_POLL_FRAMES)
	if _editor_preview_poll_frames >= poll_interval:
		_editor_preview_poll_frames = 0
		_build_editor_preview()


func _build_editor_preview() -> void:
	# Always the software backend here, whatever rt_backend requests. The
	# hardware path would install a CompositorEffect on the edited scene's
	# World3D scenario and switch managed materials into the visibility-buffer
	# transport, which renders as garbage the moment the compositor is missing.
	_teardown_editor_preview()
	if not preview_in_editor or not is_inside_tree():
		return
	# Switching editor scene tabs removes and re-adds the edited scene root, so
	# _exit_tree() drops these and _ready() does not run again. Reconnecting here
	# is idempotent and keeps mesh/light edits driving rebuilds afterwards.
	_connect_scene_tree_signals()
	_editor_preview_error = ""
	# Tool scenes are often observed while their owner tree is only partly
	# assembled. Missing roots are transient here: polling retries without
	# latching the runtime failure state or allocating RT resources.
	if get_node_or_null(geometry_root_path) == null:
		return
	_active_backend = RTBackend.SOFTWARE
	_configured_backend = rt_backend
	_configured_software_max_lights = software_max_lights_per_receiver
	var failures := _software_rt_failures()
	if not failures.is_empty():
		_abort_editor_preview("\n".join(failures))
		return
	if not _collect_scene() or _failed:
		_abort_editor_preview("")
		return
	_apply_renderer_overrides()
	_publish_snapshot()
	if _failed:
		_abort_editor_preview("")
		return
	_software_tracer = RTSoftwareTracer.new()
	var software_error := _software_tracer.initialize(
		self,
		_current_snapshot,
		_material_sources,
		_instances,
		software_max_lights_per_receiver)
	if not software_error.is_empty():
		_abort_editor_preview(software_error)
		return
	_editor_preview_active = true
	_editor_preview_reported_error = ""
	_editor_preview_poll_frames = 0


func _update_editor_preview() -> void:
	# Editing constantly adds, removes, and replaces meshes and materials. Each
	# of those is a debounced rebuild trigger here rather than the runtime hard
	# failure, because BLASes are immutable once built.
	if (
			_topology_dirty
			or software_max_lights_per_receiver != _configured_software_max_lights
	):
		_schedule_editor_preview_sync()
		return
	if _light_topology_dirty:
		_light_topology_dirty = false
		_discover_lights(true)
	_poll_light_shadow_overrides()
	_publish_snapshot()
	if _failed:
		_restart_editor_preview()
		return
	if _software_tracer:
		var software_error := _software_tracer.update(_current_snapshot)
		if not software_error.is_empty():
			_restart_editor_preview()
			return
		_software_tracer.reassert_overrides()


func _restart_editor_preview() -> void:
	# A live change the incremental path cannot absorb is an ordinary rebuild
	# trigger in the editor, not a failure worth reporting. Drop back to raster
	# and reassemble after the usual debounce.
	_teardown_editor_preview()
	_schedule_editor_preview_sync()


func _abort_editor_preview(reason: String) -> void:
	# Editor failures never latch: they tear down to plain raster and retry.
	var reported := reason if not reason.is_empty() else _editor_preview_error
	if reported.is_empty():
		reported = "The RT editor preview could not be built."
	_teardown_editor_preview()
	_editor_preview_error = reported
	_editor_preview_poll_frames = 0
	if reported != _editor_preview_reported_error:
		_editor_preview_reported_error = reported
		push_warning(
			"RT editor preview unavailable; the viewport is showing plain raster.\n%s"
			% reported)


func _teardown_editor_preview() -> void:
	# Renderer-only overrides persist until they are cleared, so this must undo
	# everything the preview installed and reset every container the collection
	# pass expects to own. Scene-tree signals stay connected: they are the
	# rebuild trigger.
	if _software_tracer:
		_software_tracer.shutdown()
		_software_tracer = null
	_disconnect_mesh_signals()
	_disconnect_texture_signals()
	_disconnect_environment_signals()
	_restore_renderer_overrides()
	_restore_editor_scene_materials()
	_instances.clear()
	_render_instances.clear()
	_render_instances_revision += 1
	_mesh_records.clear()
	_mesh_sources.clear()
	_material_records.clear()
	_material_sources.clear()
	_material_by_id.clear()
	_instance_material_indices.clear()
	_lights.clear()
	_receiver_light_starts.clear()
	_receiver_light_counts.clear()
	_receiver_light_indices.clear()
	_receiver_light_candidates.clear()
	_snapshot_instance_masks = PackedInt32Array()
	_snapshot_instance_layers = PackedInt32Array()
	# These three are published read-only, so they are replaced rather than
	# cleared in place.
	var empty_transforms: Array[Transform3D] = []
	_snapshot_transforms = empty_transforms
	_snapshot_environment = {}
	_current_snapshot = {}
	_snapshot_light = {}
	_albedo_atlas = null
	_normal_atlas = null
	_albedo_atlas_size = Vector2i.ONE
	_normal_atlas_size = Vector2i.ONE
	_albedo_region_by_texture_id.clear()
	_normal_region_by_texture_id.clear()
	_environment_source = null
	_environment_source_id = 0
	_environment_source_kind = &"default_clear"
	_environment_dirty = true
	_environment_debounce_frames = 0
	_topology_dirty = false
	_light_topology_dirty = false
	_texture_content_dirty = false
	_editor_preview_active = false
	_editor_preview_debounce_frames = 0
	_active_backend = -1
	_failed = false
	_manager_active = false


func _restore_editor_scene_materials() -> void:
	# Stateless safety net covering renderer state that can outlive this script
	# instance, most obviously across a tool-script reload. It reads only
	# authored node and material values, never captured state, so it can run at
	# any time and always restores the scene's own raster appearance.
	var root := get_node_or_null(geometry_root_path)
	if root == null:
		return
	var mesh_nodes := root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		mesh_nodes.push_front(root)
	for node in mesh_nodes:
		var mesh_node := node as MeshInstance3D
		if (
				mesh_node == null
				or not _is_managed_geometry(mesh_node)
				or not mesh_node.get_instance().is_valid()
		):
			continue
		var instance_rid := mesh_node.get_instance()
		var overall := mesh_node.material_override
		RenderingServer.instance_geometry_set_material_override(
			instance_rid, overall.get_rid() if overall else RID())
		if mesh_node.mesh:
			for surface in mesh_node.mesh.get_surface_count():
				var authored := mesh_node.get_surface_override_material(surface)
				RenderingServer.instance_set_surface_override_material(
					instance_rid, surface, authored.get_rid() if authored else RID())
				var material := mesh_node.get_active_material(surface) as ShaderMaterial
				if material != null and material.shader == BLINN_PHONG_SHADER:
					_clear_managed_material_carrier_uniforms(material)
		RenderingServer.instance_set_layer_mask(instance_rid, mesh_node.layers)
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, &"rt_instance_id", 0)
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RTSoftwareTracer.RT_RECEIVER_LAYERS_PARAMETER, 0)
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RTSoftwareTracer.RT_RECEIVER_LIGHT_START_PARAMETER, 0)
		RenderingServer.instance_geometry_set_shader_parameter(
			instance_rid, RTSoftwareTracer.RT_RECEIVER_LIGHT_COUNT_PARAMETER, 0)
	var light_nodes := root.find_children("*", "Light3D", true, false)
	if root is Light3D:
		light_nodes.push_front(root)
	for node in light_nodes:
		var light := node as Light3D
		if light != null and light != _carrier_light and light.get_base().is_valid():
			RenderingServer.light_set_shadow(light.get_base(), light.shadow_enabled)


func _clear_managed_material_carrier_uniforms(material: ShaderMaterial) -> void:
	if material == null or not is_instance_valid(material):
		return
	RenderingServer.material_set_param(
		material.get_rid(), RT_PIPELINE_ACTIVE_PARAMETER, false)
	RenderingServer.material_set_param(
		material.get_rid(), RT_MATERIAL_ID_PARAMETER, 0)
	RenderingServer.material_set_param(
		material.get_rid(), RT_HAS_ALBEDO_PARAMETER, false)
	RenderingServer.material_set_param(
		material.get_rid(), RT_HAS_NORMAL_PARAMETER, false)


func _connect_scene_tree_signals() -> void:
	if _tree_signals_connected or get_tree() == null:
		return
	get_tree().node_added.connect(_on_tree_node_added)
	get_tree().node_removed.connect(_on_tree_node_removed)
	_tree_signals_connected = true


func _disconnect_scene_tree_signals() -> void:
	if not _tree_signals_connected or get_tree() == null:
		return
	if get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.disconnect(_on_tree_node_added)
	if get_tree().node_removed.is_connected(_on_tree_node_removed):
		get_tree().node_removed.disconnect(_on_tree_node_removed)
	_tree_signals_connected = false


func _on_tree_node_added(node: Node) -> void:
	if _failed or node == _carrier_light or node.has_meta(&"__rt_internal"):
		return
	# In the editor this signal also carries every node the editor's own UI
	# creates, because the edited scene shares the editor's SceneTree. Only
	# managed 3D nodes beneath the geometry root may trigger a rebuild.
	if (
			node is MeshInstance3D
			and _is_under_geometry_root(node)
			and _is_managed_geometry(node as MeshInstance3D)
	):
		var mesh_node := node as MeshInstance3D
		if _is_receiver_only_geometry(mesh_node):
			if Engine.is_editor_hint():
				request_topology_sync()
			elif _manager_active:
				_register_receiver_only_node.call_deferred(mesh_node)
		else:
			request_topology_sync()
	elif node is Light3D and _is_under_geometry_root(node):
		_light_topology_dirty = true
	else:
		return
	_schedule_editor_preview_rebuild_if_needed()


func _on_tree_node_removed(node: Node) -> void:
	if _failed or node.has_meta(&"__rt_internal"):
		return
	if node is MeshInstance3D:
		for instance_index in _instances.size():
			var item := _instances[instance_index]
			if item["node"] == node:
				if bool(item.get("receiver_only", false)):
					if Engine.is_editor_hint():
						request_topology_sync()
					else:
						_unregister_receiver_only_instance(instance_index)
				else:
					request_topology_sync()
				return
	elif node is Light3D:
		for light in _lights:
			if light == node:
				_light_topology_dirty = true
				_schedule_editor_preview_rebuild_if_needed()
				return


func _schedule_editor_preview_rebuild_if_needed() -> void:
	# A live preview absorbs light changes incrementally; only topology changes,
	# or having no preview installed at all, need the debounced rebuild.
	if not Engine.is_editor_hint():
		return
	if _editor_preview_active and not _topology_dirty:
		return
	_schedule_editor_preview_sync()


func _on_managed_mesh_changed() -> void:
	if not _failed:
		request_topology_sync()


func _disconnect_mesh_signals() -> void:
	for mesh in _mesh_sources:
		if is_instance_valid(mesh) and mesh.changed.is_connected(_on_managed_mesh_changed):
			mesh.changed.disconnect(_on_managed_mesh_changed)


func _on_managed_texture_changed() -> void:
	_texture_content_dirty = true


func _disconnect_texture_signals() -> void:
	for texture in _managed_texture_sources:
		if is_instance_valid(texture) and texture.changed.is_connected(_on_managed_texture_changed):
			texture.changed.disconnect(_on_managed_texture_changed)
	_managed_texture_sources.clear()


func _on_environment_resource_changed() -> void:
	# Resource.changed can fire several times during one inspector edit. Collapse
	# those notifications into one rebuild after a short quiet period.
	_environment_dirty = true
	_environment_debounce_frames = 2


func _disconnect_environment_signals() -> void:
	for resource in _managed_environment_resources:
		if (
				is_instance_valid(resource)
				and resource.changed.is_connected(_on_environment_resource_changed)
		):
			resource.changed.disconnect(_on_environment_resource_changed)
	_managed_environment_resources.clear()


func _track_environment_resource(resource: Resource) -> void:
	if resource == null or not is_instance_valid(resource):
		return
	for tracked in _managed_environment_resources:
		if tracked == resource:
			return
	_managed_environment_resources.append(resource)
	if not resource.changed.is_connected(_on_environment_resource_changed):
		resource.changed.connect(_on_environment_resource_changed)


func _track_environment_resources(environment: Environment) -> void:
	_disconnect_environment_signals()
	if environment == null:
		return
	_track_environment_resource(environment)
	var sky := environment.sky
	if sky == null:
		return
	_track_environment_resource(sky)
	var sky_material := sky.sky_material
	if sky_material == null:
		return
	_track_environment_resource(sky_material)
	# Built-in sky materials do not forward content changes from their optional
	# source textures, so observe those resources directly as well.
	if sky_material is PanoramaSkyMaterial:
		_track_environment_resource((sky_material as PanoramaSkyMaterial).panorama)
	elif sky_material is ProceduralSkyMaterial:
		_track_environment_resource((sky_material as ProceduralSkyMaterial).sky_cover)
	elif sky_material is PhysicalSkyMaterial:
		_track_environment_resource((sky_material as PhysicalSkyMaterial).night_sky)


func _suppress_native_environment_reflections(environment: Environment) -> void:
	if environment == null:
		return
	# Unlike every other override the manager installs, this one writes an
	# authored Resource property. The editor preview must not touch it: the
	# software clones are `unshaded, ambient_light_disabled` and ignore the
	# native reflection source anyway, and an in-memory edit here would be
	# written out by the next scene save.
	if Engine.is_editor_hint():
		return
	var environment_id := environment.get_instance_id()
	if not _environment_reflection_states.has(environment_id):
		_environment_reflection_states[environment_id] = {
			"environment": environment,
			"reflected_light_source": environment.reflected_light_source,
		}
	if environment.reflected_light_source != Environment.REFLECTION_SOURCE_DISABLED:
		environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED


func _restore_environment_reflection_states() -> void:
	for state_value in _environment_reflection_states.values():
		var state := state_value as Dictionary
		var environment := state.get("environment") as Environment
		if environment != null and is_instance_valid(environment):
			environment.reflected_light_source = int(
				state.get("reflected_light_source", Environment.REFLECTION_SOURCE_BG))
	_environment_reflection_states.clear()


func _managed_mesh_node(item: Dictionary) -> MeshInstance3D:
	# `as` raises "Trying to cast a freed object" before is_instance_valid() can
	# guard it, so the stored Variant is validated before it is cast. Deleting a
	# managed mesh is routine while the editor preview is installed.
	var node_value: Variant = item.get("node")
	if not is_instance_valid(node_value):
		return null
	return node_value as MeshInstance3D


func _is_under_geometry_root(node: Node) -> bool:
	var root := get_node_or_null(geometry_root_path)
	return root != null and (node == root or root.is_ancestor_of(node))


func _is_managed_geometry(node: MeshInstance3D) -> bool:
	if node == null:
		return false
	# Receiver-only is a specialization of managed geometry. Requiring both
	# groups would make one missed procedural tag silently enter the raster-only
	# path, so membership in the receiver group is sufficient on its own.
	if _is_receiver_only_geometry(node):
		return true
	return managed_geometry_group.is_empty() or node.is_in_group(managed_geometry_group)


func _is_receiver_only_geometry(node: MeshInstance3D) -> bool:
	return (
		node != null
		and not receiver_only_geometry_group.is_empty()
		and node.is_in_group(receiver_only_geometry_group)
	)


func _detach_compositor(restore_renderer_state: bool = true) -> void:
	var detaching_rt_effect := _rt_effect
	var owns_current_scenario := _scenario_reservation_is_current()
	_snapshot_bridge.deactivate()
	_disconnect_scene_tree_signals()
	_disconnect_texture_signals()
	_disconnect_environment_signals()
	if _software_tracer:
		_software_tracer.shutdown()
		_software_tracer = null
	if _post_stack:
		_post_stack.shutdown()
		_post_stack = null
	if detaching_rt_effect:
		detaching_rt_effect.enabled = false
	if (
			owns_current_scenario
			and _scenario_compositor_installed
			and _scenario.is_valid()
	):
		var previous_rid := RID()
		if _previous_compositor:
			previous_rid = _previous_compositor.get_rid()
		RenderingServer.scenario_set_compositor(_scenario, previous_rid)
	if owns_current_scenario:
		_scenario_world.remove_meta(SCENARIO_OWNER_META)
	_scenario = RID()
	_scenario_world = null
	_owns_scenario = false
	_scenario_compositor_installed = false
	if detaching_rt_effect:
		detaching_rt_effect.shutdown()
	if restore_renderer_state:
		_restore_renderer_overrides()
	if _carrier_light:
		_carrier_light.visible = false
	_rt_effect = null
	_compositor = null
	_previous_compositor = null
	_current_snapshot = {}


func _hardware_rt_failures() -> PackedStringArray:
	var failures := PackedStringArray()
	if OS.has_feature("web"):
		failures.append("Web exports do not expose Vulkan ray-tracing pipelines.")
	if RenderingServer.get_current_rendering_driver_name() != "vulkan":
		failures.append("Vulkan is required (actual driver: %s)." % RenderingServer.get_current_rendering_driver_name())
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		failures.append("Forward Plus is required (actual method: %s)." % RenderingServer.get_current_rendering_method())
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		failures.append("The global RenderingDevice is unavailable.")
	else:
		if RenderingServer.get_video_adapter_type() == RenderingDevice.DEVICE_TYPE_CPU:
			failures.append("Software/CPU Vulkan adapters are not hardware RT devices.")
		if not rd.has_feature(RenderingDevice.SUPPORTS_BUFFER_DEVICE_ADDRESS):
			failures.append("The adapter lacks buffer device address support.")
		if not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
			failures.append("The adapter lacks Vulkan ray-tracing pipeline support.")
	return failures


func _software_rt_failures() -> PackedStringArray:
	var failures := PackedStringArray()
	var method := RenderingServer.get_current_rendering_method()
	if method != "forward_plus" and method != "gl_compatibility":
		failures.append("Software RT supports Forward+ or Compatibility (actual method: %s)." % method)
	if software_max_lights_per_receiver < 1 or software_max_lights_per_receiver > 32:
		failures.append("software_max_lights_per_receiver must be between 1 and 32.")
	return failures


func _select_backend() -> int:
	match rt_backend:
		RTBackend.HARDWARE:
			return RTBackend.HARDWARE
		RTBackend.SOFTWARE:
			return RTBackend.SOFTWARE
		_:
			if not OS.has_feature("web") and _hardware_rt_failures().is_empty():
				return RTBackend.HARDWARE
			return RTBackend.SOFTWARE


func _validate_runtime() -> bool:
	var failures := _hardware_rt_failures() if _active_backend == RTBackend.HARDWARE else _software_rt_failures()
	var scene_contract_failure := _runtime_scene_contract_failure()
	if not scene_contract_failure.is_empty():
		failures.append(scene_contract_failure)
	if bool(ProjectSettings.get_setting(
			"rendering/anti_aliasing/screen_space_roughness_limiter/enabled", false)):
		failures.append("The screen-space roughness limiter must be disabled.")
	# RTPostProcessStack captures and normalizes every built-in AA/scaling flag
	# after scene validation, then restores the authored values on teardown.
	if failures.is_empty():
		return true
	var backend_name := "Hardware" if _active_backend == RTBackend.HARDWARE else "Software"
	_fail("%s ray tracing is unavailable:\n%s" % [backend_name, "\n".join(failures)])
	return false


func _runtime_scene_contract_failure() -> String:
	var viewport := get_viewport()
	if viewport == null:
		return "Ray tracing requires a valid Viewport."
	var camera := viewport.get_camera_3d()
	if camera == null:
		return "Ray tracing requires an active Camera3D in the managed Viewport."
	if (
			_active_backend == RTBackend.HARDWARE
			and (camera.cull_mask & RT_CARRIER_LAYER_MASK) == 0
	):
		return (
			"The active Camera3D (%s) cull_mask must include render layer %d, which "
			+ "hardware RT reserves for managed geometry and the material-ID carrier. "
			+ "Enable that camera layer."
			) % [camera.get_path(), RT_CARRIER_LAYER]
	if (_resolve_effective_environment().get("environment") as Environment) == null:
		return (
			"The managed Viewport has no effective Environment. Add a camera Environment, "
			+ "configure world_environment_path, or add a WorldEnvironment.")
	return ""


func _resolve_effective_environment() -> Dictionary:
	# Match Godot's visible-environment precedence as closely as the scene API
	# permits: the active render camera may override the scene, followed by the
	# explicitly configured WorldEnvironment, then the World3D and its fallback.
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d() if viewport else null
	if camera and camera.environment:
		return {"environment": camera.environment, "source": &"camera"}

	if not world_environment_path.is_empty():
		var explicit_node := get_node_or_null(world_environment_path) as WorldEnvironment
		if explicit_node and explicit_node.environment:
			return {"environment": explicit_node.environment, "source": &"explicit"}

	var world: World3D
	if camera and camera.get_world_3d():
		world = camera.get_world_3d()
	if world == null:
		var root := get_node_or_null(geometry_root_path) as Node3D
		if root:
			world = root.get_world_3d()
	if world == null and viewport:
		world = viewport.world_3d
	if world:
		if world.environment:
			return {"environment": world.environment, "source": &"world"}
		if world.fallback_environment:
			return {"environment": world.fallback_environment, "source": &"world_fallback"}
	return {"environment": null, "source": &"default_clear"}


func _validate_environment(environment: Environment) -> bool:
	if environment == null:
		return _validate_camera_attributes_contract()
	if environment.fog_enabled or environment.volumetric_fog_enabled:
		_fail(
			"Environment fog is replaced by RTSceneManager's distance fog "
			+ "(fog_enabled / fog_begin / fog_end / fog_curve, or configure_distance_fog()), "
			+ "which the hardware compositor, the software fragment path and subscribed "
			+ "unmanaged shaders apply identically. Engine fog is overwritten on managed "
			+ "surfaces and would double-apply on unmanaged ones. Disable it.")
		return false
	if (
			environment.ssao_enabled
			or environment.ssil_enabled
			or environment.ssr_enabled
			or environment.sdfgi_enabled
			or environment.glow_enabled
			or environment.adjustment_enabled
	):
		_fail("SSAO, SSIL, SSR, SDFGI, glow, and Environment adjustments must be disabled by the shared visual contract.")
		return false
	if (
			environment.tonemap_mode != Environment.TONE_MAPPER_LINEAR
			or not is_equal_approx(environment.tonemap_exposure, 1.0)
	):
		_fail("The shared visual contract requires linear tonemapping with exposure 1.0.")
		return false
	match environment.background_mode:
		Environment.BG_CLEAR_COLOR, Environment.BG_COLOR:
			return _validate_camera_attributes_contract()
		Environment.BG_SKY:
			if environment.sky == null:
				_fail("The effective Environment uses BG_SKY but has no Sky resource to bake for reflection misses.")
				return false
			if environment.sky.sky_material == null:
				_fail("The effective Environment Sky has no sky material to bake for reflection misses.")
				return false
			return _validate_camera_attributes_contract()
		_:
			_fail(
				"The effective Environment background mode %d cannot provide deterministic "
				+ "reflection-miss radiance. Use BG_CLEAR_COLOR, BG_COLOR, or BG_SKY."
				% environment.background_mode)
			return false


func _validate_camera_attributes_contract() -> bool:
	var attributes: CameraAttributes
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d() if viewport else null
	if camera and camera.attributes:
		attributes = camera.attributes
	elif not world_environment_path.is_empty():
		var world_environment := get_node_or_null(world_environment_path) as WorldEnvironment
		if world_environment:
			attributes = world_environment.camera_attributes
	if attributes == null:
		return true
	if attributes.auto_exposure_enabled or not is_equal_approx(attributes.exposure_multiplier, 1.0):
		_fail("Auto exposure and camera exposure overrides must be disabled by the shared visual contract.")
		return false
	if attributes is CameraAttributesPractical:
		var practical := attributes as CameraAttributesPractical
		if practical.dof_blur_far_enabled or practical.dof_blur_near_enabled:
			_fail("Camera depth of field must be disabled by the shared visual contract.")
			return false
	elif attributes is CameraAttributesPhysical:
		_fail("CameraAttributesPhysical depth-of-field/exposure behavior is outside the shared visual contract; use neutral CameraAttributesPractical settings.")
		return false
	return true


func _validate_environment_contract() -> bool:
	var resolved := _resolve_effective_environment()
	return _validate_environment(resolved.get("environment") as Environment)


func _linear_background_color(color: Color, energy: float) -> Color:
	var linear := color.srgb_to_linear()
	linear.r *= energy
	linear.g *= energy
	linear.b *= energy
	linear.a = 1.0
	return linear


## Sanitized transport form. x=begin, y=end (always greater than begin), z=curve,
## w=enabled. Matches the vec4 the three shading paths receive.
func _effective_fog_params() -> Vector4:
	var begin := maxf(fog_begin, 0.0)
	var end_distance := maxf(fog_end, begin + 0.001)
	return Vector4(begin, end_distance, maxf(fog_curve, 0.01), 1.0 if fog_enabled else 0.0)


## Runtime push for systems that derive fog reach from their own data, such as
## streamed terrain deriving it from its load distance. Equivalent to assigning
## the four exported properties, and emits [signal distance_fog_changed] once.
func configure_distance_fog(
		begin: float,
		end_distance: float,
		curve: float = 1.0,
		enabled: bool = true) -> void:
	var changed := (
		not is_equal_approx(fog_begin, begin)
		or not is_equal_approx(fog_end, end_distance)
		or not is_equal_approx(fog_curve, curve)
		or fog_enabled != enabled)
	if not changed:
		return
	# The four setters each call _mark_fog_dirty. Mute them so one push emits one
	# signal instead of four.
	_fog_signal_muted = true
	fog_begin = maxf(begin, 0.0)
	fog_end = maxf(end_distance, 0.0)
	fog_curve = clampf(curve, 0.01, 8.0)
	fog_enabled = enabled
	_fog_signal_muted = false
	_mark_fog_dirty()


## Replaces the reflection-miss radiance without touching the visible background
## or the fog. A sky system that draws its own dome keeps the Environment on
## BG_COLOR, because that is the branch with no panorama bake and the branch
## whose flat radiance the distance fog resolves to. This is the one thing that
## branch cannot supply: something for a mirror to reflect.
##
## [param image] is linear radiance; pass null to go back to the flat colour.
## The caller owns the bake and its schedule, and only pays for it when it asks.
func set_reflection_panorama(image: Image, sky_rotation: Basis = Basis.IDENTITY) -> void:
	if image == null or image.is_empty():
		if _reflection_override == null:
			return
		_reflection_override = null
		_reflection_override_basis = Basis.IDENTITY
		_environment_dirty = true
		_environment_debounce_frames = 0
		return
	var converted := image
	if converted.get_format() != Image.FORMAT_RGBAF:
		converted = image.duplicate()
		converted.convert(Image.FORMAT_RGBAF)
	if converted.get_format() != Image.FORMAT_RGBAF:
		push_warning("RTSceneManager: reflection panorama could not be converted to RGBAF.")
		return
	_reflection_override = ImageTexture.create_from_image(converted)
	_reflection_override_basis = sky_rotation.inverse()
	_environment_dirty = true
	_environment_debounce_frames = 0


## Swaps the reflection source into a snapshot that was otherwise built from the
## flat background, so fallback_linear stays the fog colour while the miss
## radiance becomes the supplied panorama.
func _apply_reflection_panorama_override(snapshot: Dictionary) -> void:
	if _reflection_override == null or snapshot.is_empty():
		return
	snapshot["mode"] = RTEnvironmentMode.PANORAMA
	snapshot["panorama"] = _reflection_override
	snapshot["inverse_sky_basis"] = _reflection_override_basis
	snapshot["width"] = _reflection_override.get_width()
	snapshot["height"] = _reflection_override.get_height()
	snapshot["bytes"] = _reflection_override.get_width() * _reflection_override.get_height() * 16
	snapshot["bake_source"] = &"reflection_override"


## Replaces what a reflection ray resolves when it misses the acceleration
## structure, for the one case that structure can never answer: the ground.
## Streamed terrain is registered receiver-only so chunk churn never rebuilds
## the TLAS, and shell grass is vertex-deformed and so outside the managed
## contract entirely. Neither can be traced, so the ground arrives as a
## heightfield the shader marches instead of as geometry.
##
## [param image] is RGBA32F. RGB is scene-linear ground radiance and A is canopy
## height in world Y, meaning the terrain surface plus whatever grass stands on
## it, so a reflection shows the canopy without one blade being traced. Pass
## null to drop the layer and go back to a plain environment miss.
##
## [param window_origin_xz] is the minimum corner in world XZ and
## [param window_size] the extent in metres of the square the image covers.
## [param height_range] is the lowest and highest canopy height in that image;
## it is what lets a ray clearing the terrain skip the march outright, so it
## must bound the data rather than approximate it. [param ambient] is the
## ambient radiance the real ground receives, so its reflection is lit the way
## the original is.
##
## The caller owns the bake and its schedule, and only pays for it when it asks.
func configure_ground_layer(
		image: Image,
		window_origin_xz: Vector2,
		window_size: float,
		height_range: Vector2,
		ambient: Color) -> void:
	if image == null or image.is_empty() or window_size <= 0.0:
		if _ground_texture == null:
			return
		_ground_texture = null
		_ground_params = Vector4.ZERO
		_ground_bounds = Vector4.ZERO
		_ground_ambient = Color.BLACK
		_ground_revision += 1
		return
	var converted := image
	if converted.get_format() != Image.FORMAT_RGBAF:
		converted = image.duplicate()
		converted.convert(Image.FORMAT_RGBAF)
	if converted.get_format() != Image.FORMAT_RGBAF:
		push_warning("RTSceneManager: the ground layer could not be converted to RGBAF.")
		return
	# Updating in place keeps the texture RID, so a rebake does not invalidate
	# the hardware descriptor set. Only a resize has to allocate a new one.
	if (
			_ground_texture != null
			and int(_ground_texture.get_width()) == converted.get_width()
			and int(_ground_texture.get_height()) == converted.get_height()
	):
		_ground_texture.update(converted)
	else:
		_ground_texture = ImageTexture.create_from_image(converted)
	# w is left at zero here and filled with the march step count when the
	# snapshot commits, because that is a ray budget this manager owns rather
	# than something the terrain producer should be choosing. Same for bounds.z,
	# the march distance, which follows the fog the manager also owns.
	_ground_params = Vector4(
		window_origin_xz.x,
		window_origin_xz.y,
		1.0 / window_size,
		0.0)
	_ground_bounds = Vector4(
		height_range.x,
		height_range.y,
		0.0,
		window_size / float(maxi(converted.get_width(), 1)))
	_ground_ambient = ambient
	_ground_revision += 1


## Blade-scale variation for the reflected canopy, which the heightfield above
## resolves as one smooth surface. The producer bakes an average of the blade
## gradient into that surface's colour, and averaging is exactly what removes
## the thing a mirror makes obvious: without this the reflected field is a flat
## painted plane next to grass that visibly has blades in it.
##
## [param blade_frequency] is blade cells per metre, the same figure the grass
## renderer lays its stalks on. [param detail_strength] is 0..1 and zero is the
## off switch, leaving the reflected canopy exactly as it was baked.
## [param ramp_depth] is how far towards a blade's shaded base the darkest cell
## reaches. [param fade_distance] is where the detail has faded out completely;
## it exists because nothing here filters temporally and an unfaded per-pixel
## modulation crawls in the distance, so pass the reach the ground layer itself
## is useful over rather than something larger.
##
## This is texture on a stand-in surface, not traced grass. It cannot silhouette,
## cast, or receive anything.
func configure_ground_grass(
		blade_frequency: float,
		detail_strength: float,
		ramp_depth: float,
		fade_distance: float) -> void:
	var next_grass := Vector4(
		maxf(blade_frequency, 0.0),
		clampf(detail_strength, 0.0, 1.0),
		clampf(ramp_depth, 0.0, 1.0),
		maxf(fade_distance, 0.0))
	if next_grass == _ground_grass:
		return
	_ground_grass = next_grass
	_ground_revision += 1


## The producer supplies the window and the heights it baked; the march step
## count and the march distance are ray budget this manager owns, so they are
## resolved here rather than at configure_ground_layer() time. The snapshot and
## get_ground_layer() both read through this, so a consumer inspecting the layer
## sees exactly what the shader will march. The march never needs to outrun the
## fog: past fog_end the ground has already resolved to the same flat radiance
## the sky shows there, so marching further only costs.
func _resolved_ground_layer(fog_params: Vector4) -> Array:
	var params := _ground_params
	var bounds := _ground_bounds
	if _ground_texture == null:
		return [params, bounds]
	params.w = float(maxi(ground_march_steps, 0))
	var window_size := 1.0 / maxf(params.z, 0.000001)
	bounds.z = window_size * 2.0
	if fog_params.w >= 0.5:
		bounds.z = minf(fog_params.y, bounds.z)
	return [params, bounds]


## Everything a shader needs to resolve the same ground this renderer reflects.
func get_ground_layer() -> Dictionary:
	var resolved := _resolved_ground_layer(_effective_fog_params())
	return {
		"texture": _ground_texture,
		"params": resolved[0],
		"bounds": resolved[1],
		"ambient": _ground_ambient,
		"grass": _ground_grass,
		"sun_direction": _snapshot_ground_sun_direction,
		"sun_radiance": _snapshot_ground_sun_radiance,
		"sun_enabled": _snapshot_ground_sun_enabled,
	}


## The brightest directional light in the published table, which is what the
## ground layer is lit by. Positional lights are skipped on purpose: the layer
## stands in for terrain out to the fog boundary, where a lamp a few metres from
## the camera has no bearing on what a mirror shows.
func _ground_sun_from_lights(light_snapshot: Dictionary) -> Array:
	var best_direction := Vector3.UP
	var best_radiance := Color.BLACK
	var best_score := 0.0
	for record: Dictionary in light_snapshot.get("records", []) as Array:
		if int(record.get("type", -1)) != 0:
			continue
		var radiance: Color = record.get("color", Color.BLACK)
		var score := radiance.r * 0.2126 + radiance.g * 0.7152 + radiance.b * 0.0722
		if score <= best_score:
			continue
		best_score = score
		best_radiance = radiance
		best_direction = record.get("direction", Vector3.UP)
	return [best_direction, best_radiance, best_score > 0.0]


## "color" is scene-linear radiance that has already been background-energy
## scaled, so a consumer must not convert it again.
func get_distance_fog() -> Dictionary:
	var params := _effective_fog_params()
	return {
		"enabled": params.w >= 0.5,
		"begin": params.x,
		"end": params.y,
		"curve": params.z,
		"color": _current_fog_color(),
	}


func _current_fog_color() -> Color:
	if not _snapshot_environment.is_empty():
		return _snapshot_environment.get("fallback_linear", Color.BLACK)
	# Before start_rt() the snapshot is empty. Resolve directly so a freshly
	# installed level already fogs to the right colour on its first rendered frame.
	var resolved := _resolve_effective_environment()
	var environment := resolved.get("environment") as Environment
	if environment == null:
		return _linear_background_color(RenderingServer.get_default_clear_color(), 1.0)
	var energy := environment.background_energy_multiplier
	if environment.background_mode == Environment.BG_COLOR:
		return _linear_background_color(environment.background_color, energy)
	# BG_CLEAR_COLOR and BG_SKY both fall back to the clear colour here. Under a sky
	# that is an approximation: the fog asymptote is flat while the visible
	# background is not. This project uses BG_COLOR.
	return _linear_background_color(RenderingServer.get_default_clear_color(), energy)


func _mark_fog_dirty() -> void:
	# Setters also run during property initialization, before the node exists in
	# the tree. The periodic _publish_snapshot pass picks the values up either way.
	if _fog_signal_muted or not is_inside_tree():
		return
	distance_fog_changed.emit(get_distance_fog())


func _sky_bake_size(sky: Sky) -> Vector2i:
	var radiance_index := clampi(int(sky.radiance_size), 0, SKY_RADIANCE_SIZES.size() - 1)
	var height := mini(ENVIRONMENT_PANORAMA_MAX_SIZE.y, int(SKY_RADIANCE_SIZES[radiance_index]))
	return Vector2i(mini(ENVIRONMENT_PANORAMA_MAX_SIZE.x, height * 2), height)


func _diagnose_dynamic_sky_snapshot(sky: Sky) -> void:
	if sky == null or not (sky.sky_material is ShaderMaterial):
		return
	var shader_material := sky.sky_material as ShaderMaterial
	if shader_material.shader == null:
		return
	var shader_code := shader_material.shader.code.to_upper()
	if not shader_code.contains("TIME") and not shader_code.contains("POSITION"):
		return
	var material_id := shader_material.get_instance_id()
	if _dynamic_sky_snapshot_warnings.has(material_id):
		return
	_dynamic_sky_snapshot_warnings[material_id] = true
	push_warning(
		"The effective custom sky reads TIME or POSITION. RT captures it as a "
		+ "static resource-change snapshot; it is not rebaked every frame.")


func _canonicalize_panorama_material(
		material: PanoramaSkyMaterial,
		bake_size: Vector2i,
		environment_energy: float) -> Dictionary:
	# Godot 4.7's Compatibility sky bake can reinterpret a runtime RGBAF
	# PanoramaSkyMaterial differently from Forward+. The public bake is still
	# executed (and must succeed) for contract validation, then the CPU-readable
	# source is normalized identically on every renderer.
	var source_texture := material.panorama
	if source_texture == null:
		return {"error": "The effective PanoramaSkyMaterial has no panorama texture."}
	# Runtime-created float textures can be read back as normalized RGB on Web.
	# A producer that already owns the linear CPU image may attach it here; the
	# copy keeps canonicalization immutable. Imported HDR panoramas continue to
	# use their CPU-readable texture image.
	var source_image: Image
	var retained_source := source_texture.get_meta(
		&"rt_linear_panorama_image", null) as Image
	if retained_source != null and not retained_source.is_empty():
		source_image = Image.create_from_data(
			retained_source.get_width(),
			retained_source.get_height(),
			retained_source.has_mipmaps(),
			retained_source.get_format(),
			retained_source.get_data())
	else:
		source_image = source_texture.get_image()
	if source_image == null or source_image.is_empty():
		return {
			"error": (
				"The effective panorama has no CPU-readable image. Import it with CPU "
				+ "access enabled so Forward+, Compatibility, and Web can share one bake."),
		}
	if source_image.is_compressed() and source_image.decompress() != OK:
		return {"error": "The effective panorama texture could not be decompressed."}
	var source_format := source_image.get_format()
	var source_is_linear := (
		source_format >= Image.FORMAT_RF
		and source_format <= Image.FORMAT_RGBE9995)
	if source_image.get_size() != bake_size:
		source_image.resize(bake_size.x, bake_size.y, Image.INTERPOLATE_BILINEAR)
	if source_image.get_format() != Image.FORMAT_RGBAF:
		source_image.convert(Image.FORMAT_RGBAF)
	if source_image.get_format() != Image.FORMAT_RGBAF:
		return {"error": "The effective panorama could not be converted to linear RGBAF."}
	var exposure := environment_energy * material.energy_multiplier
	for y in source_image.get_height():
		for x in source_image.get_width():
			var source := source_image.get_pixel(x, y)
			var radiance := source if source_is_linear else source.srgb_to_linear()
			radiance.r *= exposure
			radiance.g *= exposure
			radiance.b *= exposure
			radiance.a = source.a
			source_image.set_pixel(x, y, radiance)
	return {"image": source_image}


func _environment_image_stats(image: Image) -> Dictionary:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	var seam_maximum := 0.0
	var north_pole_maximum := 0.0
	var south_pole_maximum := 0.0
	var north_reference := image.get_pixel(0, 0)
	var south_reference := image.get_pixel(0, image.get_height() - 1)
	for y in image.get_height():
		var left := image.get_pixel(0, y)
		var right := image.get_pixel(image.get_width() - 1, y)
		seam_maximum = maxf(seam_maximum, maxf(
			absf(left.r - right.r),
			maxf(absf(left.g - right.g), absf(left.b - right.b))))
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			var rgb := Vector3(color.r, color.g, color.b)
			minimum = minimum.min(rgb)
			maximum = maximum.max(rgb)
			if y == 0:
				north_pole_maximum = maxf(north_pole_maximum, maxf(
					absf(color.r - north_reference.r),
					maxf(
						absf(color.g - north_reference.g),
						absf(color.b - north_reference.b))))
			elif y == image.get_height() - 1:
				south_pole_maximum = maxf(south_pole_maximum, maxf(
					absf(color.r - south_reference.r),
					maxf(
						absf(color.g - south_reference.g),
						absf(color.b - south_reference.b))))
	return {
		"minimum": minimum,
		"maximum": maximum,
		"peak": maxf(maximum.x, maxf(maximum.y, maximum.z)),
		"seam_maximum": seam_maximum,
		"north_pole_maximum": north_pole_maximum,
		"south_pole_maximum": south_pole_maximum,
	}


func _make_environment_snapshot(
		environment: Environment,
		source_kind: StringName,
		next_revision: int) -> Dictionary:
	var energy := environment.background_energy_multiplier if environment else 1.0
	var clear_color := RenderingServer.get_default_clear_color()
	var fallback_linear := _linear_background_color(clear_color, energy)
	var source_id := environment.get_instance_id() if environment else 0
	if environment == null or environment.background_mode == Environment.BG_CLEAR_COLOR:
		return {
			"revision": next_revision,
			"mode": RTEnvironmentMode.FLAT,
			"fallback_linear": fallback_linear,
			"panorama": null,
			"inverse_sky_basis": Basis.IDENTITY,
			"width": 0,
			"height": 0,
			"bytes": 0,
			"source": source_kind,
			"source_id": source_id,
			"background_energy": energy,
			"bake_duration_usec": 0,
			"rebake_count": _environment_bakes,
			"bake_source": &"flat",
		}
	if environment.background_mode == Environment.BG_COLOR:
		fallback_linear = _linear_background_color(environment.background_color, energy)
		return {
			"revision": next_revision,
			"mode": RTEnvironmentMode.FLAT,
			"fallback_linear": fallback_linear,
			"panorama": null,
			"inverse_sky_basis": Basis.IDENTITY,
			"width": 0,
			"height": 0,
			"bytes": 0,
			"source": source_kind,
			"source_id": source_id,
			"background_energy": energy,
			"bake_duration_usec": 0,
			"rebake_count": _environment_bakes,
			"bake_source": &"flat",
		}

	var sky := environment.sky
	_diagnose_dynamic_sky_snapshot(sky)
	var bake_size := _sky_bake_size(sky)
	var bake_started := Time.get_ticks_usec()
	# This API evaluates built-in, panorama, and custom sky materials into the
	# same linear, untone-mapped radiance representation. A backend that cannot
	# bake it fails explicitly below; reflection misses never silently fall back
	# to a flat color.
	RenderingServer.force_sync()
	var image := RenderingServer.sky_bake_panorama(
		sky.get_rid(), energy, false, bake_size)
	var bake_source := &"rendering_server" as StringName
	var bake_usec := Time.get_ticks_usec() - bake_started
	_environment_bakes += 1
	_environment_last_bake_usec = bake_usec
	_environment_peak_bake_usec = maxi(_environment_peak_bake_usec, bake_usec)
	if image == null or image.is_empty():
		_environment_bake_failures += 1
		_fail(
			"Failed to bake the effective BG_SKY resource into the %dx%d linear reflection panorama."
			% [bake_size.x, bake_size.y])
		return {}
	# Godot 4.7 returns renderer-dependent results for runtime-created Panorama
	# skies (and Web may return a nonempty black bake). The public API above is
	# still mandatory; after it succeeds, normalize the CPU-readable linear source
	# identically for Forward+, Compatibility, and Web.
	if sky.sky_material is PanoramaSkyMaterial:
		var canonical := _canonicalize_panorama_material(
			sky.sky_material as PanoramaSkyMaterial, bake_size, energy)
		var canonical_error := String(canonical.get("error", ""))
		if not canonical_error.is_empty():
			_environment_bake_failures += 1
			_fail(canonical_error)
			return {}
		image = canonical.get("image") as Image
		bake_source = &"panorama_source_canonical"
		_environment_panorama_source_canonicalizations += 1
	if image.get_width() != bake_size.x or image.get_height() != bake_size.y:
		_environment_bake_failures += 1
		_fail(
			"Sky panorama bake returned %dx%d; expected %dx%d."
			% [image.get_width(), image.get_height(), bake_size.x, bake_size.y])
		return {}
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	if image.get_format() != Image.FORMAT_RGBAF:
		_environment_bake_failures += 1
		_fail("The sky panorama bake could not be converted to linear RGBAF data.")
		return {}
	var image_stats := _environment_image_stats(image)
	var panorama := ImageTexture.create_from_image(image)
	if panorama == null or panorama.get_width() <= 0 or panorama.get_height() <= 0:
		_environment_bake_failures += 1
		_fail("Unable to create the immutable reflection panorama texture from the sky bake.")
		return {}
	var byte_count := bake_size.x * bake_size.y * 16
	_environment_panorama_uploads += 1
	return {
		"revision": next_revision,
		"mode": RTEnvironmentMode.PANORAMA,
		"fallback_linear": fallback_linear,
		"panorama": panorama,
		"inverse_sky_basis": Basis.from_euler(environment.sky_rotation).inverse(),
		"width": bake_size.x,
		"height": bake_size.y,
		"bytes": byte_count,
		"source": source_kind,
		"source_id": source_id,
		"background_energy": energy,
		"bake_duration_usec": bake_usec,
		"rebake_count": _environment_bakes,
		"bake_source": bake_source,
		"radiance_minimum": image_stats["minimum"],
		"radiance_maximum": image_stats["maximum"],
		"peak_radiance": image_stats["peak"],
		"seam_maximum": image_stats["seam_maximum"],
		"north_pole_maximum": image_stats["north_pole_maximum"],
		"south_pole_maximum": image_stats["south_pole_maximum"],
	}


func _refresh_environment_snapshot(force: bool = false) -> int:
	var resolved := _resolve_effective_environment()
	var environment := resolved.get("environment") as Environment
	var source_kind := resolved.get("source", &"default_clear") as StringName
	var source_id := environment.get_instance_id() if environment else 0
	if source_id != _environment_source_id or source_kind != _environment_source_kind:
		if not _environment_dirty and not force:
			_environment_debounce_frames = 2
			_environment_dirty = true
	# The RenderingServer default clear color is global state rather than a
	# Resource and therefore emits no `changed` signal. Poll the small flat value
	# so BG_CLEAR_COLOR snapshots still revise when gameplay changes it.
	if (
			not force
			and not _environment_dirty
			and not _snapshot_environment.is_empty()
			and (environment == null or environment.background_mode == Environment.BG_CLEAR_COLOR)
	):
		var energy := environment.background_energy_multiplier if environment else 1.0
		var expected_clear := _linear_background_color(
			RenderingServer.get_default_clear_color(), energy)
		var captured_clear: Color = _snapshot_environment.get(
			"fallback_linear", Color.TRANSPARENT)
		if not captured_clear.is_equal_approx(expected_clear):
			_environment_dirty = true
			_environment_debounce_frames = 0
	if not force and not _environment_dirty and not _snapshot_environment.is_empty():
		return 0
	if not force and _environment_debounce_frames > 0:
		_environment_debounce_frames -= 1
		return 0
	if not _validate_environment(environment):
		return -1
	_suppress_native_environment_reflections(environment)
	_track_environment_resources(environment)
	var next_revision := _environment_revision + 1
	var next_environment := _make_environment_snapshot(
		environment, source_kind, next_revision)
	if next_environment.is_empty():
		return -1
	_apply_reflection_panorama_override(next_environment)
	next_environment.make_read_only()
	_snapshot_environment = next_environment
	_environment_revision = next_revision
	_environment_source = environment
	_environment_source_id = source_id
	_environment_source_kind = source_kind
	_environment_dirty = false
	_environment_debounce_frames = 0
	_environment_panorama_bytes = int(next_environment.get("bytes", 0))
	# The background radiance is the fog colour, so every environment revision has
	# to reach unmanaged subscribers — including the one taken during start_rt,
	# which happens after a level installs and before any _publish_snapshot pass.
	_mark_fog_dirty()
	return 1


func get_active_rt_backend() -> StringName:
	if _failed:
		return &"none"
	match _active_backend:
		RTBackend.HARDWARE:
			return &"hardware"
		RTBackend.SOFTWARE:
			return &"software"
		_:
			return &"none"


func set_rt_quality(preset: int) -> void:
	rt_quality = preset


func get_rt_quality_scale() -> float:
	return float(RT_QUALITY_SCALES[int(rt_quality)])


func get_rt_quality_name() -> StringName:
	return RT_QUALITY_NAMES[int(rt_quality)]


## The SubViewport the scene is rendered into, or null before the post stack runs.
##
## The root Viewport renders no 3D at all once this manager is active, so callers
## that need the real render target -- renderer visibility statistics, occlusion
## culling, variable rate shading -- have to go through here. Setting any of those
## on the root Viewport or as a project setting is silently a no-op.
func get_scene_viewport() -> SubViewport:
	if _post_stack and _post_stack.has_method("get_scene_viewport"):
		return _post_stack.call("get_scene_viewport")
	return null


func get_ray_render_resolution() -> Vector2i:
	if _post_stack and _post_stack.has_method("get_render_size"):
		var post_size: Variant = _post_stack.call("get_render_size")
		if post_size is Vector2i and post_size.x > 0 and post_size.y > 0:
			return post_size
	var output_size := get_full_render_resolution()
	if output_size.x <= 0 or output_size.y <= 0:
		return Vector2i.ZERO
	var scale := get_rt_quality_scale()
	return Vector2i(
		maxi(2, ceili(float(output_size.x) * scale)),
		maxi(2, ceili(float(output_size.y) * scale)))


func _set_rt_quality_value(preset: int) -> void:
	if preset < RTQualityPreset.NATIVE or preset > RTQualityPreset.PERFORMANCE:
		push_warning("Ignored invalid RT quality preset: %d" % preset)
		return
	if int(_rt_quality_preset) == preset:
		return
	_rt_quality_preset = preset
	# Serialized scene values are applied before the manager enters the tree.
	# Treat the signal as a live-change notification; initial consumers read the
	# exported property directly and configure() receives its current value.
	if is_inside_tree():
		_update_post_settings()
		rt_quality_changed.emit(preset, get_rt_quality_scale())


func _collect_scene() -> bool:
	_snapshot_bridge.publish({})
	_current_snapshot = {}
	_disconnect_mesh_signals()
	_disconnect_texture_signals()
	_disconnect_environment_signals()
	_instances.clear()
	_render_instances.clear()
	_render_instances_revision += 1
	_mesh_records.clear()
	_mesh_sources.clear()
	_material_records.clear()
	_material_sources.clear()
	_material_by_id.clear()
	_instance_material_indices.clear()
	_albedo_atlas = null
	_normal_atlas = null
	_albedo_atlas_size = Vector2i.ONE
	_normal_atlas_size = Vector2i.ONE
	_albedo_region_by_texture_id.clear()
	_normal_region_by_texture_id.clear()
	_texture_atlas_bytes = 0
	_texture_atlas_uploads = 0
	_texture_content_dirty = false
	_snapshot_environment = {}
	_environment_source = null
	_environment_source_id = 0
	_environment_source_kind = &"default_clear"
	_environment_dirty = true
	_environment_debounce_frames = 0
	_environment_panorama_bytes = 0
	# The last published transform array is read-only by contract. Replace all
	# snapshot containers rather than mutating storage retained by a backend.
	var empty_transforms: Array[Transform3D] = []
	_snapshot_transforms = empty_transforms
	_snapshot_instance_masks = PackedInt32Array()
	_snapshot_instance_layers = PackedInt32Array()
	_receiver_light_starts.clear()
	_receiver_light_counts.clear()
	_receiver_light_indices.clear()
	_receiver_light_candidates.clear()
	_receiver_list_rebuilds = 0
	_receiver_candidates_recomputed = 0
	_receiver_light_total = 0
	_receiver_light_maximum = 0
	_light_shading_updates = 0
	_light_influence_updates = 0
	_receiver_rebuilds_skipped = 0
	_receiver_only_instance_count = 0
	_traversable_instance_count = 0
	_placeholder_geometry_active = false
	_light_shadow_states.clear()
	_light_topology_dirty = false
	_topology_dirty = false
	var root := get_node_or_null(geometry_root_path)
	if root == null:
		_fail("RTSceneManager geometry_root_path does not resolve.")
		return false
	if not _validate_environment_contract():
		return false

	var mesh_by_id: Dictionary = {}
	var tracked_mesh_ids: Dictionary = {}
	var connected_mesh_ids: Dictionary = {}
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.push_front(root)
	for node in meshes:
		var mesh_node := node as MeshInstance3D
		if (
				mesh_node == null
				or mesh_node.mesh == null
				or not _is_managed_geometry(mesh_node)
		):
			continue
		if mesh_node.transparency > 0.0:
			_fail("Transparent geometry is outside the opaque RT path: %s" % mesh_node.get_path())
			return false
		var mesh_id := mesh_node.mesh.get_instance_id()
		var receiver_only := _is_receiver_only_geometry(mesh_node)
		if not receiver_only and not tracked_mesh_ids.has(mesh_id):
			tracked_mesh_ids[mesh_id] = true
			_mesh_sources.append(mesh_node.mesh)
		if not receiver_only and not connected_mesh_ids.has(mesh_id):
			connected_mesh_ids[mesh_id] = true
			if not mesh_node.mesh.changed.is_connected(_on_managed_mesh_changed):
				mesh_node.mesh.changed.connect(_on_managed_mesh_changed)

		var surface_count := mesh_node.mesh.get_surface_count()
		if surface_count <= 0:
			_fail("Managed mesh %s has no surfaces." % mesh_node.get_path())
			return false
		var geometry_index := 0
		if receiver_only:
			_receiver_only_instance_count += 1
		else:
			_traversable_instance_count += 1
			if mesh_by_id.has(mesh_id):
				geometry_index = int(mesh_by_id[mesh_id])
			else:
				geometry_index = _extract_mesh(mesh_node.mesh)
				if geometry_index < 0:
					return false
				mesh_by_id[mesh_id] = geometry_index
		var local_aabb := mesh_node.mesh.get_aabb()
		var bounds_min := local_aabb.position
		var bounds_max := local_aabb.position + local_aabb.size
		var material_base := _instance_material_indices.size()
		var active_material_ids := PackedInt64Array()
		for surface in surface_count:
			var material := mesh_node.get_active_material(surface)
			var material_index := _extract_material(material)
			if material_index < 0:
				_fail("Unsupported material on %s surface %d." % [mesh_node.get_path(), surface])
				return false
			if (
					not receiver_only
					and bool(_material_records[material_index].get("vertex_color_enabled", false))
			):
				_fail(
					(
						"%s surface %d enables vertex_color_enabled, but ray-visible managed geometry "
						+ "cannot reproduce vertex colors at secondary hits. Put this mesh in '%s' "
						+ "for receiver-only primary shading, or disable vertex colors."
					) % [mesh_node.get_path(), surface, receiver_only_geometry_group])
				return false
			_instance_material_indices.append(material_index)
			active_material_ids.append(material.get_instance_id())
		_instances.append({
			"node": mesh_node,
			"geometry": geometry_index,
			"mesh_id": mesh_id,
			"surface_count": surface_count,
			"material_ids": active_material_ids,
			"receiver_only": receiver_only,
		})
		_render_instances.append({
			"geometry": geometry_index,
			"material_base": material_base,
			"surface_count": surface_count,
			"path": String(mesh_node.get_path()),
			"bounds_min": bounds_min,
			"bounds_max": bounds_max,
			"receiver_only": receiver_only,
		})

	if _instances.is_empty():
		_fail(
			"No managed MeshInstance3D geometry was found beneath geometry_root_path. "
			+ "Add nodes to '%s', or clear managed_geometry_group for legacy scan-all behavior."
			% managed_geometry_group)
		return false
	# Both render backends require at least one valid geometry/BLAS record even
	# when every authored managed node is receiver-only. A tiny internal triangle
	# satisfies that storage contract; every receiver-only instance still carries
	# mask zero, so neither it nor this placeholder can contribute a ray hit.
	if _mesh_records.is_empty():
		_append_placeholder_mesh_record()
	if _instances.size() > MAX_SUPPORTED_INSTANCES:
		_fail("The RT path supports at most %d MeshInstance3D instances." % MAX_SUPPORTED_INSTANCES)
		return false
	if _material_records.size() > MAX_SUPPORTED_MATERIALS:
		_fail("The RT path supports at most %d distinct managed materials." % MAX_SUPPORTED_MATERIALS)
		return false
	if not _build_texture_atlases():
		return false
	if not _validate_surface_mappings(_material_records):
		return false
	_discover_lights(false)
	_snapshot_light = _make_light_snapshot()
	if _refresh_environment_snapshot(true) < 0:
		return false
	_snapshot_bias = ray_origin_bias
	_snapshot_max_distance = ray_max_distance
	_snapshot_max_lights = max_scene_lights
	_snapshot_profiling_enabled = profiling_enabled
	_snapshot_fog = _effective_fog_params()
	_topology_revision += 1
	return not _failed


func _append_placeholder_mesh_record() -> void:
	var positions := PackedVector4Array([
		Vector4(-0.0005, -0.0005, 0.0, 1.0),
		Vector4(0.0005, -0.0005, 0.0, 1.0),
		Vector4(0.0, 0.0005, 0.0, 1.0),
	])
	var normals := PackedVector4Array([
		Vector4(0.0, 0.0, 1.0, 0.0),
		Vector4(0.0, 0.0, 1.0, 0.0),
		Vector4(0.0, 0.0, 1.0, 0.0),
	])
	var uvs := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var indices := PackedInt32Array([0, 1, 2])
	_mesh_records.append({
		"positions": positions.to_byte_array(),
		"normals": normals.to_byte_array(),
		"uvs": uvs.to_byte_array(),
		"indices": indices.to_byte_array(),
		"triangle_surfaces": PackedInt32Array([0]),
		"surface_has_uv": PackedInt32Array([0]),
		"vertex_count": 3,
		"index_count": 3,
		"surface_count": 1,
		"bounds_min": Vector3(-0.0005, -0.0005, 0.0),
		"bounds_max": Vector3(0.0005, 0.0005, 0.0),
	})
	_placeholder_geometry_active = true


func _register_receiver_only_node(mesh_node: MeshInstance3D) -> void:
	if (
			not _manager_active
			or _failed
			or not is_instance_valid(mesh_node)
			or not mesh_node.is_inside_tree()
			or not _is_under_geometry_root(mesh_node)
			or not _is_receiver_only_geometry(mesh_node)
	):
		return
	for item in _instances:
		if _managed_mesh_node(item) == mesh_node:
			return
	if mesh_node.mesh == null or mesh_node.mesh.get_surface_count() <= 0:
		_fail("Receiver-only geometry has no mesh surfaces: %s" % mesh_node.get_path())
		return
	if mesh_node.transparency > 0.0:
		_fail("Transparent geometry is outside the opaque RT path: %s" % mesh_node.get_path())
		return
	var surface_count := mesh_node.mesh.get_surface_count()
	var instance_index := -1
	# Prefer a tombstone whose existing mapping span can be overwritten in place;
	# this bounds both stable instance slots and the surface-binding table during
	# ordinary same-topology terrain streaming.
	for candidate_index in _instances.size():
		if not bool(_instances[candidate_index].get("receiver_tombstone", false)):
			continue
		if int(_render_instances[candidate_index].get("surface_count", 0)) >= surface_count:
			instance_index = candidate_index
			break
		if instance_index < 0:
			instance_index = candidate_index
	if instance_index < 0 and _instances.size() >= MAX_SUPPORTED_INSTANCES:
		_fail("The RT path supports at most %d stable instance slots." % MAX_SUPPORTED_INSTANCES)
		return

	# Keep prior render-thread snapshots immutable while this registry appends or
	# reuses a primary receiver slot and its surface bindings.
	_render_instances = _render_instances.duplicate(true)
	_render_instances_revision += 1
	_instance_material_indices = _instance_material_indices.duplicate()
	var surface_material_indices := PackedInt32Array()
	var active_material_ids := PackedInt64Array()
	var material_count_before := _material_records.size()
	for surface in surface_count:
		var material := mesh_node.get_active_material(surface) as ShaderMaterial
		if material == null:
			_fail("Unsupported material on %s surface %d." % [mesh_node.get_path(), surface])
			return
		var material_error := _incremental_receiver_material_error(material)
		if not material_error.is_empty():
			_fail("%s surface %d cannot join the receiver-only registry: %s" % [
				mesh_node.get_path(), surface, material_error])
			return
		if not _material_by_id.has(material.get_instance_id()):
			_material_records = _material_records.duplicate(true)
			_material_sources = _material_sources.duplicate()
		var material_index := _extract_material(material)
		if material_index < 0:
			_fail("Unsupported material on %s surface %d." % [mesh_node.get_path(), surface])
			return
		surface_material_indices.append(material_index)
		active_material_ids.append(material.get_instance_id())
	if _material_records.size() > MAX_SUPPORTED_MATERIALS:
		_fail("The RT path supports at most %d distinct managed materials." % MAX_SUPPORTED_MATERIALS)
		return

	var material_base := _instance_material_indices.size()
	if instance_index >= 0:
		var old_render_record: Dictionary = _render_instances[instance_index]
		var old_material_base := int(old_render_record.get("material_base", -1))
		var old_surface_count := int(old_render_record.get("surface_count", 0))
		if (
				old_material_base >= 0
				and old_surface_count >= surface_count
				and old_material_base + old_surface_count <= _instance_material_indices.size()
		):
			material_base = old_material_base
			for surface in old_surface_count:
				_instance_material_indices[material_base + surface] = 0
			for surface in surface_count:
				_instance_material_indices[material_base + surface] = surface_material_indices[surface]
		else:
			_instance_material_indices.append_array(surface_material_indices)
	else:
		_instance_material_indices.append_array(surface_material_indices)

	var mesh_id := mesh_node.mesh.get_instance_id()
	var local_aabb := mesh_node.mesh.get_aabb()
	var instance_record := {
		"node": mesh_node,
		"geometry": 0,
		"mesh_id": mesh_id,
		"surface_count": surface_count,
		"material_ids": active_material_ids,
		"receiver_only": true,
	}
	var render_record := {
		"geometry": 0,
		"material_base": material_base,
		"surface_count": surface_count,
		"path": String(mesh_node.get_path()),
		"bounds_min": local_aabb.position,
		"bounds_max": local_aabb.position + local_aabb.size,
		"receiver_only": true,
	}
	var reusing_slot := instance_index >= 0
	if reusing_slot:
		_instances[instance_index] = instance_record
		_render_instances[instance_index] = render_record
	else:
		instance_index = _instances.size()
		_instances.append(instance_record)
		_render_instances.append(render_record)

	var next_transforms: Array[Transform3D] = _snapshot_transforms.duplicate()
	if reusing_slot:
		next_transforms[instance_index] = mesh_node.global_transform
	else:
		next_transforms.append(mesh_node.global_transform)
	next_transforms.make_read_only()
	_snapshot_transforms = next_transforms
	_snapshot_instance_masks = _snapshot_instance_masks.duplicate()
	_snapshot_instance_layers = _snapshot_instance_layers.duplicate()
	if reusing_slot:
		_snapshot_instance_masks[instance_index] = 0
		_snapshot_instance_layers[instance_index] = mesh_node.layers
	else:
		_snapshot_instance_masks.append(0)
		_snapshot_instance_layers.append(mesh_node.layers)
	if not _rebuild_incremental_receiver_light_lists(instance_index):
		return

	_receiver_only_instance_count += 1
	_receiver_only_registrations += 1
	_snapshot_revision += 1
	_instance_revision += 1
	_receiver_light_revision += 1
	# This revision also owns the per-instance surface-to-material mapping.
	_material_revision += 1
	if _material_records.size() != material_count_before:
		for material_index in range(material_count_before, _material_records.size()):
			_apply_material_renderer_override(material_index)
	_commit_current_snapshot()
	_apply_instance_renderer_override(
		mesh_node, instance_index, true, _active_backend == RTBackend.HARDWARE)
	if _software_tracer:
		var sync_error: String = _software_tracer.sync_receiver_instances(
			_current_snapshot, _material_sources, _instances)
		if not sync_error.is_empty():
			_fail(sync_error)


func _unregister_receiver_only_instance(instance_index: int) -> void:
	if (
			instance_index < 0
			or instance_index >= _instances.size()
			or not bool(_instances[instance_index].get("receiver_only", false))
			or bool(_instances[instance_index].get("receiver_tombstone", false))
	):
		return
	var item := _instances[instance_index].duplicate(true)
	item["node"] = null
	item["receiver_tombstone"] = true
	_instances[instance_index] = item
	_render_instances = _render_instances.duplicate(true)
	_render_instances_revision += 1
	var render_record := _render_instances[instance_index].duplicate(true)
	render_record["receiver_tombstone"] = true
	_render_instances[instance_index] = render_record
	_snapshot_instance_masks = _snapshot_instance_masks.duplicate()
	_snapshot_instance_masks[instance_index] = 0
	_snapshot_instance_layers = _snapshot_instance_layers.duplicate()
	_snapshot_instance_layers[instance_index] = 0
	if not _rebuild_incremental_receiver_light_lists(instance_index):
		return

	_receiver_only_instance_count = maxi(0, _receiver_only_instance_count - 1)
	_receiver_only_unregistrations += 1
	_snapshot_revision += 1
	_instance_revision += 1
	_receiver_light_revision += 1
	_commit_current_snapshot()
	if _software_tracer:
		var sync_error: String = _software_tracer.sync_receiver_instances(
			_current_snapshot, _material_sources, _instances)
		if not sync_error.is_empty():
			_fail(sync_error)


func _incremental_receiver_material_error(material: ShaderMaterial) -> String:
	if material.shader != BLINN_PHONG_SHADER:
		return "the exact Retro RT BlinnPhong shader is required"
	for entry in [
		[&"albedo_texture", _albedo_region_by_texture_id],
		[&"normal_texture", _normal_region_by_texture_id],
	]:
		var texture: Variant = material.get_shader_parameter(entry[0])
		if texture is Texture2D:
			var regions := entry[1] as Dictionary
			if not regions.has((texture as Texture2D).get_instance_id()):
				return (
					"its %s was not present when the static RT texture atlas was built; "
					+ "pre-register that texture or use an untextured/previously-atlased material"
				) % entry[0]
	return ""


func _rebuild_incremental_receiver_light_lists(dirty_index: int) -> bool:
	var dirty := PackedInt32Array([dirty_index])
	var result := _build_receiver_light_lists(
		_snapshot_transforms,
		_snapshot_instance_layers,
		_snapshot_light,
		dirty,
		_receiver_light_candidates.size() != _instances.size())
	var error := String(result.get("error", ""))
	if not error.is_empty():
		_fail(error)
		return false
	_receiver_light_starts = result["starts"]
	_receiver_light_counts = result["counts"]
	_receiver_light_indices = result["indices"]
	_receiver_light_candidates = result["candidates"]
	return true


func _extract_mesh(mesh: Mesh) -> int:
	if mesh.get_surface_count() == 0:
		_fail("Mesh %s has no surfaces." % mesh.resource_name)
		return -1
	# PrimitiveMesh does not expose ArrayMesh's blend-shape API in 4.7.1.
	# Imported meshes do, so only query it after narrowing the resource type.
	if mesh is ArrayMesh and (mesh as ArrayMesh).get_blend_shape_count() > 0:
		_fail("Blend-shaped meshes require deforming BLAS support and are outside the rigid RT path: %s" % mesh.resource_name)
		return -1
	var positions4 := PackedVector4Array()
	var normals4 := PackedVector4Array()
	var uvs2 := PackedVector2Array()
	var combined_indices := PackedInt32Array()
	var triangle_surfaces := PackedInt32Array()
	var surface_has_uv := PackedInt32Array()
	var vertex_base := 0
	var mesh_bounds_min := Vector3(INF, INF, INF)
	var mesh_bounds_max := Vector3(-INF, -INF, -INF)
	for surface in mesh.get_surface_count():
		# PrimitiveMesh resources are always exposed as triangle surfaces but do
		# not implement ArrayMesh.surface_get_primitive_type() in Godot 4.7.1.
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			_fail("Only triangle surfaces are supported by RT: %s surface %d" % [mesh.resource_name, surface])
			return -1
		var arrays := mesh.surface_get_arrays(surface)
		var vertices := PackedVector3Array()
		if arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			vertices = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			_fail("Mesh %s surface %d has no CPU-readable vertices." % [mesh.resource_name, surface])
			return -1
		var indices := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
			indices = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			if vertices.size() % 3 != 0:
				_fail("Non-indexed mesh %s surface %d is not a triangle list." % [mesh.resource_name, surface])
				return -1
			indices.resize(vertices.size())
			for i in vertices.size():
				indices[i] = i
		if indices.size() % 3 != 0:
			_fail("Mesh %s surface %d has an incomplete triangle." % [mesh.resource_name, surface])
			return -1
		for index in indices:
			if index < 0 or index >= vertices.size():
				_fail("Mesh %s surface %d contains an out-of-range index." % [mesh.resource_name, surface])
				return -1

		var normals := PackedVector3Array()
		if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			normals = arrays[Mesh.ARRAY_NORMAL]
		if normals.size() != vertices.size():
			normals = _generate_normals(vertices, indices)
		var surface_uvs := PackedVector2Array()
		if arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
			surface_uvs = arrays[Mesh.ARRAY_TEX_UV]
		var has_complete_uvs := surface_uvs.size() == vertices.size()
		surface_has_uv.append(1 if has_complete_uvs else 0)
		for i in vertices.size():
			mesh_bounds_min = Vector3(
				minf(mesh_bounds_min.x, vertices[i].x),
				minf(mesh_bounds_min.y, vertices[i].y),
				minf(mesh_bounds_min.z, vertices[i].z))
			mesh_bounds_max = Vector3(
				maxf(mesh_bounds_max.x, vertices[i].x),
				maxf(mesh_bounds_max.y, vertices[i].y),
				maxf(mesh_bounds_max.z, vertices[i].z))
			positions4.append(Vector4(vertices[i].x, vertices[i].y, vertices[i].z, 1.0))
			normals4.append(Vector4(normals[i].x, normals[i].y, normals[i].z, 0.0))
			uvs2.append(surface_uvs[i] if has_complete_uvs else Vector2.ZERO)
		for index in indices:
			combined_indices.append(vertex_base + index)
		for triangle in range(0, indices.size(), 3):
			triangle_surfaces.append(surface)
		vertex_base += vertices.size()

	_mesh_records.append({
		"positions": positions4.to_byte_array(),
		"normals": normals4.to_byte_array(),
		"uvs": uvs2.to_byte_array(),
		"indices": combined_indices.to_byte_array(),
		"triangle_surfaces": triangle_surfaces,
		"surface_has_uv": surface_has_uv,
		"vertex_count": positions4.size(),
		"index_count": combined_indices.size(),
		"surface_count": mesh.get_surface_count(),
		"bounds_min": mesh_bounds_min,
		"bounds_max": mesh_bounds_max,
	})
	return _mesh_records.size() - 1


func _generate_normals(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for triangle in range(0, indices.size(), 3):
		var i0 := indices[triangle]
		var i1 := indices[triangle + 1]
		var i2 := indices[triangle + 2]
		var face := (vertices[i1] - vertices[i0]).cross(vertices[i2] - vertices[i0])
		normals[i0] = normals[i0] + face
		normals[i1] = normals[i1] + face
		normals[i2] = normals[i2] + face
	for i in normals.size():
		normals[i] = normals[i].normalized() if normals[i].length_squared() > 0.00000001 else Vector3.UP
	return normals


func _extract_material(material: Material) -> int:
	if not material is ShaderMaterial:
		return -1
	var shader_material := material as ShaderMaterial
	var material_id := shader_material.get_instance_id()
	if _material_by_id.has(material_id):
		return int(_material_by_id[material_id])
	var record := _make_material_record(shader_material)
	if record.is_empty():
		return -1
	var index := _material_records.size()
	_material_by_id[material_id] = index
	_material_sources.append(shader_material)
	_material_records.append(record)
	return index


func _make_material_record(material: ShaderMaterial) -> Dictionary:
	if material.shader != BLINN_PHONG_SHADER:
		return {}
	var diffuse_value = material.get_shader_parameter("diffuse_color")
	var ambient_value = material.get_shader_parameter("ambient_light")
	var emission_value = material.get_shader_parameter("emission_color")
	var specular_value = material.get_shader_parameter("specular_color")
	var shininess_value = material.get_shader_parameter("shininess")
	var direct_intensity_value = material.get_shader_parameter("direct_specular_intensity")
	var mirror_value = material.get_shader_parameter("mirror_enabled")
	var reflection_strength_value = material.get_shader_parameter("reflection_strength")
	var reflection_shadows_value = material.get_shader_parameter("reflection_shadows_enabled")
	var albedo_value = material.get_shader_parameter("albedo_texture")
	var normal_value = material.get_shader_parameter("normal_texture")
	var vertex_color_value = material.get_shader_parameter("vertex_color_enabled")
	var triplanar_value = material.get_shader_parameter("triplanar_enabled")
	var triplanar_world_value = material.get_shader_parameter("triplanar_world_space")
	var triplanar_scale_value = material.get_shader_parameter("triplanar_scale")
	var triplanar_offset_value = material.get_shader_parameter("triplanar_offset")
	var triplanar_sharpness_value = material.get_shader_parameter("triplanar_sharpness")
	# ShaderMaterial only serializes authored overrides, so any parameter left at
	# its shader default can report NIL. Substitute the declaration defaults after
	# verifying the exact authored shader above; this also preserves old scenes.
	if diffuse_value == null:
		diffuse_value = Color(0.25, 0.5, 0.2, 1.0)
	if ambient_value == null:
		ambient_value = Color(0.1, 0.1, 0.1, 1.0)
	if emission_value == null:
		emission_value = Color(0.0, 0.0, 0.0, 1.0)
	if specular_value == null:
		specular_value = Color.WHITE
	if shininess_value == null:
		shininess_value = 40.0
	if direct_intensity_value == null:
		direct_intensity_value = 1.0
	if mirror_value == null:
		mirror_value = false
	if reflection_strength_value == null:
		reflection_strength_value = 1.0
	if reflection_shadows_value == null:
		reflection_shadows_value = false
	if vertex_color_value == null:
		vertex_color_value = false
	if triplanar_value == null:
		triplanar_value = false
	if triplanar_world_value == null:
		triplanar_world_value = false
	if triplanar_scale_value == null:
		triplanar_scale_value = Vector3.ONE
	if triplanar_offset_value == null:
		triplanar_offset_value = Vector3.ZERO
	if triplanar_sharpness_value == null:
		triplanar_sharpness_value = 1.0
	if not diffuse_value is Color or not ambient_value is Color or not emission_value is Color or not specular_value is Color:
		return {}
	if not _is_numeric(shininess_value) or not _is_numeric(direct_intensity_value):
		return {}
	if not mirror_value is bool or not _is_numeric(reflection_strength_value):
		return {}
	if not reflection_shadows_value is bool:
		return {}
	if albedo_value != null and not albedo_value is Texture2D:
		return {}
	if normal_value != null and not normal_value is Texture2D:
		return {}
	if not vertex_color_value is bool:
		return {}
	if not triplanar_value is bool or not triplanar_world_value is bool:
		return {}
	if not triplanar_scale_value is Vector3 or not triplanar_offset_value is Vector3:
		return {}
	if not _is_numeric(triplanar_sharpness_value):
		return {}
	var albedo_texture_id := (albedo_value as Texture2D).get_instance_id() if albedo_value is Texture2D else 0
	var normal_texture_id := (normal_value as Texture2D).get_instance_id() if normal_value is Texture2D else 0
	var albedo_region: Vector4 = _albedo_region_by_texture_id.get(albedo_texture_id, Vector4.ZERO)
	var normal_region: Vector4 = _normal_region_by_texture_id.get(normal_texture_id, Vector4.ZERO)
	# The shared scene contract is renderer-independent linear radiance. Primary
	# software materials receive these values through unhinted uniforms; terminal
	# hits and hardware buffers consume the same records directly.
	var diffuse_rt := (diffuse_value as Color).srgb_to_linear()
	var ambient_rt := (ambient_value as Color).srgb_to_linear()
	var emission_rt := (emission_value as Color).srgb_to_linear()
	var specular_rt := (specular_value as Color).srgb_to_linear()
	# Mirror enable/strength are encoded by the raster pass in the
	# normal/roughness target. Reflection changes therefore do not dirty the GPU
	# material table used to shade a terminal reflection hit.
	return {
		"diffuse": diffuse_rt,
		"ambient": ambient_rt,
		"emission": emission_rt,
		"specular": specular_rt,
		# The authored sRGB values are retained purely so the per-frame change
		# check can compare what the material actually holds, without paying for
		# the twelve pow() calls the linear conversion above costs.
		"diffuse_srgb": diffuse_value as Color,
		"ambient_srgb": ambient_value as Color,
		"emission_srgb": emission_value as Color,
		"specular_srgb": specular_value as Color,
		"shininess": float(shininess_value),
		"direct_intensity": float(direct_intensity_value),
		"reflection_shadows_enabled": bool(reflection_shadows_value),
		"has_albedo": albedo_texture_id != 0,
		"has_normal": normal_texture_id != 0,
		"albedo_texture_id": albedo_texture_id,
		"normal_texture_id": normal_texture_id,
		"albedo_region": albedo_region,
		"normal_region": normal_region,
		"vertex_color_enabled": bool(vertex_color_value),
		"triplanar_enabled": bool(triplanar_value),
		"triplanar_world_space": bool(triplanar_world_value),
		"triplanar_scale": triplanar_scale_value as Vector3,
		"triplanar_offset": triplanar_offset_value as Vector3,
		"triplanar_sharpness": clampf(float(triplanar_sharpness_value), 0.0, 150.0),
	}


## Classifies a managed material against its published record, per frame, for
## every managed material.
##
## Returns -2 when an atlased texture was swapped, -1 when the material no longer
## presents the RT BlinnPhong interface, 0 when a tracked value changed and 1 when
## nothing did. Contract unchanged from when this delegated to
## [method _make_material_record].
##
## Nothing is allocated on the unchanged path. This used to build a whole record
## -- a twenty-key dictionary and four sRGB conversions -- purely to discover
## that every field still matched, then throw it away. The values are read and
## compared in place instead, bailing on the first difference; the caller still
## rebuilds through [method _make_material_record] when this reports 0.
func _compare_material_record(material: ShaderMaterial, record: Dictionary) -> int:
	# Same gate _make_material_record opens with, and the cheapest check here.
	if material.shader != BLINN_PHONG_SHADER:
		return -1
	# Texture identity next: a swap here is unrecoverable (the atlases are
	# static), so it outranks every other difference.
	var albedo_value = material.get_shader_parameter("albedo_texture")
	var normal_value = material.get_shader_parameter("normal_texture")
	if albedo_value != null and not albedo_value is Texture2D:
		return -1
	if normal_value != null and not normal_value is Texture2D:
		return -1
	var albedo_texture_id := (albedo_value as Texture2D).get_instance_id() if albedo_value is Texture2D else 0
	var normal_texture_id := (normal_value as Texture2D).get_instance_id() if normal_value is Texture2D else 0
	if albedo_texture_id != int(record["albedo_texture_id"]):
		return -2
	if normal_texture_id != int(record["normal_texture_id"]):
		return -2

	# Scalars and flags before colours: they discriminate just as well and cost
	# nothing to compare.
	var shininess_value = material.get_shader_parameter("shininess")
	if shininess_value == null:
		shininess_value = 40.0
	elif not _is_numeric(shininess_value):
		return -1
	if float(shininess_value) != float(record["shininess"]):
		return 0

	var direct_intensity_value = material.get_shader_parameter("direct_specular_intensity")
	if direct_intensity_value == null:
		direct_intensity_value = 1.0
	elif not _is_numeric(direct_intensity_value):
		return -1
	if float(direct_intensity_value) != float(record["direct_intensity"]):
		return 0

	var reflection_shadows_value = material.get_shader_parameter("reflection_shadows_enabled")
	if reflection_shadows_value == null:
		reflection_shadows_value = false
	elif not reflection_shadows_value is bool:
		return -1
	if bool(reflection_shadows_value) != bool(record["reflection_shadows_enabled"]):
		return 0

	var vertex_color_value = material.get_shader_parameter("vertex_color_enabled")
	if vertex_color_value == null:
		vertex_color_value = false
	elif not vertex_color_value is bool:
		return -1
	if bool(vertex_color_value) != bool(record["vertex_color_enabled"]):
		return 0

	var triplanar_value = material.get_shader_parameter("triplanar_enabled")
	if triplanar_value == null:
		triplanar_value = false
	elif not triplanar_value is bool:
		return -1
	if bool(triplanar_value) != bool(record["triplanar_enabled"]):
		return 0

	var triplanar_world_value = material.get_shader_parameter("triplanar_world_space")
	if triplanar_world_value == null:
		triplanar_world_value = false
	elif not triplanar_world_value is bool:
		return -1
	if bool(triplanar_world_value) != bool(record["triplanar_world_space"]):
		return 0

	var triplanar_scale_value = material.get_shader_parameter("triplanar_scale")
	if triplanar_scale_value == null:
		triplanar_scale_value = Vector3.ONE
	elif not triplanar_scale_value is Vector3:
		return -1
	if (triplanar_scale_value as Vector3) != (record["triplanar_scale"] as Vector3):
		return 0

	var triplanar_offset_value = material.get_shader_parameter("triplanar_offset")
	if triplanar_offset_value == null:
		triplanar_offset_value = Vector3.ZERO
	elif not triplanar_offset_value is Vector3:
		return -1
	if (triplanar_offset_value as Vector3) != (record["triplanar_offset"] as Vector3):
		return 0

	var triplanar_sharpness_value = material.get_shader_parameter("triplanar_sharpness")
	if triplanar_sharpness_value == null:
		triplanar_sharpness_value = 1.0
	elif not _is_numeric(triplanar_sharpness_value):
		return -1
	if clampf(float(triplanar_sharpness_value), 0.0, 150.0) != float(record["triplanar_sharpness"]):
		return 0

	# Colours last, compared as authored. The record carries the sRGB values
	# alongside the linear ones precisely so this stays a plain equality.
	var diffuse_value = material.get_shader_parameter("diffuse_color")
	if diffuse_value == null:
		diffuse_value = Color(0.25, 0.5, 0.2, 1.0)
	elif not diffuse_value is Color:
		return -1
	if (diffuse_value as Color) != (record["diffuse_srgb"] as Color):
		return 0

	var ambient_value = material.get_shader_parameter("ambient_light")
	if ambient_value == null:
		ambient_value = Color(0.1, 0.1, 0.1, 1.0)
	elif not ambient_value is Color:
		return -1
	if (ambient_value as Color) != (record["ambient_srgb"] as Color):
		return 0

	var emission_value = material.get_shader_parameter("emission_color")
	if emission_value == null:
		emission_value = Color(0.0, 0.0, 0.0, 1.0)
	elif not emission_value is Color:
		return -1
	if (emission_value as Color) != (record["emission_srgb"] as Color):
		return 0

	var specular_value = material.get_shader_parameter("specular_color")
	if specular_value == null:
		specular_value = Color.WHITE
	elif not specular_value is Color:
		return -1
	if (specular_value as Color) != (record["specular_srgb"] as Color):
		return 0

	# Mirror enable and strength are not tracked fields -- the raster pass encodes
	# them, so changing one never dirties the GPU material table -- but
	# _make_material_record rejects a material whose types have drifted, and a
	# script can assign any Variant to a uniform. Checked, not compared.
	var mirror_value = material.get_shader_parameter("mirror_enabled")
	if mirror_value != null and not mirror_value is bool:
		return -1
	var reflection_strength_value = material.get_shader_parameter("reflection_strength")
	if reflection_strength_value != null and not _is_numeric(reflection_strength_value):
		return -1
	return 1


func _is_numeric(value: Variant) -> bool:
	var value_type := typeof(value)
	return value_type == TYPE_FLOAT or value_type == TYPE_INT


func _build_texture_atlases() -> bool:
	var albedo_result := _build_texture_atlas(&"albedo_texture", "albedo")
	if albedo_result.is_empty():
		return false
	var normal_result := _build_texture_atlas(&"normal_texture", "normal")
	if normal_result.is_empty():
		return false

	_albedo_atlas = albedo_result["texture"] as ImageTexture
	_normal_atlas = normal_result["texture"] as ImageTexture
	_albedo_atlas_size = albedo_result["size"] as Vector2i
	_normal_atlas_size = normal_result["size"] as Vector2i
	_albedo_region_by_texture_id = albedo_result["regions"] as Dictionary
	_normal_region_by_texture_id = normal_result["regions"] as Dictionary
	_texture_atlas_bytes = int(albedo_result["bytes"]) + int(normal_result["bytes"])
	# Both atlases have a valid one-pixel fallback even when no material uses a
	# map, keeping hardware and Compatibility bindings structurally stable.
	_texture_atlas_uploads = 2

	for i in _material_records.size():
		var record := _material_records[i]
		var albedo_id := int(record["albedo_texture_id"])
		var normal_id := int(record["normal_texture_id"])
		record["albedo_region"] = _albedo_region_by_texture_id.get(albedo_id, Vector4.ZERO)
		record["normal_region"] = _normal_region_by_texture_id.get(normal_id, Vector4.ZERO)

	var registered: Dictionary = {}
	for material in _material_sources:
		for parameter in [&"albedo_texture", &"normal_texture"]:
			var value = material.get_shader_parameter(parameter)
			if not value is Texture2D:
				continue
			var texture := value as Texture2D
			var texture_id := texture.get_instance_id()
			if registered.has(texture_id):
				continue
			registered[texture_id] = true
			_managed_texture_sources.append(texture)
			texture.changed.connect(_on_managed_texture_changed)
	return true


func _build_texture_atlas(parameter: StringName, semantic: String) -> Dictionary:
	var entries: Array[Dictionary] = []
	var seen: Dictionary = {}
	for material_index in _material_sources.size():
		var material := _material_sources[material_index]
		var value = material.get_shader_parameter(parameter)
		if not value is Texture2D:
			continue
		var texture := value as Texture2D
		var texture_id := texture.get_instance_id()
		var context := _texture_context(texture, material, material_index, semantic)
		var unsupported_reason := _unsupported_texture_reason(texture)
		if not unsupported_reason.is_empty():
			_fail("Cannot atlas %s: %s" % [context, unsupported_reason])
			return {}
		if seen.has(texture_id):
			continue
		seen[texture_id] = true
		var source_image := texture.get_image()
		if source_image == null or source_image.is_empty():
			_fail("Cannot read %s for the RT texture atlas. Texture2D.get_image() returned no pixel data; use an imported/readable Texture2D and reload the scene." % context)
			return {}
		var image := source_image.duplicate() as Image
		if image.is_compressed():
			var decompress_error := image.decompress()
			if decompress_error != OK:
				_fail("Cannot decompress %s for the RT texture atlas (error %d)." % [context, decompress_error])
				return {}
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		var image_size := image.get_size()
		if image_size.x <= 0 or image_size.y <= 0:
			_fail("%s has an empty image." % context)
			return {}
		if image_size.x > MAP_ATLAS_MAX_SIZE or image_size.y > MAP_ATLAS_MAX_SIZE:
			_fail("%s is %dx%d, exceeding the %dx%d RT atlas limit." % [context, image_size.x, image_size.y, MAP_ATLAS_MAX_SIZE, MAP_ATLAS_MAX_SIZE])
			return {}
		entries.append({
			"id": texture_id,
			"image": image,
			"context": context,
			"size": image_size,
		})

	# Tallest-first shelf packing is deterministic and avoids the worst row
	# fragmentation while preserving tightly packed, gutter-free pixel regions.
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_size := a["size"] as Vector2i
		var b_size := b["size"] as Vector2i
		if a_size.y != b_size.y:
			return a_size.y > b_size.y
		if a_size.x != b_size.x:
			return a_size.x > b_size.x
		return int(a["id"]) < int(b["id"])
	)
	var cursor_x := 0
	var cursor_y := 0
	var row_height := 0
	var used_width := 1
	var used_height := 1
	var regions: Dictionary = {}
	for entry in entries:
		var image_size := entry["size"] as Vector2i
		if cursor_x > 0 and cursor_x + image_size.x > MAP_ATLAS_MAX_SIZE:
			cursor_y += row_height
			cursor_x = 0
			row_height = 0
		if cursor_y + image_size.y > MAP_ATLAS_MAX_SIZE:
			_fail("Packing failed at %s: the %s atlas exceeds %dx%d. Reduce texture sizes/count or split the scene." % [entry["context"], semantic, MAP_ATLAS_MAX_SIZE, MAP_ATLAS_MAX_SIZE])
			return {}
		var region := Vector4(cursor_x, cursor_y, image_size.x, image_size.y)
		entry["origin"] = Vector2i(cursor_x, cursor_y)
		regions[int(entry["id"])] = region
		cursor_x += image_size.x
		row_height = maxi(row_height, image_size.y)
		used_width = maxi(used_width, cursor_x)
		used_height = maxi(used_height, cursor_y + row_height)

	var atlas_image := Image.create_empty(used_width, used_height, false, Image.FORMAT_RGBA8)
	atlas_image.fill(Color(0.5, 0.5, 1.0, 1.0) if semantic == "normal" else Color.WHITE)
	for entry in entries:
		var image := entry["image"] as Image
		atlas_image.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), entry["origin"] as Vector2i)
	var atlas_texture := ImageTexture.create_from_image(atlas_image)
	if atlas_texture == null:
		_fail("Failed to create the %s RT texture atlas (%dx%d)." % [semantic, used_width, used_height])
		return {}
	return {
		"texture": atlas_texture,
		"size": Vector2i(used_width, used_height),
		"regions": regions,
		"bytes": used_width * used_height * 4,
	}


func _texture_context(texture: Texture2D, material: ShaderMaterial, material_index: int, semantic: String) -> String:
	var texture_name := texture.resource_path
	if texture_name.is_empty():
		texture_name = texture.resource_name
	if texture_name.is_empty():
		texture_name = "Texture2D#%d" % texture.get_instance_id()
	var material_name := material.resource_path
	if material_name.is_empty():
		material_name = material.resource_name
	if material_name.is_empty():
		material_name = "material %d" % material_index
	return "%s texture '%s' used by %s" % [semantic, texture_name, material_name]


func _unsupported_texture_reason(texture: Texture2D) -> String:
	# Composite/dynamic resources either expose pixels that differ from what a
	# spatial sampler sees (AtlasTexture) or can change without a stable static
	# image/content signal. The RT map atlases intentionally accept static pixel
	# textures only; imported CompressedTexture2D and ImageTexture are supported.
	if texture is AtlasTexture:
		return "AtlasTexture regions do not match direct spatial-shader sampling; use the cropped image as its own static texture."
	if texture is AnimatedTexture:
		return "AnimatedTexture changes frames after the static RT atlas is built."
	if texture is ViewportTexture:
		return "ViewportTexture is dynamic and has no static RT-atlas representation."
	if texture.get_script() != null:
		return "scripted Texture2D resources do not provide the required static-pixel contract."
	return ""


func _validate_surface_mappings(records: Array[Dictionary]) -> bool:
	for instance_index in _render_instances.size():
		var render_instance := _render_instances[instance_index]
		if bool(render_instance.get("receiver_tombstone", false)):
			continue
		var geometry_index := int(render_instance["geometry"])
		var material_base := int(render_instance["material_base"])
		var receiver_only := bool(render_instance.get("receiver_only", false))
		var surface_has_uv := PackedInt32Array()
		if not receiver_only:
			var mesh_record := _mesh_records[geometry_index]
			surface_has_uv = mesh_record["surface_has_uv"]
		for surface in int(render_instance["surface_count"]):
			var material_index := _instance_material_indices[material_base + surface]
			var record := records[material_index]
			if not receiver_only and bool(record.get("vertex_color_enabled", false)):
				_fail((
					"%s surface %d enables vertex_color_enabled, but ray-visible managed geometry "
					+ "cannot reproduce vertex colors at secondary hits. Put this mesh in '%s' "
					+ "for receiver-only primary shading, or disable vertex colors."
				) % [render_instance["path"], surface, receiver_only_geometry_group])
				return false
			var mapped := bool(record["has_albedo"]) or bool(record["has_normal"])
			var has_uv := false
			if mapped and not bool(record["triplanar_enabled"]):
				if receiver_only:
					var mesh_node := _managed_mesh_node(_instances[instance_index])
					has_uv = mesh_node != null and _mesh_surface_has_complete_uv(mesh_node.mesh, surface)
				else:
					has_uv = surface < surface_has_uv.size() and surface_has_uv[surface] != 0
			if mapped and not bool(record["triplanar_enabled"]) and not has_uv:
				_fail("Mapped RT material %d on %s surface %d requires a complete UV0 array. Supply UV0 or enable triplanar mapping." % [material_index, render_instance["path"], surface])
				return false
	return true


func _mesh_surface_has_complete_uv(mesh: Mesh, surface: int) -> bool:
	if mesh == null or surface < 0 or surface >= mesh.get_surface_count():
		return false
	var arrays := mesh.surface_get_arrays(surface)
	if arrays.size() <= Mesh.ARRAY_TEX_UV:
		return false
	var vertices: Variant = arrays[Mesh.ARRAY_VERTEX]
	var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
	return (
		vertices is PackedVector3Array
		and uvs is PackedVector2Array
		and not (vertices as PackedVector3Array).is_empty()
		and (uvs as PackedVector2Array).size() == (vertices as PackedVector3Array).size()
	)


func _discover_lights(apply_differential_overrides: bool = true) -> void:
	var root := get_node_or_null(geometry_root_path)
	if root == null:
		return
	var discovered: Array[Light3D] = []
	var nodes := root.find_children("*", "Light3D", true, false)
	if root is Light3D:
		nodes.push_front(root)
	for node in nodes:
		var light := node as Light3D
		if light and light != _carrier_light:
			discovered.append(light)
	if apply_differential_overrides:
		var discovered_ids: Dictionary = {}
		for light in discovered:
			discovered_ids[light.get_instance_id()] = true
		for old_light in _lights:
			if is_instance_valid(old_light) and not discovered_ids.has(old_light.get_instance_id()):
				_restore_light_override(old_light)
				_light_shadow_states.erase(old_light.get_instance_id())

		var previous_ids: Dictionary = {}
		for old_light in _lights:
			if is_instance_valid(old_light):
				previous_ids[old_light.get_instance_id()] = true
		for light in discovered:
			var light_id := light.get_instance_id()
			if not previous_ids.has(light_id):
				_suppress_native_light_shadow(light)
				_suppress_light_on_managed(light)
				_light_shadow_states[light_id] = light.shadow_enabled
	_lights = discovered
	# Resolved once here rather than per light per frame in _make_light_snapshot.
	# get_path() walks to the root and builds a String, and the result is only
	# ever read by a diagnostic. Reparenting a light fires the tree signals that
	# set _light_topology_dirty, which brings us back through here.
	_light_paths.clear()
	for light in _lights:
		_light_paths.append(String(light.get_path()))


func _make_light_snapshot() -> Dictionary:
	var records: Array[Dictionary] = []
	for light_index in _lights.size():
		var light := _lights[light_index]
		if not is_instance_valid(light) or not light.is_visible_in_tree() or light.light_energy <= 0.0:
			continue
		var type := -1
		var position := light.global_position
		var direction := Vector3.ZERO
		var light_range := 0.0
		var attenuation := 1.0
		var cone_cosine := -1.0
		var cone_attenuation := 1.0
		if light is DirectionalLight3D:
			type = 0
			direction = light.global_transform.basis.z.normalized()
		elif light is OmniLight3D:
			type = 1
			light_range = (light as OmniLight3D).omni_range
			attenuation = (light as OmniLight3D).omni_attenuation
		elif light is SpotLight3D:
			type = 2
			direction = -light.global_transform.basis.z.normalized()
			light_range = (light as SpotLight3D).spot_range
			attenuation = (light as SpotLight3D).spot_attenuation
			cone_cosine = cos(deg_to_rad((light as SpotLight3D).spot_angle))
			cone_attenuation = (light as SpotLight3D).spot_angle_attenuation
		elif light is AreaLight3D:
			type = 3
			direction = -light.global_transform.basis.z.normalized()
			light_range = (light as AreaLight3D).area_range
			attenuation = (light as AreaLight3D).area_attenuation
		if type < 0:
			continue
		var sign := -1.0 if light.light_negative else 1.0
		var radiance := light.light_color.srgb_to_linear() * (light.light_energy * PI * sign)
		records.append({
			"name": light.name,
			"path": _light_paths[light_index] if light_index < _light_paths.size() else String(light.get_path()),
			"type": type,
			"position": position,
			"direction": direction,
			"color": radiance,
			"range": light_range,
			"attenuation": attenuation,
			"cone_cosine": cone_cosine,
			"cone_attenuation": cone_attenuation,
			"rt_shadow": light.shadow_enabled and not light.light_negative,
			"cull_mask": light.light_cull_mask & RENDER_LAYER_MASK,
		})
	if records.size() > max_scene_lights:
		_fail("The scene has %d active lights, exceeding max_scene_lights (%d)." % [records.size(), max_scene_lights])

	return {"records": records}


## Classifies how far the live lights have drifted from the published snapshot.
## Returns [constant LIGHT_CHANGE_NONE], [constant LIGHT_CHANGE_SHADING] or
## [constant LIGHT_CHANGE_INFLUENCE].
##
## The distinction is what keeps a rotating sun off the receiver candidate lists.
## Shading fields (colour, attenuation, shadow flag, and a directional light's
## direction) are uploaded to the GPU but are never read by the receiver/light
## culler, so they cannot change which lights a receiver sees. Influence fields
## are exactly those [method _light_cannot_affect_receiver] and the cull-mask
## test in [method _build_receiver_light_lists] consult.
func _light_snapshot_change() -> int:
	var records: Array = _snapshot_light["records"]
	var record_index := 0
	var change := LIGHT_CHANGE_NONE
	for light in _lights:
		if not is_instance_valid(light):
			return LIGHT_CHANGE_INFLUENCE
		if not light.is_visible_in_tree() or light.light_energy <= 0.0:
			continue
		# A record dropping out or appearing shifts every later light index, and
		# candidate lists store indices, so membership drift is always influence.
		if record_index >= records.size():
			return LIGHT_CHANGE_INFLUENCE
		var record_change := _light_record_change(light, records[record_index])
		if record_change == LIGHT_CHANGE_INFLUENCE:
			return LIGHT_CHANGE_INFLUENCE
		change = maxi(change, record_change)
		record_index += 1
	if record_index != records.size():
		return LIGHT_CHANGE_INFLUENCE
	return change


## Per-light half of [method _light_snapshot_change], using the same classification.
func _light_record_change(light: Light3D, record: Dictionary) -> int:
	var type := -1
	var position := light.global_position
	var direction := Vector3.ZERO
	var light_range := 0.0
	var attenuation := 1.0
	var cone_cosine := -1.0
	var cone_attenuation := 1.0
	if light is DirectionalLight3D:
		type = 0
		direction = light.global_transform.basis.z.normalized()
	elif light is OmniLight3D:
		type = 1
		light_range = (light as OmniLight3D).omni_range
		attenuation = (light as OmniLight3D).omni_attenuation
	elif light is SpotLight3D:
		type = 2
		direction = -light.global_transform.basis.z.normalized()
		light_range = (light as SpotLight3D).spot_range
		attenuation = (light as SpotLight3D).spot_attenuation
		cone_cosine = cos(deg_to_rad((light as SpotLight3D).spot_angle))
		cone_attenuation = (light as SpotLight3D).spot_angle_attenuation
	elif light is AreaLight3D:
		type = 3
		direction = -light.global_transform.basis.z.normalized()
		light_range = (light as AreaLight3D).area_range
		attenuation = (light as AreaLight3D).area_attenuation
	if type < 0:
		return LIGHT_CHANGE_INFLUENCE
	var cull_mask := light.light_cull_mask & RENDER_LAYER_MASK
	# Influence: the type gate and the cull-mask test apply to every light.
	if type != int(record["type"]) or cull_mask != int(record["cull_mask"]):
		return LIGHT_CHANGE_INFLUENCE
	# Influence, local lights only. A directional light returns early from
	# _light_cannot_affect_receiver before its position, range or direction are
	# ever read, so none of them can move it in or out of a candidate list.
	if type != 0:
		if position != (record["position"] as Vector3) or light_range != float(record["range"]):
			return LIGHT_CHANGE_INFLUENCE
		# Spot and area lights are culled against their axis; the cone half-angle
		# only narrows a spot.
		if type != 1 and direction != (record["direction"] as Vector3):
			return LIGHT_CHANGE_INFLUENCE
		if type == 2 and cone_cosine != float(record["cone_cosine"]):
			return LIGHT_CHANGE_INFLUENCE
	var sign := -1.0 if light.light_negative else 1.0
	var radiance := light.light_color.srgb_to_linear() * (light.light_energy * PI * sign)
	# Shading only: uploaded to the light buffer, never read by the culler.
	if (
			radiance != (record["color"] as Color)
			or attenuation != float(record["attenuation"])
			or cone_attenuation != float(record["cone_attenuation"])
			or (light.shadow_enabled and not light.light_negative) != bool(record["rt_shadow"])
			or direction != (record["direction"] as Vector3)
			or position != (record["position"] as Vector3)
			or light_range != float(record["range"])
			or cone_cosine != float(record["cone_cosine"])
	):
		return LIGHT_CHANGE_SHADING
	return LIGHT_CHANGE_NONE


## Whether instance [param index] falls in this frame's topology-validation slice.
##
## The sweep advances one slice per published frame and wraps, so every receiver
## is fully validated at least once every [constant _TOPOLOGY_VALIDATION_FRAMES]
## frames. Registration validates a receiver in full before it ever reaches here,
## so a freshly streamed chunk is never unchecked.
func _should_validate_topology_this_frame(index: int, instance_count: int) -> bool:
	if instance_count <= 0:
		return true
	var slice_size := ceili(float(instance_count) / float(_TOPOLOGY_VALIDATION_FRAMES))
	if slice_size >= instance_count:
		return true
	var start := _topology_validation_cursor * slice_size
	return index >= start and index < start + slice_size


## [param receiver_only] is the flag already recorded on the instance. Passing it
## avoids a group lookup per receiver per frame for membership that is fixed when
## the chunk is built.
func _instance_rt_mask(mesh_node: MeshInstance3D, receiver_only: bool) -> int:
	if receiver_only or not mesh_node.is_visible_in_tree():
		return 0
	match mesh_node.cast_shadow:
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			return 0x02
		GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			return 0x01
		_:
			return 0x03


func _build_receiver_light_lists(
		transforms: Array[Transform3D],
		layers: PackedInt32Array,
		light_snapshot: Dictionary,
		dirty_receivers: PackedInt32Array,
		recompute_all: bool) -> Dictionary:
	var starts := PackedInt32Array()
	var counts := PackedInt32Array()
	var indices := PackedInt32Array()
	var lights: Array = light_snapshot.get("records", [])
	if transforms.size() != _render_instances.size() or layers.size() != _render_instances.size():
		return {"error": "Receiver light-list inputs have inconsistent instance counts."}
	var candidate_lists: Array[PackedInt32Array] = _receiver_light_candidates.duplicate()
	if candidate_lists.size() != _render_instances.size():
		candidate_lists.resize(_render_instances.size())
		recompute_all = true
	var recompute_flags := PackedByteArray()
	recompute_flags.resize(_render_instances.size())
	if recompute_all:
		recompute_flags.fill(1)
	else:
		for instance_index in dirty_receivers:
			if instance_index >= 0 and instance_index < recompute_flags.size():
				recompute_flags[instance_index] = 1
	var recomputed := 0
	for instance_index in _render_instances.size():
		if recompute_flags[instance_index] == 0:
			continue
		var bounds := _receiver_world_bounds(instance_index, transforms[instance_index])
		if bounds.is_empty():
			return {"error": "Unable to derive conservative receiver bounds for instance %d." % instance_index}
		var candidates := PackedInt32Array()
		for light_index in lights.size():
			var light: Dictionary = lights[light_index]
			if (int(light.get("cull_mask", 0)) & layers[instance_index]) == 0:
				continue
			if _light_cannot_affect_receiver(light, bounds):
				continue
			candidates.append(light_index)
		if _active_backend == RTBackend.SOFTWARE and candidates.size() > software_max_lights_per_receiver:
			var matching_names := PackedStringArray()
			for light_index in candidates:
				var matching_light: Dictionary = lights[light_index]
				matching_names.append(String(matching_light.get("path", matching_light.get("name", "light"))))
			var instance_name := String(_render_instances[instance_index].get("path", "instance %d" % instance_index))
			return {"error": "%s is affected by %d lights, exceeding software_max_lights_per_receiver (%d): %s" % [
				instance_name, candidates.size(), software_max_lights_per_receiver, ", ".join(matching_names)]}
		candidate_lists[instance_index] = candidates
		recomputed += 1
	var maximum := 0
	var total := 0
	for instance_index in _render_instances.size():
		while indices.size() % 4 != 0:
			indices.append(-1)
		starts.append(indices.size())
		var candidates: PackedInt32Array = candidate_lists[instance_index]
		indices.append_array(candidates)
		var count := candidates.size()
		counts.append(count)
		maximum = maxi(maximum, count)
		total += count
		while indices.size() % 4 != 0:
			indices.append(-1)
	_receiver_list_rebuilds += 1
	_receiver_candidates_recomputed += recomputed
	_receiver_light_total = total
	_receiver_light_maximum = maximum
	return {
		"error": "",
		"starts": starts,
		"counts": counts,
		"indices": indices,
		"candidates": candidate_lists,
		"total": total,
		"maximum": maximum,
	}


func _receiver_world_bounds(instance_index: int, transform: Transform3D) -> Dictionary:
	var render_instance: Dictionary = _render_instances[instance_index]
	var local_min_value: Variant = render_instance.get("bounds_min")
	var local_max_value: Variant = render_instance.get("bounds_max")
	var local_min: Vector3
	var local_max: Vector3
	if local_min_value is Vector3 and local_max_value is Vector3:
		local_min = local_min_value
		local_max = local_max_value
	else:
		# Compatibility fallback for snapshots authored before per-instance bounds
		# were added. Receiver-only records always use the branch above so their
		# placeholder geometry can never shrink light-culling bounds.
		var geometry_index := int(render_instance.get("geometry", -1))
		if geometry_index < 0 or geometry_index >= _mesh_records.size():
			return {}
		var mesh_record: Dictionary = _mesh_records[geometry_index]
		local_min = mesh_record.get("bounds_min", Vector3.ZERO)
		local_max = mesh_record.get("bounds_max", Vector3.ZERO)
	var world_min := Vector3(INF, INF, INF)
	var world_max := Vector3(-INF, -INF, -INF)
	for corner_index in 8:
		var corner := Vector3(
			local_max.x if (corner_index & 1) != 0 else local_min.x,
			local_max.y if (corner_index & 2) != 0 else local_min.y,
			local_max.z if (corner_index & 4) != 0 else local_min.z)
		var world_corner := transform * corner
		world_min = Vector3(
			minf(world_min.x, world_corner.x),
			minf(world_min.y, world_corner.y),
			minf(world_min.z, world_corner.z))
		world_max = Vector3(
			maxf(world_max.x, world_corner.x),
			maxf(world_max.y, world_corner.y),
			maxf(world_max.z, world_corner.z))
	world_min -= Vector3.ONE * RECEIVER_BOUNDS_MARGIN
	world_max += Vector3.ONE * RECEIVER_BOUNDS_MARGIN
	var center := (world_min + world_max) * 0.5
	return {
		"min": world_min,
		"max": world_max,
		"center": center,
		"radius": center.distance_to(world_max),
	}


func _light_cannot_affect_receiver(light: Dictionary, bounds: Dictionary) -> bool:
	var light_type := int(light.get("type", -1))
	if light_type == 0:
		return false
	var light_range := float(light.get("range", 0.0))
	if light_range <= 0.0:
		return true
	var position: Vector3 = light.get("position", Vector3.ZERO)
	var bounds_min: Vector3 = bounds["min"]
	var bounds_max: Vector3 = bounds["max"]
	var closest := Vector3(
		clampf(position.x, bounds_min.x, bounds_max.x),
		clampf(position.y, bounds_min.y, bounds_max.y),
		clampf(position.z, bounds_min.z, bounds_max.z))
	if position.distance_squared_to(closest) >= light_range * light_range:
		return true
	var direction: Vector3 = light.get("direction", Vector3.ZERO)
	if direction.length_squared() <= 0.00000001:
		return false
	direction = direction.normalized()
	var center: Vector3 = bounds["center"]
	var radius := float(bounds["radius"])
	var from_light := center - position
	if light_type == 2:
		var center_distance := from_light.length()
		if center_distance > radius and center_distance > 0.0000001:
			var angular_radius := asin(clampf(radius / center_distance, 0.0, 1.0))
			var center_angle := acos(clampf(direction.dot(from_light / center_distance), -1.0, 1.0))
			var cone_angle := acos(clampf(float(light.get("cone_cosine", -1.0)), -1.0, 1.0))
			if center_angle - angular_radius > cone_angle + 0.000001:
				return true
	elif light_type == 3:
		if direction.dot(from_light) + radius <= 0.0:
			return true
	return false


func _packed_int_arrays_equal(left: PackedInt32Array, right: PackedInt32Array) -> bool:
	if left.size() != right.size():
		return false
	for i in left.size():
		if left[i] != right[i]:
			return false
	return true


func _apply_renderer_overrides() -> void:
	for i in _material_sources.size():
		_apply_material_renderer_override(i)
	for i in _instances.size():
		var mesh_node := _managed_mesh_node(_instances[i])
		if mesh_node != null:
			_apply_instance_renderer_override(mesh_node, i, true, _active_backend == RTBackend.HARDWARE)
	for light in _lights:
		if is_instance_valid(light):
			_suppress_native_light_shadow(light)
			_suppress_light_on_managed(light)
			_light_shadow_states[light.get_instance_id()] = light.shadow_enabled


func _apply_material_renderer_override(material_index: int) -> void:
	if material_index < 0 or material_index >= _material_sources.size():
		return
	var material := _material_sources[material_index]
	if not is_instance_valid(material):
		return
	var record := _material_records[material_index]
	RenderingServer.material_set_param(
		material.get_rid(), RT_HAS_ALBEDO_PARAMETER, bool(record["has_albedo"]))
	RenderingServer.material_set_param(
		material.get_rid(), RT_HAS_NORMAL_PARAMETER, bool(record["has_normal"]))
	RenderingServer.material_set_param(
		material.get_rid(), RT_PIPELINE_ACTIVE_PARAMETER, true)
	if _active_backend == RTBackend.HARDWARE:
		RenderingServer.material_set_param(
			material.get_rid(), RT_MATERIAL_ID_PARAMETER, material_index + 1)


func _apply_instance_renderer_override(mesh_node: MeshInstance3D, instance_index: int, apply_id: bool, use_carrier_layer: bool) -> void:
	if not mesh_node.get_instance().is_valid():
		return
	var renderer_layers := RT_CARRIER_LAYER_MASK if use_carrier_layer else mesh_node.layers
	RenderingServer.instance_set_layer_mask(mesh_node.get_instance(), renderer_layers)
	if apply_id:
		RenderingServer.instance_geometry_set_shader_parameter(mesh_node.get_instance(), &"rt_instance_id", instance_index + 1)


func _suppress_native_light_shadow(light: Light3D) -> void:
	if light.get_base().is_valid():
		RenderingServer.light_set_shadow(light.get_base(), false)


func _suppress_light_on_managed(light: Light3D) -> void:
	if _active_backend != RTBackend.HARDWARE:
		return
	if light.get_base().is_valid():
		RenderingServer.light_set_cull_mask(
			light.get_base(), light.light_cull_mask & ~RT_CARRIER_LAYER_MASK)


func _restore_light_override(light: Light3D) -> void:
	if light.get_base().is_valid():
		RenderingServer.light_set_shadow(light.get_base(), light.shadow_enabled)
		RenderingServer.light_set_cull_mask(light.get_base(), light.light_cull_mask)


func _poll_light_shadow_overrides() -> void:
	for light in _lights:
		if not is_instance_valid(light):
			_light_topology_dirty = true
			continue
		var light_id := light.get_instance_id()
		var shadow_enabled := light.shadow_enabled
		# As with instance layers, an authored toggle can change away and back
		# between polls. Reasserting this small renderer-only override guarantees
		# native shadow maps never leak into either RT path and authored lights never
		# enter the hardware carrier layer.
		_suppress_native_light_shadow(light)
		_suppress_light_on_managed(light)
		if not _light_shadow_states.has(light_id) or bool(_light_shadow_states[light_id]) != shadow_enabled:
			_light_shadow_states[light_id] = shadow_enabled


func _restore_renderer_overrides() -> void:
	_restore_environment_reflection_states()
	for material in _material_sources:
		if is_instance_valid(material):
			RenderingServer.material_set_param(material.get_rid(), RT_MATERIAL_ID_PARAMETER, 0)
			RenderingServer.material_set_param(material.get_rid(), RT_HAS_ALBEDO_PARAMETER, false)
			RenderingServer.material_set_param(material.get_rid(), RT_HAS_NORMAL_PARAMETER, false)
			RenderingServer.material_set_param(material.get_rid(), RT_PIPELINE_ACTIVE_PARAMETER, false)
	for item in _instances:
		var mesh_node := _managed_mesh_node(item)
		if mesh_node != null:
			RenderingServer.instance_set_layer_mask(mesh_node.get_instance(), mesh_node.layers)
			RenderingServer.instance_geometry_set_shader_parameter(mesh_node.get_instance(), &"rt_instance_id", 0)
	for light in _lights:
		if is_instance_valid(light):
			_restore_light_override(light)
	_light_shadow_states.clear()


func _create_material_id_carrier() -> void:
	if _carrier_light:
		# _stop_rt_internal hides the carrier rather than freeing it, so a restart
		# has to show it again. Without this the material-ID pass writes nothing
		# after the first stop, decode_visibility_id fails for every managed pixel,
		# and the compositor silently leaves raster carrier albedo on screen.
		_carrier_light.visible = true
		return
	_carrier_light = DirectionalLight3D.new()
	_carrier_light.name = "__RTMaterialIDCarrier"
	_carrier_light.light_color = Color(1.0, 0.0, 0.0, 1.0)
	_carrier_light.light_energy = RT_CARRIER_ENERGY
	_carrier_light.light_cull_mask = RT_CARRIER_LAYER_MASK
	_carrier_light.shadow_enabled = false
	_carrier_light.light_bake_mode = Light3D.BAKE_DISABLED
	add_child(_carrier_light, false, Node.INTERNAL_MODE_FRONT)


func _publish_snapshot() -> void:
	if _failed or _instances.is_empty():
		return
	if _texture_content_dirty:
		_fail("A managed albedo or normal texture changed after the RT atlases were built. Reload the scene to rebuild the static texture atlases.")
		return
	var environment_refresh := _refresh_environment_snapshot()
	if environment_refresh < 0:
		return
	var environment_changed := environment_refresh > 0
	var instance_count := _instances.size()
	var transforms_changed := _snapshot_transforms.size() != instance_count
	var masks_changed := _snapshot_instance_masks.size() != instance_count
	var layers_changed := _snapshot_instance_layers.size() != instance_count
	var transforms_uninitialized := transforms_changed
	var layers_uninitialized := layers_changed
	var traversal_changed := false
	var receiver_dirty_flags := PackedByteArray()
	receiver_dirty_flags.resize(instance_count)
	var next_transforms: Array[Transform3D] = _snapshot_transforms
	var next_instance_masks := _snapshot_instance_masks
	var next_instance_layers := _snapshot_instance_layers
	if transforms_changed:
		next_transforms = []
		next_transforms.resize(instance_count)
	if masks_changed:
		next_instance_masks = PackedInt32Array()
		next_instance_masks.resize(instance_count)
	if layers_changed:
		next_instance_layers = PackedInt32Array()
		next_instance_layers.resize(instance_count)

	for i in instance_count:
		var item := _instances[i]
		if bool(item.get("receiver_tombstone", false)):
			if transforms_changed:
				next_transforms[i] = (
					_snapshot_transforms[i]
					if i < _snapshot_transforms.size() else Transform3D.IDENTITY)
			if masks_changed:
				next_instance_masks[i] = 0
			if layers_changed:
				next_instance_layers[i] = 0
			continue
		var mesh_node := _managed_mesh_node(item)
		if mesh_node == null:
			_fail("Runtime mesh removal requires an RT topology rebuild, which is not active yet.")
			return
		var managed_mesh := mesh_node.mesh
		var surface_count := managed_mesh.get_surface_count() if managed_mesh != null else 0
		if managed_mesh == null or managed_mesh.get_instance_id() != int(item["mesh_id"]) or surface_count != int(item["surface_count"]):
			_fail("Runtime mesh replacement or surface-topology changes require an RT topology rebuild: %s" % mesh_node.get_path())
			return
		# Resolving a surface's active material walks the override -> surface ->
		# mesh chain inside the engine, and this only ever catches an authoring
		# error that hard-fails the manager anyway. Sweeping a slice per frame
		# covers every receiver within _TOPOLOGY_VALIDATION_FRAMES while keeping
		# the mesh-identity check above -- two integer compares -- on every frame.
		if _should_validate_topology_this_frame(i, instance_count):
			var material_ids: PackedInt64Array = item["material_ids"]
			for surface in surface_count:
				var active_material := mesh_node.get_active_material(surface)
				if active_material == null or active_material.get_instance_id() != material_ids[surface]:
					_fail("Runtime material replacement requires an RT topology rebuild: %s surface %d" % [mesh_node.get_path(), surface])
					return
		var receiver_only := bool(item.get("receiver_only", false))
		var current_transform := mesh_node.global_transform
		var current_mask := _instance_rt_mask(mesh_node, receiver_only)
		var current_layers := mesh_node.layers
		if not receiver_only:
			var previous_transform_missing := i >= _snapshot_transforms.size()
			var previous_mask_missing := i >= _snapshot_instance_masks.size()
			if (
					previous_transform_missing
					or previous_mask_missing
					or current_transform != _snapshot_transforms[i]
					or current_mask != _snapshot_instance_masks[i]
			):
				traversal_changed = true
		var receiver_transform_changed := (
			transforms_uninitialized
			or current_transform != _snapshot_transforms[i])
		var receiver_layers_changed := (
			layers_uninitialized
			or current_layers != _snapshot_instance_layers[i])
		if receiver_transform_changed or receiver_layers_changed:
			receiver_dirty_flags[i] = 1
		# Reassert backend-owned instance state after gameplay processing. Hardware
		# needs the private carrier layer; both paths need the one-based instance ID.
		_apply_instance_renderer_override(mesh_node, i, true, _active_backend == RTBackend.HARDWARE)
		if transforms_changed:
			next_transforms[i] = current_transform
		elif current_transform != _snapshot_transforms[i]:
			transforms_changed = true
			next_transforms = _snapshot_transforms.duplicate()
			next_transforms[i] = current_transform
		if masks_changed:
			next_instance_masks[i] = current_mask
		elif current_mask != _snapshot_instance_masks[i]:
			masks_changed = true
			next_instance_masks = _snapshot_instance_masks.duplicate()
			next_instance_masks[i] = current_mask
		if layers_changed:
			next_instance_layers[i] = current_layers
		elif current_layers != _snapshot_instance_layers[i]:
			layers_changed = true
			next_instance_layers = _snapshot_instance_layers.duplicate()
			next_instance_layers[i] = current_layers

	# Advance only after the whole instance pass, so one frame validates one
	# contiguous slice.
	_topology_validation_cursor = (_topology_validation_cursor + 1) % _TOPOLOGY_VALIDATION_FRAMES

	var materials_changed := false
	var next_materials: Array[Dictionary] = _material_records
	for i in _material_sources.size():
		var material := _material_sources[i]
		if not is_instance_valid(material):
			_fail("A managed RT material was freed at runtime.")
			return
		var comparison := _compare_material_record(material, _material_records[i])
		if comparison == -2:
			_fail("Albedo/normal texture assignment changed on managed material %d. Reload the scene to rebuild the static RT texture atlases." % i)
			return
		if comparison < 0:
			_fail("A managed material no longer uses the RT BlinnPhong interface.")
			return
		if comparison == 0:
			if not materials_changed:
				materials_changed = true
				next_materials = _material_records.duplicate()
			var next_record := _make_material_record(material)
			if next_record.is_empty():
				_fail("A managed material no longer uses the RT BlinnPhong interface.")
				return
			next_materials[i] = next_record
	if materials_changed and not _validate_surface_mappings(next_materials):
		return

	var light_change := _light_snapshot_change()
	var lights_changed := light_change != LIGHT_CHANGE_NONE
	# Only an influence-class change can alter which lights a receiver sees. The
	# day/night sun rotates every frame and lands in the shading class, which is
	# what keeps the O(receivers x lights) rebuild below off the per-frame path.
	var lights_influence_changed := light_change == LIGHT_CHANGE_INFLUENCE
	if lights_changed:
		if lights_influence_changed:
			_light_influence_updates += 1
		else:
			_light_shading_updates += 1
	var next_light := _snapshot_light
	if lights_changed:
		next_light = _make_light_snapshot()
		if _failed:
			return
	var active_light_records: Array = next_light["records"]
	if active_light_records.size() > max_scene_lights:
		_fail("The scene has %d active lights, exceeding max_scene_lights (%d)." % [active_light_records.size(), max_scene_lights])
		return
	var receiver_lists_changed := false
	var dirty_receivers := PackedInt32Array()
	for instance_index in receiver_dirty_flags.size():
		if receiver_dirty_flags[instance_index] != 0:
			dirty_receivers.append(instance_index)
	var rebuild_receiver_lists := (
		transforms_changed
		or layers_changed
		or lights_influence_changed
		or _receiver_light_starts.size() != instance_count)
	if lights_changed and not rebuild_receiver_lists:
		_receiver_rebuilds_skipped += 1
	var next_receiver_starts := _receiver_light_starts
	var next_receiver_counts := _receiver_light_counts
	var next_receiver_indices := _receiver_light_indices
	var next_receiver_candidates: Array[PackedInt32Array] = _receiver_light_candidates
	if rebuild_receiver_lists:
		var receiver_result := _build_receiver_light_lists(
			next_transforms,
			next_instance_layers,
			next_light,
			dirty_receivers,
			lights_influence_changed or _receiver_light_candidates.size() != instance_count)
		var receiver_error := String(receiver_result.get("error", ""))
		if not receiver_error.is_empty():
			_fail(receiver_error)
			return
		next_receiver_starts = receiver_result["starts"]
		next_receiver_counts = receiver_result["counts"]
		next_receiver_indices = receiver_result["indices"]
		next_receiver_candidates = receiver_result["candidates"]
		receiver_lists_changed = (
			not _packed_int_arrays_equal(next_receiver_starts, _receiver_light_starts)
			or not _packed_int_arrays_equal(next_receiver_counts, _receiver_light_counts)
			or not _packed_int_arrays_equal(next_receiver_indices, _receiver_light_indices))


	var next_fog := _effective_fog_params()
	var next_ground := _resolved_ground_layer(next_fog)
	var next_ground_params: Vector4 = next_ground[0]
	var next_ground_bounds: Vector4 = next_ground[1]
	var next_ground_sun := _ground_sun_from_lights(next_light)
	var next_ground_sun_direction: Vector3 = next_ground_sun[0]
	var next_ground_sun_radiance: Color = next_ground_sun[1]
	var next_ground_sun_enabled: bool = next_ground_sun[2]
	var settings_changed := (
		ray_origin_bias != _snapshot_bias
		or ray_max_distance != _snapshot_max_distance
		or max_scene_lights != _snapshot_max_lights
		or profiling_enabled != _snapshot_profiling_enabled
		or next_fog != _snapshot_fog
		or _ground_revision != _snapshot_ground_revision
		or next_ground_params != _snapshot_ground_params
		or next_ground_bounds != _snapshot_ground_bounds
		or _ground_ambient != _snapshot_ground_ambient
		or _ground_grass != _snapshot_ground_grass
		or next_ground_sun_direction != _snapshot_ground_sun_direction
		or next_ground_sun_radiance != _snapshot_ground_sun_radiance
		or next_ground_sun_enabled != _snapshot_ground_sun_enabled
	)
	if not transforms_changed and not masks_changed and not layers_changed and not materials_changed and not lights_changed and not environment_changed and not receiver_lists_changed and not settings_changed:
		return

	if transforms_changed:
		next_transforms.make_read_only()
		_snapshot_transforms = next_transforms
	if masks_changed:
		_snapshot_instance_masks = next_instance_masks
	if layers_changed:
		_snapshot_instance_layers = next_instance_layers
	if materials_changed:
		_material_records = next_materials
	if lights_changed:
		_snapshot_light = next_light
	if rebuild_receiver_lists:
		_receiver_light_candidates = next_receiver_candidates
	if receiver_lists_changed:
		_receiver_light_starts = next_receiver_starts
		_receiver_light_counts = next_receiver_counts
		_receiver_light_indices = next_receiver_indices
	_snapshot_bias = ray_origin_bias
	_snapshot_max_distance = ray_max_distance
	_snapshot_max_lights = max_scene_lights
	_snapshot_profiling_enabled = profiling_enabled
	_snapshot_fog = next_fog
	_snapshot_ground_texture = _ground_texture
	_snapshot_ground_params = next_ground_params
	_snapshot_ground_bounds = next_ground_bounds
	_snapshot_ground_ambient = _ground_ambient
	_snapshot_ground_grass = _ground_grass
	_snapshot_ground_revision = _ground_revision
	_snapshot_ground_sun_direction = next_ground_sun_direction
	_snapshot_ground_sun_radiance = next_ground_sun_radiance
	_snapshot_ground_sun_enabled = next_ground_sun_enabled

	_snapshot_revision += 1
	if traversal_changed:
		_tlas_revision += 1
	if transforms_changed or layers_changed:
		_instance_revision += 1
	if materials_changed:
		_material_revision += 1
	if lights_changed:
		_light_revision += 1
	if receiver_lists_changed:
		_receiver_light_revision += 1
	if settings_changed:
		_settings_revision += 1

	_commit_current_snapshot()
	if environment_changed and _post_stack:
		_post_stack.update(_get_post_settings())
	if environment_changed or settings_changed:
		# The background radiance is the fog colour, so an environment swap has to
		# reach unmanaged subscribers too, not just the two RT backends.
		_mark_fog_dirty()


func _commit_current_snapshot() -> void:
	# Arrays and dictionaries reachable from a published snapshot are never
	# mutated again. Render-instance dictionaries are cloned because the
	# receiver-only registry can append/tombstone slots while the render thread
	# still retains the prior snapshot.
	# The registry clones itself before every mutation (see the copy-on-write in
	# the receiver registration and unregistration paths), and no record already
	# in it is ever edited in place, so a clone stays valid for as long as the
	# revision holds. Rebuilding it per frame re-materialised one dictionary per
	# receiver for data that changes only when a chunk streams in or out.
	if _published_instances_revision != _render_instances_revision:
		_published_instances = _render_instances.duplicate(true)
		_published_instances.make_read_only()
		_published_instances_revision = _render_instances_revision
	var published_instances := _published_instances
	var next_snapshot := {
		"revision": _snapshot_revision,
		"topology_revision": _topology_revision,
		"tlas_revision": _tlas_revision,
		"instance_revision": _instance_revision,
		"material_revision": _material_revision,
		"light_revision": _light_revision,
		"environment_revision": _environment_revision,
		"receiver_light_revision": _receiver_light_revision,
		"settings_revision": _settings_revision,
		"transforms": _snapshot_transforms,
		"instance_masks": _snapshot_instance_masks,
		"instance_layers": _snapshot_instance_layers,
		"receiver_light_starts": _receiver_light_starts,
		"receiver_light_counts": _receiver_light_counts,
		"receiver_light_indices": _receiver_light_indices,
		"light": _snapshot_light,
		"environment": _snapshot_environment,
		"mesh_records": _mesh_records,
		"material_records": _material_records,
		"albedo_atlas": _albedo_atlas,
		"normal_atlas": _normal_atlas,
		"texture_atlas_bytes": _texture_atlas_bytes,
		"instances": published_instances,
		"instance_material_indices": _instance_material_indices,
		"bias": _snapshot_bias,
		"max_distance": _snapshot_max_distance,
		"max_lights": _snapshot_max_lights,
		"profiling_enabled": _snapshot_profiling_enabled,
		"fog_begin": _snapshot_fog.x,
		"fog_end": _snapshot_fog.y,
		"fog_curve": _snapshot_fog.z,
		"fog_enabled": _snapshot_fog.w >= 0.5,
		"ground_map": _snapshot_ground_texture,
		"ground_params": _snapshot_ground_params,
		"ground_bounds": _snapshot_ground_bounds,
		"ground_ambient": _snapshot_ground_ambient,
		"ground_grass": _snapshot_ground_grass,
		"ground_revision": _snapshot_ground_revision,
		"ground_sun_direction": _snapshot_ground_sun_direction,
		"ground_sun_radiance": _snapshot_ground_sun_radiance,
		"ground_sun_enabled": _snapshot_ground_sun_enabled,
	}
	next_snapshot.make_read_only()
	_current_snapshot = next_snapshot
	if _active_backend == RTBackend.HARDWARE:
		_snapshot_bridge.publish(next_snapshot)
	_profile_snapshot_updates += 1


func get_render_snapshot() -> Dictionary:
	return _snapshot_bridge.get_snapshot()

func get_full_render_resolution() -> Vector2i:
	# This is the native presentation resolution. Quality presets only resize the
	# private SceneCapture/post targets returned by get_ray_render_resolution().
	var viewport := get_viewport()
	if viewport == null:
		return Vector2i.ZERO
	return Vector2i(viewport.get_visible_rect().size)


func get_post_debug_stage_images() -> Dictionary:
	return _post_stack.get_debug_stage_images() if _post_stack else {}


func get_post_debug_contract_snapshot() -> Dictionary:
	# Validation-only state for asserting the actual internal target and shader
	# texel domains. Runtime callers should use the canonical profile fields.
	return _post_stack.get_debug_contract_snapshot() if _post_stack else {}

func get_profile_snapshot() -> Dictionary:
	# Main-thread diagnostics. Render-thread counters are copied under their own
	# mutex by RTLightingEffect before being merged below.
	var shadow_only_instances := 0
	var reflection_only_instances := 0
	var shadow_and_reflection_instances := 0
	var excluded_instances := 0
	var receiver_tombstones := 0
	for item in _instances:
		if bool(item.get("receiver_tombstone", false)):
			receiver_tombstones += 1
	for mask in _snapshot_instance_masks:
		match mask:
			0x01:
				shadow_only_instances += 1
			0x02:
				reflection_only_instances += 1
			0x03:
				shadow_and_reflection_instances += 1
			_:
				excluded_instances += 1
	var full_resolution := get_full_render_resolution()
	var result := {
		"active_backend": get_active_rt_backend(),
		"auto_start": auto_start,
		"startup_timeout_seconds": startup_timeout_seconds,
		"rt_ready": _ready_emitted and _manager_active and not _failed,
		"lifecycle_busy": _lifecycle_busy,
		"managed_geometry_group": managed_geometry_group,
		"receiver_only_geometry_group": receiver_only_geometry_group,
		"poll_frames": _profile_poll_frames,
		"snapshot_updates": _profile_snapshot_updates,
		"last_update_usec": _profile_last_update_usec,
		"peak_update_usec": _profile_peak_update_usec,
		"managed_instances": _instances.size(),
		"active_managed_instances": _traversable_instance_count + _receiver_only_instance_count,
		"stable_instance_slots": _instances.size(),
		"receiver_tombstones": receiver_tombstones,
		"managed_meshes": _mesh_records.size(),
		"authored_managed_mesh_resources": _mesh_sources.size(),
		"traversable_instances": _traversable_instance_count,
		"receiver_only_instances": _receiver_only_instance_count,
		"receiver_only_registrations": _receiver_only_registrations,
		"receiver_only_unregistrations": _receiver_only_unregistrations,
		"placeholder_geometry_active": _placeholder_geometry_active,
		"managed_materials": _material_records.size(),
		"albedo_atlas_width": _albedo_atlas_size.x,
		"albedo_atlas_height": _albedo_atlas_size.y,
		"normal_atlas_width": _normal_atlas_size.x,
		"normal_atlas_height": _normal_atlas_size.y,
		"texture_atlas_bytes": _texture_atlas_bytes,
		"texture_atlas_uploads": _texture_atlas_uploads,
		"shadow_only_instances": shadow_only_instances,
		"reflection_only_instances": reflection_only_instances,
		"shadow_and_reflection_instances": shadow_and_reflection_instances,
		"excluded_instances": excluded_instances,
		"discovered_lights": _lights.size(),
		"active_lights": (_snapshot_light.get("records", []) as Array).size(),
		"topology_revision": _topology_revision,
		"topology_sync_pending": _topology_sync_pending,
		"topology_sync_in_progress": _topology_sync_in_progress,
		"topology_sync_requests": _topology_sync_requests,
		"topology_sync_starts": _topology_sync_starts,
		"topology_sync_completions": _topology_sync_completions,
		"topology_sync_failures": _topology_sync_failures,
		"tlas_revision": _tlas_revision,
		"instance_revision": _instance_revision,
		"material_revision": _material_revision,
		"light_revision": _light_revision,
		"environment_revision": _environment_revision,
		"environment_mode": int(_snapshot_environment.get("mode", RTEnvironmentMode.FLAT)),
		"environment_source": _snapshot_environment.get("source", &"default_clear"),
		"environment_flat_linear": _snapshot_environment.get(
			"fallback_linear", Color.BLACK),
		"environment_panorama_width": int(_snapshot_environment.get("width", 0)),
		"environment_panorama_height": int(_snapshot_environment.get("height", 0)),
		"environment_panorama_bytes": _environment_panorama_bytes,
		"environment_panorama_uploads": _environment_panorama_uploads,
		"environment_bakes": _environment_bakes,
		"environment_bake_failures": _environment_bake_failures,
		"environment_panorama_source_canonicalizations": (
			_environment_panorama_source_canonicalizations),
		"environment_bake_source": _snapshot_environment.get(
			"bake_source", &"flat"),
		"environment_peak_radiance": float(_snapshot_environment.get(
			"peak_radiance", 0.0)),
		"environment_radiance_minimum": _snapshot_environment.get(
			"radiance_minimum", Vector3.ZERO),
		"environment_radiance_maximum": _snapshot_environment.get(
			"radiance_maximum", Vector3.ZERO),
		"environment_seam_maximum": float(_snapshot_environment.get(
			"seam_maximum", 0.0)),
		"environment_north_pole_maximum": float(_snapshot_environment.get(
			"north_pole_maximum", 0.0)),
		"environment_south_pole_maximum": float(_snapshot_environment.get(
			"south_pole_maximum", 0.0)),
		"environment_last_bake_usec": _environment_last_bake_usec,
		"environment_peak_bake_usec": _environment_peak_bake_usec,
		"receiver_light_revision": _receiver_light_revision,
		"receiver_light_list_rebuilds": _receiver_list_rebuilds,
		"receiver_light_receivers_recomputed": _receiver_candidates_recomputed,
		"light_shading_updates": _light_shading_updates,
		"light_influence_updates": _light_influence_updates,
		"receiver_rebuilds_skipped": _receiver_rebuilds_skipped,
		"receiver_light_candidates_total": _receiver_light_total,
		"receiver_light_candidates_average": (
			float(_receiver_light_total) / float(_instances.size()) if not _instances.is_empty() else 0.0),
		"receiver_light_candidates_maximum": _receiver_light_maximum,
	}
	if _rt_effect and _rt_effect.has_method("get_profile_snapshot"):
		var render_profile: Dictionary = _rt_effect.get_profile_snapshot()
		for key in render_profile:
			result[key] = render_profile[key]
	if _software_tracer:
		var software_profile := _software_tracer.get_profile_snapshot()
		for key in software_profile:
			result[key] = software_profile[key]
	if _post_stack:
		var post_profile := _post_stack.get_profile_snapshot()
		for key in post_profile:
			result[key] = post_profile[key]
	# Backend snapshots may describe their source viewport as the full render
	# size. Canonical quality diagnostics are assigned after every merge so a
	# backend cannot overwrite the output/render distinction.
	var output_resolution := full_resolution
	var render_resolution := get_ray_render_resolution()
	var post_output: Variant = result.get("post_output_size")
	if post_output is Vector2i and post_output.x > 0 and post_output.y > 0:
		output_resolution = post_output
	var post_render: Variant = result.get("post_render_size")
	if post_render is Vector2i and post_render.x > 0 and post_render.y > 0:
		render_resolution = post_render
	# Preserve the hardware callback's raw facts before the canonical target
	# fields below are normalized for both backends.
	var backend_dispatch_size := Vector2i(
		int(result.get("ray_tracing_width", 0)),
		int(result.get("ray_tracing_height", 0)))
	var backend_dispatch_pixels := int(result.get("ray_tracing_dispatch_pixels", 0))
	var effective_scale := Vector2.ONE
	if output_resolution.x > 0 and output_resolution.y > 0:
		effective_scale = Vector2(
			float(render_resolution.x) / float(output_resolution.x),
			float(render_resolution.y) / float(output_resolution.y))
	var resolution_method: StringName = (
		&"native" if render_resolution == output_resolution else &"internal_subviewport")
	result["rt_quality_preset"] = int(rt_quality)
	result["rt_quality_name"] = get_rt_quality_name()
	result["rt_quality_scale"] = get_rt_quality_scale()
	result["ray_tracing_requested_scale"] = get_rt_quality_scale()
	result["output_resolution"] = output_resolution
	result["render_resolution"] = render_resolution
	result["full_render_resolution"] = output_resolution
	result["ray_tracing_full_resolution"] = output_resolution
	result["ray_tracing_resolution"] = render_resolution
	result["ray_tracing_effective_scale"] = effective_scale
	result["ray_tracing_dispatched_pixels"] = render_resolution.x * render_resolution.y
	result["ray_tracing_resolution_method"] = resolution_method
	result["ray_tracing_backend_dispatch_size"] = backend_dispatch_size
	result["ray_tracing_backend_dispatch_pixels"] = backend_dispatch_pixels
	return result


func _scenario_reservation_is_current() -> bool:
	if not _owns_scenario or _scenario_world == null or not is_instance_valid(_scenario_world):
		return false
	if not _scenario_world.has_meta(SCENARIO_OWNER_META):
		return false
	var reservation: Variant = _scenario_world.get_meta(SCENARIO_OWNER_META)
	return reservation is WeakRef and (reservation as WeakRef).get_ref() == self


func _reserve_scenario_ownership() -> String:
	var geometry_root := get_node_or_null(geometry_root_path) as Node3D
	var world := geometry_root.get_world_3d() if geometry_root else null
	if world == null:
		var viewport := get_viewport()
		world = viewport.world_3d if viewport else null
	if world == null or not world.scenario.is_valid():
		return "Managed RT geometry is not inside a valid World3D render scenario."

	var existing_reservation: Variant = (
		world.get_meta(SCENARIO_OWNER_META)
		if world.has_meta(SCENARIO_OWNER_META) else null)
	var existing_manager: Object
	if existing_reservation is WeakRef:
		existing_manager = (existing_reservation as WeakRef).get_ref()
	elif existing_reservation is Object and is_instance_valid(existing_reservation):
		existing_manager = existing_reservation
	if existing_manager != null and existing_manager != self:
		return (
			"The managed World3D already has an active RT compositor. "
			+ "Use exactly one hardware RTSceneManager per World3D.")

	_scenario_world = world
	_scenario = world.scenario
	_scenario_world.set_meta(SCENARIO_OWNER_META, weakref(self))
	_owns_scenario = true
	return ""


func _find_scenario_world_environment() -> WorldEnvironment:
	if _scenario_world == null:
		return null
	if not world_environment_path.is_empty():
		var explicit_node := get_node_or_null(world_environment_path) as WorldEnvironment
		if explicit_node:
			var explicit_viewport := explicit_node.get_viewport()
			if explicit_viewport and explicit_viewport.world_3d == _scenario_world:
				return explicit_node

	var effective_environment := (
		_resolve_effective_environment().get("environment") as Environment)
	var scenario_environment: WorldEnvironment
	for node in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		var candidate := node as WorldEnvironment
		if candidate == null:
			continue
		var candidate_viewport := candidate.get_viewport()
		if candidate_viewport == null or candidate_viewport.world_3d != _scenario_world:
			continue
		if scenario_environment == null:
			scenario_environment = candidate
		if candidate.environment == effective_environment:
			return candidate
	return scenario_environment


func _install_compositor() -> void:
	if not _scenario_reservation_is_current():
		_fail("The hardware RT manager no longer owns its World3D compositor scenario.")
		return
	var anchor := _managed_mesh_node(_instances[0])
	if anchor == null or anchor.get_world_3d() == null:
		_fail("Managed RT geometry is not inside a World3D render scenario.")
		return
	if anchor.get_world_3d() != _scenario_world:
		_fail("Managed RT geometry moved to a different World3D after compositor reservation.")
		return
	var world_environment := _find_scenario_world_environment()
	_previous_compositor = world_environment.compositor if world_environment else null
	_snapshot_bridge.activate()
	_rt_effect = RTLightingEffect.new()
	_rt_effect.snapshot_bridge = _snapshot_bridge

	_compositor = Compositor.new()
	_compositor.compositor_effects = [_rt_effect]
	if not _scenario_reservation_is_current():
		_fail("The hardware RT manager lost its World3D compositor reservation during setup.")
		return
	RenderingServer.scenario_set_compositor(_scenario, _compositor.get_rid())
	_scenario_compositor_installed = true


func _mark_rt_ready() -> void:
	if _failed or _ready_emitted:
		return
	_ready_emitted = true
	rt_ready.emit()


func _remove_failure_layer() -> void:
	if _failure_layer == null or not is_instance_valid(_failure_layer):
		_failure_layer = null
		return
	if _failure_layer.get_parent() == self:
		remove_child(_failure_layer)
	_failure_layer.queue_free()
	_failure_layer = null


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	_manager_active = false
	_ready_emitted = false
	if Engine.is_editor_hint():
		# Editor failures are transient by construction: the scene is edited into
		# and out of the RT contract constantly. Record the reason and let the
		# caller unwind; the editor preview driver tears down to plain raster and
		# retries instead of latching failure or reporting through push_error.
		_editor_preview_error = reason
		rt_failed.emit(reason)
		return
	push_error(reason)
	# Disable stale RT immediately, including failures that happen after renderer
	# overrides were applied but before a valid compositor scenario was installed.
	# Keep authored shadow toggles suppressed: failure must not silently substitute
	# native shadow maps.
	_detach_compositor(false)
	_remove_failure_layer()
	var layer := CanvasLayer.new()
	layer.layer = 100
	var label := Label.new()
	label.text = "Ray tracing backend unavailable\n" + reason
	label.position = Vector2(24.0, 24.0)
	label.modulate = Color(1.0, 0.25, 0.2, 1.0)
	label.add_theme_font_size_override("font_size", 18)
	layer.add_child(label)
	add_child(layer)
	_failure_layer = layer
	rt_failed.emit(reason)
	
func _update_post_settings() -> void:
	if _post_stack:
		_post_stack.update(_get_post_settings())


func _get_post_settings() -> Dictionary:
	return {
		"rt_render_scale": get_rt_quality_scale(),
		"rt_quality_preset": int(rt_quality),
		"rt_quality_name": get_rt_quality_name(),
		"post_anti_aliasing_enabled": post_anti_aliasing_enabled,
		"post_smaa_quality": post_smaa_quality,
		"post_fsr_sharpness": post_fsr_sharpness,
		"post_cas_enabled": post_cas_enabled,
		"post_cas_sharpness": post_cas_sharpness,
		"recover_opaque_coverage_from_rgb": _active_backend == RTBackend.HARDWARE,
		"enabled": retro_post_enabled,
		"brightness": post_brightness,
		"contrast": post_contrast,
		"saturation": post_saturation,
		"black_point": post_black_point,
		"color_balance": post_color_balance,
		"posterize_enabled": post_posterize_enabled,
		"posterize_levels": post_posterize_levels,
		"posterize_strength": post_posterize_strength,
		"environment": _snapshot_environment,
	}
