@tool
# Chunk streaming, generation scheduling and static grass masking.
#
# Work moves through four stages, each budgeted so no single frame stalls:
#   1. _terrain_queue  -> BuildJob(terrain), on a worker thread when available
#   2. _mask_queue     -> MaskJob, physics shape queries spread over frames
#   3. _grass_queue    -> BuildJob(grass), three shell LOD variants per chunk
#   4. commit queues   -> ArrayMesh construction, capped per frame
#
# Every queued item carries the chunk revision it was created for, so results
# that arrive after the chunk was unloaded or invalidated are discarded instead
# of being applied to the wrong geometry.
extends Node3D

const IncrementalBuild = preload("res://addons/procedural_terrain_grass/core/terrain_build_state.gd")
const TerrainChunkScript = preload("res://addons/procedural_terrain_grass/core/terrain_chunk.gd")
const TerrainGenerator = preload("res://addons/procedural_terrain_grass/core/terrain_generator.gd")
const TerrainSettingsScript = preload("res://addons/procedural_terrain_grass/core/terrain_settings.gd")

signal chunk_loaded(coord: Vector2i, chunk)
signal chunk_unloaded(coord: Vector2i)
signal grass_rebuilt(coord: Vector2i)

class BuildJob:
	extends RefCounted
	var kind: StringName
	var coord: Vector2i
	var revision: int
	var snapshot: Dictionary
	var heights := PackedFloat32Array()
	var normals := PackedVector3Array()
	var occupancy := PackedByteArray()
	var fine_occupancy := PackedByteArray()
	var task_id: int = -1
	var result: Dictionary = {}
	var state

	func prepare() -> void:
		if state != null:
			return
		state = IncrementalBuild.new()
		if kind == &"terrain":
			state.configure_terrain(coord, revision, snapshot)
		else:
			state.configure_grass(coord, revision, heights, normals, occupancy, fine_occupancy, snapshot)

	func run() -> void:
		prepare()
		while not state.step(Time.get_ticks_usec() + 1_000_000):
			pass
		result = state.output

	func step(deadline_usec: int) -> bool:
		prepare()
		if not state.step(deadline_usec):
			return false
		result = state.output
		return true

class MaskJob:
	extends RefCounted
	var coord: Vector2i
	var revision: int
	var mask := PackedByteArray()
	var fine_mask := PackedByteArray()
	var next_cell: int = 0
	var active_cell: int = -1
	var next_subcell: int = 0
	var needs_physics_scan: bool = false
	var fallback_aabbs: Array[AABB] = []

class GrassCommitJob:
	extends RefCounted
	var coord: Vector2i
	var revision: int
	var variants: Array = []
	var next_variant: int = 0
	var meshes: Array[ArrayMesh] = []

var settings
var target: Node3D
var terrain_material: Material
var grass_material: Material
var interaction_manager
var grass_enabled: bool = true
var static_masking_enabled: bool = true
## Grass quality preference, applied by remapping which cached LOD variant each
## band draws. See TerrainChunk._apply_lod.
var grass_lod_bias: int = 0
var grass_suppressed: bool = false

var chunks: Dictionary = {}
var _coord_revisions: Dictionary = {}
var _terrain_queue: Array[Dictionary] = []
var _grass_queue: Array[Dictionary] = []
var _mask_queue: Array[Dictionary] = []
var _active_build_jobs: Array[BuildJob] = []
var _active_incremental_job: BuildJob
var _terrain_commit_queue: Array[Dictionary] = []
var _grass_commit_queue: Array[GrassCommitJob] = []
var _active_mask_job: MaskJob
var _height_noise: FastNoiseLite
var _snapshot: Dictionary
var _streaming_enabled: bool = false
var _use_workers: bool = false
var _stream_timer: float = 0.0
var _lod_timer: float = 0.0
var mask_query_count: int = 0
var mesh_commit_count: int = 0
var stale_result_count: int = 0

var _cell_query_shape := BoxShape3D.new()
var _cell_query := PhysicsShapeQueryParameters3D.new()
var _broad_query_shape := BoxShape3D.new()
var _broad_query := PhysicsShapeQueryParameters3D.new()


