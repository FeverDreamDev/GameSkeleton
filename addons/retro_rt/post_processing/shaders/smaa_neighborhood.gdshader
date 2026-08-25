shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Third SMAA pass. This runs at the internal render size, not the output size,
// so SMAA completes entirely in the domain it detected its edges in. The result
// is the anti-aliased visible scene, which is what FSR 1 EASU requires as input
// and what the Native path presents directly.
//
// Output is perceptual (sRGB-encoded), because every consumer downstream --
// EASU, RCAS and CAS -- is a FidelityFX kernel specified against display-like
// color rather than raw linear radiance. The present pass performs the single
// decode back to scene-linear before the artistic grade.
uniform sampler2D scene_texture : filter_nearest, repeat_disable;
uniform sampler2D blend_texture : filter_linear, repeat_disable;
uniform vec2 viewport_size = vec2(1.0);
uniform bool aa_enabled = true;

#include "rt_transfer_common.gdshaderinc"
#include "post_environment_common.gdshaderinc"

vec4 decode_scene_texel(ivec2 pixel) {
	ivec2 scene_size = max(textureSize(scene_texture, 0), ivec2(1));
	pixel = clamp(pixel, ivec2(0), scene_size - ivec2(1));
	vec4 sampled = texelFetch(scene_texture, pixel, 0);
	float coverage = rt_post_scene_coverage(sampled);
	// Transparent render targets are already premultiplied by coverage. Decode
	// each exact texel before filtering so Compatibility never interpolates in
	// nonlinear storage while Forward+ interpolates in scene-linear storage.
	vec3 straight_srgb = coverage > 0.00001
		? clamp(sampled.rgb / coverage, vec3(0.0), vec3(1.0))
		: vec3(0.0);
	vec3 linear_rgb = scene_input_is_linear
		? straight_srgb
		: rt_srgb_to_linear(straight_srgb);
	vec2 pixel_uv = (vec2(pixel) + vec2(0.5)) / vec2(scene_size);
	vec3 visible_linear = linear_rgb * coverage;
	// The environment is only visible where geometry is not. A fully covered
	// texel multiplies the reconstruction by exactly zero, and
	// rt_post_sample_environment() is always finite -- it returns either a
	// uniform or a mix of texelFetch results -- so skipping it there is an
	// equivalence, not an approximation. It saves an atan, an acos and a
	// four-tap panorama fetch. A scene that draws its background as geometry
	// rather than leaving it to the environment, such as a sky dome, takes this
	// branch on every pixel of every frame.
	if (coverage < 1.0) {
		visible_linear += rt_post_sample_environment(rt_post_camera_world_ray(pixel_uv))
			* (1.0 - coverage);
	}
	// This is the one HDR-to-SDR scene boundary. SMAA consumes and blends the
	// same normalized visible color on every renderer; artistic grading follows.
	return vec4(rt_post_sdr_boundary(visible_linear), 1.0);
}

// SMAA's intrinsic sub-texel tap. This is a same-resolution filter used to read
// across an edge at a fractional offset; it is not, and must never become, a
// resolution-changing resample. Upscaling is FSR 1 EASU's job alone.
vec4 sample_scene(vec2 uv) {
	ivec2 scene_size = max(textureSize(scene_texture, 0), ivec2(1));
	vec2 texel_position = uv * vec2(scene_size) - vec2(0.5);
	ivec2 base = ivec2(floor(texel_position));
	vec2 blend = fract(texel_position);
	vec4 top = mix(
		decode_scene_texel(base),
		decode_scene_texel(base + ivec2(1, 0)),
		blend.x);
	vec4 bottom = mix(
		decode_scene_texel(base + ivec2(0, 1)),
		decode_scene_texel(base + ivec2(1, 1)),
		blend.x);
	return mix(top, bottom, blend.y);
}

vec4 neighborhood_blend(vec2 uv) {
	vec2 texel = vec2(1.0) / max(viewport_size, vec2(1.0));
	vec4 weights;
	weights.x = texture(blend_texture, uv + vec2(texel.x, 0.0)).a;
	weights.y = texture(blend_texture, uv + vec2(0.0, texel.y)).g;
	vec4 center = texture(blend_texture, uv);
	weights.z = center.b;
	weights.w = center.r;

	if (dot(weights, vec4(1.0)) < 0.00001) {
		// No blend weight means no edge, which is the large majority of the
		// frame. sample_scene() would still run its four-tap bilinear here, and
		// at 1:1 those weights are exactly zero -- three of its four
		// decode_scene_texel() calls, each with its own panorama reconstruction,
		// are computed and then multiplied away. This is the same exact texel
		// decode the aa_enabled == false branch below already presents with.
		return decode_scene_texel(ivec2(floor(uv * max(viewport_size, vec2(1.0)))));
	}

	bool horizontal = max(weights.x, weights.z) > max(weights.y, weights.w);
	vec4 selected = horizontal
		? vec4(weights.x, 0.0, weights.z, 0.0)
		: vec4(0.0, weights.y, 0.0, weights.w);
	vec4 offsets = selected * vec4(texel.x, texel.y, -texel.x, -texel.y);
	vec2 blend_weights = vec2(selected.x + selected.y, selected.z + selected.w);
	blend_weights /= max(dot(blend_weights, vec2(1.0)), 0.00001);
	vec4 first = sample_scene(uv + offsets.xy);
	vec4 second = sample_scene(uv + offsets.zw);
	return blend_weights.x * first + blend_weights.y * second;
}

void fragment() {
	// With AA disabled this pass is an exact 1:1 texel decode. The two SMAA
	// preprocessing viewports stop updating, so no filtering happens at all.
	ivec2 pixel = ivec2(floor(UV * max(viewport_size, vec2(1.0))));
	vec4 color = aa_enabled ? neighborhood_blend(UV) : decode_scene_texel(pixel);
	COLOR = vec4(rt_linear_to_srgb(clamp(color.rgb, vec3(0.0), vec3(1.0))), 1.0);
}
