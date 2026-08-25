# GameFlow Designer Guide

GameFlow is the visual map of **what happens in the game and when**. It is the single source of
truth for story progression, level order, cutscenes, checkpoints, timed sequences, and reactions to
gameplay events.

You do not use GameFlow to build enemy movement, combat, dialogue rendering, physics, or menus.
Those systems still do the detailed work. The graph gives them high-level directions.

```text
GameFlow decides:                    The game systems perform:

Start the warehouse encounter   ->  Spawn and control the enemies
Play the introduction           ->  Animate cameras, actors, and dialogue
Go to the hospital              ->  Build and install the level scene
Save a checkpoint               ->  Write through the game's save system
```

The main menu, pause menu, save-slot screens, and the buttons that start or load a game remain
normal application UI. Choosing **New Game** starts the master graph. Choosing a save slot restores
the graph at exactly the saved place. From that point onward, the master graph is the authority for
the game's high-level flow.

This guide assumes the GameFlow editor plugin is enabled and the project already has its levels,
cutscenes, subgraphs, and game actions registered in the Flow Database.

## 1. The basic idea

A GameFlow graph is read from left to right. Each box is a **node**. A wire means, “after this,
continue here.”

```text
[When Game Starts] -> [Play Cutscene: Introduction] -> [Go To Level: House]
```

An execution path is like a moving marker following the wires. Most nodes finish immediately.
Nodes such as a timer, an event wait, a cutscene, or a level change pause only the path that reached
them. Other paths keep working.

```text
                          -> [Wait 60 Seconds] -> [Send Event: Thunder]
[Start Multiple Paths] --|
                          -> [Wait Until Event: Player Reached Tunnel] -> [Run Game Action: Start Ambush]
```

This is how story logic, ambient effects, secrets, and boss logic can all be active at once.

## 2. Open the master graph

1. Open the project in Godot.
2. Select **Game Flow** beside the usual **2D**, **3D**, **Script**, and **Game** workspaces.
3. Choose **Main Game** from the graph selector at the top.
4. Use **Frame All** if the nodes are off-screen.

The workspace has four main areas:

- **Node Palette** on the left: search for and add nodes.
- **Graph Canvas** in the center: arrange nodes and draw wires.
- **Node Inspector** on the right: edit the selected node.
- **Validation** at the bottom: shows mistakes and warnings.

For ordinary work, select a palette item and press **Add Node**, or double-click the palette item.
Select a node to edit it in the inspector. Drag from an output on the right side of one node to the
input on the left side of another node to connect them.

You can move, delete, copy, paste, connect, and disconnect nodes with normal editor undo and redo.
Pasted nodes receive new internal identities automatically. Use **Save** when finished.

Do not edit internal IDs by hand. Choose levels, cutscenes, game actions, and subgraphs through the
plain-language **Choose...** picker in the inspector.

## 3. The master graph and subgraphs

Every game has one **master graph**. It contains **When Game Starts** and remains active for the
whole run. This project's master graph is `game/flow/master_game_flow.tres`; game-specific graphs
belong under `game/flow`, never inside `addons/game_flow`.

The master graph should show the game's large structure:

