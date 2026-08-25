extends SceneTree

## Lightweight editor-only smoke for the Game Flow workspace.
##
## The host project enables the add-on. This standalone command verifies the workspace directly:
## godot --headless --editor --path . --script \
##   res://addons/game_flow/tests/flow_graph_editor_smoke.gd

const WorkspaceScript := preload("res://addons/game_flow/editor/flow_graph_editor.gd")
const FriendlyInspectorScript := preload(
	"res://addons/game_flow/editor/flow_node_inspector_plugin.gd")
const NodeCatalogScript := preload("res://addons/game_flow/data/flow_node_catalog.gd")
const GraphScript := preload("res://addons/game_flow/data/flow_graph.gd")
const ConnectionScript := preload("res://addons/game_flow/data/flow_graph_connection.gd")
const DatabaseScript := preload("res://addons/game_flow/data/flow_database.gd")
const GraphEntryScript := preload("res://addons/game_flow/data/flow_graph_entry.gd")
const LevelEntryScript := preload("res://addons/game_flow/data/flow_level_entry.gd")
const CutsceneEntryScript := preload("res://addons/game_flow/data/flow_cutscene_entry.gd")
const GameStartNodeScript := preload("res://addons/game_flow/data/flow_game_start_node.gd")
const EndNodeScript := preload("res://addons/game_flow/data/flow_end_node.gd")
const RandomNodeScript := preload("res://addons/game_flow/data/flow_random_node.gd")
const IfNodeScript := preload("res://addons/game_flow/data/flow_if_node.gd")
const ConditionScript := preload("res://addons/game_flow/data/flow_condition.gd")
const CallSubgraphNodeScript := preload("res://addons/game_flow/data/flow_call_subgraph_node.gd")
const SubgraphEntryNodeScript := preload("res://addons/game_flow/data/flow_subgraph_entry_node.gd")
const SubgraphExitNodeScript := preload("res://addons/game_flow/data/flow_subgraph_exit_node.gd")

