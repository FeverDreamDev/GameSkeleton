# Procedural Terrain + Grass — Phase 1 Results

> **Historical record.** On 2026-08-28 the project became Forward+ only. The
> regression coverage below names the OpenGL Compatibility renderer, which is no
> longer a supported target. The results were true when taken and are left
> unedited.

Phase 1 was validated on August 26, 2026 against committed baseline `c649516`.
The accepted changes remove redundant shader and script work, correct invalidation
edge cases, and preserve the authored terrain and grass quality settings. The
deferred MultiMesh architecture change was not started.

## Outcome

- No shell count, density, draw distance, mask resolution, terrain resolution,
  wind, lighting, or interaction quality setting was reduced.
- The fixed visual comparison is effectively identical: 13 of 3,686,400 pixels
  differed (0.0004%), the maximum channel delta was 1/255, and the mean delta
  rounded to 0.000000. The probe normally sees roughly 1,000 one-step pixel
  differences from the grass-mask build between launches.
- With the full Retro RT stack enabled, total frame time was neutral within run
  variance: 6.850 ms before and 6.827 ms after at the median (-0.3%).
- With Retro RT disabled to expose more of the terrain/grass cost, median frame
  time improved from 5.276 ms to 4.895 ms (-7.2%), while p99 improved from
  7.464 ms to 6.674 ms (-10.6%).
- Compatibility and Forward+ shader startup succeeded. Threaded and incremental
  terrain generation, application flow, reflection-ground behavior, blocker
  invalidation, and interactor upload behavior passed their focused smoke tests.

## Performance protocol

The before and after probes used the same executable, project settings, fixed
camera, terrain seed, authored quality settings, and 2560x1440 Forward+ render
resolution on an NVIDIA GeForce RTX 4060 with Godot 4.7.2 stable. Each measured
run followed 300 warm-up frames and collected 1,200 frame intervals. The
baseline was replayed from a clean archive of commit `c649516` after a complete
shader import.

The full-stack comparison reports the midpoint of two warmed runs. The RT-off
comparison reports the median of three independent run metrics. Raw per-frame
samples were not retained, so these aggregates operate on the reported per-run
metrics.

An earlier, temporally separated baseline run at 7.506 ms was excluded from the
warmed comparison because it was not representative of the repeat runs.

| Configuration | Metric | Before | After | Change |
| --- | --- | ---: | ---: | ---: |
| Full scene, Retro RT on | Median | 6.850 ms | 6.827 ms | -0.3% |
| Full scene, Retro RT on | p95 | 8.151 ms | 8.117 ms | -0.4% |
| Full scene, Retro RT on | p99 | 8.757 ms | 8.667 ms | -1.0% |
| Full scene, Retro RT off | Median | 5.276 ms | 4.895 ms | -7.2% |
| Full scene, Retro RT off | p95 | 6.809 ms | 6.315 ms | -7.3% |
| Full scene, Retro RT off | p99 | 7.464 ms | 6.674 ms | -10.6% |

The RT-off median corresponds to about 189.5 FPS before and 204.3 FPS
after (+7.8%). These are rendered-frame intervals rather than direct GPU timer
queries, so they include the remaining application work. The benchmark parks
the player at a fixed viewpoint. Initial streaming was regression-tested in
threaded and incremental modes, but movement across chunk boundaries and its
spikes were not separately exercised or timed in this phase.

## Visual comparison

The visual acceptance capture pinned wind and grass LOD state and used the same
2560x1440 Forward+ camera view before and after:

| Pixels changed | Maximum channel delta | Mean delta |
| ---: | ---: | ---: |
| 13 / 3,686,400 (0.0004%) | 0.00392 (1/255) | 0.000000 |

There was no intentional visible change. The residual difference is far below
the documented cross-launch noise floor of the probe.

The capture uses stopped wind and a pinned near grass LOD in the authored
terrain scene, with its directional lighting and fog enabled. It does not stand
in for separate fog-off, far-LOD, point-light, spot-light, or multiple-interactor
captures; the corresponding shader math and CPU upload states
were covered by equivalence review and focused tests rather than pixel captures.

