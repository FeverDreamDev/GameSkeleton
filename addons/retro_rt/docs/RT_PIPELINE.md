# Scalable internal-resolution RT and shared visual contract

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
post stack, the distance fog contract, and the quality presets — everything the
image shares with hardware RT.

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
Everything after the 3D pass — SMAA, FSR, Panini, the retro grade, the present —
is identical.

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
  "Why anti-aliasing is SMAA and not MSAA";
- native root `scaling_3d_scale = 1.0` with bilinear/no-upscaler mode;
- no temporal reconstruction, history, motion-vector AA, accumulation,
  denoising, or dynamic resolution;
- texture mip bias `0.0`, 4x anisotropic filtering, and debanding disabled;
- the custom SMAA 1x stack enabled at High quality by default;
- classic Panini projection available after SMAA/EASU and before sharpening;
- shared RetroGrade enabled after Panini and sharpening by default.

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

## RT quality presets and resolution domains

`RTSceneManager.rt_quality` selects one of four fixed internal scales. The enum
is `RTQualityPreset` (`NATIVE`, `QUALITY`, `BALANCED`, `PERFORMANCE`, values
`0`-`3`); the scales live in `RT_QUALITY_SCALES` and the names in
`RT_QUALITY_NAMES`. Native is the default.

| Preset | Enum | Scale | Internal size at 1920x1080 | Relative pixels | Upscaler | Sharpener |
| --- | ---: | ---: | --- | ---: | --- | --- |
| Native | 0 | 1.00 | 1920x1080 | 100% | none (bypass) | optional CAS, off by default |
| Quality | 1 | 0.85 | 1632x918 | 72.25% | FSR 1 EASU | FSR 1 RCAS |
| Balanced | 2 | 0.75 | 1440x810 | 56.25% | FSR 1 EASU | FSR 1 RCAS |
| Performance | 3 | 0.50 | 960x540 | 25% | FSR 1 EASU | FSR 1 RCAS |

Output resolution is 1920x1080 in every row: only the internal domain scales.
The internal sizes above are exact because 1920x1080 divides evenly by all three
reduced scales; other output sizes round up per axis with
`max(2, ceil(output_dimension * scale))`, so odd dimensions are expected and
validated (1151x647 at Quality gives 979x550, not 978x549).

The fixed scale contract is exercised through the runtime profile by
`receiver_registry_smoke.gd` and `game/tests/perf_probe.gd`; changing it also
requires updating the Graphics menu labels and their application smoke tests.

The root viewport, gameplay UI, final CanvasLayer, and final ColorRect always
remain at the visible output size. `Viewport.scaling_3d_scale` remains `1.0`;
quality selection never invokes Godot's root renderer scaler or a separate
compute upscaler.

Only the private scene-capture, SMAA, and SMAA-resolve SubViewports are resized;
they share the internal render size. Each internal dimension is
`max(2, ceil(output_dimension * scale))`. The hardware dispatch and the
fallback's primary raster therefore follow the same internal pixel count. Native
is the default; there is no automatic quality controller, persistence, or
per-platform default.

Reduced presets reconstruct back to the native output size with FSR 1 EASU
followed by RCAS. The FSR EASU SubViewport is the one target sized to the output
rather than the render size, and it exists only while a reduced preset is
active. Expected relative internal pixel workloads are 100%, 72.25%, 56.25% and
25%; EASU, Panini, sharpening, grade, and final presentation always run at 100%.

Runtime callers select a tier with `set_rt_quality()` and can query
`get_rt_quality_scale()`, `get_rt_quality_name()`, and
`get_ray_render_resolution()`. `rt_quality_changed` is a live-change signal;
it is not an initial-state notification during scene deserialization, so a
consumer reads `rt_quality` once in `_ready()` before listening for changes.
`get_full_render_resolution()` continues to mean the native output size.

