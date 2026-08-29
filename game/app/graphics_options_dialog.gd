class_name GraphicsOptionsDialog
extends UIDialog

## Session-only graphics controls for the skeleton. The renderer row is deliberately
## informational -- it is fixed before this dialog exists -- while ray tracing and
## post processing are all safe to change at runtime through RTSceneManager.

## Whole-pipeline switch: on installs hardware RT shadows and mirrors, off installs the
## raster fallback. Emitted only when the machine can actually ray trace; otherwise the
## checkbox is disabled and the hint says why.
signal rt_toggled(enabled: bool)
signal retro_post_toggled(enabled: bool)
signal grass_quality_selected(quality: int)
signal fps_counter_toggled(enabled: bool)
signal upscaling_quality_selected(quality: int)


var rendering_method: StringName = &"unknown"
var active_backend: StringName = &"none"
var rt_enabled: bool = true
var retro_post_enabled: bool = true
var grass_quality: int = TerrainGrass3D.GrassQuality.HIGH
var fps_counter_enabled: bool = false
var upscaling_quality: int = RTSceneManager.UpscalingQuality.NATIVE

var _backend_value: Label
var _upscaling_selector: OptionButton


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


	var upscaling_row := HBoxContainer.new()
	upscaling_row.add_theme_constant_override("separation", 12)
	column.add_child(upscaling_row)

	var upscaling_label := Label.new()
	upscaling_label.text = "Upscaling Quality"
	upscaling_label.custom_minimum_size.x = 132.0
	upscaling_row.add_child(upscaling_label)

	_upscaling_selector = OptionButton.new()
	_upscaling_selector.name = "UpscalingQualitySelector"
	_upscaling_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_upscaling_selector.add_item("Native", RTSceneManager.UpscalingQuality.NATIVE)
	_upscaling_selector.add_item("Quality", RTSceneManager.UpscalingQuality.QUALITY)
	_upscaling_selector.add_item("Balanced", RTSceneManager.UpscalingQuality.BALANCED)
	_upscaling_selector.add_item("Performance", RTSceneManager.UpscalingQuality.PERFORMANCE)
	set_upscaling_quality(upscaling_quality)
	_upscaling_selector.item_selected.connect(_on_upscaling_quality_item_selected)
	upscaling_row.add_child(_upscaling_selector)
	UISystem.bind_button(_upscaling_selector)

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


func set_upscaling_quality(value: int) -> void:
	upscaling_quality = value
	if _upscaling_selector == null or not is_instance_valid(_upscaling_selector):
		return
	var selected_index := _upscaling_selector.get_item_index(upscaling_quality)
	if selected_index < 0:
		upscaling_quality = RTSceneManager.UpscalingQuality.NATIVE
		selected_index = _upscaling_selector.get_item_index(upscaling_quality)
	_upscaling_selector.select(selected_index)


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
	var upscaling_note := (
		"Upscaling Quality controls the 3D rendering resolution. Native keeps full "
		+ "resolution; the other modes trade image detail for higher performance.")
	if hardware_available:
		return (
			"Turning ray tracing off falls back to shadow maps and screen-space reflections.\n"
			+ upscaling_note + "\n"
			+ session_note)
	# The reason matters more than the fact here: "unavailable" alone reads as a
	# bug on a machine the player believes is capable.
	return (
		"Ray tracing is unavailable on this machine, so the raster fallback is in use.\n"
		+ RTSceneManager.hardware_rt_unavailable_reason() + "\n"
		+ upscaling_note + "\n"
		+ session_note)


func _display_name(value: StringName) -> String:
	var text := String(value)
	if text.is_empty():
		return "Unknown"
	return text.replace("_", " ").capitalize()



func _on_upscaling_quality_item_selected(index: int) -> void:
	upscaling_quality = _upscaling_selector.get_item_id(index)
	upscaling_quality_selected.emit(upscaling_quality)


func _on_rt_toggled(enabled: bool) -> void:
	rt_enabled = enabled
	rt_toggled.emit(enabled)


func _on_retro_post_toggled(enabled: bool) -> void:
	retro_post_enabled = enabled
	retro_post_toggled.emit(enabled)


func _on_grass_quality_item_selected(index: int, selector: OptionButton) -> void:
	grass_quality = selector.get_item_id(index)
	grass_quality_selected.emit(grass_quality)


func _on_fps_counter_toggled(enabled: bool) -> void:
	fps_counter_enabled = enabled
	fps_counter_toggled.emit(enabled)
