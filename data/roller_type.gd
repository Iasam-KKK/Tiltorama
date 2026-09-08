extends Resource
class_name RollerType

## They roll, they don't walk. Everything a designer tunes about a roller lives here
## so a balance pass never touches code: RollerPool reads the body and look numbers,
## ImpactResolver reads on_impact / on_stop.
##
## Sizes are derived, not authored twice: a roller's drawn radius follows its mass
## (radius * cbrt(mass / type mass)), which is what lets a snowball grow and a split
## fragment come out visibly smaller from the same resource.

## Effect names. ImpactResolver dispatches on these; an unknown name is a no-op, so
## a half-finished .tres can never crash a wave.
const EFFECT_NONE := ""
## Breaks into `count` smaller rollers of `child` type on its FIRST real impact.
const EFFECT_SPLIT := "split"
## Stops dead where it hits and stands as a barrier for the rest of the wave.
const EFFECT_STICK := "stick"
## Same mechanic as split, different intent: what a snowball leaves behind when it
## runs out of hill.
const EFFECT_SHATTER := "shatter"

@export var id := "stone"
@export var display_name := "Stone"
## One line for the draft card and the shop, same as StructureType carries.
@export var description := ""

@export_group("Body")
## 0.22 is the baseline marble. Everything else on the tray is sized against it.
@export_range(0.05, 1.0, 0.01) var radius := 0.22
@export_range(0.05, 20.0, 0.05) var mass := 1.0
@export_range(0.0, 1.0, 0.01) var friction := 0.35
@export_range(0.0, 1.0, 0.01) var restitution := 0.3

@export_group("Combat")
## Multiplies the momentum a raider feels from a hit. The roller still weighs what
## it weighs -- this is the knock, not the physics, so iron can hit like three
## stones without dragging like three stones.
@export_range(0.0, 8.0, 0.05) var knockback := 1.0

@export_group("Growth")
## Snowball. Mass climbs with distance rolled, and the drawn radius follows it.
@export var grows := false
## Kilograms added per metre rolled.
@export_range(0.0, 5.0, 0.01) var grow_per_metre := 0.0
## Ceiling for the growth, in kilograms.
@export_range(0.05, 20.0, 0.05) var grow_max_mass := 1.0

@export_group("Effects")
## One of the EFFECT_* names above. Empty means the roller just hits things.
@export var on_impact := EFFECT_NONE
## Effect arguments. Recognised keys: "child" (roller id), "count", "mass_scale",
## "burst" (m/s the fragments are thrown apart at).
@export var on_impact_params: Dictionary = {}
## Fired once when the roller comes to rest after actually having rolled.
@export var on_stop := EFFECT_NONE
@export var on_stop_params: Dictionary = {}

@export_group("Economy")
## Gold per roller in the shop. Stone is the volume buy.
@export var cost := 4
## Relative odds of this type coming out of an untyped spawn (quarry mint, the
## opening stockpile). Zero means it is bought, never drafted.
@export_range(0.0, 20.0, 0.05) var draft_weight := 1.0
## What this type is an answer to, for the draft's weighting: "swarm", "armour",
## "climb", "anchor", "economy". Left empty, the draft infers them from mass and
## bounce, which is right for all six stock types.
@export var tags: Array[String] = []

@export_group("Look")
## Rollers are the only saturated objects on the tray, so each type owns a hue that
## survives the top-down camera.
@export var colour := Color("3e86d9")


## Effects read their arguments through these so a missing key falls back to the
## caller's default instead of erroring mid-cascade.
func impact_param(key: String, fallback: Variant) -> Variant:
	return on_impact_params.get(key, fallback)


func stop_param(key: String, fallback: Variant) -> Variant:
	return on_stop_params.get(key, fallback)


## Heaviest this type can ever be. RollerPool pre-builds meshes up to this size.
func peak_mass() -> float:
	return maxf(mass, grow_max_mass) if grows else mass


## Drawn radius for a given mass, so growth and split fragments stay honest about
## how much they weigh.
func radius_for_mass(m: float) -> float:
	return radius * pow(maxf(m, 0.001) / maxf(mass, 0.001), 1.0 / 3.0)