The authored gameplay camera remains attached to and current in its original
viewport. A private Camera3D is current only in the scene-capture SubViewport
and normally mirrors the authored camera's transform, projection parameters,
offsets, near/far planes, aspect policy, cull mask, Environment, and
CameraAttributes. It never copies the authored camera's `compositor`. Hardware
RT continues to use the compositor installed on the World3D scenario by
RTSceneManager.

Panini is the only intentional camera-parity exception. The authored
`RTPaniniCamera3D` remains perspective, `KEEP_WIDTH`, and at the selected exact
horizontal display FOV. When the pass is eligible, the private camera alone is
switched to the conservative symmetric rectilinear capture frustum derived from
the complete output perimeter. Transform, near/far, cull mask, Environment and
CameraAttributes remain unchanged. Profiling reports this as
`post_internal_camera_capture_override = true`, while preserving the ordinary
camera-resource parity fields.

Hardware RT reserves render layer 20 for the material-ID carrier. While the
carrier is active, each managed renderer instance is placed on that layer alone
and authored lights have that layer removed from their renderer cull masks. This
skips Godot's otherwise-empty raster `light()` invocation for every authored
light over managed pixels. Both changes are `RenderingServer` overrides: the
authored `MeshInstance3D.layers` and `Light3D.light_cull_mask` properties remain
unchanged and are still what the shared receiver/light candidate lists publish.
The raster fallback installs neither override, so it keeps the authored renderer
masks and the authored shadow toggles.

Because the private capture camera mirrors rather than widens the gameplay
camera mask, a hardware camera must include layer 20. Startup and runtime camera
switches validate that bit and fail with the camera path and reserved layer when
it is missing; the add-on never silently edits the authored mask.

## Shared post-processing: SMAA 1x, FSR 1, and Panini

Every runtime backend uses `RTPostProcessStack`. Anti-aliasing is SMAA 1x on
every backend and every preset. Reduced presets reconstruct with AMD FidelityFX
Super Resolution 1. An eligible FPS camera then applies classic Panini at native
output size. SMAA finishes completely before EASU, and Panini finishes before
CAS/RCAS and the artistic grade.

Native (`rt_render_scale == 1.0`):

```text
internal-resolution 3D scene / RT result  (internal size == output size)
    -> transparent internal scene capture
    -> per-texel scene-linear visible reconstruction (geometry + environment + fog)
    -> one normalized HDR-to-SDR clamp
    -> SMAA color edge detection
    -> SMAA blend-weight calculation
    -> SMAA neighborhood blending
    -> scene-linear-to-sRGB into the resolve target
    -> classic Panini D=1, S=0                       (native output size)
    -> optional FidelityFX CAS (off by default)
    -> sRGB-to-scene-linear, RetroGrade, display-range clamp
    -> explicit scene-linear-to-sRGB transfer
    -> final scene CanvasLayer (-100)
    -> normal gameplay Canvas/UI
```

Quality, Balanced and Performance (`rt_render_scale < 1.0`) insert EASU before
Panini and select RCAS after it:

```text
    ... SMAA neighborhood blending                   (internal render size)
    -> scene-linear-to-sRGB into the resolve target  (internal render size)
    -> FSR 1 EASU                                    (native output size)
    -> classic Panini D=1, S=0                       (native output size)
    -> FSR 1 RCAS
    -> sRGB-to-scene-linear, RetroGrade, display-range clamp
    ...
```

There is no bilinear reconstruction path. FSR 1 is the only upscaler, and it is
never bypassed at a reduced preset.

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
orthographic, and frustum cameras bind the SMAA-resolve or EASU source directly
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
symmetric perspective capture that contains it. That conservative private-camera
overscan prevents black borders, clamped corners, and culling holes without
altering the authored camera.

