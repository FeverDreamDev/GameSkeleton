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
