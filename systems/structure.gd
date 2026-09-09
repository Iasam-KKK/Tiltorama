extends StaticBody3D
class_name Structure

## One node for every structure kind; the behaviour that differs is small enough
## that a switch beats eleven scripts. Driven entirely by its StructureType.
##
## A structure is built from SLABS. Most kinds are one -- the box this file has
## always made -- but a funnel is two walls leaning in and a half-pipe is a short
## arc of banked ones, so the geometry is a list rather than a single size. The list
## is produced by the static pieces_for() below, which is also what the build ghost
## draws: the ghost and the thing it promises come out of one function, so they
## cannot disagree.
##
## Structures have hit points now. Raiders that cannot route to the keep break
## through instead of standing at a wall, which is the entire reason this file
## grew -- see take_damage().

signal minted(count: int)
## Something the spikes are lethal to walked into them. The kill belongs to the
## agent, not to the terrain, so this is a report and not a command.
signal impaled(body: Node3D)
## Hit but still standing.
signal damaged(structure: Structure, hp: int, max_hp: int)
## Emitted while it is STILL on the tray and still knows its type, so a listener
## wanting rubble has both the kind and the place.
signal destroyed(structure: Structure)

var type: StructureType
## Counts down from type.max_hp. Meaningless while max_hp is 0, which is how a
## quarry says it cannot be knocked down.
var hp := 0
## Quarter turns about Y the player placed it at. A funnel that can only ever open
## one way is not a tool, so the whole catalogue turns -- and so a ramp can be made
## to drop in any of four directions instead of always toward the same rim.
var yaw_steps := 0

## One CollisionShape3D per slab. Empty for a kind whose type is not `solid`.
var _shapes: Array[CollisionShape3D] = []
## Everything drawn, under one pivot so the damage lean can tip the art without
## tipping the colliders with it.
var _visuals: Node3D
var _meshes: Array[MeshInstance3D] = []
var _hazard: Area3D
var _damage_overlay: StandardMaterial3D
var _open := false
## Broken, and on its way off the tray. Read by base_value() and is_alive() so the
## frame between the killing blow and the deferred removal does not count it.
var _dying := false
var _rng := RandomNumberGenerator.new()


func configure(structure_type: StructureType) -> void:
    type = structure_type
    collision_layer = 1
    collision_mask = 1
    _open = false
    _dying = false
    _shapes.clear()
    _meshes.clear()
    _hazard = null
    _damage_overlay = null
    hp = type.max_hp

    for child in get_children():
        child.queue_free()

    _visuals = Node3D.new()
    _visuals.name = "Visuals"
    add_child(_visuals)

    var pieces := pieces_for(type)

    if type.solid:
        for xf in pieces:
            var box := BoxShape3D.new()
            box.size = piece_size(xf)
            var cs := CollisionShape3D.new()
            cs.shape = box
            cs.transform = piece_pose(xf)
            add_child(cs)
            _shapes.append(cs)

    if type.model:
        var art := type.model.instantiate()
        _visuals.add_child(art)
    else:
        # One material for the whole structure: every slab of a funnel is the same
        # funnel, and the damage overlay is applied per mesh anyway.
        var mat := StandardMaterial3D.new()
        mat.albedo_color = type.colour
        mat.roughness = 1.0
        mat.metallic = 0.0
        for xf in pieces:
            var mesh := BoxMesh.new()
            mesh.size = piece_size(xf)
            var mi := MeshInstance3D.new()
            mi.mesh = mesh
            mi.transform = piece_pose(xf)
            mi.material_override = mat
            _visuals.add_child(mi)
    _collect_meshes(_visuals)

    if type.kind == StructureType.Kind.BUMPER:
        var bouncy := PhysicsMaterial.new()
        bouncy.bounce = type.bounce
        bouncy.friction = 0.2
        physics_material_override = bouncy
    elif type.surface_friction >= 0.0:
        var slick := PhysicsMaterial.new()
        slick.friction = type.surface_friction
        slick.bounce = 0.05
        physics_material_override = slick

    if type.kind == StructureType.Kind.RIM_SPIKES:
        _build_hazard()

    rotation = node_rotation(type)


