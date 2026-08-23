// Deterministic fragment-shader ray traversal shared by the software material.
// All integer addresses are stored exactly in RGBA32F atlas texels.

const int SWRT_ATLAS_WIDTH = 1024;
const int SWRT_MAX_TLAS_STEPS = 4096;
const int SWRT_MAX_BLAS_STEPS = 32768;
const int SWRT_MAX_RECEIVER_LIGHTS = 32;
const float SWRT_GEOMETRY_MAGIC = 47010.0;
const float SWRT_INSTANCE_MAGIC = 47011.0;
const float SWRT_SHADING_MAGIC = 47012.0;
const float SWRT_VERSION = 3.0;
const float SWRT_DIRECTION_EPSILON = 0.0000001;
const float SWRT_TRIANGLE_EPSILON = 0.0000001;
const float SWRT_TANGENT_EPSILON = 0.00000001;
const vec3 SWRT_LUMINANCE = vec3(0.2126, 0.7152, 0.0722);


struct SWRTInstance {
	vec4 metadata;
	vec4 light_list;
	mat3 world_to_object;
	vec3 object_origin;
	mat3 normal_to_world;
};


struct SWRTMaterial {
	vec4 diffuse_shininess;
	vec4 ambient_intensity;
	vec4 emission_flags;
	vec4 specular_flags;
	vec4 albedo_region;
	vec4 normal_region;
	vec4 triplanar_scale_sharpness;
	vec4 triplanar_offset;
};


struct SWRTHit {
	float distance;
	int object_id;
	int triangle_id;
	vec2 barycentric;
};


struct SWRTFrameContext {
	ivec4 geometry_layout;
	ivec4 geometry_counts;
	ivec4 instance_layout;
	int instance_count;
	ivec4 shading_layout;
	ivec4 shading_counts;
	vec4 settings;
	vec4 miss_color;
};


struct SWRTRay {
	vec3 origin;
	vec3 direction;
	vec3 inverse_direction;
	bvec3 parallel_axes;
	float minimum_distance;
	float maximum_distance;
};


SWRTFrameContext swrt_make_frame_context() {
	SWRTFrameContext context;
	context.geometry_layout = swrt_geometry_layout;
	context.geometry_counts = swrt_geometry_counts;
	context.instance_layout = swrt_instance_layout;
	context.instance_count = swrt_instance_count;
	context.shading_layout = swrt_shading_layout;
	context.shading_counts = swrt_shading_counts;
	context.settings = swrt_frame_settings;
	context.miss_color = swrt_miss_color;
	return context;
}


ivec2 swrt_atlas_coordinate(int linear_index) {
	return ivec2(linear_index & (SWRT_ATLAS_WIDTH - 1), linear_index >> 10);
}


vec4 swrt_geometry_fetch(int linear_index) {
	return texelFetch(swrt_geometry_atlas, swrt_atlas_coordinate(linear_index), 0);
}


vec4 swrt_instance_fetch(int linear_index) {
	return texelFetch(swrt_instance_atlas, swrt_atlas_coordinate(linear_index), 0);
}


vec4 swrt_shading_fetch(int linear_index) {
	return texelFetch(swrt_shading_atlas, swrt_atlas_coordinate(linear_index), 0);
}


int swrt_positive_modulo(int value, int divisor) {
	int result = value % divisor;
	return result < 0 ? result + divisor : result;
}


vec4 swrt_sample_region(sampler2D atlas, vec4 region, vec2 uv) {
	ivec2 region_origin = ivec2(region.xy);
	ivec2 region_size = max(ivec2(region.zw), ivec2(1));
	vec2 texel_position = fract(uv) * vec2(region_size) - vec2(0.5);
	ivec2 texel_0 = ivec2(floor(texel_position));
	ivec2 texel_1 = texel_0 + ivec2(1);
	vec2 blend = fract(texel_position);
	ivec2 coordinate_00 = region_origin + ivec2(
		swrt_positive_modulo(texel_0.x, region_size.x),
		swrt_positive_modulo(texel_0.y, region_size.y));
	ivec2 coordinate_10 = region_origin + ivec2(
		swrt_positive_modulo(texel_1.x, region_size.x),
		swrt_positive_modulo(texel_0.y, region_size.y));
	ivec2 coordinate_01 = region_origin + ivec2(
		swrt_positive_modulo(texel_0.x, region_size.x),
		swrt_positive_modulo(texel_1.y, region_size.y));
	ivec2 coordinate_11 = region_origin + ivec2(
		swrt_positive_modulo(texel_1.x, region_size.x),
		swrt_positive_modulo(texel_1.y, region_size.y));
	vec4 row_0 = mix(texelFetch(atlas, coordinate_00, 0), texelFetch(atlas, coordinate_10, 0), blend.x);
	vec4 row_1 = mix(texelFetch(atlas, coordinate_01, 0), texelFetch(atlas, coordinate_11, 0), blend.x);
	return mix(row_0, row_1, blend.y);
}


vec3 swrt_triplanar_weights(vec3 mapping_normal, float sharpness) {
	float normal_length_squared = dot(mapping_normal, mapping_normal);
	vec3 absolute_normal = normal_length_squared > 1e-12
		? abs(mapping_normal * inversesqrt(normal_length_squared))
		: vec3(0.0, 1.0, 0.0);
	float clamped_sharpness = clamp(sharpness, 0.0, 150.0);
	if (clamped_sharpness <= 0.0) {
		return vec3(1.0 / 3.0);
	}
	vec3 weights = pow(absolute_normal, vec3(clamped_sharpness));
	float weight_sum = dot(weights, vec3(1.0));
	if (weight_sum > 1e-37) {
		return weights / weight_sum;
	}
	if (absolute_normal.x >= absolute_normal.y && absolute_normal.x >= absolute_normal.z) {
		return vec3(1.0, 0.0, 0.0);
	}
	return absolute_normal.y >= absolute_normal.z
		? vec3(0.0, 1.0, 0.0)
		: vec3(0.0, 0.0, 1.0);
}


