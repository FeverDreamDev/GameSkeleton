extends SceneTree

## Repeatable frame-time probe for the terrain level. Boots the real app shell,
## enters gameplay, parks the player at a fixed viewpoint, freezes the clock, and
## reports the median and p95 rendered-frame interval.
##
## Everything that makes a frame comparable is pinned here: the camera transform,
## the time of day, and the streaming target. Without that, two runs differ by
## where the clouds happened to be and how much grass had committed, which is far
## more than the differences worth measuring.
##
## Subsystem toggles are environment variables so a whole comparison sweep is a
## shell loop rather than a series of edits. Each one flips a live property; none
## of them touch an authored resource.
##
##   PERF_GRASS=0    hide every committed grass shell mesh
##   PERF_GRASS_QUALITY=n
##                   grass tier: 0 off, 1 low, 2 medium, 3 high
##   PERF_SKY=0      hide the day/night sky dome
##   PERF_CLOUDS=0   keep the dome but drop the cloud layer
##   PERF_STARS=0    keep the dome but drop the star field
##   PERF_SMAA=0     disable the three SMAA passes
##   PERF_GRADE=0    disable the RetroGrade present pass
##   PERF_PANINI=0  directly bypass the Panini projection target
##   PERF_RT=0       stop ray tracing entirely
##   PERF_CARRIER=0  hide the hardware material-ID carrier; MEASUREMENT ONLY,
##                   deliberately breaks managed-pixel lighting
##   PERF_GROUND=0   keep RT but disable the analytic reflection-ground trace
##   PERF_NATIVE_SHADOWS=0
##                   force sun/moon shadow maps off; REQUIRED in both halves of
##                   an RT on/off comparison, since stopping RT restores them
##   PERF_OCCLUSION=1 attach a terrain occluder per chunk and enable occlusion
##                   culling. MEASUREMENT ONLY -- evaluated and rejected: it culls
##                   0-1.75% of primitives (terrain meshes only, never grass) and
##                   costs more on the main thread than it saves on the GPU.
##                   Retained so the result is reproducible if terrain relief,
##                   chunk size or draw distance ever change.
##   PERF_VRS=n      uniform variable-rate-shading density over the scene pass.
##                   MEASUREMENT ONLY -- evaluated and rejected: Godot 4.7 accepts
##                   the texture and vrs_mode silently but applies no rate change
##                   in this Forward+ SubViewport setup, at any density. Retained
##                   because it is the check that would notice a future engine
##                   version wiring it up.
##   PERF_RT_QUALITY=n
##                   RT quality preset: 0 native, 1 quality, 2 balanced, 3 performance
##   PERF_BACKEND=software
##                   force the Compatibility tracer instead of hardware RT
##   PERF_VSYNC=1    restore vsync; OFF by default because the display cap
##                   otherwise floors every measurement at the refresh interval
##   PERF_CLOCK=1    let the day/night clock run; OFF BY DEFAULT, and required
##                   for any measurement involving a moving sun
##   PERF_TIME=f     time of day, default 10.5
##   PERF_WARMUP=n   warmup frames, default 300
##   PERF_FRAMES=n   measured frames, default 1200
##   PERF_LABEL=str  printed with the result so a sweep is readable
##   PERF_LOD=a,b     grass LOD band distances in metres (near->medium, medium->far)
##   PERF_PITCH=deg   camera pitch override, for framing a distant LOD seam
##   PERF_YAW=deg     camera yaw override, for sweeping the area around spawn
##   PERF_FOV=deg     horizontal display FOV override, clamped by the FPS camera
##
## Run at the project's authored resolution, which is what the RT stack sizes
## itself from:
##
##   godot --path . --rendering-method forward_plus --resolution 2560x1440 \
##       --script res://game/tests/perf_probe.gd

