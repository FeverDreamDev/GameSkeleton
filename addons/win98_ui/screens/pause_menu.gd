class_name PauseMenu
extends UIDialog

## The in-game pause popup, shaped like a Windows 98 error box: red icon, one line of text, a
## row of buttons across the bottom.
##
## It freezes the tree the moment it appears and thaws it when it closes. The UI itself keeps
## running because [UISystem] and everything under it processes while paused, so the frozen game
## sits behind a fully live popup.
##
## Settings, Save and Load deliberately leave the popup standing -- they are things you do from
## the pause menu, not ways out of it. Whoever handles Load closes this popup itself through
## [method UIDialog.dismiss] once a save has actually been chosen, so the tree unfreezes on the
## way into the new level.
##
## The menu decides nothing itself. Connect the signals and act on them:
## [codeblock]
## var pause := UISystem.show_modal(PauseMenu.new()) as PauseMenu
## pause.settings_requested.connect(_open_settings)
## pause.save_requested.connect(_save)
## pause.save_and_quit_requested.connect(_save_and_quit)
## pause.resumed.connect(_resume)
## [/codeblock]

#region Signals

signal settings_requested()
signal save_requested()
## Open the save browser to load. The handler is responsible for dismissing this popup.
signal load_requested()
## Leave gameplay and go back to the main menu, without quitting the game.
signal main_menu_requested()
signal save_and_quit_requested()
## The popup was dismissed with the X or Escape. Gameplay is already unfrozen by this point.
signal resumed()

#endregion

#region Button Ids

const ID_SETTINGS := &"settings"
const ID_SAVE := &"save"
const ID_LOAD := &"load"
const ID_MAIN_MENU := &"main_menu"
const ID_SAVE_AND_QUIT := &"save_and_quit"

#endregion

#region Configuration

@export var settings_text: String = "Settings"
@export var save_text: String = "Save"
@export var load_text: String = "Load"
@export var main_menu_text: String = "Return to Main Menu"
@export var save_and_quit_text: String = "Save and Quit"
## Whether Save and Quit is offered. Defaults from [method UISystem.can_quit], so on Web it starts
## off -- Save is already on the menu, and the "and Quit" half would do nothing there. Return to
## Main Menu is unaffected, since leaving a level is not leaving the game.
@export var show_save_and_quit: bool = UISystem.can_quit()

#endregion

func _init() -> void:
	dialog_title = "Paused"
	body_text = "The game is paused.\n\nClose this window or press Escape to resume."
	pauses_tree = true
	# The red plate and the error chord are what make it read as a system message rather than
	# as a menu that happens to be in the way.
	icon_color = Color("c02020")
	open_sound = UIAudio.ERROR
	# Windows centred the buttons on a message box; only property sheets pushed them right.
	button_alignment = BoxContainer.ALIGNMENT_CENTER
	# Four separate actions are a list, not a set of answers to a question, so they stack.
	buttons_vertical = true
	button_min_width = 168.0
	min_body_width = 300.0
	_has_cancel = true

	selected.connect(_on_selected)

## Built here rather than in [method _init] so the exported labels above are read after any
## caller has had a chance to change them.
##
## Order runs from "stay in the game" to "leave it", so nothing destructive sits next to the
## button you press most.
func _ready() -> void:
	_button_specs = [
		{"text": settings_text, "id": ID_SETTINGS, "accepted": true, "default": false, "closes": false},
		{"text": save_text, "id": ID_SAVE, "accepted": true, "default": false, "closes": false},
		{"text": load_text, "id": ID_LOAD, "accepted": true, "default": false, "closes": false},
		{"text": main_menu_text, "id": ID_MAIN_MENU, "accepted": true, "default": false, "closes": true},
	]
	if show_save_and_quit:
		_button_specs.append(
			{"text": save_and_quit_text, "id": ID_SAVE_AND_QUIT, "accepted": true, "default": false, "closes": true}
		)
	super()

func _on_selected(id: StringName) -> void:
	match id:
		ID_SETTINGS:
			settings_requested.emit()
		ID_SAVE:
			save_requested.emit()
		ID_LOAD:
			load_requested.emit()
		ID_MAIN_MENU:
			main_menu_requested.emit()
		ID_SAVE_AND_QUIT:
			save_and_quit_requested.emit()
		CANCEL_ID:
			resumed.emit()