# --- geometry, shared with the build ghost ------------------------------------

## The slabs a type is built from, as transforms whose BASIS CARRIES THE SIZE as its
## scale: one typed array then describes both the pose and the extent of every slab,
## and piece_size() / piece_pose() take it apart again. Static because BuildSystem
## draws the same list as the ghost, and a ghost that is a different shape from what
## lands is the kind of lie Task C is about.
static func pieces_for(type_res: StructureType) -> Array[Transform3D]:
    var out: Array[Transform3D] = []
    if type_res == null:
        return out
    match type_res.kind:
        StructureType.Kind.FUNNEL:
            return _funnel_pieces(type_res)
        StructureType.Kind.HALF_PIPE:
            return _half_pipe_pieces(type_res)
        StructureType.Kind.RIM_SPIKES:
            return _spike_pieces(type_res)
        StructureType.Kind.RAMP:
            return _ramp_pieces(type_res)
    var size := type_res.footprint
    out.append(_piece(size, Basis.IDENTITY, Vector3(0.0, size.y * 0.5, 0.0)))
    return out


static func piece_size(xf: Transform3D) -> Vector3:
    return xf.basis.get_scale()


static func piece_pose(xf: Transform3D) -> Transform3D:
    return Transform3D(xf.basis.orthonormalized(), xf.origin)


## The tilt configure() puts on the NODE rather than on a slab. Static so the ghost
## can strike the same pose without instancing a structure.
static func node_rotation(type_res: StructureType) -> Vector3:
    # Nothing tilts the node any more. The ramp used to: the whole slab was rotated
    # about the node origin, which swung its low END up into the air and left a face
    # a third of a metre tall for a 0.22 m marble to run into. The slope now lives in
    # the piece itself -- see _ramp_pieces -- so the leading edge is at zero.
    return Vector3.ZERO


static func _piece(size: Vector3, basis: Basis, origin: Vector3) -> Transform3D:
    # basis * from_scale, never Basis.scaled(): scaled() applies the scale on the
    # outside, and get_scale()/orthonormalized() can only take apart rotation * scale.
    return Transform3D(basis * Basis.from_scale(size), origin)


## Two walls leaning in from the mouth (-Z) to the throat (+Z). A spread of rollers
## that crosses the mouth leaves the throat in a line.
static func _funnel_pieces(t: StructureType) -> Array[Transform3D]:
    var f := t.footprint
    var mouth := maxf(f.x, 0.1)
    var throat := clampf(t.throat_width, 0.05, mouth)
    var depth := maxf(f.z, 0.1)
    var inset := (mouth - throat) * 0.5
    var length := sqrt(depth * depth + inset * inset)
    # The +X wall runs from (mouth/2, -depth/2) to (throat/2, +depth/2), so its
    # local +Z has to point along (-inset, 0, depth). The -X wall is its mirror.
    var yaw := atan2(-inset, depth)
    var thickness := maxf(t.wall_thickness, 0.05)
    var slab := Vector3(thickness, f.y, length)
    var x := (mouth + throat) * 0.25
    var y := f.y * 0.5
    var out: Array[Transform3D] = []
    out.append(_piece(slab, Basis(Vector3.UP, yaw), Vector3(x, y, 0.0)))
    out.append(_piece(slab, Basis(Vector3.UP, -yaw), Vector3(-x, y, 0.0)))
    return out


