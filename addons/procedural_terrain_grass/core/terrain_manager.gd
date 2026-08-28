@tool
# Chunk streaming, generation scheduling and static grass masking.
#
# Work moves through four stages, each budgeted so no single frame stalls:
#   1. _terrain_queue  -> BuildJob(terrain), on a worker thread when available
#   2. _mask_queue     -> MaskJob, physics shape queries spread over frames
#   3. _grass_queue    -> BuildJob(grass), one base grass surface per chunk
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

## Vertical slack the per-cell queries add below the terrain and above the grass.
## The broad-phase envelope has to cover exactly this, or a blocker sitting in
## the gap would never be collected as a candidate and the cells it really
## touches would be rejected without ever being queried.
const MASK_QUERY_PADDING_BELOW := 0.10
const MASK_QUERY_PADDING_ABOVE := 0.15

## Slack added to every candidate bound before it is used to reject a cell.
## AABB.intersects() is exclusive -- two boxes sharing a face do not intersect --
## while both physics backends treat face contact as an overlap, Jolt especially.
## Without this a wall flush against a cell boundary would skip its exact query
## and leave a strip of grass standing inside the wall.
const BLOCKER_BOUNDS_SLACK := 0.01

## How many collider/shape pairs the chunk broad phase will enumerate. Beyond
## this the query result may be truncated, so the job cannot prove it has seen
## every blocker and falls back to the exact per-cell scan.
const MASK_CANDIDATE_LIMIT := 32

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
	## Wall-clock microseconds this job spent generating, summed across every
	## slice for the incremental path. Read by the streaming benchmark; the two
	## clock reads per slice are far below the cost of the slice itself.
	var elapsed_usec: int = 0

	func prepare() -> void:
		if state != null:
			return
		state = IncrementalBuild.new()
		if kind == &"terrain":
			state.configure_terrain(coord, revision, snapshot)
		else:
			state.configure_grass(coord, revision, heights, normals, occupancy, fine_occupancy, snapshot)

	func run() -> void:
		var started_usec := Time.get_ticks_usec()
		prepare()
		while not state.step(Time.get_ticks_usec() + 1_000_000):
			pass
		result = state.output
		elapsed_usec += Time.get_ticks_usec() - started_usec

	func step(deadline_usec: int) -> bool:
		var started_usec := Time.get_ticks_usec()
		prepare()
		var complete: bool = state.step(deadline_usec)
		elapsed_usec += Time.get_ticks_usec() - started_usec
		if not complete:
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
	## Conservative world bounds of every physics collider that can reach this
	## chunk's cell query volumes, snapshotted at job start and already grown by
	## BLOCKER_BOUNDS_SLACK. Values, not node references: a blocker freed mid-job
	## must not be dereferenced, and the revision system discards the job anyway.
	var blocker_bounds: Array[AABB] = []
	## Only true when the job proved that every collider on the blocker mask which
	## can reach this chunk is represented above AND that comparing against them
	## can actually reject something. Either failure puts the job back on the
	## exhaustive exact scan it used before Phase 2, which is why an unregistered
	## body or an unsupported shape still carves grass correctly.
	var broad_phase_active: bool = false
	# The active cell's corners and origin, cached for its sixteen subcell bounds
	# so the fine pass stops re-deriving them per subcell. Stored as the same
	# terms the bounds expressions already used: reassociating the arithmetic
	# would move a boundary height by an ULP and with it a subcell's mask bit.
	var active_x: float = 0.0
	var active_z: float = 0.0
	var active_origin_x: float = 0.0
	var active_origin_z: float = 0.0
	var active_h00: float = 0.0
	var active_h10: float = 0.0
	var active_h01: float = 0.0
	var active_h11: float = 0.0

	## Whether any conservative candidate could contain something overlapping
	## [param bounds]. Inclusive by construction: the candidates were grown before
	## being stored, so face contact answers yes and costs one needless query
	## rather than wrongly leaving grass inside a blocker.
	func candidate_overlaps(bounds: AABB) -> bool:
		for candidate in blocker_bounds:
			if candidate.intersects(bounds):
				return true
		return false

class GrassCommitJob:
	extends RefCounted
	var coord: Vector2i
	var revision: int
	## One surface's worth of arrays. The three LOD shell sets draw this same
	## surface, so there is nothing left to commit per variant.
	var arrays: Array = []

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

