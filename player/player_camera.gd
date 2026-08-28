class_name PlayerCamera
extends Node3D

## Dedicated First-Person Camera Controller for Godot 4.
## Manages mouse look, dynamic FOV, procedural head bob, strafe roll tilt,
## crouch eye height transitions, stair-step smoothing, and landing impact dip
## across decoupled pivots.
##
## Correctly separates physics-tick CharacterBody3D yaw from render-frame camera yaw,
## preserving 0-latency responsive mouse look without causing physics interpolation jitter.

#region Export Settings

@export_group("Mouse Look")
@export var mouse_sensitivity: float = 0.002
@export var mouse_smoothing: bool = false
@export var mouse_smooth_speed: float = 30.0
@export var min_pitch: float = -89.0
@export var max_pitch: float = 89.0
@export var invert_y: bool = false

@export_group("Eye Height & Crouch")
@export var standing_eye_height: float = 1.7
@export var crouch_eye_height: float = 0.9

@export_group("Dynamic FOV")
@export var dynamic_fov_enabled: bool = true
@export_range(120.0, 140.0, 0.1, "degrees") var base_horizontal_fov: float = (
		RTPaniniCamera3D.DEFAULT_HORIZONTAL_FOV)
@export var fov_transition_speed: float = 8.0

@export_group("Head Bobbing")
@export var head_bob_enabled: bool = true
@export var bob_frequency: float = 2.4
@export var bob_amplitude_y: float = 0.035
@export var bob_amplitude_x: float = 0.02
@export var bob_settle_speed: float = 10.0

@export_group("Camera Tilt")
@export var camera_tilt_enabled: bool = true
@export var max_tilt_angle: float = 2.0 ## In degrees
@export var tilt_speed: float = 8.0

@export_group("Landing Feedback")
@export var landing_feedback_enabled: bool = true
@export var landing_dip_amount: float = 0.015 ## Dip per m/s downward impact velocity
@export var max_landing_dip: float = 0.15
@export var landing_recovery_speed: float = 12.0

@export_group("Stair Step Smoothing")
@export var step_smoothing_enabled: bool = true ## Absorb the instant vertical pop of a stair step
@export var max_step_smoothing: float = 0.4
@export var step_recovery_speed: float = 18.0

#endregion

#region Node References

@onready var player: Player = get_parent() as Player
@onready var head: Node3D = $Head
@onready var bob_pivot: Node3D = $Head/BobPivot
@onready var landing_pivot: Node3D = $Head/BobPivot/LandingPivot
@onready var tilt_pivot: Node3D = $Head/BobPivot/LandingPivot/TiltPivot
@onready var camera: RTPaniniCamera3D = $Head/BobPivot/LandingPivot/TiltPivot/Camera3D

#endregion

#region Internal State

var target_pitch: float = 0.0
var target_yaw: float = 0.0
var smoothed_yaw: float = 0.0
var bob_timer: float = 0.0
var landing_offset: float = 0.0
var step_offset: float = 0.0

const SPRINT_HORIZONTAL_FOV_BOOST: float = 10.0

#endregion

#region Lifecycle

func _ready() -> void:
	if not player:
		push_warning("PlayerCamera expects its parent to be a Player node.")
		set_process(false)
		set_physics_process(false)
		return

	if camera:
		camera.set_display_horizontal_fov(base_horizontal_fov)
		target_pitch = camera.rotation.x

	target_yaw = player.rotation.y
	smoothed_yaw = target_yaw

	player.landed.connect(_on_player_landed)
	player.stepped_up.connect(_on_player_stepped_up)

	# Every part of this rig is driven on the render frame: yaw, pitch, eye height, bob, tilt
	# and the vertical dip. Under the project's global physics interpolation those writes get
	# blended across the tick (Camera3D even warns about being moved outside _physics_process),
	# which costs mouse look a frame of latency. Detaching the rig and disabling interpolation
	# for it makes the look frame-exact; sampling the body's *interpolated* transform each
	# render frame keeps the position as smooth as it was before.
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_follow_body(player.global_position, target_yaw)

	# Snap the eye to the correct height for the starting stance instead of easing in from
	# whatever the scene happened to store.
	_apply_eye_height()

