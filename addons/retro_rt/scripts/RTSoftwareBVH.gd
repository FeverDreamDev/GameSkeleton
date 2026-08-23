@tool
extends RefCounted
class_name RTSoftwareBVH

## Deterministic CPU BVH builder used by the fragment-shader RT backend.
##
## BLAS nodes are emitted into one global, depth-first array. A mesh record owns
## a contiguous range within that array, and every non-terminal escape index is
## absolute within the returned array. TLAS nodes follow the same convention.

const BLAS_LEAF_SIZE := 4
const TLAS_LEAF_SIZE := 1
const SAH_BIN_COUNT := 12
const MAX_BLAS_NODES_PER_MESH := 32768
const MAX_TLAS_NODES := 4096
const MAX_EXACT_FLOAT_INTEGER := 16777216
const CENTROID_EPSILON := 0.0000001
const BOUNDS_EPSILON := 0.0001


func build_blas(mesh_records: Array) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var nodes: Array[Dictionary] = []
	var triangles: Array[Dictionary] = []
	var meshes: Array[Dictionary] = []

	for mesh_index in mesh_records.size():
		var decoded := _decode_mesh(mesh_records[mesh_index], mesh_index)
		if not bool(decoded.get("ok", false)):
			return _blas_failure(str(decoded.get("error", "Unknown mesh decode error.")), started_usec)
		var source_triangles: Array = decoded["triangles"]
		var primitives: Array[Dictionary] = []
		primitives.resize(source_triangles.size())
		for triangle_index in source_triangles.size():
			var triangle: Dictionary = source_triangles[triangle_index]
			var bounds_min := _vector_min(
				_vector_min(triangle["v0"], triangle["v1"]),
				triangle["v2"]
			)
			var bounds_max := _vector_max(
				_vector_max(triangle["v0"], triangle["v1"]),
				triangle["v2"]
			)
			primitives[triangle_index] = {
				"min": bounds_min,
				"max": bounds_max,
				"centroid": (bounds_min + bounds_max) * 0.5,
				"source": triangle_index,
			}

		var tree_result := _build_flat_tree(primitives, BLAS_LEAF_SIZE, MAX_BLAS_NODES_PER_MESH)
		if not bool(tree_result.get("ok", false)):
			return _blas_failure(
				"Mesh %d BLAS build failed: %s" % [mesh_index, str(tree_result.get("error", "unknown error"))],
				started_usec
			)
		var tree: Array = tree_result["nodes"]
		if tree.is_empty():
			return _blas_failure("Mesh %d produced an empty BLAS." % mesh_index, started_usec)

		var node_start := nodes.size()
		var triangle_start := triangles.size()
		for local_node_index in tree.size():
			var source_node: Dictionary = tree[local_node_index]
			var local_end := int(source_node["end"])
			var absolute_end := node_start + local_end
			var leaf := bool(source_node["leaf"])
			var output_node := {
				"min": source_node["min"],
				"max": source_node["max"],
				"escape": absolute_end if local_end < tree.size() else -1,
				"leaf": leaf,
				"start": triangles.size() if leaf else 0,
				"count": 0,
				"end": absolute_end,
			}
			if leaf:
				var primitive_ids: Array = source_node["ids"]
				output_node["count"] = primitive_ids.size()
				for primitive_id_value in primitive_ids:
					var primitive_id := int(primitive_id_value)
					triangles.append(source_triangles[primitive_id])
			nodes.append(output_node)

		var root_node: Dictionary = tree[0]
		var mesh_bounds_min: Vector3 = root_node["min"]
		var mesh_bounds_max: Vector3 = root_node["max"]
		meshes.append({
			"root": node_start,
			"node_count": tree.size(),
			"bounds_min": mesh_bounds_min,
			"bounds_max": mesh_bounds_max,
			"bounds": AABB(mesh_bounds_min, mesh_bounds_max - mesh_bounds_min),
			"surface_count": int(decoded["surface_count"]),
			"triangle_start": triangle_start,
			"triangle_count": source_triangles.size(),
		})

	if nodes.size() >= MAX_EXACT_FLOAT_INTEGER or triangles.size() >= MAX_EXACT_FLOAT_INTEGER:
		return _blas_failure("BLAS output exceeds exact float-integer addressing range.", started_usec)

	var validation := validate_blas(nodes, triangles, meshes)
	if not bool(validation.get("ok", false)):
		return _blas_failure("BLAS validation failed: %s" % str(validation.get("error", "unknown error")), started_usec)
	return {
		"ok": true,
		"error": "",
		"nodes": nodes,
		"triangles": triangles,
		"meshes": meshes,
		"build_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
	}


