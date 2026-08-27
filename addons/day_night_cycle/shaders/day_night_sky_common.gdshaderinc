// Shared body of the day_night_cycle sky.
//
// Two shaders include this. The dome is `shader_type spatial`, because a sky
// drawn as geometry composites into the same scene capture as everything else
// and is anti-aliased and graded with it. The bake is `shader_type sky`,
// because RenderingServer.sky_bake_panorama() only accepts a Sky, and that
// panorama is what a Retro RT mirror reflects.
//
// Neither of those can be expressed as the other, so the picture itself lives
// here and each shader is a three-line wrapper that supplies a view ray.

// "Environment and reflection misses".
//
// The dome is unmanaged geometry: it is invisible to shadow and reflection
// rays, and it is never fogged. It reads no TIME; every animated value arrives
// as a uniform, so the image is a pure function of the state DayNightCycle3D
// publishes and a warmup or capture frame is reproducible.

// Vertical gradient. Authored sRGB, matching the rest of the project.
uniform vec3 u_zenith_color : source_color = vec3(0.16, 0.33, 0.62);
uniform vec3 u_horizon_color : source_color = vec3(0.55, 0.68, 0.82);
uniform vec3 u_ground_color : source_color = vec3(0.20, 0.22, 0.24);
// Higher values keep the horizon band tight against the skyline.
uniform float u_horizon_falloff : hint_range(0.2, 8.0, 0.01) = 1.7;
uniform float u_ground_falloff : hint_range(0.2, 16.0, 0.01) = 5.0;

// Sun. u_sun_direction points from the viewer towards the sun.
uniform vec3 u_sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 u_sun_color : source_color = vec3(1.0, 0.96, 0.86);
uniform float u_sun_angular_radius : hint_range(0.002, 0.30, 0.001) = 0.035;
uniform float u_sun_intensity : hint_range(0.0, 8.0, 0.01) = 2.4;
uniform vec3 u_sun_glow_color : source_color = vec3(1.0, 0.72, 0.42);
uniform float u_sun_glow_intensity : hint_range(0.0, 4.0, 0.01) = 0.5;
uniform float u_sun_glow_falloff : hint_range(1.0, 512.0, 1.0) = 18.0;

// Moon. u_moon_direction points from the viewer towards the moon.
uniform vec3 u_moon_direction = vec3(0.0, -1.0, 0.0);
uniform vec3 u_moon_color : source_color = vec3(0.92, 0.94, 1.0);
uniform float u_moon_angular_radius : hint_range(0.002, 0.30, 0.001) = 0.045;
uniform float u_moon_intensity : hint_range(0.0, 4.0, 0.01) = 1.0;
// 0.0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
uniform float u_moon_phase : hint_range(0.0, 1.0, 0.001) = 0.5;
// Sunlight bounced off the planet onto the dark limb.
uniform float u_moon_earthshine : hint_range(0.0, 0.5, 0.001) = 0.05;
uniform float u_moon_glow_intensity : hint_range(0.0, 2.0, 0.01) = 0.10;

// Stars. Seeded per night by DayNightCycle3D, so no two nights match.
uniform float u_star_intensity : hint_range(0.0, 4.0, 0.01) = 0.0;
uniform float u_star_density : hint_range(4.0, 400.0, 1.0) = 150.0;
uniform float u_star_seed = 0.0;
uniform float u_star_size : hint_range(0.005, 0.5, 0.001) = 0.055;
// Fraction of grid cells that hold a star at all.
uniform float u_star_coverage : hint_range(0.0, 1.0, 0.01) = 0.42;
uniform float u_star_twinkle_time = 0.0;
uniform float u_star_twinkle_amount : hint_range(0.0, 1.0, 0.01) = 0.35;
// Stars fade out before they reach the skyline, where haze would drown them.
uniform float u_star_horizon_fade : hint_range(0.0, 1.0, 0.01) = 0.13;

// Cloud layer. A flat plane of tiling noise at u_cloud_params.x metres, sampled
// by intersecting the eye ray with it, which is what gives the layer parallax as
// the viewer moves instead of pinning it to the dome.
uniform vec4 u_cloud_params = vec4(260.0, 0.0, 0.5, 0.17);
uniform vec4 u_cloud_motion = vec4(0.0, 0.0, 0.0, 0.0);

// Colour of a fully lit cloud face, and of a fully shaded one. The shade colour
// is the horizon, so an overcast sky settles towards the haze it sits in.
uniform vec3 u_cloud_lit_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 u_cloud_shade_color : source_color = vec3(0.55, 0.68, 0.82);
uniform float u_cloud_shade : hint_range(0.0, 1.0, 0.01) = 0.45;
// Distance over which the layer melts into the horizon haze. A flat plane would
// otherwise compress into a hard line at the skyline.
uniform float u_cloud_fade_distance = 5200.0;
uniform vec3 u_cloud_sun_direction = vec3(0.0, 1.0, 0.0);



