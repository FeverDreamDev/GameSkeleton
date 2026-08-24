extends Node3D

## Standalone demo for the day_night_cycle add-on. Press play on
## DayNightExample.tscn.
##
## Deliberately has no RTSceneManager: the add-on renders the same sky, lights
## and clouds with or without ray tracing, and the shadows here are Godot's
## ordinary raster ones. Run the game's terrain_test level to see the RT cloud
## shadows the add-on exists for.

const SCRUB_HOURS_PER_SECOND := 3.0

@onready var cycle: DayNightCycle3D = $DayNightCycle3D
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var readout: Label = $UI/Readout

var _orbit: float = 0.0
var _fast_forward: bool = false


func _ready() -> void:
	cycle.day_changed.connect(_on_day_changed)
	cycle.phase_changed.connect(_on_phase_changed)


func _process(delta: float) -> void:
	_orbit += delta * 0.06
	$CameraPivot.rotation.y = _orbit

	if Input.is_key_pressed(KEY_BRACKETLEFT):
		cycle.advance_time(-SCRUB_HOURS_PER_SECOND * delta)
	if Input.is_key_pressed(KEY_BRACKETRIGHT):
		cycle.advance_time(SCRUB_HOURS_PER_SECOND * delta)

	readout.text = "\n".join([
		"Day %d   %s   %s" % [
			cycle.get_day_number(), _clock_text(), cycle.get_phase_name()],
		"cycle %.0f s%s" % [
			cycle.get_day_length_seconds(), "  (fast)" if _fast_forward else ""],
		"sun %.2f   moon %.2f   stars %.2f" % [
			cycle.get_sun_light_energy(),
			cycle.get_moon_light_energy(),
			cycle.get_star_intensity()],
		"cloud cover %.0f%%   sun blocked %.0f%%" % [
			cycle.get_cloud_coverage() * 100.0, cycle.get_sun_occlusion() * 100.0],
		"",
		"[ ]  scrub time      P  pause      F  fast forward",
		"1 2 3  cloud cover    C  new day",
	])


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_P:
			cycle.set_time_running(not cycle.is_time_running())
		KEY_F:
			_fast_forward = not _fast_forward
			cycle.set_time_scale(12.0 if _fast_forward else 1.0)
		KEY_1:
			cycle.set_cloud_coverage(0.0)
		KEY_2:
			cycle.set_cloud_coverage(0.55)
		KEY_3:
			cycle.set_cloud_coverage(1.0)
		KEY_C:
			# Rolling the day is what re-rolls the clouds and the stars.
			cycle.set_day_number(cycle.get_day_number() + 1)


func _clock_text() -> String:
	var hours := cycle.get_time_of_day()
	return "%02d:%02d" % [int(hours), int(fposmod(hours, 1.0) * 60.0)]


func _on_day_changed(day_number: int) -> void:
	print("day %d begins under a new sky" % day_number)


func _on_phase_changed(phase: int) -> void:
	print("phase: %s" % cycle.get_phase_name())
	if phase == DayNightCycle3D.Phase.NIGHT:
		print("  moon phase %.2f" % cycle.get_moon_phase())
