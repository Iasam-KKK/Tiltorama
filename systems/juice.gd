extends Node3D
class_name Juice

## Feedback only. Nothing here changes what happens; it changes what you can see
## happening. Marbles squash where they hit, fast ones grow a streak in their own
## colour and width, a split or a shatter or a stick leaves a mark of its own shape,
## dust marks a raider going down -- dust, never blood, because the tumble IS the
## death -- and a heavy hit kicks the camera.
##
## Three constraints shape the implementation.
##
## 1. Screen shake never touches the camera rig. TiltController writes
##    camera_rig.rotation every physics frame; a second writer on that property would
##    simply lose the race. The shake composes onto the Camera3D one level BELOW the
##    rig instead, a node nothing else writes:
##        rig.rotation (TiltController)  ->  camera.rest * shake (here)
##    Different property, different node, so the two add by construction and neither
##    can stomp the other. `camera.rest` is captured once at startup.
##
## 2. Everything updates in _physics_process, in step with the rig and the bodies, so
##    physics interpolation smooths the squash and the shake for free. The two
##    MultiMesh pools opt OUT of interpolation: they rewrite their instances every
##    tick and reuse slots, and interpolating between two different marbles smears one
##    comet into another.
##
## 3. Nothing is instanced mid-wave. Squash reuses each roller's existing
##    MeshInstance3D -- its basis, never the body transform, so the physics never sees
##    it -- and streaks and dust are fixed-size MultiMesh pools built once at startup.
##
## This node reads pools and listens to signals. It writes nothing they own.

@export var tilt_controller: TiltController
@export var roller_pool: RollerPool
@export var raider_pool: RaiderPool
@export var keep: Keep
## Splits, shatters and sticks come from here. Found automatically among the
## siblings when left empty, so wiring it is optional.
@export var impact_resolver: ImpactResolver
## Supplies reduce_motion. Without it every effect is simply on.
@export var options: Options
## The Camera3D under TiltController's camera rig. Found automatically when left
## empty, so wiring it is optional.
@export var camera: Camera3D

@export_group("Squash")
@export var squash_enabled := true
## Peak compression along the direction of travel, as a fraction of the radius.
@export_range(0.0, 0.9, 0.01) var squash_strength := 0.45
@export_range(0.02, 1.0, 0.01) var squash_seconds := 0.22
## Below this an impact gets no pulse. Juice's own gate: which contacts the pool
## bothers to announce is the pool's business, and it is not always the same number.
@export_range(0.0, 20.0, 0.1) var squash_min_speed := 2.5
## Full strength at this speed.
@export_range(1.0, 40.0, 0.5) var squash_full_speed := 9.0
## How close a roller must be to the reported impact point to be the one that hit.
## Only used on the fallback path, where the pool reports a place and not a body.
@export_range(0.01, 2.0, 0.01) var match_radius := 0.3

@export_group("Streaks")
@export var streaks_enabled := true
## The design number: a marble reads as fast above 4 m/s.
@export_range(0.5, 20.0, 0.1) var streak_speed := 4.0
## Full length and opacity here.
@export_range(1.0, 40.0, 0.5) var streak_full_speed := 11.0
## Streak length, in seconds of travel.
@export_range(0.01, 0.5, 0.005) var streak_seconds := 0.07
## Streak thickness as a fraction of the marble's diameter.
@export_range(0.05, 1.5, 0.01) var streak_width := 0.7
@export_range(0.0, 1.0, 0.01) var streak_alpha := 0.5

@export_group("Dust")
@export var dust_enabled := true
## Puffs in flight at once. Old ones are recycled, so this is a ceiling, not a budget.
@export_range(4, 256, 1) var puff_pool := 48
@export_range(0.05, 2.0, 0.01) var puff_seconds := 0.45
@export_range(0.05, 3.0, 0.01) var puff_start_size := 0.3
@export_range(0.05, 4.0, 0.01) var puff_end_size := 1.2
@export var puff_colour := Color(0.78, 0.74, 0.66, 0.55)
## Heavy roller impacts kick dust up as well as shaking the camera.
@export var puff_on_impact := true
## Nothing below the tray is worth a puff -- that raider is already in the sea.
@export var puff_min_y := -1.0

