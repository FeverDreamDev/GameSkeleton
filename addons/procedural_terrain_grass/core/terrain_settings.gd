# Immutable copy of a TerrainGrass3D's inspector values, taken when the runtime
# starts. Managers read this instead of the node so a rebuild mid-frame cannot
# change generation parameters underneath in-flight jobs.
extends Resource

## Every property TerrainGrass3D mirrors into a settings instance. Kept next to
## the declarations so adding a field in one place cannot silently drop it from
## the other.
const MIRRORED_PROPERTIES := [
	"terrain_seed", "chunk_size", "chunk_resolution", "noise_frequency", "noise_octaves",
	"noise_lacunarity", "noise_gain", "height_amplitude", "terrain_low_color",
	"terrain_high_color", "terrain_steep_color", "terrain_height_color_min",
	"terrain_height_color_max", "terrain_steep_normal_y", "terrain_roughness",
	"terrain_specular", "terrain_mesh_group", "terrain_receiver_only_group",
	"terrain_load_distance", "terrain_unload_distance",
	"stream_update_interval", "lod_update_interval", "grass_enabled", "grass_height",
	"grass_density", "max_grass_slope_degrees", "grass_prefetch_distance", "root_offset",
	"grass_base_color", "grass_tip_color", "grass_color_noise_enabled",
	"grass_color_noise_seed", "grass_color_noise_patch_size", "grass_color_noise_strength",
	"grass_color_noise_low_tint", "grass_color_noise_high_tint",
	"grass_color_noise_detail_strength", "wind_enabled", "wind_direction", "wind_speed",
	"wind_strength", "near_shell_count", "medium_shell_count", "far_shell_count",
	"far_shell_top", "lod_near_to_medium", "lod_medium_to_near", "lod_medium_to_far",
	"lod_far_to_medium", "lod_far_to_hidden", "lod_hidden_to_far",
	"dynamic_interaction_enabled", "static_masking_enabled", "active_interactor_limit",
	"interactor_discovery_radius", "interactor_discovery_interval",
	"default_interactor_radius", "default_interactor_strength", "interaction_push_scale",
	"flatten_response", "minimum_flatten", "terrain_collision_layer",
	"terrain_collision_mask", "blocker_query_mask", "interactor_query_mask",
	"max_worker_jobs", "incremental_generation_budget_usec", "mask_query_budget_usec",
	"max_mask_cell_queries", "max_mesh_commits_per_frame",
]

var terrain_seed: int = 1337
var chunk_size: float = 32.0
var chunk_resolution: int = 32
var noise_frequency: float = 0.008
var noise_octaves: int = 4
var noise_lacunarity: float = 2.0
var noise_gain: float = 0.5
var height_amplitude: float = 14.0

# Scene-linear, mirroring TerrainGrass3D. See TerrainGenerator.terrain_color.
var terrain_low_color: Color = Color(0.0040, 0.0278, 0.0008)
var terrain_high_color: Color = Color(0.0054, 0.0376, 0.0011)
var terrain_steep_color: Color = Color("665f55")
var terrain_height_color_min: float = -10.0
var terrain_height_color_max: float = 16.0
var terrain_steep_normal_y: float = 0.82
var terrain_roughness: float = 0.95
var terrain_specular: float = 0.05
var terrain_mesh_group: StringName
var terrain_receiver_only_group: StringName

var terrain_load_distance: float = 96.0
var terrain_unload_distance: float = 128.0
var stream_update_interval: float = 0.20
var lod_update_interval: float = 0.10

var grass_enabled: bool = true
var grass_height: float = 0.6
var grass_density: float = 16.0
var max_grass_slope_degrees: float = 38.0
var grass_prefetch_distance: float = 96.0
var root_offset: float = 0.006
var grass_base_color: Color = Color(0.11, 0.24, 0.06)
var grass_tip_color: Color = Color(0.32, 0.52, 0.12)
var grass_color_noise_enabled: bool = true
var grass_color_noise_seed: int = 7331
var grass_color_noise_patch_size: float = 6.0
var grass_color_noise_strength: float = 0.18
var grass_color_noise_low_tint: Color = Color(0.84, 0.94, 0.76)
var grass_color_noise_high_tint: Color = Color(1.12, 1.04, 0.82)
var grass_color_noise_detail_strength: float = 0.03

var wind_enabled: bool = true
var wind_direction: Vector2 = Vector2(1.0, 0.3)
var wind_speed: float = 2.4
var wind_strength: float = 0.035

var near_shell_count: int = 16
var medium_shell_count: int = 10
var far_shell_count: int = 4
var far_shell_top: float = 0.75
var lod_near_to_medium: float = 26.0
var lod_medium_to_near: float = 22.0
var lod_medium_to_far: float = 52.0
var lod_far_to_medium: float = 44.0
var lod_far_to_hidden: float = 86.0
var lod_hidden_to_far: float = 76.0

var dynamic_interaction_enabled: bool = true
var static_masking_enabled: bool = true
var active_interactor_limit: int = 4
var interactor_discovery_radius: float = 25.0
var interactor_discovery_interval: float = 0.10
var default_interactor_radius: float = 0.6
var default_interactor_strength: float = 0.8
var interaction_push_scale: float = 0.12
var flatten_response: float = 1.0
var minimum_flatten: float = 0.3

var terrain_collision_layer: int = 1
var terrain_collision_mask: int = 1
var blocker_query_mask: int = 1 << 7
var interactor_query_mask: int = 1 << 8

var max_worker_jobs: int = 2
var incremental_generation_budget_usec: int = 2000
var mask_query_budget_usec: int = 1000
var max_mask_cell_queries: int = 128
var max_mesh_commits_per_frame: int = 2


func cell_spacing() -> float:
	return chunk_size / float(maxi(chunk_resolution, 1))


func snapshot() -> Dictionary:
	var direction := wind_direction.normalized()
	if direction.is_zero_approx():
		direction = Vector2.RIGHT
	return {
		"seed": terrain_seed,
		"chunk_size": chunk_size,
		"resolution": chunk_resolution,
		"spacing": cell_spacing(),
		"noise_frequency": noise_frequency,
		"noise_octaves": noise_octaves,
		"noise_lacunarity": noise_lacunarity,
		"noise_gain": noise_gain,
		"height_amplitude": height_amplitude,
		"terrain_low_color": terrain_low_color,
		"terrain_high_color": terrain_high_color,
		"terrain_steep_color": terrain_steep_color,
		"terrain_height_color_min": terrain_height_color_min,
		"terrain_height_color_max": terrain_height_color_max,
		"terrain_steep_normal_y": terrain_steep_normal_y,
		"grass_height": grass_height,
		"grass_density": grass_density,
		"max_grass_slope_cos": cos(deg_to_rad(max_grass_slope_degrees)),
		"near_shell_count": near_shell_count,
		"medium_shell_count": medium_shell_count,
		"far_shell_count": far_shell_count,
		"far_shell_top": far_shell_top,
		"wind_direction": direction,
	}
