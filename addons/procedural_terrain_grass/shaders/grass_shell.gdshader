shader_type spatial;
render_mode cull_back, depth_draw_opaque;

const int MAX_INTERACTORS = 8;

uniform vec4 grass_interactors[MAX_INTERACTORS];
uniform vec3 u_base_color : source_color = vec3(0.11, 0.24, 0.06);
uniform vec3 u_tip_color : source_color = vec3(0.32, 0.52, 0.12);
uniform float u_density = 16.0;
uniform float u_max_height = 0.6;
uniform float u_root_offset = 0.006;
uniform vec2 u_wind_direction = vec2(0.957826, 0.287348);
uniform float u_wind_speed = 2.4;
uniform float u_wind_strength = 0.035;
uniform bool u_wind_enabled = true;
uniform bool u_interaction_enabled = true;
uniform bool u_color_noise_enabled = true;
uniform float u_color_noise_strength = 0.18;
uniform int u_color_noise_seed = 7331;
uniform float u_color_noise_patch_size = 6.0;
uniform vec3 u_color_noise_low_tint : source_color = vec3(0.84, 0.94, 0.76);
uniform vec3 u_color_noise_high_tint : source_color = vec3(1.12, 1.04, 0.82);
uniform float u_color_noise_detail_strength = 0.03;
uniform vec2 u_system_origin_xz = vec2(0.0);
uniform float u_interaction_push_scale = 0.12;
uniform float u_flatten_response = 1.0;
uniform float u_min_flatten = 0.3;
// Distance fog pushed by the host renderer so unmanaged grass fades on exactly
// the same curve as the managed ground under it. x=begin, y=end, z=curve,
// w=enabled.
uniform vec4 u_fog_params = vec4(0.0, 1.0, 1.0, 0.0);
// Scene-linear radiance, deliberately NOT source_color: the value arrives
// already linearized and must not be converted a second time.
uniform vec3 u_fog_color = vec3(0.0);

varying vec3 base_world_position;
varying vec3 base_world_normal;
varying float shell_level;
varying vec2 fine_mask_bytes;
varying float broad_color_noise;

vec2 hash22(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453123);
}

float hash12(vec2 p) {
	float seed = float(u_color_noise_seed) * 0.0016180339;
	return fract(sin(dot(p + vec2(seed, -seed), vec2(127.1, 311.7))) * 43758.5453123);
}

float smooth_value_noise(vec2 p) {
	vec2 lattice = floor(p);
	vec2 fraction = fract(p);
	vec2 fade = fraction * fraction * fraction * (fraction * (fraction * 6.0 - 15.0) + 10.0);
	float n00 = hash12(lattice);
	float n10 = hash12(lattice + vec2(1.0, 0.0));
	float n01 = hash12(lattice + vec2(0.0, 1.0));
	float n11 = hash12(lattice + vec2(1.0, 1.0));
	return mix(mix(n00, n10, fade.x), mix(n01, n11, fade.x), fade.y);
}


// Canonical Retro RT distance fog. Keep this function byte-identical in every
// copy: addons/retro_rt/shaders/rt_shadow_reflect.glsl,
// addons/retro_rt/shaders/BlinnPhongSoftwareBody.gdshaderinc,
// addons/procedural_terrain_grass/shaders/grass_shell.gdshader.
// Normative text: addons/retro_rt/docs/RT_PIPELINE.md, "Distance fog".
// params: x=begin, y=end (> begin), z=curve, w=enabled. distance is radial.
float rt_fog_factor(vec4 params, float view_distance) {
	if (params.w < 0.5) {
		return 0.0;
	}
	return pow(smoothstep(params.x, params.y, view_distance), params.z);
}

vec2 stalk_center_for(vec2 cell, vec2 random_value) {
	return (cell + vec2(0.5) + (random_value - vec2(0.5)) * 0.45) / u_density;
}

vec2 wind_for(vec2 random_value, float bend) {
	if (!u_wind_enabled) {
		return vec2(0.0);
	}
	float phase = random_value.x * 1.7 + dot(random_value, vec2(2.1, 1.3));
	float amplitude = mix(0.75, 1.25, random_value.y);
	float sway = sin(TIME * u_wind_speed + phase) * u_wind_strength * amplitude;
	return u_wind_direction * sway * bend;
}

void vertex() {
	shell_level = COLOR.r;
	fine_mask_bytes = COLOR.gb;
	base_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	base_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vec2 system_xz = base_world_position.xz - u_system_origin_xz;
	broad_color_noise = smooth_value_noise(system_xz / max(u_color_noise_patch_size, 0.001));
	VERTEX += NORMAL * (u_root_offset + shell_level * u_max_height);
}

