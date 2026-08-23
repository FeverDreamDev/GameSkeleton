class_name UIAudio
extends Node

## The UI sound bank. Created and owned by [UISystem]; you do not add this node yourself.
##
## Every sound slot starts empty on purpose. [method play] silently does nothing for a slot with
## no stream in it, so the whole system is already wired end to end and stays quiet until you
## drop actual files into the [UISystem] node's Sounds group in the inspector. Nothing else has
## to change when you do.
##
## Playback goes through a small pool of players so overlapping sounds -- a hover landing on top
## of a click -- do not cut each other off.

#region Sound Ids

const CLICK := &"click" ## Any button being pressed.
const HOVER := &"hover" ## Pointer entering a button.
const OPEN := &"open" ## A window or dialog appearing.
const CLOSE := &"close" ## A window or dialog going away.
const ERROR := &"error" ## The chord an error box made. Used by the pause menu.
const DISABLED := &"disabled" ## A click that went nowhere.

#endregion

#region Configuration

## Sound id to stream. Filled in by [UISystem] from its exported slots.
var streams: Dictionary = {}

var bus: StringName = &"Master"
var volume_db: float = 0.0
## Simultaneous sounds before the oldest is reused.
var voices: int = 6

#endregion

var _players: Array[AudioStreamPlayer] = []
var _next_player: int = 0

func _ready() -> void:
	# The UI keeps working while the tree is paused, so its sounds have to as well -- otherwise
	# the pause menu opens in silence and every button in it is mute.
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in maxi(voices, 1):
		var player := AudioStreamPlayer.new()
		player.bus = bus
		player.volume_db = volume_db
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(player)
		_players.append(player)

## Plays the stream registered under [param id]. A missing or empty slot is not an error; it is
## the normal state until sounds exist.
func play(id: StringName) -> void:
	var stream: AudioStream = streams.get(id)
	if stream == null or _players.is_empty():
		return
	# Round robin rather than "find a free player": a rapid click while the previous one is
	# still ringing should layer, not steal.
	var player := _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	player.stream = stream
	player.play()

func has_sound(id: StringName) -> bool:
	return streams.get(id) != null

## Gives [param button] the standard press and hover sounds.
##
## A button can override either by carrying metadata, which is how one button gets a different
## voice without a separate binding call:
## [codeblock]
## button.set_meta("ui_press_sound", UIAudio.ERROR)
## [/codeblock]
func bind_button(button: BaseButton) -> void:
	if button == null:
		return
	# The connected callables are bound, so is_connected() can never recognise them. A marker on
	# the button is what actually keeps a second bind from doubling every sound.
	if button.has_meta("ui_sound_bound"):
		return
	button.set_meta("ui_sound_bound", true)

	var press_id: StringName = StringName(button.get_meta("ui_press_sound", CLICK))
	var hover_id: StringName = StringName(button.get_meta("ui_hover_sound", HOVER))
	button.pressed.connect(_on_button_pressed.bind(button, press_id))
	button.mouse_entered.connect(_on_button_hovered.bind(button, hover_id))

func _on_button_pressed(_button: BaseButton, id: StringName) -> void:
	play(id)

## A disabled button still emits mouse_entered -- it is greyed out, not transparent -- so the
## hover sound has to be suppressed here or dead controls chirp as the pointer crosses them.
func _on_button_hovered(button: BaseButton, id: StringName) -> void:
	if not button.disabled:
		play(id)
