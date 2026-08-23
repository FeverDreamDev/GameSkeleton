shader_type canvas_item;
render_mode unshaded, blend_disabled;

// SMAA 1x blending-weight calculation (second pass), ported from the official
// reference implementation. The packed LUTs must use linear clamp sampling.
uniform sampler2D edges_texture : filter_linear, repeat_disable;
uniform sampler2D area_texture : filter_linear, repeat_disable;
uniform sampler2D search_texture : filter_linear, repeat_disable;
uniform vec2 viewport_size = vec2(1.0);
uniform int max_search_steps : hint_range(0, 16) = 16;
uniform int max_diagonal_steps : hint_range(0, 8) = 8;
uniform bool diagonal_detection_enabled = true;
uniform bool corner_detection_enabled = true;
uniform float corner_rounding : hint_range(0.0, 1.0) = 0.25;

const vec2 AREA_TEX_PIXEL_SIZE = vec2(1.0 / 160.0, 1.0 / 560.0);
const float AREA_TEX_SUBTEX_SIZE = 1.0 / 7.0;
const vec2 SEARCH_TEX_SIZE = vec2(66.0, 33.0);
const vec2 SEARCH_TEX_PACKED_SIZE = vec2(64.0, 16.0);

vec2 pixel_size() {
	return vec2(1.0) / max(viewport_size, vec2(1.0));
}

vec2 sample_edges(vec2 uv) {
	return texture(edges_texture, uv).rg;
}

vec2 sample_edges_offset(vec2 uv, vec2 offset_pixels) {
	return texture(edges_texture, uv + offset_pixels * pixel_size()).rg;
}

float search_length(vec2 edge, float offset_value) {
	vec2 scale = SEARCH_TEX_SIZE * vec2(0.5, -1.0);
	vec2 bias = SEARCH_TEX_SIZE * vec2(offset_value, 1.0);
	scale += vec2(-1.0, 1.0);
	bias += vec2(0.5, -0.5);
	scale /= SEARCH_TEX_PACKED_SIZE;
	bias /= SEARCH_TEX_PACKED_SIZE;
	return texture(search_texture, scale * edge + bias).r;
}

float search_x_left(vec2 uv, float end_x) {
	vec2 edge = vec2(0.0, 1.0);
	for (int i = 0; i < 16; i++) {
		if (i >= max_search_steps || uv.x <= end_x || edge.g <= 0.8281 || edge.r >= 0.0001) {
			break;
		}
		edge = sample_edges(uv);
		uv -= vec2(2.0 * pixel_size().x, 0.0);
	}
	float offset_value = -(255.0 / 127.0) * search_length(edge, 0.0) + 3.25;
	return uv.x + pixel_size().x * offset_value;
}

float search_x_right(vec2 uv, float end_x) {
	vec2 edge = vec2(0.0, 1.0);
	for (int i = 0; i < 16; i++) {
		if (i >= max_search_steps || uv.x >= end_x || edge.g <= 0.8281 || edge.r >= 0.0001) {
			break;
		}
		edge = sample_edges(uv);
		uv += vec2(2.0 * pixel_size().x, 0.0);
	}
	float offset_value = -(255.0 / 127.0) * search_length(edge, 0.5) + 3.25;
	return uv.x - pixel_size().x * offset_value;
}

float search_y_up(vec2 uv, float end_y) {
	vec2 edge = vec2(1.0, 0.0);
	for (int i = 0; i < 16; i++) {
		if (i >= max_search_steps || uv.y <= end_y || edge.r <= 0.8281 || edge.g >= 0.0001) {
			break;
		}
		edge = sample_edges(uv);
		uv -= vec2(0.0, 2.0 * pixel_size().y);
	}
	float offset_value = -(255.0 / 127.0) * search_length(edge.gr, 0.0) + 3.25;
	return uv.y + pixel_size().y * offset_value;
}

float search_y_down(vec2 uv, float end_y) {
	vec2 edge = vec2(1.0, 0.0);
	for (int i = 0; i < 16; i++) {
		if (i >= max_search_steps || uv.y >= end_y || edge.r <= 0.8281 || edge.g >= 0.0001) {
			break;
		}
		edge = sample_edges(uv);
		uv += vec2(0.0, 2.0 * pixel_size().y);
	}
	float offset_value = -(255.0 / 127.0) * search_length(edge.gr, 0.5) + 3.25;
	return uv.y - pixel_size().y * offset_value;
}

vec2 area(vec2 distance_pixels, float edge_a, float edge_b, float subsample_index) {
	vec2 texcoord = 16.0 * round(4.0 * vec2(edge_a, edge_b)) + distance_pixels;
	texcoord = texcoord * AREA_TEX_PIXEL_SIZE + 0.5 * AREA_TEX_PIXEL_SIZE;
	texcoord.y += AREA_TEX_SUBTEX_SIZE * subsample_index;
	return texture(area_texture, texcoord).rg;
}