vec3 swrt_triplanar_position(vec3 mapping_position, SWRTMaterial material_record) {
	return (
		mapping_position * material_record.triplanar_scale_sharpness.xyz
		+ material_record.triplanar_offset.xyz
	) * vec3(1.0, -1.0, 1.0);
}


vec4 swrt_sample_region_triplanar(
		sampler2D atlas,
		vec4 region,
		vec3 weights,
		vec3 position) {
	vec4 sampled = swrt_sample_region(atlas, region, position.xy) * weights.z;
	sampled += swrt_sample_region(atlas, region, position.xz) * weights.y;
	sampled += swrt_sample_region(atlas, region, position.zy * vec2(-1.0, 1.0)) * weights.x;
	return sampled;
}


vec3 swrt_decode_open_gl_normal(vec3 encoded_normal) {
	vec2 tangent_xy = encoded_normal.rg * 2.0 - 1.0;
	tangent_xy *= inversesqrt(max(1.0, dot(tangent_xy, tangent_xy)));
	return vec3(tangent_xy, sqrt(max(1.0 - dot(tangent_xy, tangent_xy), 0.0)));
}


int swrt_exact_int(float value) {
#ifdef SWRT_VALIDATE_HEADERS
	// The validation variant keeps malformed RGBAF integer payloads from being
	// silently truncated. Normal rendering compiles this branch out completely;
	// the CPU has already validated every packed value before upload.
	if (!(value >= -1.0 && value < 16777216.0)) {
		return -2147483647;
	}
	float rounded_value = floor(value + 0.5);
	if (abs(value - rounded_value) > 0.0001) {
		return -2147483647;
	}
	return int(rounded_value);
#else
	return int(value);
#endif
}


int swrt_vec4_int_lane(vec4 packed_value, int lane) {
	if (lane == 0) {
		return swrt_exact_int(packed_value.x);
	}
	if (lane == 1) {
		return swrt_exact_int(packed_value.y);
	}
	if (lane == 2) {
		return swrt_exact_int(packed_value.z);
	}
	return swrt_exact_int(packed_value.w);
}


int swrt_packed_int(sampler2D atlas, int scalar_base, int scalar_index) {
	vec4 packed_value = texelFetch(
		atlas,
		swrt_atlas_coordinate(scalar_base + (scalar_index >> 2)),
		0);
	return swrt_vec4_int_lane(packed_value, scalar_index & 3);
}


#ifdef SWRT_VALIDATE_HEADERS
bool swrt_validate_headers(SWRTFrameContext context) {
	vec4 geometry_header = swrt_geometry_fetch(0);
	vec4 geometry_counts = swrt_geometry_fetch(1);
	vec4 instance_header = swrt_instance_fetch(0);
	vec4 instance_counts = swrt_instance_fetch(1);
	vec4 shading_header = swrt_shading_fetch(0);
	vec4 shading_counts = swrt_shading_fetch(1);
	vec4 shading_settings = swrt_shading_fetch(2);
	return abs(geometry_header.x - SWRT_GEOMETRY_MAGIC) < 0.5
		&& abs(instance_header.x - SWRT_INSTANCE_MAGIC) < 0.5
		&& abs(shading_header.x - SWRT_SHADING_MAGIC) < 0.5
		&& abs(geometry_counts.w - SWRT_VERSION) < 0.5
		&& abs(instance_header.w - SWRT_VERSION) < 0.5
		&& abs(shading_settings.w - SWRT_VERSION) < 0.5
		&& swrt_exact_int(geometry_header.y) == context.geometry_layout.x
		&& swrt_exact_int(geometry_header.z) == context.geometry_layout.y
		&& swrt_exact_int(geometry_header.w) == context.geometry_layout.z
		&& swrt_exact_int(geometry_counts.x) == context.geometry_counts.x
		&& swrt_exact_int(geometry_counts.y) == context.geometry_counts.y
		&& swrt_exact_int(geometry_counts.z) == context.geometry_counts.z
		&& swrt_exact_int(instance_header.y) == context.instance_layout.x
		&& swrt_exact_int(instance_header.z) == context.instance_layout.y
		&& swrt_exact_int(instance_counts.x) == context.instance_layout.z
		&& swrt_exact_int(instance_counts.y) == context.instance_count
		&& swrt_exact_int(instance_counts.z) == context.instance_layout.w
		&& swrt_exact_int(shading_header.y) == context.shading_layout.x
		&& swrt_exact_int(shading_header.z) == context.shading_layout.y
		&& swrt_exact_int(shading_header.w) == context.shading_layout.z
		&& swrt_exact_int(shading_counts.x) == context.shading_layout.w
		&& swrt_exact_int(shading_counts.y) == context.shading_counts.x
		&& swrt_exact_int(shading_counts.z) == context.shading_counts.y
		&& swrt_exact_int(shading_counts.w) == context.shading_counts.z
		&& swrt_exact_int(shading_settings.z) == context.shading_counts.w;
}
#endif


SWRTRay swrt_make_ray(
		vec3 origin,
		vec3 direction,
		float minimum_distance,
		float maximum_distance) {
	SWRTRay ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.parallel_axes = lessThan(abs(direction), vec3(SWRT_DIRECTION_EPSILON));
	ray.inverse_direction = vec3(
		ray.parallel_axes.x ? 0.0 : 1.0 / direction.x,
		ray.parallel_axes.y ? 0.0 : 1.0 / direction.y,
		ray.parallel_axes.z ? 0.0 : 1.0 / direction.z);
	ray.minimum_distance = minimum_distance;
	ray.maximum_distance = maximum_distance;
	return ray;
}


