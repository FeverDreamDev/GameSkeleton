@tool
@icon("res://addons/day_night_cycle/icons/day_night_cycle_3d.svg")
class_name DayNightCycle3D
extends Node3D

## Dynamic day/night cycle: a sun and a moon on a rising arc that drive the
## directional lighting, a procedural sky with per-night stars, and a drifting
## cloud layer that shadows the world beneath it.
##
## Drop one into a level in place of its static [DirectionalLight3D]. The node
## builds and owns everything it needs — two lights and a camera-following sky
## dome carrying the sky and the clouds — so a level only has to point it at a
## [WorldEnvironment].
##
## [b]How it stays inside the Retro RT contract[/b]
##
## The [Environment] deliberately stays on [constant Environment.BG_COLOR].
## [code]RTSceneManager[/code] bakes a [constant Environment.BG_SKY] background
## into a reflection panorama on every tracked resource change, through
## [method RenderingServer.force_sync] plus
## [method RenderingServer.sky_bake_panorama]; an animated [Sky] would stall the
## pipeline several times a second. A flat background takes the no-bake branch,
## and this node keeps [member Environment.background_color] equal to the sky
## dome's horizon colour, so the renderer's distance fog and the visible sky are
## the same value by construction and terrain fades into the band it meets.
##
## Clouds are one flat layer of tiling noise at a fixed altitude, drawn by
## intersecting the eye ray with that plane so the layer has parallax. Because
## it is a plane rather than a volume, any surface can resolve its own shadow
## analytically from the same noise, which is what keeps the sky and the ground
## in exactly the same weather.
##
## Nothing here writes to an authored resource while the editor is running.

## Coarse part of the cycle, for gameplay that only needs to know roughly when
## it is. Reported by [method get_phase] and [signal phase_changed].
enum Phase { NIGHT, DAWN, DAY, DUSK }

const SkyDomeScript := preload("res://addons/day_night_cycle/core/sky_dome.gd")
## Bake-only twin of the dome shader. Same include, so the panorama a mirror
## reflects is the same picture the dome draws.
const BakeShader := preload("res://addons/day_night_cycle/shaders/day_night_sky_bake.gdshader")

const HOURS_PER_DAY := 24.0

## Maps the authored 0..1 softness onto a smoothstep half-width in noise units.
## Half the range is already a very soft edge, so this never needs to reach 1.
const SOFTNESS_TO_EDGE := 0.35
## Golden-ratio odd constant, mixed with the day number so consecutive days do
## not produce visibly related layouts.
const DAY_SEED_MIX := 0x9E3779B9
## Frames between attempts to find the renderer while none has been found.
const RT_LOOKUP_INTERVAL_FRAMES := 30
## Frames between arming a reflection bake and taking it. sky_bake_panorama()
## returns the previous sky until the renderer has caught up with the change.
const REFLECTION_BAKE_DELAY_FRAMES := 3
const REFLECTION_PANORAMA_SIZE := Vector2i(256, 128)

## Emitted every frame the clock advances, with the new hour in 0..24.
signal time_changed(hours: float)
## Emitted when the clock rolls past midnight, or when the day is set directly.
## The stars and the cloud layout have already been re-rolled when this fires.
signal day_changed(day_number: int)
signal phase_changed(phase: int)
## Emitted when the fraction of sunlight the cloud layer blocks above the
## viewer changes. A plain float rather than a payload, because it changes every
## frame and this node allocates nothing per frame.
signal sun_occlusion_changed(occlusion: float)
## Emitted alongside a colour push, which is gated on visible change: several
## times a second through a sunrise, and not at all through a still midday.
signal sky_state_changed(state: Dictionary)

@export_group("Time")
## Real seconds in one full in-game day. Safe to change at any time; the clock
## keeps its position in the day rather than jumping.
@export_range(1.0, 86400.0, 0.5, "or_greater")
var day_length_seconds: float = 1200.0
## Hour the cycle starts at, and the hour the editor preview shows.
@export_range(0.0, 24.0, 0.01) var start_time_of_day: float = 8.0
@export var start_day_number: int = 0
## Whether the clock advances on its own. Time can still be moved by hand while
## this is off.
@export var time_running: bool = true
## Extra multiplier on top of [member day_length_seconds], for a fast-forward.
@export_range(0.0, 64.0, 0.01, "or_greater") var time_scale: float = 1.0

@export_group("Sky")
## Compass rotation of the whole sun/moon arc, in degrees.
@export_range(-180.0, 180.0, 0.1) var sun_azimuth_degrees: float = 0.0
## Tilt of the arc away from vertical. Keeps the sun off the exact zenith at
## noon, so shadows sweep across the ground instead of pivoting in place.
@export_range(0.0, 80.0, 0.1) var sun_tilt_degrees: float = 25.0
## In-game days for one full new-to-new moon cycle. Day zero is a full moon.
@export_range(1, 64, 1) var moon_phase_cycle_days: int = 8
## Half-extent of the dome. Its corners reach sqrt(3) times this, so keep that
## inside the
## camera's far plane.
@export_range(50.0, 20000.0, 1.0) var sky_dome_radius: float = 1200.0
@export_range(0.05, 12.0, 0.01) var sun_angular_radius_degrees: float = 2.0
@export_range(0.05, 12.0, 0.01) var moon_angular_radius_degrees: float = 3.2

@export_group("Stars")
## Cells per cube face. Higher is more, smaller stars.
@export_range(4.0, 400.0, 1.0) var star_density: float = 150.0
## Fraction of cells that actually hold a star.
@export_range(0.0, 1.0, 0.01) var star_coverage: float = 0.42
## Angular size of one star within its cell. Large enough to survive SMAA
## rather than crawling as a subpixel speck.
@export_range(0.005, 0.5, 0.001) var star_size: float = 0.055
@export_range(0.0, 1.0, 0.01) var star_twinkle_amount: float = 0.35

@export_group("Procedural")
## Base seed for the world. Mixed with the day number, so two runs with the same
## seed see the same clouds and the same stars on the same day.
@export var world_seed: int = 20260823

