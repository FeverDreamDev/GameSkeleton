@tool
class_name FlowPersistence
extends RefCounted

## Shared persistence boundary for GameFlow runtime state.
##
## Persistence data may contain ordinary Variant values and Godot's value types, but never live
## runtime handles. In particular, Objects (including Nodes and Resources), Callables, Signals and
## RIDs cannot be reconstructed safely in another run. Validate at the boundary, then use the
## codec helpers to obtain a detached value that is safe to hand to a save payload.

const RESULT_OK := "ok"
const RESULT_VALUE := "value"
const RESULT_PROBLEMS := "problems"

## A finite bound makes validation safe even for hostile or accidentally recursive payloads.
const MAX_DEPTH := 64


## Returns every persistence problem below [param value]. An empty array means the whole value is
## safe. Paths start at [param root_path], which defaults to the familiar JSON-style [code]$[/code].
static func validate(value: Variant, root_path: String = "$") -> Array[String]:
	var problems: Array[String] = []
	var ancestors: Array = []
	_validate_value(value, root_path if not root_path.is_empty() else "$", 0, ancestors, problems)
	return problems


static func is_safe(value: Variant) -> bool:
	return validate(value).is_empty()


## Converts a safe native Variant to the JSON-compatible representation understood by
## [method JSON.to_native]. The returned dictionary always contains [code]ok[/code],
## [code]value[/code], and [code]problems[/code]. A failed conversion uses null for its value.
static func try_encode(value: Variant, root_path: String = "$") -> Dictionary:
	var problems := validate(value, root_path)
	if not problems.is_empty():
		return _result(false, null, problems)
	return _result(true, JSON.from_native(value, false), problems)


## Decodes data produced by [method try_encode] without allowing full Objects, then validates the
## result again. The second check is intentional: save data is external input and may be edited.
static func try_decode(encoded: Variant, root_path: String = "$") -> Dictionary:
	var encoded_problems := validate(encoded, "%s(encoded)" % root_path)
	if not encoded_problems.is_empty():
		return _result(false, null, encoded_problems)

	var decoded: Variant = JSON.to_native(encoded, false)
	var problems := validate(decoded, root_path)
	if not problems.is_empty():
		return _result(false, null, problems)
	return _result(true, decoded, problems)


## Returns a persistence-safe deep copy through the same native codec used by save files. This
## prevents a caller from inserting a live Object into a Dictionary after it has been stored.
static func try_clone(value: Variant, root_path: String = "$") -> Dictionary:
	var encoded := try_encode(value, root_path)
	if not bool(encoded[RESULT_OK]):
		return encoded
	return try_decode(encoded[RESULT_VALUE], root_path)


## Convenience wrappers for callers that cannot use a result dictionary. Invalid input returns
## null and reports the precise validation problems. Use the [code]try_*[/code] forms when null is
## itself a meaningful value.
static func encode(value: Variant, root_path: String = "$") -> Variant:
	return _value_or_report(try_encode(value, root_path), "encode")


static func decode(encoded: Variant, root_path: String = "$") -> Variant:
	return _value_or_report(try_decode(encoded, root_path), "decode")


static func clone(value: Variant, root_path: String = "$") -> Variant:
	return _value_or_report(try_clone(value, root_path), "clone")


static func format_problems(problems: Array[String]) -> String:
	return "; ".join(problems)


static func _result(ok: bool, value: Variant, problems: Array[String]) -> Dictionary:
	return {
		RESULT_OK: ok,
		RESULT_VALUE: value,
		RESULT_PROBLEMS: problems,
	}


static func _value_or_report(result: Dictionary, operation: String) -> Variant:
	if bool(result.get(RESULT_OK, false)):
		return result.get(RESULT_VALUE)
	var raw: Variant = result.get(RESULT_PROBLEMS, [] as Array[String])
	var problems: Array[String] = []
	if raw is Array:
		for problem: Variant in raw:
			problems.append(str(problem))
	push_warning("FlowPersistence.%s(): %s" % [operation, format_problems(problems)])
	return null


