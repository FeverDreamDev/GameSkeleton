# Tracks what carves grass away (static blockers) and what bends it (dynamic
# interactors), and keeps the grass shader's interactor uniform up to date.
#
# Selection and upload run at different rates on purpose: which nodes are the
# most relevant few changes slowly, but their positions have to reach the shader
# every frame or the bend visibly lags the body that causes it.
extends Node3D

const TerrainSettingsScript = preload("res://addons/procedural_terrain_grass/core/terrain_settings.gd")

## Must match MAX_INTERACTORS in grass_shell.gdshader.
const MAX_SHADER_INTERACTORS := 8

var settings
var terrain_manager
var target: Node3D
var grass_material: ShaderMaterial
var dynamic_interaction_enabled: bool = true

var _static_records: Dictionary = {}
var _explicit_interactors: Dictionary = {}
var _discovered_bodies: Dictionary = {}
var _selected_interactors: Array[Dictionary] = []
var _interactor_uniforms: Array[Vector4] = []
var _uploaded_uniforms: Array[Vector4] = []
var _discovery_timer: float = 0.0
var _static_poll_timer: float = 0.0
var _selection_timer: float = INF
var _discovery_shape := SphereShape3D.new()
var _discovery_query := PhysicsShapeQueryParameters3D.new()


func _ready() -> void:
	if settings == null:
		settings = TerrainSettingsScript.new()
	_interactor_uniforms.resize(MAX_SHADER_INTERACTORS)
	_uploaded_uniforms.resize(MAX_SHADER_INTERACTORS)
	_discovery_shape.radius = settings.interactor_discovery_radius
	_discovery_query.shape = _discovery_shape
	_discovery_query.collision_mask = settings.interactor_query_mask
	_discovery_query.collide_with_bodies = true
	_discovery_query.collide_with_areas = false
	if grass_material != null:
		grass_material.set_shader_parameter("grass_interactors", _uploaded_uniforms)


func _process(delta: float) -> void:
	_static_poll_timer += delta
	if _static_poll_timer >= settings.interactor_discovery_interval:
		_static_poll_timer = 0.0
		_poll_static_records()
	if not dynamic_interaction_enabled:
		if not _selected_interactors.is_empty():
			_selected_interactors.clear()
		_upload_interactors()
		return
	# Ranking allocates a candidate list and sorts it, so it runs on the same
	# cadence as discovery rather than once per frame.
	_selection_timer += delta
	if _selection_timer >= settings.interactor_discovery_interval:
		_selection_timer = 0.0
		_select_interactors()
	_upload_interactors()


func _physics_process(delta: float) -> void:
	if not dynamic_interaction_enabled:
		return
	_discovery_timer += delta
	if _discovery_timer < settings.interactor_discovery_interval or target == null:
		return
	_discovery_timer = 0.0
	_discover_dynamic_bodies()


func register_static_grass_blocker(node: Node3D) -> void:
	if not is_instance_valid(node):
		return
	var instance_id := node.get_instance_id()
	var bounds := _world_bounds_for(node)
	_static_records[instance_id] = {
		"node": weakref(node),
		"bounds": bounds,
		"fallback": node is MeshInstance3D,
	}
	if terrain_manager != null and bounds.has_volume():
		terrain_manager.invalidate_grass_region(bounds)


func unregister_static_grass_blocker(node: Node3D) -> void:
	if node == null:
		return
	var instance_id := node.get_instance_id()
	if not _static_records.has(instance_id):
		return
	var old_bounds: AABB = _static_records[instance_id]["bounds"]
	_static_records.erase(instance_id)
	if terrain_manager != null and old_bounds.has_volume():
		terrain_manager.invalidate_grass_region(old_bounds)


func notify_static_blocker_changed(node: Node3D) -> void:
	if node == null:
		return
	var instance_id := node.get_instance_id()
	if not _static_records.has(instance_id):
		register_static_grass_blocker(node)
		return
	var record: Dictionary = _static_records[instance_id]
	var old_bounds: AABB = record["bounds"]
	var new_bounds := _world_bounds_for(node)
	record["bounds"] = new_bounds
	_static_records[instance_id] = record
	if terrain_manager != null:
		terrain_manager.invalidate_grass_region(old_bounds.merge(new_bounds))


func register_grass_interactor(node: Node3D) -> void:
	if is_instance_valid(node):
		_explicit_interactors[node.get_instance_id()] = weakref(node)


func unregister_grass_interactor(node: Node3D) -> void:
	if node != null:
		_explicit_interactors.erase(node.get_instance_id())


func invalidate_grass_region(world_bounds: AABB) -> void:
	if terrain_manager != null:
		terrain_manager.invalidate_grass_region(world_bounds)


func get_fallback_aabbs(overlap_bounds: AABB) -> Array[AABB]:
	var result: Array[AABB] = []
	for record_variant in _static_records.values():
		var record: Dictionary = record_variant
		if not bool(record["fallback"]):
			continue
		var bounds: AABB = record["bounds"]
		if bounds.intersects(overlap_bounds):
			result.append(bounds)
	return result


func get_active_interactor_data() -> Array[Vector4]:
	var result: Array[Vector4] = []
	for index in range(settings.active_interactor_limit):
		if _interactor_uniforms[index].z > 0.0:
			result.append(_interactor_uniforms[index])
	return result


func get_active_count() -> int:
	return _selected_interactors.size()