@export_group("Clouds")
@export var clouds_enabled: bool = true
## How much of the sky is covered, 0 clear to 1 overcast.
@export_range(0.0, 1.0, 0.01) var cloud_coverage: float = 0.5
## Height of the cloud layer above the world origin, in metres. Every surface
## resolves its own shadow by intersecting its sun ray with this plane.
@export_range(10.0, 4000.0, 1.0) var cloud_altitude: float = 260.0
## Metres of world spanned by one tile of the cloud field. This also sets the
## size of the largest cloud mass, because the first octave of the noise has one
## lattice cell per tile: make it much larger than the sky is wide and that
## single cell becomes a visible straight-edged facet.
@export_range(16.0, 8000.0, 1.0) var cloud_world_size: float = 420.0
## Softness of the cloud edge. Low values give the hard-edged banks of a
## nineties skybox; high values give something closer to haze.
@export_range(0.0, 1.0, 0.01) var cloud_softness: float = 0.34
## How dark the underside of a cloud gets, towards the horizon colour.
@export_range(0.0, 1.0, 0.01) var cloud_shade: float = 0.45
## Distance at which the layer fades into the horizon haze, in metres. Without
## it the flat layer would compress into a hard line at the skyline.
@export_range(100.0, 40000.0, 10.0) var cloud_fade_distance: float = 5200.0
## How much of the sun a fully covered patch blocks, 0 none to 1 all of it.
@export_range(0.0, 1.0, 0.01) var cloud_shadow_strength: float = 0.8
## How much an overcast sky lifts the ambient fill. A real overcast day is not
## a sunny one with the sun switched off: the cloud deck becomes the light
## source. Without this, full cover leaves shadowed surfaces at clear-sky
## ambient, which on these materials is very close to black.
@export_range(0.0, 3.0, 0.01) var cloud_ambient_lift: float = 0.65
@export var wind_direction: Vector2 = Vector2(1.0, 0.35)
@export_range(0.0, 200.0, 0.1) var wind_speed: float = 3.5

@export_group("Integration")
## The [WorldEnvironment] whose [Environment] this node drives. Leave the
## default when the cycle sits beside one in a level.
@export_node_path("WorldEnvironment") var world_environment_path: NodePath = ^"../WorldEnvironment"
## Optional explicit camera. Empty uses the viewport's current [Camera3D],
## which is what a level normally wants.
@export_node_path("Camera3D") var camera_path: NodePath = ^""
## The [code]RTSceneManager[/code] that lights the managed geometry. Managed
## Blinn-Phong surfaces are shaded by the renderer rather than by their own
## material, so the cloud layer has to reach it there. Empty searches the tree.
@export_node_path("Node") var rt_scene_manager_path: NodePath = ^""
## Bakes the sky into the Retro RT reflection panorama, so mirrors reflect the
## real sky instead of the flat background colour. Each rebake is a pipeline
## stall of a few milliseconds, which is why it is throttled below.
@export var reflection_panorama_enabled: bool = true
## Degrees the sun must move before the reflection is rebaked. Larger is
## cheaper and more stale; a mirror hides staleness well.
@export_range(0.5, 90.0, 0.5) var reflection_sun_step_degrees: float = 8.0
## Keeps [member Environment.background_color] on the horizon colour, which is
## what the Retro RT distance fog resolves to.
@export var drive_environment_background: bool = true
## Keeps [member Environment.ambient_light_color] and energy on the palette.
## This is the fill that reaches unmanaged forward geometry such as shell grass.
@export var drive_environment_ambient: bool = true
## Managed Blinn-Phong materials whose [code]ambient_light[/code] follows the
## time of day. Their authored value is kept as the daylight reference, so a
## material tuned by hand still looks exactly as authored at noon.
@export var ambient_materials: Array[ShaderMaterial] = []
## Unmanaged materials that sample the cloud layer to resolve their own shadow.
## They must run the canonical dnc_cloud_shadow() and declare its uniforms; see
## the README. Managed Blinn-Phong surfaces get theirs from Retro RT instead.
@export var cloud_shadow_materials: Array[ShaderMaterial] = []
## Colour movement, per channel, needed before a push. Gating matters: every
## Environment write costs an RT environment revision, and every material write
## costs a material-table re-upload.
@export_range(0.0, 0.1, 0.0001) var colour_update_threshold: float = 0.003

@export_group("Preview")
## Builds the sky and both lights in the editor viewport. The preview never
## writes to the Environment or to a material: those are authored resources, and
## an in-editor edit would be saved into the scene.
@export var preview_in_editor: bool = true:
	set = _set_preview_in_editor

@export_group("Palette")
## Colour and intensity ramps. A null palette is replaced by a complete default
## set on the first frame.
@export var palette: DayNightPalette

var _time_of_day: float = 8.0
var _day_number: int = 0
var _phase: int = Phase.DAY
var _sun_occlusion: float = 0.0
var _star_seed: float = 0.0
var _twinkle_time: float = 0.0
## Distance the cloud layer has scrolled on the wind, in world metres. Shared
## with every shader that samples the layer, so they all see the same sky.
var _cloud_offset := Vector2.ZERO
## Per-day seed for the cloud field, shared with every shader copy.
var _cloud_seed: float = 0.0
var _built: bool = false
var _sky: SkyDomeScript
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _environment: Environment
var _rt_manager: Node
## Sky used only to bake the reflection panorama; never attached to the
## Environment, which stays flat.
var _reflection_sky: Sky
var _reflection_material: ShaderMaterial
var _reflection_sun := Vector3.ZERO
var _reflection_host: SubViewport
var _reflection_pending: int = 0
var _rt_lookup_cooldown: int = 0

var _day_rng := RandomNumberGenerator.new()
var _registered_materials: Array[ShaderMaterial] = []
var _material_base_ambient: PackedColorArray = PackedColorArray()
var _cloud_shadow_targets: Array[ShaderMaterial] = []

var _pushed_horizon := Color(-1.0, -1.0, -1.0)
var _pushed_ambient := Color(-1.0, -1.0, -1.0)
var _pushed_ambient_energy: float = -1.0


#region Lifecycle