bool swrt_slab_cached(
		float origin,
		float inverse_direction,
		bool parallel_axis,
		float bounds_min,
		float bounds_max,
		inout float near_distance,
		inout float far_distance) {
	if (parallel_axis) {
		return origin >= bounds_min && origin <= bounds_max;
	}
	float first = (bounds_min - origin) * inverse_direction;
	float second = (bounds_max - origin) * inverse_direction;
	float axis_near = min(first, second);
	float axis_far = max(first, second);
	near_distance = max(near_distance, axis_near);
	far_distance = min(far_distance, axis_far);
	return far_distance >= near_distance;
}


bool swrt_intersect_bounds(
		SWRTRay ray,
		vec3 bounds_min,
		vec3 bounds_max,
		float maximum_distance) {
	float near_distance = ray.minimum_distance;
	float far_distance = min(ray.maximum_distance, maximum_distance);
	if (!swrt_slab_cached(ray.origin.x, ray.inverse_direction.x, ray.parallel_axes.x,
			bounds_min.x, bounds_max.x, near_distance, far_distance)) {
		return false;
	}
	if (!swrt_slab_cached(ray.origin.y, ray.inverse_direction.y, ray.parallel_axes.y,
			bounds_min.y, bounds_max.y, near_distance, far_distance)) {
		return false;
	}
	return swrt_slab_cached(ray.origin.z, ray.inverse_direction.z, ray.parallel_axes.z,
		bounds_min.z, bounds_max.z, near_distance, far_distance);
}


bool swrt_intersect_triangle(
		vec3 ray_origin,
		vec3 ray_direction,
		vec3 vertex_0,
		vec3 vertex_1,
		vec3 vertex_2,
		float minimum_distance,
		float maximum_distance,
		out float hit_distance,
		out vec2 barycentric) {
	vec3 edge_1 = vertex_1 - vertex_0;
	vec3 edge_2 = vertex_2 - vertex_0;
	vec3 p_vector = cross(ray_direction, edge_2);
	float determinant = dot(edge_1, p_vector);
	if (abs(determinant) < SWRT_TRIANGLE_EPSILON) {
		return false;
	}
	float inverse_determinant = 1.0 / determinant;
	vec3 t_vector = ray_origin - vertex_0;
	float u = dot(t_vector, p_vector) * inverse_determinant;
	if (u < 0.0 || u > 1.0) {
		return false;
	}
	vec3 q_vector = cross(t_vector, edge_1);
	float v = dot(ray_direction, q_vector) * inverse_determinant;
	if (v < 0.0 || u + v > 1.0) {
		return false;
	}
	hit_distance = dot(edge_2, q_vector) * inverse_determinant;
	if (hit_distance < minimum_distance || hit_distance > maximum_distance) {
		return false;
	}
	barycentric = vec2(u, v);
	return true;
}


bool swrt_load_instance(
		SWRTFrameContext context,
		int object_id,
		out SWRTInstance instance_record) {
	if (object_id < 0 || object_id >= context.instance_count) {
		return false;
	}
	int instance_base = context.instance_layout.y + object_id * 8;
	instance_record.metadata = swrt_instance_fetch(instance_base);
	instance_record.light_list = swrt_instance_fetch(instance_base + 1);
	vec4 inverse_x = swrt_instance_fetch(instance_base + 2);
	vec4 inverse_y = swrt_instance_fetch(instance_base + 3);
	vec4 inverse_z = swrt_instance_fetch(instance_base + 4);
	instance_record.world_to_object = mat3(inverse_x.xyz, inverse_y.xyz, inverse_z.xyz);
	instance_record.object_origin = vec3(inverse_x.w, inverse_y.w, inverse_z.w);
	vec3 normal_x = swrt_instance_fetch(instance_base + 5).xyz;
	vec3 normal_y = swrt_instance_fetch(instance_base + 6).xyz;
	vec3 normal_z = swrt_instance_fetch(instance_base + 7).xyz;
	instance_record.normal_to_world = mat3(normal_x, normal_y, normal_z);
	return true;
}


bool swrt_load_material(
		SWRTFrameContext context,
		int material_index,
		out SWRTMaterial material_record) {
	if (material_index < 0 || material_index >= context.shading_counts.y) {
		return false;
	}
	int material_base = context.shading_layout.y + material_index * 8;
	material_record.diffuse_shininess = swrt_shading_fetch(material_base);
	material_record.ambient_intensity = swrt_shading_fetch(material_base + 1);
	material_record.emission_flags = swrt_shading_fetch(material_base + 2);
	material_record.specular_flags = swrt_shading_fetch(material_base + 3);
	material_record.albedo_region = swrt_shading_fetch(material_base + 4);
	material_record.normal_region = swrt_shading_fetch(material_base + 5);
	material_record.triplanar_scale_sharpness = swrt_shading_fetch(material_base + 6);
	material_record.triplanar_offset = swrt_shading_fetch(material_base + 7);
	return true;
}