vec2 area_diagonal(vec2 distance_pixels, vec2 crossing_edges, float subsample_index) {
	vec2 texcoord = 20.0 * crossing_edges + distance_pixels;
	texcoord = texcoord * AREA_TEX_PIXEL_SIZE + 0.5 * AREA_TEX_PIXEL_SIZE;
	texcoord.x += 0.5;
	texcoord.y += AREA_TEX_SUBTEX_SIZE * subsample_index;
	return texture(area_texture, texcoord).rg;
}

vec2 decode_diagonal2(vec2 edge) {
	return round(vec2(edge.r * abs(5.0 * edge.r - 3.75), edge.g));
}

vec4 decode_diagonal4(vec4 edge) {
	return round(vec4(
		edge.r * abs(5.0 * edge.r - 3.75),
		edge.g,
		edge.b * abs(5.0 * edge.b - 3.75),
		edge.a
	));
}

// Returns (distance, continuation, final_edge.r, final_edge.g), matching the
// reference shader's return value plus its out parameter.
vec4 search_diagonal1(vec2 uv, vec2 direction) {
	vec4 coord = vec4(uv, -1.0, 1.0);
	vec2 end_edge = vec2(0.0);
	for (int i = 0; i < 8; i++) {
		if (i >= max_diagonal_steps || coord.z >= float(max_diagonal_steps - 1) || coord.w <= 0.9) {
			break;
		}
		coord.xy += pixel_size() * direction;
		coord.z += 1.0;
		end_edge = sample_edges(coord.xy);
		coord.w = dot(end_edge, vec2(0.5));
	}
	return vec4(coord.zw, end_edge);
}

vec4 search_diagonal2(vec2 uv, vec2 direction) {
	vec4 coord = vec4(uv, -1.0, 1.0);
	coord.x += 0.25 * pixel_size().x;
	vec2 end_edge = vec2(0.0);
	for (int i = 0; i < 8; i++) {
		if (i >= max_diagonal_steps || coord.z >= float(max_diagonal_steps - 1) || coord.w <= 0.9) {
			break;
		}
		coord.xy += pixel_size() * direction;
		coord.z += 1.0;
		end_edge = decode_diagonal2(sample_edges(coord.xy));
		coord.w = dot(end_edge, vec2(0.5));
	}
	return vec4(coord.zw, end_edge);
}

vec2 calculate_diagonal_weights(vec2 uv, vec2 edge) {
	vec2 weights = vec2(0.0);
	vec4 diagonal = vec4(0.0);
	vec4 search_result;

	// First diagonal orientation. The west-edge test and end correction are
	// significant: they are what distinguish a real diagonal from a crossing.
	if (edge.r > 0.0) {
		search_result = search_diagonal1(uv, vec2(-1.0, 1.0));
		diagonal.xz = search_result.xy;
		diagonal.x += float(search_result.w > 0.9);
	} else {
		diagonal.xz = vec2(0.0);
	}
	search_result = search_diagonal1(uv, vec2(1.0, -1.0));
	diagonal.yw = search_result.xy;

	if (diagonal.x + diagonal.y > 2.0) {
		vec4 coords = vec4(
			uv + pixel_size() * vec2(-diagonal.x + 0.25, diagonal.x),
			uv + pixel_size() * vec2(diagonal.y, -diagonal.y - 0.25)
		);
		vec4 crossing = vec4(
			sample_edges_offset(coords.xy, vec2(-1.0, 0.0)),
			sample_edges_offset(coords.zw, vec2(1.0, 0.0))
		);
		vec4 decoded = decode_diagonal4(crossing);
		crossing = vec4(decoded.g, decoded.r, decoded.a, decoded.b);
		vec2 crossing_pairs = 2.0 * crossing.xz + crossing.yw;
		if (diagonal.z >= 0.9) {
			crossing_pairs.x = 0.0;
		}
		if (diagonal.w >= 0.9) {
			crossing_pairs.y = 0.0;
		}
		weights += area_diagonal(diagonal.xy, crossing_pairs, 0.0);
	}

	// Second diagonal orientation. This follows SMAACalculateDiagWeights's
	// optimized bilinear crossing-edge path exactly for SMAA 1x.
	search_result = search_diagonal2(uv, vec2(-1.0, -1.0));
	diagonal.xz = search_result.xy;
	if (sample_edges_offset(uv, vec2(1.0, 0.0)).r > 0.0) {
		search_result = search_diagonal2(uv, vec2(1.0, 1.0));
		diagonal.yw = search_result.xy;
		diagonal.y += float(search_result.w > 0.9);
	} else {
		diagonal.yw = vec2(0.0);
	}
	if (diagonal.x + diagonal.y > 2.0) {
		vec4 coords = vec4(
			uv + pixel_size() * vec2(-diagonal.x, -diagonal.x),
			uv + pixel_size() * vec2(diagonal.y, diagonal.y)
		);
		vec2 left_crossing = sample_edges_offset(coords.xy, vec2(-1.0, 0.0));
		vec2 left_below = sample_edges_offset(coords.xy, vec2(0.0, -1.0));
		vec2 right_crossing = sample_edges_offset(coords.zw, vec2(1.0, 0.0));
		vec4 crossing = vec4(
			left_crossing.g,
			left_below.r,
			right_crossing.g,
			right_crossing.r
		);
		vec2 crossing_pairs = 2.0 * crossing.xz + crossing.yw;
		if (diagonal.z >= 0.9) {
			crossing_pairs.x = 0.0;
		}
		if (diagonal.w >= 0.9) {
			crossing_pairs.y = 0.0;
		}
		vec2 diagonal_area = area_diagonal(diagonal.xy, crossing_pairs, 0.0);
		weights += vec2(diagonal_area.g, diagonal_area.r);
	}
	return weights;
}