// The cloud layer. This is now the only copy: the field used to be duplicated
// into the grass and both Retro RT shaders so every surface could resolve its
// own shadow from it, and that shadow has been removed. Clouds are drawn here
// and nowhere else.
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


vec3 hash33(vec3 p) {
	p = vec3(
		dot(p, vec3(127.1, 311.7, 74.7)),
		dot(p, vec3(269.5, 183.3, 246.1)),
		dot(p, vec3(113.5, 271.9, 124.6)));
	return fract(sin(p) * 43758.5453123);
}


// Stable, pole-free 2D cells: project the direction onto its dominant cube
// face. A latitude/longitude grid would bunch stars into dense knots at the
// zenith and nadir, which is exactly where the dome is most visible.
void star_cell_space(vec3 direction, out vec2 face_uv, out float face_id) {
	vec3 magnitude = abs(direction);
	if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
		face_uv = direction.zy / magnitude.x;
		face_id = direction.x > 0.0 ? 0.0 : 1.0;
	} else if (magnitude.y >= magnitude.z) {
		face_uv = direction.xz / magnitude.y;
		face_id = direction.y > 0.0 ? 2.0 : 3.0;
	} else {
		face_uv = direction.xy / magnitude.z;
		face_id = direction.z > 0.0 ? 4.0 : 5.0;
	}
}


vec3 star_field(vec3 direction) {
	vec2 face_uv;
	float face_id;
	star_cell_space(direction, face_uv, face_id);

	vec2 grid = face_uv * u_star_density;
	vec2 cell = floor(grid);
	vec2 local = fract(grid);

	vec3 accumulated = vec3(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 neighbour = vec2(float(x), float(y));
			vec3 random = hash33(vec3(cell + neighbour, face_id * 37.0 + u_star_seed));
			if (random.z > u_star_coverage) {
				continue;
			}
			// Reuse the same three numbers for placement, size and colour by
			// decorrelating them once. A second hash per cell would double the
			// cost of the only loop this shader runs per pixel.
			vec3 traits = fract(random * vec3(97.3, 61.7, 43.1) + random.zxy);
			vec2 star_position = neighbour + vec2(random.x, random.y);
			vec2 to_star = local - star_position;

			float magnitude = mix(0.18, 1.0, traits.x * traits.x);
			float radius = u_star_size * mix(0.55, 1.15, traits.y);
			// The core smoothstep below is exactly zero once the distance reaches
			// the radius, so cells that far out contribute nothing. Rejecting them
			// on the squared distance skips the root, the twinkle sine and the
			// tint mix without touching any pixel a star actually covers. Compare
			// squared -- feeding squared values to the smoothstep itself would
			// bend the falloff and reshape every star.
			float distance_squared = dot(to_star, to_star);
			if (distance_squared >= radius * radius) {
				continue;
			}
			float distance_to_star = sqrt(distance_squared);
			// A solid core inside a soft skirt. A true point would alias into a
			// crawling speck under SMAA; a few pixels of skirt is what makes the
			// field hold still while the view turns.
			float core = smoothstep(radius, radius * 0.2, distance_to_star);

			float twinkle = 1.0 - u_star_twinkle_amount * 0.5 * (1.0 - sin(
				u_star_twinkle_time * mix(0.6, 2.1, traits.z) + traits.x * 6.2831853));
			vec3 tint = mix(vec3(1.0, 0.88, 0.74), vec3(0.76, 0.86, 1.0), traits.z);
			accumulated += tint * (core * magnitude * twinkle);
		}
	}
	return accumulated;
}


// Orthonormal frame around a body direction, so its disc can be shaded in its
// own 2D space. Falls back to a different reference axis overhead, where the
// default one would be degenerate.
void body_basis(vec3 forward, out vec3 right, out vec3 up) {
	vec3 reference = abs(forward.y) > 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	right = normalize(cross(reference, forward));
	up = cross(forward, right);
}



