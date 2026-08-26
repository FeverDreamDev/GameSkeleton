# Procedural Terrain Grass

Godot 4.7+ streamed procedural terrain with textureless shell grass. No textures,
no meshes, no external dependencies — the whole look comes from noise and two
shaders.

## Install

1. Copy the complete `addons/procedural_terrain_grass` folder into your project.
2. Enable **Procedural Terrain Grass** under Project Settings > Plugins.
3. Add a **TerrainGrass3D** node, set **Streaming Target** (or leave it empty to
   follow the active `Camera3D`), and run the scene.

The add-on registers no input actions, autoloads, physics-layer names or
renderer settings. It does use two physics layers for its queries — layer 8 for
grass blockers and layer 9 for dynamic interactors — both configurable on the
node under **Collision**.

## Nodes

| Node | Base | Purpose |
| --- | --- | --- |
| `TerrainGrass3D` | `Node3D` | The system itself: streaming, generation, masking, materials |
| `TerrainGrassBlocker3D` | `Area3D` | Carves grass out of the region its shape covers |
| `TerrainGrassInteractor3D` | `Node3D` | Bends grass around the parent it is attached to |

All three are global classes, so they appear in **Create Node** and can be typed
directly in code:

```gdscript
@onready var terrain: TerrainGrass3D = $TerrainGrass3D
```

## Blockers and interactors

- Give a `TerrainGrassBlocker3D` a **Blocker Shape** and place it. The shape
  draws a gizmo in the editor, so it can be lined up with a prop by eye.
  **Size it to match the prop, not larger** — every centimetre of padding
  becomes a visible ring of bare ground, and the shape only has to reach the
  height the grass grows to, not the top of the prop.
  Primitive, convex-polygon and concave-polygon shapes use their actual bounds.
  Transform changes and in-place shape-resource edits invalidate affected grass
  immediately; built-in blockers therefore do not need periodic bounds polling.
- Parent a `TerrainGrassInteractor3D` under a moving body. Its **Priority**
  decides who keeps a slot when more interactors are nearby than the shader's
  limit of eight, so give the player a high value.
- `CharacterBody3D`, `RigidBody3D` and `AnimatableBody3D` nodes on the
  **Interactor Query Mask** layer are picked up automatically and need no
  interactor child at all.
- With one terrain system in the scene, helpers bind to it automatically. With
  several, set each helper's **Terrain System Path**.
- Arbitrary nodes can be registered through the root API — useful for a
  `MeshInstance3D` with no collider, which is masked by its mesh AABB:

```gdscript
terrain.register_static_grass_blocker(mesh_instance)
terrain.register_grass_interactor(some_body)
```

Arbitrary nodes registered through this API have no change-notification
contract, so their bounds are polled at the interactor discovery interval until
they are unregistered. `TerrainGrassBlocker3D` nodes notify instead.

## How tightly grass hugs a blocker

Static masking works on a grid. Each terrain cell is
`chunk_size / chunk_resolution` across — 1 m at the defaults — and is subdivided
4× for the fine mask, so grass is cut in **25 cm steps** by default. A subcell is
cleared whenever the blocker touches it at all, which never lets grass grow
inside a prop but does round the cut outwards.

A blocker face that lands exactly on the subcell grid leaves no gap; one landing
just inside a subcell leaves up to a full subcell of bare ground. To tighten it:

- Size shapes to the prop and, where it is easy, place faces on multiples of the
  subcell size. In the demo the hut is 6 × 5 at x = 12, so its walls fall on the
  grid and the grass meets them flush.
- Raise **Chunk Resolution** for a finer grid — doubling it halves the step, at
  the cost of proportionally more terrain and grass vertices.

Flat-bottomed props on rolling terrain also need sinking a little, or they float
on the downhill side and show a gap underneath that no amount of masking fixes.

## Changing properties at run time

Appearance properties — colours, wind, density, grass height, interaction
response — apply the moment they change; they are shader uniforms.

Generation, collision, LOD geometry and performance properties are read once
when the runtime starts. Change them and call `rebuild()`:

```gdscript
terrain.terrain_seed = 42
terrain.rebuild()
```

`sample_height(world_xz)` works before the runtime exists, so it is safe to use
while placing props during scene setup.

## Custom lighting and streamed-scene integration

`TerrainGrass3D` remains standalone by default. Leave **Terrain Material
Override** empty to use its built-in terrain shader, or assign one shared
`ShaderMaterial` to publish every generated terrain chunk through a custom
lighting contract. The generated palette is stored in vertex colour, so a
replacement shader must consume `COLOR` if it should retain the height/slope
variation.

**Terrain Mesh Group** and **Terrain Receiver Only Group** optionally add each
generated ground mesh to integration groups before it enters the scene tree.
They are empty by default and do not couple this add-on to a renderer. The host
project uses them to opt terrain into Retro RT as primary receiver geometry
while leaving the deforming shell grass unmanaged.

