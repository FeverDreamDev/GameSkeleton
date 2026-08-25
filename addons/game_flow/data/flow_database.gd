@tool
class_name FlowDatabase
extends Resource

## Every graph, level, cutscene and custom-action definition in the game, assigned to [FlowSystem].
##
## The arrays are what you author; the dictionaries are built from them once and are what the
## graph runtime reads, so registry lookups remain constant-time as the game grows.

@export var levels: Array[FlowLevelEntry] = []
@export var cutscenes: Array[FlowCutsceneEntry] = []

@export_group("Graphs")
@export var graphs: Array[FlowGraphEntry] = []
@export var master_graph_id: StringName = &""

@export_group("Custom Actions")
## Optional authoring catalog. Runtime Callables are registered separately on FlowSystem.
@export var custom_actions: Array[FlowCustomActionEntry] = []

var _level_index: Dictionary = {}
var _cutscene_index: Dictionary = {}
var _graph_index: Dictionary = {}
var _custom_action_index: Dictionary = {}
var _indexed: bool = false

#region Lookup

func get_level(level_id: StringName) -> FlowLevelEntry:
	_ensure_index()
	return _level_index.get(level_id)

func get_cutscene(cutscene_id: StringName) -> FlowCutsceneEntry:
	_ensure_index()
	return _cutscene_index.get(cutscene_id)

func get_graph_entry(graph_id: StringName) -> FlowGraphEntry:
	_ensure_index()
	return _graph_index.get(graph_id)

func get_graph(graph_id: StringName) -> FlowGraph:
	var entry := get_graph_entry(graph_id)
	return entry.graph if entry != null else null

func get_master_graph() -> FlowGraph:
	return get_graph(master_graph_id) if not master_graph_id.is_empty() else null

func get_custom_action(action_id: StringName) -> FlowCustomActionEntry:
	_ensure_index()
	return _custom_action_index.get(action_id)

func has_custom_action_catalog() -> bool:
	return not custom_actions.is_empty()

func level_ids() -> Array[StringName]:
	_ensure_index()
	var out: Array[StringName] = []
	for id: StringName in _level_index:
		out.append(id)
	return out

func graph_ids() -> Array[StringName]:
	_ensure_index()
	var names: Array[String] = []
	for graph_id: StringName in _graph_index:
		names.append(String(graph_id))
	names.sort()
	var out: Array[StringName] = []
	for graph_name: String in names:
		out.append(StringName(graph_name))
	return out

func custom_action_ids() -> Array[StringName]:
	_ensure_index()
	var names: Array[String] = []
	for action_id: StringName in _custom_action_index:
		names.append(String(action_id))
	names.sort()
	var out: Array[StringName] = []
	for action_name: String in names:
		out.append(StringName(action_name))
	return out

## The id whose entry points at [param path]. Lets a save written before the registry existed --
## one that recorded a raw scene path -- still resolve to a level.
func level_id_for_path(path: String) -> StringName:
	_ensure_index()
	for id: StringName in _level_index:
		var entry: FlowLevelEntry = _level_index[id]
		if entry.scene_path == path:
			return id
	return &""

#endregion

#region Index

func _ensure_index() -> void:
	if not _indexed:
		rebuild_index()

## Call after editing the arrays at runtime. Authoring in the inspector does not need it -- the
## index is built on first use.
func rebuild_index() -> void:
	_level_index.clear()
	_cutscene_index.clear()
	_graph_index.clear()
	_custom_action_index.clear()

	for level: FlowLevelEntry in levels:
		if level != null and not level.level_id.is_empty():
			_level_index[level.level_id] = level
	for cutscene: FlowCutsceneEntry in cutscenes:
		if cutscene != null and not cutscene.cutscene_id.is_empty():
			_cutscene_index[cutscene.cutscene_id] = cutscene
	for graph_entry: FlowGraphEntry in graphs:
		if graph_entry != null and not graph_entry.graph_id.is_empty():
			_graph_index[graph_entry.graph_id] = graph_entry
	for action_entry: FlowCustomActionEntry in custom_actions:
		if action_entry != null and not action_entry.action_id.is_empty():
			_custom_action_index[action_entry.action_id] = action_entry

	_indexed = true

#endregion

#region Validation

## Every problem in the database, as readable lines. A missing level is worth saying out loud at
## startup rather than discovering it as a silent failed transition three rooms later.
##
## Returns an empty array when the database is sound.
func validate() -> Array[String]:
	rebuild_index()
	var problems: Array[String] = []

	_check_duplicates(levels, "level", problems)
	_check_duplicates(cutscenes, "cutscene", problems)

	for level: FlowLevelEntry in levels:
		if level == null:
			continue
		if level.scene_path.is_empty():
			problems.append("level '%s' has no scene path" % level.level_id)
		elif not ResourceLoader.exists(level.scene_path):
			problems.append("level '%s' points at a scene that is not there: %s" % [level.level_id, level.scene_path])
		for next_id: StringName in level.preload_next:
			if not _level_index.has(next_id):
				problems.append("level '%s' wants to preload unknown level '%s'" % [level.level_id, next_id])

	for cutscene: FlowCutsceneEntry in cutscenes:
		if cutscene == null:
			continue
		if cutscene.scene_path.is_empty():
			problems.append("cutscene '%s' has no scene path" % cutscene.cutscene_id)
		elif not ResourceLoader.exists(cutscene.scene_path):
			problems.append("cutscene '%s' points at a scene that is not there: %s" % [cutscene.cutscene_id, cutscene.scene_path])

	# Registry scene-path problems were already appended above for the plain-text validation API.
	for issue: FlowValidationIssue in _validate_graphs(false):
		problems.append(issue.format_message())

	return problems

