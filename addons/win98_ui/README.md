# win98_ui

A self-contained Windows 98 style UI layer for Godot 4. Draggable windows, modal dialogs,
screens, transitions and a sound bank — with **no imported assets at all**. Every bevel,
gradient and glyph is generated at runtime, and the font comes from the operating system.

## Install

1. Copy the `addons/win98_ui/` folder into your project.
2. Add a **UISystem** node to your main scene (Add Node → search `UISystem`).

That is the whole setup. No autoload, no plugin to enable, no scene to instance. Registering
`core/ui_system.gd` as an autoload instead also works if you prefer that; nothing changes.

## Use

Every entry point is a static call that routes to whichever `UISystem` is in the tree:

```gdscript
# Full-screen pages
UISystem.show_screen(MainMenu.new())
await UISystem.close_screen()

# Modal popups
UISystem.show_modal(UIDialog.message("About", "[b]My Game[/b]\nv0.1", "OK", true))

if await UISystem.show_modal(UIDialog.confirm("Exit", "Quit the game?")).finished:
    get_tree().quit()

# Transitions
await UISystem.fade_to_black(0.4)
await UISystem.fade_from_black(0.5)
```

With no `UISystem` in the tree these no-op instead of crashing, so the widgets stay usable on
their own.

### A window of your own

```gdscript
var window := UIWindow.new()
window.window_title = "Inventory"
window.show_help_button = true
window.add_content(my_control)
window.close_pressed.connect(window.queue_free)
UISystem.add_window(window)
```

### A popup with more than two answers

```gdscript
var dialog := UIDialog.choice("Paused", "The game is paused.", [
    {"text": "Settings", "id": &"settings", "closes": false},  # reports, stays open
    {"text": "Quit", "id": &"quit"},                           # reports, closes
])
dialog.selected.connect(func(id): print(id))
UISystem.show_modal(dialog)
```

Set `dialog.buttons_vertical = true` to stack the buttons instead of laying them in a row —
worth it once there are more than two, where a row stops reading as a set of answers and starts
reading as a list of separate actions. `PauseMenu` does exactly this.

## What is in the box

| File | Class | What it does |
| --- | --- | --- |
| `core/ui_system.gd` | `UISystem` | The node you drop in. Owns the canvas layers, theme, fades, cursor and sound. |
| `core/ui_theme.gd` | `UITheme` | Generates the whole look. Palette constants and stylebox factories live here. |
| `core/ui_audio.gd` | `UIAudio` | The sound bank and its player pool. Created by `UISystem`. |
| `core/ui_save.gd` | `UISave` | Slot based save files. All static, needs nothing in the tree. |
| `widgets/ui_window.gd` | `UIWindow` | Draggable window frame with title bar and `? _ □ ×` buttons. |
| `widgets/ui_dialog.gd` | `UIDialog` | Modal popup built on `UIWindow`. `message` / `confirm` / `choice`. |
| `widgets/ui_screen.gd` | `UIScreen` | Base for a full-screen page. Override `_build()`, not `_ready()`. |
| `widgets/ui_title_button.gd` | `UITitleButton` | The small title bar buttons. Glyphs are drawn, not imported. |
| `widgets/ui_progress_bar.gd` | `UIProgressBar` | The chunky segmented progress bar. |
| `screens/boot_screen.gd` | `BootScreen` | Loading screen: a progress readout over whatever is behind it. |
| `screens/main_menu.gd` | `MainMenu` | Main menu window. Emits intent; decides nothing. |
| `screens/pause_menu.gd` | `PauseMenu` | Error-box shaped pause popup that freezes the tree. |
| `screens/save_browser.gd` | `SaveBrowser` | The slot list, in Save or Load flavour. Reports the choice; saves nothing itself. |

The four files in `screens/` are working templates meant to be edited or replaced. Everything
in `core/` and `widgets/` is the framework and needs no changes to be useful.

## Saving

`UISave` writes one JSON file per slot under `user://saves/`. Every call is static and none of
them needs a `UISystem` in the tree, so saving works in a headless test too.

```gdscript
UISave.save_slot(&"slot_1", {"position": player.global_position}, {"label": "Cavern"})

var data := UISave.load_slot(&"slot_1")
if data.is_empty():
    push_error(UISave.last_error())
```

It knows nothing about your game — the payload is a plain `Dictionary` you build and read back.
Built-in math types survive the trip (`Vector3`, `Transform3D` and friends are encoded by
`JSON.from_native`), so nothing has to be flattened into float arrays by hand. Objects are refused
in both directions, which means a hand-edited save file can never instantiate anything.

| Call | For |
| --- | --- |
| `save_slot(slot, data, header)` | Write. `header` takes `label` and `detail` for the slot row; the timestamp is added for you. |
| `load_slot(slot)` | Read. Empty dictionary on any failure, reason in `last_error()`. |
| `list_slots()` | One row per slot including the empty ones — what the browser draws. |
| `newest_slot()` / `has_any()` | For a Continue button. Empty name when there is nothing to continue. |
| `slot_ids()` | The slot names the list reports: `autosave`, then `slot_1`…`slot_N`. |
| `delete_slot(slot)` / `has_slot(slot)` | Housekeeping. Deleting nothing is not an error. |
| `is_persistent()` | **Web:** false when the browser refuses to keep site data. See below. |

