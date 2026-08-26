class_name ShaderWarmup
extends Node

## Compiles every shader in the project before gameplay, by drawing each material once into a
## hidden viewport.
##
## A shader is only compiled the first time something using it is actually drawn. Left alone, that
## happens the first time the player looks at an object, which is exactly when a stall is most
## visible. This draws everything up front instead, behind a progress bar.
##
## Which materials get drawn comes from the generated [ShaderWarmupManifest], so a material added
## to any scene later is picked up with no change to this file. Materials built in code at runtime
## cannot be in a generated file, so they announce themselves through [method register_material].
##
## [b]On renderers.[/b] Forward+ and Mobile precompile pipelines automatically from Godot 4.4 --
## merely instancing a scene is enough, drawn or not. Compatibility has no such mechanism at all,
## which is what makes this class load-bearing there. It still runs on Forward+, because a manifest
## material that no instanced scene happens to reference gets no automatic treatment either.
##
## [b]Vertex formats.[/b] A pipeline is keyed on the vertex format as well as the material, and
## every material here is drawn on one shared [BoxMesh]. That is complete coverage for a project
## built out of primitives and stops being complete the moment a mesh with a different attribute
## set appears -- a rigged character above all. The manifest therefore also records which formats
## each material is drawn on, and any that the box does not already cover gets a pass of its own on
## a proxy synthesised to match. See [ShaderWarmupVertexFormat].
##
## [b]The trap.[/b] The warmup viewport copies the main viewport's antialiasing settings. Godot
## tracks a single MSAA level for precompilation purposes, so a warmup viewport rendering at a
## different level would teach it the wrong answer and cause the very stutter this exists to
## remove. If an options menu ever changes MSAA, the warmup has to be re-run. For the same reason
## nothing here permutes MSAA deliberately: the engine tracks one level at a time, so a rig that
## varied it would cause the stutter it exists to remove.
##
## [b]Nothing here is assumed.[/b] Every batch is checked against
## [method Viewport.get_render_info] afterwards, so "compiled" means the renderer confirmed it drew
## the geometry, not that a frame went by. A rig that silently fails reports zero rather than a
## fake hundred percent.

#region Signals

## [param label] names the material just finished, for a readout like "3 / 10  Mat_Stairs".
signal progress_changed(current: int, total: int, label: String)
signal warmup_finished()

#endregion

#region Configuration

## Ceiling on materials drawn per frame. The actual batch size is smaller when there is little to
## do, so that the progress bar always gets enough steps to animate.
@export var max_batch_size: int = 16
## Roughly how many progress updates a full run should produce. The bar quantises to discrete
## blocks, so far more than this is invisible and far fewer makes it lurch.
@export var target_progress_steps: int = 24
## Small on purpose. Compiling is independent of render target size; nothing here is ever seen.
@export var viewport_size: Vector2i = Vector2i(128, 128)
## Give-up time for a single batch, in case a frame never lands.
@export var batch_timeout_msec: int = 2000
## Hard ceiling on the whole run. A stalled driver must not be able to hang the boot screen.
@export var time_budget_seconds: float = 20.0

## Warm every distinct vertex format exactly, rather than only those that differ from the shared
## box proxy in a way that changes the compiled program.
##
## What a pipeline state object really keys on is the exact format, so this is the strictly correct
## setting -- and it is off by default because it buys very little for what it costs. A material
## drawn on a mesh whose attributes are a subset of the box's compiles the same program; only the
## vertex input layout differs, and building that from an already-compiled shader is cheap. Turning
## this on adds a frame per distinct format for a hitch that is near-invisible.
##
## Ignored on Compatibility, which has no pipeline objects for the distinction to apply to. See
## [method uses_pipeline_objects].
@export var strict_vertex_formats: bool = false

@export_group("Light Variants")
## The renderer compiles a different variant per light type, so each of these covers a family of
## shaders gameplay might use. Turn one off only if the game provably never uses that light.
@export var warm_directional_light: bool = true
@export var warm_omni_light: bool = true
@export var warm_spot_light: bool = true

#endregion

#region Runtime Registration

## Materials created in code, which by definition cannot appear in a generated manifest. Static so
## callers need neither a node reference nor an autoload -- the same reasoning as [UISystem].
static var _registered: Array[Material] = []

