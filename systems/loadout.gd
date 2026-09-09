extends Node
class_name Loadout

## The run's mutable kit: which roller types the quarries mint, which structures are
## in the build palette, which tray modifiers are live. The draft writes here and
## nothing else does; every other system reads it.
##
## Two notes on coupling, because both look odd at first glance:
##
##  * `build_system` is typed Node, not BuildSystem, deliberately. BuildSystem
##    already exports a RunState and RunState exports a Loadout, so naming the
##    class here would close a parse-time cycle. The palette is a plain exported
##    array; writing it from outside is enough and adds no code to BuildSystem.
##  * A modifier's effects are a flat dictionary of key -> value. A key ending in
##    "_mul" is multiplied together, any other numeric key is summed, and a stacked
##    modifier applies its effect once per stack. That one rule is the whole
##    system, which is what lets a new modifier be data instead of code.

signal changed()
signal roller_type_added(type: Resource)
signal structure_unlocked(type: StructureType)
signal modifier_added(modifier: Dictionary)

## Matches the top of TiltController.max_tilt_deg's export range: the steepest lean
## the tray can be configured for, and the ceiling a tilt card is clamped to.
const TILT_CEILING_DEG := 30.0

@export var build_system: Node
@export var roller_pool: RollerPool
@export var tilt_controller: TiltController

@export_group("Starting kit")
## What the player opens the run with. Everything else already sitting in the
## build system's palette becomes draftable, so adding a structure to the palette
## in build_main.gd turns it into a card without touching this file, and an id
## listed here that nobody has built yet simply matches nothing. An id list that
## matches nothing at all falls back to the whole palette rather than leaving the
## player unable to build.
@export var starting_structure_ids: Array[String] = ["quarry", "gate", "ramp", "half_pipe"]
## Roller types minted from wave 1. Empty is the correct value until roller cards
## exist: the pool goes on minting its default sphere.
@export var starting_roller_types: Array[Resource] = []
## How many of a roller type are tipped onto the tray the MOMENT its card is taken.
##
## Zero is the old behaviour: the type is recorded and the player waits. That wait
## is why taking Iron read as a no-op. The quarries are the only other route onto
## the tray, they run once at the head of a wave, they cut five between them, and
## they share those five round-robin across every type drafted so far -- so the
## reward for picking Iron was two orange marbles arriving a wave later onto a tray
## already holding thirty blue ones, and none at all for a player with no quarry up.
## A card the player cannot see land is a card that did not happen. Six is roughly a
## fifth of the opening stockpile: enough of the new hue to read from the top-down
## camera, not so much that the card hands the wave over.
@export_range(0, 40, 1) var roller_card_sample := 6

@export_group("Limits")
## The villager type a footing card is measured against; only footing_deg is read.
## Wiring it is optional -- unwired, the cap falls back to what VillagerType ships,
## so the guard rail holds either way. It is a plain Resource reference rather than
## a VillagerPool because villager_pool.gd exports a Loadout and naming the pool
## here would close a parse-time cycle.
@export var villager_type: VillagerType
## Degrees of lean that must stay ABOVE villager footing at full tilt. This is the
## width of the band where the tray is steep enough to put a farmer on his back, and
## villagers slipping before the raiders do is the designed price of tilting. A
## footing card is capped to leave this band open: at zero, a big enough stack would
## price villagers out of slipping entirely and "hold the stick at the raiders" would
## become the dominant line.
@export_range(0.0, 10.0, 0.1) var villager_slip_headroom_deg := 2.0

## Roller types the quarries mint from. Read by RunState when it mints.
var roller_types: Array[Resource] = []
## The live build palette: starting kit plus everything drafted.
var structures: Array[StructureType] = []
## Active tray modifiers, one entry per stack.
var modifiers: Array[Dictionary] = []

var _catalogue: Array[StructureType] = []
var _base_max_tilt := 12.0
var _base_friction := 0.35
var _base_restitution := 0.3
var _base_stockpile := 30
## The stockpile the last _apply_to_world() pushed to the pool. -1 until the first
## one, so the opening apply is never read as a card having raised it.
var _applied_stockpile := -1
## What VillagerType ships, read off the class rather than repeated as a literal
## here: the cap must not drift when a designer retunes the villagers.
var _shipped_villager_footing: float = VillagerType.new().footing_deg
var _mint_cursor := 0
var _captured := false


