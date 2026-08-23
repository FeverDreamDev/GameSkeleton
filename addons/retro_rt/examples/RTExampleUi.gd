extends Control

## Reference integration sample for the Retro RT add-on: how to find the
## manager, drive quality at runtime, and report what the pipeline is actually
## doing. Copy from it rather than instancing it in a real game.
##
## Note that the dropdown labels bake the four preset percentages in by hand, so
## they need updating if `RT_QUALITY_SCALES` ever changes.
##
## This Control sits on the default canvas layer. The post stack presents at
## layer -100, so UI here is drawn after the grade and the upscale — ungraded
## and at native resolution, which is what gameplay UI wants.


@onready var fps_counter: Label = $MarginContainer/VBoxContainer/FPS_Counter
@onready var quality_selector: OptionButton = $MarginContainer/VBoxContainer/QualityRow/QualitySelector
@onready var render_metrics: Label = $MarginContainer/VBoxContainer/RenderMetrics

var _manager: RTSceneManager
var _metrics_elapsed := 0.0
var _frame_time_ms := 0.0


func _ready() -> void:
	quality_selector.add_item("Native (100%)", RTSceneManager.RTQualityPreset.NATIVE)
	quality_selector.add_item("Quality (85%)", RTSceneManager.RTQualityPreset.QUALITY)
	quality_selector.add_item("Balanced (75%)", RTSceneManager.RTQualityPreset.BALANCED)
	quality_selector.add_item("Performance (50%)", RTSceneManager.RTQualityPreset.PERFORMANCE)
	quality_selector.item_selected.connect(_on_quality_selected)
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
	quality_selector.disabled = _manager == null
	if _manager:
		if not _manager.rt_quality_changed.is_connected(_on_quality_changed):
			_manager.rt_quality_changed.connect(_on_quality_changed)
		var selected_index := quality_selector.get_item_index(int(_manager.rt_quality))
		if selected_index >= 0:
			quality_selector.select(selected_index)
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


func _on_quality_selected(index: int) -> void:
	if not is_instance_valid(_manager):
		return
	_manager.set_rt_quality(quality_selector.get_item_id(index))
	_update_metrics()


func _on_quality_changed(preset: int, _requested_scale: float) -> void:
	var selected_index := quality_selector.get_item_index(preset)
	if selected_index >= 0:
		quality_selector.select(selected_index)
	_update_metrics()


func _update_metrics() -> void:
	if not is_instance_valid(_manager):
		render_metrics.text = "RT backend: unavailable"
		return
	var output_size := _manager.get_full_render_resolution()
	var render_size := _manager.get_ray_render_resolution()
	# Name the reconstruction so a reduced preset is never mistaken for a plain
	# stretch. Native is a real FSR bypass and says so.
	var upscaler := "FSR1" if render_size != output_size else "native"
	render_metrics.text = "RT: %s  |  %s  |  %d×%d → %d×%d  |  %s" % [
		str(_manager.get_active_rt_backend()).capitalize(),
		str(_manager.get_rt_quality_name()),
		output_size.x,
		output_size.y,
		render_size.x,
		render_size.y,
		upscaler,
	]
