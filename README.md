# Integrated Godot Game Skeleton

This project is a runnable integration shell for the included procedural terrain/grass,
FPS controller, Win98 UI, save/load, shader-warmup, game-flow, Blinn–Phong, Retro RT,
SMAA, and FSR add-ons.

## Runtime flow

`Boot + shader/RT warmup -> Main Menu -> autosave -> blank intro -> terrain_test`

- **New Game** resets the run and starts the application-owned master graph at
  `res://game/flow/master_game_flow.tres`. That graph is the single source of truth for the
  pre-intro checkpoint, 1.2-second skippable black intro, post-intro checkpoint, initial level
  change, progress flag, gameplay autosave, and failure paths.
- The application shell still owns menus, save-slot selection, world reconstruction, and the
  button that starts or restores the graph. It does not duplicate the graph's story sequence.
- Continue, Load, pause-menu Save/Load, corrupt-save reporting, and Return to Main Menu are
  wired through the persistent application shell at `res://game/app/main.tscn`.
- Save payloads contain their schema version and resume phase, `FlowState`, resumable graph
  tokens/waits/subgraphs, the persistent player state, and scene-relative state from nodes in the
  `saveable` group.

For visual authoring instructions and the complete designer-facing node reference, see
[`docs/GAMEFLOW_NODE_TUTORIAL.md`](docs/GAMEFLOW_NODE_TUTORIAL.md).

## Rendering contract

- Forward+ and Vulkan are preferred. Godot may fall back to D3D12 and then OpenGL
  Compatibility; Retro RT `AUTO` chooses hardware only on supported Forward+/Vulkan and
  otherwise uses its software path.
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
  EASU/RCAS path; the reticle and Win98 UI remain native-resolution layers above presentation.

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
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://game/tests/app_flow_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://game/tests/app_recovery_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://addons/retro_rt/tests/receiver_registry_smoke.gd
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . --rendering-method gl_compatibility --script res://addons/retro_rt/tests/ground_layer_smoke.gd
```