@export_group("Effects")
## The cascade is the reward the whole build phase is spent buying, so a split, a
## shatter and a stick each get a tell of their own shape. All three are dust: the
## puff pool is already there, it costs nothing to instance, and it reads from
## directly above, which is the only angle this game is ever seen from.
@export var effects_enabled := true
## How much of the roller's own colour its dust takes. Rollers own the saturated
## end of the tray; dust that matched them exactly would out-shout the marbles.
@export_range(0.0, 1.0, 0.01) var effect_tint := 0.6
## One puff per fragment, up to this. A twelve-way burst is a cloud, not a tell.
@export_range(1, 12, 1) var burst_max_puffs := 6
## Split: fragments fan out on a ring, and the dust marks the same ring.
@export_range(0.02, 2.0, 0.01) var split_ring := 0.32
@export_range(0.1, 3.0, 0.05) var split_size := 0.5
## Shatter: wider and heavier than a split, with a pale core where the snowball
## stood. It is the end of a roller, not the middle of one.
@export_range(0.02, 2.0, 0.01) var shatter_ring := 0.52
@export_range(0.1, 3.0, 0.05) var shatter_size := 0.7
@export_range(0.1, 3.0, 0.05) var shatter_core := 1.2
## Stick: a tight mark that lingers instead of blowing outward, because what it
## announces is a barrier that is still standing.
@export_range(0.02, 2.0, 0.01) var stick_ring := 0.2
@export_range(0.1, 3.0, 0.05) var stick_size := 0.45
@export_range(1, 8, 1) var stick_puffs := 4
@export_range(0.05, 4.0, 0.05) var stick_seconds := 1.2
## Trauma from an effect at full momentum. Every effect kicks the camera through
## one path -- effect_fired -- so a new effect type gets the kick for free.
@export_range(0.0, 1.0, 0.01) var effect_trauma := 0.2
@export_range(0.0, 200.0, 0.5) var effect_full_momentum := 30.0

@export_group("Shake")
@export var shake_enabled := true
## Impacts at or above this speed shake. Below it only the squash plays, so ordinary
## rolling contact does not rattle the picture.
@export_range(0.5, 40.0, 0.1) var shake_speed := 6.0
@export_range(1.0, 60.0, 0.5) var shake_full_speed := 14.0
## Trauma from the hardest impact, and from one hit on the keep.
@export_range(0.0, 1.0, 0.01) var shake_impact_trauma := 0.32
@export_range(0.0, 1.0, 0.01) var shake_keep_trauma := 0.5
## A cascade would otherwise stack trauma until the screen is unreadable.
@export_range(0.0, 1.0, 0.01) var max_trauma := 0.8
## Trauma bled off per second.
@export_range(0.1, 10.0, 0.05) var trauma_decay := 1.6
## Peak camera offset in metres, at full trauma.
@export_range(0.0, 2.0, 0.01) var shake_offset := 0.22
## Peak camera roll in degrees. Roll is the part that makes people queasy, so it stays
## small even for players who have not turned motion down.
@export_range(0.0, 5.0, 0.05) var shake_roll_deg := 0.6
@export_range(1.0, 60.0, 0.5) var shake_frequency := 22.0

## Marble state, one slot per roller, index-matched to _rollers.
var _rollers: Array[RigidBody3D] = []
var _roller_meshes: Array[MeshInstance3D] = []
## body -> slot. The pool has the body in hand when it reports an impact, so the
## slot is a hash lookup rather than a walk of two hundred global transforms.
var _roller_index := {}
var _roller_children := -1
## Whether the pool reports per-body type and radius. Asked once per rebuild, not
## once per marble per tick.
var _pool_types := false
## Pulse phase, 1 at the moment of contact down to 0.
var _squash_t := PackedFloat32Array()
var _squash_peak := PackedFloat32Array()
## In the body's own frame: the marble spins, and a world axis would make the flat
## side slide around it.
var _squash_axis := PackedVector3Array()

