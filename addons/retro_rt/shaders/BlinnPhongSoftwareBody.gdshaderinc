render_mode unshaded, ambient_light_disabled, shadows_disabled, fog_disabled;

// The public material interface mirrors BlinnPhong.gdshader. RTSoftwareTracer
// creates renderer-only clones, so authored materials remain unchanged.
uniform vec4 ambient_light : source_color = vec4(0.1, 0.1, 0.1, 1.0);
uniform vec4 diffuse_color : source_color = vec4(0.25, 0.5, 0.2, 1.0);
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 specular_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool vertex_color_enabled = false;
uniform bool triplanar_enabled = false;
uniform bool triplanar_world_space = false;
uniform vec3 triplanar_scale = vec3(1.0);
uniform vec3 triplanar_offset = vec3(0.0);
uniform float triplanar_sharpness : hint_range(0.0, 150.0, 0.001) = 1.0;
uniform float shininess : hint_range(1.0, 256.0, 1.0) = 40.0;
uniform float direct_specular_intensity : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform bool mirror_enabled = false;
uniform float reflection_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform bool reflection_shadows_enabled = false;
uniform int rt_material_id = 0;
uniform bool rt_has_albedo_texture = false;
uniform bool rt_has_normal_texture = false;
uniform bool swrt_compatibility_output = false;
instance uniform int rt_instance_id = 0;
instance uniform int rt_receiver_layers = 0;
instance uniform int rt_receiver_light_start = 0;
instance uniform int rt_receiver_light_count = 0;

uniform sampler2D swrt_geometry_atlas : filter_nearest, repeat_disable;
uniform sampler2D swrt_instance_atlas : filter_nearest, repeat_disable;
uniform sampler2D swrt_shading_atlas : filter_nearest, repeat_disable;
uniform sampler2D swrt_albedo_atlas : source_color, filter_nearest, repeat_disable;
uniform sampler2D swrt_normal_atlas : filter_nearest, repeat_disable;
uniform sampler2D swrt_environment_panorama : filter_nearest, repeat_disable, hint_default_black;
uniform ivec4 swrt_geometry_layout = ivec4(0);
uniform ivec4 swrt_geometry_counts = ivec4(0);
uniform ivec4 swrt_instance_layout = ivec4(0);
uniform int swrt_instance_count = 0;
uniform ivec4 swrt_shading_layout = ivec4(0);
uniform ivec4 swrt_shading_counts = ivec4(0);
uniform vec4 swrt_frame_settings = vec4(0.0);
uniform vec4 swrt_miss_color = vec4(0.0);
// Post-lighting composite only, so deliberately not folded into
// swrt_frame_settings, which carries traversal state. The fog colour is
// swrt_miss_color: already raw scene-linear, so no source_color hint here.
// x=begin, y=end, z=curve, w=enabled.
uniform vec4 swrt_fog_params = vec4(0.0, 1.0, 1.0, 0.0);
// Analytic cloud layer pushed by a sky system, so managed surfaces resolve the
// same shadow their unmanaged neighbours already do. See addons/day_night_cycle.
uniform vec4 swrt_cloud_params = vec4(0.0);
uniform vec4 swrt_cloud_motion = vec4(0.0);
uniform vec3 swrt_cloud_sun_direction = vec3(0.0, 1.0, 0.0);
// Analytic ground layer pushed by a terrain system, so a reflection that
// misses the acceleration structure can still resolve the ground its streamed
// chunks are deliberately kept out of. See rt_ground_reflection. The sampler
// is filter_nearest for the same reason the panorama above is: the hardware
// backend fetches texels and blends them itself, and a filtered sample here
// would round differently on another driver and break that parity.
uniform sampler2D swrt_ground_map : filter_nearest, repeat_disable, hint_default_black;
// x,y=window origin in world XZ, z=1/window size, w=march step count.
uniform vec4 swrt_ground_params = vec4(0.0);
// x=lowest canopy height, y=highest, z=max march distance, w=texel metres.
uniform vec4 swrt_ground_bounds = vec4(0.0);
// xyz=direction towards the ground layer's sun, w=1 when it is lit at all.
uniform vec4 swrt_ground_sun_direction = vec4(0.0, 1.0, 0.0, 0.0);
// rgb=sun radiance already scaled by energy, w unused. No color hint: the
// manager has already resolved these to scene-linear, exactly as it does for
// swrt_miss_color and the primary direct-light fields below.
uniform vec4 swrt_ground_sun_radiance = vec4(0.0);
// rgb=ambient radiance the ground receives, w unused.
uniform vec4 swrt_ground_ambient = vec4(0.0);
uniform int swrt_environment_mode = 0;
uniform vec3 swrt_environment_basis_x = vec3(1.0, 0.0, 0.0);
uniform vec3 swrt_environment_basis_y = vec3(0.0, 1.0, 0.0);
uniform vec3 swrt_environment_basis_z = vec3(0.0, 0.0, 1.0);
// CPU-normalized primary direct-light fields deliberately have no color hint.
// This preserves the manager's renderer-dependent source-color conversion
// without reloading the complete primary material atlas record per fragment.
uniform float swrt_primary_shininess = 40.0;
uniform vec3 swrt_primary_diffuse_color = vec3(0.050876, 0.214041, 0.033105);
uniform vec3 swrt_primary_ambient_color = vec3(0.010023);
uniform vec3 swrt_primary_emission_color = vec3(0.0);
uniform vec3 swrt_primary_specular_color = vec3(1.0);
uniform float swrt_primary_direct_specular_intensity = 1.0;
uniform bool swrt_primary_reflection_shadows_enabled = false;

