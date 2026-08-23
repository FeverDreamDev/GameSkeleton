class_name FlowTrigger3D
extends Area3D

## An area that reports an event when something walks into it, so a level does not need a bespoke
## script per doorway.
##
## It reports and nothing else. What the event means is the [FlowDatabase]'s business -- that is
## what keeps this node reusable and stops story logic scattering into level scenes.

signal fired(event_id: StringName)

## The event this area announces. Nothing happens if it is empty.
@export var event_id: StringName = &""

## Extra context sent with the event.
@export var data: Dictionary = {}

@export_group("Conditions")
## Fires once, then stops testing overlaps at all. This is about not spamming the bus while the
## player stands in the doorway; it is not story memory. A beat that must never replay after a
## reload wants [member FlowEvent.one_shot] on the event instead, which is flag-guarded and goes
## into the save.
@export var one_shot: bool = true

## Only bodies in this group can set it off. Empty means anything can.
@export var required_group: StringName = &"player"

@export_group("Persistence")
## Whether a spent trigger stays spent across a save. Joins [member saveable_group], which is the
## seam [GameFlow] already walks when it captures a level.
@export var remember_when_spent: bool = true

## The group the game's save code scans. Matches [code]GameFlow.SAVEABLE_GROUP[/code].
@export var saveable_group: StringName = &"saveable"

var _spent: bool = false

func _ready() -> void:
	if remember_when_spent and not saveable_group.is_empty():
		add_to_group(saveable_group)
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)

#region Firing

func _on_body_entered(body: Node3D) -> void:
	_try_fire(body)

func _on_area_entered(area: Area3D) -> void:
	_try_fire(area)

func _try_fire(who: Node3D) -> void:
	if _spent or event_id.is_empty():
		return
	if not required_group.is_empty() and not who.is_in_group(required_group):
		return

	if one_shot:
		_spend()

	var payload := data.duplicate()
	payload["source"] = self
	payload["body"] = who
	FlowEvents.emit(event_id, payload)
	fired.emit(event_id)

func _spend() -> void:
	_spent = true
	# Deferred because this runs from inside the physics callback that reported the overlap, and
	# the physics server will not accept the change until it is out of that callback. Turning
	# monitoring off is the point: a spent trigger should stop costing overlap tests entirely.
	set_deferred(&"monitoring", false)

## Puts the trigger back in service.
func rearm() -> void:
	_spent = false
	set_deferred(&"monitoring", true)

func is_spent() -> bool:
	return _spent

#endregion

#region Persistence

func save_state() -> Dictionary:
	return {"spent": _spent}

func load_state(state: Dictionary) -> void:
	if bool(state.get("spent", false)):
		_spend()
	else:
		rearm()

#endregion
