extends StaticBody3D
class_name Keep

## The core. There is no hero to die; the run ends when this reaches zero.

signal hp_changed(hp: int, max_hp: int)
signal destroyed()

@export var max_hp := 100
## Counts 5 toward the threat formula's base value.
@export var base_value := 5

var hp := 100


func _ready() -> void:
    collision_layer = 1
    collision_mask = 1
    hp = max_hp


func reset() -> void:
    hp = max_hp
    hp_changed.emit(hp, max_hp)


func take_damage(amount: int) -> void:
    if hp <= 0:
        return
    hp = maxi(0, hp - amount)
    hp_changed.emit(hp, max_hp)
    if hp == 0:
        destroyed.emit()
