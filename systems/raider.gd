extends CharacterBody3D
class_name Raider

## Raiders walk; they do not roll. They stand up to their footing angle, slip past it,
## tumble when a roller hits them hard enough, and die if they leave the tray.
##
## They read the gravity vector but never write it -- that is TiltController's job.

signal died(raider: Raider, fell: bool)

## BREACH and SCALE are APPENDED, never inserted: juice.gd watches `state` for
## TUMBLE and DEAD by value, so renumbering the existing members would make it puff
## dust for the wrong thing.
enum State { CLIMB, WALK, SLIDE, TUMBLE, ATTACK, DEAD, BREACH, SCALE }

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
## cached path away and turns the next read into a fresh synchronous
## NavigationServer query. Sixty raiders walking at a keep that never moves was
## sixty A* queries and sixty path allocations every tick. This sits well under
## path_desired_distance (0.4), so no path is any coarser for it.
const NAV_RETARGET_EPSILON := 0.25
## How often a body throws its aim away and asks for a fresh route. The agent
## repaths itself when the navigation map changes under it, but a raider standing
## at the end of a dead route has nothing left to notice: it is not moving, its
## target is not moving, and the wall that stopped it coming down is exactly the
## event it has to react to. One query a second per body, staggered at launch.
const NAV_REPATH_SECONDS := 1.1
## Seconds of hitting a wall before the route is looked for again. A gap another
## raider just opened has to be preferred over the wall in front of this one --
## that is what keeps them unaggressive -- but asking every frame would repath
## eighty bodies a tick for a wall that takes seconds to fall.
const BREACH_RECHECK_SECONDS := 1.5
## Seconds a climber takes to go over a wall, and how far past it he lands.
const SCALE_SECONDS := 0.8
const SCALE_MARGIN := 0.35
## Arc height over the top of the wall, and the cap on it. The cap is the guard:
## a mis-read footprint must never become a body thrown off the tray.
const SCALE_CLEARANCE := 0.3
const SCALE_MAX_LIFT := 2.5
## Hard ceiling on tumble speed. move_and_slide sweeps, but the ghost below turns
## the tray floor off, and 18 m/s is 0.30 m in a 60 Hz step -- inside the 0.4 m rim
## and the 0.6 m floor, so nothing can cross either of them in one tick.
const TUMBLE_MAX_SPEED := 18.0
## Thickness of the rims (build_main.gd RIM_T). The floor slab a ghosting body
## could drop through reaches this far past the inside face.
const RIM_THICKNESS := 0.4
## Top face of the tray floor. Ghosting below this while still over the tray means
## the body is INSIDE it, not past it.
const GHOST_FLOOR_Y := 0.0
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
## Set by _desired_direction: the route ran out short of the keep and this body is
## standing on the end of it. Not "no path yet" -- that is a separate answer.
var _route_failed := false
## What is actually in the way, and how far from its centre this body can still
## reach it. Kept across a route re-check so a wall's health is never re-won.
var _blocker: Structure = null
var _blocker_reach := 0.0
var _breach_recheck := 0.0
## Counts down to the next forced repath. Staggered at launch.
var _repath := 0.0
var _scale_lift := 0.0


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
    # The foothold comes from WaveDirector, which keeps its OWN tray_half export.
    # _do_climb writes global_position straight in with no collision behind it, so if
    # the two numbers ever disagree the haul would set a body down past the floor's
    # edge with nothing under it. Clamped here, where the tray this body was told
    # about is the one that decides.
    var inside := tray_half - type.radius - 0.05
    _climb_to = Vector3(clampf(to.x, -inside, inside), to.y, clampf(to.z, -inside, inside)) + lift
    _climb_t = 0.0
    _rim_press = 0.0
    _tumble_timer = 0.0
    _set_ghost(false)
    _attack_timer = type.attack_interval
    _nav_warmup = 3
    _route_failed = false
    _blocker = null
    # Staggered, so eighty raiders launched a fifth of a second apart never all come
    # due for their forced repath on the same tick.
    _repath = randf() * NAV_REPATH_SECONDS
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
    _blocker = null
    _route_failed = false
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

    _repath = maxf(0.0, _repath - dt)
    if _repath == 0.0:
        _repath = NAV_REPATH_SECONDS
        _nav_aimed = false

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
        State.BREACH:
            _do_breach(dt)
        State.SCALE:
            _do_scale(dt)

    # The ghost is a 0.4 m transit through the rim on the way OUT and nothing else.
    # A body with its collider off that is still over the tray's own slab and below
    # the floor's top face is INSIDE the tray, not past it -- one more second of that
    # and it is a raider loose under the world. Hand the collider back and let it
    # land. Checked in every state, because the way in here is a roller catching a
    # ghosting body mid-fall and knocking it back inboard, which happens in TUMBLE
    # but is decided in hit_by_roller.
    if _ghosting and state != State.DEAD and global_position.y < GHOST_FLOOR_Y and _over_tray_slab():
        _set_ghost(false)

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
    if _route_failed:
        # The route ran out and this body is standing on the end of it. Whatever it
        # walked into is touching it, so ask the last move what that was -- and only
        # then, after routing has actually been tried and failed, deal with the
        # obstacle. Nothing here is aggression: a raider with a way round takes it.
        var blocker := _blocking_structure()
        if blocker:
            if type.climbs_walls:
                _enter_scale(blocker)
            else:
                _enter_breach(blocker)
            return
    velocity.x = dir.x * type.speed
    velocity.z = dir.z * type.speed
    velocity.y -= GRAVITY * dt
    move_and_slide()


