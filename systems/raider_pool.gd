extends Node3D
class_name RaiderPool

## Pre-instanced raiders, same discipline as the rollers: nothing is instanced
## mid-wave.

signal raider_died(type: RaiderType, fell: bool)
signal emptied()

@export var tilt_controller: TiltController
@export var keep: Node3D
@export_range(1, 200, 1) var pool_size := 80
## Distance from tray centre to the inside face of a rim.
@export var tray_half := 5.6

var _all: Array[Raider] = []
var _idle: Array[Raider] = []


func _ready() -> void:
    for i in pool_size:
        var r := Raider.new()
        add_child(r)
        r.died.connect(_on_died)
        r.park()
        _all.append(r)
        _idle.append(r)


func alive_count() -> int:
    return _all.size() - _idle.size()


func spawn(type: RaiderType, from: Vector3, to: Vector3) -> Raider:
    if _idle.is_empty():
        return null
    var r: Raider = _idle.pop_back()
    r.tray_half = tray_half
    r.launch(type, tilt_controller, keep, from, to)
    return r


func clear_all() -> void:
    for r in _all:
        if not _idle.has(r):
            r.park()
            _idle.append(r)


## Rollers report their contacts here so raiders do not each need a monitor.
func notify_roller_contact(other: Node, roller: RigidBody3D, speed: float) -> void:
    var raider := other as Raider
    if raider:
        raider.hit_by_roller(roller, speed)


func _on_died(raider: Raider, fell: bool) -> void:
    var type := raider.type
    raider.park()
    if not _idle.has(raider):
        _idle.append(raider)
    raider_died.emit(type, fell)
    if alive_count() == 0:
        emptied.emit()