One corner is sufficient because the mapping is monotonic on both axes:
`mapped.x = tan(phi)` is odd and strictly increasing in output NDC x across the
supported `|phi| < 90` degrees, and `mapped.y` is linear in output NDC y and
strictly increasing in `|phi|`. Both extrema therefore land on the four logical
corners. The CPU still caches every output-border texel center plus those four
corners whenever output size changes, and `post_panini_perimeter_samples` still
reports that set, but the perimeter is now only scanned on the exceptional
invalid-contract path to retain an exact `invalid_samples` diagnostic. The
closed form is what keeps the smoothed sprint FOV, which moves every frame, off
a scan that cost about 2 ms per frame at 1080p and 3.2 ms at 3440x1440;
`panini_projection_smoke.gd` pins the closed form against a full border scan.

The GLES3-safe canvas shader reconstructs with a five-tap Catmull-Rom where the
warp magnifies and uses exactly four bilinear samples at the positive/negative
derivative corners where it minifies. The diagnostic contract names this
`catmull_rom_or_box`. Catmull-Rom is there because the capture camera is always
wider than the display FOV, so the image center is magnified by 2.8x
horizontally at 130 degrees and 3.9x at 140; a single bilinear tap over that
magnification is what made the center read as soft. The kernel is renormalized
over its five kept taps, so it is exactly transparent at 1:1 and shifts no
brightness on a flat field, and it fades to that single bilinear tap as the
footprint approaches 1:1 so the two branches meet with no ring. Its negative
lobes are clamped to the `[0,1]` range the upstream resolve already guarantees.
It uses no compute, history, `textureGather`, dynamic allocation, or
renderer-specific branch. The native-size Panini SubViewport is persistent,
resized in place, rebound across quality changes, and set to `UPDATE_DISABLED`
while bypassed.

Panini magnifies the center on every preset, but only the reduced presets get a
sharpener after it for free, because RCAS is part of FSR. `main.tscn` therefore
enables `post_cas_enabled` so Native is not the one preset presenting an
unsharpened magnification; measured against the acceptance capture, CAS at the
default 0.15 sharpness recovers about 21 percent more center gradient energy.
The reusable add-on still defaults CAS off.
`generated/shader_warmup_manifest.tres` includes `panini_project.gdshader`; rerun
the normal warmup generator whenever this shader or its material parameters
change.

Which branch a preset takes, and what the profile reports for it:

| Preset | `post_fsr_active` | `post_upscale_method` | `post_sharpen_mode` | `post_easu_frames` | EASU target |
| --- | --- | --- | --- | --- | --- |
| Native | `false` | `none` | `none`, or `cas` if enabled | `0` | not allocated |
| Quality | `true` | `fsr1_easu_rcas` | `rcas` | increments | output size |
| Balanced | `true` | `fsr1_easu_rcas` | `rcas` | increments | output size |
| Performance | `true` | `fsr1_easu_rcas` | `rcas` | increments | output size |

The branch is chosen purely by `render_size != output_size`, not by the preset
enum, so a future scale of exactly `1.0` on a non-Native preset would also take
the bypass. See "RT quality presets and resolution domains" for the scales and
internal sizes themselves.

### Why anti-aliasing is SMAA and not MSAA

MSAA is force-disabled by `RTVisualContract` on the root and on every owned
SubViewport, and that is a hard architectural requirement rather than a
preference. Hardware RT is a deferred visibility-buffer renderer:
`BlinnPhong.gdshader` packs a 21-bit instance ID plus material ID into the
separate-specular target through `encode_rt_visibility_id()`, and
`rt_shadow_reflect.glsl` decodes it with `round(clamp(encoded, 0, 2047))` before
writing results back with `imageStore`. Multisampling breaks every part of that
contract: an `image2D` cannot bind a multisampled attachment; the effect runs at
`POST_SKY` with `access_resolved_color`/`access_resolved_depth` false, so its
writes would be discarded by the later resolve; and resolve averages samples,
which destroys a packed integer ID at exactly the silhouette pixels MSAA exists
to fix. Supporting it would require either a separate non-MSAA visibility pass
or one ray per coverage sample, and the RT ray count is deliberately tied to
internal pixel dimensions rather than sample count.

