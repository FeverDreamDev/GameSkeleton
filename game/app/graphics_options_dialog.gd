class_name GraphicsOptionsDialog
extends UIDialog

## Session-only graphics controls for the skeleton. The renderer row is deliberately
## informational -- it is fixed before this dialog exists -- while ray tracing, quality and
## post processing are all safe to change at runtime through RTSceneManager.

## Whole-pipeline switch: on installs hardware RT shadows and mirrors, off installs the
## raster fallback. Emitted only when the machine can actually ray trace; otherwise the
## checkbox is disabled and the hint says why.
signal rt_toggled(enabled: bool)
signal quality_selected(preset: int)
signal anti_aliasing_toggled(enabled: bool)
signal smaa_quality_selected(quality: int)
signal retro_post_toggled(enabled: bool)
signal grass_quality_selected(quality: int)
signal fps_counter_toggled(enabled: bool)
signal horizontal_fov_changed(fov: float)

const MIN_HORIZONTAL_FOV := 120.0
const MAX_HORIZONTAL_FOV := 140.0
const DEFAULT_HORIZONTAL_FOV := 130.0

var rendering_method: StringName = &"unknown"
var active_backend: StringName = &"none"
var rt_enabled: bool = true
var quality_preset: int = RTSceneManager.RTQualityPreset.NATIVE
var anti_aliasing_enabled: bool = true
var smaa_quality: int = RTSceneManager.SMAAQuality.HIGH
var retro_post_enabled: bool = true
var grass_quality: int = TerrainGrass3D.GrassQuality.HIGH
var fps_counter_enabled: bool = false
var horizontal_fov: float = DEFAULT_HORIZONTAL_FOV

var _quality_selector: OptionButton
var _backend_value: Label
var _fov_slider: HSlider
var _fov_value: Label


func _init() -> void:
	dialog_title = "Graphics"
	show_icon = false
	min_body_width = 390.0
	button_alignment = BoxContainer.ALIGNMENT_END
	_has_cancel = true
	_button_specs = [{
		"text": "Close",
		"id": &"close",
		"accepted": true,
		"default": true,
		"closes": true,
	}]


