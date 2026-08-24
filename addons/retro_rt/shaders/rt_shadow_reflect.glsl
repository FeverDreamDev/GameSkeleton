#[versions]
native = "";

#[raygen]
#version 460
#extension GL_EXT_ray_tracing : require
VERSION_DEFINES

layout(set = 0, binding = 0) uniform accelerationStructureEXT scene_tlas;
layout(std140, set = 0, binding = 1) uniform FrameData {
	mat4 inv_projection;
	vec4 camera_position;
	vec4 camera_basis_x;
	vec4 camera_basis_y;
	vec4 camera_basis_z;
	vec4 viewport;
	vec4 ray_params;
	vec4 scene_counts;
	vec4 miss_color;
	vec4 environment_basis_x;
	vec4 environment_basis_y;
	vec4 environment_basis_z;
	vec4 environment_params;
	// Distance fog, applied post-lighting in main(). x=begin, y=end, z=curve,
	// w=enabled. See rt_fog_factor.
	vec4 fog_params;
	// Analytic cloud layer pushed by a sky system, so managed surfaces resolve
	// the same shadow their unmanaged neighbours already do. x=altitude,
	// y=1/tile size (zero disables), z=coverage threshold, w=edge softness.
	vec4 cloud_params;
	// x,z=world scroll, y=seed, w=shadow strength.
	vec4 cloud_motion;
	// Direction towards the sun, w unused.
	vec4 cloud_sun_direction;
} frame;
layout(rgba16f, set = 0, binding = 2) uniform image2D scene_color;
layout(rgba16f, set = 0, binding = 3) uniform image2D separate_specular;
layout(set = 0, binding = 4) uniform sampler2D scene_depth;
layout(set = 0, binding = 5) uniform sampler2D normal_roughness;

layout(std430, set = 0, binding = 6) readonly buffer PositionBuffer { vec4 positions[]; };
layout(std430, set = 0, binding = 7) readonly buffer NormalBuffer { vec4 normals[]; };
layout(std430, set = 0, binding = 8) readonly buffer IndexBuffer { uint indices[]; };

struct GeometryRecord {
	uvec4 offsets;
};
layout(std430, set = 0, binding = 9) readonly buffer GeometryBuffer { GeometryRecord geometries[]; };

struct InstanceRecord {
	vec4 metadata;
	vec4 normal_basis_x;
	vec4 normal_basis_y;
	vec4 normal_basis_z;
};
layout(std430, set = 0, binding = 10) readonly buffer InstanceBuffer { InstanceRecord instances[]; };

struct MaterialRecord {
	vec4 diffuse_shininess;
	vec4 ambient_intensity;
	vec4 emission_flags;
	vec4 specular_flags;
	vec4 albedo_region_px;
	vec4 normal_region_px;
	vec4 triplanar_scale_sharpness;
	vec4 triplanar_offset_pad;
};
layout(std430, set = 0, binding = 11) readonly buffer MaterialBuffer { MaterialRecord materials[]; };

struct LightRecord {
	vec4 position_type;
	vec4 direction_range;
	vec4 color_attenuation;
	vec4 cone_shadow;
};
layout(std430, set = 0, binding = 12) readonly buffer LightBuffer { LightRecord lights[]; };
layout(std430, set = 0, binding = 13) readonly buffer TriangleSurfaceBuffer { uint triangle_surfaces[]; };
layout(std430, set = 0, binding = 14) readonly buffer InstanceMaterialBuffer { uint instance_materials[]; };
layout(std430, set = 0, binding = 15) readonly buffer UVBuffer { vec2 uvs[]; };
layout(set = 0, binding = 16) uniform sampler2D albedo_atlas;
layout(set = 0, binding = 17) uniform sampler2D normal_atlas;
layout(std430, set = 0, binding = 18) readonly buffer ReceiverLightStartBuffer { uint receiver_light_starts[]; };
layout(std430, set = 0, binding = 19) readonly buffer ReceiverLightCountBuffer { uint receiver_light_counts[]; };
layout(std430, set = 0, binding = 20) readonly buffer ReceiverLightIndexBuffer { uint receiver_light_indices[]; };
layout(set = 0, binding = 21) uniform sampler2D environment_panorama;

struct Payload {
	uint instance_id;
	uint primitive_id;
	vec2 barycentric;
	float hit_t;
};
layout(location = 0) rayPayloadEXT Payload payload;

const uint SHADOW_RAY_SENTINEL = 0xfffffffeu;
const uint NO_REFLECTION_HIT = 0xffffffffu;
const uint MATERIAL_HAS_ALBEDO = 1u;
const uint MATERIAL_HAS_NORMAL = 2u;
const uint MATERIAL_TRIPLANAR = 4u;
const uint MATERIAL_TRIPLANAR_WORLD = 8u;
const int MAX_LIGHT_RECORDS = 256;
const vec3 LUMINANCE = vec3(0.2126, 0.7152, 0.0722);


vec3 decode_normal(vec3 raw_normal) {
	return normalize(raw_normal * 2.0 - 1.0);
}


float decode_roughness(float raw_roughness) {
	// Match CompositorEffect's normal_roughness_compatibility conversion.
	float value = raw_roughness;
	if (value > 0.5) {
		value = 1.0 - value;
	}
	return value / (127.0 / 255.0);
}


