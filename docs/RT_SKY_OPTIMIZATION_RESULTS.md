# Retro RT and Day/Night Sky Optimization — Results

Removes redundant per-frame CPU work from `RTSceneManager`, redundant per-pixel
work from the day/night sky shader, and the per-frame allocation churn in the
Compatibility tracer. Every change is either provably output-identical or was
verified pixel-by-pixel.

**The headline result is honest and worth stating first: frame time did not
move.** The redundant work was real and is gone — receiver light-list rebuilds
dropped 98%, the RT manager's main-thread cost dropped ~45% — but this frame is
GPU-bound at 2560x1440, so removing main-thread work does not show up in it. The
subsystem isolation in "Where the frame actually goes" is the more useful output
of this pass, and it says the remaining headroom is somewhere the plan
deliberately did not go.

## Benchmark record

```text
Godot version:            4.7.2.stable.official (ed1daf0bf)
GPU:                      NVIDIA GeForce RTX 4060
Renderer:                 Forward+ at 2560x1440
RT backend:               hardware (software runs called out explicitly)
Camera:                   probe default, yaw -142 deg, pitch -9 deg
Scene:                    game/levels/terrain_test.tscn
Time of day:              10.5, clock RUNNING (PERF_CLOCK=1)
Grass quality:            High
Loaded chunk count:       24 (24 drawing, 288 shell instances)
Managed instances:        27 (24 receiver-only)
Lights:                   2 (sun + moon)
Measured frames:          1200 after 300 warm-up and 240 streaming frames
Runs:                     median of 3 unless stated
```

### The clock is the whole benchmark

`PERF_CLOCK` is off by default in the probe, and **a frozen-clock run cannot
measure any of this**. With the sun stationary no light ever changes, the
redundant rebuild never fires, and the main optimisation measures as exactly
zero — while the shipping default is `time_running = true`
(`day_night_cycle_3d.gd`). Every number below uses `PERF_CLOCK=1`.

### Thermal drift is larger than the effect

Runs taken ~40 minutes apart on a warm GPU differ by more than the change being
measured. The session-start baseline read 6.100 ms; re-running that *same
unmodified build* at the end of the session read 6.136 ms. The before/after
comparison below therefore uses the re-baseline, taken back-to-back with the
final build. Comparing against the cold baseline would have reported a spurious
0.044 ms regression.

## Frame time — before and after

Hardware, everything enabled, clock running.

| | Baseline (re-run) | After | Change |
|---|---|---|---|
| Median | 6.136 ms | 6.144 ms | +0.008 ms (noise) |
| p95 | 6.580 ms | 6.575 ms | −0.005 ms (noise) |
| p99 | 6.728 ms | 6.711 ms | −0.017 ms (noise) |

Run spread within each set is ~0.08 ms, so nothing here is a result. **Frame time
is unchanged.**

## RT manager CPU — before and after

Same runs, `PERF_PROFILE=1`.

| | Baseline | After | Change |
|---|---|---|---|
| `_process` last | 291 / 396 / 400 µs | 215 / 179 / 185 µs | **−45%** |
| `_process` peak | 649 / 674 / 723 µs | 411 / 431 / 365 µs | **−41%** |
| Receiver-list rebuilds | 1804–1807 | **39–40** | **−98%** |
| Polled frames | ~1789 | ~1789 | — |
| Receiver-light revision | 18–20 | 18–19 | unchanged |

The revision column is the correctness check: the number of times the rebuilt
list was *actually different* is unchanged, so the 1765 rebuilds now skipped per
run were all producing byte-identical output.

New counters make this directly visible:

```text
light updates: shading 1787, influence 0; rebuilds skipped 1765, receivers recomputed 345
```

A rotating sun produces 1787 shading-class updates and **zero** influence-class
updates, which is the intended classification — a directional light is never
culled against a receiver, so its direction cannot change any candidate list.

## Where the frame actually goes

Each subsystem switched off in isolation, against a 6.14 ms frame. This is the
most actionable output of the pass.

| Subsystem off | Median | Its share of the frame |
|---|---|---|
| Grass | 4.166 ms | **1.92 ms (31%)** |
| RT | 4.423 ms | **1.67 ms (27%)** |
| SMAA | 5.615 ms | 0.47 ms (8%) |
| Sky (whole dome) | 5.838 ms | 0.25 ms (4%) |
| — clouds only | 5.957 ms | 0.19 ms |
| — stars only (at night) | 5.891 ms | 0.027 ms |
| Reflection-ground trace | 6.133 ms | **~0 ms** |
| Colour grading | 6.113 ms | **~0 ms** |

Two conclusions fall straight out:

1. **Grass and RT are 58% of the frame.** Everything this pass was scoped to
   touch totals under 0.5 ms, and the achievable fraction of that is ~0.2 ms.
2. **Grading and reflection-ground tracing cost nothing measurable.** Both were
   slated for investigation; both are now closed with a number instead of a
   guess.

One loose thread worth recording: RT costs 1.67 ms in total but its ray dispatch
is only 0.37 ms of GPU time. The other ~1.3 ms is TLAS work, the post-process
stack, and the carrier-layer forward pass — none of which this pass examined.

