@tool
extends VBoxContainer

## Main-screen editor for FlowGraph Resources.
##
## GraphEdit and GraphNode are views only. Every edit is applied to the runtime Resource model;
## GraphEdit node names and integer port indices are reconstructed from stable node and port IDs.

const EXECUTION_PORT_TYPE := 0
const EXECUTION_PORT_COLOR := Color(0.82, 0.88, 1.0)
const VIEW_POLL_SECONDS := 0.25

var _plugin: EditorPlugin
var _graph: Resource
var _active_database: Resource
var _breadcrumbs: Array[Resource] = []
var _dirty_graphs: Dictionary = {}
var _dirty_databases: Dictionary = {}

var _toolbar: HBoxContainer
var _breadcrumb_bar: HBoxContainer
var _graph_name: Label
var _back_button: Button
var _forward_button: Button
var _graph_selector: OptionButton
var _save_button: Button
var _register_button: Button
var _set_master_button: Button
var _copy_button: Button
var _paste_button: Button
var _status: Label
var _palette_search: LineEdit
var _palette: ItemList
var _palette_add: Button
var _graph_edit: GraphEdit
var _inspector_filter: LineEdit
var _inspector: EditorInspector
var _inspector_back: Button
var _inspector_context: Label
var _inspector_owner_node: Resource
var _inspector_stack: Array[Resource] = []
var _random_panel: VBoxContainer
var _random_rows: VBoxContainer
var _random_summary: Label
var _random_row_controls: Dictionary = {}
var _reference_row: HBoxContainer
var _reference_label: Label
var _reference_selector: OptionButton
var _validation: ItemList
var _open_dialog: EditorFileDialog
var _new_graph_dialog: ConfirmationDialog
var _new_graph_name: LineEdit
var _new_graph_kind: OptionButton
var _new_graph_path_dialog: EditorFileDialog
var _register_dialog: ConfirmationDialog
var _register_graph_id: LineEdit
var _register_database_selector: OptionButton

## UI node name -> graph-node Resource.
var _view_to_node: Dictionary = {}
## Stable graph node ID -> GraphNode.
var _node_to_view: Dictionary = {}
## Stable graph node ID -> {inputs: Array[StringName], outputs: Array[StringName]}.
var _port_maps: Dictionary = {}
var _palette_entries: Array = []
var _validation_entries: Array = []
var _move_start_positions: Dictionary = {}
var _selected_node_ids: Dictionary = {}
var _clipboard_nodes: Array[Resource] = []
var _clipboard_connections: Array[Resource] = []
var _clipboard_paste_serial: int = 0
var _navigation_history: Array[Dictionary] = []
var _navigation_index: int = -1

var _filesystem: EditorFileSystem
var _suppress_canvas_events: bool = false
var _suppress_graph_selector: bool = false
var _suppress_reference_selector: bool = false
var _suppress_random_controls: bool = false
var _reference_property: StringName = &""
var _pending_new_graph_name: String = ""
var _pending_new_graph_kind: int = 0
var _view_poll_elapsed: float = 0.0


func set_editor_plugin(plugin: EditorPlugin) -> void:
	_plugin = plugin


func _ready() -> void:
	_build_ui()
	_filesystem = EditorInterface.get_resource_filesystem()
	if _filesystem != null and not _filesystem.filesystem_changed.is_connected(_refresh_palette):
		_filesystem.filesystem_changed.connect(_refresh_palette)
	_refresh_palette()
	_update_enabled_state()


func shutdown() -> void:
	apply_pending_changes()
	if _filesystem != null and _filesystem.filesystem_changed.is_connected(_refresh_palette):
		_filesystem.filesystem_changed.disconnect(_refresh_palette)
	if is_instance_valid(_inspector):
		_clear_inspector()


func _process(delta: float) -> void:
	if not visible or _graph == null or _suppress_canvas_events:
		return
	_view_poll_elapsed += delta
	if _view_poll_elapsed < VIEW_POLL_SECONDS:
		return
	_view_poll_elapsed = 0.0
	_capture_view_state()


#region Public plugin surface

func can_edit_object(object: Object) -> bool:
	return object is Resource and _is_flow_graph(object)


func open_graph(object: Object) -> void:
	if not can_edit_object(object):
		return
	var graph := object as Resource
	_active_database = _find_database_containing_graph(graph)
	_navigate_to(graph, [graph])


func open_default_graph() -> void:
	if _graph != null or not is_node_ready():
		return
	for database: Resource in _find_databases():
		var master_id := StringName(str(_read_value(database, &"master_graph_id", "")))
		if master_id.is_empty() or not database.has_method(&"get_graph"):
			continue
		var master: Variant = database.call(&"get_graph", master_id)
		if master is Resource and _is_flow_graph(master):
			_active_database = database
			_navigate_to(master, [master])
			return


func apply_pending_changes() -> void:
	_capture_view_state()


func save_all_dirty_graphs() -> void:
	_capture_view_state()
	if _graph != null:
		_validate_graphs()
	var graphs: Array = _dirty_graphs.values().duplicate()
	for value: Variant in graphs:
		if value is Resource:
			_save_graph(value)
	var databases: Array = _dirty_databases.values().duplicate()
	for value: Variant in databases:
		if value is Resource:
			_save_database(value)


func unsaved_status() -> String:
	var count := _dirty_graphs.size() + _dirty_databases.size()
	if count == 0:
		return ""
	return "%d Game Flow resource%s have unsaved changes." % [count, "" if count == 1 else "s"]


## Called by EditorPlugin._build immediately before the project runs. Every registered graph is
## checked, even when the Game Flow workspace was never opened during this editor session.
func validate_before_play() -> bool:
	var all_issues: Array = []
	for database: Resource in _find_databases():
		if database.has_method(&"validate_graphs"):
			var raw: Variant = database.call(&"validate_graphs")
			if raw is Array:
				all_issues.append_array(raw)

	if all_issues.is_empty() and _graph != null and _active_database == null \
			and _graph.has_method(&"validate_detailed"):
		var standalone_raw: Variant = _graph.call(&"validate_detailed", &"", null)
		if standalone_raw is Array:
			all_issues.append_array(standalone_raw)

	_present_validation_issues(all_issues)
	var error_count := _validation_error_count(all_issues)
	if error_count > 0:
		_status.text = "Play blocked: %d Game Flow validation error%s." % [
			error_count, "" if error_count == 1 else "s"]
		push_error(_status.text)
		return false
	return true

#endregion


#region UI construction

