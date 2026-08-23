// AMD FidelityFX kernels, ported from the reference `ffx_fsr1.h` and
// `ffx_cas.h` into Godot's shader language.
//
// Portability rules this file must keep obeying, because Compatibility/Web is a
// first-class target here:
//   - no textureGather (the reference EASU gathers; this port fetches the same
//     12 texels with texelFetch instead, which is core in GLSL ES 3.0);
//   - no compute, no RenderingDevice, no 16-bit packed path, no loops;
//   - every fetch coordinate is clamped, so no pass can sample out of bounds.
//
// All three kernels are specified against perceptual (display-like) color in
// the 0..1 range, not linear radiance. The stack feeds them the sRGB-encoded
// output of the SMAA resolve pass and decodes once afterwards.
//
// The reference uses fast approximate reciprocals (APrxLoRcpF1, APrxMedRcpF1,
// APrxLoRsqF1). Those are bit tricks that quietly return a large finite number
// for 1/0, which the surrounding saturates then absorb. Exact division would
// produce inf and then 0*inf = NaN, so each one below is replaced by an exact
// division with the degenerate case handled explicitly. That is more accurate
// than the reference, never less.

const float RT_FSR_RCAS_LIMIT = 0.25 - 1.0 / 16.0;

// Reference "luma times 2" approximation: G + 0.5*(R + B). Used by both EASU's
// direction analysis and RCAS's ring detection.
float rt_fsr_luma(vec3 c) {
	return c.b * 0.5 + (c.r * 0.5 + c.g);
}

vec3 rt_fsr_fetch(sampler2D source, ivec2 pixel, ivec2 source_size) {
	return texelFetch(source, clamp(pixel, ivec2(0), source_size - ivec2(1)), 0).rgb;
}

// FsrEasuSetF: one of the four corner analyses. `lc` is the set's center luma,
// with `la` above, `lb` left, `ld` right and `le` below.
void rt_fsr_easu_set(
		inout vec2 dir,
		inout float len,
		float w,
		float la, float lb, float lc, float ld, float le) {
	float dc = ld - lc;
	float cb = lc - lb;
	float len_x_scale = max(abs(dc), abs(cb));
	float dir_x = ld - lb;
	// saturate(|dirX| * rcp(max(|dc|,|cb|))). A zero scale means a flat run, and
	// the reference's approximate reciprocal drives this term to zero there.
	float len_x = len_x_scale > 0.0 ? clamp(abs(dir_x) / len_x_scale, 0.0, 1.0) : 0.0;
	dir.x += dir_x * w;
	len += len_x * len_x * w;

	float ec = le - lc;
	float ca = lc - la;
	float len_y_scale = max(abs(ec), abs(ca));
	float dir_y = le - la;
	float len_y = len_y_scale > 0.0 ? clamp(abs(dir_y) / len_y_scale, 0.0, 1.0) : 0.0;
	dir.y += dir_y * w;
	len += len_y * len_y * w;
}

// FsrEasuTapF: one weighted tap of the rotated, anisotropic, windowed Lanczos-2
// approximation.
void rt_fsr_easu_tap(
		inout vec3 accumulated_color,
		inout float accumulated_weight,
		vec2 offset,
		vec2 dir,
		vec2 len2,
		float lob,
		float clp,
		vec3 tap_color) {
	// Rotate the offset into the detected edge frame, then stretch it.
	vec2 v = vec2(
		offset.x * dir.x + offset.y * dir.y,
		offset.x * -dir.y + offset.y * dir.x);
	v *= len2;
	float d2 = min(v.x * v.x + v.y * v.y, clp);
	// (25/16 * (2/5*x^2 - 1)^2 - (25/16 - 1)) * (lob*x^2 - 1)^2
	float wb = 2.0 / 5.0 * d2 - 1.0;
	float wa = lob * d2 - 1.0;
	wb *= wb;
	wa *= wa;
	wb = 25.0 / 16.0 * wb - (25.0 / 16.0 - 1.0);
	float w = wb * wa;
	accumulated_color += tap_color * w;
	accumulated_weight += w;
}

