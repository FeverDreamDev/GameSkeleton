class_name FlowEvent
extends Resource

## What one story event means: the conditions under which it counts, and what happens when it does.
##
## Gameplay objects never reference this. They emit an id through [FlowEvents]; the director looks
## the id up here and decides the rest. That is the whole point of the split -- a boss stays
## reusable because it reports its own death and nothing else.

@export var event_id: StringName = &""

@export_group("Conditions")
## Runs at most once per save. Guarded by a story flag, so it survives quitting and reloading
## rather than replaying the moment the game comes back.
@export var one_shot: bool = false
## Every one of these flags must be set for the event to run.
@export var required_flags: Array[StringName] = []
## Any one of these flags blocks the event.
@export var blocked_flags: Array[StringName] = []

@export_group("Consequences")
@export var actions: Array[FlowAction] = []

## The flag that records a [member one_shot] event as spent. Derived rather than authored so it
## cannot drift out of sync with the id, and namespaced so it cannot collide with a story flag.
func one_shot_flag() -> StringName:
	return StringName("flow_ran_%s" % event_id)

## Whether the conditions are met right now.
func can_run() -> bool:
	if one_shot and FlowState.has_flag(one_shot_flag()):
		return false
	for flag: StringName in required_flags:
		if not FlowState.has_flag(flag):
			return false
	for flag: StringName in blocked_flags:
		if FlowState.has_flag(flag):
			return false
	return true

## Why [method can_run] said no, for the debug log. Empty when it said yes.
func blocked_reason() -> String:
	if one_shot and FlowState.has_flag(one_shot_flag()):
		return "already ran"
	for flag: StringName in required_flags:
		if not FlowState.has_flag(flag):
			return "needs flag %s" % flag
	for flag: StringName in blocked_flags:
		if FlowState.has_flag(flag):
			return "blocked by flag %s" % flag
	return ""