## Queues [param material] for warmup. Safe to call at any time: before a run it joins the queue,
## and after one it waits for the next.
##
## Warmed on the shared box only. A registered material has no recorded vertex format -- the
## manifest is where those come from, and nothing built at runtime is in it -- so a material
## destined for a skinned mesh still needs the mesh itself to reach the scanner. Assigning it to a
## mesh in a scene is what does that; building both in code is the case this cannot cover.
static func register_material(material: Material) -> void:
	if material == null or _registered.has(material):
		return
	_registered.append(material)

#endregion

#region State

## What the routing table decided a material needs drawing on.
enum Kind { SPATIAL, SKY, CANVAS, PARTICLES, UNSUPPORTED }

var _viewport: SubViewport
var _proxies: Array[MeshInstance3D] = []
var _canvas_proxy: ColorRect
var _particle_proxy: GPUParticles3D
var _environment: Environment
var _sky: Sky
## Passes the shared box proxy does not cover, each
## [code]{material, format, flags, label}[/code]. Decided before the rig is built, because the rig
## needs one proxy per distinct format and must not gain nodes once it is drawing.
var _pairs: Array[Dictionary] = []
## "format|flags" -> the [GeometryInstance3D] built to draw it.
var _pair_proxies: Dictionary = {}
## Built only when a skinned format turns up. A mesh carrying bones and weights only takes the
## skinned path when a skeleton actually drives it; assigning the mesh alone is not enough.
var _skeleton: Skeleton3D
## Objects the rig draws with every proxy hidden -- the shadow catcher, essentially. A pass has to
## beat this to count as having drawn anything of its own.
var _idle_objects: int = 0
## Display name per material, so the readout can name what it just compiled.
var _labels: Dictionary = {}
## The project's own sky setup, put back after the sky bucket has been warmed over it.
var _original_background_mode: int = Environment.BG_SKY
var _original_sky_material: Material

var _warmed: int = 0
var _skipped: int = 0
var _total: int = 0
var _deadline_msec: int = 0
var _running: bool = false

#endregion

#region Run

## Draws every known material once, and returns a report:
## [code]{warmed: int, skipped: int, total: int, reason: String}[/code].
##
## Await it. It always returns and always emits [signal warmup_finished], including when it gives
## up -- boot must not be able to hang here.
func run(manifest: ShaderWarmupManifest = null) -> Dictionary:
	if _running:
		push_warning("ShaderWarmup: already running.")
		return _report("already_running")
	if not is_inside_tree():
		push_warning("ShaderWarmup: must be in the tree to render. Skipping warmup.")
		return _report("not_in_tree")

	_running = true
	_warmed = 0
	_skipped = 0
	_deadline_msec = Time.get_ticks_msec() + int(time_budget_seconds * 1000.0)

	if manifest == null:
		manifest = load_manifest()

	var buckets := _build_buckets(manifest)
	_build_pairs(manifest)
	_total = _pairs.size()
	for kind in buckets:
		_total += (buckets[kind] as Array).size()
	progress_changed.emit(0, _total, "")

	var reason := "ok"
	if _total == 0:
		reason = "nothing_to_warm"
	else:
		_build_rig(manifest)
		if await _self_test():
			await _warm(buckets)
		else:
			reason = "rig_unusable"
		_teardown()

	_running = false
	warmup_finished.emit()
	return _report(reason)

func _report(reason: String) -> Dictionary:
	return {"warmed": _warmed, "skipped": _skipped, "total": _total, "reason": reason}

## The generated manifest, or null with a warning if it is missing. A missing manifest is a normal
## state on a fresh checkout, not an error: warmup degrades, boot carries on.
static func load_manifest() -> ShaderWarmupManifest:
	if not ResourceLoader.exists(ShaderWarmupScanner.MANIFEST_PATH):
		push_warning("ShaderWarmup: no manifest at %s. Rebuild it from Project > Tools." % ShaderWarmupScanner.MANIFEST_PATH)
		return null
	var manifest := ResourceLoader.load(ShaderWarmupScanner.MANIFEST_PATH) as ShaderWarmupManifest
	if manifest == null:
		push_warning("ShaderWarmup: %s is not a ShaderWarmupManifest." % ShaderWarmupScanner.MANIFEST_PATH)
	return manifest

#endregion

#region Queue

