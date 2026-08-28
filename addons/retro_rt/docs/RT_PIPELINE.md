# Hardware RT, the raster fallback, and the shared visual contract

This is the architecture and validation spec for the Retro RT add-on. For
installation, the scene contract and the public API, read `../README.md` first —
this document assumes you already have RT running and explains why it is built
the way it is.

The validation commands in this document use the fixtures that are checked into
this project: `receiver_registry_smoke.gd`, `panini_projection_smoke.gd`,
`perf_probe.gd`, and `panini_capture.tscn`.

This Godot 4.7.1 project is Forward+ only. It runs one scene, material,
lighting, ray, texture, environment, anti-aliasing, and output contract across
two pipelines: hardware ray tracing, and the raster fallback that stands in for
it on an adapter that cannot ray trace or when the player turns ray tracing off.
Both feed the same fullscreen post stack.

The two are deliberately not equivalent, and the contract does not pretend they
are: ray-traced shadows and reflections are the point, and shadow maps and
screen-space reflections are what is available without them. What the shared
contract does hold is everything around that — the same materials, the same
lighting model, the same fog curve, the same colour and exposure, the same
resolution domains, and the same present chain — so the fallback reads as the
same picture with cheaper shadows and reflections rather than as a different
renderer. **What the fallback does not reproduce** in the next section is
explicit about where they part.

## Backend selection and the raster fallback

The project is Forward+ only. There are two pipelines, and which one installs is
not a request but a consequence:

- **Hardware RT** requires Forward+ on Vulkan, a `RenderingDevice` exposing
  buffer-device-address and ray-tracing-pipeline support, and a non-CPU adapter.
- **The raster fallback** runs whenever any of that is missing, and whenever the
  player turns ray tracing off.
- `RTSceneManager.ray_tracing_enabled` requests hardware RT.
  `set_ray_tracing_enabled()` changes it on a running manager by genuinely
  reinstalling the pipeline — stop, then start. Assigning the property on a
  running manager is a contract failure rather than a silent no-op.
- `hardware_rt_supported()` and `hardware_rt_unavailable_reason()` are static, so
  a settings menu can ask before any manager exists.
- `get_active_rt_backend()` reports `hardware`, `raster`, or `none`.

Hardware RT uses BLAS/TLAS resources, a POST_SKY compositor effect, and the
material/instance carriers in `BlinnPhong.gdshader`. It relies on the Godot
4.7.1 Forward+ `forward_clustered` normal/roughness and specular buffers.

### What the raster fallback is

Not a second renderer. It is the absence of the first one, plus two switches.

The manager keeps **no scene representation** under the fallback: no mesh
extraction, no texture atlases, no light table, no snapshot, no acceleration
structure. That work exists only to feed a tracer. What it still owns is the
post stack and the distance fog contract — everything the image shares with
hardware RT.

Three things then fall out of simply not installing the hardware path:

| | Hardware RT | Raster fallback |
| --- | --- | --- |
| `rt_pipeline_active` | set true, so materials become visibility-buffer transport | left false, so `BlinnPhong.gdshader` renders its standalone Blinn-Phong branch |
| Native light shadows | suppressed through `RenderingServer.light_set_shadow`, because the RT pass owns shadows | left alone, so `Light3D.shadow_enabled` means what it says and shadow maps render |
| Reflections | traced; per-material `mirror_enabled` / `reflection_strength` | `Environment.ssr_enabled`, turned on by the manager and restored on teardown. The same `mirror_enabled` surfaces publish `SPECULAR` at roughness zero, which is what SSR reads |

`Environment.ssr_enabled` is therefore the one contract that differs by pipeline:
hardware RT rejects it, the fallback requires it. Scenes author it off and let
the manager own the switch, so one scene serves both.

The fallback also has to apply distance fog itself. Under hardware RT the
compositor fogs managed pixels; with no compositor, `BlinnPhong.gdshader` applies
`rt_fog_factor` in its standalone branch from `rt_fog_params` / `rt_fog_color`,
which the manager pushes to managed materials. Without that, terrain and props
would render unfogged while shell grass — which subscribes to
`distance_fog_changed` — still faded, and the terrain streaming boundary would
become a visible wall. Gathering those materials is the only thing the fallback
looks at the scene for.

### What the fallback does not reproduce

Screen-space reflections only reflect what is on screen, so a mirror loses
off-screen and backfacing geometry, and reflections disocclude at screen edges.
Shadow maps have finite resolution and their own acne and peter-panning
tradeoffs, where ray-traced shadows have neither. The analytic ground layer is
hardware-only and is skipped: SSR covers terrain and grass in mirrors instead.
Everything after the 3D pass — the scene resolve, Panini, the retro grade, the
present — is identical.

### In the editor

The manager is runtime-only; there is no editor RT preview. The editor viewport
shows managed materials through the same standalone `BlinnPhong.gdshader` branch
the raster fallback uses, so authoring happens against an honest preview of one
of the two shipping configurations. Previewing hardware RT would mean installing
a CompositorEffect on the edited scene's `World3D` scenario, affecting every
editor viewport on that world, and switching managed materials into
visibility-buffer transport that renders as garbage whenever the compositor is
missing. The post stack cannot run there either:
`RTPostProcessStack.configure()` sets `disable_3d = true` on the root viewport
and presents through a `CanvasLayer`, which in the editor blanks the viewport and
its gizmos.

## Central visual contract

`RTVisualContract` and `RTSceneManager` own the renderer-common state. The
project defaults and the active runtime stack agree on:

- TAA, built-in SMAA/FXAA, 2D MSAA, and 3D MSAA disabled. MSAA in particular is
  incompatible with the hardware RT visibility buffer, not merely unused; see
  "Why anti-aliasing cannot be MSAA";
