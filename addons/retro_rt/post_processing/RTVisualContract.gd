@tool
extends Resource
class_name RTVisualContract

## Renderer-independent visual settings shared by both pipelines, plus the static
## viewport-state helpers the post stack uses to capture, normalize and restore
## the root Viewport.
##
## The root and canvas passes remain native and non-temporal. The private 3D scene
## capture is the one exception: built-in FSR2 supplies temporal anti-aliasing and
## optional reconstruction before any canvas post pass. MSAA cannot be combined
## with the hardware RT visibility-buffer path because its resolve would average
## packed IDs, so both viewport helpers keep 2D/3D MSAA and separate AA disabled.
##
## [member Viewport.fsr_sharpness] belongs to that contract rather than to the
## inherited project default, because Godot's FSR2 integration runs RCAS with it.

## RCAS attenuation Godot hands to FSR2, in stops: 0.0 is the sharpest image and
## every whole number above it halves the sharpening.
##
## Godot applies this whenever [constant Viewport.SCALING_3D_MODE_FSR2] is
## selected, so leaving it unset does not mean "no sharpener" -- it means the
## project default sharpens the capture without the stack declaring that it does.
## The value here is the engine default, so pinning it changes no shipped pixel;
## what it changes is that the sharpener is now owned, restored and validated
## like every other property in this contract.
##
## Worth knowing before tuning it: RCAS runs at the rectilinear capture
## resolution, upstream of the Panini pass that still magnifies screen center by
## about 1.95x horizontally at the shipped settings. A one-texel RCAS halo
## therefore reaches the display roughly two pixels wide. That is why the
## project's own sharpening budget is spent downstream instead, by
## [constant RTPostProcessStack.PANINI_PRESENT_SHARPEN_STRENGTH], which acts at
## native resolution on the blur the projection actually introduced. This value
## stays at the engine default because FSR2 is now doing real reconstruction
## (a 0.707 render scale at Native), where RCAS earns its keep countering
## reconstruction softness at the target resolution rather than display softness.
## Raising it backs the capture-side sharpener off; lowering it toward 0.0
## strengthens it.
const FSR_SHARPNESS := 0.2

@export_category("Retro Grade")
@export var retro_enabled: bool = true:
	set(value):
		if retro_enabled == value:
			return
		retro_enabled = value
		emit_changed()

@export_range(0.0, 4.0, 0.01) var brightness: float = 1.0:
	set(value):
		value = maxf(value, 0.0)
		if is_equal_approx(brightness, value):
			return
		brightness = value
		emit_changed()

@export_range(0.0, 4.0, 0.01) var contrast: float = 1.12:
	set(value):
		value = maxf(value, 0.0)
		if is_equal_approx(contrast, value):
			return
		contrast = value
		emit_changed()

@export_range(0.0, 4.0, 0.01) var saturation: float = 1.08:
	set(value):
		value = maxf(value, 0.0)
		if is_equal_approx(saturation, value):
			return
		saturation = value
		emit_changed()

@export_range(0.0, 1.0, 0.001) var black_point: float = 0.005:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(black_point, value):
			return
		black_point = value
		emit_changed()

@export var color_balance: Vector3 = Vector3(1.02, 1.0, 0.97):
	set(value):
		value = value.max(Vector3.ZERO)
		if color_balance.is_equal_approx(value):
			return
		color_balance = value
		emit_changed()

@export var posterize_enabled: bool = false:
	set(value):
		if posterize_enabled == value:
			return
		posterize_enabled = value
		emit_changed()

@export_range(2.0, 256.0, 1.0) var posterize_levels: float = 256.0:
	set(value):
		value = clampf(value, 2.0, 256.0)
		if is_equal_approx(posterize_levels, value):
			return
		posterize_levels = value
		emit_changed()

@export_range(0.0, 1.0, 0.01) var posterize_strength: float = 1.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(posterize_strength, value):
			return
		posterize_strength = value
		emit_changed()


func get_retro_settings() -> Dictionary:
	return {
		"enabled": retro_enabled,
		"brightness": brightness,
		"contrast": contrast,
		"saturation": saturation,
		"black_point": black_point,
		"color_balance": color_balance,
		"posterize_enabled": posterize_enabled,
		"posterize_levels": posterize_levels,
		"posterize_strength": posterize_strength,
	}


