shader_type sky;

// Bake-only twin of the sky dome, for RenderingServer.sky_bake_panorama().
//
// Nothing renders with this: it exists because that API only accepts a Sky, and
// a Sky only accepts shader_type sky. DayNightCycle3D drives it with exactly
// the uniforms it just pushed to the dome, so the panorama a mirror reflects is
// the same picture the dome is drawing.

#include "res://addons/day_night_cycle/shaders/day_night_sky_common.gdshaderinc"


void sky() {
	COLOR = dnc_sky_color(EYEDIR, POSITION);
}
