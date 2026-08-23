class_name FlowPresent
extends RefCounted

## Everything the flow system shows the player, in one place.
##
## This is the only script in [code]addons/game_flow[/code] that names [code]addons/win98_ui[/code].
## Everything else in the addon goes through here, so pairing the flow system with a different UI
## later is a rewrite of this file and nothing else.
##
## Every call is safe with no [UISystem] in the tree -- it no-ops the same way the UI addon itself
## does, which is what lets a headless test drive a transition without building a UI first.

#region Transitions

## Covers the screen. Await it: it is safe to swap the world once this returns.
static func cover(duration: float = 0.4) -> void:
	if UISystem.instance == null:
		return
	await UISystem.fade_to_black(duration)

## Uncovers the screen. Await it: the fade is done once this returns.
static func reveal(duration: float = 0.5) -> void:
	if UISystem.instance == null:
		return
	await UISystem.fade_from_black(duration)

#endregion

#region Dialogs

## The red plate and the error chord, matching how [GameFlow] already marks a failure, so a
## problem raised by the flow system does not look like a different kind of problem.
static func show_error(title: String, message: String) -> void:
	if UISystem.instance == null:
		push_error("%s: %s" % [title, message])
		return
	var dialog := UIDialog.message(title, message if not message.is_empty() else "Something went wrong.", "OK")
	dialog.icon_color = Color("c02020")
	dialog.open_sound = UIAudio.ERROR
	UISystem.show_modal(dialog)

#endregion

#region Cursor and input focus

static func set_cursor_visible(value: bool) -> void:
	if UISystem.instance != null:
		UISystem.set_cursor_visible(value)

## Whether a popup currently owns the keyboard. The flow system checks this before acting on
## anything the player pressed.
static func has_modal() -> bool:
	return UISystem.instance != null and UISystem.has_modal()

#endregion
