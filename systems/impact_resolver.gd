extends Node
class_name ImpactResolver

## Impacts with consequences. RollerPool reports every contact and every roller that
## comes to rest; this turns (mass * relative speed) into the roller type's on_impact
## and on_stop effects -- splitters break into three, snowballs shatter into stones,
## sticky rollers stop dead and stand as barriers.
##
## It never writes the physics space and never instances anything: fragments come off
## RollerPool's idle list like any other spawn.
##
## Effects are queued, not run inline. A contact signal arrives while the physics
## server is flushing its query results, and moving bodies from in there is how you
## get "Function blocked during in/out signal" and a cascade that eats itself. One
## physics frame of latency is invisible; a corrupted space is not.

## Fired after the fragments are actually out of the pool, so `count` is what the
## player will see, not what was asked for. `at` is where the parent stood when it
## went, in world space -- a listener does not have to chase a body that is already
## back on the idle list. `from` is the type that broke, which is the colour and the
## voice of the tell. `depth` is how deep in a cascade this link is: 0 for a roller
## that was spawned, 1 for one that was itself a fragment, so a chain can climb in
## pitch or fade out instead of hammering the same sound.
signal did_split(at: Vector3, count: int, from: RollerType, depth: int)
signal did_shatter(at: Vector3, count: int, from: RollerType, depth: int)
signal did_stick(at: Vector3, from: RollerType, depth: int)
## Every effect through one path, for the audio pass, the camera kick and the
## cascade meter. `effect` is the RollerType.EFFECT_* name, so a fourth effect gets
## a sound and a shake without another connection; `momentum` is what set it off
## (mass * relative speed for an impact, mass alone for a stop), which is the
## loudness. Carries `from` and `depth` too, so a listener that only needs a level
## and a hue never has to subscribe to the three did_* signals as well.
signal effect_fired(effect: String, at: Vector3, momentum: float, from: RollerType, depth: int)

## More effects than this in one physics frame and the extras are dropped. A cascade
## that deep has already made its point.
const QUEUE_MAX := 64

@export var roller_pool: RollerPool
## Sticky rollers are barriers "for the rest of the wave", so leaving WAVE releases
## them. Optional: without it they stand until the next clear().
@export var run_state: RunState

@export_group("Trigger")
## A nudge is not an impact, and both gates must pass. The speed gate is on the
## LATERAL closing speed on purpose: a roller dropped out of a quarry hits the tray
## at five metres a second, and if that counted as an impact every splitter would
## burst on landing instead of on the first thing it rolls into.
@export_range(0.0, 20.0, 0.1) var min_impact_speed := 2.0
@export_range(0.0, 60.0, 0.1) var min_impact_momentum := 1.0
## Rollers land in a heap when a quarry mints them, and a heap settling is a lot of
## small contacts. Nothing fires in the first moment of a roller's life.
@export_range(0.0, 5.0, 0.05) var arm_seconds := 0.35

@export_group("Split")
## Defaults for on_impact = "split". A type's on_impact_params override any of them.
@export_range(1, 8, 1) var split_count := 3
@export_range(0.05, 1.0, 0.01) var split_mass_scale := 0.4
## How hard the fragments are thrown apart, in metres per second.
@export_range(0.0, 10.0, 0.1) var split_burst := 1.8
@export var split_child := "stone"
## A fragment that split again would never stop. 1 means the splitter breaks and its
## children do not.
@export_range(0, 4, 1) var max_split_depth := 1

@export_group("Shatter")
## Defaults for on_stop = "shatter". Four quarter-mass fragments off a grown
## snowball is four stones.
@export_range(1, 12, 1) var shatter_count := 4
@export_range(0.05, 1.0, 0.01) var shatter_mass_scale := 0.25
@export_range(0.0, 10.0, 0.1) var shatter_burst := 1.0
@export var shatter_child := "stone"

var _q_body: Array[RigidBody3D] = []
var _q_serial := PackedInt32Array()
var _q_stop := PackedByteArray()
var _q_power := PackedFloat32Array()
var _q_count := 0


func _ready() -> void:
    _q_body.resize(QUEUE_MAX)
    _q_serial.resize(QUEUE_MAX)
    _q_stop.resize(QUEUE_MAX)
    _q_power.resize(QUEUE_MAX)
    if roller_pool:
        roller_pool.roller_impact.connect(_on_roller_impact)
        roller_pool.roller_stopped.connect(_on_roller_stopped)
    if run_state:
        run_state.phase_changed.connect(_on_phase_changed)


## Effects waiting on the next physics frame. Handy in a headless test.
func pending() -> int:
    return _q_count


func _physics_process(_dt: float) -> void:
    if _q_count == 0:
        return
    var n := _q_count
    # Reset first: an effect can enqueue nothing new this frame, but a listener might.
    _q_count = 0
    for i in n:
        var r := _q_body[i]
        _q_body[i] = null
        _apply(r, _q_serial[i], _q_stop[i] == 1, _q_power[i])