static func _validate_value(
		value: Variant,
		path: String,
		depth: int,
		ancestors: Array,
		problems: Array[String]
) -> void:
	if depth > MAX_DEPTH:
		problems.append("%s is nested deeper than %d levels" % [path, MAX_DEPTH])
		return

	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			pass

		TYPE_FLOAT:
			_check_float(float(value), path, problems)

		TYPE_VECTOR2:
			var vector: Vector2 = value
			_check_components([vector.x, vector.y], path, problems)

		TYPE_VECTOR2I:
			pass

		TYPE_RECT2:
			var rect: Rect2 = value
			_check_components([
				rect.position.x, rect.position.y, rect.size.x, rect.size.y,
			], path, problems)

		TYPE_RECT2I:
			pass

		TYPE_VECTOR3:
			var vector: Vector3 = value
			_check_components([vector.x, vector.y, vector.z], path, problems)

		TYPE_VECTOR3I:
			pass

		TYPE_TRANSFORM2D:
			var transform: Transform2D = value
			_check_components([
				transform.x.x, transform.x.y,
				transform.y.x, transform.y.y,
				transform.origin.x, transform.origin.y,
			], path, problems)

		TYPE_VECTOR4:
			var vector: Vector4 = value
			_check_components([vector.x, vector.y, vector.z, vector.w], path, problems)

		TYPE_VECTOR4I:
			pass

		TYPE_PLANE:
			var plane: Plane = value
			_check_components([plane.x, plane.y, plane.z, plane.d], path, problems)

		TYPE_QUATERNION:
			var quaternion: Quaternion = value
			_check_components([
				quaternion.x, quaternion.y, quaternion.z, quaternion.w,
			], path, problems)

		TYPE_AABB:
			var box: AABB = value
			_check_components([
				box.position.x, box.position.y, box.position.z,
				box.size.x, box.size.y, box.size.z,
			], path, problems)

		TYPE_BASIS:
			var basis: Basis = value
			_check_components([
				basis.x.x, basis.x.y, basis.x.z,
				basis.y.x, basis.y.y, basis.y.z,
				basis.z.x, basis.z.y, basis.z.z,
			], path, problems)

		TYPE_TRANSFORM3D:
			var transform: Transform3D = value
			_check_components([
				transform.basis.x.x, transform.basis.x.y, transform.basis.x.z,
				transform.basis.y.x, transform.basis.y.y, transform.basis.y.z,
				transform.basis.z.x, transform.basis.z.y, transform.basis.z.z,
				transform.origin.x, transform.origin.y, transform.origin.z,
			], path, problems)

		TYPE_PROJECTION:
			var projection: Projection = value
			_check_components([
				projection.x.x, projection.x.y, projection.x.z, projection.x.w,
				projection.y.x, projection.y.y, projection.y.z, projection.y.w,
				projection.z.x, projection.z.y, projection.z.z, projection.z.w,
				projection.w.x, projection.w.y, projection.w.z, projection.w.w,
			], path, problems)

		TYPE_COLOR:
			var color: Color = value
			_check_components([color.r, color.g, color.b, color.a], path, problems)

		TYPE_DICTIONARY:
			_validate_dictionary(value, path, depth, ancestors, problems)

		TYPE_ARRAY:
			_validate_array(value, path, depth, ancestors, problems)

		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			for index: int in value.size():
				_check_float(float(value[index]), "%s[%d]" % [path, index], problems)

		TYPE_PACKED_VECTOR2_ARRAY:
			for index: int in value.size():
				var vector: Vector2 = value[index]
				_check_components([vector.x, vector.y], "%s[%d]" % [path, index], problems)

		TYPE_PACKED_VECTOR3_ARRAY:
			for index: int in value.size():
				var vector: Vector3 = value[index]
				_check_components([vector.x, vector.y, vector.z], "%s[%d]" % [path, index], problems)

		TYPE_PACKED_VECTOR4_ARRAY:
			for index: int in value.size():
				var vector: Vector4 = value[index]
				_check_components([
					vector.x, vector.y, vector.z, vector.w,
				], "%s[%d]" % [path, index], problems)

		TYPE_PACKED_COLOR_ARRAY:
			for index: int in value.size():
				var color: Color = value[index]
				_check_components([
					color.r, color.g, color.b, color.a,
				], "%s[%d]" % [path, index], problems)

		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
				TYPE_PACKED_STRING_ARRAY:
			pass

		TYPE_OBJECT:
			problems.append("%s contains an Object or Resource reference, which is runtime-only" % path)

		TYPE_CALLABLE:
			problems.append("%s contains a Callable, which is runtime-only" % path)

		TYPE_SIGNAL:
			problems.append("%s contains a Signal, which is runtime-only" % path)

		TYPE_RID:
			problems.append("%s contains an RID, which is runtime-only" % path)

		_:
			problems.append("%s has unsupported Variant type %s" % [path, type_string(typeof(value))])


static func _validate_dictionary(
		dictionary: Dictionary,
		path: String,
		depth: int,
		ancestors: Array,
		problems: Array[String]
) -> void:
	if _has_ancestor(dictionary, ancestors):
		problems.append("%s contains a recursive Dictionary reference" % path)
		return
	ancestors.append(dictionary)
	var index := 0
	for key: Variant in dictionary:
		_validate_value(key, "%s<key:%d>" % [path, index], depth + 1, ancestors, problems)
		_validate_value(
			dictionary[key], _path_for_key(path, key, index), depth + 1, ancestors, problems)
		index += 1
	ancestors.pop_back()


static func _validate_array(
		array: Array,
		path: String,
		depth: int,
		ancestors: Array,
		problems: Array[String]
) -> void:
	if _has_ancestor(array, ancestors):
		problems.append("%s contains a recursive Array reference" % path)
		return
	ancestors.append(array)
	for index: int in array.size():
		_validate_value(array[index], "%s[%d]" % [path, index], depth + 1, ancestors, problems)
	ancestors.pop_back()


static func _has_ancestor(container: Variant, ancestors: Array) -> bool:
	for ancestor: Variant in ancestors:
		if is_same(container, ancestor):
			return true
	return false


static func _path_for_key(path: String, key: Variant, index: int) -> String:
	if key is String or key is StringName:
		return "%s[%s]" % [path, JSON.stringify(str(key))]
	return "%s<value:%d>" % [path, index]


static func _check_components(components: Array, path: String, problems: Array[String]) -> void:
	for component: Variant in components:
		if not is_finite(float(component)):
			problems.append("%s contains a non-finite number" % path)
			return


static func _check_float(value: float, path: String, problems: Array[String]) -> void:
	if not is_finite(value):
		problems.append("%s is not a finite number" % path)