## Sky shader — before and after

Night (`PERF_TIME=0.0`), where the star field is active.

| | Before | After | Change |
|---|---|---|---|
| Median | 5.952 ms | 5.918 ms | −0.034 ms |
| Sky's share at night | 0.32 ms | 0.28 ms | −0.04 ms |
| Star field's share | ~0.07 ms | **0.027 ms** | **−61%** |

Midday is unchanged, as expected: `u_star_intensity` is already zero in daylight,
so the star gate has nothing to skip there.

### Pixel identity

The acceptance test the probe's own documentation demands — *"an optimisation
that is supposed to be free has to come back at zero differing pixels, and that
is not something to take on faith."* Grass hidden for an exactly reproducible
frame; star twinkle frozen (see below).

| View | Pixels differing (of 3,686,400) |
|---|---|
| Midday | **0** |
| Sunset | **0** |
| Night | **0** |
| Cloud-heavy (pitch +25) | 1, at 1/255 |

The single cloud-heavy pixel is renderer nondeterminism, not the change: the
**same build compared against itself** produces the identical 1-pixel, 1/255
difference. The sky changes are bit-exact.

## Software backend — before and after

`PERF_BACKEND=software`, 900 frames after 120 warm-up, median of 3.

| | Before | After | Change |
|---|---|---|---|
| Median | 5.323 ms | 5.296 ms | −0.027 ms (inside spread) |

Run spread is ~0.10 ms, so this is not a result either. The per-frame
allocations are gone — a `PackedFloat32Array`, a byte-array copy, an `Image`, and
an `Array[Vector4]`, all rebuilt every frame the sun moved — but at 27 instances
and 1 active light the atlas is small enough that the allocator was not the
bottleneck. The change should matter more at larger instance counts, and it
removes steady-state garbage regardless.

## Changes

### `addons/retro_rt/scripts/RTSceneManager.gd`

1. **Light change classification.** `_light_snapshot_matches_current()` became
   `_light_snapshot_change()`, returning none / shading / influence. Only an
   influence-class change rebuilds receiver candidate lists. Field membership per
   light type is derived strictly from what `_light_cannot_affect_receiver()` and
   the cull-mask test actually read — a directional light returns from the culler
   before its direction, position or range are consulted, so none of them can
   affect a candidate list. Membership drift (a light dropping out on zero energy
   or visibility) shifts later indices and is always influence-class.
2. **Snapshot commit no longer deep-copies the registry.** `_render_instances` is
   already copy-on-write at every mutation site, and no record in it is edited in
   place, so a published clone stays valid until the registry is replaced. Guarded
   by `_render_instances_revision`; previously one dictionary per receiver was
   re-materialised every frame.
3. **`_compare_material_record()` allocates nothing on the unchanged path.** It
   used to build a full 20-key record plus four sRGB conversions purely to
   discover nothing had changed. Values are now compared in place with an early
   bail. The record carries the authored sRGB colours alongside the linear ones so
   the comparison is a plain equality rather than 12 `pow()` calls. The
   `-2 / -1 / 0 / 1` contract, including both shader-identity and type validation,
   is preserved exactly.
4. **Light paths cached at discovery.** `String(light.get_path())` ran per light
   per frame — a tree walk plus a string build — for a value only a diagnostic
   reads.
5. **Per-surface topology validation amortised.** `get_active_material()` per
   surface per receiver per frame resolves the override chain inside the engine,
   and only ever catches an authoring error that hard-fails the manager anyway. It
   now sweeps a slice per frame, covering every receiver within 12 frames. The
   cheap mesh-identity check stays on every frame, and registration still
   validates a receiver in full before it reaches the sweep.
6. **`_instance_rt_mask()` takes the cached `receiver_only` flag** instead of a
   group lookup per receiver per frame.
7. **`get_surface_count()` hoisted** — it was called twice per receiver per frame.

### `addons/retro_rt/scripts/RTLightingEffect.gd`

8. **Constant dispatch facts published only on resize.** This ran on the render
   thread every frame, allocating a 7-key dictionary and taking the profile mutex
   whether or not profiling was enabled — unlike its two siblings, which are
   gated.

### `addons/retro_rt/scripts/RTSoftwareTracer.gd`

9. **Atlas staging reused across frames.** A retained `PackedFloat32Array`,
   retained `Image` per kind refilled via `set_data()`, and a retained texel
   array. The float buffer is written through the member deliberately: a packed
   array is copy-on-write, so a local reference would clone the whole buffer on
   first store and defeat the reuse. A shorter table clears only the tail it
   leaves behind.

### `addons/day_night_cycle/shaders/day_night_sky_common.gdshaderinc`

10. **Star field gated on the horizon mask.** The mask was computed and then
    applied as a post-multiply, so every fragment below the horizon ran the
    nine-cell field only to be multiplied out by zero — most of a camera-centred
    box dome, all night.
11. **Squared-distance rejection in the star loop.** The core `smoothstep` is
    exactly zero once distance reaches the radius, so those cells skip the square
    root, the twinkle sine and the tint mix. Compared squared — feeding squared
    values into the `smoothstep` itself would bend the falloff and reshape every
    star, which is why the original plan's formulation was rejected.