## Structured registry and graph validation for editor presentation and automated checks.
## [method validate] remains the backwards-compatible string API and includes these messages.
func validate_graphs() -> Array[FlowValidationIssue]:
	rebuild_index()
	return _validate_graphs(true)

func _validate_graphs(include_registry_paths: bool = true) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if include_registry_paths:
		_validate_registry_paths(issues)
	var seen_graph_ids := {}
	if not master_graph_id.is_empty() and not _graph_index.has(master_graph_id):
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"unknown_master_graph",
			"The Main Game Graph '%s' is not in the Game Flow library." % master_graph_id,
			master_graph_id
		))
	elif master_graph_id.is_empty() and not graphs.is_empty():
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.WARNING,
			&"missing_master_graph",
			"Choose one graph in the Game Flow library as the Main Game Graph."
		))

	for entry: FlowGraphEntry in graphs:
		if entry == null:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"empty_graph_entry",
				"The Game Flow library contains an empty graph slot. Remove it or choose a graph."
			))
			continue
		if entry.graph_id.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"graph_entry_missing_id",
				"A graph in the Game Flow library has no Library Name."
			))
		elif seen_graph_ids.has(entry.graph_id):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"duplicate_graph_id",
				"Two graphs in the Game Flow library share the Library Name '%s'." % entry.graph_id,
				entry.graph_id
			))
		else:
			seen_graph_ids[entry.graph_id] = true
		if entry.graph == null:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"graph_entry_missing_resource",
				"The library entry '%s' does not point to a flow graph." % entry.graph_id,
				entry.graph_id
			))
			continue
		if entry.graph_id == master_graph_id and entry.graph.kind != FlowGraph.Kind.MASTER:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"master_graph_kind_mismatch",
				"The chosen Main Game Graph is marked as a Reusable Subgraph. Change its Graph Type.",
				entry.graph_id
			))
		var graph_issues := entry.graph.validate_detailed(entry.graph_id, self)
		for issue: FlowValidationIssue in graph_issues:
			if issue.graph_path.is_empty():
				issue.graph_path = entry.graph.resource_path
		issues.append_array(graph_issues)

	_validate_subgraph_contracts(issues)
	_validate_subgraph_cycles(issues)
	_validate_custom_action_catalog(issues)
	return issues


func _validate_registry_paths(issues: Array[FlowValidationIssue]) -> void:
	for index in levels.size():
		var level := levels[index]
		if level == null:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"empty_level_entry",
				"level registry slot %d is empty" % index
			))
			continue
		if level.scene_path.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"level_missing_scene_path",
				"level '%s' has no scene path" % level.level_id
			))
		elif not ResourceLoader.exists(level.scene_path):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"level_scene_missing",
				"level '%s' points at a scene that is not there: %s" \
						% [level.level_id, level.scene_path]
			))
		for next_id: StringName in level.preload_next:
			if not _level_index.has(next_id):
				issues.append(FlowValidationIssue.make(
					FlowValidationIssue.Severity.ERROR,
					&"level_preload_unknown_id",
					"level '%s' wants to preload unknown level '%s'" \
							% [level.level_id, next_id]
				))

	for index in cutscenes.size():
		var cutscene := cutscenes[index]
		if cutscene == null:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"empty_cutscene_entry",
				"cutscene registry slot %d is empty" % index
			))
			continue
		if cutscene.scene_path.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"cutscene_missing_scene_path",
				"cutscene '%s' has no scene path" % cutscene.cutscene_id
			))
		elif not ResourceLoader.exists(cutscene.scene_path):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"cutscene_scene_missing",
				"cutscene '%s' points at a scene that is not there: %s" \
						% [cutscene.cutscene_id, cutscene.scene_path]
			))

func _validate_custom_action_catalog(issues: Array[FlowValidationIssue]) -> void:
	var seen := {}
	for entry: FlowCustomActionEntry in custom_actions:
		if entry == null:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"empty_custom_action_entry",
				"The Game Action library contains an empty slot."
			))
			continue
		if entry.action_id.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"custom_action_missing_id",
				"A Game Action in the library has no Library Name."
			))
		elif seen.has(entry.action_id):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"duplicate_custom_action_id",
				"Two Game Actions share the Library Name '%s'." % entry.action_id
			))
		else:
			seen[entry.action_id] = true
		if entry.persistence_policy == FlowNodeDescriptor.PersistencePolicy.RESUMABLE:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"custom_action_resumable_reserved",
				"custom action '%s' claims RESUMABLE, but provider snapshots are not supported in v1; use INSTANT or SAVE_BLOCKING" \
						% entry.action_id
			))

