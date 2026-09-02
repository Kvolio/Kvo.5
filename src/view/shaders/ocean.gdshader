shader_type canvas_item;

// Procedural sea for the tactical view.
//
// Drawn as a full-screen rect in a CanvasLayer rather than as geometry in the world,
// so its cost is one pass over the visible pixels no matter how large the map is —
// a 200 km battlefield renders exactly as cheaply as a 5 km one.
//
// The camera transform is passed in as uniforms so the shader can recover the world
// position of each pixel. That is what makes the swell stay locked to the water when
// the camera pans, instead of sliding around with the screen.

uniform vec2 camera_position = vec2(0.0);
uniform float camera_zoom = 1.0;
uniform vec2 viewport_size = vec2(1600.0, 900.0);
uniform float time_seconds = 0.0;

uniform vec3 deep_colour : source_color = vec3(0.043, 0.086, 0.145);
uniform vec3 shallow_colour : source_color = vec3(0.086, 0.169, 0.231);
uniform vec3 crest_colour : source_color = vec3(0.239, 0.361, 0.427);

// Sea state 0-9. Drives wave amplitude and how tightly the crests bunch up.
uniform float sea_state : hint_range(0.0, 9.0) = 3.0;
uniform vec2 wind_direction = vec2(1.0, 0.0);

// Wavelength of the primary swell in metres. Real ocean swell runs 50-150 m, and
// keeping this in world units means the sea does not change scale when zooming.
uniform float swell_wavelength = 90.0;

float wave(vec2 world, vec2 direction, float wavelength, float phase_speed, float t) {
	float k = 6.28318530718 / max(wavelength, 1.0);
	return sin(dot(world, normalize(direction)) * k + t * phase_speed);
}

// Fade a wave train out as it approaches the pixel grid.
//
// Zoomed out to a 40 km battlefield, a 90 m swell is a fraction of a pixel across.
// Sampling it there produces moire rather than sea, so each train is faded as its
// on-screen wavelength drops towards a few pixels. This is the shader equivalent of
// a mipmap, and without it the water shimmers with a false pattern the moment the
// camera pulls back.
float detail_fade(float wavelength) {
	float pixels_per_wave = wavelength * camera_zoom;
	return smoothstep(3.0, 12.0, pixels_per_wave);
}

void fragment() {
	// Screen pixel -> world metres, undoing the camera transform.
	vec2 screen_offset = (UV - vec2(0.5)) * viewport_size;
	vec2 world = camera_position + screen_offset / max(camera_zoom, 0.00001);

	float amplitude = clamp(sea_state / 9.0, 0.0, 1.0);
	vec2 wind = normalize(wind_direction + vec2(0.0001));
	vec2 cross_wind = vec2(-wind.y, wind.x);

	// Three superimposed trains at different scales and slight angles: a long
	// primary swell, a shorter secondary, and a cross sea. Summed they avoid the
	// obvious repeating corduroy a single sine gives.
	float primary = swell_wavelength;
	float secondary = swell_wavelength * 0.43;
	float chop = swell_wavelength * 0.17;

	float h = wave(world, wind, primary, 0.9, time_seconds) * 0.55 * detail_fade(primary);
	h += wave(world, normalize(wind + cross_wind * 0.35), secondary, 1.5, time_seconds)
		* 0.3 * detail_fade(secondary);
	h += wave(world, normalize(wind * 0.6 + cross_wind), chop, 2.4, time_seconds)
		* 0.15 * detail_fade(chop);

	float lit = h * amplitude;
	vec3 colour = mix(deep_colour, shallow_colour, clamp(lit * 0.5 + 0.5, 0.0, 1.0));

	// Crests only catch the light in a heavier sea; a flat calm stays glassy.
	float crest = smoothstep(0.55, 0.95, lit) * amplitude;
	colour = mix(colour, crest_colour, crest * 0.5);

	COLOR = vec4(colour, 1.0);
}