12. **Cloud distance fade hoisted above the second density tap.** The fade
    depends only on travel distance but was applied last, so the whole band beyond
    the fade distance paid for *both* four-octave taps before being zeroed. Clear
    sky now also skips the sun tap and the colour mix.

### `addons/day_night_cycle/day_night_cycle_3d.gd`

13. **`stars_enabled`**, mirroring the existing `clouds_enabled`.
14. **`_twinkle_frozen`** for reproducible night captures. Twinkle advanced from
    raw `delta` regardless of `time_running`, so two runs of the same build landed
    on different phases and every star differed — night pixel comparison was
    impossible before this.

### `game/tests/perf_probe.gd`, `README.md`

15. **`PERF_CLOUDS`, `PERF_STARS`, `PERF_GROUND`, `PERF_BACKEND=software`.**
    `PERF_CLOUDS` was already documented in `README.md` but had never been
    implemented — setting it silently did nothing.
16. Light-class counters printed; twinkle frozen alongside wind on capture; the
    `PERF_CLOCK` trap documented in both the probe header and the README.

## Investigated and deliberately left alone

- **Cloud noise lattice sharing between the two density taps.** The taps differ
  by ~0.03 noise units, so they land in the same lattice cell only sometimes —
  data-dependent, so the branch diverges — and the restructure cannot be shown
  bit-exact. It also rewrites the block `day_night_smoke.gd` pins by text.
- **Precomputed gradient/normal data for the reflection ground.** The ground map
  is RGBA32F with RGB = albedo and A = canopy height; there is no free channel.
  Now moot: the path measures at ~0 ms.
- **Conservative min/max terrain height hierarchy.** Large complexity for a path
  that measures at ~0 ms.
- **Fusing colour grading into another fullscreen pass.** Grading measures at
  ~0 ms.
- **Splitting the frame UBO into static and dynamic halves.** 368 bytes, and the
  camera matrices change every frame anyway.
- **Grass and SMAA.** The two largest remaining GPU costs (1.92 ms and 0.47 ms).
  Out of scope for this pass by design — grass was recently optimised — but they
  are where the remaining headroom is.

Nothing in this pass lowers a quality setting: no ray counts, march steps, noise
octaves, star density, LUT precision, grass or terrain quality were reduced.

## Verification

- `addons/day_night_cycle/tests/day_night_smoke.gd` — PASS
- `addons/retro_rt/tests/receiver_registry_smoke.gd` — PASS, with registry
  counters identical to the pre-change run (28 instances, 26 registrations, 26
  unregistrations, 4556 triangles, receiver-light revision 53)
- `addons/procedural_terrain_grass/tests/phase2_smoke.gd` — OK
- Pixel identity across midday, sunset, night, and a cloud-heavy view, against a
  self-vs-self control run to establish the noise floor

Reproduce the main comparison with:

```bash
PERF_CLOCK=1 PERF_PROFILE=1 PERF_LABEL=after godot --path . --script res://game/tests/perf_probe.gd
```

---

# GPU Pass — Grass, Retro RT, SMAA, Sky

The CPU pass above removed redundant main-thread work but did not move frame
time, because the frame is GPU-bound. This pass targets the GPU side, at native
quality, without disturbing the resolution-scaling presets.

**Result: median frame 5.498 ms → 5.025 ms (−8.6%), 181.9 → 199.0 FPS.** Every
shipped change is verified at zero differing pixels.

## Three measurement faults found first

None of these are optimizations. All three had to be fixed before any number in
this section could be trusted, and two of them silently understate cost.

**1. The benchmark was vsync-capped.** The project sets no vsync mode, so
Godot's default (enabled) applied, and on a 240 Hz panel every frame landed on a
4.167 ms boundary. With everything switched off — no grass, no sky, no SMAA, no
RT — the frame still measured 4.164 ms while total measured GPU work was
1.620 ms. **Nothing below 4.167 ms was measurable at all**, so any optimization
reaching that floor would have read as "no further change". Grass measured
1.92 ms capped and **3.154 ms uncapped**. `perf_probe.gd` now disables vsync
itself rather than relying on a flag being remembered.

**2. `PERF_RT=0` also re-enabled two shadow-map cascades.** Both the sun and the
moon are authored `shadow_enabled = true`, and Retro RT suppresses them while it
runs; stopping RT restores them. The old "RT costs 1.67 ms" was really
(RT stack) minus (two 4-split directional cascades). Those cascades measure
0.405 ms on their own. `PERF_NATIVE_SHADOWS=0` now forces them off so both
halves of the comparison match.

**3. `PERF_SMAA=0` left the resolve pass running**, by explicit design, so the
earlier 0.47 ms was the two preprocessing passes only.

`RenderingServer.viewport_set_measure_render_time` was unused in the project. It
is now wired into the post stack behind `profiling_enabled`, which is what
attributes the SMAA and present passes — they are 2D canvas draws with no
render-thread hook, so `capture_timestamp` cannot bracket them.

## Where the frame actually goes

Vsync off, native shadows off, base 5.560 ms. This replaces the earlier table,
which was measured through the cap.