func build_tlas(
	meshes: Array,
	instances: Array,
	transforms: Array,
	masks: PackedInt32Array
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	if instances.is_empty():
		return _tlas_failure("Cannot build a TLAS without instances.", started_usec)
	if transforms.size() != instances.size():
		return _tlas_failure(
			"TLAS transform count (%d) does not match instance count (%d)." % [transforms.size(), instances.size()],
			started_usec
		)
	if masks.size() != instances.size():
		return _tlas_failure(
			"TLAS mask count (%d) does not match instance count (%d)." % [masks.size(), instances.size()],
			started_usec
		)

	var primitives: Array[Dictionary] = []
	for instance_index in instances.size():
		var instance_value: Variant = instances[instance_index]
		if not (instance_value is Dictionary):
			return _tlas_failure("TLAS instance %d is not a dictionary." % instance_index, started_usec)
		var instance: Dictionary = instance_value
		var geometry_index := int(instance.get("geometry", -1))
		if geometry_index < 0 or geometry_index >= meshes.size():
			return _tlas_failure(
				"TLAS instance %d references invalid geometry %d." % [instance_index, geometry_index],
				started_usec
			)
		if not (transforms[instance_index] is Transform3D):
			return _tlas_failure("TLAS transform %d is not a Transform3D." % instance_index, started_usec)
		# A zero traversal mask is intentionally absent from the TLAS. Its source
		# instance index remains stable in all other tables and in visible leaves.
		if masks[instance_index] == 0:
			continue
		var transform: Transform3D = transforms[instance_index]
		var mesh: Dictionary = meshes[geometry_index]
		var local_min: Vector3 = mesh.get("bounds_min", Vector3.ZERO)
		var local_max: Vector3 = mesh.get("bounds_max", Vector3.ZERO)
		var world_bounds := _transform_bounds(local_min, local_max, transform)
		if not bool(world_bounds.get("ok", false)):
			return _tlas_failure("TLAS instance %d has non-finite bounds." % instance_index, started_usec)
		var bounds_min: Vector3 = world_bounds["min"]
		var bounds_max: Vector3 = world_bounds["max"]
		primitives.append({
			"min": bounds_min,
			"max": bounds_max,
			"centroid": (bounds_min + bounds_max) * 0.5,
			"source": instance_index,
			"mask": masks[instance_index],
		})

	if primitives.is_empty():
		return {
			"ok": true,
			"error": "",
			"nodes": [],
			"root": -1,
			"build_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
		}

	var tree_result := _build_flat_tree(primitives, TLAS_LEAF_SIZE, MAX_TLAS_NODES)
	if not bool(tree_result.get("ok", false)):
		return _tlas_failure("TLAS build failed: %s" % str(tree_result.get("error", "unknown error")), started_usec)
	var tree: Array = tree_result["nodes"]
	var nodes: Array[Dictionary] = []
	nodes.resize(tree.size())
	for node_index in tree.size():
		var source_node: Dictionary = tree[node_index]
		var local_end := int(source_node["end"])
		var leaf := bool(source_node["leaf"])
		var output_node := {
			"min": source_node["min"],
			"max": source_node["max"],
			"escape": local_end if local_end < tree.size() else -1,
			"leaf": leaf,
			"start": 0,
			"count": 0,
			"end": local_end,
			"mask": 0,
		}
		if leaf:
			var primitive_ids: Array = source_node["ids"]
			if primitive_ids.size() != 1:
				return _tlas_failure("TLAS leaf %d does not contain exactly one instance." % node_index, started_usec)
			var primitive_id := int(primitive_ids[0])
			var primitive: Dictionary = primitives[primitive_id]
			output_node["start"] = int(primitive["source"])
			output_node["count"] = 1
			output_node["mask"] = int(primitive["mask"])
		nodes[node_index] = output_node

	# The flattened tree is binary preorder. Propagate exact descendant-mask
	# unions from the leaves so traversal can reject an entire subtree before it
	# touches an instance record. The first child immediately follows its parent;
	# the second begins at the first child's exclusive end.
	for node_index in range(nodes.size() - 1, -1, -1):
		var node: Dictionary = nodes[node_index]
		if bool(node["leaf"]):
			continue
		var left_index := node_index + 1
		if left_index >= nodes.size():
			return _tlas_failure("TLAS internal node %d has no left child." % node_index, started_usec)
		var left: Dictionary = nodes[left_index]
		var right_index := int(left["end"])
		if right_index <= left_index or right_index >= int(node["end"]):
			return _tlas_failure("TLAS internal node %d has an invalid right child." % node_index, started_usec)
		var right: Dictionary = nodes[right_index]
		node["mask"] = int(left["mask"]) | int(right["mask"])
		nodes[node_index] = node

	var validation := _validate_tlas(nodes, primitives)
	if not bool(validation.get("ok", false)):
		return _tlas_failure("TLAS validation failed: %s" % str(validation.get("error", "unknown error")), started_usec)
	return {
		"ok": true,
		"error": "",
		"nodes": nodes,
		"root": 0,
		"build_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
	}


func validate_blas(nodes: Array, triangles: Array, meshes: Array) -> Dictionary:
	for mesh_index in meshes.size():
		var mesh_value: Variant = meshes[mesh_index]
		if not (mesh_value is Dictionary):
			return _validation_failure("Mesh output %d is not a dictionary." % mesh_index)
		var mesh: Dictionary = mesh_value
		var root := int(mesh.get("root", -1))
		var node_count := int(mesh.get("node_count", 0))
		var mesh_end := root + node_count
		var triangle_start := int(mesh.get("triangle_start", -1))
		var triangle_count := int(mesh.get("triangle_count", -1))
		var triangle_end := triangle_start + triangle_count
		if root < 0 or node_count <= 0 or mesh_end > nodes.size():
			return _validation_failure("Mesh %d has an invalid BLAS node range." % mesh_index)
		if node_count > MAX_BLAS_NODES_PER_MESH:
			return _validation_failure("Mesh %d exceeds the BLAS node limit." % mesh_index)
		if triangle_start < 0 or triangle_count <= 0 or triangle_end > triangles.size():
			return _validation_failure("Mesh %d has an invalid reordered triangle range." % mesh_index)
		var root_node: Dictionary = nodes[root]
		if int(root_node.get("escape", -2)) != -1:
			return _validation_failure("Mesh %d BLAS root escape must be -1." % mesh_index)
		if (
			not _bounds_equal(root_node["min"], mesh.get("bounds_min", Vector3.ZERO))
			or not _bounds_equal(root_node["max"], mesh.get("bounds_max", Vector3.ZERO))
		):
			return _validation_failure("Mesh %d root and mesh bounds disagree." % mesh_index)

		var seen := PackedByteArray()
		seen.resize(triangle_count)
		var active_parents: Array[Dictionary] = []
		for node_index in range(root, mesh_end):
			while not active_parents.is_empty() and node_index >= int(active_parents[-1]["end"]):
				active_parents.pop_back()
			var node_value: Variant = nodes[node_index]
			if not (node_value is Dictionary):
				return _validation_failure("Mesh %d node %d is not a dictionary." % [mesh_index, node_index])
			var node: Dictionary = node_value
			var bounds_min: Vector3 = node.get("min", Vector3.ZERO)
			var bounds_max: Vector3 = node.get("max", Vector3.ZERO)
			if not _valid_bounds(bounds_min, bounds_max):
				return _validation_failure("Mesh %d node %d has invalid bounds." % [mesh_index, node_index])
			var node_end := int(node.get("end", -1))
			if node_end <= node_index or node_end > mesh_end:
				return _validation_failure("Mesh %d node %d has an invalid subtree end." % [mesh_index, node_index])
			var expected_escape := node_end if node_end < mesh_end else -1
			if int(node.get("escape", -2)) != expected_escape:
				return _validation_failure("Mesh %d node %d has an invalid escape index." % [mesh_index, node_index])
			if not active_parents.is_empty():
				var parent: Dictionary = active_parents[-1]
				if not _bounds_contains(parent["min"], parent["max"], bounds_min, bounds_max):
					return _validation_failure("Mesh %d node %d escapes its parent bounds." % [mesh_index, node_index])

			if bool(node.get("leaf", false)):
				var leaf_start := int(node.get("start", -1))
				var leaf_count := int(node.get("count", 0))
				if leaf_count <= 0 or leaf_count > BLAS_LEAF_SIZE:
					return _validation_failure("Mesh %d leaf %d has invalid triangle count." % [mesh_index, node_index])
				if leaf_start < triangle_start or leaf_start + leaf_count > triangle_end:
					return _validation_failure("Mesh %d leaf %d has an invalid triangle range." % [mesh_index, node_index])
				for triangle_index in range(leaf_start, leaf_start + leaf_count):
					var triangle: Dictionary = triangles[triangle_index]
					var source_triangle := int(triangle.get("source_triangle", -1))
					if source_triangle < 0 or source_triangle >= triangle_count:
						return _validation_failure("Mesh %d contains an invalid source triangle." % mesh_index)
					if seen[source_triangle] != 0:
						return _validation_failure("Mesh %d contains source triangle %d more than once." % [mesh_index, source_triangle])
					seen[source_triangle] = 1
					var triangle_min := _vector_min(_vector_min(triangle["v0"], triangle["v1"]), triangle["v2"])
					var triangle_max := _vector_max(_vector_max(triangle["v0"], triangle["v1"]), triangle["v2"])
					if not _bounds_contains(bounds_min, bounds_max, triangle_min, triangle_max):
						return _validation_failure("Mesh %d leaf %d does not contain its triangle." % [mesh_index, node_index])
			else:
				if int(node.get("count", -1)) != 0 or node_index + 1 >= node_end:
					return _validation_failure("Mesh %d internal node %d is malformed." % [mesh_index, node_index])
				active_parents.append({"end": node_end, "min": bounds_min, "max": bounds_max})
		for source_triangle in triangle_count:
			if seen[source_triangle] == 0:
				return _validation_failure("Mesh %d is missing source triangle %d." % [mesh_index, source_triangle])
	return {"ok": true, "error": ""}


func _decode_mesh(mesh_value: Variant, mesh_index: int) -> Dictionary:
	if not (mesh_value is Dictionary):
		return {"ok": false, "error": "Mesh record %d is not a dictionary." % mesh_index}
	var mesh: Dictionary = mesh_value
	var raw_positions: Variant = mesh.get("positions")
	var raw_normals: Variant = mesh.get("normals")
	var raw_uvs: Variant = mesh.get("uvs")
	var raw_indices: Variant = mesh.get("indices")
	if (
		not (raw_positions is PackedByteArray)
		or not (raw_normals is PackedByteArray)
		or not (raw_uvs is PackedByteArray)
		or not (raw_indices is PackedByteArray)
	):
		return {"ok": false, "error": "Mesh %d has invalid packed vertex/UV/index data." % mesh_index}
	var position_bytes: PackedByteArray = raw_positions
	var normal_bytes: PackedByteArray = raw_normals
	var uv_bytes: PackedByteArray = raw_uvs
	var index_bytes: PackedByteArray = raw_indices
	var position_values := position_bytes.to_float32_array()
	var normal_values := normal_bytes.to_float32_array()
	var uv_values := uv_bytes.to_float32_array()
	var index_values := index_bytes.to_int32_array()
	if position_values.size() == 0 or position_values.size() % 4 != 0:
		return {"ok": false, "error": "Mesh %d position data is not packed vec4 data." % mesh_index}
	if normal_values.size() != position_values.size():
		return {"ok": false, "error": "Mesh %d normal data does not match its positions." % mesh_index}
	if index_values.size() == 0 or index_values.size() % 3 != 0:
		return {"ok": false, "error": "Mesh %d index data is not a triangle list." % mesh_index}
	var vertex_count := position_values.size() >> 2
	if uv_values.size() != vertex_count * 2:
		return {
			"ok": false,
			"error": "Mesh %d UV data does not contain one packed vec2 per vertex." % mesh_index,
		}
	if int(mesh.get("vertex_count", vertex_count)) != vertex_count:
		return {"ok": false, "error": "Mesh %d vertex count does not match its packed data." % mesh_index}
	if int(mesh.get("index_count", index_values.size())) != index_values.size():
		return {"ok": false, "error": "Mesh %d index count does not match its packed data." % mesh_index}

	var triangle_count := int(index_values.size() / 3.0)
	var surfaces_result := _decode_surfaces(mesh.get("triangle_surfaces"), triangle_count)
	if not bool(surfaces_result.get("ok", false)):
		return {"ok": false, "error": "Mesh %d %s" % [mesh_index, str(surfaces_result.get("error", "has invalid surfaces."))]}
	var surfaces: PackedInt32Array = surfaces_result["surfaces"]
	var surface_count := int(mesh.get("surface_count", 0))
	if surface_count <= 0:
		for surface in surfaces:
			surface_count = maxi(surface_count, surface + 1)
	if surface_count <= 0:
		return {"ok": false, "error": "Mesh %d has no valid surfaces." % mesh_index}

	var positions: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	positions.resize(vertex_count)
	normals.resize(vertex_count)
	uvs.resize(vertex_count)
	for vertex_index in vertex_count:
		var offset := vertex_index * 4
		var uv_offset := vertex_index * 2
		var position := Vector3(position_values[offset], position_values[offset + 1], position_values[offset + 2])
		var normal := Vector3(normal_values[offset], normal_values[offset + 1], normal_values[offset + 2])
		var uv := Vector2(uv_values[uv_offset], uv_values[uv_offset + 1])
		if not _vector_is_finite(position) or not _vector_is_finite(normal) or not _vector2_is_finite(uv):
			return {"ok": false, "error": "Mesh %d contains non-finite vertex data." % mesh_index}
		positions[vertex_index] = position
		normals[vertex_index] = normal
		uvs[vertex_index] = uv

	var triangles: Array[Dictionary] = []
	triangles.resize(triangle_count)
	for triangle_index in triangle_count:
		var index_offset := triangle_index * 3
		var i0 := index_values[index_offset]
		var i1 := index_values[index_offset + 1]
		var i2 := index_values[index_offset + 2]
		if i0 < 0 or i0 >= vertex_count or i1 < 0 or i1 >= vertex_count or i2 < 0 or i2 >= vertex_count:
			return {"ok": false, "error": "Mesh %d triangle %d has an out-of-range index." % [mesh_index, triangle_index]}
		var surface := surfaces[triangle_index]
		if surface < 0 or surface >= surface_count:
			return {"ok": false, "error": "Mesh %d triangle %d has an invalid surface." % [mesh_index, triangle_index]}
		triangles[triangle_index] = {
			"v0": positions[i0],
			"v1": positions[i1],
			"v2": positions[i2],
			"n0": normals[i0],
			"n1": normals[i1],
			"n2": normals[i2],
			"uv0": uvs[i0],
			"uv1": uvs[i1],
			"uv2": uvs[i2],
			"surface": surface,
			"source_triangle": triangle_index,
		}
	return {"ok": true, "error": "", "triangles": triangles, "surface_count": surface_count}


func _decode_surfaces(value: Variant, triangle_count: int) -> Dictionary:
	var surfaces := PackedInt32Array()
	if value is PackedInt32Array:
		surfaces = value
	elif value is PackedByteArray:
		var surface_bytes: PackedByteArray = value
		surfaces = surface_bytes.to_int32_array()
	else:
		return {"ok": false, "error": "triangle surface data is not packed int32 data."}
	if surfaces.size() != triangle_count:
		return {
			"ok": false,
			"error": "triangle surface count (%d) does not match triangle count (%d)." % [surfaces.size(), triangle_count],
		}
	return {"ok": true, "error": "", "surfaces": surfaces}


func _build_flat_tree(primitives: Array[Dictionary], leaf_size: int, maximum_nodes: int) -> Dictionary:
	if primitives.is_empty():
		return {"ok": false, "error": "No primitives were supplied.", "nodes": []}
	var initial_ids: Array[int] = []
	initial_ids.resize(primitives.size())
	for primitive_index in primitives.size():
		initial_ids[primitive_index] = primitive_index
	var tasks: Array[Dictionary] = [{"ids": initial_ids, "depth": 0}]
	var nodes: Array[Dictionary] = []

	while not tasks.is_empty():
		var task: Dictionary = tasks.pop_back()
		var ids: Array = task["ids"]
		var depth := int(task["depth"])
		var bounds := _primitive_bounds(ids, primitives)
		if ids.size() <= leaf_size:
			nodes.append({
				"min": bounds["min"],
				"max": bounds["max"],
				"leaf": true,
				"ids": ids,
				"depth": depth,
				"end": 0,
			})
		else:
			var split := _partition_primitives(ids, primitives)
			if not bool(split.get("ok", false)):
				return {"ok": false, "error": str(split.get("error", "Unable to split primitives.")), "nodes": []}
			var left_ids: Array = split["left"]
			var right_ids: Array = split["right"]
			nodes.append({
				"min": bounds["min"],
				"max": bounds["max"],
				"leaf": false,
				"ids": [],
				"depth": depth,
				"end": 0,
			})
			# LIFO ordering emits left then right in depth-first preorder.
			tasks.append({"ids": right_ids, "depth": depth + 1})
			tasks.append({"ids": left_ids, "depth": depth + 1})
		if nodes.size() + tasks.size() > maximum_nodes:
			return {"ok": false, "error": "Node count exceeds the %d-node limit." % maximum_nodes, "nodes": []}

	var active: Array[int] = []
	for node_index in nodes.size():
		var node_depth := int(nodes[node_index]["depth"])
		while not active.is_empty() and node_depth <= int(nodes[active[-1]]["depth"]):
			var completed_index: int = active.pop_back()
			var completed: Dictionary = nodes[completed_index]
			completed["end"] = node_index
			nodes[completed_index] = completed
		active.append(node_index)
	while not active.is_empty():
		var completed_index: int = active.pop_back()
		var completed: Dictionary = nodes[completed_index]
		completed["end"] = nodes.size()
		nodes[completed_index] = completed
	return {"ok": true, "error": "", "nodes": nodes}


func _partition_primitives(ids: Array, primitives: Array[Dictionary]) -> Dictionary:
	var centroid_min := Vector3(INF, INF, INF)
	var centroid_max := Vector3(-INF, -INF, -INF)
	for id_value in ids:
		var primitive: Dictionary = primitives[int(id_value)]
		centroid_min = _vector_min(centroid_min, primitive["centroid"])
		centroid_max = _vector_max(centroid_max, primitive["centroid"])
	var centroid_extent := centroid_max - centroid_min

	var best_axis := -1
	var best_split := -1
	var best_cost := INF
	for axis in 3:
		var extent := _axis_value(centroid_extent, axis)
		if extent <= CENTROID_EPSILON:
			continue
		var counts := PackedInt32Array()
		counts.resize(SAH_BIN_COUNT)
		var bin_mins: Array[Vector3] = []
		var bin_maxs: Array[Vector3] = []
		bin_mins.resize(SAH_BIN_COUNT)
		bin_maxs.resize(SAH_BIN_COUNT)
		for bin_index in SAH_BIN_COUNT:
			bin_mins[bin_index] = Vector3(INF, INF, INF)
			bin_maxs[bin_index] = Vector3(-INF, -INF, -INF)
		for id_value in ids:
			var primitive: Dictionary = primitives[int(id_value)]
			var bin_index := _sah_bin(primitive["centroid"], centroid_min, centroid_extent, axis)
			counts[bin_index] += 1
			bin_mins[bin_index] = _vector_min(bin_mins[bin_index], primitive["min"])
			bin_maxs[bin_index] = _vector_max(bin_maxs[bin_index], primitive["max"])

		var left_counts := PackedInt32Array()
		var right_counts := PackedInt32Array()
		var left_mins: Array[Vector3] = []
		var left_maxs: Array[Vector3] = []
		var right_mins: Array[Vector3] = []
		var right_maxs: Array[Vector3] = []
		left_counts.resize(SAH_BIN_COUNT - 1)
		right_counts.resize(SAH_BIN_COUNT - 1)
		left_mins.resize(SAH_BIN_COUNT - 1)
		left_maxs.resize(SAH_BIN_COUNT - 1)
		right_mins.resize(SAH_BIN_COUNT - 1)
		right_maxs.resize(SAH_BIN_COUNT - 1)
		var running_count := 0
		var running_min := Vector3(INF, INF, INF)
		var running_max := Vector3(-INF, -INF, -INF)
		for split_index in SAH_BIN_COUNT - 1:
			running_count += counts[split_index]
			if counts[split_index] > 0:
				running_min = _vector_min(running_min, bin_mins[split_index])
				running_max = _vector_max(running_max, bin_maxs[split_index])
			left_counts[split_index] = running_count
			left_mins[split_index] = running_min
			left_maxs[split_index] = running_max
		running_count = 0
		running_min = Vector3(INF, INF, INF)
		running_max = Vector3(-INF, -INF, -INF)
		for split_index in range(SAH_BIN_COUNT - 2, -1, -1):
			var bin_index := split_index + 1
			running_count += counts[bin_index]
			if counts[bin_index] > 0:
				running_min = _vector_min(running_min, bin_mins[bin_index])
				running_max = _vector_max(running_max, bin_maxs[bin_index])
			right_counts[split_index] = running_count
			right_mins[split_index] = running_min
			right_maxs[split_index] = running_max
		for split_index in SAH_BIN_COUNT - 1:
			if left_counts[split_index] == 0 or right_counts[split_index] == 0:
				continue
			var cost := (
				_surface_area(left_mins[split_index], left_maxs[split_index]) * float(left_counts[split_index])
				+ _surface_area(right_mins[split_index], right_maxs[split_index]) * float(right_counts[split_index])
			)
			if cost < best_cost - CENTROID_EPSILON:
				best_cost = cost
				best_axis = axis
				best_split = split_index

	if best_axis >= 0:
		var left: Array[int] = []
		var right: Array[int] = []
		for id_value in ids:
			var primitive_id := int(id_value)
			var primitive: Dictionary = primitives[primitive_id]
			var bin_index := _sah_bin(primitive["centroid"], centroid_min, centroid_extent, best_axis)
			if bin_index <= best_split:
				left.append(primitive_id)
			else:
				right.append(primitive_id)
		if not left.is_empty() and not right.is_empty():
			return {"ok": true, "left": left, "right": right}

	var fallback_axis := 0
	if centroid_extent.y > centroid_extent.x:
		fallback_axis = 1
	if _axis_value(centroid_extent, 2) > _axis_value(centroid_extent, fallback_axis):
		fallback_axis = 2
	var sorted_ids := _sort_ids_by_axis(ids, primitives, fallback_axis)
	var midpoint := sorted_ids.size() >> 1
	if midpoint <= 0 or midpoint >= sorted_ids.size():
		return {"ok": false, "error": "Median fallback could not split %d primitives." % sorted_ids.size()}
	return {
		"ok": true,
		"left": sorted_ids.slice(0, midpoint),
		"right": sorted_ids.slice(midpoint),
	}


func _sort_ids_by_axis(ids: Array, primitives: Array[Dictionary], axis: int) -> Array:
	var sorted: Array = ids.duplicate()
	var scratch: Array = ids.duplicate()
	var width := 1
	while width < sorted.size():
		var start := 0
		while start < sorted.size():
			var middle := mini(start + width, sorted.size())
			var end := mini(start + width * 2, sorted.size())
			var left := start
			var right := middle
			var output := start
			while left < middle or right < end:
				if right >= end or (left < middle and _primitive_less(int(sorted[left]), int(sorted[right]), primitives, axis)):
					scratch[output] = sorted[left]
					left += 1
				else:
					scratch[output] = sorted[right]
					right += 1
				output += 1
			start += width * 2
		var swap := sorted
		sorted = scratch
		scratch = swap
		width *= 2
	return sorted


func _primitive_less(a: int, b: int, primitives: Array[Dictionary], axis: int) -> bool:
	var a_primitive: Dictionary = primitives[a]
	var b_primitive: Dictionary = primitives[b]
	var a_value := _axis_value(a_primitive["centroid"], axis)
	var b_value := _axis_value(b_primitive["centroid"], axis)
	if a_value != b_value:
		return a_value < b_value
	return int(a_primitive["source"]) < int(b_primitive["source"])


func _primitive_bounds(ids: Array, primitives: Array[Dictionary]) -> Dictionary:
	var bounds_min := Vector3(INF, INF, INF)
	var bounds_max := Vector3(-INF, -INF, -INF)
	for id_value in ids:
		var primitive: Dictionary = primitives[int(id_value)]
		bounds_min = _vector_min(bounds_min, primitive["min"])
		bounds_max = _vector_max(bounds_max, primitive["max"])
	return {"min": bounds_min, "max": bounds_max}


func _transform_bounds(local_min: Vector3, local_max: Vector3, transform: Transform3D) -> Dictionary:
	var world_min := Vector3(INF, INF, INF)
	var world_max := Vector3(-INF, -INF, -INF)
	for corner in 8:
		var local_corner := Vector3(
			local_max.x if (corner & 1) != 0 else local_min.x,
			local_max.y if (corner & 2) != 0 else local_min.y,
			local_max.z if (corner & 4) != 0 else local_min.z
		)
		var world_corner := transform * local_corner
		if not _vector_is_finite(world_corner):
			return {"ok": false}
		world_min = _vector_min(world_min, world_corner)
		world_max = _vector_max(world_max, world_corner)
	return {"ok": true, "min": world_min, "max": world_max}


func _validate_tlas(nodes: Array, primitives: Array[Dictionary]) -> Dictionary:
	if nodes.is_empty() or nodes.size() > MAX_TLAS_NODES:
		return _validation_failure("TLAS node count is invalid.")
	if int(nodes[0].get("escape", -2)) != -1:
		return _validation_failure("TLAS root escape must be -1.")
	var primitive_by_source: Dictionary = {}
	var seen: Dictionary = {}
	for primitive_value in primitives:
		var primitive: Dictionary = primitive_value
		var source := int(primitive["source"])
		if source < 0 or primitive_by_source.has(source):
			return _validation_failure("TLAS primitive source indices are invalid or duplicated.")
		primitive_by_source[source] = primitive
		seen[source] = false
	var active_parents: Array[Dictionary] = []
	for node_index in nodes.size():
		while not active_parents.is_empty() and node_index >= int(active_parents[-1]["end"]):
			active_parents.pop_back()
		var node: Dictionary = nodes[node_index]
		var bounds_min: Vector3 = node["min"]
		var bounds_max: Vector3 = node["max"]
		var node_end := int(node["end"])
		if not _valid_bounds(bounds_min, bounds_max) or node_end <= node_index or node_end > nodes.size():
			return _validation_failure("TLAS node %d has invalid bounds or range." % node_index)
		var expected_escape := node_end if node_end < nodes.size() else -1
		if int(node["escape"]) != expected_escape:
			return _validation_failure("TLAS node %d has an invalid escape." % node_index)
		if not active_parents.is_empty():
			var parent: Dictionary = active_parents[-1]
			if not _bounds_contains(parent["min"], parent["max"], bounds_min, bounds_max):
				return _validation_failure("TLAS node %d escapes its parent bounds." % node_index)
		if bool(node["leaf"]):
			if int(node["count"]) != 1:
				return _validation_failure("TLAS leaf %d must contain one instance." % node_index)
			var source := int(node["start"])
			if not primitive_by_source.has(source) or bool(seen[source]):
				return _validation_failure("TLAS leaf %d has an invalid or duplicate instance." % node_index)
			seen[source] = true
			var primitive: Dictionary = primitive_by_source[source]
			if not _bounds_contains(bounds_min, bounds_max, primitive["min"], primitive["max"]):
				return _validation_failure("TLAS leaf %d does not contain its instance." % node_index)
			if int(node.get("mask", 0)) != int(primitive["mask"]):
				return _validation_failure("TLAS leaf %d has an incorrect traversal mask." % node_index)
		else:
			if int(node["count"]) != 0 or node_index + 1 >= node_end:
				return _validation_failure("TLAS internal node %d is malformed." % node_index)
			var left_index := node_index + 1
			var left: Dictionary = nodes[left_index]
			var right_index := int(left["end"])
			if right_index <= left_index or right_index >= node_end:
				return _validation_failure("TLAS internal node %d has invalid child ranges." % node_index)
			var right: Dictionary = nodes[right_index]
			var expected_mask := int(left.get("mask", 0)) | int(right.get("mask", 0))
			if int(node.get("mask", 0)) != expected_mask or expected_mask == 0:
				return _validation_failure("TLAS internal node %d has an incorrect subtree mask." % node_index)
			active_parents.append({"end": node_end, "min": bounds_min, "max": bounds_max})
	for source in seen:
		if not bool(seen[source]):
			return _validation_failure("TLAS is missing instance %d." % source)
	return {"ok": true, "error": ""}


func _sah_bin(centroid: Vector3, centroid_min: Vector3, centroid_extent: Vector3, axis: int) -> int:
	var normalized := (
		(_axis_value(centroid, axis) - _axis_value(centroid_min, axis))
		/ _axis_value(centroid_extent, axis)
	)
	return clampi(int(floor(normalized * float(SAH_BIN_COUNT))), 0, SAH_BIN_COUNT - 1)


func _surface_area(bounds_min: Vector3, bounds_max: Vector3) -> float:
	var extent := _vector_max(bounds_max - bounds_min, Vector3.ZERO)
	return 2.0 * (extent.x * extent.y + extent.y * extent.z + extent.z * extent.x)


func _axis_value(value: Vector3, axis: int) -> float:
	if axis == 0:
		return value.x
	if axis == 1:
		return value.y
	return value.z


func _vector_min(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))


