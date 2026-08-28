class_name UISave
extends RefCounted

## Slot based save file storage: one JSON file per slot, under [member directory].
##
## Every call is static and nothing has to be in the tree, so this works in a headless test and
## in a project that has not added a [UISystem] yet:
##
## [codeblock]
## UISave.save_slot(&"slot_1", {"position": Vector3(1, 2, 3)}, {"label": "Cavern"})
## var data := UISave.load_slot(&"slot_1")
## [/codeblock]
##
## It knows nothing about any particular game. The payload is a plain [Dictionary] the caller
## builds and reads; this file only decides how it reaches the disk and back.
##
## Built-in math types survive the trip -- [Vector3], [Transform3D] and friends are encoded by
## [method JSON.from_native], so callers never flatten them into float arrays by hand. Objects
## are refused in both directions, so a hand edited save file can never instantiate anything.
##
## Nothing here touches a rendering API, which is what makes it behave identically under
## Forward+ and Compatibility.

#region Configuration

## Where slot files live. Anything under [code]user://[/code] works.
static var directory: String = "user://saves"
static var extension: String = ".save"
## How many numbered slots [method list_slots] reports, named [code]slot_1[/code] upwards.
static var slot_count: int = 5
## The slot the game writes to on its own. Listed first, and never one of the numbered slots.
static var autosave_id: StringName = &"autosave"

#endregion

#region Constants

## Bumped when the file layout changes. A file claiming a higher version is refused rather than
## guessed at.
const FORMAT_VERSION := 1

## Header keys, stored at the top level of the file so a slot row costs no payload decoding.
const KEY_FORMAT := "format"
const KEY_SLOT := "slot"
const KEY_UNIX := "saved_unix"
const KEY_TEXT := "saved_text"
const KEY_LABEL := "label"
const KEY_DETAIL := "detail"
const KEY_DATA := "data"

## Extra keys [method describe_slot] adds, which are never written to disk.
const KEY_EXISTS := "exists"
const KEY_CORRUPT := "corrupt"

#endregion

#region State

## Why the last save, load or delete failed, phrased for a dialog. Cleared when one starts.
static var _last_error: String = ""

#endregion

#region Queries

static func slot_path(slot: StringName) -> String:
	return "%s/%s%s" % [directory.trim_suffix("/"), String(slot), extension]

static func has_slot(slot: StringName) -> bool:
	return FileAccess.file_exists(slot_path(slot))

## Every slot this system reports, autosave first.
static func slot_ids() -> Array[StringName]:
	var ids: Array[StringName] = [autosave_id]
	for index in range(1, maxi(slot_count, 0) + 1):
		ids.append(StringName("slot_%d" % index))
	return ids

## One row's worth of information, including for a slot that holds nothing.
## Keys: [code]slot, exists, corrupt, saved_unix, saved_text, label, detail[/code].
static func describe_slot(slot: StringName) -> Dictionary:
	var row := {
		KEY_SLOT: String(slot),
		KEY_EXISTS: false,
		KEY_CORRUPT: false,
		KEY_UNIX: 0,
		KEY_TEXT: "",
		KEY_LABEL: "",
		KEY_DETAIL: "",
	}
	if not has_slot(slot):
		return row

	row[KEY_EXISTS] = true
	var header := read_header(slot)
	if header.is_empty():
		row[KEY_CORRUPT] = true
		return row

	row[KEY_UNIX] = int(header.get(KEY_UNIX, 0))
	row[KEY_TEXT] = String(header.get(KEY_TEXT, ""))
	row[KEY_LABEL] = String(header.get(KEY_LABEL, ""))
	row[KEY_DETAIL] = String(header.get(KEY_DETAIL, ""))
	return row

## Describes every slot in order, ready to build a browser list from.
static func list_slots() -> Array[Dictionary]:
	var previous := _last_error
	var rows: Array[Dictionary] = []
	for slot in slot_ids():
		rows.append(describe_slot(slot))
	# Listing is a query, not an operation -- a corrupt row is reported through its own flag and
	# must not overwrite whatever the last real save or load had to say.
	_last_error = previous
	return rows

## The most recently written readable slot, or an empty name when there is nothing to continue.
static func newest_slot() -> StringName:
	var best: StringName = &""
	var best_time: int = -1
	for row in list_slots():
		if not bool(row[KEY_EXISTS]) or bool(row[KEY_CORRUPT]):
			continue
		var when: int = int(row[KEY_UNIX])
		if when > best_time:
			best_time = when
			best = StringName(row[KEY_SLOT])
	return best

static func has_any() -> bool:
	return not String(newest_slot()).is_empty()

## Why the last save, load or delete failed. Empty after a successful one.
static func last_error() -> String:
	return _last_error

#endregion

#region Writing