SMAA 1x remains a sharp, spatial, non-temporal solution that runs as an ordinary
canvas shader pipeline, so the whole post stack is SubViewports rather than a
second RenderingDevice pipeline. It handles long diagonals and corner patterns
more deliberately than a single-pass FXAA approximation without requiring
history or motion vectors.

### SMAA completes at the internal render size

All three SMAA passes and the resolve that consumes them run at `render_size`.
The neighborhood blend used to be fused into the native-resolution presentation
shader, where it doubled as a four-tap bilinear upscale; it is now its own
`SMAAResolve` pass in the internal pixel domain. Two things follow. FSR 1 EASU
receives a genuinely anti-aliased image, which it requires. And both sharpeners
can read a neighborhood of the post-SMAA result at all, which a fused pass
cannot provide.

`SMAAResolve` writes perceptual (sRGB-encoded) color. EASU, RCAS and CAS are all
specified against display-like color in the 0..1 range rather than linear
radiance, so the encode happens once here and the present pass performs the
single decode back to scene-linear before the artistic grade. SMAA itself still
blends in scene-linear on every renderer.

SMAA's own sub-texel bilinear tap inside the neighborhood blend remains: it
reads across an edge at a fractional offset and is intrinsic to the algorithm.
It is a same-resolution filter and must never become a resolution-changing
resample again.

It applies to edge pixels only. A pixel with no blend weight — the large majority
of a frame — takes the exact 1:1 texel decode instead, which is the same path the
pass presents with when custom AA is disabled and what the reference algorithm
returns for that case. The four-tap read is not merely unnecessary there: at 1:1
its weights are zero, so three of its four `decode_scene_texel()` calls, each with
its own environment reconstruction, were computed and then multiplied away.

That environment reconstruction is itself now skipped wherever geometry covers
the pixel completely, in both the resolve and the edge detector. The term is
`rt_post_sample_environment(...) * (1.0 - coverage)`, `rt_post_scene_coverage()`
returns exactly `1.0` for opaque raster and for the recovered managed case, and
`rt_post_sample_environment()` is always finite — so this is an equivalence
rather than an approximation, and it was verified as a zero-pixel difference over
a full frame. A scene that draws its background as geometry rather than leaving it
to the environment, such as the day/night sky dome, takes that branch everywhere:
the reconstruction exists for backgrounds that show through, and there it never
contributes. Together the two removed roughly 0.85 ms of a 6.8 ms frame at
2560x1440 on an RTX 4060.

The edge detector uses the maximum RGB color delta and the reference local
contrast adaptation, rather than luminance-only edges or Forward+-only depth,
normal, or G-buffer predication. It reconstructs the visible environment before
testing silhouettes, so a geometry/sky boundary is judged from the colors that
will actually be presented.

The weight shader is a Godot-language SMAA 1x port. Its rectilinear area lookup
uses the reference component-wise square-root distance encoding and subtexture
index zero. Its diagonal searches retain the reference end corrections,
quarter-texel crossing offsets, crossing-edge merge, and raw diagonal-distance
area lookup; diagonal results take priority over vertical processing. High
enables the reference diagonal/corner paths. `AreaTexDX10.dds` and
`SearchTex.dds` are the unmodified official lookup data; both use linear/clamp
sampling and neither repeats or uses mipmaps. Their MIT notice is kept in
`post_processing/smaa/LICENSE-SMAA.txt`.

When custom AA is disabled, the edge and blend SubViewports stop updating and
`SMAAResolve` degrades to an exact 1:1 texel decode. It keeps running either
way, because it is also the FSR/present source. RetroGrade remains independently
switchable.

### FSR 1

`fsr_common.gdshaderinc` ports EASU, RCAS and CAS from AMD's reference
`ffx_fsr1.h` and `ffx_cas.h`. Constraints that keep the port inside the shared
SubViewport post stack:

- no compute shaders and no RenderingDevice-only APIs, so the pass stays inside
  the SubViewport post stack rather than standing up a second pipeline;
