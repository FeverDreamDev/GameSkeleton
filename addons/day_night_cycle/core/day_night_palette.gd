@tool
class_name DayNightPalette
extends Resource

## Authorable colour and intensity ramps for [DayNightCycle3D].
##
## Every ramp is sampled by [b]body height[/b] rather than by clock time, so
## retuning [member DayNightCycle3D.sun_tilt_degrees] or the cycle length moves
## the colours with the sun instead of leaving them behind. The parameter is
## [method height_parameter] of the body in question: [code]0.0[/code] is the
## body at its lowest, roughly [code]0.42[/code] is the horizon, and
## [code]1.0[/code] is directly overhead. Sunrise and sunset therefore share a
## ramp position and look alike, which is both cheaper and correct.
##
## A palette left entirely unauthored still works: [method resolve] fills in a
## complete default set the first time the cycle asks for one. Assign only the
## ramps you actually want to change.

## Body elevation sine mapped onto the 0..1 ramp parameter. Below
## [constant HEIGHT_MIN] the body is far enough down that every ramp has
## bottomed out; above [constant HEIGHT_MAX] it reads as high sun.
const HEIGHT_MIN := -0.25
const HEIGHT_MAX := 0.35

@export_group("Sky")
## Colour straight overhead.
@export var zenith_gradient: Gradient
## Colour at the skyline. [DayNightCycle3D] also publishes this to
## [member Environment.background_color], which is what the Retro RT distance
## fog resolves to, so terrain fades into exactly the band it meets.
@export var horizon_gradient: Gradient
## Colour below the skyline. Rarely seen directly, but it is the lower half of
## the panorama a mirror reflects, so it should read as the ground the level
## actually has rather than as generic grey.
@export var ground_gradient: Gradient
## Tint of the halo around the sun.
@export var sun_glow_gradient: Gradient

@export_group("Lights")
## Colour of the sun [DirectionalLight3D].
@export var sun_light_gradient: Gradient
## Energy of the sun light, as a fraction of [member sun_peak_energy].
@export var sun_energy_curve: Curve
@export var sun_peak_energy: float = 1.15
## Colour of the moon [DirectionalLight3D], and of its disc in the sky.
@export var moon_light_color: Color = Color(0.62, 0.72, 1.0)
## Energy of the moon light, as a fraction of [member moon_peak_energy], sampled
## by the moon height rather than the sun height.
@export var moon_energy_curve: Curve
## Well above a physically faint moon on purpose. This project grades with a
## raised contrast and has no global illumination, so anything under about half
## the sun energy crushes to solid black on these dark materials; a numerically
## honest moon would render an unplayable night rather than a dim one.
@export var moon_peak_energy: float = 0.85

@export_group("Ambient")
## Fill colour. Reaches unmanaged forward geometry through
## [member Environment.ambient_light_color] and managed Blinn-Phong surfaces
## through their [code]ambient_light[/code] shader parameter.
@export var ambient_gradient: Gradient
@export var ambient_energy_curve: Curve
## Tuned so noon lands on roughly the fill the level had before the cycle
## existed: the old flat Environment supplied its background colour as ambient.
@export var ambient_peak_energy: float = 0.55

@export_group("Stars")
## Star brightness as a fraction of [member star_peak_intensity]. Reaching
## exactly zero lets the sky shader branch the whole star field out by day.
@export var star_intensity_curve: Curve
@export var star_peak_intensity: float = 1.0

## Maps a direction towards a body onto the 0..1 ramp parameter every sampler
## here takes.
static func height_parameter(direction_to_body: Vector3) -> float:
	return clampf(
		(direction_to_body.y - HEIGHT_MIN) / (HEIGHT_MAX - HEIGHT_MIN), 0.0, 1.0)


