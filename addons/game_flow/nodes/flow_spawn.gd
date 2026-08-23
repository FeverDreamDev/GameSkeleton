class_name FlowSpawn
extends Marker3D

## A named place a player can arrive. Levels carry these so story rules can say
## [code]&"loading_dock"[/code] instead of a hardcoded [Transform3D] that breaks the moment the
## level is rearranged.
##
## Put them under a [code]SpawnPoints[/code] node for tidiness; [FlowLevel] finds them anywhere
## beneath itself.

## The name story rules and save files use. One spawn per level should be called
## [code]default[/code] -- it is what a missing or unknown spawn falls back to.
@export var spawn_id: StringName = &"default"

## Whether arriving here also sets which way the player faces. Off for a spawn that should leave
## the player looking wherever they already were, which is what you want when a level reloads
## around them rather than being entered fresh.
@export var applies_facing: bool = true

## Where the camera looks on arrival. Yaw comes from this marker's own rotation; only pitch has to
## be authored, because a [Marker3D] gizmo cannot show it.
@export_range(-89.0, 89.0, 0.5, "suffix:°") var look_pitch_degrees: float = 0.0

## The direction this marker faces, in radians, ready to assign to a body's [code]rotation.y[/code].
func spawn_yaw() -> float:
	return global_rotation.y

## The pitch this marker asks the camera for, in radians.
func look_pitch() -> float:
	return deg_to_rad(look_pitch_degrees)
