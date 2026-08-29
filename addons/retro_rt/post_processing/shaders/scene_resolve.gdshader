shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Resolves the opaque scene capture into the visible image the rest of the
// stack presents. Environment and RT composition now finish in scene-linear
// space before temporal upscaling, so this pass must not infer coverage from
// alpha/RGB or reconstruct an environment after FSR2. Exact black is scene
// data again, not a coverage sentinel.
//
// It runs at the rectilinear target size, fetches the matching source texel
// exactly, and resamples nothing. The clamp below remains the stack's one HDR-to-SDR scene
// boundary; output is then perceptual (sRGB-encoded) for the present pass's
// single decode before the artistic grade.
uniform sampler2D scene_texture : filter_nearest, repeat_disable;
uniform vec2 viewport_size = vec2(1.0);

#include "rt_transfer_common.gdshaderinc"

vec3 resolve_scene_texel(ivec2 pixel) {
	ivec2 scene_size = max(textureSize(scene_texture, 0), ivec2(1));
	pixel = clamp(pixel, ivec2(0), scene_size - ivec2(1));
	vec3 scene_linear = texelFetch(scene_texture, pixel, 0).rgb;
	// Preserve the former rt_post_sdr_boundary() operation locally without
	// retaining the environment/coverage include that used to own it.
	return clamp(scene_linear, vec3(0.0), vec3(1.0));
}

void fragment() {
	ivec2 pixel = ivec2(floor(UV * max(viewport_size, vec2(1.0))));
	vec3 sdr_linear = resolve_scene_texel(pixel);
	COLOR = vec4(rt_linear_to_srgb(sdr_linear), 1.0);
}
