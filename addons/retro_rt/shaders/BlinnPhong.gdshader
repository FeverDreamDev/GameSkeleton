shader_type spatial;
render_mode fog_disabled;

// Project-owned Blinn-Phong material. Reflection strength and the mapped
// primary normal are exported through Forward+'s normal/roughness prepass.
uniform vec4 ambient_light : source_color = vec4(0.1, 0.1, 0.1, 1.0);
uniform vec4 diffuse_color : source_color = vec4(0.25, 0.5, 0.2, 1.0);
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 specular_color : source_color = vec4(1.0);

uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool vertex_color_enabled = false;
uniform bool triplanar_enabled = false;
uniform bool triplanar_world_space = false;
uniform vec3 triplanar_scale = vec3(1.0);
uniform vec3 triplanar_offset = vec3(0.0);
uniform float triplanar_sharpness : hint_range(0.0, 150.0, 0.001) = 1.0;

uniform float shininess : hint_range(1.0, 256.0, 1.0) = 40.0;
uniform float direct_specular_intensity : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform bool mirror_enabled = false;
uniform float reflection_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform bool reflection_shadows_enabled = false;
// RTSceneManager switches this on only after the managed renderer is fully
// installed, at runtime and in the editor preview alike. Keeping it off makes
// the material useful during scene assembly, on unmanaged geometry, and after a
// recoverable tool-preview failure.
uniform bool rt_pipeline_active = false;
// Assigned transiently by RTSceneManager through RenderingServer. Zero means
// unmanaged; positive values index the compositor's material table.
uniform int rt_material_id = 0;
// Texture assignment, rather than a separate authored enable checkbox, owns
// map presence. RTSceneManager updates these implementation uniforms.
uniform bool rt_has_albedo_texture = false;
uniform bool rt_has_normal_texture = false;
instance uniform int rt_instance_id = 0;

// Distance fog, pushed by RTSceneManager while the raster fallback is installed
// and left disabled under hardware RT, where the compositor applies the same
// curve itself. Unmanaged geometry (shell grass) fades on exactly this ramp
// through its own subscription to distance_fog_changed, which is what keeps a
// prop, the terrain under it and the grass around it fading together.
// params: x=begin, y=end (> begin), z=curve, w=enabled.
uniform vec4 rt_fog_params = vec4(0.0, 1.0, 1.0, 0.0);
uniform vec3 rt_fog_color : source_color = vec3(0.0);

varying vec3 rt_triplanar_position;
varying vec3 rt_triplanar_weights;
// Written in fragment(), read in light(), so the direct specular lobe fades on
// the same ramp as the diffuse term instead of surviving as a highlight against
// flat fog.
varying float rt_fog_amount;


vec4 sample_triplanar(sampler2D map, vec3 weights, vec3 position) {
	// This axis order and X-projection flip match Godot 4.7 BaseMaterial3D.
	vec4 sampled = texture(map, position.xy) * weights.z;
	sampled += texture(map, position.xz) * weights.y;
	sampled += texture(map, position.zy * vec2(-1.0, 1.0)) * weights.x;
	return sampled;
}


