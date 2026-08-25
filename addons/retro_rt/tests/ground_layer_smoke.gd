extends SceneTree

## Headless probe for the analytic ground layer: the drift guard over its two
## shader copies, the producer-to-manager handoff, the window geometry the march
## depends on, and the off-switch.
##
## The layer exists because streamed terrain is registered receiver-only, so its
## chunks never enter the acceleration structure, and shell grass is
## vertex-deformed and outside the managed contract entirely. Neither can be
## traced, so a reflection ray that misses the structure marches a published
## heightfield instead. That makes this test the only thing standing between the
## two copies of rt_ground_* and silent divergence.

const TerrainGrassScript = preload("res://addons/procedural_terrain_grass/terrain_grass_3d.gd")
const RTSceneManagerScript = preload("res://addons/retro_rt/scripts/RTSceneManager.gd")
const TerrainGeneratorScript = preload("res://addons/procedural_terrain_grass/core/terrain_generator.gd")

## rt_ground_* is duplicated across the hardware and software backends for the
## same reason rt_fog_factor is: an RDShaderFile cannot include a .gdshaderinc.
const CANONICAL_COPIES := [
	"res://addons/retro_rt/shaders/rt_shadow_reflect.glsl",
	"res://addons/retro_rt/shaders/BlinnPhongSoftwareBody.gdshaderinc",
]
const CANONICAL_START := "// Canonical Retro RT analytic ground layer."
const CANONICAL_END := "vec3 rt_ground_shade("