vec2 apply_horizontal_corner_detection(vec2 weights, vec4 coords, vec2 distance_pixels) {
	vec2 left_right = step(distance_pixels.xy, distance_pixels.yx);
	vec2 rounding = (1.0 - corner_rounding) * left_right;
	rounding /= left_right.x + left_right.y;

	vec2 factor = vec2(1.0);
	factor.x -= rounding.x * sample_edges_offset(coords.xy, vec2(0.0, 1.0)).r;
	factor.x -= rounding.y * sample_edges_offset(coords.zw, vec2(1.0, 1.0)).r;
	factor.y -= rounding.x * sample_edges_offset(coords.xy, vec2(0.0, -2.0)).r;
	factor.y -= rounding.y * sample_edges_offset(coords.zw, vec2(1.0, -2.0)).r;
	return weights * clamp(factor, vec2(0.0), vec2(1.0));
}

vec2 apply_vertical_corner_detection(vec2 weights, vec4 coords, vec2 distance_pixels) {
	vec2 top_bottom = step(distance_pixels.xy, distance_pixels.yx);
	vec2 rounding = (1.0 - corner_rounding) * top_bottom;
	rounding /= top_bottom.x + top_bottom.y;

	vec2 factor = vec2(1.0);
	factor.x -= rounding.x * sample_edges_offset(coords.xy, vec2(1.0, 0.0)).g;
	factor.x -= rounding.y * sample_edges_offset(coords.zw, vec2(1.0, 1.0)).g;
	factor.y -= rounding.x * sample_edges_offset(coords.xy, vec2(-2.0, 0.0)).g;
	factor.y -= rounding.y * sample_edges_offset(coords.zw, vec2(-2.0, 1.0)).g;
	return weights * clamp(factor, vec2(0.0), vec2(1.0));
}

void fragment() {
	vec2 texel = pixel_size();
	vec2 pixcoord = UV * viewport_size;
	vec4 weights = vec4(0.0);
	vec2 edge = sample_edges(UV);

	if (edge.g > 0.0) {
		if (diagonal_detection_enabled) {
			weights.rg = calculate_diagonal_weights(UV, edge);
		}
		if (!diagonal_detection_enabled || weights.r == -weights.g) {
			vec4 coords;
			coords.x = search_x_left(UV + texel * vec2(-0.25, -0.125), UV.x - 2.0 * texel.x * float(max_search_steps));
			coords.y = UV.y - 0.25 * texel.y;
			float edge_left = sample_edges(coords.xy).r;
			coords.z = search_x_right(UV + texel * vec2(1.25, -0.125), UV.x + 2.0 * texel.x * float(max_search_steps));
			coords.w = coords.y;
			vec2 distance_pixels = abs(round(viewport_size.xx * coords.xz - pixcoord.xx));
			float edge_right = sample_edges_offset(coords.zw, vec2(1.0, 0.0)).r;
			// SMAA 1x uses the first area-texture subtexture. Distances are
			// component-wise square-root encoded before the LUT lookup.
			vec2 horizontal = area(sqrt(distance_pixels), edge_left, edge_right, 0.0);
			if (corner_detection_enabled) {
				coords.y = UV.y;
				coords.w = UV.y;
				horizontal = apply_horizontal_corner_detection(horizontal, coords, distance_pixels);
			}
			weights.rg = horizontal;
		}
		// Diagonal processing has priority over vertical processing.
		if (diagonal_detection_enabled && weights.r != -weights.g) {
			edge.r = 0.0;
		}
	}

	if (edge.r > 0.0) {
		vec4 coords;
		coords.y = search_y_up(UV + texel * vec2(-0.125, -0.25), UV.y - 2.0 * texel.y * float(max_search_steps));
		coords.x = UV.x - 0.25 * texel.x;
		float edge_top = sample_edges(coords.xy).g;
		coords.w = search_y_down(UV + texel * vec2(-0.125, 1.25), UV.y + 2.0 * texel.y * float(max_search_steps));
		coords.z = coords.x;
		vec2 distance_pixels = abs(round(viewport_size.yy * coords.yw - pixcoord.yy));
		float edge_bottom = sample_edges_offset(coords.zw, vec2(0.0, 1.0)).g;
		vec2 vertical = area(sqrt(distance_pixels), edge_top, edge_bottom, 0.0);
		if (corner_detection_enabled) {
			coords.x = UV.x;
			coords.z = UV.x;
			vertical = apply_vertical_corner_detection(vertical, coords, distance_pixels);
		}
		weights.ba = vertical;
	}

	COLOR = weights;
}
