class_name BootScreen
extends UIScreen

## The startup screen: a progress readout over an otherwise empty screen.
##
## Deliberately a view and nothing more. It does not load anything, does not know which level
## is being prepared, and does not decide when it is done -- [GameFlow] drives it through
## [method set_progress], [method set_status] and [method set_detail]. That keeps the loading
## policy in one place and makes this screen reusable for any long operation.

## Distance from the bottom of the screen to the bottom of the window.
@export var bottom_margin: float = 72.0
@export var window_width: float = 420.0
@export var window_title: String = "Preparing"

var window: UIWindow

var _status_label: Label
var _detail_label: Label
var _bar: UIProgressBar

func _build() -> void:
	window = UIWindow.new()
	window.window_title = window_title
	window.show_close_button = false
	window.custom_minimum_size.x = window_width
	add_child(window)
	window.add_content(_build_body())

	resized.connect(_layout_window)
	# The window only knows its size once its contents have laid out.
	await get_tree().process_frame
	_layout_window()

func _build_body() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)

	_status_label = Label.new()
	_status_label.text = "Starting up"
	column.add_child(_status_label)

	_bar = UIProgressBar.new()
	_bar.custom_minimum_size = Vector2(window_width - 40.0, 20.0)
	column.add_child(_bar)

	_detail_label = Label.new()
	_detail_label.theme_type_variation = &"HintLabel"
	_detail_label.text = ""
	_detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# Reserves the line so the window does not resize, and jump, the first time detail arrives.
	_detail_label.custom_minimum_size.y = 16.0
	column.add_child(_detail_label)

	return column

## Pinned to the bottom centre. The window stays draggable, but a viewport resize snaps it
## back rather than leaving it stranded off screen.
func _layout_window() -> void:
	if window == null or not is_instance_valid(window):
		return
	window.reset_size()
	window.position = Vector2(
		floorf((size.x - window.size.x) * 0.5),
		floorf(size.y - window.size.y - bottom_margin)
	)
	window.clamp_into_parent()

#region Readout

## [param ratio] is 0 to 1.
func set_progress(ratio: float) -> void:
	if _bar:
		_bar.value = clampf(ratio, 0.0, 1.0)

## The headline: what phase the load is in.
func set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text

## The second line: which individual item is being worked on.
func set_detail(text: String) -> void:
	if _detail_label:
		_detail_label.text = text

#endregion