vec3 get_triplanar_weights(vec3 mapping_normal, float sharpness) {
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


// Canonical Retro RT distance fog. Keep this function byte-identical in every
// copy: addons/retro_rt/shaders/rt_shadow_reflect.glsl,
// addons/retro_rt/shaders/BlinnPhong.gdshader,
// addons/procedural_terrain_grass/shaders/grass_shell.gdshader.
// Normative text: addons/retro_rt/docs/RT_PIPELINE.md, "Distance fog".
// params: x=begin, y=end (> begin), z=curve, w=enabled. distance is radial.
float rt_fog_factor(vec4 params, float view_distance) {
	if (params.w < 0.5) {
		return 0.0;
	}
	return pow(smoothstep(params.x, params.y, view_distance), params.z);
}


vec3 decode_open_gl_normal(vec3 encoded_normal) {
	vec2 tangent_xy = encoded_normal.rg * 2.0 - 1.0;
	// Bilinear filtering can move RG just outside the unit disk. Clamp it back
	// before reconstructing +Z, as Godot does for two-channel normal maps.
	tangent_xy *= inversesqrt(max(1.0, dot(tangent_xy, tangent_xy)));
	return vec3(tangent_xy, sqrt(max(1.0 - dot(tangent_xy, tangent_xy), 0.0)));
}


vec3 apply_uv_normal(
		vec3 encoded_normal,
		vec3 geometric_normal,
		vec3 view_position,
		vec2 surface_uv) {
	vec3 position_dx = dFdx(view_position);
	vec3 position_dy = dFdy(view_position);
	vec2 uv_dx = dFdx(surface_uv);
	vec2 uv_dy = dFdy(surface_uv);
	float determinant = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;
	if (abs(determinant) <= 1e-8) {
		return geometric_normal;
	}

	vec3 tangent = (position_dx * uv_dy.y - position_dy * uv_dx.y) / determinant;
	vec3 bitangent_reference = (position_dy * uv_dx.x - position_dx * uv_dy.x) / determinant;
	tangent -= geometric_normal * dot(geometric_normal, tangent);
	float tangent_length_squared = dot(tangent, tangent);
	float bitangent_length_squared = dot(bitangent_reference, bitangent_reference);
	if (tangent_length_squared <= 1e-12 || bitangent_length_squared <= 1e-12) {
		return geometric_normal;
	}

	tangent *= inversesqrt(tangent_length_squared);
	vec3 perpendicular = cross(geometric_normal, tangent);
	float handedness_measure = dot(perpendicular, bitangent_reference);
	if (abs(handedness_measure) <= 1e-8) {
		return geometric_normal;
	}
	vec3 bitangent = perpendicular * (handedness_measure < 0.0 ? -1.0 : 1.0);
	vec3 tangent_normal = decode_open_gl_normal(encoded_normal);
	return normalize(
		tangent * tangent_normal.x
		+ bitangent * tangent_normal.y
		+ geometric_normal * tangent_normal.z);
}


void vertex() {
	if (triplanar_enabled) {
		vec3 mapping_normal = triplanar_world_space ? MODEL_NORMAL_MATRIX * NORMAL : NORMAL;
		vec3 mapping_position = triplanar_world_space
			? (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz
			: VERTEX;

		// BaseMaterial3D synthesizes this same basis so triplanar normal maps need
		// neither UVs nor imported tangents.
		vec3 generated_tangent = vec3(0.0, 0.0, -1.0) * abs(mapping_normal.x);
		generated_tangent += vec3(1.0, 0.0, 0.0) * abs(mapping_normal.y);
		generated_tangent += vec3(1.0, 0.0, 0.0) * abs(mapping_normal.z);
		vec3 generated_binormal = vec3(0.0, 1.0, 0.0) * abs(mapping_normal.x);
		generated_binormal += vec3(0.0, 0.0, -1.0) * abs(mapping_normal.y);
		generated_binormal += vec3(0.0, 1.0, 0.0) * abs(mapping_normal.z);
		if (triplanar_world_space) {
			TANGENT = inverse(MODEL_NORMAL_MATRIX) * normalize(generated_tangent);
			BINORMAL = inverse(MODEL_NORMAL_MATRIX) * normalize(generated_binormal);
		} else {
			TANGENT = normalize(generated_tangent);
			BINORMAL = normalize(generated_binormal);
		}

		rt_triplanar_weights = get_triplanar_weights(
			mapping_normal, triplanar_sharpness);
		rt_triplanar_position = (mapping_position * triplanar_scale + triplanar_offset)
			* vec3(1.0, -1.0, 1.0);
	}
}


vec3 encode_rt_visibility_id(uint material_id, uint instance_id) {
	// R16F stores every integer through 2048 exactly. Blue's upper half is a
	// sentinel, leaving 21 exact bits for a one-based mesh-instance ID.
	return vec3(
		float(material_id),
		float(instance_id & 2047u),
		float(1024u + ((instance_id >> 11u) & 1023u)));
}


void fragment() {
	vec3 sampled_albedo = vec3(1.0);
	if (rt_has_albedo_texture || !rt_pipeline_active) {
		sampled_albedo = triplanar_enabled
			? sample_triplanar(albedo_texture, rt_triplanar_weights, rt_triplanar_position).rgb
			: texture(albedo_texture, UV).rgb;
	}
	if (vertex_color_enabled) {
		sampled_albedo *= COLOR.rgb;
	}
	vec3 tinted_albedo = diffuse_color.rgb * sampled_albedo;
	// VERTEX is view space in fragment(), so its length is the radial distance
	// the canonical curve is defined against. Fog is never applied while the
	// compositor owns the pixel: there ALBEDO and EMISSION are ID/albedo
	// transport, not colour, and the RT pass fogs its own result.
	rt_fog_amount = rt_pipeline_active
		? 0.0
		: rt_fog_factor(rt_fog_params, length(VERTEX));
	float rt_fog_survival = 1.0 - rt_fog_amount;

	// Managed hardware pixels transport albedo through emission so native
	// environment lighting cannot contaminate the compositor's source value.
	// Scaling standalone albedo by the fog survival fades every light Godot
	// evaluates against it, which is the same identity shell grass relies on.
	ALBEDO = rt_pipeline_active ? vec3(0.0) : tinted_albedo * rt_fog_survival;

	// For managed hardware pixels the compositor needs the sampled albedo in
	// scene color to evaluate ambient and direct diffuse terms. It always
	// replaces this carrier later. Outside RTSceneManager, preserve the normal
	// standalone material appearance and add the fog radiance back here, which
	// is exactly mix(lit, rt_fog_color, fog).
	EMISSION = rt_pipeline_active && rt_material_id > 0
		? tinted_albedo
		: ((tinted_albedo * ambient_light.rgb) + emission_color.rgb) * rt_fog_survival
			+ rt_fog_color * rt_fog_amount;

	// A flat NORMAL_MAP leaves NORMAL unchanged. Triplanar mode uses Godot's
	// synthesized basis; UV0 mode derives a per-fragment TBN and writes the
	// resulting view-space normal directly, with a safe degenerate-UV fallback.
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);
	NORMAL_MAP_DEPTH = 1.0;
	if (rt_has_normal_texture || !rt_pipeline_active) {
		if (triplanar_enabled) {
			NORMAL_MAP = sample_triplanar(
				normal_texture,
				rt_triplanar_weights,
				rt_triplanar_position).rgb;
		} else {
			NORMAL = apply_uv_normal(
				texture(normal_texture, UV).rgb,
				normalize(NORMAL),
				VERTEX,
				UV);
		}
	}

	// Disable Godot's environment/SSR/probe PBR contribution. The RT pass owns
	// reflections and evaluates all authored direct lights itself.
	// Outside the RT pipeline this is what Godot's screen-space reflections
	// read, so it is the raster fallback's mirror strength. It fades with fog
	// for the same reason the specular lobe does.
	SPECULAR = !rt_pipeline_active && mirror_enabled
		? clamp(reflection_strength, 0.0, 1.0) * rt_fog_survival
		: 0.0;
	METALLIC = 0.0;
	// The roughness byte is project-owned transport for the per-pixel reflection
	// blend. Zero strength encodes as roughness 1 and launches no reflection ray.
	float active_reflection_strength = mirror_enabled
		? floor(clamp(reflection_strength, 0.0, 1.0) * 127.0 + 0.5) / 127.0
		: 0.0;
	ROUGHNESS = rt_pipeline_active
		? 1.0 - active_reflection_strength
		: (mirror_enabled ? 0.0 : 1.0);
}


void light() {
	bool is_rt_carrier = LIGHT_IS_DIRECTIONAL
		&& LIGHT_COLOR.r > 100000.0
		&& LIGHT_COLOR.g < 0.001
		&& LIGHT_COLOR.b < 0.001;
	if (!rt_pipeline_active) {
		// Ordinary standalone Blinn-Phong preview. ATTENUATION retains native
		// shadowing here; the managed RT path suppresses native authored-light
		// work instead.
		if (!is_rt_carrier) {
			float normal_dot_light = max(dot(NORMAL, LIGHT), 0.0);
			if (normal_dot_light > 0.0) {
				vec3 radiance = LIGHT_COLOR * ATTENUATION;
				DIFFUSE_LIGHT += ALBEDO * normal_dot_light * radiance;
				vec3 half_vector = normalize(VIEW + LIGHT);
				float blinn = pow(max(dot(NORMAL, half_vector), 0.0), shininess);
				SPECULAR_LIGHT += specular_color.rgb
					* blinn
					* direct_specular_intensity
					* radiance
					* (1.0 - rt_fog_amount);
			}
		}
	} else if (is_rt_carrier) {
		// A transient, project-owned red HDR DirectionalLight invokes this branch
		// exactly once. The separate-specular target becomes a 24-bit material-ID
		// carrier until POST_SKY, where the RT dispatch replaces it with evaluated
		// direct lighting. Authored lights are deliberately evaluated there instead.
		SPECULAR_LIGHT += encode_rt_visibility_id(
			uint(max(rt_material_id, 0)),
			uint(max(rt_instance_id, 0)));
	}
}
