extends CharacterBody3D
class_name Villager

## The people the kingdom is for. Same agent shape as a Raider -- read the tilt as
## an effective slope, slide past your footing with hysteresis, ghost through the
## 0.4 m rim lip so you can actually leave the tray -- but with footing 8 degrees
## instead of 12, no combat, and a "whoa!" on the way down.
##
## Deliberately a SIBLING of Raider, not a subclass:
##   * it carries a VillagerType, and GDScript will not let a subclass narrow the
##     inherited `type: RaiderType` member;
##   * `other as Raider` is how RollerPool routes contacts to RaiderPool, and a
##     Villager passing that cast would quietly enter the raider pool bookkeeping;
##   * CLIMB and ATTACK are dead states here and IDLE/WANDER are new ones, so most
##     of the state machine would have been overridden anyway;
##   * raider.gd is owned by another agent, and inheriting would couple this file
##     to edits nobody here can see.
## The cost is the duplicated slide/rim-tip block below, which is the honest price.

signal lost(villager: Villager, fell: bool)
signal slipped(at: Vector3)

enum State { IDLE, WANDER, SLIDE, TUMBLE, DEAD }

const GRAVITY := 9.8
## Slope must drop this far under footing before a slipping villager stands up
## again, so they do not stutter on the threshold.
const HYSTERESIS_DEG := 2.0
## Anything below the tray by this much is gone. Matches the raiders.
const FELL_BELOW := -3.0
## Below this he is clear of the tray and its rims, so the collider he was ghosting
## through them with is handed back. An Area3D cannot see a body whose only shape is
## disabled, so without this the kill volume never sees a villager go into the sea
## and the loss lands in silence. Matches Raider.CLEAR_OF_TRAY.
const CLEAR_OF_TRAY := -1.5
const TUMBLE_MIN := 0.45
## A slide into a wall above this speed carries them over it.
const VAULT_SPEED := 2.2
const VAULT_LIFT := 3.4
## How hard the rim tip throws them, along the downhill direction.
const RIM_TIP_PUSH := 2.5
## Knockback scale from (roller mass * relative speed) to metres per second.
const KNOCK_SCALE := 0.7
## Must lift them clear of the 0.4 m rim (about 2.8 m/s) or a good hit could never
## put a villager in the sea.
const KNOCK_LIFT := 3.2
## One knock per this many seconds. A roller resting against a villager reports a
## contact every frame, and the local scan and the pool notify can both fire.
const HIT_COOLDOWN := 0.35
## Flat distance at which a stop counts as reached.
const ARRIVE := 0.55
## Give up on a stop that is taking this long; something is in the way.
const WANDER_TIMEOUT := 9.0
## How far a stop has to move before the navigation agent is re-aimed. Re-aiming is
## never free: Godot's NavigationAgent3D.target_position setter does not compare
## against the old value, it always requests a repath, which throws the cached path
## away and turns the next is_target_reachable() into a fresh synchronous
## NavigationServer query -- one per villager per tick, for a doorstep that is not
## going anywhere. Well under path_desired_distance (0.4), so no path is coarser.
const NAV_RETARGET_EPSILON := 0.25
## Capsule detail. They are 0.7 m tall and the camera sits 32 m out, so a smooth
## capsule is triangles nobody can see.
const MESH_SEGMENTS := 8
const MESH_RINGS := 3

## Mesh, collision shape and material are shared per VillagerType, not owned per
## body. The pool reuses one fixed set of bodies and a body may come back as a
## different type, so the cache is keyed by the type resource rather than assuming
## one look per body -- otherwise every single move-in rebuilt a capsule mesh.
## Static: one cache for the whole run, the same approach RollerPool takes with its
## pre-built ladder of sphere meshes and shapes.
static var _shared_meshes := {}
static var _shared_shapes := {}
static var _shared_materials := {}

var type: VillagerType
var state := State.DEAD
var tilt_controller: TiltController
## Distance from tray centre to the inside face of a rim.
var tray_half := 5.6
## Degrees of extra footing granted by tray modifiers. The pool pushes this in
## from Loadout; it is not on VillagerType because it is a run's kit, not a
## designer's number, and every villager on the tray shares it.
var footing_bonus := 0.0

