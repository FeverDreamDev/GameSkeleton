class_name UITheme
extends RefCounted

## Procedural Windows 98 style theme for the entire UI layer.
##
## Every visual in here is generated at runtime: the bevels are 6x6 images painted pixel by
## pixel and then nine-sliced, the title bar gradient is a GradientTexture2D, the scrollbar
## trough is a two pixel checker, and the font is pulled from the operating system. Nothing
## needs an imported asset, so the placeholder look holds together until real art replaces it.
##
## To reskin the whole UI, change the palette constants below or swap the stylebox factories.
## Widgets never hardcode a colour; they ask this class or the theme for one.

#region Palette

const FACE := Color("c0c0c0") ## The 3D button face everything is built out of
const FACE_LIGHT := Color("dfdfdf") ## Outer highlight, one step down from white
const HIGHLIGHT := Color("ffffff") ## Inner highlight
const SHADOW := Color("808080") ## Inner shadow
const DARK_SHADOW := Color("0a0a0a") ## Outer shadow, near black
const WHITE := Color("ffffff") ## Client area / text field background
const TEXT := Color("000000")
const TEXT_DISABLED := Color("808080")
const TITLE_TEXT := Color("ffffff")
const TITLE_ACTIVE_LEFT := Color("000080")
const TITLE_ACTIVE_RIGHT := Color("1084d0")
const TITLE_INACTIVE_LEFT := Color("808080")
const TITLE_INACTIVE_RIGHT := Color("b5b5b5")
const SELECTION := Color("000080")
const PROGRESS_FILL := Color("000080")
const DESKTOP := Color("008080") ## The teal everyone remembers

#endregion

#region Metrics

const BEVEL := 2 ## Border thickness of every raised / sunken edge, in source pixels
const TILE := 6 ## 2 px border + 2 px stretchable centre + 2 px border
const FONT_SIZE := 12
const TITLE_BAR_HEIGHT := 18
const TITLE_BUTTON_SIZE := Vector2(16, 14)

#endregion

#region Theme Access

## Built once and shared by every layer. UIManager assigns it to the layer roots and Control
## inheritance carries it down, so individual widgets never load a theme themselves.
static var _cached_theme: Theme = null

static func get_theme() -> Theme:
	if _cached_theme == null:
		_cached_theme = build_theme()
	return _cached_theme

#endregion

#region Bevel Factories

## Paints a TILE x TILE image carrying a two pixel bevel and returns it nine-sliced.
##
## The four colours are the two top-left bands and the two bottom-right bands. Swapping those
## pairs is the entire difference between a raised edge and a sunken one, which is exactly how
## the original did it, so both directions come out of one function.
static func make_bevel(
	outer_tl: Color,
	inner_tl: Color,
	outer_br: Color,
	inner_br: Color,
	face: Color = FACE
) -> StyleBoxTexture:
	var img := Image.create_empty(TILE, TILE, false, Image.FORMAT_RGBA8)
	img.fill(face)
	var last := TILE - 1

	for i in TILE:
		img.set_pixel(i, 0, outer_tl)
		img.set_pixel(0, i, outer_tl)
	for i in range(1, last):
		img.set_pixel(i, 1, inner_tl)
		img.set_pixel(1, i, inner_tl)
	# The bottom and right bands paint last so they own the two shared corners, matching the
	# way the original stacked its highlights. Painting them first leaves a pale bottom-left
	# corner that reads as a gap in the frame.
	for i in range(1, last):
		img.set_pixel(i, last - 1, inner_br)
		img.set_pixel(last - 1, i, inner_br)
	for i in TILE:
		img.set_pixel(i, last, outer_br)
		img.set_pixel(last, i, outer_br)

	var box := StyleBoxTexture.new()
	box.texture = ImageTexture.create_from_image(img)
	box.set_texture_margin_all(BEVEL)
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	box.set_content_margin_all(BEVEL)
	return box

