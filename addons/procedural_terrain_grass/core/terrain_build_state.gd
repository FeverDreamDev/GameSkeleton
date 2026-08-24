@tool
extends RefCounted

const TerrainGenerator = preload("res://addons/procedural_terrain_grass/core/terrain_generator.gd")

enum Phase {
	TERRAIN_HALO,
	TERRAIN_VERTICES,
	TERRAIN_INDICES,
	TERRAIN_SLOPES,
	GRASS_PREPARE,
	GRASS_VERTICES,
	GRASS_INDICES,
	DONE,
}

var output: Dictionary = {}

var _kind: StringName
var _coord: Vector2i
var _revision: int
var _settings: Dictionary
var _phase: Phase
var _cursor: int = 0

var _resolution: int
var _width: int
var _spacing: float
var _noise: FastNoiseLite
var _halo_width: int
var _world_origin: Vector2
var _halo := PackedFloat32Array()
var _heights := PackedFloat32Array()
var _normals := PackedVector3Array()
var _vertices := PackedVector3Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()
var _occupancy := PackedByteArray()
var _fine_occupancy := PackedByteArray()
var _minimum_height: float = INF
var _maximum_height: float = -INF

var _grass_layers: Array[PackedFloat32Array] = []
var _grass_variants: Array = []
var _variant_index: int = 0
var _variant_layers := PackedFloat32Array()
var _grass_vertices := PackedVector3Array()
var _grass_normals := PackedVector3Array()
var _grass_colors := PackedColorArray()
var _grass_uvs := PackedVector2Array()
var _grass_indices := PackedInt32Array()
var _grass_index_write: int = 0
var _partial_cells := PackedInt32Array()
var _partial_lookup := PackedInt32Array()


func configure_terrain(coord: Vector2i, revision: int, settings: Dictionary) -> void:
	_kind = &"terrain"
	_coord = coord
	_revision = revision
	_settings = settings
	_resolution = int(settings["resolution"])
	_width = _resolution + 1
	_spacing = float(settings["spacing"])
	_halo_width = _width + 2
	_world_origin = Vector2(
		float(coord.x) * float(settings["chunk_size"]),
		float(coord.y) * float(settings["chunk_size"])
	)
	_noise = TerrainGenerator.create_noise(settings)
	_halo.resize(_halo_width * _halo_width)
	var vertex_count := _width * _width
	_heights.resize(vertex_count)
	_vertices.resize(vertex_count)
	_normals.resize(vertex_count)
	_colors.resize(vertex_count)
	_indices.resize(_resolution * _resolution * 6)
	_occupancy.resize(TerrainGenerator.mask_byte_count(_resolution))
	_occupancy.fill(255)
	_fine_occupancy.resize(_resolution * _resolution * TerrainGenerator.FINE_MASK_BYTES_PER_CELL)
	_fine_occupancy.fill(255)
	_phase = Phase.TERRAIN_HALO


func configure_grass(
	coord: Vector2i,
	revision: int,
	heights: PackedFloat32Array,
	normals: PackedVector3Array,
	occupancy: PackedByteArray,
	fine_occupancy: PackedByteArray,
	settings: Dictionary
) -> void:
	_kind = &"grass"
	_coord = coord
	_revision = revision
	_settings = settings
	_resolution = int(settings["resolution"])
	_width = _resolution + 1
	_spacing = float(settings["spacing"])
	_heights = heights
	_normals = normals
	_occupancy = occupancy
	_fine_occupancy = fine_occupancy
	_partial_cells = PackedInt32Array()
	_partial_lookup = PackedInt32Array()
	_partial_lookup.resize(_resolution * _resolution)
	_partial_lookup.fill(-1)
	for cell_index in range(_resolution * _resolution):
		var fine_mask := TerrainGenerator.fine_mask_get(_fine_occupancy, cell_index)
		if fine_mask != 0 and fine_mask != TerrainGenerator.FULL_FINE_MASK:
			_partial_lookup[cell_index] = _partial_cells.size()
			_partial_cells.append(cell_index)
	_grass_layers = TerrainGenerator.grass_shell_layer_sets(settings)
	_phase = Phase.GRASS_PREPARE


func step(deadline_usec: int) -> bool:
	if _phase == Phase.DONE:
		return true
	var operations := 0
	while _phase != Phase.DONE:
		_step_once()
		operations += 1
		# Checking the clock in small batches keeps timer overhead low while
		# still bounding a single-threaded frame to a few dozen cells.
		if operations >= 32:
			if Time.get_ticks_usec() >= deadline_usec:
				break
			operations = 0
	return _phase == Phase.DONE


