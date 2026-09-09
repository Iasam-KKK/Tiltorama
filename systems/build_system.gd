extends Node3D
class_name BuildSystem

## Prep-phase building. Pick from the palette with the number keys (one per entry,
## and Loadout resizes the palette as the draft unlocks kinds) or the mouse wheel,
## place with left click. Placing changes the base value, which raises the next
## wave's budget -- the build decision and the threat decision are the same
## decision.
##
## The ghost is built from the same slab list the real structure is (see
## Structure.pieces_for), so a funnel's ghost is a funnel and not the box it fits
## inside. It also has to tell the truth about the RULES, which is what the seal
## check below is for: a placement that closes the last way in to the keep goes
## amber, and one that closes it with nothing a raider could break is refused. See
## _seal_state() for why those two answers differ.

signal palette_changed(index: int)
signal structures_changed()
## Why the ghost is the colour it is, in words, for the HUD. Empty means "green,
## nothing to say".
signal placement_hint_changed(text: String)

## OPEN: raiders can still walk in. BREAKABLE: the kingdom is sealed, but something
## in the ring has hit points. SOLID: sealed by things nothing can break.
enum Seal { OPEN, BREAKABLE, SOLID }

@export var palette: Array[StructureType] = []
@export var structures_root: Node3D
@export var nav_region: NavigationRegion3D
@export var economy: Economy
@export var run_state: RunState
@export var keep: Node3D
## Distance from tray centre to the inside face of a rim.
@export var tray_half := 5.6
@export var grid := 0.5
## Nothing may be placed within this of the keep's centre. A keep annex is the one
## exception -- it is bolted onto the keep -- and a gate is the other, once an annex
## has opened a slot for it.
@export var keep_clearance := 1.6
## How close a sally-port gate may come to the keep's centre once an upgrade has
## opened a slot for it. Under this it would be standing inside the keep's own
## walls, which the overlap test cannot catch: the keep is not a Structure.
@export var keep_gate_inner := 1.1

@export_group("Ghost")
@export var ghost_ok := Color(0.3, 0.8, 0.5, 0.45)
## Legal, but it walls the kingdom in. The raiders will come through the wall
## instead of round it, which is a real strategy and an expensive one.
@export var ghost_warn := Color(0.95, 0.72, 0.2, 0.45)
@export var ghost_bad := Color(0.85, 0.3, 0.2, 0.4)

@export_group("Sealing the keep")
## Off skips the enclosure test entirely.
@export var seal_check := true
## The cell the tray is rasterised into for the test. Smaller is more exact and
## costs cells squared; 0.3 puts about 1400 of them on the tray, which is a
## rounding error twice a frame.
@export_range(0.1, 1.0, 0.05) var seal_cell := 0.3
## Footprints are grown by this before the flood fill, because a gap narrower than
## an agent is not a gap. Matches the navmesh agent_radius in tools/build_main.gd.
@export_range(0.0, 1.0, 0.05) var seal_agent_radius := 0.25

var selected := 0
var active := false
## Set every frame the ghost is up: why the placement is refused, or what is odd
## about it. Empty when there is nothing to say.
var placement_hint := ""

var _ghost_root: Node3D
var _ghost_material := StandardMaterial3D.new()
var _ghost_type: StructureType
var _valid := false
var _spot := Vector3.ZERO

## Rasterised tray for the seal check. Members rather than locals passed around,
## because a PackedArray handed to a helper is a copy-on-write value and mutating
## it there is the sort of thing that works until it does not.
var _seal_grid := PackedByteArray()
var _seal_seen := PackedByteArray()
var _seal_queue := PackedInt32Array()
var _seal_side := 0
## The answer is the same for every caller within one frame, so it is computed once.
var _seal_fresh := false
var _seal := Seal.OPEN


func _ready() -> void:
    _ghost_material.albedo_color = ghost_ok
    _ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    _ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    _ghost_root = Node3D.new()
    _ghost_root.name = "Ghost"
    _ghost_root.visible = false
    add_child(_ghost_root)


func current() -> StructureType:
    if palette.is_empty():
        return null
    return palette[clampi(selected, 0, palette.size() - 1)]