func _validate_subgraph_contracts(issues: Array[FlowValidationIssue]) -> void:
	var called_graphs := {}
	for source_entry: FlowGraphEntry in graphs:
		if source_entry == null or source_entry.graph == null:
			continue
		for node: FlowGraphNode in source_entry.graph.nodes:
			if not node is FlowCallSubgraphNode:
				continue
			var call := node as FlowCallSubgraphNode
			if call.subgraph_id.is_empty() or not _graph_index.has(call.subgraph_id):
				continue
			called_graphs[call.subgraph_id] = true
			var target := get_graph(call.subgraph_id)
			if target == null:
				continue
			if target.kind != FlowGraph.Kind.SUBGRAPH:
				issues.append(FlowValidationIssue.make(
					FlowValidationIssue.Severity.ERROR,
					&"call_target_not_subgraph",
					"Run Subgraph points to '%s', but that graph is not marked Reusable Subgraph." % call.subgraph_id,
					source_entry.graph_id,
					call.node_id
				))
			var target_exits := target.subgraph_exit_ids()
			for exit_id: StringName in call.exit_ids:
				if exit_id.is_empty() or exit_id == &"failed":
					continue
				if not target_exits.has(exit_id):
					issues.append(FlowValidationIssue.make(
						FlowValidationIssue.Severity.ERROR,
						&"call_subgraph_unknown_exit",
						"Subgraph '%s' has no Finish Subgraph result named '%s'." % [call.subgraph_id, exit_id],
						source_entry.graph_id,
						call.node_id
					))
			for exit_id: StringName in target_exits:
				if not call.exit_ids.has(exit_id):
					issues.append(FlowValidationIssue.make(
						FlowValidationIssue.Severity.ERROR,
						&"call_subgraph_unhandled_exit",
						"Run Subgraph does not expose the '%s' result returned by '%s'." % [exit_id, call.subgraph_id],
						source_entry.graph_id,
						call.node_id
					))

	for graph_id: StringName in called_graphs:
		var graph := get_graph(graph_id)
		if graph == null:
			continue
		var entry_count := 0
		for node: FlowGraphNode in graph.nodes:
			if node is FlowSubgraphEntryNode and node.enabled:
				entry_count += 1
		if entry_count != 1:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"subgraph_entry_count",
				"A called subgraph needs exactly one Subgraph Starts Here step (found %d)." % entry_count,
				graph_id
			))

func _validate_subgraph_cycles(issues: Array[FlowValidationIssue]) -> void:
	var adjacency := {}
	for entry: FlowGraphEntry in graphs:
		if entry == null or entry.graph == null or entry.graph_id.is_empty():
			continue
		var targets: Array[StringName] = []
		for node: FlowGraphNode in entry.graph.nodes:
			if node is FlowCallSubgraphNode:
				var target_id := (node as FlowCallSubgraphNode).subgraph_id
				if not target_id.is_empty() and _graph_index.has(target_id) and not targets.has(target_id):
					targets.append(target_id)
		adjacency[entry.graph_id] = targets

	var state := {}
	for graph_id: StringName in adjacency:
		if int(state.get(graph_id, 0)) != 0:
			continue
		var cycle_graph := _visit_subgraph_cycle(graph_id, adjacency, state)
		if not cycle_graph.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"recursive_subgraph_call",
				"These Run Subgraph steps call one another in a loop. Recursive subgraphs are not allowed.",
				cycle_graph
			))
			return

func _visit_subgraph_cycle(
		graph_id: StringName,
		adjacency: Dictionary,
		state: Dictionary
) -> StringName:
	state[graph_id] = 1
	var raw_targets: Variant = adjacency.get(graph_id)
	if raw_targets is Array:
		for target_variant: Variant in raw_targets:
			var target_id := StringName(str(target_variant))
			var target_state := int(state.get(target_id, 0))
			if target_state == 1:
				return target_id
			if target_state == 0:
				var found := _visit_subgraph_cycle(target_id, adjacency, state)
				if not found.is_empty():
					return found
	state[graph_id] = 2
	return &""

## Generic duplicate check over levels and cutscenes. Each resource type names its id
## differently, so the id is read by property name rather than through a shared base class.
func _check_duplicates(entries: Array, kind: String, problems: Array[String]) -> void:
	var seen := {}
	var property := "%s_id" % kind
	for entry: Resource in entries:
		if entry == null:
			problems.append("the %s list has an empty slot" % kind)
			continue
		var id: StringName = entry.get(property)
		if id.is_empty():
			problems.append("a %s has no id" % kind)
		elif seen.has(id):
			problems.append("two %s entries share the id '%s'" % [kind, id])
		else:
			seen[id] = true

#endregion