// FsrEasuF. `pp` is the source-texel-space position of the output pixel:
// (output_pixel + 0.5) * (input_size / output_size) - 0.5, which is exactly the
// reference con0 mapping ip*ratio + (0.5*ratio - 0.5).
vec3 rt_fsr_easu(sampler2D source, ivec2 source_size, vec2 pp) {
	vec2 fp = floor(pp);
	pp -= fp;
	ivec2 base = ivec2(fp);

	// 12-tap kernel.
	//    b c
	//  e f g h
	//  i j k l
	//    n o
	vec3 cb = rt_fsr_fetch(source, base + ivec2(0, -1), source_size);
	vec3 cc = rt_fsr_fetch(source, base + ivec2(1, -1), source_size);
	vec3 ce = rt_fsr_fetch(source, base + ivec2(-1, 0), source_size);
	vec3 cf = rt_fsr_fetch(source, base + ivec2(0, 0), source_size);
	vec3 cg = rt_fsr_fetch(source, base + ivec2(1, 0), source_size);
	vec3 ch = rt_fsr_fetch(source, base + ivec2(2, 0), source_size);
	vec3 ci = rt_fsr_fetch(source, base + ivec2(-1, 1), source_size);
	vec3 cj = rt_fsr_fetch(source, base + ivec2(0, 1), source_size);
	vec3 ck = rt_fsr_fetch(source, base + ivec2(1, 1), source_size);
	vec3 cl = rt_fsr_fetch(source, base + ivec2(2, 1), source_size);
	vec3 cn = rt_fsr_fetch(source, base + ivec2(0, 2), source_size);
	vec3 co = rt_fsr_fetch(source, base + ivec2(1, 2), source_size);

	float lb = rt_fsr_luma(cb);
	float lc = rt_fsr_luma(cc);
	float le = rt_fsr_luma(ce);
	float lf = rt_fsr_luma(cf);
	float lg = rt_fsr_luma(cg);
	float lh = rt_fsr_luma(ch);
	float li = rt_fsr_luma(ci);
	float lj = rt_fsr_luma(cj);
	float lk = rt_fsr_luma(ck);
	float ll = rt_fsr_luma(cl);
	float ln = rt_fsr_luma(cn);
	float lo = rt_fsr_luma(co);

	// Accumulate the four corner analyses with bilinear weights.
	vec2 dir = vec2(0.0);
	float len = 0.0;
	rt_fsr_easu_set(dir, len, (1.0 - pp.x) * (1.0 - pp.y), lb, le, lf, lg, lj);
	rt_fsr_easu_set(dir, len, pp.x * (1.0 - pp.y), lc, lf, lg, lh, lk);
	rt_fsr_easu_set(dir, len, (1.0 - pp.x) * pp.y, lf, li, lj, lk, ln);
	rt_fsr_easu_set(dir, len, pp.x * pp.y, lg, lj, lk, ll, lo);

	// Normalize the direction, cleaning up the near-zero case.
	vec2 dir2 = dir * dir;
	float dir_r = dir2.x + dir2.y;
	bool zero_direction = dir_r < 1.0 / 32768.0;
	dir_r = zero_direction ? 1.0 : inversesqrt(dir_r);
	dir.x = zero_direction ? 1.0 : dir.x;
	dir.y = zero_direction ? 0.0 : dir.y;
	dir *= dir_r;

	// {0..2} to {0..1}, shaped with a square.
	len = len * 0.5;
	len *= len;

	// Stretch the kernel from 1.0 on axis to sqrt(2.0) on the diagonal.
	float dir_max = max(abs(dir.x), abs(dir.y));
	float stretch = dir_max > 0.0
		? (dir.x * dir.x + dir.y * dir.y) / dir_max
		: 1.0;
	// x := 1.0 lerped to `stretch` on edges, y := 1.0 lerped to 2x contracted.
	vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
	// The window shifts from +/-sqrt(2.0) to slightly beyond 2.0 with edge amount.
	float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
	float clp = 1.0 / lob;

	// Deringing bounds come from the nearest four texels only.
	vec3 min4 = min(min(cf, cg), min(cj, ck));
	vec3 max4 = max(max(cf, cg), max(cj, ck));

	vec3 accumulated_color = vec3(0.0);
	float accumulated_weight = 0.0;
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(0.0, -1.0) - pp, dir, len2, lob, clp, cb);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(1.0, -1.0) - pp, dir, len2, lob, clp, cc);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(-1.0, 1.0) - pp, dir, len2, lob, clp, ci);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(0.0, 1.0) - pp, dir, len2, lob, clp, cj);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(0.0, 0.0) - pp, dir, len2, lob, clp, cf);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(-1.0, 0.0) - pp, dir, len2, lob, clp, ce);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(1.0, 1.0) - pp, dir, len2, lob, clp, ck);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(2.0, 1.0) - pp, dir, len2, lob, clp, cl);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(2.0, 0.0) - pp, dir, len2, lob, clp, ch);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(1.0, 0.0) - pp, dir, len2, lob, clp, cg);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(1.0, 2.0) - pp, dir, len2, lob, clp, co);
	rt_fsr_easu_tap(accumulated_color, accumulated_weight, vec2(0.0, 2.0) - pp, dir, len2, lob, clp, cn);

	// Normalize and dering. The clamp is what keeps the negative lobe from
	// ringing past the local neighborhood.
	vec3 resolved = accumulated_weight > 0.0
		? accumulated_color / accumulated_weight
		: cf;
	return min(max4, max(min4, resolved));
}