- native root `scaling_3d_scale = 1.0` with bilinear/no-upscaler mode;
- no anti-aliasing of any kind at present, and no temporal reconstruction,
  history, motion-vector AA, accumulation, denoising, or dynamic resolution;
- texture mip bias `0.0`, 4x anisotropic filtering, and debanding disabled;
- classic Panini projection available after the scene resolve;
- shared RetroGrade enabled after Panini by default.

The root Viewport state touched by the stack is captured before activation,
normalized before validation, and restored on normal teardown or failure. If a
platform cannot honor any required value (including 4x anisotropy), startup
fails with the specific rejected setting instead of silently weakening the
contract.

The root/final presentation target is also forced to `use_hdr_2d = false`.
That is part of the owned-and-restored contract: the final canvas shader emits
the one explicit scene-linear-to-sRGB transfer, so an HDR 2D root would add a
second renderer-owned display transfer. This root setting is separate from the
three internal post SubViewports, which request HDR 2D as described below.

The manager also validates the effective Environment and camera attributes.
Environment fog, volumetric fog, SSAO, SSIL, SSR, SDFGI, glow, Environment
adjustments, auto exposure, camera exposure overrides, depth of field, and
physical-camera exposure behavior are outside the shared contract. Engine fog
stays banned because the compositor overwrites managed scene color; the stack
owns an equivalent post-lighting fade instead (see "Distance fog" below).
Tonemapping must be Linear at exposure `1.0`. Screen-space roughness limiting
is disabled in project settings. Managed authored light shadow checkboxes
remain RT-shadow toggles; the corresponding native raster shadow maps are
suppressed while RT is active.

These are contract checks, not a claim that every named Godot feature was
previously active. The validation prevents a scene change from silently adding
a Forward+-only visual advantage.

Bit-exact capture tests additionally force camera attributes to null or a fixed,
non-temporal resource. Camera-attribute propagation is tested separately from
pixel hashes. Automatic exposure must never make a frozen-frame or
quality-switch determinism check intermittently fail. It remains outside the
current runtime visual contract rather than being enabled by quality scaling.

### Distance fog

`RTSceneManager` owns a post-lighting distance fog that replaces Godot's
Environment fog, which stays banned. `fog_enabled`, `fog_begin`, `fog_end` and
`fog_curve` are exported; `configure_distance_fog()` is the runtime push for
systems that derive their reach from their own data, and `get_distance_fog()`
plus the `distance_fog_changed` signal let unmanaged forward geometry stay
matched.