const VIEW_POSITION := Vector3(-1.5, 0.0, 4.0)
const VIEW_YAW_DEGREES := -142.0
const VIEW_PITCH_DEGREES := -9.0
const TIME_OF_DAY := 10.5
const TEST_SAVE_DIRECTORY := "res://.godot/perf_probe_saves"

var _shell: GameApp
var _intervals: PackedFloat64Array = []


func _initialize() -> void:
	_run.call_deferred()


func _env_flag(name: String) -> bool:
	return OS.get_environment(name) != "0"


func _env_int(name: String, fallback: int) -> int:
	var raw := OS.get_environment(name)
	return int(raw) if raw.is_valid_int() else fallback


func _wait_for(predicate: Callable, frames: int) -> bool:
	for i in frames:
		if bool(predicate.call()):
			return true
		await process_frame
	return bool(predicate.call())


func _run() -> void:
	# Without this the probe measures the display, not the renderer. The project
	# leaves vsync at its default (enabled), so on a 240 Hz panel every frame
	# lands on a 4.167 ms boundary and nothing below that is measurable -- an
	# optimisation that took the frame from 4.3 ms to 3.0 ms would read as no
	# change at all. Timing runs need the cap off; PERF_VSYNC=1 restores it for
	# anyone deliberately measuring presentation behaviour.
	if OS.get_environment("PERF_VSYNC") != "1":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Keep the probe self-contained and writable in headless/sandboxed runners.
	# Save persistence is unrelated to the frame being measured.
	UISave.directory = TEST_SAVE_DIRECTORY
	var shell_scene := load("res://game/app/main.tscn") as PackedScene
	_shell = shell_scene.instantiate() as GameApp
	_shell.rt_start_timeout_seconds = 30.0
	if OS.get_environment("PERF_PROFILE") == "1":
		_shell.get_node("RTSceneManager").profiling_enabled = true
	# The Compatibility tracer is a shipping path, and it has an entirely
	# different cost profile from the hardware one, so it needs to be measurable
	# on a machine that would otherwise always select hardware.
	if OS.get_environment("PERF_BACKEND") == "software":
		_shell.get_node("RTSceneManager").rt_backend = RTSceneManager.RTBackend.SOFTWARE
	root.add_child(_shell)

	if not await _wait_for(
			func() -> bool: return FlowSystem.get_mode() == FlowSystem.Mode.MENU, 3000):
		printerr("perf_probe: never reached the main menu"); quit(2); return
	_shell.call("_on_new_game_pressed")
	if not await _wait_for(
			func() -> bool:
				return (FlowSystem.get_mode() == FlowSystem.Mode.GAMEPLAY
					and not FlowSystem.is_busy()),
			6000):
		printerr("perf_probe: never reached gameplay"); quit(2); return

	var level := _shell.flow_system.current_level()
	var terrain = level.get_terrain()
	var day_night = level.get_day_night()

	# A frozen clock is what makes two runs comparable at all: the cloud field
	# scrolls, and its shadow is the single most expensive per-fragment term in
	# the grass.
	day_night.set_time_running(OS.get_environment("PERF_CLOCK") == "1")
	day_night.set_time_of_day(float(OS.get_environment("PERF_TIME")) if OS.get_environment("PERF_TIME").is_valid_float() else TIME_OF_DAY)
	# Stopping the clock is not enough to make two separate launches render the
	# same frame. The cloud layer scrolls on wind rather than on the time of day,
	# and the grass sways on the shader's TIME, so both keep moving and neither
	# lands in the same place twice. Pinning them is what makes PERF_REF a real
	# pixel comparison instead of a diff of two different moments.
	#
	# Only for captures, though. Still wind costs real per-fragment work in the
	# grass, so freezing it during a timing run measures something the game never
	# renders -- and worse, it shrinks the very term an optimisation is trying to
	# move, which quietly understates the result.
	if not OS.get_environment("PERF_SHOT").is_empty():
		day_night.wind_speed = 0.0
		day_night.set(&"_cloud_offset", Vector2.ZERO)
		# Twinkle advances from raw delta whether or not the clock runs, so two
		# runs of the same build land on different phases and every star differs.
		# Freezing it is what makes a night capture comparable at all.
		day_night.set(&"_twinkle_frozen", true)
		day_night.set(&"_twinkle_time", 0.0)
		var grass_material := terrain.get_grass_material() as ShaderMaterial
		if grass_material != null:
			grass_material.set_shader_parameter(&"u_wind_enabled", false)
	var grass_tier := OS.get_environment("PERF_GRASS_QUALITY")
	if grass_tier.is_valid_int():
		terrain.grass_quality = int(grass_tier) as TerrainGrass3D.GrassQuality
	# Grass LOD selection is hysteretic, so a chunk sitting near a band boundary
	# can settle either way depending on the order chunks happened to commit. That
	# is invisible in a frame-time median and completely dominates a pixel
	# comparison -- two runs of the *same* build differ by ~4.5% of pixels. Pushing
	# every band past the streaming radius pins all visible grass to the near
	# variant, which makes a capture reproducible. It changes what is measured, so
	# it is opt-in and never on for a timing run.
	var bands := OS.get_environment("PERF_LOD").split(",", false)
	if bands.size() == 2:
		terrain.lod_near_to_medium = float(bands[0])
		terrain.lod_medium_to_near = float(bands[0]) - 6.0
		terrain.lod_medium_to_far = float(bands[1])
		terrain.lod_far_to_medium = float(bands[1]) - 6.0
	if OS.get_environment("PERF_PIN_LOD") == "1":
		terrain.lod_near_to_medium = 4096.0
		terrain.lod_medium_to_far = 5120.0
		terrain.lod_far_to_hidden = 6144.0

	_apply_toggles(terrain, day_night)

	# Park the player rather than leaving it under gravity, and stop input, so
	# the camera cannot drift between the warmup and the measurement.
	FlowSystem.set_gameplay_input(false)
	var player = _shell.player
	player.velocity = Vector3.ZERO
	player.global_position = Vector3(
		VIEW_POSITION.x,
		float(terrain.sample_height(Vector2(VIEW_POSITION.x, VIEW_POSITION.z))) + 1.6,
		VIEW_POSITION.z)
	var yaw := OS.get_environment("PERF_YAW")
	player.rotation.y = deg_to_rad(float(yaw) if yaw.is_valid_float() else VIEW_YAW_DEGREES)
	var view = player.get_node("ViewRoot")
	var display_fov := OS.get_environment("PERF_FOV")
	if display_fov.is_valid_float() and view.has_method(&"set_base_horizontal_fov"):
		view.call(&"set_base_horizontal_fov", float(display_fov), true)
	var pitch := OS.get_environment("PERF_PITCH")
	view.apply_view(deg_to_rad(float(pitch) if pitch.is_valid_float() else VIEW_PITCH_DEGREES))
	# A capture compares separate launches, so even sub-pixel physics settling of
	# the player moves the whole terrain silhouette and creates a false image diff.
	# Timing runs keep normal processing; capture runs freeze the parked hierarchy
	# after its authored camera transform has been applied.
	if not OS.get_environment("PERF_SHOT").is_empty():
		player.process_mode = Node.PROCESS_MODE_DISABLED

	# Streaming has to settle before the warmup, or the measured window includes
	# mesh commits that a later run will not have.
	for i in 240:
		await process_frame

	# SPIKE, measurement only: attach a terrain occluder per loaded chunk and turn
	# the rasterizer's occlusion culling on. Deliberately crude -- full-resolution,
	# main thread, attached once after streaming settles rather than wired into the
	# streaming lifecycle. The only question it answers is whether terrain relief
	# at this chunk size hides whole instances at all; if it does not, none of the
	# real integration is worth building.
	if OS.get_environment("PERF_OCCLUSION") == "1":
		_attach_terrain_occluders(terrain)
	# SPIKE, measurement only: uniform variable rate shading over the whole scene
	# pass. A uniform rate is deliberate -- before building any mask it has to be
	# established that VRS is applied at all on this driver and what the ceiling
	# is. PERF_VRS carries the density value written to every texel.
	var vrs_density := OS.get_environment("PERF_VRS")
	if vrs_density.is_valid_int():
		_apply_uniform_vrs(int(vrs_density))

	var warmup := _env_int("PERF_WARMUP", 300)
	for i in warmup:
		await process_frame

	var frames := _env_int("PERF_FRAMES", 1200)
	_intervals.resize(0)
	var previous := Time.get_ticks_usec()
	for i in frames:
		await process_frame
		var now := Time.get_ticks_usec()
		_intervals.append(float(now - previous) / 1000.0)
		previous = now

	_report(terrain)
	await _capture()
	quit(0)


