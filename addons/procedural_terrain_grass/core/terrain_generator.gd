@tool
# Stateless helpers shared by the streaming manager and the incremental mesh
# builder in terrain_build_state.gd. Nothing here touches the scene tree, so it
# is safe to call from a WorkerThreadPool task.
extends RefCounted

const FINE_MASK_SUBDIVISIONS := 4
const FINE_MASK_BYTES_PER_CELL := 2
const FULL_FINE_MASK := 0xffff

## Number of grass shell MultiMesh resources cached per chunk, one per LOD band.
const GRASS_LOD_VARIANT_COUNT := 3

## Floats one MultiMesh instance occupies in [member MultiMesh.buffer] for
## TRANSFORM_3D with custom data and no colours: twelve for the transform, four
## for INSTANCE_CUSTOM. Verified against 4.7.2 rather than assumed.
const GRASS_INSTANCE_STRIDE := 16


static func create_noise(settings: Dictionary) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = int(settings["seed"])
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = float(settings["noise_frequency"])
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = int(settings["noise_octaves"])
	noise.fractal_lacunarity = float(settings["noise_lacunarity"])
	noise.fractal_gain = float(settings["noise_gain"])
	return noise


static func sample_height(noise: FastNoiseLite, world_x: float, world_z: float, settings: Dictionary) -> float:
	return noise.get_noise_2d(world_x, world_z) * float(settings["height_amplitude"])


static func grass_shell_layer_sets(settings: Dictionary) -> Array[PackedFloat32Array]:
	return [
		_make_shell_layers(int(settings["near_shell_count"]), 1.0),
		_make_shell_layers(int(settings["medium_shell_count"]), 0.95),
		_make_shell_layers(int(settings["far_shell_count"]), float(settings["far_shell_top"])),
	]


## Shell heights for one LOD variant, emitted canopy-first.
##
## The order is the draw order: MultiMesh instances rasterize in buffer order,
## and Godot's opaque sort works per GeometryInstance3D, so it cannot reorder
## shells inside one chunk. Emitting the canopy first puts the shells nearest a
## camera above the field in front, which is what lets the depth prepass reject
## the shells underneath before their fragment shader runs. Ground-first is the
## same picture drawn in the worst possible order -- every shell fully shaded,
## nothing ever occluded.
##
## The set of heights is unchanged, so every shell still lands at exactly the
## height it did before; only the sequence differs. Two shells never share a
## depth, so there is no ordering ambiguity to resolve.
static func _make_shell_layers(count: int, maximum: float) -> PackedFloat32Array:
	var layers := PackedFloat32Array()
	layers.resize(count)
	var last := maxi(count - 1, 1)
	for index in range(count):
		layers[index] = maximum * float(last - index) / float(last)
	return layers


## A shell fraction as the shell shader has always actually received it.
##
## The duplicated-shell architecture wrote the fraction into ARRAY_COLOR.r, and
## Godot stores a vertex colour as unorm8 by TRUNCATING: the byte is
## floor(f * 255.0), not the nearest one. Measured on 4.7.2, where an authored
## 0.25 comes back as 63/255 and not 64/255. The shader therefore never saw the
## authored float, and reproducing that byte exactly -- rather than handing the
## instanced path a freshly rounded float -- is what makes the two architectures
## render the same pixels.
##
## See [method shell_fraction_quantized] for why the byte is decoded here rather
## than in the shader.
static func shell_fraction_byte(fraction: float) -> int:
	return clampi(int(clampf(fraction, 0.0, 1.0) * 255.0), 0, 255)


## The shell fraction the shader reads, decoded from its 8-bit form here rather
## than in GLSL.
##
## Dividing by 255.0 in the shader is not the same operation the vertex fetch
## performed: a shader compiler is free to fold a division by a constant into a
## multiply by its reciprocal, and 1/255 is not exactly representable, so a
## handful of shells came back one ULP off. That is invisible in the shell height
## itself and not invisible at a blade silhouette, where it flips the
## edge_coverage and random_height discards on isolated fragments -- 187 pixels
## of a 2560x1440 frame, measured.
##
## float32(byte / 255.0) computed in double precision is exactly the float the
## hardware produces when it decodes a unorm8 vertex colour, so handing the
## shader the finished value and doing no arithmetic on it reproduces the
## duplicated-shell output bit for bit.
static func shell_fraction_quantized(fraction: float) -> float:
	return float(shell_fraction_byte(fraction)) / 255.0


## Whether shell instance data has to travel as the raw 0-255 byte rather than
## as the finished fraction, and the constant the shader multiplies it back by.
##
## Forward+ keeps MultiMesh instance custom data at float32, so the finished
## fraction travels as-is and the shader multiplies it by exactly one. That is
## exact, which is what makes the instanced canopy bit-identical to the
## duplicated-shell one it replaced -- verified at 0 of 3,686,400 differing
## pixels. The byte encoding existed for the Compatibility renderer, which packed
## custom data into float16; the pair is kept as a named contract so the
## shader-side scale can never drift from the encoding.
static func shell_data_is_byte_encoded() -> bool:
	return false


## Value for the shader's u_shell_decode_scale, paired with the encoding above.
static func shell_decode_scale() -> float:
	return 1.0 / 255.0 if shell_data_is_byte_encoded() else 1.0


