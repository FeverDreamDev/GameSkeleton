class_name GraphicsOptionsDialog
extends UIDialog

## Session-only graphics controls for the skeleton. The renderer and RT backend are deliberately
## informational: both are selected before this dialog exists, while quality and post processing
## are safe to change at runtime through RTSceneManager.

signal quality_selected(preset: int)
signal anti_aliasing_toggled(enabled: bool)
signal smaa_quality_selected(quality: int)
signal retro_post_toggled(enabled: bool)
signal grass_quality_selected(quality: int)
signal fps_counter_toggled(enabled: bool)

var rendering_method: StringName = &"unknown"
var active_backend: StringName = &"none"
var quality_preset: int = RTSceneManager.RTQualityPreset.NATIVE
var anti_aliasing_enabled: bool = true
var smaa_quality: int = RTSceneManager.SMAAQuality.HIGH
var retro_post_enabled: bool = true
var grass_quality: int = TerrainGrass3D.GrassQuality.HIGH
var fps_counter_enabled: bool = false

var _quality_selector: OptionButton
var _backend_value: Label


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
	_add_status_row(status_grid, "Fallback", "Hardware RT -> Software RT")

	var quality_row := HBoxContainer.new()
	quality_row.add_theme_constant_override("separation", 12)
	column.add_child(quality_row)

	var quality_label := Label.new()
	quality_label.text = "RT render quality"
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
	hint.text = "AUTO prefers hardware RT and falls back to software RT on this renderer.\nSettings apply for this session and reset on restart."
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
	if active_backend == &"software":
		return "Software RT"
	return "AUTO (starts with the level)"


func _display_name(value: StringName) -> String:
	var text := String(value)
	if text.is_empty():
		return "Unknown"
	return text.replace("_", " ").capitalize()


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
