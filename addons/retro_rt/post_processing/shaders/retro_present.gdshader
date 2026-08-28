shader_type canvas_item;
render_mode unshaded;

// Final presentation. Its source is always 1:1 with this rect -- the scene
// resolve target, or the Panini target when that pass is active -- and carries
// perceptual (sRGB-encoded) color, which this pass decodes once back to
// scene-linear for the artistic grade.
//
// This pass never samples SceneCapture, performs no reconstruction, and
// resamples nothing.
uniform sampler2D source_texture : filter_nearest, repeat_disable;
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

void fragment() {
	ivec2 source_size = max(textureSize(source_texture, 0), ivec2(1));
	ivec2 pixel = clamp(
		ivec2(floor(UV * vec2(source_size))), ivec2(0), source_size - ivec2(1));

	vec3 color = rt_srgb_to_linear(texelFetch(source_texture, pixel, 0).rgb);
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