## Manifest entries plus anything registered at runtime, sorted into one bucket per proxy type.
func _build_buckets(manifest: ShaderWarmupManifest) -> Dictionary:
	var buckets := {
		Kind.SKY: [] as Array[Material],
		Kind.SPATIAL: [] as Array[Material],
		Kind.CANVAS: [] as Array[Material],
		Kind.PARTICLES: [] as Array[Material],
	}
	var labels := {}
	var seen := {}

	if manifest != null:
		for index in manifest.materials.size():
			_sort_into(buckets, labels, seen, manifest.materials[index], manifest.label_at(index))

	var pending := _registered.duplicate()
	_registered.clear()
	for material in pending:
		_sort_into(buckets, labels, seen, material, _label_for(material))

	_labels = labels
	return buckets

func _sort_into(buckets: Dictionary, labels: Dictionary, seen: Dictionary, material: Material, label: String) -> void:
	if material == null or not is_instance_valid(material) or seen.has(material):
		return
	seen[material] = true

	var kind := classify(material)
	if not buckets.has(kind):
		push_warning("ShaderWarmup: no proxy for %s (%s); skipping." % [label, material.get_class()])
		_skipped += 1
		return

	labels[material] = label
	(buckets[kind] as Array[Material]).append(material)

## Works out which recorded (material, vertex format) pairings need drawing on geometry of their
## own, and drops the ones the shared box already accounts for.
##
## Nearly all of them are dropped in a project built out of primitives: a box, a cylinder and a
## plane all carry the same attributes, so the material pass has already compiled everything they
## need and re-drawing them would be pure boot time. What survives is the case this exists for --
## a format the box cannot stand in for, skinning above all.
func _build_pairs(manifest: ShaderWarmupManifest) -> void:
	_pairs.clear()
	if manifest == null:
		return

	var base := ShaderWarmupVertexFormat.base_format()
	# Tier 3: exact formats are a pipeline-object concern, and Compatibility has no pipeline
	# objects. The skinning and compression cases below are not gated -- those are shader variants
	# on both renderers, and skipping them there would reintroduce the very stutter this removes.
	var strict := strict_vertex_formats and uses_pipeline_objects()
	var seen := {}

	for index in manifest.pair_count():
		var material := manifest.pair_material(index)
		if material == null or not is_instance_valid(material):
			continue
		# Anything not drawn on a mesh has no vertex format worth pairing, and its proxy would be
		# the wrong shape entirely.
		if classify(material) != Kind.SPATIAL:
			continue

		var format: int = manifest.pair_vertex_formats[index]
		var flags: int = manifest.pair_flags[index]
		# Instanced draws source their transform from a per-instance buffer, so they are a separate
		# program however ordinary the vertex format is.
		if flags == ShaderWarmupManifest.PairFlags.NONE \
				and ShaderWarmupVertexFormat.covered_by(base, format, strict):
			continue

		var key := "%d|%d|%d" % [material.get_instance_id(), format, flags]
		if seen.has(key):
			continue
		seen[key] = true

		_pairs.append({
			"material": material,
			"format": format,
			"flags": flags,
			"label": "%s (%s)" % [_label_for(material), _describe_pair(format, flags)],
		})

static func _describe_pair(format: int, flags: int) -> String:
	var description := ShaderWarmupVertexFormat.describe(format)
	if flags & ShaderWarmupManifest.PairFlags.MULTIMESH == 0:
		return description
	var instancing := PackedStringArray(["instanced"])
	if flags & ShaderWarmupManifest.PairFlags.MULTIMESH_COLORS:
		instancing.append("instance colour")
	if flags & ShaderWarmupManifest.PairFlags.MULTIMESH_CUSTOM_DATA:
		instancing.append("instance custom")
	return "%s, %s" % [", ".join(instancing), description]

#endregion

#region Renderer

## True when the renderer builds real pipeline state objects -- Forward+ and Mobile, on Vulkan,
## Direct3D 12 or Metal. False on Compatibility, where OpenGL has no PSO concept at all: render
## state is set with loose glEnable calls per draw rather than baked into a compiled object.
##
## Asked of the rendering server rather than read from the project setting, because the setting
## does not reflect a driver fallback at runtime.
##
## Only the narrowest tier of work is gated on this. Material warmup is load-bearing on
## Compatibility -- it is the only mechanism GL has -- and so is vertex-format warmup, because
## GLES3 does skinning behind its own shader variant. What this gates is the pipeline-only
## permutations that would be wasted effort there.
static func uses_pipeline_objects() -> bool:
	return RenderingServer.get_current_rendering_method() != "gl_compatibility"