- no FSR2, no temporal accumulation, no motion vectors, no history — FSR 1 is
  spatial, and that is the whole reason it is usable here;
- no `textureGather`. The reference EASU gathers three channels; this port
  fetches the same 12 texels with `texelFetch`. The rule originally existed for
  the Compatibility renderer, which is gone, so a gather port is now possible —
  it would be an optimization, not a correctness fix, and has not been measured.
  The kernel stays EASU rather than a bicubic, Lanczos or generic-sharpening
  substitute;
- no 16-bit packed path — the full float path only;
- every fetch coordinate is clamped, so no pass samples out of bounds and no
  black border pixels appear at the frame edge.

The reference's fast approximate reciprocals return a large finite value for
`1/0`, which the surrounding saturates absorb. Exact division would produce
`inf` and then `0*inf = NaN`, so each one is replaced by an exact division with
the degenerate case handled explicitly. That is more accurate than the
reference, never less.

EASU maps output pixels to source texel space with the reference `con0`
relationship, `(output_pixel + 0.5) * (input_size / output_size) - 0.5`. Both
constants are refreshed by `_resize()` whenever either dimension moves, so a
window resize and a quality switch are equally safe and no fixed 16:9 output
resolution is assumed.

RCAS's limiter clamps its numerators against the center sample as well as the
ring — `min(mn4, e)` and `max(mx4, e)`, matching the reference — while the
denominators stay on the ring extremes. This only matters when the center sits
outside its four neighbors, which is exactly the lone-bright-or-dark-pixel case
that rings. Solving the filter for `result >= 0` gives `w >= -e/(4*mx4)`, so the
numerator has to see `e`; a ring-only limiter authorizes a lobe that overshoots.
A black pixel on a uniform `0.5` ring resolves to about `-0.56` without the
clamp and is correctly left untouched with it; ordinary neighborhoods remain
unchanged.

### Native is a true bypass

At Native the stack does not create the EASU SubViewport at all. EASU does zero
work, RCAS does zero work, no bilinear upscale runs, and no upscale buffer is
allocated. `get_debug_contract_snapshot()` reports `easu_viewport_size`,
`easu_uniform_input_size` and `easu_uniform_output_size` as zero and `fsr_active`
as false; the profile reports `post_upscale_method` as `none`. The present pass
reads the native resolve through Panini when the current camera is eligible, or
reads resolve directly when it is not. Native is therefore a true *FSR* bypass;
Panini eligibility is independent of quality.

`_resize()` owns the whole FSR lifecycle, because it is the single place both
sizes are recomputed. Entering the FSR path allocates the EASU material and
viewport once; a later size change resizes them in place rather than
reallocating. Leaving the FSR path rebinds the present pass to the resolve
target *before* the upscale viewport leaves the tree, so no `ViewportTexture` is
left dangling and no frame is presented from a freed target. Nothing here is
allocated per frame.

### Sharpening

RCAS is used only as part of the FSR path and never at Native. CAS is the
Native-only optional sharpener and is off by default, so Native ships as the
reference image. The two are never stacked: `sharpen_mode` is `rcas` whenever
FSR is active, otherwise `cas` when CAS is enabled, otherwise `none`.

`post_fsr_sharpness` is the reference RCAS attenuation in stops per
`FsrRcasCon`, applied as `exp2(-value)`. Note the inverted sense: `0.0` is
maximum sharpness and `2.0` the minimum. The default `0.5` is mid-range and
deliberately conservative, because hard Blinn-Phong highlights, hard RT shadows
and high-contrast geometry ring easily. `post_cas_sharpness` is on the standard
CAS `0..1` scale, which the reference `CasSetup` maps to
`peak = -1/lerp(8, 5, sharpness)`; `0.15` is the recommended starting point.

Native-resolution sharpening is CAS specifically because RCAS belongs to FSR and
is bypassed along with it.

### Targets and precision