var _streaks: MultiMeshInstance3D
var _streak_on := PackedByteArray()
var _streaks_shown := false

var _puffs: MultiMeshInstance3D
var _puff_pos := PackedVector3Array()
var _puff_left := PackedFloat32Array()
## Per puff, because an effect tell is dust in the roller's own hue over a life of
## its own choosing -- a stick mark holds four times as long as a raider's dust.
var _puff_life := PackedFloat32Array()
var _puff_colour := PackedColorArray()
var _puff_scale := PackedFloat32Array()
var _puff_on := PackedByteArray()
var _next_puff := 0

var _raiders: Array[Raider] = []
var _raider_children := -1
var _raider_state := PackedInt32Array()
## Last position while still visible. A dying raider is parked below the world before
## anyone hears about it, so the puff needs somewhere to remember.
var _raider_pos := PackedVector3Array()

var _trauma := 0.0
var _shake_time := 0.0
var _shake_applied := false
var _camera_rest := Transform3D.IDENTITY
var _noise := FastNoiseLite.new()
var _keep_hp := -1

var _hidden := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
var _ready_done := false


func _ready() -> void:
    _noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    _noise.frequency = 1.0
    _noise.seed = randi()

    _streaks = _make_field(_blob_mesh(10, 5))
    _puffs = _make_field(_blob_mesh(8, 4))
    _size_puffs()

    _connect_impacts()
    if tilt_controller:
        # Levelling is the panic button. Whatever the camera was doing, stop it.
        tilt_controller.levelled.connect(_on_levelled)
    if keep:
        keep.hp_changed.connect(_on_keep_hp_changed)
    if options:
        options.changed.connect(_on_options_changed)

    # Both pools fill their children in their own _ready. One frame of patience and
    # the caches see every body exactly once.
    await get_tree().process_frame
    _find_camera()
    _find_resolver()
    _connect_effects()
    _rebuild_rollers()
    _rebuild_raiders()
    _ready_done = true


## Public so a future system can punch the camera without Juice reaching into it.
## Silently ignored while motion is reduced -- callers never need to check.
func add_trauma(amount: float) -> void:
    if not shake_enabled or amount <= 0.0 or _reduced():
        return
    _trauma = minf(max_trauma, _trauma + amount)


## Dust at a point. `size` scales the puff; 1.0 is a raider going down.
func puff_at(at: Vector3, size := 1.0) -> void:
    _puff(at, size, puff_colour, puff_seconds)


## The same, with the tint and the life the caller wants. Private because a puff
## that is not dust-coloured is an effect tell, and effects are answered here.
func _puff(at: Vector3, size: float, tint: Color, seconds: float) -> void:
    if not dust_enabled or _puff_left.is_empty() or at.y < puff_min_y:
        return
    var i := _next_puff
    _next_puff = (_next_puff + 1) % _puff_left.size()
    _puff_pos[i] = at
    _puff_left[i] = maxf(seconds, 0.01)
    _puff_life[i] = maxf(seconds, 0.01)
    _puff_colour[i] = tint
    _puff_scale[i] = size


## For the debug readout.
func trauma() -> float:
    return _trauma


func streak_count() -> int:
    var n := 0
    for i in _streak_on.size():
        n += _streak_on[i]
    return n


func _physics_process(dt: float) -> void:
    if not _ready_done:
        return
    # Pool sizes are a designer decision, not a runtime one, but a changed child count
    # means the caches are stale and every index below would be wrong.
    if roller_pool and roller_pool.get_child_count() != _roller_children:
        _rebuild_rollers()
    if raider_pool and raider_pool.get_child_count() != _raider_children:
        _rebuild_raiders()

    var calm := _reduced()
    _update_squash(dt)
    if streaks_enabled and not calm:
        _update_streaks()
    elif _streaks_shown:
        _hide_streaks()
    _update_puffs(dt)
    _watch_raiders()
    _update_shake(dt, calm)