## Applies a uniform variable-rate-shading density over the scene pass.
##
## The density texture is one texel per 16x16 block of the render target, which is
## the granularity the hardware works at, and the red channel selects the rate.
## Filling it uniformly answers the only question worth asking first: whether VRS
## reaches this driver at all, and what a given rate is worth before any mask is
## built to restrict it. A silently wrong texture size or channel reads as "no
## gain", which is indistinguishable from the technique not helping -- so the
## resolved size is printed rather than assumed.
func _apply_uniform_vrs(density: int) -> void:
	var scene_viewport: SubViewport = _shell.rt_manager.get_scene_viewport()
	if scene_viewport == null:
		printerr("perf_probe: no scene viewport; VRS spike skipped")
		return
	if density <= 0:
		scene_viewport.vrs_mode = Viewport.VRS_DISABLED
		print("perf_probe: VRS disabled")
		return
	var render_size: Vector2i = scene_viewport.size
	var vrs_size := Vector2i(
		maxi(1, int(ceil(float(render_size.x) / 16.0))),
		maxi(1, int(ceil(float(render_size.y) / 16.0))))
	var image := Image.create(vrs_size.x, vrs_size.y, false, Image.FORMAT_R8)
	image.fill(Color8(density, 0, 0))
	scene_viewport.vrs_texture = ImageTexture.create_from_image(image)
	scene_viewport.vrs_mode = Viewport.VRS_TEXTURE
	scene_viewport.vrs_update_mode = Viewport.VRS_UPDATE_ONCE
	print("perf_probe: VRS density %d over %s texels for a %s render target"
		% [density, vrs_size, render_size])


