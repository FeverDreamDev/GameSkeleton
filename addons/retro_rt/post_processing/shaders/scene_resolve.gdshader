shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Resolves the scene capture into the visible image the rest of the stack
// presents. One pass, one job: undo the capture's coverage premultiplication and
// reconstruct the environment behind every texel geometry did not cover.
//
// It runs at the output size, 1:1 with the capture, and resamples nothing.
//
// Output is perceptual (sRGB-encoded). The present pass performs the single
// decode back to scene-linear before the artistic grade.
uniform sampler2D scene_texture : filter_nearest, repeat_disable;
uniform vec2 viewport_size = vec2(1.0);

#include "rt_transfer_common.gdshaderinc"
#include "post_environment_common.gdshaderinc"

vec4 decode_scene_texel(ivec2 pixel) {
	ivec2 scene_size = max(textureSize(scene_texture, 0), ivec2(1));
	pixel = clamp(pixel, ivec2(0), scene_size - ivec2(1));
	vec4 sampled = texelFetch(scene_texture, pixel, 0);
	float coverage = rt_post_scene_coverage(sampled);
	// Transparent render targets are already premultiplied by coverage. Decode
	// each exact texel so downstream filtering always happens in scene-linear
	// storage rather than in whatever the target happens to hold.
	// Forward+ honors use_hdr_2d, so the capture always stores scene-linear
	// radiance; startup fails loudly if a target ever refuses that format.
	vec3 linear_rgb = coverage > 0.00001
		? clamp(sampled.rgb / coverage, vec3(0.0), vec3(1.0))
		: vec3(0.0);
	vec2 pixel_uv = (vec2(pixel) + vec2(0.5)) / vec2(scene_size);
	vec3 visible_linear = linear_rgb * coverage;
	// The environment is only visible where geometry is not. A fully covered
	// texel multiplies the reconstruction by exactly zero, and
	// rt_post_sample_environment() is always finite -- it returns either a
	// uniform or a mix of texelFetch results -- so skipping it there is an
	// equivalence, not an approximation. It saves an atan, an acos and a
	// four-tap panorama fetch. A scene that draws its background as geometry
	// rather than leaving it to the environment, such as a sky dome, takes this
	// branch on every pixel of every frame. The raster fallback captures opaque,
	// so it takes it on none.
	if (coverage < 1.0) {
		visible_linear += rt_post_sample_environment(rt_post_camera_world_ray(pixel_uv))
			* (1.0 - coverage);
	}
	// This is the one HDR-to-SDR scene boundary; artistic grading follows.
	return vec4(rt_post_sdr_boundary(visible_linear), 1.0);
}

void fragment() {
	ivec2 pixel = ivec2(floor(UV * max(viewport_size, vec2(1.0))));
	vec4 color = decode_scene_texel(pixel);
	COLOR = vec4(rt_linear_to_srgb(clamp(color.rgb, vec3(0.0), vec3(1.0))), 1.0);
}
