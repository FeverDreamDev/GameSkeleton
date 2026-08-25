@tool
extends EditorInspectorPlugin

## Presentation-only names and help for GameFlow node properties.
##
## The real property paths are deliberately unchanged so existing Resources, runtime code, undo,
## and save snapshots keep the same stable contracts. Godot's own property editor still owns the
## value widget; this adapter only replaces its visible label and tooltip.

var _creating_builtin_editor: bool = false


func _can_handle(object: Object) -> bool:
	return object is FlowGraphNode or object is FlowCondition or object is FlowRandomBranch


func _parse_property(
		object: Object,
		type: Variant.Type,
		name: String,
		hint_type: PropertyHint,
		hint_string: String,
		usage_flags: int,
		wide: bool
) -> bool:
	# instantiate_property_editor() asks registered Inspector plugins for help. The guard lets that
	# nested request fall through to Godot's native editor instead of recursively selecting us.
	if _creating_builtin_editor:
		return false
	var friendly_label := friendly_label_for(object, name)
	if friendly_label.is_empty():
		return false
	var shown_hint_type := hint_type
	var shown_hint_string := hint_string
	if object is FlowCondition and name == "source":
		shown_hint_type = PROPERTY_HINT_ENUM
		shown_hint_string = "Story Flag,Story Value,Event Detail,Path Value"
	elif object is FlowCondition and name == "operator":
		shown_hint_type = PROPERTY_HINT_ENUM
		shown_hint_string = "Equals,Is Not,Less Than,At Most,Greater Than,At Least,Is On,Is Off,Is Set,Is Not Set"
	_creating_builtin_editor = true
	var editor := EditorInspector.instantiate_property_editor(
		object, type, name, shown_hint_type, shown_hint_string, usage_flags, wide)
	_creating_builtin_editor = false
	if editor == null:
		return false
	var help := friendly_help_for(object, name)
	if not help.is_empty():
		editor.tooltip_text = help
	add_property_editor(name, editor, false, friendly_label)
	return true


func friendly_enum_options_for(object: Object, property_name: String) -> PackedStringArray:
	if not object is FlowCondition:
		return PackedStringArray()
	if property_name == "source":
		return PackedStringArray(["Story Flag", "Story Value", "Event Detail", "Path Value"])
	if property_name == "operator":
		return PackedStringArray([
			"Equals", "Is Not", "Less Than", "At Most", "Greater Than", "At Least",
			"Is On", "Is Off", "Is Set", "Is Not Set"])
	return PackedStringArray()


func friendly_label_for(object: Object, property_name: String) -> String:
	if object is FlowCondition:
		match property_name:
			"source":
				return "Where to Look"
			"key":
				return "Name to Check"
			"operator":
				return "Comparison"
			"value":
				return "Compare With"
	if object is FlowRandomBranch:
		match property_name:
			"label":
				return "Outcome Name"
			"weight":
				return "Chance Weight"
	if not object is FlowGraphNode:
		return ""
	match property_name:
		"title_override":
			return "Custom Title"
		"comment":
			return "Designer Note"
		"enabled":
			return "Use This Step"
		"event_id":
			return "Event Name"
		"one_shot":
			return "Trigger Only Once"
		"condition":
			return "Condition"
		"subgraph_id":
			return "Subgraph"
		"exit_ids":
			return "Possible Results"
		"exit_id":
			return "Result Name"
		"flag_id":
			return "Story Flag"
		"flag_value":
			return "Flag Is On"
		"value_key":
			return "Story Value Name"
		"value":
			return "New Value"
		"seconds":
			return "Time in Seconds"
		"data":
			return "Event Details"
		"cutscene_id":
			return "Cutscene"
		"context":
			return "Cutscene Details"
		"level_id":
			return "Level"
		"spawn_id":
			return "Player Start"
		"transition_data":
			return "Level Transition Details"
		"reason":
			return "Save Label"
		"lease_id":
			return "Control Lock Name"
		"action_id":
			return "Game Action"
		"arguments":
			return "Action Settings"
	return ""


func friendly_help_for(object: Object, property_name: String) -> String:
	if object is FlowCondition:
		match property_name:
			"source":
				return "Choose whether to check saved story state, details from the event that started this path, or a value local to this path."
			"key":
				return "The exact name of the flag or value to check, such as boss_defeated or chapter_number."
			"operator":
				return "Choose how the current value should be compared."
			"value":
				return "The value on the right side of the comparison. It is not needed for Is On, Is Off, Is Set, or Is Not Set."
	if object is FlowRandomBranch:
		match property_name:
			"label":
				return "The readable outcome name shown on the node."
			"weight":
				return "Relative chance for this outcome. For example, weights 99 and 1 produce 99% and 1% chances."
	if not object is FlowGraphNode:
		return ""
	match property_name:
		"title_override":
			return "Optional label shown on this node instead of its automatic title."
		"comment":
			return "An author note for teammates. It does not change what the graph does."
		"enabled":
			return "Turn this off to temporarily leave the step out of the flow."
		"event_id":
			return "The shared gameplay event name, such as player_entered_tunnel or boss_defeated."
		"one_shot":
			return "When on, this entry starts a path only the first time the event happens during this run."
		"condition":
			return "Create or open the condition to choose what this step checks."
		"subgraph_id":
			return "Choose the reusable subgraph to run."
		"exit_ids":
			return "The result names this node expects the subgraph to return."
		"exit_id":
			return "The result returned to the graph that started this subgraph."
		"flag_id":
			return "A memorable story-state name, such as met_mayor or bridge_repaired."
		"flag_value":
			return "On = the flag is set. Off = the flag is removed and conditions treat it as false."
		"value_key":
			return "A memorable story-state name, such as chapter_number or boss_phase."
		"value":
			return "The number, text, boolean, array, or dictionary to remember. Live scene objects cannot be saved here."
		"seconds":
			return "How long this path pauses. Other graph paths continue normally."
		"data":
			return "Optional save-safe details sent with the event."
		"cutscene_id":
			return "Choose a cutscene registered by the game."
		"context":
			return "Optional save-safe details passed to the cutscene. Most cutscenes can leave this empty."
		"level_id":
			return "Choose a level registered by the game."
		"spawn_id":
			return "Optional named starting point for the player in the new level."
		"transition_data":
			return "Optional save-safe details for the level transition. Most level changes can leave this empty."
		"reason":
			return "A readable internal label describing why this checkpoint exists, such as intro_complete."
		"lease_id":
			return "Use the same lock name on matching Lock and Unlock Player Controls steps. Separate names can overlap safely."
		"action_id":
			return "Choose an action provided by the game, such as start_encounter or open_secret_door."
		"arguments":
			return "Optional save-safe settings passed to the selected game action."
	return ""