## Snaps the rig back to a neutral view: level pitch, yaw matching the body, and every
## procedural offset cleared. Call after teleporting the body -- restarting a level, or loading
## a save -- so the new view does not begin wherever the old one was left, and so the bob and
## dip do not ease out of stale values on the first frame.
func reset_view() -> void:
	if not player:
		return

	target_yaw = player.rotation.y
	smoothed_yaw = target_yaw
	target_pitch = 0.0
	bob_timer = 0.0
	landing_offset = 0.0
	step_offset = 0.0

	if camera:
		camera.rotation.x = 0.0
		camera.set_display_horizontal_fov(base_horizontal_fov)
	if bob_pivot:
		bob_pivot.position = Vector3.ZERO
	if landing_pivot:
		landing_pivot.position = Vector3.ZERO
	if tilt_pivot:
		tilt_pivot.rotation.z = 0.0

	# The pivots are written every render frame, but a suspended player is not running one, so
	# they are cleared here rather than left to settle whenever gameplay resumes.
	_follow_body(player.global_position, target_yaw)
	_apply_eye_height()

## Restores a saved look direction.
##
## [method reset_view] levels the pitch, which is right for a fresh spawn and wrong for a load --
## a save taken looking down a stairwell should come back looking down it. Yaw is not a parameter
## because the body owns it: set [member Node3D.rotation] on the player first and this picks it up.
func apply_view(pitch: float) -> void:
	reset_view()
	target_pitch = clampf(pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))
	if camera:
		camera.rotation.x = target_pitch

func _unhandled_input(event: InputEvent) -> void:
	if not player or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	# The rig keeps running while control is away -- bob settles, the landing dip recovers, the
	# view still follows the body -- it just stops answering the mouse, so a cutscene can aim the
	# camera without the player fighting it.
	if not player.input_enabled:
		return

	if event is InputEventMouseMotion:
		var y_mult: float = -1.0 if invert_y else 1.0
		var yaw_delta: float = -event.relative.x * mouse_sensitivity
		var pitch_delta: float = -event.relative.y * mouse_sensitivity * y_mult

		target_yaw += yaw_delta
		target_pitch = clampf(
			target_pitch + pitch_delta,
			deg_to_rad(min_pitch),
			deg_to_rad(max_pitch)
		)

func _process(delta: float) -> void:
	if not player:
		return

	_handle_render_camera_look(delta)
	_apply_eye_height()
	_handle_dynamic_fov(delta)
	_handle_head_bob(delta)
	_handle_camera_tilt(delta)
	_handle_vertical_offsets(delta)

func _physics_process(_delta: float) -> void:
	if not player:
		return

	# Update physical CharacterBody3D yaw on the physics tick. The smoothed value is advanced
	# only in _process; decaying it here as well applied the filter twice per frame, which made
	# the effective smooth speed depend on the render/physics rate ratio.
	player.rotation.y = smoothed_yaw if mouse_smoothing else target_yaw

#endregion

#region Smoothing Helper

func _exp_decay(current: float, target: float, speed: float, delta: float) -> float:
	var weight: float = 1.0 - exp(-speed * delta)
	return lerpf(current, target, weight)

func _exp_decay_angle(current: float, target: float, speed: float, delta: float) -> float:
	var weight: float = 1.0 - exp(-speed * delta)
	return lerp_angle(current, target, weight)

#endregion

#region Render-Frame Camera Look

func _handle_render_camera_look(delta: float) -> void:
	# Calculate visual camera yaw offset relative to current physical body yaw
	var desired_visual_yaw: float = target_yaw
	if mouse_smoothing:
		smoothed_yaw = _exp_decay_angle(smoothed_yaw, target_yaw, mouse_smooth_speed, delta)
		desired_visual_yaw = smoothed_yaw
		if camera:
			camera.rotation.x = _exp_decay_angle(camera.rotation.x, target_pitch, mouse_smooth_speed, delta)
	else:
		# Keep the filter primed so toggling mouse_smoothing at runtime does not snap the view.
		smoothed_yaw = target_yaw
		if camera:
			camera.rotation.x = target_pitch

	# The rig is top_level, so it tracks the body explicitly. Reading the interpolated origin
	# (rather than the raw one) keeps the view gliding between physics ticks.
	_follow_body(player.get_global_transform_interpolated().origin, desired_visual_yaw)

func _follow_body(origin: Vector3, yaw: float) -> void:
	global_position = origin
	global_rotation = Vector3(0.0, yaw, 0.0)

#endregion

#region Crouch Eye Height

## Derived directly from the collision capsule rather than run through a second, independently
## configured lerp. The eye can no longer drift out of sync with the body during a transition.
func _apply_eye_height() -> void:
	if not head:
		return
	var span: float = player.standing_height - player.crouch_height
	var stand_ratio: float = 1.0
	if span > 0.0:
		stand_ratio = clampf((player.current_height - player.crouch_height) / span, 0.0, 1.0)
	head.position.y = lerpf(crouch_eye_height, standing_eye_height, stand_ratio)