The fog colour is not authorable. It is always the environment's linear
background radiance (the snapshot's `fallback_linear`), which is also what the
post stack composites into uncovered pixels, so the fog asymptote and the
visible background are the same value by construction and there is no seam
where terrain meets sky.

This function is normative. It is duplicated rather than included because the
compute shader is compiled by `RDShaderFile` and the others by Godot's shading
language; keep every copy byte-identical.

```glsl
float rt_fog_factor(vec4 params, float view_distance) {
	if (params.w < 0.5) {
		return 0.0;
	}
	return pow(smoothstep(params.x, params.y, view_distance), params.z);
}
```

`params` is `(begin, end, curve, enabled)` and `view_distance` is radial, not
view-space Z, so fog does not shimmer as the camera turns. `smoothstep` is
C1-continuous at both ends, so there is no kink where the fog starts.

Copies live in `shaders/rt_shadow_reflect.glsl`, `shaders/BlinnPhong.gdshader`,
and `addons/procedural_terrain_grass/shaders/grass_shell.gdshader`.
`ground_layer_smoke.gd` compares all three byte for byte, because three slightly
different ramps would show up as a seam between a prop, the terrain under it and
the grass around it.

Every path composites `final = lit * (1 - f) + fog_color * f`:

| Path | Application |
| --- | --- |
| Hardware | `scene_color = mix(ambient + emission + reflection, miss_color, f)` and `separate_specular = direct * (1 - f)`. Forward+ adds the two buffers. |
| Raster fallback | `ALBEDO *= (1 - f)`, `EMISSION = (ambient + emission) * (1 - f) + fog_color * f`, and the Blinn specular lobe and `SPECULAR` both scale by `(1 - f)`. Scaling `ALBEDO` attenuates every light Godot evaluates against it. Parameters arrive as `rt_fog_params` / `rt_fog_color`, pushed by the manager. |
| Unmanaged | `ALBEDO *= (1 - f)`, `EMISSION = fog_color * f`, `SPECULAR *= (1 - f)`. The same identity as the fallback, reached through `distance_fog_changed`. |

Fog is applied once, to the primary hit. Reflected radiance inherits the
reflector's fog rather than the reflected path length.

## Shared post-processing: scene resolve, Panini, grade

Every runtime pipeline uses `RTPostProcessStack`. There are three canvas passes.
Presentation is always native, and there is no resolution *scaling* in the
upscaler sense — no reconstruction, no history, nothing temporal. The one stage
that leaves the output pixel domain is the 3D capture, which the Panini pass
sizes for its own sampling requirement; see **Capture resolution is the
projection's sharpness control**. With Panini bypassed the capture is the output
size and every stage in the chain is 1:1.

**There is currently no anti-aliasing.** The custom SMAA 1x implementation, FSR 1
(EASU and RCAS), FidelityFX CAS and the RT quality presets that drove them were
all removed on 2026-08-28. They existed to make one image work across renderers
this project no longer targets, and the cost of keeping them parity-matched
outgrew what they bought. A replacement is still to be chosen; see **Why
anti-aliasing cannot be MSAA** below for the one option that is permanently
closed off. Note that the Panini capture is supersampled at the shipped
sharpness, so it is currently doing the geometric-aliasing work an AA pass would
otherwise do.

```text
3D scene / RT result                             (capture size)
    -> internal scene capture                    (capture size)
    -> scene resolve: coverage decode, environment reconstruction, fog,
       one normalized HDR-to-SDR clamp, scene-linear-to-sRGB   (capture size)
    -> classic Panini D=1, S=0                   (optional, to native output size)
    -> sRGB-to-scene-linear, RetroGrade, display-range clamp   (native output size)
    -> explicit scene-linear-to-sRGB transfer
    -> final scene CanvasLayer (-100)
    -> normal gameplay Canvas/UI
```

The scene capture is transparent under hardware RT, where managed pixels carry
ID transport rather than colour and the environment has to be reconstructed
behind them. The raster fallback captures opaque instead, both because it has no
transport to hide and because Godot silently disables screen-space reflections
in a transparent viewport. Coverage then reads 1 everywhere and the resolve pass
composites nothing behind the image.

All depth, camera-matrix, lighting, RT, shadow, reflection, fog, terrain, grass,
and environment work is rectilinear and upstream. Panini warps that completed
opaque perceptual image as one coherent layer. The reticle, FPS counter, status
overlays, and menus are ordinary root/UI canvases downstream of the scene
CanvasLayer, so aim and text are never projected.

### Panini projection and horizontal FOV

`RTPaniniCamera3D` is the reusable opt-in capability. It forces perspective and
`Camera3D.KEEP_WIDTH`; `display_horizontal_fov` therefore means exact horizontal
coverage at every aspect ratio. Valid values are 120–140 degrees, default 130.
`set_display_horizontal_fov()` clamps finite values and rejects NaN/infinity
without replacing the last valid value. The game FPS camera enables
`panini_enabled`; reusable add-on and utility cameras default it off.

`PlayerCamera.set_base_horizontal_fov()` owns the same 120/130/140 constants and
smooths in horizontal-degree space. Sprint requests a 10-degree boost capped at
140, and disabling dynamic FOV always returns to the selected base. `GameApp`
owns the session preference independently of RT initialization; the Graphics
slider applies synchronously while paused, and reset, respawn, load, menu return,
and new game reuse that session baseline. FOV is intentionally absent from save
payloads and returns to 130 only after an application restart.

The pass runs only when both `RTSceneManager.post_panini_enabled` and the current
perspective camera capability are enabled. Missing, unsupported, disabled,
orthographic, and frustum cameras bind the scene resolve target directly
to presentation. Cutscenes, warmup, examples, reflection-bake, and other utility
cameras therefore retain the ordinary rectilinear path unless they explicitly
opt in.

The inverse mapping and capture bounds are symmetric, so a perspective camera
with nonzero `h_offset` or `v_offset` bypasses with
`camera_offset_unsupported` instead of sampling rays around the wrong projection
center. The stack never edits authored offsets; the supported zero offsets are
copied unchanged to the private camera.

The projection is fixed classic Panini with distance `D=1` and squeeze `S=0`.
Its native-output horizontal extent makes the left and right center rays exactly
minus/plus half the selected display FOV; the vertical center extent follows
from output aspect. Each FOV or size-domain change evaluates the inverse mapping
at one logical corner, adds a half-texel margin, and chooses the smallest
perspective capture frustum that contains it. That conservative private-camera
overscan prevents black borders, clamped corners, and culling holes without
altering the authored camera.

One corner is sufficient because the mapping is monotonic on both axes:
`mapped.x = tan(phi)` is odd and strictly increasing in output NDC x across the
supported `|phi| < 90` degrees, and `mapped.y` is linear in output NDC y and
strictly increasing in `|phi|`. Both extrema therefore land on the four logical
corners. `post_panini_perimeter_samples` still reports every output-border texel
center plus those four corners, but the perimeter is only materialized and
scanned on the exceptional invalid-contract path, to retain an exact
`invalid_samples` diagnostic. The closed form is what keeps the smoothed sprint
FOV, which moves every frame, off a scan that cost about 2 ms per frame at 1080p
and 3.2 ms at 3440x1440; `panini_projection_smoke.gd` pins the closed form
against a full border scan.

### Capture resolution is the projection's sharpness control

The projection reads its source through a warp that compresses the periphery, so
the screen center is a magnification of whatever the capture rendered. That
magnification, not the reconstruction filter, is what decides how sharp a
Panini frame can be. `post_panini_center_texels_per_pixel` reports it directly:
source texels read per output pixel at screen center, where 1.0 means the center
is not magnified at all.

The 3D capture and its resolve are therefore the only stages that leave the
output pixel domain. Presentation, the projection target, and every UI canvas
stay at native output resolution at all times.

Two decisions size that capture, and both are exact rather than tuned.

**Aspect.** The capture uses the ratio of the two required half-tangents. That
ratio is the sharpness optimum, not a convenience: capture width grows as
`sqrt(aspect)` at a fixed pixel count, while the horizontal capture tangent is
flat until the aspect passes that ratio and grows linearly after it, so the
horizontal center ratio peaks exactly there. It is also the only aspect that
wastes no frustum. An output-aspect capture at a 130-degree display FOV renders
41 percent of its width outside anything the projection can sample —
`post_panini_source_uv_min/max` used to span `[0.203, 0.797]` horizontally and
now spans the full `[0, 1]`, and the capture FOV needed at 140 degrees fell from
159 to 140.

**Scale.** `RTSceneManager.post_panini_capture_sharpness` is the center ratio
itself: with the optimal aspect the ratio reduces to the linear scale, so the
setting means what it reports. The cost is quadratic in it, roughly
`4.8 * value^2` times the output pixel count at a 130-degree display FOV and
`7.6 * value^2` at 140. Measured on the terrain scene at 2560x1440 with hardware
RT:

| sharpness | capture pixels | median frame | scene pass |
| --- | --- | --- | --- |
| 0.353 | 0.94x | 3.35 ms | 2.56 ms |
| 0.458 | 1.59x | 5.02 ms | 4.49 ms |
| 0.55 | 2.29x | 6.93 ms | 6.38 ms |
| 0.65 | 3.19x | 9.34 ms | 8.24 ms |
| 0.75 | 4.25x | 12.09 ms | 11.10 ms |
| 1.00 | 7.56x | 20.93 ms | 19.03 ms |

The add-on defaults to 0.5 and `main.tscn` selects 0.75. Since the capture is
supersampled at any value above roughly 0.5, this is also the only thing in the
stack currently reducing geometric aliasing; expect to lower it once real
anti-aliasing lands.

The capture is sized from `RTPaniniCamera3D.max_display_horizontal_fov` — the
widest angle the camera declares it will ever request — rather than from the
live angle, because the capture is a render target and the live angle moves
every frame while a sprint transition eases. `PlayerCamera` sets that ceiling to
its session base plus the sprint boost. A ceiling below the live angle stays
correct, since the frustum still widens to contain the projection, and only
costs sharpness the capture already paid for; a camera that declares no ceiling
keeps the plain output-sized capture. `panini_capture.tscn` sweeps the display
FOV across 40 eased angles and asserts `post_capture_resize_count` does not move.

### Reconstruction filter

The canvas shader picks its filter from the per-pixel footprint, and the capture
resolution decides which branch most of the frame takes. The diagnostic contract
names the pair `catmull_rom_or_tent`.

Below a 1:1 footprint the capture is magnified, and a single bilinear tap is what
makes a magnified center read as soft. A five-tap Catmull-Rom reconstructs the
same texels with edge slope preserved and no extra source data. The kernel is
renormalized over its five kept taps, so it is exactly transparent at 1:1 and
shifts no brightness on a flat field, and it fades to that single bilinear tap as
the footprint approaches 1:1. Its negative lobes are clamped to the `[0,1]` range
the upstream resolve already guarantees.

Above a 1:1 footprint the capture is minified, and a supersampled capture minifies
most of the frame rather than only the corners — at sharpness 0.75 the footprint
runs from 1.47 at center to 5.32 at the corners. A separable 3x3 tent over the
pixel's own footprint covers that: each bilinear tap already averages a 2x2 texel
neighbourhood, so three taps per axis tile a footprint of up to about four texels
with no gap between kernels, where the two taps per axis this replaced leave one
from a footprint of two upward. Its outer taps collapse onto the center as the
footprint approaches 1:1, which is what lets the two branches meet with no
visible ring.

Neither branch uses compute, history, dynamic allocation, or a varying tap count.
The output-size Panini SubViewport is persistent, resized in place, and set to
`UPDATE_DISABLED` while bypassed; a bypassed frame presents the resolve target
1:1, so the capture returns to the output size with the pass.

Nothing sharpens after the projection: the CAS pass that used to sit there was
removed along with FSR. Any replacement sharpener belongs in the same place,
between Panini and the grade.
`generated/shader_warmup_manifest.tres` includes `panini_project.gdshader`; rerun
the normal warmup generator whenever this shader or its material parameters
change.
`post_panini_source_stage` always reports `scene_resolve`, and
`post_present_source` reports `panini` while the pass is active or
`scene_resolve` while it is bypassed.

### Why anti-aliasing cannot be MSAA

Whatever replaces SMAA, it cannot be MSAA, and that is a property of the
renderer rather than a preference.

Hardware RT here is a deferred visibility-buffer renderer. `BlinnPhong.gdshader`
packs a 21-bit instance plus material ID through the separate-specular target,
and the compute shader decodes it before writing results back. Multisample
resolve averages that packed integer away at exactly the silhouette pixels MSAA
exists to fix, producing garbage IDs. Separately, `image2D` cannot bind a
multisampled attachment, and the effect runs at `POST_SKY` with unresolved
access, so its writes would be discarded by the resolve.

`RTVisualContract.apply_native_viewport_state()` therefore force-disables 2D and
3D MSAA, TAA, built-in screen-space AA and debanding on the root Viewport,
captures the authored values first, and restores them on teardown or failure.

### Targets and precision

The Panini target and the final presentation are native output size. The scene
capture and its resolve are the projection's capture size, which equals the
output size whenever the projection is bypassed.

All three targets ask for `use_hdr_2d = true` and Forward+ honors it, so all
three are RGBA16F. That is now a startup requirement rather than a preference:
the resolve shader decodes coverage assuming scene-linear storage and has no sRGB
fallback branch, so `configure()` fails with the offending target name if any of
them comes back LDR. The `post_*_hdr_requested`, `post_*_hdr`, and
`post_data_viewports_rgba` profile fields remain, and still distinguish the
requested state from what the renderer actually supplied.

Intermediate SubViewports are persistent and resize only when the output size,
the capture size, or the projection's active state changes; they are not
reallocated per frame, and `post_capture_resize_count` is the counter that proves
it. The Panini target is disabled rather than freed while bypassed. Its input is
always the resolve target, and the final present source is Panini when active or
that resolve target, 1:1, when bypassed.

Posterization happens in the grade and remains intentionally crisp. There is one
grade path, shared by both pipelines; there is no separate compute grade for
hardware.

### Artist controls

- `post_panini_enabled` (manager-wide request; camera capability still gates it);
- `retro_post_enabled`;
- brightness, contrast, saturation, black point, and color balance;
- posterization enable, levels, and strength.

The final scene is presented on CanvasLayer `-100`. Gameplay UI should remain on
the default canvas or a higher CanvasLayer, so it is not graded, posterized or
Panini-projected as part of the 3D image. Panini operates only on the private
rendered 3D scene; fonts, reticles, HUD elements, and menus stay at native
resolution. `panini_capture.tscn` leaves a known status marker above the scene to
make that ordering visible.

## Color, exposure, and texture sampling

Forward+ honors the HDR 2D scene-capture request. The capture is sampled as
scene-linear data and can carry radiance above `1.0` until the display-range
boundary in the resolve pass. The `scene_input_is_linear` uniform the resolve
shader reads follows `use_hdr_2d`, and exists to decode a non-linear capture
back to scene-linear if one is ever configured.

Both pipelines reconstruct the same visible environment and clamp normalized
linear scene color once in the resolve pass. That pass encodes to perceptual
color, and the present shader
decodes once, performs the post-grade display clamp, and emits one explicit
scene-linear-to-sRGB transfer into the deliberately LDR root canvas. Environment
tonemapping is neutral Linear/1.0. There is no shader-authored 8-bit
quantization; the final PNG is an unavoidable storage boundary, while explicit
posterization remains an artist control.

Directly visible albedo and normal maps use repeating, mipmapped, anisotropic
sampling. The shared viewport contract fixes 4x
anisotropy and zero mip bias. Albedo is source-color data; normal maps remain
linear and use the same OpenGL-style decoding. UV and triplanar equations are
shared. Ray-hit atlases use tile-local repeat with bilinear mip-0 sampling so a
lookup cannot bleed into another atlas tile.

Forward+'s compositor storage path does not propagate opaque alpha into a
transparent ViewportTexture. Managed exactly-black hardware pixels therefore
carry a visually black, sub-display-step float sentinel, and the post shader
recovers zero-alpha managed coverage before environment reconstruction. A
translucent raster surface directly over managed hardware geometry still has no
separate engine-exposed opaque coverage mask; overlapping mixed coverage is an
explicit Forward+ limitation, while ordinary transparency against the visible
environment remains supported.

Hardware RT packs directly visible maps into static RGBA8 albedo and normal
atlases, which preserve source-color versus linear-normal semantics, and the
ray-hit path samples those rather than the authored textures.

Assigned map references and pixel content are static atlas inputs. Changing
either requires a scene reload and fails explicitly if detected during a run.
The raster fallback builds no atlases and samples the authored textures
directly, so it is not subject to that restriction.

## Environment and reflection misses

Reflection misses now use the same effective background that is visible to the
scene. Resolution precedence is active camera Environment, the manager's
explicit `world_environment_path`, World3D Environment, then World3D fallback.
Runtime initialization fails visibly when none of those supplies an Environment.
`BG_CLEAR_COLOR` reads the project/default clear color only after an effective
Environment has selected that background mode.

The scene capture is transparent and the final shared canvas shader reconstructs
that same immutable environment snapshot behind every exact geometry texel from
the active camera's corner rays. This prevents native Forward+ sky
tonemapping from becoming a second visible-background path. Background radiance
and reflection misses therefore share panorama texels, energy, rotation, seam
wrapping, and pole clamping.

- `BG_CLEAR_COLOR` and `BG_COLOR` produce a linear flat miss radiance with the
  Environment background energy applied.
- Every `BG_SKY` first calls public
  `RenderingServer.sky_bake_panorama(..., bake_irradiance = false, ...)`. The
  call must succeed on the active renderer; failure is reported and is never
  replaced by a flat color. Procedural, Physical, and custom sky materials use
  that linear, untone-mapped result directly, with no source-color decoding.
- `PanoramaSkyMaterial` also requires a CPU-readable source texture. After the
  public bake succeeds, the manager canonicalizes that source to the same
  RGBAF panorama, so a runtime Panorama is interpreted the same way whatever
  format the producer handed over. Floating
  source formats are treated as linear; integer/color formats receive one sRGB
  decode; Environment and Panorama material energy multipliers are then
  applied. Profiles identify this path as `panorama_source_canonical`.
  Runtime producers may retain their original float CPU `Image` on the texture
  as `rt_linear_panorama_image`; this avoids a runtime texture readback from
  normalizing an otherwise valid HDR source. The canonicalizer copies the
  retained image and never mutates producer-owned pixels.
- The immutable panorama is bounded at 512x256 and capped further by Sky
  radiance size. Its descriptor includes dimensions, byte size, source,
  inverse sky basis, bake duration, rebake count, and its own environment
  revision. Values above 1.0 survive the snapshot until the common post
  boundary.
- The reflection-miss and background paths use the same seam-wrapped bilinear
  panorama sampling equation. A mirror whose reflection ray misses therefore
  sees the visible sky/HDRI instead of a hard-coded black or unrelated clear
  color. The raster fallback has no reflection rays to miss: SSR falls back to
  the same environment through Godot's own reflection source.
- Environment, Sky, sky-material, and relevant source-texture `changed` signals
  are debounced into one revision/rebake and atomically republish the
  environment. The next backend update receives the new flat value or panorama
  without rebuilding scene geometry.
- Custom sky shaders that read `TIME` or `POSITION` are static snapshots. The
  manager emits one warning for that material and only rebakes after a tracked
  resource changes; it never performs a synchronous per-frame sky readback.

This is sharp one-bounce reflection miss radiance. It is not diffuse IBL,
roughness convolution, a reflection probe, or another reflection bounce.
Unsupported Environment modes fail instead of producing backend-dependent
results.

## Analytic ground layer

A reflection miss can resolve against the ground instead of the sky. This exists
for one specific hole: the ground is the only thing in these scenes that a ray
can never hit, and it is the thing a mirror sitting on it most obviously ought
to show.

Two independent reasons put it out of reach of the acceleration structure, and
neither is worth undoing:

- Streamed terrain chunks are registered `retro_rt_receiver_only`, which gives
  them instance mask `0`. That is what stops chunk streaming from rebuilding the
  BLAS and TLAS several times a second. Admitting them would also collide with
  the vertex-colour rule below: ray-visible managed geometry may not use vertex
  colours, and terrain ground colour is authored as exactly that.
- Shell grass is vertex-deformed, so it is outside the managed material contract
  permanently, MultiMesh and skinning being excluded for the same reason.

So the ground arrives as data rather than as geometry. A terrain system calls
`RTSceneManager.configure_ground_layer()` with one RGBA32F image covering a
square window in world XZ:

- `RGB` is scene-linear ground radiance, baked by the producer from the same
  colour rule that bakes its chunk vertex colours. Nothing about that rule is
  restated in shader code, so the reflection cannot drift from the ground it
  stands in for.
- `A` is canopy height in world Y: the terrain surface plus whatever grass
  stands on it. The reflected surface is therefore the canopy, and grass appears
  in mirrors without one blade being traced.

Six `vec4`s carry the rest, riding in `FrameData`:

| | x | y | z | w |
|---|---|---|---|---|
| `ground_params` | window origin X | window origin Z | 1/window size | march step count |
| `ground_bounds` | lowest canopy height | highest canopy height | max march distance | texel size in metres |
| `ground_sun_direction` | direction to sun | | | 1 when lit |
| `ground_sun_radiance` | colour scaled by energy | | | unused |
| `ground_ambient` | ambient radiance | | | unused |
| `ground_grass` | blade cells per metre | detail strength | ramp depth | detail fade distance |

`ground_params.w` doubles as the disable switch:
a zero step count leaves the miss path byte-identical to what it was before the
layer existed. The step count and the march distance are ray budget the manager
owns rather than values the producer chooses, so both are resolved when the
snapshot commits. The march is capped at `fog_end`, because past it the ground
has already resolved to what the sky shows there.

`ground_grass.y` is the second disable switch: a zero detail strength publishes
the baked canopy unchanged, which is what a scene with no grass gets.

`rt_ground_shade()` and the rest of the block live only in
`addons/retro_rt/shaders/rt_shadow_reflect.glsl`. The layer is hardware-only —
the raster fallback reflects terrain and grass through SSR instead — so there is
no second copy to drift against, but `addons/retro_rt/tests/ground_layer_smoke.gd`
still asserts the invariants below, and it is the only thing that reads them.

Three properties of the march are load-bearing rather than tuning:

- **The window test comes first.** A reflection that never reaches the ground
  costs one ray/box test and nothing else. Most mirror pixels point at sky, and
  that early-out is the whole reason the layer is affordable.
- **Texels are fetched and blended by hand**, never handed to a sampler. The two
  backends have to agree bit for bit and drivers round filtering differently,
  which is why the environment panorama is sampled the same way. Blending rather
  than point sampling is also not optional: this field is a surface a ray is
  marched against, and a staircase of texels catches a grazing ray on its risers
  and paints the reflection in flat axis-aligned plateaus.
- **A ray starting under the canopy resolves where it stands.** That is the
  ordinary case for a mirror resting in grass, not an error: the bottom of the
  reflector is inside the layer. Marching on would find no crossing and let sky
  out through the underside of the reflector.

A ground hit is shaded with ambient plus one directional term and then fades on
`rt_fog_factor` into exactly what the ray would have returned had it missed.
Fading to the flat fog colour instead leaves a visible step at the fog boundary,
because below the horizon a sky is free to draw something other than its horizon
band, and a mirror shows both sides of that boundary at once.

The shadow ray below attenuates that directional term and leaves the ambient
alone, which is what the primary paths do when they scale `direct` and add
ambient separately. Scaling the whole lit value instead takes the ambient with
it, and wherever the sun is occluded that drops the reflected ground to pure
black while the terrain and grass it stands in for stay plainly visible.

Tracing and shading are two calls, not one, because a real ray belongs between
them. When the reflector sets `reflection_shadows_enabled`, the caller traces one
occlusion ray from the ground hit towards the sun with traversal mask `0x01`,
bounded by the same fog-capped march distance, and passes the result to
`rt_ground_shade()` as `sun_visibility`. That is what puts a cube's shadow onto
the ground a mirror shows. The ray cannot live inside the shared block: a
`traceRayEXT` is only available to the `RDShaderFile`, which is why trace and
shade stayed separate calls. Nothing can self-intersect here, because
the ground is not in the acceleration structure at all. A caller that traces no
ray passes `1.0` and gets the pre-shadow result exactly.

Blade detail is the other half. The producer bakes an *average* of the blade
gradient into RGB, and averaging is precisely what makes a reflected field read
as a flat painted plane beside grass that visibly has blades in it, so
`rt_ground_blade_detail()` puts the spread back per pixel: one cell hash on the
hit's world XZ at the producer's own blade pitch, shaped by the same
base-to-tip value ramp `grass_shell.gdshader` gives a real blade. Two properties
of it are load-bearing rather than tuning:

- **It fades out with distance.** Nothing in this renderer filters temporally
  and a mirror shows a great deal of distance in very few pixels, so detail held
  at full strength to the fog boundary crawls as the camera turns.
- **The hash calls no trig.** Cell indices reach the thousands at blade pitch
  across the window, and `sin()` of an argument that large loses enough 32-bit
  precision to print axis-aligned rectangles, which is why the hash mixes integers
  rather than calling trig.

This is still a stand-in for ground rather than a second renderer. The detail is
texture on one smooth marched surface: it cannot silhouette, the blades cast
nothing, and the layer has no reflection of its own.

## Shared rays, lighting, and materials

- Directional, Omni, Spot, and Area lights under the geometry root are
  discovered automatically.
- Every visible managed pixel evaluates all affecting Blinn-Phong lights, then
  selects the strongest eligible shadow-enabled contribution for at most one
  binary visibility traversal. Other lights still contribute direct lighting.
- Mirror pixels launch one sharp reflection ray. A hit receives ambient,
  emission, and direct lighting but cannot launch a second reflection.
- `reflection_shadows_enabled` is a default-off per-mirror option. When enabled,
  a reflection that resolves against the analytic ground layer also traces one
  sun-visibility ray, so a mirror shows shadows on reflected ground as well, and
  a reflection hit may select one eligible light for one additional shadow ray.
- Disabled/zero-strength mirrors, environment misses, and reflection hits
  without an eligible light do not launch a reflected-shadow ray.
- Area lights intentionally use a hard center-point approximation.
- Ray origin bias and maximum distance, cull/receiver layers, instance masks,
  `cast_shadow`, reflected lighting, normal transforms, and texture rules are
  all hardware-RT concepts. The raster fallback publishes no light table at all
  and lets Godot's own clustered forward renderer light the same materials.

Hardware RT accepts up to `max_scene_lights` (256 by default). Overflow is an
explicit error; lights are not silently discarded.

Nested opaque rigid triangle MeshInstance3D geometry is supported, including
indexed/non-indexed, multi-surface, shared-mesh, and instance-override cases.
Missing normals are generated during extraction. Alpha, skinning, morphs,
vertex deformation, Environment fog, MultiMesh, GridMap, and arbitrary shader
semantics remain outside the managed material contract. Unmanaged forward
geometry that must match managed surfaces (the streamed shell grass) subscribes
to `distance_fog_changed` and applies the canonical `rt_fog_factor` itself.

Each render snapshot contains immutable receiver-light starts/counts/indices
and a receiver-light revision, which is what the hardware compositor consumes as
its conservative receiver/light candidate lists.

## Remaining unavoidable differences

The shared contract deliberately does not emulate implementation weaknesses.
Forward+ retains its native depth precision and reversed-Z behavior; no depth
quantization or artificial Z fighting is introduced.

Between the two pipelines the differences are the intended ones, listed under
**What the fallback does not reproduce** above: traced versus screen-space
reflections, and traced versus mapped shadows. Everything else is shared, and an
image-level difference outside those two is a bug rather than an accepted
backend feature.

Distance fog is the one shared term the two compute differently: the hardware
path derives its fog distance from a depth-reconstructed world position while
`BlinnPhong.gdshader` uses the interpolated view-space one, so the two differ by
float reconstruction error rather than by formula. The curve itself is asserted
byte-identical across all three copies by `ground_layer_smoke.gd`.

## Profiling

Set `profiling_enabled` and call `get_profile_snapshot()` for main-thread,
backend, environment, and post facts. No profiling path performs per-frame GPU
readback.

Common fields include backend/count/revision statistics, atlas dimensions and
bytes, output and internal RT resolution, and:

- `environment_revision`, `environment_mode` (`0` flat, `1` panorama),
  `environment_source`, flat radiance, panorama width/height/bytes/uploads,
  `environment_bakes`, bake failures, and last/peak bake microseconds;
- `environment_bake_source` (`flat`, `rendering_server`, or
  `panorama_source_canonical`), source-canonicalization count, peak/minimum/
  maximum radiance, and seam/north-pole/south-pole continuity measurements;
- `post_panini_requested`, camera capable/enabled/eligible state,
  `post_panini_enabled`, and `post_panini_bypass_reason`; projection/filter
  identity, persistent target and source stage/size; display and conservative
  capture horizontal/vertical FOVs; mapped rect and source-UV bounds; perimeter
  sample and invalid-sample counts; `post_panini_bounds_valid`;
  `post_panini_capture_sharpness`, `post_panini_capture_ceiling_fov` and the
  achieved `post_panini_center_texels_per_pixel`; and dedicated
  `post_panini_buffer_bytes`;
- `ray_tracing_full_resolution`, `ray_tracing_resolution`, and dispatched pixel
  count;
- `post_output_size`, `post_capture_size`, `post_capture_pixel_ratio`,
  `post_capture_resize_count`, `post_render_size` (an alias of the capture size),
  `post_rendered_pixels`, and `post_persistent_buffer_bytes`; camera diagnostic
  fields report the source identity, active state, visual-state and resource
  matches, null internal compositor, and the intentional Panini capture-FOV
  override;
- `post_native_size` (legacy output-size alias), instrumented
  `post_per_frame_allocation_count`/peak, initialization and total explicit
  post-object allocation counts, resize count/timing,
  `post_scene_capture_frames`, `post_resolve_frames`, and
  `post_panini_frames` (increments only while eligible).
  The per-frame counters measure explicit Node/Resource construction inside the
  stack's frame update, including a settings update issued earlier in the same
  manager frame. Normal unchanged frames report zero because every viewport,
  material, and pass node is reused; a revision that rebuilds the temporary
  visual-contract Resource is visible in the current/peak counter.
  The persistent byte count is the owned color targets only: two capture-size
  targets (scene capture and resolve) at 8 bytes per pixel, since Forward+ honors
  the RGBA16F request, plus the persistent output-size Panini target. It excludes
  depth/render buffers. `get_post_debug_contract_snapshot()` exposes the same
  target as `panini_buffer_bytes`;
- `post_pass_gpu_ms` names the measured `scene`, `scene_resolve`, `panini`, and
  `root_present` viewport costs while profiling is enabled;
- `post_scene_viewport_hdr_requested`/`post_scene_viewport_hdr`,
  `post_data_viewports_hdr_requested`/`post_data_viewports_hdr`, and
  `post_data_viewports_rgba`;
- `post_input_transfer` (`scene_linear` while the scene capture is HDR,
  `srgb_to_scene_linear` otherwise), `post_output_transfer`, the post
  environment revision/composite state, and hardware opaque-coverage recovery
  state.

`get_post_debug_stage_images()` exposes the active Panini target as `panini` for
validation readback and returns null while the pass is bypassed. Runtime does not
perform this readback automatically.

Hardware RT additionally reports acceleration-structure builds, uploads, uniform
sets, dispatch pixels, and available CPU/GPU timings; its render-thread facts may
lag main-thread changes by one rendered frame. Under the raster fallback the
scene, geometry and light counters are all zero, because the fallback keeps no
scene representation; `active_backend` reads `raster` and the post fields are
the meaningful ones.

## Repeatable frame-time benchmark

`res://game/tests/perf_probe.gd` boots the real application shell, enters the
terrain level, parks the FPS camera at a fixed viewpoint, warms up for 300 frames
by default, and reports median and p95 frame intervals over 1,200 frames. It can
also emit the complete RT/profile snapshot, including named per-pass GPU time.
Run comparisons at the same renderer, driver, output size, warmup, measured
frames, camera, FOV, and quality.

The relevant controls are:

- `PERF_PROFILE=1` enables manager and named viewport timings;
- `PERF_PANINI=0` and `PERF_GRADE=0` isolate post stages;
- `PERF_PANINI_SHARPNESS=f` sets the projection capture sharpness, which is the
  single most expensive visual control in the stack;
- `PERF_FOV=120|130|140` selects exact horizontal display coverage;
- `PERF_RASTER=1` forces the raster fallback on a hardware-capable system, so
  both pipelines can be measured on one machine;
- `PERF_WARMUP` and `PERF_FRAMES` override the sampling windows;
- `PERF_SHOT` writes a fixed capture and `PERF_REF` compares it with a previous
  image, subject to the deterministic-capture notes in the project README.

```text
godot --path . --rendering-method forward_plus --resolution 2560x1440 --script res://game/tests/perf_probe.gd
PERF_PROFILE=1 PERF_FOV=140 PERF_RT_QUALITY=3 godot --path . --rendering-method forward_plus --resolution 2560x1440 --script res://game/tests/perf_probe.gd
PERF_PROFILE=1 PERF_RASTER=1 godot --path . --rendering-method forward_plus --resolution 2560x1440 --script res://game/tests/perf_probe.gd
```

`post_pass_gpu_ms.panini` is the projection cost; the steady-state explicit
allocation count must remain zero. Quality and FOV transitions resize/rebind
persistent targets and should be measured separately from unchanged frames.

## Feature and pipeline validation

The checked-in tests divide the contract at useful boundaries. Headless Forward+
has no `RenderingDevice`, so every headless run exercises the raster fallback;
anything that asserts hardware RT needs a real ray-tracing adapter and says so.

- `addons/retro_rt/tests/panini_projection_smoke.gd` tests 120, 130, and 140
  degrees across 4:3, 16:9, 21:9, and 32:9 domains.
  It checks symmetry, finite capture FOVs, aspect-derived vertical extent,
  full-perimeter containment, zero invalid pre-clamp samples, invalid-input
  rejection, agreement between the closed-form capture bounds and an exhaustive
  border scan, and the exact Catmull-Rom/tent-derivative shader contract. It also
  pins the two capture-sizing claims across every output and FOV: the horizontal
  center ratio equals the requested sharpness, and no capture width goes
  unsampled.
- `addons/retro_rt/tests/raster_fallback_smoke.gd` is the fallback's own probe:
  the backend reports `raster`, `rt_pipeline_active` stays false, native shadow
  toggles are untouched, `Environment.ssr_enabled` is turned on and restored on
  teardown, the fog push reaches the managed materials, and the post stack is
  still configured. It runs anywhere, with or without a ray-tracing GPU.
- `addons/retro_rt/tests/ground_layer_smoke.gd` guards the analytic ground
  layer's invariants and compares the three copies of `rt_fog_factor` byte for
  byte, which is the live drift risk now that the fallback fogs its own
  surfaces.
- `addons/retro_rt/tests/receiver_registry_smoke.gd` boots the terrain fixture
  against hardware RT, and skips with a clear message on a machine that has
  none: the receiver registry only exists under hardware RT. With
  `--panini`, it asserts resolve-to-Panini ordering, capture overscan,
  persistent native target/buffer bytes, pass/frame counters, non-perspective
  bypass, and shifted-camera-offset bypass without mutating the authored values.
- `game/tests/player_camera_smoke.gd`, `app_flow_smoke.gd`, and
  `app_recovery_smoke.gd` cover exact horizontal camera semantics, sprint
  clamping/return, dynamic-FOV disable, live settings application while paused,
  menu reopening, and session retention across gameplay reconstruction.
- `game/tests/panini_capture.tscn` boots the complete application and terrain
  level, validates every FOV endpoint plus the grade and posterization
  toggles, sweeps the display FOV across 40 eased angles to prove a moving angle
  never resizes the 3D capture, saves a real graphical capture, and leaves a
  native CanvasLayer status marker above the projected scene.

```text
godot --headless --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/panini_projection_smoke.gd
godot --headless --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/raster_fallback_smoke.gd
godot --headless --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/ground_layer_smoke.gd
godot --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/receiver_registry_smoke.gd -- --panini
godot --path . --rendering-method forward_plus --scene res://game/tests/panini_capture.tscn
godot --path . --rendering-method forward_plus --scene res://game/tests/panini_capture.tscn -- --force-raster
```

Use the same output size and FOV for graphical comparisons. The capture harness
and `PERF_SHOT`/`PERF_REF` provide the current image evidence; these checked-in
harnesses are the source of truth. Both pipelines must report zero invalid
Panini samples, no black borders or culling holes, the correct upstream source
stage, and native UI ordering. Differing shadows and reflections between them
are the intended difference; missing geometry, displaced aim, or a
pipeline-specific post branch is a failure.
