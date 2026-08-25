# game_flow

A global game-flow system for Godot 4.7: world objects report what happened, a concurrent visual
graph decides what happens next, and normal game systems perform levels, cutscenes, encounters,
transitions and saves. The original event/action lists remain supported as a compatibility lane.

It pairs with [`win98_ui`](../win98_ui/README.md) for its fades and dialogs, and with that addon's
`UISave` for storage. It never writes to disk itself.

## Install

Copy the folder, add a `FlowSystem` node to your persistent main scene, and point it at a
`FlowDatabase` and three containers. There is no runtime autoload. The optional `Game Flow`
editor plugin adds the visual main-screen workspace; exported and headless games never depend on
the plugin being enabled.

```
Main
├── UISystem            win98_ui
├── FlowSystem          database + the three NodePaths below
├── LevelRoot           world_container_path      -- levels are instanced here
├── PersistentActors    persistent_actors_path    -- the player lives here
├── CutsceneRoot        cutscene_container_path
└── PersistentAudio     music that outlives a level
```

There are **no autoloads**, deliberately. `--check-only --script` does not register autoload names,
so a script naming one fails to parse standalone. Everything here is either a `class_name` with
`static` members or a node that claims a `static var instance` in `_enter_tree()` — the same
convention `UISystem` uses, and the reason every file in this project parse-checks on its own.

`FlowSystem` is `PROCESS_MODE_ALWAYS`, and that is **inherited**. State the mode outright on your
containers or a frozen tree will not actually freeze the world:

```gdscript
level_root.process_mode = Node.PROCESS_MODE_PAUSABLE
persistent_actors.process_mode = Node.PROCESS_MODE_PAUSABLE
cutscene_root.process_mode = Node.PROCESS_MODE_PAUSABLE
```

## Use

A gameplay object reports what happened and decides nothing:

```gdscript
FlowEvents.emit(&"warehouse_boss_defeated", {"boss_id": persistent_id})
```

What that means lives in the database, as a `FlowEvent` with a list of `FlowAction`s:

```
FlowEvent  warehouse_boss_defeated
    one_shot = true
    SET_FLAG        warehouse_boss_dead
    REQUEST_SAVE    boss_defeated
    PLAY_CUTSCENE   warehouse_boss_outro
    LOAD_LEVEL      freeway_night -> warehouse_exit
    REQUEST_SAVE    level_entered
```

That is the whole contract. The boss stays reusable because it never mentions a level, a cutscene
or the save system, and the story is edited in one place instead of scattered through level scenes.

An event with no entry in the database is a normal, silent no-op — content can emit events before
the rules for them exist.

## Visual graphs

Set `FlowDatabase.master_graph_id` to opt into graph execution. Leaving it empty preserves the
legacy behavior exactly. A `FlowGraphEntry` maps that stable ID to an external or embedded
`FlowGraph` Resource; graph connections and save files refer only to graph, node, connection and
logical port IDs, never to editor controls or integer slot indexes.

The v1 palette includes Game Start and Event Entry roots; If/Else, Parallel, weighted Random, End
and structured subgraph calls; flags and values; timer/event waits and event emission; level
preload/load, cutscene, save and input actions; and Invoke Custom Action. Connections are execution
wires. More than one connection from an output creates independent execution tokens, so a story
wait, ambient timer, secret trigger and boss threshold can all remain active at once.

`FlowGraphRunner` drains immediate work in deterministic connection order. Timers use timeout
callbacks and event waits are indexed by event ID—there is no per-frame graph polling. Emitted
events enter a non-reentrant inbox; existing waiters resume before Event Entry nodes activate for
the same event. Loads and cutscenes pass through a global FIFO arbiter while unrelated tokens keep
running. A bounded immediate-step budget turns accidental zero-time loops into diagnostics.

Enable `res://addons/game_flow/plugin.cfg` to add **Game Flow** beside the standard editor workspaces.
The workspace provides a searchable palette, `GraphEdit` canvas, embedded node inspector,
undo/redo, structured validation, graph selection, breadcrumbs/history, subgraph navigation and
Resource persistence. `GraphNode` objects are disposable views; the `.tres` graph Resources are
the runtime truth.

Structured subgraphs contain one Subgraph Entry and named Subgraph Exits. Call Subgraph creates a
child instance and suspends only its caller. Reaching an exit cancels the child's remaining paths
and resumes the parent through the matching named port. Event Entry listeners exist only while
their graph instance exists. Recursion is rejected by validation in v1.

### Weighted random branches

Random owns an authored list of stable named output ports and positive relative weights. For a
one-percent rare path, use weights `99` and `1`; weights need not total 100. It chooses exactly one
port from the currently connected, valid outputs. The selected port then follows normal execution
semantics, including intentional fan-out when that one port has multiple wires. Empty branch lists,
duplicate or empty port IDs, non-finite/non-positive weights, and a node with no connected output
are validation errors.

