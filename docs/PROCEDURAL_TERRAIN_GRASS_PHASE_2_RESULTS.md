# Procedural Terrain + Grass — Phase 2 Results

> **Historical record.** On 2026-08-28 the project became Forward+ only. The
> test notes below name the OpenGL Compatibility renderer, and the float16
> instance-data encoding they describe existed for it; Forward+ keeps float32 and
> the byte encoding is no longer used. The results were true when taken and are
> left unedited.

Phase 2 replaces the duplicated shell geometry with one base grass surface per
chunk drawn through prebuilt `MultiMesh` shell sets, and puts a conservative
broad phase in front of the static masker's exact physics queries. Validated on
August 26, 2026 against the Phase 1 working tree.

## Outcome

- No shell count, density, draw distance, mask resolution, terrain resolution,
  wind, lighting, or interaction setting was reduced.
- **The rendered frame is bit-identical.** 0 of 3,686,400 pixels differ at
  2560x1440 Forward+ against the pre-refactor capture, at zero maximum channel
  delta. This is not "below the noise floor" — it is exact.
- **Grass geometry per chunk fell 30x**: 32,670 vertices and 184,320 indices
  became 1,089 and 6,144. Persistent grass geometry across 24 loaded chunks fell
  from 40.80 MiB to 1.36 MiB.
- **Worker grass generation fell 29.7x**, from 74.45 ms/chunk to 2.51 ms/chunk;
  main-thread commit fell 28.4x, from 1.929 ms/chunk to 0.068 ms/chunk.
- **Exact physics queries fell by up to 98%** on sparse blocker layouts, with no
  dense-layout regression, and every one of eleven blocker scenarios produced
  byte-for-byte identical occupancy and fine-mask output.
- Steady-state frame time is neutral to slightly better on Forward+ and 3.3%
  better under Compatibility. No configuration regressed.

## Benchmark record

Shared across every run below unless stated otherwise:

```text
Godot version:            4.7.2.stable.official (ed1daf0bf)
GPU:                      NVIDIA GeForce RTX 4060
Terrain chunk size:       32.0
Terrain resolution:       32
Grass quality:            High
Grass shell counts:       16 / 10 / 4 (far top 0.75)
Grass density:            16.0
Grass draw distance:      load 64 m, hide 86 m
Loaded chunk count:       24
Active interactor count:  1 (the player) for app runs, 0 for the isolated bench
```

### Memory and geometry

Measured by `addons/procedural_terrain_grass/tests/phase2_bench.gd`, reading the
resources each chunk actually published.

| | Before | After | Change |
| --- | ---: | ---: | ---: |
| Grass vertices per chunk | 32,670 | 1,089 | −96.7% |
| Grass indices per chunk | 184,320 | 6,144 | −96.7% |
| Grass `Mesh` resources per chunk | 3 | 1 | −67% |
| Grass `MultiMesh` resources per chunk | 0 | 3 | — |
| Shell instances per chunk | — | 30 (16+10+4) | — |
| Approx. persistent grass geometry, 24 chunks | 40.80 MiB | 1.36 MiB | −96.7% |
| Engine static memory, headless bench at idle | 94.20 MiB | 62.98 MiB | −33.1% |

The geometry figure is calculated from the declared vertex payload (position,
packed normal/tangent, UV, colour, 32-bit index), not read from the driver: Godot
exposes no per-resource VRAM number. `MEMORY_STATIC` is a whole-process delta
under otherwise identical conditions, which is why it moves by less than the
geometry does.

Temporary worker allocation was not measured directly. It scales with the same
30x, since the worker's transient vertex/normal/colour/UV/index arrays are sized
from exactly the counts above.

### Generation and streaming

| | Before | After | Change |
| --- | ---: | ---: | ---: |
| Worker grass generation, per chunk | 74.453 ms | 2.510 ms | −96.6% |
| Main-thread grass commit, per chunk | 1.929 ms | 0.068 ms | −96.5% |
| Worker terrain generation, total | 93.65 ms | 95.73 ms | neutral |
| Settle to idle, no blockers | 1,050 ms | 408 ms | −61.1% |
| Settle to idle, `mixed` blockers | 1,180 ms | 677 ms | −42.6% |
| Settle to idle, `full_chunk` | 2,547 ms | 2,009 ms | −21.1% |