## Writes [param data] to [param slot], replacing whatever was there.
##
## [param header] is optional metadata for the slot list: [code]label[/code] names the place,
## [code]detail[/code] is a free line such as a play time. The timestamp is added here.
static func save_slot(slot: StringName, data: Dictionary, header: Dictionary = {}) -> Error:
	_last_error = ""
	if String(slot).is_empty():
		return _fail(ERR_INVALID_PARAMETER, "No slot name was given.")

	var dir_error := DirAccess.make_dir_recursive_absolute(directory)
	if dir_error != OK and dir_error != ERR_ALREADY_EXISTS:
		return _fail(dir_error, "Could not create %s (error %d)." % [directory, dir_error])

	var record := {
		KEY_FORMAT: FORMAT_VERSION,
		KEY_SLOT: String(slot),
		KEY_UNIX: int(Time.get_unix_time_from_system()),
		# Local time, taken now, so the list reads the way the clock did when it was saved. The
		# unix stamp beside it is what ordering uses, since that one is timezone free.
		KEY_TEXT: Time.get_datetime_string_from_system(false, true),
		KEY_LABEL: String(header.get(KEY_LABEL, "")),
		KEY_DETAIL: String(header.get(KEY_DETAIL, "")),
		KEY_DATA: _encode(data),
	}

	return _write_atomic(slot_path(slot), JSON.stringify(record, "\t"))

static func delete_slot(slot: StringName) -> Error:
	_last_error = ""
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return OK
	var error := DirAccess.remove_absolute(path)
	if error != OK:
		return _fail(error, "Could not delete %s (error %d)." % [path, error])
	return OK

## Writes through a temporary file and swaps it into place, keeping the previous file aside until
## the swap succeeds. A save interrupted halfway then costs the new state rather than the old one,
## which is the failure a player can actually recover from.
static func _write_atomic(path: String, text: String) -> Error:
	var temp_path := path + ".tmp"
	var backup_path := path + ".bak"

	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		return _fail(open_error, "Could not open %s (error %d)." % [temp_path, open_error])
	file.store_string(text)
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temp_path)
		return _fail(write_error, "Could not write %s (error %d)." % [temp_path, write_error])

	# Windows will not rename onto an existing file, so the old one has to move aside first
	# rather than simply being overwritten.
	var had_previous := FileAccess.file_exists(path)
	if had_previous:
		if FileAccess.file_exists(backup_path):
			DirAccess.remove_absolute(backup_path)
		var backup_error := DirAccess.rename_absolute(path, backup_path)
		if backup_error != OK:
			DirAccess.remove_absolute(temp_path)
			return _fail(backup_error, "Could not replace %s (error %d)." % [path, backup_error])

	var rename_error := DirAccess.rename_absolute(temp_path, path)
	if rename_error != OK:
		DirAccess.remove_absolute(temp_path)
		if had_previous:
			DirAccess.rename_absolute(backup_path, path)
		return _fail(rename_error, "Could not finish writing %s (error %d)." % [path, rename_error])

	if had_previous:
		DirAccess.remove_absolute(backup_path)
	return OK

#endregion

#region Reading

## The header alone, for building a slot row. Returns an empty dictionary for a slot that is
## missing, unreadable, or written by a format this build does not understand.
static func read_header(slot: StringName) -> Dictionary:
	_last_error = ""
	var record := _read_record(slot)
	if record.is_empty():
		return {}
	# The whole file is parsed to get at the header. Save files are small, and the alternative --
	# a separate index beside them -- is a second thing that can fall out of step with the saves.
	record.erase(KEY_DATA)
	return record

## The payload that was handed to [method save_slot]. Empty on any failure, with the reason in
## [method last_error].
static func load_slot(slot: StringName) -> Dictionary:
	_last_error = ""
	var record := _read_record(slot)
	if record.is_empty():
		return {}
	if not record.has(KEY_DATA):
		_last_error = "%s holds no payload." % slot_path(slot)
		return {}
	return _decode(record[KEY_DATA])

## Reads and validates the file. Every rejection here is a file that exists but cannot be trusted,
## so it is left on disk rather than deleted -- a corrupt save is still evidence.
static func _read_record(slot: StringName) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		_last_error = "There is no save in %s." % String(slot)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var open_error := FileAccess.get_open_error()
		_last_error = "Could not open %s (error %d)." % [path, open_error]
		return {}
	var text := file.get_as_text()
	file.close()

	# An instance rather than JSON.parse_string(): the static call pushes an engine error of its
	# own, so a player with one bad save file would get a stack trace in the log every time the
	# browser drew the list. Here the failure is just a return value, and a better message.
	var json := JSON.new()
	if json.parse(text) != OK:
		_last_error = "%s could not be read (line %d: %s)." % [
			path, json.get_error_line(), json.get_error_message()]
		return {}
	if not json.data is Dictionary:
		_last_error = "%s is not a save file." % path
		return {}

	var record: Dictionary = json.data
	var format := int(record.get(KEY_FORMAT, 0))
	if format <= 0:
		_last_error = "%s is missing its format version." % path
		return {}
	if format > FORMAT_VERSION:
		_last_error = "%s was written by a newer version of the game (format %d)." % [path, format]
		return {}
	return record

#endregion

#region Format

## The two functions that decide the on-disk representation of a payload. Change the format here
## and nothing else has to move.
##
## [method JSON.from_native] is what lets a payload hold a [Vector3] or a [Transform3D] without
## the caller taking it apart first. Both calls pass false for full objects, so an encoded payload
## can never carry a script and a decoded one can never instantiate a class.
static func _encode(data: Dictionary) -> Variant:
	return JSON.from_native(data, false)

static func _decode(raw: Variant) -> Dictionary:
	var value: Variant = JSON.to_native(raw, false)
	if value is Dictionary:
		return value
	_last_error = "The save payload is not a dictionary."
	return {}

#endregion

#region Errors

static func _fail(error: Error, message: String) -> Error:
	_last_error = message
	push_warning("UISave: %s" % message)
	return error if error != OK else FAILED

#endregion