var _failures: int = 0
var _workspace: Control
var _editor_plugin: EditorPlugin


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Give the headless editor time to install EditorInterface services before creating editor-only
	# controls such as EditorInspector and EditorFileDialog.
	for _frame in 5:
		await process_frame

	_workspace = WorkspaceScript.new()
	_workspace.name = "GameFlowEditorSmoke"
	_editor_plugin = EditorPlugin.new()
	_workspace.set_editor_plugin(_editor_plugin)
	EditorInterface.get_editor_main_screen().add_child(_workspace)
	await process_frame
	_check(_workspace.is_node_ready(), "workspace _ready completed")
	_check(_editor_plugin.get_undo_redo() != null, "workspace uses the editor undo/redo manager")

	var graph = _build_graph()
	_workspace.open_graph(graph)
	await process_frame
	_check(_workspace.can_edit_object(graph), "workspace accepts a FlowGraph Resource")
	_check(_workspace.get("_graph") == graph, "in-memory graph opened")

	var palette := _workspace.get("_palette") as ItemList
	_check(palette != null and palette.item_count > 0, "node catalog populated the searchable palette")
	_check(_palette_contains(palette, "Start & Finish  ›  When Game Starts") \
			and _palette_contains(palette, "Choices & Paths  ›  Check Condition") \
			and _palette_contains(palette, "Player  ›  Lock Player Controls"),
		"palette uses approachable game-design names and categories")
	var catalog_descriptions_complete := true
	for descriptor in NodeCatalogScript.descriptors():
		if descriptor.display_name.is_empty() or descriptor.category.is_empty() \
				or descriptor.description.is_empty():
			catalog_descriptions_complete = false
			break
	_check(catalog_descriptions_complete, "every built-in palette step has author-facing help")

	var canvas := _workspace.get("_graph_edit") as GraphEdit
	var graph_node_count := 0
	if canvas != null:
		for child: Node in canvas.get_children():
			if child is GraphNode:
				graph_node_count += 1
	_check(graph_node_count == 2, "GraphEdit rendered both Resource nodes")
	_check(canvas != null and canvas.get_connection_list().size() == 1,
		"GraphEdit rendered the stable execution connection")

	# Opening and every navigation validate automatically; explicit Validate uses the same path.
	var validation := _workspace.get("_validation") as ItemList
	_check(validation != null and validation.item_count > 0,
		"graph open automatically produced structured validation feedback")

	var node_views: Dictionary = _workspace.get("_node_to_view")
	var start_view := node_views.get(&"start") as GraphNode
	var finish_view := node_views.get(&"finish") as GraphNode
	_check(start_view != null and finish_view != null, "stable node IDs map to disposable GraphNode views")
	_check(start_view.title == "When Game Starts" and finish_view.title == "Stop This Path",
		"canvas titles use plain game-design language")
	_check(_graph_view_contains(start_view, "Next") and _graph_view_contains(finish_view, "Enter"),
		"execution ports read as Enter and Next without changing their stable IDs")
	_check(start_view.tooltip_text.contains("Begins the master graph") \
			and not start_view.tooltip_text.contains("game_start"),
		"canvas tooltip explains behavior instead of exposing a runtime type ID")

	# The editor-only Inspector adapter keeps serialized property paths unchanged while replacing
	# labels and enum choices with terms a designer can understand.
	var friendly_inspector = FriendlyInspectorScript.new()
	var event_entry = preload("res://addons/game_flow/data/flow_event_entry_node.gd").new()
	var condition = ConditionScript.new()
	_check(friendly_inspector.friendly_label_for(event_entry, "event_id") == "Event Name" \
			and friendly_inspector.friendly_label_for(event_entry, "one_shot") == "Trigger Only Once" \
			and friendly_inspector.friendly_label_for(condition, "source") == "Where to Look",
		"Inspector presents common node properties in designer language")
	_check(friendly_inspector.friendly_enum_options_for(condition, "source") \
			== PackedStringArray(["Story Flag", "Story Value", "Event Detail", "Path Value"]),
		"condition sources have friendly choices in their stable numeric order")
	_check(friendly_inspector.friendly_enum_options_for(condition, "operator") \
			== PackedStringArray([
				"Equals", "Is Not", "Less Than", "At Most", "Greater Than", "At Least",
				"Is On", "Is Off", "Is Set", "Is Not Set"]),
		"condition comparisons have friendly choices in their stable numeric order")
	condition.key = &"boss_health"
	condition.operator = ConditionScript.Operator.LESS
	condition.value = 0.3
	var check_node = IfNodeScript.new()
	check_node.condition = condition
	_check(check_node.display_title() == "Check: Boss Health < 0.3" \
			and check_node.port_label(&"true") == "Yes" \
			and check_node.port_label(&"false") == "No",
		"condition step summarizes its rule and uses Yes/No outcomes")

	# Disconnect/connect mutations are authored into the Resource, not just drawn on GraphEdit.
	_workspace.call("_on_disconnection_requested", start_view.name, 0, finish_view.name, 0)
	_check(graph.connections.is_empty(), "disconnect request changed the authored connection array")
	var undo := _editor_plugin.get_undo_redo()
	var graph_history := undo.get_object_history_id(graph)
	undo.get_history_undo_redo(graph_history).undo()
	_check(graph.connections.size() == 1, "disconnect can be undone")
	undo.get_history_undo_redo(graph_history).redo()
	_check(graph.connections.is_empty(), "disconnect can be redone")
	node_views = _workspace.get("_node_to_view")
	start_view = node_views.get(&"start") as GraphNode
	finish_view = node_views.get(&"finish") as GraphNode
	_workspace.call("_on_connection_requested", start_view.name, 0, finish_view.name, 0)
	_check(graph.connections.size() == 1, "connect request created a stable authored connection")

	# Position changes also participate in the editor history.
	node_views = _workspace.get("_node_to_view")
	finish_view = node_views.get(&"finish") as GraphNode
	var old_position: Vector2 = graph.get_node(&"finish").editor_position
	_workspace.call("_on_begin_node_move")
	finish_view.position_offset = old_position + Vector2(96.0, 48.0)
	_workspace.call("_on_end_node_move")
	_check(graph.get_node(&"finish").editor_position == old_position + Vector2(96.0, 48.0),
		"moving a view authored the stable node position")
	graph_history = undo.get_object_history_id(graph)
	undo.get_history_undo_redo(graph_history).undo()
	_check(graph.get_node(&"finish").editor_position == old_position, "node movement can be undone")
	undo.get_history_undo_redo(graph_history).redo()
	_check(graph.get_node(&"finish").editor_position == old_position + Vector2(96.0, 48.0),
		"node movement can be redone")

	# Copy/paste preserves internal topology but assigns fresh permanent IDs.
	_workspace.set("_selected_node_ids", {&"start": true, &"finish": true})
	_workspace.call("_copy_selected_nodes")
	_workspace.call("_paste_nodes")
	_check(graph.nodes.size() == 4 and graph.connections.size() == 2,
		"copy/paste duplicated selected topology")
	var unique_ids: Dictionary = {}
	for node in graph.nodes:
		unique_ids[node.node_id] = true
	_check(unique_ids.size() == graph.nodes.size(), "pasted nodes received fresh stable IDs")

	var pasted_view_names: Array[StringName] = []
	for node in graph.nodes:
		if node.node_id == &"start" or node.node_id == &"finish":
			continue
		var pasted_view := (_workspace.get("_node_to_view") as Dictionary).get(node.node_id) as GraphNode
		if pasted_view != null:
			pasted_view_names.append(pasted_view.name)
	_workspace.call("_on_delete_nodes_requested", pasted_view_names)
	_check(graph.nodes.size() == 2 and graph.connections.size() == 1,
		"delete removed selected nodes and their incident connection")
	graph_history = undo.get_object_history_id(graph)
	undo.get_history_undo_redo(graph_history).undo()
	_check(graph.nodes.size() == 4 and graph.connections.size() == 2, "node deletion can be undone")
	undo.get_history_undo_redo(graph_history).redo()
	_check(graph.nodes.size() == 2 and graph.connections.size() == 1, "node deletion can be redone")

	# External graph persistence survives a cache-replacing reload.
	var save_path := "res://addons/game_flow/tests/.flow_graph_editor_smoke.tres"
	_check(ResourceSaver.save(graph, save_path) == OK, "external FlowGraph resource saved")
	var reopened = ResourceLoader.load(save_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	_check(reopened != null and reopened.nodes.size() == 2 and reopened.connections.size() == 1,
		"external FlowGraph resource reopened with authored topology")

	# Weighted Random has a dedicated structural editor. Port renames and removals keep authored
	# connections valid in the same undo action, while scalar Resource edits stay owner-aware.
	var random_graph = _build_random_graph()
	_workspace.open_graph(random_graph)
	_workspace.call("_select_node", &"random", false)
	var random_node = random_graph.get_node(&"random")
	var common_branch = random_node.branches[0]
	var rare_branch = random_node.branches[1]
	var random_panel := _workspace.get("_random_panel") as VBoxContainer
	var random_rows := _workspace.get("_random_rows") as VBoxContainer
	_check(random_panel != null and random_panel.get_parent().visible and random_rows.get_child_count() == 2,
		"selecting Random exposed both weighted branches in the dedicated editor")

	_workspace.call(
		"_set_random_branch_scalar", random_node, common_branch, &"weight", 99.0,
		"Set Random Branch Weight", false)
	_check(is_equal_approx(common_branch.weight, 99.0), "Random branch weight was authored")
	var branch_history := undo.get_object_history_id(common_branch)
	undo.get_history_undo_redo(branch_history).undo()
	_check(is_equal_approx(common_branch.weight, 1.0), "Random weight edit can be undone")
	undo.get_history_undo_redo(branch_history).redo()
	_check(is_equal_approx(common_branch.weight, 99.0), "Random weight edit can be redone")
	_check(_random_view_contains(random_node.node_id, "chance weight 99"),
		"Random GraphNode output visibly includes its authored weight")

	_workspace.call("_on_inspector_resource_selected", common_branch, "branches/0")
	var embedded_inspector := _workspace.get("_inspector") as EditorInspector
	_check(embedded_inspector.get_edited_object() == common_branch \
			and not (_workspace.get("_inspector_back") as Button).disabled,
		"embedded branch Resource inspection retained its owning node")
	common_branch.label = "Common Outcome"
	_workspace.call("_on_inspector_property_edited", "label")
	_check((_workspace.get("_dirty_graphs") as Dictionary).has(random_graph.get_instance_id()) \
			and _random_view_contains(random_node.node_id, "Common Outcome"),
		"branch Resource edits dirtied and refreshed the owning graph")
	_workspace.call("_on_inspector_back")
	_check(embedded_inspector.get_edited_object() == random_node,
		"embedded inspector returned from the branch to its Random node")

	_workspace.call("_rename_random_branch_port", random_node, common_branch, &"common")
	_check(common_branch.port_id == &"common" \
			and _find_connection(random_graph, &"random_common").from_port_id == &"common",
		"Random port rename atomically migrated its attached wire")
	var random_history := undo.get_object_history_id(random_node)
	undo.get_history_undo_redo(random_history).undo()
	_check(common_branch.port_id == &"option_a" \
			and _find_connection(random_graph, &"random_common").from_port_id == &"option_a",
		"Random port migration can be undone atomically")
	undo.get_history_undo_redo(random_history).redo()
	_check(common_branch.port_id == &"common" \
			and _find_connection(random_graph, &"random_common").from_port_id == &"common",
		"Random port migration can be redone atomically")

	_workspace.call("_remove_random_branch", random_node, 1)
	_check(random_node.branches.size() == 1 \
			and _find_connection(random_graph, &"random_rare") == null,
		"removing a Random branch also removed its attached wire")
	random_history = undo.get_object_history_id(random_node)
	undo.get_history_undo_redo(random_history).undo()
	_check(random_node.branches.size() == 2 \
			and _find_connection(random_graph, &"random_rare") != null,
		"Random branch removal can restore the branch and wire together")
	undo.get_history_undo_redo(random_history).redo()
	_check(random_node.branches.size() == 1 and _find_connection(random_graph, &"random_rare") == null,
		"Random branch removal can be redone")
	undo.get_history_undo_redo(random_history).undo()

	_workspace.call("_add_random_branch")
	_check(random_node.branches.size() == 3 and random_node.output_ports().size() == 3,
		"Add Branch created a fresh dynamic execution port")
	random_history = undo.get_object_history_id(random_node)
	undo.get_history_undo_redo(random_history).undo()
	_check(random_node.branches.size() == 2, "adding a Random branch can be undone")
	undo.get_history_undo_redo(random_history).redo()
	_check(random_node.branches.size() == 3, "adding a Random branch can be redone")

	var random_save_path := "res://addons/game_flow/tests/.flow_random_editor_smoke.tres"
	_check(ResourceSaver.save(random_graph, random_save_path) == OK,
		"Random graph with branch subresources saved externally")
	var reopened_random = ResourceLoader.load(
		random_save_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	var reopened_random_node = reopened_random.get_node(&"random") if reopened_random != null else null
	_check(reopened_random_node != null and reopened_random_node.branches.size() == 3 \
			and is_equal_approx(reopened_random_node.branches[0].weight, 99.0) \
			and _find_connection(reopened_random, &"random_common").from_port_id == &"common",
		"Random weights, stable ports, and migrated wires survived external reopen")

	# Structured validation used by EditorPlugin._build includes registry asset validity, not only
	# graph references to those IDs.
	var invalid_registry = DatabaseScript.new()
	var missing_level = LevelEntryScript.new()
	missing_level.level_id = &"missing_level"
	missing_level.scene_path = "res://does_not_exist/editor_missing_level.tscn"
	invalid_registry.levels.append(missing_level)
	var missing_cutscene = CutsceneEntryScript.new()
	missing_cutscene.cutscene_id = &"missing_cutscene"
	missing_cutscene.scene_path = ""
	invalid_registry.cutscenes.append(missing_cutscene)
	var registry_codes := _issue_codes(invalid_registry.validate_graphs())
	_check(registry_codes.has(&"level_scene_missing") \
			and registry_codes.has(&"cutscene_missing_scene_path"),
		"structured pre-play validation rejects invalid registered scene paths")

	# A database provides graph navigation, registration/master authoring, and breadcrumbs.
	var child = _build_subgraph()
	var database = DatabaseScript.new()
	var master_entry = GraphEntryScript.new()
	master_entry.graph_id = &"editor_master"
	master_entry.graph = graph
	var child_entry = GraphEntryScript.new()
	child_entry.graph_id = &"editor_child"
	child_entry.graph = child
	database.graphs.append(master_entry)
	database.graphs.append(child_entry)
	database.rebuild_index()
	var call_child = CallSubgraphNodeScript.new()
	call_child.node_id = &"call_child"
	call_child.editor_position = Vector2(660.0, 60.0)
	graph.nodes.append(call_child)
	graph.invalidate_index()
	_workspace.set("_active_database", database)
	_workspace.call("_navigate_to", graph, [graph])
	_workspace.call("_select_node", &"call_child", false)
	var reference_picker := _workspace.get("_reference_selector") as OptionButton
	var child_option := -1
	for option in reference_picker.item_count:
		if StringName(str(reference_picker.get_item_metadata(option))) == &"editor_child":
			child_option = option
			break
	_check((_workspace.get("_reference_row") as HBoxContainer).visible and child_option >= 0,
		"node inspector offered IDs from the active FlowDatabase")
	if child_option >= 0:
		_workspace.call("_on_reference_selected", child_option)
	_check(call_child.subgraph_id == &"editor_child", "database reference picker authored the stable ID")
	_check(_workspace.call("_node_title", call_child) == "Run Subgraph: Editor Child",
		"canvas title uses the registered subgraph's readable display name")
	_workspace.call("_open_subgraph", &"editor_child")
	_check(_workspace.get("_graph") == child and (_workspace.get("_breadcrumbs") as Array).size() == 2,
		"subgraph navigation pushed a breadcrumb")
	_workspace.call("_navigate_back")
	_check(_workspace.get("_graph") == graph, "back navigation returned to the master graph")
	_workspace.call("_navigate_forward")
	_check(_workspace.get("_graph") == child, "forward navigation reopened the subgraph")

	# Register and Set Master are normal undoable database edits.
	var standalone = _build_graph()
	standalone.display_name = "Registered Smoke"
	var register_database = DatabaseScript.new()
	_workspace.open_graph(standalone)
	_workspace.set("_active_database", register_database)
	var database_selector := _workspace.get("_register_database_selector") as OptionButton
	database_selector.clear()
	database_selector.add_item("In-memory test database")
	database_selector.set_item_metadata(0, register_database)
	(_workspace.get("_register_graph_id") as LineEdit).text = "registered_smoke"
	_workspace.call("_register_current_graph")
	_check(register_database.get_graph(&"registered_smoke") == standalone,
		"Register Graph added a stable database entry")
	_workspace.call("_set_current_graph_as_master")
	_check(register_database.master_graph_id == &"registered_smoke" and standalone.kind == GraphScript.Kind.MASTER,
		"Set Master configured the run root and graph kind")

	_check(_workspace.get_node_or_null("Toolbar/NewGraphButton") != null,
		"New Graph is exposed as a production toolbar command")
	_check(_workspace.validate_before_play(), "pre-play validation accepts valid registered graphs")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(random_save_path))

	_workspace.shutdown()
	_workspace.queue_free()
	await process_frame
	_workspace = null
	_editor_plugin = null

	if _failures == 0:
		print("Flow graph editor smoke: PASS")
		quit()
	else:
		push_error("Flow graph editor smoke: %d failure(s)" % _failures)
		quit(1)


func _build_graph():
	var graph = GraphScript.new()
	graph.display_name = "Editor Smoke"

	var start = GameStartNodeScript.new()
	start.node_id = &"start"
	start.editor_position = Vector2(40.0, 60.0)
	graph.nodes.append(start)

	var finish = EndNodeScript.new()
	finish.node_id = &"finish"
	finish.editor_position = Vector2(360.0, 60.0)
	graph.nodes.append(finish)

	var connection = ConnectionScript.new()
	connection.connection_id = &"start_to_finish"
	connection.from_node_id = start.node_id
	connection.from_port_id = &"out"
	connection.to_node_id = finish.node_id
	connection.to_port_id = &"in"
	graph.connections.append(connection)
	return graph


func _build_subgraph():
	var graph = GraphScript.new()
	graph.kind = GraphScript.Kind.SUBGRAPH
	graph.display_name = "Editor Child"

	var entry = SubgraphEntryNodeScript.new()
	entry.node_id = &"child_entry"
	entry.editor_position = Vector2(40.0, 60.0)
	graph.nodes.append(entry)

	var exit = SubgraphExitNodeScript.new()
	exit.node_id = &"child_exit"
	exit.exit_id = &"completed"
	exit.editor_position = Vector2(360.0, 60.0)
	graph.nodes.append(exit)

	var connection = ConnectionScript.new()
	connection.connection_id = &"child_entry_to_exit"
	connection.from_node_id = entry.node_id
	connection.from_port_id = &"out"
	connection.to_node_id = exit.node_id
	connection.to_port_id = &"in"
	graph.connections.append(connection)
	return graph


func _build_random_graph():
	var graph = GraphScript.new()
	graph.display_name = "Random Editor Smoke"

	var start = GameStartNodeScript.new()
	start.node_id = &"random_start"
	start.editor_position = Vector2(20.0, 120.0)
	graph.nodes.append(start)

	var random = RandomNodeScript.new()
	random.node_id = &"random"
	random.editor_position = Vector2(280.0, 120.0)
	random.branches[0].port_id = &"option_a"
	random.branches[0].label = "Common"
	random.branches[0].weight = 1.0
	random.branches[1].port_id = &"option_b"
	random.branches[1].label = "Rare"
	random.branches[1].weight = 1.0
	graph.nodes.append(random)

	var common_end = EndNodeScript.new()
	common_end.node_id = &"common_end"
	common_end.editor_position = Vector2(620.0, 40.0)
	graph.nodes.append(common_end)

	var rare_end = EndNodeScript.new()
	rare_end.node_id = &"rare_end"
	rare_end.editor_position = Vector2(620.0, 220.0)
	graph.nodes.append(rare_end)

	_wire(graph, &"start_random", &"random_start", &"out", &"random", &"in")
	_wire(graph, &"random_common", &"random", &"option_a", &"common_end", &"in")
	_wire(graph, &"random_rare", &"random", &"option_b", &"rare_end", &"in")
	return graph


func _wire(
		graph,
		connection_id: StringName,
		from_node_id: StringName,
		from_port_id: StringName,
		to_node_id: StringName,
		to_port_id: StringName
) -> void:
	var connection = ConnectionScript.new()
	connection.connection_id = connection_id
	connection.from_node_id = from_node_id
	connection.from_port_id = from_port_id
	connection.to_node_id = to_node_id
	connection.to_port_id = to_port_id
	graph.connections.append(connection)


func _find_connection(graph, connection_id: StringName):
	if graph == null:
		return null
	for connection in graph.connections:
		if connection != null and connection.connection_id == connection_id:
			return connection
	return null


func _random_view_contains(node_id: StringName, needle: String) -> bool:
	var view := (_workspace.get("_node_to_view") as Dictionary).get(node_id) as GraphNode
	return _graph_view_contains(view, needle)


func _graph_view_contains(view: GraphNode, needle: String) -> bool:
	if view == null:
		return false
	for child: Node in view.get_children():
		if not child is HBoxContainer:
			continue
		for label_candidate: Node in child.get_children():
			if label_candidate is Label and (label_candidate as Label).text.contains(needle):
				return true
	return false


func _palette_contains(palette: ItemList, expected_text: String) -> bool:
	if palette == null:
		return false
	for index in palette.item_count:
		if palette.get_item_text(index) == expected_text:
			return true
	return false


func _issue_codes(issues: Array) -> Array[StringName]:
	var codes: Array[StringName] = []
	for issue in issues:
		if issue != null:
			codes.append(issue.code)
	return codes


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS: ", label)
		return
	_failures += 1
	push_error("  FAIL: %s" % label)
