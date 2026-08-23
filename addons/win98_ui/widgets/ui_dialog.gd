class_name UIDialog
extends Control

## A modal popup: a [UIWindow] centred over a click-blocking backdrop.
##
## Build one with [method message], [method confirm] or [method choice] and hand it to
## [code]UISystem.show_modal()[/code], then await the result:
##
## [codeblock]
## var dialog := UISystem.show_modal(UIDialog.confirm("Exit", "Quit the game?"))
## if await dialog.finished:
##     get_tree().quit()
## [/codeblock]
##
## A dialog frees itself once it resolves, so the caller never has to clean it up. Buttons
## marked as non-closing are the exception: they report through [signal selected] and leave the
## dialog standing, which is how a menu-shaped popup such as [PauseMenu] works.

#region Signals

## True if the user took the affirmative action, false if they cancelled or closed the window.
## Emitted once, when the dialog resolves.
signal finished(accepted: bool)

## The id of the button that was pressed. Fires for every button, including ones that leave the
## dialog open, and for a cancel. Use this when there are more than two outcomes.
signal selected(id: StringName)

#endregion

#region Configuration

@export var dialog_title: String = "Message"
## Body copy. Parsed as BBCode when [member use_bbcode] is on, which is how the credits get
## their bold headings without a second font.
@export_multiline var body_text: String = ""
@export var use_bbcode: bool = false
## The real thing never dimmed what was behind it, but a menu sitting over a lit 3D scene needs
## the separation. Set to 0.0 for a period-accurate popup.
@export_range(0.0, 1.0, 0.05) var backdrop_dim: float = 0.35
## Placeholder stand-in for the message box icon. Colour it red for an error, and swap the
## ColorRect in [method _build_body] for a TextureRect once there is art.
@export var show_icon: bool = true
@export var icon_color: Color = UITheme.TITLE_ACTIVE_RIGHT
@export var min_body_width: float = 260.0
@export var button_alignment: BoxContainer.AlignmentMode = BoxContainer.ALIGNMENT_END
@export var button_min_width: float = 84.0
## Stacks the buttons instead of laying them in a row. A row is right for a question with two
## answers; a stack is right once the buttons are a list of separate actions, which stops
## reading as a row somewhere around three.
@export var buttons_vertical: bool = false
## Freezes the whole tree while the dialog is up. The UI itself keeps running, because
## [UISystem] and everything under it processes while paused.
@export var pauses_tree: bool = false
## Sound played as the dialog appears. Error style popups use [constant UIAudio.ERROR].
@export var open_sound: StringName = UIAudio.OPEN

#endregion

#region Internals

var window: UIWindow

## One entry per button: {text: String, id: StringName, accepted: bool, default: bool,
## closes: bool}.
var _button_specs: Array[Dictionary] = []
var _finished: bool = false
var _default_accepted: bool = true
var _default_id: StringName = &"ok"
var _has_default: bool = false
var _has_cancel: bool = false
var _paused_by_us: bool = false

const CANCEL_ID := &"cancel"

#endregion

#region Factories

## A popup with a single dismiss button. [signal finished] always reports true.
static func message(title: String, text: String, button_text: String = "OK", bbcode: bool = false) -> UIDialog:
	var dialog := UIDialog.new()
	dialog.dialog_title = title
	dialog.body_text = text
	dialog.use_bbcode = bbcode
	dialog._button_specs = [
		{"text": button_text, "id": &"ok", "accepted": true, "default": true, "closes": true},
	]
	return dialog

## A two button question. [signal finished] reports true only for the affirmative button.
static func confirm(
	title: String,
	text: String,
	accept_text: String = "Yes",
	cancel_text: String = "No",
	bbcode: bool = false
) -> UIDialog:
	var dialog := UIDialog.new()
	dialog.dialog_title = title
	dialog.body_text = text
	dialog.use_bbcode = bbcode
	dialog._button_specs = [
		{"text": accept_text, "id": &"yes", "accepted": true, "default": true, "closes": true},
		{"text": cancel_text, "id": &"no", "accepted": false, "default": false, "closes": true},
	]
	dialog._has_cancel = true
	return dialog

## Any number of outcomes, reported through [signal selected].
##
## [param options] takes either plain strings, or dictionaries for full control:
## [codeblock]
## UIDialog.choice("Paused", "The game is paused.", [
##     {"text": "Settings", "id": &"settings", "closes": false},
##     {"text": "Save and Quit", "id": &"save_quit"},
## ])
## [/codeblock]
## An entry with [code]closes: false[/code] reports and leaves the dialog up, which turns the
## popup into a small menu. Closing the window reports [constant CANCEL_ID].
static func choice(title: String, text: String, options: Array, bbcode: bool = false) -> UIDialog:
	var dialog := UIDialog.new()
	dialog.dialog_title = title
	dialog.body_text = text
	dialog.use_bbcode = bbcode
	dialog._has_cancel = true

	for option in options:
		if option is Dictionary:
			var label: String = String(option.get("text", "?"))
			dialog._button_specs.append({
				"text": label,
				"id": StringName(option.get("id", label.to_snake_case())),
				"accepted": bool(option.get("accepted", true)),
				"default": bool(option.get("default", false)),
				"closes": bool(option.get("closes", true)),
			})
		else:
			var plain: String = String(option)
			dialog._button_specs.append({
				"text": plain,
				"id": StringName(plain.to_snake_case()),
				"accepted": true,
				"default": false,
				"closes": true,
			})
	return dialog

