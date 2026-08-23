@tool
extends EditorPlugin

## RTSceneManager and the five types it owns register themselves as global
## classes through [code]class_name[/code], so they appear in Create Node and are
## statically typeable whether or not this plugin is enabled. That is deliberate:
## enabling the add-on is not a precondition for using it, and a project that
## ships RT in an exported build never depends on editor state.
##
## The plugin entry earns its place for two reasons. It lets the add-on be
## enabled, updated and removed from Project Settings > Plugins like any other,
## and it clears the one project setting ray tracing refuses to start against.

## Godot defaults this to true. [code]RTSceneManager._validate_runtime()[/code]
## treats an enabled limiter as a hard startup failure, so on a stock project RT
## would fail on its very first run. Clearing it here is what makes the add-on
## drag-and-drop.
const ROUGHNESS_LIMITER_SETTING := "rendering/anti_aliasing/screen_space_roughness_limiter/enabled"


func _enable_plugin() -> void:
	if not bool(ProjectSettings.get_setting(ROUGHNESS_LIMITER_SETTING, false)):
		return
	ProjectSettings.set_setting(ROUGHNESS_LIMITER_SETTING, false)
	# The save is deferred, not immediate. The editor calls `_enable_plugin()`
	# *before* it adds this add-on to `editor_plugins/enabled`, so saving here
	# and now writes a project.godot in which Retro RT is not actually enabled,
	# and the enable is lost. Deferring puts the write after that bookkeeping.
	_save_project_settings.call_deferred()


func _save_project_settings() -> void:
	var error := ProjectSettings.save()
	if error != OK:
		push_warning(
			"Retro RT could not save project.godot (error %d). Disable Rendering > "
			% error
			+ "Anti Aliasing > Screen Space Roughness Limiter by hand before running.")
		return
	print(
		"Retro RT: disabled the screen-space roughness limiter, which ray tracing "
		+ "requires off. The next run picks this up; no editor restart is needed.")


## Deliberately no `_disable_plugin()` counterpart. Silently switching a renderer
## setting back on, in a project that may since have been authored against it,
## would be a worse surprise than leaving it cleared.