# --- intake ---------------------------------------------------------------

func _on_roller_impact(roller: RigidBody3D, _other: Node, type: RollerType, _speed: float, lateral: float, momentum: float) -> void:
    if roller_pool == null or type == null or type.on_impact == RollerType.EFFECT_NONE:
        return
    if lateral < min_impact_speed or momentum < min_impact_momentum:
        return
    if not roller_pool.is_active(roller) or roller_pool.age_of(roller) < arm_seconds:
        return
    _enqueue(roller, false, momentum)


func _on_roller_stopped(roller: RigidBody3D, type: RollerType) -> void:
    if roller_pool == null or type == null or type.on_stop == RollerType.EFFECT_NONE:
        return
    if not roller_pool.is_active(roller):
        return
    # A roller at rest carries no momentum, so its mass is what the effect is worth.
    _enqueue(roller, true, roller.mass)


func _enqueue(roller: RigidBody3D, on_stop: bool, momentum: float) -> void:
    var serial := roller_pool.spawn_serial(roller)
    for i in _q_count:
        # One roller, one fate per frame: a splitter takes several contacts in the
        # frame it lands, and only the first of them is its "first impact".
        if _q_body[i] == roller and _q_serial[i] == serial:
            return
    if _q_count >= QUEUE_MAX:
        return
    _q_body[_q_count] = roller
    _q_serial[_q_count] = serial
    _q_stop[_q_count] = 1 if on_stop else 0
    _q_power[_q_count] = momentum
    _q_count += 1


# --- effects --------------------------------------------------------------

func _apply(roller: RigidBody3D, serial: int, on_stop: bool, momentum: float) -> void:
    if roller_pool == null or roller == null or not roller_pool.is_active(roller):
        return
    # The body may have been recycled and respawned as something else in the frame
    # since it was queued. The serial says whether this is still the same roller.
    if roller_pool.spawn_serial(roller) != serial:
        return
    var type := roller_pool.type_of(roller)
    if type == null:
        return
    var effect: String = type.on_stop if on_stop else type.on_impact
    var at := roller.global_position
    # Read before the effect runs: split_roller() retires the parent, and a retired
    # body reports depth 0 again. This is the LINK's depth -- 0 when a splitter the
    # player poured comes apart, 1 when a fragment does.
    var depth := roller_pool.split_depth(roller)
    match effect:
        RollerType.EFFECT_SPLIT:
            _burst(roller, type, on_stop, at, momentum, depth, false)
        RollerType.EFFECT_SHATTER:
            _burst(roller, type, on_stop, at, momentum, depth, true)
        RollerType.EFFECT_STICK:
            _stick(roller, type, at, momentum, depth)
        _:
            # An unknown effect name is a designer typo, not a crash.
            pass


## Split and shatter are one mechanic: the roller is spent, N smaller ones take its
## place. They differ only in what triggers them and what the fragments weigh.
func _burst(roller: RigidBody3D, type: RollerType, on_stop: bool, at: Vector3, momentum: float, depth: int, as_shatter: bool) -> void:
    if depth >= max_split_depth:
        return
    var count := int(_param(type, on_stop, "count", shatter_count if as_shatter else split_count))
    var scale := float(_param(type, on_stop, "mass_scale", shatter_mass_scale if as_shatter else split_mass_scale))
    var burst := float(_param(type, on_stop, "burst", shatter_burst if as_shatter else split_burst))
    var child_id := String(_param(type, on_stop, "child", shatter_child if as_shatter else split_child))
    var child := roller_pool.type_by_id(child_id)
    var made := roller_pool.split_roller(roller, child, count, scale, burst)
    if made <= 0:
        return
    if as_shatter:
        did_shatter.emit(at, made, type, depth)
        effect_fired.emit(RollerType.EFFECT_SHATTER, at, momentum, type, depth)
    else:
        did_split.emit(at, made, type, depth)
        effect_fired.emit(RollerType.EFFECT_SPLIT, at, momentum, type, depth)


func _stick(roller: RigidBody3D, type: RollerType, at: Vector3, momentum: float, depth: int) -> void:
    if not roller_pool.stick_roller(roller):
        return
    did_stick.emit(at, type, depth)
    effect_fired.emit(RollerType.EFFECT_STICK, at, momentum, type, depth)


func _param(type: RollerType, on_stop: bool, key: String, fallback: Variant) -> Variant:
    return type.stop_param(key, fallback) if on_stop else type.impact_param(key, fallback)


func _on_phase_changed(phase: int) -> void:
    if roller_pool == null or phase == RunState.Phase.WAVE:
        return
    # The wave is over: barriers come loose and anything still queued is stale.
    _q_count = 0
    for i in QUEUE_MAX:
        _q_body[i] = null
    roller_pool.release_stuck()