#endregion

#region Dynamic FOV

## Sets the session's normal horizontal FOV. The camera capability owns range
## validation, while this controller owns whether the change snaps or eases in.
func set_base_horizontal_fov(value: float, immediate: bool = true) -> void:
	if not is_finite(value):
		return
	base_horizontal_fov = clampf(
		value,
		RTPaniniCamera3D.MIN_HORIZONTAL_FOV,
		RTPaniniCamera3D.MAX_HORIZONTAL_FOV)
	if immediate and camera:
		camera.set_display_horizontal_fov(base_horizontal_fov)


## Returns the angle actually used for rendering, including a partially blended
## sprint transition. Before the child camera is ready, the session base is the
## effective value.
func get_effective_horizontal_fov() -> float:
	return camera.display_horizontal_fov if camera else base_horizontal_fov


func _handle_dynamic_fov(delta: float) -> void:
	if not camera:
		return

	var target_fov: float = base_horizontal_fov
	# Reads is_sprinting rather than the movement state, so the FOV holds through a sprint
	# jump instead of snapping back the instant the state flips to AIRBORNE.
	if (
			dynamic_fov_enabled
			and player.is_sprinting
			and player.horizontal_speed > player.walk_speed + 0.5
	):
		target_fov = minf(
			base_horizontal_fov + SPRINT_HORIZONTAL_FOV_BOOST,
			RTPaniniCamera3D.MAX_HORIZONTAL_FOV)

	# Smooth the player-facing angle itself. Camera3D uses the same horizontal
	# degree value because RTPaniniCamera3D enforces KEEP_WIDTH.
	camera.set_display_horizontal_fov(_exp_decay(
		get_effective_horizontal_fov(), target_fov, fov_transition_speed, delta))

#endregion

#region Head Bob

func _handle_head_bob(delta: float) -> void:
	if not head_bob_enabled or not bob_pivot:
		return

	var speed: float = player.horizontal_speed

	if player.is_on_floor() and speed > 0.5:
		var speed_factor: float = speed / maxf(player.walk_speed, 0.001)
		bob_timer += delta * bob_frequency * speed_factor
		bob_timer = fmod(bob_timer, 2.0) # Bounded: the X term has a period of 2
		bob_pivot.position.y = sin(bob_timer * TAU) * bob_amplitude_y
		bob_pivot.position.x = cos(bob_timer * PI) * bob_amplitude_x
	else:
		bob_pivot.position.y = _exp_decay(bob_pivot.position.y, 0.0, bob_settle_speed, delta)
		bob_pivot.position.x = _exp_decay(bob_pivot.position.x, 0.0, bob_settle_speed, delta)
		# Resume from the neutral part of the cycle so the next step does not start mid-stride.
		bob_timer = 0.0

#endregion

#region Camera Tilt

func _handle_camera_tilt(delta: float) -> void:
	if not camera_tilt_enabled or not tilt_pivot:
		return

	# Uses the strafe input the controller actually consumed, so the tilt stays correct if
	# input is ever driven by something other than the local keyboard.
	var target_tilt: float = -player.move_input.x * deg_to_rad(max_tilt_angle)
	tilt_pivot.rotation.z = _exp_decay_angle(tilt_pivot.rotation.z, target_tilt, tilt_speed, delta)

#endregion

#region Vertical Offsets (Landing Dip + Stair Step Smoothing)

func _on_player_landed(impact_velocity: float) -> void:
	if not landing_feedback_enabled:
		return
	var dip: float = clampf(impact_velocity * landing_dip_amount, 0.02, max_landing_dip)
	landing_offset = -dip

## A stair step teleports the body up instantly. Offsetting the view down by the same amount
## and easing it back keeps the horizon steady while the feet climb.
func _on_player_stepped_up(height: float) -> void:
	if not step_smoothing_enabled:
		return
	step_offset = clampf(step_offset - height, -max_step_smoothing, 0.0)

func _handle_vertical_offsets(delta: float) -> void:
	if not landing_pivot:
		return
	landing_offset = _exp_decay(landing_offset, 0.0, landing_recovery_speed, delta)
	step_offset = _exp_decay(step_offset, 0.0, step_recovery_speed, delta)
	landing_pivot.position.y = landing_offset + step_offset

#endregion