func _ready() -> void:
	# After the player camera rig, which is written on the render frame, and
	# before RTSceneManager at 100000, which publishes the frame's snapshot.
	process_priority = 90000
	_time_of_day = fposmod(start_time_of_day, HOURS_PER_DAY)
	_day_number = start_day_number
	if Engine.is_editor_hint() and not preview_in_editor:
		return
	_build()


func _exit_tree() -> void:
	# Children are owned by this node and go with it. Only the cached references
	# have to be dropped, so a re-entering node rebuilds rather than writing to
	# freed instances.
	_environment = null


func _process(delta: float) -> void:
	if not _built:
		return
	if Engine.is_editor_hint():
		# The preview follows the authored hour so scrubbing it in the inspector
		# shows the result, and never advances on its own.
		_time_of_day = fposmod(start_time_of_day, HOURS_PER_DAY)
	elif time_running and delta > 0.0:
		_advance(delta)

	_twinkle_time = fmod(_twinkle_time + delta, TAU * 1024.0)
	# One tile of the cloud texture covers cloud_world_size metres, so wrapping
	# the scroll at that distance is exact and the offset never grows large
	# enough to lose precision in a shader.
	var wind := _wind_velocity() * delta
	_cloud_offset = Vector2(
		fposmod(_cloud_offset.x + wind.x, cloud_world_size),
		fposmod(_cloud_offset.y + wind.y, cloud_world_size))
	_update_visuals(delta)


func _advance(delta: float) -> void:
	var hours := delta * (HOURS_PER_DAY / maxf(day_length_seconds, 0.001)) * maxf(time_scale, 0.0)
	if hours <= 0.0:
		return
	var advanced := _time_of_day + hours
	if advanced >= HOURS_PER_DAY:
		var rolled := int(advanced / HOURS_PER_DAY)
		_time_of_day = fposmod(advanced, HOURS_PER_DAY)
		_day_number += rolled
		_reseed_day()
		day_changed.emit(_day_number)
	else:
		_time_of_day = advanced
	time_changed.emit(_time_of_day)

#endregion


#region Construction

func _build() -> void:
	if _built:
		return
	_resolve_palette()

	_sun = _make_light("SunLight")
	_moon = _make_light("MoonLight")

	_sky = SkyDomeScript.new()
	add_child(_sky)
	_sky.setup(sky_dome_radius)

	_resolve_rt_manager()

	for material: ShaderMaterial in ambient_materials:
		register_ambient_material(material)
	for shadowed: ShaderMaterial in cloud_shadow_materials:
		register_cloud_shadow_material(shadowed)

	_built = true
	_reseed_day()
	_update_visuals(0.0)




func _make_light(light_name: String) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = light_name
	# Retro RT repurposes this checkbox as the RT-shadow toggle and suppresses
	# the native shadow map while it runs.
	light.shadow_enabled = true
	light.directional_shadow_max_distance = 256.0
	# Rewritten every render frame; interpolation would leave the shadow
	# direction a tick behind the sun that casts it.
	light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(light)
	return light


func _resolve_palette() -> void:
	if palette == null:
		palette = DayNightPalette.new()
	palette.resolve()


func _set_preview_in_editor(value: bool) -> void:
	preview_in_editor = value
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if value:
		_build()
	elif _built:
		_teardown()


func _teardown() -> void:
	for child: Node in [_sky, _sun, _moon]:
		if child != null and is_instance_valid(child):
			remove_child(child)
			child.queue_free()
	_sky = null
	_sun = null
	_moon = null
	_built = false
	_pushed_horizon = Color(-1.0, -1.0, -1.0)
	_pushed_ambient = Color(-1.0, -1.0, -1.0)
	_pushed_ambient_energy = -1.0

#endregion


#region Per-frame update

func _update_visuals(delta: float) -> void:
	var to_sun := get_direction_to_sun()
	var to_moon := -to_sun
	var sun_height := DayNightPalette.height_parameter(to_sun)
	var moon_height := DayNightPalette.height_parameter(to_moon)

	var sun_color := palette.sample_sun_light(sun_height)
	var sun_energy := palette.sample_sun_energy(sun_height)
	var moon_energy := palette.sample_moon_energy(moon_height)
	var zenith := palette.sample_zenith(sun_height)
	var horizon := palette.sample_horizon(sun_height)
	var ground := palette.sample_ground(sun_height)
	var glow := palette.sample_sun_glow(sun_height)
	var ambient := palette.sample_ambient(sun_height)
	var ambient_energy := palette.sample_ambient_energy(sun_height)
	# An overcast deck scatters light down rather than blocking it outright.
	ambient_energy *= 1.0 + clampf(cloud_coverage, 0.0, 1.0) * cloud_ambient_lift
	var star_intensity := palette.sample_star_intensity(sun_height)

	_aim_light(_sun, to_sun)
	_sun.light_color = sun_color
	_sun.light_energy = sun_energy
	_aim_light(_moon, to_moon)
	_moon.light_color = palette.moon_light_color
	_moon.light_energy = moon_energy

	var camera := _resolve_camera()
	var camera_position := camera.global_position if camera != null else global_position
	_sky.follow(camera_position)
	_push_sky(zenith, horizon, ground, to_sun, sun_color, glow, to_moon, star_intensity)
	_push_cloud_layer(to_sun, sun_color, horizon, sun_height)
	_update_occlusion(camera_position, to_sun)
	_update_reflection_panorama()

	_update_phase()
	_push_colours(horizon, ambient, ambient_energy, sun_height)


