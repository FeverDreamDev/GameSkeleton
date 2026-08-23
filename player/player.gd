class_name Player
extends CharacterBody3D

## First-Person Character Controller for Godot 4.
## Manages locomotion states, collision-safe crouching, full-body collision stair stepping,
## deterministic acceleration, variable-height jumping, landing impact signals, and footstep events.
##
## Everything an animation layer needs is exposed through signals and the read-only helpers in
## the "Animation / Presentation API" region, so a rigged mesh can be driven without editing this.

#region Enums

enum MovementState {
	WALKING,
	SPRINTING,
	CROUCHING,
	AIRBORNE
}

#endregion

#region Signals

signal step_taken(foot: int, speed: float)
signal landed(impact_velocity: float)
signal jumped()
signal stepped_up(height: float)
signal crouch_changed(crouching: bool)
signal state_changed(new_state: MovementState, previous_state: MovementState)

#endregion

#region Export Settings

@export_group("Movement Speeds")
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var crouch_speed: float = 2.5

@export_group("Acceleration & Friction (m/s²)")
@export var ground_acceleration: float = 40.0
@export var ground_deceleration: float = 35.0
@export var air_acceleration: float = 10.0
@export var air_deceleration: float = 3.0
@export var air_speed_cap: float = 6.0

@export_group("Jump & Gravity")
@export var jump_height: float = 1.3
@export var jump_time_to_peak: float = 0.38
@export var jump_time_to_descent: float = 0.32
@export var coyote_time_duration: float = 0.15
@export var jump_buffer_duration: float = 0.15
@export var variable_jump_height: bool = true
@export var jump_cut_multiplier: float = 0.5
@export var max_fall_speed: float = 50.0
@export var jump_uncrouches: bool = true ## Jump while crouched stands up, then jumps once clear

@export_group("Step Up & Slopes")
@export var auto_step_enabled: bool = true
@export var max_step_height: float = 0.35 ## Maximum climbable step height
@export var floor_snap_distance: float = 0.2 ## Ground snapping distance for stairs & slopes
@export var snap_down_to_stairs: bool = true ## Extend snapping to max_step_height when descending stairs
@export_range(0.0, 89.0, 0.5, "degrees") var max_floor_angle: float = 45.0

@export_group("Crouch Settings")
@export var standing_height: float = 2.0
@export var crouch_height: float = 1.2
@export var crouch_transition_speed: float = 12.0
@export var toggle_crouch: bool = false

@export_group("Footsteps")
@export var footsteps_enabled: bool = true
@export var walk_step_distance: float = 1.8
@export var sprint_step_distance: float = 2.2
@export var crouch_step_distance: float = 1.3

@export_group("Input Actions")
## When true, a persistent application shell owns cursor and pause behavior.
## Movement/look still obey [member input_enabled], but this controller never
## captures or releases the mouse on its own.
@export var integrated_mode: bool = false
## Whether this controller captures the mouse as soon as it enters the tree. Turn it off when
## something else owns the cursor -- in this project that is [GameFlow].
@export var capture_mouse_on_ready: bool = true
@export var action_forward: StringName = "move_forward"
@export var action_backward: StringName = "move_backward"
@export var action_left: StringName = "move_left"
@export var action_right: StringName = "move_right"
@export var action_jump: StringName = "jump"
@export var action_crouch: StringName = "crouch"
@export var action_sprint: StringName = "sprint"

#endregion

#region Constants

## Inset applied to every clearance probe so resting contact with the floor, a step surface
## or a wall is not mistaken for an obstruction.
const CLEARANCE_SKIN: float = 0.01

## Extra lift used while probing for a step. Rising by exactly max_step_height leaves the
## capsule sole flush with the top of a max-height step, so the forward probe reports a
## collision and the tallest legal step becomes unclimbable.
const STEP_PROBE_HEADROOM: float = 0.04

#endregion

#region Node References

@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var capsule_shape: CapsuleShape3D = $CollisionShape3D.shape as CapsuleShape3D
@onready var ceiling_check: ShapeCast3D = get_node_or_null("CeilingCheck")
@onready var body_mesh: MeshInstance3D = get_node_or_null("MeshInstance3D")

#endregion

#region Internal State

var current_state: MovementState = MovementState.WALKING
var is_crouching: bool = false
var is_sprinting: bool = false
var wants_crouch: bool = false
var is_jumping: bool = false