func _build_ui() -> void:
	_toolbar = HBoxContainer.new()
	_toolbar.name = "Toolbar"
	add_child(_toolbar)

	var open_button := Button.new()
	open_button.text = "Open"
	open_button.tooltip_text = "Open a saved Game Flow graph"
	open_button.pressed.connect(_show_open_dialog)
	_toolbar.add_child(open_button)

	var new_button := Button.new()
	new_button.name = "NewGraphButton"
	new_button.text = "New"
	new_button.tooltip_text = "Create a new Game Flow graph"
	new_button.pressed.connect(_show_new_graph_dialog)
	_toolbar.add_child(new_button)

	_back_button = Button.new()
	_back_button.text = "<"
	_back_button.tooltip_text = "Back to the previous graph"
	_back_button.disabled = true
	_back_button.pressed.connect(_navigate_back)
	_toolbar.add_child(_back_button)

	_forward_button = Button.new()
	_forward_button.text = ">"
	_forward_button.tooltip_text = "Forward to the next graph"
	_forward_button.disabled = true
	_forward_button.pressed.connect(_navigate_forward)
	_toolbar.add_child(_forward_button)

	_graph_selector = OptionButton.new()
	_graph_selector.tooltip_text = "Open another graph from this project's Game Flow library"
	_graph_selector.custom_minimum_size.x = 220.0
	_graph_selector.item_selected.connect(_on_graph_selector_selected)
	_toolbar.add_child(_graph_selector)

	_register_button = Button.new()
	_register_button.name = "RegisterGraphButton"
	_register_button.text = "Add to Library"
	_register_button.tooltip_text = "Make this graph available to the game and other graphs"
	_register_button.pressed.connect(_show_register_graph_dialog)
	_toolbar.add_child(_register_button)

	_set_master_button = Button.new()
	_set_master_button.name = "SetMasterButton"
	_set_master_button.text = "Make Main Graph"
	_set_master_button.tooltip_text = "Use this as the graph that starts the game's high-level flow"
	_set_master_button.pressed.connect(_set_current_graph_as_master)
	_toolbar.add_child(_set_master_button)

	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.tooltip_text = "Save the current graph resource"
	_save_button.pressed.connect(_save_current_graph)
	_toolbar.add_child(_save_button)

	var validate_button := Button.new()
	validate_button.text = "Check Graph"
	validate_button.tooltip_text = "Check the graph for missing settings, broken wires, and unreachable steps"
	validate_button.pressed.connect(_validate_graphs)
	_toolbar.add_child(validate_button)

	var frame_all_button := Button.new()
	frame_all_button.text = "Frame All"
	frame_all_button.tooltip_text = "Center and zoom the canvas to show every node"
	frame_all_button.pressed.connect(_frame_all)
	_toolbar.add_child(frame_all_button)

	_copy_button = Button.new()
	_copy_button.text = "Copy"
	_copy_button.tooltip_text = "Copy selected steps and the wires between them (Ctrl/Cmd+C)"
	_copy_button.disabled = true
	_copy_button.pressed.connect(_copy_selected_nodes)
	_toolbar.add_child(_copy_button)

	_paste_button = Button.new()
	_paste_button.text = "Paste"
	_paste_button.tooltip_text = "Paste copied steps as a separate copy (Ctrl/Cmd+V)"
	_paste_button.disabled = true
	_paste_button.pressed.connect(_paste_nodes)
	_toolbar.add_child(_paste_button)

	var separator := VSeparator.new()
	_toolbar.add_child(separator)

	_breadcrumb_bar = HBoxContainer.new()
	_breadcrumb_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.add_child(_breadcrumb_bar)

	_graph_name = Label.new()
	_graph_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_graph_name.custom_minimum_size.x = 180.0
	_toolbar.add_child(_graph_name)

	var vertical_split := VSplitContainer.new()
	vertical_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vertical_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vertical_split.split_offset = -170
	add_child(vertical_split)

	var work_area := HSplitContainer.new()
	work_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	work_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vertical_split.add_child(work_area)

	var palette_panel := VBoxContainer.new()
	palette_panel.custom_minimum_size.x = 220.0
	work_area.add_child(palette_panel)

	var palette_title := Label.new()
	palette_title.text = "Add a Step"
	palette_panel.add_child(palette_title)

	_palette_search = LineEdit.new()
	_palette_search.placeholder_text = "Search game-flow steps..."
	_palette_search.clear_button_enabled = true
	_palette_search.text_changed.connect(_on_palette_search_changed)
	palette_panel.add_child(_palette_search)

	_palette = ItemList.new()
	_palette.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_palette.allow_reselect = true
	_palette.item_activated.connect(_on_palette_item_activated)
	_palette.item_selected.connect(_on_palette_item_selected)
	palette_panel.add_child(_palette)

	_palette_add = Button.new()
	_palette_add.text = "Add Step"
	_palette_add.tooltip_text = "Add the selected step to the open graph"
	_palette_add.disabled = true
	_palette_add.pressed.connect(_add_selected_palette_node)
	palette_panel.add_child(_palette_add)

	_graph_edit = GraphEdit.new()
	_graph_edit.name = "GraphCanvas"
	_graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph_edit.custom_minimum_size.x = 480.0
	_graph_edit.right_disconnects = true
	_graph_edit.show_arrange_button = true
	_graph_edit.connection_request.connect(_on_connection_requested)
	_graph_edit.disconnection_request.connect(_on_disconnection_requested)
	_graph_edit.delete_nodes_request.connect(_on_delete_nodes_requested)
	_graph_edit.begin_node_move.connect(_on_begin_node_move)
	_graph_edit.end_node_move.connect(_on_end_node_move)
	_graph_edit.node_selected.connect(_on_view_selected)
	_graph_edit.node_deselected.connect(_on_view_deselected)
	_graph_edit.popup_request.connect(_on_graph_popup_requested)
	_graph_edit.scroll_offset_changed.connect(_on_scroll_offset_changed)
	work_area.add_child(_graph_edit)

	var inspector_panel := VBoxContainer.new()
	inspector_panel.custom_minimum_size.x = 300.0
	work_area.add_child(inspector_panel)

	var inspector_title := Label.new()
	inspector_title.text = "Step Settings"
	inspector_panel.add_child(inspector_title)

	var inspector_navigation := HBoxContainer.new()
	_inspector_back = Button.new()
	_inspector_back.text = "<"
	_inspector_back.tooltip_text = "Return to the main settings for this step"
	_inspector_back.disabled = true
	_inspector_back.pressed.connect(_on_inspector_back)
	inspector_navigation.add_child(_inspector_back)
	_inspector_context = Label.new()
	_inspector_context.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_context.text = "No node selected"
	inspector_navigation.add_child(_inspector_context)
	inspector_panel.add_child(inspector_navigation)

	_inspector_filter = LineEdit.new()
	_inspector_filter.placeholder_text = "Find a setting..."
	_inspector_filter.clear_button_enabled = true
	inspector_panel.add_child(_inspector_filter)

	var random_scroll := ScrollContainer.new()
	random_scroll.name = "RandomBranchEditor"
	random_scroll.custom_minimum_size.y = 170.0
	random_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	random_scroll.visible = false
	_random_panel = VBoxContainer.new()
	_random_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	random_scroll.add_child(_random_panel)
	var random_header := HBoxContainer.new()
	var random_title := Label.new()
	random_title.text = "Random Outcomes"
	random_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	random_header.add_child(random_title)
	var add_random_branch := Button.new()
	add_random_branch.name = "AddRandomBranchButton"
	add_random_branch.text = "+ Outcome"
	add_random_branch.tooltip_text = "Add another possible random outcome"
	add_random_branch.pressed.connect(_add_random_branch)
	random_header.add_child(add_random_branch)
	_random_panel.add_child(random_header)
	_random_summary = Label.new()
	_random_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_random_panel.add_child(_random_summary)
	_random_rows = VBoxContainer.new()
	_random_panel.add_child(_random_rows)
	inspector_panel.add_child(random_scroll)

	# The default editor inspector owns native EditorUndoRedoManager property actions. Our
	# property_edited callback only marks the owning graph dirty and refreshes dynamic ports/titles.
	_inspector = EditorInspector.create_default_inspector(_inspector_filter)
	_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_inspector.property_edited.connect(_on_inspector_property_edited)
	_inspector.resource_selected.connect(_on_inspector_resource_selected)
	inspector_panel.add_child(_inspector)

	_reference_row = HBoxContainer.new()
	_reference_row.name = "DatabaseReferencePicker"
	_reference_row.visible = false
	_reference_label = Label.new()
	_reference_label.text = "Choose from Library"
	_reference_row.add_child(_reference_label)
	_reference_selector = OptionButton.new()
	_reference_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reference_selector.tooltip_text = "Choose an item already set up in this project's Game Flow library"
	_reference_selector.item_selected.connect(_on_reference_selected)
	_reference_row.add_child(_reference_selector)
	inspector_panel.add_child(_reference_row)

	var validation_panel := VBoxContainer.new()
	validation_panel.custom_minimum_size.y = 110.0
	vertical_split.add_child(validation_panel)

	var validation_header := HBoxContainer.new()
	validation_panel.add_child(validation_header)
	var validation_title := Label.new()
	validation_title.text = "Graph Check"
	validation_header.add_child(validation_title)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	validation_header.add_child(_status)

	_validation = ItemList.new()
	_validation.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_validation.item_activated.connect(_on_validation_item_activated)
	validation_panel.add_child(_validation)

	_open_dialog = EditorFileDialog.new()
	_open_dialog.title = "Open Flow Graph"
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_RESOURCES
	_open_dialog.add_filter("*.tres, *.res ; Flow Graph Resources")
	_open_dialog.file_selected.connect(_on_graph_file_selected)
	add_child(_open_dialog)

	_new_graph_dialog = ConfirmationDialog.new()
	_new_graph_dialog.title = "New Flow Graph"
	_new_graph_dialog.ok_button_text = "Choose Save Location"
	var new_fields := VBoxContainer.new()
	var new_name_label := Label.new()
	new_name_label.text = "Display name"
	new_fields.add_child(new_name_label)
	_new_graph_name = LineEdit.new()
	_new_graph_name.placeholder_text = "New Game Flow"
	new_fields.add_child(_new_graph_name)
	var new_kind_label := Label.new()
	new_kind_label.text = "Graph kind"
	new_fields.add_child(new_kind_label)
	_new_graph_kind = OptionButton.new()
	_new_graph_kind.add_item("Main Game Graph", 0)
	_new_graph_kind.add_item("Reusable Subgraph", 1)
	new_fields.add_child(_new_graph_kind)
	_new_graph_dialog.add_child(new_fields)
	_new_graph_dialog.confirmed.connect(_on_new_graph_settings_confirmed)
	add_child(_new_graph_dialog)

	_new_graph_path_dialog = EditorFileDialog.new()
	_new_graph_path_dialog.title = "Save New Flow Graph"
	_new_graph_path_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_new_graph_path_dialog.access = FileDialog.ACCESS_RESOURCES
	_new_graph_path_dialog.add_filter("*.tres ; Flow Graph Resource")
	_new_graph_path_dialog.file_selected.connect(_create_new_graph_at_path)
	add_child(_new_graph_path_dialog)

	_register_dialog = ConfirmationDialog.new()
	_register_dialog.title = "Add Graph to Game Flow"
	_register_dialog.ok_button_text = "Add to Library"
	var register_fields := VBoxContainer.new()
	var graph_id_label := Label.new()
	graph_id_label.text = "Graph Name for Connections"
	graph_id_label.tooltip_text = "A permanent short name used by subgraph steps and saved games"
	register_fields.add_child(graph_id_label)
	_register_graph_id = LineEdit.new()
	_register_graph_id.placeholder_text = "intro_sequence"
	register_fields.add_child(_register_graph_id)
	var database_label := Label.new()
	database_label.text = "Game Flow Library"
	register_fields.add_child(database_label)
	_register_database_selector = OptionButton.new()
	register_fields.add_child(_register_database_selector)
	_register_dialog.add_child(register_fields)
	_register_dialog.confirmed.connect(_register_current_graph)
	add_child(_register_dialog)


func _update_enabled_state() -> void:
	var has_graph := _graph != null
	_save_button.disabled = not has_graph
	var containing_database := _known_database_containing_graph(_graph) if has_graph else null
	_register_button.disabled = not has_graph or containing_database != null or _find_databases().is_empty()
	_set_master_button.disabled = not has_graph or containing_database == null
	_palette_add.disabled = not has_graph or _palette.get_selected_items().is_empty()
	_graph_name.text = _graph_display_name(_graph) if has_graph else "No graph open"
	if not has_graph:
		_clear_inspector()
	_update_navigation_buttons()
	_update_copy_paste_buttons()

#endregion


#region Graph loading and rendering

func _set_graph(graph: Resource) -> void:
	if graph == null or not _is_flow_graph(graph):
		return
	_capture_view_state()
	_graph = graph
	_rebuild_breadcrumbs()
	_rebuild_canvas()
	_refresh_graph_selector()
	_update_enabled_state()
	_validate_graphs()


func _rebuild_canvas() -> void:
	_suppress_canvas_events = true
	_graph_edit.clear_connections()
	for raw_view: Variant in _view_to_node.keys():
		var old_view := _graph_edit.get_node_or_null(NodePath(String(raw_view)))
		if old_view != null:
			_graph_edit.remove_child(old_view)
			old_view.queue_free()
	_view_to_node.clear()
	_node_to_view.clear()
	_port_maps.clear()
	_selected_node_ids.clear()
	_clear_inspector()

	if _graph == null:
		_suppress_canvas_events = false
		return

	var nodes: Array = _array_property(_graph, &"nodes")
	for index in nodes.size():
		var node: Variant = nodes[index]
		if not node is Resource:
			continue
		var view := _build_node_view(node, index)
		_graph_edit.add_child(view)

	for connection: Variant in _array_property(_graph, &"connections"):
		_draw_connection(connection)

	var stored_offset: Variant = _read_value(_graph, &"editor_scroll_offset", Vector2.ZERO)
	_graph_edit.scroll_offset = stored_offset if stored_offset is Vector2 else Vector2.ZERO
	var stored_zoom := float(_read_value(_graph, &"editor_zoom", 1.0))
	_graph_edit.zoom = clampf(stored_zoom if stored_zoom > 0.0 else 1.0, _graph_edit.zoom_min, _graph_edit.zoom_max)
	_suppress_canvas_events = false
	_update_copy_paste_buttons()


func _build_node_view(node: Resource, index: int) -> GraphNode:
	var node_id := _node_id(node)
	var view := GraphNode.new()
	view.name = "FlowNode_%d" % index
	view.title = _node_title(node)
	view.tooltip_text = _node_tooltip(node)
	var stored_position: Variant = _read_value(node, &"editor_position", Vector2.ZERO)
	view.position_offset = stored_position if stored_position is Vector2 else Vector2.ZERO

	var inputs := _string_name_array(_call_if_present(node, &"input_ports", []))
	var outputs := _string_name_array(_call_if_present(node, &"output_ports", []))
	_port_maps[node_id] = {"inputs": inputs, "outputs": outputs}

	var slot_count := maxi(inputs.size(), outputs.size())
	for slot_index in slot_count:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(190.0, 24.0)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var input_label := Label.new()
		input_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		input_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		input_label.text = _port_label(node, inputs[slot_index]) if slot_index < inputs.size() else ""
		row.add_child(input_label)

		var output_label := Label.new()
		output_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		output_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		output_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		output_label.text = _port_label(node, outputs[slot_index]) if slot_index < outputs.size() else ""
		row.add_child(output_label)

		view.add_child(row)
		view.set_slot(
			slot_index,
			slot_index < inputs.size(), EXECUTION_PORT_TYPE, EXECUTION_PORT_COLOR,
			slot_index < outputs.size(), EXECUTION_PORT_TYPE, EXECUTION_PORT_COLOR)

	var subgraph_id := StringName(str(_read_value(node, &"subgraph_id", "")))
	if not subgraph_id.is_empty():
		view.tooltip_text = "%s\nDouble-click to open this reusable subgraph." % view.tooltip_text
		view.gui_input.connect(_on_subgraph_view_input.bind(subgraph_id))
		var open_subgraph := Button.new()
		open_subgraph.text = "Open This Subgraph"
		open_subgraph.tooltip_text = "Open the reusable flow controlled by this step"
		open_subgraph.pressed.connect(_open_subgraph.bind(subgraph_id))
		view.add_child(open_subgraph)

	_view_to_node[view.name] = node
	_node_to_view[node_id] = view
	return view


func _on_subgraph_view_input(event: InputEvent, subgraph_id: StringName) -> void:
	if not event is InputEventMouseButton:
		return
	var mouse := event as InputEventMouseButton
	if mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT and mouse.double_click:
		_open_subgraph(subgraph_id)
		get_viewport().set_input_as_handled()


func _draw_connection(connection: Variant) -> void:
	if not connection is Object:
		return
	var from_id := StringName(str(_read_value(connection, &"from_node_id", "")))
	var to_id := StringName(str(_read_value(connection, &"to_node_id", "")))
	var from_port := StringName(str(_read_value(connection, &"from_port_id", "")))
	var to_port := StringName(str(_read_value(connection, &"to_port_id", "")))
	var from_view := _node_to_view.get(from_id) as GraphNode
	var to_view := _node_to_view.get(to_id) as GraphNode
	if from_view == null or to_view == null:
		return
	var from_index := _port_index(from_id, from_port, true)
	var to_index := _port_index(to_id, to_port, false)
	if from_index < 0 or to_index < 0:
		return
	_graph_edit.connect_node(from_view.name, from_index, to_view.name, to_index)


