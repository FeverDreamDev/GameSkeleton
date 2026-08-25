# Scalable internal-resolution RT and shared visual contract

This is the architecture and validation spec for the Retro RT add-on. For
installation, the scene contract and the public API, read `../README.md` first —
this document assumes you already have RT running and explains why it is built
the way it is.

Command lines below that reference `res://scenes/…`, `res://tools/…` and
`res://builds/…` belong to the benchmark, feature-validation and renderer-parity
harnesses, which ship with the add-on's development repository rather than with
the add-on itself.

This Godot 4.7.1 project targets visual equivalence between Forward+ and
Compatibility through one scene, material, lighting, ray, texture, environment,
anti-aliasing, and output contract. Forward+ hardware RT, Forward+ forced
software RT, desktop Compatibility software RT, and Web Compatibility all feed
the same fullscreen post stack.

Visual equivalence is the target, not cross-API bit identity. Godot still owns
different rasterizers, depth formats, render-target formats, shader compilers,
and floating-point implementations. Small edge/intersection differences may
remain, and the parity workflow below measures them instead of hiding them
behind an exact cross-renderer hash.

## Backend selection and editor preview

`RTSceneManager.rt_backend` accepts `AUTO`, `HARDWARE`, or `SOFTWARE`.

- `AUTO` selects hardware RT only for a non-Web Forward+ Vulkan run whose
  RenderingDevice exposes buffer-device-address and ray-tracing-pipeline
  support. All other supported runs select software RT.
- Explicit `HARDWARE` or `SOFTWARE` selection is used by validation. An
  unavailable forced backend fails visibly instead of silently changing paths.
- Compatibility, Web, and non-Vulkan Forward+ use software RT. Web never
  creates a compute pipeline or an acceleration-structure RID.
- `get_active_rt_backend()` reports `hardware`, `software`, or `none`.

The editor scene viewport previews real ray tracing, and it always previews it
through `RTSoftwareTracer` regardless of `rt_backend`. The software backend's
overrides are renderer-only `RenderingServer.instance_set_*` state that restores
cleanly and never touches authored resources, so a scene that is only partly
assembled degrades to ordinary raster. The hardware path would instead install a
CompositorEffect on the edited scene's `World3D` scenario, affecting every editor
viewport on that world, and switch managed materials into the visibility-buffer
transport, which renders as garbage whenever the compositor is missing. The
fidelity cost of previewing software is bounded by the measured hardware/software
parity result.

The editor preview deliberately stops there: it does **not** run the shared
fullscreen post stack. `RTPostProcessStack.configure()` sets `disable_3d = true`
on the root viewport and presents through a `CanvasLayer`, which in the editor
would blank the viewport and its gizmos. Editor preview therefore means RT
shadows and reflections against the normal editor background, with no retro
grade, no SMAA, and no FSR. The runtime remains the authoritative image.

Editor preview also never suppresses `Environment.reflected_light_source`. That
is the one override the manager writes to an authored Resource rather than to
the RenderingServer, and the software clones are `unshaded,
ambient_light_disabled` anyway, so skipping it keeps scene files clean.

`preview_in_editor` controls that preview. Enabling it schedules a debounced
build; disabling it tears the preview down completely — tracer clones freed,
surface overrides returned to their authored values, carrier uniforms cleared,
and native light shadows restored — leaving the shader's standalone raster
fallback as the authored default. Scene changes, script reload, manager removal,
and editor shutdown perform the same teardown.

Failures never latch in the editor. Adding a mesh with no managed material, or
any other break in the RT scene contract, tears the preview down to plain raster,
reports once through `push_warning`, and retries on a backoff poll; the runtime's
permanent `_fail()` state is not entered. Mesh additions, removals, replacements,
and mesh-resource edits trigger a debounced rebuild rather than the runtime's
hard topology failure, because BLASes are immutable once built. Light additions,
removals, transforms, and material property edits are absorbed incrementally with
no rebuild.

Headless editor runs (import, export) install no preview and stop processing.

Hardware RT uses BLAS/TLAS resources, a POST_SKY compositor effect, and the
material/instance carriers in `BlinnPhong.gdshader`. It relies on the Godot
4.7.1 Forward+ `forward_clustered` normal/roughness and specular buffers.

Software RT never creates ray-tracing pipelines. It rasterizes primary
visibility with `BlinnPhongSoftware.gdshader` and traverses the project BVH from
the spatial fragment shader. The same path runs under Forward+, Compatibility,
and Web.

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
- shared RetroGrade enabled after SMAA by default.

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

Copies live in `shaders/rt_shadow_reflect.glsl`,
`shaders/BlinnPhongSoftwareBody.gdshaderinc`, and
`addons/procedural_terrain_grass/shaders/grass_shell.gdshader`.

Every path composites `final = lit * (1 - f) + fog_color * f`:

