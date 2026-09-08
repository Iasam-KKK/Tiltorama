extends Resource
class_name VillagerType

## Everything a designer tunes about the people who live on the tray. Villagers are
## the price of tilting: they slip four degrees before the raiders do, so the tilt
## that steers a roller into a Viking is already enough to put a farmer on his back.

@export var id := "villager"
@export var display_name := "Villager"

@export_group("Housing")
## How many live in one house. StructureType has no field for this and that file
## belongs to someone else, so the house's capacity is a villager property.
@export_range(1, 8, 1) var per_house := 2
## Gold each LIVING villager pays at the end of a wave. Per head, not per house:
## that is what makes one going over the rim an income cut you can feel.
@export var income := 6
## Empty slots refilled per prep phase, per house. A newly bought house fills at
## once -- spending 40 gold has to do something now -- but a villager you lost
## trickles back one per prep, so a bad tilt is felt for more than one wave.
@export_range(0, 8, 1) var repopulate_per_prep := 1

@export_group("Movement")
@export var speed := 1.1
## Four degrees under the raiders' 12. This single number is why "hold the stick
## toward the raiders" is not the dominant strategy.
@export var footing_deg := 8.0
## Seconds leaning on the rim before they go over it. Under the raiders' 0.7,
## because the loss has to actually land.
@export var rim_tip_seconds := 0.5
## Sliding drag. Terminal speed is roughly (9.8 * sin(tilt)) / this, so keep it
## low enough that a sustained lean actually carries them to the edge.
@export_range(0.05, 4.0, 0.05) var slide_drag := 0.35

@export_group("Wandering")
## Seconds stood still at a stop before choosing the next one.
@export var dwell_min := 1.5
@export var dwell_max := 4.5

@export_group("Knocks")
## Knockback below this many kg*m/s is shrugged off. Well under a raider's 1.0:
## a villager is meant to be sent flying by a ball he never saw coming.
@export var knockback_resist := 0.35
@export var mass := 0.7

@export_group("Look")
## Warm and pale against the raiders' near-black and the rollers' blue, so a
## glance from above tells you whose body is sliding.
@export var colour := Color("e3c08a")
@export var height := 0.7
@export var radius := 0.17

@export_group("Voice")
## Shown over their head when they lose their footing. The fall is a laugh first
## and a loss second; this is the laugh. Day 9 can pick a sample to match.
@export var cries: PackedStringArray = ["Whoa!", "Oi!", "Steady!", "Aaah!", "My legs!"]
## World metres per font pixel. The camera sits 32 m out, so small text is unreadable.
@export_range(0.002, 0.08, 0.001) var cry_pixel_size := 0.014
@export var cry_seconds := 1.1