func _ready() -> void:
	if settings == null:
		settings = TerrainSettingsScript.new()
	_snapshot = settings.snapshot()
	# Worker jobs share this dictionary instead of deep-copying it per chunk,
	# which is only safe because nothing writes to it after setup.
	_snapshot.make_read_only()
	_height_noise = TerrainGenerator.create_noise(_snapshot)
	# Single-threaded exports fall back to the incremental main-thread builder.
	# `--force-nothreads` exercises that path on a threaded build.
	_use_workers = OS.has_feature("threads") and not OS.get_cmdline_user_args().has("--force-nothreads")
	_cell_query.shape = _cell_query_shape
	_cell_query.collision_mask = settings.blocker_query_mask
	_cell_query.collide_with_bodies = true
	_cell_query.collide_with_areas = true
	_broad_query.shape = _broad_query_shape
	_broad_query.collision_mask = settings.blocker_query_mask
	_broad_query.collide_with_bodies = true
	_broad_query.collide_with_areas = true


func start_streaming() -> void:
	if target == null:
		return
	_streaming_enabled = true
	_stream_timer = settings.stream_update_interval
	_update_streaming_set()


func stop_streaming(clear_chunks: bool = false) -> void:
	_streaming_enabled = false
	if not clear_chunks:
		return
	_terrain_queue.clear()
	_grass_queue.clear()
	_mask_queue.clear()
	_terrain_commit_queue.clear()
	_grass_commit_queue.clear()
	_active_incremental_job = null
	_active_mask_job = null
	for chunk in chunks.values():
		if is_instance_valid(chunk):
			chunk.queue_free()
	chunks.clear()


func shutdown() -> void:
	stop_streaming(true)
	# Dropping the job list while tasks are still queued would leave the pool
	# building meshes for a runtime that no longer exists, and the results would
	# outlive this node. Join them first; each task is bounded by one chunk.
	for job in _active_build_jobs:
		WorkerThreadPool.wait_for_task_completion(job.task_id)
	_active_build_jobs.clear()
	target = null
	interaction_manager = null


func sample_height(world_xz: Vector2) -> float:
	var local_xz := _world_to_local_xz(world_xz)
	return TerrainGenerator.sample_height(_height_noise, local_xz.x, local_xz.y, _snapshot) + _origin_position().y


func world_to_chunk(world_xz: Vector2) -> Vector2i:
	var size := float(settings.chunk_size)
	var local_xz := _world_to_local_xz(world_xz)
	return Vector2i(floori(local_xz.x / size), floori(local_xz.y / size))


func get_loaded_chunks() -> Array:
	var result: Array = []
	for value in chunks.values():
		result.append(value)
	return result


func get_chunk(coord: Vector2i):
	return chunks.get(coord)


func generation_backend_name() -> String:
	return "WorkerThreadPool" if _use_workers else "Incremental main thread"


func is_generation_idle() -> bool:
	return (
		_terrain_queue.is_empty()
		and _grass_queue.is_empty()
		and _mask_queue.is_empty()
		and _active_build_jobs.is_empty()
		and _active_incremental_job == null
		and _terrain_commit_queue.is_empty()
		and _grass_commit_queue.is_empty()
		and _active_mask_job == null
	)


func queued_work_count() -> int:
	return (
		_terrain_queue.size()
		+ _grass_queue.size()
		+ _mask_queue.size()
		+ _terrain_commit_queue.size()
		+ _grass_commit_queue.size()
	)


func active_generation_job_count() -> int:
	return _active_build_jobs.size() + (1 if _active_incremental_job != null else 0)


## Applies a runtime grass-height change to every loaded chunk's cull volume.
## The shells themselves are shader-driven, so no geometry has to be rebuilt.
func set_grass_cull_height(height: float) -> void:
	for chunk in chunks.values():
		if is_instance_valid(chunk):
			chunk.set_grass_cull_height(height)


## Applies a grass quality preference to every loaded chunk and to every chunk
## streamed afterwards. [param bias] shifts each distance band towards a coarser
## cached variant; [param suppressed] hides the canopy outright.
func set_grass_quality(bias: int, suppressed: bool) -> void:
	if bias == grass_lod_bias and suppressed == grass_suppressed:
		return
	grass_lod_bias = bias
	grass_suppressed = suppressed
	for chunk in get_loaded_chunks():
		chunk.refresh_grass_quality(bias, suppressed)


func invalidate_grass_region(world_bounds: AABB) -> void:
	if not grass_enabled or not static_masking_enabled:
		return
	var epsilon := 0.0001
	var minimum := world_to_chunk(Vector2(world_bounds.position.x, world_bounds.position.z))
	var end := world_bounds.end
	var maximum := world_to_chunk(Vector2(end.x - epsilon, end.z - epsilon))
	for z in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			var coord := Vector2i(x, z)
			var chunk = get_chunk(coord)
			if chunk == null or not chunk.terrain_ready:
				continue
			chunk.grass_revision += 1
			_queue_mask_build(chunk)


