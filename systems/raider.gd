extends CharacterBody3D
class_name Raider

## Raiders walk; they do not roll. They stand up to their footing angle, slip past it,
## tumble when a roller hits them hard enough, and die if they leave the tray.
##
## They read the gravity vector but never write it -- that is TiltController's job.

signal died(raider: Raider, fell: bool)

enum State { CLIMB, WALK, SLIDE, TUMBLE, ATTACK, DEAD }

const GRAVITY := 9.8
## Slope must drop this far below footing before a slipping raider stands up again,
## so they do not stutter on the threshold.
const HYSTERESIS_DEG := 2.0
## A slide into a wall above this speed vaults the raider over it.
const VAULT_SPEED := 2.6
## Leaning them against the rim for this long tips them over it. Speed alone is not
## enough: a 0.4 m lip contains a sliding body, so without this they just stack up
## against the edge and "tilt too far and they slide off" never happens.
const RIM_TIP_SECONDS := 0.7
## How hard the tip throws them, along the downhill direction.
const RIM_TIP_PUSH := 2.5
## Sliding drag. Terminal speed is roughly (9.8 * sin(max tilt)) / this, so it has
## to stay well under the vault threshold or nobody ever leaves the tray.
const SLIDE_DRAG := 0.4
const VAULT_LIFT := 3.4
const TUMBLE_MIN := 0.45
## Anything below the tray by this much is gone.
const FELL_BELOW := -3.0
## Below this the body is clear of the tray and its rims, so the collider it was
## ghosting through them with is handed back. The kill volume is an Area3D, and an
## Area3D cannot see a body whose only shape is disabled: without this a raider
## tipped over the rim falls into the sea silently, and AudioDirector's
## "_on_raider_died skips a fall because the volume already splashed" is a lie.
## The tray floor bottoms out at -0.6, so there is nothing down here to land on.
const CLEAR_OF_TRAY := -1.5
const ATTACK_RANGE := 1.35
## Knockback scale from (roller mass * relative speed) to metres per second.
const KNOCK_SCALE := 0.55
## Must lift the body clear of the 0.4 m rim (about 2.8 m/s) or a good hit can
## never put a raider in the sea.
const KNOCK_LIFT := 3.2
## How far the destination has to move before the navigation agent is re-aimed.
## Re-aiming is never free: Godot's NavigationAgent3D.target_position setter does
## not compare against the old value, it always requests a repath, which throws the
## cached path away and turns the next is_target_reachable() into a fresh
## synchronous NavigationServer query. Sixty raiders walking at a keep that never
## moves was sixty A* queries and sixty path allocations every tick. This sits well
## under path_desired_distance (0.4), so no path is any coarser for it.
const NAV_RETARGET_EPSILON := 0.25
## Capsule detail. These bodies are under a metre tall and the camera sits 32 m out,
## so a smooth capsule is triangles nobody can see -- and there are up to eighty.
const MESH_SEGMENTS := 8
const MESH_RINGS := 3

## Mesh, collision shape and material are shared per RaiderType, not owned per body:
## the pool reuses one fixed set of bodies for DIFFERENT types (a grunt body comes
## back as a shieldwall), so a per-body capsule had to be rebuilt on every launch and
## could never be batched. Keyed by the type resource, so two types that happen to
## share a radius still keep their own colour. Static: one cache for the whole run.
static var _shared_meshes := {}
static var _shared_shapes := {}
static var _shared_materials := {}

var type: RaiderType
var state := State.WALK
var tilt_controller: TiltController
var target: Node3D

var _agent: NavigationAgent3D
var _mesh: MeshInstance3D
var _shape: CollisionShape3D
## The shared capsule of the CURRENT type. Read for its height; never written to,
## because every other raider of this type is standing on the same resource.
var _capsule: CapsuleShape3D

var _tumble_timer := 0.0
var _attack_timer := 0.0
var _nav_warmup := 0
## Where the agent is currently aimed, and whether it has been aimed at all since
## this body was launched or shoved off its path.
var _nav_aim := Vector3.ZERO
var _nav_aimed := false
var _rim_press := 0.0
var _ghosting := false
var tray_half := 5.6
var _climb_from := Vector3.ZERO
var _climb_to := Vector3.ZERO
var _climb_t := 0.0


func _ready() -> void:
    collision_layer = 4
    collision_mask = 1 | 2
    floor_max_angle = deg_to_rad(50.0)

    # No mesh, shape or material yet: a pooled body has no type until it is launched,
    # and everything it wears then comes from the shared per-type cache.
    _mesh = MeshInstance3D.new()
    add_child(_mesh)

    _shape = CollisionShape3D.new()
    add_child(_shape)

    _agent = NavigationAgent3D.new()
    _agent.path_desired_distance = 0.4
    _agent.target_desired_distance = 0.8
    _agent.avoidance_enabled = false
    add_child(_agent)

    set_physics_process(false)


