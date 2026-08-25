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

A host that pushes a cloud layer onto the grass material — `u_cloud_params`,
`u_cloud_motion`, `u_cloud_sun_direction` — gets its shadow resolved **per
vertex**, not per fragment. That function is four octaves of gradient noise, and
paid per fragment across up to sixteen shell layers it was the most expensive
thing in the shader by a wide margin. One tile of the layer covers hundreds of
metres while these vertices sit a metre apart, so a triangle spans a tiny
fraction of the smallest feature the field can produce and interpolating it is
not a difference you can see; it was measured at eight pixels out of 3.7 million,
one code apart. If you drive those uniforms with something genuinely
high-frequency, that assumption is yours to re-check.

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
| `sample_height(world_xz)` | Terrain height in world space, chunk or no chunk |
| `world_to_chunk(world_xz)` | Chunk coordinate containing a world position |
| `get_chunk(coord)` / `get_loaded_chunks()` | Live chunk access |
| `is_generation_idle()` | True once every queue has drained |
| `is_position_ready(world_xz)` / `wait_for_position_ready(world_xz, timeout)` | Collision-safe spawn/load handoff |
| `get_runtime_stats()` | Counters for an on-screen overlay |
| `invalidate_grass_region(aabb)` | Force static masking to re-run over a region |
| `set_distance_fog(enabled, begin, end, curve, color)` | Host-renderer hook: fades the unmanaged grass on the renderer's fog curve. `color` is scene-linear radiance |
| `chunk_loaded` / `chunk_unloaded` / `grass_rebuilt` | Streaming signals |

## Constraints

- The terrain root supports translation only. Rotation and non-unit scale are
  rejected with a configuration error.
- The grass shader supports at most 8 simultaneous interactors.
- Threads are used when the export target has them; single-threaded targets fall
  back to an incremental main-thread builder bounded by
  **Incremental Generation Budget Usec**.

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