var _agent: NavigationAgent3D
var _mesh: MeshInstance3D
var _shape: CollisionShape3D
var _cry_label: Label3D
## The shared capsule of the CURRENT type. Read for its height; never written to,
## because every other villager of this type is standing on the same resource.
var _capsule: CapsuleShape3D

var _waypoints := PackedVector3Array()
var _destination := Vector3.ZERO
var _dwell := 0.0
var _walked := 0.0
var _tumble_timer := 0.0
var _rim_press := 0.0
var _hit_cooldown := 0.0
var _cry_timer := 0.0
var _nav_warmup := 0
## Where the agent is currently aimed, and whether it has been aimed at all since
## this body was placed, shoved off its path, or the kingdom changed shape.
var _nav_aim := Vector3.ZERO
var _nav_aimed := false
var _ghosting := false


func _ready() -> void:
    # Layer 8 is villagers: their own layer, so rollers can be told to knock them
    # over without also pointing raider logic at them.
    collision_layer = 8
    # World, rollers, and each other so two do not stand in the same square. NOT
    # raiders (layer 4): raiders mask 1|2 and would walk straight through anyway,
    # and a one-way block reads as a bug.
    collision_mask = 1 | 2 | 8
    floor_max_angle = deg_to_rad(50.0)

    # No mesh, shape or material yet: a pooled body has no type until somebody moves
    # in, and everything it wears then comes from the shared per-type cache.
    _mesh = MeshInstance3D.new()
    add_child(_mesh)

    _shape = CollisionShape3D.new()
    add_child(_shape)

    _cry_label = Label3D.new()
    _cry_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    _cry_label.no_depth_test = true
    _cry_label.shaded = false
    _cry_label.font_size = 64
    _cry_label.outline_size = 18
    _cry_label.outline_modulate = Color(0.08, 0.07, 0.06, 1.0)
    _cry_label.modulate = Color(1.0, 0.97, 0.9, 1.0)
    _cry_label.visible = false
    add_child(_cry_label)

    _agent = NavigationAgent3D.new()
    _agent.path_desired_distance = 0.4
    _agent.target_desired_distance = 0.5
    _agent.avoidance_enabled = false
    add_child(_agent)

    set_physics_process(false)


## Called by the pool. `at` is a point on the tray surface, outside the house's
## own collider; the body is lifted half a capsule so it stands on the floor.
func place(villager_type: VillagerType, tilt: TiltController, at: Vector3, points: PackedVector3Array) -> void:
    type = villager_type
    tilt_controller = tilt

    _wear(type)

    _cry_label.pixel_size = type.cry_pixel_size
    _cry_label.position = Vector3(0.0, _capsule.height * 0.5 + 0.5, 0.0)
    _cry_label.visible = false
    _cry_timer = 0.0

    set_waypoints(points)
    _destination = Vector3(at.x, 0.0, at.z)
    _dwell = randf_range(type.dwell_min, type.dwell_max)
    _walked = 0.0
    _rim_press = 0.0
    _tumble_timer = 0.0
    _hit_cooldown = 0.0
    _nav_warmup = 3
    # A recycled body stands somewhere else entirely; whatever its agent was aimed at
    # belonged to whoever used it last.
    _nav_aimed = false
    _set_ghost(false)

    _mesh.rotation = Vector3.ZERO
    global_position = at + Vector3(0.0, _capsule.height * 0.5, 0.0)
    # Physics interpolation is on project-wide: a teleport has to forget where the
    # body was or it smears across the tray for a frame.
    reset_physics_interpolation()
    velocity = Vector3.ZERO
    state = State.IDLE
    visible = true
    set_physics_process(true)


func park() -> void:
    state = State.DEAD
    _set_ghost(false)
    set_physics_process(false)
    visible = false
    if _cry_label:
        _cry_label.visible = false
    velocity = Vector3.ZERO
    global_position = Vector3(0.0, -1000.0, 0.0)
    reset_physics_interpolation()


