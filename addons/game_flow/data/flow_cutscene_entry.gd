class_name FlowCutsceneEntry
extends Resource

## One cutscene in the registry. Same indirection as [FlowLevelEntry]: story rules name the id,
## never the scene path.

@export var cutscene_id: StringName = &""
@export_file("*.tscn") var scene_path: String = ""
@export var display_name: String = ""
## Whether gameplay input is taken away for the duration. Off for a scripted moment the player can
## still walk through, on for a camera take.
@export var blocks_input: bool = true
## Whether the cutscene may be skipped. A skipped cutscene still reports finished, so the actions
## queued behind it run either way.
@export var skippable: bool = true

func label() -> String:
	return display_name if not display_name.is_empty() else String(cutscene_id)
