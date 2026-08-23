shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform float u_roughness = 0.95;
uniform float u_specular = 0.05;

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = u_roughness;
	SPECULAR = u_specular;
}