// Canonical Retro RT distance fog. Keep this function byte-identical in every
// copy: addons/retro_rt/shaders/rt_shadow_reflect.glsl,
// addons/retro_rt/shaders/BlinnPhongSoftwareBody.gdshaderinc,
// addons/procedural_terrain_grass/shaders/grass_shell.gdshader.
// Normative text: addons/retro_rt/docs/RT_PIPELINE.md, "Distance fog".
// params: x=begin, y=end (> begin), z=curve, w=enabled. distance is radial.
float rt_fog_factor(vec4 params, float view_distance) {
	if (params.w < 0.5) {
		return 0.0;
	}
	return pow(smoothstep(params.x, params.y, view_distance), params.z);
}
// Canonical day_night_cycle cloud layer. Keep every function below
// byte-identical in each copy: addons/day_night_cycle/shaders/day_night_sky.gdshader,
// addons/procedural_terrain_grass/shaders/grass_shell.gdshader,
// addons/retro_rt/shaders/BlinnPhong.gdshader,
// addons/retro_rt/shaders/BlinnPhongSoftwareBody.gdshaderinc,
// addons/retro_rt/shaders/rt_shadow_reflect.glsl.
// Normative text: addons/day_night_cycle/README.md, "The cloud layer".
//
// The layer is one flat plane of fractal noise. That is the whole reason a
// shadow can be resolved analytically: there is no volume to march and no
// geometry to trace, so the sky and the ground agree by construction rather
// than by being kept in sync.
//
// The field is computed rather than sampled from a texture on purpose. A
// sampler would have to be threaded through the hardware ray tracing descriptor
// set as well as every material, where two vec4s ride along in FrameData for
// free.
//
// params: x=altitude, y=1/tile size in metres (zero disables the layer),
// z=coverage threshold, w=edge softness.
// motion: x,z=world scroll offset, y=seed, w=shadow strength.
// Deliberately not the usual fract(sin(dot(...))) hash. Cloud cells run to the
// hundreds once the layer is sampled a few kilometres out, and sin() of an
// argument that large loses so much precision in 32-bit float that the hash
// degenerates into visible axis-aligned rectangles across the sky. This one
// never calls a trig function and stays stable out there.
//
// The three multipliers below must stay distinct. Scaling every component by
// the same constant leaves the third equal to the first -- the input only has
// two dimensions -- and the gradients it produces end up correlated, which
// draws long straight streaks across the layer at grazing angles.
vec2 dnc_cloud_hash(vec2 cell, float seed) {
	vec3 scattered = fract(
		vec3(cell.x, cell.y, cell.x) * vec3(0.1031, 0.1030, 0.0973) + seed);
	scattered += dot(scattered, vec3(scattered.y, scattered.z, scattered.x) + 33.33);
	return fract(
		(vec2(scattered.x, scattered.x) + vec2(scattered.y, scattered.z))
		* vec2(scattered.z, scattered.y));
}


// A unit vector per lattice corner. Taking the angle from the hash rather than
// normalising a hashed vector keeps the distribution even; sin and cos are safe
// here because the argument is bounded to one turn.
vec2 dnc_cloud_gradient(vec2 cell, float seed) {
	float angle = dnc_cloud_hash(cell, seed).x * 6.2831853;
	return vec2(cos(angle), sin(angle));
}


float dnc_cloud_noise(vec2 point, float seed) {
	vec2 lattice = floor(point);
	vec2 fraction = point - lattice;
	// Quintic, not the cheaper cubic smoothstep. Interpolated with a cubic the
	// second derivative is discontinuous at every lattice boundary, and a
	// coverage threshold turns those creases into straight visible seams the
	// moment the layer is viewed at a grazing angle.
	vec2 fade = fraction * fraction * fraction * (fraction * (fraction * 6.0 - 15.0) + 10.0);
	float corner00 = dot(dnc_cloud_gradient(lattice, seed), fraction);
	float corner10 = dot(
		dnc_cloud_gradient(lattice + vec2(1.0, 0.0), seed), fraction - vec2(1.0, 0.0));
	float corner01 = dot(
		dnc_cloud_gradient(lattice + vec2(0.0, 1.0), seed), fraction - vec2(0.0, 1.0));
	float corner11 = dot(
		dnc_cloud_gradient(lattice + vec2(1.0, 1.0), seed), fraction - vec2(1.0, 1.0));
	float value = mix(
		mix(corner00, corner10, fade.x),
		mix(corner01, corner11, fade.x),
		fade.y);
	// Two-dimensional gradient noise spans roughly -0.707..0.707.
	return clamp(value * 0.7071 + 0.5, 0.0, 1.0);
}


float dnc_cloud_field(vec2 point, float seed) {
	float total = 0.0;
	float amplitude = 0.5;
	float normalization = 0.0;
	vec2 sample_point = point;
	for (int octave = 0; octave < 4; octave++) {
		total += dnc_cloud_noise(sample_point, seed) * amplitude;
		normalization += amplitude;
		// Each octave is rotated as well as scaled. Sharing one lattice
		// orientation across octaves lets their grids reinforce into a visible
		// direction; an irrational-looking rotation leaves them nothing to agree
		// on. The lacunarity is deliberately not exactly two either: whole-number
		// steps line the octaves up on the same lattice and print a grid.
		sample_point = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * sample_point;
		sample_point = sample_point * 2.03 + vec2(37.0, 17.0);
		amplitude *= 0.5;
	}
	return total / normalization;
}


// [param edge_scale] widens the coverage threshold, which is how the layer
// stops aliasing as it stretches towards the horizon: it is the cheap stand-in
// for the mip level a texture lookup would have picked. Pass 1.0 for a lookup
// that is not being minified.
float dnc_cloud_density(vec4 params, vec4 motion, vec2 world_xz, float edge_scale) {
	if (params.y <= 0.0) {
		return 0.0;
	}
	float raw = dnc_cloud_field((world_xz + motion.xz) * params.y, motion.y);
	float edge = max(params.w * edge_scale, 0.001);
	return smoothstep(params.z - edge, params.z + edge, raw);
}


// Fraction of the sun a world position loses to the layer overhead.
float dnc_cloud_shadow(
		vec4 params,
		vec4 motion,
		vec3 world_position,
		vec3 direction_to_sun) {
	// Under a grazing sun the ray runs almost parallel to the layer and the
	// travel distance explodes, so the shadow is dropped rather than smeared
	// out to the horizon.
	if (params.y <= 0.0 || motion.w <= 0.0 || direction_to_sun.y <= 0.05) {
		return 0.0;
	}
	float travel = (params.x - world_position.y) / direction_to_sun.y;
	if (travel <= 0.0) {
		return 0.0;
	}
	vec2 hit = world_position.xz + direction_to_sun.xz * travel;
	return dnc_cloud_density(params, motion, hit, 1.0) * motion.w;
}