// FsrRcasF. `con` is the reference FsrRcasCon constant, exp2(-sharpness_stops).
// FSR_RCAS_DENOISE is deliberately not compiled in: the RT image is not noisy
// and the denoiser would only soften highlights.
vec3 rt_fsr_rcas(sampler2D source, ivec2 pixel, ivec2 source_size, float con) {
	//   b
	// d e f
	//   h
	vec3 cb = rt_fsr_fetch(source, pixel + ivec2(0, -1), source_size);
	vec3 cd = rt_fsr_fetch(source, pixel + ivec2(-1, 0), source_size);
	vec3 ce = rt_fsr_fetch(source, pixel, source_size);
	vec3 cf = rt_fsr_fetch(source, pixel + ivec2(1, 0), source_size);
	vec3 ch = rt_fsr_fetch(source, pixel + ivec2(0, 1), source_size);

	// Min and max of the ring.
	vec3 mn4 = min(min(cb, cd), min(cf, ch));
	vec3 mx4 = max(max(cb, cd), max(cf, ch));

	// Limiters. peakC = (1.0, -4.0) in the reference.
	//
	// The numerators clamp against the center sample as well as the ring, per
	// the reference FsrRcasF. This only bites when e falls outside
	// [mn4, mx4] -- a lone bright or dark pixel -- and there it is what stops
	// the limiter from authorizing a lobe that overshoots. Solving the filter
	// (w*(b+d+f+h) + e) / (4w + 1) >= 0 for the worst-case ring gives
	// w >= -e/(4*mx4), so the numerator has to see e; taking min(mn4, e) is the
	// conservative combination of that bound and the ring bound. Without it a
	// black pixel on a uniform 0.5 ring resolves to about -0.56 instead of
	// being left alone. Where e sits inside the ring range both terms collapse
	// back to the ring and nothing changes.
	//
	// The denominators stay on the ring extremes, matching the reference.
	vec3 mn4_limit = min(mn4, ce);
	vec3 mx4_limit = max(mx4, ce);
	vec3 four_mx4 = 4.0 * mx4;
	vec3 hit_min = vec3(
		four_mx4.r > 0.0 ? mn4_limit.r / four_mx4.r : 0.0,
		four_mx4.g > 0.0 ? mn4_limit.g / four_mx4.g : 0.0,
		four_mx4.b > 0.0 ? mn4_limit.b / four_mx4.b : 0.0);
	// 4*mn4 - 4 is <= 0 and only reaches 0 for a fully saturated ring, where the
	// numerator 1 - mx4_limit is also 0 because e cannot exceed 1.
	vec3 max_denominator = 4.0 * mn4 - 4.0;
	vec3 hit_max = vec3(
		max_denominator.r < 0.0 ? (1.0 - mx4_limit.r) / max_denominator.r : 0.0,
		max_denominator.g < 0.0 ? (1.0 - mx4_limit.g) / max_denominator.g : 0.0,
		max_denominator.b < 0.0 ? (1.0 - mx4_limit.b) / max_denominator.b : 0.0);
	vec3 lobe_rgb = max(-hit_min, hit_max);
	float lobe = max(
		-RT_FSR_RCAS_LIMIT,
		min(max(lobe_rgb.r, max(lobe_rgb.g, lobe_rgb.b)), 0.0)) * con;

	// 4*lobe + 1 stays in [0.25, 1]; it can never reach zero.
	float rcp_weight = 1.0 / (4.0 * lobe + 1.0);
	return (lobe * cb + lobe * cd + lobe * cf + lobe * ch + ce) * rcp_weight;
}