## An arc of slabs, each rolled inward about its own tangent. The bank is what lets
## a roller keep its speed through the turn: a vertical wall spends the momentum on
## the impact, a leaning one redirects it.
## One slab, tilted along its own length and sunk so the TOP FACE of its low end
## sits exactly on the tray. That is the whole fix: a roller meets the surface at
## zero height and rolls on, instead of meeting the slab's end grain and stopping.
## The underside runs below the tray and is buried in the 0.6 m slab.
static func _ramp_pieces(t: StructureType) -> Array[Transform3D]:
    var f := t.footprint
    var run := maxf(f.z, 0.01)
    var rise := maxf(t.drop, 0.0)
    var theta := atan2(rise, run)
    # The slab is longer than the footprint by exactly the slope's hypotenuse, so the
    # ramp still occupies `run` metres of tray once it is tilted.
    var slope_len := sqrt(run * run + rise * rise)
    var thick := maxf(f.y, 0.05)
    # Top face low corner at y = 0; the high end then lands at exactly `rise`.
    var y := rise * 0.5 - thick * 0.5 * cos(theta)
    return [_piece(Vector3(f.x, thick, slope_len),
        Basis.from_euler(Vector3(theta, 0.0, 0.0)), Vector3(0.0, y, 0.0))]


static func _half_pipe_pieces(t: StructureType) -> Array[Transform3D]:
    var f := t.footprint
    var segments := clampi(t.arc_segments, 1, 16)
    var span := deg_to_rad(t.arc_deg)
    var radius := maxf(t.arc_radius, 0.1)
    var bank := deg_to_rad(t.bank_deg)
    var step := span / float(segments)
    # Chord of one segment, overlapped a little so the slabs leave no lip between
    # them for a roller to catch on.
    var chord := 2.0 * radius * sin(step * 0.5) * 1.08
    var thickness := maxf(t.wall_thickness, 0.05)
    # Measured from the MIDDLE of the arc, so the ghost sits where the wall will be
    # rather than where its imaginary centre of curvature is.
    var mid := span * 0.5
    var origin := -Vector3(cos(mid), 0.0, sin(mid)) * radius
    # Banking lifts the outer edge and drops the inner one; this keeps the low edge
    # buried in the tray rather than hovering over it.
    var y := f.y * 0.5 * cos(bank)
    var out: Array[Transform3D] = []
    for i in segments:
        var a := step * (float(i) + 0.5)
        var radial := Vector3(cos(a), 0.0, sin(a))
        var tangent := Vector3(-sin(a), 0.0, cos(a))
        # Columns x, y, z. Rotating about the tangent (the slab's own length axis)
        # by a POSITIVE bank leans the top toward -radial, which is inward.
        var basis := Basis(radial, Vector3.UP, tangent).rotated(tangent, bank)
        out.append(_piece(Vector3(thickness, f.y, chord), basis,
            origin + radial * radius + Vector3(0.0, y, 0.0)))
    return out


## A row of teeth rather than one more low wall, so the strip reads as a hazard from
## above. Visual only: spikes are not solid, and the lethal volume is one box over
## the whole footprint so nothing can walk between the teeth and live.
static func _spike_pieces(t: StructureType) -> Array[Transform3D]:
    var f := t.footprint
    var tooth := maxf(t.wall_thickness, 0.05)
    var count := maxi(int(round(f.x / (tooth * 2.0))), 1)
    var step := f.x / float(count)
    var out: Array[Transform3D] = []
    for i in count:
        var x := -f.x * 0.5 + step * (float(i) + 0.5)
        out.append(_piece(Vector3(tooth, f.y, tooth), Basis.IDENTITY,
            Vector3(x, f.y * 0.5, 0.0)))
    return out


# --- what kind is it ----------------------------------------------------------

func base_value() -> int:
    if type == null or _dying:
        return 0
    return type.base_value


func is_gate() -> bool:
    return type != null and type.kind == StructureType.Kind.GATE


func is_quarry() -> bool:
    return type != null and type.kind == StructureType.Kind.QUARRY


## Houses are what VillagerPool bills beds against. It matches on `id` today
## because the HOUSE kind did not exist when it was written; this is the check it
## should move to, because it survives a house being re-skinned under a new id.
func is_house() -> bool:
    return type != null and type.kind == StructureType.Kind.HOUSE