var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var distance_traveled_since_step: float = 0.0
var foot_index: int = 0

var current_height: float = 2.0
var was_on_floor_last_frame: bool = true

## Whether this controller is currently steered by the player. Set through
## [method set_input_enabled] rather than written directly.
var input_enabled: bool = true

## Raw movement input this tick, in Godot screen convention (y < 0 is forward).
var move_input: Vector2 = Vector2.ZERO
## World-space normalized direction the player is asking to move in.
var wish_direction: Vector3 = Vector3.ZERO

# Reusable physics query objects. Allocating these per call produced avoidable per-frame
# garbage, since crouching and stair stepping each run clearance tests every tick.
var _clearance_query := PhysicsShapeQueryParameters3D.new()
var _clearance_shape := CapsuleShape3D.new()
var _probe_collision := KinematicCollision3D.new()
var _shadow_proxy_reference_height: float = 2.0
var _shadow_proxy_base_scale: Vector3 = Vector3.ONE

# Calculated jump kinematics
var jump_velocity: float:
	get:
		return (2.0 * jump_height) / jump_time_to_peak

var jump_gravity: float:
	get:
		return (2.0 * jump_height) / (jump_time_to_peak * jump_time_to_peak)

var fall_gravity: float:
	get:
		return (2.0 * jump_height) / (jump_time_to_descent * jump_time_to_descent)

#endregion

#region Animation / Presentation API

## Current ground speed in m/s.
var horizontal_speed: float:
	get:
		return Vector2(velocity.x, velocity.z).length()

## Ground speed as a fraction of the current stance top speed, ready to drive a 1D blend.
var normalized_speed: float:
	get:
		var top: float = get_target_speed()
		return 0.0 if top <= 0.0 else clampf(horizontal_speed / top, 0.0, 1.0)

## Actual velocity in body-local space as (strafe, forward), scaled against walk_speed.
## Feed straight into a 2D locomotion BlendSpace once a rig is attached.
func get_local_velocity_2d() -> Vector2:
	var local: Vector3 = global_basis.inverse() * Vector3(velocity.x, 0.0, velocity.z)
	return Vector2(local.x, -local.z) / maxf(walk_speed, 0.001)

## Top speed for the current stance, before acceleration is applied.
func get_target_speed() -> float:
	if is_crouching:
		return crouch_speed
	if is_sprinting:
		return sprint_speed
	return walk_speed

#endregion

#region Control Ownership

## Hands control to or takes it from the player.
##
## This is not the same as disabling the node. The body keeps simulating -- gravity, momentum,
## floor contact and every animation-facing signal carry on -- it just stops being steered. That is
## what a cutscene wants: a character who coasts to a stop and stands there, not one who freezes
## mid-stride and stops casting a shadow.
##
## Whatever is currently held down is released on the way out, so the player does not resume a
## sprint they stopped asking for two minutes ago.
func set_input_enabled(enabled: bool) -> void:
	if input_enabled == enabled:
		return
	input_enabled = enabled
	if not enabled:
		move_input = Vector2.ZERO
		wish_direction = Vector3.ZERO
		is_sprinting = false
		jump_buffer_timer = 0.0

## Input readers funnel through these four so there is exactly one place control is taken away,
## rather than a gate to forget at each call site.
func _action_pressed(action: StringName) -> bool:
	return input_enabled and Input.is_action_pressed(action)

func _action_just_pressed(action: StringName) -> bool:
	return input_enabled and Input.is_action_just_pressed(action)

func _action_just_released(action: StringName) -> bool:
	return input_enabled and Input.is_action_just_released(action)

func _movement_vector() -> Vector2:
	if not input_enabled:
		return Vector2.ZERO
	return Input.get_vector(action_left, action_right, action_forward, action_backward)

#endregion

#region Lifecycle

func _ready() -> void:
	_setup_fallback_inputs()
	# Lets triggers and other flow components recognise the player without the addon needing to
	# know this class exists.
	add_to_group(&"player")
	# Off in main.tscn, where GameFlow hands the cursor back and forth around menus and a player
	# that grabs it here would fight that. Left on by default so player.tscn opened on its own
	# still has mouse look.
	if not integrated_mode and capture_mouse_on_ready:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	standing_height = maxf(standing_height, crouch_height)
	_localize_shared_resources()
	_configure_shadow_proxy()

	current_height = standing_height
	_apply_height(current_height)

	_clearance_shape.radius = maxf((capsule_shape.radius if capsule_shape else 0.4) - CLEARANCE_SKIN, 0.01)
	_clearance_query.shape = _clearance_shape
	_clearance_query.exclude = [get_rid()]

	# CharacterBody3D floor & snapping configuration
	floor_snap_length = floor_snap_distance
	floor_max_angle = deg_to_rad(max_floor_angle)
	floor_stop_on_slope = true
	floor_constant_speed = true

	_configure_ceiling_check()

