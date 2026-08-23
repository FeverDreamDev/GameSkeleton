@tool
extends EditorExportPlugin

## Rebuilds the warmup manifest at the start of an export.
##
## Without this, a manifest left stale by a forgotten rebuild ships quietly and the missing shaders
## only turn up as hitches on someone else's machine.

func _get_name() -> String:
	return "ShaderWarmup"

func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var manifest := ShaderWarmupScanner.scan_and_save()
	if manifest != null:
		print("Shader Warmup: manifest checked before export (%d materials, %d pairings)." % [
			manifest.size(), manifest.pair_count(),
		])

## Belt and braces for the case where the export file list was taken before [method _export_begin]
## ran: whatever is on disk now is what gets packed, replacing the copy the exporter picked up.
func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path != ShaderWarmupScanner.MANIFEST_PATH:
		return
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return
	skip()
	add_file(path, bytes, false)