func _process(delta: float) -> void:
	if not _streaming_enabled or target == null:
		return
	_stream_timer += delta
	_lod_timer += delta
	if _stream_timer >= settings.stream_update_interval:
		_stream_timer = 0.0
		_update_streaming_set()
	if _lod_timer >= settings.lod_update_interval:
		_lod_timer = 0.0
		_update_lods()
	_poll_worker_jobs()
	_dispatch_generation_jobs()
	_process_mesh_commits()


func _physics_process(_delta: float) -> void:
	# The target can disappear mid-stream (the camera is freed, or an assigned
	# streaming target is), and finishing a mask job reads its position.
	if not _streaming_enabled or target == null:
		return
	_process_mask_jobs()


func _update_streaming_set() -> void:
	var target_xz := Vector2(target.global_position.x, target.global_position.z)
	var center := world_to_chunk(target_xz)
	var radius_chunks := ceili(settings.terrain_load_distance / float(settings.chunk_size)) + 1
	var desired: Dictionary = {}
	for z in range(center.y - radius_chunks, center.y + radius_chunks + 1):
		for x in range(center.x - radius_chunks, center.x + radius_chunks + 1):
			var coord := Vector2i(x, z)
			var distance := distance_to_chunk_aabb(target_xz, coord)
			if distance <= settings.terrain_load_distance:
				desired[coord] = distance
				if not chunks.has(coord):
					_create_pending_chunk(coord, distance)

	var unload: Array[Vector2i] = []
	for coord_variant in chunks.keys():
		var coord: Vector2i = coord_variant
		if desired.has(coord):
			continue
		if distance_to_chunk_aabb(target_xz, coord) > settings.terrain_unload_distance:
			unload.append(coord)
	for coord in unload:
		_unload_chunk(coord)

	_resort_queue(_terrain_queue, target_xz)
	_resort_queue(_grass_queue, target_xz)


# Entries record the distance they were queued at, which goes stale as soon as
# the target moves. Refreshing before the sort is what keeps "nearest first"
# actually nearest; both queues are small enough that this is cheap.
func _resort_queue(queue: Array[Dictionary], target_xz: Vector2) -> void:
	for entry in queue:
		entry["distance"] = distance_to_chunk_aabb(target_xz, entry["coord"])
	queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))


func _create_pending_chunk(coord: Vector2i, distance: float) -> void:
	var revision := int(_coord_revisions.get(coord, 0)) + 1
	_coord_revisions[coord] = revision
	var chunk := TerrainChunkScript.new()
	chunk.configure(coord, revision, settings, terrain_material, grass_material)
	# Chunks stream in long after the player last touched the quality setting, so
	# the preference has to be handed to each new one rather than only broadcast.
	chunk.grass_lod_bias = grass_lod_bias
	chunk.grass_suppressed = grass_suppressed
	chunks[coord] = chunk
	add_child(chunk)
	_terrain_queue.append({"coord": coord, "revision": revision, "distance": distance})


func _unload_chunk(coord: Vector2i) -> void:
	var chunk = get_chunk(coord)
	if chunk == null:
		return
	_coord_revisions[coord] = int(_coord_revisions.get(coord, chunk.generation_revision)) + 1
	chunks.erase(coord)
	chunk.queue_free()
	chunk_unloaded.emit(coord)


func _dispatch_generation_jobs() -> void:
	if _use_workers:
		while _active_build_jobs.size() < settings.max_worker_jobs:
			var job := _next_build_job()
			if job == null:
				break
			job.task_id = WorkerThreadPool.add_task(job.run, false, "Terrain %s" % job.kind)
			_active_build_jobs.append(job)
		return

	var deadline_usec: int = Time.get_ticks_usec() + int(settings.incremental_generation_budget_usec)
	while Time.get_ticks_usec() < deadline_usec:
		if _active_incremental_job == null:
			_active_incremental_job = _next_build_job()
		if _active_incremental_job == null:
			break
		if not _active_incremental_job.step(deadline_usec):
			break
		_accept_completed_job(_active_incremental_job)
		_active_incremental_job = null


