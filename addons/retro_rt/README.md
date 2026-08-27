# Retro RT

Ray-traced shadows and reflections for Blinn-Phong materials in Godot 4.7+,
with one visual contract shared by four runtime configurations: Forward+
hardware RT, Forward+ forced software RT, desktop Compatibility software RT, and
Web Compatibility. All four feed the same fullscreen SMAA 1x + FSR 1 post stack,
so the image is the same picture at four performance points rather than four
different looks.

No textures to import, no `.gdextension`, no autoloads, no input actions. The
add-on is one folder and six global classes.

## Install

1. Copy the whole `addons/retro_rt` folder into your project.
2. Enable **Retro RT** under **Project Settings > Plugins**.
3. Open `addons/retro_rt/examples/RTExample.tscn` and press play.

Enabling the plugin clears one project setting: **Rendering > Anti Aliasing >
Screen Space Roughness Limiter**. Godot defaults it on, and ray tracing refuses
to start while it is — the limiter perturbs the roughness the reflection path
reads back. The plugin prints what it changed. The next run picks it up; no
editor restart is needed.

Do not rename the folder. GDScript resource paths inside the add-on are absolute
`res://addons/retro_rt/...` strings. (Shader `#include`s are relative and would
survive a rename; the script consts would not.)

## Requirements

- **Godot 4.7 or newer.** There is no version gate — on an older engine
  `RTLightingEffect` fails at `extends CompositorEffect` parse time.
- **Hardware RT** additionally needs Forward+ on Vulkan, with the
  `RenderingDevice` exposing buffer-device-address and ray-tracing-pipeline
  support, and a non-CPU adapter. Everything else — Compatibility, Web,
  non-Vulkan Forward+ — selects the software backend automatically.
- The software backend needs no compute, no storage buffers, no compositor and
  no ray-tracing pipeline. It rasterizes primary visibility and traverses a CPU
  BVH from the fragment shader, which is why Web stays a first-class target.

## Quick start

The minimum scene is a `Node` with `RTSceneManager.gd`, sitting alongside your
3D content:

```
RTExample (Node)
├─ DirectionalLight3D          shadow_enabled is now the RT-shadow toggle
├─ WorldEnvironment
├─ MeshInstance3D ...          materials use BlinnPhong.gdshader
├─ Camera3D
├─ RTSceneManager (Node)       the integration point
└─ RTExampleUi                 gameplay UI, on the default canvas layer
```

`RTSceneManager` publishes every active `DirectionalLight3D`, `OmniLight3D`,
`SpotLight3D` and `AreaLight3D` beneath its geometry root, builds the
acceleration structure, installs the compositor effect (hardware) or the
material overrides (software), and owns the post stack. It sets its own
`process_priority` to 100000 so it runs after gameplay.

Two exported node paths locate the rest, and both default to this layout:
`geometry_root_path` (`../`) and `world_environment_path` (`../WorldEnvironment`).

Geometry is opt-in: add rigid ray-visible meshes to `retro_rt_managed`. Add a
managed mesh to `retro_rt_receiver_only` when it should receive primary RT
lighting/shadows but never cast a ray shadow or appear in reflections. Receiver
slots are appended/tombstoned/reused incrementally, so streamed terrain does not
rebuild the hardware TLAS or software BLAS/BVH. Set `managed_geometry_group` to
an empty name only when you explicitly want the legacy scan-all behavior.

`auto_start` defaults on. A persistent shell can set it off, assemble an active
camera/environment and geometry, then `await start_rt()`. The call returns `true`
only after the selected backend reports ready; failure, `stop_rt()`, a superseding
restart, or the bounded `startup_timeout_seconds` returns `false`. Call
`request_topology_sync()` after changing ray-visible mesh topology in place.
Receiver-only add/remove events are handled incrementally and do not need it.

### Materials

Managed surfaces must be a `ShaderMaterial` running
`addons/retro_rt/shaders/BlinnPhong.gdshader` — the manager compares shader
identity, not just parameters, and rejects anything else with
`"Unsupported material on <path> surface N."`

Authored parameters:

| Parameter | Type | Notes |
| --- | --- | --- |
| `ambient_light`, `diffuse_color`, `emission_color`, `specular_color` | `Color` | `source_color` |
| `albedo_texture`, `normal_texture` | `sampler2D` | optional; anisotropic, repeat |
| `vertex_color_enabled` | `bool` | primary raster/software colour; receiver-only geometry only |
| `triplanar_enabled`, `triplanar_world_space`, `triplanar_scale`, `triplanar_offset`, `triplanar_sharpness` | | for UV-less geometry |
| `shininess` | `1..256` | Blinn-Phong exponent |
| `direct_specular_intensity` | `0..2` | |
| `mirror_enabled`, `reflection_strength`, `reflection_shadows_enabled` | | per-material RT reflection controls; the shadow toggle covers reflected geometry and the analytic ground alike |

