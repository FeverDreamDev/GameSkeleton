class_name FlowDatabase
extends Resource

## Every story rule, level and cutscene in the game, in one resource assigned to [FlowSystem].
##
## The arrays are what you author; the dictionaries are built from them once and are what the
## director actually reads, so routing an event is a hash lookup rather than a walk down a list
## that grows with the size of the story.

@export var events: Array[FlowEvent] = []
@export var levels: Array[FlowLevelEntry] = []
@export var cutscenes: Array[FlowCutsceneEntry] = []

var _event_index: Dictionary = {}
var _level_index: Dictionary = {}
var _cutscene_index: Dictionary = {}
var _indexed: bool = false

#region Lookup

func get_event(event_id: StringName) -> FlowEvent:
	_ensure_index()
	return _event_index.get(event_id)

func get_level(level_id: StringName) -> FlowLevelEntry:
	_ensure_index()
	return _level_index.get(level_id)

func get_cutscene(cutscene_id: StringName) -> FlowCutsceneEntry:
	_ensure_index()
	return _cutscene_index.get(cutscene_id)

func has_event(event_id: StringName) -> bool:
	_ensure_index()
	return _event_index.has(event_id)

func level_ids() -> Array[StringName]:
	_ensure_index()
	var out: Array[StringName] = []
	for id: StringName in _level_index:
		out.append(id)
	return out

## The id whose entry points at [param path]. Lets a save written before the registry existed --
## one that recorded a raw scene path -- still resolve to a level.
func level_id_for_path(path: String) -> StringName:
	_ensure_index()
	for id: StringName in _level_index:
		var entry: FlowLevelEntry = _level_index[id]
		if entry.scene_path == path:
			return id
	return &""

#endregion

#region Index

func _ensure_index() -> void:
	if not _indexed:
		rebuild_index()

## Call after editing the arrays at runtime. Authoring in the inspector does not need it -- the
## index is built on first use.
func rebuild_index() -> void:
	_event_index.clear()
	_level_index.clear()
	_cutscene_index.clear()

	for event: FlowEvent in events:
		if event != null and not event.event_id.is_empty():
			_event_index[event.event_id] = event
	for level: FlowLevelEntry in levels:
		if level != null and not level.level_id.is_empty():
			_level_index[level.level_id] = level
	for cutscene: FlowCutsceneEntry in cutscenes:
		if cutscene != null and not cutscene.cutscene_id.is_empty():
			_cutscene_index[cutscene.cutscene_id] = cutscene

	_indexed = true

#endregion

#region Validation

## Every problem in the database, as readable lines. A missing level is worth saying out loud at
## startup rather than discovering it as a silent failed transition three rooms later.
##
## Returns an empty array when the database is sound.
func validate() -> Array[String]:
	rebuild_index()
	var problems: Array[String] = []

	_check_duplicates(events, "event", problems)
	_check_duplicates(levels, "level", problems)
	_check_duplicates(cutscenes, "cutscene", problems)

	for level: FlowLevelEntry in levels:
		if level == null:
			continue
		if level.scene_path.is_empty():
			problems.append("level '%s' has no scene path" % level.level_id)
		elif not ResourceLoader.exists(level.scene_path):
			problems.append("level '%s' points at a scene that is not there: %s" % [level.level_id, level.scene_path])
		for next_id: StringName in level.preload_next:
			if not _level_index.has(next_id):
				problems.append("level '%s' wants to preload unknown level '%s'" % [level.level_id, next_id])

	for cutscene: FlowCutsceneEntry in cutscenes:
		if cutscene == null:
			continue
		if cutscene.scene_path.is_empty():
			problems.append("cutscene '%s' has no scene path" % cutscene.cutscene_id)
		elif not ResourceLoader.exists(cutscene.scene_path):
			problems.append("cutscene '%s' points at a scene that is not there: %s" % [cutscene.cutscene_id, cutscene.scene_path])

	for event: FlowEvent in events:
		if event == null:
			continue
		if event.event_id.is_empty():
			problems.append("an event has no id")
			continue
		for action: FlowAction in event.actions:
			if action == null:
				problems.append("event '%s' has an empty action slot" % event.event_id)
				continue
			problems.append_array(_check_action(event.event_id, action))

	return problems

func _check_action(event_id: StringName, action: FlowAction) -> Array[String]:
	var problems: Array[String] = []
	match action.type:
		FlowAction.Type.LOAD_LEVEL, FlowAction.Type.PRELOAD_LEVEL:
			if not _level_index.has(action.target_id):
				problems.append("event '%s' names unknown level '%s'" % [event_id, action.target_id])
		FlowAction.Type.PLAY_CUTSCENE:
			if not _cutscene_index.has(action.target_id):
				problems.append("event '%s' names unknown cutscene '%s'" % [event_id, action.target_id])
		FlowAction.Type.EMIT_EVENT:
			if action.target_id == event_id:
				problems.append("event '%s' emits itself" % event_id)
		FlowAction.Type.WAIT:
			if action.number <= 0.0:
				problems.append("event '%s' waits for %.2f seconds" % [event_id, action.number])
		_:
			if action.target_id.is_empty():
				problems.append("event '%s' has a %s action with no target" % [event_id, FlowAction.Type.keys()[action.type]])
	return problems

## Generic duplicate check over any of the three arrays. Each resource type names its id
## differently, so the id is read by property name rather than through a shared base class.
func _check_duplicates(entries: Array, kind: String, problems: Array[String]) -> void:
	var seen := {}
	var property := "%s_id" % kind
	for entry: Resource in entries:
		if entry == null:
			problems.append("the %s list has an empty slot" % kind)
			continue
		var id: StringName = entry.get(property)
		if id.is_empty():
			problems.append("a %s has no id" % kind)
		elif seen.has(id):
			problems.append("two %s entries share the id '%s'" % [kind, id])
		else:
			seen[id] = true

#endregion
