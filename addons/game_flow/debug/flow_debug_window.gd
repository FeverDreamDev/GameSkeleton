class_name FlowDebugWindow
extends UIWindow

## A development panel showing what the flow system is doing right now.
##
## Built on [UIWindow] rather than on chrome of its own, so it is draggable, themed and disposable
## like anything else on the window layer.
##
## Everything it shows comes from [method FlowSystem.debug_snapshot]. Reading it should answer the
## two questions that cost the most time when a story rule misbehaves: what mode is the game in,
## and what each graph path is waiting for.

## How often the readout is rebuilt. There is no reason to do this every frame.
@export var refresh_interval: float = 0.2

var _readout: Label
var _elapsed: float = 0.0

#region Opening

## Puts a debug window on the window layer and returns it.
static func open() -> FlowDebugWindow:
	var window := FlowDebugWindow.new()
	UISystem.add_window(window)
	return window

#endregion

#region Lifecycle

func _ready() -> void:
	# UIWindow builds its frame in _ready, so the title and the content can only be set once that
	# has happened.
	super()
	window_title = "Flow Debug"
	# The panel is at its most useful while the game is frozen behind a pause menu, so it has to
	# keep updating there.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_readout = Label.new()
	_readout.custom_minimum_size = Vector2(268.0, 0.0)
	_readout.autowrap_mode = TextServer.AUTOWRAP_OFF
	add_content(_readout)

	close_pressed.connect(queue_free)
	position = Vector2(24.0, 24.0)
	_refresh()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < refresh_interval:
		return
	_elapsed = 0.0
	_refresh()

#endregion

#region Readout

func _refresh() -> void:
	if _readout == null:
		return

	var system := FlowSystem.instance
	if system == null:
		_readout.text = "No FlowSystem in the tree."
		return

	var snapshot := system.debug_snapshot()
	var lines := PackedStringArray()

	lines.append(_row("Mode", "%s%s" % [snapshot["mode"], "  [busy]" if snapshot["busy"] else ""]))
	lines.append(_row("Input", "enabled" if snapshot["input"] else "disabled"))
	lines.append(_row("Level", _or_dash(snapshot["level"])))
	lines.append(_row("Spawn", _or_dash(snapshot["spawn"])))

	var loading := String(snapshot["loading"])
	if not loading.is_empty():
		lines.append(_row("Loading", "%s  %d%%" % [loading, int(_loading_progress(system, loading) * 100.0)]))

	lines.append(_row("Cutscene", _or_dash(snapshot["cutscene"])))
	lines.append(_row("Exclusive", "%d queued%s" % [
		int(snapshot.get("exclusive_queued", 0)),
		"  [active]" if snapshot.get("exclusive_active", false) else "",
	]))

	lines.append(_row("Save", _or_dash(snapshot["pending_save"])))

	var warmed := FlowLoader.pending()
	if not warmed.is_empty():
		lines.append(_row("Preloaded", "%d" % warmed.size()))
		for path: String in warmed:
			lines.append("    %s" % path.get_file())

	var flags: Array[StringName] = snapshot["flags"]
	lines.append(_row("Flags", str(flags.size())))
	for flag: StringName in flags:
		lines.append("    %s" % flag)

	var values: Dictionary = snapshot.get("values", {})
	lines.append(_row("Values", str(values.size())))
	var value_names: Array[String] = []
	for key: Variant in values:
		value_names.append(str(key))
	value_names.sort()
	for key in value_names:
		lines.append("    %s = %s" % [key, values.get(StringName(key), values.get(key))])

	var tokens: Array = snapshot.get("graph_tokens", [])
	lines.append(_row("Graph", "%d token(s)%s" % [
		tokens.size(), "  [suspended]" if snapshot.get("graph_suspended", false) else ""]))
	for token: Dictionary in tokens:
		var wait: Dictionary = token.get("wait", {})
		var suffix := ""
		if not wait.is_empty():
			suffix = "  %s" % wait.get("kind", "")
		var stack_names := PackedStringArray()
		for graph_id: StringName in token.get("subgraph_stack", []):
			stack_names.append(String(graph_id))
		var graph_label := " > ".join(stack_names) if not stack_names.is_empty() \
				else String(token.get("graph_id", &""))
		lines.append("    %s/%s  %s%s" % [
			graph_label,
			token.get("node_id", &""),
			token.get("status", &""),
			suffix,
		])

	_readout.text = "\n".join(lines)

func _loading_progress(system: FlowSystem, level_id: String) -> float:
	var entry := system.get_level_entry(StringName(level_id))
	return FlowLoader.progress(entry.scene_path) if entry != null else 0.0

func _row(label: String, value: String) -> String:
	return "%-10s %s" % [label, value]

func _or_dash(value: Variant) -> String:
	var text := str(value)
	return text if not text.is_empty() else "-"

#endregion
