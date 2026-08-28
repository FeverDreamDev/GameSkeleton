# Integrated Godot Game Skeleton

This project is a runnable integration shell for the included procedural terrain/grass,
FPS controller, Win98 UI, save/load, shader-warmup, game-flow, Blinn–Phong, Retro RT,
SMAA, and FSR add-ons.

## Runtime flow

`Boot + shader/RT warmup -> Main Menu -> autosave -> blank intro -> terrain_test`

- **New Game** resets the run and starts the application-owned master graph at
  `res://game/flow/master_game_flow.tres`. That graph is the single source of truth for the
  pre-intro checkpoint, 1.2-second skippable black intro, post-intro checkpoint, initial level
  change, gameplay autosave, and failure paths.
- The application shell still owns menus, save-slot selection, world reconstruction, and the
  button that starts or restores the graph. It does not duplicate the graph's story sequence.
- Continue, Load, pause-menu Save/Load, corrupt-save reporting, and Return to Main Menu are
  wired through the persistent application shell at `res://game/app/main.tscn`.
- Save payloads contain their current schema version, `FlowState`, resumable graph
  tokens/waits/subgraphs, whether the world must be reconstructed before graph resume, the
  persistent player state, and scene-relative state from nodes in the `saveable` group.

For visual authoring instructions and the complete designer-facing node reference, see
[`docs/GAMEFLOW_NODE_TUTORIAL.md`](docs/GAMEFLOW_NODE_TUTORIAL.md).
The quality-neutral terrain and grass Phase 1 optimizations and their before/after
evidence are recorded in
[`docs/PROCEDURAL_TERRAIN_GRASS_PHASE_1_RESULTS.md`](docs/PROCEDURAL_TERRAIN_GRASS_PHASE_1_RESULTS.md).

## Rendering contract

- Forward+ and Vulkan are preferred. Godot may fall back to D3D12 and then OpenGL
  Compatibility; Retro RT `AUTO` chooses hardware only on supported Forward+/Vulkan and
  otherwise uses its software path.
- Hardware RT reserves render layer 20 for managed geometry and the material-ID carrier.
  Every active gameplay camera must include that bit in `cull_mask`; the manager reports a
  contract failure with the camera path if it does not. Authored mesh/light masks still own
  RT candidate culling and are never mutated by the renderer-only override.
- Terrain chunks use the shared Blinn–Phong material with baked vertex colours. They are
  registered as `retro_rt_receiver_only`, have a zero ray mask, and have raster shadow
  casting disabled: they receive RT light/shadow results without casting RT shadows or
  appearing in RT reflections.
- Rigid props and the fixed player proxy use `retro_rt_managed`. Deforming shell grass stays
  outside RT geometry but remains inside the shared post stack.
- Neither terrain nor grass can therefore be traced, so `TerrainGrass3D` publishes the ground
  to `RTSceneManager.configure_ground_layer()` as one camera-centred RGBA32F heightfield:
  scene-linear canopy colour in RGB, canopy height in A. A reflection ray that misses the
  acceleration structure marches that instead of falling straight through to the sky, which
  is how ground and grass appear in mirrors without either entering the TLAS. Set
  `RTSceneManager.ground_march_steps` to zero to turn it off. See `RT_PIPELINE.md`,
  "Analytic ground layer".
- Distance fog is owned by `RTSceneManager`, not the Environment (engine fog stays banned).
  The level derives its reach from `terrain_load_distance`, so the fade always covers the
  chunk streaming boundary, and the same `rt_fog_factor` runs in the hardware, software and
  shell-grass paths. Terrain vertex colours are authored in scene-linear and target the
  grass canopy so the ground stays invisible under grass.
- The default is Native (100%) plus High SMAA. Reduced RT quality presets enable the FSR1
  EASU/RCAS path. The FPS camera then applies a native-resolution classic Panini projection
  before CAS/RCAS and RetroGrade; the reticle and Win98 UI remain native-resolution layers
  above presentation. The full order is `3D + RT -> environment -> SMAA -> optional EASU ->
  Panini -> CAS/RCAS -> RetroGrade -> HUD/UI`. Only the FPS camera opts in, so cutscene and
  utility cameras bypass it. Shifted camera offsets also bypass the symmetric Panini mapping.
- **Graphics** in the main and pause menus carries a live 120–140 degree horizontal FOV
  slider (130 by default). It is exact horizontal coverage at every aspect ratio. The dialog
  also carries RT render quality, SMAA, retro grading, grass detail and an FPS counter.
  Sprint adds up to 10 degrees without exceeding 140. FOV is session-only, omitted from save
  payloads, and returns to 130 when the application restarts. Grass is the one worth
  reaching for first: it is stacked shell layers,
  so it costs its shell count in overdraw over whatever share of the screen it covers. At
  2560x1440 the tiers measure 188 / 220 / 241 FPS for High / Medium / Low, against a 241 FPS
  floor with grass hidden entirely — Low is already at that floor, which is why the menu does
  not offer an off switch. Switching tiers swaps between shell meshes each chunk already
  caches, so it applies on the same frame and never disturbs terrain collision. Settings are
  session-scoped.
- The FPS counter is `UIFpsCounter` from the Win98 add-on, on its own CanvasLayer at 90 —
  above the RT presentation layer at -100, below `UISystem`'s screens at 100, so it reads over
  the game and under menus. It samples four times a second rather than every frame.

## Controls

