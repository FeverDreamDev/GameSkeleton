class_name FlowLoader
extends RefCounted

## Threaded scene loading, and the preloading that makes a transition after a cutscene cost nothing.
##
## Loading happens off the main thread and is polled over frames, never spun on in a blocking loop
## -- a blocking load would freeze the very progress bar that exists to show the load happening.
##
## Preloading works by leaving the threaded request in flight rather than by pumping it to
## completion. Nothing has to tick this class: the background thread does the work while a cutscene
## plays, and the [method load_scene] that eventually asks for the same path finds the request
## already finished on its first status check.

## Paths with a threaded request outstanding. A path is removed as it is handed over.
static var _requested: Dictionary = {}

#region Preloading

## Starts loading [param path] without waiting for it or installing anything.
##
## Preload the one or two levels the player is likely to reach next, never the whole game -- that
## spends memory to save nothing.
static func preload_scene(path: String) -> void:
	if path.is_empty() or _requested.has(path):
		return
	if not ResourceLoader.exists(path):
		push_warning("FlowLoader: asked to preload a scene that is not there: %s" % path)
		return
	if ResourceLoader.load_threaded_request(path, "PackedScene") != OK:
		push_warning("FlowLoader: could not start preloading %s" % path)
		return
	_requested[path] = true
	FlowEvents.log_line("preloading: %s" % path.get_file())

## Whether [param path] is already loaded and would install without waiting.
static func is_ready(path: String) -> bool:
	if not _requested.has(path):
		return false
	return ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED

## How far along an outstanding request is, 0 to 1. Returns 0 for a path nobody asked for.
static func progress(path: String) -> float:
	if not _requested.has(path):
		return 0.0
	var out: Array = []
	ResourceLoader.load_threaded_get_status(path, out)
	return float(out[0]) if not out.is_empty() else 0.0

## Paths with a request still outstanding, for the debug window.
static func pending() -> Array[String]:
	var out: Array[String] = []
	for path: String in _requested:
		out.append(path)
	return out

#endregion

#region Loading

## Loads [param path] and returns the scene, or [code]null[/code] with the reason pushed as an
## error. Await it.
##
## [param on_progress] is called with a float from 0 to 1 as the load advances, so a caller can
## drive a progress bar without this class knowing that progress bars exist.
static func load_scene(path: String, on_progress: Callable = Callable()) -> PackedScene:
	if path.is_empty():
		push_error("FlowLoader: asked to load a scene with no path.")
		return null
	if not ResourceLoader.exists(path):
		push_error("FlowLoader: no scene at %s" % path)
		return null

	# A preload already in flight is picked up here rather than started again, which is the whole
	# point of having preloaded it.
	if not _requested.has(path):
		if ResourceLoader.load_threaded_request(path, "PackedScene") != OK:
			push_error("FlowLoader: could not start loading %s" % path)
			return null
		_requested[path] = true

	var tree := Engine.get_main_loop() as SceneTree
	var reported: Array = []
	var status := ResourceLoader.load_threaded_get_status(path, reported)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		if on_progress.is_valid() and not reported.is_empty():
			on_progress.call(float(reported[0]))
		if tree == null:
			push_error("FlowLoader: no SceneTree to wait on while loading %s" % path)
			_requested.erase(path)
			return null
		await tree.process_frame
		status = ResourceLoader.load_threaded_get_status(path, reported)

	_requested.erase(path)

	if status != ResourceLoader.THREAD_LOAD_LOADED:
		push_error("FlowLoader: failed to load %s (status %d)" % [path, status])
		return null

	var scene := ResourceLoader.load_threaded_get(path) as PackedScene
	if scene == null:
		push_error("FlowLoader: %s loaded but is not a PackedScene." % path)
		return null

	if on_progress.is_valid():
		on_progress.call(1.0)
	return scene

#endregion

#region Lifecycle

## Collects an outstanding request without installing it, so an abandoned preload does not sit
## holding a scene the game turned out not to need.
static func discard(path: String) -> void:
	if not _requested.has(path):
		return
	_requested.erase(path)
	if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
		ResourceLoader.load_threaded_get(path)

## Drops every outstanding request. Called when a run ends -- this state is static and would
## otherwise outlive the run that asked for it.
static func reset() -> void:
	for path: String in _requested.keys():
		discard(path)
	_requested.clear()

#endregion