// CasFilter with CAS_BETTER_DIAGONALS, sharpen-only (no scaling). `sharpness`
// is on the standard CAS 0..1 scale; the reference CasSetup turns it into
// peak = -1/lerp(8, 5, sharpness).
vec3 rt_cas(sampler2D source, ivec2 pixel, ivec2 source_size, float sharpness) {
	// a b c
	// d e f
	// g h i
	vec3 ca = rt_fsr_fetch(source, pixel + ivec2(-1, -1), source_size);
	vec3 cb = rt_fsr_fetch(source, pixel + ivec2(0, -1), source_size);
	vec3 cc = rt_fsr_fetch(source, pixel + ivec2(1, -1), source_size);
	vec3 cd = rt_fsr_fetch(source, pixel + ivec2(-1, 0), source_size);
	vec3 ce = rt_fsr_fetch(source, pixel, source_size);
	vec3 cf = rt_fsr_fetch(source, pixel + ivec2(1, 0), source_size);
	vec3 cg = rt_fsr_fetch(source, pixel + ivec2(-1, 1), source_size);
	vec3 chh = rt_fsr_fetch(source, pixel + ivec2(0, 1), source_size);
	vec3 ci = rt_fsr_fetch(source, pixel + ivec2(1, 1), source_size);

	// Soft min/max: the cross, plus the diagonals at half weight. The reference
	// factors the 0.5 out by summing the two passes, so these run 2x large and
	// the amplitude test compares against 2.0 rather than 1.0.
	vec3 mn = min(min(min(cd, ce), cf), min(cb, chh));
	vec3 mn2 = min(min(min(mn, ca), cc), min(cg, ci));
	mn += mn2;
	vec3 mx = max(max(max(cd, ce), cf), max(cb, chh));
	vec3 mx2 = max(max(max(mx, ca), cc), max(cg, ci));
	mx += mx2;

	vec3 amp = vec3(
		mx.r > 0.0 ? clamp(min(mn.r, 2.0 - mx.r) / mx.r, 0.0, 1.0) : 0.0,
		mx.g > 0.0 ? clamp(min(mn.g, 2.0 - mx.g) / mx.g, 0.0, 1.0) : 0.0,
		mx.b > 0.0 ? clamp(min(mn.b, 2.0 - mx.b) / mx.b, 0.0, 1.0) : 0.0);
	amp = sqrt(amp);

	// Filter shape:
	//  0 w 0
	//  w 1 w
	//  0 w 0
	float peak = -1.0 / mix(8.0, 5.0, clamp(sharpness, 0.0, 1.0));
	vec3 w = amp * peak;
	vec3 rcp_weight = vec3(1.0) / (vec3(1.0) + 4.0 * w);
	return clamp((cb * w + cd * w + cf * w + chh * w + ce) * rcp_weight, vec3(0.0), vec3(1.0));
}
