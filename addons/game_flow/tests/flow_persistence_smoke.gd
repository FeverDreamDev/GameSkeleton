extends SceneTree

## Run with:
## godot --headless --path . --script res://addons/game_flow/tests/flow_persistence_smoke.gd

const Persistence := preload("res://addons/game_flow/core/flow_persistence.gd")
const State := preload("res://addons/game_flow/core/flow_state.gd")

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_native_round_trip()
	_test_runtime_references_are_rejected()
	_test_recursive_and_non_finite_values_are_rejected()
	_test_flow_state_boundary()
	State.reset()

	if _failures == 0:
		print("Flow persistence smoke: PASS")
		quit()
	else:
		push_error("Flow persistence smoke: %d failure(s)" % _failures)
		quit(1)


func _test_native_round_trip() -> void:
	var safe := {
		"nothing": null,
		"enabled": true,
		"count": 73,
		"ratio": 0.3,
		"label": "boss phase",
		"id": &"phase_two",
		"path": ^"Arena/SpawnPoints/North",
		"position": Vector3(1.0, 2.0, 3.0),
		"transform": Transform3D(Basis.IDENTITY, Vector3(4.0, 5.0, 6.0)),
		"colors": PackedColorArray([Color.RED, Color(0.2, 0.4, 0.6, 0.8)]),
		"nested": [{"event": &"wave_cleared", "remaining": 1.25}],
	}

	_check(Persistence.validate(safe).is_empty(), "safe native values validate")
	var encoded := Persistence.try_encode(safe)
	_check(bool(encoded[Persistence.RESULT_OK]), "safe native values encode")
	var text := JSON.stringify(encoded[Persistence.RESULT_VALUE])
	var parsed: Variant = JSON.parse_string(text)
	var decoded := Persistence.try_decode(parsed)
	_check(bool(decoded[Persistence.RESULT_OK]), "JSON-round-tripped values decode")
	_check(decoded[Persistence.RESULT_VALUE] == safe, "native types survive the codec round trip")

	var clone_result := Persistence.try_clone(safe)
	_check(bool(clone_result[Persistence.RESULT_OK]), "safe native values clone")
	var clone: Dictionary = clone_result[Persistence.RESULT_VALUE]
	(safe["nested"] as Array).append({"event": &"mutated_after_clone"})
	_check((clone["nested"] as Array).size() == 1, "codec clone detaches nested containers")


func _test_runtime_references_are_rejected() -> void:
	var node := Node.new()
	var resource := Resource.new()
	var unsafe := {
		"node": node,
		"resource": resource,
		"callable": node.queue_free,
		"signal": node.tree_entered,
		"rid": RID(),
	}
	var problems := Persistence.validate(unsafe, "runtime")
	_check(problems.size() == 5, "every runtime-only reference is reported")
	_check(_contains(problems, "runtime[\"node\"]"), "object problem carries its nested path")
	_check(_contains(problems, "runtime[\"resource\"]"), "resource problem carries its nested path")
	_check(_contains(problems, "Callable"), "callables are explicitly rejected")
	_check(_contains(problems, "Signal"), "signals are explicitly rejected")
	_check(_contains(problems, "RID"), "RIDs are explicitly rejected")
	_check(not bool(Persistence.try_encode(unsafe)[Persistence.RESULT_OK]),
		"unsafe values do not encode")
	node.free()


func _test_recursive_and_non_finite_values_are_rejected() -> void:
	var recursive: Array = []
	recursive.append(recursive)
	_check(_contains(Persistence.validate(recursive), "recursive"),
		"recursive containers are rejected")
	_check(not Persistence.is_safe(INF), "infinite floats are rejected")
	_check(not Persistence.is_safe(NAN), "NaN floats are rejected")
	_check(not Persistence.is_safe(Vector3(0.0, INF, 0.0)),
		"non-finite vector components are rejected")


func _test_flow_state_boundary() -> void:
	State.reset()
	State.current_level = &"arena"
	State.current_spawn = &"north"
	State.set_flag(&"boss_awake")

	var original := {"phase": 2, "arrivals": [&"north", &"south"]}
	_check(State.try_set_value(&"boss", original), "FlowState accepts safe values")
	(original["arrivals"] as Array).append(&"mutated_after_store")
	var stored: Dictionary = State.get_value(&"boss")
	_check((stored["arrivals"] as Array).size() == 2,
		"set_value detaches the caller's nested containers")

	(stored["arrivals"] as Array).append(Resource.new())
	stored = State.get_value(&"boss")
	_check((stored["arrivals"] as Array).size() == 2,
		"get_value does not expose mutable internal containers")

	var node := Node.new()
	_check(not State.can_store_value({"source": node}),
		"FlowState exposes persistence validation")
	_check(not State.try_set_value(&"boss", {"source": node}),
		"an unsafe write is refused")
	_check((State.get_value(&"boss") as Dictionary).get("phase") == 2,
		"a refused write does not replace the prior safe value")

	var payload := State.to_dict()
	_check(Persistence.is_safe(payload), "FlowState.to_dict is persistence-safe")
	_check(payload[State.KEY_LEVEL] == "arena" and payload[State.KEY_SPAWN] == "north",
		"existing level and spawn payload keys are unchanged")
	_check("boss_awake" in (payload[State.KEY_FLAGS] as Array),
		"existing flag payload behavior is unchanged")

	State.from_dict({
		State.KEY_LEVEL: "restored_arena",
		State.KEY_SPAWN: "center",
		State.KEY_FLAGS: ["restored_flag"],
		State.KEY_VALUES: {
			"safe": {"value": 11},
			"unsafe": node,
		},
	})
	_check(State.current_level == &"restored_arena" and State.current_spawn == &"center",
		"from_dict restores existing location fields")
	_check(State.has_flag(&"restored_flag"), "from_dict restores existing flags")
	_check(State.has_value(&"safe") and not State.has_value(&"unsafe"),
		"from_dict accepts safe values and drops runtime references")
	node.free()


func _contains(problems: Array[String], fragment: String) -> bool:
	for problem: String in problems:
		if fragment in problem:
			return true
	return false


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS: ", label)
		return
	_failures += 1
	push_error("  FAIL: %s" % label)