## Called by the pool. `from` is off the rim, `to` is the first foothold on the tray.
func launch(raider_type: RaiderType, tilt: TiltController, keep: Node3D, from: Vector3, to: Vector3) -> void:
    type = raider_type
    tilt_controller = tilt
    target = keep

    _wear(type)

    # `from`/`to` are given on the tray surface; lift them by half a capsule so the
    # body sits on the floor instead of half inside it.
    var lift := Vector3(0.0, _capsule.height * 0.5, 0.0)
    _climb_from = from + lift
    _climb_to = to + lift
    _climb_t = 0.0
    _rim_press = 0.0
    _tumble_timer = 0.0
    _set_ghost(false)
    _attack_timer = type.attack_interval
    _nav_warmup = 3
    # A recycled body is somewhere else entirely; whatever its agent was aimed at
    # belongs to the raider that used it last.
    _nav_aimed = false

    # A raider that died mid-tumble never landed, so _do_tumble never put its roll
    # back. Without this the recycled body climbs the rim lying on its side.
    _mesh.rotation = Vector3.ZERO
    global_position = _climb_from
    reset_physics_interpolation()
    velocity = Vector3.ZERO
    state = State.CLIMB
    visible = true
    set_physics_process(true)


func park() -> void:
    state = State.DEAD
    _set_ghost(false)
    set_physics_process(false)
    visible = false
    velocity = Vector3.ZERO
    global_position = Vector3(0.0, -1000.0, 0.0)
    reset_physics_interpolation()


## Called by RollerPool when a roller makes contact.
func hit_by_roller(roller: RigidBody3D, speed: float) -> void:
    if state == State.DEAD:
        return
    var momentum := roller.mass * speed
    if momentum < type.knockback_resist:
        return
    var away := global_position - roller.global_position
    away.y = 0.0
    if away.length() < 0.01:
        away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
    var push := away.normalized() * (momentum / maxf(type.mass, 0.1)) * KNOCK_SCALE
    push.y = KNOCK_LIFT
    # Keep ghosting if it is already going over the edge: a roller catching a raider
    # mid-fall must not hand its collider back and drop it on the rim.
    _enter_tumble(push, _ghosting)


func _physics_process(dt: float) -> void:
    if _nav_warmup > 0:
        _nav_warmup -= 1

    match state:
        State.CLIMB:
            _do_climb(dt)
        State.WALK:
            _do_walk(dt)
        State.SLIDE:
            _do_slide(dt)
        State.TUMBLE:
            _do_tumble(dt)
        State.ATTACK:
            _do_attack(dt)

    if state != State.DEAD and global_position.y < FELL_BELOW:
        _die(true)


## Coming over the rim. Not navigation -- a scripted 0.7 s haul so the player can see
## which rim the wave chose.
func _do_climb(dt: float) -> void:
    _climb_t = minf(1.0, _climb_t + dt / 0.7)
    var p := _climb_from.lerp(_climb_to, _climb_t)
    p.y += sin(_climb_t * PI) * 0.25
    global_position = p
    if _climb_t >= 1.0:
        state = State.WALK
        velocity = Vector3.ZERO


func _do_walk(dt: float) -> void:
    if _slipping():
        _enter_slide()
        return
    if target and _flat_distance_to_target() < ATTACK_RANGE:
        state = State.ATTACK
        _attack_timer = 0.0
        return
    var dir := _desired_direction()
    velocity.x = dir.x * type.speed
    velocity.z = dir.z * type.speed
    velocity.y -= GRAVITY * dt
    move_and_slide()


func _do_slide(dt: float) -> void:
    if not _slipping(HYSTERESIS_DEG):
        state = State.WALK
        velocity = Vector3.ZERO
        return
    velocity += _gravity_dir() * GRAVITY * dt
    velocity *= maxf(0.0, 1.0 - SLIDE_DRAG * dt)
    var speed_before := Vector2(velocity.x, velocity.z).length()
    move_and_slide()

    var against_wall := _hit_a_wall()
    var at_rim := _at_rim()
    # Only the rim tips them out. Walls and the keep are meant to hold.
    if against_wall and at_rim:
        _rim_press += dt
    else:
        _rim_press = 0.0

    if _rim_press >= RIM_TIP_SECONDS or (against_wall and speed_before > VAULT_SPEED):
        var downhill := _gravity_dir()
        downhill.y = 0.0
        if downhill.length() < 0.01:
            downhill = Vector3(global_position.x, 0.0, global_position.z)
        # Tipped over the lip rather than vaulting it: the outward push is cancelled
        # against the rim every frame while the body is still low enough to touch it,
        # so it goes through instead. Nothing exists outside the tray to collide with.
        #
        # The ghost is gated on the rim in BOTH branches. A fast slide into a wall in
        # the middle of the tray vaults it with its collider intact; handing that one
        # a ghost would drop it through the tray floor and kill it at FELL_BELOW.
        _enter_tumble(downhill.normalized() * RIM_TIP_PUSH + Vector3.UP * VAULT_LIFT, at_rim)