bool decode_visibility_id(vec3 encoded, out uint material_id, out uint instance_index) {
	uvec3 words = uvec3(round(clamp(encoded, vec3(0.0), vec3(2047.0))));
	if (words.x == 0u || words.z < 1024u) {
		return false;
	}
	uint one_based_instance_id = words.y | ((words.z - 1024u) << 11u);
	if (one_based_instance_id == 0u) {
		return false;
	}
	material_id = words.x;
	instance_index = one_based_instance_id - 1u;
	return true;
}


vec3 reconstruct_world_position(ivec2 pixel, float depth) {
	vec2 uv = (vec2(pixel) + vec2(0.5)) / frame.viewport.xy;
	vec4 clip_position = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_position_h = frame.inv_projection * clip_position;
	vec3 view_position = view_position_h.xyz / view_position_h.w;
	mat3 camera_to_world = mat3(frame.camera_basis_x.xyz, frame.camera_basis_y.xyz, frame.camera_basis_z.xyz);
	return camera_to_world * view_position + frame.camera_position.xyz;
}


vec3 safe_normalize(vec3 value, vec3 fallback) {
	float length_squared = dot(value, value);
	if (!(length_squared > 1e-12)) {
		return fallback;
	}
	return value * inversesqrt(length_squared);
}


uint get_material_flags(MaterialRecord material) {
	return uint(material.specular_flags.a + 0.5);
}


ivec2 positive_mod(ivec2 value, ivec2 divisor) {
	return ((value % divisor) + divisor) % divisor;
}


int environment_positive_mod(int value, int divisor) {
	int result = value % divisor;
	return result < 0 ? result + divisor : result;
}


vec3 sample_environment_miss(vec3 world_direction) {
	if (frame.environment_params.x < 0.5) {
		return frame.miss_color.rgb;
	}
	mat3 inverse_sky_basis = mat3(
		frame.environment_basis_x.xyz,
		frame.environment_basis_y.xyz,
		frame.environment_basis_z.xyz);
	vec3 direction = safe_normalize(
		inverse_sky_basis * world_direction, vec3(0.0, 0.0, -1.0));
	vec2 uv = vec2(atan(direction.x, -direction.z), acos(clamp(direction.y, -1.0, 1.0)));
	if (uv.x < 0.0) {
		uv.x += 6.283185307179586;
	}
	uv /= vec2(6.283185307179586, 3.141592653589793);

	ivec2 panorama_size = max(textureSize(environment_panorama, 0), ivec2(1));
	vec2 texel_position = uv * vec2(panorama_size) - vec2(0.5);
	ivec2 base = ivec2(floor(texel_position));
	vec2 blend = fract(texel_position);
	int x0 = environment_positive_mod(base.x, panorama_size.x);
	int x1 = environment_positive_mod(base.x + 1, panorama_size.x);
	int y0 = clamp(base.y, 0, panorama_size.y - 1);
	int y1 = clamp(base.y + 1, 0, panorama_size.y - 1);
	vec3 top = mix(
		texelFetch(environment_panorama, ivec2(x0, y0), 0).rgb,
		texelFetch(environment_panorama, ivec2(x1, y0), 0).rgb,
		blend.x);
	vec3 bottom = mix(
		texelFetch(environment_panorama, ivec2(x0, y1), 0).rgb,
		texelFetch(environment_panorama, ivec2(x1, y1), 0).rgb,
		blend.x);
	return mix(top, bottom, blend.y);
}


vec4 sample_atlas_repeat_bilinear(sampler2D atlas, vec4 region_px, vec2 uv) {
	ivec2 atlas_size = textureSize(atlas, 0);
	ivec2 origin = clamp(ivec2(round(region_px.xy)), ivec2(0), max(atlas_size - ivec2(1), ivec2(0)));
	ivec2 tile_size = max(ivec2(round(region_px.zw)), ivec2(1));
	tile_size = min(tile_size, max(atlas_size - origin, ivec2(1)));
	vec2 texel_position = fract(uv) * vec2(tile_size) - vec2(0.5);
	ivec2 base = ivec2(floor(texel_position));
	vec2 blend = fract(texel_position);
	ivec2 p00 = origin + positive_mod(base, tile_size);
	ivec2 p10 = origin + positive_mod(base + ivec2(1, 0), tile_size);
	ivec2 p01 = origin + positive_mod(base + ivec2(0, 1), tile_size);
	ivec2 p11 = origin + positive_mod(base + ivec2(1, 1), tile_size);
	vec4 top = mix(texelFetch(atlas, p00, 0), texelFetch(atlas, p10, 0), blend.x);
	vec4 bottom = mix(texelFetch(atlas, p01, 0), texelFetch(atlas, p11, 0), blend.x);
	return mix(top, bottom, blend.y);
}


vec3 get_triplanar_weights(vec3 mapping_normal, float sharpness) {
	vec3 absolute_normal = abs(safe_normalize(mapping_normal, vec3(0.0, 1.0, 0.0)));
	float clamped_sharpness = clamp(sharpness, 0.0, 150.0);
	if (clamped_sharpness <= 0.0) {
		return vec3(1.0 / 3.0);
	}
	vec3 weights = pow(absolute_normal, vec3(clamped_sharpness));
	float weight_sum = dot(weights, vec3(1.0));
	if (!(weight_sum > 1e-37)) {
		if (absolute_normal.x >= absolute_normal.y && absolute_normal.x >= absolute_normal.z) {
			return vec3(1.0, 0.0, 0.0);
		}
		if (absolute_normal.y >= absolute_normal.z) {
			return vec3(0.0, 1.0, 0.0);
		}
		return vec3(0.0, 0.0, 1.0);
	}
	return weights / weight_sum;
}


vec4 sample_atlas_triplanar(
	sampler2D atlas,
	vec4 region_px,
	vec3 weights,
	vec3 triplanar_position) {
	vec4 sampled = sample_atlas_repeat_bilinear(atlas, region_px, triplanar_position.xy) * weights.z;
	sampled += sample_atlas_repeat_bilinear(atlas, region_px, triplanar_position.xz) * weights.y;
	sampled += sample_atlas_repeat_bilinear(atlas, region_px, triplanar_position.zy * vec2(-1.0, 1.0)) * weights.x;
	return sampled;
}


