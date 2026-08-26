extends SceneTree

## Phase 2 memory / streaming / masking benchmark for the terrain-grass add-on.
##
## Runs the streaming runtime headlessly around a scripted target, waits for
## generation to drain, and prints the record the Phase 2 plan asks for: grass
## geometry per chunk, resource counts, worker and commit time, exact physics
## query totals, and mask-job CPU time.
##
## It deliberately reads the chunk's published resources rather than the
## generator's intermediates, so the same script measures the duplicated-shell
## architecture and the instanced one and the two numbers are comparable.
##
##   BENCH_SCENARIO=name   blocker layout, see _build_scenario
##   BENCH_LABEL=str       printed with the record
##   BENCH_DUMP=path       write the exact occupancy + fine-mask bytes here
##   BENCH_SWEEP=1         also time a deterministic run across chunk borders
##
##   godot --path . --headless --script \
##       res://addons/procedural_terrain_grass/tests/phase2_bench.gd

const TerrainGrassScript = preload("res://addons/procedural_terrain_grass/terrain_grass_3d.gd")
const TerrainGrassBlockerScript = preload("res://addons/procedural_terrain_grass/terrain_grass_blocker_3d.gd")
const TerrainGenerator = preload("res://addons/procedural_terrain_grass/core/terrain_generator.gd")

## Mirrors game/levels/terrain_test.tscn so the benchmark and the played level
## stream the same amount of work.
const LOAD_DISTANCE := 64.0
const UNLOAD_DISTANCE := 96.0
const BLOCKER_LAYER := 1 << 7

var _terrain: Node3D
var _manager: Node3D
var _target: Node3D
var _blocker_count: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := Node3D.new()
	world.name = "BenchWorld"
	root.add_child(world)

	_target = Node3D.new()
	_target.name = "StreamingTarget"
	world.add_child(_target)

	_terrain = TerrainGrassScript.new()
	_terrain.name = "TerrainGrass3D"
	_terrain.auto_start = false
	_terrain.editor_preview_enabled = false
	_terrain.terrain_load_distance = LOAD_DISTANCE
	_terrain.terrain_unload_distance = UNLOAD_DISTANCE
	_terrain.lod_near_to_medium = 52.0
	_terrain.lod_medium_to_near = 46.0
	_terrain.lod_medium_to_far = 62.0
	_terrain.lod_far_to_medium = 56.0
	_terrain.streaming_target = _target
	world.add_child(_terrain)

	_build_scenario(world, OS.get_environment("BENCH_SCENARIO"))
	# Blockers register deferred, and registration invalidates chunks. Letting
	# them land before streaming starts keeps the measured mask work to one pass.
	await physics_frame
	await physics_frame

	_manager = _terrain.get_node_or_null("_TerrainManager") as Node3D
	if _manager == null:
		printerr("phase2_bench: terrain runtime did not start")
		quit(2)
		return

	var started_msec := Time.get_ticks_msec()
	_terrain.start_streaming()
	if not await _wait_for(func() -> bool: return _terrain.is_generation_idle(), 4000):
		printerr("phase2_bench: streaming never went idle")
		quit(2)
		return
	var settle_msec := Time.get_ticks_msec() - started_msec

	_report(OS.get_environment("BENCH_LABEL"), settle_msec)

	var dump_path := OS.get_environment("BENCH_DUMP")
	if not dump_path.is_empty():
		_dump_masks(dump_path)

	if OS.get_environment("BENCH_SWEEP") == "1":
		await _sweep()

	quit(0)


func _wait_for(predicate: Callable, frames: int) -> bool:
	for i in frames:
		if bool(predicate.call()):
			return true
		await process_frame
	return bool(predicate.call())


#region Scenarios

