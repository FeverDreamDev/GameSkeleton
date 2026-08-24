extends MeshInstance3D

## Camera-following sky dome for [DayNightCycle3D]. Internal to the add-on.
##
## Ordinary unmanaged geometry, so it is invisible to Retro RT shadow and
## reflection rays and is never fogged. The dome exists at all because the
## Environment has to stay on BG_COLOR: a BG_SKY Environment would make
## RTSceneManager bake a reflection panorama on every change, and an animated
## sky would do that several times a second.

const SkyShader := preload("res://addons/day_night_cycle/shaders/day_night_sky.gdshader")

## Assigned in [method setup]. The owner pushes the per-frame sky state
## straight onto it, so there is no second copy of the uniform names here.
var sky_material: ShaderMaterial


func setup(radius: float) -> void:
	name = "SkyDome"
	# The dome is placed on the camera every render frame. Physics interpolation
	# would blend those writes across the tick and leave the sky trailing the
	# view, which is the same reason PlayerCamera detaches its own rig.
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# A box, not a sphere, and this is the whole reason the sky has no seams.
	#
	# The shader reconstructs its view direction from the interpolated world
	# position of the fragment. Across a planar face that interpolation is exact,
	# so the direction is exact per pixel. Across a curved sphere face it is a
	# chord rather than an arc, which leaves a small angular error that changes
	# discontinuously at every triangle edge -- and the cloud layer amplifies it,
	# because a ray-plane intersection turns a fraction of a degree into metres.
	# A sphere is also degenerate at its poles, where the triangles become slivers
	# radiating from a point, which is exactly where the seams looked worst.
	#
	# Twelve triangles, no tessellation to tune, and nothing to get wrong.
	var box := BoxMesh.new()
	box.size = Vector3(radius, radius, radius) * 2.0
	mesh = box

	sky_material = ShaderMaterial.new()
	sky_material.shader = SkyShader
	material_override = sky_material


## Recentres the dome. Position only: the shader derives its view direction from
## the world position of the fragment, so rotating the dome would rotate the sky.
func follow(camera_position: Vector3) -> void:
	global_position = camera_position