```text
Main Game
|- Introduction
|- House
|- Freeway
|- Hospital
|- Final Area
`- Ending
```

Use smaller subgraphs for a level, encounter, boss, or self-contained sequence. The master graph
then stays readable instead of becoming one enormous canvas.

To create a graph:

1. Press **New** in the Game Flow toolbar.
2. Give it a clear display name.
3. Choose **Master** or **Subgraph**.
4. Save it under the game's `game/flow` folder.
5. Press **Register** and give it a stable graph name.
6. For the one root graph only, press **Set Master**.

There must be exactly one master graph. Do not use **Set Master** on an ordinary level or sequence
subgraph.

## 4. Starting and ending paths

### When Game Starts

This is the beginning of a new run. A master graph must contain exactly one. It has no input wire
because nothing comes before it.

### When Event Happens

This starts a new path whenever the chosen event is announced. Use it for reactions that should be
available while this graph is active.

```text
[When Event Happens: Boss Defeated] -> [Set Story Flag: Boss Is Dead] -> [Save Checkpoint]
```

Turn on **Trigger Only Once** when the reaction should happen once during the current playthrough.
GameFlow remembers that it already ran when the player saves and loads.

### Stop This Path

This ends only the path that reaches it. Other paths continue. Use it to make finished branches
visually clear.

An unconnected output also stops, but an explicit **Stop This Path** is easier for another designer
to understand and avoids an “unconnected output” warning.

## 5. Events: announcements between the game and the graph

An event is a named announcement such as:

- `player_reached_tunnel`
- `item_collected`
- `wave_cleared`
- `boss_health_low`
- `player_died`

Use readable names that describe something that **already happened**. Events do not contain story
rules. For example, the tunnel trigger only announces `player_reached_tunnel`; the graph decides
whether that starts an ambush, a cutscene, or nothing at all.

There are three event nodes:

- **When Event Happens** starts a fresh path every time the event occurs.
- **Wait Until Event** pauses the current path until the next occurrence.
- **Send Event** announces an event to GameFlow and any listening game systems.

The difference between the first two is important:

```text
Always listening:  [When Event Happens: Item Collected] -> start a new reaction

Story sequence:    [Show Objective] -> [Wait Until Event: Item Collected] -> continue this sequence
```

Events are announcements, not stored memories. If an event happens before a **Wait Until Event**
path begins waiting, that path does not receive the old event. Use a story flag when the graph must
remember that something happened.

Events can carry small details, such as which item was collected. A **Check Condition** can inspect
those details immediately. Treat event details as temporary: they are cleared when the path first
waits for a timer, event, cutscene, level change, or game action. Important long-term information
belongs in story state.

## 6. Story state: what the game remembers

Story state survives checkpoints and save/load. Use it for decisions the game must remember.

### Story flags

A flag is a yes/no fact:

- `intro_seen`
- `generator_started`
- `warehouse_boss_dead`
- `secret_door_open`

Use **Set Story Flag** with **Turn Flag On** enabled to remember “yes.” Use **Clear Story Flag** to
forget it or return it to “no.”

### Story values

A value stores a small piece of information, such as:

- `chapter = 3`
- `boss_health = 0.30`
- `rescued_survivors = 4`
- `ending_choice = "leave"`

Use **Set Story Value** to store it.

Keep story state small and simple. Numbers, text, true/false values, lists, and dictionaries made
from those values are safe. Never try to store a scene object, character, timer, signal, Resource,
or other live Godot object. Store a stable name such as `warehouse_guard_02` instead.

Changing story state updates the running game immediately. It reaches disk when the player saves
through the UI or when the graph reaches **Save Checkpoint**.

## 7. Choices with Check Condition

**Check Condition** sends the path through **Yes** or **No**.

```text
                              Yes -> [Run Game Action: Open Secret Door]
[Check: Has Secret Key?] -----|
                              No  -> [Send Event: Door Locked]
```

Open **Condition**, then use **Where to Look**, **Name to Check**, **Comparison**, and (when needed)
**Compare With**. Choose what to inspect:

- **Story Flag** for a remembered yes/no fact.
- **Story Value** for a remembered number or piece of text.
- **Event Detail** for information attached to the event that started or resumed this path.
- **Path Value** only when a programmer-provided game action or extension supplies temporary path
  information.

Useful comparisons include:

- **Is On** / **Is Off** for flags.
- **Equals** / **Is Not** for text, choices, or exact values.
- **Less Than**, **At Most**, **Greater Than**, and **At Least** for numbers.
- **Is Set** / **Is Not Set** when the presence of a value matters.

Use a custom node title that reads like a question, such as **Has The Fuse?** or **Boss Below 30%?**.
That makes the Yes and No wires understandable without opening the inspector.

## 8. Time, parallel paths, and random choices

### Wait

**Wait _n_ Seconds** pauses only its current path. It does not freeze the game or any other graph
path. Saved timers resume with the time they had left; time spent with the game closed does not
count down the timer.

### Start Multiple Paths

Connect several wires to **Next**. Each wire becomes an independent path.

```text
                             -> Main objective path