## Blocker layouts from the Phase 2 masking benchmark list. Every body sits on
## the blocker query layer; only the TerrainGrassBlocker3D entries register
## themselves with the system, so the "unregistered" cases stay exercised.
func _build_scenario(world: Node3D, scenario: String) -> void:
	match scenario:
		"", "none":
			return
		"tiny":
			_add_blocker(world, Vector3(4.0, 0.0, 4.0), Vector3(0.6, 2.0, 0.6))
		"several":
			for index in 6:
				_add_blocker(world,
					Vector3(float(index) * 7.0 - 18.0, 0.0, float(index % 3) * 9.0 - 9.0),
					Vector3(0.8, 2.0, 0.8))
		"building":
			_add_blocker(world, Vector3(6.0, 0.0, -6.0), Vector3(14.0, 6.0, 10.0))
		"scattered":
			for z in range(-2, 3):
				for x in range(-2, 3):
					_add_blocker(world,
						Vector3(float(x) * 31.0 + 3.0, 0.0, float(z) * 31.0 - 5.0),
						Vector3(1.4, 2.0, 1.4))
		"full_chunk":
			# One chunk is 32 m across; this covers a whole one and then some, so
			# every cell in it is a real overlap and the broad phase saves nothing.
			_add_blocker(world, Vector3(16.0, 0.0, 16.0), Vector3(40.0, 20.0, 40.0))
		"overlapping":
			for index in 8:
				_add_blocker(world,
					Vector3(2.0 + float(index) * 0.7, 0.0, 2.0 + float(index) * 0.7),
					Vector3(6.0, 4.0, 6.0))
		"boundary":
			# Faces flush with a cell boundary at the chunk edge: the case an
			# exclusive AABB test would wrongly reject.
			_add_blocker(world, Vector3(32.0, 0.0, 16.0), Vector3(4.0, 6.0, 4.0))
			_add_blocker(world, Vector3(8.0, 0.0, 8.0), Vector3(2.0, 6.0, 2.0))
		"unsupported":
			_add_unsupported_blocker(world, Vector3(5.0, 0.0, 5.0))
		"unregistered":
			_add_unregistered_body(world, Vector3(5.0, 0.0, 5.0), Vector3(3.0, 4.0, 3.0))
		"mixed":
			_add_blocker(world, Vector3(6.0, 0.0, -6.0), Vector3(9.0, 6.0, 7.0))
			_add_unregistered_body(world, Vector3(-9.0, 0.0, 4.0), Vector3(3.0, 4.0, 3.0))
			_add_blocker(world, Vector3(32.0, 0.0, 16.0), Vector3(4.0, 6.0, 4.0))
			for index in 4:
				_add_blocker(world,
					Vector3(float(index) * 11.0 - 22.0, 0.0, 18.0),
					Vector3(0.9, 2.0, 0.9))
		_:
			printerr("phase2_bench: unknown scenario '%s'" % scenario)


