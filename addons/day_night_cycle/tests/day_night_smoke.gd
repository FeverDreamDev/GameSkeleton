extends SceneTree

## Headless probe for the day/night cycle: the clock and its rollover, the
## sun/moon arc, the light handover at the terminator, the Retro RT registration
## contract the cloud casters depend on, the Environment push, and save/load.
##
## Runs against a bare scene rather than the game level, so a failure here is
## the add-on rather than the level wiring.

var _failures := PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _close(actual: float, expected: float, tolerance: float, message: String) -> void:
	_check(absf(actual - expected) <= tolerance,
		"%s (got %.4f, expected %.4f +/- %.4f)" % [message, actual, expected, tolerance])


func _run() -> void:
	var world := Node3D.new()
	world.name = "DayNightSmokeWorld"
	root.add_child(world)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.1, 0.1, 0.1)
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_exposure = 1.0
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	world.add_child(world_environment)

	var ambient_material := ShaderMaterial.new()
	ambient_material.shader = load(
		"res://addons/retro_rt/shaders/BlinnPhong.gdshader") as Shader
	var authored_ambient := Color(0.2, 0.22, 0.26, 1.0)
	ambient_material.set_shader_parameter(&"ambient_light", authored_ambient)

	var cycle := DayNightCycle3D.new()
	cycle.name = "DayNightCycle3D"
	cycle.world_environment_path = NodePath("../WorldEnvironment")
	cycle.day_length_seconds = 60.0
	cycle.start_time_of_day = 12.0
	cycle.time_running = false
	cycle.cloud_coverage = 0.5
	var tinted: Array[ShaderMaterial] = [ambient_material]
	cycle.ambient_materials = tinted
	world.add_child(cycle)
	await process_frame

	_check_canonical_block()
	_check_scene_contract(cycle)
	_check_cloud_layer(cycle)
	_check_arc(cycle)
	await _check_lights(cycle)
	await _check_clock(cycle)
	await _check_environment_push(cycle, environment)
	await _check_material_ambient(cycle, ambient_material, authored_ambient)
	await _check_persistence(cycle)

	world.queue_free()
	await process_frame
	_finish()



## The cloud field used to be duplicated byte-identically across five shaders so
## every surface could resolve its own shadow from it. The shadow is gone and so
## are the copies -- clouds are drawn by the sky and nowhere else -- but the
## properties below are still load-bearing for how the field looks, and still
## easy to undo by accident.
const CANONICAL_COPIES := [
	"res://addons/day_night_cycle/shaders/day_night_sky_common.gdshaderinc",
]
const CANONICAL_START := "// The cloud layer."
const CANONICAL_END := "float dnc_cloud_density("


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


