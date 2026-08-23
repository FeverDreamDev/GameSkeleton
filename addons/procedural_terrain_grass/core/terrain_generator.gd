# Stateless helpers shared by the streaming manager and the incremental mesh
# builder in terrain_build_state.gd. Nothing here touches the scene tree, so it
# is safe to call from a WorkerThreadPool task.
extends RefCounted

const FINE_MASK_SUBDIVISIONS := 4
const FINE_MASK_BYTES_PER_CELL := 2
const FULL_FINE_MASK := 0xffff

## Number of grass shell meshes cached per chunk, one per LOD band.
const GRASS_LOD_VARIANT_COUNT := 3


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


static func _make_shell_layers(count: int, maximum: float) -> PackedFloat32Array:
	var layers := PackedFloat32Array()
	layers.resize(count)
	for index in range(count):
		layers[index] = maximum * float(index) / float(maxi(count - 1, 1))
	return layers


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


# Baked into ARRAY_COLOR and read straight out as ALBEDO by terrain.gdshader.
#
# These colours are authored in sRGB and are passed through unconverted, which
# looks like it should clash with grass_shell.gdshader taking its colours via
# `source_color` uniforms. It does not: measured against a StandardMaterial3D
# plate of the same authored colour under identical lighting, the raw vertex
# colour matches, while an srgb_to_linear() conversion here renders roughly
# half as bright. Do not "fix" this without re-measuring.
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