func select(index: int) -> void:
    if palette.is_empty():
        return
    selected = clampi(index, 0, palette.size() - 1)
    palette_changed.emit(selected)


## The number keys only reach nine and the catalogue is eleven kinds deep, so the
## wheel is the way to the rest of a fully drafted palette. It needs no entry in the
## input map, which is what keeps adding a structure from waiting on a keybinding.
func cycle(step: int) -> void:
    if palette.is_empty():
        return
    selected = posmod(selected + step, palette.size())
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
    if click == null or not click.pressed:
        return
    match click.button_index:
        MOUSE_BUTTON_WHEEL_DOWN:
            cycle(1)
            get_viewport().set_input_as_handled()
        MOUSE_BUTTON_WHEEL_UP:
            cycle(-1)
            get_viewport().set_input_as_handled()
        MOUSE_BUTTON_LEFT:
            if _valid:
                _place()
                get_viewport().set_input_as_handled()


func _process(_dt: float) -> void:
    # One seal answer per frame, whoever asks for it.
    _seal_fresh = false
    active = run_state != null and run_state.phase == RunState.Phase.PREP
    if not active or current() == null:
        _ghost_root.visible = false
        _set_hint("")
        return
    var hit: Variant = _mouse_on_tray()
    if hit == null:
        _ghost_root.visible = false
        _set_hint("")
        return

    var type := current()
    _spot = _snap(hit)

    var problem := _placement_problem(_spot, type)
    if problem.is_empty() and economy != null and not economy.can_afford(type.cost):
        problem = "%d gold short" % (type.cost - economy.gold)
    _valid = problem.is_empty()

    var colour := ghost_bad
    if _valid:
        # Legal but it walls the kingdom in. Amber rather than red on purpose: with
        # breakable walls that is a real (expensive) strategy, not a mistake.
        if _seal_state(_spot, type) == Seal.BREAKABLE:
            colour = ghost_warn
            problem = "this seals the keep -- raiders will break through instead"
        else:
            colour = ghost_ok
    _set_hint(problem)

    _rebuild_ghost(type)
    _ghost_root.position = _spot
    _ghost_root.rotation = Structure.node_rotation(type)
    _ghost_material.albedo_color = colour
    _ghost_root.visible = true


func _set_hint(text: String) -> void:
    if placement_hint == text:
        return
    placement_hint = text
    placement_hint_changed.emit(text)


## The ghost is the type's own slab list, so what the player drags is the shape that
## lands. Rebuilt only when the selection changes.
func _rebuild_ghost(type: StructureType) -> void:
    if _ghost_type == type:
        return
    _ghost_type = type
    for child in _ghost_root.get_children():
        _ghost_root.remove_child(child)
        child.queue_free()
    for xf in Structure.pieces_for(type):
        var mesh := BoxMesh.new()
        mesh.size = Structure.piece_size(xf)
        var mi := MeshInstance3D.new()
        mi.mesh = mesh
        mi.transform = Structure.piece_pose(xf)
        mi.material_override = _ghost_material
        _ghost_root.add_child(mi)


func _place() -> void:
    var type := current()
    # Re-asked rather than trusting the _valid the ghost left behind: the answer is
    # memoised for the frame, so this costs nothing, and it is the guard that stops
    # gold being spent on a placement that stopped being legal.
    if type == null or not _is_placeable(_spot, type):
        return
    if economy == null or not economy.spend(type.cost):
        return
    var s := Structure.new()
    # Positioned BEFORE it enters the tree. Physics interpolation is on
    # project-wide and the automatic reset a node gets on entering captures
    # whatever transform it holds at that moment -- so placing after add_child()
    # leaves the wall interpolating out of the tray centre for one frame.
    s.position = structures_root.to_local(_spot)
    structures_root.add_child(s)
    s.configure(type)
    # configure() tilts a ramp and offsets the meshes and shapes it just added, all
    # of it after the node is already in the tree, so the interpolation history
    # has to be refreshed once more. Recursive, which is what covers the children.
    s.reset_physics_interpolation()
    s.destroyed.connect(_on_structure_destroyed)
    _rebake()
    structures_changed.emit()