func _reload_after_mutation(changed_graph: Resource) -> void:
	if changed_graph != null and changed_graph.has_method(&"invalidate_index"):
		changed_graph.call(&"invalidate_index")
	_mark_dirty(changed_graph)
	if changed_graph == _graph:
		_rebuild_canvas()


func _sync_positions_after_mutation(changed_graph: Resource) -> void:
	_mark_dirty(changed_graph)
	if changed_graph != _graph:
		return
	for node: Variant in _array_property(_graph, &"nodes"):
		if not node is Resource:
			continue
		var view := _node_to_view.get(_node_id(node)) as GraphNode
		var position: Variant = _read_value(node, &"editor_position", Vector2.ZERO)
		if view != null and position is Vector2:
			view.position_offset = position

#endregion


#region Palette and node creation

func _refresh_palette() -> void:
	_palette_entries = _catalog_descriptors()
	_palette_entries.sort_custom(_descriptor_less_than)
	_apply_palette_filter(_palette_search.text if is_instance_valid(_palette_search) else "")


func _apply_palette_filter(filter_text: String) -> void:
	if not is_instance_valid(_palette):
		return
	_palette.clear()
	var needle := filter_text.strip_edges().to_lower()
	for descriptor: Variant in _palette_entries:
		var type_id := StringName(str(_read_value(descriptor, &"type_id", "")))
		var display_name := str(_read_value(descriptor, &"display_name", type_id))
		var category := str(_read_value(descriptor, &"category", "Custom"))
		var description := str(_read_value(descriptor, &"description", ""))
		var haystack := "%s %s %s %s" % [type_id, display_name, category, description]
		if not needle.is_empty() and not haystack.to_lower().contains(needle):
			continue
		var item_index := _palette.add_item("%s  ›  %s" % [category, display_name])
		_palette.set_item_metadata(item_index, descriptor)
		_palette.set_item_tooltip(item_index,
			description if not description.is_empty() else "Custom game-flow step")
	_palette_add.disabled = _graph == null or _palette.get_selected_items().is_empty()
	if _palette.item_count == 0 and _palette_entries.is_empty():
		_status.text = "No game-flow steps are available."


func _catalog_descriptors() -> Array:
	var catalog_script := _global_class_script(&"FlowNodeCatalog")
	if catalog_script != null and catalog_script.has_method(&"descriptors"):
		var raw: Variant = catalog_script.call(&"descriptors")
		if raw is Array:
			return raw.duplicate()

	# Extension fallback: discover globally named FlowGraphNode subclasses. This also keeps custom
	# nodes authorable if a project intentionally omits the optional catalog helper.
	var discovered: Array = []
	var classes: Array[Dictionary] = ProjectSettings.get_global_class_list()
	for entry: Dictionary in classes:
		var class_name_text := StringName(str(entry.get("class", "")))
		if class_name_text == &"FlowGraphNode" or not _inherits_global_class(class_name_text, &"FlowGraphNode", classes):
			continue
		var path := str(entry.get("path", ""))
		var script: Variant = load(path) if not path.is_empty() else null
		if script == null or not script.can_instantiate():
			continue
		var node: Variant = script.new()
		if not node is Resource:
			continue
		discovered.append({
			"type_id": _call_if_present(node, &"type_id", class_name_text),
			"display_name": _call_if_present(node, &"display_title", class_name_text),
			"category": "Custom",
			"description": "",
			"node_script": script,
		})
	return discovered


func _create_node_from_descriptor(descriptor: Variant) -> Resource:
	if descriptor is Object and descriptor.has_method(&"create_node"):
		var created: Variant = descriptor.call(&"create_node")
		if created is Resource:
			return created
	var catalog_script := _global_class_script(&"FlowNodeCatalog")
	var type_id := StringName(str(_read_value(descriptor, &"type_id", "")))
	if catalog_script != null and catalog_script.has_method(&"create_node"):
		var from_catalog: Variant = catalog_script.call(&"create_node", type_id)
		if from_catalog is Resource:
			return from_catalog
	var node_script: Variant = _read_value(descriptor, &"node_script", null)
	if node_script != null and node_script.has_method(&"new"):
		var from_script: Variant = node_script.call(&"new")
		if from_script is Resource:
			return from_script
	return null


func _add_palette_node(descriptor: Variant) -> void:
	if _graph == null:
		return
	var node := _create_node_from_descriptor(descriptor)
	if node == null:
		_status.text = "That game-flow step could not be created."
		return
	node.set(&"node_id", _new_stable_id(&"node"))
	var center := _graph_edit.scroll_offset + (_graph_edit.size / maxf(_graph_edit.zoom, 0.01)) * 0.5
	if _graph_edit.snapping_enabled and _graph_edit.snapping_distance > 0:
		var snap := float(_graph_edit.snapping_distance)
		center = center.snapped(Vector2(snap, snap))
	node.set(&"editor_position", center)

	var before := _array_property(_graph, &"nodes")
	var after := before.duplicate()
	after.append(node)
	_commit_graph_array_change("Add Flow Node", &"nodes", before, after)


func _on_palette_search_changed(text: String) -> void:
	_apply_palette_filter(text)


func _on_palette_item_selected(_index: int) -> void:
	_palette_add.disabled = _graph == null


func _on_palette_item_activated(index: int) -> void:
	_add_palette_node(_palette.get_item_metadata(index))


func _add_selected_palette_node() -> void:
	var selected := _palette.get_selected_items()
	if selected.is_empty():
		return
	_add_palette_node(_palette.get_item_metadata(selected[0]))


func _descriptor_less_than(a: Variant, b: Variant) -> bool:
	var a_key := "%s/%s" % [_read_value(a, &"category", ""), _read_value(a, &"display_name", "")]
	var b_key := "%s/%s" % [_read_value(b, &"category", ""), _read_value(b, &"display_name", "")]
	return a_key.naturalnocasecmp_to(b_key) < 0

#endregion


#region Graph mutations and undo

func _copy_selected_nodes() -> void:
	_clipboard_nodes.clear()
	_clipboard_connections.clear()
	_clipboard_paste_serial = 0
	if _graph == null or _selected_node_ids.is_empty():
		_status.text = "Select one or more steps to copy."
		_update_copy_paste_buttons()
		return

	var copied_ids: Dictionary = {}
	for raw_node: Variant in _array_property(_graph, &"nodes"):
		var node := raw_node as Resource
		if node == null or not _selected_node_ids.has(_node_id(node)):
			continue
		var template := node.duplicate(true) as Resource
		if template == null:
			continue
		_clipboard_nodes.append(template)
		copied_ids[_node_id(node)] = true

	for raw_connection: Variant in _array_property(_graph, &"connections"):
		var connection := raw_connection as Resource
		if connection == null:
			continue
		var from_id := StringName(str(_read_value(connection, &"from_node_id", "")))
		var to_id := StringName(str(_read_value(connection, &"to_node_id", "")))
		if not copied_ids.has(from_id) or not copied_ids.has(to_id):
			continue
		var template := connection.duplicate(true) as Resource
		if template != null:
			_clipboard_connections.append(template)

	_status.text = "Copied %d step%s and %d wire%s." % [
		_clipboard_nodes.size(), "" if _clipboard_nodes.size() == 1 else "s",
		_clipboard_connections.size(), "" if _clipboard_connections.size() == 1 else "s"]
	_update_copy_paste_buttons()


func _paste_nodes() -> void:
	if _graph == null or _clipboard_nodes.is_empty():
		return
	_clipboard_paste_serial += 1
	var paste_offset := Vector2(48.0, 48.0) * float(_clipboard_paste_serial)
	var id_map: Dictionary = {}
	var reserved_ids: Dictionary = {}
	var pasted_ids: Array[StringName] = []
	var before_nodes := _array_property(_graph, &"nodes")
	var after_nodes := before_nodes.duplicate()
	for template: Resource in _clipboard_nodes:
		var node := template.duplicate(true) as Resource
		if node == null:
			continue
		var old_id := _node_id(node)
		var new_id := _new_stable_id(&"node", reserved_ids)
		reserved_ids[new_id] = true
		id_map[old_id] = new_id
		pasted_ids.append(new_id)
		node.set(&"node_id", new_id)
		var old_position: Variant = _read_value(node, &"editor_position", Vector2.ZERO)
		node.set(&"editor_position", (old_position if old_position is Vector2 else Vector2.ZERO) + paste_offset)
		after_nodes.append(node)

	var before_connections := _array_property(_graph, &"connections")
	var after_connections := before_connections.duplicate()
	for template: Resource in _clipboard_connections:
		var connection := template.duplicate(true) as Resource
		if connection == null:
			continue
		var old_from := StringName(str(_read_value(connection, &"from_node_id", "")))
		var old_to := StringName(str(_read_value(connection, &"to_node_id", "")))
		if not id_map.has(old_from) or not id_map.has(old_to):
			continue
		var connection_id := _new_stable_id(&"connection", reserved_ids)
		reserved_ids[connection_id] = true
		connection.set(&"connection_id", connection_id)
		connection.set(&"from_node_id", id_map[old_from])
		connection.set(&"to_node_id", id_map[old_to])
		after_connections.append(connection)

	if pasted_ids.is_empty():
		_status.text = "The copied steps could not be pasted."
		return
	var undo := _undo_redo()
	if undo == null:
		_graph.set(&"nodes", after_nodes)
		_graph.set(&"connections", after_connections)
		_reload_after_paste(_graph, pasted_ids)
		return
	undo.create_action("Paste Flow Nodes", UndoRedo.MERGE_DISABLE, _graph)
	undo.add_do_property(_graph, &"nodes", after_nodes)
	undo.add_do_property(_graph, &"connections", after_connections)
	undo.add_do_method(_graph, &"emit_changed")
	undo.add_do_method(self, &"_reload_after_paste", _graph, pasted_ids)
	undo.add_undo_property(_graph, &"nodes", before_nodes)
	undo.add_undo_property(_graph, &"connections", before_connections)
	undo.add_undo_method(_graph, &"emit_changed")
	undo.add_undo_method(self, &"_reload_after_mutation", _graph)
	undo.commit_action()


func _reload_after_paste(changed_graph: Resource, pasted_ids: Array[StringName]) -> void:
	_reload_after_mutation(changed_graph)
	if changed_graph != _graph:
		return
	if not pasted_ids.is_empty():
		var first := pasted_ids[0]
		var first_view := _node_to_view.get(first) as GraphNode
		if first_view != null:
			_graph_edit.set_selected(first_view)
			_selected_node_ids[first] = true
			_inspect_node(_view_to_node.get(first_view.name) as Resource)
	_status.text = "Pasted %d separate step%s." % [
		pasted_ids.size(), "" if pasted_ids.size() == 1 else "s"]
	_update_copy_paste_buttons()


func _on_connection_requested(from_view: StringName, from_port: int, to_view: StringName, to_port: int) -> void:
	if _graph == null:
		return
	var from_node := _view_to_node.get(from_view) as Resource
	var to_node := _view_to_node.get(to_view) as Resource
	if from_node == null or to_node == null:
		return
	var from_id := _node_id(from_node)
	var to_id := _node_id(to_node)
	var from_port_id := _port_id_at(from_id, from_port, true)
	var to_port_id := _port_id_at(to_id, to_port, false)
	if from_port_id.is_empty() or to_port_id.is_empty():
		return

	var before := _array_property(_graph, &"connections")
	for existing: Variant in before:
		if _connection_matches(existing, from_id, from_port_id, to_id, to_port_id):
			return
	var connection := _new_global_class_instance(&"FlowGraphConnection") as Resource
	if connection == null:
		_status.text = "A new wire could not be created."
		return
	connection.set(&"connection_id", _new_stable_id(&"connection"))
	connection.set(&"from_node_id", from_id)
	connection.set(&"from_port_id", from_port_id)
	connection.set(&"to_node_id", to_id)
	connection.set(&"to_port_id", to_port_id)
	var next_order := 0
	for existing: Variant in before:
		if StringName(str(_read_value(existing, &"from_node_id", ""))) == from_id \
				and StringName(str(_read_value(existing, &"from_port_id", ""))) == from_port_id:
			next_order = maxi(next_order, int(_read_value(existing, &"order", 0)) + 1)
	connection.set(&"order", next_order)
	var after := before.duplicate()
	after.append(connection)
	_commit_graph_array_change("Connect Flow Nodes", &"connections", before, after)


