extends StaticBody3D
class_name Structure

## One node for every structure kind; the behaviour that differs is small enough
## that a switch beats six scripts. Driven entirely by its StructureType.

signal minted(count: int)

var type: StructureType

var _shape: CollisionShape3D
var _box := BoxShape3D.new()
var _open := false


func configure(structure_type: StructureType) -> void:
    type = structure_type
    collision_layer = 1
    collision_mask = 1

    for child in get_children():
        child.queue_free()

    var size := type.footprint

    _shape = CollisionShape3D.new()
    _box.size = size
    _shape.shape = _box
    _shape.position = Vector3(0.0, size.y * 0.5, 0.0)
    add_child(_shape)

    if type.kind == StructureType.Kind.BUMPER:
        var bouncy := PhysicsMaterial.new()
        bouncy.bounce = type.bounce
        bouncy.friction = 0.2
        physics_material_override = bouncy

    if type.model:
        var art := type.model.instantiate()
        add_child(art)
    else:
        var mi := MeshInstance3D.new()
        var mesh := BoxMesh.new()
        mesh.size = size
        mi.mesh = mesh
        mi.position = Vector3(0.0, size.y * 0.5, 0.0)
        var mat := StandardMaterial3D.new()
        mat.albedo_color = type.colour
        mat.roughness = 1.0
        mat.metallic = 0.0
        mi.material_override = mat
        add_child(mi)

    # A ramp is a slab tipped along its own length; rollers pick up speed down it.
    if type.kind == StructureType.Kind.RAMP:
        var angle := atan2(type.drop, maxf(size.z, 0.01))
        rotation.x = -angle


func base_value() -> int:
    return type.base_value if type else 0


func is_gate() -> bool:
    return type != null and type.kind == StructureType.Kind.GATE


func is_quarry() -> bool:
    return type != null and type.kind == StructureType.Kind.QUARRY


## Houses are what VillagerPool bills beds against. It matches on `id` today
## because the HOUSE kind did not exist when it was written; this is the check it
## should move to, because it survives a house being re-skinned under a new id.
func is_house() -> bool:
    return type != null and type.kind == StructureType.Kind.HOUSE


## Gates hold a stockpile until the player opens them, which is what turns a tilt
## into a shot.
func set_open(open: bool) -> void:
    if not is_gate() or _open == open:
        return
    _open = open
    if _shape:
        _shape.set_deferred("disabled", open)
    for child in get_children():
        if child is Node3D and child != _shape:
            (child as Node3D).visible = not open


func mint() -> int:
    if not is_quarry():
        return 0
    minted.emit(type.mint_per_wave)
    return type.mint_per_wave