func set_retro_settings(settings: Dictionary) -> void:
	if settings.has("enabled"):
		retro_enabled = bool(settings["enabled"])
	if settings.has("brightness"):
		brightness = float(settings["brightness"])
	if settings.has("contrast"):
		contrast = float(settings["contrast"])
	if settings.has("saturation"):
		saturation = float(settings["saturation"])
	if settings.has("black_point"):
		black_point = float(settings["black_point"])
	if settings.has("color_balance") and settings["color_balance"] is Vector3:
		color_balance = settings["color_balance"]
	if settings.has("posterize_enabled"):
		posterize_enabled = bool(settings["posterize_enabled"])
	if settings.has("posterize_levels"):
		posterize_levels = float(settings["posterize_levels"])
	if settings.has("posterize_strength"):
		posterize_strength = float(settings["posterize_strength"])


## Captures every caller-owned viewport property changed by
## `apply_native_viewport_state`, for exact restoration during teardown.
static func capture_viewport_state(viewport: Viewport) -> Dictionary:
	var state := {
		"use_taa": viewport.use_taa,
		"screen_space_aa": viewport.screen_space_aa,
		"msaa_3d": viewport.msaa_3d,
		"msaa_2d": viewport.msaa_2d,
		"scaling_3d_scale": viewport.scaling_3d_scale,
		"scaling_3d_mode": viewport.scaling_3d_mode,
		"texture_mipmap_bias": viewport.texture_mipmap_bias,
		"anisotropic_filtering_level": viewport.anisotropic_filtering_level,
		"use_debanding": viewport.use_debanding,
		"use_hdr_2d": viewport.use_hdr_2d,
		"fsr_sharpness": viewport.fsr_sharpness,
	}
	if viewport is SubViewport:
		var subviewport := viewport as SubViewport
		state["size"] = subviewport.size
		state["render_target_update_mode"] = subviewport.render_target_update_mode
	return state


## `hdr_2d` selects the target format. The root/final presentation target is
## deliberately LDR: the final canvas shader performs the single explicit display
## transfer, and an HDR 2D destination would add a renderer-owned second one. The
## stack's internal targets carry scene radiance between passes and ask for true.
static func apply_native_viewport_state(
		viewport: Viewport,
		native_size: Vector2i,
		hdr_2d: bool = false) -> void:
	viewport.use_taa = false
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.msaa_2d = Viewport.MSAA_DISABLED
	viewport.scaling_3d_scale = 1.0
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	# Inert while no FSR pass runs on this target, but pinned anyway so a viewport
	# that moves between this helper and the FSR2 one carries a declared value in
	# both directions rather than whatever the other helper happened to leave.
	viewport.fsr_sharpness = FSR_SHARPNESS
	viewport.texture_mipmap_bias = 0.0
	viewport.anisotropic_filtering_level = Viewport.ANISOTROPY_4X
	viewport.use_debanding = false
	viewport.use_hdr_2d = hdr_2d
	if viewport is SubViewport:
		var subviewport := viewport as SubViewport
		subviewport.size = Vector2i(maxi(native_size.x, 1), maxi(native_size.y, 1))
		subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


## Applies the one temporal contract in the project. Only the private 3D scene
## capture may use it: FSR2 owns jitter, motion-vector consumption, temporal AA
## and reconstruction there, while every canvas/presentation target remains on
## [method apply_native_viewport_state]. `target_size` is the rectilinear image
## FSR2 reconstructs; `render_scale` controls the smaller 3D buffers feeding it.
static func apply_fsr2_scene_viewport_state(
		viewport: Viewport,
		target_size: Vector2i,
		render_scale: float,
		hdr_2d: bool = true) -> void:
	viewport.use_taa = false
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.msaa_2d = Viewport.MSAA_DISABLED
	viewport.scaling_3d_scale = clampf(render_scale, 0.1, 1.0)
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	# The one target where this is live: Godot's FSR2 sharpens its output with it.
	viewport.fsr_sharpness = FSR_SHARPNESS
	# Godot adds the scale-dependent mip bias internally. This remains the
	# project's authored offset on top of that automatic bias.
	viewport.texture_mipmap_bias = 0.0
	viewport.anisotropic_filtering_level = Viewport.ANISOTROPY_4X
	viewport.use_debanding = false
	viewport.use_hdr_2d = hdr_2d
	if viewport is SubViewport:
		var subviewport := viewport as SubViewport
		subviewport.size = Vector2i(maxi(target_size.x, 1), maxi(target_size.y, 1))
		subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