func _on_disconnection_requested(from_view: StringName, from_port: int, to_view: StringName, to_port: int) -> void:
	if _graph == null:
		return
	var from_node := _view_to_node.get(from_view) as Resource
	var to_node := _view_to_node.get(to_view) as Resource
	if from_node == null or to_node == null:
		return
	var from_id := _node_id(from_node)
	var to_id := _node_id(to_node)
	var from_port_id := _port_id_at(from_id, from_port, true)
	var to_port_id := _port_id_at(to_id, to_port, false)
	var before := _array_property(_graph, &"connections")
	var after := before.duplicate()
	for index in range(after.size() - 1, -1, -1):
		if _connection_matches(after[index], from_id, from_port_id, to_id, to_port_id):
			after.remove_at(index)
	if after.size() != before.size():
		_commit_graph_array_change("Disconnect Flow Nodes", &"connections", before, after)


func _on_delete_nodes_requested(view_names: Array[StringName]) -> void:
	if _graph == null or view_names.is_empty():
		return
	var removed_ids: Dictionary = {}
	for view_name: StringName in view_names:
		var node := _view_to_node.get(view_name) as Resource
		if node != null:
			removed_ids[_node_id(node)] = true
	if removed_ids.is_empty():
		return

	var before_nodes := _array_property(_graph, &"nodes")
	var after_nodes := before_nodes.duplicate()
	for index in range(after_nodes.size() - 1, -1, -1):
		var candidate := after_nodes[index] as Resource
		if candidate != null and removed_ids.has(_node_id(candidate)):
			after_nodes.remove_at(index)

	var before_connections := _array_property(_graph, &"connections")
	var after_connections := before_connections.duplicate()
	for index in range(after_connections.size() - 1, -1, -1):
		var connection: Variant = after_connections[index]
		var from_id := StringName(str(_read_value(connection, &"from_node_id", "")))
		var to_id := StringName(str(_read_value(connection, &"to_node_id", "")))
		if removed_ids.has(from_id) or removed_ids.has(to_id):
			after_connections.remove_at(index)

	var undo := _undo_redo()
	if undo == null:
		_graph.set(&"nodes", after_nodes)
		_graph.set(&"connections", after_connections)
		_reload_after_mutation(_graph)
		return
	undo.create_action("Delete Flow Nodes", UndoRedo.MERGE_DISABLE, _graph)
	undo.add_do_property(_graph, &"nodes", after_nodes)
	undo.add_do_property(_graph, &"connections", after_connections)
	undo.add_do_method(_graph, &"emit_changed")
	undo.add_do_method(self, &"_reload_after_mutation", _graph)
	undo.add_undo_property(_graph, &"nodes", before_nodes)
	undo.add_undo_property(_graph, &"connections", before_connections)
	undo.add_undo_method(_graph, &"emit_changed")
	undo.add_undo_method(self, &"_reload_after_mutation", _graph)
	undo.commit_action()


func _on_begin_node_move() -> void:
	_move_start_positions.clear()
	if _graph == null:
		return
	for node: Variant in _array_property(_graph, &"nodes"):
		if node is Resource:
			_move_start_positions[_node_id(node)] = _read_value(node, &"editor_position", Vector2.ZERO)


func _on_end_node_move() -> void:
	if _graph == null or _move_start_positions.is_empty():
		return
	var changes: Array[Dictionary] = []
	for node: Variant in _array_property(_graph, &"nodes"):
		if not node is Resource:
			continue
		var node_id := _node_id(node)
		var view := _node_to_view.get(node_id) as GraphNode
		if view == null or not _move_start_positions.has(node_id):
			continue
		var before: Variant = _move_start_positions[node_id]
		var after := view.position_offset
		if before is Vector2 and not before.is_equal_approx(after):
			changes.append({"node": node, "before": before, "after": after})
	_move_start_positions.clear()
	if changes.is_empty():
		return

	var undo := _undo_redo()
	if undo == null:
		for change: Dictionary in changes:
			(change["node"] as Resource).set(&"editor_position", change["after"])
		_sync_positions_after_mutation(_graph)
		return
	undo.create_action("Move Flow Nodes", UndoRedo.MERGE_DISABLE, _graph)
	for change: Dictionary in changes:
		undo.add_do_property(change["node"], &"editor_position", change["after"])
	undo.add_do_method(_graph, &"emit_changed")
	undo.add_do_method(self, &"_sync_positions_after_mutation", _graph)
	for change: Dictionary in changes:
		undo.add_undo_property(change["node"], &"editor_position", change["before"])
	undo.add_undo_method(_graph, &"emit_changed")
	undo.add_undo_method(self, &"_sync_positions_after_mutation", _graph)
	undo.commit_action()


func _commit_graph_array_change(label: String, property: StringName, before: Array, after: Array) -> void:
	var undo := _undo_redo()
	if undo == null:
		_graph.set(property, after)
		_graph.emit_changed()
		_reload_after_mutation(_graph)
		return
	undo.create_action(label, UndoRedo.MERGE_DISABLE, _graph)
	undo.add_do_property(_graph, property, after)
	undo.add_do_method(_graph, &"emit_changed")
	undo.add_do_method(self, &"_reload_after_mutation", _graph)
	undo.add_undo_property(_graph, property, before)
	undo.add_undo_method(_graph, &"emit_changed")
	undo.add_undo_method(self, &"_reload_after_mutation", _graph)
	undo.commit_action()


func _undo_redo() -> EditorUndoRedoManager:
	return _plugin.get_undo_redo() if is_instance_valid(_plugin) else null

#endregion


#region Selection, inspector, and view state

func _on_view_selected(view: Node) -> void:
	var node := _view_to_node.get(view.name) as Resource
	if node != null:
		_selected_node_ids[_node_id(node)] = true
	_inspect_node(node)
	_update_copy_paste_buttons()


func _on_view_deselected(view: Node) -> void:
	var node := _view_to_node.get(view.name) as Resource
	if node != null:
		_selected_node_ids.erase(_node_id(node))
	var edited := _inspector.get_edited_object()
	if edited == node or _inspector_owner_node == node:
		_clear_inspector()
	_update_copy_paste_buttons()


func _inspect_node(node: Resource) -> void:
	if node == null:
		_clear_inspector()
		return
	_inspector_owner_node = node
	_inspector_stack.clear()
	_inspector_stack.append(node)
	_show_inspector_object(node)


func _inspect_subresource(resource: Resource) -> void:
	if resource == null or _inspector_owner_node == null:
		return
	if _inspector_stack.is_empty():
		_inspector_stack.append(_inspector_owner_node)
	if _inspector_stack.back() != resource:
		_inspector_stack.append(resource)
	_show_inspector_object(resource)


func _show_inspector_object(resource: Resource) -> void:
	_inspector.edit(resource)
	_inspector_back.disabled = _inspector_stack.size() <= 1
	_inspector_context.text = _inspector_object_label(resource)
	_refresh_reference_picker(_inspector_owner_node)
	_refresh_random_panel(_inspector_owner_node)


func _clear_inspector() -> void:
	_inspector_owner_node = null
	_inspector_stack.clear()
	_inspector.edit(null)
	if is_instance_valid(_inspector_back):
		_inspector_back.disabled = true
	if is_instance_valid(_inspector_context):
		_inspector_context.text = "No node selected"
	_refresh_reference_picker(null)
	_refresh_random_panel(null)


func _on_inspector_resource_selected(resource: Resource, _path: String) -> void:
	_inspect_subresource(resource)


func _on_inspector_back() -> void:
	if _inspector_stack.size() <= 1:
		return
	_inspector_stack.pop_back()
	_show_inspector_object(_inspector_stack.back())


func _inspector_object_label(resource: Resource) -> String:
	if resource == null:
		return "No node selected"
	if resource == _inspector_owner_node:
		return _node_title(resource)
	var script: Variant = resource.get_script()
	if script != null and script.has_method(&"get_global_name"):
		var global_name := str(script.call(&"get_global_name"))
		if not global_name.is_empty():
			return "%s > %s" % [_node_title(_inspector_owner_node), global_name]
	return "%s > %s" % [_node_title(_inspector_owner_node), resource.get_class()]


func _on_inspector_property_edited(_property: String) -> void:
	var edited := _inspector.get_edited_object()
	var owner := _inspector_owner_node
	if edited is Resource and owner != null and _graph != null:
		if _graph.has_method(&"invalidate_index"):
			_graph.call(&"invalidate_index")
		_mark_dirty(_graph)
		if _is_random_node(owner) and edited != owner:
			_after_random_value_mutation(owner)
			return
		# Port lists and titles can depend on authored properties (for example subgraph exit IDs).
		_reload_preserving_selection.call_deferred(_node_id(owner))


func _refresh_random_panel(node: Resource) -> void:
	if not is_instance_valid(_random_panel):
		return
	var scroll := _random_panel.get_parent() as ScrollContainer
	var is_random := _is_random_node(node)
	if scroll != null:
		scroll.visible = is_random
	for child: Node in _random_rows.get_children():
		_random_rows.remove_child(child)
		child.queue_free()
	_random_row_controls.clear()
	if not is_random:
		return

	var branches := _array_property(node, &"branches")
	_random_summary.text = "%d possible outcome%s. Percentages use connected outcomes only; a larger Chance Weight is more likely." % [
		branches.size(), "" if branches.size() == 1 else "s"]
	for index in branches.size():
		var branch := branches[index] as Resource
		var row := VBoxContainer.new()
		row.name = "RandomBranch_%d" % index
		var identity_row := HBoxContainer.new()
		var index_label := Label.new()
		index_label.text = "#%d" % (index + 1)
		index_label.custom_minimum_size.x = 28.0
		identity_row.add_child(index_label)
		if branch == null:
			var empty_label := Label.new()
			empty_label.text = "Missing outcome"
			empty_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			identity_row.add_child(empty_label)
			var remove_empty := Button.new()
			remove_empty.text = "Remove"
			remove_empty.pressed.connect(_remove_random_branch.bind(node, index))
			identity_row.add_child(remove_empty)
			row.add_child(identity_row)
			_random_rows.add_child(row)
			continue

		var label_edit := LineEdit.new()
		label_edit.name = "Label"
		label_edit.placeholder_text = "Outcome name"
		label_edit.tooltip_text = "The readable outcome name shown on the node"
		label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label_edit.text = str(_read_value(branch, &"label", ""))
		label_edit.text_submitted.connect(_on_random_label_submitted.bind(node, branch))
		label_edit.focus_exited.connect(_on_random_label_focus_exited.bind(label_edit, node, branch))
		identity_row.add_child(label_edit)
		var inspect_branch := Button.new()
		inspect_branch.text = "More"
		inspect_branch.tooltip_text = "Open all settings for this random outcome"
		inspect_branch.pressed.connect(_inspect_subresource.bind(branch))
		identity_row.add_child(inspect_branch)
		var remove_branch := Button.new()
		remove_branch.text = "X"
		remove_branch.tooltip_text = "Remove this outcome and its attached wire"
		remove_branch.pressed.connect(_remove_random_branch.bind(node, index))
		identity_row.add_child(remove_branch)
		row.add_child(identity_row)

		var values_row := HBoxContainer.new()
		var weight_label := Label.new()
		weight_label.text = "Chance Weight"
		weight_label.tooltip_text = "For example, weights 99 and 1 give 99% and 1% chances"
		values_row.add_child(weight_label)
		var weight := SpinBox.new()
		weight.name = "Weight"
		weight.tooltip_text = "Relative chance among connected outcomes"
		weight.min_value = 0.01
		weight.max_value = 1000000.0
		weight.step = 0.01
		weight.allow_greater = true
		weight.custom_minimum_size.x = 92.0
		weight.value = float(_read_value(branch, &"weight", 1.0))
		weight.value_changed.connect(_on_random_weight_changed.bind(node, branch))
		values_row.add_child(weight)
		var port_label := Label.new()
		port_label.text = "Connection Name"
		port_label.tooltip_text = "Permanent internal name for this outcome's wire"
		values_row.add_child(port_label)
		var port_edit := LineEdit.new()
		port_edit.name = "PortId"
		port_edit.placeholder_text = "outcome_name"
		port_edit.tooltip_text = "Permanent internal connection name. Renaming it safely moves every attached wire."
		port_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		port_edit.text = str(_read_value(branch, &"port_id", ""))
		port_edit.text_submitted.connect(_on_random_port_submitted.bind(node, branch))
		port_edit.focus_exited.connect(_on_random_port_focus_exited.bind(port_edit, node, branch))
		values_row.add_child(port_edit)
		row.add_child(values_row)
		_random_rows.add_child(row)
		_random_row_controls[branch.get_instance_id()] = {
			"port": port_edit,
			"label": label_edit,
			"weight": weight,
		}