#endregion

#region Routing

## Decides what a material has to be drawn on.
##
## [ShaderMaterial] is the interesting case: the resource type says nothing, so its shader's own
## mode is the only reliable answer. Note the ordering -- ShaderMaterial is a direct [Material]
## subclass and has to be tested before anything else.
static func classify(material: Material) -> Kind:
	if material == null:
		return Kind.UNSUPPORTED

	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader == null:
			return Kind.UNSUPPORTED
		match shader.get_mode():
			Shader.MODE_SPATIAL:
				return Kind.SPATIAL
			Shader.MODE_SKY:
				return Kind.SKY
			Shader.MODE_CANVAS_ITEM:
				return Kind.CANVAS
			Shader.MODE_PARTICLES:
				return Kind.PARTICLES
			_:
				# MODE_FOG needs a FogVolume, and 4.7's MODE_TEXTURE_BLIT has no node proxy at all.
				return Kind.UNSUPPORTED

	if material is BaseMaterial3D:
		return Kind.SPATIAL
	# The three sky materials share no base class beyond Material, so they must be named.
	if material is ProceduralSkyMaterial or material is PanoramaSkyMaterial or material is PhysicalSkyMaterial:
		return Kind.SKY
	if material is CanvasItemMaterial:
		return Kind.CANVAS
	if material is ParticleProcessMaterial:
		return Kind.PARTICLES
	return Kind.UNSUPPORTED

#endregion

#region Warming

func _warm(buckets: Dictionary) -> void:
	# Sky first, and the project's own sky is put back afterwards. Ambient light taken from a sky
	# is part of how a spatial material compiles, so warming spatial against the wrong sky would
	# produce shaders gameplay never asks for.
	for material in buckets[Kind.SKY]:
		if _out_of_time():
			return
		await _warm_one(material, Kind.SKY)
	_restore_sky()

	var spatial: Array[Material] = buckets[Kind.SPATIAL]
	var batch_size := _batch_size_for(spatial.size())
	var index := 0
	while index < spatial.size():
		if _out_of_time():
			return
		var batch := spatial.slice(index, mini(index + batch_size, spatial.size()))
		var drawn := await _submit(func() -> void: _apply_spatial(batch)) > 0
		_account(batch.size(), drawn, _label_for(batch.back()))
		index += batch.size()
	_apply_spatial([] as Array[Material])

	# One frame each rather than batched: there is a single proxy per vertex format, and a project
	# with enough of these to notice the difference has bigger problems than boot time.
	for pair in _pairs:
		if _out_of_time():
			return
		await _warm_pair(pair)

	for material in buckets[Kind.CANVAS]:
		if _out_of_time():
			return
		await _warm_one(material, Kind.CANVAS)

	for material in buckets[Kind.PARTICLES]:
		if _out_of_time():
			return
		await _warm_one(material, Kind.PARTICLES)

func _warm_one(material: Material, kind: Kind) -> void:
	var drawn := await _submit(func() -> void: _apply_single(material, kind)) > 0
	_clear_single(kind)
	_account(1, drawn, _label_for(material))

## Draws one material on geometry carrying the vertex format it is really used with.
##
## The check is against [member _idle_objects] rather than against zero, because the shadow
## catcher is visible in every frame the rig draws: a proxy that failed to render would still
## leave a non-zero object count behind and report a pass that never happened.
func _warm_pair(pair: Dictionary) -> void:
	var label: String = pair["label"]
	var proxy: GeometryInstance3D = _pair_proxies.get(_pair_key(pair))
	if proxy == null:
		# The proxy could not be built; counting it warmed would be a lie.
		_account(1, false, label)
		return

	var material: Material = pair["material"]
	var objects := await _submit(func() -> void:
		proxy.material_override = material
		proxy.visible = true)
	proxy.visible = false
	proxy.material_override = null
	_account(1, objects > _idle_objects, label)

static func _pair_key(pair: Dictionary) -> String:
	return "%d|%d" % [pair["format"], pair["flags"]]

func _apply_spatial(batch: Array[Material]) -> void:
	for slot in _proxies.size():
		var proxy := _proxies[slot]
		var active := slot < batch.size()
		proxy.visible = active
		# Cleared when unused, or the last partial batch would redraw a material already counted.
		proxy.material_override = batch[slot] if active else null