## The collision capsule is mutated while crouching, so it must be local to this
## player. The render/shadow mesh deliberately stays shared and immutable: RT
## acceleration structures can follow transform changes, but mesh topology
## changes require an expensive rebuild.
func _localize_shared_resources() -> void:
	if collision_shape and collision_shape.shape is CapsuleShape3D:
		collision_shape.shape = collision_shape.shape.duplicate()
		capsule_shape = collision_shape.shape

func _configure_shadow_proxy() -> void:
	if not body_mesh:
		return
	_shadow_proxy_base_scale = body_mesh.scale
	var capsule_mesh := body_mesh.mesh as CapsuleMesh
	if capsule_mesh:
		_shadow_proxy_reference_height = maxf(capsule_mesh.height, 0.001)

## Sweep only the band the head passes through while standing up. The scene values were baked
## for the default 1.2 m / 2.0 m heights and overshot the standing head by the probe radius,
## reporting a false ceiling for anything hanging just above head height.
func _configure_ceiling_check() -> void:
	if not ceiling_check:
		return
	var sphere := ceiling_check.shape as SphereShape3D
	var probe_radius: float = sphere.radius if sphere else 0.38
	ceiling_check.position = Vector3(0.0, crouch_height - probe_radius, 0.0)
	ceiling_check.target_position = Vector3(0.0, standing_height - crouch_height, 0.0)
	ceiling_check.collision_mask = collision_mask
	ceiling_check.add_exception(self)
	ceiling_check.enabled = false # Polled on demand via force_shapecast_update()

func _unhandled_input(event: InputEvent) -> void:
	if integrated_mode:
		return
	# Mouse lock / unlock toggle with Escape (ui_cancel)
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	# Re-capture mouse on click when window is focused. Gated on control: clicking during a
	# cutscene, or on a menu that reached this far, must not steal the cursor back.
	if input_enabled and event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return

func _physics_process(delta: float) -> void:
	var previous_state: MovementState = current_state

	_handle_crouch(delta)
	_handle_jump_and_gravity(delta)
	_handle_movement(delta)

	_update_locomotion_state()

	# Attempt step-up before move_and_slide (elevates character so move_and_slide handles horizontal displacement)
	if auto_step_enabled and is_on_floor() and not is_jumping:
		_try_step_up(delta, wish_direction, false)

	# Floor snapping active only when grounded and not actively jumping
	if is_jumping or not is_on_floor():
		floor_snap_length = 0.0
	else:
		floor_snap_length = _grounded_snap_length()

	# Captured before move_and_slide cancels it against the floor.
	var impact_velocity: float = velocity.y

	move_and_slide()

	# Attempt step-up after move_and_slide if we collided with a wall/step
	if auto_step_enabled and is_on_wall() and is_on_floor() and not is_jumping:
		_try_step_up(delta, wish_direction, true)

	_check_landing_transition(impact_velocity)
	_handle_footsteps(delta)

	was_on_floor_last_frame = is_on_floor()

	if current_state != previous_state:
		state_changed.emit(current_state, previous_state)

#endregion

#region Locomotion State

func _update_locomotion_state() -> void:
	if not is_on_floor():
		current_state = MovementState.AIRBORNE
	elif is_crouching:
		current_state = MovementState.CROUCHING
	elif is_sprinting:
		current_state = MovementState.SPRINTING
	else:
		current_state = MovementState.WALKING

## Descending stairs with a snap length shorter than the step height makes the body go briefly
## airborne on every step, which reads as a stutter and interrupts footsteps.
func _grounded_snap_length() -> float:
	if snap_down_to_stairs and auto_step_enabled:
		return maxf(floor_snap_distance, max_step_height)
	return floor_snap_distance

#endregion

#region Capsule Clearance Verification (Full-Shape Query)

