class_name Reticle
extends Control

## A clean, smooth hollow circle / ring outline crosshair centered on screen.

@export_group("Circle Outline Reticle")
@export var circle_color: Color = Color(1.0, 1.0, 1.0, 0.9):
	set(value):
		circle_color = value
		queue_redraw()

@export var radius: float = 4.0:
	set(value):
		radius = value
		queue_redraw()

@export var line_width: float = 1.5:
	set(value):
		line_width = value
		queue_redraw()

@export var point_count: int = 48:
	set(value):
		point_count = value
		queue_redraw()

@export_group("Outline / Shadow")
@export var outline_enabled: bool = true:
	set(value):
		outline_enabled = value
		queue_redraw()

@export var outline_color: Color = Color(0.0, 0.0, 0.0, 0.5):
	set(value):
		outline_color = value
		queue_redraw()

@export var outline_width_offset: float = 1.0:
	set(value):
		outline_width_offset = value
		queue_redraw()

@export_group("Optional Center Dot")
@export var draw_center_dot: bool = false:
	set(value):
		draw_center_dot = value
		queue_redraw()

@export var dot_radius: float = 1.0:
	set(value):
		dot_radius = value
		queue_redraw()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func _draw() -> void:
	var center: Vector2 = size / 2.0
	var pts: int = max(32, point_count)
	
	# Draw dark background outline so the circle is clearly visible against bright surfaces
	if outline_enabled and outline_width_offset > 0.0:
		draw_arc(center, radius, 0.0, TAU, pts, outline_color, line_width + (outline_width_offset * 2.0), true)
	
	# Draw the primary hollow circle outline (antialiased)
	draw_arc(center, radius, 0.0, TAU, pts, circle_color, line_width, true)
	
	# Optional center dot if enabled
	if draw_center_dot:
		if outline_enabled:
			draw_circle(center, dot_radius + outline_width_offset, outline_color)
		draw_circle(center, dot_radius, circle_color)
