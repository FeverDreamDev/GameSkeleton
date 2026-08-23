class_name UIScreen
extends Control

## Base class for a full-screen UI page such as the loading screen or the main menu.
##
## Handles the parts every screen shares -- filling the viewport, keeping the generated bevel
## textures crisp, and fading in and out -- so subclasses only implement [method _build].
## Override [method _build] rather than [method _ready]; [method _ready] is already spoken for.

signal closed()

## How long [method fade_in] and [method fade_out] take by default.
@export var fade_duration: float = 0.2

## Colour painted behind the screen's contents. Transparent by default, which is what a screen
## laid over a live 3D view wants. Set it when there is nothing behind the screen to look at --
## [constant UITheme.DESKTOP] gives the familiar teal. Must be set before the screen enters the
## tree, since the backdrop is built in [method _ready].
@export var backdrop_color: Color = Color.TRANSPARENT

var _fade_tween: Tween
var _backdrop: ColorRect

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# PASS rather than STOP: a screen is a backdrop for its widgets, and swallowing clicks here
	# would block anything sitting on a layer underneath it.
	mouse_filter = Control.MOUSE_FILTER_PASS
	# The theme's bevels are 6x6 source images. Under the project's canvas_items stretch they
	# get scaled, and anything but nearest turns the one pixel highlights into grey mush.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Added before _build(), so it is the first child and everything else draws over it.
	_build_backdrop()
	_build()

## A fully transparent ColorRect still costs a full-screen draw call, so an unset backdrop builds
## no node at all rather than an invisible one.
func _build_backdrop() -> void:
	if backdrop_color.a <= 0.0:
		return
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = backdrop_color
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

## Build the screen's contents here. Called once, after the screen is in the tree and sized.
func _build() -> void:
	pass

#region Transitions

func fade_in(duration: float = -1.0) -> void:
	await _fade_to(1.0, duration if duration >= 0.0 else fade_duration)

func fade_out(duration: float = -1.0) -> void:
	await _fade_to(0.0, duration if duration >= 0.0 else fade_duration)

func _fade_to(target_alpha: float, duration: float) -> void:
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	if duration <= 0.0:
		modulate.a = target_alpha
		return
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", target_alpha, duration)
	await _fade_tween.finished

#endregion

## Fades the screen out and frees it. Use this rather than queue_free() so the screen gets a
## chance to animate away, and so anything waiting on [signal closed] hears about it.
func close() -> void:
	await fade_out()
	closed.emit()
	queue_free()