## A button, window frame or scrollbar grabber sitting proud of the surface.
static func raised(face: Color = FACE) -> StyleBoxTexture:
	return make_bevel(FACE_LIGHT, HIGHLIGHT, DARK_SHADOW, SHADOW, face)

## A client area, text field or progress trough cut into the surface.
static func sunken(face: Color = FACE) -> StyleBoxTexture:
	return make_bevel(SHADOW, DARK_SHADOW, FACE_LIGHT, HIGHLIGHT, face)

## A button being held down: the light and dark bands trade places.
static func depressed(face: Color = FACE) -> StyleBoxTexture:
	return make_bevel(DARK_SHADOW, SHADOW, HIGHLIGHT, FACE_LIGHT, face)

## The two pixel etched groove used by separators.
static func etched_line(horizontal: bool = true) -> StyleBoxTexture:
	var img := Image.create_empty(1 if horizontal else 2, 2 if horizontal else 1, false, Image.FORMAT_RGBA8)
	if horizontal:
		img.set_pixel(0, 0, SHADOW)
		img.set_pixel(0, 1, HIGHLIGHT)
	else:
		img.set_pixel(0, 0, SHADOW)
		img.set_pixel(1, 0, HIGHLIGHT)
	var box := StyleBoxTexture.new()
	box.texture = ImageTexture.create_from_image(img)
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	return box

## The dithered scrollbar trough, tiled rather than stretched so the checker stays 1:1.
static func checker(light: Color = WHITE, dark: Color = FACE) -> StyleBoxTexture:
	var img := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, light)
	img.set_pixel(1, 1, light)
	img.set_pixel(1, 0, dark)
	img.set_pixel(0, 1, dark)
	var box := StyleBoxTexture.new()
	box.texture = ImageTexture.create_from_image(img)
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	return box

## The title bar fill. Windows 95 used a flat navy; the 98 default faded it out to the right.
static func title_gradient(active: bool) -> StyleBoxTexture:
	var gradient := Gradient.new()
	gradient.set_color(0, TITLE_ACTIVE_LEFT if active else TITLE_INACTIVE_LEFT)
	gradient.set_color(1, TITLE_ACTIVE_RIGHT if active else TITLE_INACTIVE_RIGHT)

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 128
	texture.height = 1
	texture.fill_from = Vector2.ZERO
	texture.fill_to = Vector2.RIGHT

	var box := StyleBoxTexture.new()
	box.texture = texture
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	box.content_margin_left = 3
	box.content_margin_right = 2
	box.content_margin_top = 1
	box.content_margin_bottom = 1
	return box

## The dotted rectangle a focused control wore. Approximated with a thin inset frame, since a
## real dotted border needs a pattern texture sized to the individual control.
static func focus_rect() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.set_border_width_all(1)
	box.border_color = Color(0.0, 0.0, 0.0, 0.55)
	box.set_expand_margin_all(-3)
	return box

static func empty() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()

#endregion

#region Font

## MS Sans Serif is the real thing; the rest are near-identical stand-ins on machines that no
## longer ship it. Antialiasing and subpixel positioning are off because the original was a
## bitmap font, and the crisp edges are most of what sells the look at these sizes.
static func make_font(bold: bool = false, italic: bool = false) -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"MS Sans Serif", "Tahoma", "Verdana", "DejaVu Sans", "Arial", "Sans-Serif",
	])
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	font.hinting = TextServer.HINTING_NORMAL
	font.allow_system_fallback = true
	if bold:
		font.font_weight = 700
	font.font_italic = italic
	return font

static func make_mono_font() -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Courier New", "Consolas", "DejaVu Sans Mono", "Monospace"])
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	font.hinting = TextServer.HINTING_NORMAL
	font.allow_system_fallback = true
	return font

#endregion

#region Theme Construction

static func build_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = make_font()
	theme.default_font_size = FONT_SIZE

	_apply_buttons(theme)
	_apply_panels(theme)
	_apply_text(theme)
	_apply_fields(theme)
	_apply_progress(theme)
	_apply_scrollbars(theme)
	_apply_tabs(theme)
	_apply_separators(theme)
	_apply_variations(theme)
	return theme

