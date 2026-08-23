// Shared final-grade math. Keep this include free of renderer-specific uniforms
// so the same function can be called by any presentation path.

vec3 rt_apply_retro_grade(
		vec3 color,
		float grade_brightness,
		float grade_contrast,
		float grade_saturation,
		float grade_black_point,
		vec3 grade_color_balance,
		bool grade_posterize_enabled,
		float grade_posterize_levels,
		float grade_posterize_strength) {
	color *= grade_brightness;
	color *= grade_color_balance;
	float black_range = max(1.0 - grade_black_point, 0.0001);
	color = max(color - vec3(grade_black_point), vec3(0.0)) / black_range;
	color = (color - vec3(0.5)) * grade_contrast + vec3(0.5);
	float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
	color = mix(vec3(luminance), color, grade_saturation);
	if (grade_posterize_enabled) {
		float steps = max(grade_posterize_levels - 1.0, 1.0);
		vec3 bounded = clamp(color, vec3(0.0), vec3(1.0));
		vec3 quantized = floor(bounded * steps + vec3(0.5)) / steps;
		color = mix(color, quantized, grade_posterize_strength);
	}
	return color;
}