func _vector_max(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))


func _vector_is_finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _vector2_is_finite(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


func _valid_bounds(bounds_min: Vector3, bounds_max: Vector3) -> bool:
	return (
		_vector_is_finite(bounds_min)
		and _vector_is_finite(bounds_max)
		and bounds_min.x <= bounds_max.x
		and bounds_min.y <= bounds_max.y
		and bounds_min.z <= bounds_max.z
	)


func _bounds_contains(outer_min: Vector3, outer_max: Vector3, inner_min: Vector3, inner_max: Vector3) -> bool:
	return (
		inner_min.x >= outer_min.x - BOUNDS_EPSILON
		and inner_min.y >= outer_min.y - BOUNDS_EPSILON
		and inner_min.z >= outer_min.z - BOUNDS_EPSILON
		and inner_max.x <= outer_max.x + BOUNDS_EPSILON
		and inner_max.y <= outer_max.y + BOUNDS_EPSILON
		and inner_max.z <= outer_max.z + BOUNDS_EPSILON
	)


func _bounds_equal(a: Vector3, b: Vector3) -> bool:
	return a.distance_squared_to(b) <= BOUNDS_EPSILON * BOUNDS_EPSILON


func _blas_failure(message: String, started_usec: int) -> Dictionary:
	return {
		"ok": false,
		"error": message,
		"nodes": [],
		"triangles": [],
		"meshes": [],
		"build_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
	}


func _tlas_failure(message: String, started_usec: int) -> Dictionary:
	return {
		"ok": false,
		"error": message,
		"nodes": [],
		"root": -1,
		"build_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
	}


func _validation_failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
