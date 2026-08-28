# Day Night Cycle

A dynamic day/night cycle for Godot 4.7+: a sun and a moon that rise and set on
a tilted arc and drive the directional lighting, a procedural sky with a fresh
star field every night, and a drifting cloud layer overhead. The clouds are
beneath it — grass, terrain and props alike.

One node does all of it. Drop a `DayNightCycle3D` into a level in place of its
static `DirectionalLight3D`, point it at a `WorldEnvironment`, and press play.

No autoloads, no input actions, no project settings, no imported assets. Two
global classes: `DayNightCycle3D` and `DayNightPalette`.

## Install

1. Copy the whole `addons/day_night_cycle` folder into your project.
2. Enable **Day Night Cycle** under **Project Settings > Plugins**.
3. Open `addons/day_night_cycle/examples/DayNightExample.tscn` and press play.

Do not rename the folder. Script and `#include` paths inside the add-on are
absolute `res://addons/day_night_cycle/...` strings.

## Requirements

- **Godot 4.7 or newer.**
- **Retro RT is optional.** The sky, the stars, the sun, the moon and the clouds
  all work without it. Retro RT is only needed for the one thing it owns: the sky
  reflected in a mirror.
- The effective `Environment` must use `BG_COLOR`. See **Why there is no Sky
  resource**; this is a deliberate design constraint, not an oversight.

## Quick start

```
Level (Node3D)
├─ WorldEnvironment            BG_COLOR, Linear tonemap at exposure 1.0
├─ DayNightCycle3D             the whole add-on
│   ├─ SunLight                built at runtime
│   ├─ MoonLight               built at runtime
│   └─ SkyDome                 built at runtime, follows the camera
└─ ... your geometry
```

`world_environment_path` defaults to `../WorldEnvironment`, so the layout above
needs no configuration. The camera is found through the viewport unless
`camera_path` names one, and the renderer is found by searching the tree unless
`rt_scene_manager_path` names one.

## The cloud layer

Clouds are **one flat plane of fractal noise** at `cloud_altitude`, drawn by
intersecting the eye ray with that plane. Intersecting rather than painting is
what gives the layer parallax as you move, instead of pinning it to the dome.

Nothing is added to any acceleration structure, and a moving cloud never dirties
a TLAS.

The layer **casts no shadow on the world**. Because it is a plane rather than a
volume, any surface once resolved its own shadow analytically from the same
noise, and the field was duplicated into the grass and both Retro RT shaders to
let it. That is gone: it read as a soft modern lighting effect against a
deliberately hard-edged retro image, and it was the most expensive term in the
grass shader. Clouds are now drawn by the sky and nowhere else, which is why
`dnc_cloud_shadow()` no longer exists and the field has exactly one copy.

The contract is two vectors, and the sky reads exactly these:

| | x | y | z | w |
| --- | --- | --- | --- | --- |
| `cloud_params` | altitude | 1 / tile size in metres, zero disables | coverage threshold | edge softness |
| `cloud_motion` | scroll x | seed | scroll z | unused, kept at zero |

The functions that consume them live in `dnc_cloud_*`, in one place:
`addons/day_night_cycle/shaders/day_night_sky_common.gdshaderinc`. There is a
second implementation, in GDScript, on `DayNightCycle3D` itself: it backs
`get_sun_occlusion()` so gameplay can ask whether the player is under a cloud and
get the same answer the sky drew.

Three details in that shared code are load-bearing, all of them found by
chasing straight lines across the sky, and all of them easy to undo by accident:

- **The hash scales its three components by three *distinct* constants.** The
  input is two-dimensional, so scaling every component by the same value leaves
  the third equal to the first, and the gradients it produces come out
  correlated. That draws long straight streaks that converge on the horizon —
  the layer is a flat plane, so any correlated direction in the noise projects
  into a line.
- **The field is gradient noise, not value noise.** Value noise is built from
  per-cell scalars and its iso-contours line up with the lattice, so a coverage
  threshold across it prints cell edges.
- **The hash never calls `sin`, and the interpolation is quintic.** Cloud cells
  run into the hundreds a few kilometres out, where `fract(sin(dot(...)))`
  degenerates into axis-aligned rectangles; and a cubic fade leaves a
  discontinuous second derivative at every lattice boundary that a threshold
  turns into creases.

Octaves are rotated as well as scaled, so no two share a lattice orientation
and none of them can reinforce into a visible direction. The per-day seed is
kept inside one unit because the hash adds it before a `fract()`.

`cloud_world_size` also matters more than it looks: the first octave has one
lattice cell per tile, so making it much larger than the sky is wide turns that
single cell into a visible facet.

### The layer at night