Scene, edge, blend and resolve SubViewports all request `use_hdr_2d = true`, and
so do the persistent Panini target and the EASU target while it exists, but this
is honored: Forward+ gives every one of them RGBA16F, and the profile reports an
HDR scene capture plus HDR data targets. The targets are also `transparent_bg`,
which guarantees all four SMAA directional weight channels are present rather
than RGB-only. The `post_*_hdr_requested`, `post_*_hdr`, and
`post_data_viewports_rgba` profile fields remain, and still distinguish the
requested state from what the renderer actually supplied.

Intermediate SubViewports are persistent and resize only when the output size or
quality preset changes; they are not reallocated per frame. Every SMAA
`viewport_size` uniform receives the internal render size, because its texel
offsets address the scaled source textures. The Panini target is always allocated
at native output size and is disabled rather than freed while bypassed. Its input
is always 1:1 — resolve at Native or EASU at a reduced preset — and the final
present source is Panini when active or that same upstream image when bypassed.

Posterization happens after AA and remains intentionally crisp. There is one
grade path, shared by both pipelines; there is no separate compute grade for
hardware.

### Artist controls

- `post_anti_aliasing_enabled`;
- `post_smaa_quality` (`LOW`, `MEDIUM`, or `HIGH`);
- `post_fsr_sharpness` (RCAS attenuation in stops; reduced presets only);
- `post_cas_enabled` and `post_cas_sharpness` (Native only);
- `post_panini_enabled` (manager-wide request; camera capability still gates it);
- `retro_post_enabled`;
- brightness, contrast, saturation, black point, and color balance;
- posterization enable, levels, and strength.

The SMAA presets are fixed shared behavior rather than renderer-specific
quality overrides:

| Preset | Threshold | Search steps | Diagonal steps | Corner detection |
| --- | ---: | ---: | ---: | --- |
| Low | 0.15 | 4 | 0 | off |
| Medium | 0.10 | 8 | 0 | off |
| High | 0.10 | 16 | 8 | on, rounding 0.25 |

The final scene is presented on CanvasLayer `-100`. Gameplay UI should remain on
the default canvas or a higher CanvasLayer, so it is not graded, posterized,
anti-aliased, upscaled, or Panini-projected as part of the 3D image. EASU and
Panini operate only on the private rendered 3D scene; fonts, reticles, HUD
elements, and menus stay at native resolution. `panini_capture.tscn` leaves a
known status marker above the scene to make that ordering visible.

## Color, exposure, and texture sampling

Forward+ honors the HDR 2D scene-capture request. The capture is sampled as
scene-linear data and can carry radiance above `1.0` until the common
pre-SMAA/display-range boundary. The `scene_input_is_linear` uniform the edge
and resolve shaders read follows `use_hdr_2d`, and exists to decode a
non-linear capture back to scene-linear if one is ever configured.

Both pipelines reconstruct the same visible environment, clamp normalized linear
scene color once before SMAA, and run the same SMAA and RetroGrade math. The
resolve pass encodes to perceptual color for FSR/CAS, and the present shader
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
the active camera's corner rays before SMAA. This prevents native Forward+ sky
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
- `post_anti_aliasing_enabled`, integer `post_smaa_quality`, and
  `post_smaa_quality_name`;
- `post_fsr_active`, `post_upscale_method` (`none` or `fsr1_easu_rcas`),
  `post_fsr_input_size`, `post_fsr_output_size`, `post_easu_viewport_size`,
  `post_fsr_sharpness`, `post_sharpen_mode` (`none`, `cas`, or `rcas`),
  `post_cas_enabled`, and `post_cas_sharpness`. At Native the sizes are zero and
  the method is `none`, which is how a true FSR bypass is asserted;
- `post_panini_requested`, camera capable/enabled/eligible state,
  `post_panini_enabled`, and `post_panini_bypass_reason`; projection/filter
  identity, persistent target and source stage/size; display and conservative
  capture horizontal/vertical FOVs; mapped rect and source-UV bounds; perimeter
  sample and invalid-sample counts; `post_panini_bounds_valid`; and dedicated
  `post_panini_buffer_bytes`;
