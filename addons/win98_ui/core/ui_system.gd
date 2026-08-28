class_name UISystem
extends Node

## The whole UI package in one node. Drop it into any scene and the rest of the addon works.
##
## Copy [code]addons/win98_ui/[/code] into a project, add a UISystem node anywhere in the main
## scene (Add Node, search "UISystem"), and call it from anywhere:
##
## [codeblock]
## UISystem.show_screen(MainMenu.new())
## if await UISystem.show_modal(UIDialog.confirm("Exit", "Quit?")).finished:
##     get_tree().quit()
## [/codeblock]
##
## The calls above are static and route to whichever UISystem is currently in the tree, so no
## autoload, no singleton registration and no node paths are involved. With no UISystem present
## they quietly do nothing rather than crashing, which keeps the widgets usable on their own.
## Registering the script as an autoload also works if you prefer that; nothing changes.
##
## It builds four canvas layers, bottom to top:
## [codeblock]
## screen  -- one full-screen page at a time (loading screen, main menu)
## window  -- free-floating UIWindows that outlive the screen underneath
## modal   -- UIDialogs, each blocking everything below it
## fade    -- the black curtain used between screens
## [/codeblock]
##
## It knows nothing about any particular game. Game state belongs in your own code, which
## listens to the signals the screens emit.

#region Configuration

@export_group("Layers")
## Canvas layer indices. Raise them if the game draws its own HUD above 100.
@export var screen_layer: int = 100
@export var window_layer: int = 110
@export var modal_layer: int = 120
@export var fade_layer: int = 130

@export_group("Sounds")
## Every slot is empty until you fill it. The wiring is already in place, so a stream dropped
## here is audible immediately with no code change. See [UIAudio] for what each one covers.
@export var sound_click: AudioStream ## Any button press.
@export var sound_hover: AudioStream ## Pointer entering a button.
@export var sound_open: AudioStream ## A window or dialog appearing.
@export var sound_close: AudioStream ## A window or dialog going away.
@export var sound_error: AudioStream ## Error style dialogs, including the pause menu.
@export var sound_disabled: AudioStream ## A click that went nowhere.
@export var sound_bus: StringName = &"Master"
@export_range(-40.0, 12.0, 0.5, "suffix:dB") var sound_volume_db: float = 0.0
## Sounds that can overlap before the oldest player is reused.
@export_range(1, 16, 1) var sound_voices: int = 6

#endregion

#region Instance Access

## The UISystem currently in the tree. The static calls below all route through it.
static var instance: UISystem

#endregion

#region State

## The theme every layer root carries. Controls inherit it, so widgets never load it directly.
var theme_resource: Theme

var screen_root: Control
var window_root: Control
var modal_root: Control

var current_screen: UIScreen
var audio: UIAudio

var _fade_rect: ColorRect
var _fade_tween: Tween

#endregion

#region Lifecycle

func _enter_tree() -> void:
	# Claimed here rather than in _ready() so a sibling's _ready() can already use the system.
	if instance != null and instance != self and is_instance_valid(instance):
		push_warning("UISystem: a second instance entered the tree; the newest one wins.")
	instance = self

func _exit_tree() -> void:
	if instance == self:
		instance = null

func _ready() -> void:
	# Everything under this node has to keep running while the tree is paused, or the pause
	# menu would freeze along with the game it is supposed to be controlling. Children inherit
	# this, so the layers, screens, dialogs and sound players are all covered by this one line.
	process_mode = Node.PROCESS_MODE_ALWAYS

	theme_resource = UITheme.get_theme()
	screen_root = _create_layer(screen_layer, "ScreenLayer")
	window_root = _create_layer(window_layer, "WindowLayer")
	modal_root = _create_layer(modal_layer, "ModalLayer")
	_create_fade_layer()
	_create_audio()

func _create_layer(layer_index: int, layer_name: String) -> Control:
	var canvas := CanvasLayer.new()
	canvas.name = layer_name
	canvas.layer = layer_index
	add_child(canvas)

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# IGNORE, not PASS: an empty layer must be completely transparent to the mouse, or the
	# topmost one would quietly eat every click meant for the game.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme_resource
	root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	canvas.add_child(root)
	return root

func _create_fade_layer() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "FadeLayer"
	canvas.layer = fade_layer
	add_child(canvas)

	_fade_rect = ColorRect.new()
	_fade_rect.name = "Fade"
	_fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade_rect.color = Color(0.0, 0.0, 0.0, 0.0)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_rect.visible = false
	canvas.add_child(_fade_rect)