# Cumulative benchmark counters. mask_query_count above is reset on every physics
# frame, which is useless for a before/after total, so these run for the lifetime
# of the manager and are only ever read.
var mask_query_total: int = 0
var mask_broad_phase_rejections: int = 0
var mask_jobs_completed: int = 0
var mask_job_usec_total: int = 0
var terrain_build_usec_total: int = 0
var grass_build_usec_total: int = 0
var terrain_commit_usec_total: int = 0
var grass_commit_usec_total: int = 0

var _cell_query_shape := BoxShape3D.new()
var _cell_query := PhysicsShapeQueryParameters3D.new()
var _broad_query_shape := BoxShape3D.new()
var _broad_query := PhysicsShapeQueryParameters3D.new()
## Identity transforms plus the quantised shell byte, one buffer per LOD variant.
## Shell distribution is a settings property, so this is built once and every
## chunk's MultiMesh resources bulk-copy it.
var _grass_shell_buffers: Array[PackedFloat32Array] = []
## Shape3D instance id -> derived local bounds, for the masking broad phase.
var _shape_bounds_cache: Dictionary = {}


func _ready() -> void:
	if settings == null:
		settings = TerrainSettingsScript.new()
	_snapshot = settings.snapshot()
	# Worker jobs share this dictionary instead of deep-copying it per chunk,
	# which is only safe because nothing writes to it after setup.
	_snapshot.make_read_only()
	_height_noise = TerrainGenerator.create_noise(_snapshot)
	_grass_shell_buffers = TerrainGenerator.grass_shell_instance_buffers(_snapshot)
	# Targets without thread support fall back to the incremental main-thread
	# builder. `--force-nothreads` exercises that path on a threaded build.
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
	for coord_variant in chunks:
		var chunk = chunks[coord_variant]
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
	return chunks.values()


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
	for coord_variant in chunks:
		var chunk = chunks[coord_variant]
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
	for coord_variant in chunks:
		var chunk = chunks[coord_variant]
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
	var local_target_xz := _world_to_local_xz(target_xz)
	var chunk_size := float(settings.chunk_size)
	var load_distance := float(settings.terrain_load_distance)
	var unload_distance := float(settings.terrain_unload_distance)
	var grass_prefetch_distance := float(settings.grass_prefetch_distance)
	var load_distance_squared := load_distance * load_distance
	var unload_distance_squared := unload_distance * unload_distance
	var grass_prefetch_distance_squared := grass_prefetch_distance * grass_prefetch_distance
	var center := Vector2i(
		floori(local_target_xz.x / chunk_size),
		floori(local_target_xz.y / chunk_size)
	)
	var radius_chunks := ceili(load_distance / chunk_size) + 1
	var desired: Dictionary = {}
	for z in range(center.y - radius_chunks, center.y + radius_chunks + 1):
		for x in range(center.x - radius_chunks, center.x + radius_chunks + 1):
			var coord := Vector2i(x, z)
			var distance_squared := _distance_squared_to_chunk_aabb_local(local_target_xz, coord, chunk_size)
			if distance_squared <= load_distance_squared:
				desired[coord] = true
				if not chunks.has(coord):
					_create_pending_chunk(coord, distance_squared)

	var unload: Array[Vector2i] = []
	for coord_variant in chunks:
		var coord: Vector2i = coord_variant
		if desired.has(coord):
			continue
		if _distance_squared_to_chunk_aabb_local(local_target_xz, coord, chunk_size) > unload_distance_squared:
			unload.append(coord)
	for coord in unload:
		_unload_chunk(coord)

	# Unload listeners may move this translated terrain before the remaining
	# work in this pass. Keep the captured target position, but refresh its local
	# equivalent after those synchronous signals.
	local_target_xz = _world_to_local_xz(target_xz)

	# Catch any chunk whose mask finished while it was still outside the prefetch
	# radius. Without this the only chance a chunk ever gets is the instant its
	# mask completes; see _queue_grass_if_wanted.
	for coord_variant in chunks:
		var chunk = chunks[coord_variant]
		if is_instance_valid(chunk):
			_queue_grass_if_wanted(
				chunk,
				_distance_squared_to_chunk_aabb_local(local_target_xz, chunk.coord, chunk_size),
				grass_prefetch_distance_squared
			)

	_resort_queue(_terrain_queue, local_target_xz, chunk_size)
	_resort_queue(_grass_queue, local_target_xz, chunk_size)