# --- squash -----------------------------------------------------------------

func _start_squash(i: int, speed: float) -> void:
    if not squash_enabled or i < 0 or i >= _rollers.size():
        return
    var body := _rollers[i]
    var travel := body.linear_velocity
    var axis := body.global_transform.basis.inverse() * travel
    _squash_axis[i] = axis.normalized() if axis.length() > 0.01 else Vector3.UP
    _squash_peak[i] = squash_strength * _ramp(speed, squash_min_speed, squash_full_speed)
    _squash_t[i] = 1.0


func _update_squash(dt: float) -> void:
    for i in _rollers.size():
        if _squash_t[i] <= 0.0:
            continue
        _squash_t[i] = maxf(0.0, _squash_t[i] - dt / maxf(squash_seconds, 0.01))
        var mesh := _roller_meshes[i]
        if mesh == null:
            continue
        if _squash_t[i] == 0.0:
            mesh.basis = Basis.IDENTITY
            continue
        var t := _squash_t[i]
        # Compress on contact, overshoot into a stretch, settle. One cosine term is
        # the whole envelope, and it lands exactly on zero when t does.
        mesh.basis = _pulse_basis(_squash_axis[i], _squash_peak[i] * t * cos((1.0 - t) * PI * 1.5))


## Scale along `axis` by (1 - a) and across it by (1 + a/2), so the marble keeps
## roughly its volume. Symmetric, so the columns and rows agree.
func _pulse_basis(axis: Vector3, a: float) -> Basis:
    var along := 1.0 - a
    var across := 1.0 + a * 0.5
    var k := along - across
    return Basis(
        Vector3(across + k * axis.x * axis.x, k * axis.y * axis.x, k * axis.z * axis.x),
        Vector3(k * axis.x * axis.y, across + k * axis.y * axis.y, k * axis.z * axis.y),
        Vector3(k * axis.x * axis.z, k * axis.y * axis.z, across + k * axis.z * axis.z))


# --- streaks ----------------------------------------------------------------

func _update_streaks() -> void:
    var mm := _streaks.multimesh
    if mm == null or mm.instance_count != _rollers.size():
        return
    # Pool-wide values are the fallback for a body the pool will not describe, not
    # the answer for every body: see below.
    var pool_radius: float = roller_pool.radius if roller_pool else 0.22
    var pool_colour: Color = roller_pool.colour if roller_pool else Color.WHITE
    _streaks_shown = false
    for i in _rollers.size():
        var body := _rollers[i]
        var travel := body.linear_velocity
        var speed := travel.length()
        if not body.visible or speed < streak_speed:
            if _streak_on[i] == 1:
                mm.set_instance_transform(i, _hidden)
                _streak_on[i] = 0
            continue
        # Per marble, because the pool is one size and one colour and the marbles
        # are not: a grown snowball is three times the width of the stone it began
        # as, and an iron roller drawing a stone-blue comet is a lie about what
        # just went past. Two meta reads, and only for a marble fast enough to draw.
        var radius := pool_radius
        var base := pool_colour
        if _pool_types:
            var r: float = roller_pool.radius_of(body)
            if r > 0.0:
                radius = r
            var t: RollerType = roller_pool.type_of(body)
            if t:
                base = t.colour
        var width := radius * 2.0 * streak_width
        var dir := travel / speed
        var length := maxf(speed * streak_seconds, radius * 2.0)
        # Trailing, not centred: the streak is where the marble has just been.
        var at := body.global_position - dir * (length * 0.5 - radius * 0.5)
        mm.set_instance_transform(i, Transform3D(_stretch_basis(dir, width, length), at))
        # A streak reads as motion blur, so it is a paler version of the marble.
        var tint := base.lerp(Color.WHITE, 0.35)
        tint.a = streak_alpha * _ramp(speed, streak_speed, streak_full_speed)
        mm.set_instance_color(i, tint)
        _streak_on[i] = 1
        _streaks_shown = true