[Start Multiple Paths] -----|-> Ambient weather path
                             -> Secret-room path
```

GameFlow also permits several wires from any one output. **Start Multiple Paths** is recommended
because it tells readers that the split is intentional.

Starting paths together does not join them again automatically. Each path should finish on its
own, wait for an event, or coordinate through a story flag and event.

### Choose Random Path

This selects exactly one connected outcome. Add outcomes in the node's **Outcomes** panel. Give
each one an **Outcome Name** and a **Chance Weight**. The canvas shows the authored chance weight,
not a percentage, because only outcomes with attached wires participate at runtime.

Weights are relative and do not need to total 100:

```text
Normal loading screen:  Chance Weight 99
Rare loading screen:    Chance Weight 1
```

When both outcomes are connected, this gives a 99% / 1% choice. A connected `3` and `1` pair gives
75% / 25%.

Only connected outcomes take part in the choice. If you add an outcome but do not wire it, the
remaining connected weights form a different ratio. Always validate and confirm that every intended
outcome is connected after changing a random choice. Each outcome also has a unique **Connection
Name** used to keep its wire stable; the editor creates one automatically, so only rename it when a
clearer connection name is useful.

The choice is made before the graph can be saved at a later node, so loading a save continues down
the already chosen path instead of rolling again.

## 9. Cutscenes, levels, checkpoints, and player control

### Play Cutscene

Choose a registered cutscene. The node waits until that cutscene reports that it finished, while
unrelated graph paths keep running.

Wire both results:

```text
                             Finished -> continue the story
[Play Cutscene: Intro] -----|
                             Failed   -> show or report a recovery path
```

Cutscenes control their own cameras, animation, dialogue, and timing. The graph only decides when
to play them and what follows.

### Prepare Level

This begins loading a registered level in the background and immediately continues. Use it before
a cutscene or other delay when the next destination is already known.

```text
[Prepare Level: Hospital] -> [Play Cutscene: Drive To Hospital] -> [Go To Level: Hospital]
```

Preparing is optional. **Go To Level** still works without it.

### Go To Level

Choose the registered level and its named arrival point. The node waits for the level transition,
then uses **Finished** or **Failed**. Level scenes own their terrain, objects, spawn markers, and
gameplay scripts; the graph owns when the move happens.

### Save Checkpoint

This requests an automatic save through the game's existing save system. Give the checkpoint a
short reason such as `intro_complete` or `boss_defeated` so logs and save metadata remain useful.

GameFlow moves the path to the next node before capturing the save. Loading that checkpoint
therefore continues after **Save Checkpoint** and does not create a save loop.

The application still owns save files, save slots, manual Save, Continue, and Save & Quit. Those UI
actions include both story state and all active graph paths. Use **Save Checkpoint** only to choose
automatic story save moments.

### Lock Player Controls and Unlock Player Controls

Use these around moments when gameplay input must be unavailable. Give both nodes the same named
control lock, for example `intro` or `boss_transition`.

```text
[Lock Player Controls: intro]
-> [Play Cutscene: Introduction]
-> [Unlock Player Controls: intro]
```

Keep the matching lock and unlock on the same continuous path. Do not lock on one parallel path
and try to unlock from another. Different systems can safely hold different locks at the same time;
controls return only after every owner has released its own lock. A cutscene also takes care of its
own internal control lock.

## 10. Run Game Action: the bridge to gameplay systems

Use **Run Game Action** when the graph needs a game-specific verb that is not one of the built-in
nodes. Examples include:

- Start Encounter
- Open Door
- Change Weather
- Advance Boss Phase
- Give Objective
- Play Music Cue

Choose a registered game action and fill in its designer-facing options. Wire both **Finished** and
**Failed**.

```text
[Run Game Action: Start Encounter]
-> [Wait Until Event: Wave Cleared]
-> [Run Game Action: Start Reinforcements]
```

The graph coordinates the encounter. The encounter system still owns enemy scenes, formations,
spawn timing, AI, health, and combat. If the action you need is not in the picker, ask a programmer
to register it once; do not add gameplay implementation to the graph itself.

## 11. Building and calling subgraphs

A subgraph is a reusable or self-contained flow section.

Inside the subgraph:

1. Add exactly one **Subgraph Starts Here**.
2. Build the sequence from that node.
3. End successful and alternate routes with **Finish Subgraph** nodes.
4. Give each result a clear name, such as `finished`, `escaped`, or `player_died`.

```text
[Subgraph Starts Here]
-> [Run Game Action: Start Boss]
-> [Wait Until Event: Boss Defeated]
-> [Finish Subgraph: Victory]
```

In the parent graph, add **Run Subgraph**, choose the registered subgraph, and list the same result
names as outputs. Connect every expected result, plus **Failed**.

```text
                           Victory -> [Save Checkpoint]
