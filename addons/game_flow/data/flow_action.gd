class_name FlowAction
extends Resource

## One step of a story consequence. A [FlowEvent] is an ordered list of these, and the director
## runs them one at a time so that a cutscene finishes before the level under it is swapped.
##
## The set is deliberately small. Resist adding an action type for every situation -- most
## combinations are better expressed as [constant Type.EMIT_EVENT] chaining to another
## [FlowEvent], which composes without growing this file.

enum Type {
	## Sets a story flag on [FlowState]. Uses [member flag_value].
	SET_FLAG,
	## Clears a story flag.
	CLEAR_FLAG,
	## Stores a value on [FlowState]. Uses [member value_kind] to pick which field carries it.
	SET_VALUE,
	## Emits another event. This is how one story beat composes others.
	EMIT_EVENT,
	## Plays a cutscene by id and waits for it to finish or be skipped.
	PLAY_CUTSCENE,
	## Swaps the world for another level, arriving at [member spawn_id].
	LOAD_LEVEL,
	## Starts a threaded load without swapping anything, so a later transition is instant.
	PRELOAD_LEVEL,
	## Asks the game to autosave. Deferred until the flow is stable again.
	REQUEST_SAVE,
	## Turns player gameplay input on or off. Uses [member flag_value].
	SET_INPUT,
	## Pauses the queue for [member number] seconds.
	WAIT,
}

## Which field of this resource carries the payload of a [constant Type.SET_VALUE].
enum ValueKind { NUMBER, TEXT, BOOL }

@export var type: Type = Type.SET_FLAG

## What the action acts on: a flag name, a value key, an event id, a cutscene id, a level id, or a
## save reason, depending on [member type].
@export var target_id: StringName = &""

@export_group("Level")
## Where the player arrives, for [constant Type.LOAD_LEVEL]. Empty means the level's own default.
@export var spawn_id: StringName = &""

@export_group("Payload")
## The truth value for [constant Type.SET_FLAG] and [constant Type.SET_INPUT].
@export var flag_value: bool = true
## Seconds for [constant Type.WAIT], and the payload for a numeric [constant Type.SET_VALUE].
@export var number: float = 0.0
## The payload for a textual [constant Type.SET_VALUE].
@export var text: String = ""
@export var value_kind: ValueKind = ValueKind.NUMBER
## Context handed to a cutscene, or the data carried by an emitted event.
@export var data: Dictionary = {}

## The payload a [constant Type.SET_VALUE] should store.
func resolve_value() -> Variant:
	match value_kind:
		ValueKind.TEXT:
			return text
		ValueKind.BOOL:
			return flag_value
		_:
			return number

## One line for the [code][FLOW][/code] log and the debug window.
func describe() -> String:
	var name := Type.keys()[type] as String
	match type:
		Type.LOAD_LEVEL:
			return "%s %s -> %s" % [name, target_id, spawn_id if not spawn_id.is_empty() else &"default"]
		Type.WAIT:
			return "%s %.2fs" % [name, number]
		Type.SET_FLAG, Type.SET_INPUT:
			return "%s %s = %s" % [name, target_id, flag_value]
		Type.SET_VALUE:
			return "%s %s = %s" % [name, target_id, resolve_value()]
		_:
			return "%s %s" % [name, target_id]