## Accepted implementation changes

1. Grass interaction and offset clamps now reject out-of-range work with
   squared distances, calculating a square root only when its exact magnitude
   is required.
2. The CPU uploads a compact active-interactor set and an explicit count. The
   shader stops at that count, zero-interactor frames disable the path, count
   decreases clear stale slots, and nodes freed during selection are skipped
   without disturbing the surviving order.
3. Grass fog uses fragment view-space distance directly and avoids the distance
   calculation when fog is disabled. Grass lighting uses Godot's view-space
   normal plus view-space world-up, removing a redundant custom varying and
   transform while preserving the original blend.
4. Self-notifying `TerrainGrassBlocker3D` nodes are no longer polled. Arbitrary
   nodes registered through the public API retain polling, and stale records are
   removed safely.
5. Terrain streaming, queue priority, commit eligibility, and LOD comparisons
   use squared distances. Streaming passes cache target-local coordinates and
   loop invariants, and internal hot paths avoid temporary public snapshot
   arrays.
6. Reflection-ground images now have explicit dirty invalidation. Relevant
   appearance changes rebake once, lightweight grass parameters update without
   an image bake, stale in-flight results are discarded, and `GrassQuality.OFF`
   publishes bare terrain rather than stale or black canopy data.
7. Convex and concave blocker bounds come from their real geometry, cache
   correctly, respond to in-place `Shape3D` changes, and remain correct after
   transform, rotation, and scale. Empty complex geometry is handled safely.

Additional correctness fixes found while implementing the plan include planar
X/Z blocker invalidation, translated-terrain reflection sampling, and safe
compaction when an interactor disappears between discovery and upload. The
performance probe now places test saves under `.godot` so benchmark runs do not
depend on access to a user's normal save directory.

## Files changed

- `addons/procedural_terrain_grass/shaders/grass_shell.gdshader`
- `addons/procedural_terrain_grass/core/grass_interaction_manager.gd`
- `addons/procedural_terrain_grass/core/terrain_manager.gd`
- `addons/procedural_terrain_grass/core/terrain_chunk.gd`
- `addons/procedural_terrain_grass/terrain_grass_3d.gd`
- `addons/procedural_terrain_grass/terrain_grass_blocker_3d.gd`
- `addons/procedural_terrain_grass/tests/phase1_smoke.gd` and its UID sidecar
- `addons/retro_rt/tests/ground_layer_smoke.gd`
- `game/tests/perf_probe.gd`
- `addons/procedural_terrain_grass/README.md`
- `README.md`
- `docs/PROCEDURAL_TERRAIN_GRASS_PHASE_1_RESULTS.md`

## Regression coverage

| Check | Renderer / mode | Result |
| --- | --- | --- |
| Phase 1 interactor and blocker-polling smoke test | Compatibility | Pass |
| Reflection-ground and complex-blocker smoke test | Compatibility | Pass |
| Terrain/player streaming smoke test | Threaded | Pass |
| Terrain/player streaming smoke test | Incremental (`--force-nothreads`) | Pass |
| Application flow smoke test | Compatibility | Pass |
| Application recovery smoke test | Compatibility | Pass |
| Grass shader startup | Compatibility / OpenGL | Pass |
| Grass shader startup | Forward+ / D3D12 | Pass |

The focused tests cover 0, 1, 4, and 8 interactors; count decreases and stale
slots; freed-node compaction; dynamic interaction disablement; notifying versus
polled blockers; convex, concave, empty, transformed, and edited shapes; clean
reflection updates; property invalidation; in-flight invalidation; `HIGH` to
`OFF` to `HIGH`; and translated bare-terrain publication.

This phase did not collect a separate LOW/MEDIUM/OFF timing sweep, direct GPU
queries, terrain-script or masking timers, or moving-target streaming-spike
measurements. Those remain useful follow-up measurements if later phases change
geometry, quality tiers, masking architecture, or chunk scheduling.
