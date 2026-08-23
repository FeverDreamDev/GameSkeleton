shader_type canvas_item;
render_mode unshaded, blend_disabled;

// FSR 1 EASU. This pass exists only while rt_render_scale < 1.0; at Native the
// stack does not create it at all, so there is no 1:1 EASU work and no upscale
// buffer. Input is the SMAA-resolved perceptual image at the internal render
// size, output is the reconstructed perceptual image at the native output size.
//
// FSR 1 requires an anti-aliased input, which is exactly why SMAA runs to
// completion at the internal resolution before this pass.
uniform sampler2D source_texture : filter_nearest, repeat_disable;
uniform vec2 easu_input_size = vec2(1.0);
uniform vec2 easu_output_size = vec2(1.0);

#include "fsr_common.gdshaderinc"

void fragment() {
	ivec2 source_size = max(textureSize(source_texture, 0), ivec2(1));
	vec2 output_size = max(easu_output_size, vec2(1.0));
	vec2 output_pixel = floor(UV * output_size);
	// Reference con0: ip * ratio + (0.5 * ratio - 0.5).
	vec2 pp = (output_pixel + vec2(0.5)) * (easu_input_size / output_size) - vec2(0.5);
	COLOR = vec4(rt_fsr_easu(source_texture, source_size, pp), 1.0);
}