func _add_blocker(world: Node3D, position: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var blocker = TerrainGrassBlockerScript.new()
	blocker.name = "Blocker%d" % _blocker_count
	blocker.blocker_shape = shape
	world.add_child(blocker)
	blocker.global_position = Vector3(position.x, _terrain.sample_height(
		Vector2(position.x, position.z)) + size.y * 0.5 - 0.5, position.z)
	_blocker_count += 1


## A shape TerrainGrassBlocker3D cannot bound conservatively, which must force
## the exact per-cell scan rather than being used for rejection.
func _add_unsupported_blocker(world: Node3D, position: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "UnsupportedBlocker%d" % _blocker_count
	body.collision_layer = BLOCKER_LAYER
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := HeightMapShape3D.new()
	shape.map_width = 3
	shape.map_depth = 3
	shape.map_data = PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	collision.shape = shape
	body.add_child(collision)
	world.add_child(body)
	body.global_position = Vector3(position.x, _terrain.sample_height(
		Vector2(position.x, position.z)) + 0.2, position.z)
	_blocker_count += 1


## On the blocker query layer but never registered with the system. Phase 2 must
## keep carving grass out from under it.
func _add_unregistered_body(world: Node3D, position: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "UnregisteredBlocker%d" % _blocker_count
	body.collision_layer = BLOCKER_LAYER
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	world.add_child(body)
	body.global_position = Vector3(position.x, _terrain.sample_height(
		Vector2(position.x, position.z)) + size.y * 0.5 - 0.5, position.z)
	_blocker_count += 1

#endregion

#region Reporting

func _report(label: String, settle_msec: int) -> void:
	if label.is_empty():
		label = "default"
	var chunks: Array = _terrain.get_loaded_chunks()
	var grass_chunks := 0
	var vertices := 0
	var indices := 0
	var mesh_resources := 0
	var multimesh_resources := 0
	var instances := 0
	for chunk in chunks:
		var measured := _measure_chunk_grass(chunk)
		if measured.is_empty():
			continue
		grass_chunks += 1
		vertices += int(measured["vertices"])
		indices += int(measured["indices"])
		mesh_resources += int(measured["meshes"])
		multimesh_resources += int(measured["multimeshes"])
		instances += int(measured["instances"])

	var divisor := float(maxi(grass_chunks, 1))
	print("phase2_bench [%s] scenario=%s" % [
		label, _scenario_name()])
	print("  Godot %s   renderer %s   threads %s" % [
		Engine.get_version_info().get("string", "?"),
		RenderingServer.get_current_rendering_method(),
		_manager.generation_backend_name()])
	print("  chunk size %.1f   resolution %d   density %.1f   grass height %.2f" % [
		float(_terrain.chunk_size), int(_terrain.chunk_resolution),
		float(_terrain.grass_density), float(_terrain.grass_height)])
	print("  shells near/medium/far %d/%d/%d   load distance %.1f" % [
		int(_terrain.near_shell_count), int(_terrain.medium_shell_count),
		int(_terrain.far_shell_count), float(_terrain.terrain_load_distance)])
	print("  loaded chunks %d (grass on %d)   static blockers %d" % [
		chunks.size(), grass_chunks, _blocker_count])
	print("  grass vertices/chunk %.1f   indices/chunk %.1f" % [
		float(vertices) / divisor, float(indices) / divisor])
	print("  grass Mesh resources/chunk %.2f   MultiMesh/chunk %.2f   instances/chunk %.2f" % [
		float(mesh_resources) / divisor, float(multimesh_resources) / divisor,
		float(instances) / divisor])
	print("  approx persistent grass geometry %.2f MiB (%.1f KiB/chunk)" % [
		float(_geometry_bytes(vertices, indices)) / 1048576.0,
		float(_geometry_bytes(vertices, indices)) / divisor / 1024.0])
	print("  settle to idle %d ms" % settle_msec)
	print("  worker terrain %.2f ms total   worker grass %.2f ms total (%.3f ms/chunk)" % [
		float(_manager.terrain_build_usec_total) / 1000.0,
		float(_manager.grass_build_usec_total) / 1000.0,
		float(_manager.grass_build_usec_total) / 1000.0 / divisor])
	print("  commit terrain %.2f ms total   commit grass %.2f ms total (%.3f ms/chunk)" % [
		float(_manager.terrain_commit_usec_total) / 1000.0,
		float(_manager.grass_commit_usec_total) / 1000.0,
		float(_manager.grass_commit_usec_total) / 1000.0 / divisor])
	print("  mask jobs %d   exact physics queries %d   broad-phase rejections %d" % [
		int(_manager.mask_jobs_completed), int(_manager.mask_query_total),
		int(_manager.mask_broad_phase_rejections)])
	print("  mask CPU %.2f ms total (%.3f ms/job)" % [
		float(_manager.mask_job_usec_total) / 1000.0,
		float(_manager.mask_job_usec_total) / 1000.0 / float(maxi(int(_manager.mask_jobs_completed), 1))])
	var masks := _mask_blob()
	print("  occupancy+fine-mask bytes %d   hash %d" % [masks.size(), hash(masks)])
	print("  engine static memory %.2f MiB   objects %d" % [
		float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
		int(Performance.get_monitor(Performance.OBJECT_COUNT))])


func _scenario_name() -> String:
	var scenario := OS.get_environment("BENCH_SCENARIO")
	return "none" if scenario.is_empty() else scenario


## Grass geometry actually resident for one chunk: one base ArrayMesh with three
## MultiMesh resources over it.
##
## Read off the published resources rather than off the generator, so the figure
## is the geometry that really exists and the same measurement can be taken from
## an older checkout of the add-on for comparison.
func _measure_chunk_grass(chunk) -> Dictionary:
	var base: ArrayMesh = chunk.grass_base_mesh
	if base == null:
		return {}
	var instances := 0
	for multimesh in chunk.grass_multimeshes:
		instances += int((multimesh as MultiMesh).instance_count)
	var vertices := 0
	var indices := 0
	for surface in base.get_surface_count():
		vertices += base.surface_get_array_len(surface)
		indices += base.surface_get_array_index_len(surface)
	return {
		"vertices": vertices,
		"indices": indices,
		"meshes": 1,
		"multimeshes": chunk.grass_multimeshes.size(),
		"instances": instances,
	}


## Vertex payload the grass surfaces actually declare: position (12 B), packed
## normal+tangent (8 B), UV (8 B in the uncompressed attribute block), colour
## (4 B) and a 32-bit index. Close enough to compare two architectures; the
## engine exposes no per-resource VRAM figure.
func _geometry_bytes(vertices: int, indices: int) -> int:
	return vertices * 32 + indices * 4


## Every loaded chunk's exact mask bytes in a stable coordinate order, which is
## what a byte-for-byte before/after comparison needs.
func _mask_blob() -> PackedByteArray:
	var coords: Array[Vector2i] = []
	for chunk in _terrain.get_loaded_chunks():
		coords.append(chunk.coord)
	coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x)
	var blob := PackedByteArray()
	for coord in coords:
		var chunk = _terrain.get_chunk(coord)
		blob.append_array(var_to_bytes(coord))
		blob.append_array(chunk.occupancy)
		blob.append_array(chunk.fine_occupancy)
	return blob


func _dump_masks(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("phase2_bench: could not write %s" % path)
		return
	file.store_buffer(_mask_blob())
	file.close()
	print("  wrote %s" % path)


## Deterministic walk across chunk borders, which is where streaming spikes
## live. Frame intervals are wall clock, so this is only meaningful headless
## against another headless run.
func _sweep() -> void:
	var samples := PackedFloat64Array()
	var previous := Time.get_ticks_usec()
	for step in 600:
		_target.global_position = Vector3(float(step) * 0.6, 0.0, float(step) * 0.35)
		await process_frame
		var now := Time.get_ticks_usec()
		samples.append(float(now - previous) / 1000.0)
		previous = now
	var sorted := samples.duplicate()
	sorted.sort()
	print("  sweep frames %d   median %.3f ms   p95 %.3f ms   p99 %.3f ms   max %.3f ms" % [
		sorted.size(), _percentile(sorted, 0.5), _percentile(sorted, 0.95),
		_percentile(sorted, 0.99), sorted[sorted.size() - 1]])
	print("  sweep worker grass %.2f ms   commit grass %.2f ms   exact queries %d" % [
		float(_manager.grass_build_usec_total) / 1000.0,
		float(_manager.grass_commit_usec_total) / 1000.0,
		int(_manager.mask_query_total)])


func _percentile(sorted: PackedFloat64Array, fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(int(floor(fraction * float(sorted.size() - 1))), 0, sorted.size() - 1)]

#endregion