## A keep annex: exempt from the keep's clearance ring, and only buildable inside
## the band its type declares.
func is_annex() -> bool:
    return type != null and type.keep_annex_band.y > 0.0


## Gates this structure lets the player build inside the keep's clearance ring.
func gate_slots() -> int:
    if type == null or _dying:
        return 0
    return type.gate_slots


## Gates hold a stockpile until the player opens them, which is what turns a tilt
## into a shot.
func set_open(open: bool) -> void:
    if not is_gate() or _open == open or _dying:
        return
    _open = open
    for cs in _shapes:
        cs.set_deferred(&"disabled", open)
    if _visuals:
        _visuals.visible = not open


func mint() -> int:
    if not is_quarry():
        return 0
    minted.emit(type.mint_per_wave)
    return type.mint_per_wave


# --- taking a beating ---------------------------------------------------------

## THE ENTRY POINT RAIDERS CALL:  structure.take_damage(amount: int) -> void
##
## Safe on anything. A kind with no hit points -- a quarry, a house -- swallows the
## blow and stands, so a pathing fix that swings at whatever is in the way can never
## quietly delete the economy. Whether it landed is readable from is_alive(), from
## hp_ratio(), and from the `damaged` / `destroyed` signals; the return value is
## void so the signature matches Keep.take_damage(), which is the other thing on the
## tray a raider hits.
func take_damage(amount: int) -> void:
    if amount <= 0 or not is_destructible():
        return
    hp = maxi(0, hp - amount)
    _show_damage()
    damaged.emit(self, hp, type.max_hp)
    if hp == 0:
        _destroy()


## Can it be broken at all? False for a kind with no hit points and for one already
## on its way off the tray.
func is_destructible() -> bool:
    return type != null and type.max_hp > 0 and not _dying


## Still standing. An indestructible kind is always alive; a broken one is not,
## from the killing blow onward rather than from the deferred removal.
func is_alive() -> bool:
    if _dying:
        return false
    return type == null or type.max_hp <= 0 or hp > 0


## 1.0 at full health, 0.0 at none. Indestructible kinds read 1.0 forever.
func hp_ratio() -> float:
    if type == null or type.max_hp <= 0:
        return 1.0
    return clampf(float(hp) / float(type.max_hp), 0.0, 1.0)


func _show_damage() -> void:
    if type == null or type.max_hp <= 0 or _visuals == null:
        return
    var wear := 1.0 - hp_ratio()
    if _damage_overlay == null:
        _damage_overlay = StandardMaterial3D.new()
        _damage_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        _damage_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        # An OVERLAY, not a tint on the albedo: the kinds that wear a GLB get their
        # materials out of the imported scene, and those instances are shared, so
        # writing one would stain every wall on the tray at once.
        for mi in _meshes:
            mi.material_overlay = _damage_overlay
    var stain := type.damage_colour
    stain.a = wear * type.damage_tint
    _damage_overlay.albedo_color = stain
    # Only the art leans and settles. The colliders stay square -- see
    # StructureType.damage_lean_deg.
    _visuals.rotation.z = deg_to_rad(type.damage_lean_deg) * wear
    _visuals.position.y = -type.damage_sink * wear


func _destroy() -> void:
    if _dying:
        return
    _dying = true
    destroyed.emit(self)
    # Collision off on the deferred queue: take_damage() is called from inside the
    # attacker's own physics step, and pulling a shape out from under the server
    # mid-step is how Jolt is made to fall over. Deferred is still the same frame,
    # so the raider that broke it cannot walk into it again.
    for cs in _shapes:
        cs.set_deferred(&"disabled", true)
    if _hazard:
        _hazard.set_deferred(&"monitoring", false)
    _leave_tray.call_deferred()


