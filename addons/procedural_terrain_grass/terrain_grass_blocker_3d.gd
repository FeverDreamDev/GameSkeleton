@tool
@icon("res://addons/procedural_terrain_grass/icons/terrain_grass_blocker_3d.svg")
class_name TerrainGrassBlocker3D
extends Area3D

## Carves grass out of the region its shape covers.
##
## Give it a [member blocker_shape] and place it in the world. The area sits on
## the terrain system's blocker query layer, so the chunk masker finds it while
## building each chunk's occupancy mask. The shape draws a gizmo in the editor,
## which is the easiest way to line one up with a prop.

const TerrainGrassBinding = preload("res://addons/procedural_terrain_grass/core/terrain_grass_binding.gd")

## Region to clear. Primitive, convex-polygon and concave-polygon shapes get an
## exact bounding box; unsupported shape types fall back to a unit cube in the
## broad phase.
@export var blocker_shape: Shape3D:
	set(value):
		if blocker_shape == value:
			return
		_disconnect_shape_changed()
		blocker_shape = value
		_connect_shape_changed()
		_refresh_local_shape_aabb()
		if is_instance_valid(_collision_shape):
			_collision_shape.shape = blocker_shape
		if is_instance_valid(_terrain_system):
			_terrain_system.notify_static_blocker_changed(self)
		update_configuration_warnings()

## Terrain system to attach to. Only needed when a scene holds more than one
## TerrainGrass3D; otherwise the single system is found automatically.
@export_node_path("Node3D") var terrain_system_path: NodePath

var _collision_shape: CollisionShape3D
var _terrain_system: Node
var _local_shape_aabb := AABB()
var _local_shape_aabb_valid: bool = false


func _ready() -> void:
	# Scene deserialization can assign the exported resource before this node is
	# ready. Re-establishing the connection here keeps in-place edits such as
	# BoxShape3D.size and ConvexPolygonShape3D.points self-notifying too.
	_connect_shape_changed()
	_refresh_local_shape_aabb()
	# Internal so the shape draws its gizmo in the editor without appearing in
	# the user's scene tree or being written into their .tscn.
	_collision_shape = CollisionShape3D.new()
	_collision_shape.name = "BlockerShape"
	_collision_shape.shape = blocker_shape
	add_child(_collision_shape, false, Node.INTERNAL_MODE_FRONT)
	if Engine.is_editor_hint():
		return
	# The area exists only to be found by the masker's shape queries: it never
	# reports overlaps itself, so monitoring stays off.
	collision_mask = 0
	monitoring = false
	monitorable = true
	# Replaced with the system's configured mask once one is resolved.
	collision_layer = 1 << 7
	set_notify_transform(true)


# Binding happens on every tree entry rather than in _ready, so a blocker that is
# removed and re-added later rejoins the system instead of going quietly inert.
func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		_register_with_manager.call_deferred()


func _exit_tree() -> void:
	if is_instance_valid(_terrain_system):
		_terrain_system.unregister_static_grass_blocker(self)
	_terrain_system = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready() and is_instance_valid(_terrain_system):
		_terrain_system.notify_static_blocker_changed(self)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if blocker_shape == null:
		warnings.append("TerrainGrassBlocker3D has no blocker_shape, so it will not remove any grass.")
	return warnings


## Assigns a new shape and rebuilds the grass across both the old and new
## bounds. Equivalent to setting [member blocker_shape] directly.
func set_shape(shape: Shape3D) -> void:
	blocker_shape = shape


## World-space bounds of the shape, used by the chunk masker's broad phase.
func get_world_aabb() -> AABB:
	if blocker_shape == null:
		return AABB(global_position, Vector3.ZERO)
	if not _local_shape_aabb_valid:
		_refresh_local_shape_aabb()
	return global_transform * _local_shape_aabb


## Whether [method shape_local_aabb] returns bounds guaranteed to contain the
## whole of [param shape].
##
## The masker's broad phase may only skip an exact physics query when nothing
## conservative overlaps, so it needs to know which shapes it is allowed to
## reason about. The unit-cube fallback below is a broad-phase convenience for a
## blocker's own footprint, not a bound -- a shape larger than a unit cube would
## be under-covered by it, and rejecting a cell against that would leave grass
## growing through the blocker. Everything not answered here is exact-tested.
static func shape_bounds_are_conservative(shape: Shape3D) -> bool:
	if shape is BoxShape3D or shape is SphereShape3D:
		return true
	if shape is CapsuleShape3D or shape is CylinderShape3D:
		return true
	if shape is ConvexPolygonShape3D:
		# An empty point set produces a zero AABB that bounds nothing.
		return not (shape as ConvexPolygonShape3D).points.is_empty()
	if shape is ConcavePolygonShape3D:
		return not (shape as ConcavePolygonShape3D).get_faces().is_empty()
	return false


## Local-space bounds of any [Shape3D], falling back to a unit cube for shapes
## whose extents cannot be derived cheaply. Check
## [method shape_bounds_are_conservative] before treating the result as a bound.
static func shape_local_aabb(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var box := shape as BoxShape3D
		return AABB(-box.size * 0.5, box.size)
	if shape is SphereShape3D:
		var sphere := shape as SphereShape3D
		var extent := Vector3.ONE * sphere.radius
		return AABB(-extent, extent * 2.0)
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		var extent := Vector3(capsule.radius, capsule.height * 0.5, capsule.radius)
		return AABB(-extent, extent * 2.0)
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		var extent := Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)
		return AABB(-extent, extent * 2.0)
	if shape is ConvexPolygonShape3D:
		return _points_local_aabb((shape as ConvexPolygonShape3D).points)
	if shape is ConcavePolygonShape3D:
		return _points_local_aabb((shape as ConcavePolygonShape3D).get_faces())
	return AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


static func _points_local_aabb(points: PackedVector3Array) -> AABB:
	if points.is_empty():
		return AABB()
	var bounds := AABB(points[0], Vector3.ZERO)
	for index in range(1, points.size()):
		bounds = bounds.expand(points[index])
	return bounds


func _connect_shape_changed() -> void:
	if blocker_shape != null and not blocker_shape.changed.is_connected(_on_blocker_shape_changed):
		blocker_shape.changed.connect(_on_blocker_shape_changed)


func _disconnect_shape_changed() -> void:
	if blocker_shape != null and blocker_shape.changed.is_connected(_on_blocker_shape_changed):
		blocker_shape.changed.disconnect(_on_blocker_shape_changed)


func _refresh_local_shape_aabb() -> void:
	_local_shape_aabb = shape_local_aabb(blocker_shape) if blocker_shape != null else AABB()
	_local_shape_aabb_valid = true


func _on_blocker_shape_changed() -> void:
	_refresh_local_shape_aabb()
	if is_instance_valid(_terrain_system):
		_terrain_system.notify_static_blocker_changed(self)
	update_configuration_warnings()


func _register_with_manager() -> void:
	# The deferred call can land after the node left the tree again.
	if not is_inside_tree():
		return
	_terrain_system = TerrainGrassBinding.resolve_system(self, terrain_system_path, "TerrainGrassBlocker3D")
	if not is_instance_valid(_terrain_system):
		return
	collision_layer = _terrain_system.get_blocker_query_mask()
	_terrain_system.register_static_grass_blocker(self)