func _do_tumble(dt: float) -> void:
    _tumble_timer = maxf(0.0, _tumble_timer - dt)
    velocity += _gravity_dir() * GRAVITY * dt
    move_and_slide()
    _mesh.rotate_x(dt * 9.0)
    # Past the tray, so the ghost has done its job (getting through the rim) and the
    # collider goes back on -- that is the only way the kill volume can see the fall
    # and splash it.
    if _ghosting and global_position.y < CLEAR_OF_TRAY:
        _set_ghost(false)
    # A ghosting raider has been tipped off the edge; it falls until the kill check.
    if not _ghosting and _tumble_timer == 0.0 and is_on_floor():
        _mesh.rotation = Vector3.ZERO
        velocity = Vector3.ZERO
        _rim_press = 0.0
        state = State.SLIDE if _slipping() else State.WALK


func _do_attack(dt: float) -> void:
    if _slipping():
        _enter_slide()
        return
    if target == null or _flat_distance_to_target() > ATTACK_RANGE * 1.4:
        state = State.WALK
        return
    velocity.x = 0.0
    velocity.z = 0.0
    velocity.y -= GRAVITY * dt
    move_and_slide()
    _attack_timer -= dt
    if _attack_timer <= 0.0:
        _attack_timer = type.attack_interval
        if target.has_method("take_damage"):
            target.take_damage(type.keep_damage)


## Sliding and tumbling drag the body off whatever path it was following, so the
## cached path is stale by the time it stands up again. Dropping the aim here costs
## one query on the way back into WALK instead of one per frame while walking.
func _enter_slide() -> void:
    state = State.SLIDE
    _nav_aimed = false


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


func _die(fell: bool) -> void:
    if state == State.DEAD:
        return
    state = State.DEAD
    set_physics_process(false)
    died.emit(self, fell)


func _slipping(margin := 0.0) -> bool:
    if type.never_slips:
        return false
    # Inclusive, with a float-error margin: max tilt and raider footing are both
    # 12 degrees by design, so full tilt has to be enough to start them slipping.
    return _slope_deg() >= type.footing_deg - margin - 0.01


## The tray is flat, so the effective slope is simply how far the world is leaning.
func _slope_deg() -> float:
    return tilt_controller.tilt.length() if tilt_controller else 0.0


func _gravity_dir() -> Vector3:
    return tilt_controller.gravity_dir if tilt_controller else Vector3.DOWN


func _flat_distance_to_target() -> float:
    var d := target.global_position - global_position
    d.y = 0.0
    return d.length()


## True when the raider is up against the outer lip rather than a built wall.
func _at_rim() -> bool:
    var edge := tray_half - type.radius - 0.08
    return absf(global_position.x) >= edge or absf(global_position.z) >= edge


func _hit_a_wall() -> bool:
    for i in get_slide_collision_count():
        if absf(get_slide_collision(i).get_normal().y) < 0.6:
            return true
    return false


func _desired_direction() -> Vector3:
    var goal := target.global_position
    var straight := goal - global_position
    straight.y = 0.0
    var fallback := straight.normalized() if straight.length() > 0.01 else Vector3.ZERO
    if _agent == null or _nav_warmup > 0:
        return fallback
    _aim_nav(goal)
    if not _agent.is_target_reachable():
        # Unreachable, or the nav map is not warm yet. The straight line is what makes
        # the first frames after a spawn work, so keep it -- and forget the aim, so the
        # moment the map answers the agent asks again instead of trusting a dead path.
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
## the first raider of a type has been launched.
func _wear(t: RaiderType) -> void:
    _capsule = _shared_shape(t)
    _shape.shape = _capsule
    _mesh.mesh = _shared_mesh(t)
    # material_override lives on the MeshInstance3D, and the tumble roll turns that
    # node rather than the mesh, so both resources stay safe to share.
    _mesh.material_override = _shared_material(t)


## A capsule shorter than its own diameter is degenerate, hence the floor.
static func _capsule_height(t: RaiderType) -> float:
    return maxf(t.height, t.radius * 2.0 + 0.01)


static func _shared_shape(t: RaiderType) -> CapsuleShape3D:
    if _shared_shapes.has(t):
        var cached: CapsuleShape3D = _shared_shapes[t]
        return cached
    var s := CapsuleShape3D.new()
    s.radius = t.radius
    s.height = _capsule_height(t)
    _shared_shapes[t] = s
    return s


static func _shared_mesh(t: RaiderType) -> CapsuleMesh:
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


static func _shared_material(t: RaiderType) -> StandardMaterial3D:
    if _shared_materials.has(t):
        var cached: StandardMaterial3D = _shared_materials[t]
        return cached
    var s := StandardMaterial3D.new()
    s.albedo_color = t.colour
    s.roughness = 1.0
    s.metallic = 0.0
    _shared_materials[t] = s
    return s