Configure it by assigning to the static vars — `UISave.directory`, `extension`, `slot_count`,
`autosave_id`. Writes go through a temporary file and swap into place with the previous one kept
aside until the swap lands, so a save interrupted halfway costs the new state rather than the old.

`save_slot` and `load_slot` take **any** name, but `list_slots()` and `newest_slot()` only report
the ones `slot_ids()` names. Save to `&"quicksave"` without adding it there and it works fine —
it just never shows up in the browser, and Continue will not find it.

### The browser

`SaveBrowser` is a `UIDialog`, so it stacks over a `PauseMenu` without unfreezing the game.

```gdscript
var browser := SaveBrowser.new()
browser.mode = SaveBrowser.Mode.LOAD          # or Mode.SAVE
browser.slot_chosen.connect(_load_from)        # closes itself right after
browser.slot_delete_requested.connect(_delete) # stays open; call browser.refresh() after
UISystem.show_modal(browser)
```

It reads `UISave` to draw the list and reports what was picked. It never writes anything — in Save
mode it asks before overwriting an occupied slot and then hands you the name.

`MainMenu` grows a **Continue** and a **Load Game** button, both disabled until `UISave` has
something; call `menu.refresh_saves()` if a save is written while the menu is up. `PauseMenu`
grows a **Load** entry, which — like Settings and Save — leaves the popup standing, so whoever
handles it closes the popup with `dialog.dismiss()` once a save has actually been chosen.

### On the web

`user://` is IndexedDB there (`/userfs/godot/app_userdata/<project>`), with two consequences worth
handling:

- `UISave.is_persistent()` is false in a private window or when site storage is blocked. Writes
  still appear to succeed and none of them survive a reload, so say so rather than saving into a
  void.
- The flush to IndexedDB happens after the file closes and is asynchronous. Do not quit in the
  same frame as a save — show the confirmation first and let it double as the window it needs.

Checked in a real browser on a Godot 4.7.2 single-threaded Web export: a save written in one page
load reads back intact after a reload, `Vector3` included, and `newest_slot()` still finds it —
so Continue lights up on a fresh visit. The temp-file swap works on the emscripten filesystem too,
leaving no `.tmp` or `.bak` behind. Note JSON has no integer type, so header numbers come back as
floats (`format` reads `1.0`); everything that compares them casts first.

Nothing in `UISave` touches a rendering API, so it behaves identically under Forward+,
Compatibility and Web.

There is also nothing to quit *to* in a browser tab, so `UISystem.can_quit()` is false there and
the screens drop their exits by default: `MainMenu` loses its Exit button **and** the title bar X
that asks the same question, and `PauseMenu` loses Save and Quit. Return to Main Menu stays —
leaving a level is not leaving the game. Override with `menu.show_exit_button` and
`pause.show_save_and_quit` if your build has somewhere to go.

## Sounds

Every sound slot on the `UISystem` node starts **empty**, and the wiring is already complete —
drop an `AudioStream` into a slot in the inspector and it is audible immediately, with no code
change anywhere.

| Slot | Fires on |
| --- | --- |
| `sound_click` | Any button press |
| `sound_hover` | Pointer entering a button |
| `sound_open` | A window or dialog appearing |
| `sound_close` | A dialog dismissed with the X or Escape |
| `sound_error` | Error style dialogs, including the pause menu |
| `sound_disabled` | A click that went nowhere |

Buttons this addon builds are bound automatically. For buttons you add yourself:

```gdscript
UISystem.bind_button(my_button)
```

One button can use a different voice without its own binding call:

```gdscript
my_button.set_meta("ui_press_sound", UIAudio.ERROR)
UISystem.bind_button(my_button)
```

## Theming

`UITheme` builds one `Theme` and caches it. To reskin everything, change the palette constants
at the top of `core/ui_theme.gd` — nothing else hardcodes a colour.

Widgets opt into a role through theme type variations rather than local overrides:
`WindowFrame`, `ClientPanel`, `SunkenPanel`, `TitleBar`, `TitleBarInactive`, `TitleButton`,
`TitleLabel`, `HintLabel`.

```gdscript
var panel := PanelContainer.new()
panel.theme_type_variation = &"ClientPanel"  # the sunken white plate
```

The bevels are 6×6 source images, so the layer roots set `TEXTURE_FILTER_NEAREST`. Keep that if
you re-parent things, or the one pixel highlights blur into grey under a stretched canvas.

## Pausing

`UISystem` sets itself to `PROCESS_MODE_ALWAYS`, and everything it creates inherits that. A
dialog with `pauses_tree = true` freezes the game on the way in and thaws it on the way out,
while remaining fully interactive itself. Dialogs stack, so a settings popup can open on top of
a pause menu without unfreezing anything.

## Placeholders left on purpose

- Window and dialog icons are `ColorRect` squares. Swap them for a `TextureRect` in
  `ui_window.gd` / `ui_dialog.gd` when there is art; no layout depends on them.
- The focus rectangle is a thin solid frame rather than the original dotted one.
- The credits text in `main_menu.gd` is a placeholder — set `MainMenu.credits_bbcode`.
