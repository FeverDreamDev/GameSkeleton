class_name UIWindow
extends PanelContainer

## A draggable, Windows 98 style window frame with a pluggable content area.
##
## This is the one container every piece of chrome in the project is built from: the main menu,
## the loading readout and both popup dialogs are all a UIWindow with something dropped into
## [member content]. It owns its frame, title bar and title buttons, and nothing else -- the
## contents are entirely the caller's business.
##
## Because the children are built in [method _ready], a UIWindow added from the editor shows an
## empty frame there and fills in at runtime.
##
## [codeblock]
## var window := UIWindow.new()
## window.window_title = "Options"
## window.show_help_button = true
## window.add_content(my_options_control)
## window.close_pressed.connect(_on_close)
## [/codeblock]

#region Signals

signal close_pressed() ## The X was clicked. The window does not close itself.
signal help_pressed() ## The question mark was clicked.
signal minimize_pressed()
signal maximize_pressed()
signal activated() ## This window was clicked and is now the focused one.
signal drag_ended() ## Emitted once when the user lets go of the title bar.

#endregion

#region Configuration

@export var window_title: String = "Window":
	set(value):
		window_title = value
		if _title_label:
			_title_label.text = value

@export_group("Title Buttons")
@export var show_close_button: bool = true:
	set(value):
		show_close_button = value
		_refresh_title_buttons()
@export var show_help_button: bool = false:
	set(value):
		show_help_button = value
		_refresh_title_buttons()
@export var show_minimize_button: bool = false:
	set(value):
		show_minimize_button = value
		_refresh_title_buttons()
@export var show_maximize_button: bool = false:
	set(value):
		show_maximize_button = value
		_refresh_title_buttons()

@export_group("Behaviour")
@export var draggable: bool = true
## Stops the window being dragged off the edge of its parent. Turn this off for windows that
## are meant to overhang, such as a tooltip.
@export var keep_inside_parent: bool = true
## Padding between the frame and whatever is placed in [member content].
@export var content_padding: int = 8:
	set(value):
		content_padding = value
		_apply_content_padding()
## Draws the small placeholder icon at the left of the title bar.
@export var show_icon: bool = true:
	set(value):
		show_icon = value
		if _icon:
			_icon.visible = value

#endregion

#region Node References

## Put window contents in here. Populated in [method _ready].
var content: MarginContainer

var _title_bar: PanelContainer
var _title_label: Label
var _title_buttons: HBoxContainer
var _icon: ColorRect
var _active: bool = true

var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

#endregion

#region Lifecycle

func _ready() -> void:
	theme_type_variation = &"WindowFrame"
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()

func _build() -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	add_child(column)

	_title_bar = PanelContainer.new()
	_title_bar.theme_type_variation = &"TitleBar"
	_title_bar.custom_minimum_size.y = UITheme.TITLE_BAR_HEIGHT
	_title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_title_bar.gui_input.connect(_on_title_bar_gui_input)
	column.add_child(_title_bar)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 3)
	title_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	_title_bar.add_child(title_row)

	# Placeholder application icon. Swap this ColorRect for a TextureRect once there is art.
	_icon = ColorRect.new()
	_icon.custom_minimum_size = Vector2(14, 14)
	_icon.color = UITheme.FACE_LIGHT
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.visible = show_icon
	title_row.add_child(_icon)

	_title_label = Label.new()
	_title_label.theme_type_variation = &"TitleLabel"
	_title_label.text = window_title
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_row.add_child(_title_label)

	_title_buttons = HBoxContainer.new()
	_title_buttons.add_theme_constant_override("separation", 2)
	_title_buttons.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(_title_buttons)

	content = MarginContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(content)

	_apply_content_padding()
	_refresh_title_buttons()
	set_active(_active)

#endregion

#region Content

## Adds a control to the window body. Several calls stack, so wrap them in a container first if
## the order or spacing matters.
func add_content(node: Control) -> void:
	if content == null:
		push_error("UIWindow.add_content() called before the window entered the tree.")
		return
	content.add_child(node)

## Removes and frees everything currently in the window body.
func clear_content() -> void:
	if content == null:
		return
	for child in content.get_children():
		child.queue_free()

func _apply_content_padding() -> void:
	if content == null:
		return
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		content.add_theme_constant_override(side, content_padding)

#endregion

#region Title Buttons

## Rebuilt rather than hidden so the buttons always sit flush against the right edge in the
## order Windows used: help, minimize, maximize, close.
func _refresh_title_buttons() -> void:
	if _title_buttons == null:
		return
	for child in _title_buttons.get_children():
		child.queue_free()

	if show_help_button:
		_add_title_button(UITitleButton.Glyph.HELP, help_pressed)
	if show_minimize_button:
		_add_title_button(UITitleButton.Glyph.MINIMIZE, minimize_pressed)
	if show_maximize_button:
		_add_title_button(UITitleButton.Glyph.MAXIMIZE, maximize_pressed)
	if show_close_button:
		_add_title_button(UITitleButton.Glyph.CLOSE, close_pressed)

func _add_title_button(glyph: UITitleButton.Glyph, target: Signal) -> void:
	var button := UITitleButton.new(glyph)
	button.pressed.connect(func() -> void: target.emit())
	_title_buttons.add_child(button)
	UISystem.bind_button(button)

#endregion

#region Activation

## Brings the window to the front of its siblings and dims every other one, so exactly one
## title bar is ever lit. Windows coordinate this between themselves rather than through a
## manager, which keeps a UIWindow usable anywhere a Control can go.
func activate() -> void:
	move_to_front()
	var parent := get_parent()
	if parent:
		for sibling in parent.get_children():
			if sibling is UIWindow and sibling != self:
				(sibling as UIWindow).set_active(false)
	set_active(true)
	activated.emit()

func set_active(value: bool) -> void:
	_active = value
	if _title_bar:
		_title_bar.theme_type_variation = &"TitleBar" if value else &"TitleBarInactive"

func is_active() -> bool:
	return _active

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and not _active:
		activate()

#endregion

#region Dragging

func _on_title_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			activate()
			if draggable:
				_dragging = true
				# Stored in global space so the grab point stays under the cursor no matter
				# how the parent is anchored or offset.
				_drag_offset = get_global_mouse_position() - global_position
				accept_event()
		elif _dragging:
			_dragging = false
			drag_ended.emit()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		global_position = get_global_mouse_position() - _drag_offset
		if keep_inside_parent:
			clamp_into_parent()
		accept_event()

## Nudges the window back inside its parent. Also worth calling after the viewport resizes.
func clamp_into_parent() -> void:
	var bounds: Vector2 = get_viewport_rect().size
	var parent_control := get_parent() as Control
	if parent_control:
		bounds = parent_control.size
	# maxf keeps the clamp sane for a window that is wider than the space it lives in: it then
	# pins to the top-left instead of being dragged off to negative coordinates.
	position = position.clamp(Vector2.ZERO, Vector2(maxf(bounds.x - size.x, 0.0), maxf(bounds.y - size.y, 0.0)))

## Places the window in the middle of its parent. Call after the layout has settled, or the
## window is still reporting its minimum size.
func center_in_parent() -> void:
	var bounds: Vector2 = get_viewport_rect().size
	var parent_control := get_parent() as Control
	if parent_control:
		bounds = parent_control.size
	position = ((bounds - size) * 0.5).floor()

#endregion
