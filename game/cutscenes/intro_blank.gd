class_name IntroBlankCutscene
extends FlowCutscene

## Temporary intro beat used by the game skeleton. The black presentation is
## part of the scene, so the cutscene remains valid even when it is run outside
## the application shell.

@export_range(0.0, 30.0, 0.1, "or_greater", "suffix:s") var duration: float = 1.2

var _run_token: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _begin(_context: Dictionary) -> void:
	_run_token += 1
	_finish_after_delay(_run_token)


func _finish_after_delay(token: int) -> void:
	if duration > 0.0:
		await get_tree().create_timer(duration, true, false, true).timeout
	if token == _run_token and not is_finished():
		report_finished()


func _unhandled_input(event: InputEvent) -> void:
	if is_finished():
		return
	if event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		request_skip()


func _request_skip() -> void:
	_run_token += 1
	report_finished()