func _apply_single(material: Material, kind: Kind) -> void:
	match kind:
		Kind.SKY:
			if _sky != null:
				_sky.sky_material = material
				if _environment != null:
					_environment.background_mode = Environment.BG_SKY
		Kind.CANVAS:
			_canvas_proxy.material = material
			_canvas_proxy.visible = true
		Kind.PARTICLES:
			_particle_proxy.process_material = material
			_particle_proxy.visible = true
			_particle_proxy.emitting = true

func _clear_single(kind: Kind) -> void:
	match kind:
		Kind.CANVAS:
			_canvas_proxy.material = null
			_canvas_proxy.visible = false
		Kind.PARTICLES:
			_particle_proxy.emitting = false
			_particle_proxy.visible = false

func _account(count: int, drawn: bool, label: String) -> void:
	if drawn:
		_warmed += count
	else:
		_skipped += count
	progress_changed.emit(_warmed + _skipped, _total, label)

## Enough steps to animate the bar, without flooding it with updates nobody can see.
func _batch_size_for(total: int) -> int:
	if total <= 0:
		return 1
	var wanted := ceili(float(total) / float(maxi(target_progress_steps, 1)))
	return clampi(wanted, 1, _proxies.size())

func _out_of_time() -> bool:
	if Time.get_ticks_msec() < _deadline_msec:
		return false
	push_warning("ShaderWarmup: budget of %.1fs spent after %d of %d materials; continuing boot." % [
		time_budget_seconds, _warmed + _skipped, _total,
	])
	return true

#endregion

#region Frame Sync

## Applies one batch and returns how many objects the renderer confirms it rasterized. Zero means
## the batch never reached the rasterizer, whatever the frame counter says.
##
## The order is the whole point. [signal SceneTree.process_frame] fires [i]before[/i] the frame is
## drawn and [signal RenderingServer.frame_post_draw] fires after, so the work is applied in the
## gap between them and the result read once the draw is known to have finished. Reading render
## info any earlier reports the previous frame and quietly measures nothing.
func _submit(apply: Callable) -> int:
	await get_tree().process_frame
	apply.call()

	if not await _await_post_draw():
		return 0

	return _viewport.get_render_info(
		Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_OBJECTS_IN_FRAME)

## Waits for one completed draw, or gives up. An unbounded [code]await[/code] on a signal is the
## one construct here that could hang boot forever, so there is a deadline on it.
func _await_post_draw() -> bool:
	# Boxed in a dictionary because a lambda captures locals by value.
	var state := {"drawn": false}
	var callback := func() -> void: state["drawn"] = true
	RenderingServer.frame_post_draw.connect(callback, CONNECT_ONE_SHOT)

	var deadline := Time.get_ticks_msec() + batch_timeout_msec
	while not state["drawn"] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	if RenderingServer.frame_post_draw.is_connected(callback):
		RenderingServer.frame_post_draw.disconnect(callback)
	return state["drawn"]

## Draws a throwaway material before any real work, to prove the rig renders at all.
##
## Without this, a misconfigured viewport would sail through every batch drawing nothing and
## report a confident hundred percent. Better to warm nothing and say so.
func _self_test() -> bool:
	var probe := StandardMaterial3D.new()
	probe.albedo_color = Color.MAGENTA
	var objects := await _submit(func() -> void: _apply_spatial([probe] as Array[Material]))

	if objects <= 0:
		_apply_spatial([] as Array[Material])
		push_warning("ShaderWarmup: the offscreen rig drew nothing; skipping warmup entirely.")
		return false

	# Compatibility never populates the shadow counter -- it reads zero even for a textbook
	# shadow-casting setup -- so checking it there would warn on every single boot. The shadow
	# pass still runs; only the reporting is missing.
	if uses_pipeline_objects():
		if _viewport.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_OBJECTS_IN_FRAME) <= 0:
			push_warning("ShaderWarmup: no shadow pass ran; depth-pass variants will not be warmed.")

	# The same frame that hides the probe measures what the rig draws when idle. Every proxy is
	# hidden here, so what remains is the shadow catcher -- the floor a pairing pass has to beat to
	# prove it drew geometry of its own.
	_idle_objects = await _submit(func() -> void: _apply_spatial([] as Array[Material]))
	return true

