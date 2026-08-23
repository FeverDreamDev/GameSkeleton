@tool
class_name ShaderWarmupVertexFormat
extends RefCounted

## Reads a mesh surface's vertex format, and builds a throwaway mesh that reproduces it.
##
## A pipeline state object is keyed on more than the material: shaders, render state, render-target
## format, MSAA [i]and the vertex format[/i]. [ShaderWarmup] draws every material on one shared
## [BoxMesh], which covers a project built out of primitives and stops covering it the moment a
## mesh with a different attribute set appears. The case this exists for is a rigged character:
## [constant Mesh.ARRAY_FORMAT_BONES] takes a different vertex-shader path and would hitch on first
## draw while the warmup reported success. That is true on both renderers -- Forward+ compiles a
## different pipeline, Compatibility a different GLSL program, because GLES3 does skinning behind
## its own shader variant.
##
## [b]Formats, not meshes.[/b] An [ArrayMesh] carries its whole vertex buffer, so copying real
## meshes into the generated manifest would bloat it without bound. Only the format bitfield is
## stored, and a proxy is synthesised from it at warmup time. A pipeline keys on the attribute
## [i]layout[/i], not on the vertex data, so a 24-vertex synthetic box with the same attributes
## produces the same pipeline the real character mesh will need.

#region Format Bits

## Attribute slot bits, [constant Mesh.ARRAY_FORMAT_VERTEX] through [constant Mesh.ARRAY_FORMAT_INDEX].
const SLOT_MASK := (1 << (Mesh.ARRAY_INDEX + 1)) - 1

## Where each custom channel's three-bit [enum Mesh.ArrayCustomFormat] sits in the bitfield.
const CUSTOM_SHIFTS: Array[int] = [
	Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT,
	Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT,
	Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT,
	Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT,
]

const CUSTOM_SLOTS: Array[int] = [
	Mesh.ARRAY_FORMAT_CUSTOM0,
	Mesh.ARRAY_FORMAT_CUSTOM1,
	Mesh.ARRAY_FORMAT_CUSTOM2,
	Mesh.ARRAY_FORMAT_CUSTOM3,
]

const CUSTOM_ARRAYS: Array[int] = [
	Mesh.ARRAY_CUSTOM0,
	Mesh.ARRAY_CUSTOM1,
	Mesh.ARRAY_CUSTOM2,
	Mesh.ARRAY_CUSTOM3,
]

## Bytes per vertex for the custom formats stored as a [PackedByteArray].
const CUSTOM_BYTE_STRIDE := {
	Mesh.ARRAY_CUSTOM_RGBA8_UNORM: 4,
	Mesh.ARRAY_CUSTOM_RGBA8_SNORM: 4,
	Mesh.ARRAY_CUSTOM_RG_HALF: 4,
	Mesh.ARRAY_CUSTOM_RGBA_HALF: 8,
}

## Floats per vertex for the custom formats stored as a [PackedFloat32Array].
const CUSTOM_FLOAT_STRIDE := {
	Mesh.ARRAY_CUSTOM_R_FLOAT: 1,
	Mesh.ARRAY_CUSTOM_RG_FLOAT: 2,
	Mesh.ARRAY_CUSTOM_RGB_FLOAT: 3,
	Mesh.ARRAY_CUSTOM_RGBA_FLOAT: 4,
}

const SKIN_MASK := Mesh.ARRAY_FORMAT_BONES | Mesh.ARRAY_FORMAT_WEIGHTS