func _is_random_node(node: Resource) -> bool:
	return node != null and StringName(str(_call_if_present(node, &"type_id", ""))) == &"random"


func _on_random_port_submitted(text: String, node: Resource, branch: Resource) -> void:
	_rename_random_branch_port(node, branch, StringName(text.strip_edges()))


func _on_random_port_focus_exited(edit: LineEdit, node: Resource, branch: Resource) -> void:
	_rename_random_branch_port(node, branch, StringName(edit.text.strip_edges()))


func _on_random_label_submitted(text: String, node: Resource, branch: Resource) -> void:
	_set_random_branch_scalar(node, branch, &"label", text, "Set Random Branch Label")


func _on_random_label_focus_exited(edit: LineEdit, node: Resource, branch: Resource) -> void:
	_set_random_branch_scalar(node, branch, &"label", edit.text, "Set Random Branch Label")


func _on_random_weight_changed(value: float, node: Resource, branch: Resource) -> void:
	if not _suppress_random_controls:
		_set_random_branch_scalar(node, branch, &"weight", value, "Set Random Branch Weight", true)


func _sync_random_controls(node: Resource) -> void:
	if not _is_random_node(node):
		return
	_suppress_random_controls = true
	for raw_branch: Variant in _array_property(node, &"branches"):
		var branch := raw_branch as Resource
		if branch == null:
			continue
		var controls: Dictionary = _random_row_controls.get(branch.get_instance_id(), {})
		var port_edit := controls.get("port") as LineEdit
		var label_edit := controls.get("label") as LineEdit
		var weight := controls.get("weight") as SpinBox
		if port_edit != null:
			port_edit.text = str(_read_value(branch, &"port_id", ""))
		if label_edit != null:
			label_edit.text = str(_read_value(branch, &"label", ""))
		if weight != null:
			weight.value = float(_read_value(branch, &"weight", 1.0))
	_suppress_random_controls = false


func _refresh_node_view_labels(node: Resource) -> void:
	var view := _node_to_view.get(_node_id(node)) as GraphNode
	if view == null:
		return
	view.title = _node_title(node)
	var outputs := _string_name_array(_call_if_present(node, &"output_ports", []))
	for slot_index in outputs.size():
		if slot_index >= view.get_child_count():
			break
		var row := view.get_child(slot_index) as HBoxContainer
		if row != null and row.get_child_count() >= 2:
			var output_label := row.get_child(1) as Label
			if output_label != null:
				output_label.text = _port_label(node, outputs[slot_index])


func _add_random_branch() -> void:
	var node := _inspector_owner_node
	if not _is_random_node(node) or _graph == null:
		return
	var branch := _new_global_class_instance(&"FlowRandomBranch") as Resource
	if branch == null:
		_status.text = "A new random outcome could not be created."
		return
	var port_id := _next_random_port_id(node)
	branch.set(&"port_id", port_id)
	branch.set(&"label", String(port_id).replace("_", " ").capitalize())
	branch.set(&"weight", 1.0)
	var before := _array_property(node, &"branches")
	var after := before.duplicate()
	after.append(branch)
	var connections := _array_property(_graph, &"connections")
	_commit_random_structure_change(
		"Add Random Outcome", node, before, after, connections, connections)


func _remove_random_branch(node: Resource, index: int) -> void:
	if not _is_random_node(node) or _graph == null:
		return
	var before_branches := _array_property(node, &"branches")
	if index < 0 or index >= before_branches.size():
		return
	var branch := before_branches[index] as Resource
	var removed_port := StringName(str(_read_value(branch, &"port_id", "")))
	var after_branches := before_branches.duplicate()
	after_branches.remove_at(index)
	var before_connections := _array_property(_graph, &"connections")
	var after_connections := before_connections.duplicate()
	for connection_index in range(after_connections.size() - 1, -1, -1):
		var connection: Variant = after_connections[connection_index]
		if StringName(str(_read_value(connection, &"from_node_id", ""))) == _node_id(node) \
				and StringName(str(_read_value(connection, &"from_port_id", ""))) == removed_port:
			after_connections.remove_at(connection_index)
	_commit_random_structure_change(
		"Remove Random Outcome", node, before_branches, after_branches,
		before_connections, after_connections)


func _commit_random_structure_change(
		label: String,
		node: Resource,
		before_branches: Array,
		after_branches: Array,
		before_connections: Array,
		after_connections: Array
) -> void:
	var undo := _undo_redo()
	if undo == null:
		node.set(&"branches", after_branches)
		_graph.set(&"connections", after_connections)
		node.emit_changed()
		_graph.emit_changed()
		_after_random_structure_mutation(node)
		return
	undo.create_action(label, UndoRedo.MERGE_DISABLE, node)
	undo.add_do_property(node, &"branches", after_branches)
	undo.add_do_property(_graph, &"connections", after_connections)
	undo.add_do_method(node, &"emit_changed")
	undo.add_do_method(_graph, &"emit_changed")
	undo.add_do_method(self, &"_after_random_structure_mutation", node)
	undo.add_undo_property(node, &"branches", before_branches)
	undo.add_undo_property(_graph, &"connections", before_connections)
	undo.add_undo_method(node, &"emit_changed")
	undo.add_undo_method(_graph, &"emit_changed")
	undo.add_undo_method(self, &"_after_random_structure_mutation", node)
	undo.commit_action()


func _rename_random_branch_port(node: Resource, branch: Resource, new_port: StringName) -> void:
	if not _is_random_node(node) or branch == null or _graph == null:
		return
	var old_port := StringName(str(_read_value(branch, &"port_id", "")))
	if old_port == new_port:
		return
	if new_port.is_empty():
		_status.text = "Every random outcome needs a Connection Name."
		_sync_random_controls(node)
		return
	for other: Variant in _array_property(node, &"branches"):
		if other is Resource and other != branch \
				and StringName(str(_read_value(other, &"port_id", ""))) == new_port:
			_status.text = "Connection Name '%s' is already used by another outcome." % new_port
			_sync_random_controls(node)
			return

	var affected_connections: Array[Resource] = []
	for raw_connection: Variant in _array_property(_graph, &"connections"):
		var connection := raw_connection as Resource
		if connection != null \
				and StringName(str(_read_value(connection, &"from_node_id", ""))) == _node_id(node) \
				and StringName(str(_read_value(connection, &"from_port_id", ""))) == old_port:
			affected_connections.append(connection)
	var undo := _undo_redo()
	if undo == null:
		branch.set(&"port_id", new_port)
		for connection: Resource in affected_connections:
			connection.set(&"from_port_id", new_port)
		branch.emit_changed()
		_graph.emit_changed()
		_after_random_structure_mutation(node)
		return
	undo.create_action("Rename Random Outcome Connection", UndoRedo.MERGE_DISABLE, node)
	undo.add_do_property(branch, &"port_id", new_port)
	for connection: Resource in affected_connections:
		undo.add_do_property(connection, &"from_port_id", new_port)
	undo.add_do_method(branch, &"emit_changed")
	undo.add_do_method(_graph, &"emit_changed")
	undo.add_do_method(self, &"_after_random_structure_mutation", node)
	undo.add_undo_property(branch, &"port_id", old_port)
	for connection: Resource in affected_connections:
		undo.add_undo_property(connection, &"from_port_id", old_port)
	undo.add_undo_method(branch, &"emit_changed")
	undo.add_undo_method(_graph, &"emit_changed")
	undo.add_undo_method(self, &"_after_random_structure_mutation", node)
	undo.commit_action()


func _set_random_branch_scalar(
		node: Resource,
		branch: Resource,
		property: StringName,
		value: Variant,
		label: String,
		merge: bool = false
) -> void:
	if not _is_random_node(node) or branch == null or _graph == null:
		return
	var before := _read_value(branch, property, null)
	if before == value or (before is float and value is float and is_equal_approx(before, value)):
		return
	var undo := _undo_redo()
	if undo == null:
		branch.set(property, value)
		branch.emit_changed()
		_after_random_value_mutation(node)
		return
	undo.create_action(label, UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE, branch)
	undo.add_do_property(branch, property, value)
	undo.add_do_method(branch, &"emit_changed")
	undo.add_do_method(self, &"_after_random_value_mutation", node)
	undo.add_undo_property(branch, property, before)
	undo.add_undo_method(branch, &"emit_changed")
	undo.add_undo_method(self, &"_after_random_value_mutation", node)
	undo.commit_action()


func _after_random_structure_mutation(node: Resource) -> void:
	if _graph == null or node == null:
		return
	if _graph.has_method(&"invalidate_index"):
		_graph.call(&"invalidate_index")
	_mark_dirty(_graph)
	_reload_preserving_selection(_node_id(node))
	_validate_graphs()


func _after_random_value_mutation(node: Resource) -> void:
	if _graph == null or node == null:
		return
	node.emit_changed()
	_graph.emit_changed()
	_mark_dirty(_graph)
	_sync_random_controls(node)
	_refresh_node_view_labels(node)


func _next_random_port_id(node: Resource) -> StringName:
	var used: Dictionary = {}
	for branch: Variant in _array_property(node, &"branches"):
		used[StringName(str(_read_value(branch, &"port_id", "")))] = true
	var suffix := maxi(1, used.size() + 1)
	var candidate := StringName("option_%d" % suffix)
	while used.has(candidate):
		suffix += 1
		candidate = StringName("option_%d" % suffix)
	return candidate