# Entries record the squared distance they were queued at, which goes stale as
# soon as the target moves. Refreshing before the sort is what keeps "nearest
# first" actually nearest; both queues are small enough that this is cheap.
func _resort_queue(queue: Array[Dictionary], local_target_xz: Vector2, chunk_size: float) -> void:
	for entry in queue:
		entry["distance_squared"] = _distance_squared_to_chunk_aabb_local(
			local_target_xz, entry["coord"], chunk_size)
	queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance_squared"]) < float(b["distance_squared"]))


func _create_pending_chunk(coord: Vector2i, distance_squared: float) -> void:
	var revision := int(_coord_revisions.get(coord, 0)) + 1
	_coord_revisions[coord] = revision
	var chunk := TerrainChunkScript.new()
	chunk.configure(
		coord, revision, settings, terrain_material, grass_material, _grass_shell_buffers)
	# Chunks stream in long after the player last touched the quality setting, so
	# the preference has to be handed to each new one rather than only broadcast.
	chunk.grass_lod_bias = grass_lod_bias
	chunk.grass_suppressed = grass_suppressed
	chunks[coord] = chunk
	add_child(chunk)
	_terrain_queue.append({
		"coord": coord,
		"revision": revision,
		"distance_squared": distance_squared,
	})


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
		and float(terrain_entry["distance_squared"]) <= float(grass_entry["distance_squared"])
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
		terrain_build_usec_total += job.elapsed_usec
		if chunk.generation_revision != job.revision:
			stale_result_count += 1
			return
		_terrain_commit_queue.append(job.result)
	else:
		grass_build_usec_total += job.elapsed_usec
		if chunk.grass_revision != job.revision:
			stale_result_count += 1
			return
		var commit := GrassCommitJob.new()
		commit.coord = job.coord
		commit.revision = job.revision
		commit.arrays = job.result["arrays"]
		_grass_commit_queue.append(commit)


func _process_mesh_commits() -> void:
	mesh_commit_count = 0
	while mesh_commit_count < settings.max_mesh_commits_per_frame and not _terrain_commit_queue.is_empty():
		var result: Dictionary = _terrain_commit_queue.pop_front()
		var chunk = get_chunk(result["coord"])
		if chunk == null or chunk.generation_revision != int(result["revision"]):
			stale_result_count += 1
			continue
		var terrain_commit_started_usec := Time.get_ticks_usec()
		chunk.apply_terrain(result)
		terrain_commit_usec_total += Time.get_ticks_usec() - terrain_commit_started_usec
		mesh_commit_count += 1
		chunk_loaded.emit(chunk.coord, chunk)
		if grass_enabled:
			_queue_mask_build(chunk)

	while mesh_commit_count < settings.max_mesh_commits_per_frame and not _grass_commit_queue.is_empty():
		var commit := _grass_commit_queue.pop_front() as GrassCommitJob
		var chunk = get_chunk(commit.coord)
		if chunk == null or chunk.grass_revision != commit.revision:
			stale_result_count += 1
			continue
		var grass_commit_started_usec := Time.get_ticks_usec()
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, commit.arrays)
		grass_commit_usec_total += Time.get_ticks_usec() - grass_commit_started_usec
		mesh_commit_count += 1
		var target_xz := Vector2(target.global_position.x, target.global_position.z)
		var local_target_xz := _world_to_local_xz(target_xz)
		chunk.publish_grass_mesh_squared(
			mesh,
			_distance_squared_to_chunk_aabb_local(
				local_target_xz, chunk.coord, float(settings.chunk_size))
		)
		grass_rebuilt.emit(chunk.coord)


func _queue_mask_build(chunk) -> void:
	for queued in _mask_queue:
		if queued["coord"] == chunk.coord and int(queued["revision"]) == chunk.grass_revision:
			return
	_mask_queue.append({"coord": chunk.coord, "revision": chunk.grass_revision})


