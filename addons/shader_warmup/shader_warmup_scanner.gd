@tool
class_name ShaderWarmupScanner
extends RefCounted

## Finds every material in the project and writes them into a [ShaderWarmupManifest].
##
## Run from the editor by [ShaderWarmupPlugin], and directly from a headless script by calling
## [method scan]. It never instantiates a scene: it reads the [SceneState] of each [PackedScene]
## instead, so no script's [code]_init[/code] runs and scanning has no side effects.
##
## The part that is easy to get wrong: a material is very often [i]not[/i] a node property. In this
## project every single one is assigned to the mesh ([code]BoxMesh.material[/code]), so the node
## property holds a [Mesh] and the material hangs off that. The sky material is further down still,
## behind [code]WorldEnvironment -> Environment -> Sky -> sky_material[/code]. So the harvester
## recurses through resource values rather than only reading properties that are typed [Material].
##
## Alongside the materials it records [i]pairings[/i]: which vertex format each material is
## actually drawn on. A pipeline is keyed on that as well, and the warmup rig draws everything on
## one box. See [ShaderWarmupVertexFormat] for why formats are stored and meshes are not.

## Where the generated manifest is written.
const MANIFEST_PATH := "res://generated/shader_warmup_manifest.tres"

const SCENE_EXTENSIONS: PackedStringArray = ["tscn", "scn"]
const RESOURCE_EXTENSIONS: PackedStringArray = ["tres", "res", "material"]
const SHADER_EXTENSIONS: PackedStringArray = ["gdshader"]

## Directories never scanned. The generated folder is the important one -- harvesting the manifest
## back into itself would double every entry on each rebuild.
const DEFAULT_IGNORES: PackedStringArray = [
	"res://generated/",
	"res://addons/shader_warmup/",
	"res://.godot/",
]

## Guards against a resource graph that loops back on itself through next_pass or a cycle of
## sub-resources.
const MAX_DEPTH := 8

#region State

var _materials: Array[Material] = []
var _labels: PackedStringArray = []
var _sources: PackedStringArray = []
var _environments: Array[Environment] = []
## Dedupe key -> true, for materials already recorded.
var _seen: Dictionary = {}
## Dedupe key -> index into [member _materials], so a pairing can point at the entry a material
## already has rather than storing a second copy of it.
var _material_index: Dictionary = {}
## Distinct (material, vertex format) combinations, as three parallel arrays.
var _pair_material_indices: PackedInt32Array = []
var _pair_vertex_formats: PackedInt64Array = []
var _pair_flags: PackedInt32Array = []
## "index|format|flags" -> true, for pairings already recorded.
var _seen_pairs: Dictionary = {}
## Instance ids of non-material resources already walked, so a mesh shared by 27 nodes is
## inspected once rather than 27 times.
var _walked: Dictionary = {}
## Shader paths already covered by an authored material, so a bare .gdshader file does not add a
## second entry compiling the same program.
var _shader_paths: Dictionary = {}
var _current_source: String = ""
var _skipped: PackedStringArray = []

#endregion

#region Entry Points

## Scans the project and returns a fresh manifest. Writes nothing.
static func scan(extra_ignores: PackedStringArray = PackedStringArray()) -> ShaderWarmupManifest:
	var scanner := ShaderWarmupScanner.new()
	return scanner.build(extra_ignores)