func _push_sky(
		zenith: Color,
		horizon: Color,
		ground: Color,
		to_sun: Vector3,
		sun_color: Color,
		glow: Color,
		to_moon: Vector3,
		star_intensity: float) -> void:
	var material := _sky.sky_material
	material.set_shader_parameter(&"u_zenith_color", zenith)
	material.set_shader_parameter(&"u_horizon_color", horizon)
	material.set_shader_parameter(&"u_ground_color", ground)
	material.set_shader_parameter(&"u_sun_direction", to_sun)
	material.set_shader_parameter(&"u_sun_color", sun_color)
	material.set_shader_parameter(&"u_sun_glow_color", glow)
	material.set_shader_parameter(
		&"u_sun_angular_radius", deg_to_rad(sun_angular_radius_degrees))
	material.set_shader_parameter(&"u_moon_direction", to_moon)
	material.set_shader_parameter(&"u_moon_color", palette.moon_light_color)
	material.set_shader_parameter(
		&"u_moon_angular_radius", deg_to_rad(moon_angular_radius_degrees))
	material.set_shader_parameter(&"u_moon_phase", get_moon_phase())
	# The moon has to fade out by day on its own: it stays antipodal to the sun,
	# so it is above the horizon for part of the daylight hours.
	material.set_shader_parameter(
		&"u_moon_intensity", clampf(star_intensity, 0.0, 1.0))
	material.set_shader_parameter(
		&"u_moon_glow_intensity", 0.10 * clampf(star_intensity, 0.0, 1.0))
	material.set_shader_parameter(&"u_star_intensity", star_intensity)
	material.set_shader_parameter(&"u_star_density", star_density)
	material.set_shader_parameter(&"u_star_coverage", star_coverage)
	material.set_shader_parameter(&"u_star_size", star_size)
	material.set_shader_parameter(&"u_star_seed", _star_seed)
	material.set_shader_parameter(&"u_star_twinkle_amount", star_twinkle_amount)
	material.set_shader_parameter(&"u_star_twinkle_time", _twinkle_time)


## The cloud layer lives in the sky shader, and the same layer is what every
## surface samples to resolve its own shadow. These four values are the whole
## contract, and every consumer has to agree on them exactly.
func _cloud_params() -> Vector4:
	# A zero tile scale is what disables the layer, which leaves w free to carry
	# the edge softness. Every consumer reads the same four numbers.
	var scale := 0.0
	if clouds_enabled:
		scale = 1.0 / maxf(cloud_world_size, 0.001)
	return Vector4(
		cloud_altitude,
		scale,
		1.0 - clampf(cloud_coverage, 0.0, 1.0),
		maxf(cloud_softness * SOFTNESS_TO_EDGE, 0.001))


func _push_cloud_layer(
		to_sun: Vector3,
		sun_color: Color,
		horizon: Color,
		sun_height: float) -> void:
	# Whichever body is actually lighting the sky. Their energies cross over at
	# dusk, so the layer turns from warm to blue on its own, and the shading tap
	# follows the light that is casting the shadow on the ground.
	var lit := sun_color
	var direction := to_sun
	var energy := _sun.light_energy
	if _moon.light_energy > _sun.light_energy:
		lit = palette.moon_light_color
		direction = -to_sun
		energy = _moon.light_energy
	# Blending towards the shade colour by energy is what keeps a night sky from
	# holding blazing white clouds against a black background.
	lit = horizon.lerp(lit, clampf(energy, 0.0, 1.0))

	# The shadow only makes sense under the sun, so its strength falls away with
	# the sun rather than letting the moon cast one.
	var params := _cloud_params()
	var motion := _cloud_motion(
		cloud_shadow_strength * smoothstep(0.40, 0.55, sun_height))

	var material := _sky.sky_material
	material.set_shader_parameter(&"u_cloud_params", params)
	material.set_shader_parameter(&"u_cloud_motion", motion)
	material.set_shader_parameter(&"u_cloud_lit_color", lit)
	material.set_shader_parameter(&"u_cloud_shade_color", horizon)
	material.set_shader_parameter(&"u_cloud_shade", cloud_shade)
	material.set_shader_parameter(&"u_cloud_fade_distance", cloud_fade_distance)
	material.set_shader_parameter(&"u_cloud_sun_direction", direction)

	# Every surface that resolves its own shadow reads the same two vectors.
	# Both naming conventions are pushed because Retro RT's own shaders leave
	# their uniforms unprefixed while this add-on and the grass use u_; an
	# unknown parameter name is simply stored and ignored.
	for shadowed: ShaderMaterial in _cloud_shadow_targets:
		if shadowed == null or not is_instance_valid(shadowed):
			continue
		shadowed.set_shader_parameter(&"u_cloud_params", params)
		shadowed.set_shader_parameter(&"u_cloud_motion", motion)
		shadowed.set_shader_parameter(&"u_cloud_sun_direction", to_sun)
		shadowed.set_shader_parameter(&"cloud_params", params)
		shadowed.set_shader_parameter(&"cloud_motion", motion)
		shadowed.set_shader_parameter(&"cloud_sun_direction", to_sun)

	_resolve_rt_manager()
	# Managed Blinn-Phong surfaces are lit by Retro RT, not by their own shader,
	# so the layer has to reach the renderer instead of the material.
	if _rt_manager != null and _rt_manager.has_method(&"configure_cloud_layer"):
		_rt_manager.call(&"configure_cloud_layer", params, motion, to_sun)


## Keeps the mirror reflecting the sky this add-on draws.
##
## Retro RT resolves a reflection miss against the Environment, and this level
## keeps that Environment flat on purpose: BG_COLOR is the branch with no
## panorama bake, and its flat radiance is what the distance fog resolves to. So
## the sky is baked separately, off a Sky that lives in a private world, and
## handed to the renderer as a reflection source alone. Fog and the visible
## background stay exact and free; only the mirror pays.
##
## RenderingServer.sky_bake_panorama() returns black for a Sky that no
## Environment is using, and it needs a couple of frames after a change before
## it returns the new one. Hence the private SubViewport and the two-step arm
## below, neither of which is optional.
##
## The bake stalls the pipeline, so it is throttled by how far the sun has
## actually moved rather than run on a timer. A reflection a few degrees out of
## date is not something anyone can see in a curved mirror.
func _update_reflection_panorama() -> void:
	# Never in the editor: the bake stalls the pipeline the editor draws with.
	if Engine.is_editor_hint() or not reflection_panorama_enabled:
		return
	if _rt_manager == null or not _rt_manager.has_method(&"set_reflection_panorama"):
		return

	if _reflection_pending > 0:
		_reflection_pending -= 1
		if _reflection_pending == 0:
			_bake_reflection_panorama()
			# Back to sleep until the sun has moved far enough to arm another.
			_reflection_host.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return

	var to_sun := get_direction_to_sun()
	var moved := rad_to_deg(acos(clampf(to_sun.dot(_reflection_sun), -1.0, 1.0)))
	if _reflection_sky != null and moved < reflection_sun_step_degrees:
		return
	_arm_reflection_bake(to_sun)