bool swrt_trace_blas(
		SWRTFrameContext context,
		int geometry_index,
		int object_id,
		SWRTRay local_ray,
		bool any_hit,
		inout SWRTHit hit,
		inout bool overflowed) {
	if (geometry_index < 0 || geometry_index >= context.geometry_counts.y) {
		overflowed = true;
		return false;
	}
	vec4 mesh_record = swrt_geometry_fetch(context.geometry_layout.y + geometry_index);
	int node_index = swrt_exact_int(mesh_record.x);
	int mesh_node_count = swrt_exact_int(mesh_record.z);
	if (mesh_node_count <= 0 || mesh_node_count > SWRT_MAX_BLAS_STEPS) {
		overflowed = true;
		return false;
	}
	int node_limit = node_index + mesh_node_count;
	int node_texel_base = context.geometry_layout.x;
	int triangle_base = context.geometry_layout.z;

	// The CPU validates the same 32,768-node hard limit before upload. Using
	// this mesh's actual node count as the dynamic loop bound prevents GLES3
	// compilers from treating the global maximum as a huge nested static loop.
	for (int step = 0; step < mesh_node_count; step++) {
		if (node_index < 0 || node_index >= node_limit) {
			return false;
		}
		int node_address = node_texel_base + node_index * 3;
		vec4 node_min_escape = swrt_geometry_fetch(node_address);
		vec4 node_max_kind = swrt_geometry_fetch(node_address + 1);
		int escape_index = swrt_exact_int(node_min_escape.w);
		if (!swrt_intersect_bounds(
				local_ray,
				node_min_escape.xyz,
				node_max_kind.xyz,
				hit.distance)) {
			node_index = escape_index;
			continue;
		}

		bool leaf = node_max_kind.w >= 0.5;
		if (!leaf) {
			node_index += 1;
			continue;
		}

		// The leaf payload is cold for rejected/internal nodes, so defer its
		// third texture read until it is actually needed.
		vec4 node_primitives = swrt_geometry_fetch(node_address + 2);
		int primitive_start = swrt_exact_int(node_primitives.x);
		int primitive_count = swrt_exact_int(node_primitives.y);
		for (int primitive_offset = 0; primitive_offset < 4; primitive_offset++) {
			if (primitive_offset >= primitive_count) {
				break;
			}
			int triangle_index = primitive_start + primitive_offset;
			int triangle_address = triangle_base + triangle_index * 8;
			vec3 vertex_0 = swrt_geometry_fetch(triangle_address).xyz;
			vec3 vertex_1 = swrt_geometry_fetch(triangle_address + 1).xyz;
			vec3 vertex_2 = swrt_geometry_fetch(triangle_address + 2).xyz;
			float triangle_distance;
			vec2 triangle_barycentric;
			if (swrt_intersect_triangle(
					local_ray.origin,
					local_ray.direction,
					vertex_0,
					vertex_1,
					vertex_2,
					local_ray.minimum_distance,
					hit.distance,
					triangle_distance,
					triangle_barycentric)) {
				hit.distance = triangle_distance;
				hit.object_id = object_id;
				hit.triangle_id = triangle_index;
				hit.barycentric = triangle_barycentric;
				if (any_hit) {
					return true;
				}
			}
		}
		node_index = escape_index;
	}
	if (node_index < 0 || node_index >= node_limit) {
		return false;
	}
	overflowed = true;
	return false;
}


bool swrt_trace_scene(
		SWRTFrameContext context,
		vec3 ray_origin,
		vec3 ray_direction,
		float minimum_distance,
		float maximum_distance,
		uint traversal_mask,
		bool any_hit,
		out SWRTHit hit,
		out bool overflowed) {
	hit.distance = maximum_distance;
	hit.object_id = -1;
	hit.triangle_id = -1;
	hit.barycentric = vec2(0.0);
	overflowed = false;
	SWRTRay world_ray = swrt_make_ray(
		ray_origin, ray_direction, minimum_distance, maximum_distance);
	int node_index = context.instance_layout.w;
	int tlas_node_count = context.instance_layout.z;
	if (node_index < 0 || tlas_node_count == 0) {
		return false;
	}
	if (tlas_node_count < 0 || tlas_node_count > SWRT_MAX_TLAS_STEPS) {
		overflowed = true;
		return false;
	}
	int node_texel_base = context.instance_layout.x;

	// As with BLAS traversal, retain the documented hard capacity while making
	// the generated GLES3 loop proportional to the uploaded scene.
	for (int step = 0; step < tlas_node_count; step++) {
		if (node_index < 0 || node_index >= tlas_node_count) {
			return hit.object_id >= 0;
		}
		int node_address = node_texel_base + node_index * 3;
		vec4 node_min_escape = swrt_instance_fetch(node_address);
		vec4 node_max_kind = swrt_instance_fetch(node_address + 1);
		int escape_index = swrt_exact_int(node_min_escape.w);
		int node_flags = swrt_exact_int(node_max_kind.w);
		uint subtree_mask = uint(node_flags & 3);
		if ((subtree_mask & traversal_mask) == 0u) {
			node_index = escape_index;
			continue;
		}
		if (!swrt_intersect_bounds(
				world_ray,
				node_min_escape.xyz,
				node_max_kind.xyz,
				hit.distance)) {
			node_index = escape_index;
			continue;
		}

		bool leaf = (node_flags & 4) != 0;
		if (!leaf) {
			node_index += 1;
			continue;
		}
		// As with BLAS traversal, the payload is fetched only for a surviving
		// leaf. Its redundant mask remains available to debug ABI validation.
		vec4 node_primitive = swrt_instance_fetch(node_address + 2);
#ifdef SWRT_VALIDATE_HEADERS
		if (swrt_exact_int(node_primitive.y) != 1
				|| uint(swrt_exact_int(node_primitive.z)) != subtree_mask) {
			overflowed = true;
			return false;
		}
#endif
		int object_id = swrt_exact_int(node_primitive.x);
		SWRTInstance instance_record;
		if (!swrt_load_instance(context, object_id, instance_record)) {
			overflowed = true;
			return false;
		}
		uint instance_mask = uint(swrt_exact_int(instance_record.metadata.w));
		if ((instance_mask & traversal_mask) != 0u) {
			vec3 local_origin = instance_record.world_to_object * world_ray.origin + instance_record.object_origin;
			// Do not normalize: this preserves the world-space ray parameter t.
			vec3 local_direction = instance_record.world_to_object * world_ray.direction;
			SWRTRay local_ray = swrt_make_ray(
				local_origin,
				local_direction,
				world_ray.minimum_distance,
				hit.distance);
			int geometry_index = swrt_exact_int(instance_record.metadata.x);
			if (swrt_trace_blas(
					context,
					geometry_index,
					object_id,
					local_ray,
					any_hit,
					hit,
					overflowed)) {
				if (any_hit) {
					return true;
				}
			}
			if (overflowed) {
				return false;
			}
		}
		node_index = escape_index;
	}
	if (node_index < 0 || node_index >= tlas_node_count) {
		return hit.object_id >= 0;
	}
	overflowed = true;
	return false;
}


bool swrt_material_flag(SWRTMaterial material_record, int flag) {
	return (swrt_exact_int(material_record.specular_flags.w) & flag) != 0;
}


