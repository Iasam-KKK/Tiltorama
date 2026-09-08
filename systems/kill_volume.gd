extends Area3D
class_name KillVolume

## Sits below the tray. Anything that falls off enters here and goes back to the pool.

signal fell(at: Vector3)

@export var pool: RollerPool


func _ready() -> void:
    body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
    fell.emit(body.global_position)
    if pool and body is RigidBody3D:
        pool.recycle(body as RigidBody3D)
