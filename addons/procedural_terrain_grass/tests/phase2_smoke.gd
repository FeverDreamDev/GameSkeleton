extends SceneTree

## Focused checks for the Phase 2 instanced-shell architecture and the masking
## broad phase, covering the things a screenshot cannot prove:
##
##   * every shell instance carries exactly the value the duplicated-shell vertex
##     colour used to carry, compared against a real ArrayMesh round trip rather
##     than against a restatement of the same formula;
##   * shell instance transforms stay identity, so nothing rotates or scales the
##     normals the lighting reads;
##   * the base grass surface keeps the vertex format, the partial-cell corner
##     duplication and the omitted indices masking depends on;
##   * an LOD or quality change swaps a prebuilt resource and never rebuilds
##     instance data, and a remask replaces the mesh under the same shells;
##   * only shapes whose bounds provably contain them are usable for rejection.
##
##   godot --path . --headless --script \
##       res://addons/procedural_terrain_grass/tests/phase2_smoke.gd

const TerrainGenerator = preload("res://addons/procedural_terrain_grass/core/terrain_generator.gd")
const TerrainChunkScript = preload("res://addons/procedural_terrain_grass/core/terrain_chunk.gd")
const TerrainSettingsScript = preload("res://addons/procedural_terrain_grass/core/terrain_settings.gd")
const IncrementalBuild = preload("res://addons/procedural_terrain_grass/core/terrain_build_state.gd")
const TerrainGrassBlockerScript = preload("res://addons/procedural_terrain_grass/terrain_grass_blocker_3d.gd")

var _failures := PackedStringArray()
var _owned: Array[Node] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	var settings = TerrainSettingsScript.new()
	var snapshot := settings.snapshot()

	_check_shell_quantisation(snapshot)
	_check_shape_bounds_conservatism()
	_check_base_surface(settings, snapshot)
	if _multimesh_storage_available():
		_check_shell_instances(snapshot)
		_check_lod_swapping(settings, snapshot)
	else:
		print("phase2_smoke: MultiMesh storage is stubbed on this renderer; "
			+ "instance and LOD checks need --rendering-method forward_plus or gl_compatibility.")

	for node in _owned:
		if is_instance_valid(node):
			node.free()

	if _failures.is_empty():
		print("phase2_smoke: OK")
		quit(0)
		return
	for failure in _failures:
		printerr("phase2_smoke: %s" % failure)
	quit(1)


## True when the renderer actually stores MultiMesh instance data. The headless
## dummy driver accepts every call and keeps nothing -- instance_count sticks but
## the data does not -- which would make every instance assertion below pass
## vacuously, so this writes a value and reads it back rather than trusting the
## count.
func _multimesh_storage_available() -> bool:
	var probe := MultiMesh.new()
	probe.transform_format = MultiMesh.TRANSFORM_3D
	probe.use_custom_data = true
	probe.mesh = PlaceholderMesh.new()
	probe.instance_count = 2
	if probe.instance_count != 2:
		return false
	probe.set_instance_custom_data(1, Color(0.5, 0.0, 0.0, 0.0))
	return probe.get_instance_custom_data(1).r == 0.5


#region Shell encoding

## The value the shader receives must equal, exactly, what the old path produced.
##
## Ground truth is a real ArrayMesh: authoring Color(layer, 1, 1, 1) and reading
## the surface back reproduces Godot's own unorm8 storage, which is the only
## thing that settles whether the engine rounds or truncates. Comparing against
## a second copy of the add-on's formula would prove nothing.
func _check_shell_quantisation(snapshot: Dictionary) -> void:
	var layer_sets := TerrainGenerator.grass_shell_layer_sets(snapshot)
	_check(layer_sets.size() == TerrainGenerator.GRASS_LOD_VARIANT_COUNT,
		"three shell layer sets are produced")
	var expected_counts := [
		int(snapshot["near_shell_count"]),
		int(snapshot["medium_shell_count"]),
		int(snapshot["far_shell_count"]),
	]
	for variant in layer_sets.size():
		var layers := layer_sets[variant]
		_check(layers.size() == expected_counts[variant],
			"variant %d keeps its authored shell count" % variant)
		var stored := _round_trip_vertex_colors(layers)
		for index in layers.size():
			var quantised := _as_float32(TerrainGenerator.shell_fraction_quantized(layers[index]))
			_check(quantised == stored[index],
				"variant %d shell %d decodes to the old vertex-colour value (%.9f vs %.9f)" % [
					variant, index, quantised, stored[index]])

	_check(TerrainGenerator.shell_fraction_byte(0.0) == 0, "shell 0.0 encodes to byte 0")
	_check(TerrainGenerator.shell_fraction_byte(1.0) == 255, "shell 1.0 encodes to byte 255")
	# Clamped rather than wrapped: a settings change must never produce a shell
	# above the canopy or below the roots.
	_check(TerrainGenerator.shell_fraction_byte(1.5) == 255, "an over-range shell clamps to 255")
	_check(TerrainGenerator.shell_fraction_byte(-0.5) == 0, "an under-range shell clamps to 0")