func _ready() -> void:
    _capture_baselines()
    reset_run()


## Called by RunState.start_run(). Everything the draft granted goes away and the
## nodes the modifiers touched go back to the numbers the designer shipped.
func reset_run() -> void:
    _capture_baselines()

    roller_types.clear()
    for t in starting_roller_types:
        if t:
            roller_types.append(t)

    modifiers.clear()

    structures.clear()
    for t in _catalogue:
        if t and starting_structure_ids.has(String(t.id)):
            structures.append(t)
    if structures.is_empty():
        # A mis-typed id list must never leave the player with nothing to build.
        for t in _catalogue:
            structures.append(t)

    _mint_cursor = 0
    _push_palette()
    _apply_to_world()
    changed.emit()


# --- what the draft can grant -----------------------------------------------

func add_roller_type(type: Resource) -> bool:
    if type == null or roller_types.has(type):
        return false
    roller_types.append(type)
    # Poured here for the same reason Full Stores pours its stock in
    # _apply_to_world() rather than leaving it as a number: what the card grants is
    # read at the head of a wave and nowhere else, so on its own it moves nothing
    # the player can see until the wave after next. This is the one moment the
    # player is looking straight at the choice, so it is the moment the new hue has
    # to appear on the tray.
    if roller_pool and roller_card_sample > 0:
        roller_pool.mint_type(type, roller_card_sample)
    roller_type_added.emit(type)
    changed.emit()
    return true


func unlock_structure(type: StructureType) -> bool:
    if type == null or structures.has(type):
        return false
    structures.append(type)
    _push_palette()
    structure_unlocked.emit(type)
    changed.emit()
    return true


func add_modifier(modifier: Dictionary) -> bool:
    if modifier.is_empty():
        return false
    var id := String(modifier.get("id", ""))
    if id.is_empty() or modifier_stacks(id) >= max_stacks_of(modifier):
        return false
    modifiers.append(modifier.duplicate(true))
    # true: this apply is a card landing mid-run, so anything the pools only read
    # at start-up -- the stockpile -- has to be delivered by hand here.
    _apply_to_world(true)
    modifier_added.emit(modifier)
    changed.emit()
    return true


# --- what the draft asks about ----------------------------------------------

## Structures in the catalogue that are not in the palette yet: the structure card
## pool. Empty when everything is already unlocked, which is a valid offer state.
func locked_structures() -> Array[StructureType]:
    var out: Array[StructureType] = []
    for t in _catalogue:
        if t and not structures.has(t):
            out.append(t)
    return out


func has_modifier(id: String) -> bool:
    return modifier_stacks(id) > 0


func modifier_stacks(id: String) -> int:
    var n := 0
    for m in modifiers:
        if String(m.get("id", "")) == id:
            n += 1
    return n


func max_stacks_of(modifier: Dictionary) -> int:
    return maxi(1, int(modifier.get("max_stacks", 1)))


## tag -> how many things the player owns that answer it. The draft subtracts this
## from the pressure the coming wave puts on the same tags.
func owned_tags() -> Dictionary:
    var out := {}
    for s in structures:
        for tag in tags_for_structure(s):
            out[tag] = int(out.get(tag, 0)) + 1
    for r in roller_types:
        for tag in tags_for_roller(r):
            out[tag] = int(out.get(tag, 0)) + 1
    for m in modifiers:
        for tag in tag_list(m.get("counters")):
            out[tag] = int(out.get(tag, 0)) + 1
    return out


## A resource may declare its own tags in a "counters" or "tags" array; nothing
## does yet, so both structures and rollers fall back to what they obviously are.
func tags_for_structure(type: StructureType) -> Array[String]:
    var declared := declared_tags(type)
    if not declared.is_empty():
        return declared
    var out: Array[String] = []
    if type == null:
        return out
    match type.kind:
        StructureType.Kind.WALL:
            out.append("swarm")
        StructureType.Kind.GATE:
            out.append("armour")
            out.append("swarm")
        StructureType.Kind.RAMP:
            out.append("armour")
        StructureType.Kind.BUMPER:
            out.append("climb")
            out.append("swarm")
        StructureType.Kind.QUARRY:
            out.append("economy")
        # HOUSE deliberately answers nothing. A house is the liability the wave
        # pushes on -- people to lose -- not a counter to any of it, so owning one
        # must not read as coverage. (It used to fall into the WALL branch and
        # claim "swarm" purely because both were kind 0.)
    return out