For safe player placement, `is_position_ready(world_xz)` checks that the target
chunk and its height-map collision are live. Await
`wait_for_position_ready(world_xz, timeout_seconds)` before teleporting a body;
it also waits one final physics frame so the new shape has reached the physics
server.

## Useful API

| Member | Notes |
| --- | --- |
| `start_streaming()` / `stop_streaming()` | Manual control when `auto_start` is off |
| `rebuild()` | Recreate the runtime from current inspector values |
| `grass_quality` | `Off` / `Low` / `Medium` / `High`, safe to change live. See below |
| `sample_height(world_xz)` | Terrain height in world space, chunk or no chunk |
| `world_to_chunk(world_xz)` | Chunk coordinate containing a world position |
| `get_chunk(coord)` / `get_loaded_chunks()` | Live chunk access |
| `is_generation_idle()` | True once every queue has drained |
| `is_position_ready(world_xz)` / `wait_for_position_ready(world_xz, timeout)` | Collision-safe spawn/load handoff |
| `get_runtime_stats()` | Counters for an on-screen overlay |
| `invalidate_grass_region(aabb)` | Force static masking to re-run over a region |
| `set_distance_fog(enabled, begin, end, curve, color)` | Host-renderer hook: fades the unmanaged grass on the renderer's fog curve. `color` is scene-linear radiance |
| `chunk_loaded` / `chunk_unloaded` / `grass_rebuilt` | Streaming signals |

## How the canopy is built

A chunk publishes **one grass surface** — the terrain grid, with fully blocked
cells left out of the index buffer and partially blocked cells carrying four
corners of their own — and draws it once per shell through a `MultiMesh`. Each
chunk holds three of them, Near/Medium/Far, differing only in how many instances
they have; a `MultiMeshInstance3D` named `GrassMesh` points at whichever one the
distance band and the quality tier select.

```text
chunk grass base ArrayMesh          1,089 vertices, 6,144 indices at 32x32
    ├── Near   MultiMesh  16 instances
    ├── Medium MultiMesh  10 instances
    └── Far    MultiMesh   4 instances
            one MultiMeshInstance3D draws exactly one of them
```

Shell instance transforms are **identity**. A shell is lifted along each terrain
vertex's own normal inside the shader, which is what makes the canopy stand up
off a slope instead of shearing across it, and what keeps instancing from
rotating the normals the lighting reads. The shell level travels in
`INSTANCE_CUSTOM.x`.

Two details there are worth knowing before touching them:

- **The shell level is 8-bit on purpose.** It used to live in `ARRAY_COLOR.r`,
  and Godot stores a vertex colour as unorm8 by *truncating* — an authored 0.25
  becomes 63/255, not 64/255. `TerrainGenerator.shell_fraction_byte()` reproduces
  that truncation so the instanced canopy renders the same pixels the duplicated
  geometry did, rather than merely similar ones.
- **The two backends are handed different encodings.** Forward+ and Mobile store
  instance custom data as float32 and receive the finished fraction, scaled by
  `u_shell_decode_scale = 1.0`. Compatibility packs custom data into float16 —
  hand GLES3 17/255 and 0.06665 comes back — so it receives the 0-255 byte, which
  float16 holds exactly, and scales by 1/255 instead. See
  `TerrainGenerator.shell_data_is_byte_encoded()`.

`COLOR.gb` still carries the two exact fine-mask bytes per vertex and `UV` still
carries the per-cell corner, so masking precision is unchanged: only the shell
level moved from vertex data to instance data.

Nothing rebuilds during play. LOD and quality changes pick a different prebuilt
`MultiMesh`; a static-mask rebuild after a blocker moves replaces the base
`ArrayMesh` and re-points the same three shell sets at it, leaving their instance
buffers alone.

## Static masking runs a broad phase first

Carving grass out from under a blocker needs an exact physics query — an AABB is
not a shape, and rejecting cells on bounds alone would eat grass around anything
rotated or concave. What the masker avoids is issuing that query for cells no
blocker can possibly reach.

When a chunk's mask job starts it runs one shape query over an envelope that is
the exact union of the cell query volumes, padding included, and snapshots
conservative world bounds for every collider that came back. A cell overlapping
none of them provably cannot hit anything, so its query is skipped; a cell
overlapping any of them is tested exactly as before. Fine subcells go through the
same gate.

The candidates come from **what the query returned, not from what registered**,
so a plain `StaticBody3D` sitting on the blocker layer without ever calling
`register_static_grass_blocker()` keeps carving grass exactly as it did.

The job falls back to the pre-existing exhaustive scan whenever it cannot prove
it has seen everything: a shape whose bounds are not derivable (a heightmap, a
world boundary, an empty point set), a collider the query could not resolve to a
node (a GridMap tile, a CSG body), or more than 32 overlapping collider/shape
pairs. It also skips the comparison when a candidate spans the whole chunk, where
it could never reject anything. Both paths produce identical masks — verified
byte-for-byte across eleven blocker layouts — so this only ever chooses the
cheaper one.