func _refresh_reference_picker(node: Resource) -> void:
	if not is_instance_valid(_reference_row):
		return
	_reference_property = &""
	_reference_row.visible = false
	_suppress_reference_selector = true
	_reference_selector.clear()

	if node == null or _active_database == null:
		_suppress_reference_selector = false
		return

	var source_property := &""
	var node_property := &""
	var entry_id_property := &""
	var label := "Choose from Library"
	var empty_choice := "<Choose an item>"
	if _has_property(node, &"level_id"):
		source_property = &"levels"
		node_property = &"level_id"
		entry_id_property = &"level_id"
		label = "Choose Level"
		empty_choice = "<Choose a level>"
	elif _has_property(node, &"cutscene_id"):
		source_property = &"cutscenes"
		node_property = &"cutscene_id"
		entry_id_property = &"cutscene_id"
		label = "Choose Cutscene"
		empty_choice = "<Choose a cutscene>"
	elif _has_property(node, &"action_id"):
		source_property = &"custom_actions"
		node_property = &"action_id"
		entry_id_property = &"action_id"
		label = "Choose Game Action"
		empty_choice = "<Choose a game action>"
	elif _has_property(node, &"subgraph_id"):
		source_property = &"graphs"
		node_property = &"subgraph_id"
		entry_id_property = &"graph_id"
		label = "Choose Subgraph"
		empty_choice = "<Choose a subgraph>"
	else:
		_suppress_reference_selector = false
		return

	_reference_property = node_property
	_reference_label.text = label
	_reference_selector.add_item(empty_choice)
	_reference_selector.set_item_metadata(0, &"")
	var current_id := StringName(str(_read_value(node, node_property, "")))
	var selected_index := 0
	var found_current := current_id.is_empty()
	var entries: Array = _array_property(_active_database, source_property)
	for entry: Variant in entries:
		var entry_id := StringName(str(_read_value(entry, entry_id_property, "")))
		if entry_id.is_empty():
			continue
		if source_property == &"graphs":
			var candidate_graph := _read_value(entry, &"graph", null) as Resource
			# Calls only target subgraphs. Filtering master/current graphs prevents an easy-to-author
			# recursion error while the raw Inspector field remains available for recovery work.
			if candidate_graph == _graph or int(_read_value(candidate_graph, &"kind", 0)) != 1:
				continue
		var item := _reference_selector.item_count
		var display := str(_read_value(entry, &"display_name", "")).strip_edges()
		if display.is_empty() and source_property == &"graphs":
			display = _graph_display_name(_read_value(entry, &"graph", null) as Resource)
		_reference_selector.add_item("%s%s" % [
			display if not display.is_empty() else _friendly_authored_name(entry_id),
			"  (%s)" % entry_id if not display.is_empty() else ""])
		_reference_selector.set_item_metadata(item, entry_id)
		if entry_id == current_id:
			selected_index = item
			found_current = true

	if not found_current:
		selected_index = _reference_selector.item_count
		_reference_selector.add_item("%s  (not found in library)" % _friendly_authored_name(current_id))
		_reference_selector.set_item_metadata(selected_index, current_id)
	_reference_selector.select(selected_index)
	_reference_selector.disabled = _reference_selector.item_count <= 1
	_reference_row.visible = true
	_suppress_reference_selector = false


func _on_reference_selected(index: int) -> void:
	if _suppress_reference_selector or _graph == null or _reference_property.is_empty() or index < 0:
		return
	var edited := _inspector.get_edited_object() as Resource
	if edited == null or not _has_property(edited, _reference_property):
		return
	var new_id := StringName(str(_reference_selector.get_item_metadata(index)))
	if new_id.is_empty():
		return
	var old_id := StringName(str(_read_value(edited, _reference_property, "")))
	if old_id == new_id:
		return
	var undo := _undo_redo()
	if undo == null:
		edited.set(_reference_property, new_id)
		edited.emit_changed()
		_reload_preserving_selection(_node_id(edited))
		_mark_dirty(_graph)
		return
	undo.create_action("Set Flow Node Registered ID", UndoRedo.MERGE_DISABLE, edited)
	undo.add_do_property(edited, _reference_property, new_id)
	undo.add_do_method(edited, &"emit_changed")
	undo.add_do_method(self, &"_after_reference_edit", edited)
	undo.add_undo_property(edited, _reference_property, old_id)
	undo.add_undo_method(edited, &"emit_changed")
	undo.add_undo_method(self, &"_after_reference_edit", edited)
	undo.commit_action()


func _after_reference_edit(node: Resource) -> void:
	if _graph == null or node == null:
		return
	if _graph.has_method(&"invalidate_index"):
		_graph.call(&"invalidate_index")
	_mark_dirty(_graph)
	_reload_preserving_selection(_node_id(node))


func _reload_preserving_selection(node_id: StringName) -> void:
	if _graph == null:
		return
	_rebuild_canvas()
	_select_node(node_id, false)


func _select_node(node_id: StringName, center_view: bool = true) -> void:
	var view := _node_to_view.get(node_id) as GraphNode
	if view == null:
		return
	_graph_edit.set_selected(view)
	_selected_node_ids[node_id] = true
	var node := _view_to_node.get(view.name) as Resource
	_inspect_node(node)
	if center_view:
		_graph_edit.scroll_offset = view.position_offset - (_graph_edit.size / maxf(_graph_edit.zoom, 0.01)) * 0.5
	_update_copy_paste_buttons()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or not (key.ctrl_pressed or key.meta_pressed):
		return
	if key.keycode == KEY_C:
		_copy_selected_nodes()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_V:
		_paste_nodes()
		get_viewport().set_input_as_handled()


func _update_copy_paste_buttons() -> void:
	if is_instance_valid(_copy_button):
		_copy_button.disabled = _graph == null or _selected_node_ids.is_empty()
	if is_instance_valid(_paste_button):
		_paste_button.disabled = _graph == null or _clipboard_nodes.is_empty()


func _frame_all() -> void:
	if _graph == null or _node_to_view.is_empty():
		return
	var bounds := Rect2()
	var has_bounds := false
	for raw_view: Variant in _node_to_view.values():
		var view := raw_view as GraphNode
		if view == null:
			continue
		var node_size := view.size
		if node_size.x <= 1.0 or node_size.y <= 1.0:
			node_size = Vector2(220.0, 100.0)
		var node_rect := Rect2(view.position_offset, node_size)
		bounds = bounds.merge(node_rect) if has_bounds else node_rect
		has_bounds = true
	if not has_bounds:
		return
	var available := _graph_edit.size - Vector2(96.0, 96.0)
	if available.x <= 1.0 or available.y <= 1.0:
		return
	var padded_size := bounds.size + Vector2(64.0, 64.0)
	var target_zoom := minf(available.x / maxf(padded_size.x, 1.0), available.y / maxf(padded_size.y, 1.0))
	_graph_edit.zoom = clampf(target_zoom, _graph_edit.zoom_min, _graph_edit.zoom_max)
	_graph_edit.scroll_offset = bounds.get_center() - _graph_edit.size / (_graph_edit.zoom * 2.0)
	_capture_view_state.call_deferred()


func _capture_view_state() -> void:
	if _graph == null or _suppress_canvas_events:
		return
	var changed := false
	var old_offset: Variant = _read_value(_graph, &"editor_scroll_offset", Vector2.ZERO)
	if not old_offset is Vector2 or not old_offset.is_equal_approx(_graph_edit.scroll_offset):
		_graph.set(&"editor_scroll_offset", _graph_edit.scroll_offset)
		changed = true
	var old_zoom := float(_read_value(_graph, &"editor_zoom", 1.0))
	if not is_equal_approx(old_zoom, _graph_edit.zoom):
		_graph.set(&"editor_zoom", _graph_edit.zoom)
		changed = true
	if changed:
		_graph.emit_changed()
		_mark_dirty(_graph)


func _on_scroll_offset_changed(_offset: Vector2) -> void:
	if not _suppress_canvas_events:
		_capture_view_state.call_deferred()


func _on_graph_popup_requested(_position: Vector2) -> void:
	if is_instance_valid(_palette_search):
		_palette_search.grab_focus()

#endregion


#region Breadcrumbs and subgraphs

func _navigate_to(graph: Resource, breadcrumb_chain: Array, record_history: bool = true) -> void:
	if graph == null or not _is_flow_graph(graph):
		return
	var normalized: Array[Resource] = []
	for item: Variant in breadcrumb_chain:
		if item is Resource and _is_flow_graph(item):
			normalized.append(item)
	if normalized.is_empty() or normalized.back() != graph:
		normalized.append(graph)

	if record_history:
		if _navigation_index + 1 < _navigation_history.size():
			_navigation_history.resize(_navigation_index + 1)
		_navigation_history.append({
			"graph": graph,
			"breadcrumbs": normalized.duplicate(),
			"database": _active_database,
		})
		_navigation_index = _navigation_history.size() - 1
	_breadcrumbs.assign(normalized)
	_set_graph(graph)
	_update_navigation_buttons()


func _navigate_back() -> void:
	if _navigation_index <= 0:
		return
	_navigation_index -= 1
	_restore_navigation_entry(_navigation_history[_navigation_index])


func _navigate_forward() -> void:
	if _navigation_index < 0 or _navigation_index + 1 >= _navigation_history.size():
		return
	_navigation_index += 1
	_restore_navigation_entry(_navigation_history[_navigation_index])


func _restore_navigation_entry(entry: Dictionary) -> void:
	var graph := entry.get("graph") as Resource
	if graph == null:
		_update_navigation_buttons()
		return
	_active_database = entry.get("database") as Resource
	if _active_database == null:
		_active_database = _find_database_containing_graph(graph)
	var trail: Array = entry.get("breadcrumbs", [graph])
	_navigate_to(graph, trail, false)


func _update_navigation_buttons() -> void:
	if is_instance_valid(_back_button):
		_back_button.disabled = _navigation_index <= 0
	if is_instance_valid(_forward_button):
		_forward_button.disabled = _navigation_index < 0 or _navigation_index + 1 >= _navigation_history.size()


func _refresh_graph_selector() -> void:
	if not is_instance_valid(_graph_selector):
		return
	_suppress_graph_selector = true
	_graph_selector.clear()
	var selected_index := -1
	if _active_database != null:
		for entry: Variant in _array_property(_active_database, &"graphs"):
			var graph_id := StringName(str(_read_value(entry, &"graph_id", "")))
			var graph := _read_value(entry, &"graph", null) as Resource
			if graph_id.is_empty() or graph == null:
				continue
			var item := _graph_selector.item_count
			_graph_selector.add_item("%s  [%s]" % [_graph_display_name(graph), graph_id])
			_graph_selector.set_item_metadata(item, graph_id)
			if graph == _graph:
				selected_index = item
	_graph_selector.disabled = _graph_selector.item_count == 0
	if _graph_selector.item_count == 0:
		_graph_selector.add_item("Graph not yet in library" if _graph != null else "No Game Flow library")
		_graph_selector.disabled = true
	if selected_index >= 0:
		_graph_selector.select(selected_index)
	_suppress_graph_selector = false


func _on_graph_selector_selected(index: int) -> void:
	if _suppress_graph_selector or _active_database == null or index < 0:
		return
	var graph_id := StringName(str(_graph_selector.get_item_metadata(index)))
	if graph_id.is_empty() or not _active_database.has_method(&"get_graph"):
		return
	var graph := _active_database.call(&"get_graph", graph_id) as Resource
	if graph != null and graph != _graph:
		_navigate_to(graph, [graph])

func _rebuild_breadcrumbs() -> void:
	for child: Node in _breadcrumb_bar.get_children():
		child.queue_free()
	for index in _breadcrumbs.size():
		if index > 0:
			var arrow := Label.new()
			arrow.text = "  >  "
			_breadcrumb_bar.add_child(arrow)
		var graph := _breadcrumbs[index]
		var button := Button.new()
		button.flat = true
		button.text = _graph_display_name(graph)
		button.disabled = graph == _graph
		button.pressed.connect(_on_breadcrumb_pressed.bind(index))
		_breadcrumb_bar.add_child(button)


func _on_breadcrumb_pressed(index: int) -> void:
	if index < 0 or index >= _breadcrumbs.size():
		return
	var graph := _breadcrumbs[index]
	var trail := _breadcrumbs.duplicate()
	trail.resize(index + 1)
	_navigate_to(graph, trail)


func _open_subgraph(subgraph_id: StringName) -> void:
	var graph := _resolve_graph_by_id(subgraph_id)
	if graph == null:
		_status.text = "Subgraph '%s' was not found in the Game Flow library." % \
			_friendly_authored_name(subgraph_id)
		return
	var trail := _breadcrumbs.duplicate()
	trail.append(graph)
	_navigate_to(graph, trail)


func _resolve_graph_by_id(graph_id: StringName) -> Resource:
	if _active_database != null and _active_database.has_method(&"get_graph"):
		var graph: Variant = _active_database.call(&"get_graph", graph_id)
		if graph is Resource:
			return graph
	for database: Resource in _find_databases():
		if not database.has_method(&"get_graph"):
			continue
		var graph: Variant = database.call(&"get_graph", graph_id)
		if graph is Resource:
			_active_database = database
			return graph
	return null