The moon `DirectionalLight3D` is deliberately far brighter than a real one — see
**The palette** — because it is the only thing lighting the ground once the sun
is down. The sky must not inherit that figure. Taking it whole lit the deck to
nearly full moon colour against an almost black sky, which read as daylight
clouds on a night background and left no room for the stars.

`cloud_moonlight`, default `0.30`, is the share of the moon's energy the cloud
layer takes instead. It lands the layer just above where the presentation grade
crushes to black, so the clouds stay a faint drift the stars show around. The
cliff there is steep: the grade's contrast is applied around a 0.5 pivot, which
puts everything under roughly `0.27` sRGB at exactly zero, so `0.25` is an
invisible layer and `0.35` is a clearly present one. Daylight is untouched — the
term only applies once the moon is the brighter of the two bodies.

## The star field

Stars are cells on a cube projection of the view ray, which makes them a pure
function of direction: the field cannot parallax, shear or drift as the camera
moves, and the layout is re-rolled once per day from `world_seed`.

**A star is never drawn narrower than the pixel that samples it.** At any sane
resolution the authored size is well under a pixel, and drawing one honestly
means whether it lights up at all depends on where the pixel centre happened to
fall inside it. Most stars are missed outright, the survivors change as the view
turns, and the sky looks nearly empty — which is not twinkle, it is the field
being resampled. So the shader takes the angular width of a pixel from the
screen-space derivative of the view ray, widens any star below it, and divides
its light by the area it gained. The flux is unchanged, every star resolves, and
a 0.02° yaw — about a third of a pixel — moves six times fewer pixels than it
did before.

That footprint comes from the view ray rather than from `fwidth()` of the star
field's own cube-face coordinates, for exactly the reason the grass shader takes
its footprint from the world position: face coordinates jump at every cube face
boundary, and a derivative sampled across the jump comes back enormous, which
would print a bright cross over the sky. The bake shader has no view to
differentiate and states the panorama's texel angle instead, which is far
coarser than a star — so the mirror averages the field away rather than
sparkling.

`star_size` is a floor rather than a fine control: authoring it below a pixel
does not buy sharper stars, it buys fainter ones. `star_density` and
`star_coverage` together set how many are on screen; the defaults put roughly a
thousand in a 75° view, and the coverage is kept low over a fine grid on purpose
because a dense field over a coarse one visibly puts one star in every box.

## Why there is no Sky resource

`RTSceneManager` bakes a `BG_SKY` background into a reflection panorama on every
tracked resource change, through `RenderingServer.force_sync()` plus
`sky_bake_panorama()`. **Measured at ~4 ms per bake**, and the cost is the sync,
not the resolution — 512x256 and 128x64 both take the same. An animated `Sky`
would drop a frame several times a second.

A flat `BG_COLOR` background takes the no-bake branch instead, so this add-on
paints the sky on a camera-following dome mesh and keeps
`Environment.background_color` equal to the dome's horizon colour. The renderer
resolves its distance fog to exactly that value, so terrain fades into the band
it meets with no seam, and a capture of the shipped level reports
`environment_bakes = 0` for the whole run.

## Mirrors

That leaves one thing the flat branch cannot supply: something for a mirror to
reflect. Retro RT resolves a reflection miss against the Environment, which is
now a flat colour.

So the sky is baked **separately**, off a `Sky` that lives in a private 4x4
`SubViewport` with its own world, and handed to the renderer through
`RTSceneManager.set_reflection_panorama()`. That replaces the reflection-miss
radiance only: `fallback_linear` stays the flat horizon, so fog and the visible
background remain exact and free, and only the mirror pays.

This is a hardware-RT path: it exists because a traced reflection ray can miss.
Under Retro RT's raster fallback there are no reflection rays — mirrors are
screen-space — so the bake is simply unused, and the panorama handoff is a
no-op rather than an error.

`day_night_sky_bake.gdshader` is a `shader_type sky` twin of the dome that
`#include`s the same body, so the panorama is the same picture the dome draws.
Neither shader type can be expressed as the other — `sky_bake_panorama()` only
accepts a `Sky`, and a dome drawn as geometry is what composites into the scene
capture and gets anti-aliased and graded with everything else.

Two behaviours of that API are not optional and are why the code looks the way
it does: a `Sky` that no `Environment` is using bakes **solid black**, and after
a change it returns the *previous* sky for a couple of frames.

Rebakes are throttled by how far the sun has actually moved
(`reflection_sun_step_degrees`, default 8°), not on a timer. A reflection a few
degrees out of date is not visible in a curved mirror.