func _process_mask_jobs() -> void:
	mask_query_count = 0
	var job_start_usec := Time.get_ticks_usec()
	if _active_mask_job == null:
		_active_mask_job = _begin_next_mask_job()
	if _active_mask_job == null:
		mask_job_usec_total += Time.get_ticks_usec() - job_start_usec
		return
	var job := _active_mask_job
	var chunk = get_chunk(job.coord)
	if chunk == null or chunk.grass_revision != job.revision:
		_active_mask_job = null
		mask_job_usec_total += Time.get_ticks_usec() - job_start_usec
		return
	if not job.needs_physics_scan and job.fallback_aabbs.is_empty():
		_finish_mask_job(job, chunk)
		mask_job_usec_total += Time.get_ticks_usec() - job_start_usec
		return

	var start_usec := Time.get_ticks_usec()
	var resolution: int = int(settings.chunk_resolution)
	var cell_count: int = resolution * resolution
	var spacing: float = settings.cell_spacing()
	# Constant for the whole call, and this loop reads it once per cell and once
	# per subcell. Nothing inside the loop can move the system.
	var world_transform := global_transform
	while job.next_cell < cell_count:
		if mask_query_count >= settings.max_mask_cell_queries:
			break
		if Time.get_ticks_usec() - start_usec >= settings.mask_query_budget_usec:
			break
		if job.active_cell >= 0:
			var subcell_aabb := _subcell_world_aabb(job, job.next_subcell, spacing, world_transform)
			if _bounds_are_blocked(job, subcell_aabb):
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
		var cell_aabb := _cell_world_aabb(chunk, cell_index, resolution, spacing, world_transform)
		if _bounds_are_blocked(job, cell_aabb):
			job.active_cell = cell_index
			job.next_subcell = 0
			_cache_active_cell(job, chunk, cell_index, resolution, spacing)
		else:
			job.next_cell += 1
	if job.next_cell >= cell_count:
		_finish_mask_job(job, chunk)
	mask_job_usec_total += Time.get_ticks_usec() - job_start_usec


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
		# The envelope is the exact union of the cell query volumes, padding
		# included. The old broad query grew the chunk AABB symmetrically by
		# 0.125, which is under the 0.15 the cells reach above the canopy: a
		# blocker in that band was missed here and then found by nothing.
		var envelope := global_transform * _mask_envelope_local(chunk)
		_collect_blocker_candidates(job, envelope)
		if interaction_manager != null:
			job.fallback_aabbs = interaction_manager.get_fallback_aabbs(envelope)
		return job
	return null


## The union of every cell and subcell query volume in [param chunk], in the
## system's local space.
func _mask_envelope_local(chunk) -> AABB:
	var size := float(settings.chunk_size)
	var minimum: float = chunk.minimum_height - MASK_QUERY_PADDING_BELOW
	var maximum: float = (chunk.maximum_height
		+ float(settings.grass_height) + MASK_QUERY_PADDING_ABOVE)
	return AABB(
		Vector3(chunk.position.x, minimum, chunk.position.z),
		Vector3(size, maximum - minimum, size)
	)