varying vec3 rt_triplanar_position;
varying vec3 rt_triplanar_weights;


vec4 sample_triplanar(sampler2D map, vec3 weights, vec3 position) {
	vec4 sampled = texture(map, position.xy) * weights.z;
	sampled += texture(map, position.xz) * weights.y;
	sampled += texture(map, position.zy * vec2(-1.0, 1.0)) * weights.x;
	return sampled;
}


vec3 swrt_linear_to_srgb(vec3 color) {
	// Match Godot Compatibility's inverse transfer so the engine's spatial
	// ALBEDO decode recovers the same scene-linear RGB, including the dark toe.
	bvec3 cutoff = lessThanEqual(color, vec3(0.0031308));
	vec3 low = color * 12.92;
	vec3 high = 1.055 * pow(max(color, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
	return mix(high, low, cutoff);
}


vec3 swrt_srgb_to_linear(vec3 color) {
	bvec3 cutoff = lessThanEqual(color, vec3(0.04045));
	vec3 low = color / 12.92;
	vec3 high = pow(max((color + 0.055) / 1.055, vec3(0.0)), vec3(2.4));
	return mix(high, low, cutoff);
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
// Canonical day_night_cycle cloud layer. Keep every function below
// byte-identical in each copy: addons/day_night_cycle/shaders/day_night_sky.gdshader,
// addons/procedural_terrain_grass/shaders/grass_shell.gdshader,
// addons/retro_rt/shaders/BlinnPhong.gdshader,
// addons/retro_rt/shaders/BlinnPhongSoftwareBody.gdshaderinc,
// addons/retro_rt/shaders/rt_shadow_reflect.glsl.
// Normative text: addons/day_night_cycle/README.md, "The cloud layer".
//
// The layer is one flat plane of fractal noise. That is the whole reason a
// shadow can be resolved analytically: there is no volume to march and no
// geometry to trace, so the sky and the ground agree by construction rather
// than by being kept in sync.
//
// The field is computed rather than sampled from a texture on purpose. A
// sampler would have to be threaded through the hardware ray tracing descriptor
// set as well as every material, where two vec4s ride along in FrameData for
// free.
//
// params: x=altitude, y=1/tile size in metres (zero disables the layer),
// z=coverage threshold, w=edge softness.
// motion: x,z=world scroll offset, y=seed, w=shadow strength.
// Deliberately not the usual fract(sin(dot(...))) hash. Cloud cells run to the
// hundreds once the layer is sampled a few kilometres out, and sin() of an
// argument that large loses so much precision in 32-bit float that the hash
// degenerates into visible axis-aligned rectangles across the sky. This one
// never calls a trig function and stays stable out there.
//
// The three multipliers below must stay distinct. Scaling every component by
// the same constant leaves the third equal to the first -- the input only has
// two dimensions -- and the gradients it produces end up correlated, which
// draws long straight streaks across the layer at grazing angles.
vec2 dnc_cloud_hash(vec2 cell, float seed) {
	vec3 scattered = fract(
		vec3(cell.x, cell.y, cell.x) * vec3(0.1031, 0.1030, 0.0973) + seed);
	scattered += dot(scattered, vec3(scattered.y, scattered.z, scattered.x) + 33.33);
	return fract(
		(vec2(scattered.x, scattered.x) + vec2(scattered.y, scattered.z))
		* vec2(scattered.z, scattered.y));
}


// A unit vector per lattice corner. Taking the angle from the hash rather than
// normalising a hashed vector keeps the distribution even; sin and cos are safe
// here because the argument is bounded to one turn.
vec2 dnc_cloud_gradient(vec2 cell, float seed) {
	float angle = dnc_cloud_hash(cell, seed).x * 6.2831853;
	return vec2(cos(angle), sin(angle));
}


float dnc_cloud_noise(vec2 point, float seed) {
	vec2 lattice = floor(point);
	vec2 fraction = point - lattice;
	// Quintic, not the cheaper cubic smoothstep. Interpolated with a cubic the
	// second derivative is discontinuous at every lattice boundary, and a
	// coverage threshold turns those creases into straight visible seams the
	// moment the layer is viewed at a grazing angle.
	vec2 fade = fraction * fraction * fraction * (fraction * (fraction * 6.0 - 15.0) + 10.0);
	float corner00 = dot(dnc_cloud_gradient(lattice, seed), fraction);
	float corner10 = dot(
		dnc_cloud_gradient(lattice + vec2(1.0, 0.0), seed), fraction - vec2(1.0, 0.0));
	float corner01 = dot(
		dnc_cloud_gradient(lattice + vec2(0.0, 1.0), seed), fraction - vec2(0.0, 1.0));
	float corner11 = dot(
		dnc_cloud_gradient(lattice + vec2(1.0, 1.0), seed), fraction - vec2(1.0, 1.0));
	float value = mix(
		mix(corner00, corner10, fade.x),
		mix(corner01, corner11, fade.x),
		fade.y);
	// Two-dimensional gradient noise spans roughly -0.707..0.707.
	return clamp(value * 0.7071 + 0.5, 0.0, 1.0);
}


float dnc_cloud_field(vec2 point, float seed) {
	float total = 0.0;
	float amplitude = 0.5;
	float normalization = 0.0;
	vec2 sample_point = point;
	for (int octave = 0; octave < 4; octave++) {
		total += dnc_cloud_noise(sample_point, seed) * amplitude;
		normalization += amplitude;
		// Each octave is rotated as well as scaled. Sharing one lattice
		// orientation across octaves lets their grids reinforce into a visible
		// direction; an irrational-looking rotation leaves them nothing to agree
		// on. The lacunarity is deliberately not exactly two either: whole-number
		// steps line the octaves up on the same lattice and print a grid.
		sample_point = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * sample_point;
		sample_point = sample_point * 2.03 + vec2(37.0, 17.0);
		amplitude *= 0.5;
	}
	return total / normalization;
}


// [param edge_scale] widens the coverage threshold, which is how the layer
// stops aliasing as it stretches towards the horizon: it is the cheap stand-in
// for the mip level a texture lookup would have picked. Pass 1.0 for a lookup
// that is not being minified.
float dnc_cloud_density(vec4 params, vec4 motion, vec2 world_xz, float edge_scale) {
	if (params.y <= 0.0) {
		return 0.0;
	}
	float raw = dnc_cloud_field((world_xz + motion.xz) * params.y, motion.y);
	float edge = max(params.w * edge_scale, 0.001);
	return smoothstep(params.z - edge, params.z + edge, raw);
}


// Fraction of the sun a world position loses to the layer overhead.
float dnc_cloud_shadow(
		vec4 params,
		vec4 motion,
		vec3 world_position,
		vec3 direction_to_sun) {
	// Under a grazing sun the ray runs almost parallel to the layer and the
	// travel distance explodes, so the shadow is dropped rather than smeared
	// out to the horizon.
	if (params.y <= 0.0 || motion.w <= 0.0 || direction_to_sun.y <= 0.05) {
		return 0.0;
	}
	float travel = (params.x - world_position.y) / direction_to_sun.y;
	if (travel <= 0.0) {
		return 0.0;
	}
	vec2 hit = world_position.xz + direction_to_sun.xz * travel;
	return dnc_cloud_density(params, motion, hit, 1.0) * motion.w;
}


// Canonical Retro RT analytic ground layer. Keep every function below
// byte-identical in each copy: addons/retro_rt/shaders/rt_shadow_reflect.glsl,
// addons/retro_rt/shaders/BlinnPhongSoftwareBody.gdshaderinc.
// Normative text: addons/retro_rt/docs/RT_PIPELINE.md, "Analytic ground layer".
//
// Streamed terrain is receiver-only and shell grass is unmanaged, so neither
// is in the acceleration structure and a reflection ray can never hit the
// ground. This layer resolves that one miss against a camera-centred
// heightfield instead of admitting chunks to the TLAS, which would rebuild it
// on every chunk commit and forbid the vertex colours the ground is authored
// with.
//
// RGB is the producer's own terrain colour, already scene-linear, and A is
// canopy height in world Y: the terrain surface plus the grass the shell
// renderer draws on top of it. The reflected ground is therefore the grass
// canopy by construction, with no grass geometry traced and no colour rule
// restated here to drift from the one that bakes the vertex colours.
//
// params: x,y=window origin in world XZ, z=1/window size in metres, w=march
// step count (zero disables the layer).
// bounds: x=lowest canopy height, y=highest canopy height, z=maximum march
// distance, w=texel size in metres.
const int RT_GROUND_REFINE_STEPS = 4;


vec4 rt_ground_sample(sampler2D ground_map, vec4 params, vec3 world_position) {
	// Fetched and blended by hand rather than handed to the sampler, the way the
	// environment panorama is and for the same reason: the two backends have to
	// agree bit for bit and drivers round filtering differently.
	//
	// Blending rather than point sampling is not a quality option here. This
	// field is a surface a ray gets marched against, and a staircase of texels
	// catches a grazing ray on its risers, which paints the reflection in flat
	// axis-aligned plateaus rather than terrain.
	ivec2 map_size = max(textureSize(ground_map, 0), ivec2(1));
	vec2 texel_position =
		(world_position.xz - params.xy) * params.z * vec2(map_size) - vec2(0.5);
	ivec2 base = ivec2(floor(texel_position));
	vec2 blend = fract(texel_position);
	// Clamped rather than wrapped: past the window edge the march is already
	// being cut short by the window test, and a wrap would fold far terrain back
	// under the reflector.
	ivec2 low = clamp(base, ivec2(0), map_size - ivec2(1));
	ivec2 high = clamp(base + ivec2(1), ivec2(0), map_size - ivec2(1));
	vec4 near_row = mix(
		texelFetch(ground_map, ivec2(low.x, low.y), 0),
		texelFetch(ground_map, ivec2(high.x, low.y), 0),
		blend.x);
	vec4 far_row = mix(
		texelFetch(ground_map, ivec2(low.x, high.y), 0),
		texelFetch(ground_map, ivec2(high.x, high.y), 0),
		blend.x);
	return mix(near_row, far_row, blend.y);
}


// Ray against the window box, so a reflection that never reaches the ground
// costs this test and nothing else. That early-out is what keeps the layer
// affordable: most mirror pixels point at sky.
bool rt_ground_window(
		vec4 params,
		vec4 bounds,
		vec3 origin,
		vec3 direction,
		out float enter_distance,
		out float exit_distance) {
	float window_size = 1.0 / max(params.z, 1e-6);
	vec3 box_min = vec3(params.x, bounds.x, params.y);
	vec3 box_max = vec3(params.x + window_size, bounds.y, params.y + window_size);
	// A zero component yields an infinite slab bound here, which min and max
	// order correctly. Only an origin exactly on the face of a parallel ray
	// produces a NaN, and the ordered comparison below rejects that case.
	vec3 inverse_direction = 1.0 / direction;
	vec3 first_plane = (box_min - origin) * inverse_direction;
	vec3 second_plane = (box_max - origin) * inverse_direction;
	vec3 near_plane = min(first_plane, second_plane);
	vec3 far_plane = max(first_plane, second_plane);
	enter_distance = max(max(near_plane.x, near_plane.y), max(near_plane.z, 0.0));
	exit_distance = min(min(far_plane.x, far_plane.y), min(far_plane.z, bounds.z));
	return exit_distance > enter_distance;
}


// Central differences over the canopy channel, in the shape the terrain mesher
// gives its vertex normals, so the reflected ground shades like the ground it
// stands in for.
vec3 rt_ground_normal(
		sampler2D ground_map,
		vec4 params,
		vec4 bounds,
		vec3 world_position) {
	vec3 offset_x = vec3(bounds.w, 0.0, 0.0);
	vec3 offset_z = vec3(0.0, 0.0, bounds.w);
	float left = rt_ground_sample(ground_map, params, world_position - offset_x).a;
	float right = rt_ground_sample(ground_map, params, world_position + offset_x).a;
	float back = rt_ground_sample(ground_map, params, world_position - offset_z).a;
	float front = rt_ground_sample(ground_map, params, world_position + offset_z).a;
	return normalize(vec3(left - right, 2.0 * bounds.w, back - front));
}


// Uniform march to the first crossing, then a fixed bisection of that one
// interval. Both counts stay small on purpose: this runs only for a reflection
// ray that entered the window, and it stands in for ground far enough away
// that a silhouette a texel or two out cannot be read.
bool rt_ground_trace(
		sampler2D ground_map,
		vec4 params,
		vec4 bounds,
		vec3 origin,
		vec3 direction,
		out vec3 hit_position,
		out float hit_distance) {
	hit_position = origin;
	hit_distance = 0.0;
	int step_count = int(params.w);
	float enter_distance = 0.0;
	float exit_distance = 0.0;
	if (step_count < 1 || !rt_ground_window(
			params, bounds, origin, direction, enter_distance, exit_distance)) {
		return false;
	}
	vec3 entry_position = origin + direction * enter_distance;
	if (entry_position.y < rt_ground_sample(ground_map, params, entry_position).a) {
		// The ray starts under the canopy, which is the ordinary case for a mirror
		// resting in grass rather than an error: the bottom of the reflector is
		// inside the layer. Resolving it where it stands shows the canopy it is
		// sitting in. Marching on instead would find no crossing and let sky out
		// through the underside of the reflector.
		hit_distance = enter_distance;
		hit_position = entry_position;
		return true;
	}
	float step_size = (exit_distance - enter_distance) / float(step_count);
	float previous_distance = enter_distance;
	for (int index = 1; index <= step_count; index++) {
		float current_distance = enter_distance + step_size * float(index);
		vec3 current_position = origin + direction * current_distance;
		if (current_position.y < rt_ground_sample(ground_map, params, current_position).a) {
			float above_distance = previous_distance;
			float below_distance = current_distance;
			for (int refine = 0; refine < RT_GROUND_REFINE_STEPS; refine++) {
				float middle_distance = (above_distance + below_distance) * 0.5;
				vec3 middle_position = origin + direction * middle_distance;
				if (middle_position.y
						< rt_ground_sample(ground_map, params, middle_position).a) {
					below_distance = middle_distance;
				} else {
					above_distance = middle_distance;
				}
			}
			hit_distance = below_distance;
			hit_position = origin + direction * hit_distance;
			return true;
		}
		previous_distance = current_distance;
	}
	return false;
}


// One reflection miss resolved against the ground instead of the sky. Returns
// false when the ray leaves the window without crossing the canopy, which is
// the caller's signal to fall back to the environment exactly as before.
bool rt_ground_reflection(
		sampler2D ground_map,
		vec4 params,
		vec4 bounds,
		vec4 sun_direction,
		vec4 sun_radiance,
		vec4 ambient,
		vec4 cloud_params,
		vec4 cloud_motion,
		vec3 cloud_sun_direction,
		vec4 fog_params,
		vec3 environment_radiance,
		vec3 origin,
		vec3 direction,
		out vec3 radiance) {
	radiance = vec3(0.0);
	vec3 hit_position = origin;
	float hit_distance = 0.0;
	if (!rt_ground_trace(
			ground_map, params, bounds, origin, direction, hit_position, hit_distance)) {
		return false;
	}
	vec3 albedo = rt_ground_sample(ground_map, params, hit_position).rgb;
	vec3 normal = rt_ground_normal(ground_map, params, bounds, hit_position);
	float n_dot_l = max(dot(normal, sun_direction.xyz), 0.0) * sun_direction.w;
	vec3 lit = albedo * (ambient.rgb + sun_radiance.rgb * n_dot_l);
	lit *= 1.0 - dnc_cloud_shadow(cloud_params, cloud_motion, hit_position, cloud_sun_direction);
	// Fades into exactly what this ray would have returned had it missed, which
	// is what the caller passes in. Fading to the flat fog colour instead leaves
	// a visible step at the fog boundary, because below the horizon a sky is
	// free to draw something other than its horizon band, and the mirror shows
	// both sides of that boundary at once.
	radiance = mix(lit, environment_radiance, rt_fog_factor(fog_params, hit_distance));
	return true;
}


vec3 get_triplanar_weights(vec3 mapping_normal, float sharpness) {
	float normal_length_squared = dot(mapping_normal, mapping_normal);
	vec3 absolute_normal = normal_length_squared > 1e-12
		? abs(mapping_normal * inversesqrt(normal_length_squared))
		: vec3(0.0, 1.0, 0.0);
	float clamped_sharpness = clamp(sharpness, 0.0, 150.0);
	if (clamped_sharpness <= 0.0) {
		return vec3(1.0 / 3.0);
	}
	vec3 weights = pow(absolute_normal, vec3(clamped_sharpness));
	float weight_sum = dot(weights, vec3(1.0));
	if (weight_sum > 1e-37) {
		return weights / weight_sum;
	}
	if (absolute_normal.x >= absolute_normal.y && absolute_normal.x >= absolute_normal.z) {
		return vec3(1.0, 0.0, 0.0);
	}
	return absolute_normal.y >= absolute_normal.z
		? vec3(0.0, 1.0, 0.0)
		: vec3(0.0, 0.0, 1.0);
}


vec3 decode_open_gl_normal(vec3 encoded_normal) {
	vec2 tangent_xy = encoded_normal.rg * 2.0 - 1.0;
	tangent_xy *= inversesqrt(max(1.0, dot(tangent_xy, tangent_xy)));
	return vec3(tangent_xy, sqrt(max(1.0 - dot(tangent_xy, tangent_xy), 0.0)));
}


int environment_positive_mod(int value, int divisor) {
	int result = value % divisor;
	return result < 0 ? result + divisor : result;
}


vec3 sample_environment_miss(vec3 world_direction) {
	if (swrt_environment_mode == 0) {
		return swrt_miss_color.rgb;
	}
	mat3 inverse_sky_basis = mat3(
		swrt_environment_basis_x,
		swrt_environment_basis_y,
		swrt_environment_basis_z);
	vec3 transformed = inverse_sky_basis * world_direction;
	float length_squared = dot(transformed, transformed);
	vec3 direction = length_squared > 1e-12
		? transformed * inversesqrt(length_squared)
		: vec3(0.0, 0.0, -1.0);
	vec2 uv = vec2(atan(direction.x, -direction.z), acos(clamp(direction.y, -1.0, 1.0)));
	if (uv.x < 0.0) {
		uv.x += 6.283185307179586;
	}
	uv /= vec2(6.283185307179586, 3.141592653589793);

	ivec2 panorama_size = max(textureSize(swrt_environment_panorama, 0), ivec2(1));
	vec2 texel_position = uv * vec2(panorama_size) - vec2(0.5);
	ivec2 base = ivec2(floor(texel_position));
	vec2 blend = fract(texel_position);
	int x0 = environment_positive_mod(base.x, panorama_size.x);
	int x1 = environment_positive_mod(base.x + 1, panorama_size.x);
	int y0 = clamp(base.y, 0, panorama_size.y - 1);
	int y1 = clamp(base.y + 1, 0, panorama_size.y - 1);
	vec3 top = mix(
		texelFetch(swrt_environment_panorama, ivec2(x0, y0), 0).rgb,
		texelFetch(swrt_environment_panorama, ivec2(x1, y0), 0).rgb,
		blend.x);
	vec3 bottom = mix(
		texelFetch(swrt_environment_panorama, ivec2(x0, y1), 0).rgb,
		texelFetch(swrt_environment_panorama, ivec2(x1, y1), 0).rgb,
		blend.x);
	return mix(top, bottom, blend.y);
}


vec3 apply_uv_normal(
		vec3 encoded_normal,
		vec3 geometric_normal,
		vec3 view_position,
		vec2 surface_uv) {
	vec3 position_dx = dFdx(view_position);
	vec3 position_dy = dFdy(view_position);
	vec2 uv_dx = dFdx(surface_uv);
	vec2 uv_dy = dFdy(surface_uv);
	float determinant = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;
	if (abs(determinant) <= 1e-8) {
		return geometric_normal;
	}
	vec3 tangent = (position_dx * uv_dy.y - position_dy * uv_dx.y) / determinant;
	vec3 bitangent_reference = (position_dy * uv_dx.x - position_dx * uv_dy.x) / determinant;
	tangent -= geometric_normal * dot(geometric_normal, tangent);
	float tangent_length_squared = dot(tangent, tangent);
	float bitangent_length_squared = dot(bitangent_reference, bitangent_reference);
	if (tangent_length_squared <= 1e-12 || bitangent_length_squared <= 1e-12) {
		return geometric_normal;
	}
	tangent *= inversesqrt(tangent_length_squared);
	vec3 perpendicular = cross(geometric_normal, tangent);
	float handedness_measure = dot(perpendicular, bitangent_reference);
	if (abs(handedness_measure) <= 1e-8) {
		return geometric_normal;
	}
	vec3 bitangent = perpendicular * (handedness_measure < 0.0 ? -1.0 : 1.0);
	vec3 tangent_normal = decode_open_gl_normal(encoded_normal);
	return normalize(
		tangent * tangent_normal.x
		+ bitangent * tangent_normal.y
		+ geometric_normal * tangent_normal.z);
}


void vertex() {
	if (triplanar_enabled) {
		vec3 mapping_normal = triplanar_world_space ? MODEL_NORMAL_MATRIX * NORMAL : NORMAL;
		vec3 mapping_position = triplanar_world_space
			? (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz
			: VERTEX;
		vec3 generated_tangent = vec3(0.0, 0.0, -1.0) * abs(mapping_normal.x);
		generated_tangent += vec3(1.0, 0.0, 0.0) * abs(mapping_normal.y);
		generated_tangent += vec3(1.0, 0.0, 0.0) * abs(mapping_normal.z);
		vec3 generated_binormal = vec3(0.0, 1.0, 0.0) * abs(mapping_normal.x);
		generated_binormal += vec3(0.0, 0.0, -1.0) * abs(mapping_normal.y);
		generated_binormal += vec3(0.0, 1.0, 0.0) * abs(mapping_normal.z);
		if (triplanar_world_space) {
			TANGENT = inverse(MODEL_NORMAL_MATRIX) * normalize(generated_tangent);
			BINORMAL = inverse(MODEL_NORMAL_MATRIX) * normalize(generated_binormal);
		} else {
			TANGENT = normalize(generated_tangent);
			BINORMAL = normalize(generated_binormal);
		}
		rt_triplanar_weights = get_triplanar_weights(
			mapping_normal, triplanar_sharpness);
		rt_triplanar_position = (mapping_position * triplanar_scale + triplanar_offset)
			* vec3(1.0, -1.0, 1.0);
	}
}

#include "rt_software.gdshaderinc"


void fragment() {
	SWRTFrameContext swrt_context = swrt_make_frame_context();
	int primary_object_id = rt_instance_id - 1;
	bool valid = primary_object_id >= 0
		&& primary_object_id < swrt_context.instance_count
		&& rt_material_id > 0
		&& rt_material_id <= swrt_context.shading_counts.y;
#ifdef SWRT_VALIDATE_HEADERS
	valid = valid && swrt_validate_headers(swrt_context);
#endif
	SWRTInstance primary_instance;
	SWRTMaterial primary_material;
	if (valid) {
		// Primary raster data is already bound to this material/instance. Avoid
		// reloading its complete atlas records before every lighting query.
		primary_instance.metadata = vec4(0.0, 0.0, float(rt_receiver_layers), 0.0);
		primary_instance.light_list = vec4(
			float(rt_receiver_light_start), float(rt_receiver_light_count), 0.0, 0.0);
		primary_instance.world_to_object = mat3(1.0);
		primary_instance.object_origin = vec3(0.0);
		primary_instance.normal_to_world = mat3(1.0);
		primary_material.diffuse_shininess = vec4(
			swrt_primary_diffuse_color, swrt_primary_shininess);
		primary_material.ambient_intensity = vec4(
			swrt_primary_ambient_color, swrt_primary_direct_specular_intensity);
		primary_material.emission_flags = vec4(
			swrt_primary_emission_color,
			swrt_primary_reflection_shadows_enabled ? 1.0 : 0.0);
		primary_material.specular_flags = vec4(swrt_primary_specular_color, 0.0);
		primary_material.albedo_region = vec4(0.0);
		primary_material.normal_region = vec4(0.0);
		primary_material.triplanar_scale_sharpness = vec4(0.0);
		primary_material.triplanar_offset = vec4(0.0);
	}
	if (!valid) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
	} else {
		mat3 camera_to_world = mat3(INV_VIEW_MATRIX);
		vec3 world_position = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		// Godot normalizes N/T/B per vertex, then interpolates them. Preserve the
		// raw interpolated normal for triplanar TBN application (matching the
		// authored NORMAL_MAP path), while keeping a normalized copy for lighting,
		// UV tangent construction, and safe ray bias.
		vec3 interpolated_view_normal = NORMAL;
		vec3 geometric_view_normal = normalize(interpolated_view_normal);
		vec3 geometric_world_normal = normalize(camera_to_world * geometric_view_normal);
		vec3 sampled_albedo = vec3(1.0);
		if (rt_has_albedo_texture) {
			sampled_albedo = triplanar_enabled
				? sample_triplanar(
					albedo_texture, rt_triplanar_weights, rt_triplanar_position).rgb
				: texture(albedo_texture, UV).rgb;
			if (swrt_compatibility_output) {
				sampled_albedo = swrt_srgb_to_linear(sampled_albedo);
			}
		}
		if (vertex_color_enabled) {
			sampled_albedo *= COLOR.rgb;
		}
		vec3 surface_diffuse = swrt_primary_diffuse_color * sampled_albedo;
		primary_material.diffuse_shininess.rgb = surface_diffuse;

		vec3 shading_view_normal = geometric_view_normal;
		if (rt_has_normal_texture) {
			vec3 encoded_normal = triplanar_enabled
				? sample_triplanar(
					normal_texture, rt_triplanar_weights, rt_triplanar_position).rgb
				: texture(normal_texture, UV).rgb;
			if (triplanar_enabled) {
				vec3 tangent_normal = decode_open_gl_normal(encoded_normal);
				shading_view_normal = normalize(
					TANGENT * tangent_normal.x
					+ BINORMAL * tangent_normal.y
					+ interpolated_view_normal * tangent_normal.z);
			} else {
				shading_view_normal = apply_uv_normal(
					encoded_normal, geometric_view_normal, VERTEX, UV);
			}
		}
		vec3 shading_world_normal = normalize(camera_to_world * shading_view_normal);
		vec3 camera_position = INV_VIEW_MATRIX[3].xyz;
		vec3 view_direction = normalize(camera_position - world_position);
		float reflection_amount = mirror_enabled
			? floor(clamp(reflection_strength, 0.0, 1.0) * 127.0 + 0.5) / 127.0
			: 0.0;

		int selected_light;
		vec3 selected_contribution;
		vec3 selected_shadow_direction;
		float selected_shadow_distance;
		bool malformed_light_list;
		vec3 direct_lighting = swrt_evaluate_primary_lights(
			swrt_context,
			world_position,
			shading_world_normal,
			view_direction,
			primary_material,
			primary_instance,
			reflection_amount,
			selected_light,
			selected_contribution,
			selected_shadow_direction,
			selected_shadow_distance,
			malformed_light_list);

		float ray_bias = swrt_context.settings.x;
		bool malformed = malformed_light_list;
		if (selected_light >= 0) {
			SWRTHit shadow_hit;
			bool shadow_overflow;
			bool obstructed = swrt_trace_scene(
				swrt_context,
				world_position + shading_world_normal * ray_bias,
				selected_shadow_direction,
				ray_bias,
				selected_shadow_distance,
				1u,
				true,
				shadow_hit,
				shadow_overflow);
			malformed = malformed || shadow_overflow;
			if (obstructed) {
				direct_lighting -= selected_contribution;
			}
		}

		vec3 ambient_emission = surface_diffuse * swrt_primary_ambient_color + swrt_primary_emission_color;
		vec3 reflected_radiance = swrt_context.miss_color.rgb;
		if (reflection_amount > (0.5 / 127.0)) {
			vec3 reflection_direction = normalize(reflect(-view_direction, shading_world_normal));
			vec3 reflection_origin = world_position + shading_world_normal * ray_bias;
			SWRTHit reflection_hit;
			bool reflection_overflow;
			bool reflection_found = swrt_trace_scene(
				swrt_context,
				reflection_origin,
				reflection_direction,
				ray_bias,
				swrt_context.settings.y,
				2u,
				false,
				reflection_hit,
				reflection_overflow);
			malformed = malformed || reflection_overflow;
			if (reflection_found) {
				vec3 hit_position = reflection_origin + reflection_direction * reflection_hit.distance;
				vec3 hit_geometric_normal;
				vec3 hit_shading_normal;
				SWRTMaterial hit_material;
				SWRTInstance hit_instance;
				if (!swrt_load_hit_shading(
						swrt_context,
						reflection_hit,
						reflection_direction,
						hit_position,
						hit_geometric_normal,
						hit_shading_normal,
						hit_material,
						hit_instance)) {
					malformed = true;
				} else {
					int reflected_shadow_light;
					vec3 reflected_shadow_contribution;
					vec3 reflected_shadow_direction;
					float reflected_shadow_distance;
					bool malformed_hit_light_list;
					reflected_radiance = swrt_shade_terminal_hit(
						swrt_context,
						hit_position,
						hit_shading_normal,
						reflection_direction,
						hit_material,
						hit_instance,
						primary_material.emission_flags.w >= 0.5,
						reflected_shadow_light,
						reflected_shadow_contribution,
						reflected_shadow_direction,
						reflected_shadow_distance,
						malformed_hit_light_list);
					malformed = malformed || malformed_hit_light_list;
					if (primary_material.emission_flags.w >= 0.5 && reflected_shadow_light >= 0) {
						SWRTHit reflected_shadow_hit;
						bool reflected_shadow_overflow;
						bool reflected_obstructed = swrt_trace_scene(
							swrt_context,
							hit_position + hit_geometric_normal * ray_bias,
							reflected_shadow_direction,
							ray_bias,
							reflected_shadow_distance,
							1u,
							true,
							reflected_shadow_hit,
							reflected_shadow_overflow);
						malformed = malformed || reflected_shadow_overflow;
						if (reflected_obstructed) {
							reflected_radiance -= reflected_shadow_contribution;
						}
					}
				}
			} else {
				// Sampled once and used for both outcomes: it is the fallback when
				// the march finds no ground, and the target the ground fades into
				// when it does, which keeps the two continuous at the fog boundary.
				vec3 environment_radiance = sample_environment_miss(reflection_direction);
				if (!rt_ground_reflection(
						swrt_ground_map,
						swrt_ground_params,
						swrt_ground_bounds,
						swrt_ground_sun_direction,
						swrt_ground_sun_radiance,
						swrt_ground_ambient,
						swrt_cloud_params,
						swrt_cloud_motion,
						swrt_cloud_sun_direction,
						swrt_fog_params,
						environment_radiance,
						reflection_origin,
						reflection_direction,
						reflected_radiance)) {
					reflected_radiance = environment_radiance;
				}
			}
		}

		vec3 base_lighting = reflection_amount > (0.5 / 127.0)
			? mix(ambient_emission, reflected_radiance, reflection_amount)
			: ambient_emission;
		// Fog matches the hardware path: applied post-lighting to the primary hit
		// only, fading to the environment radiance the post stack also composites
		// into uncovered pixels.
		// The cloud layer shadows the primary hit at the same point the hardware
		// path applies it, so the two backends stay matched.
		direct_lighting *= 1.0 - dnc_cloud_shadow(
			swrt_cloud_params,
			swrt_cloud_motion,
			world_position,
			swrt_cloud_sun_direction);
		vec3 lit = base_lighting + direct_lighting;
		float fog = rt_fog_factor(swrt_fog_params, length(world_position - camera_position));
		lit = mix(lit, swrt_miss_color.rgb, fog);
		ALBEDO = malformed ? vec3(1.0, 0.0, 1.0) : lit;
		// Compatibility always linearizes spatial ALBEDO before its lighting/
		// tonemap stage. Compensate only at this renderer boundary so the value
		// arriving at the shared post stack remains canonical scene-linear RGB.
		if (!malformed && swrt_compatibility_output) {
			ALBEDO = swrt_linear_to_srgb(max(ALBEDO, vec3(0.0)));
		}
	}
}