func tags_for_roller(type: Resource) -> Array[String]:
    var declared := declared_tags(type)
    if not declared.is_empty():
        return declared
    var out: Array[String] = []
    if type == null:
        return out
    # Heavy rollers are the answer to a shieldwall; bouncy ones reach a climber a
    # rolling shot would pass underneath.
    if res_number(type, "mass", 1.0) >= 1.8:
        out.append("armour")
    if res_number(type, "restitution", res_number(type, "bounce", 0.3)) >= 0.6:
        out.append("climb")
    if out.is_empty():
        out.append("swarm")
    return out


func declared_tags(res: Resource) -> Array[String]:
    var out: Array[String] = []
    if res == null:
        return out
    out = tag_list(res.get("counters"))
    if out.is_empty():
        out = tag_list(res.get("tags"))
    return out


func tag_list(value: Variant) -> Array[String]:
    var out: Array[String] = []
    if value is Array:
        for e in value:
            out.append(String(e))
    return out


# --- what the modifiers add up to -------------------------------------------

func effect_total(key: String) -> float:
    var total := 0.0
    for m in modifiers:
        var v: Variant = _effects_of(m).get(key)
        if v is float or v is int:
            total += float(v)
    return total


func effect_factor(key: String) -> float:
    var factor := 1.0
    for m in modifiers:
        var v: Variant = _effects_of(m).get(key)
        if v is float or v is int:
            factor *= float(v)
    return factor


## Extra rollers each quarry mints at the start of a wave. Read by RunState.
func quarry_mint_bonus() -> int:
    return int(roundf(effect_total("quarry_mint_bonus")))


## Rollers poured from the pool at the start of every wave, on top of the quarries.
func wave_start_rollers() -> int:
    return int(roundf(effect_total("wave_start_rollers")))


func prep_seconds_bonus() -> float:
    return effect_total("prep_seconds_bonus")


## Degrees of extra footing for villagers, capped so no stack of cards can switch
## the villager-slip mechanic off. Villagers losing their feet four degrees before
## the raiders do is the price of tilting, and the thing that stops "hold the stick
## at the raiders" being dominant: push their footing past the steepest slope the
## stick can reach and they simply stop falling over. The cap rides on the tilt
## ceiling rather than on a fixed number, so Steady Hand widens the room for footing
## exactly as much as it widens the range the tray can produce, and no card here has
## to know which other cards exist.
func villager_footing_bonus() -> float:
    var ceiling := reachable_tilt_deg() - villager_slip_headroom_deg
    # minf, not clampf: a future card that made footing WORSE is still allowed
    # through. The cap only stops footing running away upward.
    return minf(effect_total("villager_footing_bonus"), maxf(0.0, ceiling - villager_base_footing()))


## The footing villagers start from, read off the wired VillagerType so the cap is
## never measured against a number that lives only in this file.
func villager_base_footing() -> float:
    return res_number(villager_type, "footing_deg", _shipped_villager_footing)


## The steepest slope the stick can actually reach, tilt cards included. Read from
## the controller when there is one, so the debug slider counts too; computed from
## the baseline when there is not, which is the headless case.
func reachable_tilt_deg() -> float:
    if tilt_controller:
        return tilt_controller.max_tilt_deg
    return clampf(_base_max_tilt + effect_total("max_tilt_bonus"), 0.0, TILT_CEILING_DEG)


## Rims the draft has frozen, lower case ("north"). Nothing feeds this today: the
## two ice cards were withdrawn from DraftSystem.tray_modifiers because no node owns
## a per-rim surface, and because raiders and villagers are CharacterBody3D and read
## their footing off the tilt, never off a PhysicsMaterial -- so ice is a slip rule
## in the agents, not a friction number on the tray. Kept as the hook the day that
## rule exists: populate the effect and the cards work with no change here.
func ice_rims() -> Array[String]:
    var out: Array[String] = []
    for m in modifiers:
        var v: Variant = _effects_of(m).get("rim_ice")
        if v is String or v is StringName:
            var rim := String(v).to_lower()
            if not out.has(rim):
                out.append(rim)
    return out