void fragment() {
	int fine_x = clamp(int(floor(UV.x * 4.0)), 0, 3);
	int fine_z = clamp(int(floor(UV.y * 4.0)), 0, 3);
	int fine_index = fine_z * 4 + fine_x;
	int encoded_byte = fine_index < 8
		? int(floor(fine_mask_bytes.x * 255.0 + 0.5))
		: int(floor(fine_mask_bytes.y * 255.0 + 0.5));
	int bit_index = fine_index < 8 ? fine_index : fine_index - 8;
	if ((encoded_byte & (1 << bit_index)) == 0) {
		discard;
	}

	float h = shell_level;
	float bend = h * h;
	vec2 base_xz = base_world_position.xz - u_system_origin_xz;
	vec2 provisional_cell = floor(base_xz * u_density);
	vec2 provisional_random = hash22(provisional_cell);
	vec2 provisional_center = stalk_center_for(provisional_cell, provisional_random);
	vec2 wind_offset = wind_for(provisional_random, bend);
	vec2 push_offset = vec2(0.0);
	float flatten_factor = 1.0;

	// Hoisted out of the loop: it is a uniform, so testing it per iteration only
	// costs eight redundant branches on every fragment of every shell layer.
	if (u_interaction_enabled) {
		vec2 stalk_world = provisional_center + u_system_origin_xz;
		for (int i = 0; i < MAX_INTERACTORS; i++) {
			vec4 data = grass_interactors[i];
			if (data.z <= 0.0) {
				continue;
			}
			vec2 to_stalk = stalk_world - data.xy;
			float distance_to_interactor = length(to_stalk);
			if (distance_to_interactor < data.z) {
				float influence = 1.0 - clamp(distance_to_interactor / data.z, 0.0, 1.0);
				influence *= influence;
				vec2 direction = distance_to_interactor > 0.0001 ? to_stalk / distance_to_interactor : vec2(1.0, 0.0);
				push_offset += direction * influence * data.w * u_interaction_push_scale * bend;
				float flatten_amount = clamp(influence * data.w * u_flatten_response, 0.0, 1.0);
				flatten_factor = min(flatten_factor, mix(1.0, u_min_flatten, flatten_amount));
			}
		}
	}

	vec2 combined_offset = wind_offset + push_offset;
	float maximum_offset = 0.4 / u_density;
	float combined_length = length(combined_offset);
	if (combined_length > maximum_offset) {
		combined_offset *= maximum_offset / combined_length;
	}

	// One inverse-warp refinement lets a bent cross-section cross a cell edge
	// without deriving wind identity from an already wind-displaced coordinate.
	vec2 source_coordinate = base_xz - combined_offset;
	vec2 source_cell = floor(source_coordinate * u_density);
	vec2 cell_random = hash22(source_cell);
	vec2 stalk_center = stalk_center_for(source_cell, cell_random);
	wind_offset = wind_for(cell_random, bend);
	combined_offset = wind_offset + push_offset;
	combined_length = length(combined_offset);
	if (combined_length > maximum_offset) {
		combined_offset *= maximum_offset / combined_length;
	}
	vec2 sample_position = base_xz - combined_offset;

	float random_height = mix(0.72, 1.08, cell_random.x) * flatten_factor;
	if (h > random_height) {
		discard;
	}
	float shape_height = clamp(h / max(random_height, 0.001), 0.0, 1.0);
	vec2 stalk_delta = (sample_position - stalk_center) * u_density;
	float orientation = cell_random.y * TAU;
	float cosine_angle = cos(orientation);
	float sine_angle = sin(orientation);
	vec2 blade_space = vec2(
		stalk_delta.x * cosine_angle - stalk_delta.y * sine_angle,
		stalk_delta.x * sine_angle + stalk_delta.y * cosine_angle
	);
	float width_variation = mix(0.88, 1.12, cell_random.x);
	float width_taper = pow(shape_height, 0.42);
	float length_taper = pow(shape_height, 0.75);
	float blade_width = mix(0.46, 0.018, width_taper) * width_variation;
	float blade_length = mix(0.60, 0.18, length_taper) * mix(0.9, 1.1, cell_random.y);
	vec2 ellipse = blade_space / vec2(blade_width, blade_length);
	float ellipse_distance = dot(ellipse, ellipse);
	float edge_width = max(fwidth(ellipse_distance) * 1.25, 0.025);
	float edge_coverage = 1.0 - smoothstep(1.0 - edge_width, 1.0 + edge_width, ellipse_distance);
	if (edge_coverage < 0.42) {
		discard;
	}

	vec3 color = mix(u_base_color, u_tip_color, h);
	if (u_color_noise_enabled) {
		vec3 broad_tint = mix(u_color_noise_low_tint, u_color_noise_high_tint, broad_color_noise);
		float detail_tint = mix(
			1.0 - u_color_noise_detail_strength,
			1.0 + u_color_noise_detail_strength,
			cell_random.y
		);
		vec3 combined_tint = broad_tint * detail_tint;
		color *= mix(vec3(1.0), combined_tint, clamp(u_color_noise_strength, 0.0, 1.0));
	}
	color *= mix(0.72, 1.0, pow(h, 0.72));
	color *= mix(0.88, 1.0, edge_coverage);
	// Grass is unmanaged and forward-lit with no light() override, so fog is applied
	// by attenuating ALBEDO (which scales both the diffuse and the ambient term) and
	// adding the fog radiance back through EMISSION. That is exactly
	// mix(lit, u_fog_color, fog), matching the two RT paths.
	vec3 fog_world_position = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float fog = rt_fog_factor(u_fog_params, length(fog_world_position - INV_VIEW_MATRIX[3].xyz));
	ALBEDO = color * (1.0 - fog);
	EMISSION = u_fog_color * fog;
	ROUGHNESS = 0.92;
	// Godot derives f90 from f0 = 0.16 * SPECULAR^2, so driving SPECULAR to zero
	// removes the grazing-angle Fresnel rim as well. Left at 0.08 the far grass
	// would keep a highlight against flat fog, which is the pop this hides.
	SPECULAR = 0.08 * (1.0 - fog);
	vec3 world_normal = normalize(mix(base_world_normal, vec3(0.0, 1.0, 0.0), h * 0.78));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
}