## Isolates one function out of the block, so a check can be aimed at the part
## it actually means.
func _function_body(block: String, function_name: String) -> String:
	var body := ""
	var inside := false
	for line: String in block.split("
"):
		if line.contains(" %s(" % function_name) and line.ends_with("{"):
			inside = true
		if not inside:
			continue
		body += line + "
"
		if line == "}":
			break
	return body


## The block explains in prose which hash it deliberately avoids, so the checks
## below have to read the code rather than the comments.
func _code_of(block: String) -> String:
	var code := ""
	for line: String in block.split("
"):
		if not line.strip_edges().begins_with("//"):
			code += line + "
"
	return code


func _check_canonical_block() -> void:
	var reference := _extract_canonical(CANONICAL_COPIES[0])
	_check(not reference.is_empty(),
		"the cloud block is found in %s" % CANONICAL_COPIES[0])
	if reference.is_empty():
		return
	_check(reference.contains("dnc_cloud_hash")
			and reference.contains("dnc_cloud_field")
			and reference.contains("dnc_cloud_density"),
		"the cloud block holds every function it is supposed to")
	_check(not reference.contains("dnc_cloud_shadow"),
		"the shadow function is gone, not merely unused")
	# Both of these are load-bearing and easy to undo by accident.
	# Only the hash: dnc_cloud_gradient turns a hash into an angle and does call
	# sin, which is safe because the argument is bounded to one turn.
	_check(not _code_of(_function_body(reference, "dnc_cloud_hash")).contains("sin("),
		"the cloud hash calls no trig, which is what keeps it stable far out")
	# The hash scales its three components by three distinct constants. Using one
	# constant leaves the third equal to the first, because the input is only two
	# dimensional, and the correlated gradients draw straight streaks across the
	# sky at grazing angles.
	_check(_code_of(_function_body(reference, "dnc_cloud_hash"))
			.contains("vec3(0.1031, 0.1030, 0.0973)"),
		"the cloud hash decorrelates its components with distinct multipliers")
	_check(_code_of(reference).contains("dnc_cloud_gradient"),
		"the field is gradient noise, which has no lattice-aligned iso-contours")
	_check(_code_of(reference).contains("fraction * (fraction * 6.0 - 15.0) + 10.0"),
		"the noise interpolation is quintic, not cubic")
	for index in range(1, CANONICAL_COPIES.size()):
		var path: String = CANONICAL_COPIES[index]
		var copy := _extract_canonical(path)
		_check(copy == reference, "%s carries the canonical cloud block verbatim" % path)


## The cycle adds no ray-visible geometry at all any more. Clouds are a layer in
## the sky shader, so nothing here can dirty an acceleration structure.
func _check_scene_contract(cycle: DayNightCycle3D) -> void:
	var sky := cycle.get_node_or_null("SkyDome") as MeshInstance3D
	_check(sky != null, "the cycle builds a sky dome")
	if sky != null:
		_check(not sky.is_in_group(&"retro_rt_managed"),
			"the sky dome is unmanaged, so it is invisible to rays and never fogged")
		_check(sky.top_level, "the sky dome is top level so it can follow the camera")
		_check(sky.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"the sky dome casts nothing")

	var managed := 0
	for child: Node in cycle.get_children():
		if child.is_in_group(&"retro_rt_managed"):
			managed += 1
	_check(managed == 0,
		"the cycle owns no ray-visible geometry (found %d)" % managed)


## The layer is the contract: two vectors, one flat plane, and a shadow that
## every surface resolves for itself from the same numbers.
func _check_cloud_layer(cycle: DayNightCycle3D) -> void:
	cycle.set_time_of_day(12.0)
	var to_sun := cycle.get_direction_to_sun()
	# There is no camera in this scene, so the cycle probes from its own origin.
	var above := cycle.global_position

	cycle.set_cloud_coverage(0.0)
	cycle._update_visuals(0.0)
	_close(cycle.get_sun_occlusion(), 0.0, 0.0001, "a clear sky casts no shadow")

	cycle.set_cloud_coverage(1.0)
	cycle._update_visuals(0.0)
	_close(cycle.get_sun_occlusion(), 1.0, 0.0001, "a covered sky shadows everything")

	# Partial cover has to actually vary across the world, or the layer is a
	# constant and the whole point of resolving it per surface is lost.
	cycle.set_cloud_coverage(0.5)
	var lowest := 1.0
	var highest := 0.0
	for step in 64:
		var probe := Vector3(float(step) * 137.0, 2.0, float(step) * 61.0)
		var density: float = cycle._cloud_density_at(Vector2(probe.x, probe.z))
		lowest = minf(lowest, density)
		highest = maxf(highest, density)
	_check(highest - lowest > 0.5,
		"partial cover varies across the world (spread %.3f)" % (highest - lowest))

	# The shadow is resolved by intersecting the sun ray with the layer, so a
	# point directly under a gap and the gap itself have to agree.
	var travel := (cycle.cloud_altitude - above.y) / to_sun.y
	var hit := Vector2(above.x + to_sun.x * travel, above.z + to_sun.z * travel)
	cycle._update_visuals(0.0)
	_close(cycle._cloud_density_at(hit), cycle.get_sun_occlusion(), 0.0001,
		"the reported occlusion is the density where the sun ray crosses the layer")

	# A sun below the horizon must not cast a cloud shadow up from underneath.
	cycle.set_time_of_day(0.0)
	cycle._update_visuals(0.0)
	_close(cycle.get_sun_occlusion(), 0.0, 0.0001, "no cloud shadow at night")

	cycle.set_time_of_day(12.0)
	cycle.set_cloud_coverage(0.5)


func _check_arc(cycle: DayNightCycle3D) -> void:
	cycle.set_time_of_day(6.0)
	_close(cycle.get_direction_to_sun().y, 0.0, 0.02, "the sun is on the horizon at 06:00")
	_check(cycle.get_direction_to_sun().x > 0.9, "the sun rises in the east")

	cycle.set_time_of_day(12.0)
	_check(cycle.get_sun_elevation() > deg_to_rad(60.0), "the sun is high at noon")
	_check(cycle.get_direction_to_sun().y < 0.999,
		"the tilt keeps the sun off the exact zenith, so shadows sweep")

	cycle.set_time_of_day(18.0)
	_close(cycle.get_direction_to_sun().y, 0.0, 0.02, "the sun is on the horizon at 18:00")
	_check(cycle.get_direction_to_sun().x < -0.9, "the sun sets in the west")

	cycle.set_time_of_day(0.0)
	_check(cycle.get_sun_elevation() < deg_to_rad(-60.0), "the sun is down at midnight")
	_check(cycle.get_moon_elevation() > deg_to_rad(60.0), "the moon is up at midnight")

	for hour in [0.0, 4.0, 9.0, 15.0, 21.5]:
		cycle.set_time_of_day(hour)
		var opposed := cycle.get_direction_to_sun() + cycle.get_direction_to_moon()
		_check(opposed.length() < 0.0001,
			"the moon stays opposite the sun at %.1fh" % hour)


## RTSceneManager gives its single shadow ray to the strongest shadow-enabled
## light, so the handover from sun to moon has to happen through their energies
## rather than through an explicit switch.
func _check_lights(cycle: DayNightCycle3D) -> void:
	var sun := cycle.get_sun_light()
	var moon := cycle.get_moon_light()
	_check(sun != null and moon != null, "the cycle owns a sun and a moon light")
	if sun == null or moon == null:
		return
	_check(sun.shadow_enabled and moon.shadow_enabled,
		"both lights have shadows enabled, which is the RT-shadow toggle")

	cycle.set_time_of_day(12.0)
	await process_frame
	_check(sun.light_energy > moon.light_energy,
		"the sun is the strongest shadow caster at noon")
	_check(cycle.get_moon_light_energy() <= 0.0001,
		"the moon contributes nothing while it is down")

	cycle.set_time_of_day(0.0)
	await process_frame
	_check(moon.light_energy > sun.light_energy,
		"the moon is the strongest shadow caster at midnight")
	_check(cycle.get_sun_light_energy() <= 0.0001,
		"the sun contributes nothing while it is down")
	# The moon is deliberately generous against a physical one, because this
	# project grades with raised contrast and no global illumination and a faint
	# moon renders an unplayable night. It still has to be strictly dimmer than
	# the sun, or night stops reading as night.
	_check(moon.light_energy < cycle.palette.sun_peak_energy * 0.9,
		"the moon is a dim sun rather than a second one")

	# +Z is the direction towards the light, which is how RTSceneManager reads a
	# DirectionalLight3D. A sign error here would light the world from below.
	var to_moon := cycle.get_direction_to_moon()
	_check(moon.global_transform.basis.z.dot(to_moon) > 0.999,
		"the moon light points at the moon")
	cycle.set_time_of_day(12.0)
	await process_frame
	_check(sun.global_transform.basis.z.dot(cycle.get_direction_to_sun()) > 0.999,
		"the sun light points at the sun")


func _check_clock(cycle: DayNightCycle3D) -> void:
	cycle.set_day_number(0)
	cycle.set_time_of_day(23.0)
	var day_before := cycle.get_day_number()
	var rolled := [false]
	var on_day := func(_day: int) -> void:
		rolled[0] = true
	cycle.day_changed.connect(on_day)

	cycle.advance_time(2.0)
	_close(cycle.get_time_of_day(), 1.0, 0.0001, "the clock wraps past midnight")
	_check(cycle.get_day_number() == day_before + 1, "crossing midnight rolls the day")
	_check(rolled[0], "crossing midnight emits day_changed")

	cycle.advance_time(-3.0)
	_close(cycle.get_time_of_day(), 22.0, 0.0001, "the clock wraps backwards")
	_check(cycle.get_day_number() == day_before, "going back past midnight unrolls the day")
	cycle.day_changed.disconnect(on_day)

	# Setting the hour directly must not disturb the day, and with it the sky.
	cycle.set_time_of_day(3.0)
	_check(cycle.get_day_number() == day_before, "setting the hour leaves the day alone")

	_close(cycle.get_normalized_time(), 3.0 / 24.0, 0.0001, "normalized time tracks the hour")
	cycle.set_normalized_time(0.5)
	_close(cycle.get_time_of_day(), 12.0, 0.0001, "normalized time can be set")

	# The cycle length is meant to be live-adjustable.
	cycle.set_day_length_seconds(24.0)
	cycle.set_time_running(true)
	cycle.set_time_of_day(6.0)
	var before := cycle.get_time_of_day()
	for _frame in 10:
		await process_frame
	_check(cycle.get_time_of_day() > before, "a running clock advances")
	cycle.set_time_running(false)
	var held := cycle.get_time_of_day()
	for _frame in 5:
		await process_frame
	_close(cycle.get_time_of_day(), held, 0.0001, "a stopped clock holds")
	cycle.set_day_length_seconds(60.0)


## The Environment stays flat and its background colour is the horizon, because
## that value is what RTSceneManager resolves its distance fog to.
func _check_environment_push(cycle: DayNightCycle3D, environment: Environment) -> void:
	cycle.set_time_of_day(12.0)
	for _frame in 3:
		await process_frame
	var noon := environment.background_color
	_check(environment.background_mode == Environment.BG_COLOR,
		"the background stays flat, so no sky panorama is ever baked")
	_check(noon.is_equal_approx(cycle.get_horizon_color()),
		"the background colour is the horizon colour")
	_check(environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR,
		"ambient comes from the palette, not from the background")
	var noon_ambient_energy := environment.ambient_light_energy

	cycle.set_time_of_day(0.0)
	for _frame in 3:
		await process_frame
	var midnight := environment.background_color
	_check(not midnight.is_equal_approx(noon), "the horizon changes with the time of day")
	_check(midnight.get_luminance() < noon.get_luminance(), "midnight is darker than noon")
	_check(environment.ambient_light_energy < noon_ambient_energy,
		"ambient falls at night")

	# A still sky must not churn the renderer: an Environment write costs an RT
	# environment revision and a distance_fog_changed on every subscriber.
	var settled := environment.background_color
	for _frame in 10:
		await process_frame
	_check(environment.background_color.is_equal_approx(settled),
		"a stopped clock pushes no further Environment writes")


## Managed Blinn-Phong surfaces take ambient from a per-material uniform, so the
## ramp has to reach them separately from the Environment.
func _check_material_ambient(
		cycle: DayNightCycle3D,
		material: ShaderMaterial,
		authored: Color) -> void:
	cycle.set_time_of_day(12.0)
	await process_frame
	var noon: Color = material.get_shader_parameter(&"ambient_light")
	_check(noon.is_equal_approx(authored),
		"a hand-tuned material is left exactly as authored at noon")

	cycle.set_time_of_day(0.0)
	await process_frame
	var midnight: Color = material.get_shader_parameter(&"ambient_light")
	_check(midnight.get_luminance() < noon.get_luminance() * 0.5,
		"material ambient falls well below daylight at night")
	_check(midnight.b / maxf(midnight.r, 0.0001) > noon.b / maxf(noon.r, 0.0001),
		"night ambient shifts blue")

	cycle.unregister_ambient_material(material)
	var restored: Color = material.get_shader_parameter(&"ambient_light")
	_check(restored.is_equal_approx(authored),
		"unregistering hands the material back exactly as authored")
	cycle.register_ambient_material(material)


func _check_persistence(cycle: DayNightCycle3D) -> void:
	cycle.set_day_number(7)
	cycle.set_time_of_day(17.25)
	cycle.set_cloud_coverage(0.3)
	var saved := cycle.save_state()
	_check(saved.has("time_of_day") and saved.has("day_number"),
		"the save payload carries the clock and the day")

	cycle.set_day_number(0)
	cycle.set_time_of_day(2.0)
	cycle.set_cloud_coverage(1.0)
	await process_frame

	cycle.load_state(saved)
	_close(cycle.get_time_of_day(), 17.25, 0.0001, "load restores the hour")
	_check(cycle.get_day_number() == 7, "load restores the day")
	_close(cycle.get_cloud_coverage(), 0.3, 0.0001, "load restores cloud cover")

	# The day number is the seed for the stars and the cloud field, so restoring
	# it has to reproduce the same sky rather than merely the same clock.
	var restored: float = cycle.get_sky_state()["cloud_seed"]
	cycle.set_day_number(3)
	cycle.set_day_number(7)
	var replayed: float = cycle.get_sky_state()["cloud_seed"]
	_check(is_equal_approx(replayed, restored),
		"the same day reproduces the same cloud field")

	# Pace is authored configuration, not world state. A save that still carries
	# it -- every save written before this rule existed does -- must not put the
	# old rate back, or retuning the cycle in the inspector silently does nothing
	# and the sun keeps crawling at whatever the save remembered.
	cycle.set_day_length_seconds(120.0)
	cycle.set_time_scale(2.0)
	cycle.set_time_running(true)
	cycle.load_state({
		"time_of_day": 6.0,
		"day_number": 3,
		"day_length_seconds": 1200.0,
		"time_scale": 1.0,
		"time_running": false,
	})
	_close(cycle.day_length_seconds, 120.0, 0.0001,
		"a save does not overwrite the authored day length")
	_close(cycle.time_scale, 2.0, 0.0001, "a save does not overwrite the time scale")
	_check(cycle.time_running, "a save does not overwrite whether the clock runs")
	_close(cycle.get_time_of_day(), 6.0, 0.0001, "the hour still comes from the save")

	# A partial payload must not throw: GameApp tolerates saves written before
	# this node existed.
	cycle.load_state({})
	_check(true, "an empty payload loads without error")


func _finish() -> void:
	if _failures.is_empty():
		print("day_night_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("day_night_smoke: %s" % failure)
	quit(1)
