class_name FlowLevelEntry
extends Resource

## One level in the registry: the id story rules use, and the scene it actually resolves to.
##
## The indirection is the point. Story logic, save files and triggers all name [member level_id],
## so a level can be renamed or moved on disk by editing this one row.

@export var level_id: StringName = &""
## Kept as a path rather than a [PackedScene] export on purpose: exporting the scene would make the
## editor load every level up front, which is exactly what the threaded loader exists to avoid.
@export_file("*.tscn") var scene_path: String = ""
## Shown on the loading screen and on the save browser row. Falls back to the id.
@export var display_name: String = ""
## Where the player arrives when nothing more specific is asked for.
@export var default_spawn: StringName = &"default"
## Levels likely to follow this one. [FlowLoader] can warm these during a cutscene so the swap
## after it costs nothing. Leave empty rather than listing everything -- preloading the whole game
## at boot spends memory to save nothing.
@export var preload_next: Array[StringName] = []

func label() -> String:
	return display_name if not display_name.is_empty() else String(level_id)