// The whole picture, as a pure function of a view ray and where it starts.
// Both wrappers call exactly this, so the dome and the baked panorama can never
// show different weather.
vec3 dnc_sky_color(vec3 direction, vec3 camera_position) {
	float height = direction.y;

	// Vertical gradient, with the lower half kept dark so the dome reads as a
	// horizon rather than as a mirrored sky when the camera looks down.
	vec3 sky = mix(
		u_horizon_color,
		u_zenith_color,
		pow(clamp(height, 0.0, 1.0), 1.0 / max(u_horizon_falloff, 0.01)));
	sky = mix(
		sky,
		u_ground_color,
		smoothstep(0.0, 1.0, clamp(-height * u_ground_falloff, 0.0, 1.0)));

	float sun_alignment = clamp(dot(direction, u_sun_direction), 0.0, 1.0);
	sky += u_sun_glow_color * (pow(sun_alignment, u_sun_glow_falloff) * u_sun_glow_intensity);

	float moon_alignment = clamp(dot(direction, u_moon_direction), 0.0, 1.0);
	sky += u_moon_color * (pow(moon_alignment, 220.0) * u_moon_glow_intensity);

	if (u_star_intensity > 0.0) {
		float horizon_mask = smoothstep(0.0, max(u_star_horizon_fade, 0.001), height);
		// The mask is zero across the whole lower hemisphere, and the dome is a
		// box centred on the camera, so without this gate every fragment below
		// the horizon ran the nine-cell field only to be multiplied out by zero.
		if (horizon_mask > 0.0) {
			// Stars go in before the discs and the glow terms have already been
			// added, so a bright sky washes them out without a second blend.
			sky += star_field(direction) * (u_star_intensity * horizon_mask);
		}
	}

	// The soft edge is a fixed fraction of the radius, so shrinking the sun
	// does not turn it into an aliased dot.
	float sun_soft = u_sun_angular_radius * 0.35;
	float sun_disc = smoothstep(
		cos(u_sun_angular_radius + sun_soft),
		cos(max(u_sun_angular_radius - sun_soft, 0.0)),
		dot(direction, u_sun_direction));
	sky = mix(sky, u_sun_color * u_sun_intensity, sun_disc);

	// The moon is shaded in its own tangent frame so the terminator can sweep
	// across it as the phase advances. The alignment gate keeps that work off
	// the 99.9% of the dome the moon does not cover.
	if (moon_alignment > 0.9) {
		vec3 moon_right;
		vec3 moon_up;
		body_basis(u_moon_direction, moon_right, moon_up);
		vec2 disc = vec2(dot(direction, moon_right), dot(direction, moon_up))
			/ max(u_moon_angular_radius, 0.0001);
		float moon_mask = smoothstep(1.10, 0.90, length(disc));
		if (moon_mask > 0.0) {
			// The terminator is the projection of the day/night great circle,
			// x = cos(phase) * sqrt(1 - y*y). Mirroring x past half phase turns
			// waxing into waning without a second equation.
			float mirrored_x = u_moon_phase > 0.5 ? -disc.x : disc.x;
			float terminator = cos(u_moon_phase * 6.2831853)
				* sqrt(max(0.0, 1.0 - disc.y * disc.y));
			float lit = smoothstep(terminator - 0.06, terminator + 0.06, mirrored_x);
			vec3 moon_surface = u_moon_color
				* u_moon_intensity
				* mix(u_moon_earthshine, 1.0, lit);
			sky = mix(sky, moon_surface, moon_mask);
		}
	}

	// Cloud layer, composited over the sky and under nothing. Intersecting the
	// eye ray with the plane rather than painting the clouds onto the dome is
	// what gives them parallax, and it is the same intersection every surface
	// does to resolve its own shadow.
	if (direction.y > 0.005 && u_cloud_params.y > 0.0) {
		float travel = (u_cloud_params.x - camera_position.y) / direction.y;
		if (travel > 0.0) {
			// The layer is flat, so distance grows without bound towards the
			// skyline. Fading it out there is what keeps it from collapsing into a
			// hard band across the horizon. The factor depends on nothing but the
			// travel distance, so resolving it here -- rather than after both
			// density taps as it used to be -- lets the whole band beyond the fade
			// distance skip eight octaves of noise it could only multiply away.
			float distance_fade = 1.0 - smoothstep(
				u_cloud_fade_distance * 0.3, u_cloud_fade_distance, travel);
			if (distance_fade > 0.0) {
				vec2 hit = camera_position.xz + direction.xz * travel;
				// A flat layer stretches without bound towards the skyline, so the
				// noise has to be filtered by how far away it is or it breaks into
				// straight aliased streaks long before the distance fade reaches it.
				float edge_scale = 1.0 + travel * u_cloud_params.y * 0.35;
				float density = dnc_cloud_density(
					u_cloud_params, u_cloud_motion, hit, edge_scale);
				// Clear sky is the common case: the coverage threshold has already
				// zeroed the density, and a zero-weight mix cannot tint anything, so
				// the sun tap and the shading below would be discarded in full.
				if (density > 0.0) {
					// One extra tap towards the sun. Where the layer thickens in that
					// direction the near face is turned away from the light, which is all
					// the shading a flat layer needs to stop reading as a decal.
					vec2 sun_step = u_cloud_sun_direction.xz * (0.03 / max(u_cloud_params.y, 0.00001));
					float towards_sun = dnc_cloud_density(
						u_cloud_params, u_cloud_motion, hit + sun_step, edge_scale);
					float slope = clamp((towards_sun - density) * 1.6 + 0.45, 0.0, 1.0);
					vec3 cloud_color = mix(
						u_cloud_lit_color, u_cloud_shade_color, u_cloud_shade * slope);
					density *= distance_fade;
					sky = mix(sky, cloud_color, density);
				}
			}
		}
	}
	return sky;
}