func is_active() -> bool:
    return state != State.DEAD


## The stops they drift between: house doorsteps and a ring round the keep. The
## pool rebuilds this whenever the kingdom changes shape.
func set_waypoints(points: PackedVector3Array) -> void:
    # The pool re-pushes the same list every quarter second during prep, so compare
    # before reacting. A list that really changed means a house appeared or went, so
    # the navmesh moved under whatever path is cached: drop the aim and let the next
    # step ask again. Otherwise a villager would walk his old path into a new wall.
    if _waypoints != points:
        _nav_aimed = false
    _waypoints = points


## Called by VillagerPool when a roller reports a contact, and by the local scan
## below when nobody is routing contacts here.
func hit_by_roller(roller: RigidBody3D, speed: float) -> void:
    if state == State.DEAD or _hit_cooldown > 0.0 or type == null:
        return
    var momentum := roller.mass * speed
    if momentum < type.knockback_resist:
        return
    _hit_cooldown = HIT_COOLDOWN
    var away := global_position - roller.global_position
    away.y = 0.0
    if away.length() < 0.01:
        away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
    var push := away.normalized() * (momentum / maxf(type.mass, 0.1)) * KNOCK_SCALE
    push.y = KNOCK_LIFT
    _shout()
    # Keep ghosting if this one is already on its way over the edge: a roller
    # catching a villager mid-fall must not hand the collider back and drop him
    # on top of the rim.
    _enter_tumble(push, _ghosting)


func _physics_process(dt: float) -> void:
    if _nav_warmup > 0:
        _nav_warmup -= 1
    _hit_cooldown = maxf(0.0, _hit_cooldown - dt)
    if _cry_timer > 0.0:
        _cry_timer = maxf(0.0, _cry_timer - dt)
        if _cry_timer == 0.0:
            _cry_label.visible = false

    match state:
        State.IDLE:
            _do_idle(dt)
        State.WANDER:
            _do_wander(dt)
        State.SLIDE:
            _do_slide(dt)
        State.TUMBLE:
            _do_tumble(dt)

    if state != State.DEAD and global_position.y < FELL_BELOW:
        _die(true)


func _do_idle(dt: float) -> void:
    if _slipping():
        _enter_slide()
        return
    _dwell -= dt
    if _dwell <= 0.0:
        _pick_destination()
        state = State.WANDER
        return
    velocity.x = 0.0
    velocity.z = 0.0
    velocity.y -= GRAVITY * dt
    move_and_slide()
    _scan_for_rollers()


func _do_wander(dt: float) -> void:
    if _slipping():
        _enter_slide()
        return
    _walked += dt
    if _flat_distance_to(_destination) < ARRIVE or _walked > WANDER_TIMEOUT:
        state = State.IDLE
        _dwell = randf_range(type.dwell_min, type.dwell_max)
        velocity.x = 0.0
        velocity.z = 0.0
        return
    var dir := _desired_direction()
    velocity.x = dir.x * type.speed
    velocity.z = dir.z * type.speed
    velocity.y -= GRAVITY * dt
    move_and_slide()
    _scan_for_rollers()


## Mirrors the raiders, because the rim lip problem is the same one: a sliding body
## cannot climb 0.4 m, so leaning on the rim long enough has to tip it through
## instead, or "tilt too far and they slide off" never happens.
func _do_slide(dt: float) -> void:
    if not _slipping(HYSTERESIS_DEG):
        state = State.IDLE
        _dwell = randf_range(type.dwell_min, type.dwell_max)
        velocity = Vector3.ZERO
        _rim_press = 0.0
        return
    velocity += _gravity_dir() * GRAVITY * dt
    velocity *= maxf(0.0, 1.0 - type.slide_drag * dt)
    var speed_before := Vector2(velocity.x, velocity.z).length()
    move_and_slide()
    _scan_for_rollers()

    var against_wall := _hit_a_wall()
    # Only the rim lets go. Walls, houses, the keep and each other are meant to
    # hold -- and the tip hands out a ghost, so granting one anywhere but the edge
    # would drop the body straight through the tray floor.
    var at_rim := _at_rim()
    if against_wall and at_rim:
        _rim_press += dt
    else:
        _rim_press = 0.0

    if at_rim and (_rim_press >= type.rim_tip_seconds or (against_wall and speed_before > VAULT_SPEED)):
        var downhill := _gravity_dir()
        downhill.y = 0.0
        if downhill.length() < 0.01:
            downhill = Vector3(global_position.x, 0.0, global_position.z)
        # Ghosted on the way over: the outward push is cancelled against the rim
        # every frame while the body is still low enough to touch it, so it goes
        # through instead. Nothing exists outside the tray to collide with.
        _enter_tumble(downhill.normalized() * RIM_TIP_PUSH + Vector3.UP * VAULT_LIFT, true)


