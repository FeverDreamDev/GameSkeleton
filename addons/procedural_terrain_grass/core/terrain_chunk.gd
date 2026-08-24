@tool
# One streamed terrain tile: a terrain mesh, a heightmap collider, and the three
# cached grass shell meshes the LOD bands switch between.
extends Node3D

const TerrainGenerator = preload("res://addons/procedural_terrain_grass/core/terrain_generator.gd")

const LOD_NEAR := 0
const LOD_MEDIUM := 1
const LOD_FAR := 2
const LOD_HIDDEN := 3

## Slack added on top of the grass AABB so shells are not culled at the moment
## they bend outside the terrain surface.
const CULL_MARGIN_SLACK := 0.25

var coord: Vector2i
var generation_revision: int = 0
var grass_revision: int = 0
var terrain_ready: bool = false
var grass_ready: bool = false
var current_lod: int = LOD_HIDDEN
var heights := PackedFloat32Array()
var normals := PackedVector3Array()
var base_occupancy := PackedByteArray()
var occupancy := PackedByteArray()
var base_fine_occupancy := PackedByteArray()
var fine_occupancy := PackedByteArray()
var minimum_height: float = 0.0
var maximum_height: float = 0.0
var grass_meshes: Array[ArrayMesh] = []

var terrain_mesh_instance: MeshInstance3D
var grass_mesh_instance: MeshInstance3D
var terrain_body: StaticBody3D
var terrain_collision: CollisionShape3D
var _settings
var _terrain_material: Material


func configure(
	chunk_coord: Vector2i,
	revision: int,
	settings,
	terrain_material: Material,
	grass_material: Material
) -> void:
	coord = chunk_coord
	generation_revision = revision
	grass_revision = revision
	_settings = settings
	_terrain_material = terrain_material
	name = "TerrainChunk_%d_%d" % [coord.x, coord.y]
	position = Vector3(float(coord.x) * settings.chunk_size, 0.0, float(coord.y) * settings.chunk_size)

	grass_mesh_instance = MeshInstance3D.new()
	grass_mesh_instance.name = "GrassMesh"
	grass_mesh_instance.material_override = grass_material
	# Shell grass is many overlapping layers; casting shadows from all of them
	# costs far more than the result is worth at this density.
	grass_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grass_mesh_instance.visible = false
	grass_mesh_instance.extra_cull_margin = settings.grass_height + CULL_MARGIN_SLACK
	add_child(grass_mesh_instance)

	terrain_body = StaticBody3D.new()
	terrain_body.name = "StaticBody3D"
	terrain_body.collision_layer = settings.terrain_collision_layer
	terrain_body.collision_mask = settings.terrain_collision_mask
	terrain_collision = CollisionShape3D.new()
	terrain_collision.name = "CollisionShape3D"
	terrain_collision.position = Vector3(settings.chunk_size * 0.5, 0.0, settings.chunk_size * 0.5)
	terrain_collision.scale = Vector3(settings.cell_spacing(), 1.0, settings.cell_spacing())
	terrain_body.add_child(terrain_collision)
	add_child(terrain_body)


func apply_terrain(result: Dictionary) -> void:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, result["arrays"])
	# Publish the managed node only after its mesh, material, shadow mode and
	# groups are complete. Streamed RT collectors observe node_added; exposing a
	# null-mesh placeholder earlier would make the later assignment invisible to
	# that topology signal.
	terrain_mesh_instance = MeshInstance3D.new()
	terrain_mesh_instance.name = "TerrainMesh"
	terrain_mesh_instance.mesh = mesh
	terrain_mesh_instance.material_override = _terrain_material
	terrain_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if not _settings.terrain_mesh_group.is_empty():
		terrain_mesh_instance.add_to_group(_settings.terrain_mesh_group)
	if not _settings.terrain_receiver_only_group.is_empty():
		terrain_mesh_instance.add_to_group(_settings.terrain_receiver_only_group)
	add_child(terrain_mesh_instance)
	heights = result["heights"]
	normals = result["normals"]
	base_occupancy = result["occupancy"]
	occupancy = base_occupancy.duplicate()
	base_fine_occupancy = result["fine_occupancy"]
	fine_occupancy = base_fine_occupancy.duplicate()
	minimum_height = float(result["min_height"])
	maximum_height = float(result["max_height"])

	var height_shape := HeightMapShape3D.new()
	height_shape.map_width = _settings.chunk_resolution + 1
	height_shape.map_depth = _settings.chunk_resolution + 1
	height_shape.map_data = heights
	terrain_collision.shape = height_shape
	terrain_ready = true

	var chunk_extent := float(_settings.chunk_size)
	terrain_mesh_instance.custom_aabb = AABB(
		Vector3(0.0, minimum_height - 0.5, 0.0),
		Vector3(chunk_extent, maximum_height - minimum_height + 1.0, chunk_extent)
	)
	grass_mesh_instance.custom_aabb = AABB(
		Vector3(-1.0, minimum_height - 0.5, -1.0),
		Vector3(chunk_extent + 2.0, maximum_height - minimum_height + _settings.grass_height + 1.5, chunk_extent + 2.0)
	)


