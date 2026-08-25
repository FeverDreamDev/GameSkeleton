class_name FlowActionHandle
extends RefCounted

## Completion handle for queued flow operations and game-owned custom actions.
##
## Handles are deliberately transient. Graph saves record the token's declarative wait state,
## never this object or the Callable/Node that eventually resolves it.

signal completed(success: bool, data: Dictionary)

var _finished: bool = false
var _success: bool = false
var _data: Dictionary = {}


func resolve(success: bool = true, data: Dictionary = {}) -> void:
	if _finished:
		return
	_finished = true
	_success = success
	_data = data.duplicate(true)
	completed.emit(_success, _data)


func cancel(reason: String = "cancelled") -> void:
	resolve(false, {"reason": reason})


func is_finished() -> bool:
	return _finished


func succeeded() -> bool:
	return _finished and _success


func result_data() -> Dictionary:
	return _data.duplicate(true)
