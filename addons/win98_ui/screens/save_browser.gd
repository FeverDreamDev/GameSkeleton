class_name SaveBrowser
extends UIDialog

## The slot list, in Save or Load flavour: a sunken list of every slot over a row of buttons.
##
## It is a [UIDialog], so it inherits the window frame, the click blocking backdrop, Escape
## handling, and the ability to stack -- which is what lets Save open over a [PauseMenu] without
## unfreezing the game underneath.
##
## Like every other screen here it decides nothing. It reads [UISave] to draw the list and reports
## what the player picked; the game does the actual saving and loading:
## [codeblock]
## var browser := SaveBrowser.new()
## browser.mode = SaveBrowser.Mode.LOAD
## browser.slot_chosen.connect(_load_from)
## UISystem.show_modal(browser)
## [/codeblock]

#region Signals

## A slot was picked and confirmed. The browser closes itself immediately afterwards.
signal slot_chosen(slot: StringName)
## Delete was confirmed for this slot. The browser stays open and refreshes once you have acted.
signal slot_delete_requested(slot: StringName)

#endregion

enum Mode {
	## Any slot can be picked, and an occupied one asks before it is overwritten.
	SAVE,
	## Any occupied slot can be picked. An unreadable file is deliberately handed to the game so
	## it can explain the concrete load error instead of leaving a disabled button with no reason.
	LOAD,
}

#region Configuration

@export var mode: Mode = Mode.LOAD

@export_group("Labels")
@export var save_title: String = "Save Game"
@export var load_title: String = "Load Game"
@export_multiline var save_prompt: String = "Choose a slot to save to."
@export_multiline var load_prompt: String = "Choose a save to load."
@export var save_button_text: String = "Save"
@export var load_button_text: String = "Load"
@export var delete_button_text: String = "Delete"
@export var cancel_button_text: String = "Cancel"
## Shown in place of a timestamp for a slot that holds nothing.
@export var empty_text: String = "<empty>"
## Shown for a file that exists but could not be read. The file is never deleted on its own.
@export var corrupt_text: String = "<unreadable>"
@export var autosave_text: String = "Autosave"
## Prefix for the numbered slots, so [code]slot_1[/code] reads as "Slot 1".
@export var slot_text: String = "Slot"

@export_group("Layout")
## How many rows the list shows before it starts scrolling. The height is worked out from this
## rather than set in pixels, so the last visible row is never sliced in half.
@export var max_visible_rows: int = 6
## Width of the left hand column that holds the slot name.
@export var name_column_width: float = 72.0

#endregion

#region Internals

const ID_ACTION := &"action"
const ID_DELETE := &"delete"

## Set on each row button so the handler knows which slot it belongs to without an index.
const META_SLOT := &"ui_save_slot"

const ROW_HEIGHT := 24.0
const ROW_SEPARATION := 2

var _rows_box: VBoxContainer
var _group: ButtonGroup
var _action_button: Button
var _delete_button: Button

var _rows: Array[Dictionary] = []
var _selected_slot: StringName = &""

#endregion

#region Lifecycle

func _init() -> void:
	# The list is the content; a message box icon beside it would only push it off centre.
	show_icon = false
	min_body_width = 340.0
	button_alignment = BoxContainer.ALIGNMENT_END
	# Escape and the title bar X close the browser without choosing anything.
	_has_cancel = true

## The title and prompt are chosen here rather than in [method _init] because they both depend on
## [member mode], which the caller sets after construction.
func _ready() -> void:
	dialog_title = save_title if mode == Mode.SAVE else load_title
	body_text = save_prompt if mode == Mode.SAVE else load_prompt
	super()

#endregion

#region Construction

func _build_body() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)

	var prompt := Label.new()
	prompt.text = body_text
	prompt.custom_minimum_size.x = min_body_width
	column.add_child(prompt)

	column.add_child(_build_slot_list())
	column.add_child(_build_button_row())
	return column

## The sunken white plate a Windows 98 file list sat in. Rows are ordinary [Button]s rather than
## an [ItemList] so they pick up the theme, the click sound and keyboard focus with no extra work.
func _build_slot_list() -> Control:
	var frame := PanelContainer.new()
	frame.theme_type_variation = &"SunkenPanel"

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# The height goes on the scroller rather than the frame, so the sunken border is drawn around
	# a whole number of rows instead of eating into the last one.
	scroll.custom_minimum_size = Vector2(
		min_body_width,
		maxi(max_visible_rows, 1) * (ROW_HEIGHT + ROW_SEPARATION) - ROW_SEPARATION
	)
	frame.add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", ROW_SEPARATION)
	scroll.add_child(_rows_box)

	_populate_rows()
	return frame

## Built here rather than through [member _button_specs] because two of the three buttons change
## their disabled state as the selection moves, and the specs hand back no references.
func _build_button_row() -> Control:
	var row := HBoxContainer.new()
	row.alignment = button_alignment
	row.add_theme_constant_override("separation", 8)

	var action_text := save_button_text if mode == Mode.SAVE else load_button_text
	_action_button = _add_button(row, action_text, _on_action_pressed)
	_delete_button = _add_button(row, delete_button_text, _on_delete_pressed)
	_add_button(row, cancel_button_text, _cancel)

	_update_action_state()
	return row

