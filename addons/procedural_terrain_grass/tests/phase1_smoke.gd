extends SceneTree

const GrassInteractionManagerScript = preload(
	"res://addons/procedural_terrain_grass/core/grass_interaction_manager.gd")
const TerrainSettingsScript = preload(
	"res://addons/procedural_terrain_grass/core/terrain_settings.gd")
const TerrainGrassBlockerScript = preload(
	"res://addons/procedural_terrain_grass/terrain_grass_blocker_3d.gd")
const GrassShader = preload(
	"res://addons/procedural_terrain_grass/shaders/grass_shell.gdshader")

const SHADER_INTERACTOR_CAPACITY := 8

var _failures := PackedStringArray()
var _owned_nodes: Array[Node] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	var settings = TerrainSettingsScript.new()
	settings.active_interactor_limit = SHADER_INTERACTOR_CAPACITY
	var material := ShaderMaterial.new()
	material.shader = GrassShader
	var manager = GrassInteractionManagerScript.new()
	manager.settings = settings
	manager.grass_material = material
	# Initialize through normal tree entry, but keep discovery/selection timers
	# from racing the deliberately constructed states asserted below.
	manager.set_process(false)
	manager.set_physics_process(false)
	root.add_child(manager)

	_check_uploaded_state(manager, material, [], false, "initial")

	var nodes: Array[Node3D] = []
	var candidates: Array[Dictionary] = []
	var expected: Array[Vector4] = []
	for index in SHADER_INTERACTOR_CAPACITY:
		var node := Node3D.new()
		node.position = Vector3(float(index + 1), 0.0, float(-2 * index - 1))
		_owned_nodes.append(node)
		nodes.append(node)
		var radius := 0.5 + float(index) * 0.125
		var strength := 0.75 + float(index) * 0.125
		candidates.append({
			"node": node,
			"radius": radius,
			"strength": strength,
			"priority": index,
		})
		expected.append(Vector4(node.position.x, node.position.z, radius, strength))

	_upload_selection(manager, candidates.slice(0, 1))
	_check_uploaded_state(manager, material, expected.slice(0, 1), true, "one interactor")

	_upload_selection(manager, candidates.slice(0, 4))
	_check_uploaded_state(manager, material, expected.slice(0, 4), true, "four interactors")

	_upload_selection(manager, candidates)
	_check_uploaded_state(manager, material, expected, true, "eight interactors")

	# Keep the freed node in the selected array. Upload must skip it and compact
	# every later live entry forward without changing their relative order.
	nodes[3].free()
	var compacted_expected: Array[Vector4] = []
	for index in SHADER_INTERACTOR_CAPACITY:
		if index != 3:
			compacted_expected.append(expected[index])
	_upload_selection(manager, candidates)
	_check_uploaded_state(
		manager, material, compacted_expected, true, "invalid selected node compaction")

	var reduced_candidates: Array[Dictionary] = [candidates[0], candidates[1]]
	var reduced_expected: Array[Vector4] = [expected[0], expected[1]]
	_upload_selection(manager, reduced_candidates)
	_check_uploaded_state(manager, material, reduced_expected, true, "count decrease")

	# Exercise the public per-frame behavior rather than manually clearing the
	# private selection: disabling interaction must publish a zero count, clear
	# every stale slot and lower the shader's enabled flag.
	manager.dynamic_interaction_enabled = false
	manager.call(&"_process", 0.0)
	_check_uploaded_state(manager, material, [], false, "dynamic interaction disabled")

	_test_blocker_polling_classification(manager)
	_finish(manager)


func _upload_selection(manager: Node, selection: Array[Dictionary]) -> void:
	manager.set(&"_selected_interactors", selection)
	manager.call(&"_upload_interactors")


func _check_uploaded_state(
	manager: Node,
	material: ShaderMaterial,
	expected: Array[Vector4],
	expected_enabled: bool,
	label: String
) -> void:
	_check(
		manager.call(&"get_active_count") == expected.size(),
		"%s: manager count is %d" % [label, expected.size()])
	_check(
		int(material.get_shader_parameter(&"u_interactor_count")) == expected.size(),
		"%s: shader count is %d" % [label, expected.size()])
	_check(
		bool(material.get_shader_parameter(&"u_interaction_enabled")) == expected_enabled,
		"%s: shader enabled is %s" % [label, expected_enabled])

	var uploaded := _shader_interactors(material)
	_check(
		uploaded.size() == SHADER_INTERACTOR_CAPACITY,
		"%s: shader array retains capacity %d" % [label, SHADER_INTERACTOR_CAPACITY])
	if uploaded.size() != SHADER_INTERACTOR_CAPACITY:
		return
	for index in expected.size():
		_check(
			uploaded[index].is_equal_approx(expected[index]),
			"%s: slot %d preserves compacted data" % [label, index])
	for index in range(expected.size(), SHADER_INTERACTOR_CAPACITY):
		_check(
			uploaded[index].is_equal_approx(Vector4.ZERO),
			"%s: stale slot %d is zero" % [label, index])

	var public_data: Array[Vector4] = manager.call(&"get_active_interactor_data")
	_check(
		public_data.size() == expected.size(),
		"%s: public active data has %d entries" % [label, expected.size()])
	if public_data.size() == expected.size():
		for index in expected.size():
			_check(
				public_data[index].is_equal_approx(expected[index]),
				"%s: public active slot %d matches upload" % [label, index])


func _shader_interactors(material: ShaderMaterial) -> Array[Vector4]:
	var result: Array[Vector4] = []
	var value: Variant = material.get_shader_parameter(&"grass_interactors")
	if value is Array or value is PackedVector4Array:
		for entry in value:
			result.append(entry)
	return result


func _test_blocker_polling_classification(manager: Node) -> void:
	var blocker = TerrainGrassBlockerScript.new()
	blocker.blocker_shape = BoxShape3D.new()
	_owned_nodes.append(blocker)
	root.add_child(blocker)
	manager.call(&"register_static_grass_blocker", blocker)
	var blocker_id := blocker.get_instance_id()
	var records: Dictionary = manager.get(&"_static_records")
	var polling_ids: Dictionary = manager.get(&"_polling_static_ids")
	_check(records.has(blocker_id), "notifying blocker is registered")
	if records.has(blocker_id):
		_check(
			not bool((records[blocker_id] as Dictionary)["requires_polling"]),
			"TerrainGrassBlocker3D does not require polling")
	_check(
		not polling_ids.has(blocker_id),
		"TerrainGrassBlocker3D is absent from polling IDs")

	var generic := MeshInstance3D.new()
	generic.mesh = BoxMesh.new()
	_owned_nodes.append(generic)
	root.add_child(generic)
	manager.call(&"register_static_grass_blocker", generic)
	var generic_id := generic.get_instance_id()
	records = manager.get(&"_static_records")
	polling_ids = manager.get(&"_polling_static_ids")
	_check(records.has(generic_id), "generic MeshInstance3D blocker is registered")
	if records.has(generic_id):
		_check(
			bool((records[generic_id] as Dictionary)["requires_polling"]),
			"generic MeshInstance3D blocker requires polling")
	_check(
		polling_ids.has(generic_id),
		"generic MeshInstance3D blocker remains in polling IDs")


func _finish(manager: Node) -> void:
	for node in _owned_nodes:
		if is_instance_valid(node):
			node.free()
	if is_instance_valid(manager):
		manager.free()
	if _failures.is_empty():
		print("phase1_smoke: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("phase1_smoke: %s" % failure)
	quit(1)