func _capsule_fits_at(target_pos: Vector3, shape_height: float) -> bool:
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if not space_state:
		return true

	# The probe is inset by CLEARANCE_SKIN on every axis. A probe sized exactly like the body
	# reports the floor it rests on, and any wall it leans against, as an obstruction, which
	# locks the player in a crouch and vetoes every stair step.
	var probe_height: float = maxf(shape_height - CLEARANCE_SKIN * 2.0, _clearance_shape.radius * 2.0)
	_clearance_shape.height = probe_height
	_clearance_query.collision_mask = collision_mask
	# Identity basis: only the position matters here, and inheriting the body basis would break
	# if a rigged visual ever scales or tilts the root node.
	_clearance_query.transform = Transform3D(Basis(), target_pos + Vector3(0.0, shape_height * 0.5, 0.0))

	return space_state.intersect_shape(_clearance_query, 1).is_empty()

func _can_stand_up() -> bool:
	return _capsule_fits_at(global_position, standing_height)

#endregion

#region Crouching (Collision-Safe)

func _handle_crouch(delta: float) -> void:
	if toggle_crouch:
		if _action_just_pressed(action_crouch):
			wants_crouch = not wants_crouch
	else:
		wants_crouch = _action_pressed(action_crouch)

	# Jumping out of a crouch: drop the crouch here, and the buffered jump fires on whichever
	# tick the standing capsule actually clears.
	if jump_uncrouches and wants_crouch and _action_just_pressed(action_jump):
		wants_crouch = false

	var blocked_by_ceiling: bool = false
	if is_crouching and not wants_crouch:
		# Cheap early test with ShapeCast3D
		if ceiling_check:
			ceiling_check.force_shapecast_update()
			blocked_by_ceiling = ceiling_check.is_colliding()

		# Full standing capsule verification
		if not blocked_by_ceiling:
			blocked_by_ceiling = not _can_stand_up()

	var crouching_now: bool = wants_crouch or blocked_by_ceiling
	if crouching_now != is_crouching:
		is_crouching = crouching_now
		crouch_changed.emit(is_crouching)

	# Smoothly resize collision capsule anchored at feet
	var target_h: float = crouch_height if is_crouching else standing_height
	if not is_equal_approx(current_height, target_h):
		var weight: float = 1.0 - exp(-crouch_transition_speed * delta)
		current_height = lerpf(current_height, target_h, weight)
		if absf(current_height - target_h) < 0.001:
			current_height = target_h # Settle instead of approaching asymptotically forever
		_apply_height(current_height)

func _apply_height(height: float) -> void:
	if capsule_shape:
		capsule_shape.height = height
		collision_shape.position.y = height * 0.5
	# Keep the fixed shadow proxy in sync through its transform only. Mutating a
	# PrimitiveMesh here would invalidate the RT BLAS on every crouch frame.
	if body_mesh:
		body_mesh.position.y = height * 0.5
		var next_scale := _shadow_proxy_base_scale
		next_scale.y *= height / _shadow_proxy_reference_height
		body_mesh.scale = next_scale

## Snaps the stance to a known state, for a teleport or a loaded save.
##
## The transition above eases the capsule between heights over several ticks, and the player is
## suspended while a level is being set up, so a restored crouch would otherwise spend its first
## frames standing at full height -- long enough to be pushed out of the tunnel it was saved in.
##
## What happens after that is still up to [method _handle_crouch]. With [member toggle_crouch]
## off it reads the crouch key every tick, so a player who is not holding it stands back up as
## soon as they have the room, and stays crouched when they do not. That is the right answer for
## a hold-to-crouch control, so this only has to be correct for the handover.
func apply_stance(crouching: bool, height: float) -> void:
	is_crouching = crouching
	wants_crouch = crouching
	current_height = clampf(height, crouch_height, standing_height)
	_apply_height(current_height)

#endregion

#region Jump & Gravity

func _handle_jump_and_gravity(delta: float) -> void:
	if is_on_floor():
		coyote_timer = coyote_time_duration
		is_jumping = false
	else:
		coyote_timer = maxf(0.0, coyote_timer - delta)

	if _action_just_pressed(action_jump):
		jump_buffer_timer = jump_buffer_duration
	else:
		jump_buffer_timer = maxf(0.0, jump_buffer_timer - delta)

	# Variable jump height: release early to cut upward velocity
	if variable_jump_height and _action_just_released(action_jump) and velocity.y > 0.0:
		velocity.y *= jump_cut_multiplier

	# Apply gravity with distinct rising vs falling acceleration
	if not is_on_floor():
		var current_gravity: float = fall_gravity if velocity.y < 0.0 else jump_gravity
		velocity.y -= current_gravity * delta
		velocity.y = maxf(velocity.y, -max_fall_speed)

	# Execute jump
	if jump_buffer_timer > 0.0 and coyote_timer > 0.0 and not is_crouching:
		velocity.y = jump_velocity
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		is_jumping = true
		jumped.emit()