func _hide_streaks() -> void:
    var mm := _streaks.multimesh
    if mm == null:
        return
    for i in _streak_on.size():
        if _streak_on[i] == 1 and i < mm.instance_count:
            mm.set_instance_transform(i, _hidden)
        _streak_on[i] = 0
    _streaks_shown = false


## The blob mesh is a unit sphere with its long axis on Y, so Y carries the length.
func _stretch_basis(dir: Vector3, width: float, length: float) -> Basis:
    var side := dir.cross(Vector3.FORWARD)
    if side.length_squared() < 0.0001:
        side = dir.cross(Vector3.RIGHT)
    side = side.normalized()
    var out := side.cross(dir).normalized()
    return Basis(side * width, dir * length, out * width)


# --- dust -------------------------------------------------------------------

func _update_puffs(dt: float) -> void:
    var mm := _puffs.multimesh
    if mm == null:
        return
    for i in _puff_left.size():
        if _puff_left[i] <= 0.0:
            if _puff_on[i] == 1:
                mm.set_instance_transform(i, _hidden)
                _puff_on[i] = 0
            continue
        _puff_left[i] = maxf(0.0, _puff_left[i] - dt)
        # Against this puff's own life, not the pool default: a stick mark lingers
        # and would otherwise finish its fade in the first quarter of it.
        var t := 1.0 - _puff_left[i] / maxf(_puff_life[i], 0.01)
        var s := lerpf(puff_start_size, puff_end_size, t) * _puff_scale[i]
        mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3(s, s, s)), _puff_pos[i]))
        var c := _puff_colour[i]
        c.a *= 1.0 - t
        mm.set_instance_color(i, c)
        _puff_on[i] = 1


## Polls the raider pool rather than listening to raider_died, because by the time
## that signal fires the body has been parked a thousand metres down and the place it
## died is gone. Eighty state reads a tick is cheaper than making the pool report it.
func _watch_raiders() -> void:
    for i in _raiders.size():
        var r := _raiders[i]
        if r.visible:
            _raider_pos[i] = r.global_position
        var now: int = r.state
        if now == _raider_state[i]:
            continue
        var was: int = _raider_state[i]
        _raider_state[i] = now
        if now == Raider.State.TUMBLE:
            # Feet, not centre: the dust belongs where the ground is.
            var drop: float = r.type.height * 0.5 if r.type else 0.5
            puff_at(r.global_position - Vector3(0.0, drop, 0.0), 0.9)
        elif now == Raider.State.DEAD and was != Raider.State.DEAD:
            puff_at(_raider_pos[i], 1.3)


# --- shake ------------------------------------------------------------------

func _update_shake(dt: float, calm: bool) -> void:
    if camera == null:
        return
    if calm or not shake_enabled or _trauma <= 0.0:
        _clear_shake()
        return
    _trauma = maxf(0.0, _trauma - trauma_decay * dt)
    _shake_time += dt
    # Trauma squared: small hits barely move the picture, big ones are unmistakable.
    var amount := _trauma * _trauma
    var t := _shake_time * shake_frequency
    var offset := Vector3(
        _noise.get_noise_2d(t, 0.0) * shake_offset * amount,
        _noise.get_noise_2d(t, 131.0) * shake_offset * amount,
        0.0)
    var roll := deg_to_rad(_noise.get_noise_2d(t, 277.0) * shake_roll_deg * amount)
    # Composed in the camera's own frame, one level below the rig. TiltController
    # keeps writing camera_rig.rotation; neither of us reads the other's work.
    camera.transform = _camera_rest * Transform3D(Basis(Vector3.BACK, roll), offset)
    _shake_applied = true


func _clear_shake() -> void:
    _trauma = 0.0
    if _shake_applied and camera:
        camera.transform = _camera_rest
        _shake_applied = false


