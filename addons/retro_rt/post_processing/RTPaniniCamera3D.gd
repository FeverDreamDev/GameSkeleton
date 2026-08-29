@tool
class_name RTPaniniCamera3D
extends Camera3D

## Camera capability consumed by the shared Panini presentation pass.
##
## Godot interprets [member Camera3D.fov] on the axis selected by
## [member Camera3D.keep_aspect]. Keeping width makes the inherited value the
## horizontal display FOV directly, so the authored camera and the Panini mapping
## share one authoritative display angle; the post stack may widen only its
## private rectilinear capture camera to supply the required overscan.
##
## That angle is now a single fixed value rather than a range. The projection is
## tuned for exactly one FOV, and every part of that tuning -- the target's
## aspect, its pixel budget, and the FSR2 render scale derived from it -- is
## chosen for [constant HORIZONTAL_FOV]. A camera free to move within a range
## forced the post stack to size its render target from the widest angle the
## camera might ever reach, which left the frustum wider than the projection
## could sample at every narrower angle: at the former 130-degree default the
## capture spent 14.3 percent of its rendered rows and ray dispatch outside
## anything the mapping read. Fixing the angle spends that budget on the image
## instead.

## The one display angle this project renders. Changing it invalidates the
## measured target sizing in `RT_PIPELINE.md`; see **Fixed-budget Panini target
## and FSR2 quality** before touching it.
const HORIZONTAL_FOV: float = 140.0

## Opts this camera into Panini presentation when it is the source camera.
## Reusable cameras are conservative by default; the FPS scene enables it.
@export var panini_enabled: bool = false

## Horizontal display FOV in degrees. Fixed; see the class docstring.
##
## The post stack discovers this by name through [method Object.get_property_list],
## so it stays a property rather than becoming a bare constant. The setter accepts
## and discards writes because scene files are data: an authored value left over
## from when this was adjustable must not fail to load.
var display_horizontal_fov: float = HORIZONTAL_FOV:
	set(_value):
		pass
	get:
		return HORIZONTAL_FOV

## The widest horizontal display FOV this camera will ever request, which is the
## same fixed angle. The post stack sizes its render target from this, and the
## two agreeing is what removes the unsampled frustum described above.
var max_display_horizontal_fov: float = HORIZONTAL_FOV:
	set(_value):
		pass
	get:
		return HORIZONTAL_FOV


func _init() -> void:
	_apply_projection_contract()


func _ready() -> void:
	# Reassert after scene deserialization in case authored native Camera3D
	# properties preceded this script's exported properties.
	_apply_projection_contract()


func _apply_projection_contract() -> void:
	projection = Camera3D.PROJECTION_PERSPECTIVE
	keep_aspect = Camera3D.KEEP_WIDTH
	fov = HORIZONTAL_FOV