func _poll_static_records() -> void:
	var remove_ids: Array[int] = []
	for id_variant in _static_records.keys():
		var instance_id := int(id_variant)
		var record: Dictionary = _static_records[instance_id]
		var reference := record["node"] as WeakRef
		var node := reference.get_ref() as Node3D
		if not is_instance_valid(node):
			var removed_bounds: AABB = record["bounds"]
			if terrain_manager != null and removed_bounds.has_volume():
				terrain_manager.invalidate_grass_region(removed_bounds)
			remove_ids.append(instance_id)
			continue
		var old_bounds: AABB = record["bounds"]
		var new_bounds := _world_bounds_for(node)
		if not old_bounds.position.is_equal_approx(new_bounds.position) or not old_bounds.size.is_equal_approx(new_bounds.size):
			record["bounds"] = new_bounds
			_static_records[instance_id] = record
			if terrain_manager != null:
				terrain_manager.invalidate_grass_region(old_bounds.merge(new_bounds))
	for instance_id in remove_ids:
		_static_records.erase(instance_id)


func _discover_dynamic_bodies() -> void:
	_discovery_shape.radius = settings.interactor_discovery_radius
	_discovery_query.transform = Transform3D(Basis.IDENTITY, target.global_position)
	var results := get_world_3d().direct_space_state.intersect_shape(_discovery_query, 32)
	_discovered_bodies.clear()
	for hit in results:
		var collider := hit.get("collider") as Node3D
		if not is_instance_valid(collider):
			continue
		if not (collider is CharacterBody3D or collider is RigidBody3D or collider is AnimatableBody3D):
			continue
		var has_component := false
		for child in collider.get_children():
			if child is TerrainGrassInteractor3D:
				has_component = true
				break
		if has_component:
			continue
		_discovered_bodies[collider.get_instance_id()] = weakref(collider)


func _select_interactors() -> void:
	var candidates: Array[Dictionary] = []
	_collect_candidates(_explicit_interactors, candidates, true)
	_collect_candidates(_discovered_bodies, candidates, false)
	var target_position := _node_position(target) if target != null else Vector3.ZERO
	for candidate in candidates:
		var node := candidate["node"] as Node3D
		var distance := _node_position(node).distance_to(target_position)
		var distance_factor := maxf(0.0, 1.0 - distance / settings.interactor_discovery_radius)
		candidate["score"] = float(candidate["priority"]) * 1000.0 + float(candidate["strength"]) * distance_factor
	var reserved: Dictionary = {}
	var ranked: Array[Dictionary] = []
	for candidate in candidates:
		if reserved.is_empty() and candidate["node"] == target:
			reserved = candidate
		else:
			ranked.append(candidate)
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	_selected_interactors.clear()
	if not reserved.is_empty() and settings.active_interactor_limit > 0:
		_selected_interactors.append(reserved)
	var remaining_slots: int = int(settings.active_interactor_limit) - _selected_interactors.size()
	for index in range(mini(remaining_slots, ranked.size())):
		_selected_interactors.append(ranked[index])


func _collect_candidates(source: Dictionary, destination: Array[Dictionary], explicit: bool) -> void:
	var remove_ids: Array[int] = []
	for id_variant in source.keys():
		var instance_id := int(id_variant)
		var reference := source[instance_id] as WeakRef
		var node := reference.get_ref() as Node3D
		if not is_instance_valid(node):
			remove_ids.append(instance_id)
			continue
		if explicit:
			var component = _find_interactor_component(node)
			if component == null:
				destination.append({
					"node": node,
					"radius": settings.default_interactor_radius,
					"strength": settings.default_interactor_strength,
					"priority": 0,
				})
				continue
			destination.append({
				"node": node,
				"radius": component.radius,
				"strength": component.strength,
				"priority": component.priority,
			})
		else:
			destination.append({
				"node": node,
				"radius": settings.default_interactor_radius,
				"strength": settings.default_interactor_strength,
				"priority": 0,
			})
	for instance_id in remove_ids:
		source.erase(instance_id)


func _find_interactor_component(node: Node3D):
	if node is TerrainGrassInteractor3D:
		return node
	for child in node.get_children():
		if child is TerrainGrassInteractor3D:
			return child
	return null


func _upload_interactors() -> void:
	for index in range(MAX_SHADER_INTERACTORS):
		_interactor_uniforms[index] = Vector4.ZERO
	for index in range(_selected_interactors.size()):
		var candidate := _selected_interactors[index]
		var node := candidate["node"] as Node3D
		if not is_instance_valid(node):
			continue
		var world_position := _node_position(node)
		_interactor_uniforms[index] = Vector4(world_position.x, world_position.z, float(candidate["radius"]), float(candidate["strength"]))
	if grass_material == null or _interactor_uniforms == _uploaded_uniforms:
		return
	# Uploading an unchanged array still costs a material parameter write and a
	# uniform-buffer push, which is pure waste while nothing is moving. The
	# material is handed the copy so it never aliases the array mutated above.
	_uploaded_uniforms = _interactor_uniforms.duplicate()
	grass_material.set_shader_parameter("grass_interactors", _uploaded_uniforms)


func _node_position(node: Node3D) -> Vector3:
	return node.global_position if node.is_inside_tree() else node.position


func _world_bounds_for(node: Node3D) -> AABB:
	if node is TerrainGrassBlocker3D:
		return node.get_world_aabb()
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		return mesh_instance.global_transform * mesh_instance.get_aabb()
	var combined := AABB()
	var found := false
	for child in node.find_children("*", "CollisionShape3D", true, false):
		var collision := child as CollisionShape3D
		if collision == null or collision.shape == null:
			continue
		var bounds := collision.global_transform * TerrainGrassBlocker3D.shape_local_aabb(collision.shape)
		combined = bounds if not found else combined.merge(bounds)
		found = true
	if found:
		return combined
	return AABB(node.global_position, Vector3.ZERO)