The runner uses its own transient `RandomNumberGenerator`. Tests or game-owned deterministic
services may call `FlowSystem.instance.graph_runner.set_random_seed(seed)` or inject a callable
with `set_random_float_source(callable)`. Neither the generator nor an injected Callable is stored
in graph Resources or save snapshots; a Random node is an immediate step, so snapshots always
record its selected successor rather than re-rolling it after load.

### Custom game actions

Keep gameplay implementation outside the graph. Register a transient provider and author only its
stable ID and persistence-safe arguments:

```gdscript
FlowSystem.register_action(&"start_encounter", _start_encounter)

func _start_encounter(arguments: Dictionary, context: Dictionary) -> FlowActionHandle:
	encounter_controller.start_definition(arguments["encounter_id"])
	var handle := FlowActionHandle.new()
	encounter_controller.finished.connect(func(success: bool): handle.resolve(success), CONNECT_ONE_SHOT)
	return handle
```

Add a `FlowCustomActionEntry` to the optional database catalog so the editor validator can catch
misspelled action IDs. No provider Node or Callable is stored in a graph or save. Enemy AI,
formations, spawning, combat and boss health remain owned by encounter/boss systems; those systems
emit `FlowEvents` such as `wave_cleared` or `boss_defeated` for the graph to coordinate.

### The escape hatch

Not everything wants to be data. Subscribe directly for anything that is genuinely code:

```gdscript
FlowEvents.subscribe(&"door_opened", _on_door_opened)   # one event
FlowEvents.subscribe_any(_log_everything)               # all of them
```

Handlers take `(event_id: StringName, data: Dictionary)`. One fixed signature, so a handler that
wants neither drops them with `Callable.unbind()`, exactly as it would for a signal.

## What is in the box

**`core/`** — the framework.

| File | Class | What it does |
|---|---|---|
| `flow_events.gd` | `FlowEvents` | The bus. Keyed pub/sub, plus the `[FLOW]` log and a debug history ring. |
| `flow_state.gd` | `FlowState` | Story flags, values, current level and spawn, and the two methods that put them in somebody else's save payload. |
| `flow_system.gd` | `FlowSystem` | The node. Mode, containers, and the orchestration of a level swap and a cutscene. |
| `flow_director.gd` | `FlowDirector` | Event-facing compatibility facade: feeds graphs and runs legacy actions through a serialized lane. |
| `flow_graph_runner.gd` | `FlowGraphRunner` | Concurrent token scheduler, event/timer waits, subgraphs, snapshots and telemetry. |
| `flow_operation_arbiter.gd` | `FlowOperationArbiter` | Event-driven FIFO for globally exclusive loads, cutscenes and future exclusive verbs. |
| `flow_persistence.gd` | `FlowPersistence` | Rejects live Objects/Callables and safely clones persistent Variant data. |
| `flow_loader.gd` | `FlowLoader` | Threaded loading and preloading. |
| `flow_present.gd` | `FlowPresent` | Fades and error dialogs. **The only file that names `win98_ui`.** |

**`data/`** — what you author: the legacy resources plus `FlowGraph`, typed graph nodes,
`FlowGraphConnection`, `FlowCondition`, registries/descriptors and structured validation issues.

**`editor/`** — editor-only visual graph UI. Runtime files do not import it.

**`nodes/`** — what goes in scenes: `FlowLevel` (level root), `FlowSpawn` (arrival marker),
`FlowTrigger3D` (an area that reports an event), `FlowCutscene` (the cutscene contract).

**`debug/`** — `FlowDebugWindow`, a `UIWindow` showing mode, level, spawn, queue, pending save and
every story flag, live.

## Modes

`BOOT`, `MENU`, `GAMEPLAY`, `CUTSCENE`, `TRANSITION`, `PAUSED`. Only add one when it actually
changes high-level behaviour.

Two of them are load-bearing. `TRANSITION` refuses saves, because a world in pieces is not worth
recording. `PAUSED` allows them, because the world is whole — it is just frozen, and saving from
the pause menu is the most ordinary thing a player does.

## Levels and spawns

Levels are named, never pathed. Story rules, save files and triggers all say `&"warehouse"`, and
the registry row is the only place the `res://` path appears — so a level can be moved on disk
without touching anything else.

Put `FlowLevel` on the level root and scatter `FlowSpawn` markers through it. A spawn carries its
own facing, so arrival direction is authored in the level rather than hardcoded in a story script.
A missing spawn warns and falls back to `default` rather than refusing to load.

Entering a level announces `entered_<level_id>` on the bus. A one-shot `FlowEvent` with that id is
how a first-visit cutscene works, with no script in the level scene at all.

## Cutscenes

Extend `FlowCutscene` on the root of a cutscene scene, override `_begin`, and call
`report_finished()` when done. How it is built — `AnimationPlayer`, a camera rig, a dialogue runner
— is entirely its own business.

A cutscene may finish inside `begin()`. `FlowSystem` checks `is_finished()` before awaiting, so a
cutscene that resolves instantly does not hang the queue waiting for a signal already emitted.