#endregion

#region Movement & Acceleration

func _handle_movement(delta: float) -> void:
	move_input = _movement_vector()
	wish_direction = (global_basis * Vector3(move_input.x, 0.0, move_input.y)).normalized()

	# Sprint requires forward input on the ground, but is retained through a jump so FOV and
	# animation state do not pop the moment the feet leave the floor.
	var wants_sprint: bool = (
		_action_pressed(action_sprint)
		and move_input.y < -0.1
		and not is_crouching
	)
	if is_on_floor():
		is_sprinting = wants_sprint
	else:
		is_sprinting = is_sprinting and wants_sprint

	var target_speed: float = get_target_speed()

	if is_on_floor():
		# Ground movement with deterministic move_toward (m/s²)
		if wish_direction.length_squared() > 0.001:
			var target_vel: Vector3 = wish_direction * target_speed
			velocity.x = move_toward(velocity.x, target_vel.x, ground_acceleration * delta)
			velocity.z = move_toward(velocity.z, target_vel.z, ground_acceleration * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, ground_deceleration * delta)
			velocity.z = move_toward(velocity.z, 0.0, ground_deceleration * delta)
	else:
		# Air control: air_speed_cap limits input generation while preserving existing momentum
		if wish_direction.length_squared() > 0.001:
			var horiz_vel := Vector3(velocity.x, 0.0, velocity.z)
			var current_speed_in_wish_dir: float = horiz_vel.dot(wish_direction)
			var add_speed: float = air_speed_cap - current_speed_in_wish_dir
			if add_speed > 0.0:
				var accel_amount: float = air_acceleration * delta * air_speed_cap
				var applied_speed: float = minf(accel_amount, add_speed)
				velocity.x += wish_direction.x * applied_speed
				velocity.z += wish_direction.z * applied_speed
		else:
			velocity.x = move_toward(velocity.x, 0.0, air_deceleration * delta)
			velocity.z = move_toward(velocity.z, 0.0, air_deceleration * delta)

#endregion

#region Full-Body Collision-Tested Stair Stepping

