class_name FlowState
extends RefCounted

const FlowPersistenceCodec := preload("res://addons/game_flow/core/flow_persistence.gd")

## The persistent blackboard the flow graph reasons about: where the player is in the world and
## how far they are through the story.
##
## This is not the save file. [UISave] owns serialisation and knows nothing about any game;
## [method to_dict] and [method from_dict] are the two lines that put this state into somebody
## else's payload and take it back out again.
##
## Keep this small. Story flags, quest state, chapter, important choices and world progression
## belong here. Ammo counts and door animation timers do not -- temporary data should stay local
## to whatever owns it.

#region Payload keys

const KEY_LEVEL := "level"
const KEY_SPAWN := "spawn"
const KEY_FLAGS := "flags"
const KEY_VALUES := "values"

#endregion

#region State

## Which level the run is in, as a registry id -- never a [code]res://[/code] path, so levels can
## be moved on disk without rewriting saves or story rules.
static var current_level: StringName = &""
## Which spawn point in that level the player arrived at.
static var current_spawn: StringName = &""

## Only true flags are held. Clearing one erases it, which keeps both this dictionary and the
## save file down to the things that have actually happened.
static var _flags: Dictionary = {}
static var _values: Dictionary = {}

#endregion

#region Flags

static func set_flag(flag: StringName, value: bool = true) -> void:
	if flag.is_empty():
		push_warning("FlowState.set_flag(): refusing a flag with no name.")
		return
	if value:
		_flags[flag] = true
	else:
		_flags.erase(flag)

static func has_flag(flag: StringName) -> bool:
	return _flags.has(flag)

## Every flag that is set, in alphabetical order. For the debug window and for tests.
##
## Sorted as strings and converted back, because [StringName] compares by pointer rather than
## alphabetically -- sorting an [code]Array[StringName][/code] directly yields an order that is
## stable within a run but otherwise arbitrary. [method to_dict] is unaffected; it already sorts
## an [code]Array[String][/code].
static func flags() -> Array[StringName]:
	var names: Array[String] = []
	for flag: StringName in _flags:
		names.append(String(flag))
	names.sort()

	var out: Array[StringName] = []
	for flag_name: String in names:
		out.append(StringName(flag_name))
	return out

#endregion

#region Values

static func set_value(key: StringName, value: Variant) -> void:
	try_set_value(key, value)

## Stores [param value] only when it is safe to persist, returning whether it was accepted.
##
## The stored value is detached through [FlowPersistence], so a caller cannot add a live Node or
## Resource to a Dictionary after handing it over. [method set_value] remains the void-compatible
## convenience API used by existing game code.
static func try_set_value(key: StringName, value: Variant) -> bool:
	if key.is_empty():
		push_warning("FlowState.set_value(): refusing a value with no key.")
		return false

	var result := FlowPersistenceCodec.try_clone(value, _value_path(key))
	if not bool(result[FlowPersistenceCodec.RESULT_OK]):
		var problems: Array[String] = result[FlowPersistenceCodec.RESULT_PROBLEMS]
		push_warning("FlowState.set_value(): refusing '%s': %s" % [
			key, FlowPersistenceCodec.format_problems(problems),
		])
		return false

	_values[key] = result[FlowPersistenceCodec.RESULT_VALUE]
	return true

## Every reason [param value] cannot be stored in persistent flow state. Empty means safe.
static func validate_value(value: Variant) -> Array[String]:
	return FlowPersistenceCodec.validate(value, "FlowState value")

static func can_store_value(value: Variant) -> bool:
	return validate_value(value).is_empty()

static func get_value(key: StringName, default_value: Variant = null) -> Variant:
	if not _values.has(key):
		return default_value
	var result := FlowPersistenceCodec.try_clone(_values[key], _value_path(key))
	if bool(result[FlowPersistenceCodec.RESULT_OK]):
		return result[FlowPersistenceCodec.RESULT_VALUE]
	_report_corrupt_value(key, result[FlowPersistenceCodec.RESULT_PROBLEMS])
	return default_value

static func has_value(key: StringName) -> bool:
	return _values.has(key)

static func erase_value(key: StringName) -> void:
	_values.erase(key)

static func values() -> Dictionary:
	var out := {}
	for key: StringName in _values:
		var result := FlowPersistenceCodec.try_clone(_values[key], _value_path(key))
		if bool(result[FlowPersistenceCodec.RESULT_OK]):
			out[key] = result[FlowPersistenceCodec.RESULT_VALUE]
		else:
			_report_corrupt_value(key, result[FlowPersistenceCodec.RESULT_PROBLEMS])
	return out

#endregion

#region Lifecycle

## Wipes the run. Static state outlives the scene tree, so this has to be called when a run ends or
## the next New Game inherits the last one's story progress.
static func reset() -> void:
	current_level = &""
	current_spawn = &""
	_flags.clear()
	_values.clear()

#endregion

#region Serialisation

## Everything worth persisting, as plain JSON-friendly types.
##
## Flags go out as a sorted list of names rather than a name-to-true dictionary: it is half the
## bytes, it sorts stably so two save files diff readably, and "set" means exactly "present".
static func to_dict() -> Dictionary:
	var flag_names: Array[String] = []
	for flag: StringName in _flags:
		flag_names.append(String(flag))
	flag_names.sort()

	var out_values := {}
	for key: StringName in _values:
		var result := FlowPersistenceCodec.try_clone(_values[key], _value_path(key))
		if bool(result[FlowPersistenceCodec.RESULT_OK]):
			out_values[String(key)] = result[FlowPersistenceCodec.RESULT_VALUE]
		else:
			_report_corrupt_value(key, result[FlowPersistenceCodec.RESULT_PROBLEMS])

	return {
		KEY_LEVEL: String(current_level),
		KEY_SPAWN: String(current_spawn),
		KEY_FLAGS: flag_names,
		KEY_VALUES: out_values,
	}

## Replaces the run with [param state]. Save files are readable JSON by design, so a hand-edited
## one can hold anything at all -- every value is checked rather than assigned on trust, the same
## way [GameFlow] treats its own payload.
static func from_dict(state: Dictionary) -> void:
	reset()
	if state.is_empty():
		return

	current_level = StringName(str(state.get(KEY_LEVEL, "")))
	current_spawn = StringName(str(state.get(KEY_SPAWN, "")))

	var raw_flags: Variant = state.get(KEY_FLAGS)
	if raw_flags is Array:
		for raw: Variant in raw_flags:
			var name := str(raw)
			if not name.is_empty():
				_flags[StringName(name)] = true

	var raw_values: Variant = state.get(KEY_VALUES)
	if raw_values is Dictionary:
		for key: Variant in raw_values:
			var name := str(key)
			if not name.is_empty():
				try_set_value(StringName(name), raw_values[key])

## A stable path for diagnostics from nested dictionaries and arrays.
static func _value_path(key: StringName) -> String:
	return "FlowState.values[%s]" % JSON.stringify(String(key))

static func _report_corrupt_value(key: StringName, problems: Array[String]) -> void:
	push_error("FlowState: unsafe value '%s' was omitted: %s" % [
		key, FlowPersistenceCodec.format_problems(problems),
	])

#endregion
