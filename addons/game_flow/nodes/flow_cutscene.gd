class_name FlowCutscene
extends Node

## The contract every cutscene scene answers to.
##
## How a cutscene is actually built is entirely its own business -- an [AnimationPlayer], an
## [AnimationTree], a hand-written camera sequence, a dialogue runner, or all four. The flow system
## only needs to know when it started, when it ended, and whether it can be skipped.
##
## Extend this on the root of a cutscene scene and override [method _begin]. Emit nothing yourself:
## call [method report_finished] so a cutscene cannot half-finish by forgetting to raise its own
## signal twice, or raise it twice by accident.

signal finished()
signal skip_requested()

## True once this cutscene has reported in, so a double [method report_finished] -- an animation
## that finishes on the same frame as a skip, say -- resolves once.
var _resolved: bool = false

## Whether the player skipped rather than watched it through. Readable by whatever runs next.
var was_skipped: bool = false

#region Public

## Starts the cutscene. [param context] is whatever the [FlowAction] carried, so one cutscene scene
## can serve several moments.
func begin(context: Dictionary = {}) -> void:
	_begin(context)

## Asks the cutscene to cut to its end. The default implementation finishes immediately; override
## it if the ending needs setting up -- putting the camera where the last frame would have left it,
## for instance, so the hand back to gameplay does not jump.
func request_skip() -> void:
	if _resolved:
		return
	was_skipped = true
	skip_requested.emit()
	_request_skip()

## Call this when the cutscene is over, however it got there.
func report_finished() -> void:
	if _resolved:
		return
	_resolved = true
	finished.emit()

func is_finished() -> bool:
	return _resolved

#endregion

#region Override these

## Where a cutscene does its work. Call [method report_finished] when done.
func _begin(_context: Dictionary) -> void:
	push_warning("FlowCutscene: %s does not override _begin(); finishing immediately." % name)
	report_finished()

## What a skip should do beyond ending. The default just ends.
func _request_skip() -> void:
	report_finished()

#endregion
