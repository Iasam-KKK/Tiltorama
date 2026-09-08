extends Resource
class_name StructureType

## Placed in prep, static during a wave. Every structure carries a base value, and
## the wave director spends a raider budget derived from the total: bigger kingdom,
## bigger raid.

## APPEND ONLY. Every .tres stores its kind as the integer, and Structure.is_quarry()
## -- which RunState reads to decide what mints at the head of a wave -- compares
## against these values. Inserting a member renumbers every kind after it and
## silently turns saved walls into ramps.
enum Kind { WALL, RAMP, GATE, QUARRY, BUMPER, HOUSE }

@export var id := "wall"
@export var display_name := "Wall"
@export var kind: Kind = Kind.WALL
@export var cost := 20
@export var base_value := 1
@export var footprint := Vector3(1.0, 1.0, 1.0)
@export var colour := Color("8c7b62")
## Optional GLB shown instead of the primitive.
@export var model: PackedScene
@export var description := ""

@export_group("Kind specific")
## QUARRY: rollers minted at the start of each wave.
@export var mint_per_wave := 4
## BUMPER: restitution of its surface.
@export var bounce := 0.95
## RAMP: how far it falls across its own length.
@export var drop := 0.6