## Bits worth recording: every attribute slot, every custom channel's format, and the two flags
## that change the vertex layout rather than merely describing it.
##
## Everything else a raw format carries is deliberately dropped. Godot 4.7 sets a version bit at
## 1 << 35 on every surface it builds, and [constant Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE] is a
## storage hint; neither survives a round trip through [method build_mesh], so keeping them would
## make a synthesised proxy's format differ from the one that was recorded.
const FORMAT_MASK := SLOT_MASK \
	| (Mesh.ARRAY_FORMAT_CUSTOM_MASK << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
	| (Mesh.ARRAY_FORMAT_CUSTOM_MASK << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
	| (Mesh.ARRAY_FORMAT_CUSTOM_MASK << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) \
	| (Mesh.ARRAY_FORMAT_CUSTOM_MASK << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT) \
	| Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS \
	| Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES

## The bits that select a different [i]compiled program[/i] rather than only a different vertex
## input layout: skinning is a shader variant on both renderers, and attribute compression changes
## how the vertex shader decodes what it is handed.
##
## Used by [method covered_by] to decide which pairings need a pass of their own. An attribute the
## base proxy simply has more of -- a UV2 the real mesh lacks -- does not change the program.
const VARIANT_MASK := SKIN_MASK \
	| Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS \
	| Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES

#endregion

#region Reading

## The canonical format of [param mesh]'s [param surface], or 0 if it has none.
##
## [method ArrayMesh.surface_get_format] is declared on [ArrayMesh] and not on the [Mesh] base
## class -- verified on 4.7.2, where [BoxMesh] does not have the method at all -- so a
## [PrimitiveMesh] has to be asked through the rendering server instead.
static func of_surface(mesh: Mesh, surface: int) -> int:
	if mesh == null or surface < 0 or surface >= mesh.get_surface_count():
		return 0

	if mesh is ArrayMesh:
		return canonical((mesh as ArrayMesh).surface_get_format(surface))

	var rid := mesh.get_rid()
	if rid.is_valid():
		var built: Dictionary = RenderingServer.mesh_get_surface(rid, surface)
		if built.has("format"):
			return canonical(int(built["format"]))

	return canonical(_derive_from_arrays(mesh, surface))

## Last resort for a [Mesh] subclass with neither a format accessor nor a live RID: infer the
## format from which array slots came back populated. Cannot see the compression or eight-bone
## flags, but nothing that reaches this path has them.
static func _derive_from_arrays(mesh: Mesh, surface: int) -> int:
	var arrays: Array = mesh.surface_get_arrays(surface)
	if arrays.size() < Mesh.ARRAY_MAX:
		return 0
	var format := 0
	for slot in Mesh.ARRAY_MAX:
		if _is_populated(arrays[slot]):
			format |= 1 << slot
	return format

## True for a packed array slot that actually carries data. Written as a type switch because the
## array slots hold six different packed types and a bare truthiness test would accept an object.
static func _is_populated(value: Variant) -> bool:
	match typeof(value):
		TYPE_PACKED_VECTOR3_ARRAY:
			return not (value as PackedVector3Array).is_empty()
		TYPE_PACKED_VECTOR2_ARRAY:
			return not (value as PackedVector2Array).is_empty()
		TYPE_PACKED_FLOAT32_ARRAY:
			return not (value as PackedFloat32Array).is_empty()
		TYPE_PACKED_INT32_ARRAY:
			return not (value as PackedInt32Array).is_empty()
		TYPE_PACKED_COLOR_ARRAY:
			return not (value as PackedColorArray).is_empty()
		TYPE_PACKED_BYTE_ARRAY:
			return not (value as PackedByteArray).is_empty()
	return false

## Strips a raw format down to the bits [method build_mesh] can reproduce, and settles the two
## cases where the engine's own storage rules would otherwise make an identical mesh compare unequal.
static func canonical(raw: int) -> int:
	var format := raw & FORMAT_MASK
	if format & Mesh.ARRAY_FORMAT_VERTEX == 0:
		return 0

	# Normals and tangents share one packed attribute, so a surface built with normals alone reads
	# back as having both. Setting the bit here rather than discovering the mismatch later is what
	# keeps a synthesised proxy's format equal to the recorded one.
	if format & Mesh.ARRAY_FORMAT_NORMAL:
		format |= Mesh.ARRAY_FORMAT_TANGENT

	# Half a skinning pair cannot be drawn skinned, and would make build_mesh emit a surface the
	# renderer rejects.
	if format & SKIN_MASK != SKIN_MASK:
		format &= ~(SKIN_MASK | Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)

	return format

## Whether drawing on a [param base] mesh already compiles what [param wanted] would.
##
## With [param strict] the formats must be identical, which is what a pipeline state object really
## keys on. Otherwise only the variant-selecting bits have to match and the rest may be a subset:
## a material drawn on a box that carries a UV2 the real mesh does not have compiles the same
## program, and paying a frame to prove it again is waste. See [constant VARIANT_MASK].
static func covered_by(base: int, wanted: int, strict: bool) -> bool:
	if wanted == 0:
		return true
	if strict:
		return base == wanted
	if base & VARIANT_MASK != wanted & VARIANT_MASK:
		return false
	return wanted & ~base == 0

static func is_skinned(format: int) -> bool:
	return format & SKIN_MASK == SKIN_MASK

## How many bone indices and weights each vertex carries.
static func bones_per_vertex(format: int) -> int:
	return 8 if format & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else 4

#endregion

#region Building

## Size of the synthesised proxy, matching the boxes [ShaderWarmup] already draws materials on so
## that a pairing pass frames the same way as an ordinary one.
const PROXY_SIZE := Vector3(0.6, 0.6, 0.6)

## The mesh every material is drawn on when nothing said otherwise. Its format is the baseline
## [method covered_by] measures against.
static func base_mesh() -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = PROXY_SIZE
	mesh.add_uv2 = true
	return mesh

static func base_format() -> int:
	return of_surface(base_mesh(), 0)

## A minimal mesh carrying exactly the attributes [param format] names, or null if it names none.
##
## Built by taking a real box apart rather than emitting geometry by hand: the box already supplies
## positions, normals, tangents and both UV sets across 24 vertices and six faces, so the proxy is
## guaranteed to rasterize and to have faces both facing and turned away from every light. Slots
## the format does not ask for are dropped, and the ones a box has no opinion about -- colour,
## skinning, custom channels -- are synthesised at the right width.
static func build_mesh(format: int) -> ArrayMesh:
	if format & Mesh.ARRAY_FORMAT_VERTEX == 0:
		return null

	var arrays: Array = base_mesh().surface_get_arrays(0)
	if arrays.size() < Mesh.ARRAY_MAX:
		return null
	var vertex_count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()

	for slot: int in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX]:
		if format & (1 << slot) == 0:
			arrays[slot] = null

	if format & Mesh.ARRAY_FORMAT_COLOR:
		var colors := PackedColorArray()
		colors.resize(vertex_count)
		colors.fill(Color.WHITE)
		arrays[Mesh.ARRAY_COLOR] = colors

	if is_skinned(format):
		_fill_skin(arrays, vertex_count, bones_per_vertex(format))

	for channel in CUSTOM_SLOTS.size():
		if format & CUSTOM_SLOTS[channel] == 0:
			continue
		var custom: Variant = _build_custom(format, channel, vertex_count)
		if custom == null:
			push_warning("ShaderWarmupVertexFormat: custom channel %d names no buildable format; the proxy will compile without it." % channel)
			continue
		arrays[CUSTOM_ARRAYS[channel]] = custom

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, _flags_for(format))
	return mesh