func _create_audio() -> void:
	audio = UIAudio.new()
	audio.name = "Audio"
	audio.bus = sound_bus
	audio.volume_db = sound_volume_db
	audio.voices = sound_voices
	audio.streams = {
		UIAudio.CLICK: sound_click,
		UIAudio.HOVER: sound_hover,
		UIAudio.OPEN: sound_open,
		UIAudio.CLOSE: sound_close,
		UIAudio.ERROR: sound_error,
		UIAudio.DISABLED: sound_disabled,
	}
	add_child(audio)

#endregion

#region Static Facade

## Replaces whatever screen is showing. The outgoing screen fades out and frees itself while
## the new one fades in, so the two overlap rather than flashing through the background.
static func show_screen(screen: UIScreen, fade: bool = true) -> UIScreen:
	if instance == null:
		push_error("UISystem.show_screen() called with no UISystem in the tree.")
		return screen
	return instance._show_screen(screen, fade)

## Fades out the current screen and frees it, leaving the screen layer empty.
static func close_screen(fade: bool = true) -> void:
	if instance:
		await instance._close_screen(fade)

static func get_current_screen() -> UIScreen:
	return instance.current_screen if instance else null

## Adds a free-floating window that is not tied to the current screen.
static func add_window(window: UIWindow) -> UIWindow:
	if instance:
		instance.window_root.add_child(window)
		window.activate()
	return window

## Shows a modal dialog and returns it, ready to be awaited:
## [code]if await UISystem.show_modal(UIDialog.confirm(...)).finished:[/code]
static func show_modal(dialog: UIDialog) -> UIDialog:
	if instance:
		instance.modal_root.add_child(dialog)
	return dialog

static func has_modal() -> bool:
	return instance != null and instance.modal_root != null and instance.modal_root.get_child_count() > 0

## Fades the screen to black. Await it to run something once the curtain is fully down.
static func fade_to_black(duration: float = 0.35) -> void:
	if instance:
		await instance._fade_to(1.0, duration)

static func fade_from_black(duration: float = 0.35) -> void:
	if instance:
		await instance._fade_to(0.0, duration)

## Single place that decides whether the mouse is a pointer or a look input, so UI code and the
## player controller are not fighting over [member Input.mouse_mode].
static func set_cursor_visible(value: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if value else Input.MOUSE_MODE_CAPTURED

static func is_cursor_visible() -> bool:
	return Input.mouse_mode != Input.MOUSE_MODE_CAPTURED

## Plays one of the [UIAudio] sounds. Silent until that slot has a stream in it.
static func play_sound(id: StringName) -> void:
	if instance and instance.audio:
		instance.audio.play(id)

## Gives a button the standard press and hover sounds. Every button this addon builds is bound
## automatically; call this for buttons you add yourself.
static func bind_button(button: BaseButton) -> void:
	if instance and instance.audio:
		instance.audio.bind_button(button)

## The shared theme, for a Control that lives outside the UI layers and still wants the look.
static func get_ui_theme() -> Theme:
	return instance.theme_resource if instance else UITheme.get_theme()

#endregion

#region Implementation

func _show_screen(screen: UIScreen, fade: bool) -> UIScreen:
	var outgoing := current_screen
	current_screen = screen

	if fade:
		screen.modulate.a = 0.0
	screen_root.add_child(screen)

	if outgoing and is_instance_valid(outgoing):
		if fade:
			outgoing.close()
		else:
			outgoing.queue_free()

	if fade:
		screen.fade_in()
	return screen

func _close_screen(fade: bool) -> void:
	if current_screen == null or not is_instance_valid(current_screen):
		current_screen = null
		return
	var screen := current_screen
	current_screen = null
	if fade:
		await screen.close()
	else:
		screen.queue_free()

func _fade_to(target_alpha: float, duration: float) -> void:
	if _fade_rect == null:
		return
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()

	_fade_rect.visible = true
	if duration <= 0.0:
		_fade_rect.color.a = target_alpha
	else:
		_fade_tween = create_tween()
		# The curtain must keep animating while the tree is paused, for the same reason this
		# whole node does.
		_fade_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		_fade_tween.tween_property(_fade_rect, "color:a", target_alpha, duration)
		await _fade_tween.finished

	# A fully transparent ColorRect still costs a full-screen draw call every frame.
	_fade_rect.visible = target_alpha > 0.0

#endregion
