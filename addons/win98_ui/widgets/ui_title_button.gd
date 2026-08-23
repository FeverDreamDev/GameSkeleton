class_name UITitleButton
extends Button

## One of the small square buttons in a window title bar.
##
## The glyphs are drawn rather than imported so the widget carries no art dependency, and so
## they stay crisp at any UI scale. Each glyph is laid out on the same odd-sized pixel grid the
## originals used, which is why they are drawn from integer rects instead of vector shapes.

enum Glyph {
	CLOSE, ## The X
	HELP, ## The question mark, opens the credits in this project
	MINIMIZE, ## Bar along the bottom
	MAXIMIZE, ## Hollow box with a heavy title edge
}

@export var glyph: Glyph = Glyph.CLOSE:
	set(value):
		glyph = value
		queue_redraw()

## Colour of the glyph itself. Disabled buttons dim it automatically.
@export var glyph_color: Color = UITheme.TEXT:
	set(value):
		glyph_color = value
		queue_redraw()

func _init(initial_glyph: Glyph = Glyph.CLOSE) -> void:
	glyph = initial_glyph

func _ready() -> void:
	custom_minimum_size = UITheme.TITLE_BUTTON_SIZE
	theme_type_variation = &"TitleButton"
	focus_mode = Control.FOCUS_NONE
	# Without this the glyph is redrawn only on resize, so the one pixel press offset below
	# would never appear.
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)

func _draw() -> void:
	# The whole glyph shifts down and right while held, exactly like the button face does.
	var origin: Vector2 = (size * 0.5).floor() + (Vector2.ONE if is_pressed() else Vector2.ZERO)
	var color: Color = glyph_color if not disabled else UITheme.TEXT_DISABLED

	match glyph:
		Glyph.CLOSE:
			_draw_close(origin, color)
		Glyph.HELP:
			_draw_help(origin, color)
		Glyph.MINIMIZE:
			_draw_minimize(origin, color)
		Glyph.MAXIMIZE:
			_draw_maximize(origin, color)

## A 7x7 X built from single pixels, which keeps both diagonals hard-edged. draw_line would
## antialias the stroke back into a smudge at this size.
func _draw_close(origin: Vector2, color: Color) -> void:
	var start := origin - Vector2(4, 4)
	for i in 7:
		draw_rect(Rect2(start + Vector2(i, i), Vector2.ONE), color)
		draw_rect(Rect2(start + Vector2(6 - i, i), Vector2.ONE), color)

func _draw_help(origin: Vector2, color: Color) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	var text := "?"
	var text_size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE)
	# draw_string takes a baseline, not a top-left corner.
	var baseline := origin - Vector2(text_size.x * 0.5, 0.0) + Vector2(0.0, text_size.y * 0.5 - font.get_descent(UITheme.FONT_SIZE))
	draw_string(font, baseline.floor(), text, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE, color)

func _draw_minimize(origin: Vector2, color: Color) -> void:
	draw_rect(Rect2(origin + Vector2(-4, 2), Vector2(7, 2)), color)

func _draw_maximize(origin: Vector2, color: Color) -> void:
	var rect := Rect2(origin - Vector2(4, 4), Vector2(9, 9))
	draw_rect(rect, color, false, 1.0)
	# The heavy top edge stands in for the title bar of the window being restored.
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, 2)), color)