# --- signals ----------------------------------------------------------------

## The pool named the body that hit. Preferred: the slot is a hash lookup.
func _on_impact_body(body: RigidBody3D, speed: float, at: Vector3) -> void:
    _handle_impact(body, speed, at)


## Every contact, body first. Used when `impact` does not name the body; the gates
## inside _handle_impact are what make a contact worth drawing, so an ungated feed
## costs one comparison per contact and reports the same events.
func _on_roller_impact(body: RigidBody3D, _other: Node, _type: RollerType, speed: float,
        _lateral: float, _momentum: float) -> void:
    _handle_impact(body, speed, body.global_position if body else Vector3.ZERO)


## Last resort: the pool reported a place, not a marble, so one has to be found.
func _on_impact(speed: float, at: Vector3) -> void:
    _handle_impact(null, speed, at)


func _handle_impact(body: RigidBody3D, speed: float, at: Vector3) -> void:
    if not _ready_done:
        return
    if squash_enabled and speed >= squash_min_speed:
        _start_squash(_index_of(body) if body else _roller_at(at), speed)
    if speed >= shake_speed:
        add_trauma(shake_impact_trauma * _ramp(speed, shake_speed, shake_full_speed))
        if puff_on_impact:
            puff_at(at, 0.7)


## A splitter came apart. Dust on the ring the fragments left along, one puff per
## fragment, in the parent's colour -- so the tell says how many and which type.
func _on_did_split(at: Vector3, count: int, from: RollerType, _depth: int) -> void:
    if not effects_enabled:
        return
    _ring_puffs(at, count, split_ring, split_size, _dust_tint(from, effect_tint), puff_seconds)


## A snowball ran out of hill. Wider and slower than a split, with a pale core
## where the roller stood: this is a body ending, not a body multiplying.
func _on_did_shatter(at: Vector3, count: int, from: RollerType, _depth: int) -> void:
    if not effects_enabled:
        return
    var tint := _dust_tint(from, effect_tint * 0.5)
    _ring_puffs(at, count, shatter_ring, shatter_size, tint, puff_seconds)
    _puff(at, shatter_core, tint, puff_seconds)


## A sticky roller planted itself. The mark holds rather than blowing outward,
## because what it announces is a wall the raiders now have to go round.
func _on_did_stick(at: Vector3, from: RollerType, _depth: int) -> void:
    if not effects_enabled:
        return
    _ring_puffs(at, stick_puffs, stick_ring, stick_size, _dust_tint(from, effect_tint),
        stick_seconds)


## Every effect kicks the camera through this one path, so the kick is consistent
## across the three and a fourth effect gets it without another connection. The
## did_* signals draw; this one shakes. Neither does the other's job, so an effect
## that fires both is not counted twice.
func _on_effect_fired(_effect: String, _at: Vector3, momentum: float, _from: RollerType,
        _depth: int) -> void:
    if not effects_enabled:
        return
    add_trauma(effect_trauma * _ramp(momentum, 0.0, effect_full_momentum))


func _on_levelled() -> void:
    _clear_shake()


func _on_keep_hp_changed(hp: int, _max_hp: int) -> void:
    # reset() raises hp; only losing it is worth a thump.
    if _keep_hp >= 0 and hp < _keep_hp:
        add_trauma(shake_keep_trauma)
    _keep_hp = hp


func _on_options_changed(key: StringName) -> void:
    if key != Options.REDUCE_MOTION or not _reduced():
        return
    # Turning it on has to take effect on the frame it is turned on, not whenever the
    # current shake happens to run out.
    _clear_shake()
    _hide_streaks()


# --- plumbing ---------------------------------------------------------------

func _reduced() -> bool:
    return options != null and options.reduce_motion


func _ramp(v: float, low: float, high: float) -> float:
    return clampf((v - low) / maxf(high - low, 0.001), 0.0, 1.0)