vec3 apply_tangent_normal(
	vec3 encoded_normal,
	vec3 tangent,
	vec3 binormal,
	vec3 basis_normal,
	vec3 fallback_normal) {
	vec2 tangent_xy = encoded_normal.rg * 2.0 - 1.0;
	tangent_xy *= inversesqrt(max(1.0, dot(tangent_xy, tangent_xy)));
	vec3 tangent_normal = vec3(
		tangent_xy,
		sqrt(max(1.0 - dot(tangent_xy, tangent_xy), 0.0)));
	vec3 mapped = tangent * tangent_normal.x + binormal * tangent_normal.y + basis_normal * tangent_normal.z;
	return safe_normalize(mapped, fallback_normal);
}


vec3 apply_uv_normal(
	vec3 encoded_normal,
	vec3 local_p0,
	vec3 local_p1,
	vec3 local_p2,
	vec2 uv0,
	vec2 uv1,
	vec2 uv2,
	mat3 object_to_world,
	vec3 world_geometric_normal) {
	vec3 edge1 = object_to_world * (local_p1 - local_p0);
	vec3 edge2 = object_to_world * (local_p2 - local_p0);
	vec2 uv_edge1 = uv1 - uv0;
	vec2 uv_edge2 = uv2 - uv0;
	float determinant = uv_edge1.x * uv_edge2.y - uv_edge1.y * uv_edge2.x;
	if (!(abs(determinant) > 1e-8)) {
		return world_geometric_normal;
	}
	vec3 raw_tangent = (edge1 * uv_edge2.y - edge2 * uv_edge1.y) / determinant;
	vec3 raw_binormal = (-edge1 * uv_edge2.x + edge2 * uv_edge1.x) / determinant;
	vec3 tangent = raw_tangent - world_geometric_normal * dot(world_geometric_normal, raw_tangent);
	float tangent_length_squared = dot(tangent, tangent);
	if (!(tangent_length_squared > 1e-12) || !(dot(raw_binormal, raw_binormal) > 1e-12)) {
		return world_geometric_normal;
	}
	tangent *= inversesqrt(tangent_length_squared);
	vec3 cross_binormal = cross(world_geometric_normal, tangent);
	float handedness_measure = dot(cross_binormal, raw_binormal);
	if (!(abs(handedness_measure) > 1e-8)) {
		return world_geometric_normal;
	}
	vec3 binormal = cross_binormal * (handedness_measure < 0.0 ? -1.0 : 1.0);
	return apply_tangent_normal(
		encoded_normal,
		tangent,
		binormal,
		world_geometric_normal,
		world_geometric_normal);
}


vec3 interpolate_triplanar_weights(
	vec3 local_normal0,
	vec3 local_normal1,
	vec3 local_normal2,
	vec3 vertex_weights,
	mat3 normal_matrix,
	bool world_space,
	float sharpness) {
	vec3 mapping_normal0 = world_space ? normal_matrix * local_normal0 : local_normal0;
	vec3 mapping_normal1 = world_space ? normal_matrix * local_normal1 : local_normal1;
	vec3 mapping_normal2 = world_space ? normal_matrix * local_normal2 : local_normal2;
	vec3 weights =
		get_triplanar_weights(mapping_normal0, sharpness) * vertex_weights.x
		+ get_triplanar_weights(mapping_normal1, sharpness) * vertex_weights.y
		+ get_triplanar_weights(mapping_normal2, sharpness) * vertex_weights.z;
	// Every vertex value sums to one, so a valid barycentric interpolation
	// does too. Keep the unnormalized interpolation to match the raster
	// varying, retaining a finite fallback for malformed input.
	if (!(dot(weights, vec3(1.0)) > 1e-37)) {
		return vec3(1.0 / 3.0);
	}
	return weights;
}


void make_triplanar_vertex_basis(
	vec3 local_normal,
	mat3 normal_matrix,
	bool world_space,
	out vec3 world_tangent,
	out vec3 world_binormal) {
	vec3 mapping_normal = world_space ? normal_matrix * local_normal : local_normal;
	vec3 absolute_normal = abs(safe_normalize(mapping_normal, vec3(0.0, 1.0, 0.0)));
	vec3 generated_tangent = vec3(0.0, 0.0, -1.0) * absolute_normal.x;
	generated_tangent += vec3(1.0, 0.0, 0.0) * absolute_normal.y;
	generated_tangent += vec3(1.0, 0.0, 0.0) * absolute_normal.z;
	vec3 generated_binormal = vec3(0.0, 1.0, 0.0) * absolute_normal.x;
	generated_binormal += vec3(0.0, 0.0, -1.0) * absolute_normal.y;
	generated_binormal += vec3(0.0, 1.0, 0.0) * absolute_normal.z;
	generated_tangent = safe_normalize(generated_tangent, vec3(1.0, 0.0, 0.0));
	generated_binormal = safe_normalize(generated_binormal, vec3(0.0, 0.0, -1.0));
	if (world_space) {
		// The direct vertex shader cancels MODEL_NORMAL_MATRIX by assigning
		// its inverse here; Godot's later vertex transform restores this
		// generated world-space direction.
		world_tangent = generated_tangent;
		world_binormal = generated_binormal;
	} else {
		world_tangent = normal_matrix * generated_tangent;
		world_binormal = normal_matrix * generated_binormal;
	}
	// Godot normalizes transformed TBN vectors before interpolation.
	world_tangent = safe_normalize(world_tangent, vec3(0.0));
	world_binormal = safe_normalize(world_binormal, vec3(0.0));
}