## Snapshots conservative bounds for every physics collider that can reach this
## chunk's cell volumes, and decides whether the per-cell broad phase may run.
##
## The candidates come from the colliders the query actually returns, not from
## the registration list. That is deliberate: bodies on the blocker mask which
## never registered -- the terrain test level has one -- must keep carving grass
## exactly as they did, and enumerating them here is what makes registration
## stay optional rather than quietly becoming mandatory.
##
## Anything that cannot be bounded conservatively clears broad_phase_active and
## the job runs the pre-Phase-2 exact scan over every cell: a shape type whose
## extents are not derivable, a collider the query could not resolve to a node,
## or more overlaps than MASK_CANDIDATE_LIMIT could report.
func _collect_blocker_candidates(job: MaskJob, envelope: AABB) -> void:
	_broad_query_shape.size = envelope.size
	_broad_query.transform = Transform3D(Basis.IDENTITY, envelope.get_center())
	var hits := get_world_3d().direct_space_state.intersect_shape(
		_broad_query, MASK_CANDIDATE_LIMIT)
	job.needs_physics_scan = not hits.is_empty()
	if not job.needs_physics_scan:
		return
	if hits.size() >= MASK_CANDIDATE_LIMIT:
		return

	for hit in hits:
		var collider := hit.get("collider") as CollisionObject3D
		if collider == null:
			# A shape owned by an RID rather than by a node -- a GridMap tile, a
			# CSG body -- which this cannot bound. Fall back to exact testing.
			job.blocker_bounds.clear()
			return
		var owner_id: int = collider.shape_find_owner(int(hit.get("shape", 0)))
		if owner_id < 0:
			job.blocker_bounds.clear()
			return
		# Physics resolves a shape's placement as body transform * owner
		# transform, and Godot requires a CollisionShape3D to be a direct child
		# for that to hold, so this is the transform the engine itself used.
		var owner_transform: Transform3D = (collider.global_transform
			* collider.shape_owner_get_transform(owner_id))
		for index in collider.shape_owner_get_shape_count(owner_id):
			var shape := collider.shape_owner_get_shape(owner_id, index)
			var bounds := _conservative_shape_bounds(shape)
			if not bool(bounds.get("conservative", false)):
				job.blocker_bounds.clear()
				return
			job.blocker_bounds.append(
				(owner_transform * (bounds["aabb"] as AABB)).grow(BLOCKER_BOUNDS_SLACK))

	# Colliders overlapped the envelope but nothing was bounded, which should be
	# unreachable -- a reported hit has a shape. Activating the broad phase on an
	# empty candidate set would reject every cell and silently leave grass inside
	# a blocker, so the exhaustive scan is the only safe reading of it.
	if job.blocker_bounds.is_empty():
		return

	# A candidate spanning the whole chunk cannot reject a single cell, so the
	# comparison would be pure overhead on top of the queries it never avoids.
	# Both paths produce the same mask; this only picks the cheaper one.
	for candidate in job.blocker_bounds:
		if candidate.encloses(envelope):
			return
	job.broad_phase_active = true


## Local-space bounds guaranteed to contain [param shape], with a
## [code]conservative[/code] flag that is false when the type has no bound this
## add-on can prove -- a heightmap, a world boundary, a degenerate point set.
## Only a conservative bound may reject an exact query.
##
## Cached per shape resource because a concave collider's bound costs a pass over
## every face, and a mask job would otherwise redo it for each chunk the collider
## touches. Editing a shape in place drops its entry, so a resized blocker is
## never compared against its old extent.
func _conservative_shape_bounds(shape: Shape3D) -> Dictionary:
	if shape == null:
		return {}
	var key := shape.get_instance_id()
	var cached: Dictionary = _shape_bounds_cache.get(key, {})
	if not cached.is_empty() and (cached["shape"] as WeakRef).get_ref() == shape:
		return cached
	var conservative: bool = TerrainGrassBlocker3D.shape_bounds_are_conservative(shape)
	var entry := {
		"shape": weakref(shape),
		"conservative": conservative,
		"aabb": TerrainGrassBlocker3D.shape_local_aabb(shape) if conservative else AABB(),
	}
	_shape_bounds_cache[key] = entry
	if not shape.changed.is_connected(_drop_cached_shape_bounds):
		shape.changed.connect(_drop_cached_shape_bounds.bind(key))
	return entry


func _drop_cached_shape_bounds(key: int) -> void:
	_shape_bounds_cache.erase(key)


func _finish_mask_job(job: MaskJob, chunk) -> void:
	mask_jobs_completed += 1
	if chunk.grass_revision == job.revision:
		chunk.occupancy = job.mask
		chunk.fine_occupancy = job.fine_mask
		var target_xz := Vector2(target.global_position.x, target.global_position.z)
		var local_target_xz := _world_to_local_xz(target_xz)
		var grass_prefetch_distance := float(settings.grass_prefetch_distance)
		_queue_grass_if_wanted(
			chunk,
			_distance_squared_to_chunk_aabb_local(
				local_target_xz, chunk.coord, float(settings.chunk_size)),
			grass_prefetch_distance * grass_prefetch_distance
		)
	_active_mask_job = null