## Fills in any ramp that was left unassigned. Idempotent, and cheap enough to
## call from [method Node._ready]; it allocates only what is actually missing.
func resolve() -> void:
	if zenith_gradient == null:
		zenith_gradient = _gradient([
			[0.00, Color(0.030, 0.042, 0.095)],
			[0.35, Color(0.055, 0.080, 0.160)],
			[0.45, Color(0.130, 0.180, 0.330)],
			[0.60, Color(0.170, 0.320, 0.580)],
			[1.00, Color(0.150, 0.330, 0.660)],
		])
	if horizon_gradient == null:
		horizon_gradient = _gradient([
			[0.00, Color(0.035, 0.048, 0.090)],
			[0.34, Color(0.140, 0.110, 0.155)],
			[0.45, Color(0.720, 0.360, 0.190)],
			[0.55, Color(0.780, 0.630, 0.470)],
			[0.75, Color(0.620, 0.720, 0.825)],
			[1.00, Color(0.560, 0.700, 0.850)],
		])
	if ground_gradient == null:
		ground_gradient = _gradient([
			[0.00, Color(0.014, 0.020, 0.018)],
			[0.45, Color(0.075, 0.085, 0.055)],
			[1.00, Color(0.115, 0.200, 0.075)],
		])
	if sun_glow_gradient == null:
		sun_glow_gradient = _gradient([
			[0.00, Color(0.000, 0.000, 0.000)],
			[0.36, Color(0.350, 0.200, 0.280)],
			[0.45, Color(1.000, 0.450, 0.180)],
			[0.60, Color(1.000, 0.720, 0.420)],
			[1.00, Color(0.850, 0.880, 0.950)],
		])
	if sun_light_gradient == null:
		sun_light_gradient = _gradient([
			[0.00, Color(1.000, 0.380, 0.160)],
			[0.45, Color(1.000, 0.420, 0.180)],
			[0.52, Color(1.000, 0.620, 0.340)],
			[0.64, Color(1.000, 0.850, 0.680)],
			[1.00, Color(1.000, 0.955, 0.870)],
		])
	if ambient_gradient == null:
		# Night is roughly a fifth of noon and shifted well into the blue. Going
		# much darker reads as broken rather than as night: the moon light alone
		# is a fifth of the sun, and there is no other fill down here.
		ambient_gradient = _gradient([
			[0.00, Color(0.160, 0.200, 0.340)],
			[0.42, Color(0.230, 0.200, 0.230)],
			[0.52, Color(0.330, 0.290, 0.300)],
			[1.00, Color(0.420, 0.500, 0.620)],
		])
	if sun_energy_curve == null:
		# The sun keeps a little energy just under the skyline, which is what
		# rakes warm light across the ground through sunset. It reaches a flat
		# zero well before the moon rises, so Retro RT hands its single shadow
		# ray from one to the other without an explicit switch.
		sun_energy_curve = _curve([
			[0.00, 0.0], [0.36, 0.0], [0.44, 0.30], [0.58, 0.70], [1.00, 1.0],
		])
	if moon_energy_curve == null:
		moon_energy_curve = _curve([
			[0.00, 0.0], [0.40, 0.0], [0.52, 0.55], [1.00, 1.0],
		])
	if ambient_energy_curve == null:
		ambient_energy_curve = _curve([
			[0.00, 0.45], [0.32, 0.60], [0.46, 0.88], [0.65, 0.96], [1.00, 1.0],
		])
	if star_intensity_curve == null:
		star_intensity_curve = _curve([
			[0.00, 1.0], [0.18, 1.0], [0.44, 0.0], [1.00, 0.0],
		])


func sample_zenith(height: float) -> Color:
	return zenith_gradient.sample(height)


func sample_horizon(height: float) -> Color:
	return horizon_gradient.sample(height)


func sample_ground(height: float) -> Color:
	return ground_gradient.sample(height)


func sample_sun_glow(height: float) -> Color:
	return sun_glow_gradient.sample(height)


func sample_sun_light(height: float) -> Color:
	return sun_light_gradient.sample(height)


func sample_sun_energy(height: float) -> float:
	return maxf(sun_energy_curve.sample(height), 0.0) * maxf(sun_peak_energy, 0.0)


func sample_moon_energy(moon_height: float) -> float:
	return maxf(moon_energy_curve.sample(moon_height), 0.0) * maxf(moon_peak_energy, 0.0)


func sample_ambient(height: float) -> Color:
	return ambient_gradient.sample(height)


func sample_ambient_energy(height: float) -> float:
	return maxf(ambient_energy_curve.sample(height), 0.0) * maxf(ambient_peak_energy, 0.0)


func sample_star_intensity(height: float) -> float:
	return maxf(star_intensity_curve.sample(height), 0.0) * maxf(star_peak_intensity, 0.0)


func _gradient(stops: Array) -> Gradient:
	var gradient := Gradient.new()
	# A fresh Gradient already owns two points and refuses to drop below two, so
	# the first pair is overwritten in place rather than added.
	gradient.set_offset(0, float(stops[0][0]))
	gradient.set_color(0, stops[0][1] as Color)
	gradient.set_offset(1, float(stops[1][0]))
	gradient.set_color(1, stops[1][1] as Color)
	for index in range(2, stops.size()):
		gradient.add_point(float(stops[index][0]), stops[index][1] as Color)
	return gradient


func _curve(points: Array) -> Curve:
	var curve := Curve.new()
	for point: Array in points:
		# Linear tangents: a ramp that reads as a straight line in the inspector
		# should behave as one. The default free/zero tangents would flatten the
		# curve at every control point and stall the sunrise.
		var index := curve.add_point(Vector2(float(point[0]), float(point[1])))
		curve.set_point_left_mode(index, Curve.TANGENT_LINEAR)
		curve.set_point_right_mode(index, Curve.TANGENT_LINEAR)
	return curve