func _arm_reflection_bake(to_sun: Vector3) -> void:
	if _reflection_sky == null:
		_reflection_material = ShaderMaterial.new()
		_reflection_material.shader = BakeShader
		_reflection_sky = Sky.new()
		_reflection_sky.sky_material = _reflection_material
		# Only ever seen curved across a mirror, so the smallest radiance size
		# that still resolves the sun keeps the bake as cheap as the API allows.
		_reflection_sky.radiance_size = Sky.RADIANCE_SIZE_128

		var environment := Environment.new()
		environment.background_mode = Environment.BG_SKY
		environment.sky = _reflection_sky
		# A private world: a second WorldEnvironment in the level's own world
		# would fight the one the renderer validates against.
		_reflection_host = SubViewport.new()
		_reflection_host.name = "ReflectionBakeWorld"
		_reflection_host.size = Vector2i(4, 4)
		_reflection_host.own_world_3d = true
		add_child(_reflection_host)
		var host_environment := WorldEnvironment.new()
		host_environment.environment = environment
		_reflection_host.add_child(host_environment)
		var host_camera := Camera3D.new()
		host_camera.current = true
		_reflection_host.add_child(host_camera)

	# The dome material already holds the exact state being drawn this frame.
	var dome_material := _sky.sky_material
	for parameter: Dictionary in dome_material.shader.get_shader_uniform_list():
		var parameter_name := StringName(parameter["name"])
		var value: Variant = dome_material.get_shader_parameter(parameter_name)
		if value != null:
			_reflection_material.set_shader_parameter(parameter_name, value)
	_reflection_sun = to_sun
	_reflection_pending = REFLECTION_BAKE_DELAY_FRAMES
	# Woken only for the frames a bake actually needs. Left on UPDATE_ALWAYS this
	# private world renders its own sky, and its radiance cubemap, every frame
	# forever -- for a 4x4 target that nothing samples between bakes, which are
	# eight degrees of sun travel apart.
	_reflection_host.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _bake_reflection_panorama() -> void:
	var image := RenderingServer.sky_bake_panorama(
		_reflection_sky.get_rid(), 1.0, false, REFLECTION_PANORAMA_SIZE)
	if image == null or image.is_empty():
		# A backend that cannot bake simply keeps the flat reflection colour.
		reflection_panorama_enabled = false
		push_warning(
			"DayNightCycle3D could not bake a reflection panorama; "
			+ "mirrors keep the flat background colour.")
		return
	_rt_manager.call(&"set_reflection_panorama", image, Basis.IDENTITY)




## Samples the same noise the shaders do, so the reported value agrees with the
## shadow actually on the ground rather than approximating it.
func _update_occlusion(camera_position: Vector3, to_sun: Vector3) -> void:
	var occlusion := 0.0
	if clouds_enabled and to_sun.y > 0.05:
		var travel := (cloud_altitude - camera_position.y) / to_sun.y
		if travel > 0.0:
			var hit := Vector2(
				camera_position.x + to_sun.x * travel,
				camera_position.z + to_sun.z * travel)
			occlusion = _cloud_density_at(hit)
	if is_equal_approx(occlusion, _sun_occlusion):
		return
	_sun_occlusion = occlusion
	sun_occlusion_changed.emit(_sun_occlusion)


## The CPU twin of dnc_cloud_density(). Kept in step with the shader copies by
## hand; only [method get_sun_occlusion] reads it, so a last-bit difference is
## harmless, but the shape of the field must match.
func _cloud_density_at(world_xz: Vector2) -> float:
	var scale := 1.0 / maxf(cloud_world_size, 0.001)
	var raw := _cloud_field((world_xz + _cloud_offset) * scale)
	var threshold := 1.0 - clampf(cloud_coverage, 0.0, 1.0)
	var edge := maxf(cloud_softness * SOFTNESS_TO_EDGE, 0.001)
	return smoothstep(threshold - edge, threshold + edge, raw)


func _cloud_field(point: Vector2) -> float:
	var total := 0.0
	var amplitude := 0.5
	var normalization := 0.0
	var sample_point := point
	for _octave in 4:
		total += _cloud_noise_at(sample_point) * amplitude
		normalization += amplitude
		# Matches the shader copies: rotate as well as scale, so no two octaves
		# share a lattice orientation.
		sample_point = Vector2(
			0.8 * sample_point.x - 0.6 * sample_point.y,
			0.6 * sample_point.x + 0.8 * sample_point.y)
		sample_point = sample_point * 2.03 + Vector2(37.0, 17.0)
		amplitude *= 0.5
	return total / normalization




func _cloud_noise_at(point: Vector2) -> float:
	var lattice := point.floor()
	var fraction := point - lattice
	var fade := fraction * fraction * fraction * (
		fraction * (fraction * 6.0 - Vector2(15.0, 15.0)) + Vector2(10.0, 10.0))
	var corner00 := _cloud_gradient(lattice).dot(fraction)
	var corner10 := _cloud_gradient(lattice + Vector2(1.0, 0.0)).dot(
		fraction - Vector2(1.0, 0.0))
	var corner01 := _cloud_gradient(lattice + Vector2(0.0, 1.0)).dot(
		fraction - Vector2(0.0, 1.0))
	var corner11 := _cloud_gradient(lattice + Vector2(1.0, 1.0)).dot(
		fraction - Vector2(1.0, 1.0))
	var value := lerpf(
		lerpf(corner00, corner10, fade.x),
		lerpf(corner01, corner11, fade.x),
		fade.y)
	return clampf(value * 0.7071 + 0.5, 0.0, 1.0)


func _cloud_hash(cell: Vector2) -> Vector2:
	var scattered := Vector3(cell.x, cell.y, cell.x) * Vector3(0.1031, 0.1030, 0.0973) \
		+ Vector3.ONE * _cloud_seed
	scattered = Vector3(
		scattered.x - floor(scattered.x),
		scattered.y - floor(scattered.y),
		scattered.z - floor(scattered.z))
	var shifted := Vector3(scattered.y, scattered.z, scattered.x) + Vector3.ONE * 33.33
	scattered += Vector3.ONE * scattered.dot(shifted)
	var pair := Vector2(
		(scattered.x + scattered.y) * scattered.z,
		(scattered.x + scattered.z) * scattered.y)
	return Vector2(pair.x - floor(pair.x), pair.y - floor(pair.y))


