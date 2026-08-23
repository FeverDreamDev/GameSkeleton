// Shared sRGB transfer functions. Keep this include free of uniforms so any
// pass in the stack can call it. These are the exact piecewise curves; the
// project deliberately never substitutes the gamma-2.2 approximation, because
// the same numbers have to survive a Forward+/Compatibility parity comparison.

vec3 rt_srgb_to_linear(vec3 color) {
	bvec3 cutoff = lessThanEqual(color, vec3(0.04045));
	vec3 low = color / 12.92;
	vec3 high = pow(max((color + 0.055) / 1.055, vec3(0.0)), vec3(2.4));
	return mix(high, low, cutoff);
}

vec3 rt_linear_to_srgb(vec3 color) {
	bvec3 cutoff = lessThanEqual(color, vec3(0.0031308));
	vec3 low = color * 12.92;
	vec3 high = 1.055 * pow(max(color, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
	return mix(high, low, cutoff);
}