Cutscenes and graph input nodes take control through owner-scoped input leases; the legacy/manual
`FlowSystem.set_gameplay_input()` override remains available. `gameplay_input_changed` reports the
aggregate result. That is **not** the same as disabling the player node: the body keeps simulating,
so a character coasts to a stop and stands there rather than freezing mid-stride and dropping its
shadow. Overlapping owners cannot accidentally re-enable one another's lock.

## Saving

This addon still does not write save files. `UISave` owns that, and knows nothing about any game.

`FlowSystem.request_save(reason)` raises `save_requested`; the game forwards it to whatever save
code it already has. A request that arrives mid-transition is **deferred**, not dropped, and
flushed when the flow settles. Only the most recent reason is kept — two autosaves queued behind
one transition are one autosave.

Put the story state in your payload with two lines:

```gdscript
state["flow"] = FlowState.to_dict()     # saving
FlowState.from_dict(payload["flow"])    # loading
```

The host game also stores `FlowSystem.graph_state_to_dict()` in a versioned `flow_graph` section
and restores it with `FlowSystem.restore_graph_state(snapshot, true)`. A graph snapshot contains
plain graph/instance/token IDs, continuations, locals, event/timer wait descriptors and input
leases. It never contains Nodes, Resources, Callables, signals, timers or coroutine state.

Action waits (loads, cutscenes and unresolved custom providers) are save-blocking. Timer and event
waits are resumable. A save request made inside the graph commits its successor first, then waits
for the current synchronous scheduler chain to quiesce before raising `save_requested`. On load,
restore the graph suspended before installing the level, then resume after the world is stable;
events emitted during installation are buffered in order. Saved timers resume from their remaining
duration and offline time does not advance them.

`FlowState` now enforces the same persistence boundary for its values. Objects, Resources,
Callables, Signals, RIDs, recursive containers and non-finite numbers are refused rather than
producing a corrupt save. Returned containers are detached copies.

Restore it **before** the level is instanced, or a door that reads a flag in its own `_ready()`
reads the value from the run that was just abandoned.

One-shot events are guarded by a story flag (`flow_ran_<event_id>`), so "seen it once" survives
quitting and reloading rather than replaying every time the game comes back.

## Why it stays fast as the story grows

- **Keyed dispatch.** Listeners are stored per event id, so an emit wakes only the handlers that
  asked for that event. `subscribe_any` exists for the two things that legitimately want
  everything — the director and the log.
- **Hash lookup, not a `match` chain.** The director indexes the database once at startup, so three
  hundred events cost the same per event as three.
- **No allocation on a bare emit.** `FlowEvents.NO_DATA` is shared, and safe to share because a
  `const` Dictionary is read-only.
- **Spent triggers stop costing.** A one-shot `FlowTrigger3D` sets `monitoring = false`, so the
  physics server stops testing overlaps against it.
- **Preloading during dead time.** `preload_next` warms the likely next level while a cutscene
  plays. Preloads leave the threaded request in flight rather than being pumped to completion, so
  nothing has to tick this addon.
- **Dead listeners are pruned on dispatch**, so a freed level cannot leave handlers behind for the
  next one.
- **The log compiles out.** Everything `[FLOW]` is behind `OS.is_debug_build()`.

## Gotchas worth knowing

- **`queue_free()` defers.** A level released with `queue_free()` alone is still in the container
  until the end of the frame, long enough to be mistaken for the level that just arrived. Detach
  it first. `FlowSystem.current_level()` skips nodes queued for deletion for the same reason.
- **An unconsumed preload holds its scene.** `FlowSystem` discards outstanding requests in
  `_exit_tree`; call `FlowLoader.reset()` yourself if you preload outside it. Skipping this shows
  up as a leaked instance at exit.
- **Static state outlives the scene tree.** `FlowSystem.reset_run()` wipes flags, subscriptions and
  preloads when a run ends. Without it a second New Game inherits the first one's story.
  `FlowEvents.reset()` also drops the director's own subscription, so anything that resets the bus
  must reconnect it.
- **An emitted event joins the queue *behind* the rest of the current event's actions.**
  In graphs it enters the non-reentrant inbox; in the compatibility lane it joins the legacy FIFO.
- **A `StringName` compares by pointer, not alphabetically.** Sorting an `Array[StringName]`
  directly gives an order that is stable within a run but otherwise arbitrary. `FlowState.flags()`
  sorts as strings and converts back.
- **GDScript lambdas capture by value.** A lambda that refers to the variable holding itself
  captures an empty `Callable`, so it cannot unsubscribe itself. Use a method.

## Placeholders left on purpose

`scenes/cutscenes/demo_cutscene.tscn` in the host project is a 1.2-second beat and nothing else —
it exists to prove the handover works end to end, not to look like anything. `FlowDebugWindow` uses
a plain `Label`; no effort has gone into making it pretty.