## Standing on the blocking structure and taking it apart. The escape valve: without
## it, walling the keep in completely is an exploit that ends the game, and with it a
## seal is a delay the player paid gold for.
func _do_breach(dt: float) -> void:
    if _slipping():
        _enter_slide()
        return
    if _blocker_gone():
        # It came down. Whatever route it was blocking is worth another look.
        _blocker = null
        _nav_aimed = false
        state = State.WALK
        return
    if _flat_distance_to(_blocker.global_position) > _blocker_reach:
        # Knocked off it, or slid away from it. Walk rather than swing at air.
        state = State.WALK
        return

    velocity.x = 0.0
    velocity.z = 0.0
    velocity.y -= GRAVITY * dt
    move_and_slide()

    _attack_timer -= dt
    if _attack_timer <= 0.0:
        _attack_timer = type.attack_interval
        # Duck-typed on purpose: structure hit points belong to another system, and
        # until they land this is a raider hammering a wall that does not give.
        if _blocker.has_method("take_damage"):
            _blocker.take_damage(type.keep_damage)

    _breach_recheck -= dt
    if _breach_recheck <= 0.0:
        # A gap may have opened -- another raider through the same wall, a gate the
        # player threw. Preferring a route to a wall is the whole point, so the route
        # is asked about again rather than assumed gone. _enter_breach keeps this
        # body's swing if it comes straight back to the same wall.
        _nav_aimed = false
        state = State.WALK


## Climbers go OVER. A scripted haul, like the rim climb: the collider stays ON --
## turning it off is exactly how a body ends up loose under the world -- and the arc
## is clamped to land inside the tray, so the worst this can do is put a climber on
## the near side of a wall he meant to be on the far side of.
func _do_scale(dt: float) -> void:
    _climb_t = minf(1.0, _climb_t + dt / SCALE_SECONDS)
    var p := _climb_from.lerp(_climb_to, _climb_t)
    p.y += sin(_climb_t * PI) * _scale_lift
    global_position = p
    if _climb_t >= 1.0:
        state = State.WALK
        velocity = Vector3.ZERO
        # On the far side of a wall, every metre of the old path is behind him.
        _nav_aimed = false


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
    # Capped every tick, not just at the impulse: a long fall under a leaning gravity
    # keeps accelerating, and the ghost that carried this body over the rim has the
    # tray floor turned off behind it.
    velocity = velocity.limit_length(TUMBLE_MAX_SPEED)
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
    # An iron roller (mass 3) at speed against a grunt is momentum / mass * 0.55, and
    # nothing bounds what the tilt can do to a roller's speed. Clamped so one knock
    # can never move a body further in a tick than the tray floor is thick.
    velocity = impulse.limit_length(TUMBLE_MAX_SPEED)
    _nav_aimed = false
    _blocker = null
    _set_ghost(ghost)


