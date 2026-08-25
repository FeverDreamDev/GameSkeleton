@tool
class_name FlowCondition
extends Resource

## A property-based condition for an IF node. There are no typed data wires in v1.

enum Source {
	FLOW_STATE_FLAG,
	FLOW_STATE_VALUE,
	EVENT_DATA,
	LOCAL_VALUE,
}

enum Operator {
	EQUAL,
	NOT_EQUAL,
	LESS,
	LESS_OR_EQUAL,
	GREATER,
	GREATER_OR_EQUAL,
	IS_TRUE,
	IS_FALSE,
	EXISTS,
	NOT_EXISTS,
}

@export var source: Source = Source.FLOW_STATE_VALUE
@export var key: StringName = &""
@export var operator: Operator = Operator.EQUAL
@export var value: Variant = null


## Runtime context may contain `event_data` and `locals` dictionaries. FlowState-backed sources
## read the existing durable story blackboard directly.
func evaluate(context: Dictionary = {}) -> bool:
	var resolved := _resolve(context)
	var exists := bool(resolved["exists"])
	var actual: Variant = resolved["value"]

	match operator:
		Operator.EXISTS:
			return exists
		Operator.NOT_EXISTS:
			return not exists
		Operator.IS_TRUE:
			return exists and bool(actual)
		Operator.IS_FALSE:
			return not exists or not bool(actual)
		Operator.EQUAL:
			return exists and actual == value
		Operator.NOT_EQUAL:
			return not exists or actual != value
		Operator.LESS, Operator.LESS_OR_EQUAL, Operator.GREATER, Operator.GREATER_OR_EQUAL:
			if not exists or not _is_number(actual) or not _is_number(value):
				return false
			var left := float(actual)
			var right := float(value)
			match operator:
				Operator.LESS:
					return left < right
				Operator.LESS_OR_EQUAL:
					return left <= right
				Operator.GREATER:
					return left > right
				_:
					return left >= right
	return false


func validation_issues(graph_id: StringName, node_id: StringName) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if key.is_empty():
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"condition_missing_key",
			"Choose a Story Flag, Story Value, Event Detail, or Path Value to check.",
			graph_id,
			node_id
		))
	if operator in [Operator.LESS, Operator.LESS_OR_EQUAL, Operator.GREATER, Operator.GREATER_OR_EQUAL]:
		if source == Source.FLOW_STATE_FLAG:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"condition_ordered_flag",
				"A Story Flag can only be checked as On, Off, Set, Equal, or Not Equal.",
				graph_id,
				node_id
			))
		if not _is_number(value) or not is_finite(float(value)):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"condition_ordered_non_numeric",
				"Compare With must be a normal number for this comparison.",
				graph_id,
				node_id
			))
	var persistence_problems := FlowPersistence.validate(value, "if.condition.value")
	if not persistence_problems.is_empty():
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"condition_unsafe_value",
			"Compare With contains something that cannot be saved: %s" \
					% FlowPersistence.format_problems(persistence_problems),
			graph_id,
			node_id
		))
	return issues


func describe() -> String:
	var subject := String(key).replace("_", " ").capitalize()
	match operator:
		Operator.EXISTS:
			return "%s Is Set" % subject
		Operator.NOT_EXISTS:
			return "%s Is Not Set" % subject
		Operator.IS_TRUE:
			return "%s Is On" % subject
		Operator.IS_FALSE:
			return "%s Is Off" % subject
		Operator.EQUAL:
			return "%s = %s" % [subject, _friendly_value(value)]
		Operator.NOT_EQUAL:
			return "%s ≠ %s" % [subject, _friendly_value(value)]
		Operator.LESS:
			return "%s < %s" % [subject, _friendly_value(value)]
		Operator.LESS_OR_EQUAL:
			return "%s ≤ %s" % [subject, _friendly_value(value)]
		Operator.GREATER:
			return "%s > %s" % [subject, _friendly_value(value)]
		Operator.GREATER_OR_EQUAL:
			return "%s ≥ %s" % [subject, _friendly_value(value)]
	return subject


func _friendly_value(candidate: Variant) -> String:
	if candidate is bool:
		return "On" if candidate else "Off"
	if candidate is String or candidate is StringName:
		return String(candidate).replace("_", " ").capitalize()
	return str(candidate)


func _resolve(context: Dictionary) -> Dictionary:
	match source:
		Source.FLOW_STATE_FLAG:
			return {"exists": FlowState.has_flag(key), "value": FlowState.has_flag(key)}
		Source.FLOW_STATE_VALUE:
			return {"exists": FlowState.has_value(key), "value": FlowState.get_value(key)}
		Source.EVENT_DATA:
			return _resolve_dictionary(context.get("event_data", {}))
		Source.LOCAL_VALUE:
			return _resolve_dictionary(context.get("locals", {}))
	return {"exists": false, "value": null}


func _resolve_dictionary(candidate: Variant) -> Dictionary:
	if candidate is Dictionary:
		var dictionary: Dictionary = candidate
		if dictionary.has(key):
			return {"exists": true, "value": dictionary.get(key)}
		var string_key := String(key)
		if dictionary.has(string_key):
			return {"exists": true, "value": dictionary.get(string_key)}
	return {"exists": false, "value": null}


func _is_number(candidate: Variant) -> bool:
	return candidate is int or candidate is float
