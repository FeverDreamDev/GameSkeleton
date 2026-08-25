class_name UIFpsCounter
extends PanelContainer

## A small sunken readout showing the current frame rate, in the theme's own style.
##
## Standalone on purpose: it carries its own theme rather than relying on a
## [UISystem] layer root, so it can be parented to a game's own HUD canvas without
## having to sit inside the UI stack. Drop one into a [CanvasLayer] below
## [member UISystem.screen_layer] and it will draw under menus rather than over
## them.
##
## [codeblock]
## var counter := UIFpsCounter.new()
## hud_layer.add_child(counter)
## counter.visible = show_fps
## [/codeblock]

## How often the label is rewritten. Frame rate at 200 FPS changes far faster than
## anyone can read, and every rewrite re-runs text layout, so sampling is both
## easier to read and cheaper than the thing it measures.
@export_range(0.05, 2.0, 0.05, "suffix:s") var update_interval: float = 0.25:
	set(value):
		update_interval = value
		_elapsed = update_interval

## Margin from the corner of the parent, in pixels.
@export var screen_margin: Vector2 = Vector2(8.0, 8.0):
	set(value):
		screen_margin = value
		_apply_placement()

var _label: Label
var _elapsed: float = 0.0


func _init() -> void:
	name = "UIFpsCounter"
	theme = UITheme.get_theme()
	theme_type_variation = &"SunkenPanel"
	# The counter is a readout, never a target: it must not swallow a click meant
	# for whatever is behind it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Keeps counting while the tree is paused, which is exactly when someone is
	# looking at it in an options menu.
	process_mode = Node.PROCESS_MODE_ALWAYS

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 6)
	for side in ["margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 2)
	add_child(margin)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Monospaced so the panel does not twitch a pixel wider every time the reading
	# crosses from two digits to three.
	_label.add_theme_font_override("font", UITheme.make_mono_font())
	_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	_label.text = "-- FPS"
	margin.add_child(_label)


func _ready() -> void:
	_apply_placement()
	_refresh()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < update_interval:
		return
	_elapsed = 0.0
	_refresh()


func _refresh() -> void:
	if _label == null or not is_instance_valid(_label):
		return
	_label.text = "%d FPS" % int(round(Engine.get_frames_per_second()))


func _apply_placement() -> void:
	if not is_inside_tree():
		return
	# Top-left, sized to its own content rather than stretched across the layer.
	set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	position = screen_margin
