shader_type spatial;
render_mode unshaded, cull_front, fog_disabled;

// Sky dome for the day_night_cycle add-on.
//
// The picture lives in the shared include; this wrapper only supplies the view
// ray. Drawing the sky as geometry rather than as a Sky resource is deliberate:
// RTSceneManager bakes a BG_SKY Environment into a reflection panorama on every
// tracked resource change, through RenderingServer.force_sync() plus
// sky_bake_panorama(), so an animated Sky would stall the pipeline several
// times a second. Keeping the Environment on BG_COLOR takes the no-bake branch,
// and DayNightCycle3D holds Environment.background_color equal to
// u_horizon_color so the renderer's distance fog resolves to exactly the band
// the terrain meets.
//
// The mirror still reflects this sky: DayNightCycle3D bakes the same include
// through day_night_sky_bake.gdshader on its own schedule and hands the result
// to RTSceneManager.set_reflection_panorama().
//
// The dome is unmanaged geometry, so it is invisible to shadow and reflection
// rays and is never fogged.

#include "res://addons/day_night_cycle/shaders/day_night_sky_common.gdshaderinc"

varying vec3 v_world_position;


void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	vec3 camera_position = INV_VIEW_MATRIX[3].xyz;
	vec3 direction = normalize(v_world_position - camera_position);
	// Angular width of one pixel, which the star field needs so it never draws a
	// star narrower than the pixel sampling it. Taken from the view ray itself
	// because that is continuous everywhere on the dome; the star field's own
	// cube-face coordinates are not, and a derivative across a face boundary
	// would print a cross over the sky.
	ALBEDO = dnc_sky_color(direction, camera_position, length(fwidth(direction)));
}