#endregion


#region Validation

func _validate_graphs() -> bool:
	if _graph == null:
		_present_validation_issues([])
		_status.text = "Open a graph before validating."
		return true
	if _active_database == null:
		_active_database = _find_database_containing_graph(_graph)
	_refresh_reference_picker(_inspector.get_edited_object() as Resource)
	var issues := _collect_validation_issues(_active_database, _graph)
	_present_validation_issues(issues)
	return _validation_error_count(issues) == 0


func _collect_validation_issues(database: Resource, graph: Resource) -> Array:
	var issues: Array = []
	if database != null:
		if database.has_method(&"validate_issues"):
			var raw: Variant = database.call(&"validate_issues")
			if raw is Array:
				issues = raw
		elif database.has_method(&"validate_graphs"):
			var graph_raw: Variant = database.call(&"validate_graphs")
			if graph_raw is Array:
				issues = graph_raw
	if issues.is_empty() and graph != null and graph.has_method(&"validate_detailed"):
		var graph_id := _graph_id_in_database(graph, database)
		var detailed_raw: Variant = graph.call(&"validate_detailed", graph_id, database)
		if detailed_raw is Array:
			issues = detailed_raw
	return issues


func _present_validation_issues(issues: Array) -> void:
	_validation.clear()
	_validation_entries.clear()
	for issue: Variant in issues:
		var severity := int(_read_value(issue, &"severity", 2))
		var message := str(_read_value(issue, &"message", "The graph needs attention."))
		var location := _friendly_validation_location(issue)
		if not location.is_empty():
			message = "%s — %s" % [location, message]
		var prefix: String = ["INFO", "WARNING", "ERROR"][clampi(severity, 0, 2)]
		var item := _validation.add_item("[%s] %s" % [prefix, message])
		if severity == 2:
			_validation.set_item_custom_fg_color(item, Color(1.0, 0.42, 0.38))
		elif severity == 1:
			_validation.set_item_custom_fg_color(item, Color(1.0, 0.78, 0.3))
		_validation_entries.append(issue)

	if issues.is_empty():
		_validation.add_item("No problems found.")
		_status.text = "Graph check passed."
	else:
		_status.text = "%d item%s need attention." % [issues.size(), "" if issues.size() == 1 else "s"]


func _friendly_validation_location(issue: Variant) -> String:
	var parts: Array[String] = []
	var graph_id := StringName(str(_read_value(issue, &"graph_id", "")))
	var node_id := StringName(str(_read_value(issue, &"node_id", "")))
	var port_id := StringName(str(_read_value(issue, &"port_id", "")))
	var target_graph := _graph
	if not graph_id.is_empty() and _active_database != null \
			and _active_database.has_method(&"get_graph"):
		var registered_graph: Variant = _active_database.call(&"get_graph", graph_id)
		if registered_graph is Resource:
			target_graph = registered_graph
	if target_graph != null:
		parts.append(_graph_display_name(target_graph))
	var target_node: Variant = null
	if target_graph != null and not node_id.is_empty() and target_graph.has_method(&"get_node"):
		target_node = target_graph.call(&"get_node", node_id)
	if target_node != null:
		parts.append("Step: %s" % _node_title(target_node))
		if not port_id.is_empty():
			parts.append("Outcome: %s" % _port_label(target_node, port_id))
	elif not StringName(str(_read_value(issue, &"connection_id", ""))).is_empty():
		parts.append("Wire")
	return " › ".join(parts)


func _validation_error_count(issues: Array) -> int:
	var count := 0
	for issue: Variant in issues:
		if int(_read_value(issue, &"severity", 2)) >= 2:
			count += 1
	return count


func _on_validation_item_activated(index: int) -> void:
	if index < 0 or index >= _validation_entries.size():
		return
	var issue: Variant = _validation_entries[index]
	var graph_id := StringName(str(_read_value(issue, &"graph_id", "")))
	var node_id := StringName(str(_read_value(issue, &"node_id", "")))
	if not graph_id.is_empty():
		var target := _resolve_graph_by_id(graph_id)
		if target != null and target != _graph:
			var trail := _breadcrumbs.duplicate()
			trail.append(target)
			_navigate_to(target, trail)
	if not node_id.is_empty():
		_select_node.call_deferred(node_id, true)

#endregion


#region Persistence

func _show_new_graph_dialog() -> void:
	_new_graph_name.text = ""
	_new_graph_kind.select(0)
	_new_graph_dialog.popup_centered(Vector2i(420, 210))
	_new_graph_name.grab_focus.call_deferred()


func _on_new_graph_settings_confirmed() -> void:
	_pending_new_graph_name = _new_graph_name.text.strip_edges()
	if _pending_new_graph_name.is_empty():
		_pending_new_graph_name = "New Game Flow"
	_pending_new_graph_kind = _new_graph_kind.get_selected_id()
	var suggested := _pending_new_graph_name.to_snake_case()
	if suggested.is_empty():
		suggested = "game_flow"
	_new_graph_path_dialog.current_file = "%s.tres" % suggested
	_new_graph_path_dialog.popup_centered_ratio(0.72)


func _create_new_graph_at_path(path: String) -> void:
	var graph := _new_global_class_instance(&"FlowGraph") as Resource
	if graph == null:
		_status.text = "A new Game Flow graph could not be created."
		return
	graph.set(&"display_name", _pending_new_graph_name)
	graph.set(&"kind", _pending_new_graph_kind)
	var error := ResourceSaver.save(graph, path)
	if error != OK:
		_status.text = "Could not create %s (error %d)." % [path, error]
		return
	if _filesystem != null:
		_filesystem.update_file(path)
	_active_database = null
	_navigate_to(graph, [graph])
	_status.text = "Created %s. Add it to the Game Flow library when ready." % path


func _show_register_graph_dialog() -> void:
	if _graph == null:
		return
	var databases := _find_databases()
	if databases.is_empty():
		_status.text = "No Game Flow library was found in the project."
		return
	_register_database_selector.clear()
	for database: Resource in databases:
		var item := _register_database_selector.item_count
		var label := database.resource_path if not database.resource_path.is_empty() else "Built-in Game Flow Library"
		_register_database_selector.add_item(label)
		_register_database_selector.set_item_metadata(item, database)
		if database == _active_database:
			_register_database_selector.select(item)
	var suggested := _graph_display_name(_graph).to_snake_case()
	_register_graph_id.text = suggested if not suggested.is_empty() else "game_flow"
	_register_dialog.popup_centered(Vector2i(520, 230))
	_register_graph_id.select_all.call_deferred()
	_register_graph_id.grab_focus.call_deferred()


func _register_current_graph() -> void:
	if _graph == null:
		return
	var selected := _register_database_selector.selected
	if selected < 0:
		_status.text = "Choose a Game Flow library."
		return
	var database := _register_database_selector.get_item_metadata(selected) as Resource
	var graph_id := StringName(_register_graph_id.text.strip_edges())
	if database == null or graph_id.is_empty():
		_status.text = "Choose a library and enter a Graph Name for Connections."
		return
	if database.has_method(&"rebuild_index"):
		database.call(&"rebuild_index")
	if database.has_method(&"get_graph"):
		var existing := database.call(&"get_graph", graph_id) as Resource
		if existing != null and existing != _graph:
			_status.text = "Graph Name '%s' is already used in this library." % graph_id
			return

	var entry := _new_global_class_instance(&"FlowGraphEntry") as Resource
	if entry == null:
		_status.text = "This graph could not be added to the Game Flow library."
		return
	entry.set(&"graph_id", graph_id)
	entry.set(&"graph", _graph)
	entry.set(&"display_name", _graph_display_name(_graph))
	var before := _array_property(database, &"graphs")
	var after := before.duplicate()
	after.append(entry)
	var undo := _undo_redo()
	if undo == null:
		database.set(&"graphs", after)
		database.emit_changed()
		_after_database_mutation(database, _graph)
		return
	undo.create_action("Register Flow Graph", UndoRedo.MERGE_DISABLE, database)
	undo.add_do_property(database, &"graphs", after)
	undo.add_do_method(database, &"emit_changed")
	undo.add_do_method(self, &"_after_database_mutation", database, _graph)
	undo.add_undo_property(database, &"graphs", before)
	undo.add_undo_method(database, &"emit_changed")
	undo.add_undo_method(self, &"_after_database_mutation", database, _graph)
	undo.commit_action()


func _set_current_graph_as_master() -> void:
	if _graph == null:
		return
	var database := _known_database_containing_graph(_graph)
	if database == null:
		_status.text = "Register this graph before setting it as master."
		return
	var graph_id := _graph_id_in_database(_graph, database)
	if graph_id.is_empty():
		_status.text = "This graph is missing its Graph Name for Connections."
		return
	var old_master := StringName(str(_read_value(database, &"master_graph_id", "")))
	var old_kind := int(_read_value(_graph, &"kind", 0))
	if old_master == graph_id and old_kind == 0:
		_status.text = "'%s' is already the master graph." % graph_id
		return
	var undo := _undo_redo()
	if undo == null:
		database.set(&"master_graph_id", graph_id)
		_graph.set(&"kind", 0)
		database.emit_changed()
		_graph.emit_changed()
		_after_master_mutation(database, _graph)
		return
	undo.create_action("Make Main Game Flow Graph", UndoRedo.MERGE_DISABLE, database)
	undo.add_do_property(database, &"master_graph_id", graph_id)
	undo.add_do_property(_graph, &"kind", 0)
	undo.add_do_method(database, &"emit_changed")
	undo.add_do_method(_graph, &"emit_changed")
	undo.add_do_method(self, &"_after_master_mutation", database, _graph)
	undo.add_undo_property(database, &"master_graph_id", old_master)
	undo.add_undo_property(_graph, &"kind", old_kind)
	undo.add_undo_method(database, &"emit_changed")
	undo.add_undo_method(_graph, &"emit_changed")
	undo.add_undo_method(self, &"_after_master_mutation", database, _graph)
	undo.commit_action()


func _after_database_mutation(database: Resource, graph: Resource) -> void:
	if database != null and database.has_method(&"rebuild_index"):
		database.call(&"rebuild_index")
	_active_database = database if not _graph_id_in_database(graph, database).is_empty() \
			else _find_database_containing_graph(graph)
	_mark_database_dirty(database)
	_refresh_graph_selector()
	_update_enabled_state()
	_validate_graphs()


func _after_master_mutation(database: Resource, graph: Resource) -> void:
	if database != null and database.has_method(&"rebuild_index"):
		database.call(&"rebuild_index")
	_active_database = database
	_mark_database_dirty(database)
	_mark_dirty(graph)
	_refresh_graph_selector()
	_update_enabled_state()
	_validate_graphs()


func _show_open_dialog() -> void:
	_open_dialog.popup_centered_ratio(0.72)


func _on_graph_file_selected(path: String) -> void:
	var resource := ResourceLoader.load(path)
	if not resource is Resource or not _is_flow_graph(resource):
		_status.text = "%s is not a Game Flow graph." % path
		return
	open_graph(resource)


func _save_current_graph() -> void:
	_capture_view_state()
	if _graph != null:
		# Validation is advisory during authoring: surface structured issues, but never prevent an
		# incomplete graph from being saved.
		_validate_graphs()
		_save_graph(_graph)
	if _active_database != null and _dirty_databases.has(_active_database.get_instance_id()):
		_save_database(_active_database)


