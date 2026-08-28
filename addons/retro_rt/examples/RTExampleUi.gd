extends Control

## Reference integration sample for the Retro RT add-on: how to find the
## manager, drive quality at runtime, and report what the pipeline is actually
## doing. Copy from it rather than instancing it in a real game.
##
## This Control sits on the default canvas layer. The post stack presents at
## layer -100, so UI here is drawn after the grade and the upscale — ungraded
## and at native resolution, which is what gameplay UI wants.


@onready var fps_counter: Label = $MarginContainer/VBoxContainer/FPS_Counter
@onready var render_metrics: Label = $MarginContainer/VBoxContainer/RenderMetrics

var _manager: RTSceneManager
var _metrics_elapsed := 0.0
var _frame_time_ms := 0.0


func _ready() -> void:
	_resolve_manager()


func _process(delta: float) -> void:
	if not is_instance_valid(_manager):
		_resolve_manager()
	_frame_time_ms = lerpf(_frame_time_ms, delta * 1000.0, 0.1)
	_metrics_elapsed += delta
	if _metrics_elapsed < 0.25:
		return
	_metrics_elapsed = 0.0
	fps_counter.text = "FPS: %d  |  Frame: %.2f ms" % [
		Engine.get_frames_per_second(), _frame_time_ms]
	_update_metrics()


func _resolve_manager() -> void:
	_manager = _find_manager(get_tree().current_scene)
	if _manager:
		_update_metrics()


func _find_manager(root: Node) -> RTSceneManager:
	if root == null:
		return null
	if root is RTSceneManager:
		return root as RTSceneManager
	for child in root.get_children():
		var found := _find_manager(child)
		if found:
			return found
	return null


func _update_metrics() -> void:
	if not is_instance_valid(_manager):
		render_metrics.text = "RT backend: unavailable"
		return
	var output_size := _manager.get_full_render_resolution()
	render_metrics.text = "RT: %s  |  %d×%d" % [
		str(_manager.get_active_rt_backend()).capitalize(),
		output_size.x,
		output_size.y,
	]