func _do_tumble(dt: float) -> void:
    _tumble_timer = maxf(0.0, _tumble_timer - dt)
    velocity += _gravity_dir() * GRAVITY * dt
    move_and_slide()
    _mesh.rotate_x(dt * 11.0)
    # Past the tray, so the ghost has done its job (getting through the rim) and the
    # collider goes back on -- that is the only way the kill volume can see the fall.
    if _ghosting and global_position.y < CLEAR_OF_TRAY:
        _set_ghost(false)
    # A ghosting villager has been tipped off the edge; he falls to the kill check.
    if not _ghosting and _tumble_timer == 0.0 and is_on_floor():
        _mesh.rotation = Vector3.ZERO
        velocity = Vector3.ZERO
        _rim_press = 0.0
        if _slipping():
            state = State.SLIDE
        else:
            state = State.IDLE
            _dwell = randf_range(type.dwell_min, type.dwell_max)


## Sliding and tumbling drag the body off whatever path it was following, so the
## cached path is stale by the time he stands up. Dropping the aim here costs one
## query on the way back into WANDER instead of one every frame he walks.
func _enter_slide() -> void:
    state = State.SLIDE
    _rim_press = 0.0
    _nav_aimed = false
    _shout()
    slipped.emit(global_position)


func _enter_tumble(impulse: Vector3, ghost := false) -> void:
    state = State.TUMBLE
    _tumble_timer = TUMBLE_MIN
    velocity = impulse
    _nav_aimed = false
    _set_ghost(ghost)


func _set_ghost(on: bool) -> void:
    if _ghosting == on:
        return
    _ghosting = on
    if _shape:
        _shape.set_deferred("disabled", on)


## The laugh. Audio is a stub until the day 9 pass, so the "whoa!" is on screen.
func _shout() -> void:
    if type == null or type.cries.is_empty() or _cry_label == null:
        return
    _cry_label.text = type.cries[randi() % type.cries.size()]
    _cry_label.visible = true
    _cry_timer = type.cry_seconds


func _die(fell: bool) -> void:
    if state == State.DEAD:
        return
    state = State.DEAD
    set_physics_process(false)
    if _cry_label:
        _cry_label.visible = false
    lost.emit(self, fell)


## Fallback for when nothing routes roller contacts here. RollerPool reports its
## contacts to one pool today, so until it also reports to VillagerPool this keeps
## rollers able to bowl villagers over. The cooldown makes both paths safe to run
## at once.
func _scan_for_rollers() -> void:
    if _hit_cooldown > 0.0:
        return
    for i in get_slide_collision_count():
        var body := get_slide_collision(i).get_collider() as RigidBody3D
        # Layer 2 is the rollers; a future dynamic prop must not read as a hit.
        if body == null or (body.collision_layer & 2) == 0:
            continue
        hit_by_roller(body, (body.linear_velocity - velocity).length())
        return


func _slipping(margin := 0.0) -> bool:
    if type == null:
        return false
    # Inclusive with a float-error margin, the same as the raiders: a footing that
    # equals a reachable tilt has to actually be reachable.
    return _slope_deg() >= type.footing_deg + footing_bonus - margin - 0.01


## The tray is flat, so the effective slope is simply how far the world is leaning.
func _slope_deg() -> float:
    return tilt_controller.tilt.length() if tilt_controller else 0.0