## Scans, then writes the manifest to [constant MANIFEST_PATH] -- but only if its fingerprint
## differs from what is already on disk. Returns whichever manifest is now current.
##
## Skipping the identical write is what keeps the editor plugin's auto-rescan from feeding itself:
## saving the file emits filesystem_changed, which would trigger another scan, which would save
## again, and so on forever.
static func scan_and_save(extra_ignores: PackedStringArray = PackedStringArray()) -> ShaderWarmupManifest:
	var manifest := scan(extra_ignores)

	var existing: ShaderWarmupManifest = null
	if ResourceLoader.exists(MANIFEST_PATH):
		existing = ResourceLoader.load(MANIFEST_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as ShaderWarmupManifest
	if existing != null and existing.fingerprint == manifest.fingerprint:
		return existing

	DirAccess.make_dir_recursive_absolute(MANIFEST_PATH.get_base_dir())
	var error := ResourceSaver.save(manifest, MANIFEST_PATH)
	if error != OK:
		push_error("ShaderWarmupScanner: could not save %s (error %d)" % [MANIFEST_PATH, error])
	return manifest

## A cheap fingerprint of the files a scan would read: paths and modification times, with no
## resource loading at all.
##
## The editor sweeps the filesystem on a timer and emits filesystem_changed each time, so without
## this every sweep would pay for a full project scan. Comparing signatures first reduces the
## common case -- nothing actually changed -- to a directory walk.
static func source_signature(extra_ignores: PackedStringArray = PackedStringArray()) -> String:
	var scanner := ShaderWarmupScanner.new()
	var ignores := DEFAULT_IGNORES.duplicate()
	ignores.append_array(extra_ignores)

	var files := PackedStringArray()
	scanner._collect_files("res://", ignores, files)

	var parts := PackedStringArray()
	for path in files:
		var extension := path.get_extension().to_lower()
		if not (SCENE_EXTENSIONS.has(extension) or RESOURCE_EXTENSIONS.has(extension) or SHADER_EXTENSIONS.has(extension)):
			continue
		parts.append("%s:%d" % [path, FileAccess.get_modified_time(path)])
	parts.sort()
	return "\n".join(parts).sha256_text()

#endregion

#region Scan

func build(extra_ignores: PackedStringArray = PackedStringArray()) -> ShaderWarmupManifest:
	var ignores := DEFAULT_IGNORES.duplicate()
	ignores.append_array(extra_ignores)

	var files := PackedStringArray()
	_collect_files("res://", ignores, files)

	# Scenes and standalone resources first, so that by the time bare .gdshader files are
	# considered, any shader already used by an authored material is known and skipped.
	for path in files:
		var extension := path.get_extension().to_lower()
		if SCENE_EXTENSIONS.has(extension):
			_scan_scene(path)
		elif RESOURCE_EXTENSIONS.has(extension):
			_scan_resource(path)

	for path in files:
		if SHADER_EXTENSIONS.has(path.get_extension().to_lower()):
			_scan_shader(path)

	if not _skipped.is_empty():
		push_warning("ShaderWarmupScanner: skipped %d unreadable file(s): %s" % [
			_skipped.size(), ", ".join(_skipped),
		])

	var manifest := ShaderWarmupManifest.new()
	manifest.materials = _materials
	manifest.labels = _labels
	manifest.sources = _sources
	manifest.environments = _environments
	manifest.pair_material_indices = _pair_material_indices
	manifest.pair_vertex_formats = _pair_vertex_formats
	manifest.pair_flags = _pair_flags
	manifest.generated_at = Time.get_datetime_string_from_system(false, true)
	manifest.fingerprint = _fingerprint()
	return manifest

func _collect_files(directory: String, ignores: PackedStringArray, into: PackedStringArray) -> void:
	if _is_ignored(directory, ignores):
		return
	var dir := DirAccess.open(directory)
	if dir == null:
		return

	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var full := directory.path_join(entry)
		if dir.current_is_dir():
			_collect_files(full + "/", ignores, into)
		else:
			into.append(full)
		entry = dir.get_next()
	dir.list_dir_end()

func _is_ignored(path: String, ignores: PackedStringArray) -> bool:
	for prefix in ignores:
		if path.begins_with(prefix):
			return true
	return false

## Reads a scene's stored node properties without instancing it.
func _scan_scene(path: String) -> void:
	var scene := ResourceLoader.load(path, "PackedScene") as PackedScene
	if scene == null:
		_skipped.append(path)
		return

	var state := scene.get_state()
	if state == null:
		_skipped.append(path)
		return

	_current_source = path
	for node_index in state.get_node_count():
		# Gathered per node rather than harvested one property at a time, because an override
		# material only means something alongside the mesh property sitting next to it.
		var properties := {}
		for property_index in state.get_node_property_count(node_index):
			var property_name := String(state.get_node_property_name(node_index, property_index))
			var value: Variant = state.get_node_property_value(node_index, property_index)
			properties[property_name] = value
			_harvest(value)
		_pair_node_overrides(properties)

func _scan_resource(path: String) -> void:
	var resource := ResourceLoader.load(path)
	if resource == null:
		_skipped.append(path)
		return
	_current_source = path
	_harvest(resource)

## A shader with no material of its own still has to compile. Wrapping it in a throwaway
## ShaderMaterial gives the warmup something it knows how to draw.
func _scan_shader(path: String) -> void:
	if _shader_paths.has(path):
		return
	var shader := ResourceLoader.load(path, "Shader") as Shader
	if shader == null:
		_skipped.append(path)
		return

	var material := ShaderMaterial.new()
	material.shader = shader
	material.resource_name = path.get_file().get_basename()
	_shader_paths[path] = true
	_append(material, material.resource_name, path)

#endregion

#region Harvest

## Pulls every material out of [param value], whatever shape it arrives in.
##
## Deliberately generic. Rather than knowing that a material can be at [code]material_override[/code]
## or [code]surface_material_override/0[/code] or [code]multimesh -> mesh -> material[/code], it
## walks every storage property that holds an object. A material hanging off some node property
## this scanner has never heard of is still found, which is the whole point of the feature.
func _harvest(value: Variant, depth: int = 0) -> void:
	if depth > MAX_DEPTH or value == null:
		return

	if value is Array:
		for element in value:
			_harvest(element, depth + 1)
		return
	if value is Dictionary:
		for key in value:
			_harvest(value[key], depth + 1)
		return

	# Tested rather than cast: most property values are plain data, and "as Resource" on an int or
	# a Vector3 raises an invalid-cast error instead of quietly returning null.
	if not (value is Resource):
		return
	var resource: Resource = value

	if resource is Material:
		_record_material(resource as Material, depth)
		return

	# Walk each carrier only once: a single BoxMesh is referenced by dozens of nodes in this
	# project's test level, and a Theme is a deep graph nobody needs traversed twice.
	var id := resource.get_instance_id()
	if _walked.has(id):
		return
	_walked[id] = true

	if resource is Environment:
		_record_environment(resource as Environment)

	# Mesh and MeshLibrary keep their materials behind an API rather than in properties --
	# ArrayMesh stores surfaces internally, so get_property_list() never reveals them.
	if resource is Mesh:
		_record_mesh_pairings(resource as Mesh, ShaderWarmupManifest.PairFlags.NONE, depth)
	elif resource is MultiMesh:
		# Recorded as instanced pairings in addition to whatever the generic walk below finds on
		# the same mesh, because that is a different draw: the transform arrives from a
		# per-instance buffer rather than from a uniform.
		_record_mesh_pairings((resource as MultiMesh).mesh,
			ShaderWarmupManifest.PairFlags.MULTIMESH, depth)
	elif resource is MeshLibrary:
		var library := resource as MeshLibrary
		for item in library.get_item_list():
			_harvest(library.get_item_mesh(item), depth + 1)

	for property in resource.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_STORAGE == 0:
			continue
		if int(property.type) != TYPE_OBJECT:
			continue
		var property_name := String(property.name)
		if property_name == "script":
			continue
		_harvest(resource.get(property_name), depth + 1)

## Environments are collected whole, not just for their sky. The renderer folds background mode,
## ambient source and fog into a spatial material's compiled form, so the warmup rig has to render
## against the real one or it compiles shaders gameplay never asks for.
func _record_environment(environment: Environment) -> void:
	var copy := environment.duplicate(false) as Environment
	if copy == null:
		return
	# Rebuilt rather than deep-copied: duplicate(true) would clone any panorama texture's pixel
	# data into the manifest, while a shallow copy would leave a link into the source scene.
	if environment.sky != null:
		var sky_copy := environment.sky.duplicate(false) as Sky
		if sky_copy != null:
			if environment.sky.sky_material != null:
				sky_copy.sky_material = _detach(environment.sky.sky_material)
			copy.sky = sky_copy
	_environments.append(copy)

func _record_material(material: Material, depth: int) -> void:
	var key := _key_for(material)
	if _seen.has(key):
		return
	_seen[key] = true

	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader != null and not shader.resource_path.is_empty():
			_shader_paths[shader.resource_path] = true

	# Indexed immediately before the append that gives it that index, so a pairing recorded later
	# points at the right entry. Keep the two lines together.
	_material_index[key] = _materials.size()
	_append(_detach(material), _label_for(material), _current_source)

	# Flattened rather than followed: the chain becomes separate top-level entries, because the
	# copy stored above has had its next_pass cleared to keep it free of links back into the
	# scene it came from.
	_harvest(material.next_pass, depth + 1)

## A standalone copy of [param material], with nothing pointing back at the file it came from.
func _detach(material: Material) -> Material:
	var copy := material.duplicate(false) as Material
	if copy == null:
		# Better a manifest with an external reference in it than a material that never compiles.
		# Returned before anything is written to it -- the original must not be touched.
		push_warning("ShaderWarmupScanner: could not duplicate %s; storing the original." % _label_for(material))
		return material
	copy.next_pass = null
	copy.resource_name = _label_for(material)
	return copy

func _append(material: Material, label: String, source: String) -> void:
	_materials.append(material)
	_labels.append(label)
	_sources.append(source)

## Sub-resources of a scene carry their id after a double colon, which is where names like
## "Mat_Stairs" come from.
func _label_for(material: Material) -> String:
	if material == null:
		return "<none>"
	if not material.resource_name.is_empty():
		return material.resource_name
	var path := material.resource_path
	if path.contains("::"):
		return path.get_slice("::", 1)
	if not path.is_empty():
		return path.get_file()
	return material.get_class()

#endregion

#region Pairings

## Harvests every surface material of [param mesh] and records what vertex format each was found on.
##
## Both halves matter and neither implies the other: the material has to be in the manifest to be
## warmed at all, and the format has to be recorded for it to be warmed on the right geometry.
func _record_mesh_pairings(mesh: Mesh, flags: int, depth: int) -> void:
	if mesh == null:
		return
	for surface in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface)
		if material == null:
			# Nothing to warm: the surface draws with the engine's built-in default, which is not
			# a resource the manifest can carry. A material_override on the node covers this case
			# and is handled in _pair_node_overrides.
			continue
		_harvest(material, depth + 1)
		# Recorded after the harvest, which is what put the material in the index.
		_record_pairing(material, ShaderWarmupVertexFormat.of_surface(mesh, surface), flags)