## Builds one ArrayOccluder3D per loaded chunk from the height grid the chunk
## already holds for its collider, and enables occlusion culling on the viewport
## that actually renders 3D.
##
## Every chunk keeps `heights` as a (resolution + 1) squared grid in chunk-local
## space, the same data the HeightMapShape3D is built from, so the occluder needs
## no new sampling and no bake step -- it is a direct re-expression of geometry
## already in memory.
func _attach_terrain_occluders(terrain) -> void:
	var scene_viewport: SubViewport = _shell.rt_manager.get_scene_viewport()
	if scene_viewport == null:
		printerr("perf_probe: no scene viewport; occlusion spike skipped")
		return
	# Must be the scene SubViewport. The root renders no 3D while RT is active, so
	# setting this there or as a project setting does nothing at all.
	scene_viewport.use_occlusion_culling = true

	var manager = terrain.get("_terrain_manager")
	if manager == null:
		printerr("perf_probe: no terrain manager; occlusion spike skipped")
		return
	var settings = manager.settings
	var side: int = int(settings.chunk_resolution) + 1
	var spacing: float = settings.cell_spacing()

	# A regular grid, identical in layout to the terrain surface itself.
	var indices := PackedInt32Array()
	for z in side - 1:
		for x in side - 1:
			var origin := z * side + x
			indices.append_array([
				origin, origin + side, origin + 1,
				origin + 1, origin + side, origin + side + 1])

	var attached := 0
	for coord in manager.chunks:
		var chunk = manager.chunks[coord]
		var heights: PackedFloat32Array = chunk.heights
		if heights.size() != side * side:
			continue
		var vertices := PackedVector3Array()
		vertices.resize(heights.size())
		for z in side:
			for x in side:
				var index := z * side + x
				vertices[index] = Vector3(
					float(x) * spacing, heights[index], float(z) * spacing)
		var occluder := ArrayOccluder3D.new()
		occluder.set_arrays(vertices, indices)
		var instance := OccluderInstance3D.new()
		instance.name = "__PerfOccluder"
		instance.occluder = occluder
		chunk.add_child(instance)
		attached += 1
	print("perf_probe: occlusion spike attached %d chunk occluders (%d tris each)"
		% [attached, indices.size() / 3])


