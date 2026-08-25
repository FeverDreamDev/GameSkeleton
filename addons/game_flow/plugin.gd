@tool
extends EditorPlugin

## Editor-only entry point for the Game Flow main-screen workspace.
##
## Runtime graph resources remain ordinary `class_name` Resources and do not depend on this
## plugin being enabled. Keeping the editor entry point free of a `class_name` also prevents game
## code from accidentally taking a dependency on editor-only APIs.

const GRAPH_EDITOR_SCRIPT := preload("res://addons/game_flow/editor/flow_graph_editor.gd")

var _main_screen: Control


func _enter_tree() -> void:
	_main_screen = GRAPH_EDITOR_SCRIPT.new()
	_main_screen.name = "GameFlowEditor"
	_main_screen.set_editor_plugin(self)
	_main_screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	EditorInterface.get_editor_main_screen().add_child(_main_screen)
	_make_visible(false)


func _exit_tree() -> void:
	if is_instance_valid(_main_screen):
		_main_screen.shutdown()
		_main_screen.queue_free()
	_main_screen = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_main_screen):
		_main_screen.visible = visible
		if visible:
			_main_screen.open_default_graph()


func _get_plugin_name() -> String:
	return "Game Flow"


func _get_plugin_icon() -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(&"VisualShader", &"EditorIcons"):
		return theme.get_icon(&"VisualShader", &"EditorIcons")
	return null


func _handles(object: Object) -> bool:
	return is_instance_valid(_main_screen) and _main_screen.can_edit_object(object)


func _edit(object: Object) -> void:
	if not is_instance_valid(_main_screen) or object == null:
		return
	_main_screen.open_graph(object)
	# Available in Godot 4.7. Use a dynamic call so the add-on remains loadable on compatible
	# editor builds that expose the main-screen selector under a different API revision.
	if EditorInterface.has_method(&"set_main_screen_editor"):
		EditorInterface.call(&"set_main_screen_editor", "Game Flow")


func _apply_changes() -> void:
	if is_instance_valid(_main_screen):
		_main_screen.apply_pending_changes()


func _save_external_data() -> void:
	if is_instance_valid(_main_screen):
		_main_screen.save_all_dirty_graphs()


## Godot invokes this hook before running the project. Returning false keeps an invalid authored
## graph from reaching runtime, where a missing node/reference would otherwise fail much later.
func _build() -> bool:
	return not is_instance_valid(_main_screen) or _main_screen.validate_before_play()


func _get_unsaved_status(for_scene: String) -> String:
	if not for_scene.is_empty() or not is_instance_valid(_main_screen):
		return ""
	return _main_screen.unsaved_status()
