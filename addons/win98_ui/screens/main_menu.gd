class_name MainMenu
extends UIScreen

## The main menu: one draggable window over whatever the camera is looking at.
##
## The window's two title buttons do what they did in Windows 98 -- the question mark opens an
## About box, the X asks whether you really meant it. Both are ordinary [UIDialog]s, so the
## menu itself contains no popup code beyond deciding what they say.
##
## The screen reports intent through signals and never acts on the game directly; whoever creates
## the menu decides what "play" and "quit" actually mean.
##
## The one thing it reads for itself is [UISave], to know whether Continue and Load Game have
## anything to offer. That is still the addon talking to the addon, so the menu picks up no
## knowledge of the game it is sitting in front of.

#region Signals

signal play_pressed()
## Jump straight back into the newest save. Only reachable when one exists.
signal continue_pressed()
## Open a save browser and pick which save to load.
signal load_pressed()
signal options_pressed()
## The exit dialog was answered yes.
signal quit_confirmed()

#endregion

#region Configuration

## Defaults are deliberately generic; whoever creates the menu sets the real strings, so this
## file carries no particular game's name.
@export var game_title: String = "Untitled Game"
@export var window_title: String = "Main Menu"
@export var subtitle: String = "Placeholder build - no art yet"
@export var window_width: float = 320.0

@export_group("Buttons")
@export var continue_text: String = "Continue"
@export var new_game_text: String = "New Game"
@export var load_text: String = "Load Game"
@export var options_text: String = "Options"
@export var exit_text: String = "Exit"
## Whether the menu offers Continue and Load Game at all. Turn it off for a game that does not
## save; the two buttons disappear rather than sitting there permanently greyed out.
@export var show_save_buttons: bool = true
## Whether the menu offers a way out of the game, as both the Exit button and the title bar X.
## Defaults from [method UISystem.can_quit], so on Web it starts off -- a button that visibly
## does nothing is worse than no button. Set it true to put them back.
@export var show_exit_button: bool = UISystem.can_quit()

@export_group("Popups")
@export var credits_title: String = "About"
## Shown by the question mark button. BBCode. Falls back to [constant DEFAULT_CREDITS].
@export_multiline var credits_bbcode: String = ""
@export var exit_title: String = "Exit"
@export_multiline var exit_prompt: String = "Are you sure you want to exit the game?"

#endregion

var window: UIWindow

var _continue_button: Button
var _load_button: Button

## Used when [member credits_bbcode] is left empty, so the question mark button always opens
## something rather than an empty box.
const DEFAULT_CREDITS := """[b]Created by[/b]
Nobody yet

[b]Built with[/b]
Godot Engine

[i]Placeholder credits - set MainMenu.credits_bbcode.[/i]"""

#region Construction

func _build() -> void:
	window = UIWindow.new()
	window.window_title = window_title
	# The X is the same action as the Exit button, so it goes when that goes -- otherwise closing
	# the window on Web opens a "quit the game?" question with no answer that does anything.
	window.show_close_button = show_exit_button
	window.show_help_button = true
	window.custom_minimum_size.x = window_width
	add_child(window)

	window.help_pressed.connect(show_credits)
	window.close_pressed.connect(confirm_exit)
	window.add_content(_build_body())

	resized.connect(_layout_window)
	# Same story as every other window here: it has no size until its contents have laid out.
	await get_tree().process_frame
	_layout_window()
	window.activate()

func _build_body() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)

	column.add_child(_build_banner())
	column.add_child(HSeparator.new())
	column.add_child(_build_menu_buttons())
	return column

## The sunken white plate a Windows 98 wizard put its artwork on. The square is a placeholder
## for a logo; swap it for a TextureRect and the layout holds.
func _build_banner() -> Control:
	var plate := PanelContainer.new()
	plate.theme_type_variation = &"ClientPanel"
	plate.custom_minimum_size.y = 96.0

	var center := CenterContainer.new()
	plate.add_child(center)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 6)
	center.add_child(column)

	var logo := ColorRect.new()
	logo.custom_minimum_size = Vector2(40, 40)
	logo.color = UITheme.TITLE_ACTIVE_LEFT
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(logo)

	var title := Label.new()
	title.text = game_title
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var hint := Label.new()
	hint.theme_type_variation = &"HintLabel"
	hint.text = subtitle
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)

	return plate

func _build_menu_buttons() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)

	if show_save_buttons:
		# Continue goes first because it is what a returning player came for. With no save it is
		# disabled rather than hidden, so the menu does not change shape underneath them the first
		# time they save.
		_continue_button = _add_menu_button(column, continue_text, func() -> void: continue_pressed.emit())
	_add_menu_button(column, new_game_text, func() -> void: play_pressed.emit())
	if show_save_buttons:
		_load_button = _add_menu_button(column, load_text, _on_load_pressed)
	_add_menu_button(column, options_text, _on_options_pressed)
	if show_exit_button:
		_add_menu_button(column, exit_text, confirm_exit)

	refresh_saves()
	return column

func _add_menu_button(parent: Control, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 26.0
	button.pressed.connect(action)
	parent.add_child(button)
	UISystem.bind_button(button)
	return button

## Re-reads [UISave] and enables or disables Continue and Load Game to match. Call it if the game
## writes or deletes a save while this menu is up.
func refresh_saves() -> void:
	var has_saves := UISave.has_any()
	if _continue_button and is_instance_valid(_continue_button):
		_continue_button.disabled = not has_saves
	if _load_button and is_instance_valid(_load_button):
		_load_button.disabled = not has_saves

func _layout_window() -> void:
	if window == null or not is_instance_valid(window):
		return
	window.reset_size()
	window.center_in_parent()

#endregion

#region Popups

## Opened by the question mark in the title bar.
func show_credits() -> void:
	var text := credits_bbcode if not credits_bbcode.is_empty() else DEFAULT_CREDITS
	UISystem.show_modal(UIDialog.message(credits_title, text, "OK", true))

## Opened by the X in the title bar and by the Exit button. Emits [signal quit_confirmed] only
## if the answer is yes.
func confirm_exit() -> void:
	var dialog := UISystem.show_modal(UIDialog.confirm(exit_title, exit_prompt, "Yes", "No"))
	if await dialog.finished:
		quit_confirmed.emit()

## Hands the Options button to whoever owns the menu, and falls back to saying so when nobody
## has claimed it -- a dead button in a template is worse than an honest one.
func _on_options_pressed() -> void:
	if options_pressed.get_connections().is_empty():
		UISystem.show_modal(UIDialog.message(
			"Options",
			"Nothing is connected to MainMenu.options_pressed yet.",
			"OK"
		))
		return
	options_pressed.emit()

## Same honesty as the Options button above.
func _on_load_pressed() -> void:
	if load_pressed.get_connections().is_empty():
		UISystem.show_modal(UIDialog.message(
			"Load Game",
			"Nothing is connected to MainMenu.load_pressed yet.",
			"OK"
		))
		return
	load_pressed.emit()

#endregion