## A wall the raiders broke changes the base value, and therefore the next wave's
## budget, so the readouts have to hear about it the same way they hear about a
## purchase. The rebake is the structure's own job -- it can only happen after the
## node has left the tray.
func _on_structure_destroyed(_s: Structure) -> void:
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
    return _placement_problem(at, type).is_empty()


## Empty when it may be built here; otherwise the reason, in the words the player
## would use. One string rather than a bool because the ghost turning red without
## saying why is how a player learns to distrust it.
func _placement_problem(at: Vector3, type: StructureType) -> String:
    if type == null:
        return "nothing selected"
    var half_x := type.footprint.x * 0.5
    var half_z := type.footprint.z * 0.5
    if absf(at.x) + half_x > tray_half or absf(at.z) + half_z > tray_half:
        return "off the tray"

    var to_keep := INF
    if keep:
        to_keep = Vector2(at.x - keep.global_position.x, at.z - keep.global_position.z).length()
    var band := type.keep_annex_band
    if band.y > 0.0:
        # An annex is bolted ONTO the keep. It is the one kind exempt from the
        # clearance ring, and in exchange it may not be built anywhere else.
        if to_keep > band.y:
            return "must be built against the keep"
        if to_keep < band.x:
            return "too close to the keep's own walls"
    elif to_keep < keep_clearance:
        # The sally port. A gate may stand inside the ring once an upgrade has
        # opened a slot, but never inside the keep's own walls.
        if not (to_keep >= keep_gate_inner and _has_free_gate_slot(type)):
            return "too close to the keep"

    if structures_root:
        for child in structures_root.get_children():
            var other := child as Structure
            if other == null or other.type == null or not other.is_alive():
                continue
            var gap_x := absf(at.x - other.global_position.x)
            var gap_z := absf(at.z - other.global_position.z)
            if gap_x < half_x + other.type.footprint.x * 0.5 - 0.01 \
                    and gap_z < half_z + other.type.footprint.z * 0.5 - 0.01:
                return "overlaps the %s" % other.type.display_name.to_lower()

    # The only placement the game refuses on grounds of strategy, and it refuses it
    # to stop a SOFT LOCK rather than to police the player -- see _seal_state().
    if _seal_state(at, type) == Seal.SOLID:
        return "this would seal the keep behind walls nothing can break"
    return ""


## Keep upgrades open a sally port: while one stands, a gate may be built inside the
## keep's clearance ring, one per slot granted. It is what makes the upgrade more
## than hit points -- a door the player opens with the same key that opens every
## other gate, right where the fighting is.
func _has_free_gate_slot(type: StructureType) -> bool:
    if type == null or type.kind != StructureType.Kind.GATE or structures_root == null:
        return false
    var slots := 0
    var used := 0
    for child in structures_root.get_children():
        var s := child as Structure
        if s == null or s.type == null or not s.is_alive():
            continue
        slots += s.gate_slots()
        if s.is_gate() and _inside_clearance(s.global_position):
            used += 1
    return used < slots


func _inside_clearance(at: Vector3) -> bool:
    if keep == null:
        return false
    return Vector2(at.x - keep.global_position.x, at.z - keep.global_position.z).length() \
        < keep_clearance


# --- does this placement wall the kingdom in? ---------------------------------

## Ben walled his keep in and the raiders stood at the wall, so this has to be
## answered honestly rather than silently forbidden. There are three answers and
## only one of them is a refusal:
##
##  OPEN       a raider can still walk to the keep. Nothing to say.
##  BREAKABLE  the ring is closed, but something in it has hit points. LEGAL, and
##             the ghost goes amber: the raiders will come through the wall instead
##             of round it, which is a real strategy and an expensive one.
##  SOLID      the ring is closed by things nothing can break -- quarries, houses.
##             REFUSED, because it is not a strategy, it is a soft lock: the raiders
##             can never reach the keep, the wave can never clear, and the run stops
##             without ever saying so.
##
## Two flood fills from the rim over a rasterised tray: the first with every
## footprint blocking, the second with the breakable ones opened up. Cheap enough to
## run twice a frame -- about 1400 cells at the shipped cell size.
func _seal_state(at: Vector3, type: StructureType) -> int:
    if not seal_check or keep == null or structures_root == null or type == null:
        return Seal.OPEN
    if _seal_fresh:
        return _seal
    _seal_fresh = true
    _seal = _compute_seal(at, type)
    return _seal