static func _apply_buttons(theme: Theme) -> void:
	var normal := raised()
	normal.content_margin_left = 12
	normal.content_margin_right = 12
	normal.content_margin_top = 4
	normal.content_margin_bottom = 4

	# The original had no hover state at all. A game menu is unusable without one, so the face
	# lifts by a hair rather than adopting a colour the palette never had.
	var hover := raised(Color("cacaca"))
	hover.content_margin_left = 12
	hover.content_margin_right = 12
	hover.content_margin_top = 4
	hover.content_margin_bottom = 4

	# Held buttons shifted their label a pixel down and right, which is most of what sells the
	# press. Asymmetric content margins reproduce it without touching the label itself.
	var pressed := depressed()
	pressed.content_margin_left = 13
	pressed.content_margin_right = 11
	pressed.content_margin_top = 5
	pressed.content_margin_bottom = 3

	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("disabled", "Button", normal)
	theme.set_stylebox("focus", "Button", focus_rect())

	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", TEXT)
	theme.set_color("font_pressed_color", "Button", TEXT)
	theme.set_color("font_focus_color", "Button", TEXT)
	theme.set_color("font_disabled_color", "Button", TEXT_DISABLED)
	theme.set_constant("h_separation", "Button", 4)
	theme.set_font_size("font_size", "Button", FONT_SIZE)

static func _apply_panels(theme: Theme) -> void:
	var frame := raised()
	frame.set_content_margin_all(3)
	theme.set_stylebox("panel", "Panel", frame)
	theme.set_stylebox("panel", "PanelContainer", frame)

static func _apply_text(theme: Theme) -> void:
	theme.set_color("font_color", "Label", TEXT)
	theme.set_font_size("font_size", "Label", FONT_SIZE)
	theme.set_stylebox("normal", "Label", empty())

	theme.set_color("default_color", "RichTextLabel", TEXT)
	theme.set_stylebox("normal", "RichTextLabel", empty())
	theme.set_stylebox("focus", "RichTextLabel", empty())

	# Without these, every BBCode tag falls back to the default font and [b] renders identical
	# to body text -- which quietly flattens anything built out of headings, like the credits.
	theme.set_font("normal_font", "RichTextLabel", make_font())
	theme.set_font("bold_font", "RichTextLabel", make_font(true))
	theme.set_font("italics_font", "RichTextLabel", make_font(false, true))
	theme.set_font("bold_italics_font", "RichTextLabel", make_font(true, true))
	theme.set_font("mono_font", "RichTextLabel", make_mono_font())
	for entry in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		theme.set_font_size(entry, "RichTextLabel", FONT_SIZE)

static func _apply_fields(theme: Theme) -> void:
	var field := sunken(WHITE)
	field.content_margin_left = 4
	field.content_margin_right = 4
	field.content_margin_top = 3
	field.content_margin_bottom = 3

	theme.set_stylebox("normal", "LineEdit", field)
	theme.set_stylebox("focus", "LineEdit", empty())
	theme.set_stylebox("read_only", "LineEdit", sunken(FACE))
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_uneditable_color", "LineEdit", TEXT_DISABLED)
	theme.set_color("font_placeholder_color", "LineEdit", TEXT_DISABLED)
	theme.set_color("caret_color", "LineEdit", TEXT)
	theme.set_color("selection_color", "LineEdit", SELECTION)
	theme.set_color("font_selected_color", "LineEdit", WHITE)

static func _apply_progress(theme: Theme) -> void:
	var trough := sunken(FACE)
	trough.set_content_margin_all(0)
	var fill := StyleBoxFlat.new()
	fill.bg_color = PROGRESS_FILL
	theme.set_stylebox("background", "ProgressBar", trough)
	theme.set_stylebox("fill", "ProgressBar", fill)
	theme.set_color("font_color", "ProgressBar", TEXT)