`rt_pipeline_active`, `rt_material_id`, `rt_has_albedo_texture`,
`rt_has_normal_texture` and the `rt_instance_id` instance uniform are written by
the manager. Leave them alone; the shader falls back to standalone raster when
`rt_pipeline_active` is false, which is what you see with the add-on inactive.

### What startup validates

RT fails loudly rather than silently rendering something different, so the scene
has to stay inside the shared contract:

- an active `Camera3D` and a resolvable `Environment` (camera → `world_environment_path`
  → `World3D`);
- on hardware RT, the active camera's `cull_mask` includes render layer 20. The
  add-on reserves that layer for managed geometry and its material-ID carrier;
  omitting it is an explicit contract failure rather than an empty scene;
- background `BG_CLEAR_COLOR`, `BG_COLOR` or `BG_SKY`;
- **Linear** tonemapping at exposure `1.0`;
- no Environment fog or volumetric fog (RTSceneManager owns an equivalent
  post-lighting distance fog instead — see **Distance fog**), no SSAO, SSIL, SSR,
  SDFGI, glow, Environment adjustments, auto exposure, camera exposure overrides,
  or depth of field;
- one `RTSceneManager` per Viewport — the stack stamps a meta on the root
  Viewport and refuses a second;
- opaque, rigid, triangle `MeshInstance3D` geometry: no alpha, skinning, morphs,
  vertex deformation, `MultiMesh` or `GridMap`;
- at most 256 lights (hardware) and `software_max_lights_per_receiver` lights per
  receiver (software, 16 by default, 32 maximum). Overflow is an error, never a
  silent drop.

Texture references and pixel content of managed maps are static; changing them
needs a scene reload.

Secondary hits do not carry vertex colour attributes. The manager therefore
rejects `vertex_color_enabled = true` on ray-visible managed geometry, with the
mesh and surface in the error. It is supported on receiver-only primary
surfaces, including streamed terrain.

Your gameplay UI must sit on the default canvas layer or higher. The stack
presents through a `CanvasLayer` at `-100`, so anything above that is drawn
after the grade and the upscale, ungraded and at native resolution.

## Quality presets

`rt_quality` scales the internal render domain only. Output resolution, the root
viewport, the UI and the final present always stay native — `scaling_3d_scale`
is never touched, so Godot's own renderer scaler is not involved.

| Preset | Scale | Internal at 1920x1080 | Upscaler | Sharpener |
| --- | ---: | --- | --- | --- |
| `NATIVE` | 1.00 | 1920x1080 | none (true bypass) | optional CAS, off by default |
| `QUALITY` | 0.85 | 1632x918 | FSR 1 EASU | FSR 1 RCAS |
| `BALANCED` | 0.75 | 1440x810 | FSR 1 EASU | FSR 1 RCAS |
| `PERFORMANCE` | 0.50 | 960x540 | FSR 1 EASU | FSR 1 RCAS |

Other output sizes round up per axis with `max(2, ceil(output * scale))`.

`rt_quality_changed` is a live-change signal, not an initial-state
notification — read `rt_quality` once in `_ready()`, then listen.

## API

`addons/retro_rt/examples/RTExampleUi.gd` is a 90-line worked example of
everything below.

### `RTSceneManager` (Node)

**Signals** — `rt_ready`, `rt_failed(reason: String)`,
`rt_quality_changed(preset: int, requested_scale: float)`,
`topology_sync_started`, `topology_sync_completed`

**Enums** — `RTBackend { AUTO, HARDWARE, SOFTWARE }`,
`RTQualityPreset { NATIVE, QUALITY, BALANCED, PERFORMANCE }`,
`SMAAQuality { LOW, MEDIUM, HIGH }`, `RTEnvironmentMode { FLAT, PANORAMA }`

**Methods**

| Method | Returns |
| --- | --- |
| `start_rt()` | awaitable `bool`; true only when ready |
| `stop_rt()` | —; restores every owned renderer override and wakes start waiters |
| `request_topology_sync()` | —; queues a safe full rebuild for ray-visible topology |
| `get_active_rt_backend()` | `&"hardware"`, `&"software"` or `&"none"` |
| `set_rt_quality(preset: int)` | — |
| `get_rt_quality_scale()` / `get_rt_quality_name()` | `float` / `StringName` |
| `get_ray_render_resolution()` | internal traced size |
| `get_full_render_resolution()` | native output size |
| `get_render_snapshot()` / `get_profile_snapshot()` | `Dictionary` |
| `get_post_debug_stage_images()` / `get_post_debug_contract_snapshot()` | validation use |