func _step_once() -> void:
	match _phase:
		Phase.TERRAIN_HALO:
			_step_terrain_halo()
		Phase.TERRAIN_VERTICES:
			_step_terrain_vertex()
		Phase.TERRAIN_INDICES:
			_step_terrain_index_cell()
		Phase.TERRAIN_SLOPES:
			_step_terrain_slope_cell()
		Phase.GRASS_PREPARE:
			_prepare_grass_variant()
		Phase.GRASS_VERTICES:
			_step_grass_vertex()
		Phase.GRASS_INDICES:
			_step_grass_index_cell()


func _step_terrain_halo() -> void:
	var hx := _cursor % _halo_width
	var hz := floori(float(_cursor) / float(_halo_width))
	var world_x := _world_origin.x + float(hx - 1) * _spacing
	var world_z := _world_origin.y + float(hz - 1) * _spacing
	_halo[_cursor] = TerrainGenerator.sample_height(_noise, world_x, world_z, _settings)
	_cursor += 1
	if _cursor >= _halo.size():
		_cursor = 0
		_phase = Phase.TERRAIN_VERTICES


func _step_terrain_vertex() -> void:
	var x := _cursor % _width
	var z := floori(float(_cursor) / float(_width))
	var halo_index := (z + 1) * _halo_width + x + 1
	var height := _halo[halo_index]
	var normal := Vector3(
		_halo[halo_index - 1] - _halo[halo_index + 1],
		2.0 * _spacing,
		_halo[halo_index - _halo_width] - _halo[halo_index + _halo_width]
	).normalized()
	_heights[_cursor] = height
	_vertices[_cursor] = Vector3(float(x) * _spacing, height, float(z) * _spacing)
	_normals[_cursor] = normal
	_colors[_cursor] = TerrainGenerator.terrain_color(height, normal.y, _settings)
	_minimum_height = minf(_minimum_height, height)
	_maximum_height = maxf(_maximum_height, height)
	_cursor += 1
	if _cursor >= _vertices.size():
		_cursor = 0
		_phase = Phase.TERRAIN_INDICES


func _step_terrain_index_cell() -> void:
	var x := _cursor % _resolution
	var z := floori(float(_cursor) / float(_resolution))
	var i00 := z * _width + x
	var i10 := i00 + 1
	var i01 := i00 + _width
	var i11 := i01 + 1
	var write := _cursor * 6
	_indices[write] = i00
	_indices[write + 1] = i10
	_indices[write + 2] = i01
	_indices[write + 3] = i10
	_indices[write + 4] = i11
	_indices[write + 5] = i01
	_cursor += 1
	if _cursor >= _resolution * _resolution:
		_cursor = 0
		_phase = Phase.TERRAIN_SLOPES


func _step_terrain_slope_cell() -> void:
	var x := _cursor % _resolution
	var z := floori(float(_cursor) / float(_resolution))
	var i00 := z * _width + x
	var average_up := (
		_normals[i00].y
		+ _normals[i00 + 1].y
		+ _normals[i00 + _width].y
		+ _normals[i00 + _width + 1].y
	) * 0.25
	if average_up < float(_settings["max_grass_slope_cos"]):
		TerrainGenerator.mask_set(_occupancy, _cursor, false)
		TerrainGenerator.fine_mask_set(_fine_occupancy, _cursor, 0)
	_cursor += 1
	if _cursor >= _resolution * _resolution:
		_finish_terrain()


func _finish_terrain() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_INDEX] = _indices
	output = {
		"coord": _coord,
		"revision": _revision,
		"arrays": arrays,
		"heights": _heights,
		"normals": _normals,
		"occupancy": _occupancy,
		"fine_occupancy": _fine_occupancy,
		"min_height": _minimum_height,
		"max_height": _maximum_height,
	}
	_phase = Phase.DONE


func _prepare_grass_variant() -> void:
	_variant_layers = _grass_layers[_variant_index]
	var base_vertex_count := _width * _width
	var shared_vertex_count := base_vertex_count * _variant_layers.size()
	var partial_vertex_count := _partial_cells.size() * 4 * _variant_layers.size()
	var vertex_count := shared_vertex_count + partial_vertex_count
	_grass_vertices = PackedVector3Array()
	_grass_normals = PackedVector3Array()
	_grass_colors = PackedColorArray()
	_grass_uvs = PackedVector2Array()
	_grass_indices = PackedInt32Array()
	_grass_vertices.resize(vertex_count)
	_grass_normals.resize(vertex_count)
	_grass_colors.resize(vertex_count)
	_grass_uvs.resize(vertex_count)
	_grass_indices.resize(_variant_layers.size() * _resolution * _resolution * 6)
	_grass_index_write = 0
	_cursor = 0
	_phase = Phase.GRASS_VERTICES