func _compute_seal(at: Vector3, type: StructureType) -> int:
    _seal_side = int(ceil(tray_half * 2.0 / seal_cell))
    if _seal_side < 3:
        return Seal.OPEN
    _seal_grid.resize(_seal_side * _seal_side)
    _seal_grid.fill(0)

    # 1 = breakable, 2 = nothing gets through this. A hard blocker always wins the
    # cell, so the second fill cannot walk through a quarry because a wall happened
    # to be stamped over it afterwards.
    for child in structures_root.get_children():
        var s := child as Structure
        if s == null or s.type == null or not s.type.solid or not s.is_alive():
            continue
        _stamp(s.global_position, s.type.footprint, 1 if s.is_destructible() else 2)
    if type.solid:
        _stamp(at, type.footprint, 1 if type.max_hp > 0 else 2)

    if _rim_reaches_keep(1):
        return Seal.OPEN
    if _rim_reaches_keep(2):
        return Seal.BREAKABLE
    return Seal.SOLID


## Marks every cell a footprint covers, grown by the agent radius on all sides.
func _stamp(centre: Vector3, footprint: Vector3, value: int) -> void:
    var pad := seal_agent_radius
    var min_x := _cell(centre.x - footprint.x * 0.5 - pad)
    var max_x := _cell(centre.x + footprint.x * 0.5 + pad)
    var min_z := _cell(centre.z - footprint.z * 0.5 - pad)
    var max_z := _cell(centre.z + footprint.z * 0.5 + pad)
    for iz in range(min_z, max_z + 1):
        var row := iz * _seal_side
        for ix in range(min_x, max_x + 1):
            if _seal_grid[row + ix] < value:
                _seal_grid[row + ix] = value


func _cell(world: float) -> int:
    return clampi(int(floor((world + tray_half) / seal_cell)), 0, _seal_side - 1)


## Flood in from every edge cell. `blocks_at` is the grid value that stops the
## fill -- 1 counts breakable walls as walls, 2 walks straight through them.
## Reaching the keep's clearance ring is reaching the keep: nothing may be built
## inside it, so a raider that gets that far is at the door.
func _rim_reaches_keep(blocks_at: int) -> bool:
    var n := _seal_side
    var cells := n * n
    _seal_seen.resize(cells)
    _seal_seen.fill(0)
    _seal_queue.clear()

    for i in n:
        _seed(i, blocks_at)
        _seed((n - 1) * n + i, blocks_at)
        _seed(i * n, blocks_at)
        _seed(i * n + n - 1, blocks_at)

    var reach := keep_clearance + seal_cell
    var kx := keep.global_position.x
    var kz := keep.global_position.z
    var head := 0
    while head < _seal_queue.size():
        var i := _seal_queue[head]
        head += 1
        var ix := i % n
        var iz := i / n
        var wx := -tray_half + (float(ix) + 0.5) * seal_cell
        var wz := -tray_half + (float(iz) + 0.5) * seal_cell
        if Vector2(wx - kx, wz - kz).length() <= reach:
            return true
        if ix > 0 and _seal_seen[i - 1] == 0 and _seal_grid[i - 1] < blocks_at:
            _seal_seen[i - 1] = 1
            _seal_queue.append(i - 1)
        if ix < n - 1 and _seal_seen[i + 1] == 0 and _seal_grid[i + 1] < blocks_at:
            _seal_seen[i + 1] = 1
            _seal_queue.append(i + 1)
        if iz > 0 and _seal_seen[i - n] == 0 and _seal_grid[i - n] < blocks_at:
            _seal_seen[i - n] = 1
            _seal_queue.append(i - n)
        if iz < n - 1 and _seal_seen[i + n] == 0 and _seal_grid[i + n] < blocks_at:
            _seal_seen[i + n] = 1
            _seal_queue.append(i + n)
    return false


func _seed(index: int, blocks_at: int) -> void:
    if _seal_seen[index] == 0 and _seal_grid[index] < blocks_at:
        _seal_seen[index] = 1
        _seal_queue.append(index)