#endregion

#region Rig

## Builds the offscreen scene everything is drawn into.
##
## [member SubViewport.own_world_3d] is the load-bearing line: without it these proxies and lights
## join the game's own [World3D] and show up in the level, and the level shows up in here.
##
## The structure is built once and never changed afterwards -- only [member
## GeometryInstance3D.material_override] is written per batch. Adding or moving a node defers its
## transform to the render server, which would race the very draw being waited on.
func _build_rig(manifest: ShaderWarmupManifest) -> void:
	_viewport = SubViewport.new()
	_viewport.name = "WarmupViewport"
	_viewport.size = viewport_size
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	# Not the default: a SubViewport with no SubViewportContainer is never "visible", so
	# UPDATE_WHEN_VISIBLE would mean it never draws at all.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	# Never let a proxy get culled or LOD'd out of the very draw that exists to compile it.
	_viewport.mesh_lod_threshold = 0.0
	_viewport.use_occlusion_culling = false
	_mirror_main_viewport()
	# The world has to be in place before the viewport enters the tree. Swapping it afterwards
	# leaves the render server briefly holding a null scenario and it complains.
	_build_environment(manifest)
	add_child(_viewport)

	_build_lights()
	_build_proxies()
	_build_pair_proxies()
	_build_camera()
	_build_special_proxies()

## Copies the antialiasing and sampling setup of the window. See the note in the class docs: a
## mismatch here makes Forward+ stutter rather than stop stuttering.
func _mirror_main_viewport() -> void:
	var root := get_tree().root
	if root == null:
		return
	_viewport.msaa_3d = root.msaa_3d
	_viewport.msaa_2d = root.msaa_2d
	_viewport.screen_space_aa = root.screen_space_aa
	_viewport.use_taa = root.use_taa
	_viewport.use_debanding = root.use_debanding
	_viewport.use_hdr_2d = root.use_hdr_2d
	_viewport.scaling_3d_mode = root.scaling_3d_mode
	_viewport.texture_mipmap_bias = root.texture_mipmap_bias
	_viewport.anisotropic_filtering_level = root.anisotropic_filtering_level
	_viewport.positional_shadow_atlas_size = root.positional_shadow_atlas_size

## Installs the project's own environment, so materials compile against the background mode,
## ambient source and fog gameplay actually uses rather than against engine defaults.
func _build_environment(manifest: ShaderWarmupManifest) -> void:
	if manifest != null and not manifest.environments.is_empty() and manifest.environments[0] != null:
		_environment = manifest.environments[0]
	else:
		_environment = Environment.new()
		_environment.background_mode = Environment.BG_SKY
		_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY

	if _environment.sky == null:
		_environment.sky = Sky.new()
	if _environment.sky.sky_material == null:
		_environment.sky.sky_material = ProceduralSkyMaterial.new()
	_sky = _environment.sky
	# Smallest radiance map that is still a real one: warming must exercise the ambient path
	# without paying for a cubemap nobody looks at.
	_sky.radiance_size = Sky.RADIANCE_SIZE_128
	_original_background_mode = _environment.background_mode
	_original_sky_material = _sky.sky_material

	# Built explicitly rather than reached through world_3d: own_world_3d makes the viewport *use*
	# a private world, but leaves the world_3d property itself null until something is put there,
	# so writing straight to it fails.
	var world := World3D.new()
	world.environment = _environment
	_viewport.world_3d = world

## Puts the project's own sky back after the sky bucket has been warmed, so spatial materials
## compile against the real ambient setup.
func _restore_sky() -> void:
	if _environment == null:
		return
	_environment.background_mode = _original_background_mode
	if _sky != null and _original_sky_material != null:
		_sky.sky_material = _original_sky_material

## A superset of the lights any level might use. The renderer picks a different shader variant for
## directional, omni and spot lighting, so warming only one of them leaves the other two for the
## player to discover. An over-warmed variant costs one draw call; a missing one is the bug.
func _build_lights() -> void:
	if warm_directional_light:
		var directional := DirectionalLight3D.new()
		directional.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
		directional.shadow_enabled = true
		_viewport.add_child(directional)

	if warm_omni_light:
		var omni := OmniLight3D.new()
		omni.position = Vector3(2.0, 2.0, -2.0)
		omni.omni_range = 12.0
		omni.shadow_enabled = true
		_viewport.add_child(omni)

	if warm_spot_light:
		var spot := SpotLight3D.new()
		spot.position = Vector3(-2.0, 2.5, -1.0)
		spot.rotation_degrees = Vector3(-60.0, 0.0, 0.0)
		spot.spot_range = 12.0
		spot.shadow_enabled = true
		_viewport.add_child(spot)