[Run Subgraph: Boss] -----| Player Died -> [Run Subgraph: Death Sequence]
                           Failed -> [Send Event: Flow Error]
```

Double-click **Run Subgraph** to open the referenced graph. Use the breadcrumbs and back/forward
buttons to navigate between parent and child graphs.

Important subgraph rules:

- Subgraphs cannot call themselves, even indirectly.
- Reaching any **Finish Subgraph** ends the entire called subgraph, including its other waiting
  paths, and returns to the parent through that named result.
- Put ambient or world-long listeners in the master graph when they must survive the end of a
  called subgraph.
- A subgraph is active only while its **Run Subgraph** call is active. Its **When Event Happens**
  nodes listen only during that time.

## 12. Save and load behavior designers should know

The existing game UI saves and restores all relevant GameFlow progress:

- remembered story flags and values;
- every active path and subgraph call;
- waits for events;
- remaining timer duration;
- player-control locks.

The save never contains live scene objects. This is why graph properties and story values must use
stable names and simple data.

Timers, event waits, and subgraph calls can be saved directly. A level change, cutscene, or
unfinished game action is a live operation and temporarily delays saving until it reaches a safe
point. A Save & Quit request does not quit if the save cannot be written safely.

Loading restores the graph before the world becomes active, rebuilds the level and player through
the normal application loading path, and then resumes each graph path once. Designers should not
add “load recovery” duplicates around every node; the runtime already preserves continuations.

## 13. Validate before testing

Press **Validate** after meaningful edits. Validation also runs when graphs are opened and before
the project starts. Errors block Play; warnings point out suspicious but sometimes intentional
layouts.

Double-click a validation message to navigate to the relevant graph and node.

Validation catches problems such as:

- missing or duplicate nodes and wires;
- missing levels, cutscenes, actions, or subgraphs;
- output names that no longer match;
- nodes that cannot be reached from a starting point;
- random choices with no connected outcome;
- subgraphs with the wrong start or result layout;
- recursive subgraph calls;
- an instant loop with no timer, event wait, cutscene, level change, action, or subgraph wait;
- values that cannot safely be saved.

Treat red errors as broken flow. Review yellow warnings rather than automatically ignoring them.
For example, an intentionally unfinished branch may be harmless during early work, but production
paths should normally end with **Stop This Path** or **Finish Subgraph**.

## 14. Worked examples

### Intro and first level

```text
[When Game Starts]
-> [Save Checkpoint: New Game]
-> [Play Cutscene: Introduction]
   Finished -> [Save Checkpoint: Intro Complete]
            -> [Go To Level: House]
            -> [Set Story Flag: Introduction Complete]
            -> [Save Checkpoint: Entered House]
            -> [Stop This Path]
   Failed   -> [Send Event: Main Flow Failed]
            -> [Stop This Path]
```

### Four independent activities

```text
[Start Multiple Paths]
|- [Wait Until Event: Player Reached Tunnel] -> [Run Game Action: Start Ambush]
|- [Wait 60 Seconds] -> [Send Event: Thunder]
|- [Wait Until Event: Secret Item Collected] -> [Run Game Action: Open Secret Door]
`- [Wait Until Event: Boss Health Low] -> [Run Game Action: Start Boss Phase Two]
```

The sixty-second wait does not delay the tunnel, secret, or boss paths.

### A rare variation

