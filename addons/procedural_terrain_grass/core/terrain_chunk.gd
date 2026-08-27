@tool
# One streamed terrain tile: a terrain mesh, a heightmap collider, and one base
# grass surface drawn through the three cached shell MultiMeshes the LOD bands
# switch between.
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
## Quality bias, owned by the manager. Shifts which of the three baked variants a
## band actually draws, so a quality change is a mesh swap rather than a rebuild.
var grass_lod_bias: int = 0
## Quality "off". Kept separate from LOD_HIDDEN so distance and preference do not
## overwrite each other when either changes.
var grass_suppressed: bool = false
var heights := PackedFloat32Array()
var normals := PackedVector3Array()
var base_occupancy := PackedByteArray()
var occupancy := PackedByteArray()
var base_fine_occupancy := PackedByteArray()
var fine_occupancy := PackedByteArray()
var minimum_height: float = 0.0
var maximum_height: float = 0.0
## The one grass surface this chunk publishes. All three shell MultiMeshes point
## at it; a static-mask rebuild replaces it without touching their instance data.
var grass_base_mesh: ArrayMesh
## Near/Medium/Far shell instance sets, prebuilt at configure time. Their
## distributions are not prefixes of one another -- Near ends at 1.00, Medium at
## 0.95, Far at the configured far top -- so visible_instance_count cannot select
## between them and three resources are what an LOD swap chooses from.
var grass_multimeshes: Array[MultiMesh] = []

var terrain_mesh_instance: MeshInstance3D
var grass_mesh_instance: MultiMeshInstance3D
var terrain_body: StaticBody3D
var terrain_collision: CollisionShape3D
var _settings
var _terrain_material: Material
var _lod_near_to_medium_squared: float
var _lod_medium_to_near_squared: float
var _lod_medium_to_far_squared: float
var _lod_far_to_medium_squared: float
var _lod_far_to_hidden_squared: float
var _lod_hidden_to_far_squared: float


func configure(
	chunk_coord: Vector2i,
	revision: int,
	settings,
	terrain_material: Material,
	grass_material: Material,
	shell_instance_buffers: Array[PackedFloat32Array]
) -> void:
	coord = chunk_coord
	generation_revision = revision
	grass_revision = revision
	_settings = settings
	_terrain_material = terrain_material
	refresh_lod_thresholds()
	name = "TerrainChunk_%d_%d" % [coord.x, coord.y]
	position = Vector3(float(coord.x) * settings.chunk_size, 0.0, float(coord.y) * settings.chunk_size)

	grass_mesh_instance = MultiMeshInstance3D.new()
	grass_mesh_instance.name = "GrassMesh"
	grass_mesh_instance.material_override = grass_material
	# Shell grass is many overlapping layers; casting shadows from all of them
	# costs far more than the result is worth at this density.
	grass_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grass_mesh_instance.visible = false
	grass_mesh_instance.extra_cull_margin = settings.grass_height + CULL_MARGIN_SLACK
	add_child(grass_mesh_instance)

	# Instance data is built once here and never rewritten: an LOD change picks a
	# different resource, and a mask rebuild only swaps the mesh underneath these.
	for buffer in shell_instance_buffers:
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_custom_data = true
		@warning_ignore("integer_division")
		multimesh.instance_count = buffer.size() / TerrainGenerator.GRASS_INSTANCE_STRIDE
		multimesh.buffer = buffer
		grass_multimeshes.append(multimesh)

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


func publish_grass_mesh(mesh: ArrayMesh, distance_to_chunk: float) -> void:
	publish_grass_mesh_squared(mesh, distance_to_chunk * distance_to_chunk)


## Points the three shell MultiMeshes at a newly committed base surface.
##
## Their instance buffers are deliberately left alone: shell counts and fractions
## are settings, not chunk data, so a remask after a blocker moves rewrites the
## geometry underneath the same shells rather than rebuilding them.
func publish_grass_mesh_squared(mesh: ArrayMesh, distance_squared_to_chunk: float) -> void:
	grass_base_mesh = mesh
	for multimesh in grass_multimeshes:
		multimesh.mesh = mesh
	grass_ready = mesh != null \
		and grass_multimeshes.size() == TerrainGenerator.GRASS_LOD_VARIANT_COUNT
	if not grass_ready:
		grass_mesh_instance.multimesh = null
		grass_mesh_instance.visible = false
		return
	current_lod = _initial_lod_squared(distance_squared_to_chunk)
	_apply_lod()