## Optional image check. PERF_SHOT writes the parked viewpoint to a PNG; adding
## PERF_REF compares against an earlier one and prints the difference. An
## optimisation that is supposed to be free has to come back at zero differing
## pixels, and that is not something to take on faith.
func _capture() -> void:
	var shot := OS.get_environment("PERF_SHOT")
	if shot.is_empty():
		return
	for i in 6:
		await process_frame
	var image := root.get_texture().get_image()
	image.save_png(shot)
	print("  wrote %s" % shot)

	var reference_path := OS.get_environment("PERF_REF")
	if reference_path.is_empty():
		return
	var reference := Image.load_from_file(reference_path)
	if reference == null:
		printerr("  reference %s did not load" % reference_path)
		return
	if reference.get_size() != image.get_size():
		printerr("  reference is %s, capture is %s" % [reference.get_size(), image.get_size()])
		return
	var differing := 0
	var max_delta := 0.0
	var total_delta := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var a := image.get_pixel(x, y)
			var b := reference.get_pixel(x, y)
			var delta := maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))
			if delta > 0.0:
				differing += 1
				max_delta = maxf(max_delta, delta)
				total_delta += delta
	var pixels := image.get_width() * image.get_height()
	print("  vs %s: %d/%d pixels differ (%.4f%%), max channel delta %.5f (%.2f/255), mean %.6f" % [
		reference_path.get_file(), differing, pixels,
		100.0 * float(differing) / float(pixels),
		max_delta, max_delta * 255.0,
		total_delta / float(pixels)])
	_write_difference(image, reference, shot.get_basename() + "_diff.png")


func _apply_toggles(terrain, day_night) -> void:
	if not _env_flag("PERF_GRASS"):
		for node in terrain.find_children("GrassMesh", "MultiMeshInstance3D", true, false):
			(node as MultiMeshInstance3D).visible = false
	if not _env_flag("PERF_SKY"):
		var dome := day_night.find_child("SkyDome", true, false) as MeshInstance3D
		if dome != null:
			dome.visible = false
	# Clouds and stars are the two expensive terms inside the sky shader, and
	# PERF_SKY only answers what the whole dome costs. Both gates are the ones
	# the cycle already uses, so nothing else about the sky shifts.
	if not _env_flag("PERF_CLOUDS"):
		day_night.clouds_enabled = false
	if not _env_flag("PERF_STARS"):
		day_night.stars_enabled = false
	if not _env_flag("PERF_SMAA"):
		_shell.rt_manager.post_anti_aliasing_enabled = false
	if not _env_flag("PERF_GRADE"):
		_shell.rt_manager.retro_post_enabled = false
	if not _env_flag("PERF_PANINI"):
		_shell.rt_manager.post_panini_enabled = false
	# The carrier is a deliberately overbright directional light whose only job is
	# to transport material/instance IDs through separate specular. Hiding it
	# measures that raster light pass, but decode_visibility_id then rejects every
	# managed pixel, so this is an attribution toggle rather than a playable mode.
	if not _env_flag("PERF_CARRIER"):
		var carrier := _shell.rt_manager.get_node_or_null("__RTMaterialIDCarrier") as Light3D
		if carrier != null:
			carrier.visible = false
	if not _env_flag("PERF_RT"):
		_shell.rt_manager.stop_rt()
	# Zero march steps is the shader's own "layer disabled" encoding, so this
	# isolates the analytic ground trace without disturbing reflections
	# themselves -- a reflection ray that misses then resolves to the environment.
	if not _env_flag("PERF_GROUND"):
		_shell.rt_manager.ground_march_steps = 0
	# The scaled presets composite the same scene at fewer pixels, so a native
	# optimisation has to be shown still working -- and still paying off -- there.
	var quality_preset := OS.get_environment("PERF_RT_QUALITY")
	if quality_preset.is_valid_int():
		_shell.rt_manager.set_rt_quality(int(quality_preset))
	# Retro RT suppresses every native shadow map while it runs, so stopping RT
	# also RESTORES two 4-split directional cascades over the whole scene. An
	# RT on/off comparison therefore measures (RT stack) minus (the shadow maps RT
	# was suppressing) and understates RT. Forcing shadows off in BOTH halves of
	# the comparison is what makes the delta mean "the cost of the RT stack".
	if not _env_flag("PERF_NATIVE_SHADOWS"):
		for light in day_night.find_children("*", "DirectionalLight3D", true, false):
			(light as DirectionalLight3D).shadow_enabled = false