## Keeps the grass cull volume in step with a grass height changed at runtime,
## which the shader applies immediately but the baked AABB does not know about.
func set_grass_cull_height(height: float) -> void:
	grass_mesh_instance.extra_cull_margin = height + CULL_MARGIN_SLACK


func publish_grass_meshes(meshes: Array[ArrayMesh], distance_to_chunk: float) -> void:
	grass_meshes = meshes
	grass_ready = grass_meshes.size() == TerrainGenerator.GRASS_LOD_VARIANT_COUNT
	if not grass_ready:
		grass_mesh_instance.mesh = null
		grass_mesh_instance.visible = false
		return
	current_lod = _initial_lod(distance_to_chunk)
	_apply_lod()


func update_grass_lod(distance_to_chunk: float) -> void:
	if not grass_ready:
		return
	var next_lod := current_lod
	match current_lod:
		LOD_NEAR:
			if distance_to_chunk > _settings.lod_far_to_hidden:
				next_lod = LOD_HIDDEN
			elif distance_to_chunk > _settings.lod_medium_to_far:
				next_lod = LOD_FAR
			elif distance_to_chunk > _settings.lod_near_to_medium:
				next_lod = LOD_MEDIUM
		LOD_MEDIUM:
			if distance_to_chunk < _settings.lod_medium_to_near:
				next_lod = LOD_NEAR
			elif distance_to_chunk > _settings.lod_far_to_hidden:
				next_lod = LOD_HIDDEN
			elif distance_to_chunk > _settings.lod_medium_to_far:
				next_lod = LOD_FAR
		LOD_FAR:
			if distance_to_chunk < _settings.lod_medium_to_near:
				next_lod = LOD_NEAR
			elif distance_to_chunk < _settings.lod_far_to_medium:
				next_lod = LOD_MEDIUM
			elif distance_to_chunk > _settings.lod_far_to_hidden:
				next_lod = LOD_HIDDEN
		LOD_HIDDEN:
			if distance_to_chunk < _settings.lod_medium_to_near:
				next_lod = LOD_NEAR
			elif distance_to_chunk < _settings.lod_far_to_medium:
				next_lod = LOD_MEDIUM
			elif distance_to_chunk < _settings.lod_hidden_to_far:
				next_lod = LOD_FAR
	if next_lod != current_lod:
		current_lod = next_lod
		_apply_lod()


func world_aabb() -> AABB:
	return global_transform * AABB(
		Vector3(0.0, minimum_height, 0.0),
		Vector3(float(_settings.chunk_size), maximum_height - minimum_height + _settings.grass_height, float(_settings.chunk_size))
	)


func _initial_lod(distance_to_chunk: float) -> int:
	if distance_to_chunk <= _settings.lod_near_to_medium:
		return LOD_NEAR
	if distance_to_chunk <= _settings.lod_medium_to_far:
		return LOD_MEDIUM
	if distance_to_chunk <= _settings.lod_far_to_hidden:
		return LOD_FAR
	return LOD_HIDDEN


func _apply_lod() -> void:
	if current_lod == LOD_HIDDEN:
		grass_mesh_instance.visible = false
		return
	grass_mesh_instance.mesh = grass_meshes[current_lod]
	grass_mesh_instance.visible = true