Grass commits are also cheaper per chunk than the table alone shows: the commit
queue used to spend three of its per-frame budget slots on one chunk (one per LOD
variant) and now spends one.

A 600-frame deterministic sweep across chunk boundaries after the change reports
median 4.155 ms, p95 9.140 ms, p99 9.382 ms, max 9.751 ms, having spent 204.09 ms
of worker time and 7.40 ms of commit time on grass across roughly 80 streamed
chunks. **The before side of this sweep was not captured** — no rapid-movement
baseline was taken before the refactor, and the pre-change tree was not
reconstructible afterwards. The streaming comparison above therefore rests on
settle-to-idle and per-chunk worker/commit cost, both measured on both sides.

The incremental single-threaded builder (`-- --force-nothreads`) was exercised
separately and produces identical geometry counts and identical masks.

### Masking

Eleven blocker layouts from the Phase 2 test list, each streaming the same 24
chunks. "Rejections" counts cell and subcell volumes the broad phase proved could
not overlap anything.

| Scenario | Exact queries before | after | Change | Mask CPU before | after | Rejections |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| none | 0 | 0 | — | 1.30 ms | 1.03 ms | 0 |
| tiny (one 0.6 m box) | 1,088 | 20 | −98.2% | 4.92 ms | 3.56 ms | 1,068 |
| several (six small) | 4,480 | 120 | −97.3% | 17.65 ms | 10.18 ms | 4,360 |
| building (14x6x10) | 3,232 | 1,878 | −41.9% | 19.51 ms | 15.08 ms | 1,354 |
| scattered (25 across chunks) | 21,760 | 800 | −96.3% | 72.99 ms | 43.11 ms | 20,960 |
| full_chunk (covers a chunk) | 16,896 | 11,819 | −30.0% | 94.28 ms | 75.88 ms | 5,077 |
| overlapping (8 stacked AABBs) | 4,720 | 1,571 | −66.7% | 23.60 ms | 17.00 ms | 3,149 |
| boundary (faces flush to cells) | 2,624 | 436 | −83.4% | 11.30 ms | 7.65 ms | 2,188 |
| unsupported (HeightMapShape3D) | 1,200 | 1,200 | 0% | 5.57 ms | 5.47 ms | 0 |
| unregistered (plain StaticBody3D) | 1,280 | 212 | −83.4% | 5.84 ms | 3.91 ms | 1,068 |
| mixed | 6,224 | 1,653 | −73.4% | 28.68 ms | 18.32 ms | 4,571 |

**Every scenario produced byte-identical output.** Occupancy and fine-mask bytes
for all 24 chunks were dumped to a binary blob in a stable coordinate order and
compared with `cmp`; all eleven matched exactly, 52,512 bytes each. Screenshots
were not relied on for this.

The two rows that matter most for the design are the last three:

- `unsupported` shows the fallback working. A `HeightMapShape3D` has no bound this
  add-on can derive, so the job discards its candidate set and runs the original
  exhaustive scan — identical query count, identical mask.
- `unregistered` shows why the candidates come from the physics query rather than
  from the registration list. A `StaticBody3D` that never called
  `register_static_grass_blocker()` still gets carved correctly, and still gets
  the 83% saving.
- `full_chunk` is the dense case the plan asked to guard. A candidate spanning the
  whole chunk cannot reject anything, so the comparison is skipped for that chunk;
  the 30% saving that remains comes from neighbouring chunks. Mask CPU still fell
  19.5%, so there is no dense-layout regression to trade against.

`boundary` is the case an exclusive AABB test would have got wrong. Candidate
bounds are grown by 1 cm before comparison, because `AABB.intersects()` treats
two boxes sharing a face as disjoint while both physics backends treat face
contact as an overlap.

### GPU and frame time

Forward+ at 2560x1440, 1,200 measured frames after 300 warm-up, camera parked.
Compatibility at 1920x1080 with a 2560x1440 internal render, 600 frames. Frame
intervals are rendered-frame wall clock, so they include the rest of the
application; the plan's caution about viewport GPU timers applies equally here.

