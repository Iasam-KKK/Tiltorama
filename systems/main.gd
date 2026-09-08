extends Node3D

## Greybox shell. Bakes the navmesh once the tray and its structures are in the
## tree, and quits on Escape so the build can be run fullscreen for playtests.

@export var nav_region: NavigationRegion3D


func _ready() -> void:
    if nav_region and nav_region.navigation_mesh:
        nav_region.bake_navigation_mesh(false)


func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_cancel"):
        get_tree().quit()