| Subsystem | Cost | Share |
|---|---|---|
| **Grass** | **3.154 ms** | **57%** |
| Retro RT (gross) | 1.576 ms | 28% |
| SMAA (all three passes) | 0.553 ms | 10% |
| Sky | 0.084 ms | 1.5% |

Per-viewport GPU time, base build:

```text
scene 4.306   smaa_edges 0.135   smaa_weights 0.188   smaa_resolve 0.235   root_present 0.117
```

**The scene render is ~80% of the frame and the entire post chain is 0.674 ms.**
That killed the bandwidth hypothesis this pass started with: the four full-res
RGBA16F targets were estimated at 0.6–1.1 ms of traffic and are not close to it.

## Changes

All three are grass, all bit-exact, all verified at 0/3686400 differing pixels
against a same-build control.

**1. Canopy-first shell order** (`core/terrain_generator.gd`) — **−0.330 ms.**
Shells were emitted ground-first, and MultiMesh instances rasterize in buffer
order while Godot's opaque sort works per `GeometryInstance3D` — so it cannot
reorder shells inside a chunk. With the camera above the field that drew them
far-to-near: the worst possible order, every shell fully shaded, nothing ever
occluded. Emitting the canopy first lets the depth prepass reject the shells
underneath. The set of heights is unchanged; only the sequence differs, and two
shells never share a depth.

**2. Cell reuse across the warp refinement** (`shaders/grass_shell.gdshader`) —
**−0.125 ms.** The wind/interaction warp is clamped to 0.4 of a cell, so most
fragments land back in the cell they started from. The second `hash22` and the
second `wind_for` are pure functions of that cell, so when it has not changed
they recompute bit-identical numbers — three sines to arrive where we already
were. Now recomputed only when the warp genuinely crosses an edge, which is the
case the refinement exists to serve.

**3. Shared logarithm for the two blade tapers** — **−0.039 ms.** `width_taper`
and `length_taper` are the same base raised to different exponents, and `pow` is
`exp2(y * log2(x))`, so the logarithm is taken once instead of twice.

## Before and after

Native, vsync off, native shadows off, 1200 frames after 300 warm-up, median of
3, baseline re-run back-to-back with the final build.

| | Before | After | Change |
|---|---|---|---|
| Median | 5.498 ms (181.9 FPS) | **5.025 ms (199.0 FPS)** | **−8.6%, +17.1 FPS** |
| p95 | 5.937 ms | 5.424 ms | −8.6% |
| p99 | 6.009 ms | 5.583 ms | −7.1% |
| Scene pass GPU | 4.305 ms | 3.886 ms | −9.7% |

Run spread was ~0.05 ms per set and the two sets do not overlap.

### Resolution-scaling presets still work, and benefit

Required, since the presets must remain available and composite a cheaper base.

| Preset | Render size | Before | After | Change |
|---|---|---|---|---|
| QUALITY (0.85) | 2176×1224 | 4.550 ms | 4.265 ms | −6.3% |
| BALANCED (0.75) | 1920×1080 | 3.844 ms | 3.612 ms | −6.0% |

Both engage at the correct internal size with the FSR target allocated, and no
contract failure is raised.

## Rejected, with the measurement that rejected it

- **Conservative early silhouette rejection.** Bounding the blade ellipse before
  the two `pow`s, the rotation and the `fwidth` is sound in principle — but the
  `fwidth`-driven edge band widens the acceptance region view-dependently and
  without bound, which is the minification behaviour that keeps distant grass
  from aliasing. At a 1.5× radius margin it cut visible blades: **6.59% of pixels
  differing, max delta 243/255, for 0.028 ms.** No margin is both tight enough to
  pay and loose enough to be safe.
- **8-bit SMAA edge and blend-weight targets.** The reference SMAA formats, and
  three of the four offscreen targets hold LDR data. Measured **slower**
  (5.066 → 5.125 ms) *and* 0.416% of pixels differing at up to 5/255. These
  passes are not bandwidth-bound at this resolution.
- **Disabling the depth prepass.** 5.105 → **9.362 ms**. Early-Z rejection in
  the colour pass is doing enormous work; the prepass stays.
- **The per-vertex colour noise.** Four sines per vertex across ~313k vertex
  invocations, and stubbing it changed nothing measurable (4.041 vs 4.027 ms).
  The shader is fragment-bound, not vertex-bound.

## Diagnostics, for whoever optimizes this next

Throwaway builds that change the image, measured only to locate cost. They are
the map of what is left in the grass fragment shader:

| Stub | Saving |
|---|---|
| Both silhouette `pow` calls removed | 0.500 ms |
| `fwidth` in the edge band removed | 0.347 ms |
| `hash22` sine removed (4 per fragment) | 0.261 ms |
| `wind_for` stubbed (2 sines, kills the warp) | 0.219 ms |

The remaining cost is concentrated in the blade silhouette test, which every
covered fragment of every shell runs in the prepass. It is not reachable without
either changing blade shape or finding a rejection that survives the `fwidth`
band.

## Also worth knowing