One thing the mask has never handled, and still does not: a collider that *moves*
on the blocker layer without notifying the system. Registered blockers invalidate
their region on transform or shape change; an unregistered body that drifts
leaves a mask describing where it used to be.

## Grass quality at run time

Shell grass is stacked layers, so it costs its shell count in overdraw across
whatever share of the screen it covers — reliably the most expensive thing in a
scene that uses it, and the first thing worth handing a player.

`grass_quality` is built for an options menu: **High** is the authored bands,
**Medium** and **Low** shift every band one and two variants coarser, and **Off**
hides the canopy without unloading it. Nothing is rebuilt — each chunk already
holds all three shell sets, so a change is a resource swap that applies on the
same frame and reverses just as fast.

When the optional Retro RT reflection-ground integration is present, the same
authoritative active state is used there: **Off** republishes bare reflected
terrain with no blade detail, and returning to an enabled tier refreshes the
canopy even when the reflection window has not moved. Grass height and palette
changes likewise invalidate the baked canopy once rather than rebaking every
frame.

It works that way for a reason worth knowing before "just lower the shell count"
looks tempting: shell counts come from the settings snapshot the worker threads
read, which is deliberately read-only and shared. Changing them for real means
`rebuild()`, which tears down terrain collision — with the player standing on it.
Lowering a tier is free; lowering the count is not.

Measured on the host project at 2560x1440, one viewpoint in open field:

| Tier | Frame | FPS |
| --- | ---: | ---: |
| High | 5.32 ms | 188 |
| Medium | 4.54 ms | 220 |
| Low | 4.16 ms | 241 |
| Off | 4.16 ms | 240 |

Low and Off cost the same, so Low is the better floor — the four-shell variant is
already close to free. Off is worth keeping in the enum for a host that wants to
hide grass for its own reasons, but it is not a performance tier, and an options
menu is usually better off not offering it.

## Grass prefetch has to cover everything that can be drawn

**Keep `grass_prefetch_distance` at or above `lod_far_to_hidden`.** A chunk's
grass is queued at one moment — when its occupancy mask finishes — and only if
the chunk is inside the prefetch radius right then. Nothing reconsiders it later
on distance alone, so a chunk that was outside the radius at that instant keeps
its terrain and never grows grass, however close you walk to it afterwards. The
symptom is a chunk-shaped patch of bare ground that never fills in, with
`is_generation_idle()` reporting true the whole time.

Setting prefetch equal to `terrain_load_distance` is not enough, and is the easy
mistake: chunks stay loaded out to `terrain_unload_distance`, so one sitting on
the load boundary is microns outside the prefetch radius while remaining visible.
The host project hit exactly this — load 64, prefetch 64, hide 86 — and four
chunks on the +x/+z side of the player came out bald because their distance
rounded to 64.006 while their mirror images at 63.994 were fine.

`_configuration_errors()` now reports this, and the manager re-checks eligibility
on every streaming update so a chunk that misses its first chance is picked up
later rather than never.

## LOD bands and distance fog

The LOD distances default to `26 / 52 / 86`, which suit the default
`terrain_load_distance` of 96. **Retune them whenever you change the streaming
radius**, because a band that falls in clear air is a visible seam: a chunk
dropping to fewer shells reveals more dark ground between blades, and that reads
as a hard line of darker terrain across the field.

The rule is to put every transition where the fog has already taken over. In the
host project, streaming is 64 m and fog runs 32 → 64 m, so the default first band
at 26 m sat in front of the fog entirely; moving the bands to `52 / 62` puts the
first step at 68% fog and the second at 96%, and cost about 0.3 ms of a 5.4 ms
frame because distant chunks cover so little of the screen.

## Constraints

- The terrain root supports translation only. Rotation and non-unit scale are
  rejected with a configuration error.
- The grass shader supports at most 8 simultaneous interactors and only loops
  over the compact active upload, not unused slots.
- Threads are used when the export target has them; single-threaded targets fall
  back to an incremental main-thread builder bounded by
  **Incremental Generation Budget Usec**.
- The canopy is drawn through `MultiMesh`, so a target without instancing support
  cannot render it. Both Godot renderers have it; the headless dummy driver does
  not store instance data at all, which is only relevant to tests.

## Demo

`res://demo/demo.tscn` in this repository exercises every node:

- a hut and a boulder, each with a `TerrainGrassBlocker3D` child shaped to clear
  the grass around it
- five bare `TerrainGrassBlocker3D` nodes carving a dirt trail across the
  hillside, with no meshes of their own
- a colliderless `MeshInstance3D` registered from code and masked by its AABB
- a red sphere that bends grass purely because it is a physics body on the
  interactor query layer — it carries no interactor node
- a player with an explicit high-priority `TerrainGrassInteractor3D`

Props are dropped onto the generated surface at run time with `sample_height()`.
Press <kbd>F3</kbd> for the runtime stats readout.