## Queues a chunk's grass if it is close enough and is not already queued or
## being built.
##
## This has to be re-checked as the target moves, not decided once. A chunk that
## finishes its mask while it is still outside the prefetch radius -- which
## happens routinely at spawn, where the streaming target jumps from the
## placement anchor to the player -- would otherwise keep its terrain and never
## grow grass, however close the player later walked to it. The result is a
## permanent chunk-shaped bald patch, and because generation reports itself idle
## nothing ever comes back to fix it.
func _queue_grass_if_wanted(
	chunk,
	distance_squared: float,
	grass_prefetch_distance_squared: float
) -> void:
	if not chunk.terrain_ready or chunk.grass_ready:
		return
	if distance_squared > grass_prefetch_distance_squared:
		return
	for queued: Dictionary in _grass_queue:
		if queued["coord"] == chunk.coord:
			return
	for job in _active_build_jobs:
		if job.kind == &"grass" and job.coord == chunk.coord:
			return
	if _active_incremental_job != null \
			and _active_incremental_job.kind == &"grass" \
			and _active_incremental_job.coord == chunk.coord:
		return
	_grass_queue.append({
		"coord": chunk.coord,
		"revision": chunk.grass_revision,
		"distance_squared": distance_squared,
	})


func _cell_world_aabb(
	chunk,
	cell_index: int,
	resolution: int,
	spacing: float,
	world_transform: Transform3D
) -> AABB:
	var width: int = resolution + 1
	@warning_ignore("integer_division")
	var z: int = cell_index / resolution
	var x: int = cell_index - z * resolution
	var i00: int = z * width + x
	var h0: float = chunk.heights[i00]
	var h1: float = chunk.heights[i00 + 1]
	var h2: float = chunk.heights[i00 + width]
	var h3: float = chunk.heights[i00 + width + 1]
	var minimum := minf(minf(h0, h1), minf(h2, h3)) - MASK_QUERY_PADDING_BELOW
	var maximum: float = (maxf(maxf(h0, h1), maxf(h2, h3))
		+ float(settings.grass_height) + MASK_QUERY_PADDING_ABOVE)
	return world_transform * AABB(
		Vector3(chunk.position.x + float(x) * spacing, minimum, chunk.position.z + float(z) * spacing),
		Vector3(spacing, maximum - minimum, spacing)
	)


## Caches everything the sixteen subcell bounds of the newly active cell share:
## its four corner heights and the two origin terms. The expressions in
## _subcell_world_aabb are otherwise left exactly as they were, because folding
## `origin + (x + u) * spacing` into `(origin + x * spacing) + u * spacing` is
## not the same float and would move mask bits at cell boundaries.
func _cache_active_cell(job: MaskJob, chunk, cell_index: int, resolution: int, _spacing: float) -> void:
	var width: int = resolution + 1
	@warning_ignore("integer_division")
	var z: int = cell_index / resolution
	var x: int = cell_index - z * resolution
	var i00: int = z * width + x
	job.active_x = float(x)
	job.active_z = float(z)
	job.active_origin_x = chunk.position.x
	job.active_origin_z = chunk.position.z
	job.active_h00 = chunk.heights[i00]
	job.active_h10 = chunk.heights[i00 + 1]
	job.active_h01 = chunk.heights[i00 + width]
	job.active_h11 = chunk.heights[i00 + width + 1]


func _subcell_world_aabb(
	job: MaskJob,
	subcell_index: int,
	spacing: float,
	world_transform: Transform3D
) -> AABB:
	var sub_x := subcell_index % TerrainGenerator.FINE_MASK_SUBDIVISIONS
	@warning_ignore("integer_division")
	var sub_z: int = subcell_index / TerrainGenerator.FINE_MASK_SUBDIVISIONS
	var fraction_step := 1.0 / float(TerrainGenerator.FINE_MASK_SUBDIVISIONS)
	var u0 := float(sub_x) * fraction_step
	var v0 := float(sub_z) * fraction_step
	var u1 := u0 + fraction_step
	var v1 := v0 + fraction_step
	var h00 := job.active_h00
	var h10 := job.active_h10
	var h01 := job.active_h01
	var h11 := job.active_h11
	var height_a := _bilinear_height(h00, h10, h01, h11, u0, v0)
	var height_b := _bilinear_height(h00, h10, h01, h11, u1, v0)
	var height_c := _bilinear_height(h00, h10, h01, h11, u0, v1)
	var height_d := _bilinear_height(h00, h10, h01, h11, u1, v1)
	var minimum := minf(minf(height_a, height_b), minf(height_c, height_d)) - MASK_QUERY_PADDING_BELOW
	var maximum: float = (maxf(maxf(height_a, height_b), maxf(height_c, height_d))
		+ float(settings.grass_height) + MASK_QUERY_PADDING_ABOVE)
	# Jolt treats face contact as an overlap. Insetting one millimetre prevents
	# the subcell immediately outside an aligned wall from being removed too.
	var subcell_size: float = spacing * fraction_step
	var query_inset := minf(0.001, subcell_size * 0.1)
	return world_transform * AABB(
		Vector3(
			job.active_origin_x + (job.active_x + u0) * spacing + query_inset,
			minimum,
			job.active_origin_z + (job.active_z + v0) * spacing + query_inset
		),
		Vector3(subcell_size - query_inset * 2.0, maximum - minimum, subcell_size - query_inset * 2.0)
	)