func _cloud_gradient(cell: Vector2) -> Vector2:
	var angle := _cloud_hash(cell).x * TAU
	return Vector2(cos(angle), sin(angle))


## The two vectors every consumer of the layer reads, alongside _cloud_params().
func _cloud_motion(shadow_strength: float) -> Vector4:
	return Vector4(_cloud_offset.x, _cloud_seed, _cloud_offset.y, shadow_strength)


func _push_colours(
		horizon: Color,
		ambient: Color,
		ambient_energy: float,
		sun_height: float) -> void:
	# Authored resources are never written from the editor. RTSceneManager takes
	# the same care with the one Environment property it owns: an in-memory edit
	# here would be serialised into the level by the next scene save.
	if Engine.is_editor_hint():
		return
	var moved := (
		not _within_threshold(horizon, _pushed_horizon)
		or not _within_threshold(ambient, _pushed_ambient)
		or absf(ambient_energy - _pushed_ambient_energy) > colour_update_threshold)
	if not moved:
		return
	_pushed_horizon = horizon
	_pushed_ambient = ambient
	_pushed_ambient_energy = ambient_energy

	var environment := _resolve_environment()
	if environment != null:
		if drive_environment_background and environment.background_mode == Environment.BG_COLOR:
			# One write, one RT environment revision, one distance_fog_changed.
			# The renderer resolves its fog colour from exactly this value, so
			# the terrain keeps fading into the band the sky dome draws.
			environment.background_color = horizon
		if drive_environment_ambient:
			environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			environment.ambient_light_color = ambient
			environment.ambient_light_energy = ambient_energy

	_push_material_ambient(sun_height)
	sky_state_changed.emit(get_sky_state())


## Managed Blinn-Phong surfaces take their fill from a per-material uniform, not
## from the Environment, so the ambient ramp has to reach them separately. The
## authored value is treated as the daylight reference and scaled by how far the
## ramp has fallen from its peak, which leaves a hand-tuned material untouched
## at noon and correctly blue and dim at midnight.
func _push_material_ambient(sun_height: float) -> void:
	if _registered_materials.is_empty():
		return
	var reference := palette.sample_ambient(1.0) * palette.sample_ambient_energy(1.0)
	var current := palette.sample_ambient(sun_height) * palette.sample_ambient_energy(sun_height)
	var factor := Color(
		current.r / maxf(reference.r, 0.0001),
		current.g / maxf(reference.g, 0.0001),
		current.b / maxf(reference.b, 0.0001),
		1.0)
	for index in _registered_materials.size():
		var material := _registered_materials[index]
		if material == null or not is_instance_valid(material):
			continue
		var base := _material_base_ambient[index]
		material.set_shader_parameter(&"ambient_light", Color(
			base.r * factor.r, base.g * factor.g, base.b * factor.b, base.a))


func _within_threshold(a: Color, b: Color) -> bool:
	return (
		absf(a.r - b.r) <= colour_update_threshold
		and absf(a.g - b.g) <= colour_update_threshold
		and absf(a.b - b.b) <= colour_update_threshold)


func _update_phase() -> void:
	var next := _compute_phase()
	if next == _phase:
		return
	_phase = next
	phase_changed.emit(_phase)


func _compute_phase() -> int:
	var height := DayNightPalette.height_parameter(get_direction_to_sun())
	if height >= 0.58:
		return Phase.DAY
	if height <= 0.30:
		return Phase.NIGHT
	# Inside the twilight band the sun's direction of travel is what separates
	# dawn from dusk, and that is simply which half of the day it is.
	return Phase.DAWN if get_normalized_time() < 0.5 else Phase.DUSK


func _wind_velocity() -> Vector2:
	var direction := wind_direction
	if direction.length_squared() < 0.000001:
		return Vector2.ZERO
	return direction.normalized() * wind_speed


func _aim_light(light: DirectionalLight3D, direction_to_body: Vector3) -> void:
	# RTSceneManager reads a DirectionalLight3D's +Z basis vector as the
	# direction towards the light, and looking_at() puts -Z on its target, so
	# the target is the negated body direction.
	var target := -direction_to_body
	var up := Vector3.UP if absf(direction_to_body.y) < 0.999 else Vector3.BACK
	light.global_transform = Transform3D(
		Basis.looking_at(target, up), light.global_position)


func _resolve_camera() -> Camera3D:
	if not camera_path.is_empty():
		var explicit := get_node_or_null(camera_path) as Camera3D
		if explicit != null:
			return explicit
	var viewport := get_viewport()
	return viewport.get_camera_3d() if viewport != null else null


## Managed Blinn-Phong surfaces are lit by Retro RT rather than by their own
## material, so the cloud layer has to reach the renderer to shadow them. The
## lookup is duck-typed: the add-on works without Retro RT, and the sky, the
## lights and every unmanaged surface behave the same either way.
func _resolve_rt_manager() -> void:
	if _rt_manager != null and is_instance_valid(_rt_manager):
		return
	_rt_manager = null
	# A persistent app shell can install its renderer after the level, and a
	# level can be reinstalled under a running one, so the lookup retries rather
	# than being resolved once at build time. Throttled because a miss walks the
	# tree.
	_rt_lookup_cooldown -= 1
	if _rt_lookup_cooldown > 0:
		return
	_rt_lookup_cooldown = RT_LOOKUP_INTERVAL_FRAMES
	if not rt_scene_manager_path.is_empty():
		_rt_manager = get_node_or_null(rt_scene_manager_path)
		return
	if not is_inside_tree():
		return
	for candidate: Node in get_tree().get_nodes_in_group(&"retro_rt_scene_manager"):
		_rt_manager = candidate
		return
	# No group to search, so fall back to the first manager in the tree. A
	# project with several would name one explicitly.
	var root := get_tree().root
	if root != null:
		_rt_manager = _find_rt_manager(root)