vec3 swrt_apply_uv_hit_normal(
		vec3 encoded_normal,
		vec3 geometric_world_normal,
		vec3 local_edge_1,
		vec3 local_edge_2,
		vec2 uv_edge_1,
		vec2 uv_edge_2,
		SWRTInstance instance_record) {
	float determinant = uv_edge_1.x * uv_edge_2.y - uv_edge_1.y * uv_edge_2.x;
	if (abs(determinant) <= SWRT_TANGENT_EPSILON) {
		return geometric_world_normal;
	}
	mat3 object_to_world = inverse(instance_record.world_to_object);
	vec3 world_edge_1 = object_to_world * local_edge_1;
	vec3 world_edge_2 = object_to_world * local_edge_2;
	vec3 tangent = (world_edge_1 * uv_edge_2.y - world_edge_2 * uv_edge_1.y) / determinant;
	vec3 bitangent_reference = (world_edge_2 * uv_edge_1.x - world_edge_1 * uv_edge_2.x) / determinant;
	tangent -= geometric_world_normal * dot(geometric_world_normal, tangent);
	float tangent_length_squared = dot(tangent, tangent);
	float bitangent_length_squared = dot(bitangent_reference, bitangent_reference);
	if (tangent_length_squared <= 1e-12 || bitangent_length_squared <= 1e-12) {
		return geometric_world_normal;
	}
	tangent *= inversesqrt(tangent_length_squared);
	vec3 perpendicular = cross(geometric_world_normal, tangent);
	float handedness_measure = dot(perpendicular, bitangent_reference);
	if (abs(handedness_measure) <= SWRT_TANGENT_EPSILON) {
		return geometric_world_normal;
	}
	vec3 bitangent = perpendicular * (handedness_measure < 0.0 ? -1.0 : 1.0);
	vec3 tangent_normal = swrt_decode_open_gl_normal(encoded_normal);
	return normalize(
		tangent * tangent_normal.x
		+ bitangent * tangent_normal.y
		+ geometric_world_normal * tangent_normal.z);
}


vec3 swrt_safe_normalize(vec3 value, vec3 fallback) {
	float length_squared = dot(value, value);
	return length_squared > 1e-12 ? value * inversesqrt(length_squared) : fallback;
}


vec3 swrt_interpolate_triplanar_weights(
		vec3 local_normal_0,
		vec3 local_normal_1,
		vec3 local_normal_2,
		vec3 vertex_weights,
		bool world_space,
		float sharpness,
		SWRTInstance instance_record) {
	vec3 mapping_normal_0 = world_space
		? instance_record.normal_to_world * local_normal_0 : local_normal_0;
	vec3 mapping_normal_1 = world_space
		? instance_record.normal_to_world * local_normal_1 : local_normal_1;
	vec3 mapping_normal_2 = world_space
		? instance_record.normal_to_world * local_normal_2 : local_normal_2;
	vec3 weights =
		swrt_triplanar_weights(mapping_normal_0, sharpness) * vertex_weights.x
		+ swrt_triplanar_weights(mapping_normal_1, sharpness) * vertex_weights.y
		+ swrt_triplanar_weights(mapping_normal_2, sharpness) * vertex_weights.z;
	// Match the raster varying: normalize each vertex's projection weights,
	// then barycentrically interpolate without a fragment-stage renormalize.
	if (!(dot(weights, vec3(1.0)) > 1e-37)) {
		return vec3(1.0 / 3.0);
	}
	return weights;
}


void swrt_make_triplanar_vertex_basis(
		vec3 local_normal,
		bool world_space,
		SWRTInstance instance_record,
		out vec3 world_tangent,
		out vec3 world_binormal) {
	vec3 mapping_normal = world_space
		? instance_record.normal_to_world * local_normal : local_normal;
	vec3 absolute_normal = abs(swrt_safe_normalize(mapping_normal, vec3(0.0, 1.0, 0.0)));
	vec3 generated_tangent = vec3(0.0, 0.0, -1.0) * absolute_normal.x;
	generated_tangent += vec3(1.0, 0.0, 0.0) * absolute_normal.y;
	generated_tangent += vec3(1.0, 0.0, 0.0) * absolute_normal.z;
	vec3 generated_binormal = vec3(0.0, 1.0, 0.0) * absolute_normal.x;
	generated_binormal += vec3(0.0, 0.0, -1.0) * absolute_normal.y;
	generated_binormal += vec3(0.0, 1.0, 0.0) * absolute_normal.z;
	generated_tangent = swrt_safe_normalize(generated_tangent, vec3(1.0, 0.0, 0.0));
	generated_binormal = swrt_safe_normalize(generated_binormal, vec3(0.0, 0.0, -1.0));
	world_tangent = world_space
		? generated_tangent : instance_record.normal_to_world * generated_tangent;
	world_binormal = world_space
		? generated_binormal : instance_record.normal_to_world * generated_binormal;
	// Godot normalizes transformed TBN vectors before interpolation.
	world_tangent = swrt_safe_normalize(world_tangent, vec3(0.0));
	world_binormal = swrt_safe_normalize(world_binormal, vec3(0.0));
}