# Both queues are drained by nearest-first distance rather than terrain-before-
# grass. Draining terrain first starves grass for as long as the target keeps
# moving, because every streaming tick refills the terrain queue: the player
# ends up walking over bare ground that never catches up.
func _next_build_job() -> BuildJob:
	var terrain_entry := _peek_valid(_terrain_queue, false)
	var grass_entry := _peek_valid(_grass_queue, true)
	if terrain_entry.is_empty() and grass_entry.is_empty():
		return null
	# Terrain wins ties, since a chunk cannot grow grass before it has a surface.
	var take_terrain := grass_entry.is_empty() or (
		not terrain_entry.is_empty()
		and float(terrain_entry["distance"]) <= float(grass_entry["distance"])
	)
	var job := BuildJob.new()
	job.snapshot = _snapshot
	if take_terrain:
		_terrain_queue.pop_front()
		job.kind = &"terrain"
		job.coord = terrain_entry["coord"]
		job.revision = int(terrain_entry["revision"])
		return job

	_grass_queue.pop_front()
	var chunk = get_chunk(grass_entry["coord"])
	job.kind = &"grass"
	job.coord = grass_entry["coord"]
	job.revision = int(grass_entry["revision"])
	# Copied because the worker reads them off-thread while masking may still be
	# writing the chunk's live occupancy.
	job.heights = chunk.heights.duplicate()
	job.normals = chunk.normals.duplicate()
	job.occupancy = chunk.occupancy.duplicate()
	job.fine_occupancy = chunk.fine_occupancy.duplicate()
	return job


## Discards stale heads and returns the front entry, leaving it in the queue.
func _peek_valid(queue: Array[Dictionary], for_grass: bool) -> Dictionary:
	while not queue.is_empty():
		var queued: Dictionary = queue[0]
		var chunk = get_chunk(queued["coord"])
		var stale := chunk == null
		if not stale and for_grass:
			stale = not chunk.terrain_ready or chunk.grass_revision != int(queued["revision"])
		elif not stale:
			stale = chunk.generation_revision != int(queued["revision"])
		if not stale:
			return queued
		queue.pop_front()
	return {}


func _poll_worker_jobs() -> void:
	for index in range(_active_build_jobs.size() - 1, -1, -1):
		var job := _active_build_jobs[index]
		if not WorkerThreadPool.is_task_completed(job.task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(job.task_id)
		_active_build_jobs.remove_at(index)
		_accept_completed_job(job)


func _accept_completed_job(job: BuildJob) -> void:
	var chunk = get_chunk(job.coord)
	if chunk == null:
		stale_result_count += 1
		return
	if job.kind == &"terrain":
		if chunk.generation_revision != job.revision:
			stale_result_count += 1
			return
		_terrain_commit_queue.append(job.result)
	else:
		if chunk.grass_revision != job.revision:
			stale_result_count += 1
			return
		var commit := GrassCommitJob.new()
		commit.coord = job.coord
		commit.revision = job.revision
		commit.variants = job.result["variants"]
		_grass_commit_queue.append(commit)


func _process_mesh_commits() -> void:
	mesh_commit_count = 0
	while mesh_commit_count < settings.max_mesh_commits_per_frame and not _terrain_commit_queue.is_empty():
		var result: Dictionary = _terrain_commit_queue.pop_front()
		var chunk = get_chunk(result["coord"])
		if chunk == null or chunk.generation_revision != int(result["revision"]):
			stale_result_count += 1
			continue
		chunk.apply_terrain(result)
		mesh_commit_count += 1
		chunk_loaded.emit(chunk.coord, chunk)
		if grass_enabled:
			_queue_mask_build(chunk)

	while mesh_commit_count < settings.max_mesh_commits_per_frame and not _grass_commit_queue.is_empty():
		var commit := _grass_commit_queue[0]
		var chunk = get_chunk(commit.coord)
		if chunk == null or chunk.grass_revision != commit.revision:
			_grass_commit_queue.pop_front()
			stale_result_count += 1
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, commit.variants[commit.next_variant])
		commit.meshes.append(mesh)
		commit.next_variant += 1
		mesh_commit_count += 1
		if commit.next_variant >= commit.variants.size():
			_grass_commit_queue.pop_front()
			var target_xz := Vector2(target.global_position.x, target.global_position.z)
			chunk.publish_grass_meshes(commit.meshes, distance_to_chunk_aabb(target_xz, chunk.coord))
			grass_rebuilt.emit(chunk.coord)


func _queue_mask_build(chunk) -> void:
	for queued in _mask_queue:
		if queued["coord"] == chunk.coord and int(queued["revision"]) == chunk.grass_revision:
			return
	_mask_queue.append({"coord": chunk.coord, "revision": chunk.grass_revision})


