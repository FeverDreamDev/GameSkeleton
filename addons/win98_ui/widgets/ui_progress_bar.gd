class_name UIProgressBar
extends Range

## The chunky segmented progress bar, drawn rather than themed.
##
## Godot's ProgressBar fills a continuous rectangle, so the blocks are drawn here instead. The
## bar quantises to whole blocks the way the original did, which is why a long load appears to
## sit still and then jump.

@export var block_color: Color = UITheme.PROGRESS_FILL:
	set(value):
		block_color = value
		queue_redraw()

## Width of one block in pixels. The trough fits as many as it can and drops the remainder.
@export_range(2, 32, 1) var block_width: int = 8:
	set(value):
		block_width = value
		queue_redraw()

@export_range(0, 8, 1) var block_gap: int = 2:
	set(value):
		block_gap = value
		queue_redraw()

## Gap between the sunken trough and the blocks inside it.
@export_range(0, 8, 1) var block_inset: int = 3:
	set(value):
		block_inset = value
		queue_redraw()

var _trough: StyleBox

func _ready() -> void:
	_trough = UITheme.sunken(UITheme.FACE)
	custom_minimum_size.y = maxf(custom_minimum_size.y, 20.0)
	min_value = 0.0
	max_value = 1.0
	step = 0.0
	resized.connect(queue_redraw)

func _value_changed(_new_value: float) -> void:
	queue_redraw()

func _draw() -> void:
	if _trough:
		draw_style_box(_trough, Rect2(Vector2.ZERO, size))

	var inner := Rect2(
		Vector2(block_inset, block_inset),
		size - Vector2(block_inset, block_inset) * 2.0
	)
	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return

	var stride: float = float(block_width + block_gap)
	# The trailing gap is not needed, so it is added back before dividing.
	var capacity: int = int(floor((inner.size.x + float(block_gap)) / stride))
	if capacity <= 0:
		return

	var filled: int = int(round(ratio * float(capacity)))
	for i in filled:
		draw_rect(
			Rect2(inner.position + Vector2(float(i) * stride, 0.0), Vector2(float(block_width), inner.size.y)),
			block_color
		)