vec3 apply_triplanar_normal(
	vec3 encoded_normal,
	vec3 local_normal0,
	vec3 local_normal1,
	vec3 local_normal2,
	vec3 vertex_weights,
	mat3 normal_matrix,
	bool world_space,
	vec3 interpolated_world_normal,
	vec3 world_geometric_normal) {
	vec3 tangent0;
	vec3 tangent1;
	vec3 tangent2;
	vec3 binormal0;
	vec3 binormal1;
	vec3 binormal2;
	make_triplanar_vertex_basis(local_normal0, normal_matrix, world_space, tangent0, binormal0);
	make_triplanar_vertex_basis(local_normal1, normal_matrix, world_space, tangent1, binormal1);
	make_triplanar_vertex_basis(local_normal2, normal_matrix, world_space, tangent2, binormal2);
	// Fragment TBN inputs are deliberately not renormalized after
	// interpolation (MikkTSpace/Godot convention).
	vec3 tangent = tangent0 * vertex_weights.x
		+ tangent1 * vertex_weights.y
		+ tangent2 * vertex_weights.z;
	vec3 binormal = binormal0 * vertex_weights.x
		+ binormal1 * vertex_weights.y
		+ binormal2 * vertex_weights.z;
	if (!(dot(tangent, tangent) > 1e-12) || !(dot(binormal, binormal) > 1e-12)) {
		return world_geometric_normal;
	}
	if (dot(interpolated_world_normal, world_geometric_normal) < 0.0) {
		interpolated_world_normal = -interpolated_world_normal;
	}
	if (!(dot(interpolated_world_normal, interpolated_world_normal) > 1e-12)) {
		interpolated_world_normal = world_geometric_normal;
	}
	return apply_tangent_normal(
		encoded_normal,
		tangent,
		binormal,
		interpolated_world_normal,
		world_geometric_normal);
}


void evaluate_material_surface(
	MaterialRecord material,
	vec3 local_position,
	vec2 surface_uv,
	vec3 local_p0,
	vec3 local_p1,
	vec3 local_p2,
	vec3 local_normal0,
	vec3 local_normal1,
	vec3 local_normal2,
	vec3 vertex_weights,
	vec2 uv0,
	vec2 uv1,
	vec2 uv2,
	mat3 normal_matrix,
	vec3 world_position,
	vec3 interpolated_world_normal,
	vec3 world_geometric_normal,
	out vec3 surface_albedo,
	out vec3 shading_normal) {
	uint flags = get_material_flags(material);
	surface_albedo = material.diffuse_shininess.rgb;
	shading_normal = world_geometric_normal;
	bool triplanar = (flags & MATERIAL_TRIPLANAR) != 0u;
	bool world_triplanar = (flags & MATERIAL_TRIPLANAR_WORLD) != 0u;
	vec3 triplanar_position = vec3(0.0);
	vec3 triplanar_weights = vec3(0.0);
	if (triplanar) {
		vec3 mapping_position = world_triplanar ? world_position : local_position;
		triplanar_weights = interpolate_triplanar_weights(
			local_normal0,
			local_normal1,
			local_normal2,
			vertex_weights,
			normal_matrix,
			world_triplanar,
			material.triplanar_scale_sharpness.w);
		triplanar_position = mapping_position * material.triplanar_scale_sharpness.xyz + material.triplanar_offset_pad.xyz;
		triplanar_position *= vec3(1.0, -1.0, 1.0);
	}
	if ((flags & MATERIAL_HAS_ALBEDO) != 0u) {
		vec3 sampled_albedo = triplanar
			? sample_atlas_triplanar(albedo_atlas, material.albedo_region_px, triplanar_weights, triplanar_position).rgb
			: sample_atlas_repeat_bilinear(albedo_atlas, material.albedo_region_px, surface_uv).rgb;
		surface_albedo *= sampled_albedo;
	}
	if ((flags & MATERIAL_HAS_NORMAL) == 0u) {
		return;
	}
	vec3 encoded_normal = triplanar
		? sample_atlas_triplanar(normal_atlas, material.normal_region_px, triplanar_weights, triplanar_position).rgb
		: sample_atlas_repeat_bilinear(normal_atlas, material.normal_region_px, surface_uv).rgb;
	if (triplanar) {
		shading_normal = apply_triplanar_normal(
			encoded_normal,
			local_normal0,
			local_normal1,
			local_normal2,
			vertex_weights,
			normal_matrix,
			world_triplanar,
			interpolated_world_normal,
			world_geometric_normal);
	} else {
		mat3 object_to_world = inverse(transpose(normal_matrix));
		shading_normal = apply_uv_normal(
			encoded_normal,
			local_p0,
			local_p1,
			local_p2,
			uv0,
			uv1,
			uv2,
			object_to_world,
			world_geometric_normal);
	}
}


bool sample_light(
	LightRecord light,
	vec3 position,
	vec3 normal,
	uint receiver_layers,
	out vec3 light_direction,
	out vec3 radiance,
	out float n_dot_l,
	out float shadow_max_distance) {
	uint light_cull_mask = uint(light.cone_shadow.w + 0.5);
	if ((light_cull_mask & receiver_layers) == 0u) {
		return false;
	}
	int type = int(light.position_type.w + 0.5);
	float attenuation = 1.0;
	float distance_to_light = frame.ray_params.y;
	float spot_cone_dot = 1.0;
	if (type == 0) {
		light_direction = normalize(light.direction_range.xyz);
		shadow_max_distance = frame.ray_params.y;
	} else {
		vec3 to_light = light.position_type.xyz - position;
		distance_to_light = length(to_light);
		float light_range = light.direction_range.w;
		if (distance_to_light <= 0.0001 || light_range <= 0.0 || distance_to_light >= light_range) {
			return false;
		}
		light_direction = to_light / distance_to_light;
		shadow_max_distance = max(distance_to_light - frame.ray_params.x, frame.ray_params.x);
	}

	n_dot_l = max(dot(normal, light_direction), 0.0);
	if (n_dot_l <= 0.0) {
		return false;
	}

	if (type == 2) {
		vec3 from_light = -light_direction;
		float cone_edge = light.cone_shadow.x;
		spot_cone_dot = dot(from_light, normalize(light.direction_range.xyz));
		// For ordinary cone widths, the existing formula evaluates to exactly
		// zero at and beyond the edge. Preserve its narrow-cone clamp behavior.
		if (spot_cone_dot <= cone_edge && (1.0 - cone_edge) >= 0.0001) {
			return false;
		}
	} else if (type == 3) {
		// Hard-shadow approximation for AreaLight3D: one ray to its center,
		// matching the center-origin convention of Godot's shadow map.
		if (dot(-light_direction, normalize(light.direction_range.xyz)) <= 0.0) {
			return false;
		}
	}

	if (type != 0) {
		float light_range = light.direction_range.w;
		// Match Godot 4.7's hard positional-light range/decay curve.
		float normalized_distance = distance_to_light / light_range;
		normalized_distance *= normalized_distance;
		normalized_distance *= normalized_distance;
		float range_fade = max(1.0 - normalized_distance, 0.0);
		range_fade *= range_fade;
		attenuation = range_fade * pow(max(distance_to_light, 0.0001), -light.color_attenuation.w);
		if (type == 2) {
			float cone_edge = light.cone_shadow.x;
			float cone = max(spot_cone_dot, cone_edge);
			float cone_rim = max(0.0001, (1.0 - cone) / max(1.0 - cone_edge, 0.0001));
			attenuation *= 1.0 - pow(cone_rim, max(light.cone_shadow.y, 0.001));
		}
	}
	radiance = light.color_attenuation.rgb * attenuation;
	return true;
}