func _process_mask_jobs() -> void:
	mask_query_count = 0
	if _active_mask_job == null:
		_active_mask_job = _begin_next_mask_job()
	if _active_mask_job == null:
		return
	var job := _active_mask_job
	var chunk = get_chunk(job.coord)
	if chunk == null or chunk.grass_revision != job.revision:
		_active_mask_job = null
		return
	if not job.needs_physics_scan and job.fallback_aabbs.is_empty():
		_finish_mask_job(job, chunk)
		return

	var start_usec := Time.get_ticks_usec()
	var cell_count: int = int(settings.chunk_resolution) * int(settings.chunk_resolution)
	while job.next_cell < cell_count:
		if mask_query_count >= settings.max_mask_cell_queries:
			break
		if Time.get_ticks_usec() - start_usec >= settings.mask_query_budget_usec:
			break
		if job.active_cell >= 0:
			var subcell_aabb := _subcell_world_aabb(chunk, job.active_cell, job.next_subcell)
			if _aabb_hits_fallback(subcell_aabb, job.fallback_aabbs) or _query_hits_blocker(subcell_aabb, job.needs_physics_scan):
				TerrainGenerator.fine_mask_set_subcell(job.fine_mask, job.active_cell, job.next_subcell, false)
			job.next_subcell += 1
			if job.next_subcell >= TerrainGenerator.FINE_MASK_SUBDIVISIONS * TerrainGenerator.FINE_MASK_SUBDIVISIONS:
				if TerrainGenerator.fine_mask_get(job.fine_mask, job.active_cell) == 0:
					TerrainGenerator.mask_set(job.mask, job.active_cell, false)
				job.active_cell = -1
				job.next_subcell = 0
				job.next_cell += 1
			continue

		var cell_index := job.next_cell
		if not TerrainGenerator.mask_get(job.mask, cell_index):
			job.next_cell += 1
			continue
		var cell_aabb := _cell_world_aabb(chunk, cell_index)
		if _aabb_hits_fallback(cell_aabb, job.fallback_aabbs) or _query_hits_blocker(cell_aabb, job.needs_physics_scan):
			job.active_cell = cell_index
			job.next_subcell = 0
		else:
			job.next_cell += 1
	if job.next_cell >= cell_count:
		_finish_mask_job(job, chunk)


func _begin_next_mask_job() -> MaskJob:
	while not _mask_queue.is_empty():
		var queued: Dictionary = _mask_queue.pop_front()
		var chunk = get_chunk(queued["coord"])
		if chunk == null or not chunk.terrain_ready or chunk.grass_revision != int(queued["revision"]):
			continue
		var job := MaskJob.new()
		job.coord = chunk.coord
		job.revision = chunk.grass_revision
		job.mask = chunk.base_occupancy.duplicate()
		job.fine_mask = chunk.base_fine_occupancy.duplicate()
		if not static_masking_enabled:
			return job
		var bounds: AABB = chunk.world_aabb()
		_broad_query_shape.size = Vector3(bounds.size.x, bounds.size.y + 0.25, bounds.size.z)
		_broad_query.transform = Transform3D(Basis.IDENTITY, bounds.get_center())
		job.needs_physics_scan = not get_world_3d().direct_space_state.intersect_shape(_broad_query, 1).is_empty()
		if interaction_manager != null:
			job.fallback_aabbs = interaction_manager.get_fallback_aabbs(bounds)
		return job
	return null


func _finish_mask_job(job: MaskJob, chunk) -> void:
	if chunk.grass_revision == job.revision:
		chunk.occupancy = job.mask
		chunk.fine_occupancy = job.fine_mask
		var target_xz := Vector2(target.global_position.x, target.global_position.z)
		var distance := distance_to_chunk_aabb(target_xz, chunk.coord)
		if distance <= settings.grass_prefetch_distance:
			_grass_queue.append({"coord": chunk.coord, "revision": chunk.grass_revision, "distance": distance})
	_active_mask_job = null


func _cell_world_aabb(chunk, cell_index: int) -> AABB:
	var resolution: int = int(settings.chunk_resolution)
	var width: int = resolution + 1
	var x: int = cell_index % resolution
	var z := floori(float(cell_index) / float(resolution))
	var i00: int = z * width + x
	var h0: float = chunk.heights[i00]
	var h1: float = chunk.heights[i00 + 1]
	var h2: float = chunk.heights[i00 + width]
	var h3: float = chunk.heights[i00 + width + 1]
	var minimum := minf(minf(h0, h1), minf(h2, h3)) - 0.10
	var maximum: float = maxf(maxf(h0, h1), maxf(h2, h3)) + float(settings.grass_height) + 0.15
	var spacing: float = settings.cell_spacing()
	return global_transform * AABB(
		Vector3(chunk.position.x + float(x) * spacing, minimum, chunk.position.z + float(z) * spacing),
		Vector3(spacing, maximum - minimum, spacing)
	)