## The ghost -- collider off -- exists to cross the 0.4 m lip on the way out of the
## tray, and for nothing else. Granting one anywhere but at the rim drops the body
## through the floor instead, which is the whole "raiders glitch out of the plane"
## bug, so the rule is enforced HERE rather than trusted to every caller. A body that
## already holds one keeps it: a roller catching a raider mid-fall must not hand the
## collider back while it is still level with the lip.
func _set_ghost(on: bool) -> void:
    if on and not _ghosting and (type == null or not _at_rim()):
        return
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


func _flat_distance_to(point: Vector3) -> float:
    return Vector2(point.x - global_position.x, point.z - global_position.z).length()


## True when the raider is up against the outer lip rather than a built wall.
func _at_rim() -> bool:
    var edge := tray_half - type.radius - 0.08
    return absf(global_position.x) >= edge or absf(global_position.z) >= edge


## True while this body is still over the tray's own floor slab -- the inside face
## plus the thickness of a rim. Combined with being below the floor's top face, this
## is the test for "inside the tray", which is somewhere nothing may ever be.
func _over_tray_slab() -> bool:
    var edge := tray_half + RIM_THICKNESS
    return absf(global_position.x) < edge and absf(global_position.z) < edge


func _hit_a_wall() -> bool:
    for i in get_slide_collision_count():
        if absf(get_slide_collision(i).get_normal().y) < 0.6:
            return true
    return false


## Where to walk this tick, and -- as a side effect -- whether routing has failed.
##
## Navigation is the PRIMARY behaviour. The straight line is a genuine last resort:
## the navigation map having no answer at all, which is true for a handful of frames
## after a spawn and never again. Three things used to make it the common case:
##
##   * is_target_reachable() compares get_final_position() with target_position, and
##     get_final_position() returns Vector3.ZERO when the path is EMPTY. The keep
##     stands at the world origin, so "no path at all" measures as zero distance from
##     the keep and reads as reachable. The code then asked for the next path position,
##     which on an empty path returns the body's own position, so the step was zero
##     and it fell through to the straight line -- silently, every frame.
##   * When the keep really was walled off, is_target_reachable() went false and the
##     partial path was thrown away. That path is the route round the wall as far as
##     the wall allows: Godot returns the way to the closest REACHABLE point when the
##     target cannot be reached, which is exactly what "go around" needs.
##   * The next path position advances only once the body is inside
##     path_desired_distance of a waypoint, measured in 3D. A raider stands half a
##     capsule (0.43 m for a grunt) above the mesh its path lies on, and that is
##     already past 0.4 m, so the index could never advance off the first waypoint --
##     the one under its own feet -- and the step was zero again.
##
## So the path is now read and walked directly, and only an EMPTY path beelines.
func _desired_direction() -> Vector3:
    _route_failed = false
    var goal := target.global_position
    var straight := goal - global_position
    straight.y = 0.0
    var fallback := straight.normalized() if straight.length() > 0.01 else Vector3.ZERO
    if _agent == null or _nav_warmup > 0:
        return fallback

    _aim_nav(goal)
    # Order matters. get_current_navigation_path() is a const read of whatever the
    # agent last computed; get_next_path_position() is what makes it run the query.
    # Without this call the path stays empty and every raider beelines forever.
    _agent.get_next_path_position()
    var path := _agent.get_current_navigation_path()
    if path.is_empty():
        # The map has no answer yet. Forget the aim so the moment it does answer the
        # agent asks again instead of trusting a dead path -- and do NOT read this as
        # "walled in": nothing has been proven about the world.
        _nav_aimed = false
        return fallback

    var step := _path_step(path)
    if step != Vector3.ZERO:
        return step

    # Standing on the end of the route. If it ended within reach of the keep this is
    # simply arrival and _do_walk hands over to ATTACK. If it ended short, the way is
    # blocked and _do_walk decides what to do about that. Either way keep pushing at
    # the keep, so whatever is in the way registers as a contact to identify it by.
    var end := path[path.size() - 1]
    _route_failed = Vector2(end.x - goal.x, end.z - goal.z).length() > ATTACK_RANGE
    return fallback