## One [member MultiMesh.buffer] payload per LOD variant: identity transforms
## and the encoded shell level in INSTANCE_CUSTOM.x.
##
## The shell distribution depends only on the settings, so every chunk's three
## MultiMesh resources share these three buffers. Built through a throwaway
## MultiMesh rather than by packing floats by hand, so the transform layout comes
## from the engine instead of from an assumption about it.
##
## Main thread only: MultiMesh instance data lives in the rendering server.
static func grass_shell_instance_buffers(settings: Dictionary) -> Array[PackedFloat32Array]:
	var buffers: Array[PackedFloat32Array] = []
	var byte_encoded := shell_data_is_byte_encoded()
	for layers in grass_shell_layer_sets(settings):
		var template := MultiMesh.new()
		template.transform_format = MultiMesh.TRANSFORM_3D
		template.use_custom_data = true
		# A MultiMesh rebuilds its bounds from the base mesh whenever instance
		# data changes and errors when it has none. These templates exist only to
		# have the engine lay their buffer out, never to be drawn, so an empty
		# placeholder is all the base they need.
		template.mesh = PlaceholderMesh.new()
		template.instance_count = layers.size()
		for index in range(layers.size()):
			# Identity, deliberately. A shell is lifted along each terrain vertex
			# normal inside the shader, so translating the instance would both
			# flatten the canopy on slopes and rotate the normals lighting reads.
			template.set_instance_transform(index, Transform3D.IDENTITY)
			var encoded := (float(shell_fraction_byte(layers[index])) if byte_encoded
				else shell_fraction_quantized(layers[index]))
			template.set_instance_custom_data(index, Color(encoded, 0.0, 0.0, 0.0))
		buffers.append(template.buffer)
	return buffers


static func mask_get(mask: PackedByteArray, cell_index: int) -> bool:
	return (mask[cell_index >> 3] & (1 << (cell_index & 7))) != 0


static func mask_set(mask: PackedByteArray, cell_index: int, allowed: bool) -> void:
	var byte_index := cell_index >> 3
	var bit := 1 << (cell_index & 7)
	if allowed:
		mask[byte_index] = mask[byte_index] | bit
	else:
		mask[byte_index] = mask[byte_index] & (~bit & 0xff)


static func fine_mask_get(mask: PackedByteArray, cell_index: int) -> int:
	var byte_index := cell_index * FINE_MASK_BYTES_PER_CELL
	if byte_index + 1 >= mask.size():
		return FULL_FINE_MASK
	return int(mask[byte_index]) | (int(mask[byte_index + 1]) << 8)


static func fine_mask_set(mask: PackedByteArray, cell_index: int, value: int) -> void:
	var byte_index := cell_index * FINE_MASK_BYTES_PER_CELL
	mask[byte_index] = value & 0xff
	mask[byte_index + 1] = (value >> 8) & 0xff


static func fine_mask_set_subcell(mask: PackedByteArray, cell_index: int, subcell_index: int, allowed: bool) -> void:
	var value := fine_mask_get(mask, cell_index)
	var bit := 1 << subcell_index
	if allowed:
		value |= bit
	else:
		value &= ~bit
	fine_mask_set(mask, cell_index, value)


static func mask_byte_count(resolution: int) -> int:
	return ceili(float(resolution * resolution) / 8.0)


# Baked into ARRAY_COLOR and read straight out as ALBEDO by terrain.gdshader, or
# multiplied into a white diffuse_color by BlinnPhong.gdshader.
#
# ARRAY_COLOR is NOT sRGB-decoded by the renderer, and the grass in this same
# add-on depends on that: TerrainBuildState packs exact 8-bit fine-occupancy
# bytes into COLOR.gb and an evenly spaced shell ramp into COLOR.r, and
# grass_shell.gdshader decodes them with int(floor(x * 255.0 + 0.5)). A transfer
# function anywhere on that path would corrupt the mask and bunch the shell
# heights, so COLOR demonstrably arrives raw.
#
# These colours are therefore authored directly in SCENE-LINEAR radiance, unlike
# the grass shader's source_color uniforms, which the compiler linearizes. Do not
# add srgb_to_linear() here, and do not re-author them as sRGB swatches: the
# values are calibrated against measured shell-grass canopy radiance so the
# ground disappears under grass. See TerrainGrass3D.terrain_low_color for the
# measurement method and the residual blue mismatch.
static func terrain_color(height: float, normal_y: float, settings: Dictionary) -> Color:
	var steep_threshold := float(settings["terrain_steep_normal_y"])
	var steep_color: Color = settings["terrain_steep_color"]
	if normal_y < steep_threshold:
		return steep_color.darkened((1.0 - normal_y) * 0.25)
	var color_min := float(settings["terrain_height_color_min"])
	var color_max := float(settings["terrain_height_color_max"])
	var height_t := clampf(inverse_lerp(color_min, color_max, height), 0.0, 1.0)
	height_t = floor(height_t * 6.0) / 6.0
	var low_color: Color = settings["terrain_low_color"]
	var high_color: Color = settings["terrain_high_color"]
	return low_color.lerp(high_color, height_t)