func _find_rt_manager(node: Node) -> Node:
	if node.has_method(&"configure_cloud_layer") and node.has_method(&"get_active_rt_backend"):
		return node
	for child: Node in node.get_children():
		var found := _find_rt_manager(child)
		if found != null:
			return found
	return null


func _resolve_environment() -> Environment:
	if _environment != null:
		return _environment
	var host := get_node_or_null(world_environment_path) as WorldEnvironment
	if host != null:
		_environment = host.environment
	elif is_inside_tree() and get_world_3d() != null:
		_environment = get_world_3d().environment
	return _environment

#endregion


#region Per-day procedural state

func _day_seed() -> int:
	return world_seed ^ (_day_number * DAY_SEED_MIX)


## Re-rolls everything that is supposed to differ from one day to the next: the
## star field and the shape of the cloud layer. One integer each, so nothing is
## rebuilt and no acceleration structure is touched.
func _reseed_day() -> void:
	if not _built:
		return
	_day_rng.seed = _day_seed()
	_star_seed = float(_day_rng.randi_range(0, 4095))
	# The seed is one number shared by the sky, every shadowed material and the
	# renderer, so a new day changes all of them on the same frame.
	# Kept inside one unit: the shader hash adds this before a fract(), and a
	# large value there would eat the precision the fraction needs.
	_cloud_seed = _day_rng.randf()

#endregion


#region Time API

func get_time_of_day() -> float:
	return _time_of_day


## Moves the clock without changing the day, so the cloud layout and star field
## stay put. Use [method advance_time] to cross midnight properly.
func set_time_of_day(hours: float) -> void:
	_time_of_day = fposmod(hours, HOURS_PER_DAY)
	time_changed.emit(_time_of_day)


func get_normalized_time() -> float:
	return _time_of_day / HOURS_PER_DAY


func set_normalized_time(value: float) -> void:
	set_time_of_day(value * HOURS_PER_DAY)


## Adds to the clock, rolling the day over — and re-rolling the sky with it —
## as many times as the offset crosses midnight. Accepts negative offsets.
func advance_time(hours: float) -> void:
	var total := _time_of_day + hours
	var rolled := int(floorf(total / HOURS_PER_DAY))
	_time_of_day = fposmod(total, HOURS_PER_DAY)
	if rolled != 0:
		_day_number += rolled
		_reseed_day()
		day_changed.emit(_day_number)
	time_changed.emit(_time_of_day)


func get_day_length_seconds() -> float:
	return day_length_seconds


func set_day_length_seconds(seconds: float) -> void:
	day_length_seconds = maxf(seconds, 0.001)


func get_day_number() -> int:
	return _day_number


func set_day_number(value: int) -> void:
	if value == _day_number:
		return
	_day_number = value
	_reseed_day()
	day_changed.emit(_day_number)


func is_time_running() -> bool:
	return time_running


func set_time_running(value: bool) -> void:
	time_running = value


func get_time_scale() -> float:
	return time_scale


func set_time_scale(value: float) -> void:
	time_scale = maxf(value, 0.0)

#endregion


#region Sky and lighting API

## Unit vector from the world towards the sun. This is the +Z basis vector of
## the sun light, matching how Retro RT reads a directional light.
func get_direction_to_sun() -> Vector3:
	var angle := (get_normalized_time() - 0.25) * TAU
	var orbit := Basis.from_euler(Vector3(0.0, deg_to_rad(sun_azimuth_degrees), 0.0)) \
		* Basis.from_euler(Vector3(deg_to_rad(sun_tilt_degrees), 0.0, 0.0))
	return (orbit * Vector3(cos(angle), sin(angle), 0.0)).normalized()


func get_direction_to_moon() -> Vector3:
	return -get_direction_to_sun()


## Elevation above the horizon in radians. Negative below it.
func get_sun_elevation() -> float:
	return asin(clampf(get_direction_to_sun().y, -1.0, 1.0))


func get_moon_elevation() -> float:
	return asin(clampf(get_direction_to_moon().y, -1.0, 1.0))


## 0.0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter. Day zero is full.
func get_moon_phase() -> float:
	var cycle := float(maxi(moon_phase_cycle_days, 1))
	return fposmod(float(_day_number) + cycle * 0.5, cycle) / cycle


## Smooth 0..1 blend from full night to full day, for gameplay that wants to
## fade something with the light rather than switch on [method get_phase].
func get_day_factor() -> float:
	return smoothstep(
		0.40, 0.58, DayNightPalette.height_parameter(get_direction_to_sun()))


func is_night() -> bool:
	return _phase == Phase.NIGHT


func get_phase() -> int:
	return _phase


func get_phase_name() -> StringName:
	match _phase:
		Phase.DAWN:
			return &"dawn"
		Phase.DAY:
			return &"day"
		Phase.DUSK:
			return &"dusk"
		_:
			return &"night"


func get_sun_light() -> DirectionalLight3D:
	return _sun


func get_moon_light() -> DirectionalLight3D:
	return _moon


func get_sun_light_color() -> Color:
	return _sun.light_color if _sun != null else Color.WHITE


func get_sun_light_energy() -> float:
	return _sun.light_energy if _sun != null else 0.0


func get_moon_light_energy() -> float:
	return _moon.light_energy if _moon != null else 0.0


func get_horizon_color() -> Color:
	_resolve_palette()
	return palette.sample_horizon(
		DayNightPalette.height_parameter(get_direction_to_sun()))


func get_zenith_color() -> Color:
	_resolve_palette()
	return palette.sample_zenith(
		DayNightPalette.height_parameter(get_direction_to_sun()))


func get_ambient_color() -> Color:
	_resolve_palette()
	return palette.sample_ambient(
		DayNightPalette.height_parameter(get_direction_to_sun()))


func get_ambient_energy() -> float:
	_resolve_palette()
	return palette.sample_ambient_energy(
		DayNightPalette.height_parameter(get_direction_to_sun()))


func get_star_intensity() -> float:
	_resolve_palette()
	return palette.sample_star_intensity(
		DayNightPalette.height_parameter(get_direction_to_sun()))