## The point on `path` to steer at, flattened. Recomputed from the whole path every
## tick rather than kept as an index: the agent silently rebuilds its path when the
## navigation map changes under it -- which is precisely what placing a wall does --
## and an index into a path that is no longer the same path walks a raider backwards.
## The scan starts at the nearest waypoint and only ever looks FORWARD, so a route
## that doubles back past this body is never rejoined at the wrong end.
##
## Returns ZERO when every remaining waypoint is underfoot: this is the end of it.
func _path_step(path: PackedVector3Array) -> Vector3:
    var nearest := 0
    var nearest_d := INF
    for i in path.size():
        var d := _flat_distance_to(path[i])
        if d < nearest_d:
            nearest_d = d
            nearest = i
    for i in range(nearest, path.size()):
        var to := path[i] - global_position
        # Flat, and this is the whole reason the agent's own waypoint advance could
        # not be used: the body stands half a capsule above the mesh the path lies on.
        to.y = 0.0
        if to.length() > _agent.path_desired_distance:
            return to.normalized()
    return Vector3.ZERO


## What is actually in the way, taken from the last move rather than guessed at with
## a ray: a raider that has walked into a wall is touching it. Only what the PLAYER
## built and can lose counts -- the tray, its rims and the corner dressing are not
## ours to break, the keep has ATTACK for that, and an indestructible kind would be a
## raider stood swinging at it forever.
func _blocking_structure() -> Structure:
    for i in get_slide_collision_count():
        var hit := get_slide_collision(i)
        # Floors and ceilings are not obstacles; only something standing up is.
        if absf(hit.get_normal().y) >= 0.6:
            continue
        var s := hit.get_collider() as Structure
        if s == null or s == target:
            continue
        if s.has_method("is_destructible") and not s.is_destructible():
            continue
        return s
    return null


## Routing has failed and this is what stopped it. Breaking it is the escape valve
## that keeps sealing the keep in from being an exploit, and it only ever happens
## AFTER a route has been looked for and not found -- which is the difference between
## Ben's "not aggressive" and a raider that chews the nearest wall on sight.
func _enter_breach(blocker: Structure) -> void:
    if _blocker != blocker:
        # A new wall gets the same wind-up the keep gets. The SAME wall keeps the
        # swing it had going, so re-checking for a route never resets its progress.
        _blocker = blocker
        _attack_timer = type.attack_interval
        _blocker_reach = ATTACK_RANGE + type.radius
        if blocker.type:
            _blocker_reach += maxf(blocker.type.footprint.x, blocker.type.footprint.z) * 0.5
    state = State.BREACH
    _breach_recheck = BREACH_RECHECK_SECONDS


## Duck-typed on purpose, all the way down: structure hit points belong to another
## system, and a raider must not fall over if they move. is_alive() goes false on the
## killing blow, a frame or more before the node is freed, so this is what stops a
## raider swinging at rubble.
func _blocker_gone() -> bool:
    if _blocker == null or not is_instance_valid(_blocker):
        return true
    return _blocker.has_method("is_alive") and not _blocker.is_alive()


## Climbers go over instead. Every number here is clamped, because _do_scale writes
## global_position straight in: the landing is forced inside the tray and onto the
## floor, and the arc is capped, so a wall with a footprint this code misreads still
## cannot throw anybody off the world.
func _enter_scale(blocker: Structure) -> void:
    var over := blocker.global_position - global_position
    over.y = 0.0
    if over.length() < 0.01:
        over = Vector3(0.0, 0.0, 1.0)
    over = over.normalized()

    var size := blocker.type.footprint if blocker.type else Vector3.ONE
    var across := maxf(size.x, size.z) * 0.5 + type.radius + SCALE_MARGIN
    var landing := blocker.global_position + over * across
    var inside := tray_half - type.radius - 0.05
    var half := _capsule.height * 0.5

    _climb_from = global_position
    _climb_to = Vector3(clampf(landing.x, -inside, inside), half, clampf(landing.z, -inside, inside))
    _scale_lift = clampf(size.y + SCALE_CLEARANCE, 0.15, SCALE_MAX_LIFT)
    _climb_t = 0.0
    _blocker = null
    state = State.SCALE


## The kingdom changed shape: something went up, or something came down. Whatever
## path this body is holding was made for a world that no longer exists.
func notify_world_changed() -> void:
    _nav_aimed = false
    _repath = NAV_REPATH_SECONDS
    # A raider only breaking a wall because it had no way round gets to look for the
    # way round again the instant the shape of the place changes.
    if state == State.BREACH:
        state = State.WALK


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