func _subcell_world_aabb(chunk, cell_index: int, subcell_index: int) -> AABB:
	var resolution: int = int(settings.chunk_resolution)
	var width: int = resolution + 1
	var x: int = cell_index % resolution
	var z := floori(float(cell_index) / float(resolution))
	var sub_x := subcell_index % TerrainGenerator.FINE_MASK_SUBDIVISIONS
	var sub_z := floori(float(subcell_index) / float(TerrainGenerator.FINE_MASK_SUBDIVISIONS))
	var fraction_step := 1.0 / float(TerrainGenerator.FINE_MASK_SUBDIVISIONS)
	var u0 := float(sub_x) * fraction_step
	var v0 := float(sub_z) * fraction_step
	var u1 := u0 + fraction_step
	var v1 := v0 + fraction_step
	var i00: int = z * width + x
	var h00: float = chunk.heights[i00]
	var h10: float = chunk.heights[i00 + 1]
	var h01: float = chunk.heights[i00 + width]
	var h11: float = chunk.heights[i00 + width + 1]
	var height_a := _bilinear_height(h00, h10, h01, h11, u0, v0)
	var height_b := _bilinear_height(h00, h10, h01, h11, u1, v0)
	var height_c := _bilinear_height(h00, h10, h01, h11, u0, v1)
	var height_d := _bilinear_height(h00, h10, h01, h11, u1, v1)
	var minimum := minf(minf(height_a, height_b), minf(height_c, height_d)) - 0.10
	var maximum: float = maxf(maxf(height_a, height_b), maxf(height_c, height_d)) + float(settings.grass_height) + 0.15
	# Jolt treats face contact as an overlap. Insetting one millimetre prevents
	# the subcell immediately outside an aligned wall from being removed too.
	var spacing: float = settings.cell_spacing()
	var subcell_size: float = spacing * fraction_step
	var query_inset := minf(0.001, subcell_size * 0.1)
	return global_transform * AABB(
		Vector3(
			chunk.position.x + (float(x) + u0) * spacing + query_inset,
			minimum,
			chunk.position.z + (float(z) + v0) * spacing + query_inset
		),
		Vector3(subcell_size - query_inset * 2.0, maximum - minimum, subcell_size - query_inset * 2.0)
	)


func _bilinear_height(h00: float, h10: float, h01: float, h11: float, u: float, v: float) -> float:
	return lerpf(lerpf(h00, h10, u), lerpf(h01, h11, u), v)


func _aabb_hits_fallback(bounds: AABB, fallback_aabbs: Array[AABB]) -> bool:
	for fallback in fallback_aabbs:
		if fallback.intersects(bounds):
			return true
	return false


func _query_hits_blocker(bounds: AABB, enabled: bool) -> bool:
	if not enabled:
		return false
	_cell_query_shape.size = bounds.size
	_cell_query.transform = Transform3D(Basis.IDENTITY, bounds.get_center())
	mask_query_count += 1
	return not get_world_3d().direct_space_state.intersect_shape(_cell_query, 1).is_empty()


func _update_lods() -> void:
	var target_xz := Vector2(target.global_position.x, target.global_position.z)
	for chunk in get_loaded_chunks():
		chunk.update_grass_lod(distance_to_chunk_aabb(target_xz, chunk.coord))


func distance_to_chunk_aabb(world_xz: Vector2, coord: Vector2i) -> float:
	var size := float(settings.chunk_size)
	var minimum := Vector2(float(coord.x) * size, float(coord.y) * size)
	var maximum := minimum + Vector2(size, size)
	var local_xz := _world_to_local_xz(world_xz)
	var nearest := Vector2(
		clampf(local_xz.x, minimum.x, maximum.x),
		clampf(local_xz.y, minimum.y, maximum.y)
	)
	return local_xz.distance_to(nearest)


func _world_to_local_xz(world_xz: Vector2) -> Vector2:
	var origin := _origin_position()
	return world_xz - Vector2(origin.x, origin.z)


func _origin_position() -> Vector3:
	return global_position if is_inside_tree() else position
