shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Classic Panini projection, fixed to D=1 and squeeze S=0. The source is the
// opaque perceptual image produced by SMAA resolve at Native or by FSR EASU at
// a reduced preset. CAS/RCAS and RetroGrade intentionally remain downstream.
uniform sampler2D source_texture : filter_linear, repeat_disable;
uniform vec2 source_size = vec2(1.0);
// Horizontal Panini-plane extent reached by the requested display FOV.
uniform float panini_extent_x = 1.0;
// Vertical center extent preserves the ordinary aspect-derived perspective
// angle; the capture overscan below absorbs Panini's additional corner reach.
uniform float panini_extent_y = 1.0;
// Rectilinear tangent extents rendered by the private capture camera.
uniform vec2 capture_tan_half_fov = vec2(1.0);


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


void fragment() {
	vec2 source_uv = panini_source_uv(UV);

	// The derivative decision and fixed upper bound are portable to GLES3. The
	// common magnified/1:1 path performs exactly one bilinear lookup; only
	// minified regions take the bounded four-tap branch.
	vec2 derivative_x = dFdx(source_uv);
	vec2 derivative_y = dFdy(source_uv);
	vec2 source_pixels = max(source_size, vec2(1.0));
	float footprint = max(
		length(derivative_x * source_pixels),
		length(derivative_y * source_pixels));
	vec3 color;
	if (footprint <= 1.0) {
		color = texture(source_texture, clamp_source_uv(source_uv)).rgb;
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