func _gravity_dir() -> Vector3:
    return tilt_controller.gravity_dir if tilt_controller else Vector3.DOWN


func _flat_distance_to(point: Vector3) -> float:
    return Vector2(point.x - global_position.x, point.z - global_position.z).length()


## True when he is up against the outer lip rather than a built wall.
func _at_rim() -> bool:
    var edge := tray_half - type.radius - 0.08
    return absf(global_position.x) >= edge or absf(global_position.z) >= edge


func _hit_a_wall() -> bool:
    for i in get_slide_collision_count():
        if absf(get_slide_collision(i).get_normal().y) < 0.6:
            return true
    return false


## Somewhere that is not here. Villagers drift between the doorsteps and the keep;
## they never beeline, so the player watches them wander into trouble.
func _pick_destination() -> void:
    _walked = 0.0
    if _waypoints.is_empty():
        _destination = Vector3(global_position.x, 0.0, global_position.z)
        return
    for _attempt in 4:
        var p := _waypoints[randi() % _waypoints.size()]
        if _flat_distance_to(p) > ARRIVE * 2.0:
            _destination = p
            return
    _destination = _waypoints[randi() % _waypoints.size()]


func _desired_direction() -> Vector3:
    var straight := _destination - global_position
    straight.y = 0.0
    var fallback := straight.normalized() if straight.length() > 0.01 else Vector3.ZERO
    if _agent == null or _nav_warmup > 0:
        return fallback
    _aim_nav(_destination)
    if not _agent.is_target_reachable():
        # Unreachable, or the nav map is not warm yet. The straight line is what makes
        # the first frames after a move-in work, so keep it -- and forget the aim, so
        # the moment the map answers he asks again instead of trusting a dead path.
        _nav_aimed = false
        return fallback
    var step := _agent.get_next_path_position() - global_position
    step.y = 0.0
    return step.normalized() if step.length() > 0.05 else fallback


## Aims the agent, but only when that is worth a repath. See NAV_RETARGET_EPSILON.
func _aim_nav(to: Vector3) -> void:
    if _nav_aimed and _nav_aim.distance_squared_to(to) <= NAV_RETARGET_EPSILON * NAV_RETARGET_EPSILON:
        return
    _nav_aim = to
    _nav_aimed = true
    _agent.target_position = to


## Hands this body the look of `t`. Pointer writes only: nothing is allocated after
## the first villager of a type has moved in.
func _wear(t: VillagerType) -> void:
    _capsule = _shared_shape(t)
    _shape.shape = _capsule
    _mesh.mesh = _shared_mesh(t)
    # material_override lives on the MeshInstance3D, and the tumble roll turns that
    # node rather than the mesh, so both resources stay safe to share.
    _mesh.material_override = _shared_material(t)


## A capsule shorter than its own diameter is degenerate, hence the floor.
static func _capsule_height(t: VillagerType) -> float:
    return maxf(t.height, t.radius * 2.0 + 0.01)


static func _shared_shape(t: VillagerType) -> CapsuleShape3D:
    if _shared_shapes.has(t):
        var cached: CapsuleShape3D = _shared_shapes[t]
        return cached
    var s := CapsuleShape3D.new()
    s.radius = t.radius
    s.height = _capsule_height(t)
    _shared_shapes[t] = s
    return s


static func _shared_mesh(t: VillagerType) -> CapsuleMesh:
    if _shared_meshes.has(t):
        var cached: CapsuleMesh = _shared_meshes[t]
        return cached
    var m := CapsuleMesh.new()
    m.radius = t.radius
    m.height = _capsule_height(t)
    m.radial_segments = MESH_SEGMENTS
    m.rings = MESH_RINGS
    _shared_meshes[t] = m
    return m


static func _shared_material(t: VillagerType) -> StandardMaterial3D:
    if _shared_materials.has(t):
        var cached: StandardMaterial3D = _shared_materials[t]
        return cached
    var s := StandardMaterial3D.new()
    s.albedo_color = t.colour
    s.roughness = 1.0
    s.metallic = 0.0
    _shared_materials[t] = s
    return s
