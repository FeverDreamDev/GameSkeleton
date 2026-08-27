shader_type sky;

// Bake-only twin of the sky dome, for RenderingServer.sky_bake_panorama().
//
// Nothing renders with this: it exists because that API only accepts a Sky, and
// a Sky only accepts shader_type sky. DayNightCycle3D drives it with exactly
// the uniforms it just pushed to the dome, so the panorama a mirror reflects is
// the same picture the dome is drawing.

#include "res://addons/day_night_cycle/shaders/day_night_sky_common.gdshaderinc"


// One texel of the 256x128 panorama DayNightCycle3D bakes, in radians. The dome
// reads this off a screen-space derivative, which a sky shader has no view to
// take; the panorama is a fixed size in the same add-on, so it can simply be
// stated. It is far coarser than a star is wide, which is the point: passing it
// lets the star field average itself down instead of sparkling in the mirror.
const float PANORAMA_TEXEL_ANGLE = 6.2831853 / 256.0;


void sky() {
	COLOR = dnc_sky_color(EYEDIR, POSITION, PANORAMA_TEXEL_ANGLE);
}
