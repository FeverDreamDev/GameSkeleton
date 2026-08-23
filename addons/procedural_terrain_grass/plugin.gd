@tool
extends EditorPlugin

# TerrainGrass3D, TerrainGrassBlocker3D and TerrainGrassInteractor3D register
# themselves as global classes through `class_name`, so they appear in Create
# Node and are statically typeable whether or not this plugin is enabled. That
# replaces the older add_custom_type() registration, which produced plain
# Node3D/Area3D nodes that user code could not type-check against.
#
# The plugin entry is kept so the add-on can be enabled, updated and removed
# from Project Settings > Plugins like any other.