var _failures := PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _extract_canonical(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var lines := file.get_as_text().split("\n")
	var collecting := false
	var closed := false
	var block := ""
	for line: String in lines:
		if not collecting and line.begins_with(CANONICAL_START):
			collecting = true
		if not collecting:
			continue
		block += line + "\n"
		if line.begins_with(CANONICAL_END):
			closed = true
		if closed and line == "}":
			break
	return block


func _check_canonical_block() -> void:
	var reference := _extract_canonical(CANONICAL_COPIES[0])
	_check(not reference.is_empty(),
		"the canonical ground block is found in %s" % CANONICAL_COPIES[0])
	if reference.is_empty():
		return
	_check(reference.contains("rt_ground_sample")
			and reference.contains("rt_ground_window")
			and reference.contains("rt_ground_normal")
			and reference.contains("rt_ground_trace")
			and reference.contains("rt_ground_blade_detail")
			and reference.contains("rt_ground_shade"),
		"the canonical block holds every function it is supposed to")
	# Hand-blended fetches are load-bearing twice over: the two backends have to
	# agree bit for bit and drivers round filtering differently, and a point
	# sampled field is a staircase that catches grazing rays on its risers and
	# paints the reflection in flat plateaus.
	_check(reference.contains("texelFetch(ground_map,")
			and not reference.contains("textureLod(")
			and not reference.contains("texture(ground_map"),
		"the ground layer fetches texels rather than letting a sampler filter them")
	_check(reference.contains("vec2 blend = fract(texel_position);")
			and reference.contains("return mix(near_row, far_row, blend.y);"),
		"the height field is blended, so a grazing ray does not terrace")
	# Without the window test every mirror pixel pointing at sky would still pay
	# for a march. This early-out is the whole reason the layer is affordable.
	_check(reference.contains("rt_ground_window(")
			and reference.contains("return exit_distance > enter_distance;"),
		"a reflection that never reaches the ground is rejected before marching")
	# The reflected ground has to fade to the same flat radiance the primary view
	# fades terrain to, or ground and sky meet with a seam inside the mirror.
	_check(reference.contains("rt_fog_factor(fog_params, hit_distance)"),
		"a ground hit fades on the shared fog curve, by its own ray distance")
	# Trace and shade are separate calls precisely so the sun-visibility ray can
	# sit between them in backend-specific code. Folding them back together would
	# take the shadow with it, because a traceRayEXT cannot live in this block.
	_check(reference.contains("float sun_visibility) {")
			and reference.contains("n_dot_l * sun_visibility"),
		"a shaded ground hit takes the caller's sun visibility")
	# Both shadow terms belong on the sun and nowhere near the ambient. Scaling
	# the whole lit value drops the reflected ground to black under an overcast
	# sky while the terrain and grass it stands in for stay plainly visible.
	_check(reference.contains("vec3 lit = albedo * (ambient.rgb + sun_radiance.rgb * sun);")
			and not reference.contains("lit *= 1.0 - dnc_cloud_shadow"),
		"cloud and ray shadows attenuate the sun only, leaving ambient intact")
	# Blade detail without the distance fade crawls: nothing in this renderer
	# filters temporally, and a mirror shows a lot of distance in few pixels.
	_check(reference.contains("clamp(1.0 - hit_distance / grass.w, 0.0, 1.0)"),
		"blade detail fades out with distance rather than shimmering")
	# sin() of a cell index in the thousands loses enough 32-bit precision to
	# print axis-aligned rectangles, which is why the cloud layer avoids it too.
	# Scanned with comments stripped: the comment explaining the rule names the
	# function it forbids.
	var code := ""
	for line in reference.split("\n"):
		var text: String = line.strip_edges()
		if not text.begins_with("//"):
			code += text
	_check(not code.contains("sin(") and not code.contains("cos("),
		"the blade hash uses no trigonometry")
	_check(code.contains("vec3(0.1031, 0.1030, 0.0973)"),
		"the blade hash mixes integers the way the cloud hash does")
	for index in range(1, CANONICAL_COPIES.size()):
		var path: String = CANONICAL_COPIES[index]
		var copy := _extract_canonical(path)
		_check(copy == reference, "%s carries the canonical ground block verbatim" % path)


## Both backends have to declare the layer, or one of them silently keeps
## resolving its reflection misses against the sky alone.
func _check_backend_bindings() -> void:
	var hardware := _read_text("res://addons/retro_rt/shaders/rt_shadow_reflect.glsl")
	_check(hardware.contains("layout(set = 0, binding = 22) uniform sampler2D ground_map;"),
		"the hardware shader binds the ground map")
	for field in ["ground_params", "ground_bounds", "ground_sun_direction",
			"ground_sun_radiance", "ground_ambient", "ground_grass"]:
		_check(hardware.contains("vec4 %s;" % field),
			"the hardware FrameData carries %s" % field)
	var software := _read_text("res://addons/retro_rt/shaders/BlinnPhongSoftwareBody.gdshaderinc")
	_check(software.contains("uniform sampler2D swrt_ground_map"),
		"the software shader declares the ground map")
	_check(software.contains("filter_nearest"),
		"the software ground sampler is unfiltered, matching the hardware fetch")
	for field in ["swrt_ground_params", "swrt_ground_bounds", "swrt_ground_sun_direction",
			"swrt_ground_sun_radiance", "swrt_ground_ambient", "swrt_ground_grass"]:
		_check(software.contains("uniform vec4 %s" % field),
			"the software path declares %s" % field)
	# The frame UBO is std140 and every field is a vec4, so the float count has
	# to keep pace with the struct or the tail reads garbage.
	var effect := _read_text("res://addons/retro_rt/scripts/RTLightingEffect.gd")
	_check(effect.contains("const FRAME_UBO_FLOATS := 104"),
		"the frame UBO is sized for the six ground vec4s")
	_check(effect.contains("_set_frame_vec4(100,"),
		"the last ground vec4 is packed at the offset the struct puts it")
	# The shadow ray deliberately lives outside the canonical block, one copy per
	# backend, so nothing but this notices when only one of them grows it. Both
	# traverse with mask 1, which is the shadow bit; the reflection bit is 2 and
	# would let the ray through anything registered reflection-visible only.
	_check(hardware.contains("rt_ground_trace(") and hardware.contains("rt_ground_shade("),
		"the hardware path traces the ground and shades it separately")
	_check(hardware.contains("frame.ground_sun_direction.xyz,")
			and hardware.contains("sun_visibility = payload.instance_id == NO_REFLECTION_HIT ? 1.0 : 0.0;"),
		"the hardware path traces a sun-visibility ray from its ground hit")
	_check(software.contains("rt_ground_trace(") and software.contains("rt_ground_shade("),
		"the software path traces the ground and shades it separately")
	_check(software.contains("swrt_ground_sun_direction.xyz,")
			and software.contains("sun_visibility = ground_obstructed ? 0.0 : 1.0;"),
		"the software path traces a sun-visibility ray from its ground hit")


## The one rule the terrain palette has to obey is that the ground disappears
## under the canopy, and it is authored in scene-linear radiance to obey it.
## An sRGB hex swatch pasted into any of the three arrives roughly an order of
## magnitude too bright and paints that slope straight through the blades, which
## is exactly what happened to terrain_steep_color once. Compare luminances
## rather than the literals so a re-measured palette still passes.
func _check_terrain_palette() -> void:
	var settings := TerrainGrassScript.new()
	var snapshot: Dictionary = settings.call(&"_build_settings").snapshot()
	var flat := TerrainGeneratorScript.terrain_color(0.0, 1.0, snapshot)
	var steep := TerrainGeneratorScript.terrain_color(
		0.0, float(snapshot["terrain_steep_normal_y"]) - 0.2, snapshot)
	var flat_luminance := flat.r * 0.2126 + flat.g * 0.7152 + flat.b * 0.0722
	var steep_luminance := steep.r * 0.2126 + steep.g * 0.7152 + steep.b * 0.0722
	_check(flat_luminance > 0.0 and steep_luminance <= flat_luminance * 3.0,
		"steep terrain is not brighter than flat terrain can hide (%.4f vs %.4f)"
			% [steep_luminance, flat_luminance])
	settings.free()


## The software copy is compiled by every test that renders a frame, but the
## hardware copy is only ever built by the importer, so nothing else in a
## headless run would notice it stopped compiling. Reads the imported artifact,
## which means it reports on the last import rather than on the file as it sits
## right now: reimport before trusting a failure here.
func _check_hardware_shader_compiles() -> void:
	var file := load("res://addons/retro_rt/shaders/rt_shadow_reflect.glsl") as RDShaderFile
	_check(file != null, "the hardware ray tracing shader loads as an RDShaderFile")
	if file == null:
		return
	for version in file.get_version_list():
		var spirv := file.get_spirv(version)
		_check(spirv != null, "the hardware shader has SPIR-V for version %s" % version)
		if spirv == null:
			continue
		for stage in [RenderingDevice.SHADER_STAGE_RAYGEN, RenderingDevice.SHADER_STAGE_MISS,
				RenderingDevice.SHADER_STAGE_CLOSEST_HIT]:
			var compile_error := spirv.get_stage_compile_error(stage)
			_check(compile_error.is_empty(),
				"hardware shader stage %d compiles: %s" % [stage, compile_error])


func _run() -> void:
	_check_canonical_block()
	_check_backend_bindings()
	_check_hardware_shader_compiles()
	_check_terrain_palette()

	var world := Node3D.new()
	world.name = "GroundLayerSmokeWorld"
	root.add_child(world)

	var manager := RTSceneManagerScript.new()
	manager.name = "RTSceneManager"
	manager.auto_start = false
	world.add_child(manager)

	# A plain Node3D stands in for the player: the layer follows whatever the
	# terrain streams around, and nothing here needs it to move.
	var target := Node3D.new()
	target.name = "Target"
	target.position = Vector3(12.0, 0.0, -34.0)
	world.add_child(target)

	var terrain: Node3D = TerrainGrassScript.new()
	terrain.name = "TerrainGrass3D"
	terrain.auto_start = false
	terrain.editor_preview_enabled = false
	terrain.streaming_target = target
	terrain.terrain_load_distance = 64.0
	terrain.reflection_ground_resolution = 64
	terrain.rt_scene_manager_path = NodePath("../RTSceneManager")
	world.add_child(terrain)

	_check(manager.has_method(&"configure_ground_layer"),
		"the manager exposes configure_ground_layer for a producer to call")
	_check(manager.has_method(&"get_ground_layer"),
		"the manager exposes get_ground_layer for a consumer to read")
	_check(manager.has_method(&"configure_ground_grass"),
		"the manager exposes configure_ground_grass for a producer to call")

	# Drive the producer directly rather than waiting on streaming, so the test
	# stays about the layer rather than about chunk scheduling.
	terrain.call(&"_update_reflection_ground")
	var deadline := Time.get_ticks_msec() + 15000
	while terrain.get(&"_ground_bake_task") != -1 and Time.get_ticks_msec() < deadline:
		await process_frame
		terrain.call(&"_update_reflection_ground")
	_check(terrain.get(&"_ground_bake_task") == -1, "the ground bake completes")
	_check(terrain.get(&"_ground_layer_published"), "the producer publishes its ground layer")

	var layer: Dictionary = manager.get_ground_layer()
	var texture: Texture2D = layer.get("texture")
	_check(texture != null, "the manager holds a ground texture")
	if texture != null:
		_check(texture.get_width() == 64 and texture.get_height() == 64,
			"the published texture is the resolution the producer asked for")
		var image := texture.get_image()
		_check(image != null and image.get_format() == Image.FORMAT_RGBAF,
			"the ground layer is RGBA32F, so canopy heights survive unclamped")

	# The window has to map onto the world exactly, or the march samples the
	# wrong ground and the reflection slides against the terrain it mirrors.
	var expected_window := 64.0 * 2.0 * float(terrain.reflection_ground_margin)
	var params: Vector4 = layer.get("params", Vector4.ZERO)
	var bounds: Vector4 = layer.get("bounds", Vector4.ZERO)
	_check(absf(1.0 / maxf(params.z, 0.000001) - expected_window) <= 0.01,
		"the window spans the load distance plus its margin")
	_check(absf(params.x - (target.position.x - expected_window * 0.5)) <= expected_window,
		"the window is centred on the streaming target")
	_check(bounds.y > bounds.x,
		"the height range bounds the data, which is what lets a ray skip the march")
	_check(bounds.w > 0.0, "the texel size is published for the normal's differences")
	# Blade detail rides beside the layer rather than inside it, so a producer
	# that publishes ground but forgets its grass leaves the reflection flat.
	var grass: Vector4 = layer.get("grass", Vector4.ZERO)
	_check(absf(grass.x - float(terrain.grass_density)) <= 0.001,
		"reflected blades are laid on the same pitch the real ones are")
	_check(grass.y > 0.0, "the producer publishes a blade detail strength")
	_check(absf(grass.w - float(terrain.terrain_load_distance)) <= 0.001,
		"the detail fades out by the distance the ground layer stops standing in for")
	# Canopy heights are routinely negative; a Color-backed write would clamp
	# them to zero and flatten every valley in the reflection.
	_check(bounds.x < 0.0,
		"negative canopy heights survive the bake, so valleys are not flattened")

	# The step count is a ray budget the manager owns, not something the terrain
	# chooses, and zero has to leave the miss path exactly as it was.
	_check(absf(params.w - float(manager.ground_march_steps)) <= 0.001,
		"the manager fills in its own march step count")
	manager.ground_march_steps = 0
	terrain.call(&"_update_reflection_ground")
	await process_frame
	_check(int(manager.get_ground_layer().get("params", Vector4.ZERO).w) == 0,
		"a zero step count disables the layer without unpublishing the texture")

	# Turning the producer off has to retract the layer, not just stop updating.
	terrain.reflection_ground_enabled = false
	terrain.call(&"_update_reflection_ground")
	await process_frame
	_check(manager.get_ground_layer().get("texture") == null,
		"disabling the producer retracts the layer")

	world.queue_free()
	await process_frame

	if _failures.is_empty():
		print("ground_layer_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("ground_layer_smoke FAIL: %s" % failure)
	printerr("ground_layer_smoke: %d failure(s)" % _failures.size())
	quit(1)
