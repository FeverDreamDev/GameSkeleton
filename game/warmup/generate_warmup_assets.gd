extends SceneTree

## Reproducible generator for the two vertex formats produced at runtime by
## TerrainGrass3D. The generated proxy scene is intentionally authored data:
## ShaderWarmupScanner reads PackedScene state without running scripts.

const TERRAIN_MATERIAL_PATH := "res://game/materials/terrain_blinn_phong.tres"
const GRASS_MATERIAL_PATH := "res://game/materials/warmup_grass.tres"
const TERRAIN_MESH_PATH := "res://game/warmup/terrain_vertex_format.res"
const GRASS_MESH_PATH := "res://game/warmup/grass_vertex_format.res"
const PROXY_SCENE_PATH := "res://game/warmup/terrain_grass_proxy.tscn"
const GRASS_SHADER := preload("res://addons/procedural_terrain_grass/shaders/grass_shell.gdshader")
const Scanner := preload("res://addons/shader_warmup/shader_warmup_scanner.gd")


func _initialize() -> void:
	_generate.call_deferred()


func _generate() -> void:
	var base_dir := ProjectSettings.globalize_path("res://game/warmup")
	var materials_dir := ProjectSettings.globalize_path("res://game/materials")
	DirAccess.make_dir_recursive_absolute(base_dir)
	DirAccess.make_dir_recursive_absolute(materials_dir)

	var terrain_material := load(TERRAIN_MATERIAL_PATH) as Material
	if terrain_material == null:
		push_error("Warmup generator: missing %s" % TERRAIN_MATERIAL_PATH)
		quit(1)
		return

	var grass_material := ShaderMaterial.new()
	grass_material.resource_name = "Runtime Grass Shell Warmup"
	grass_material.shader = GRASS_SHADER
	grass_material.set_shader_parameter(&"u_base_color", Color(0.11, 0.24, 0.06, 1.0))
	grass_material.set_shader_parameter(&"u_tip_color", Color(0.32, 0.52, 0.12, 1.0))
	grass_material.set_shader_parameter(&"u_density", 16.0)
	grass_material.set_shader_parameter(&"u_max_height", 0.6)
	if ResourceSaver.save(grass_material, GRASS_MATERIAL_PATH) != OK:
		push_error("Warmup generator: could not save grass material.")
		quit(1)
		return

	var terrain_mesh := _build_format_mesh(false, terrain_material)
	var grass_mesh := _build_format_mesh(true, grass_material)
	if ResourceSaver.save(terrain_mesh, TERRAIN_MESH_PATH) != OK:
		push_error("Warmup generator: could not save terrain proxy mesh.")
		quit(1)
		return
	if ResourceSaver.save(grass_mesh, GRASS_MESH_PATH) != OK:
		push_error("Warmup generator: could not save grass proxy mesh.")
		quit(1)
		return

	var root := Node3D.new()
	root.name = "TerrainGrassWarmupProxy"
	var terrain_proxy := MeshInstance3D.new()
	terrain_proxy.name = "TerrainVertexColorFormat"
	terrain_proxy.mesh = terrain_mesh
	terrain_proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(terrain_proxy)
	terrain_proxy.owner = root
	var grass_proxy := MeshInstance3D.new()
	grass_proxy.name = "GrassVertexColorUVFormat"
	grass_proxy.mesh = grass_mesh
	grass_proxy.position = Vector3(0.0, 0.0, -2.0)
	grass_proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(grass_proxy)
	grass_proxy.owner = root

	var packed := PackedScene.new()
	if packed.pack(root) != OK or ResourceSaver.save(packed, PROXY_SCENE_PATH) != OK:
		push_error("Warmup generator: could not save proxy scene.")
		root.free()
		quit(1)
		return
	root.free()

	var manifest = Scanner.scan_and_save()
	if manifest == null:
		push_error("Warmup generator: manifest scan failed.")
		quit(1)
		return
	print("Warmup assets generated: %d materials, %d vertex-format pairs." % [
		manifest.size(), manifest.pair_count(),
	])
	quit(0)


func _build_format_mesh(include_uv: bool, material: Material) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1.0, 0.0, -1.0), Vector3(1.0, 0.0, -1.0),
		Vector3(1.0, 0.0, 1.0), Vector3(-1.0, 0.0, 1.0),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP,
	])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([
		Color(0.25, 0.45, 0.18, 1.0), Color(0.32, 0.52, 0.22, 1.0),
		Color(0.42, 0.38, 0.20, 1.0), Color(0.22, 0.34, 0.14, 1.0),
	])
	if include_uv:
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
			Vector2(0.0, 0.0), Vector2(1.0, 0.0),
			Vector2(1.0, 1.0), Vector2(0.0, 1.0),
		])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh
