extends Resource
class_name StructureType

## Placed in prep, static during a wave. Every structure carries a base value, and
## the wave director spends a raider budget derived from the total: bigger kingdom,
## bigger raid.

## APPEND ONLY. Every .tres stores its kind as the integer, and Structure.is_quarry()
## -- which RunState reads to decide what mints at the head of a wave -- compares
## against these values. Inserting a member renumbers every kind after it and
## silently turns saved walls into ramps.
enum Kind {
    WALL,
    RAMP,
    GATE,
    QUARRY,
    BUMPER,
    HOUSE,
    FUNNEL,
    HALF_PIPE,
    RIM_SPIKES,
    RETURN_CHUTE,
    KEEP_UPGRADE,
}

@export var id := "wall"
@export var display_name := "Wall"
@export var kind: Kind = Kind.WALL
@export var cost := 20
@export var base_value := 1
## The box the placement rules reason about: overlap, tray bounds, and the grid the
## seal check rasterises. A kind built from several slabs (a funnel, a half-pipe)
## still declares the box those slabs live inside, because that is what the player
## is spending tray space on.
@export var footprint := Vector3(1.0, 1.0, 1.0)
@export var colour := Color("8c7b62")
## Optional GLB shown instead of the primitive. Only for single-slab kinds: a model
## replaces ALL of the generated art, so a funnel or a half-pipe wearing one would
## lose the shape that is the whole point of it.
@export var model: PackedScene
@export var description := ""
## Does it stand in the way? False builds the art and the hazard volume but no
## collision at all, so nothing routes around it and the navmesh does not see it.
## That is how rim spikes trap somebody instead of being politely walked past.
@export var solid := true

@export_group("Damage")
## Hit points. 0 means indestructible, and take_damage() on it is a no-op.
##
## Zero is the right answer for anything whose destruction would have to cascade
## into a system that does not own it: a quarry mints at the head of a wave and a
## house is billed for beds, so losing one mid-wave is a rule those systems have to
## write before the hit points here would be honest.
@export var max_hp := 0
## What it stains towards as it is beaten in. Painted on as a material overlay, so
## it works over a GLB's own materials as well as over a primitive's colour.
@export var damage_colour := Color(0.10, 0.07, 0.05)
## Overlay opacity at the last hit point. All three of these read as a fraction of
## the damage taken, so a wall at half health is half way through every one of them.
@export_range(0.0, 1.0, 0.01) var damage_tint := 0.55
## How far the art leans over as it goes. The COLLISION never moves: a wall that
## stopped a roller at full health has to stop the same roller at one hit point, or
## the damage state would be a nerf the player never agreed to.
@export_range(0.0, 25.0, 0.5) var damage_lean_deg := 7.0
## ...and how far it settles into the tray.
@export_range(0.0, 1.0, 0.01) var damage_sink := 0.12

@export_group("Kind specific")
## QUARRY: rollers minted at the start of each wave.
@export var mint_per_wave := 4
## BUMPER: restitution of its surface.
@export var bounce := 0.95
## RAMP: how far it falls across its own length.
@export var drop := 0.6
## FUNNEL, HALF_PIPE, RIM_SPIKES: how thick each of the slabs it is built from is.
@export var wall_thickness := 0.2

@export_subgroup("Funnel")
## The gap the two walls leave at the narrow end. A spread of rollers that crosses
## the mouth leaves the throat in a line, which is the whole trick.
@export var throat_width := 0.6

@export_subgroup("Half-pipe")
## Radius of the banked turn.
@export var arc_radius := 1.6
## How much of a turn it makes.
@export_range(10.0, 180.0, 5.0) var arc_deg := 90.0
## Slabs the arc is chopped into. More is smoother and costs more colliders.
@export_range(1, 16, 1) var arc_segments := 6
## How far the wall leans in over the turn. This is what keeps the speed: a
## vertical wall spends a roller's momentum on the impact, a banked one turns it.
@export_range(0.0, 60.0, 1.0) var bank_deg := 32.0

@export_subgroup("Rim spikes")
## The collision layers the spikes are lethal to. 4 = raiders, 8 = villagers.
##
## Rollers (2) are deliberately off by default. A roller that has reached a rim is
## already going over it and is already counted lost by the kill volume, so killing
## it here would double-count the loss AND fight the return chute for the same
## marble. Villagers being on the list is not an oversight -- it is the trade.
@export_flags_3d_physics var lethal_layers := 4 | 8
## How far past the footprint the lethal volume reaches, so an agent's capsule
## overlaps a strip low enough to see the tray over.
@export var hazard_margin := 0.25

@export_subgroup("Return chute")
## How far from the chute a roller may leave the tray and still be caught. Measured
## across the tray only: by the time the kill volume sees a roller it is metres
## below the chute.
@export var catch_radius := 2.4
## The share of those it actually gives back.
@export_range(0.0, 1.0, 0.01) var recovery_chance := 0.5
## How high above the chute a recovered roller is poured back in, so it rolls out
## onto the tray instead of being teleported into the middle of the kingdom.
@export var return_height := 1.2

@export_subgroup("Keep upgrade")
## The band, measured from the keep's centre, an annex may be built in: x is how
## close it may come (it has to clear the keep's own walls), y how far out it may
## sit and still count as bolted on. A y of zero means "not an annex" and leaves
## the ordinary keep clearance in force, which is what every other kind wants.
@export var keep_annex_band := Vector2.ZERO
## Gates that may be built INSIDE the keep's clearance ring while this stands. The
## sally port: one slot per upgrade is what the bible asks for.
@export_range(0, 4, 1) var gate_slots := 0