**What a mirror does not reflect:** terrain and grass, per pixel. Terrain is
`retro_rt_receiver_only` precisely so streaming never rebuilds the acceleration
structure, and making it ray-visible would force a full rebuild per chunk load;
grass is alpha-tested and deforming, which the Retro RT contract excludes
outright. The baked panorama includes a ground band below the horizon, tinted
from `ground_gradient`, which is what gives the lower half of a mirror a
coherent colour instead of a hole.

## Grass, terrain, and anything else unmanaged

Under hardware RT, Retro RT suppresses the native shadow map of every light it
discovers, so unmanaged forward geometry receives no engine shadow at all, and
managed surfaces are lit by the renderer rather than by their own material.
(Under its raster fallback none of that happens: shadow maps are the shadows, so
unmanaged geometry is shadowed like anything else.) Either way nothing here needs
to reach them: the cloud layer casts no shadow, so it is drawn by the sky and
read by nothing else.

`cloud_ambient_lift` exists because an overcast day is not a sunny one with the
sun switched off: the cloud deck becomes the light source. Without it, full
cover leaves shadowed surfaces at clear-sky ambient, which on dark materials is
very close to black — and a grass canopy that vanishes into its own shadow is
what a cloud passing overhead should never look like.

## API

`examples/DayNightExample.gd` is a worked example of most of this.

### Signals

`time_changed(hours)`, `day_changed(day_number)`, `phase_changed(phase)`,
`sun_occlusion_changed(occlusion)`, `sky_state_changed(state)`

`sun_occlusion_changed` carries a plain float because it changes every frame and
this node allocates nothing per frame. `sky_state_changed` carries a dictionary
and is gated on visible colour change: several times a second through a sunrise,
and not at all through a still midday.

### Time

| Method | Notes |
| --- | --- |
| `get/set_time_of_day(hours)` | 0..24. Setting it leaves the day, and so the sky, alone |
| `get/set_normalized_time(t)` | the same clock as 0..1 |
| `advance_time(hours)` | rolls the day, and re-rolls the sky with it; accepts negatives |
| `get/set_day_length_seconds()` | live-adjustable; the clock keeps its place in the day |
| `get/set_day_number()` | the seed for the stars and the cloud field |
| `get/set_time_running()`, `get/set_time_scale()` | |

### Sky and lighting

`get_direction_to_sun()`, `get_direction_to_moon()`, `get_sun_elevation()`,
`get_moon_elevation()`, `get_moon_phase()`, `get_day_factor()`, `is_night()`,
`get_phase()`, `get_phase_name()`, `get_sun_light()`, `get_moon_light()`,
`get_sun_light_color()`, `get_sun_light_energy()`, `get_moon_light_energy()`,
`get_horizon_color()`, `get_zenith_color()`, `get_ambient_color()`,
`get_ambient_energy()`, `get_star_intensity()`, `get_sun_occlusion()`

Directions point *towards* the body and are unit length, matching how Retro RT
reads a `DirectionalLight3D` basis. `get_sky_state()` returns all of it in one
dictionary; it allocates, so read it from a signal rather than a per-frame loop.

### Clouds

`get/set_cloud_coverage()`, `get/set_cloud_altitude()`,
`get/set_wind_direction()`, `get/set_wind_speed()`, `get_cloud_offset()`,
`reseed_day()`

### Materials

`register_ambient_material()` / `unregister_ambient_material()` — managed
Blinn-Phong materials whose `ambient_light` should follow the time of day. The
value a material already holds is captured as its **daylight reference**: a
hand-tuned material is left exactly as authored at noon and scaled down and
blue-shifted from there.

### Persistence

`save_state()` / `load_state(state)` match the host project's `saveable` group
contract. The day number is in the payload because the stars and the cloud field
are derived from it, so a reloaded save comes back under exactly the sky it was
written under. A partial or empty payload loads without error.

A save records **where the sky is** — hour, day, cloud cover — and deliberately
not how fast it runs. `day_length_seconds`, `time_scale` and `time_running` are
authored configuration and are never restored. Persisting pace makes a save
written before you retuned the cycle quietly reinstate the old rate, so the value
you just typed into the inspector appears to do nothing: the sun crawls at the
old speed, night never arrives, and the only sign anything happened is the clock
snapping to the saved hour on load. If your game changes pace as part of its own
state, save that with your own data and re-apply it through `set_time_scale()`
after the level is installed.

## Exports worth knowing