## The slot for a body the pool named. One hash lookup; no transforms are read.
func _index_of(body: RigidBody3D) -> int:
    return int(_roller_index.get(body, -1))


## Dust on a ring lying flat on the tray. `count` is what actually came out of the
## pool, capped: past half a dozen puffs a burst reads as a cloud, not a count.
func _ring_puffs(at: Vector3, count: int, ring: float, size: float, tint: Color,
        seconds: float) -> void:
    var n := clampi(count, 1, burst_max_puffs)
    var axes := _tray_axes()
    for i in n:
        var a := TAU * float(i) / float(n)
        _puff(at + (axes[0] * cos(a) + axes[1] * sin(a)) * ring, size, tint, seconds)


## Dust in the marble's own hue, mixed with the dust colour rather than replacing
## it, so a burst still reads as dust and not as a second marble.
func _dust_tint(from: RollerType, mix: float) -> Color:
    if from == null:
        return puff_colour
    var c := puff_colour.lerp(from.colour, clampf(mix, 0.0, 1.0))
    # lerp() moves alpha too, and the dust colour owns how solid dust is.
    c.a = puff_colour.a
    return c


## Two axes across the tray surface, so a ring lies on the floor rather than
## standing on edge when the world is leaning. Reads gravity; never writes it.
func _tray_axes() -> PackedVector3Array:
    var up := -tilt_controller.gravity_dir if tilt_controller else Vector3.UP
    if up.length_squared() < 0.0001:
        up = Vector3.UP
    up = up.normalized()
    var bx := up.cross(Vector3.FORWARD)
    if bx.length_squared() < 0.0001:
        bx = up.cross(Vector3.RIGHT)
    bx = bx.normalized()
    return PackedVector3Array([bx, up.cross(bx).normalized()])


## RollerPool has the body in hand when it reports an impact, so the preferred
## signal hands it over -- impact(body, speed, at) -- and the slot is a lookup.
## Two older shapes still work: roller_impact(...), which also names the body, and
## the plain impact(speed, at), which costs a scan of the pool to recover it.
## Exactly one is connected, so no impact is ever answered twice.
func _connect_impacts() -> void:
    if roller_pool == null:
        return
    var impact_args := _signal_args(&"impact")
    if impact_args.size() >= 3 and int(impact_args[0].get("type", TYPE_NIL)) == TYPE_OBJECT:
        roller_pool.impact.connect(_on_impact_body)
    elif _signal_args(&"roller_impact").size() == 6:
        roller_pool.roller_impact.connect(_on_roller_impact)
    elif impact_args.size() == 2:
        roller_pool.impact.connect(_on_impact)


func _signal_args(sig: StringName) -> Array:
    for s in roller_pool.get_signal_list():
        if s["name"] == sig:
            return s["args"]
    return []


func _connect_effects() -> void:
    _link(impact_resolver, &"did_split", _on_did_split)
    _link(impact_resolver, &"did_shatter", _on_did_shatter)
    _link(impact_resolver, &"did_stick", _on_did_stick)
    _link(impact_resolver, &"effect_fired", _on_effect_fired)


## Another system owns these signals. Asking rather than assuming keeps a renamed
## signal a missing tell instead of an error on startup.
func _link(source: Object, sig: StringName, to: Callable) -> void:
    if source and source.has_signal(sig) and not source.is_connected(sig, to):
        source.connect(sig, to)


func _find_resolver() -> void:
    if impact_resolver != null:
        return
    var parent := get_parent()
    if parent == null:
        return
    for sibling in parent.get_children():
        var r := sibling as ImpactResolver
        if r:
            impact_resolver = r
            return


## Fallback for a pool that reports where an impact happened but not what hit.
## RollerPool sends the body's own position, so the match is exact and the loop
## stops on the first hit rather than ranking 200 candidates.
func _roller_at(at: Vector3) -> int:
    var best := -1
    var best_d := match_radius * match_radius
    for i in _rollers.size():
        var d := _rollers[i].global_position.distance_squared_to(at)
        if d < best_d:
            best_d = d
            best = i
            if d < 0.0001:
                break
    return best