**Night and sunset captures cannot verify anything.** `_star_seed` is drawn from
a per-run RNG (`day_night_cycle_3d.gd:861`), so two runs of the *same build*
differ by **15.3% of pixels at night** and 0.46% at sunset — larger than the
differences under test. Midday and horizon-heavy views are reproducible and both
came back at exactly 0. Pinning the seed under `PERF_SHOT`, the way wind and
twinkle already are, would make the night path testable.

## Verification

- Midday and horizon-heavy captures: **0/3686400 pixels differ**, each change
  also verified individually at 0 against a same-build control
- `day_night_smoke.gd` PASS, `receiver_registry_smoke.gd` PASS,
  `phase2_smoke.gd` OK
- `phase2_bench.gd`: shells 16/10/4, 1089 vertices and 6144 indices per chunk,
  mask hash 2109454005 — geometry unchanged, only draw sequence
- CPU non-regression: manager `_process` 192 µs, `light_influence_updates` 0
  with a moving sun, receiver-list rebuilds 43 across 1029 polled frames

New probe toggles: `PERF_NATIVE_SHADOWS`, `PERF_RT_QUALITY`, `PERF_VSYNC`,
`PERF_GROUND`, plus per-pass GPU timing under `PERF_PROFILE=1`.

```bash
PERF_NATIVE_SHADOWS=0 PERF_CLOCK=1 PERF_PROFILE=1 godot --path . --script res://game/tests/perf_probe.gd
```

---

## Follow-up: the blade-cell lattice artifact

Reported from a top-down view — a bright green grid boxing in each blade group,
crawling as the camera moved. **Pre-existing, not introduced by the work above:**
a straight-down A/B of the optimized build against the pre-optimization build
came back at 0/3686400 pixels differing. Worth noting that none of the earlier
captures covered a top-down camera, which is why it took a bug report rather than
the pixel suite to surface it.

### Cause

`grass_shell.gdshader`, the blade silhouette test:

```glsl
float edge_width = max(fwidth(ellipse_distance) * 1.25, 0.025);
float edge_coverage = 1.0 - smoothstep(1.0 - edge_width, 1.0 + edge_width, ellipse_distance);
if (edge_coverage < 0.42) { discard; }
```

`ellipse_distance` is assembled entirely from per-cell values — the cell hash,
the stalk centre, the blade orientation, and both blade axes. All of them are
constant inside a 6.25 cm blade cell and **jump at its border**.

`fwidth()` reports how much a value changes across a 2x2 pixel quad. On a quad
straddling a cell border it samples that jump rather than a gradient and returns
an enormous number. `edge_width` inflates far past the blade, and
`edge_coverage` collapses toward **0.5 everywhere along the border** — above the
0.42 threshold. Fragments therefore survive the discard where no blade exists,
shaded at `mix(0.88, 1.0, ~0.5)` ~= 94% brightness, and the cell lattice draws
itself across the field. It is worst looking down (most cell borders per pixel)
and crawls in motion because the lattice is world-anchored while the pixel quads
are not.

### Fix

The band still wants to be one pixel wide in the ellipse's own space, but the
footprint is now taken from `base_xz` — the fragment's world position, which is
continuous across cell borders — and carried into ellipse space analytically
(`d(dot(e,e)) = 2 * |e| * d|e|`, with the narrower axis bounding `d|e|`). The
discontinuity is gone by construction rather than clamped after the fact.

A one-token alternative (`clamp(fwidth(...), 0.025, 1.0)`) also removes most of
the lattice and is noted here in case the analytic version ever needs backing
out, but it caps a symptom and leaves residual grid at extreme angles.

### Result

**It is also a performance win**, because the runaway band had been keeping dead
fragments alive through the discard and shading them:

| | Before fix | After fix |
|---|---|---|
| Median | 5.025 ms (199.0 FPS) | **4.789 ms (208.8 FPS)** |
| p95 | 5.424 ms | 5.085 ms |

Verified clean at -88, -40 and -9 degrees pitch. The image change is large
(40.6% of pixels) because the coverage test changes for every fragment near a
cell border — that is the artifact being removed, and it is the one change in
this document that is *intended* to alter the picture.

`phase2_smoke.gd` OK, `receiver_registry_smoke.gd` PASS.

## GPU pass, final totals

Including the lattice fix, against the pre-GPU-pass baseline:

| Configuration | Before | After | Change |
|---|---|---|---|
| Native | 5.498 ms (181.9 FPS) | **4.789 ms (208.8 FPS)** | **−12.9%, +26.9 FPS** |
| QUALITY (0.85) | 4.550 ms (219.8 FPS) | 4.018 ms (248.9 FPS) | −11.7% |
| BALANCED (0.75) | 3.844 ms (260.1 FPS) | 3.367 ms (297.0 FPS) | −12.4% |

---

## Final pass: private carrier-layer raster culling

This pass removes authored raster lights from hardware RT's private material-ID
carrier layer. Managed renderer instances are placed on layer 20 alone at the
RenderingServer, while authored lights have layer 20 removed from their
renderer cull masks. Their authored `layers` and `light_cull_mask` properties
remain untouched and continue to drive the shared RT receiver/light lists.

**The output is bit-exact, and the performance effect is zero.** An independent
interleaved re-measurement (A/B/A/B/A/B, 1200 frames each, the optimization
stashed and restored between consecutive runs) puts the change at
**+0.010 ms frame time and −0.004 ms scene GPU — both inside a ~0.03 ms run
spread**:

| | With change | Without change |
|---|---|---|
| Median frame | 4.334 / 4.365 / 4.360 ms | 4.326 / 4.351 / 4.350 ms |
| Scene-pass GPU | 3.444 / 3.452 / 3.443 ms | 3.425 / 3.448 / 3.455 ms |

An earlier write-up of this pass reported a **−0.273 ms (−6.5%)** scene-pass
win. That figure does not reproduce, and it was internally inconsistent on its
own terms: it reported the scene pass falling 0.273 ms while frame time *rose*
0.038 ms. The frame is GPU-bound and the scene pass is ~80% of it, so both
cannot be true.

The cause is a sampling error worth recording, because the trap is easy to walk
back into. **`post_pass_gpu_ms` is a single-frame snapshot taken at report time,
not a distribution** — `viewport_get_measured_render_time_gpu()` returns the last
frame's value, so a median-of-three over that statistic is a median of three
individual frames, not of 3600. It cannot resolve a 0.27 ms effect. Frame-time
median over 1200 frames is the reliable statistic; where the two disagree, the
distribution wins.

**Why there was nothing to win.** The wasted evaluations are the sun and moon —
directional lights, which Forward+ does not cluster-cull, so they are the only
lights that touch every managed pixel. Their `light()` body is empty under RT,
shadows are already suppressed, and the terrain underneath is largely occluded by
grass and rejected by the depth prepass, so the managed pixel count actually
paying for them is far smaller than terrain's nominal coverage. Local omni and
spot lights are already cluster-culled, so this does not grow into a win as a
level gains lights either.

The change was kept regardless: it is verified harmless, and it makes the layer
semantics honest — managed geometry takes all of its lighting from the RT
dispatch, so it never belonged on authored light layers. The test coverage added
alongside it is the more durable outcome of this pass.

### Benchmark protocol

```text
Godot version:            4.7.2.stable.official (ed1daf0bf)
GPU:                      NVIDIA GeForce RTX 4060
Renderer:                 Forward+ / Vulkan at 2560x1440
RT backend:               hardware
Camera:                   yaw -142 deg, pitch -9 deg
Scene:                    game/levels/terrain_test.tscn
Clock:                    running (PERF_CLOCK=1)
Native shadow maps:       forced off in both halves
Measured frames:          1200 after 300 warm-up frames
Runs:                     median of 3, baseline and final interleaved
```

All feature toggles were explicitly enabled. `PERF_PROFILE=1` and
`PERF_VSYNC=0` were used for every performance run.

### Carrier-cost gate

The measurement-only `PERF_CARRIER=0` toggle hides
`__RTMaterialIDCarrier`. It deliberately breaks managed-pixel lighting and is
not a supported quality mode.

| Configuration | Median | p95 | p99 |
|---|---:|---:|---:|
| A — RT on, carrier on | 5.025 ms | 6.047 ms | 6.470 ms |
| B — RT on, carrier off | 4.912 ms | 6.050 ms | 6.468 ms |
| C — RT off | 3.587 ms | 4.333 ms | 4.722 ms |

The raw A−B gate was **0.113 ms**. That sits in the plan's optional/simple
implementation band, and the renderer-only mask change was sufficiently small
and reversible to proceed.

The toggle is not an exact carrier-raster isolator: removing the ID carrier also
makes managed-pixel RT dispatch/resolve early-out. A−B and B−C therefore cannot
be treated as independent, additive carrier and engine measurements. The most
defensible accounting is:

| Quantity | Time | Interpretation |
|---|---:|---|
| Gross RT integration, A−C | 1.438 ms | Measured frame-interval difference |
| Post stack sample | ~0.578 ms | SMAA edges/weights/resolve plus root present |
| Active RT dispatch sample | ~0.339 ms | Hardware compositor timestamp |
| Arithmetic remainder | ~0.521 ms | Raster plus engine plumbing; not separately isolated |
| Carrier-enabled gate, A−B | 0.113 ms | Mixed carrier/dispatch/resolve effect; non-additive |

### Native before/after

| Metric | Baseline | Final | Change |
|---|---:|---:|---:|
| Median frame interval | 4.995 ms (200.2 FPS) | 5.033 ms (198.7 FPS) | +0.038 ms (noise) |
| p95 | 6.203 ms | 6.050 ms | −0.153 ms |
| p99 | 6.723 ms | 6.350 ms | −0.373 ms |
| Scene-pass GPU snapshot | 4.201 ms | 3.928 ms | −0.273 ms — **does not reproduce; single-frame sample** |
| Sum of reported GPU passes | 4.787 ms | 4.514 ms | same artifact |
| `RTSceneManager._process` last | 171 µs | 182 µs | +11 µs (noise), below 250 µs target |
| Receiver-list rebuilds | 41 | 39 | No per-frame rebuild regression |

The two scene-pass rows are retained only to document the sampling error; see the
interleaved re-measurement at the top of this section for the real figure. **This
pass did not meet its 0.25 ms target.** The optimization is output-identical and
costs nothing, but it does not measurably improve frame time on this machine, and
the residual RT cost is engine-forced — the `needs_normal_roughness` prepass
promotion, the separate-specular MRT, and the specular merge, none of which are
reachable from this codebase because the RT shader genuinely consumes both
targets.