func _try_step_up(delta: float, wish_dir: Vector3, is_post_slide: bool) -> bool:
	if not is_on_floor() or velocity.y > 0.01:
		return false

	# Determine forward probe direction
	var move_dir: Vector3 = wish_dir
	if move_dir.is_zero_approx():
		var horiz_vel := Vector3(velocity.x, 0.0, velocity.z)
		if horiz_vel.length_squared() > 0.01:
			move_dir = horiz_vel.normalized()
		else:
			return false

	# Two distances are needed here. The short one is how far the body actually wants to travel
	# this tick and answers "am I blocked?". The long one answers "what would I land on?" and has
	# to carry the capsule *axis* past the lip of the step: probing any shorter leaves the rounded
	# sole overhanging the edge, so the downward probe returns the edge bevel instead of the tread
	# and its steep normal then fails the walkable-surface test.
	var probe_radius: float = capsule_shape.radius if capsule_shape else 0.4
	var move_distance: float = maxf(horizontal_speed * delta, 0.08)
	var probe_distance: float = maxf(move_distance, probe_radius + CLEARANCE_SKIN)
	var horiz_step: Vector3 = move_dir * move_distance

	var body_transform: Transform3D = global_transform

	# Step 1: Confirm something is actually blocking forward movement, and that it is not a
	# walkable slope the standard slope solver already handles.
	if is_post_slide:
		# The pre-slide probe below is skipped on this path, so _probe_collision holds no
		# result yet. Reuse the normal move_and_slide already resolved instead of reading an
		# empty KinematicCollision3D.
		var slide_normal: Vector3 = get_wall_normal()
		if not slide_normal.is_zero_approx() and slide_normal.angle_to(Vector3.UP) <= floor_max_angle:
			return false
	else:
		if not test_move(body_transform, horiz_step, _probe_collision):
			return false
		if _probe_collision.get_collision_count() > 0:
			var wall_normal: Vector3 = _probe_collision.get_normal()
			if wall_normal.angle_to(Vector3.UP) <= floor_max_angle:
				return false

	# Step 2: Rise to the probe height (max_step_height plus a sliver of headroom)
	var up_step: Vector3 = Vector3.UP * (max_step_height + STEP_PROBE_HEADROOM)
	var up_transform: Transform3D = body_transform
	if test_move(up_transform, up_step, _probe_collision):
		var travel_up: float = _probe_collision.get_travel().y
		if travel_up < 0.05:
			return false # Blocked immediately by low ceiling
		up_step = Vector3.UP * (travel_up - 0.001)

	up_transform.origin += up_step

	# Step 3: Reach forward from the elevated position. A partial reach is fine — a narrow tread
	# still counts — but failing to clear this tick's own travel means the obstacle is simply
	# taller than max_step_height.
	var forward_reach: float = probe_distance
	if test_move(up_transform, move_dir * probe_distance, _probe_collision):
		forward_reach = _probe_collision.get_travel().length()
		if forward_reach < move_distance:
			return false # Blocked in front (obstacle is taller than max_step_height)

	var fwd_transform: Transform3D = up_transform
	fwd_transform.origin += move_dir * forward_reach

	# Step 4: Test downward movement to locate landing floor surface
	var down_step: Vector3 = Vector3.DOWN * (up_step.y + 0.05)
	if not test_move(fwd_transform, down_step, _probe_collision):
		return false # No floor found beneath step

	# Step 5: Verify landing surface is walkable
	var landing_normal: Vector3 = _probe_collision.get_normal()
	if landing_normal.angle_to(Vector3.UP) > floor_max_angle:
		return false # Landing surface too steep

	# Step 6: Verify full capsule fits at landing position using intersect_shape
	var landing_pos: Vector3 = fwd_transform.origin + _probe_collision.get_travel()
	if not _capsule_fits_at(landing_pos, current_height):
		return false # Capsule overlaps geometry at landing position

	var actual_step_height: float = landing_pos.y - body_transform.origin.y
	# The slack absorbs float error so a step measuring exactly max_step_height still passes.
	if actual_step_height <= 0.01 or actual_step_height > max_step_height + 0.001:
		return false

	# Step 7: Commit the rise only, never the probe's horizontal reach — that reach is sized for
	# reliable surface detection, not for travel, and teleporting the body a capsule radius
	# forward in one tick reads as a lurch. Step 2 already proved the body can rise this far in
	# place, so the vertical move is safe on both paths; horizontal travel is left to
	# move_and_slide (this tick when called before it, next tick when called after).
	global_position.y = landing_pos.y

	stepped_up.emit(actual_step_height)
	return true

#endregion

#region Landing Feedback Signals

func _check_landing_transition(impact_velocity: float) -> void:
	if not was_on_floor_last_frame and is_on_floor():
		# Only downward motion counts; impact_velocity is sampled before move_and_slide.
		var impact_speed: float = absf(minf(impact_velocity, 0.0))
		if impact_speed > 1.5:
			landed.emit(impact_speed)

#endregion

#region Footstep Signals

func _handle_footsteps(delta: float) -> void:
	if not footsteps_enabled or not is_on_floor():
		return

	var speed: float = horizontal_speed
	if speed < 0.2:
		return

	var current_interval: float = walk_step_distance
	if current_state == MovementState.SPRINTING:
		current_interval = sprint_step_distance
	elif current_state == MovementState.CROUCHING:
		current_interval = crouch_step_distance

	distance_traveled_since_step += speed * delta
	if distance_traveled_since_step >= current_interval:
		distance_traveled_since_step = 0.0
		foot_index = 1 - foot_index
		step_taken.emit(foot_index, speed)

#endregion

#region Input Map Fallback

func _setup_fallback_inputs() -> void:
	var defaults: Dictionary = {
		action_forward: [KEY_W, KEY_UP],
		action_backward: [KEY_S, KEY_DOWN],
		action_left: [KEY_A, KEY_LEFT],
		action_right: [KEY_D, KEY_RIGHT],
		action_jump: [KEY_SPACE],
		action_crouch: [KEY_CTRL, KEY_C],
		action_sprint: [KEY_SHIFT],
	}

	for action: StringName in defaults:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key: Key in defaults[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action, event)

#endregion
