shader_type canvas_item;
render_mode unshaded;

// Final presentation. Its source is always 1:1 with this rect -- the scene
// resolve target, or the Panini target when that pass is active -- and carries
// perceptual (sRGB-encoded) color, which this pass decodes once back to
// scene-linear for the artistic grade.
//
// This pass never samples SceneCapture, performs no reconstruction, and
// resamples nothing. The optional sharpen below reads neighbours by texelFetch
// at the same 1:1 grid, so it remains a neighbourhood filter rather than a
// resample.
uniform sampler2D source_texture : filter_nearest, repeat_disable;
// Contrast Adaptive Sharpening over the Panini output, at native resolution.
//
// The projection magnifies screen center -- the target's pixel budget decides
// by how much -- and that magnification is a resampling blur, which is exactly
// what a contrast-adaptive sharpener is good at. It runs here rather than in its
// own pass because this pass is already a full-rect native-resolution draw over
// the same source, so folding it in costs four extra taps instead of another
// 2560x1440 render target.
//
// Gated on the projection, not left always-on: with Panini bypassed the source
// is the 1:1 resolve target, which was never magnified and has nothing for this
// to recover.
uniform bool sharpen_enabled = false;
uniform float sharpen_strength = 0.0;
uniform bool grade_enabled = true;
uniform float brightness = 1.0;
uniform float contrast = 1.12;
uniform float saturation = 1.08;
uniform float black_point = 0.005;
uniform vec3 color_balance = vec3(1.02, 1.0, 0.97);
uniform bool posterize_enabled = false;
uniform float posterize_levels = 256.0;
uniform float posterize_strength = 1.0;

#include "rt_transfer_common.gdshaderinc"
#include "retro_grade_common.gdshaderinc"

vec3 fetch_source(ivec2 pixel, ivec2 source_size) {
	return texelFetch(
		source_texture, clamp(pixel, ivec2(0), source_size - ivec2(1)), 0).rgb;
}


// AMD Contrast Adaptive Sharpening, cross-tap form. The adaptive term is the
// point: the sharpening amount falls off wherever local contrast is already
// high, so it lifts the magnified midtone detail without ringing the
// high-contrast edges that the projection's Catmull-Rom branch has already
// overshot. Runs in the source's perceptual space, which is where CAS is
// defined and where the source already lives.
vec3 contrast_adaptive_sharpen(
		ivec2 pixel, ivec2 source_size, vec3 center, float strength) {
	vec3 up = fetch_source(pixel + ivec2(0, -1), source_size);
	vec3 left = fetch_source(pixel + ivec2(-1, 0), source_size);
	vec3 right = fetch_source(pixel + ivec2(1, 0), source_size);
	vec3 down = fetch_source(pixel + ivec2(0, 1), source_size);

	vec3 minimum = min(min(min(up, left), min(right, down)), center);
	vec3 maximum = max(max(max(up, left), max(right, down)), center);
	// Headroom to the nearer clipping limit, so a value already near 0 or 1
	// cannot be pushed past it. rcp is guarded because maximum reaches 0 on a
	// black frame.
	vec3 headroom = min(minimum, vec3(1.0) - maximum)
		/ max(maximum, vec3(0.0001));
	vec3 amplitude = sqrt(clamp(headroom, vec3(0.0), vec3(1.0)));
	// CAS peaks at a weight of -1/8 per neighbour; strength scales within that.
	vec3 weight = amplitude * (-0.125 * clamp(strength, 0.0, 1.0));
	vec3 sharpened = (up + left + right + down) * weight + center;
	return clamp(
		sharpened / (4.0 * weight + vec3(1.0)), vec3(0.0), vec3(1.0));
}


void fragment() {
	ivec2 source_size = max(textureSize(source_texture, 0), ivec2(1));
	ivec2 pixel = clamp(
		ivec2(floor(UV * vec2(source_size))), ivec2(0), source_size - ivec2(1));

	vec3 source = texelFetch(source_texture, pixel, 0).rgb;
	if (sharpen_enabled && sharpen_strength > 0.0) {
		source = contrast_adaptive_sharpen(
			pixel, source_size, source, sharpen_strength);
	}
	vec3 color = rt_srgb_to_linear(source);
	if (grade_enabled) {
		color = rt_apply_retro_grade(
			color,
			brightness,
			contrast,
			saturation,
			black_point,
			color_balance,
			posterize_enabled,
			posterize_levels,
			posterize_strength
		);
	}
	// Presentation owns one SDR boundary regardless of whether the optional
	// artistic grade is enabled.
	COLOR = vec4(rt_linear_to_srgb(clamp(color, vec3(0.0), vec3(1.0))), 1.0);
}
