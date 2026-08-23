shader_type canvas_item;
render_mode unshaded;

// Final presentation. Its source is always 1:1 with this rect: the SMAA resolve
// target at Native, the FSR EASU target at every reduced preset. Both carry
// perceptual (sRGB-encoded) color, which is the domain CAS and RCAS are
// specified in, so sharpening happens before the single decode back to
// scene-linear for the artistic grade.
//
// This pass never samples SceneCapture and performs no reconstruction. Nothing
// here resamples: the old bilinear upscale lived in the previous fused shader
// and has been replaced by FSR 1 EASU.
uniform sampler2D source_texture : filter_nearest, repeat_disable;
// 0 = passthrough, 1 = FidelityFX CAS, 2 = FSR 1 RCAS. RCAS is used only as
// part of the FSR path; CAS is the optional Native-only sharpener. They are
// never stacked.
uniform int sharpen_mode = 0;
// Standard CAS 0..1 scale.
uniform float cas_sharpness = 0.15;
// Reference RCAS attenuation in stops: 0.0 is maximum sharpness, 2.0 minimum.
uniform float fsr_sharpness = 0.5;
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
#include "fsr_common.gdshaderinc"
#include "retro_grade_common.gdshaderinc"

void fragment() {
	ivec2 source_size = max(textureSize(source_texture, 0), ivec2(1));
	ivec2 pixel = clamp(
		ivec2(floor(UV * vec2(source_size))), ivec2(0), source_size - ivec2(1));

	vec3 perceptual;
	if (sharpen_mode == 1) {
		perceptual = rt_cas(source_texture, pixel, source_size, cas_sharpness);
	} else if (sharpen_mode == 2) {
		// FsrRcasCon: con = exp2(-sharpness_stops).
		perceptual = rt_fsr_rcas(
			source_texture, pixel, source_size, exp2(-fsr_sharpness));
	} else {
		perceptual = texelFetch(source_texture, pixel, 0).rgb;
	}

	vec3 color = rt_srgb_to_linear(perceptual);
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
