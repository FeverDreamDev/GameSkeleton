@tool
class_name RTPaniniCamera3D
extends Camera3D

## Camera capability consumed by the shared Panini presentation pass.
##
## Godot interprets [member Camera3D.fov] on the axis selected by
## [member Camera3D.keep_aspect]. Keeping width makes the inherited value the
## horizontal display FOV directly. The authored camera and the Panini mapping
## therefore share one authoritative display angle; the post stack may widen
## only its private rectilinear capture camera to supply the required overscan.

const MIN_HORIZONTAL_FOV: float = 120.0
const DEFAULT_HORIZONTAL_FOV: float = 130.0
const MAX_HORIZONTAL_FOV: float = 140.0

## Opts this camera into Panini presentation when it is the source camera.
## Reusable cameras are conservative by default; the FPS scene enables it.
@export var panini_enabled: bool = false

## Requested horizontal display FOV in degrees. Finite out-of-range values are
## clamped to the supported Panini interval; NaN and infinities are rejected.
@export_range(120.0, 140.0, 0.1, "degrees") var display_horizontal_fov: float = (
		DEFAULT_HORIZONTAL_FOV):
	set(value):
		if not is_finite(value):
			return
		display_horizontal_fov = clampf(
			value, MIN_HORIZONTAL_FOV, MAX_HORIZONTAL_FOV)
		_apply_projection_contract()


func _init() -> void:
	_apply_projection_contract()


func _ready() -> void:
	# Reassert after scene deserialization in case authored native Camera3D
	# properties preceded this script's exported properties.
	_apply_projection_contract()


func set_display_horizontal_fov(value: float) -> void:
	display_horizontal_fov = value


func _apply_projection_contract() -> void:
	projection = Camera3D.PROJECTION_PERSPECTIVE
	keep_aspect = Camera3D.KEEP_WIDTH
	fov = display_horizontal_fov
