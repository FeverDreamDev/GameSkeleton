# Shared lookup used by the blocker and interactor helper nodes to find the
# TerrainGrass3D they belong to.
#
# This deliberately identifies the system by group rather than by class so the
# helpers carry no dependency back on terrain_grass_3d.gd, which references
# them in turn.
extends RefCounted

## Group every TerrainGrass3D adds itself to on _ready.
const SYSTEM_GROUP := &"procedural_terrain_grass_system"


## Resolves the terrain system for [param node]: an explicit [param explicit_path]
## wins, otherwise the scene's only terrain system is used. Returns null and
## warns when the binding is ambiguous or points somewhere unexpected.
static func resolve_system(node: Node, explicit_path: NodePath, type_name: String) -> Node:
	if not explicit_path.is_empty():
		var explicit := node.get_node_or_null(explicit_path)
		if explicit != null and explicit.is_in_group(SYSTEM_GROUP):
			return explicit
		push_warning("%s: terrain_system_path does not point at a TerrainGrass3D." % type_name)
		return null
	var systems := node.get_tree().get_nodes_in_group(SYSTEM_GROUP)
	if systems.size() == 1:
		return systems[0]
	if systems.size() > 1:
		push_warning("%s needs terrain_system_path set when multiple TerrainGrass3D nodes exist." % type_name)
	return null