## Every vertex bound rigidly to bone 0. The pipeline keys on the attribute widths, not on which
## bone a weight points at, so one bone drawn at rest compiles what a real rig will need.
static func _fill_skin(arrays: Array, vertex_count: int, bones_per: int) -> void:
	var bones := PackedInt32Array()
	bones.resize(vertex_count * bones_per)
	bones.fill(0)
	var weights := PackedFloat32Array()
	weights.resize(vertex_count * bones_per)
	weights.fill(0.0)
	for vertex in vertex_count:
		weights[vertex * bones_per] = 1.0
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights

static func _build_custom(format: int, channel: int, vertex_count: int) -> Variant:
	var custom_format := (format >> CUSTOM_SHIFTS[channel]) & Mesh.ARRAY_FORMAT_CUSTOM_MASK
	if CUSTOM_BYTE_STRIDE.has(custom_format):
		var bytes := PackedByteArray()
		bytes.resize(vertex_count * int(CUSTOM_BYTE_STRIDE[custom_format]))
		bytes.fill(0)
		return bytes
	if CUSTOM_FLOAT_STRIDE.has(custom_format):
		var floats := PackedFloat32Array()
		floats.resize(vertex_count * int(CUSTOM_FLOAT_STRIDE[custom_format]))
		floats.fill(0.0)
		return floats
	return null

## The subset of [param format] that goes in the flags argument of
## [method ArrayMesh.add_surface_from_arrays] rather than being implied by which arrays are filled.
static func _flags_for(format: int) -> int:
	var flags := format & (Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS | Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
	for channel in CUSTOM_SLOTS.size():
		if format & CUSTOM_SLOTS[channel]:
			flags |= ((format >> CUSTOM_SHIFTS[channel]) & Mesh.ARRAY_FORMAT_CUSTOM_MASK) << CUSTOM_SHIFTS[channel]
	return flags

#endregion

#region Describing

## A short phrase naming what makes [param format] worth its own pass, for the boot readout.
static func describe(format: int) -> String:
	var parts := PackedStringArray()
	if is_skinned(format):
		parts.append("skinned x8" if format & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else "skinned")
	if format & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES:
		parts.append("compressed")
	if format & Mesh.ARRAY_FORMAT_COLOR:
		parts.append("vertex colour")
	for channel in CUSTOM_SLOTS.size():
		if format & CUSTOM_SLOTS[channel]:
			parts.append("custom%d" % channel)
	if parts.is_empty():
		parts.append("format %d" % format)
	return ", ".join(parts)

#endregion