## Fraction of sunlight the cloud layer blocks directly above the viewer, 0..1.
##
## Evaluated on the CPU against the same noise the shaders sample, so it agrees
## with the shadow actually on the ground. Gameplay information only: every
## surface resolves its own shadow per pixel.
func get_sun_occlusion() -> float:
	return _sun_occlusion

#endregion


#region Cloud API

func get_cloud_coverage() -> float:
	return cloud_coverage


## Higher is more sky covered. Takes effect immediately.
func set_cloud_coverage(value: float) -> void:
	cloud_coverage = clampf(value, 0.0, 1.0)


func get_cloud_altitude() -> float:
	return cloud_altitude


func set_cloud_altitude(value: float) -> void:
	cloud_altitude = value


func get_wind_direction() -> Vector2:
	return wind_direction


func set_wind_direction(value: Vector2) -> void:
	wind_direction = value


func get_wind_speed() -> float:
	return wind_speed


func set_wind_speed(value: float) -> void:
	wind_speed = value


## Distance the layer has scrolled, in world metres. Every shader that samples
## the clouds needs this, and they all have to agree on it.
func get_cloud_offset() -> Vector2:
	return _cloud_offset


## Re-rolls the star field and the cloud shapes without changing the clock.
func reseed_day() -> void:
	_reseed_day()

#endregion


#region Ambient material registration

## Registers a managed Blinn-Phong material whose [code]ambient_light[/code]
## should follow the cycle. The value it currently holds is captured as its
## daylight reference, so call this before changing it by hand.
func register_ambient_material(material: ShaderMaterial) -> void:
	if material == null or _registered_materials.has(material):
		return
	_registered_materials.append(material)
	_material_base_ambient.append(_authored_ambient(material))
	# A newly registered material is still at its authored value, so force the
	# next push instead of waiting for the ramp to move past the threshold.
	_pushed_ambient_energy = -1.0


## Registers an unmanaged material that resolves its own cloud shadow. Safe to
## call more than once with the same material.
func register_cloud_shadow_material(material: ShaderMaterial) -> void:
	if material == null or _cloud_shadow_targets.has(material):
		return
	_cloud_shadow_targets.append(material)


func unregister_cloud_shadow_material(material: ShaderMaterial) -> void:
	var index := _cloud_shadow_targets.find(material)
	if index < 0:
		return
	if is_instance_valid(material):
		# Hand it back unshadowed rather than frozen under whatever the layer
		# happened to be doing.
		material.set_shader_parameter(&"u_cloud_shadow_strength", 0.0)
	_cloud_shadow_targets.remove_at(index)


func unregister_ambient_material(material: ShaderMaterial) -> void:
	var index := _registered_materials.find(material)
	if index < 0:
		return
	# Hand the material back exactly as it was authored.
	if is_instance_valid(material):
		material.set_shader_parameter(&"ambient_light", _material_base_ambient[index])
	_registered_materials.remove_at(index)
	_material_base_ambient.remove_at(index)


func _authored_ambient(material: ShaderMaterial) -> Color:
	var value: Variant = material.get_shader_parameter(&"ambient_light")
	if value is Color:
		return value
	# Unset parameters read back as null; the shader's own default is the
	# authored value in that case.
	if material.shader != null:
		var fallback: Variant = RenderingServer.shader_get_parameter_default(
			material.shader.get_rid(), &"ambient_light")
		if fallback is Color:
			return fallback
	return Color(0.1, 0.1, 0.1, 1.0)

#endregion


#region State snapshot and persistence

## Everything the cycle currently knows, in one dictionary. Allocated per call,
## so read it from a signal or a UI refresh rather than from a per-frame loop —
## the individual getters above are free.
func get_sky_state() -> Dictionary:
	_resolve_palette()
	var to_sun := get_direction_to_sun()
	return {
		"time_of_day": _time_of_day,
		"normalized_time": get_normalized_time(),
		"day_number": _day_number,
		"day_length_seconds": day_length_seconds,
		"phase": _phase,
		"phase_name": get_phase_name(),
		"is_night": is_night(),
		"day_factor": get_day_factor(),
		"direction_to_sun": to_sun,
		"direction_to_moon": -to_sun,
		"sun_elevation": get_sun_elevation(),
		"moon_elevation": get_moon_elevation(),
		"moon_phase": get_moon_phase(),
		"sun_color": get_sun_light_color(),
		"sun_energy": get_sun_light_energy(),
		"moon_energy": get_moon_light_energy(),
		"zenith_color": get_zenith_color(),
		"horizon_color": get_horizon_color(),
		"ambient_color": get_ambient_color(),
		"ambient_energy": get_ambient_energy(),
		"star_intensity": get_star_intensity(),
		"cloud_coverage": cloud_coverage,
		"cloud_altitude": cloud_altitude,
		"cloud_offset": _cloud_offset,
		"cloud_seed": _cloud_seed,
		"wind_direction": wind_direction,
		"wind_speed": wind_speed,
		"sun_occlusion": _sun_occlusion,
	}


## Save contract for the [code]saveable[/code] group. The day number is part of
## the payload because the stars and the cloud layout are derived from it, so a
## reloaded save comes back under the same sky it was written under.
func save_state() -> Dictionary:
	return {
		"time_of_day": _time_of_day,
		"day_number": _day_number,
		"day_length_seconds": day_length_seconds,
		"cloud_coverage": cloud_coverage,
		"time_running": time_running,
		"time_scale": time_scale,
	}


func load_state(state: Dictionary) -> void:
	day_length_seconds = maxf(float(state.get("day_length_seconds", day_length_seconds)), 0.001)
	cloud_coverage = clampf(float(state.get("cloud_coverage", cloud_coverage)), 0.0, 1.0)
	time_running = bool(state.get("time_running", time_running))
	time_scale = maxf(float(state.get("time_scale", time_scale)), 0.0)
	_time_of_day = fposmod(float(state.get("time_of_day", _time_of_day)), HOURS_PER_DAY)
	_day_number = int(state.get("day_number", _day_number))
	_reseed_day()
	if _built:
		_update_visuals(0.0)
	time_changed.emit(_time_of_day)
	day_changed.emit(_day_number)

#endregion