## A GDScript float narrowed to the single precision every one of these values
## actually lives at. Both sides of the comparisons above are 32-bit by the time
## the GPU sees them -- Color components, MultiMesh custom data and the vertex
## buffer all are -- while a GDScript literal is a double, and comparing the two
## widths would fail on the last few bits of a value that is in fact identical.
func _as_float32(value: float) -> float:
	var narrowed := PackedFloat32Array([value])
	return narrowed[0]


## Every fraction pushed through ARRAY_COLOR.r and read straight back out.
func _round_trip_vertex_colors(fractions: PackedFloat32Array) -> PackedFloat32Array:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	for fraction in fractions:
		vertices.append(Vector3(fraction, 0.0, 0.0))
		colors.append(Color(fraction, 1.0, 1.0, 1.0))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var stored: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var result := PackedFloat32Array()
	for color in stored:
		result.append(color.r)
	return result


func _check_shell_instances(snapshot: Dictionary) -> void:
	var buffers := TerrainGenerator.grass_shell_instance_buffers(snapshot)
	var layer_sets := TerrainGenerator.grass_shell_layer_sets(snapshot)
	_check(buffers.size() == TerrainGenerator.GRASS_LOD_VARIANT_COUNT,
		"one instance buffer per LOD variant")
	for variant in buffers.size():
		var layers := layer_sets[variant]
		var buffer := buffers[variant]
		_check(buffer.size() == layers.size() * TerrainGenerator.GRASS_INSTANCE_STRIDE,
			"variant %d buffer is one stride per shell" % variant)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_custom_data = true
		multimesh.mesh = PlaceholderMesh.new()
		multimesh.instance_count = layers.size()
		multimesh.buffer = buffer
		for index in layers.size():
			var custom := multimesh.get_instance_custom_data(index)
			# Whatever the backend's storage precision, INSTANCE_CUSTOM.x times
			# u_shell_decode_scale has to land back on the fraction the
			# duplicated-shell vertex colour carried. On Compatibility that costs
			# one float32 rounding, which is why this is a tolerance rather than
			# an equality; on Forward+ the multiply is by 1.0 and it is exact.
			var decoded := custom.r * TerrainGenerator.shell_decode_scale()
			var expected := TerrainGenerator.shell_fraction_quantized(layers[index])
			_check(absf(decoded - expected) <= 1e-6,
				"variant %d instance %d decodes to its shell fraction (%.9f vs %.9f)" % [
					variant, index, decoded, expected])
			if not TerrainGenerator.shell_data_is_byte_encoded():
				_check(custom.r == _as_float32(expected),
					"variant %d instance %d is stored exactly where custom data is float32" % [
						variant, index])
			else:
				# The byte itself must survive float16 storage untouched, which is
				# the whole reason Compatibility gets the integer.
				_check(custom.r == float(TerrainGenerator.shell_fraction_byte(layers[index])),
					"variant %d instance %d keeps its byte through float16 storage" % [
						variant, index])
			# A non-identity instance transform would displace the shell instead
			# of the shader lifting it along the terrain normal, and would rotate
			# the normals with it.
			_check(multimesh.get_instance_transform(index) == Transform3D.IDENTITY,
				"variant %d instance %d transform is identity" % [variant, index])

#endregion

#region Base surface