Later CPU spot-check after the change, for the record: `_process` 130 µs,
`light_influence_updates` 0 with a moving sun, 40 receiver-list rebuilds across
1322 polled frames — all consistent with the CPU pass and no regression from the
per-frame `light_set_cull_mask` re-assertion.

### QUALITY and BALANCED presets

| Preset | Internal target | Baseline median | Final median | p95, before → after | p99, before → after |
|---|---:|---:|---:|---:|---:|
| QUALITY (0.85) | 2176×1224 | 4.180 ms | 4.161 ms | 5.055 → 5.075 ms | 5.402 → 5.350 ms |
| BALANCED (0.75) | 1920×1080 | 3.486 ms | 3.471 ms | 4.429 → 4.381 ms | 4.761 → 4.796 ms |

Both presets selected the expected internal target and reported the FSR EASU
pass. Their 0.019 and 0.015 ms median changes are within noise; neither preset
regressed materially and no quality setting was reduced.

### Pixel-exact output gate

Cross-launch captures disable the procedural stars and grass and freeze the
parked player after applying its camera transform. Those controls are necessary
because the star seed is generated per process and the grass mask has a known
~1/255 cross-launch floor. Every baseline self-control and every final-vs-
baseline comparison was exact across all 3,686,400 pixels:

| View | Baseline self-control | Final vs baseline | Maximum channel delta |
|---|---:|---:|---:|
| Default (yaw −142°, pitch −9°) | 0 pixels | 0 pixels | 0 |
| Horizon (yaw −142°, pitch 0°) | 0 pixels | 0 pixels | 0 |
| Top-down (yaw −142°, pitch −88°) | 0 pixels | 0 pixels | 0 |
| Reflector-facing (yaw 18°, pitch −4°) | 0 pixels | 0 pixels | 0 |

### Runtime contracts and smoke coverage

- Hardware startup and camera switches now reject an active camera whose
  `cull_mask` omits reserved layer 20, reporting the camera path and layer.
- Newly discovered and already-managed authored lights have the private bit
  cleared at the RenderingServer, and polling reasserts the override after live
  mask edits. Stop/removal restores the current authored mask.
- A moving local `OmniLight3D` remains an RT candidate, updates receiver lists
  when moved out and back into range, and retains its authored cull mask in both
  hardware and software paths.
- `receiver_registry_smoke.gd` passed on software and hardware;
  `terrain_player_smoke.gd`, `day_night_smoke.gd`, and `phase2_smoke.gd` also
  passed. A full editor import/parse run completed without script errors.

---

## Grass pass 2: fog-band culling and shell-constant hoisting

Four changes, all effectively output-identical. **Combined: −0.025 ms native
(4.352 → 4.327 ms), −0.030 ms QUALITY, −0.020 ms BALANCED.** Small, but positive
and consistent in every configuration and in every interleaved pair.

### Fog-band grass culling — correct, and worth ~nothing here

Distance fog reaches exactly 1.0 at its end, where the shell shader scales
`ALBEDO` to zero and emits flat fog radiance — the same colour as the fogged
terrain behind it. Grass entirely beyond that distance cannot change a pixel.

The numbers lined up for it: `fog_end` is `terrain_load_distance ×
fog_end_fraction` = 64 m, while `lod_far_to_hidden` is 86 m, so a 22 m band of
grass was being drawn purely to be fogged out. The LOD metric is already the
distance to the chunk's **AABB** (nearest point, via
`_distance_squared_to_chunk_aabb_local`), so capping the hide band at `fog_end`
removes only chunks whose entire footprint is past it.

Implemented as a cap rather than an overwrite: authored `lod_far_to_hidden` still
applies when it is tighter, and when fog is disabled it is the only rule. The
authored hysteresis gap is preserved on the re-show distance so a chunk on the
boundary cannot flicker. Chunks cache their thresholds squared, so
`TerrainChunk.refresh_lod_thresholds()` and `TerrainManager.refresh_lod_thresholds()`
were added to let a live fog change propagate to already-streamed chunks — fog is
resolved by the renderer well after terrain starts streaming.

**It culls 4 chunks and 16 shell instances (24 → 20 drawing, 288 → 272) and
changes frame time by nothing measurable.** The reason is the geometry of the
streaming radius: chunks load at 64 m, so only the outermost corners have their
*nearest* point past the fog end. Those four are drawn at the FAR variant (4
shells), sit at the horizon where they cover few pixels, and are largely occluded
by nearer terrain already. An earlier estimate that this band was ~45% of grass
ground area was wrong — it assumed grass filled the disc out to 86 m in every
direction, which streaming never populates.

Kept because it is free and correct, and because the gain scales with streaming
radius and fog reach, both of which are level configuration.

### Shell-constant colour hoisted to the vertex stage

`mix(u_base_color, u_tip_color, h)` and `mix(0.72, 1.0, pow(h, 0.72))` are pure
functions of the shell level, which is per instance — so both were constant
across an entire shell and were being recomputed for every surviving fragment,
including a `pow()`. Both now ride as `varying flat` terms.