func _bilinear_height(h00: float, h10: float, h01: float, h11: float, u: float, v: float) -> float:
	return lerpf(lerpf(h00, h10, u), lerpf(h01, h11, u), v)


## Whether one cell or subcell volume must lose its grass.
##
## The two candidate kinds stay separate on purpose. A registered fallback mesh
## has no collider at all, so its AABB overlap is the answer, exactly as before.
## A physics-backed blocker's conservative bound is never the answer: it only
## says the exact query still has to run. Overlapping nothing conservative is the
## one case that can skip the query, and only when the job proved it saw every
## collider that could reach this chunk.
func _bounds_are_blocked(job: MaskJob, bounds: AABB) -> bool:
	if _aabb_hits_fallback(bounds, job.fallback_aabbs):
		return true
	if not job.needs_physics_scan:
		return false
	if job.broad_phase_active and not job.candidate_overlaps(bounds):
		mask_broad_phase_rejections += 1
		return false
	return _query_hits_blocker(bounds)


func _aabb_hits_fallback(bounds: AABB, fallback_aabbs: Array[AABB]) -> bool:
	for fallback in fallback_aabbs:
		if fallback.intersects(bounds):
			return true
	return false


func _query_hits_blocker(bounds: AABB) -> bool:
	_cell_query_shape.size = bounds.size
	_cell_query.transform = Transform3D(Basis.IDENTITY, bounds.get_center())
	mask_query_count += 1
	mask_query_total += 1
	return not get_world_3d().direct_space_state.intersect_shape(_cell_query, 1).is_empty()


## Re-derives every loaded chunk's LOD band distances and re-selects immediately.
##
## Called when something outside the terrain changes a threshold the chunks
## cached -- in practice the renderer resolving its fog reach, which caps how far
## grass is worth drawing. Without the immediate re-selection a chunk would keep
## its stale band until the next LOD tick moved the streaming target.
func refresh_lod_thresholds() -> void:
	for coord_variant in chunks:
		chunks[coord_variant].refresh_lod_thresholds()
	if target != null and is_instance_valid(target):
		_update_lods()


func _update_lods() -> void:
	var target_xz := Vector2(target.global_position.x, target.global_position.z)
	var local_target_xz := _world_to_local_xz(target_xz)
	var chunk_size := float(settings.chunk_size)
	for coord_variant in chunks:
		var chunk = chunks[coord_variant]
		chunk.update_grass_lod_squared(
			_distance_squared_to_chunk_aabb_local(local_target_xz, chunk.coord, chunk_size))


func distance_to_chunk_aabb(world_xz: Vector2, coord: Vector2i) -> float:
	var local_xz := _world_to_local_xz(world_xz)
	return sqrt(_distance_squared_to_chunk_aabb_local(local_xz, coord, float(settings.chunk_size)))


func _distance_squared_to_chunk_aabb_local(
	local_xz: Vector2,
	coord: Vector2i,
	chunk_size: float
) -> float:
	var minimum := Vector2(float(coord.x) * chunk_size, float(coord.y) * chunk_size)
	var maximum := minimum + Vector2(chunk_size, chunk_size)
	var nearest := Vector2(
		clampf(local_xz.x, minimum.x, maximum.x),
		clampf(local_xz.y, minimum.y, maximum.y)
	)
	return local_xz.distance_squared_to(nearest)


func _world_to_local_xz(world_xz: Vector2) -> Vector2:
	var origin := _origin_position()
	return world_xz - Vector2(origin.x, origin.z)


func _origin_position() -> Vector3:
	return global_position if is_inside_tree() else position