func _percentile(sorted: PackedFloat64Array, fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index := int(floor(fraction * float(sorted.size() - 1)))
	return sorted[clampi(index, 0, sorted.size() - 1)]


func _report(terrain) -> void:
	var sorted := _intervals.duplicate()
	sorted.sort()
	var median := _percentile(sorted, 0.5)
	var p95 := _percentile(sorted, 0.95)
	var p99 := _percentile(sorted, 0.99)
	var label := OS.get_environment("PERF_LABEL")
	if label.is_empty():
		label = "default"

	var toggles: PackedStringArray = []
	for name in [
			"PERF_GRASS", "PERF_SKY", "PERF_CLOUDS", "PERF_STARS", "PERF_GROUND", "PERF_NATIVE_SHADOWS",
			"PERF_SMAA", "PERF_GRADE", "PERF_PANINI", "PERF_CARRIER", "PERF_RT"]:
		if not _env_flag(name):
			toggles.append(name.trim_prefix("PERF_").to_lower() + "=off")
	if toggles.is_empty():
		toggles.append("all on")

	print("perf_probe [%s] %s" % [label, ", ".join(toggles)])
	if not _env_flag("PERF_CARRIER"):
		print("  WARNING: carrier=off deliberately breaks managed-pixel lighting; measurement only")
	print("  median %.3f ms (%.1f FPS)   p95 %.3f ms   p99 %.3f ms   n=%d" % [
		median, 1000.0 / maxf(median, 0.0001), p95, p99, _intervals.size()])

	var manager := _shell.rt_manager
	print("  backend %s   render %s   dispatch px %d" % [
		manager.get_active_rt_backend(),
		manager.get_ray_render_resolution(),
		int(manager.get_ray_render_resolution().x) * int(manager.get_ray_render_resolution().y)])
	var grass_instances: Array = terrain.find_children(
		"GrassMesh", "MultiMeshInstance3D", true, false)
	var visible_grass := 0
	var drawn_shells := 0
	for node in grass_instances:
		var instance := node as MultiMeshInstance3D
		if not instance.visible or instance.multimesh == null:
			continue
		visible_grass += 1
		drawn_shells += instance.multimesh.instance_count
	print("  grass chunks %d (%d drawing, %d shell instances)" % [
		grass_instances.size(), visible_grass, drawn_shells])
	# What the renderer actually submitted, as opposed to what the scene tree
	# holds. The counts above are nodes; these are draws, and they are the only
	# way to see a culling change -- an object the frustum or an occluder rejected
	# still exists as a visible node.
	#
	# Read from the scene SubViewport, never the root: the root renders no 3D
	# while RT is active, so asking it reports zero objects and looks like a
	# spectacular culling win.
	var scene_viewport := manager.get_scene_viewport()
	if scene_viewport != null:
		print("  drawn: %d objects, %d primitives, %d draw calls" % [
			scene_viewport.get_render_info(
				Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_OBJECTS_IN_FRAME),
			scene_viewport.get_render_info(
				Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
			scene_viewport.get_render_info(
				Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)])

	if manager.profiling_enabled:
		var profile: Dictionary = manager.get_profile_snapshot()
		# last/peak _process cost, and the two counters whose gap is the wasted
		# receiver-light rebuild: the list is recomputed whenever a light moves,
		# but its revision only advances when the result actually changed.
		print("  manager _process last %d us, peak %d us" % [
			int(profile.get("last_update_usec", -1)), int(profile.get("peak_update_usec", -1))])
		print("  snapshot updates %d / %d polled frames; receiver-list rebuilds %d, revision %d" % [
			int(profile.get("snapshot_updates", -1)), int(profile.get("poll_frames", -1)),
			int(profile.get("receiver_light_list_rebuilds", -1)),
			int(profile.get("receiver_light_revision", -1))])
		# A rotating sun lands in the shading class, which is what keeps rebuilds
		# far below the frame count. Influence updates are the ones that must
		# rebuild; skipped is the count that used to be paid for nothing.
		print("  light updates: shading %d, influence %d; rebuilds skipped %d, receivers recomputed %d" % [
			int(profile.get("light_shading_updates", -1)),
			int(profile.get("light_influence_updates", -1)),
			int(profile.get("receiver_rebuilds_skipped", -1)),
			int(profile.get("receiver_light_receivers_recomputed", -1))])
		print("  instances %d (receiver-only %d), dispatch gpu %.3f ms" % [
			int(profile.get("managed_instances", -1)),
			int(profile.get("receiver_only_instances", -1)),
			float(profile.get("dispatch_gpu_seconds", 0.0)) * 1000.0])
		# Per-viewport GPU time, which is the only way to attribute the SMAA and
		# present passes -- they are 2D canvas draws with no render-thread hook.
		#
		# These are a SINGLE FRAME, not a distribution: the rendering server
		# reports the last frame's timing, so this line is one sample no matter how
		# many frames were measured. It is the right tool for "which pass is
		# expensive" and the wrong one for "did this change save 0.2 ms" -- a
		# median of three runs of this statistic is a median of three frames. Use
		# the frame-interval median above for before/after, and where the two
		# disagree, believe the distribution. A change was once credited with a
		# 6.5% scene-pass win on this line while frame time moved the other way.
		var pass_gpu: Dictionary = profile.get("post_pass_gpu_ms", {})
		if not pass_gpu.is_empty():
			var parts: PackedStringArray = []
			var total := 0.0
			for name in pass_gpu:
				var milliseconds := float(pass_gpu[name])
				total += milliseconds
				parts.append("%s %.3f" % [name, milliseconds])
			parts.append("SUM %.3f" % total)
			print("  pass gpu ms: %s" % ", ".join(parts))


## Amplified difference image, written next to the capture whenever PERF_REF is
## set. A three-code difference is invisible at a glance and obvious at 60x.
func _write_difference(image: Image, reference: Image, path: String) -> void:
	var diff := Image.create_empty(image.get_width(), image.get_height(), false, Image.FORMAT_RGB8)
	for y in image.get_height():
		for x in image.get_width():
			var a := image.get_pixel(x, y)
			var b := reference.get_pixel(x, y)
			diff.set_pixel(x, y, Color(
				clampf(absf(a.r - b.r) * 60.0, 0.0, 1.0),
				clampf(absf(a.g - b.g) * 60.0, 0.0, 1.0),
				clampf(absf(a.b - b.b) * 60.0, 0.0, 1.0)))
	diff.save_png(path)
	print("  wrote %s" % path)