## One surface carrying what the shader and the mask still read: a normal to lift
## the shell along, the fine-mask bytes in COLOR.gb, the per-cell UV corners, and
## an index buffer with the fully blocked cells left out.
func _check_base_surface(settings, snapshot: Dictionary) -> void:
	var resolution := int(snapshot["resolution"])
	var width := resolution + 1
	var heights := PackedFloat32Array()
	var normals := PackedVector3Array()
	heights.resize(width * width)
	normals.resize(width * width)
	for index in width * width:
		heights[index] = sin(float(index) * 0.05)
		normals[index] = Vector3.UP
	var occupancy := PackedByteArray()
	occupancy.resize(TerrainGenerator.mask_byte_count(resolution))
	occupancy.fill(255)
	var fine := PackedByteArray()
	fine.resize(resolution * resolution * TerrainGenerator.FINE_MASK_BYTES_PER_CELL)
	fine.fill(255)

	# One fully blocked cell, which must lose its indices, and one partial cell,
	# which must gain four corners of its own.
	TerrainGenerator.mask_set(occupancy, 5, false)
	TerrainGenerator.fine_mask_set(fine, 5, 0)
	TerrainGenerator.fine_mask_set(fine, 9, 0x0f0f)

	var state = IncrementalBuild.new()
	state.configure_grass(Vector2i.ZERO, 1, heights, normals, occupancy, fine, snapshot)
	while not state.step(Time.get_ticks_usec() + 5_000_000):
		pass
	var arrays: Array = state.output["arrays"]

	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	_check(vertices.size() == width * width + 4,
		"the base surface is one grid plus four corners for the one partial cell, got %d" % vertices.size())
	_check((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).size() == vertices.size(),
		"every base vertex carries a terrain normal")
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	_check(indices.size() == (resolution * resolution - 1) * 6,
		"the fully blocked cell is absent from the index buffer, got %d" % indices.size())

	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	_check(colors[0].g == 1.0 and colors[0].b == 1.0,
		"a shared grid vertex carries a full fine mask")
	var partial_base := width * width
	_check(is_equal_approx(colors[partial_base].g, 15.0 / 255.0)
			and is_equal_approx(colors[partial_base].b, 15.0 / 255.0),
		"a partial cell's corners carry its two fine-mask bytes")
	_check(uvs[partial_base] == Vector2(0.0, 0.0) and uvs[partial_base + 3] == Vector2(1.0, 1.0),
		"a partial cell's corners span the whole cell in UV")

	# The surface has to survive the commit unchanged, since the vertex format is
	# what the shader warmup pairs the grass material against.
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var format := mesh.surface_get_format(0)
	for slot in [Mesh.ARRAY_FORMAT_VERTEX, Mesh.ARRAY_FORMAT_NORMAL,
			Mesh.ARRAY_FORMAT_COLOR, Mesh.ARRAY_FORMAT_TEX_UV, Mesh.ARRAY_FORMAT_INDEX]:
		_check(format & slot != 0, "the committed grass surface keeps array slot %d" % slot)

#endregion

#region LOD

func _check_lod_swapping(settings, snapshot: Dictionary) -> void:
	var buffers := TerrainGenerator.grass_shell_instance_buffers(snapshot)
	var chunk = TerrainChunkScript.new()
	_owned.append(chunk)
	chunk.configure(Vector2i.ZERO, 1, settings, null, null, buffers)
	root.add_child(chunk)

	_check(chunk.grass_multimeshes.size() == TerrainGenerator.GRASS_LOD_VARIANT_COUNT,
		"a chunk builds one MultiMesh per LOD variant")
	var expected_counts := [
		int(snapshot["near_shell_count"]),
		int(snapshot["medium_shell_count"]),
		int(snapshot["far_shell_count"]),
	]
	for variant in chunk.grass_multimeshes.size():
		_check(chunk.grass_multimeshes[variant].instance_count == expected_counts[variant],
			"variant %d holds its authored shell count" % variant)
	_check(not chunk.grass_mesh_instance.visible, "grass stays hidden until a surface arrives")

	var near_distance: float = settings.lod_medium_to_near * 0.5
	chunk.publish_grass_mesh_squared(_stub_grass_mesh(), near_distance * near_distance)
	_check(chunk.grass_ready, "publishing a base surface makes the chunk grass-ready")
	_check(chunk.grass_mesh_instance.visible, "the canopy shows once published")
	_check(chunk.grass_mesh_instance.multimesh == chunk.grass_multimeshes[TerrainChunkScript.LOD_NEAR],
		"a close chunk draws the near shell set")
	for multimesh in chunk.grass_multimeshes:
		_check(multimesh.mesh == chunk.grass_base_mesh,
			"every shell set points at the one base surface")

	# Walking out and back must cross the authored bands with their hysteresis,
	# and must never leave a stale resource on the instance.
	var far_distance: float = settings.lod_medium_to_far + 1.0
	chunk.update_grass_lod_squared(far_distance * far_distance)
	_check(chunk.grass_mesh_instance.multimesh == chunk.grass_multimeshes[TerrainChunkScript.LOD_FAR],
		"crossing the medium-to-far band draws the far shell set")
	var hysteresis_distance: float = (settings.lod_far_to_medium + settings.lod_medium_to_far) * 0.5
	chunk.update_grass_lod_squared(hysteresis_distance * hysteresis_distance)
	_check(chunk.grass_mesh_instance.multimesh == chunk.grass_multimeshes[TerrainChunkScript.LOD_FAR],
		"the far band holds through its hysteresis window")
	var hidden_distance: float = settings.lod_far_to_hidden + 1.0
	chunk.update_grass_lod_squared(hidden_distance * hidden_distance)
	_check(not chunk.grass_mesh_instance.visible, "past the last band the canopy is hidden")

	# A quality drop shifts the band towards a coarser prebuilt set. It must not
	# touch instance data: that is what makes the change free.
	chunk.update_grass_lod_squared(near_distance * near_distance)
	var near_buffer: PackedFloat32Array = chunk.grass_multimeshes[TerrainChunkScript.LOD_NEAR].buffer
	chunk.refresh_grass_quality(1, false)
	_check(chunk.grass_mesh_instance.multimesh == chunk.grass_multimeshes[TerrainChunkScript.LOD_MEDIUM],
		"a one-step quality bias draws the next coarser shell set")
	chunk.refresh_grass_quality(2, false)
	_check(chunk.grass_mesh_instance.multimesh == chunk.grass_multimeshes[TerrainChunkScript.LOD_FAR],
		"a two-step quality bias draws the far shell set")
	chunk.refresh_grass_quality(0, true)
	_check(not chunk.grass_mesh_instance.visible, "suppressed quality hides the canopy")
	chunk.refresh_grass_quality(0, false)
	_check(chunk.grass_mesh_instance.multimesh == chunk.grass_multimeshes[TerrainChunkScript.LOD_NEAR],
		"returning to full quality restores the near shell set")
	_check(chunk.grass_multimeshes[TerrainChunkScript.LOD_NEAR].buffer == near_buffer,
		"LOD and quality changes leave shell instance data untouched")

	# A blocker moving re-masks the chunk, which replaces the surface. The shells
	# must be re-pointed, not rebuilt.
	var remasked := _stub_grass_mesh()
	chunk.publish_grass_mesh_squared(remasked, near_distance * near_distance)
	for variant in chunk.grass_multimeshes.size():
		var multimesh: MultiMesh = chunk.grass_multimeshes[variant]
		_check(multimesh.mesh == remasked, "variant %d follows the remasked surface" % variant)
		_check(multimesh.instance_count == expected_counts[variant],
			"variant %d keeps its shell count across a remask" % variant)
	_check(chunk.grass_multimeshes[TerrainChunkScript.LOD_NEAR].buffer == near_buffer,
		"a remask leaves shell instance data untouched")