func _rebuild_rollers() -> void:
    _rollers.clear()
    _roller_meshes.clear()
    _roller_index.clear()
    if roller_pool == null:
        _roller_children = -1
        _pool_types = false
        return
    _roller_children = roller_pool.get_child_count()
    _pool_types = roller_pool.has_method(&"type_of") and roller_pool.has_method(&"radius_of")
    for child in roller_pool.get_children():
        var body := child as RigidBody3D
        if body == null:
            continue
        _roller_index[body] = _rollers.size()
        _rollers.append(body)
        _roller_meshes.append(_first_mesh(body))

    var n := _rollers.size()
    _squash_t.resize(n)
    _squash_t.fill(0.0)
    _squash_peak.resize(n)
    _squash_peak.fill(0.0)
    _squash_axis.resize(n)
    _squash_axis.fill(Vector3.UP)
    _streak_on.resize(n)
    _streak_on.fill(0)
    _streaks_shown = false
    # One streak slot per marble for the life of the run, so a slot never has to
    # jump from one body to another.
    _streaks.multimesh.instance_count = n


func _rebuild_raiders() -> void:
    _raiders.clear()
    if raider_pool == null:
        _raider_children = -1
        return
    _raider_children = raider_pool.get_child_count()
    for child in raider_pool.get_children():
        var r := child as Raider
        if r:
            _raiders.append(r)

    var n := _raiders.size()
    _raider_state.resize(n)
    _raider_pos.resize(n)
    for i in n:
        # Seeded from the current state, so parking the pool at startup is not read
        # as eighty raiders dying at once.
        _raider_state[i] = _raiders[i].state
        _raider_pos[i] = _raiders[i].global_position


func _size_puffs() -> void:
    var n := puff_pool
    _puff_pos.resize(n)
    _puff_pos.fill(Vector3.ZERO)
    _puff_left.resize(n)
    _puff_left.fill(0.0)
    _puff_life.resize(n)
    _puff_life.fill(puff_seconds)
    _puff_colour.resize(n)
    _puff_colour.fill(puff_colour)
    _puff_scale.resize(n)
    _puff_scale.fill(1.0)
    _puff_on.resize(n)
    _puff_on.fill(0)
    _next_puff = 0
    _puffs.multimesh.instance_count = n


func _first_mesh(body: Node) -> MeshInstance3D:
    for child in body.get_children():
        var m := child as MeshInstance3D
        if m:
            return m
    return null


func _find_camera() -> void:
    if camera == null and tilt_controller and tilt_controller.camera_rig:
        for child in tilt_controller.camera_rig.get_children():
            var c := child as Camera3D
            if c:
                camera = c
                break
    if camera:
        _camera_rest = camera.transform


func _blob_mesh(segments: int, rings: int) -> SphereMesh:
    var m := SphereMesh.new()
    m.radius = 0.5
    m.height = 1.0
    m.radial_segments = segments
    m.rings = rings
    return m


func _make_field(mesh: Mesh) -> MultiMeshInstance3D:
    var mm := MultiMesh.new()
    # Format before count: setting instance_count is what allocates the buffers.
    mm.transform_format = MultiMesh.TRANSFORM_3D
    mm.use_colors = true
    mm.mesh = mesh

    var mat := StandardMaterial3D.new()
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    mat.vertex_color_use_as_albedo = true
    mat.albedo_color = Color.WHITE

    var node := MultiMeshInstance3D.new()
    node.multimesh = mm
    node.material_override = mat
    node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    # Instance transforms are world space; top_level keeps them so wherever this node
    # is parented.
    node.top_level = true
    # These slots are rewritten every tick and reused between marbles, so smoothing
    # them across a tick boundary would draw a comet from one to the other. The
    # marbles themselves stay interpolated -- this is only the effect field.
    node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
    add_child(node)
    return node