## Pairs a node's override materials with the mesh they land on.
##
## [param properties] is one node's stored properties from a [SceneState]. The generic harvest has
## already found these materials -- what it cannot know is which mesh they were assigned over, and
## that is the only thing that says what vertex format they will be drawn with. An override applies
## to [i]every[/i] surface, a per-surface override to exactly one.
func _pair_node_overrides(properties: Dictionary) -> void:
	var flags := ShaderWarmupManifest.PairFlags.NONE
	var mesh: Mesh = null
	if properties.get("mesh") is Mesh:
		mesh = properties["mesh"]
	elif properties.get("multimesh") is MultiMesh:
		mesh = (properties["multimesh"] as MultiMesh).mesh
		flags = ShaderWarmupManifest.PairFlags.MULTIMESH
	if mesh == null:
		return

	var formats := PackedInt64Array()
	for surface in mesh.get_surface_count():
		formats.append(ShaderWarmupVertexFormat.of_surface(mesh, surface))
	if formats.is_empty():
		return

	for property_name: String in properties:
		var value: Variant = properties[property_name]
		if not (value is Material):
			continue
		var material: Material = value
		if property_name == "material_override" or property_name == "material_overlay":
			for format in formats:
				_record_pairing(material, format, flags)
		elif property_name.begins_with("surface_material_override/"):
			var surface := property_name.get_slice("/", 1).to_int()
			if surface >= 0 and surface < formats.size():
				_record_pairing(material, formats[surface], flags)