| Path | Application |
| --- | --- |
| Hardware | `scene_color = mix(ambient + emission + reflection, miss_color, f)` and `separate_specular = direct * (1 - f)`. Forward+ adds the two buffers. |
| Software | `ALBEDO = mix(base_lighting + direct_lighting, miss_color, f)`, before the Compatibility sRGB compensation. |
| Unmanaged | `ALBEDO *= (1 - f)`, `EMISSION = fog_color * f`, `SPECULAR *= (1 - f)`. Scaling `ALBEDO` attenuates the diffuse and ambient terms; `EMISSION` adds the fog back. |

Fog is applied once, to the primary hit. Reflected radiance inherits the
reflector's fog rather than the reflected path length; both RT backends do this
at the same point, so they stay matched.

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

These four values are duplicated on purpose in the validation and benchmark
harnesses (`FeatureValidation._quality_scale()`,
`RTBenchmark._quality_scale()`) so that changing `RT_QUALITY_SCALES` alone makes
those harnesses fail rather than silently follow. `TestUi` bakes the
percentages into its dropdown labels and would need updating by hand.

The root viewport, gameplay UI, final CanvasLayer, and final ColorRect always
remain at the visible output size. `Viewport.scaling_3d_scale` remains `1.0`;
quality selection never invokes Godot's root renderer scaler or a separate
compute upscaler. This is especially important on Web, where reducing the root
3D scale is affected by Godot issue
[#119317](https://github.com/godotengine/godot/issues/119317).

Only the private scene-capture, SMAA, and SMAA-resolve SubViewports are resized;
they share the internal render size. Each internal dimension is
`max(2, ceil(output_dimension * scale))`. Hardware dispatch and software primary
raster/BVH work therefore follow the same internal pixel count. Native is the
default on every platform; there is no automatic quality controller,
persistence, or Web-only default.

Reduced presets reconstruct back to the native output size with FSR 1 EASU
followed by RCAS. The FSR EASU SubViewport is the one target sized to the output
rather than the render size, and it exists only while a reduced preset is
active. Expected relative internal pixel workloads are 100%, 72.25%, 56.25% and
25%; the upscale and present passes always run at 100%.

Runtime callers select a tier with `set_rt_quality()` and can query
`get_rt_quality_scale()`, `get_rt_quality_name()`, and
`get_ray_render_resolution()`. `rt_quality_changed` is a live-change signal;
it is not an initial-state notification during scene deserialization, so a
consumer reads `rt_quality` once in `_ready()` before listening for changes.
`get_full_render_resolution()` continues to mean the native output size.

The authored gameplay camera remains attached to and current in its original
viewport. A private Camera3D is current only in the scene-capture SubViewport
and mirrors the authored camera's transform, projection parameters, offsets,
near/far planes, aspect policy, cull mask, Environment, and CameraAttributes.
It never copies the authored camera's `compositor`. Hardware RT continues to
use the compositor installed on the World3D scenario by RTSceneManager.

## Shared post-processing: SMAA 1x and FSR 1

Every runtime backend uses `RTPostProcessStack`. Anti-aliasing is SMAA 1x on
every backend and every preset. Resolution reconstruction is AMD FidelityFX
Super Resolution 1. The order is deliberate: SMAA finishes completely before FSR
starts, because FSR 1 requires an anti-aliased input.

Native (`rt_render_scale == 1.0`):

```text
internal-resolution 3D scene / RT result  (internal size == output size)
    -> transparent internal scene capture
    -> per-texel scene-linear visible reconstruction (geometry + environment)
    -> one normalized HDR-to-SDR clamp
    -> SMAA color edge detection
    -> SMAA blend-weight calculation
    -> SMAA neighborhood blending
    -> scene-linear-to-sRGB into the resolve target
    -> optional FidelityFX CAS (off by default)
    -> sRGB-to-scene-linear, RetroGrade, display-range clamp
    -> explicit scene-linear-to-sRGB transfer
    -> final scene CanvasLayer (-100)
    -> normal gameplay Canvas/UI
```

Quality, Balanced and Performance (`rt_render_scale < 1.0`) insert exactly two
passes into that chain and change nothing else:

```text
    ... SMAA neighborhood blending                   (internal render size)
    -> scene-linear-to-sRGB into the resolve target  (internal render size)
    -> FSR 1 EASU                                    (native output size)
    -> FSR 1 RCAS
    -> sRGB-to-scene-linear, RetroGrade, display-range clamp
    ...
```

There is no bilinear reconstruction path. FSR 1 is the only upscaler, and it is
never bypassed at a reduced preset.

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

SMAA 1x remains a sharp, spatial, non-temporal solution that runs as the same
canvas shader pipeline on Forward+, desktop Compatibility and Web. It handles
long diagonals and corner patterns more deliberately than a single-pass FXAA
approximation without requiring history or motion vectors.

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
`ffx_fsr1.h` and `ffx_cas.h`. Constraints that keep Compatibility and Web
first-class:

- no compute shaders, no RenderingDevice-only APIs, no Vulkan-only or
  Forward+-only functionality;
- no FSR2, no temporal accumulation, no motion vectors, no history — FSR 1 is
  spatial, and that is the whole reason it is usable here;
- no `textureGather`. The reference EASU gathers three channels; this port
  fetches the same 12 texels with `texelFetch`, which is core in GLSL ES 3.0.
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
clamp and is correctly left untouched with it. On the parity fixture the clamp
changes 11 pixels out of 746,496 by more than `4/255`, peaking at `10/255`, and
is bit-identical everywhere else.

### Native is a true bypass

At Native the stack does not create the EASU SubViewport at all. EASU does zero
work, RCAS does zero work, no bilinear upscale runs, and no upscale buffer is
allocated. `get_debug_contract_snapshot()` reports `easu_viewport_size`,
`easu_uniform_input_size` and `easu_uniform_output_size` as zero and `fsr_active`
as false; the profile reports `post_upscale_method` as `none`. The present pass
simply samples the native resolve target. Native is therefore the clean
reference-quality mode.

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
so does the EASU target while it exists, but this is not the same physical
format on every renderer. Forward+ honors the request and the profile reports an
HDR scene capture plus HDR data targets. Godot Compatibility/Web ignores HDR 2D;
the supported fallback is a transparent RGBA8 target. Transparency guarantees
all four directional weight channels remain present, but the fallback has lower
precision. The `post_*_hdr_requested`, `post_*_hdr`, and
`post_data_viewports_rgba` profile fields distinguish requested state from the
format the active renderer can actually supply.

On Compatibility/Web the resolve target is RGBA8, so SMAA's sub-8-bit edge blend
is re-quantized once before the grade. That is the same precision the scene
capture already carries on that renderer, and the final output is 8-bit sRGB
regardless, but it is a real difference from the previous fused pass and is why
the Native reference SHA was re-baselined.

Intermediate SubViewports are persistent and resize only when the output size or
quality preset changes; they are not reallocated per frame. Every SMAA
`viewport_size` uniform receives the internal render size, because its texel
offsets address the scaled source textures. The present pass deliberately has no
such uniform: its source is always 1:1 with the rect it covers — the resolve
target at Native, the EASU target at every reduced preset.

Posterization happens after AA and remains intentionally crisp. There is no
separate compute grade for hardware and no Compatibility-only grade path.

### Artist controls

- `post_anti_aliasing_enabled`;
- `post_smaa_quality` (`LOW`, `MEDIUM`, or `HIGH`);
- `post_fsr_sharpness` (RCAS attenuation in stops; reduced presets only);
- `post_cas_enabled` and `post_cas_sharpness` (Native only);
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
anti-aliased, or upscaled as part of the 3D image. FSR reconstructs only the
private rendered 3D scene; fonts, HUD elements and other game UI stay at native
resolution. The parity fixture samples a known UI marker from the final
screenshot to enforce that ordering.

## Color, exposure, and texture sampling

Forward+ honors the HDR 2D scene-capture request. Its capture is sampled as
scene-linear data and can carry radiance above `1.0` until the common
pre-SMAA/display-range boundary. Compatibility/Web cannot honor that target:
its scene capture is renderer-produced sRGB RGBA8, and the edge/resolve shaders
decode the straight (un-premultiplied) captured color once back to
scene-linear. Radiance already clipped or rounded by that Compatibility target
cannot be reconstructed; this is an explicit platform limitation, not a claim
of identical intermediate precision.

After that input boundary, both paths reconstruct the same visible environment,
clamp normalized linear scene color once before SMAA, and run the same SMAA and
RetroGrade math. The resolve pass encodes to perceptual color for FSR/CAS, and
the present shader decodes once, performs the post-grade display clamp, and
emits one explicit scene-linear-to-sRGB transfer into the deliberately LDR root
canvas. Environment tonemapping is neutral Linear/1.0. There is no
shader-authored 8-bit quantization; Compatibility/Web's RGBA8 capture/data
targets and the final PNG are unavoidable storage boundaries, while explicit
posterization remains an artist control.

Directly visible albedo and normal maps use repeating, mipmapped, anisotropic
sampling in both Blinn-Phong shaders. The shared viewport contract fixes 4x
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
environment remains in the parity fixture.

The software data/atlas representation remains bounded and deterministic:

1. three nearest, non-mipmapped RGBAF data textures carry BLAS/TLAS,
   material/light, receiver lists, and settings;
2. separate static RGBA8 albedo and normal atlases preserve source-color versus
   linear-normal semantics;
3. runtime-only software material clones bind those resources and restore the
   authored materials on teardown.

Assigned map references and pixel content are static atlas inputs. Changing
either requires a scene reload and fails explicitly if detected during a run.

## Environment and reflection misses

Reflection misses now use the same effective background that is visible to the
scene. Resolution precedence is active camera Environment, the manager's
explicit `world_environment_path`, World3D Environment, then World3D fallback.
Runtime initialization fails visibly when none of those supplies an Environment.
`BG_CLEAR_COLOR` reads the project/default clear color only after an effective
Environment has selected that background mode.

The scene capture is transparent and the final shared canvas shader reconstructs
that same immutable environment snapshot behind every exact geometry texel from
the active camera's corner rays before SMAA. This prevents native
Forward+/Compatibility sky tonemapping from becoming a second visible-background
path. Background radiance and reflection misses therefore share panorama
texels, energy, rotation, seam wrapping, and pole clamping.

- `BG_CLEAR_COLOR` and `BG_COLOR` produce a linear flat miss radiance with the
  Environment background energy applied.
- Every `BG_SKY` first calls public
  `RenderingServer.sky_bake_panorama(..., bake_irradiance = false, ...)`. The
  call must succeed on the active renderer; failure is reported and is never
  replaced by a flat color. Procedural, Physical, and custom sky materials use
  that linear, untone-mapped result directly, with no source-color decoding.
- `PanoramaSkyMaterial` also requires a CPU-readable source texture. After the
  public bake succeeds, the manager canonicalizes that source to the same
  RGBAF panorama on every renderer because Godot 4.7 Compatibility can
  reinterpret a runtime RGBAF Panorama differently from Forward+. Floating
  source formats are treated as linear; integer/color formats receive one sRGB
  decode; Environment and Panorama material energy multipliers are then
  applied. Profiles identify this path as `panorama_source_canonical`.
  Runtime producers may retain their original float CPU `Image` on the texture
  as `rt_linear_panorama_image`; this avoids Web texture readback normalizing an
  otherwise valid HDR source. The canonicalizer copies the retained image and
  never mutates producer-owned pixels.
- The immutable panorama is bounded at 512x256 and capped further by Sky
  radiance size. Its descriptor includes dimensions, byte size, source,
  inverse sky basis, bake duration, rebake count, and its own environment
  revision. Values above 1.0 survive the snapshot until the common post
  boundary.
- Hardware and software shaders use the same seam-wrapped bilinear panorama
  sampling equation. A mirror whose reflection ray misses therefore sees the
  visible sky/HDRI instead of a hard-coded black or unrelated clear color.
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

Six `vec4`s carry the rest, riding in `FrameData` next to the cloud layer:

| | x | y | z | w |
|---|---|---|---|---|
| `ground_params` | window origin X | window origin Z | 1/window size | march step count |
| `ground_bounds` | lowest canopy height | highest canopy height | max march distance | texel size in metres |
| `ground_sun_direction` | direction to sun | | | 1 when lit |
| `ground_sun_radiance` | colour scaled by energy | | | unused |
| `ground_ambient` | ambient radiance | | | unused |
| `ground_grass` | blade cells per metre | detail strength | ramp depth | detail fade distance |

`ground_params.w` doubles as the disable switch, the way `cloud_params.y` does:
a zero step count leaves the miss path byte-identical to what it was before the
layer existed. The step count and the march distance are ray budget the manager
owns rather than values the producer chooses, so both are resolved when the
snapshot commits. The march is capped at `fog_end`, because past it the ground
has already resolved to what the sky shows there.

`ground_grass.y` is the second disable switch: a zero detail strength publishes
the baked canopy unchanged, which is what a scene with no grass gets.

`rt_ground_shade()` and the rest of the block are duplicated byte-identically in
`addons/retro_rt/shaders/rt_shadow_reflect.glsl` and
`addons/retro_rt/shaders/BlinnPhongSoftwareBody.gdshaderinc`, for the same
reason `rt_fog_factor` is: an `RDShaderFile` cannot include a `.gdshaderinc`.
`addons/retro_rt/tests/ground_layer_smoke.gd` fails if the two copies drift.

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

Both shadow terms — the cloud layer and the ray below — attenuate that
directional term and leave the ambient alone, which is what the primary paths do
when they scale `direct` and add ambient separately. Scaling the whole lit value
instead takes the ambient with it, and under an overcast sky that drops the
reflected ground to pure black while the terrain and grass it stands in for stay
plainly visible.

Tracing and shading are two calls, not one, because a real ray belongs between
them. When the reflector sets `reflection_shadows_enabled`, the caller traces one
occlusion ray from the ground hit towards the sun with traversal mask `0x01`,
bounded by the same fog-capped march distance, and passes the result to
`rt_ground_shade()` as `sun_visibility`. That is what puts a cube's shadow onto
the ground a mirror shows. The ray cannot live inside the canonical block: the
two backends trace with `traceRayEXT` and `swrt_trace_scene` respectively, and
the block has to stay byte-identical. Nothing can self-intersect here, because
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
  precision to print axis-aligned rectangles — the same failure documented for
  the cloud layer, which is why the hash is the same integer-mixing shape.

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
  shared between hardware and software.

Hardware accepts up to `max_scene_lights` (256 by default). Software consumes
the same shared light table but limits each receiver to
`software_max_lights_per_receiver` candidates (16 by default, maximum 32).
Overflow is an explicit error; lights are not silently discarded.

Nested opaque rigid triangle MeshInstance3D geometry is supported, including
indexed/non-indexed, multi-surface, shared-mesh, and instance-override cases.
Missing normals are generated during extraction. Alpha, skinning, morphs,
vertex deformation, Environment fog, MultiMesh, GridMap, and arbitrary shader
semantics remain outside the managed material contract. Unmanaged forward
geometry that must match managed surfaces (the streamed shell grass) subscribes
to `distance_fog_changed` and applies the canonical `rt_fog_factor` itself.

## Software acceleration structure

The CPU builds one local-space 12-bin-SAH BLAS for each unique mesh and a
world-space TLAS over rigid instances. Nodes are depth-first with escape indices
for bounded stackless traversal. BLAS leaves contain at most four triangles and
TLAS leaves contain one instance.

The data-table width is 1024 texels with a maximum height of 4096. TLAS
traversal is capped at 4096 nodes, each BLAS at 32768 nodes, and float-encoded
integers remain below `2^24`. The CPU validates finite input, bounds, leaves,
escape indices, index precision, headers, and atlas capacity before a shader
consumes the data. Static geometry uploads once; revision changes update only
the affected data.

Each render snapshot contains immutable receiver-light starts/counts/indices
and a receiver-light revision. Hardware and software consume the same
conservative receiver/light candidate lists.

## Remaining unavoidable differences

The shared contract deliberately does not emulate implementation weaknesses.
Forward+ retains its native depth precision and reversed-Z behavior; no depth
quantization or artificial Z fighting is introduced. Hardware RT uses Vulkan
intersection hardware while software RT traverses texture-backed CPU-built BVHs.
Forward+, OpenGL Compatibility, and browser drivers may round raster edges,
intersections, derivatives, filtered samples, and final conversions differently.
Those differences are acceptable only when they remain below the measured
visual tolerances; an obvious image-level difference is a bug, not an accepted
backend feature.

Distance fog inherits that same class of difference: the hardware path derives
its fog distance from a depth-reconstructed world position while the software
path uses the interpolated one, so the two differ by float reconstruction
error rather than by formula.

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
- `rt_quality_preset`, `rt_quality_name`, `ray_tracing_requested_scale`,
  per-axis `ray_tracing_effective_scale`, `ray_tracing_full_resolution`,
  `ray_tracing_resolution`, `ray_tracing_resolution_method`, and rendered or
  dispatched pixel count;
- `post_output_size`, `post_render_size`, `post_requested_render_scale`,
  per-axis `post_effective_render_scale`, `post_resolution_method`,
  `post_rendered_pixels`, `post_smaa_viewport_size`, and
  `post_persistent_buffer_bytes`; camera diagnostic fields report the source
  identity, active state, visual-state and resource matches, and null internal
  compositor;
- `post_native_size` (legacy output-size alias), instrumented
  `post_per_frame_allocation_count`/peak, initialization and total explicit
  post-object allocation counts, resize count/timing,
  `post_scene_capture_frames`, `post_edge_frames`, `post_blend_frames`,
  `post_resolve_frames`, and `post_easu_frames` (zero at Native).
  The per-frame counters measure explicit Node/Resource construction inside the
  stack's frame update, including a settings update issued earlier in the same
  manager frame. Normal unchanged frames report zero because every viewport,
  material, and pass node is reused; a revision that rebuilds the temporary
  visual-contract Resource is visible in the current/peak counter.
  The persistent byte count is the owned color targets only: four render-size
  targets (scene, edges, weights, resolve) at 8 bytes per pixel when Forward+
  honors RGBA16F or 4 bytes for Compatibility/Web RGBA8, plus one output-size
  EASU target at the same per-pixel cost while a reduced preset is active. It
  excludes depth/render buffers and the SMAA LUTs.
- `post_scene_viewport_hdr_requested`/`post_scene_viewport_hdr`,
  `post_data_viewports_hdr_requested`/`post_data_viewports_hdr`, and
  `post_data_viewports_rgba`;
- `post_input_transfer` (`scene_linear` for Forward+ or
  `srgb_to_scene_linear` for Compatibility/Web), `post_output_transfer`, the
  post environment revision/composite state, and hardware opaque-coverage
  recovery state.

Hardware additionally reports acceleration-structure builds, uploads, uniform
sets, dispatch pixels, and available CPU/GPU timings. Software reports BVH and
atlas counts/bytes/build timings. Hardware render-thread facts may lag
main-thread changes by one rendered frame.

## Repeatable frame-time benchmark

The benchmark scene lives in the development repository, not in the add-on
folder.

`res://scenes/Benchmark/RTBenchmark.tscn` waits for `rt_ready`, warms up 300
rendered frames, records 1,200 `frame_post_draw` intervals, and repeats five
times. It emits median/p95/p99 JSON and writes desktop results beneath
`res://builds/benchmarks/`; Web emits stdout only.

Existing ray, load, light, map, and revision cases remain available. Dedicated
post cases isolate the shared fullscreen cost:

- `post_baseline`: shared presentation with SMAA and RetroGrade disabled;
- `post_smaa_low`, `post_smaa_medium`, and `post_smaa_high`: the three SMAA
  presets with grade disabled;
- `post_retro`: High SMAA plus RetroGrade and 16-level posterization.
- `post_fsr`: High SMAA with grade disabled, isolating the FSR 1 upscale cost.
  Pair it with `--benchmark-quality` to choose the internal resolution; at
  `native` it degenerates to `post_smaa_high` because FSR is bypassed. Compare
  `performance` against `native` here specifically, since EASU and RCAS both run
  at full output resolution and are the largest share of the frame at 50%;
- `post_cas`: High SMAA with grade disabled plus CAS at 0.15. Only meaningful at
  `--benchmark-quality=native`, because reduced presets sharpen with RCAS and
  ignore CAS;
- `post_resize`: measures one native buffer resize and records its microseconds;
- `environment_rebake`: proves a flat revision-1 snapshot becomes panorama
  revision 2 after one runtime resource edit, then records the single rebake,
  bake time, and same-frame post allocation event.

Each result records the active post features and complete RT profile. Use the
same renderer, driver, viewport, case, warmup, measured frames, and run count
when comparing costs.

Use `--benchmark-quality=native|quality|balanced|performance` to select the
fixed internal scale. Before sampling, the harness validates root/output size,
internal target size, SMAA source-texel size, compositor isolation, resolution
method, and rendered/dispatch pixel count. Hardware validation waits for and
checks the RTLightingEffect's raw `ray_tracing_width`, `ray_tracing_height`, and
`ray_tracing_dispatch_pixels` facts as well as the manager's canonical fields;
canonical normalization therefore cannot hide a stale hardware dispatch. The
quality name is included in the result filename.

```text
godot --path . --rendering-method forward_plus --scene res://scenes/Benchmark/RTBenchmark.tscn -- --force-hardware --benchmark-case=shadows_reflections --benchmark-quality=performance
godot --path . --rendering-method forward_plus --scene res://scenes/Benchmark/RTBenchmark.tscn -- --force-software --benchmark-case=post_baseline --benchmark-quality=balanced
godot --path . --rendering-method gl_compatibility --scene res://scenes/Benchmark/RTBenchmark.tscn -- --force-software --benchmark-case=post_retro --benchmark-quality=quality
```

### Recorded SMAA + bilinear vs SMAA + FSR 1 comparison

`shadows_reflections`, 300 warmup frames, 1,200 measured frames, 5 runs, 1152x648
output, RTX 4060, Godot 4.7.2. Aggregate median frame interval in milliseconds,
old (SMAA plus the four-tap bilinear upscale) against new (SMAA plus FSR 1):

| Preset | Forward+ hardware old | new | Compatibility software old | new |
| --- | ---: | ---: | ---: | ---: |
| Native | 0.864 | 0.883 | 0.988 | 1.009 |
| Quality | 0.709 | 0.782 | 0.884 | 1.020 |
| Balanced | 0.615 | 0.679 | 0.809 | 0.874 |
| Performance | 0.499 | 0.509 | 0.753 | 0.828 |

FSR 1 costs roughly 2-10% of frame time on hardware and 2-15% on Compatibility
software here. Native pays about 0.02 ms for the extra resolve pass alone.

Two results are worth understanding rather than just reading. Performance is the
*smallest* hardware regression (+0.01 ms) even though EASU and RCAS both run at
full output resolution, because the pass they replaced was expensive in exactly
the opposite direction: the old bilinear upscale ran four `decode_scene_texel()`
calls per output pixel, and each one reconstructed the environment with its own
four-tap panorama fetch. FSR reads twelve cheap texels from an
already-composited image instead. And every median here is under 1.1 ms, so this
scene is nowhere near GPU-bound on this hardware and the percentages are
inflated by fixed per-frame overhead. Re-measure on representative target
hardware before drawing conclusions about a real workload.

The Compatibility Quality run reported a 56.7 ms p95 against a 1.02 ms median.
The previous baseline had the same pathology at that exact configuration, which
is why a `-rerun` log exists; treat the median as the signal and the tail as
unrelated desktop-GL hitching.

Override the defaults with `--benchmark-warmup=<frames>`,
`--benchmark-frames=<frames>`, and `--benchmark-runs=<runs>`.

## Feature and renderer-parity validation

The fixtures and harnesses in this section live in the development repository,
not in the add-on folder.

`FeatureValidation.tscn` remains the deterministic material/light/ray fixture.
It covers UV/triplanar maps, UV-less geometry, multi-surface overrides,
non-uniform transforms, reflection variants, all supported lights, caster
modes, and layers. Its AA teardown diagnostic verifies built-in AA is disabled,
custom High SMAA is reported, and the exact caller-owned viewport state is
restored after manager teardown.

`--exercise-quality-switch-diagnostic` freezes the fixture, removes temporal
CameraAttributes, and captures `Native -> Quality -> Balanced -> Performance ->
Native`. Every tier must produce two bit-identical consecutive frames, and the
returned Native SHA must equal the original Native SHA. The diagnostic verifies
that the root remains native, internal/SMAA/resolve sizes and pixel counts
follow the preset, the EASU target and its two size constants exist with the
right dimensions at every reduced preset and are absent at Native, the reported
upscale method and sharpener match the preset, every transition causes exactly
one logical post resize, and topology, TLAS, instance, material, light,
environment, and receiver-list revisions do not change.

After those hashes complete, a separate resource-copy check assigns authored
camera-local Environment, neutral CameraAttributes, and a compositor, then
swaps both resource references. Post-stack diagnostics must show that
Environment and CameraAttributes identity are preserved, both source resources
remain unmodified, the source camera is neither replaced nor mutated, and the
internal camera compositor remains null. This resource check intentionally
makes no image-equality claim.

The same structural phase temporarily resizes the logical output to odd
dimensions and verifies the exact ceil-rounded Quality target. It then exercises
orthographic and asymmetric frustum projections with offsets/aspect policies,
switches to a second active authored camera, and requires the full internal
camera visual-state diagnostic after every change. The original camera, active
selection, Native quality, and output dimensions are restored before reporting.

`RendererParityCapture.tscn` adds capture-only high-contrast diagonals, thin and
subpixel geometry, near/far edges, highlights, mirrors, hard shadows, saturated
surfaces, a deterministic optional HDR panorama, and a UI marker above scene
post. It requires a graphical render loop; a headless run is rejected. All
ready and `frame_post_draw` waits are bounded.

A capture:

- requires an explicit hardware/software backend on desktop; Web selects
  software explicitly for its entrypoint;
- freezes scene motion and uses custom High SMAA plus the normal RetroGrade;
- can add `--parity-retro-stress` for 16-level posterization;
- can use `--parity-aa-off` or `--parity-grade-off` to isolate the raw shared
  presentation/color boundary while diagnosing a failed comparison;
- can add `--parity-sky` for the deterministic RGBAF/HDR sky-reflection case;
- can add `--parity-sky-rotate-90` to capture the same fixture after one
  90-degree environment rotation (it implies `--parity-sky`);
- requires two same-path frames to match exactly before saving;
- asserts native resolution, built-in AA state, post profile/counters,
  environment upload/radiance/seam/pole facts, a visible reflection miss,
  and UI ordering;
- writes `<label>.png` and `<label>.json` beneath `builds/parity` by default.

Capture the three useful comparisons with identical window size and flags:

```text
# Test A: renderer-only difference (the strict primary gate)
godot --path . --rendering-method forward_plus --scene res://scenes/Validation/RendererParityCapture.tscn -- --force-software --parity-sky --parity-label=forward_software
godot --path . --rendering-method gl_compatibility --scene res://scenes/Validation/RendererParityCapture.tscn -- --force-software --parity-sky --parity-label=compatibility_software

# Test B: RT backend difference
godot --path . --rendering-method forward_plus --scene res://scenes/Validation/RendererParityCapture.tscn -- --force-hardware --parity-sky --parity-label=forward_hardware
```

`tools/compare_parity.gd` compares decoded PNG RGB values offline and writes
`comparison.json` plus an amplified `difference.png`. It reports mean absolute
RGB difference, maximum channel difference, RGB MSE/PSNR, and the number and
percentage of pixels whose largest RGB-channel error exceeds the profile's
channel tolerance. Maximum error is diagnostic only because isolated raster
edge pixels are expected across APIs.

```text
# Test A: Forward+ software vs Compatibility software
godot --headless --path . --script res://tools/compare_parity.gd -- --reference=res://builds/parity/forward_software.png --candidate=res://builds/parity/compatibility_software.png --output-dir=res://builds/parity/test_a --profile=strict

# Test B: Forward+ hardware vs Forward+ software
godot --headless --path . --script res://tools/compare_parity.gd -- --reference=res://builds/parity/forward_hardware.png --candidate=res://builds/parity/forward_software.png --output-dir=res://builds/parity/test_b --profile=balanced

# Test C: Forward+ hardware vs Compatibility software
godot --headless --path . --script res://tools/compare_parity.gd -- --reference=res://builds/parity/forward_hardware.png --candidate=res://builds/parity/compatibility_software.png --output-dir=res://builds/parity/test_c --profile=balanced
```

Threshold profiles are intentionally fixed:

| Profile | Max MAE | Channel tolerance | Max pixels over | Min PSNR |
| --- | ---: | ---: | ---: | ---: |
| Strict | 0.005 | 0.02 | 0.5% | 40 dB |
| Balanced | 0.01 | 0.04 | 1.0% | 35 dB |
| Report-only | not gated | 4/255 | not gated | not gated |

Strict is the fail-safe default when `--profile` is omitted.

These thresholds are acceptance targets. The latest complete High-SMAA,
grade-on, deterministic-panorama Native artifacts (`fsr_*`, generated
2026-08-20 after the FSR 1 change) report, with the previous `current_*`
baselines in brackets for comparison:

| Comparison | Profile | MAE | Pixels over tolerance | PSNR | Result |
| --- | --- | ---: | ---: | ---: | --- |
| Forward+ software vs Compatibility software | Strict | 0.001790 (0.001742) | 1.591% (1.593%) | 34.03 dB (34.04) | fail |
| Forward+ hardware vs Forward+ software | Balanced | 0.000880 (0.000879) | 0.327% (0.327%) | 35.20 dB (35.20) | pass |
| Forward+ hardware vs Compatibility software | Balanced | 0.002433 (0.002390) | 1.737% (1.737%) | 31.60 dB (31.60) | fail |

Native did not regress. Comparing the new Native capture directly against the
previous fused-shader Native gives MAE 0.000100, maximum channel difference
exactly 1/255, zero pixels over tolerance, and PSNR 64.05 dB — that is the
single sRGB round trip through the resolve target described under "Targets and
precision", and nothing else. The two open cross-renderer gates fail for the
same pre-existing reasons and by the same margins.

The FSR path was captured separately with `--parity-quality=`. Against the new
Native reference, Quality reports MAE 0.00259 / 32.34 dB, Balanced 0.00301 /
31.44 dB, and Performance 0.00487 / 28.07 dB: monotonic with scale, with
differences confined to one- and two-pixel edge lines and flat regions
bit-identical. Forward+ hardware and Compatibility software agree at Performance
to MAE 0.00280 / 31.57 dB, matching the Native cross-renderer margin, so EASU and
RCAS reconstruct consistently on both renderers. A half-texel offset, a flipped
Y axis, or a stale resolution constant would all raise these by an order of
magnitude and break the monotonicity, so this is the regression signal to watch.

All three individual captures passed their internal same-path stability and
fixture checks. The same-renderer hardware/software gate now passes; the two
cross-renderer gates remain open on raster coverage, direct texture filtering,
and Compatibility target-precision differences. Diagnostic grade-off/AA-off
comparisons do not substitute for these default-path gates.
The rotation capture verifies the requested 90-degree environment basis and
reflection visibility; proving identical region displacement still requires
paired baseline/rotated captures and cross-renderer comparison.

Both tools return `0` for a passing run, `1` for failed assertions/thresholds,
and `2` for configuration or runtime errors. Cross-renderer exact SHA is never
a gate; the exact SHA pair in each capture only proves deterministic same-path
frames.

## Web target

The post stack uses canvas shaders, ordinary SubViewports, and lookup
textures; it does not require compute, storage buffers, compositor APIs, motion
vectors, or history for AA/color/upscaling processing. FSR 1 is included in
that: EASU, RCAS and CAS are ordinary fragment kernels with no loops, no 16-bit
packed path, and no `textureGather`, so they compile under WebGL 2. This keeps
Web Compatibility a first-class runtime path. The checked-in Web export preset
remains single-threaded.

`project.godot` keeps the authored desktop main scene but sets
`run/main_scene.web` to `RendererParityCapture.tscn`. The runnable `Web` export
preset exports all resources to `builds/web/index.html` with thread support
disabled, so launching that export enters the parity harness without changing
normal desktop play. With no injected browser arguments it selects software RT,
High SMAA, normal RetroGrade, and the asymmetric HDR panorama fixture. The
90-degree rotation case still requires the corresponding parity argument in a
browser launch that supplies user arguments. The export canvas resize policy is
engine-controlled (`1`), keeping the harness at its native 1152x648 canvas
instead of browser-stretching it.

The Web harness writes its PNG/JSON pair beneath `user://parity` and prints the
structured `RT_PARITY_CAPTURE` record to the browser console. Collect the files
from browser persistent storage, then run the offline comparator.

A current in-app Chromium/WebGL2 run completed with `runtime.web = true`, no
browser console errors, native 1152x648 output, exact consecutive-frame SHA,
active High SMAA, ungraded UI ordering, one 512x256 RGBAF sky bake, and HDR peak
radiance `2.8223`; every harness check passed. It reported
`post_upscale_method = none`, `post_sharpen_mode = none` and
`post_easu_frames = 0`, confirming the Native FSR bypass on Web.

A second WebGL2 run forced the Performance preset through the engine `args` to
prove the FSR path itself compiles and runs there. It also passed every check,
with `post_fsr_active = true`, `post_easu_frames = 18`,
`post_fsr_input_size = (576, 324)`, `post_fsr_output_size = (1152, 648)`,
`post_upscale_method = fsr1_easu_rcas`, `post_sharpen_mode = rcas`, a native
1152x648 capture, a correct UI marker, and two matching consecutive frames — so
EASU and RCAS produce a real, stable, non-black image under WebGL 2 with no
unsupported shader instructions and no framebuffer errors. Note that a hidden
browser tab pauses `requestAnimationFrame` and stalls the Godot main loop; an
automated WebGL run needs either a visible tab or a shim that drives the loop
from `setTimeout`.

Firefox was not available in the current browser-control environment and remains
a required manual acceptance run. Mobile browsers and Safari are not current
validation targets.

A separate in-browser quality benchmark kept the root/output canvas at
1152x648 while Performance rendered the private RT/SMAA targets at 576x324.
Native and Performance both measured a 4.20 ms aggregate median frame interval
on the high-refresh test system (p95 4.4 ms and 4.5 ms respectively), so the
reduced internal target did not reproduce the root-scaling FPS collapse. Every
resolution, SMAA-source-domain, compositor-isolation, and root-scale contract
check passed. This refresh-cadence-limited result is a regression check, not a
claim of a Web speedup on every GPU; Chromium and Firefox should still be
benchmarked on representative target hardware before changing the default.
