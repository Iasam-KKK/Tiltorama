extends Node
class_name TiltController

## The tray never moves. The stick sets a target tilt; a spring-damper carries the
## current tilt toward it; every physics frame the world's gravity VECTOR is rotated
## by that tilt and the camera rig is rotated to match.
##
## Architecture rule: this is the only node that writes to the physics space.
## Everything else reads `tilt` or listens to the signals below.

signal tilt_changed(tilt_deg: Vector2)
signal tilt_active_changed(active: bool)
signal levelled()

@export var camera_rig: Node3D

@export_group("Feel")
## How far the world can lean. Raiders slip exactly here (day 3).
@export_range(0.0, 30.0, 0.1) var max_tilt_deg := 12.0
## How fast the target angle chases the stick. Too fast reads twitchy, too slow mushy.
@export_range(5.0, 200.0, 1.0) var tray_speed_deg := 40.0
## Spring and damping carry the current tilt to the target.
@export_range(1.0, 60.0, 0.1) var spring := 18.0
@export_range(0.0, 30.0, 0.1) var damping := 6.0
## The panic button's cooldown. Keeps levelling a decision.
@export_range(0.0, 10.0, 0.1) var level_cooldown := 3.0

@export_group("Input")
@export var invert_x := false
@export var invert_y := false
## Keep the horizon level and let the tray lean on screen instead. For anyone the
## camera roll makes uncomfortable; gravity is unaffected either way.
@export var lock_camera := false
## Hold right mouse button and drag as an alternative to the stick.
@export var mouse_drag := true
@export_range(0.001, 0.05, 0.001) var mouse_sensitivity := 0.008

const GRAVITY := 9.8
## Below this the tray counts as level, and rollers are allowed to sleep again.
const SETTLED_DEG := 0.05

## Degrees. x = roll (stick left/right), y = pitch (stick up/down).
var tilt := Vector2.ZERO
## Where "down" currently points. Read by raiders and villagers; written only here.
var gravity_dir := Vector3.DOWN
var target := Vector2.ZERO
var velocity := Vector2.ZERO

var _space: RID
var _level_timer := 0.0
var _mouse := Vector2.ZERO
var _dragging := false
var _active := false


func _ready() -> void:
    _space = get_viewport().find_world_3d().space
    PhysicsServer3D.area_set_param(_space, PhysicsServer3D.AREA_PARAM_GRAVITY, GRAVITY)
    PhysicsServer3D.area_set_param(_space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3.DOWN)


func level_cooldown_left() -> float:
    return _level_timer


func is_active() -> bool:
    return _active


func _unhandled_input(event: InputEvent) -> void:
    if not mouse_drag:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
        _dragging = event.pressed
        if not _dragging:
            _mouse = Vector2.ZERO
    elif event is InputEventMouseMotion and _dragging:
        _mouse = (_mouse + event.relative * mouse_sensitivity).limit_length(1.0)


func _physics_process(dt: float) -> void:
    var stick := Input.get_vector("tilt_left", "tilt_right", "tilt_up", "tilt_down")
    if _dragging:
        stick = _mouse
    if invert_x:
        stick.x = -stick.x
    if invert_y:
        stick.y = -stick.y

    target = target.move_toward(stick.limit_length(1.0) * max_tilt_deg, tray_speed_deg * dt)

    _level_timer = maxf(0.0, _level_timer - dt)
    if Input.is_action_just_pressed("tray_level") and _level_timer == 0.0:
        target = Vector2.ZERO
        tilt = Vector2.ZERO
        velocity = Vector2.ZERO
        _mouse = Vector2.ZERO
        _level_timer = level_cooldown
        levelled.emit()

    velocity += (target - tilt) * spring * dt - velocity * damping * dt
    tilt += velocity * dt

    # Hard cap at max_tilt_deg: clamp the angle and drop only the outward part of
    # the velocity, so overshoot still reads as weight everywhere below the cap.
    if tilt.length() > max_tilt_deg:
        var n := tilt.normalized()
        tilt = n * max_tilt_deg
        var outward := velocity.dot(n)
        if outward > 0.0:
            velocity -= n * outward

    _apply()


func _apply() -> void:
    # Same rotation for gravity and camera. Physically this is the tray-local frame
    # of a tray rotated the other way, so both must use the SAME basis -- if they
    # disagree in sign the marbles roll uphill on screen.
    var b := Basis.from_euler(Vector3(deg_to_rad(-tilt.y), 0.0, deg_to_rad(tilt.x)))
    gravity_dir = (b * Vector3.DOWN).normalized()
    PhysicsServer3D.area_set_param(_space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, gravity_dir)
    if camera_rig:
        camera_rig.rotation = (Vector3.ZERO if lock_camera
            else Vector3(deg_to_rad(-tilt.y), 0.0, deg_to_rad(tilt.x)))

    tilt_changed.emit(tilt)
    var now_active := tilt.length() > SETTLED_DEG or velocity.length() > SETTLED_DEG
    if now_active != _active:
        _active = now_active
        tilt_active_changed.emit(_active)


## Day 3, for raiders and villagers: the angle between gravity and a surface normal.
func effective_slope_deg(surface_normal: Vector3) -> float:
    var g: Vector3 = PhysicsServer3D.area_get_param(_space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR)
    return rad_to_deg(acos(clampf(g.dot(-surface_normal), -1.0, 1.0)))