static func _apply_scrollbars(theme: Theme) -> void:
	var grabber := raised()
	for bar in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", bar, checker())
		theme.set_stylebox("scroll_focus", bar, checker())
		theme.set_stylebox("grabber", bar, grabber)
		theme.set_stylebox("grabber_highlight", bar, raised(Color("cacaca")))
		theme.set_stylebox("grabber_pressed", bar, grabber)
	theme.set_stylebox("panel", "ScrollContainer", empty())
	theme.set_stylebox("focus", "ScrollContainer", empty())

static func _apply_tabs(theme: Theme) -> void:
	# A selected tab grew upward and lost its bottom edge, which a single stylebox cannot
	# express, so it is approximated with a lighter face and taller padding.
	var unselected := raised()
	unselected.content_margin_left = 10
	unselected.content_margin_right = 10
	unselected.content_margin_top = 3
	unselected.content_margin_bottom = 3

	var selected := raised(Color("cacaca"))
	selected.content_margin_left = 11
	selected.content_margin_right = 11
	selected.content_margin_top = 5
	selected.content_margin_bottom = 3

	for tab_type in ["TabBar", "TabContainer"]:
		theme.set_stylebox("tab_selected", tab_type, selected)
		theme.set_stylebox("tab_hovered", tab_type, selected)
		theme.set_stylebox("tab_unselected", tab_type, unselected)
		theme.set_stylebox("tabbar_background", tab_type, empty())
		theme.set_color("font_selected_color", tab_type, TEXT)
		theme.set_color("font_unselected_color", tab_type, TEXT)
		theme.set_color("font_hovered_color", tab_type, TEXT)

	var page := raised()
	page.set_content_margin_all(8)
	theme.set_stylebox("panel", "TabContainer", page)

static func _apply_separators(theme: Theme) -> void:
	theme.set_stylebox("separator", "HSeparator", etched_line(true))
	theme.set_stylebox("separator", "VSeparator", etched_line(false))
	theme.set_constant("separation", "HSeparator", 2)
	theme.set_constant("separation", "VSeparator", 2)

## Named variations let a widget opt into a role, rather than overriding styleboxes locally.
## Anything a variation does not redefine falls back to its base type, so each one only ever
## states its difference.
static func _apply_variations(theme: Theme) -> void:
	var window_frame := raised()
	window_frame.set_content_margin_all(3)
	theme.set_type_variation("WindowFrame", "PanelContainer")
	theme.set_stylebox("panel", "WindowFrame", window_frame)

	var client := sunken(WHITE)
	client.set_content_margin_all(6)
	theme.set_type_variation("ClientPanel", "PanelContainer")
	theme.set_stylebox("panel", "ClientPanel", client)

	var sunken_face := sunken(FACE)
	sunken_face.set_content_margin_all(4)
	theme.set_type_variation("SunkenPanel", "PanelContainer")
	theme.set_stylebox("panel", "SunkenPanel", sunken_face)

	theme.set_type_variation("TitleBar", "PanelContainer")
	theme.set_stylebox("panel", "TitleBar", title_gradient(true))

	theme.set_type_variation("TitleBarInactive", "PanelContainer")
	theme.set_stylebox("panel", "TitleBarInactive", title_gradient(false))

	var title_button := raised()
	title_button.set_content_margin_all(0)
	var title_button_pressed := depressed()
	title_button_pressed.set_content_margin_all(0)
	theme.set_type_variation("TitleButton", "Button")
	theme.set_stylebox("normal", "TitleButton", title_button)
	theme.set_stylebox("hover", "TitleButton", raised(Color("cacaca")))
	theme.set_stylebox("pressed", "TitleButton", title_button_pressed)
	theme.set_stylebox("disabled", "TitleButton", title_button)
	theme.set_stylebox("focus", "TitleButton", empty())

	theme.set_type_variation("TitleLabel", "Label")
	theme.set_color("font_color", "TitleLabel", TITLE_TEXT)

	theme.set_type_variation("HintLabel", "Label")
	theme.set_color("font_color", "HintLabel", TEXT_DISABLED)

#endregion
