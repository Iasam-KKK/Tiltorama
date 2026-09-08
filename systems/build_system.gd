extends Node3D
class_name BuildSystem

## Prep-phase building. Pick from the palette with the number keys (one per entry,
## and Loadout resizes the palette as the draft unlocks kinds), place with left click.
## Placing changes the base value, which raises the next wave's budget -- the
## build decision and the threat decision are the same decision.

signal palette_changed(index: int)
signal structures_changed()

@export var palette: Array[StructureType] = []
@export var structures_root: Node3D
@export var nav_region: NavigationRegion3D
@export var economy: Economy
@export var run_state: RunState
@export var keep: Node3D
## Distance from tray centre to the inside face of a rim.
@export var tray_half := 5.6
@export var grid := 0.5
## Nothing may be placed within this of the keep's centre.
@export var keep_clearance := 1.6

var selected := 0
var active := false

var _ghost: MeshInstance3D
var _ghost_material := StandardMaterial3D.new()
var _ghost_mesh := BoxMesh.new()
var _valid := false
var _spot := Vector3.ZERO


func _ready() -> void:
    _ghost_material.albedo_color = Color(0.3, 0.8, 0.5, 0.45)
    _ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    _ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    _ghost = MeshInstance3D.new()
    _ghost.mesh = _ghost_mesh
    _ghost.material_override = _ghost_material
    _ghost.visible = false
    add_child(_ghost)


func current() -> StructureType:
    if palette.is_empty():
        return null
    return palette[clampi(selected, 0, palette.size() - 1)]


func select(index: int) -> void:
    if palette.is_empty():
        return
    selected = clampi(index, 0, palette.size() - 1)
    palette_changed.emit(selected)


func _unhandled_input(event: InputEvent) -> void:
    if not active:
        return
    var key := event as InputEventKey
    if key and key.pressed and not key.echo:
        if key.keycode >= KEY_1 and key.keycode <= KEY_9:
            select(key.keycode - KEY_1)
            get_viewport().set_input_as_handled()
        return
    var click := event as InputEventMouseButton
    if click and click.pressed and click.button_index == MOUSE_BUTTON_LEFT and _valid:
        _place()
        get_viewport().set_input_as_handled()


func _process(_dt: float) -> void:
    active = run_state != null and run_state.phase == RunState.Phase.PREP
    if not active or current() == null:
        _ghost.visible = false
        return
    var hit: Variant = _mouse_on_tray()
    if hit == null:
        _ghost.visible = false
        return

    var type := current()
    _spot = _snap(hit)
    _valid = _is_placeable(_spot, type) and economy != null and economy.can_afford(type.cost)

    _ghost_mesh.size = type.footprint
    _ghost.position = _spot + Vector3(0.0, type.footprint.y * 0.5, 0.0)
    _ghost_material.albedo_color = (Color(0.3, 0.8, 0.5, 0.45) if _valid
        else Color(0.85, 0.3, 0.2, 0.4))
    _ghost.visible = true


func _place() -> void:
    var type := current()
    if type == null or economy == null or not economy.spend(type.cost):
        return
    var s := Structure.new()
    # Positioned BEFORE it enters the tree. Physics interpolation is on
    # project-wide and the automatic reset a node gets on entering captures
    # whatever transform it holds at that moment -- so placing after add_child()
    # leaves the wall interpolating out of the tray centre for one frame.
    s.position = structures_root.to_local(_spot)
    structures_root.add_child(s)
    s.configure(type)
    # configure() tilts a ramp and offsets the mesh and shape it just added, all
    # of it after the node is already in the tree, so the interpolation history
    # has to be refreshed once more. Recursive, which is what covers the children.
    s.reset_physics_interpolation()
    _rebake()
    structures_changed.emit()


func _rebake() -> void:
    if nav_region and nav_region.navigation_mesh:
        nav_region.bake_navigation_mesh(false)


func _snap(p: Vector3) -> Vector3:
    return Vector3(roundf(p.x / grid) * grid, 0.0, roundf(p.z / grid) * grid)


## Returns the point where the mouse ray meets the tray plane, or null if it misses.
func _mouse_on_tray() -> Variant:
    var cam := get_viewport().get_camera_3d()
    if cam == null:
        return null
    var mouse := get_viewport().get_mouse_position()
    var origin := cam.project_ray_origin(mouse)
    var dir := cam.project_ray_normal(mouse)
    if absf(dir.y) < 0.0001:
        return null
    var t := -origin.y / dir.y
    if t <= 0.0:
        return null
    return origin + dir * t


func _is_placeable(at: Vector3, type: StructureType) -> bool:
    var half_x := type.footprint.x * 0.5
    var half_z := type.footprint.z * 0.5
    if absf(at.x) + half_x > tray_half or absf(at.z) + half_z > tray_half:
        return false
    if keep and Vector2(at.x - keep.global_position.x, at.z - keep.global_position.z).length() < keep_clearance:
        return false
    for child in structures_root.get_children():
        var other := child as Structure
        if other == null or other.type == null:
            continue
        var gap_x := absf(at.x - other.global_position.x)
        var gap_z := absf(at.z - other.global_position.z)
        if gap_x < half_x + other.type.footprint.x * 0.5 - 0.01 \
                and gap_z < half_z + other.type.footprint.z * 0.5 - 0.01:
            return false
    return true