vec3 swrt_apply_triplanar_hit_normal(
		vec3 encoded_normal,
		vec3 local_normal_0,
		vec3 local_normal_1,
		vec3 local_normal_2,
		vec3 vertex_weights,
		vec3 interpolated_world_normal,
		vec3 geometric_world_normal,
		bool world_space,
		SWRTInstance instance_record) {
	vec3 tangent_0;
	vec3 tangent_1;
	vec3 tangent_2;
	vec3 binormal_0;
	vec3 binormal_1;
	vec3 binormal_2;
	swrt_make_triplanar_vertex_basis(
		local_normal_0, world_space, instance_record, tangent_0, binormal_0);
	swrt_make_triplanar_vertex_basis(
		local_normal_1, world_space, instance_record, tangent_1, binormal_1);
	swrt_make_triplanar_vertex_basis(
		local_normal_2, world_space, instance_record, tangent_2, binormal_2);
	vec3 world_tangent = tangent_0 * vertex_weights.x
		+ tangent_1 * vertex_weights.y
		+ tangent_2 * vertex_weights.z;
	vec3 world_binormal = binormal_0 * vertex_weights.x
		+ binormal_1 * vertex_weights.y
		+ binormal_2 * vertex_weights.z;
	if (!(dot(world_tangent, world_tangent) > 1e-12)
			|| !(dot(world_binormal, world_binormal) > 1e-12)) {
		return geometric_world_normal;
	}
	if (dot(interpolated_world_normal, geometric_world_normal) < 0.0) {
		interpolated_world_normal = -interpolated_world_normal;
	}
	if (!(dot(interpolated_world_normal, interpolated_world_normal) > 1e-12)) {
		interpolated_world_normal = geometric_world_normal;
	}
	vec3 tangent_normal = swrt_decode_open_gl_normal(encoded_normal);
	return swrt_safe_normalize(
		world_tangent * tangent_normal.x
		+ world_binormal * tangent_normal.y
		+ interpolated_world_normal * tangent_normal.z,
		geometric_world_normal);
}


bool swrt_load_hit_shading(
		SWRTFrameContext context,
		SWRTHit hit,
		vec3 ray_direction,
		vec3 world_position,
		out vec3 geometric_world_normal,
		out vec3 shading_world_normal,
		out SWRTMaterial material_record,
		out SWRTInstance instance_record) {
	if (!swrt_load_instance(context, hit.object_id, instance_record)) {
		return false;
	}
	if (hit.triangle_id < 0 || hit.triangle_id >= context.geometry_counts.z) {
		return false;
	}
	int triangle_address = context.geometry_layout.z + hit.triangle_id * 8;
	vec4 vertex_surface = swrt_geometry_fetch(triangle_address);
	vec3 vertex_0 = vertex_surface.xyz;
	vec3 vertex_1 = swrt_geometry_fetch(triangle_address + 1).xyz;
	vec3 vertex_2 = swrt_geometry_fetch(triangle_address + 2).xyz;
	vec3 normal_0 = swrt_geometry_fetch(triangle_address + 3).xyz;
	vec3 normal_1 = swrt_geometry_fetch(triangle_address + 4).xyz;
	vec3 normal_2 = swrt_geometry_fetch(triangle_address + 5).xyz;
	vec4 uv_01 = swrt_geometry_fetch(triangle_address + 6);
	vec2 uv_0 = uv_01.xy;
	vec2 uv_1 = uv_01.zw;
	vec2 uv_2 = swrt_geometry_fetch(triangle_address + 7).xy;
	float weight_0 = 1.0 - hit.barycentric.x - hit.barycentric.y;
	vec3 vertex_weights = vec3(weight_0, hit.barycentric.x, hit.barycentric.y);
	vec3 local_position =
		vertex_0 * vertex_weights.x
		+ vertex_1 * vertex_weights.y
		+ vertex_2 * vertex_weights.z;
	vec3 local_normal = normalize(
		normal_0 * vertex_weights.x
		+ normal_1 * vertex_weights.y
		+ normal_2 * vertex_weights.z);
	vec2 surface_uv =
		uv_0 * vertex_weights.x
		+ uv_1 * vertex_weights.y
		+ uv_2 * vertex_weights.z;
	vec3 world_normal_fallback = swrt_safe_normalize(
		instance_record.normal_to_world
			* swrt_safe_normalize(local_normal, vec3(0.0, 1.0, 0.0)),
		vec3(0.0, 1.0, 0.0));
	vec3 world_normal_0 = swrt_safe_normalize(
		instance_record.normal_to_world * normal_0, world_normal_fallback);
	vec3 world_normal_1 = swrt_safe_normalize(
		instance_record.normal_to_world * normal_1, world_normal_fallback);
	vec3 world_normal_2 = swrt_safe_normalize(
		instance_record.normal_to_world * normal_2, world_normal_fallback);
	vec3 interpolated_world_normal =
		world_normal_0 * vertex_weights.x
		+ world_normal_1 * vertex_weights.y
		+ world_normal_2 * vertex_weights.z;
	geometric_world_normal = swrt_safe_normalize(
		interpolated_world_normal, world_normal_fallback);
	if (dot(geometric_world_normal, -ray_direction) < 0.0) {
		local_normal = -local_normal;
		interpolated_world_normal = -interpolated_world_normal;
		geometric_world_normal = -geometric_world_normal;
	}
	shading_world_normal = geometric_world_normal;

	int surface_index = swrt_exact_int(vertex_surface.w);
	int surface_count = swrt_exact_int(instance_record.light_list.z);
	if (surface_index < 0 || surface_index >= surface_count) {
		return false;
	}
	int mapping_index = swrt_exact_int(instance_record.metadata.y) + surface_index;
	if (mapping_index < 0 || mapping_index >= context.shading_counts.x) {
		return false;
	}
	int material_index = swrt_packed_int(
		swrt_shading_atlas, context.shading_layout.x, mapping_index);
	if (!swrt_load_material(context, material_index, material_record)) {
		return false;
	}

	bool triplanar = swrt_material_flag(material_record, 4);
	bool world_space = swrt_material_flag(material_record, 8);
	vec3 mapping_position = world_space ? world_position : local_position;
	vec3 triplanar_weights = vec3(0.0);
	vec3 triplanar_position = vec3(0.0);
	if (triplanar) {
		triplanar_weights = swrt_interpolate_triplanar_weights(
			normal_0,
			normal_1,
			normal_2,
			vertex_weights,
			world_space,
			material_record.triplanar_scale_sharpness.w,
			instance_record);
		triplanar_position = swrt_triplanar_position(mapping_position, material_record);
	}
	if (swrt_material_flag(material_record, 1)) {
		vec3 sampled_albedo = triplanar
			? swrt_sample_region_triplanar(
				swrt_albedo_atlas,
				material_record.albedo_region,
				triplanar_weights,
				triplanar_position).rgb
			: swrt_sample_region(swrt_albedo_atlas, material_record.albedo_region, surface_uv).rgb;
		if (swrt_compatibility_output) {
			sampled_albedo = swrt_srgb_to_linear(sampled_albedo);
		}
		material_record.diffuse_shininess.rgb *= sampled_albedo;
	}
	if (swrt_material_flag(material_record, 2)) {
		vec3 encoded_normal = triplanar
			? swrt_sample_region_triplanar(
				swrt_normal_atlas,
				material_record.normal_region,
				triplanar_weights,
				triplanar_position).rgb
			: swrt_sample_region(swrt_normal_atlas, material_record.normal_region, surface_uv).rgb;
		shading_world_normal = triplanar
			? swrt_apply_triplanar_hit_normal(
				encoded_normal,
				normal_0,
				normal_1,
				normal_2,
				vertex_weights,
				interpolated_world_normal,
				geometric_world_normal,
				world_space,
				instance_record)
			: swrt_apply_uv_hit_normal(
				encoded_normal,
				geometric_world_normal,
				vertex_1 - vertex_0,
				vertex_2 - vertex_0,
				uv_1 - uv_0,
				uv_2 - uv_0,
				instance_record);
	}
	return true;
}


