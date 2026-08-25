@tool
class_name FlowNodeCatalog
extends RefCounted

## Fixed catalog of the fundamental flow steps implemented by [FlowGraphRunner].
##
## This supplies validation and editor-palette metadata; it is deliberately not an executor
## registry. Adding a [FlowGraphNode] script cannot add runtime semantics on its own. Games expose
## their own behavior through **Run Game Action** and a provider registered with [FlowSystem].

const BUILTIN_NODE_SCRIPTS: Array[Script] = [
	preload("res://addons/game_flow/data/flow_game_start_node.gd"),
	preload("res://addons/game_flow/data/flow_event_entry_node.gd"),
	preload("res://addons/game_flow/data/flow_end_node.gd"),
	preload("res://addons/game_flow/data/flow_if_node.gd"),
	preload("res://addons/game_flow/data/flow_parallel_node.gd"),
	preload("res://addons/game_flow/data/flow_random_node.gd"),
	preload("res://addons/game_flow/data/flow_subgraph_entry_node.gd"),
	preload("res://addons/game_flow/data/flow_subgraph_exit_node.gd"),
	preload("res://addons/game_flow/data/flow_call_subgraph_node.gd"),
	preload("res://addons/game_flow/data/flow_set_flag_node.gd"),
	preload("res://addons/game_flow/data/flow_set_value_node.gd"),
	preload("res://addons/game_flow/data/flow_wait_timer_node.gd"),
	preload("res://addons/game_flow/data/flow_wait_event_node.gd"),
	preload("res://addons/game_flow/data/flow_emit_event_node.gd"),
	preload("res://addons/game_flow/data/flow_play_cutscene_node.gd"),
	preload("res://addons/game_flow/data/flow_preload_level_node.gd"),
	preload("res://addons/game_flow/data/flow_load_level_node.gd"),
	preload("res://addons/game_flow/data/flow_request_save_node.gd"),
	preload("res://addons/game_flow/data/flow_disable_input_node.gd"),
	preload("res://addons/game_flow/data/flow_enable_input_node.gd"),
	preload("res://addons/game_flow/data/flow_invoke_action_node.gd"),
]

static var _descriptors: Dictionary = {}
static var _builtins_ready: bool = false


static func get_descriptor(type_id: StringName) -> FlowNodeDescriptor:
	_ensure_builtins()
	return _descriptors.get(type_id)


static func has_type(type_id: StringName) -> bool:
	_ensure_builtins()
	return _descriptors.has(type_id)


static func descriptors() -> Array[FlowNodeDescriptor]:
	_ensure_builtins()
	var out: Array[FlowNodeDescriptor] = []
	for descriptor: FlowNodeDescriptor in _descriptors.values():
		out.append(descriptor)
	out.sort_custom(func(a: FlowNodeDescriptor, b: FlowNodeDescriptor) -> bool:
		return a.display_name.naturalnocasecmp_to(b.display_name) < 0)
	return out


static func type_ids() -> Array[StringName]:
	_ensure_builtins()
	var out: Array[StringName] = []
	for type_id: StringName in _descriptors:
		out.append(type_id)
	out.sort_custom(func(a: StringName, b: StringName) -> bool:
		return String(a).naturalnocasecmp_to(String(b)) < 0)
	return out


static func create_node(type_id: StringName) -> FlowGraphNode:
	var descriptor := get_descriptor(type_id)
	return descriptor.create_node() if descriptor != null else null


static func _ensure_builtins() -> void:
	if _builtins_ready:
		return
	_builtins_ready = true
	for node_script: Script in BUILTIN_NODE_SCRIPTS:
		var prototype := node_script.new() as FlowGraphNode
		if prototype == null or prototype.type_id().is_empty() or prototype.type_id() == &"base":
			continue
		var descriptor := FlowNodeDescriptor.new()
		descriptor.type_id = prototype.type_id()
		descriptor.display_name = prototype.display_title()
		descriptor.category = _builtin_category(prototype.type_id())
		descriptor.description = _builtin_description(prototype.type_id())
		descriptor.node_script = node_script
		_descriptors[descriptor.type_id] = descriptor


static func _builtin_category(type_id: StringName) -> String:
	match type_id:
		&"game_start", &"event_entry", &"end":
			return "Start & Finish"
		&"if", &"parallel", &"random":
			return "Choices & Paths"
		&"subgraph_entry", &"subgraph_exit", &"call_subgraph":
			return "Subgraphs"
		&"set_flag", &"set_value":
			return "Story State"
		&"wait_timer", &"wait_event", &"emit_event":
			return "Events & Timing"
		&"play_cutscene", &"preload_level", &"load_level":
			return "Levels & Cutscenes"
		&"request_save":
			return "Saving"
		&"disable_input", &"enable_input":
			return "Player"
		&"invoke_action":
			return "Game Actions"
	return "Other"


static func _builtin_description(type_id: StringName) -> String:
	match type_id:
		&"game_start":
			return "Begins the master graph when a new game-flow run starts. Use exactly one."
		&"event_entry":
			return "Starts a new path whenever the named gameplay event happens."
		&"end":
			return "Ends only the path that reaches this step. Other active paths keep running."
		&"if":
			return "Checks a story condition and continues through Yes or No."
		&"parallel":
			return "Starts every connected path at the same time. Waiting on one path does not stop the others."
		&"random":
			return "Chooses one connected outcome. A larger Chance Weight makes an outcome more likely."
		&"subgraph_entry":
			return "Marks where a reusable subgraph begins. Each subgraph needs exactly one."
		&"subgraph_exit":
			return "Finishes this subgraph and returns its named result to the graph that started it."
		&"call_subgraph":
			return "Runs a reusable subgraph, waits for it to finish, then continues through its result."
		&"set_flag":
			return "Sets a story flag On or Off. On remembers it; Off removes it and conditions read false."
		&"set_value":
			return "Stores a named story value such as a chapter number, score, phase, or relationship level."
		&"wait_timer":
			return "Pauses only this path for the chosen number of seconds. Other paths keep running."
		&"wait_event":
			return "Pauses only this path until the named gameplay event happens."
		&"emit_event":
			return "Sends a named event to waiting graph paths and gameplay systems."
		&"play_cutscene":
			return "Plays the chosen cutscene, waits for it to finish, then continues."
		&"preload_level":
			return "Prepares a level in the background so a later level change can be faster."
		&"load_level":
			return "Changes to the chosen level and continues after the new world is ready."
		&"request_save":
			return "Creates a safe save checkpoint before this path continues."
		&"disable_input":
			return "Locks player controls until a matching Unlock Player Controls step is reached."
		&"enable_input":
			return "Releases the matching player-control lock. Other active locks still apply."
		&"invoke_action":
			return "Asks a game-owned system to perform an action. GameFlow controls when; game code controls how."
	return ""
