extends Resource
class_name RaiderType

## They walk, they don't roll. Everything a designer tunes about a raider lives here
## so balance changes never touch code.

@export var id := "grunt"
@export var display_name := "Grunt"

@export_group("Wave director")
## What one of these costs out of the wave's budget.
@export var budget_cost := 1
## Earliest wave this type can appear on.
@export var unlock_wave := 1

@export_group("Movement")
@export var speed := 1.6
## The effective slope at which this type starts to slip.
@export var footing_deg := 12.0
## Anchor-men drive a stake and never slip.
@export var never_slips := false
## Climbers scale walls. Greybox: they ignore wall collision.
@export var climbs_walls := false

@export_group("Combat")
## Knockback below this many kg*m/s is shrugged off. Shieldwalls sit at 2x.
@export var knockback_resist := 1.0
@export var mass := 1.0
@export var keep_damage := 3
@export var attack_interval := 1.0

@export_group("Reward")
@export var gold := 3

@export_group("Look")
@export var colour := Color("2f3138")
@export var height := 0.85
@export var radius := 0.2