bool swrt_sample_light(
		SWRTFrameContext context,
		int light_index,
		vec3 surface_position,
		vec3 surface_normal,
		uint receiver_layers,
		out vec3 light_direction,
		out vec3 radiance,
		out float normal_dot_light,
		out float shadow_max_distance,
		out bool shadow_enabled) {
	if (light_index < 0 || light_index >= context.shading_counts.z) {
		return false;
	}
	int light_address = context.shading_layout.z + light_index * 4;
	vec4 position_type = swrt_shading_fetch(light_address);
	vec4 direction_range = swrt_shading_fetch(light_address + 1);
	vec4 color_attenuation = swrt_shading_fetch(light_address + 2);
	vec4 cone_shadow = swrt_shading_fetch(light_address + 3);
	uint light_cull_mask = uint(swrt_exact_int(cone_shadow.w));
	if ((light_cull_mask & receiver_layers) == 0u) {
		return false;
	}
	int light_type = swrt_exact_int(position_type.w);
	float light_attenuation = 1.0;
	float distance_to_light = context.settings.y;
	float spot_cone_dot = 1.0;
	if (light_type == 0) {
		light_direction = normalize(direction_range.xyz);
		shadow_max_distance = context.settings.y;
	} else {
		vec3 to_light = position_type.xyz - surface_position;
		distance_to_light = length(to_light);
		float light_range = direction_range.w;
		if (distance_to_light <= 0.0001 || light_range <= 0.0 || distance_to_light >= light_range) {
			return false;
		}
		light_direction = to_light / distance_to_light;
		float ray_bias = context.settings.x;
		shadow_max_distance = max(distance_to_light - ray_bias, ray_bias);
	}

	normal_dot_light = max(dot(surface_normal, light_direction), 0.0);
	if (normal_dot_light <= 0.0) {
		return false;
	}
	if (light_type == 2) {
		vec3 from_light = -light_direction;
		float cone_edge = cone_shadow.x;
		spot_cone_dot = dot(from_light, normalize(direction_range.xyz));
		if (spot_cone_dot <= cone_edge && (1.0 - cone_edge) >= 0.0001) {
			return false;
		}
	} else if (light_type == 3) {
		if (dot(-light_direction, normalize(direction_range.xyz)) <= 0.0) {
			return false;
		}
	}

	if (light_type != 0) {
		float light_range = direction_range.w;
		float normalized_distance = distance_to_light / light_range;
		normalized_distance *= normalized_distance;
		normalized_distance *= normalized_distance;
		float range_fade = max(1.0 - normalized_distance, 0.0);
		range_fade *= range_fade;
		light_attenuation = range_fade * pow(max(distance_to_light, 0.0001), -color_attenuation.w);
		if (light_type == 2) {
			float cone_edge = cone_shadow.x;
			float cone = max(spot_cone_dot, cone_edge);
			float cone_rim = max(0.0001, (1.0 - cone) / max(1.0 - cone_edge, 0.0001));
			light_attenuation *= 1.0 - pow(cone_rim, max(cone_shadow.y, 0.001));
		}
	}
	radiance = color_attenuation.rgb * light_attenuation;
	shadow_enabled = cone_shadow.z >= 0.5;
	return true;
}


vec3 swrt_evaluate_direct_contribution(
		SWRTMaterial material_record,
		vec3 surface_normal,
		vec3 view_direction,
		vec3 light_direction,
		vec3 radiance,
		float normal_dot_light,
		float diffuse_scale) {
	vec3 diffuse_term = material_record.diffuse_shininess.rgb * normal_dot_light * radiance;
	vec3 highlight_term = vec3(0.0);
	if (material_record.ambient_intensity.w != 0.0 && dot(abs(material_record.specular_flags.rgb), vec3(1.0)) != 0.0) {
		vec3 half_vector = normalize(view_direction + light_direction);
		float blinn = pow(max(dot(surface_normal, half_vector), 0.0), material_record.diffuse_shininess.w);
		highlight_term = material_record.specular_flags.rgb * blinn * material_record.ambient_intensity.w * radiance;
	}
	return diffuse_term * diffuse_scale + highlight_term;
}


vec4 swrt_receiver_light_group(
		SWRTFrameContext context,
		SWRTInstance instance_record,
		int group_index) {
	int scalar_index = swrt_exact_int(instance_record.light_list.x) + (group_index << 2);
	return swrt_shading_fetch(context.shading_layout.w + (scalar_index >> 2));
}


