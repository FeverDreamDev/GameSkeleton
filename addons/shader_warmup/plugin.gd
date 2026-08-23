@tool
extends EditorPlugin

## Keeps the generated shader warmup manifest in step with the project.
##
## Deliberately has no [code]class_name[/code]: nothing at runtime should be able to reach an
## editor-only script, and a global class would be pulled into an exported build.
##
## Three triggers, in decreasing order of precision:
## [codeblock]
## Project > Tools > Rebuild Shader Warmup Manifest   -- manual, for debugging
## scene / resource saved                             -- the usual case
## filesystem changed                                 -- catches a git checkout or branch switch
## [/codeblock]
##
## All three are debounced into one rebuild, and the rebuild itself writes nothing when the scan
## comes out identical. That second guard is the important one: saving the manifest emits
## filesystem_changed, so a rebuild that always wrote would trigger itself forever.

const MENU_ITEM := "Rebuild Shader Warmup Manifest"
const DEBOUNCE_SECONDS := 1.5

var _debounce: Timer
var _export_plugin: EditorExportPlugin
var _dirty: bool = false
## Paths and modification times as of the last rebuild, so a filesystem sweep that changed nothing
## relevant does not pay for a full scan.
var _last_signature: String = ""

func _enter_tree() -> void:
	add_tool_menu_item(MENU_ITEM, _rebuild)

	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = DEBOUNCE_SECONDS
	_debounce.timeout.connect(_on_debounce_elapsed)
	add_child(_debounce)

	_export_plugin = preload("res://addons/shader_warmup/shader_warmup_export_plugin.gd").new()
	add_export_plugin(_export_plugin)

	scene_saved.connect(_on_scene_saved)
	resource_saved.connect(_on_resource_saved)
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem != null:
		filesystem.filesystem_changed.connect(_on_filesystem_changed)

	# In case the manifest is missing or was left stale by an earlier session.
	_mark_dirty()

func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ITEM)

	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null

	if scene_saved.is_connected(_on_scene_saved):
		scene_saved.disconnect(_on_scene_saved)
	if resource_saved.is_connected(_on_resource_saved):
		resource_saved.disconnect(_on_resource_saved)

	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem != null and filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		filesystem.filesystem_changed.disconnect(_on_filesystem_changed)

	if is_instance_valid(_debounce):
		_debounce.queue_free()
	_debounce = null

#region Triggers

func _on_scene_saved(filepath: String) -> void:
	if filepath == ShaderWarmupScanner.MANIFEST_PATH:
		return
	_mark_dirty()

func _on_resource_saved(resource: Resource) -> void:
	if resource == null or resource is ShaderWarmupManifest:
		return
	if resource.resource_path == ShaderWarmupScanner.MANIFEST_PATH:
		return
	_mark_dirty()

## Fires after every editor scan, including the one caused by saving the manifest. It carries no
## information about what changed, so the loop is broken by the content check in the scanner, not
## here.
func _on_filesystem_changed() -> void:
	_mark_dirty()

func _mark_dirty() -> void:
	_dirty = true
	if is_instance_valid(_debounce):
		# Restarting an already-running one-shot timer resets it, which is the debounce.
		_debounce.start()

func _on_debounce_elapsed() -> void:
	if not _dirty:
		return
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem != null and (filesystem.is_scanning() or filesystem.is_importing()):
		# Never scan a filesystem that is still moving; try again shortly.
		_debounce.start()
		return
	_dirty = false

	# The editor rescans on a timer, so most wake-ups here have nothing behind them.
	var signature := ShaderWarmupScanner.source_signature()
	if signature == _last_signature:
		return
	_last_signature = signature
	_rebuild()

#endregion

## Always scans, whatever the signature says -- this is what the menu item is for when something
## has gone wrong and the manifest needs rebuilding regardless.
func _rebuild() -> void:
	var manifest := ShaderWarmupScanner.scan_and_save()
	if manifest == null:
		return
	_last_signature = ShaderWarmupScanner.source_signature()

	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem != null:
		filesystem.update_file(ShaderWarmupScanner.MANIFEST_PATH)
	print("Shader Warmup: %d material(s), %d vertex-format pairing(s) in the manifest." % [
		manifest.size(), manifest.pair_count(),
	])