func _save_graph(graph: Resource) -> void:
	var save_owner: Resource = graph
	var save_path := graph.resource_path
	# A graph may be an embedded subresource of a FlowDatabase. Save the owning database in that
	# case; ResourceSaver cannot write a `res://database.tres::SubResource` path directly.
	if save_path.is_empty() or save_path.contains("::"):
		var database := _active_database
		if database == null or _graph_id_in_database(graph, database).is_empty():
			database = _find_database_containing_graph(graph)
		if database != null and not database.resource_path.is_empty():
			save_owner = database
			save_path = database.resource_path
	if save_path.is_empty() or save_path.contains("::"):
		_status.text = "Save this graph or its Game Flow library to the project first."
		return
	var error := ResourceSaver.save(save_owner, save_path)
	if error != OK:
		_status.text = "Could not save %s (error %d)." % [save_path, error]
		return
	if save_owner == graph:
		_dirty_graphs.erase(graph.get_instance_id())
	else:
		_dirty_databases.erase(save_owner.get_instance_id())
		for entry: Variant in _array_property(save_owner, &"graphs"):
			var embedded_graph: Variant = _read_value(entry, &"graph", null)
			if embedded_graph is Resource:
				_dirty_graphs.erase(embedded_graph.get_instance_id())
	if _filesystem != null:
		_filesystem.update_file(save_path)
	_status.text = "Saved %s" % save_path
	_update_enabled_state()


func _save_database(database: Resource) -> void:
	if database == null or database.resource_path.is_empty() or database.resource_path.contains("::"):
		_status.text = "Save the Game Flow library to the project first."
		return
	var error := ResourceSaver.save(database, database.resource_path)
	if error != OK:
		_status.text = "Could not save %s (error %d)." % [database.resource_path, error]
		return
	_dirty_databases.erase(database.get_instance_id())
	if _filesystem != null:
		_filesystem.update_file(database.resource_path)
	_status.text = "Saved %s" % database.resource_path
	_update_enabled_state()


func _mark_dirty(graph: Resource) -> void:
	if graph == null:
		return
	_dirty_graphs[graph.get_instance_id()] = graph
	if graph == _graph:
		_graph_name.text = "%s *" % _graph_display_name(graph)


func _mark_database_dirty(database: Resource) -> void:
	if database == null:
		return
	_dirty_databases[database.get_instance_id()] = database

#endregion


#region Database discovery

func _known_database_containing_graph(graph: Resource) -> Resource:
	if _active_database != null and not _graph_id_in_database(graph, _active_database).is_empty():
		return _active_database
	return _find_database_containing_graph(graph)


func _find_database_containing_graph(graph: Resource) -> Resource:
	for database: Resource in _find_databases():
		for entry: Variant in _array_property(database, &"graphs"):
			if _read_value(entry, &"graph", null) == graph:
				return database
	return null


func _find_databases() -> Array[Resource]:
	var found: Array[Resource] = []
	var seen: Dictionary = {}
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		var scene_nodes: Array[Node] = [root]
		scene_nodes.append_array(root.find_children("*", "", true, false))
		for node: Node in scene_nodes:
			var database: Variant = _read_value(node, &"database", null)
			if database is Resource and _looks_like_database(database):
				seen[database.get_instance_id()] = true
				found.append(database)

	if _filesystem == null:
		return found
	var paths: PackedStringArray = []
	_collect_database_paths(_filesystem.get_filesystem(), paths)
	for path: String in paths:
		var database := ResourceLoader.load(path)
		if database is Resource and _looks_like_database(database) and not seen.has(database.get_instance_id()):
			seen[database.get_instance_id()] = true
			found.append(database)
	return found


func _collect_database_paths(directory: EditorFileSystemDirectory, out: PackedStringArray) -> void:
	if directory == null:
		return
	for index in directory.get_file_count():
		var type_name := directory.get_file_type(index)
		var path := directory.get_file_path(index)
		if type_name == "FlowDatabase" or path.get_file().to_lower().contains("flow_database"):
			out.append(path)
	for index in directory.get_subdir_count():
		_collect_database_paths(directory.get_subdir(index), out)


func _looks_like_database(value: Variant) -> bool:
	return value is Resource and value.has_method(&"get_graph") and (
		value.has_method(&"validate_issues") or value.has_method(&"validate_graphs"))


func _graph_id_in_database(graph: Resource, database: Resource) -> StringName:
	if graph == null or database == null:
		return &""
	for entry: Variant in _array_property(database, &"graphs"):
		if _read_value(entry, &"graph", null) == graph:
			return StringName(str(_read_value(entry, &"graph_id", "")))
	return &""

#endregion


#region Data adapters

func _is_flow_graph(value: Variant) -> bool:
	if not value is Resource:
		return false
	var script: Variant = value.get_script()
	if script != null and script.has_method(&"get_global_name"):
		if StringName(str(script.call(&"get_global_name"))) == &"FlowGraph":
			return true
	return _has_property(value, &"nodes") and _has_property(value, &"connections") \
			and _has_property(value, &"editor_scroll_offset") and _has_property(value, &"editor_zoom")


func _node_id(node: Variant) -> StringName:
	return StringName(str(_read_value(node, &"node_id", "")))


func _node_title(node: Variant) -> String:
	var custom_title := str(_read_value(node, &"title_override", "")).strip_edges()
	if not custom_title.is_empty():
		return custom_title
	var type_id := StringName(str(_call_if_present(node, &"type_id", "")))
	var collection := &""
	var id_property := &""
	var entry_id_property := &""
	var prefix := ""
	match type_id:
		&"play_cutscene":
			collection = &"cutscenes"
			id_property = &"cutscene_id"
			entry_id_property = &"cutscene_id"
			prefix = "Play Cutscene"
		&"preload_level":
			collection = &"levels"
			id_property = &"level_id"
			entry_id_property = &"level_id"
			prefix = "Prepare Level"
		&"load_level":
			collection = &"levels"
			id_property = &"level_id"
			entry_id_property = &"level_id"
			prefix = "Go To Level"
		&"invoke_action":
			collection = &"custom_actions"
			id_property = &"action_id"
			entry_id_property = &"action_id"
			prefix = "Run Game Action"
		&"call_subgraph":
			collection = &"graphs"
			id_property = &"subgraph_id"
			entry_id_property = &"graph_id"
			prefix = "Run Subgraph"
	if not collection.is_empty():
		var selected_id := StringName(str(_read_value(node, id_property, "")))
		var library_name := _library_item_display_name(collection, entry_id_property, selected_id)
		if not library_name.is_empty():
			return "%s: %s" % [prefix, library_name]
	var title := str(_call_if_present(node, &"display_title", "Game Flow Step"))
	return title if not title.is_empty() else "Game Flow Step"


func _node_tooltip(node: Variant) -> String:
	var lines: Array[String] = []
	var catalog_script := _global_class_script(&"FlowNodeCatalog")
	if catalog_script != null and catalog_script.has_method(&"get_descriptor"):
		var type_id := StringName(str(_call_if_present(node, &"type_id", "")))
		var descriptor: Variant = catalog_script.call(&"get_descriptor", type_id)
		var description := str(_read_value(descriptor, &"description", "")).strip_edges()
		if not description.is_empty():
			lines.append(description)
	var designer_note := str(_read_value(node, &"comment", "")).strip_edges()
	if not designer_note.is_empty():
		lines.append("Designer note: %s" % designer_note)
	return "\n".join(lines) if not lines.is_empty() else "Game-flow step"


func _library_item_display_name(
		collection: StringName,
		id_property: StringName,
		selected_id: StringName
) -> String:
	if selected_id.is_empty():
		return ""
	if _active_database != null:
		for entry: Variant in _array_property(_active_database, collection):
			if StringName(str(_read_value(entry, id_property, ""))) != selected_id:
				continue
			var display := str(_read_value(entry, &"display_name", "")).strip_edges()
			if display.is_empty() and collection == &"graphs":
				display = _graph_display_name(_read_value(entry, &"graph", null) as Resource)
			return display if not display.is_empty() else _friendly_authored_name(selected_id)
	return ""


func _friendly_authored_name(authored_name: StringName) -> String:
	return String(authored_name).replace("_", " ").capitalize()


func _port_label(node: Variant, port_id: StringName) -> String:
	if node is Object and node.has_method(&"port_label"):
		var label := str(node.call(&"port_label", port_id))
		if not label.is_empty():
			return label
	return String(port_id).replace("_", " ").capitalize()


func _port_index(node_id: StringName, port_id: StringName, output: bool) -> int:
	var maps: Dictionary = _port_maps.get(node_id, {})
	var ports: Array = maps.get("outputs" if output else "inputs", [])
	return ports.find(port_id)


func _port_id_at(node_id: StringName, index: int, output: bool) -> StringName:
	var maps: Dictionary = _port_maps.get(node_id, {})
	var ports: Array = maps.get("outputs" if output else "inputs", [])
	if index < 0 or index >= ports.size():
		return &""
	return StringName(str(ports[index]))


func _connection_matches(
		connection: Variant,
		from_id: StringName,
		from_port: StringName,
		to_id: StringName,
		to_port: StringName
) -> bool:
	return StringName(str(_read_value(connection, &"from_node_id", ""))) == from_id \
			and StringName(str(_read_value(connection, &"from_port_id", ""))) == from_port \
			and StringName(str(_read_value(connection, &"to_node_id", ""))) == to_id \
			and StringName(str(_read_value(connection, &"to_port_id", ""))) == to_port


func _graph_display_name(graph: Resource) -> String:
	if graph == null:
		return ""
	var display_name := str(_read_value(graph, &"display_name", "")).strip_edges()
	if not display_name.is_empty():
		return display_name
	if not graph.resource_path.is_empty():
		return graph.resource_path.get_file().get_basename().capitalize()
	return "Flow Graph"


func _array_property(object: Variant, property: StringName) -> Array:
	var value := _read_value(object, property, [])
	return value if value is Array else []


func _string_name_array(value: Variant) -> Array[StringName]:
	var out: Array[StringName] = []
	if value is Array:
		for item: Variant in value:
			out.append(StringName(str(item)))
	return out


func _read_value(source: Variant, property: StringName, default_value: Variant) -> Variant:
	if source is Dictionary:
		return source.get(property, source.get(String(property), default_value))
	if source is Object and _has_property(source, property):
		return source.get(property)
	return default_value


func _call_if_present(source: Variant, method: StringName, default_value: Variant) -> Variant:
	return source.call(method) if source is Object and source.has_method(method) else default_value


func _has_property(object: Object, property: StringName) -> bool:
	if object == null:
		return false
	for raw_info: Dictionary in object.get_property_list():
		if StringName(str(raw_info.get("name", ""))) == property:
			return true
	return false


func _global_class_script(class_name_to_find: StringName) -> Script:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if StringName(str(entry.get("class", ""))) != class_name_to_find:
			continue
		var path := str(entry.get("path", ""))
		var script := load(path) if not path.is_empty() else null
		return script as Script
	return null


func _new_global_class_instance(class_name_to_create: StringName) -> Object:
	var script := _global_class_script(class_name_to_create)
	return script.new() if script != null and script.can_instantiate() else null


func _inherits_global_class(candidate: StringName, target: StringName, classes: Array[Dictionary]) -> bool:
	var current := candidate
	var visited: Dictionary = {}
	while not current.is_empty() and not visited.has(current):
		visited[current] = true
		var base := StringName()
		for entry: Dictionary in classes:
			if StringName(str(entry.get("class", ""))) == current:
				base = StringName(str(entry.get("base", "")))
				break
		if base == target:
			return true
		current = base
	return false


func _new_stable_id(prefix: StringName, additional_used: Dictionary = {}) -> StringName:
	var candidate := StringName("%s_%x_%x" % [prefix, Time.get_ticks_usec(), randi()])
	var used: Dictionary = {}
	if _graph != null:
		for node: Variant in _array_property(_graph, &"nodes"):
			used[_node_id(node)] = true
		for connection: Variant in _array_property(_graph, &"connections"):
			used[StringName(str(_read_value(connection, &"connection_id", "")))] = true
	for reserved: Variant in additional_used.keys():
		used[reserved] = true
	while used.has(candidate):
		candidate = StringName("%s_%x_%x" % [prefix, Time.get_ticks_usec(), randi()])
	return candidate

#endregion
