@tool
extends EditorPlugin

# DayNightCycle3D and DayNightPalette register themselves as global classes
# through `class_name`, so they appear in Create Node / Create Resource and are
# statically typeable whether or not this plugin is enabled. That is the same
# choice procedural_terrain_grass made, and it replaces add_custom_type(), which
# produced plain Node3D/Resource instances user code could not type-check
# against.
#
# The plugin entry is kept so the add-on can be enabled, updated and removed
# from Project Settings > Plugins like any other. It writes no project settings:
# the add-on inherits the Retro RT visual contract rather than changing it.