void evaluate_direct_terms(
	MaterialRecord material,
	vec3 surface_albedo,
	vec3 normal,
	vec3 view_direction,
	vec3 light_direction,
	vec3 radiance,
	float n_dot_l,
	out vec3 diffuse,
	out vec3 highlight) {
	diffuse = surface_albedo * n_dot_l * radiance;
	highlight = vec3(0.0);
	if (material.ambient_intensity.a == 0.0 || all(equal(material.specular_flags.rgb, vec3(0.0)))) {
		return;
	}
	vec3 half_vector = normalize(view_direction + light_direction);
	float blinn = pow(max(dot(normal, half_vector), 0.0), material.diffuse_shininess.a);
	highlight = material.specular_flags.rgb * blinn * material.ambient_intensity.a * radiance;
}


void evaluate_primary_lights(
	vec3 position,
	vec3 normal,
	vec3 view_direction,
	MaterialRecord material,
	vec3 surface_albedo,
	float reflection_strength,
	uint receiver_layers,
	uint receiver_instance_index,
	out vec3 unshadowed_direct,
	out int selected_light,
	out vec3 selected_contribution,
	out vec3 selected_shadow_direction,
	out float selected_shadow_tmax) {
	unshadowed_direct = vec3(0.0);
	selected_light = -1;
	selected_contribution = vec3(0.0);
	selected_shadow_direction = vec3(0.0);
	selected_shadow_tmax = 0.0;
	float best_score = 0.0;
	uint range_start = receiver_light_starts[receiver_instance_index];
	uint range_count = min(receiver_light_counts[receiver_instance_index], uint(MAX_LIGHT_RECORDS));
	uint scene_light_count = uint(frame.scene_counts.x + 0.5);
	for (int slot = 0; slot < MAX_LIGHT_RECORDS; slot++) {
		if (uint(slot) >= range_count) {
			break;
		}
		uint light_index = receiver_light_indices[range_start + uint(slot)];
		if (light_index >= scene_light_count) {
			continue;
		}
		vec3 light_direction;
		vec3 radiance;
		float n_dot_l;
		float shadow_tmax;
		if (!sample_light(lights[light_index], position, normal, receiver_layers, light_direction, radiance, n_dot_l, shadow_tmax)) {
			continue;
		}
		vec3 diffuse;
		vec3 highlight;
		evaluate_direct_terms(material, surface_albedo, normal, view_direction, light_direction, radiance, n_dot_l, diffuse, highlight);
		vec3 contribution = diffuse * (1.0 - reflection_strength) + highlight;
		unshadowed_direct += contribution;
		if (lights[light_index].cone_shadow.z >= 0.5) {
			float score = dot(max(contribution, vec3(0.0)), LUMINANCE);
			if (score > best_score) {
				best_score = score;
				selected_light = int(light_index);
				selected_contribution = contribution;
				selected_shadow_direction = light_direction;
				selected_shadow_tmax = shadow_tmax;
			}
		}
	}
}


vec3 shade_hit(
	vec3 position,
	vec3 geometric_normal,
	vec3 shading_normal,
	vec3 incoming_ray_direction,
	MaterialRecord material,
	vec3 surface_albedo,
	uint receiver_layers,
	uint receiver_instance_index,
	bool shadows_enabled) {
	vec3 view_direction = normalize(-incoming_ray_direction);
	vec3 result = surface_albedo * material.ambient_intensity.rgb + material.emission_flags.rgb;
	int selected_light = -1;
	vec3 selected_contribution = vec3(0.0);
	vec3 selected_shadow_direction = vec3(0.0);
	float selected_shadow_tmax = 0.0;
	float best_score = 0.0;
	uint range_start = receiver_light_starts[receiver_instance_index];
	uint range_count = min(receiver_light_counts[receiver_instance_index], uint(MAX_LIGHT_RECORDS));
	uint scene_light_count = uint(frame.scene_counts.x + 0.5);
	for (int slot = 0; slot < MAX_LIGHT_RECORDS; slot++) {
		if (uint(slot) >= range_count) {
			break;
		}
		uint light_index = receiver_light_indices[range_start + uint(slot)];
		if (light_index >= scene_light_count) {
			continue;
		}
		vec3 light_direction;
		vec3 radiance;
		float n_dot_l;
		float shadow_tmax;
		if (!sample_light(lights[light_index], position, shading_normal, receiver_layers, light_direction, radiance, n_dot_l, shadow_tmax)) {
			continue;
		}
		vec3 diffuse;
		vec3 highlight;
		evaluate_direct_terms(material, surface_albedo, shading_normal, view_direction, light_direction, radiance, n_dot_l, diffuse, highlight);
		vec3 contribution = diffuse + highlight;
		result += contribution;
		if (shadows_enabled && lights[light_index].cone_shadow.z >= 0.5) {
			float score = dot(max(contribution, vec3(0.0)), LUMINANCE);
			if (score > best_score) {
				best_score = score;
				selected_light = int(light_index);
				selected_contribution = contribution;
				selected_shadow_direction = light_direction;
				selected_shadow_tmax = shadow_tmax;
			}
		}
	}
	if (selected_light >= 0) {
		vec3 shadow_origin = position + geometric_normal * frame.ray_params.x;
		payload.instance_id = SHADOW_RAY_SENTINEL;
		payload.primitive_id = 0u;
		payload.hit_t = 0.0;
		payload.barycentric = vec2(0.0);
		traceRayEXT(scene_tlas,
			gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT,
			0x01, 0, 1, 0, shadow_origin, frame.ray_params.x, selected_shadow_direction, selected_shadow_tmax, 0);
		if (payload.instance_id != NO_REFLECTION_HIT) {
			result -= selected_contribution;
		}
	}
	return result;
}


