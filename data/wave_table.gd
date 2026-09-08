extends Resource
class_name WaveTable

## The threat formula, in one place. Tune the two constants here, not by hand
## per wave:
##     budget(w) = base_value * threat_k * (1 + threat_growth * w)

@export var threat_k := 0.4
@export var threat_growth := 0.15
## No more than this share of a wave's budget goes on a single raider type.
@export var max_share_per_type := 0.4
## How many rims raiders arrive over, indexed by wave - 1.
@export var rims_by_wave: Array[int] = [1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3]
@export var boss_wave := 12
## The raider the boss wave is built around. The director grants one of these on
## that wave instead of drafting it, so it has to know the type by id.
@export var boss_id := "jarl"

@export_group("Pacing")
@export var prep_seconds := 30.0
@export var spawn_interval := 0.45
## Calling the wave early pays this share extra on the kill total.
@export var early_call_bonus := 0.10
## Cleared-screen dwell before the next prep.
@export var cleared_seconds := 3.0