func is_rim_iced(rim: String) -> bool:
    return ice_rims().has(rim.to_lower())


## Round-robin over the drafted roller types, so a quarry minting four rollers with
## two types minted two of each. Returns null while no roller card has landed.
func next_mint_type() -> Variant:
    if roller_types.is_empty():
        return null
    var t: Resource = roller_types[_mint_cursor % roller_types.size()]
    _mint_cursor += 1
    return t


func describe() -> String:
    var parts: Array[String] = []
    parts.append("build %d" % structures.size())
    parts.append("rollers %d" % roller_types.size())
    for m in modifiers:
        parts.append(String(m.get("title", m.get("id", "?"))))
    return "   ".join(parts)


# --- reading and writing the world ------------------------------------------

func _capture_baselines() -> void:
    if _captured:
        return
    _captured = true
    if build_system:
        var palette: Variant = build_system.get("palette")
        if palette is Array:
            for t in palette:
                var s := t as StructureType
                if s and not _catalogue.has(s):
                    _catalogue.append(s)
    if tilt_controller:
        _base_max_tilt = tilt_controller.max_tilt_deg
    if roller_pool:
        _base_friction = roller_pool.friction
        _base_restitution = roller_pool.restitution
        _base_stockpile = roller_pool.stockpile


func _push_palette() -> void:
    if build_system == null:
        return
    var out: Array[StructureType] = []
    for t in structures:
        out.append(t)
    build_system.set("palette", out)
    var selected: Variant = build_system.get("selected")
    if selected is int and int(selected) >= out.size():
        build_system.set("selected", maxi(0, out.size() - 1))


## Recomputed from the captured baselines every time, so stacking a modifier twice
## and then restarting the run cannot leave a multiplier compounded into the node.
##
## `pour_new_stock` is true only when a card has just landed. The friction, bounce
## and tilt numbers are read live by the nodes that own them, but `stockpile` is
## read by RollerPool in _ready() and respawn() and nowhere else, so raising it
## mid-run moves nothing on its own: the extra stones have to be tipped onto the
## tray here or the card does nothing until the run after next.
func _apply_to_world(pour_new_stock := false) -> void:
    if tilt_controller:
        tilt_controller.max_tilt_deg = clampf(_base_max_tilt + effect_total("max_tilt_bonus"), 0.0, TILT_CEILING_DEG)
    if roller_pool:
        roller_pool.friction = clampf(_base_friction * effect_factor("tray_friction_mul"), 0.0, 1.0)
        roller_pool.restitution = clampf(_base_restitution * effect_factor("roller_bounce_mul"), 0.0, 1.0)
        var stock := clampi(_base_stockpile + int(roundf(effect_total("roller_stockpile_bonus"))), 1, 200)
        # The delta, never the shortfall against what is on the tray: pouring up to
        # the stockpile would hand a player who had just lost forty rollers over the
        # rim forty more, and the recovery bonus is measured off that same count.
        var extra := (stock - _applied_stockpile) if _applied_stockpile >= 0 else 0
        _applied_stockpile = stock
        roller_pool.stockpile = stock
        if pour_new_stock and extra > 0:
            roller_pool.spawn(extra)


func _effects_of(modifier: Dictionary) -> Dictionary:
    var raw: Variant = modifier.get("effects")
    if raw is Dictionary:
        return raw
    return {}


# --- duck-typed reads, for resources whose class may not exist yet -----------

func res_number(res: Resource, key: String, fallback: float) -> float:
    if res == null:
        return fallback
    var v: Variant = res.get(key)
    if v is float or v is int:
        return float(v)
    return fallback


func res_string(res: Resource, key: String, fallback: String) -> String:
    if res == null:
        return fallback
    var v: Variant = res.get(key)
    if (v is String or v is StringName) and not String(v).is_empty():
        return String(v)
    return fallback
