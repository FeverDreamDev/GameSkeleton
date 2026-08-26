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
const TerrainGrassBlockerScript = preload("res://addons/procedural_terrain_grass/terrain_grass_blocker_3d.gd")
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


class BlockerNotificationSpy extends Node:
	var change_count: int = 0

	func notify_static_blocker_changed(_blocker: Node3D) -> void:
		change_count += 1

	func unregister_static_grass_blocker(_blocker: Node3D) -> void:
		pass


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _check_aabb(actual: AABB, expected: AABB, message: String) -> void:
	_check(
		actual.position.is_equal_approx(expected.position)
			and actual.size.is_equal_approx(expected.size),
		"%s (got %s, expected %s)" % [message, actual, expected])


func _drive_reflection_ground(terrain: Node3D, timeout_msec: int = 15000) -> bool:
	terrain.call(&"_update_reflection_ground")
	var deadline := Time.get_ticks_msec() + timeout_msec
	while terrain.get(&"_ground_bake_task") != -1 and Time.get_ticks_msec() < deadline:
		await process_frame
		terrain.call(&"_update_reflection_ground")
	return terrain.get(&"_ground_bake_task") == -1


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
	# Shadow belongs on the sun and nowhere near the ambient. Scaling the whole
	# lit value drops the reflected ground to black wherever the sun is occluded,
	# while the terrain and grass it stands in for stay plainly visible.
	_check(reference.contains("vec3 lit = albedo * (ambient.rgb + sun_radiance.rgb * sun);")
			and not reference.contains("dnc_cloud"),
		"shadow attenuates the sun only, leaving ambient intact")
	# Blade detail without the distance fade crawls: nothing in this renderer
	# filters temporally, and a mirror shows a lot of distance in few pixels.
	_check(reference.contains("clamp(1.0 - hit_distance / grass.w, 0.0, 1.0)"),
		"blade detail fades out with distance rather than shimmering")
	# sin() of a cell index in the thousands loses enough 32-bit precision to
	# print axis-aligned rectangles.
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
		"the blade hash mixes integers rather than calling trig")
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
	_check(effect.contains("const FRAME_UBO_FLOATS := 92"),
		"the frame UBO is sized for the six ground vec4s")
	_check(effect.contains("_set_frame_vec4(88,"),
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


func _check_blocker_bounds_and_notifications() -> void:
	var convex := ConvexPolygonShape3D.new()
	convex.points = PackedVector3Array([
		Vector3(-3.0, -2.0, -1.0),
		Vector3(4.0, -2.0, -1.0),
		Vector3(0.0, 5.0, -1.0),
		Vector3(0.0, 0.0, 6.0),
	])
	_check_aabb(
		TerrainGrassBlockerScript.shape_local_aabb(convex),
		AABB(Vector3(-3.0, -2.0, -1.0), Vector3(7.0, 7.0, 7.0)),
		"convex blocker bounds come from their actual points")

	var concave := ConcavePolygonShape3D.new()
	var faces := PackedVector3Array([
		Vector3(-4.0, -1.0, 2.0),
		Vector3(3.0, -1.0, 2.0),
		Vector3(0.0, 5.0, -6.0),
		Vector3(-4.0, -1.0, 2.0),
		Vector3(0.0, 5.0, -6.0),
		Vector3(1.0, 2.0, 1.0),
	])
	concave.set_faces(faces)
	_check_aabb(
		TerrainGrassBlockerScript.shape_local_aabb(concave),
		AABB(Vector3(-4.0, -1.0, -6.0), Vector3(7.0, 6.0, 8.0)),
		"concave blocker bounds come from their actual faces")
	_check_aabb(
		TerrainGrassBlockerScript.shape_local_aabb(ConvexPolygonShape3D.new()),
		AABB(),
		"empty complex geometry has empty bounds rather than a fake unit cube")

	# A built-in blocker no longer needs manager polling, so mutating its Shape3D
	# resource in place has to refresh the cache and notify the owner itself.
	var blocker = TerrainGrassBlockerScript.new()
	var spy := BlockerNotificationSpy.new()
	var blocker_host := Node3D.new()
	root.add_child(blocker_host)
	blocker_host.add_child(spy)
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 3.0, 4.0)
	blocker.blocker_shape = box
	blocker_host.add_child(blocker)
	blocker.set(&"_terrain_system", spy)
	box.size = Vector3(6.0, 7.0, 8.0)
	_check(spy.change_count > 0,
		"an in-place Shape3D edit explicitly notifies the terrain system")
	_check_aabb(
		blocker.get_world_aabb(),
		AABB(Vector3(-3.0, -3.5, -4.0), Vector3(6.0, 7.0, 8.0)),
		"an in-place Shape3D edit refreshes the cached blocker bounds")

	var notifications_before_transform := spy.change_count
	blocker.transform = Transform3D(
		Basis.from_euler(Vector3(0.31, -0.57, 0.19)).scaled(Vector3(1.5, 0.75, 2.0)),
		Vector3(8.0, -3.0, 11.0))
	blocker.force_update_transform()
	_check(spy.change_count > notifications_before_transform,
		"a blocker transform change explicitly notifies the terrain system")
	var transformed_bounds: AABB = blocker.get_world_aabb().grow(0.0001)
	var local_bounds := AABB(Vector3(-3.0, -3.5, -4.0), Vector3(6.0, 7.0, 8.0))
	for corner_index in 8:
		var corner := local_bounds.get_endpoint(corner_index)
		_check(transformed_bounds.has_point(blocker.transform * corner),
			"the transformed blocker AABB contains source corner %d" % corner_index)

	blocker_host.free()


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
	_check_blocker_bounds_and_notifications()

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
	terrain.max_grass_slope_degrees = 90.0
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
	_check(await _drive_reflection_ground(terrain), "the ground bake completes")
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

	# Force a dirty bake, then cross to OFF while its worker is in flight. The
	# first result is now stale and must never be published; one revision updates
	# the lightweight detail params and one publishes the replacement image.
	terrain.position = Vector3(7.0, 5.0, -11.0)
	terrain.reflection_ground_resolution = 96
	terrain.call(&"_update_reflection_ground")
	terrain.grass_quality = TerrainGrassScript.GrassQuality.OFF
	var revision_before_off := int(manager.get(&"_ground_revision"))
	_check(await _drive_reflection_ground(terrain),
		"an OFF transition replaces an in-flight reflection bake")
	var revision_after_off := int(manager.get(&"_ground_revision"))
	_check(revision_after_off - revision_before_off == 2,
		"an invalidated in-flight image is discarded rather than published")

	var off_layer: Dictionary = manager.get_ground_layer()
	var off_grass: Vector4 = off_layer.get("grass", Vector4.ZERO)
	_check(is_zero_approx(off_grass.y),
		"GrassQuality.OFF disables reflected blade detail")
	var off_texture: Texture2D = off_layer.get("texture")
	var off_image := off_texture.get_image() if off_texture != null else null
	_check(off_image != null and off_image.get_width() == 96,
		"the OFF transition publishes its replacement image")
	if off_image != null:
		var sample_pixel := Vector2i(48, 48)
		var off_pixel := off_image.get_pixel(sample_pixel.x, sample_pixel.y)
		var off_params: Vector4 = off_layer.get("params", Vector4.ZERO)
		var off_window_size := 1.0 / maxf(off_params.z, 0.000001)
		var off_texel_size := off_window_size / float(off_image.get_width())
		var sample_world_x := off_params.x + (float(sample_pixel.x) + 0.5) * off_texel_size
		var sample_world_z := off_params.y + (float(sample_pixel.y) + 0.5) * off_texel_size
		var translated_snapshot: Dictionary = terrain.call(&"_build_settings").snapshot()
		var translated_noise := TerrainGeneratorScript.create_noise(translated_snapshot)
		var expected_bare_height := TerrainGeneratorScript.sample_height(
			translated_noise,
			sample_world_x - terrain.global_position.x,
			sample_world_z - terrain.global_position.z,
			translated_snapshot) + terrain.global_position.y
		_check(absf(off_pixel.a - expected_bare_height) <= 0.0001,
			"OFF publishes translated bare-terrain height instead of stale canopy")
		_check(off_pixel.r + off_pixel.g + off_pixel.b > 0.000001,
			"OFF preserves bare-terrain colour instead of blending it to black")

	# Crossing back to an enabled tier must restore the same analytic canopy,
	# while changes among enabled tiers must stay image-bake-free.
	terrain.grass_quality = TerrainGrassScript.GrassQuality.HIGH
	_check(await _drive_reflection_ground(terrain),
		"returning from OFF restores reflected grass")
	var restored_layer: Dictionary = manager.get_ground_layer()
	var off_height_range: Vector4 = off_layer.get("bounds", Vector4.ZERO)
	var restored_height_range: Vector4 = restored_layer.get("bounds", Vector4.ZERO)
	var expected_canopy_height := float(terrain.grass_height) * float(terrain.grass_canopy_fill)
	var restored_minimum_delta := restored_height_range.x - off_height_range.x
	var restored_maximum_delta := restored_height_range.y - off_height_range.y
	_check(absf(restored_minimum_delta - expected_canopy_height) <= 0.0001
			and absf(restored_maximum_delta - expected_canopy_height) <= 0.0001,
		"returning from OFF restores the authored canopy height")
	_check(float(restored_layer.get("grass", Vector4.ZERO).y) > 0.0,
		"returning from OFF restores reflected blade detail")

	var enabled_tier_revision := int(manager.get(&"_ground_revision"))
	for quality in [
			TerrainGrassScript.GrassQuality.LOW,
			TerrainGrassScript.GrassQuality.MEDIUM,
			TerrainGrassScript.GrassQuality.HIGH,
	]:
		terrain.grass_quality = quality
		terrain.call(&"_update_reflection_ground")
		_check(terrain.get(&"_ground_bake_task") == -1,
			"changing among enabled grass tiers does not start a reflection bake")
	_check(int(manager.get(&"_ground_revision")) == enabled_tier_revision,
		"changing among enabled grass tiers does not republish reflection data")

	# Height and palette affect image pixels and therefore do rebake even when the
	# target has not moved. Detail controls ride beside the image and update once
	# without paying for another worker task.
	var height_range_before: Vector4 = restored_layer.get("bounds", Vector4.ZERO)
	terrain.grass_height += 0.2
	_check(await _drive_reflection_ground(terrain),
		"grass height dirties a stationary reflection window")
	var height_range_after: Vector4 = manager.get_ground_layer().get("bounds", Vector4.ZERO)
	var expected_height_delta := 0.2 * float(terrain.grass_canopy_fill)
	_check(absf((height_range_after.x - height_range_before.x) - expected_height_delta) <= 0.0001
			and absf((height_range_after.y - height_range_before.y) - expected_height_delta) <= 0.0001,
		"the dirty rebake publishes the changed grass height")

	var palette_revision := int(manager.get(&"_ground_revision"))
	terrain.grass_tip_color = Color(0.41, 0.63, 0.17)
	_check(bool(terrain.get(&"_reflection_ground_dirty")),
		"a grass palette change explicitly dirties the reflection image")
	_check(await _drive_reflection_ground(terrain),
		"a grass palette change rebakes a stationary reflection window")
	_check(int(manager.get(&"_ground_revision")) == palette_revision + 1,
		"a grass palette change publishes exactly one replacement image")

	var image_revision_before_params := int(manager.get(&"_ground_revision"))
	terrain.grass_density += 3.0
	terrain.reflection_grass_detail = 0.21
	terrain.reflection_grass_ramp_depth = 0.37
	terrain.call(&"_update_reflection_ground")
	_check(terrain.get(&"_ground_bake_task") == -1,
		"reflected blade parameters update without an image bake")
	var changed_grass: Vector4 = manager.get_ground_layer().get("grass", Vector4.ZERO)
	_check(absf(changed_grass.x - float(terrain.grass_density)) <= 0.001
			and absf(changed_grass.y - 0.21) <= 0.001
			and absf(changed_grass.z - 0.37) <= 0.001,
		"the lightweight reflection update publishes density, detail and ramp depth")
	_check(int(manager.get(&"_ground_revision")) == image_revision_before_params + 1,
		"the lightweight reflection update produces only one manager revision")

	var clean_revision := int(manager.get(&"_ground_revision"))
	for iteration in 4:
		terrain.call(&"_update_reflection_ground")
	_check(terrain.get(&"_ground_bake_task") == -1
			and int(manager.get(&"_ground_revision")) == clean_revision,
		"a clean stationary reflection window performs no repeated work")
	terrain.terrain_material_override = terrain.terrain_material_override
	terrain.grass_height = terrain.grass_height
	terrain.grass_density = terrain.grass_density
	terrain.grass_base_color = terrain.grass_base_color
	terrain.grass_tip_color = terrain.grass_tip_color
	terrain.call(&"_update_reflection_ground")
	_check(terrain.get(&"_ground_bake_task") == -1
			and int(manager.get(&"_ground_revision")) == clean_revision,
		"assigning unchanged reflection inputs remains free")

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