func _step_grass_vertex() -> void:
	var base_vertex_count := _width * _width
	var shared_vertex_count := base_vertex_count * _variant_layers.size()
	if _cursor < shared_vertex_count:
		var layer_index := floori(float(_cursor) / float(base_vertex_count))
		var source_index := _cursor % base_vertex_count
		var x := source_index % _width
		var z := floori(float(source_index) / float(_width))
		_grass_vertices[_cursor] = Vector3(float(x) * _spacing, _heights[source_index], float(z) * _spacing)
		_grass_normals[_cursor] = _normals[source_index]
		_grass_colors[_cursor] = Color(_variant_layers[layer_index], 1.0, 1.0, 1.0)
		_grass_uvs[_cursor] = Vector2.ZERO
	else:
		var local_cursor := _cursor - shared_vertex_count
		var partial_vertices_per_layer := _partial_cells.size() * 4
		var layer_index := floori(float(local_cursor) / float(partial_vertices_per_layer))
		var within_layer := local_cursor % partial_vertices_per_layer
		var partial_index := floori(float(within_layer) / 4.0)
		var corner := within_layer % 4
		var cell_index := _partial_cells[partial_index]
		var x := cell_index % _resolution
		var z := floori(float(cell_index) / float(_resolution))
		var source_index := (z + (corner >> 1)) * _width + x + (corner & 1)
		var fine_mask := TerrainGenerator.fine_mask_get(_fine_occupancy, cell_index)
		_grass_vertices[_cursor] = Vector3(
			float(x + (corner & 1)) * _spacing,
			_heights[source_index],
			float(z + (corner >> 1)) * _spacing
		)
		_grass_normals[_cursor] = _normals[source_index]
		_grass_colors[_cursor] = Color(
			_variant_layers[layer_index],
			float(fine_mask & 0xff) / 255.0,
			float((fine_mask >> 8) & 0xff) / 255.0,
			1.0
		)
		_grass_uvs[_cursor] = Vector2(float(corner & 1), float(corner >> 1))
	_cursor += 1
	if _cursor >= _grass_vertices.size():
		_cursor = 0
		_phase = Phase.GRASS_INDICES


func _step_grass_index_cell() -> void:
	var cells_per_layer := _resolution * _resolution
	var layer_index := floori(float(_cursor) / float(cells_per_layer))
	var cell_index := _cursor % cells_per_layer
	var fine_mask := TerrainGenerator.fine_mask_get(_fine_occupancy, cell_index)
	if TerrainGenerator.mask_get(_occupancy, cell_index) and fine_mask != 0:
		var x := cell_index % _resolution
		var z := floori(float(cell_index) / float(_resolution))
		var i00: int
		var i10: int
		var i01: int
		var i11: int
		if fine_mask == TerrainGenerator.FULL_FINE_MASK:
			i00 = layer_index * _width * _width + z * _width + x
			i10 = i00 + 1
			i01 = i00 + _width
			i11 = i01 + 1
		else:
			var shared_vertex_count := _width * _width * _variant_layers.size()
			var partial_index := _partial_lookup[cell_index]
			i00 = shared_vertex_count + layer_index * _partial_cells.size() * 4 + partial_index * 4
			i10 = i00 + 1
			i01 = i00 + 2
			i11 = i00 + 3
		_grass_indices[_grass_index_write] = i00
		_grass_indices[_grass_index_write + 1] = i10
		_grass_indices[_grass_index_write + 2] = i01
		_grass_indices[_grass_index_write + 3] = i10
		_grass_indices[_grass_index_write + 4] = i11
		_grass_indices[_grass_index_write + 5] = i01
		_grass_index_write += 6
	_cursor += 1
	if _cursor >= _variant_layers.size() * cells_per_layer:
		_finish_grass_variant()


func _finish_grass_variant() -> void:
	_grass_indices.resize(_grass_index_write)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _grass_vertices
	arrays[Mesh.ARRAY_NORMAL] = _grass_normals
	arrays[Mesh.ARRAY_COLOR] = _grass_colors
	arrays[Mesh.ARRAY_TEX_UV] = _grass_uvs
	arrays[Mesh.ARRAY_INDEX] = _grass_indices
	_grass_variants.append(arrays)
	_variant_index += 1
	if _variant_index < _grass_layers.size():
		_phase = Phase.GRASS_PREPARE
	else:
		output = {"coord": _coord, "revision": _revision, "variants": _grass_variants}
		_phase = Phase.DONE