#endregion

#region Lifecycle

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# STOP is what makes this modal: every click lands here instead of reaching the screen or
	# the windows underneath.
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	if pauses_tree and not get_tree().paused:
		get_tree().paused = true
		_paused_by_us = true
	# Set explicitly rather than inherited, so a dialog still works when it is parented outside
	# the UISystem layers.
	process_mode = Node.PROCESS_MODE_ALWAYS

	var backdrop := ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.0, 0.0, backdrop_dim)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	window = UIWindow.new()
	window.window_title = dialog_title
	window.show_close_button = true
	add_child(window)
	window.close_pressed.connect(_on_close_pressed)
	window.add_content(_build_body())

	UISystem.play_sound(open_sound)

	# The window reports its minimum size only after the containers inside it have laid out,
	# so centring has to wait a frame.
	await get_tree().process_frame
	if is_instance_valid(window):
		window.reset_size()
		window.center_in_parent()
		window.activate()

func _build_body() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	column.add_child(row)

	if show_icon:
		var icon := ColorRect.new()
		icon.custom_minimum_size = Vector2(32, 32)
		icon.color = icon_color
		icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(icon)

	row.add_child(_build_body_text())
	column.add_child(_build_button_row())
	return column

func _build_body_text() -> Control:
	if use_bbcode:
		var rich := RichTextLabel.new()
		rich.bbcode_enabled = true
		rich.text = body_text
		rich.fit_content = true
		rich.scroll_active = false
		rich.custom_minimum_size.x = min_body_width
		rich.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return rich

	var label := Label.new()
	label.text = body_text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = min_body_width
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label

func _build_button_row() -> Control:
	var row: BoxContainer = VBoxContainer.new() if buttons_vertical else HBoxContainer.new()
	row.alignment = button_alignment
	# A stack wants tighter spacing than a row; 8 px between stacked buttons reads as a gap.
	row.add_theme_constant_override("separation", 4 if buttons_vertical else 8)

	for spec in _button_specs:
		var button := Button.new()
		button.text = String(spec["text"])
		button.custom_minimum_size.x = button_min_width
		var id: StringName = spec["id"]
		var accepted: bool = bool(spec["accepted"])
		if bool(spec.get("closes", true)):
			button.pressed.connect(_resolve.bind(accepted, id, false))
		else:
			button.pressed.connect(selected.emit.bind(id))
		row.add_child(button)
		UISystem.bind_button(button)

		if bool(spec.get("default", false)):
			_default_accepted = accepted
			_default_id = id
			_has_default = true
			button.call_deferred("grab_focus")
	return row

#endregion

#region Result

## Closes the dialog from outside, exactly as one of its own buttons would.
##
## Needed whenever something else takes over: loading a save has to close the [PauseMenu] that
## asked for it, and a dialog that builds its own controls resolves itself rather than routing
## every outcome through a button spec. Freeing such a dialog directly would skip [method
## _resolve] and leave a [member pauses_tree] popup's freeze in place forever.
##
## No close sound, because nothing was clicked.
func dismiss(accepted: bool = false, id: StringName = CANCEL_ID) -> void:
	_resolve(accepted, id, false)

func _on_close_pressed() -> void:
	_cancel()

## Closing the window is a cancel, unless there is nothing to cancel -- a single button popup
## has only one outcome.
func _cancel() -> void:
	if _has_cancel:
		_resolve(false, CANCEL_ID, true)
	else:
		_resolve(_default_accepted, _default_id, true)

## Reports the outcome and disposes of the dialog. Repeat calls are ignored, so a double click
## on a button cannot emit twice.
##
## [param play_close] is false for button presses, which already made their own click; only a
## dismissal through the title bar X or Escape gets the close sound.
func _resolve(accepted: bool, id: StringName, play_close: bool) -> void:
	if _finished:
		return
	_finished = true

	if _paused_by_us:
		_paused_by_us = false
		get_tree().paused = false
	if play_close:
		UISystem.play_sound(UIAudio.CLOSE)

	selected.emit(id)
	finished.emit(accepted)
	queue_free()

## _unhandled_input rather than _unhandled_key_input: the latter only ever sees key events, so
## a gamepad face button mapped to ui_cancel -- or a synthetic InputEventAction -- would never
## be able to dismiss a dialog.
func _unhandled_input(event: InputEvent) -> void:
	if _finished or not event.is_pressed():
		return
	# Only the topmost dialog answers the keyboard, or a stack of them would all resolve at
	# once on a single Escape.
	var parent := get_parent()
	if parent and parent.get_child(parent.get_child_count() - 1) != self:
		return
	if event.is_action("ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()
	elif event.is_action("ui_accept") and _has_default:
		# A menu-shaped dialog with no marked default has no obvious answer to Enter, so it is
		# left alone rather than guessing at one of several equally weighted outcomes.
		_resolve(_default_accepted, _default_id, false)
		get_viewport().set_input_as_handled()

#endregion