| Configuration | Metric | Before | After | Change |
| --- | --- | ---: | ---: | ---: |
| Forward+, Retro RT off | Median | 4.401 ms | 4.398 ms | −0.1% |
| Forward+, Retro RT off | p95 | 4.676 ms | 4.715 ms | +0.8% |
| Forward+, Retro RT off | p99 | 4.816 ms | 4.870 ms | +1.1% |
| Forward+, Retro RT on | Median | 6.114 ms | 6.072 ms | −0.7% |
| Forward+, Retro RT on | p95 | 6.706 ms | 6.479 ms | −3.4% |
| Forward+, Retro RT on | p99 | 7.145 ms | 6.629 ms | −7.2% |
| Compatibility, Retro RT off | Median | 4.308 ms | 4.167 ms | −3.3% |
| Compatibility, Retro RT off | p95 | 4.713 ms | 4.380 ms | −7.1% |
| Compatibility, Retro RT off | p99 | 4.916 ms | 4.413 ms | −10.2% |

Forward+/RT-off figures are the median of three runs each; RT-on is the midpoint
of two. The RT-off p95/p99 movement is inside the spread of those runs (before
4.666–4.720 and 4.765–4.852; after 4.714–4.724 and 4.815–5.012) and is not a
result.

This is the expected shape. The same shell fragments are still rasterized — 288
shell instances across 24 visible chunks at the benchmark viewpoint, exactly the
shell count the duplicated geometry drew — so no large steady-state GPU win was
available and none appeared. **No draw-call reduction is claimed**: the previous
architecture was already one visible surface per chunk. The gains are in
generation, upload, and memory, which is what was predicted.

## Visual equivalence

| Renderer | Pixels changed | Max channel delta | Mean delta |
| --- | ---: | ---: | ---: |
| Forward+ 2560x1440 | 0 / 3,686,400 | 0.00000 | 0.000000 |

The capture is the same fixed viewpoint, seed, time of day and quality settings
before and after, with wind and the cloud offset pinned. The new build is also
deterministic across launches — two independent runs produced identical PNGs,
which the previous build did not reliably do — so the zero is a real zero rather
than two noisy images happening to agree.

Getting there required two measured corrections that a "looks the same" check
would have missed:

1. **Godot truncates vertex colours, it does not round them.** An authored 0.25
   is stored as 63/255, not 64/255. Quantising with `floor(f * 255 + 0.5)` would
   have shifted every Medium and Far shell by one code.
2. **`INSTANCE_CUSTOM.x / 255.0` in GLSL is not the fixed-function unorm8 decode.**
   A shader compiler may fold a division by a constant into a multiply by its
   reciprocal, and 1/255 is not exactly representable. That moved a handful of
   shells by one ULP, which is invisible in shell height and very visible at a
   blade silhouette, where it flips the `edge_coverage` and `random_height`
   discards: 187 differing pixels, up to 56/255 apart. Doing the decode on the CPU
   and multiplying by a uniform 1.0 removed it.

**A Compatibility pixel capture was not taken.** No Compatibility baseline image
existed before the change, and the pre-refactor tree could not be reconstructed
afterwards (the working tree carried uncommitted Phase 1 changes, so a stash
round-trip reaches the wrong commit). Compatibility equivalence is instead
established numerically — `phase2_smoke.gd` asserts that the shell level the
shader receives, after `u_shell_decode_scale`, lands on the pre-refactor fraction
within 1e-6 on that backend — plus the frame-time comparison above and a clean
boot with the instanced shader variant.

That numeric check found something worth recording: **Compatibility stores
MultiMesh custom data as float16.** Handing GLES3 the value 17/255 gets 0.06665
back, an error that reaches 2.4e-4 near the canopy top. The fix is that the two
backends are handed different encodings — Forward+ the finished float32 fraction
scaled by 1.0, Compatibility the 0-255 byte (exact in float16) scaled by 1/255 —
which brings Compatibility's error to about 1e-7 instead.

## Tests

| Test | Purpose |
| --- | --- |
| `addons/procedural_terrain_grass/tests/phase2_smoke.gd` | Shell encoding against a real `ArrayMesh` round trip, identity instance transforms, base-surface format and partial-cell topology, LOD/quality swapping without instance rebuilds, conservative-shape predicate |
| `addons/procedural_terrain_grass/tests/phase2_bench.gd` | The benchmark record above, plus `BENCH_DUMP` for exact mask comparison |
| `addons/procedural_terrain_grass/tests/phase1_smoke.gd` | Unchanged, passes |
| `addons/retro_rt/tests/ground_layer_smoke.gd` | Unchanged, passes |