They are two separate varyings rather than one product on purpose: the fragment
still applies them in the order it always did, because float multiplication is
not associative and folding them would move the result.

**`shell_level` itself is deliberately still interpolated**, and that is the
interesting part. Flattening it is the honest qualifier — the value is per
instance — and it measured slightly faster. But interpolating a constant is not
bit-exact, and `shell_level` feeds the blade height test: flattening it moved a
few dozen blade-edge fragments across their discard threshold, which showed up as
**56 extra differing pixels at up to 26/255**. Flat is safe for the two colour
terms because nothing branches on them and a last-bit difference cannot survive
8-bit output; it is not safe for geometry. The final build differs from the
reference by **11 pixels at 1/255**, against a launch-to-launch noise floor of
**235,963 pixels at 3/255** for the *same* build.

### Two reorderings and a dead guard

- The blade height test now runs as soon as its cell's random draw is resolved,
  before the stalk centre, the second offset clamp and the warped sample position
  — all of which were being computed for fragments about to be thrown away, and
  the upper shells discard here most often.
- The provisional stalk centre moved inside the interaction branch, which is its
  only consumer.
- Dropped `max(min(blade_width, blade_length), 0.001)`. Both axes are `mix()`
  results between positive endpoints scaled by positive variation, so the
  narrower bottoms out near 0.0158 and the guard could never fire.

### A dead end worth recording

`x^0.75 == sqrt(x) · sqrt(sqrt(x))` looks like a way to avoid a transcendental
for the length taper. It is not: the shared-logarithm form already in the shader
costs **3** SFU ops for *both* tapers (`log2` once, `exp2` twice), while routing
0.75 through square roots needs 2 for that taper plus `log2`+`exp2` for the 0.42
one — **4**. The pair is already near-optimal, and the only remaining way to
attack it is a lookup texture, with the precision risk that `pow(x, 0.42)` has
unbounded derivative as x approaches zero, exactly at the blade base where blades
are widest.

### Verification

- Pixel gate: 11 pixels at 1/255 against a 235,963-pixel / 3-per-255 same-build
  noise floor
- Presets engage at 2176×1224 and 1920×1080 and both improved
- `phase2_smoke` (covers the LOD hysteresis this touches), `terrain_player_smoke`,
  `receiver_registry_smoke`, `ground_layer_smoke`, `day_night_smoke`,
  `app_flow_smoke` — all pass

One process note: the first version of this shader used `flat varying float` and
**failed to compile** — Godot's qualifier order is `varying flat`. The material
silently fell back and the capture came back 76–99% different. The pixel gate
caught it immediately; a frame-time-only check would have reported a large,
meaningless "win".

### The three remaining candidates, each measured and each reverted

These were the only items left with a measured target after the output-identical
work. All three were implemented, measured against an interleaved baseline, and
backed out. Recording them so nobody spends the same day twice.

| Candidate | Predicted | Measured | Outcome |
|---|---:|---:|---|
| Non-trigonometric cell hash | −0.261 ms | **+0.080 ms** | Reverted, slower |
| Blade tapers via 2048×2 lookup texture | −0.500 ms | **+0.003 ms** | Reverted, no gain |
| Cheaper AA-band norm (`length` → `max`) | −0.347 ms | −0.035 ms | Rejected on quality |

**The predictions were all wrong in the same way**, and it is worth naming why.
Each came from a diagnostic that *stubbed out* a piece of the shader and measured
the difference. That measures the cost of the whole construct, not the cost of
the part a real optimization would remove. Stubbing `hash22` to
`fract(p * 0.0001)` removes two sines *and* two dot products *and* replaces them
with almost nothing; the honest replacement still has to produce a well
distributed pair of numbers, and every non-trig hash worth using costs about a
dozen ALU ops. Two `sin` calls are two special-function instructions the RTX 4060
issues cheaply. **A stub measures an upper bound that no real change can reach.**

The lookup texture fails for the neighbouring reason: it trades three
special-function ops for one texture fetch, and a texture unit has *lower*
throughput than the special-function unit — the fetch being otherwise free
(this shader samples nothing) only cancels that out rather than winning. It also
brought a 16 KB texture, a precision cliff where `pow(x, 0.42)` has unbounded
derivative as x approaches zero (exactly the blade base, where blades are
widest), and a float-filtering portability question on Compatibility and Web.
None of that is worth 0.003 ms.

The AA-band norm is the only one that *did* produce a gain, and it was declined
rather than failed: `length(fwidth(base_xz))` and `max(fwidth(base_xz))` differ
by up to 41% when the two derivatives are similar, so the band narrows and blade
silhouettes alias harder. That is the same failure mode as the cell lattice this
document already describes, on the same geometry, for 0.8%.

**What this closes.** Grass fragment cost is now dominated by work that is either
load-bearing (the AA band) or already near-optimal (the shared-logarithm tapers,
the sine hash). There is no further output-identical headroom in this shader that
measurement has been able to find. Anything beyond this point is a deliberate
quality decision — fewer shells, a coarser blade model, or a temporal technique —
not an optimization.
