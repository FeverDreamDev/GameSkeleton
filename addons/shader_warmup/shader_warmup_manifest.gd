@tool
class_name ShaderWarmupManifest
extends Resource

## The generated list of every material in the project that needs warming up.
##
## Written by [ShaderWarmupScanner] in the editor, read by [ShaderWarmup] at boot. Never edit it
## by hand -- the next rebuild overwrites it. To change what ends up in here, change the scanner.
##
## The materials stored here are shallow duplicates of the originals, not references to them. A
## material authored inside a scene has a resource path like [code]res://scenes/test.tscn::Mat_Floor[/code],
## and saving that reference would make loading this manifest pull in every scene it came from.
## A shallow duplicate has no path, so it serialises as a self-contained sub-resource instead.
##
## Duplicating is safe for warmup purposes: Godot keys a [BaseMaterial3D]'s generated shader on
## its feature flags, which [method Resource.duplicate] copies verbatim, and a duplicated
## [ShaderMaterial] points at the very same [Shader]. The copy compiles the same program the
## original would.

## Every material to warm, in scan order.
@export var materials: Array[Material] = []

## The project's own environments. The warmup rig installs the first one, so that materials compile
## against the same background mode, ambient source and fog settings gameplay will use.
##
## This matters more than it looks. [code]test.tscn[/code] renders with a sky background and takes
## its ambient light from that sky, which the renderer treats as part of a spatial material's
## configuration. Warming against a bare default environment would compile one set of shaders and
## leave gameplay to compile another.
@export var environments: Array[Environment] = []

## Display names, parallel to [member materials]. Kept separately because the stored duplicates
## have no resource path left to derive "Mat_Stairs" from.
@export var labels: PackedStringArray = []

## Where each material was found, parallel to [member materials]. Only used to make a surprising
## entry traceable back to the file that produced it.
@export var sources: PackedStringArray = []

## How a pairing is drawn, as distinct from what it is drawn on.
enum PairFlags {
	NONE = 0,
	## Drawn through a [MultiMesh]. Instancing sources the transform from a per-instance buffer,
	## which is a separate pipeline on Forward+ and a separate shader variant on Compatibility.
	MULTIMESH = 1,
	## That [MultiMesh] carries per-instance custom data, which the renderers select with a
	## specialization constant rather than a branch -- so INSTANCE_CUSTOM compiles a program of its
	## own, and warming the plain instanced variant would not cover it.
	MULTIMESH_CUSTOM_DATA = 1 << 1,
	## That [MultiMesh] carries per-instance colours, selected the same way as the above.
	MULTIMESH_COLORS = 1 << 2,
}

## Distinct (material, vertex format) combinations the project actually uses.
##
## Kept as parallel arrays rather than as a struct so the generated [code].tres[/code] stays
## readable in a diff. Each entry indexes into [member materials].
##
## The point of recording these at all: a pipeline is keyed on the vertex format as well as the
## material, and the warmup rig draws everything on one box. That is complete coverage for a
## project built out of primitives and stops being complete the moment a mesh with a different
## attribute set appears -- a rigged character above all, whose bones and weights take a different
## vertex-shader path on both renderers.
@export var pair_material_indices: PackedInt32Array = []

## [enum Mesh.ArrayFormat] bitfield for each pairing above, canonicalised by
## [ShaderWarmupVertexFormat]. Sixty-four bit because Godot 4 puts flags above bit 32.
@export var pair_vertex_formats: PackedInt64Array = []

## [enum PairFlags] for each pairing above.
@export var pair_flags: PackedInt32Array = []

## Timestamp of the last rebuild, for spotting a manifest that has gone stale.
@export var generated_at: String = ""

## Fingerprint of the scan that produced this manifest. The editor plugin compares it against a
## fresh scan and skips writing when they match, so a rebuild that changes nothing does not touch
## the file -- which is what stops the auto-rescan from retriggering itself forever.
@export var fingerprint: String = ""

func size() -> int:
	return materials.size()

## How many (material, vertex format) pairings were recorded. Clamped to the shortest of the three
## parallel arrays, so a hand-edited manifest cannot make the warmup read past the end of one.
func pair_count() -> int:
	return mini(pair_material_indices.size(), mini(pair_vertex_formats.size(), pair_flags.size()))

## The material a pairing refers to, or null if the index does not resolve.
func pair_material(pair_index: int) -> Material:
	if pair_index < 0 or pair_index >= pair_count():
		return null
	var material_index := pair_material_indices[pair_index]
	if material_index < 0 or material_index >= materials.size():
		return null
	return materials[material_index]

## Name for the entry at [param index], falling back to the material's class if the scan did not
## record one.
func label_at(index: int) -> String:
	if index >= 0 and index < labels.size() and not labels[index].is_empty():
		return labels[index]
	if index >= 0 and index < materials.size() and materials[index] != null:
		return materials[index].get_class()
	return "<unknown>"

func source_at(index: int) -> String:
	return sources[index] if index >= 0 and index < sources.size() else ""