`phase2_smoke.gd` passes under Forward+, Compatibility and headless; it skips the
instance and LOD assertions headless rather than passing them vacuously, because
the dummy driver accepts MultiMesh writes and stores nothing.

```bash
godot --path . --rendering-method forward_plus --script res://addons/procedural_terrain_grass/tests/phase2_smoke.gd
```

```bash
BENCH_SCENARIO=mixed godot --path . --headless --script res://addons/procedural_terrain_grass/tests/phase2_bench.gd
```

## Files changed

| File | Change |
| --- | --- |
| `addons/procedural_terrain_grass/core/terrain_generator.gd` | Shell byte quantisation, per-backend encoding choice, shared shell instance buffers |
| `addons/procedural_terrain_grass/core/terrain_build_state.gd` | Worker emits one base grass surface instead of three shell-expanded ones |
| `addons/procedural_terrain_grass/core/terrain_chunk.gd` | `MultiMeshInstance3D` with three prebuilt shell sets; obsolete `world_aabb()` removed |
| `addons/procedural_terrain_grass/core/terrain_manager.gd` | Single-surface commit, masking broad phase, conservative shape-bounds cache, benchmark counters |
| `addons/procedural_terrain_grass/shaders/grass_shell.gdshader` | Shell level from `INSTANCE_CUSTOM`, `u_shell_decode_scale` |
| `addons/procedural_terrain_grass/terrain_grass_blocker_3d.gd` | `shape_bounds_are_conservative()` |
| `addons/procedural_terrain_grass/terrain_grass_3d.gd` | Pushes `u_shell_decode_scale`, exposes lifetime mask counters |
| `addons/procedural_terrain_grass/README.md` | New architecture, encoding rules, broad-phase behaviour |
| `addons/shader_warmup/shader_warmup_manifest.gd` | `MULTIMESH_CUSTOM_DATA` / `MULTIMESH_COLORS` pair flags |
| `addons/shader_warmup/shader_warmup_scanner.gd` | Records those flags from the scanned `MultiMesh` |
| `addons/shader_warmup/shader_warmup.gd` | Instanced proxy reproduces the per-instance channels |
| `game/warmup/generate_warmup_assets.gd` | Grass proxy is a `MultiMeshInstance3D` with custom data |
| `game/warmup/terrain_grass_proxy.tscn`, `grass_vertex_format.res`, `game/materials/warmup_grass.tres`, `generated/shader_warmup_manifest.tres` | Regenerated by the warmup asset generator |
| `game/tests/perf_probe.gd` | Finds the grass through `MultiMeshInstance3D`, reports drawn shell instances |
| `addons/procedural_terrain_grass/tests/phase2_smoke.gd`, `phase2_bench.gd` | New |

## Not implemented, and why

- **`visible_instance_count` for LOD selection.** Near ends at 1.00, Medium at
  0.95 and Far at 0.75, so the three sequences are not prefixes of one another and
  a shared buffer with a moving count would change every shell height. Three
  resources per chunk cost 30 instances of buffer, which is nothing next to the
  geometry removed.
- **A shared base mesh across chunks.** Terrain height, normals, occupancy and
  fine-mask bytes are all chunk-specific; there is nothing to share.
- **A fine-mask texture.** Out of the approved scope, and it would trade exact
  8-bit mask bytes for filtering and sampling risk on Compatibility to save
  vertex colour that the surface carries anyway.
- **Precomputing every cell and subcell AABB.** Only the active cell's four corner
  heights and origin terms are cached, because the subcell bounds expressions are
  boundary-sensitive: folding `origin + (x + u) * spacing` into
  `(origin + x * spacing) + u * spacing` is a different float and would move mask
  bits. The cheap wins — integer row/column derivation, one transform read per
  masking call instead of one per cell, constant cell extents — were taken.
- **Local-space cell bounds for the broad phase.** Rejected as a staleness risk:
  the system can be translated between frames, and a mask job spans frames, so
  candidate bounds stay in the world space physics reported them in. The
  comparison is cheap next to the queries it removes.
- **Making blocker registration mandatory.** Explicitly out of scope; the query
  enumerates colliders directly, so unregistered bodies on the blocker layer keep
  working with no compatibility change.