func _build_body() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)

	var status_frame := PanelContainer.new()
	status_frame.theme_type_variation = &"SunkenPanel"
	column.add_child(status_frame)

	var status_margin := MarginContainer.new()
	status_margin.add_theme_constant_override("margin_left", 8)
	status_margin.add_theme_constant_override("margin_top", 6)
	status_margin.add_theme_constant_override("margin_right", 8)
	status_margin.add_theme_constant_override("margin_bottom", 6)
	status_frame.add_child(status_margin)

	var status_grid := GridContainer.new()
	status_grid.columns = 2
	status_grid.add_theme_constant_override("h_separation", 18)
	status_grid.add_theme_constant_override("v_separation", 4)
	status_margin.add_child(status_grid)
	_add_status_row(status_grid, "Renderer", _display_name(rendering_method))
	_backend_value = _add_status_row(status_grid, "Ray tracing", _backend_text())

	var hardware_available := RTSceneManager.hardware_rt_supported()
	var rt_toggle := CheckBox.new()
	rt_toggle.name = "RayTracingToggle"
	rt_toggle.text = "RT shadows & mirrors"
	# Forced off rather than merely disabled on an adapter that cannot ray trace,
	# so the checkbox always shows what is actually rendering.
	rt_toggle.button_pressed = rt_enabled and hardware_available
	rt_toggle.disabled = not hardware_available
	rt_toggle.toggled.connect(_on_rt_toggled)
	column.add_child(rt_toggle)
	UISystem.bind_button(rt_toggle)

	var fov_row := HBoxContainer.new()
	fov_row.add_theme_constant_override("separation", 12)
	column.add_child(fov_row)

	var fov_label := Label.new()
	fov_label.text = "Horizontal FOV"
	fov_label.custom_minimum_size.x = 132.0
	fov_row.add_child(fov_label)

	_fov_slider = HSlider.new()
	_fov_slider.name = "HorizontalFovSlider"
	_fov_slider.min_value = MIN_HORIZONTAL_FOV
	_fov_slider.max_value = MAX_HORIZONTAL_FOV
	_fov_slider.step = 1.0
	_fov_slider.allow_lesser = false
	_fov_slider.allow_greater = false
	_fov_slider.focus_mode = Control.FOCUS_ALL
	_fov_slider.custom_minimum_size.x = 160.0
	_fov_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Initialize before connecting so merely opening the dialog never reapplies or emits a setting.
	_fov_slider.value = clampf(roundf(horizontal_fov), MIN_HORIZONTAL_FOV, MAX_HORIZONTAL_FOV)
	fov_row.add_child(_fov_slider)

	_fov_value = Label.new()
	_fov_value.name = "HorizontalFovValue"
	_fov_value.custom_minimum_size.x = 42.0
	_fov_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fov_value.text = _fov_text(_fov_slider.value)
	fov_row.add_child(_fov_value)
	_fov_slider.value_changed.connect(_on_horizontal_fov_value_changed)

	var quality_row := HBoxContainer.new()
	quality_row.add_theme_constant_override("separation", 12)
	column.add_child(quality_row)

	var quality_label := Label.new()
	quality_label.text = "Render quality"
	quality_label.custom_minimum_size.x = 132.0
	quality_row.add_child(quality_label)

	_quality_selector = OptionButton.new()
	_quality_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_quality_selector.add_item("Native (100%)", RTSceneManager.RTQualityPreset.NATIVE)
	_quality_selector.add_item("Quality (85%, FSR)", RTSceneManager.RTQualityPreset.QUALITY)
	_quality_selector.add_item("Balanced (75%, FSR)", RTSceneManager.RTQualityPreset.BALANCED)
	_quality_selector.add_item("Performance (50%, FSR)", RTSceneManager.RTQualityPreset.PERFORMANCE)
	var selected_index := _quality_selector.get_item_index(quality_preset)
	if selected_index >= 0:
		_quality_selector.select(selected_index)
	_quality_selector.item_selected.connect(_on_quality_item_selected)
	quality_row.add_child(_quality_selector)
	UISystem.bind_button(_quality_selector)

	var smaa_toggle := CheckBox.new()
	smaa_toggle.text = "Enable SMAA"
	smaa_toggle.button_pressed = anti_aliasing_enabled
	smaa_toggle.toggled.connect(_on_anti_aliasing_toggled)
	column.add_child(smaa_toggle)
	UISystem.bind_button(smaa_toggle)

	var smaa_row := HBoxContainer.new()
	smaa_row.add_theme_constant_override("separation", 12)
	column.add_child(smaa_row)
	var smaa_label := Label.new()
	smaa_label.text = "SMAA quality"
	smaa_label.custom_minimum_size.x = 132.0
	smaa_row.add_child(smaa_label)
	var smaa_selector := OptionButton.new()
	smaa_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	smaa_selector.add_item("Low", RTSceneManager.SMAAQuality.LOW)
	smaa_selector.add_item("Medium", RTSceneManager.SMAAQuality.MEDIUM)
	smaa_selector.add_item("High", RTSceneManager.SMAAQuality.HIGH)
	var smaa_selected_index := smaa_selector.get_item_index(smaa_quality)
	if smaa_selected_index >= 0:
		smaa_selector.select(smaa_selected_index)
	smaa_selector.item_selected.connect(_on_smaa_quality_item_selected.bind(smaa_selector))
	smaa_row.add_child(smaa_selector)
	UISystem.bind_button(smaa_selector)

	# Grass is the single most expensive thing in the scene -- it is drawn as
	# stacked shell layers, so it costs its shell count in overdraw over whatever
	# fraction of the screen it covers. That makes it the most useful thing to
	# hand the player, and the tiers are a real spread rather than three names.
	var grass_row := HBoxContainer.new()
	grass_row.add_theme_constant_override("separation", 12)
	column.add_child(grass_row)
	var grass_label := Label.new()
	grass_label.text = "Grass detail"
	grass_label.custom_minimum_size.x = 132.0
	grass_row.add_child(grass_label)
	var grass_selector := OptionButton.new()
	grass_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# GrassQuality.OFF is deliberately not offered. It measures the same as Low --
	# the four-shell variant is already close to free -- so it would be a choice
	# between an empty field and a free one.
	grass_selector.add_item("Low", TerrainGrass3D.GrassQuality.LOW)
	grass_selector.add_item("Medium", TerrainGrass3D.GrassQuality.MEDIUM)
	grass_selector.add_item("High", TerrainGrass3D.GrassQuality.HIGH)
	var grass_selected_index := grass_selector.get_item_index(grass_quality)
	if grass_selected_index >= 0:
		grass_selector.select(grass_selected_index)
	grass_selector.item_selected.connect(_on_grass_quality_item_selected.bind(grass_selector))
	grass_row.add_child(grass_selector)
	UISystem.bind_button(grass_selector)

	var retro_toggle := CheckBox.new()
	retro_toggle.text = "Retro color grading"
	retro_toggle.button_pressed = retro_post_enabled
	retro_toggle.toggled.connect(_on_retro_post_toggled)
	column.add_child(retro_toggle)
	UISystem.bind_button(retro_toggle)

	var fps_toggle := CheckBox.new()
	fps_toggle.text = "Show FPS counter"
	fps_toggle.button_pressed = fps_counter_enabled
	fps_toggle.toggled.connect(_on_fps_counter_toggled)
	column.add_child(fps_toggle)
	UISystem.bind_button(fps_toggle)

	var hint := Label.new()
	hint.theme_type_variation = &"HintLabel"
	hint.text = _hint_text(hardware_available)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = min_body_width
	column.add_child(hint)

	column.add_child(_build_button_row())
	return column