- `rt_quality_preset`, `rt_quality_name`, `ray_tracing_requested_scale`,
  per-axis `ray_tracing_effective_scale`, `ray_tracing_full_resolution`,
  `ray_tracing_resolution`, `ray_tracing_resolution_method`, and rendered or
  dispatched pixel count;
- `post_output_size`, `post_render_size`, `post_requested_render_scale`,
  per-axis `post_effective_render_scale`, `post_resolution_method`,
  `post_rendered_pixels`, `post_smaa_viewport_size`, and
  `post_persistent_buffer_bytes`; camera diagnostic fields report the source
  identity, active state, visual-state and resource matches, null internal
  compositor, and the intentional Panini capture-FOV override;
- `post_native_size` (legacy output-size alias), instrumented
  `post_per_frame_allocation_count`/peak, initialization and total explicit
  post-object allocation counts, resize count/timing,
  `post_scene_capture_frames`, `post_edge_frames`, `post_blend_frames`,
  `post_resolve_frames`, `post_easu_frames` (zero at Native), and
  `post_panini_frames` (increments only while eligible).
  The per-frame counters measure explicit Node/Resource construction inside the
  stack's frame update, including a settings update issued earlier in the same
  manager frame. Normal unchanged frames report zero because every viewport,
  material, and pass node is reused; a revision that rebuilds the temporary
  visual-contract Resource is visible in the current/peak counter.
  The persistent byte count is the owned color targets only: four render-size
  targets (scene, edges, weights, resolve) at 8 bytes per pixel, since Forward+
  honors the RGBA16F request, plus one persistent output-size Panini target and
  one additional output-size EASU target while a reduced preset is active. It
  excludes depth/render buffers and the SMAA LUTs.
  `get_post_debug_contract_snapshot()` exposes the same target as
  `panini_buffer_bytes`;
- `post_pass_gpu_ms` names the measured `scene`, SMAA, optional `fsr_easu`,
  `panini`, and `root_present` viewport costs while profiling is enabled;
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
- `PERF_PANINI=0`, `PERF_SMAA=0`, and `PERF_GRADE=0` isolate post stages;
- `PERF_FOV=120|130|140` selects exact horizontal display coverage;
- `PERF_RT_QUALITY=0|1|2|3` selects Native through Performance;
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
  degrees across 4:3, 16:9, 21:9, and 32:9 domains and all four render scales.
  It checks symmetry, finite capture FOVs, aspect-derived vertical extent,
  full-perimeter containment, zero invalid pre-clamp samples, invalid-input
  rejection, agreement between the closed-form capture bounds and an exhaustive
  border scan, and the exact Catmull-Rom/box-derivative shader contract.
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
  `--panini`, it asserts native resolve-to-Panini ordering, capture overscan,
  persistent native target/buffer bytes, pass/frame counters, non-perspective
  bypass, and shifted-camera-offset bypass without mutating the authored values.
  `--panini-performance` additionally asserts EASU-to-Panini-to-RCAS ordering.
- `game/tests/player_camera_smoke.gd`, `app_flow_smoke.gd`, and
  `app_recovery_smoke.gd` cover exact horizontal camera semantics, sprint
  clamping/return, dynamic-FOV disable, live settings application while paused,
  menu reopening, and session retention across gameplay reconstruction.
- `game/tests/panini_capture.tscn` boots the complete application and terrain
  level, validates every FOV/quality/SMAA endpoint plus sharpening and grade
  toggles, saves a real graphical capture, and leaves a native CanvasLayer
  status marker above the projected scene.

```text
godot --headless --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/panini_projection_smoke.gd
godot --headless --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/raster_fallback_smoke.gd
godot --headless --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/ground_layer_smoke.gd
godot --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/receiver_registry_smoke.gd -- --panini
godot --path . --rendering-method forward_plus --script res://addons/retro_rt/tests/receiver_registry_smoke.gd -- --panini-performance
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