func _stub_grass_mesh() -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO, Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2.ZERO, Vector2(1.0, 0.0), Vector2(0.0, 1.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

#endregion

#region Masking broad phase

## Only a shape whose AABB provably contains it may reject an exact query. The
## unit-cube fallback shape_local_aabb returns for anything else is a footprint
## hint, not a bound, and using it for rejection would grow grass through a
## blocker larger than a metre.
func _check_shape_bounds_conservatism() -> void:
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 2.0, 3.0)
	var convex := ConvexPolygonShape3D.new()
	convex.points = PackedVector3Array([
		Vector3(-2.0, 0.0, -2.0), Vector3(2.0, 0.0, -2.0),
		Vector3(0.0, 3.0, 2.0), Vector3(0.0, -1.0, 0.0)])
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(PackedVector3Array([
		Vector3(-5.0, 0.0, -5.0), Vector3(5.0, 0.0, -5.0), Vector3(0.0, 4.0, 5.0)]))

	for shape in [box, SphereShape3D.new(), CapsuleShape3D.new(), CylinderShape3D.new(),
			convex, concave]:
		_check(TerrainGrassBlockerScript.shape_bounds_are_conservative(shape),
			"%s can be bounded conservatively" % shape.get_class())

	var heightmap := HeightMapShape3D.new()
	for shape in [heightmap, WorldBoundaryShape3D.new(), SeparationRayShape3D.new(),
			ConvexPolygonShape3D.new(), ConcavePolygonShape3D.new()]:
		_check(not TerrainGrassBlockerScript.shape_bounds_are_conservative(shape),
			"%s is never used to reject an exact query" % shape.get_class())

	# The derived bounds must actually contain the shape they claim to.
	var box_bounds := TerrainGrassBlockerScript.shape_local_aabb(box)
	_check(box_bounds.position.is_equal_approx(-box.size * 0.5)
			and box_bounds.size.is_equal_approx(box.size),
		"a box's bounds are its own extent")
	var convex_bounds := TerrainGrassBlockerScript.shape_local_aabb(convex)
	for point in convex.points:
		_check(convex_bounds.grow(0.0001).has_point(point),
			"a convex hull's bounds contain every point")

#endregion