```text
[Choose Random Path]
|- Normal, Chance Weight 99 -> [Run Game Action: Use Normal Loading Art]
`- Rare,   Chance Weight  1 -> [Run Game Action: Use Rare Loading Art]
```

### First visit only

```text
[When Event Happens: Entered Hospital]  (Trigger Only Once enabled)
-> [Play Cutscene: Hospital Arrival]
-> [Set Story Flag: Hospital Introduced]
-> [Save Checkpoint]
-> [Stop This Path]
```

## 15. Common mistakes

**Using an event as memory.** Events are momentary. Store lasting facts with **Set Story Flag** or
**Set Story Value**.

**Putting gameplay implementation in the graph.** Use **Run Game Action** to request an encounter,
door, boss, weather, or objective operation. Keep its detailed behavior in its normal system.

**Leaving failure outputs unwired.** Cutscenes, level changes, subgraphs, and game actions can fail.
Give their **Failed** output a clear recovery or reporting path.

**Creating an instant loop.** A wire that loops through only immediate nodes would run forever.
Every intentional loop needs a real wait, such as **Wait Until Event** or **Wait _n_ Seconds**.

**Assuming parallel paths rejoin.** They do not. Coordinate them explicitly with events/state, or
let them end independently.

**Ending a subgraph too early.** The first path to reach **Finish Subgraph** cancels the child's
other paths. Keep work that must outlive the result in the master graph.

**Using mismatched control-lock names.** A lock and unlock are a pair. Keep them on the same path
and use exactly the same name.

**Saving live objects in state or node options.** Store stable names and plain data only.

**Editing graph files inside the addon.** The addon is the reusable tool. This game's authored flow
belongs in `game/flow`.

## 16. Compact node reference

| Palette group | Node | Designer meaning |
|---|---|---|
| Start & Finish | **When Game Starts** | Starts the master graph once for a new run. |
| Start & Finish | **When Event Happens** | Starts a new path when an event is announced. |
| Start & Finish | **Stop This Path** | Ends only the path that reaches it. |
| Choices & Paths | **Check Condition** | Chooses the Yes or No output from state or current path details. |
| Choices & Paths | **Start Multiple Paths** | Starts every wire from Next as an independent path. |
| Choices & Paths | **Choose Random Path** | Chooses one connected outcome by relative chance weight. |
| Subgraphs | **Subgraph Starts Here** | Required starting point inside a subgraph. |
| Subgraphs | **Finish Subgraph** | Ends the called subgraph and returns a named result. |
| Subgraphs | **Run Subgraph** | Runs a registered subgraph and waits for its result. |
| Story State | **Set Story Flag** | Remembers a yes/no story fact as yes. |
| Story State | **Clear Story Flag** | Removes a remembered story fact. |
| Story State | **Set Story Value** | Remembers a number, text value, or other small safe value. |
| Events & Timing | **Wait _n_ Seconds** | Pauses this path for a duration. |
| Events & Timing | **Wait Until Event** | Pauses this path until the next chosen event. |
| Events & Timing | **Send Event** | Announces an event to graphs and game systems. |
| Levels & Cutscenes | **Play Cutscene** | Plays a registered cutscene and waits for Finished or Failed. |
| Levels & Cutscenes | **Prepare Level** | Starts background loading and immediately continues. |
| Levels & Cutscenes | **Go To Level** | Changes to a registered level and named arrival point. |
| Saving | **Save Checkpoint** | Requests an automatic save at a safe continuation. |
| Player | **Lock Player Controls** | Takes a named control lock for this path. |
| Player | **Unlock Player Controls** | Releases this path's matching control lock. |
| Game Actions | **Run Game Action** | Requests a registered game-specific operation. |

## 17. A final design checklist

Before calling a flow section complete, check that:

- the master graph shows the game's major structure at a glance;
- detailed sequences live in clearly named subgraphs;
- node titles read like game-design instructions or questions;
- every important branch has an explicit ending;
- every operation that can fail has a sensible failure path;
- events describe what happened and state stores what must be remembered;
- parallel paths are intentionally independent;
- checkpoints sit after meaningful progress boundaries;
- all control locks have a matching unlock on the same path;
- validation has no errors and every warning has been reviewed;
- New Game, manual Save, Continue, and Save & Quit have been tested through the actual UI.
