class_name FlowLevel
extends Node3D

## The contract every gameplay level answers to: it knows its own id and where a player can arrive.
##
## Put this on the root of a level scene. Without it a level still loads, but the flow system has
## nowhere to ask about spawn points and will drop the player wherever the scene's own origin is.
##
## Levels stay ignorant of the story. A level never decides what comes next -- it reports through
## [FlowEvents] like everything else.

## Matches an id in the [FlowDatabase] level list. Warned about at load time if it does not.
@export var level_id: StringName = &""

## Spawn id -> [FlowSpawn], built on first use rather than in [method Node._ready], so a level
## subclass that overrides [code]_ready[/code] without calling [code]super()[/code] still works.
var _spawns: Dictionary = {}
var _indexed: bool = false

#region Spawn points

## The spawn called [param spawn_id], or [code]null[/code].
##
## Callers should fall back to [method get_default_spawn] rather than treating null as fatal -- a
## save naming a spawn that has since been deleted should put the player somewhere sensible, not
## refuse to load the level.
func get_spawn_point(spawn_id: StringName) -> FlowSpawn:
	_ensure_index()
	return _spawns.get(spawn_id)

## The spawn named [code]default[/code], or any spawn at all, or [code]null[/code] if the level has
## none.
func get_default_spawn() -> FlowSpawn:
	_ensure_index()
	if _spawns.has(&"default"):
		return _spawns[&"default"]
	for id: StringName in _spawns:
		return _spawns[id]
	return null

## Resolves [param spawn_id] with the fallback chain, saying out loud when it had to fall back --
## a player quietly appearing at the wrong end of a level is a hard bug to see.
func resolve_spawn(spawn_id: StringName) -> FlowSpawn:
	if not spawn_id.is_empty():
		var wanted := get_spawn_point(spawn_id)
		if wanted != null:
			return wanted
		push_warning("FlowLevel '%s': no spawn called '%s'; using the default." % [level_id, spawn_id])

	var fallback := get_default_spawn()
	if fallback == null:
		push_warning("FlowLevel '%s' has no spawn points at all." % level_id)
	return fallback

func spawn_ids() -> Array[StringName]:
	_ensure_index()
	var out: Array[StringName] = []
	for id: StringName in _spawns:
		out.append(id)
	return out

func _ensure_index() -> void:
	if _indexed:
		return
	_indexed = true
	_spawns.clear()
	for node in _descendants():
		var spawn := node as FlowSpawn
		if spawn == null:
			continue
		if _spawns.has(spawn.spawn_id):
			push_warning("FlowLevel '%s': two spawns share the id '%s'." % [level_id, spawn.spawn_id])
			continue
		_spawns[spawn.spawn_id] = spawn

## Call after adding or removing spawn points at runtime.
func rebuild_spawn_index() -> void:
	_indexed = false
	_ensure_index()

func _descendants() -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		out.append(node)
		for child in node.get_children():
			stack.append(child)
	return out

#endregion

#region Override these

## Called once the level is in the tree and the player has been placed. [param transition_data] is
## whatever the flow action carried.
func on_level_entered(_spawn_id: StringName, _transition_data: Dictionary) -> void:
	pass

## Called before the level is freed, while it is still whole.
func on_level_exiting() -> void:
	pass

#endregion
