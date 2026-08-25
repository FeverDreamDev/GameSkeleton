@tool
class_name FlowNodeCatalog
extends RefCounted

## Shared registry used by graph validation and the editor node palette.
##
## Games may register additional FlowGraphNode scripts without editing a central enum. Runtime
## action implementations remain keyed separately by FlowInvokeActionNode.action_id.

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
	preload("res://addons/game_flow/data/flow_clear_flag_node.gd"),
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


static func register_descriptor(descriptor: FlowNodeDescriptor, replace: bool = false) -> bool:
	if descriptor == null or not descriptor.is_valid():
		push_warning("FlowNodeCatalog: refusing an invalid descriptor.")
		return false
	if _descriptors.has(descriptor.type_id) and not replace:
		push_warning("FlowNodeCatalog: type_id '%s' is already registered." % descriptor.type_id)
		return false
	_descriptors[descriptor.type_id] = descriptor
	return true


static func register_node_script(
		node_script: Script,
		category: String = "Custom",
		description: String = "",
		replace: bool = false,
		persistence_policy: FlowNodeDescriptor.PersistencePolicy = \
				FlowNodeDescriptor.PersistencePolicy.SAVE_BLOCKING,
		exclusivity_group: StringName = &""
) -> bool:
	if node_script == null or not node_script.can_instantiate():
		push_warning("FlowNodeCatalog: node script cannot be instantiated.")
		return false
	var prototype := node_script.new() as FlowGraphNode
	if prototype == null or prototype.type_id().is_empty() or prototype.type_id() == &"base":
		push_warning("FlowNodeCatalog: node script must create a concrete FlowGraphNode with a type_id.")
		return false
	var descriptor := FlowNodeDescriptor.new()
	descriptor.type_id = prototype.type_id()
	descriptor.display_name = prototype.display_title()
	descriptor.category = category
	descriptor.description = description
	descriptor.node_script = node_script
	descriptor.persistence_policy = persistence_policy
	descriptor.exclusivity_group = exclusivity_group
	return register_descriptor(descriptor, replace)


static func unregister_type(type_id: StringName) -> void:
	_ensure_builtins()
	_descriptors.erase(type_id)


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


static func reset_custom_descriptors() -> void:
	_descriptors.clear()
	_builtins_ready = false
	_ensure_builtins()


static func _ensure_builtins() -> void:
	if _builtins_ready:
		return
	_builtins_ready = true
	for node_script: Script in BUILTIN_NODE_SCRIPTS:
		var prototype := node_script.new() as FlowGraphNode
		if prototype == null:
			continue
		register_node_script(
			node_script,
			_builtin_category(prototype.type_id()),
			_builtin_description(prototype.type_id()),
			false,
			_builtin_persistence_policy(prototype.type_id()),
			_builtin_exclusivity_group(prototype.type_id())
		)


static func _builtin_category(type_id: StringName) -> String:
	match type_id:
		&"game_start", &"event_entry", &"end":
			return "Flow"
		&"if", &"parallel", &"random", &"subgraph_entry", &"subgraph_exit", \
				&"call_subgraph":
			return "Control"
		&"set_flag", &"clear_flag", &"set_value":
			return "State"
		&"wait_timer", &"wait_event", &"emit_event":
			return "Events & Timing"
		&"play_cutscene", &"preload_level", &"load_level", &"request_save":
			return "Game Flow"
		&"disable_input", &"enable_input":
			return "Input"
		&"invoke_action":
			return "Game Actions"
	return "Other"


static func _builtin_description(type_id: StringName) -> String:
	match type_id:
		&"parallel":
			return "Starts one independent execution path for every wire leaving its output."
		&"random":
			return "Chooses one connected execution output using authored relative weights."
		&"call_subgraph":
			return "Runs a registered subgraph and resumes through its named exit."
		&"invoke_action":
			return "Invokes a game-registered action without adding a hardcoded flow-node enum case."
	return ""


static func _builtin_persistence_policy(
		type_id: StringName
) -> FlowNodeDescriptor.PersistencePolicy:
	match type_id:
		&"wait_timer", &"wait_event", &"call_subgraph":
			return FlowNodeDescriptor.PersistencePolicy.RESUMABLE
		&"play_cutscene", &"load_level", &"invoke_action":
			return FlowNodeDescriptor.PersistencePolicy.SAVE_BLOCKING
	return FlowNodeDescriptor.PersistencePolicy.INSTANT


static func _builtin_exclusivity_group(type_id: StringName) -> StringName:
	if type_id == &"play_cutscene" or type_id == &"load_level":
		return &"major_flow"
	return &""
