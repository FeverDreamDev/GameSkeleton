class_name TerrainTestLevel
extends FlowLevel

## Small integration level for the procedural terrain, grass, FPS controller,
## game-flow spawn contract, and the persistent Retro RT renderer.
##
## This scene deliberately holds no RTSceneManager, so the editor viewport shows
## plain raster with Godot's own shadow maps. Soft, low-resolution shadows on the
## test caster and reflector while editing are that, not an RT regression. The
## manager is persistent and lives in the app shell (game/app/main.tscn) because
## RT owns root-Viewport state across level transitions, and only one is allowed
## per Viewport; a second one here would refuse to start the moment this level
## was installed. Previewing it here would also stay half a picture regardless:
## RTPostProcessStack.configure() sets disable_3d on the root and presents
## through a CanvasLayer, which in the editor blanks the viewport and its gizmos,
## so an editor preview is RT shadows and reflections with no SMAA, FSR or grade.
##
## The runtime is the authoritative image. GameApp._renderer_summary() reports
## the live backend on the boot screen and under the main-menu title, which is
## the quickest way to confirm RT actually started.

const SPAWN_CLEARANCE := 0.08

@onready var terrain: TerrainGrass3D = $TerrainGrass3D
@onready var default_spawn: FlowSpawn = $SpawnPoints/Default
@onready var streaming_anchor: Node3D = $StreamingAnchor
@onready var test_caster: Node3D = $TestCaster
@onready var test_reflector: Node3D = $TestReflector
@onready var day_night: DayNightCycle3D = $DayNightCycle3D

@export var standalone_player_scene: PackedScene

@export_group("Distance Fog")
## Fog begins at this fraction of the terrain's load distance and reaches full
## strength at [member fog_end_fraction] of it, so chunk pop-in at the load
## boundary and the grass LOD cutoff always sit inside solid fog. Deriving the
## reach keeps the two aligned when terrain_load_distance is retuned.
@export_range(0.0, 1.0, 0.01) var fog_begin_fraction: float = 0.5
@export_range(0.0, 2.0, 0.01) var fog_end_fraction: float = 1.0
@export_range(0.25, 4.0, 0.01) var fog_curve: float = 1.0
@export var fog_enabled: bool = true

var _bound_player: Player


func _ready() -> void:
	_place_static_content_on_terrain()
	# The shell grass is unmanaged forward geometry, so it resolves its own cloud
	# shadow from the layer the sky draws. TerrainGrass3D builds its materials in
	# its own _ready, which runs before this one.
	day_night.register_cloud_shadow_material(terrain.get_grass_material())
	_bind_existing_or_spawn_standalone.call_deferred()


func get_terrain() -> TerrainGrass3D:
	return terrain


## Fog reach derived from the streaming radius. GameApp calls this when the level
## is installed and forwards the result to RTSceneManager.
func distance_fog_request() -> Dictionary:
	var reach := terrain.terrain_load_distance
	return {
		"enabled": fog_enabled,
		"begin": reach * fog_begin_fraction,
		"end": reach * fog_end_fraction,
		"curve": fog_curve,
	}


## Receives the renderer's resolved fog, including the background radiance the
## managed paths fade to, and hands it to the unmanaged shell grass.
func apply_distance_fog(params: Dictionary) -> void:
	if terrain == null:
		return
	var color: Color = params.get("color", Color.BLACK)
	terrain.set_distance_fog(
		bool(params.get("enabled", false)),
		float(params.get("begin", 0.0)),
		float(params.get("end", 0.0)),
		float(params.get("curve", 1.0)),
		Vector3(color.r, color.g, color.b))




func get_day_night() -> DayNightCycle3D:
	return day_night


func get_bound_player() -> Player:
	return _bound_player


## Makes the persistent player the terrain streaming target. Placement remains
## a separate operation so save restoration can warm the destination first.
func bind_player(target: Player) -> void:
	_bound_player = target
	terrain.streaming_target = target
	terrain.start_streaming()


## Resolves and height-adjusts a flow spawn without moving the player.
func prepare_spawn(spawn_id: StringName = &"default") -> FlowSpawn:
	var spawn := resolve_spawn(spawn_id)
	if spawn == null:
		return null
	var spawn_xz := Vector2(spawn.global_position.x, spawn.global_position.z)
	spawn.global_position.y = terrain.sample_height(spawn_xz) + SPAWN_CLEARANCE
	return spawn


## Warms collision around an arbitrary save/spawn destination before the host
## teleports the persistent player there.
func wait_for_placement_position(
		world_position: Vector3,
		timeout_seconds: float = 10.0
) -> bool:
	streaming_anchor.global_position = world_position
	terrain.streaming_target = streaming_anchor
	terrain.start_streaming()
	return await terrain.wait_for_position_ready(
		Vector2(world_position.x, world_position.z), timeout_seconds)


## Standalone convenience and the host's fresh-spawn path. Save restoration can
## instead call [method wait_for_placement_position], apply its full transform,
## then [method bind_player].
func place_player_at_spawn(
		target: Player,
		spawn_id: StringName = &"default",
		timeout_seconds: float = 10.0
) -> StringName:
	var spawn := prepare_spawn(spawn_id)
	if spawn == null:
		return &""
	if not await wait_for_placement_position(spawn.global_position, timeout_seconds):
		push_error("TerrainTestLevel timed out waiting for collision at spawn '%s'." % spawn.spawn_id)
		return &""
	target.global_position = spawn.global_position
	target.velocity = Vector3.ZERO
	if spawn.applies_facing:
		target.rotation.y = spawn.spawn_yaw()
	bind_player(target)
	return spawn.spawn_id


func _place_static_content_on_terrain() -> void:
	var spawn_xz := Vector2(default_spawn.global_position.x, default_spawn.global_position.z)
	default_spawn.global_position.y = terrain.sample_height(spawn_xz) + SPAWN_CLEARANCE

	var caster_xz := Vector2(test_caster.global_position.x, test_caster.global_position.z)
	# TestCaster's origin is at the centre of its three-metre-high box.
	test_caster.global_position.y = terrain.sample_height(caster_xz) + 1.5
	var reflector_xz := Vector2(test_reflector.global_position.x, test_reflector.global_position.z)
	# The reflector is a two-metre sphere, so its centre sits one metre up.
	test_reflector.global_position.y = terrain.sample_height(reflector_xz) + 1.0


func _bind_existing_or_spawn_standalone() -> void:
	var existing := get_tree().get_first_node_in_group(&"player") as Player
	if existing != null:
		bind_player(existing)
		return
	# Integrated play always has a persistent player. Only direct scene play is
	# allowed to create this disposable fallback.
	if get_tree().current_scene != self or standalone_player_scene == null:
		return
	var fallback := standalone_player_scene.instantiate() as Player
	if fallback == null:
		push_error("TerrainTestLevel standalone_player_scene does not instantiate Player.")
		return
	fallback.integrated_mode = false
	fallback.capture_mouse_on_ready = true
	add_child(fallback)
	await place_player_at_spawn(fallback)