vec3 shade_reflection_hit(vec3 ray_origin, vec3 ray_direction, bool shadows_enabled) {
	uint instance_index = payload.instance_id;
	uint primitive_index = payload.primitive_id;
	InstanceRecord instance_record = instances[instance_index];
	uint geometry_index = uint(instance_record.metadata.x + 0.5);
	uint material_base = uint(instance_record.metadata.y + 0.5);
	GeometryRecord geometry_record = geometries[geometry_index];
	uint surface_count = geometry_record.offsets.w;
	uint surface_index = 0u;
	if (surface_count > 1u) {
		surface_index = triangle_surfaces[geometry_record.offsets.z + primitive_index];
		surface_index = min(surface_index, surface_count - 1u);
	}
	uint material_index = instance_materials[material_base + surface_index];
	uint index_base = geometry_record.offsets.y + primitive_index * 3u;
	uint i0 = indices[index_base + 0u];
	uint i1 = indices[index_base + 1u];
	uint i2 = indices[index_base + 2u];
	float b0 = 1.0 - payload.barycentric.x - payload.barycentric.y;
	vec3 vertex_weights = vec3(b0, payload.barycentric.x, payload.barycentric.y);
	vec3 local_p0 = positions[geometry_record.offsets.x + i0].xyz;
	vec3 local_p1 = positions[geometry_record.offsets.x + i1].xyz;
	vec3 local_p2 = positions[geometry_record.offsets.x + i2].xyz;
	vec3 local_position = local_p0 * vertex_weights.x + local_p1 * vertex_weights.y + local_p2 * vertex_weights.z;
	vec3 local_normal0 = normals[geometry_record.offsets.x + i0].xyz;
	vec3 local_normal1 = normals[geometry_record.offsets.x + i1].xyz;
	vec3 local_normal2 = normals[geometry_record.offsets.x + i2].xyz;
	vec3 local_normal = normalize(
		local_normal0 * vertex_weights.x +
		local_normal1 * vertex_weights.y +
		local_normal2 * vertex_weights.z);
	vec2 uv0 = uvs[geometry_record.offsets.x + i0];
	vec2 uv1 = uvs[geometry_record.offsets.x + i1];
	vec2 uv2 = uvs[geometry_record.offsets.x + i2];
	vec2 surface_uv = uv0 * vertex_weights.x + uv1 * vertex_weights.y + uv2 * vertex_weights.z;
	mat3 normal_matrix = mat3(
		instance_record.normal_basis_x.xyz,
		instance_record.normal_basis_y.xyz,
		instance_record.normal_basis_z.xyz);
	vec3 world_normal_fallback = safe_normalize(
		normal_matrix * safe_normalize(local_normal, vec3(0.0, 1.0, 0.0)),
		vec3(0.0, 1.0, 0.0));
	vec3 world_normal0 = safe_normalize(normal_matrix * local_normal0, world_normal_fallback);
	vec3 world_normal1 = safe_normalize(normal_matrix * local_normal1, world_normal_fallback);
	vec3 world_normal2 = safe_normalize(normal_matrix * local_normal2, world_normal_fallback);
	vec3 interpolated_world_normal =
		world_normal0 * vertex_weights.x
		+ world_normal1 * vertex_weights.y
		+ world_normal2 * vertex_weights.z;
	vec3 world_normal = safe_normalize(interpolated_world_normal, world_normal_fallback);
	vec3 hit_position = ray_origin + payload.hit_t * ray_direction;
	if (dot(world_normal, -ray_direction) < 0.0) {
		world_normal = -world_normal;
		interpolated_world_normal = -interpolated_world_normal;
		local_normal = -local_normal;
	}
	vec3 surface_albedo;
	vec3 shading_normal;
	MaterialRecord material = materials[material_index];
	evaluate_material_surface(
		material,
		local_position,
		surface_uv,
		local_p0,
		local_p1,
		local_p2,
		local_normal0,
		local_normal1,
		local_normal2,
		vertex_weights,
		uv0,
		uv1,
		uv2,
		normal_matrix,
		hit_position,
		interpolated_world_normal,
		world_normal,
		surface_albedo,
		shading_normal);
	uint receiver_layers = uint(instance_record.metadata.w + 0.5);
	return shade_hit(
		hit_position,
		world_normal,
		shading_normal,
		ray_direction,
		material,
		surface_albedo,
		receiver_layers,
		instance_index,
		shadows_enabled);
}