const PROXY_DISTANCE := 4.0
const PROXY_SPACING := 1.0

## A grid of boxes, plus a plane behind them.
##
## Boxes rather than quads or spheres: a BoxMesh supplies normals, tangents and UVs, and its six
## faces guarantee that some are lit and some are turned away, so both branches of a material get
## exercised. UV2 is generated because materials can put ambient occlusion or emission on it.
##
## The plane is not decoration. Something has to receive a shadow for the positional shadow atlas
## to be rendered, which is what makes the depth-pass variant compile -- and what makes the shadow
## render-info counter a usable signal in [method _self_test].
func _build_proxies() -> void:
	# Built through the vertex-format helper rather than inline, because the same box is what
	# _build_pairs measures every recorded format against. Two definitions of "the default proxy"
	# would drift and start warming pairings that were already covered.
	var mesh := ShaderWarmupVertexFormat.base_mesh()

	var columns := maxi(ceili(sqrt(float(maxi(max_batch_size, 1)))), 1)
	for slot in maxi(max_batch_size, 1):
		var proxy := MeshInstance3D.new()
		proxy.mesh = mesh
		proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		proxy.ignore_occlusion_culling = true
		proxy.position = Vector3(
			(float(slot % columns) - float(columns - 1) * 0.5) * PROXY_SPACING,
			(float(slot / columns) - float(columns - 1) * 0.5) * PROXY_SPACING,
			-PROXY_DISTANCE
		)
		proxy.visible = false
		_viewport.add_child(proxy)
		_proxies.append(proxy)

	var catcher := MeshInstance3D.new()
	catcher.name = "ShadowReceiver"
	var plane := PlaneMesh.new()
	plane.size = Vector2(20.0, 20.0)
	catcher.mesh = plane
	catcher.material_override = StandardMaterial3D.new()
	catcher.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	catcher.position = Vector3(0.0, -2.0, -PROXY_DISTANCE)
	_viewport.add_child(catcher)

## One proxy per distinct (vertex format, flags) among [member _pairs], built before anything is
## drawn and never touched again except through [member GeometryInstance3D.material_override].
##
## Built here rather than lazily during the run for the reason given on [method _build_rig]: adding
## a node defers its transform to the render server, which would race the very draw being waited on.
func _build_pair_proxies() -> void:
	for pair in _pairs:
		var key := _pair_key(pair)
		if _pair_proxies.has(key):
			continue

		var format: int = pair["format"]
		var mesh := ShaderWarmupVertexFormat.build_mesh(format)
		if mesh == null:
			push_warning("ShaderWarmup: no proxy mesh for vertex format %d (%s); skipping." % [
				format, pair["label"],
			])
			continue

		var proxy: GeometryInstance3D
		if pair["flags"] & ShaderWarmupManifest.PairFlags.MULTIMESH:
			proxy = _build_multimesh_proxy(mesh, pair["flags"])
		else:
			proxy = _build_mesh_proxy(mesh, format)
		proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		proxy.ignore_occlusion_culling = true
		proxy.visible = false
		_pair_proxies[key] = proxy

## A plain proxy, or a skinned one hung off a real [Skeleton3D].
##
## The skeleton is the point of the whole exercise. A mesh carrying bones and weights only takes
## the skinned vertex path when a skeleton is actually driving it -- assigning the mesh alone
## leaves the renderer compiling the unskinned variant, and the character still hitches on first
## draw while the warmup reports success.
func _build_mesh_proxy(mesh: ArrayMesh, format: int) -> MeshInstance3D:
	var proxy := MeshInstance3D.new()
	proxy.mesh = mesh

	if not ShaderWarmupVertexFormat.is_skinned(format):
		proxy.position = Vector3(0.0, 0.0, -PROXY_DISTANCE)
		_viewport.add_child(proxy)
		return proxy

	var skeleton := _ensure_skeleton(ShaderWarmupVertexFormat.bones_per_vertex(format))
	skeleton.add_child(proxy)
	# Every vertex is weighted to bone 0 at rest, so one bone is enough to select the path; the
	# rest exist to match the width the format declares.
	proxy.skeleton = ^".."
	proxy.skin = skeleton.create_skin_from_rest_transforms()
	return proxy