func _add_button(parent: Control, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.x = button_min_width
	button.pressed.connect(action)
	parent.add_child(button)
	UISystem.bind_button(button)
	return button

#endregion

#region Rows

## Rebuilds the list from disk. Call after something outside the browser changed a slot.
func refresh() -> void:
	if _rows_box == null or not is_instance_valid(_rows_box):
		return
	_populate_rows()

func _populate_rows() -> void:
	for child in _rows_box.get_children():
		# Removed as well as freed: queue_free() alone leaves the old row in the container for the
		# rest of the frame, and a rebuild would briefly show both sets stacked.
		_rows_box.remove_child(child)
		child.queue_free()

	# A fresh group each time, or the freed buttons stay in the old one and nothing is pressable.
	_group = ButtonGroup.new()
	_rows = UISave.list_slots()
	for row in _rows:
		_rows_box.add_child(_build_row(row))

	_selected_slot = &""
	_update_action_state()

func _build_row(row: Dictionary) -> Button:
	var slot := StringName(row[UISave.KEY_SLOT])

	var button := Button.new()
	button.toggle_mode = true
	button.button_group = _group
	button.custom_minimum_size.y = ROW_HEIGHT
	# Which slot a row stands for, readable from outside without reaching into the list order.
	button.set_meta(META_SLOT, slot)
	button.toggled.connect(_on_row_toggled.bind(slot))
	# A file list has always confirmed on a double click, and the buttons at the bottom stay the
	# discoverable way to do the same thing.
	button.gui_input.connect(_on_row_gui_input)
	UISystem.bind_button(button)

	# Two columns rather than padded text: the font is proportional, so spaces would not line the
	# timestamps up. The box ignores the mouse so every click still lands on the button.
	var columns := HBoxContainer.new()
	columns.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	columns.offset_left = 6.0
	columns.offset_right = -6.0
	columns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	columns.add_theme_constant_override("separation", 8)
	button.add_child(columns)

	var name_label := Label.new()
	name_label.text = _slot_display_name(slot)
	name_label.custom_minimum_size.x = name_column_width
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	columns.add_child(name_label)

	var detail_label := Label.new()
	detail_label.text = _row_detail(row)
	detail_label.clip_text = true
	detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	columns.add_child(detail_label)

	return button

func _row_detail(row: Dictionary) -> String:
	if not bool(row[UISave.KEY_EXISTS]):
		return empty_text
	if bool(row[UISave.KEY_CORRUPT]):
		return corrupt_text

	var parts: Array[String] = []
	for key in [UISave.KEY_TEXT, UISave.KEY_LABEL, UISave.KEY_DETAIL]:
		var value := String(row.get(key, ""))
		if not value.is_empty():
			parts.append(value)
	return "   ".join(parts)

func _slot_display_name(slot: StringName) -> String:
	if slot == UISave.autosave_id:
		return autosave_text
	var text := String(slot)
	if text.begins_with("slot_"):
		return "%s %s" % [slot_text, text.trim_prefix("slot_")]
	return text.capitalize()

func _find_row(slot: StringName) -> Dictionary:
	for row in _rows:
		if StringName(row[UISave.KEY_SLOT]) == slot:
			return row
	return {}

#endregion

#region Selection

func _on_row_toggled(pressed: bool, slot: StringName) -> void:
	if not pressed:
		return
	_selected_slot = slot
	_update_action_state()

func _on_row_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
		if _action_button and not _action_button.disabled:
			_on_action_pressed()

func _update_action_state() -> void:
	var row := _find_row(_selected_slot)
	var chosen := not String(_selected_slot).is_empty()
	var occupied := chosen and bool(row.get(UISave.KEY_EXISTS, false))

	if _action_button and is_instance_valid(_action_button):
		# Saving needs only a slot; loading needs an occupied one. Corrupt rows remain actionable so
		# the caller can surface UISave's precise parse/version error in its normal error dialog.
		_action_button.disabled = not chosen if mode == Mode.SAVE else not occupied
	if _delete_button and is_instance_valid(_delete_button):
		_delete_button.disabled = not occupied

#endregion

#region Actions

func _on_action_pressed() -> void:
	if String(_selected_slot).is_empty():
		return
	var slot := _selected_slot

	if mode == Mode.SAVE and bool(_find_row(slot).get(UISave.KEY_EXISTS, false)):
		var prompt := UIDialog.confirm(
			"Overwrite",
			"%s already holds a save.\n\nOverwrite it?" % _slot_display_name(slot),
			"Yes",
			"No"
		)
		if not await UISystem.show_modal(prompt).finished:
			return
		# Awaiting hands control back to the tree, so re-check rather than assuming the browser
		# is still the same one that asked the question.
		if _finished:
			return

	slot_chosen.emit(slot)
	dismiss(true, ID_ACTION)

func _on_delete_pressed() -> void:
	if String(_selected_slot).is_empty():
		return
	var slot := _selected_slot

	var prompt := UIDialog.confirm(
		"Delete",
		"Permanently delete the save in %s?" % _slot_display_name(slot),
		"Yes",
		"No"
	)
	if not await UISystem.show_modal(prompt).finished:
		return
	if _finished:
		return

	slot_delete_requested.emit(slot)
	# Deleting is something you do from the browser rather than a way out of it, so the list is
	# rebuilt in place -- the same reason Settings and Save leave the pause menu standing.
	refresh()

#endregion