func set_active_backend(value: StringName) -> void:
	active_backend = value
	if _backend_value != null and is_instance_valid(_backend_value):
		_backend_value.text = _backend_text()


func _add_status_row(grid: GridContainer, title: String, value: String) -> Label:
	var title_label := Label.new()
	title_label.text = title + ":"
	grid.add_child(title_label)

	var value_label := Label.new()
	value_label.text = value
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(value_label)
	return value_label


func _backend_text() -> String:
	if active_backend == &"hardware":
		return "Hardware RT"
	if active_backend == &"raster":
		return "Raster (shadow maps + SSR)"
	return "Starts with the level"


func _hint_text(hardware_available: bool) -> String:
	var session_note := "Settings apply for this session and reset on restart."
	if hardware_available:
		return (
			"Turning ray tracing off falls back to shadow maps and screen-space reflections.\n"
			+ session_note)
	# The reason matters more than the fact here: "unavailable" alone reads as a
	# bug on a machine the player believes is capable.
	return (
		"Ray tracing is unavailable on this machine, so the raster fallback is in use.\n"
		+ RTSceneManager.hardware_rt_unavailable_reason() + "\n"
		+ session_note)


func _display_name(value: StringName) -> String:
	var text := String(value)
	if text.is_empty():
		return "Unknown"
	return text.replace("_", " ").capitalize()


func _fov_text(value: float) -> String:
	return "%d°" % roundi(value)


func _on_horizontal_fov_value_changed(value: float) -> void:
	horizontal_fov = clampf(roundf(value), MIN_HORIZONTAL_FOV, MAX_HORIZONTAL_FOV)
	if _fov_value != null:
		_fov_value.text = _fov_text(horizontal_fov)
	horizontal_fov_changed.emit(horizontal_fov)


func _on_rt_toggled(enabled: bool) -> void:
	rt_enabled = enabled
	rt_toggled.emit(enabled)


func _on_quality_item_selected(index: int) -> void:
	if _quality_selector == null:
		return
	quality_preset = _quality_selector.get_item_id(index)
	quality_selected.emit(quality_preset)


func _on_anti_aliasing_toggled(enabled: bool) -> void:
	anti_aliasing_enabled = enabled
	anti_aliasing_toggled.emit(enabled)


func _on_smaa_quality_item_selected(index: int, selector: OptionButton) -> void:
	smaa_quality = selector.get_item_id(index)
	smaa_quality_selected.emit(smaa_quality)


func _on_retro_post_toggled(enabled: bool) -> void:
	retro_post_enabled = enabled
	retro_post_toggled.emit(enabled)


func _on_grass_quality_item_selected(index: int, selector: OptionButton) -> void:
	grass_quality = selector.get_item_id(index)
	grass_quality_selected.emit(grass_quality)


func _on_fps_counter_toggled(enabled: bool) -> void:
	fps_counter_enabled = enabled
	fps_counter_toggled.emit(enabled)