void main() {
	ivec2 launch_pixel = ivec2(gl_LaunchIDEXT.xy);
	ivec2 size = ivec2(frame.viewport.xy);
	if (launch_pixel.x >= size.x || launch_pixel.y >= size.y) {
		return;
	}
	ivec2 pixel = launch_pixel;
	float depth = texelFetch(scene_depth, pixel, 0).r;
	if (depth <= 0.000001) {
		return;
	}

	vec4 specular = imageLoad(separate_specular, pixel);
	uint encoded_material_id;
	uint primary_instance_index;
	if (!decode_visibility_id(specular.rgb, encoded_material_id, primary_instance_index)) {
		return;
	}
	uint material_count = uint(frame.scene_counts.y + 0.5);
	uint instance_count = uint(frame.scene_counts.z + 0.5);
	if (encoded_material_id > material_count || primary_instance_index >= instance_count) {
		return;
	}
	uint material_index = encoded_material_id - 1u;
	MaterialRecord material = materials[material_index];
	uint receiver_layers = uint(instances[primary_instance_index].metadata.w + 0.5);

	vec4 raw_normal_roughness = texelFetch(normal_roughness, pixel, 0);
	vec3 view_normal = decode_normal(raw_normal_roughness.xyz);
	mat3 camera_to_world = mat3(frame.camera_basis_x.xyz, frame.camera_basis_y.xyz, frame.camera_basis_z.xyz);
	vec3 normal = normalize(camera_to_world * view_normal);
	float reflection_strength = clamp(1.0 - decode_roughness(raw_normal_roughness.w), 0.0, 1.0);
	vec3 world_position = reconstruct_world_position(pixel, depth);
	vec3 view_direction = normalize(frame.camera_position.xyz - world_position);
	vec4 color = imageLoad(scene_color, pixel);
	vec3 surface_albedo = color.rgb;
	// Primary raster shading transports the sampled, diffuse-tinted albedo in
	// scene_color. Replace that carrier unconditionally before the frame leaves
	// the compositor pass.
	color.rgb = surface_albedo * material.ambient_intensity.rgb + material.emission_flags.rgb;

	vec3 direct;
	int selected_light;
	vec3 selected_contribution;
	vec3 selected_shadow_direction;
	float selected_shadow_tmax;
	evaluate_primary_lights(
		world_position,
		normal,
		view_direction,
		material,
		surface_albedo,
		reflection_strength,
		receiver_layers,
		primary_instance_index,
		direct,
		selected_light,
		selected_contribution,
		selected_shadow_direction,
		selected_shadow_tmax);
	float visibility = 1.0;
	if (selected_light >= 0) {
		vec3 shadow_origin = world_position + normal * frame.ray_params.x;
		payload.instance_id = SHADOW_RAY_SENTINEL;
		payload.primitive_id = 0u;
		payload.hit_t = 0.0;
		payload.barycentric = vec2(0.0);
		traceRayEXT(scene_tlas,
			gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT,
			0x01, 0, 1, 0, shadow_origin, frame.ray_params.x, selected_shadow_direction, selected_shadow_tmax, 0);
		visibility = payload.instance_id == NO_REFLECTION_HIT ? 1.0 : 0.0;
		direct += selected_contribution * (visibility - 1.0);
	}

	vec3 reflected_radiance = frame.miss_color.rgb;
	if (reflection_strength > (0.5 / 127.0)) {
		vec3 reflection_direction = normalize(reflect(-view_direction, normal));
		vec3 reflection_origin = world_position + normal * frame.ray_params.x;
		payload.instance_id = NO_REFLECTION_HIT;
		payload.primitive_id = 0u;
		payload.hit_t = 0.0;
		payload.barycentric = vec2(0.0);
		traceRayEXT(scene_tlas,
			gl_RayFlagsOpaqueEXT,
			0x02, 0, 1, 0, reflection_origin, frame.ray_params.x, reflection_direction, frame.ray_params.y, 0);
		if (payload.instance_id != NO_REFLECTION_HIT) {
			reflected_radiance = shade_reflection_hit(
				reflection_origin,
				reflection_direction,
				material.emission_flags.a >= 0.5);
		} else {
			reflected_radiance = sample_environment_miss(reflection_direction);
		}
		color.rgb = mix(color.rgb, reflected_radiance, reflection_strength);
	}
	// The cloud layer shadows the primary hit only, at the same point the fog
	// does, so managed ground and unmanaged grass darken together under the same
	// cloud. A reflected hit inherits the reflector's sky, not its own.
	direct *= 1.0 - dnc_cloud_shadow(
		frame.cloud_params,
		frame.cloud_motion,
		world_position,
		frame.cloud_sun_direction.xyz);
	float fog = rt_fog_factor(frame.fog_params, length(world_position - frame.camera_position.xyz));
	color.rgb = mix(color.rgb, frame.miss_color.rgb, fog);
	// Forward+ adds separate_specular back into scene_color, so attenuating direct
	// here makes the composite exactly (ambient + reflection + direct) * (1 - f)
	// + fog_color * f. Fog is applied to the primary hit only: reflected radiance
	// inherits the reflector's fog, not the reflected path length. The software
	// path does the same thing at the same point so the two backends stay matched.
	direct *= 1.0 - fog;
	// Forward+'s compositor storage path does not propagate opaque alpha into a
	// transparent ViewportTexture. Keep a visually-black half-float sentinel so
	// the shared post pass can distinguish an exactly black managed surface from
	// uncovered transparent background. This is far below one display-code step.
	if (max(color.r, max(color.g, color.b)) <= 0.000001) {
		color.rgb = vec3(0.00002);
	}
	imageStore(scene_color, pixel, color);
	specular.rgb = direct;
	imageStore(separate_specular, pixel, specular);
}


#[miss]
#version 460
#extension GL_EXT_ray_tracing : require
struct Payload { uint instance_id; uint primitive_id; vec2 barycentric; float hit_t; };
layout(location = 0) rayPayloadInEXT Payload payload;
void main() {
	if (payload.instance_id == 0xfffffffeu) {
		payload.instance_id = 0xffffffffu;
	}
}


#[closest_hit]
#version 460
#extension GL_EXT_ray_tracing : require
struct Payload { uint instance_id; uint primitive_id; vec2 barycentric; float hit_t; };
layout(location = 0) rayPayloadInEXT Payload payload;
hitAttributeEXT vec2 hit_attribute;
void main() {
	payload.instance_id = gl_InstanceCustomIndexEXT;
	payload.primitive_id = gl_PrimitiveID;
	payload.hit_t = gl_HitTEXT;
	payload.barycentric = hit_attribute;
}
