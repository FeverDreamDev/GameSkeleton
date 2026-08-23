shader_type canvas_item;
render_mode unshaded, blend_disabled;

// SMAA color edge detection (first pass). The source is sampled at exact
// internal-render-resolution texel centers; edges are intentionally stored as data.
uniform sampler2D scene_texture : filter_nearest, repeat_disable;
uniform vec2 viewport_size = vec2(1.0);
uniform float threshold : hint_range(0.01, 0.5) = 0.1;

const float LOCAL_CONTRAST_ADAPTATION_FACTOR = 2.0;

#include "rt_transfer_common.gdshaderinc"
#include "post_environment_common.gdshaderinc"

vec3 sample_source(vec2 uv, vec2 texel_offset) {
	vec4 sampled = texture(scene_texture, uv + texel_offset / viewport_size);
	// SceneCapture is transparent so the final pass can draw the exact same
	// baked environment on every renderer. Ignore renderer-native sky RGB here;
	// alpha keeps edge detection deterministic at the geometry silhouette.
	float coverage = rt_post_scene_coverage(sampled);
	vec3 straight_srgb = coverage > 0.00001
		? clamp(sampled.rgb / coverage, vec3(0.0), vec3(1.0))
		: vec3(0.0);
	vec3 geometry_linear = (
		scene_input_is_linear
			? straight_srgb
			: rt_srgb_to_linear(straight_srgb)) * coverage;
	vec2 sample_uv = uv + texel_offset / viewport_size;
	vec3 visible_linear = geometry_linear
		+ rt_post_sample_environment(rt_post_camera_world_ray(sample_uv))
			* (1.0 - coverage);
	// HDR is kept through lighting/reflection and clamped at the common SMAA
	// boundary so edge thresholds see exactly the visible SDR scene.
	return rt_post_sdr_boundary(visible_linear);
}

void fragment() {
	vec3 center = sample_source(UV, vec2(0.0));
	vec3 left = sample_source(UV, vec2(-1.0, 0.0));
	vec3 top = sample_source(UV, vec2(0.0, -1.0));

	vec3 delta_left = abs(center - left);
	vec3 delta_top = abs(center - top);
	float delta_x = max(delta_left.r, max(delta_left.g, delta_left.b));
	float delta_y = max(delta_top.r, max(delta_top.g, delta_top.b));
	vec2 edges = step(vec2(threshold), vec2(delta_x, delta_y));

	if (dot(edges, vec2(1.0)) > 0.0) {
		vec3 right = sample_source(UV, vec2(1.0, 0.0));
		vec3 bottom = sample_source(UV, vec2(0.0, 1.0));
		vec3 delta_right = abs(center - right);
		vec3 delta_bottom = abs(center - bottom);
		float max_delta = max(delta_x, delta_y);
		max_delta = max(max_delta, max(delta_right.r, max(delta_right.g, delta_right.b)));
		max_delta = max(max_delta, max(delta_bottom.r, max(delta_bottom.g, delta_bottom.b)));

		vec3 left_left = sample_source(UV, vec2(-2.0, 0.0));
		vec3 top_top = sample_source(UV, vec2(0.0, -2.0));
		vec3 delta_left_left = abs(left - left_left);
		vec3 delta_top_top = abs(top - top_top);
		max_delta = max(max_delta, max(delta_left_left.r, max(delta_left_left.g, delta_left_left.b)));
		max_delta = max(max_delta, max(delta_top_top.r, max(delta_top_top.g, delta_top_top.b)));
		edges *= step(vec2(max_delta), LOCAL_CONTRAST_ADAPTATION_FACTOR * vec2(delta_x, delta_y));
	}

	COLOR = vec4(edges, 0.0, 1.0);
}
