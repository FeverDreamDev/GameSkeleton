@tool
class_name FlowRandomNode
extends FlowGraphNode

## Chooses exactly one connected output using the authored relative weights.
##
## The port IDs are stable graph-model identifiers, not GraphNode slot indexes. Connections on
## unselected ports are never traversed. Multiple wires may intentionally fan out from the one
## selected port using the normal graph execution rules.

## Structural branch edits are owned by the Game Flow editor so port changes can migrate graph
## connections atomically. The array still serializes normally, but the generic Inspector does not
## expose a second, unsafe editing path.
@export_storage var branches: Array[FlowRandomBranch] = []


func _init() -> void:
	if branches.is_empty():
		branches = [
			_branch(&"option_a", "Option A"),
			_branch(&"option_b", "Option B"),
		] as Array[FlowRandomBranch]


func type_id() -> StringName:
	return &"random"


func display_title() -> String:
	return title_override if not title_override.is_empty() else "Choose Random Path"


func output_ports() -> Array[StringName]:
	var ports: Array[StringName] = []
	for branch: FlowRandomBranch in branches:
		if branch == null or branch.port_id.is_empty() or ports.has(branch.port_id):
			continue
		ports.append(branch.port_id)
	return ports


func port_label(port_id: StringName) -> String:
	for branch: FlowRandomBranch in branches:
		if branch != null and branch.port_id == port_id:
			return "%s  (chance weight %s)" % [branch.display_label(), _format_weight(branch.weight)]
	return super.port_label(port_id)


func validation_issues(
		_database: FlowDatabase,
		graph_id: StringName
) -> Array[FlowValidationIssue]:
	var issues: Array[FlowValidationIssue] = []
	if branches.is_empty():
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"random_missing_branches",
			"Add at least one possible outcome to Choose Random Path.",
			graph_id,
			node_id
		))
		return issues

	var seen_ports := {}
	var total_weight := 0.0
	for index in branches.size():
		var branch: FlowRandomBranch = branches[index]
		if branch == null:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"random_empty_branch_slot",
				"Random outcome %d is missing." % (index + 1),
				graph_id,
				node_id
			))
			continue
		if branch.port_id.is_empty():
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"random_missing_port_id",
				"Random outcome %d needs an internal connection name." % (index + 1),
				graph_id,
				node_id
			))
		elif seen_ports.has(branch.port_id):
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"random_duplicate_port_id",
				"Two random outcomes use the same internal connection name '%s'." % branch.port_id,
				graph_id,
				node_id,
				&"",
				"",
				branch.port_id
			))
		else:
			seen_ports[branch.port_id] = true

		if not is_finite(branch.weight) or branch.weight <= 0.0:
			issues.append(FlowValidationIssue.make(
				FlowValidationIssue.Severity.ERROR,
				&"random_invalid_weight",
				"The Chance Weight for '%s' must be greater than zero." \
						% branch.port_id,
				graph_id,
				node_id,
				&"",
				"",
				branch.port_id
			))
		else:
			total_weight += branch.weight

	if not is_finite(total_weight):
		issues.append(FlowValidationIssue.make(
			FlowValidationIssue.Severity.ERROR,
			&"random_invalid_total_weight",
			"The combined Chance Weight is too large.",
			graph_id,
			node_id
		))
	return issues


func _branch(port_id: StringName, label: String) -> FlowRandomBranch:
	var branch := FlowRandomBranch.new()
	branch.port_id = port_id
	branch.label = label
	return branch


func _format_weight(weight: float) -> String:
	if not is_finite(weight):
		return str(weight)
	if is_equal_approx(weight, roundf(weight)):
		return str(int(roundf(weight)))
	return String.num(weight, 2).trim_suffix("0").trim_suffix("0").trim_suffix(".")
