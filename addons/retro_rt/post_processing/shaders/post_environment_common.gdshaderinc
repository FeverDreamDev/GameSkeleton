uniform int environment_mode = 0;
uniform vec3 environment_flat_linear = vec3(0.0);
uniform sampler2D environment_panorama : filter_nearest, repeat_disable, hint_default_black;
uniform vec3 environment_basis_x = vec3(1.0, 0.0, 0.0);
uniform vec3 environment_basis_y = vec3(0.0, 1.0, 0.0);
uniform vec3 environment_basis_z = vec3(0.0, 0.0, 1.0);
uniform vec3 camera_ray_top_left = vec3(0.0, 0.0, -1.0);
uniform vec3 camera_ray_top_right = vec3(0.0, 0.0, -1.0);
uniform vec3 camera_ray_bottom_left = vec3(0.0, 0.0, -1.0);
uniform vec3 camera_ray_bottom_right = vec3(0.0, 0.0, -1.0);
uniform bool recover_opaque_coverage_from_rgb = false;
uniform bool scene_input_is_linear = false;

float rt_post_scene_coverage(vec4 sampled) {
	float coverage = clamp(sampled.a, 0.0, 1.0);
	// Forward+ compositor storage writes do not propagate managed opaque alpha
	// to a transparent ViewportTexture. Transparent raster objects still carry
	// authored alpha, while uncovered pixels are transparent black, so recover
	// only the zero-alpha/nonblack managed case.
	if (recover_opaque_coverage_from_rgb
			&& coverage <= 0.00001
			&& max(sampled.r, max(sampled.g, sampled.b)) > 0.000001) {
		coverage = 1.0;
	}
	return coverage;
}

int rt_post_positive_mod(int value, int divisor) {
	int result = value % divisor;
	return result < 0 ? result + divisor : result;
}

vec3 rt_post_sample_environment(vec3 world_direction) {
	if (environment_mode == 0) {
		return environment_flat_linear;
	}
	mat3 inverse_sky_basis = mat3(
		environment_basis_x,
		environment_basis_y,
		environment_basis_z);
	vec3 transformed = inverse_sky_basis * world_direction;
	float length_squared = dot(transformed, transformed);
	vec3 direction = length_squared > 1e-12
		? transformed * inversesqrt(length_squared)
		: vec3(0.0, 0.0, -1.0);
	vec2 uv = vec2(
		atan(direction.x, -direction.z),
		acos(clamp(direction.y, -1.0, 1.0)));
	if (uv.x < 0.0) {
		uv.x += 6.283185307179586;
	}
	uv /= vec2(6.283185307179586, 3.141592653589793);

	ivec2 panorama_size = max(textureSize(environment_panorama, 0), ivec2(1));
	vec2 texel_position = uv * vec2(panorama_size) - vec2(0.5);
	ivec2 base = ivec2(floor(texel_position));
	vec2 blend = fract(texel_position);
	int x0 = rt_post_positive_mod(base.x, panorama_size.x);
	int x1 = rt_post_positive_mod(base.x + 1, panorama_size.x);
	int y0 = clamp(base.y, 0, panorama_size.y - 1);
	int y1 = clamp(base.y + 1, 0, panorama_size.y - 1);
	vec3 top = mix(
		texelFetch(environment_panorama, ivec2(x0, y0), 0).rgb,
		texelFetch(environment_panorama, ivec2(x1, y0), 0).rgb,
		blend.x);
	vec3 bottom = mix(
		texelFetch(environment_panorama, ivec2(x0, y1), 0).rgb,
		texelFetch(environment_panorama, ivec2(x1, y1), 0).rgb,
		blend.x);
	return mix(top, bottom, blend.y);
}

vec3 rt_post_camera_world_ray(vec2 uv) {
	vec3 top = mix(camera_ray_top_left, camera_ray_top_right, uv.x);
	vec3 bottom = mix(camera_ray_bottom_left, camera_ray_bottom_right, uv.x);
	return normalize(mix(top, bottom, uv.y));
}

vec3 rt_post_sdr_boundary(vec3 linear_radiance) {
	// Clamp once before SMAA without adding another explicit quantization stage.
	// The RGBA16F targets retain their native precision until the shared LDR
	// presentation target.
	return clamp(linear_radiance, vec3(0.0), vec3(1.0));
}
