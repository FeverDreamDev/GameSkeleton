shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Classic Panini projection, fixed to D=1 and squeeze S=0. The source is the
// opaque perceptual image produced by the scene resolve pass. RetroGrade
// intentionally remains downstream.
uniform sampler2D source_texture : filter_linear, repeat_disable;
uniform vec2 source_size = vec2(1.0);
// Horizontal Panini-plane extent reached by the requested display FOV.
uniform float panini_extent_x = 1.0;
// Vertical center extent preserves the ordinary aspect-derived perspective
// angle; the capture overscan below absorbs Panini's additional corner reach.
uniform float panini_extent_y = 1.0;
// Rectilinear tangent extents rendered by the private capture camera.
uniform vec2 capture_tan_half_fov = vec2(1.0);

// Catmull-Rom reconstruction is faded out between this footprint and 1:1 so the
// magnified branch lands on exactly the bilinear tap the minified branch starts
// from. Without the fade the two branches meet at a visible ring.
const float CATMULL_ROM_FADE_START = 0.9;


vec2 panini_source_uv(vec2 output_uv) {
	vec2 output_ndc = output_uv * 2.0 - 1.0;
	float panini_x = output_ndc.x * panini_extent_x;
	// The projection plane uses positive Y up while canvas UV uses positive Y down.
	float panini_y = -output_ndc.y * panini_extent_y;

	// With D=1, x_p = 2*tan(phi/2), which has this stable closed-form inverse.
	float phi = 2.0 * atan(0.5 * panini_x);
	float cos_phi = max(cos(phi), 0.00001);
	float panini_scale = 2.0 / (1.0 + cos_phi);
	float tan_theta = panini_y / panini_scale;

	// Convert longitude/latitude back to the rectilinear capture plane.
	vec2 rectilinear = vec2(tan(phi), tan_theta / cos_phi);
	vec2 safe_tangent = max(capture_tan_half_fov, vec2(0.00001));
	return vec2(
		0.5 + 0.5 * rectilinear.x / safe_tangent.x,
		0.5 - 0.5 * rectilinear.y / safe_tangent.y);
}


vec2 clamp_source_uv(vec2 uv) {
	vec2 half_texel = 0.5 / max(source_size, vec2(1.0));
	return clamp(uv, half_texel, vec2(1.0) - half_texel);
}


// Nine-tap Catmull-Rom reduced to its five significant bilinear taps. The four
// dropped corner taps carry a small share of the unit weight sum, so the kept
// weights are renormalized. Only texture(), floor(), and arithmetic are used,
// which keeps this inside the same plain canvas-fragment contract -- no compute,
// no RenderingDevice -- as the rest of the post stack.
vec3 catmull_rom_sample(vec2 uv, vec2 texel_grid) {
	vec2 sample_position = uv * texel_grid;
	vec2 center_texel = floor(sample_position - 0.5) + 0.5;
	vec2 f = sample_position - center_texel;

	vec2 weight0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 weight1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 weight2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 weight3 = f * f * (-0.5 + 0.5 * f);
	// weight1 + weight2 stays within [1.0, 1.125] for f in [0,1]; the guard only
	// protects the division from denormal input.
	vec2 weight12 = max(weight1 + weight2, vec2(0.00001));

	vec2 uv0 = (center_texel - 1.0) / texel_grid;
	vec2 uv3 = (center_texel + 2.0) / texel_grid;
	vec2 uv12 = (center_texel + weight2 / weight12) / texel_grid;

	vec3 color = texture(
		source_texture, clamp_source_uv(vec2(uv12.x, uv0.y))).rgb
		* (weight12.x * weight0.y);
	color += texture(
		source_texture, clamp_source_uv(vec2(uv0.x, uv12.y))).rgb
		* (weight0.x * weight12.y);
	color += texture(
		source_texture, clamp_source_uv(uv12)).rgb
		* (weight12.x * weight12.y);
	color += texture(
		source_texture, clamp_source_uv(vec2(uv3.x, uv12.y))).rgb
		* (weight3.x * weight12.y);
	color += texture(
		source_texture, clamp_source_uv(vec2(uv12.x, uv3.y))).rgb
		* (weight12.x * weight3.y);

	float total = weight12.x * (weight0.y + weight12.y + weight3.y)
		+ weight12.y * (weight0.x + weight3.x);
	return color / max(total, 0.00001);
}


void fragment() {
	vec2 source_uv = panini_source_uv(UV);

	// The derivative decision and fixed upper bound keep the cost bounded and
	// the branch uniform enough to be cheap. Only minified regions take the
	// four-tap branch.
	vec2 derivative_x = dFdx(source_uv);
	vec2 derivative_y = dFdy(source_uv);
	vec2 source_pixels = max(source_size, vec2(1.0));
	float footprint = max(
		length(derivative_x * source_pixels),
		length(derivative_y * source_pixels));
	vec3 color;
	if (footprint <= 1.0) {
		// The capture camera is always wider than the display FOV, so the image
		// center magnifies by more than 2x at every supported FOV. One bilinear
		// tap is what makes that center read as soft; Catmull-Rom reconstructs
		// the same texels with edge slope preserved and no extra source data.
		vec3 bilinear = texture(source_texture, clamp_source_uv(source_uv)).rgb;
		float sharpness = 1.0 - smoothstep(
			CATMULL_ROM_FADE_START, 1.0, footprint);
		color = mix(
			bilinear, catmull_rom_sample(source_uv, source_pixels), sharpness);
		// Catmull-Rom's negative lobes overshoot around high-contrast edges. The
		// source is the upstream-clamped perceptual image, so the valid range is
		// exactly [0,1] and the overshoot is a halo rather than signal.
		color = clamp(color, vec3(0.0), vec3(1.0));
	} else {
		float filter_amount = min(footprint - 1.0, 1.0);
		vec2 maximum_step = 2.0 / source_pixels;
		vec2 tap_x = clamp(
			derivative_x * (0.5 * filter_amount), -maximum_step, maximum_step);
		vec2 tap_y = clamp(
			derivative_y * (0.5 * filter_amount), -maximum_step, maximum_step);

		color = texture(
			source_texture, clamp_source_uv(source_uv + tap_x + tap_y)).rgb * 0.25;
		color += texture(
			source_texture, clamp_source_uv(source_uv + tap_x - tap_y)).rgb * 0.25;
		color += texture(
			source_texture, clamp_source_uv(source_uv - tap_x + tap_y)).rgb * 0.25;
		color += texture(
			source_texture, clamp_source_uv(source_uv - tap_x - tap_y)).rgb * 0.25;
	}
	COLOR = vec4(color, 1.0);
}