vec3 swrt_evaluate_primary_lights(
		SWRTFrameContext context,
		vec3 surface_position,
		vec3 surface_normal,
		vec3 view_direction,
		SWRTMaterial material_record,
		SWRTInstance instance_record,
		float reflection_amount,
		out int selected_light,
		out vec3 selected_contribution,
		out vec3 selected_direction,
		out float selected_distance,
		out bool malformed_light_list) {
	vec3 direct_lighting = vec3(0.0);
	selected_light = -1;
	selected_contribution = vec3(0.0);
	selected_direction = vec3(0.0);
	selected_distance = 0.0;
	float best_score = 0.0;
	uint receiver_layers = uint(swrt_exact_int(instance_record.metadata.z));
	int receiver_light_start = swrt_exact_int(instance_record.light_list.x);
	int receiver_light_count = swrt_exact_int(instance_record.light_list.y);
	int configured_light_cap = context.shading_counts.w;
	malformed_light_list = configured_light_cap < 1
		|| configured_light_cap > SWRT_MAX_RECEIVER_LIGHTS
		|| receiver_light_start < 0
		|| (receiver_light_start & 3) != 0
		|| receiver_light_count < 0
		|| receiver_light_count > configured_light_cap;
	receiver_light_count = clamp(
		receiver_light_count,
		0,
		clamp(configured_light_cap, 0, SWRT_MAX_RECEIVER_LIGHTS));
	for (int light_group = 0; light_group < SWRT_MAX_RECEIVER_LIGHTS / 4; light_group++) {
		int group_offset = light_group << 2;
		if (group_offset >= receiver_light_count) {
			break;
		}
		vec4 packed_light_indices = swrt_receiver_light_group(context, instance_record, light_group);
		for (int lane = 0; lane < 4; lane++) {
			int receiver_offset = group_offset + lane;
			if (receiver_offset >= receiver_light_count) {
				break;
			}
			int light_index = swrt_vec4_int_lane(packed_light_indices, lane);
			vec3 light_direction;
			vec3 radiance;
			float normal_dot_light;
			float shadow_max_distance;
			bool shadow_enabled;
			if (!swrt_sample_light(
					context,
					light_index,
					surface_position,
					surface_normal,
					receiver_layers,
					light_direction,
					radiance,
					normal_dot_light,
					shadow_max_distance,
					shadow_enabled)) {
				continue;
			}
			vec3 contribution = swrt_evaluate_direct_contribution(
				material_record,
				surface_normal,
				view_direction,
				light_direction,
				radiance,
				normal_dot_light,
				1.0 - reflection_amount);
			direct_lighting += contribution;
			if (shadow_enabled) {
				float score = dot(max(contribution, vec3(0.0)), SWRT_LUMINANCE);
				if (score > best_score) {
					best_score = score;
					selected_light = light_index;
					selected_contribution = contribution;
					selected_direction = light_direction;
					selected_distance = shadow_max_distance;
				}
			}
		}
	}
	return direct_lighting;
}


vec3 swrt_shade_terminal_hit(
		SWRTFrameContext context,
		vec3 surface_position,
		vec3 surface_normal,
		vec3 incoming_ray_direction,
		SWRTMaterial material_record,
		SWRTInstance instance_record,
		bool shadows_enabled,
		out int selected_light,
		out vec3 selected_contribution,
		out vec3 selected_direction,
		out float selected_distance,
		out bool malformed_light_list) {
	vec3 view_direction = normalize(-incoming_ray_direction);
	vec3 result = material_record.diffuse_shininess.rgb * material_record.ambient_intensity.rgb
		+ material_record.emission_flags.rgb;
	selected_light = -1;
	selected_contribution = vec3(0.0);
	selected_direction = vec3(0.0);
	selected_distance = 0.0;
	float best_score = 0.0;
	uint receiver_layers = uint(swrt_exact_int(instance_record.metadata.z));
	int receiver_light_start = swrt_exact_int(instance_record.light_list.x);
	int receiver_light_count = swrt_exact_int(instance_record.light_list.y);
	int configured_light_cap = context.shading_counts.w;
	malformed_light_list = configured_light_cap < 1
		|| configured_light_cap > SWRT_MAX_RECEIVER_LIGHTS
		|| receiver_light_start < 0
		|| (receiver_light_start & 3) != 0
		|| receiver_light_count < 0
		|| receiver_light_count > configured_light_cap;
	receiver_light_count = clamp(
		receiver_light_count,
		0,
		clamp(configured_light_cap, 0, SWRT_MAX_RECEIVER_LIGHTS));
	for (int light_group = 0; light_group < SWRT_MAX_RECEIVER_LIGHTS / 4; light_group++) {
		int group_offset = light_group << 2;
		if (group_offset >= receiver_light_count) {
			break;
		}
		vec4 packed_light_indices = swrt_receiver_light_group(context, instance_record, light_group);
		for (int lane = 0; lane < 4; lane++) {
			int receiver_offset = group_offset + lane;
			if (receiver_offset >= receiver_light_count) {
				break;
			}
			int light_index = swrt_vec4_int_lane(packed_light_indices, lane);
			vec3 light_direction;
			vec3 radiance;
			float normal_dot_light;
			float shadow_max_distance;
			bool shadow_enabled;
			if (!swrt_sample_light(
					context,
					light_index,
					surface_position,
					surface_normal,
					receiver_layers,
					light_direction,
					radiance,
					normal_dot_light,
					shadow_max_distance,
					shadow_enabled)) {
				continue;
			}
			vec3 contribution = swrt_evaluate_direct_contribution(
				material_record,
				surface_normal,
				view_direction,
				light_direction,
				radiance,
				normal_dot_light,
				1.0);
			result += contribution;
			if (shadows_enabled && shadow_enabled) {
				float score = dot(max(contribution, vec3(0.0)), SWRT_LUMINANCE);
				if (score > best_score) {
					best_score = score;
					selected_light = light_index;
					selected_contribution = contribution;
					selected_direction = light_direction;
					selected_distance = shadow_max_distance;
				}
			}
		}
	}
	return result;
}
