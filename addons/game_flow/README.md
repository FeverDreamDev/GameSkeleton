# game_flow

A global game-flow system for Godot 4.7: world objects report what happened, a director decides
what it means, and levels, cutscenes, transitions and autosaves follow from that.

It pairs with [`win98_ui`](../win98_ui/README.md) for its fades and dialogs, and with that addon's
`UISave` for storage. It never writes to disk itself.

## Install

Copy the folder, add a `FlowSystem` node to your persistent main scene, and point it at a
`FlowDatabase` and three containers. No autoload, no plugin to enable.

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
| `flow_director.gd` | `FlowDirector` | Routes events to database entries and runs their actions through a queue. |
| `flow_loader.gd` | `FlowLoader` | Threaded loading and preloading. |
| `flow_present.gd` | `FlowPresent` | Fades and error dialogs. **The only file that names `win98_ui`.** |

**`data/`** — what you author: `FlowDatabase`, `FlowEvent`, `FlowAction`, `FlowLevelEntry`,
`FlowCutsceneEntry`.

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

Control is taken with `FlowSystem.set_gameplay_input(false)`, which raises
`gameplay_input_changed`. That is **not** the same as disabling the player node: the body keeps
simulating, so a character coasts to a stop and stands there rather than freezing mid-stride and
dropping its shadow.

## Saving

This addon has no serialisation. `UISave` owns that, and knows nothing about any game.

`FlowSystem.request_save(reason)` raises `save_requested`; the game forwards it to whatever save
code it already has. A request that arrives mid-transition is **deferred**, not dropped, and
flushed when the flow settles. Only the most recent reason is kept — two autosaves queued behind
one transition are one autosave.

Put the story state in your payload with two lines:

```gdscript
state["flow"] = FlowState.to_dict()     # saving
FlowState.from_dict(payload["flow"])    # loading
```

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
  `EMIT_EVENT` is for fire-and-forget composition. When order matters, list the actions inline.
- **A `StringName` compares by pointer, not alphabetically.** Sorting an `Array[StringName]`
  directly gives an order that is stable within a run but otherwise arbitrary. `FlowState.flags()`
  sorts as strings and converts back.
- **GDScript lambdas capture by value.** A lambda that refers to the variable holding itself
  captures an empty `Callable`, so it cannot unsubscribe itself. Use a method.

## Placeholders left on purpose

`scenes/cutscenes/demo_cutscene.tscn` in the host project is a 1.2-second beat and nothing else —
it exists to prove the handover works end to end, not to look like anything. `FlowDebugWindow` uses
a plain `Label`; no effort has gone into making it pretty.