| Property | Default | Notes |
| --- | --- | --- |
| `day_length_seconds` | `1200.0` | real seconds per in-game day |
| `sun_tilt_degrees` | `25.0` | keeps the sun off the exact zenith at noon, so shadows sweep instead of pivoting |
| `moon_phase_cycle_days` | `8` | day zero is a full moon |
| `world_seed` | | mixed with the day number; same seed, same sky |
| `cloud_coverage` | `0.5` | 0 clear, 1 overcast |
| `cloud_altitude` | `260.0` | the plane every shadow is resolved against |
| `cloud_world_size` | `420.0` | metres per noise tile; see **The cloud layer** |
| `cloud_softness` | `0.34` | hard-edged banks at 0, haze at 1 |
| `cloud_moonlight` | `0.30` | share of the moon's energy the layer takes; see **The layer at night** |
| `cloud_ambient_lift` | `0.65` | how much overcast raises the fill |
| `star_density` | `60.0` | cells per cube face |
| `star_coverage` | `0.10` | fraction of cells holding a star; with the density, about a thousand on screen |
| `star_size` | `0.12` | wants to land a couple of pixels across; see **The star field** |
| `reflection_panorama_enabled` | `true` | sky in mirrors; costs a bake per `reflection_sun_step_degrees` |
| `preview_in_editor` | `true` | sky and lights in the editor viewport |
| `palette` | | a `DayNightPalette`; a null one is replaced by a full default set |

## The palette

`DayNightPalette` holds every colour and intensity ramp. Ramps are sampled by
**body height**, not by clock time, so retuning the tilt or the cycle length
moves the colours with the sun. Sunrise and sunset share a ramp position and
look alike, which is both cheaper and correct.

An unassigned palette, or an unassigned ramp inside one, is filled in with a
complete default set on the first frame. Assign only what you want to change.

Two defaults are tuned rather than physical, and deliberately so. This project
grades with raised contrast and has no global illumination, so anything under
about half the sun energy crushes to solid black on dark materials.
`moon_peak_energy` is therefore `0.85` against a `sun_peak_energy` of `1.15`: a
numerically honest moon renders an unplayable night rather than a dim one.
`ambient_peak_energy` is `0.55`, which lands noon on roughly the fill the level
had before the cycle existed.

## Cost

- **Zero sky bakes for the background.** The `BG_COLOR` path is preserved.
  Reflection bakes are separate, opt-out, and throttled by sun movement.
- **No ray-visible geometry and no acceleration-structure churn.** A captured
  run of the shipped level reports one TLAS build for the whole session.
- One extra opaque draw for the dome. Clouds add two noise evaluations per sky
  pixel and one per lit surface pixel; there is no volume and no marching.
- One `_process` on one node, and no per-frame `Node` or `Resource` allocation.
- Environment, ambient and material pushes are gated on visible colour change,
  so a still midday causes no RT revision churn. During a sunrise the colours
  move every frame and the gate never trips, which is what keeps the light
  continuous.
- Nothing in the post stack changes.

### Hard shadows and slow suns

Retro RT's *geometry* shadows are binary by design — one or zero, no soft edge,
no temporal history. A shadow edge can therefore only lie on a pixel boundary,
so when the sun moves slowly enough that the edge travels less than a pixel per
frame, it holds still for several frames and then jumps. Measured on the shipped
20-minute day, a test box's shadow was identical in 46 of 48 consecutive frames
and then stepped once. Nothing here can smooth that; it would take soft shadows
or temporal accumulation, both of which the RT pipeline excludes.

Cloud shadows are not affected: they are an analytic term with a soft threshold,
not a traced edge.

## Constraints and gotchas

- **Nothing is written to an authored resource while the editor is running.**
  The `Environment` and any registered material are only driven at runtime,
  because an in-editor write would be saved into the scene. The editor preview
  is therefore sky and lights only, and never bakes a reflection.
- **The dome is a box, not a sphere, and its half-extent must leave room.** The
  shader reconstructs its view direction from the interpolated world position of
  the fragment, and that interpolation is exact across a planar face but a chord
  rather than an arc across a curved one; a sphere is also degenerate at its
  poles. The corners reach sqrt(3) times the radius, so the 1200 m default sits
  inside a 4000 m far plane.
- A `DayNightCycle3D` with no `RTSceneManager` in the tree simply skips the
  managed-surface shadow and the reflection panorama; everything else is
  unchanged.

## Tests

```powershell
& "<godot>" --headless --path . --rendering-method forward_plus --script res://addons/day_night_cycle/tests/day_night_smoke.gd
```

Covers the clock and its rollover, the sun/moon arc, the light handover at the
terminator, the cloud layer and its shadow geometry, the Environment push and
its gating, the material ambient reference, save/load, and that the five copies
of the canonical cloud code are still byte-identical and still carry the three
details above.

## Exporting

`examples/` is only needed while learning the add-on. Exclude it with an export
filter (`addons/day_night_cycle/examples/*`) once your own scene is set up.

## Global class names this add-on registers

`DayNightCycle3D`, `DayNightPalette`. Check these against your project and any
other add-ons before installing — Godot reports a global class collision as an
error.