**Exports**

| Property | Default | Notes |
| --- | --- | --- |
| `geometry_root_path` | `../` | |
| `world_environment_path` | `../WorldEnvironment` | |
| `auto_start` | `true` | set false for a persistent loading/app shell |
| `managed_geometry_group` | `retro_rt_managed` | empty retains legacy scan-all |
| `receiver_only_geometry_group` | `retro_rt_receiver_only` | primary receiver, traversal mask zero |
| `startup_timeout_seconds` | `15.0` | bounds the backend-ready handshake |
| `preview_in_editor` | `true` | see below |
| `rt_backend` | `AUTO` | read-only after `_ready()` |
| `max_scene_lights` | `256` | |
| `software_max_lights_per_receiver` | `16` | read-only after `_ready()`, max 32 |
| `ray_origin_bias` / `ray_max_distance` | `0.001` / `10000.0` | |
| `profiling_enabled` | `false` | feeds `get_profile_snapshot()` |
| `rt_quality` | `NATIVE` | |
| `post_anti_aliasing_enabled` | `true` | SMAA on/off |
| `post_smaa_quality` | `HIGH` | |
| `post_fsr_sharpness` | `0.5` | RCAS stops; **0.0 is sharpest**, 2.0 softest |
| `post_cas_enabled` / `post_cas_sharpness` | `false` / `0.15` | Native-only sharpener |
| `retro_post_enabled` | `true` | the colour grade |
| `post_brightness`, `post_contrast`, `post_saturation`, `post_black_point`, `post_color_balance` | | |
| `post_posterize_enabled`, `post_posterize_levels`, `post_posterize_strength` | | |

Every post-processing setter updates the live stack.

### Other types

`RTVisualContract` (Resource) is the authorable form of the shared AA / grade /
sharpening settings, plus the static viewport-state helpers the stack uses to
capture, normalize and restore the root Viewport. `RTLightingEffect`
(CompositorEffect), `RTPostProcessStack` and `RTSoftwareTracer` / `RTSoftwareBVH`
are owned by the manager and are not meant to be instantiated directly.

### Global class names this add-on registers

`RTSceneManager`, `RTLightingEffect`, `RTSoftwareTracer`, `RTSoftwareBVH`,
`RTPostProcessStack`, `RTVisualContract`. Check these against your project and
any other add-ons before installing — Godot reports a global class collision as
an error.

## Editor preview

`preview_in_editor` (on by default) previews real ray tracing in the editor
viewport, always through the software tracer regardless of `rt_backend`: its
overrides are renderer-only state that restores cleanly, so a half-assembled
scene degrades to ordinary raster instead of rendering garbage.

Preview is RT shadows and reflections only. It deliberately does **not** run the
post stack — `RTPostProcessStack.configure()` sets `disable_3d` on the root
viewport and presents through a `CanvasLayer`, which in the editor would blank
the viewport and its gizmos. No grade, no SMAA, no FSR until you press play. The
runtime remains the authoritative image.

Editor failures never latch: they tear down to plain raster, warn once, and
retry. Headless editor runs (import, export) install no preview at all.

## Anti-aliasing is SMAA, and cannot be MSAA

Hardware RT here is a deferred visibility-buffer renderer — `BlinnPhong.gdshader`
packs a 21-bit instance + material ID through the separate-specular target, and
the compute shader decodes it before writing results back. Multisample resolve
averages that packed integer away at exactly the silhouette pixels MSAA exists
to fix. Separately, `image2D` cannot bind a multisampled attachment, and the
effect runs at `POST_SKY` with unresolved access, so its writes would be
discarded by the resolve.

The stack therefore force-disables 2D and 3D MSAA, TAA, built-in screen-space
AA and debanding on the root Viewport, captures the authored values first, and
restores them on teardown or failure.

## Exporting

`examples/` is only needed while learning the add-on. Exclude it with an export
filter (`addons/retro_rt/examples/*`) once your own scene is set up.

## Credits

`post_processing/smaa/AreaTexDX10.dds` and `SearchTex.dds` are the unmodified
lookup textures from Jorge Jimenez's SMAA reference implementation, MIT
licensed — see `post_processing/smaa/LICENSE-SMAA.txt`. The shader ports preserve
the reference presets and lookup conventions in Godot shader syntax.

`docs/RT_PIPELINE.md` is the architecture and validation spec: transport,
resolution domains, colour and exposure, environment baking, the software
acceleration structure, profiling fields, and the measured parity and frame-time
results behind the design.