static func native_viewport_failure(
		viewport: Viewport,
		native_size: Vector2i,
		hdr_2d: bool = false) -> String:
	if viewport.use_taa:
		return "TAA remained enabled"
	if viewport.screen_space_aa != Viewport.SCREEN_SPACE_AA_DISABLED:
		return "built-in screen-space AA remained enabled"
	if viewport.msaa_3d != Viewport.MSAA_DISABLED:
		return "3D MSAA remained enabled"
	if viewport.msaa_2d != Viewport.MSAA_DISABLED:
		return "2D MSAA remained enabled"
	if not is_equal_approx(viewport.scaling_3d_scale, 1.0):
		return "3D scaling is not native"
	if viewport.scaling_3d_mode != Viewport.SCALING_3D_MODE_BILINEAR:
		return "a temporal or non-contract 3D scaler remained active"
	if not is_equal_approx(viewport.fsr_sharpness, FSR_SHARPNESS):
		return "the contract FSR sharpness was not accepted"
	if not is_equal_approx(viewport.texture_mipmap_bias, 0.0):
		return "texture mip bias is not 0"
	if viewport.anisotropic_filtering_level != Viewport.ANISOTROPY_4X:
		return "the platform did not accept 4x anisotropic filtering"
	if viewport.use_debanding:
		return "debanding remained enabled"
	if viewport.use_hdr_2d != hdr_2d:
		return (
			"the platform did not honor HDR 2D on a scene-radiance target"
			if hdr_2d
			else "HDR 2D remained enabled on the explicit display-transfer target")
	if viewport is SubViewport:
		var expected := Vector2i(maxi(native_size.x, 1), maxi(native_size.y, 1))
		if (viewport as SubViewport).size != expected:
			return "the SubViewport did not accept the native size"
	return ""


static func fsr2_scene_viewport_failure(
		viewport: Viewport,
		target_size: Vector2i,
		render_scale: float,
		hdr_2d: bool = true) -> String:
	if viewport.use_taa:
		return "separate TAA remained enabled alongside FSR2"
	if viewport.screen_space_aa != Viewport.SCREEN_SPACE_AA_DISABLED:
		return "built-in screen-space AA remained enabled alongside FSR2"
	if viewport.msaa_3d != Viewport.MSAA_DISABLED:
		return "3D MSAA remained enabled alongside FSR2"
	if viewport.msaa_2d != Viewport.MSAA_DISABLED:
		return "2D MSAA remained enabled on the scene capture"
	if not is_equal_approx(
			viewport.scaling_3d_scale, clampf(render_scale, 0.1, 1.0)):
		return "the requested FSR2 render scale was not accepted"
	if viewport.scaling_3d_mode != Viewport.SCALING_3D_MODE_FSR2:
		return "FSR2 scaling mode was not accepted"
	if not is_equal_approx(viewport.fsr_sharpness, FSR_SHARPNESS):
		return "the contract FSR2 RCAS sharpness was not accepted"
	if not is_equal_approx(viewport.texture_mipmap_bias, 0.0):
		return "the authored texture mip bias is not 0"
	if viewport.anisotropic_filtering_level != Viewport.ANISOTROPY_4X:
		return "the platform did not accept 4x anisotropic filtering"
	if viewport.use_debanding:
		return "debanding remained enabled"
	if viewport.use_hdr_2d != hdr_2d:
		return "the platform did not honor the scene capture HDR target"
	if viewport is SubViewport:
		var expected := Vector2i(maxi(target_size.x, 1), maxi(target_size.y, 1))
		if (viewport as SubViewport).size != expected:
			return "the SubViewport did not accept the FSR2 target size"
	return ""


static func restore_viewport_state(viewport: Viewport, state: Dictionary) -> void:
	if state.has("use_taa"):
		viewport.use_taa = bool(state["use_taa"])
	if state.has("screen_space_aa"):
		viewport.screen_space_aa = int(state["screen_space_aa"]) as Viewport.ScreenSpaceAA
	if state.has("msaa_3d"):
		viewport.set(&"msaa_3d", int(state["msaa_3d"]))
	if state.has("msaa_2d"):
		viewport.set(&"msaa_2d", int(state["msaa_2d"]))
	if state.has("scaling_3d_scale"):
		viewport.scaling_3d_scale = float(state["scaling_3d_scale"])
	if state.has("scaling_3d_mode"):
		viewport.set(&"scaling_3d_mode", int(state["scaling_3d_mode"]))
	if state.has("texture_mipmap_bias"):
		viewport.texture_mipmap_bias = float(state["texture_mipmap_bias"])
	if state.has("anisotropic_filtering_level"):
		viewport.set(&"anisotropic_filtering_level", int(state["anisotropic_filtering_level"]))
	if state.has("use_debanding"):
		viewport.use_debanding = bool(state["use_debanding"])
	if state.has("use_hdr_2d"):
		viewport.use_hdr_2d = bool(state["use_hdr_2d"])
	if state.has("fsr_sharpness"):
		viewport.fsr_sharpness = float(state["fsr_sharpness"])
	if viewport is SubViewport:
		var subviewport := viewport as SubViewport
		if state.has("size"):
			subviewport.size = state["size"]
		if state.has("render_target_update_mode"):
			subviewport.set(&"render_target_update_mode", int(state["render_target_update_mode"]))