## Re-reads the LOD band distances from the shared settings object.
##
## The squared thresholds are cached because the comparison runs for every loaded
## chunk on every LOD tick, but the settings they come from can change after a
## chunk exists -- the fog reach caps the hide distance, and fog is resolved by
## the renderer well after the terrain starts streaming. Chunks hold the settings
## by reference, so re-deriving here is all that a live change needs.
func refresh_lod_thresholds() -> void:
	if _settings == null:
		return
	_lod_near_to_medium_squared = _settings.lod_near_to_medium * _settings.lod_near_to_medium
	_lod_medium_to_near_squared = _settings.lod_medium_to_near * _settings.lod_medium_to_near
	_lod_medium_to_far_squared = _settings.lod_medium_to_far * _settings.lod_medium_to_far
	_lod_far_to_medium_squared = _settings.lod_far_to_medium * _settings.lod_far_to_medium
	_lod_far_to_hidden_squared = _settings.lod_far_to_hidden * _settings.lod_far_to_hidden
	_lod_hidden_to_far_squared = _settings.lod_hidden_to_far * _settings.lod_hidden_to_far


func update_grass_lod(distance_to_chunk: float) -> void:
	update_grass_lod_squared(distance_to_chunk * distance_to_chunk)


func update_grass_lod_squared(distance_squared_to_chunk: float) -> void:
	if not grass_ready:
		return
	var next_lod := current_lod
	match current_lod:
		LOD_NEAR:
			if distance_squared_to_chunk > _lod_far_to_hidden_squared:
				next_lod = LOD_HIDDEN
			elif distance_squared_to_chunk > _lod_medium_to_far_squared:
				next_lod = LOD_FAR
			elif distance_squared_to_chunk > _lod_near_to_medium_squared:
				next_lod = LOD_MEDIUM
		LOD_MEDIUM:
			if distance_squared_to_chunk < _lod_medium_to_near_squared:
				next_lod = LOD_NEAR
			elif distance_squared_to_chunk > _lod_far_to_hidden_squared:
				next_lod = LOD_HIDDEN
			elif distance_squared_to_chunk > _lod_medium_to_far_squared:
				next_lod = LOD_FAR
		LOD_FAR:
			if distance_squared_to_chunk < _lod_medium_to_near_squared:
				next_lod = LOD_NEAR
			elif distance_squared_to_chunk < _lod_far_to_medium_squared:
				next_lod = LOD_MEDIUM
			elif distance_squared_to_chunk > _lod_far_to_hidden_squared:
				next_lod = LOD_HIDDEN
		LOD_HIDDEN:
			if distance_squared_to_chunk < _lod_medium_to_near_squared:
				next_lod = LOD_NEAR
			elif distance_squared_to_chunk < _lod_far_to_medium_squared:
				next_lod = LOD_MEDIUM
			elif distance_squared_to_chunk < _lod_hidden_to_far_squared:
				next_lod = LOD_FAR
	if next_lod != current_lod:
		current_lod = next_lod
		_apply_lod()


func _initial_lod(distance_to_chunk: float) -> int:
	return _initial_lod_squared(distance_to_chunk * distance_to_chunk)


func _initial_lod_squared(distance_squared_to_chunk: float) -> int:
	if distance_squared_to_chunk <= _lod_near_to_medium_squared:
		return LOD_NEAR
	if distance_squared_to_chunk <= _lod_medium_to_far_squared:
		return LOD_MEDIUM
	if distance_squared_to_chunk <= _lod_far_to_hidden_squared:
		return LOD_FAR
	return LOD_HIDDEN


## Re-applies the current band, for when the quality preference changed rather
## than the distance.
func refresh_grass_quality(bias: int, suppressed: bool) -> void:
	grass_lod_bias = bias
	grass_suppressed = suppressed
	if grass_ready:
		_apply_lod()
	elif suppressed:
		grass_mesh_instance.visible = false


func _apply_lod() -> void:
	if grass_suppressed or current_lod == LOD_HIDDEN:
		grass_mesh_instance.visible = false
		return
	# Shell counts come from the settings snapshot the worker jobs read, which is
	# deliberately read-only, so lowering them for real means tearing the runtime
	# down -- taking terrain collision with it while the player is standing on
	# it. Every chunk already holds all three shell sets, though, so a quality
	# preference can simply draw a coarser one than the distance band asked for.
	# Instant, reversible, and it cannot drop the floor.
	var variant := clampi(current_lod + grass_lod_bias, LOD_NEAR, LOD_FAR)
	var wanted := grass_multimeshes[variant]
	# Assigning the same resource again would still re-register the instance base
	# with the rendering server, and this runs on every LOD tick.
	if grass_mesh_instance.multimesh != wanted:
		grass_mesh_instance.multimesh = wanted
	grass_mesh_instance.visible = true