## Notes that [param material] is drawn on [param format]. Deduplicated on the whole triple, so a
## material used on twenty identical boxes is recorded once.
func _record_pairing(material: Material, format: int, flags: int) -> void:
	if material == null or format == 0:
		return
	var key := _key_for(material)
	if not _material_index.has(key):
		# The material was never recorded -- it duplicated badly, or the harvest never reached it.
		# Warming it on the wrong geometry is not an option, so there is nothing useful to store.
		return

	var index: int = _material_index[key]
	var canonical := ShaderWarmupVertexFormat.canonical(format)
	var pair_key := "%d|%d|%d" % [index, canonical, flags]
	if _seen_pairs.has(pair_key):
		return
	_seen_pairs[pair_key] = true

	_pair_material_indices.append(index)
	_pair_vertex_formats.append(canonical)
	_pair_flags.append(flags)

## A material authored inside a scene has a resource path; one built in code has only its instance
## id. Either identifies it for as long as a scan runs.
func _key_for(material: Material) -> String:
	if not material.resource_path.is_empty():
		return material.resource_path
	return str(material.get_instance_id())

#endregion


#region Fingerprint

## Identifies the result of a scan by content, so an unchanged rebuild can skip writing the file.
## Property values are included, not just the material list, or editing a colour would go unnoticed.
func _fingerprint() -> String:
	var context := PackedStringArray()
	for index in _materials.size():
		context.append("%s|%s|%s" % [_sources[index], _labels[index], _digest(_materials[index])])
	# Pairings are part of the fingerprint, not just the material list. Swapping a box for a rigged
	# mesh changes no material at all, and without this the manifest would be judged unchanged and
	# the skinned pairing would never reach disk.
	for index in _pair_material_indices.size():
		context.append("pair|%d|%d|%d" % [
			_pair_material_indices[index], _pair_vertex_formats[index], _pair_flags[index],
		])
	return "\n".join(context).sha256_text()

func _digest(material: Material) -> String:
	if material == null:
		return "null"
	var parts := PackedStringArray([material.get_class()])
	for property in material.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var property_name := String(property.name)
		parts.append("%s=%s" % [property_name, var_to_str(material.get(property_name))])
	return "\n".join(parts).sha256_text()

#endregion