- Move: `W`, `A`, `S`, `D`
- Jump: `Space`
- Crouch: `C`
- Sprint: `Shift`
- Pause / skip intro: `Escape`

## Regenerating shader warmup data

Run this after adding or changing rendered content:

```powershell
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --script res://game/warmup/generate_warmup_assets.gd
```

The generator writes the exact runtime terrain/grass vertex-format proxies and
`res://generated/shader_warmup_manifest.tres`.

## Smoke tests

```powershell
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://game/tests/terrain_player_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://game/tests/player_camera_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://addons/retro_rt/tests/panini_projection_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://addons/procedural_terrain_grass/tests/phase1_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://game/tests/app_flow_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://game/tests/app_recovery_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://addons/retro_rt/tests/receiver_registry_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path . --rendering-method gl_compatibility --script res://addons/retro_rt/tests/receiver_registry_smoke.gd -- --panini
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path . --rendering-method gl_compatibility --script res://addons/retro_rt/tests/receiver_registry_smoke.gd -- --panini-performance
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://addons/retro_rt/tests/ground_layer_smoke.gd
# Optional hardware variant; exercises carrier-layer camera and local-light contracts.
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path . --rendering-method forward_plus --resolution 2560x1440 --script res://addons/retro_rt/tests/receiver_registry_smoke.gd -- --hardware
```

## Frame-time probe

`game/tests/perf_probe.gd` boots the shell, enters the terrain level, parks the
player at a fixed viewpoint and reports the median and p95 frame interval. Run it
at the authored resolution, because the RT stack sizes every pass from it:

```powershell
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path . --rendering-method forward_plus --resolution 2560x1440 --script res://game/tests/perf_probe.gd
```

`PERF_GRASS=0`, `PERF_SKY=0`, `PERF_CLOUDS=0`, `PERF_STARS=0`, `PERF_SMAA=0`,
`PERF_PANINI=0`, `PERF_GRADE=0`, `PERF_GROUND=0` and `PERF_RT=0` switch a
subsystem off so its share of the frame can be read off the difference. `PERF_CLOUDS` and
`PERF_STARS` keep the dome and drop one term inside the sky shader;
`PERF_GROUND` keeps ray tracing and drops only the analytic reflection-ground
trace. `PERF_BACKEND=software` forces the Compatibility tracer on a machine that
would otherwise select hardware RT. `PERF_PROFILE=1` adds the RT manager's
main-thread cost and its snapshot counters.

`PERF_FOV=120|130|140` selects the FPS camera's horizontal display FOV and
`PERF_RT_QUALITY=0|1|2|3` selects Native, Quality, Balanced, or Performance.
With profiling enabled, `post_pass_gpu_ms.panini` isolates the projection target and
`post_panini_buffer_bytes` reports its persistent native-size color buffer.

`PERF_CARRIER=0` is an attribution toggle only. It hides the hardware material-ID
carrier, deliberately makes managed pixels lose RT lighting, and prints a warning;
it must never be used as a gameplay or image-quality setting.

**`PERF_CLOCK=1` is off by default, and every measurement involving a moving sun
needs it.** With the clock frozen the sun never moves, so anything that only
costs something while lights change measures as exactly zero — while the shipping
default is a running clock. A frozen-clock run is a control, not a baseline.

`PERF_SHOT=<path>` writes the viewpoint to a PNG, and `PERF_REF=<path>` compares
against an earlier one and reports how many pixels differ, plus an amplified
difference image. That is the acceptance test for any change that claims to be
free. Two things must be pinned for it to mean anything, and the probe does both
only when capturing: wind (the cloud layer scrolls and the grass sways
independently of the clock) and, with `PERF_PIN_LOD=1`, the grass LOD bands —
their hysteresis otherwise settles two different ways and swamps the comparison
at ~5% of pixels. Even pinned, the grass mask build is not bit-reproducible
between launches; roughly 1000 pixels at 1/255 is the floor. Hide the grass to
get an exactly reproducible frame. Capture runs also freeze the parked player
hierarchy after applying the requested camera transform. Use `PERF_STARS=0` for
an exact cross-launch gate because the star layout seed is generated per run.

## WebGL2 Panini acceptance

The production `Web` preset continues to start the game. The separate
single-threaded `Web Panini Validation` preset starts
`res://game/tests/panini_web_capture.tscn` at 1152x648 through a custom export
feature, without changing the desktop or production-Web main scene. The harness
enters the real terrain level, verifies all three FOV endpoints, all four quality
presets, SMAA off/Low/Medium/High, Native CAS, reduced-preset RCAS, and grade and
posterization toggles. It also checks Compatibility/software selection, capture
overscan and steady-state allocation contracts, leaves an unwarped status marker
above the scene, and prints a `PANINI_WEB_CAPTURE` JSON record to the browser console.

```powershell
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --export-release Web builds/web/index.html
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --export-release "Web Panini Validation" builds/web-panini/index.html
```

Serve `builds/web-panini` over HTTP and open `index.html` in a WebGL2 browser. A
passing run displays `PANINI WEB CHECK: PASS`; the JSON record must report
`runtime_web: true`, `renderer: "gl_compatibility"`, `rt_backend: "software"`,
`source_stage: "fsr_easu"`, and zero invalid samples. The equivalent desktop
Compatibility check is:

```powershell
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path . --rendering-method gl_compatibility --scene res://game/tests/panini_web_capture.tscn -- --force-software
```