## Two instances rather than one, so the draw genuinely goes through the instanced path rather
## than being something the driver could collapse.
##
## The per-instance colour and custom-data channels are reproduced when the recorded pairing used
## them: both are specialization constants on Forward+ and Mobile and defines on Compatibility, so
## a shader that reads INSTANCE_CUSTOM compiles a different program from one that does not, and
## leaving them off here would report a warmed pipeline the first real draw does not have.
func _build_multimesh_proxy(mesh: ArrayMesh, flags: int) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = flags & ShaderWarmupManifest.PairFlags.MULTIMESH_COLORS != 0
	multimesh.use_custom_data = flags & ShaderWarmupManifest.PairFlags.MULTIMESH_CUSTOM_DATA != 0
	multimesh.mesh = mesh
	multimesh.instance_count = 2
	for instance in multimesh.instance_count:
		multimesh.set_instance_transform(instance,
			Transform3D(Basis(), Vector3(float(instance) * 0.8 - 0.4, 0.0, 0.0)))
		if multimesh.use_colors:
			multimesh.set_instance_color(instance, Color.WHITE)
		if multimesh.use_custom_data:
			multimesh.set_instance_custom_data(instance, Color(1.0, 0.0, 0.0, 0.0))

	var proxy := MultiMeshInstance3D.new()
	proxy.multimesh = multimesh
	proxy.position = Vector3(0.0, 0.0, -PROXY_DISTANCE)
	_viewport.add_child(proxy)
	return proxy

## The rig's skeleton, grown to [param bone_count] bones if it already exists with fewer.
func _ensure_skeleton(bone_count: int) -> Skeleton3D:
	if _skeleton == null:
		_skeleton = Skeleton3D.new()
		_skeleton.name = "WarmupSkeleton"
		_skeleton.position = Vector3(0.0, 0.0, -PROXY_DISTANCE)
		_viewport.add_child(_skeleton)

	while _skeleton.get_bone_count() < bone_count:
		var bone := _skeleton.add_bone("Bone%d" % _skeleton.get_bone_count())
		_skeleton.set_bone_rest(bone, Transform3D.IDENTITY)
		_skeleton.set_bone_pose_position(bone, Vector3.ZERO)
	return _skeleton

func _build_camera() -> void:
	var camera := Camera3D.new()
	_viewport.add_child(camera)
	camera.current = true

func _build_special_proxies() -> void:
	_canvas_proxy = ColorRect.new()
	_canvas_proxy.size = Vector2(32.0, 32.0)
	_canvas_proxy.visible = false
	_viewport.add_child(_canvas_proxy)

	_particle_proxy = GPUParticles3D.new()
	_particle_proxy.amount = 1
	_particle_proxy.lifetime = 1.0
	# Without a draw pass the process shader has nothing to feed and nothing gets drawn.
	var quad := QuadMesh.new()
	_particle_proxy.draw_pass_1 = quad
	_particle_proxy.position = Vector3(0.0, 0.0, -PROXY_DISTANCE)
	_particle_proxy.visible = false
	_particle_proxy.emitting = false
	_viewport.add_child(_particle_proxy)

func _teardown() -> void:
	_proxies.clear()
	_pairs.clear()
	_pair_proxies.clear()
	_skeleton = null
	_idle_objects = 0
	_canvas_proxy = null
	_particle_proxy = null
	_environment = null
	_sky = null
	_original_sky_material = null
	if is_instance_valid(_viewport):
		# Stopped before freeing, so it cannot draw during the frame it is being torn down in.
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_viewport.queue_free()
	_viewport = null

## Defensive: a run interrupted by the node being removed still cleans up its viewport.
func _exit_tree() -> void:
	if _viewport != null:
		_teardown()

#endregion

#region Helpers

func _label_for(material: Material) -> String:
	if material == null:
		return "<none>"
	if _labels.has(material):
		return _labels[material]
	if not material.resource_name.is_empty():
		return material.resource_name
	var path := material.resource_path
	if path.contains("::"):
		return path.get_slice("::", 1)
	if not path.is_empty():
		return path.get_file()
	return material.get_class()

#endregion