func _leave_tray() -> void:
    # Read BEFORE the node is unparented; afterwards there is no tree to walk up.
    var region := _nav_region()
    var parent := get_parent()
    if parent:
        # Removed before it is freed, so the base value RunState walks and the child
        # count AudioDirector caches are right on the very next frame rather than
        # whenever queue_free() gets round to it.
        parent.remove_child(self)
    # After the removal, or the bake still finds the wall that just fell -- and the
    # raiders that broke it would path around a hole that is no longer there.
    if region and region.navigation_mesh:
        region.bake_navigation_mesh(false)
    queue_free()


## The region the tray is baked into, found by walking up: Structures is a child of
## NavRegion, so a broken wall triggers its own rebake and nobody has to wire a
## reference into every structure that gets placed. Null when there is none, which
## is the headless-rig case.
func _nav_region() -> NavigationRegion3D:
    var n := get_parent()
    while n:
        var region := n as NavigationRegion3D
        if region:
            return region
        n = n.get_parent()
    return null


# --- rim spikes ---------------------------------------------------------------

## One lethal box over the whole footprint. Not one per tooth: gaps between teeth
## would be exactly the safe lane a raider is best at finding.
func _build_hazard() -> void:
    var f := type.footprint
    var box := BoxShape3D.new()
    box.size = f + Vector3.ONE * type.hazard_margin
    var cs := CollisionShape3D.new()
    cs.shape = box
    cs.position = Vector3(0.0, f.y * 0.5, 0.0)

    _hazard = Area3D.new()
    _hazard.name = "Spikes"
    _hazard.monitoring = true
    _hazard.monitorable = false
    _hazard.collision_layer = 0
    _hazard.collision_mask = type.lethal_layers
    _hazard.add_child(cs)
    _hazard.body_entered.connect(_on_hazard_entered)
    add_child(_hazard)


func _on_hazard_entered(body: Node3D) -> void:
    if _dying or body == null:
        return
    impaled.emit(body)
    # Duck-typed and guarded: spikes are inert rather than broken against a build
    # where Raider.impale() / Villager.impale() have not landed yet.
    if body.has_method(&"impale"):
        body.call(&"impale", self)


# --- return chute -------------------------------------------------------------

## Did a roller that left the tray here leave it over THIS chute's corner? Measured
## across the tray only: by the time the kill volume sees a roller it is metres
## below the chute.
func covers(point: Vector3) -> bool:
    if type == null or _dying or type.kind != StructureType.Kind.RETURN_CHUTE:
        return false
    return Vector2(point.x - global_position.x, point.z - global_position.z).length() \
        <= type.catch_radius


## The chute's share. Rolled per roller, so recovery is a rate and not a promise.
func rolls_recovery() -> bool:
    return type != null and _rng.randf() < type.recovery_chance


## Where a recovered roller is poured back in: above the chute mouth, so it rolls
## out onto the tray instead of being teleported into the middle of the kingdom.
func return_point() -> Vector3:
    var lift := type.return_height if type else 1.2
    return global_position + Vector3(0.0, lift, 0.0)


## One call for the kill volume: the point a roller lost at `at` comes back onto the
## tray at, or null when no chute covered that corner or its roll came up short.
##
## Static and handed the root rather than wired chute by chute, because the volume
## sees a roller once, on the frame it falls, and has no business holding a
## reference to every chute that has ever been built.
static func reclaim_point(structures_root: Node, at: Vector3) -> Variant:
    if structures_root == null:
        return null
    for child in structures_root.get_children():
        var s := child as Structure
        if s == null or not s.covers(at):
            continue
        if s.rolls_recovery():
            return s.return_point()
        # A chute that covered the corner and missed its roll has answered for that
        # roller. No second chute gets to re-roll the same marble.
        return null
    return null


# --- internals ----------------------------------------------------------------

## Every MeshInstance3D under the art pivot, GLB children included, so the damage
## overlay reaches an imported model and not just the primitives.
func _collect_meshes(node: Node) -> void:
    for child in node.get_children():
        var mi := child as MeshInstance3D
        if mi:
            _meshes.append(mi)
        _collect_meshes(child)
