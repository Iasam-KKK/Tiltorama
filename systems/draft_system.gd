extends Node
class_name DraftSystem

## One of three, after every cleared wave. A card is a roller type for the
## quarries, a structure for the build menu, or a tray modifier. The run waits on
## the pick rather than a timer, so the offer has to be worth reading.
##
## Weighting leans toward what the player has no answer to. The wave director's
## roster says what is coming, the loadout says what the player owns, and the
## difference between them is the weight: a player with nothing that breaks a
## shieldwall sees the heavy roller far more often than someone who already has it.
##
## Cards are plain Dictionaries built from three pools, any of which may be empty
## -- the roller pool is empty on a fresh checkout until roller .tres files land.
## An empty pool contributes nothing, and if all three are empty open_for()
## returns false so the run goes straight to prep instead of stalling.

enum Kind { ROLLER, STRUCTURE, MODIFIER }

signal offer_made(wave: int, cards: Array)
signal card_taken(index: int, card: Dictionary)
signal skipped()
signal closed()

@export var loadout: Loadout
@export var economy: Economy
@export var wave_director: WaveDirector

@export_group("Offer")
@export_range(1, 5, 1) var cards_per_offer := 3
## Skipping the offer costs gold. The button is disabled below this, and taking a
## card is always free, so the player can never be stuck.
@export var skip_cost := 15

@export_group("Pools")
## Roller types on offer. Left empty, the directory below is scanned instead,
## which is what lets the roller cards appear the moment someone adds the .tres
## files without anyone editing this script or the scene.
@export var roller_types: Array[Resource] = []
@export_dir var roller_dir: String = "res://data/rollers"
## Structure cards come from the build system's palette minus the starting kit --
## see Loadout.starting_structure_ids -- so a new structure needs no entry here.
##
## Tray modifiers are data, not resources, because a modifier is a name and a
## handful of numbers. Effect keys ending in "_mul" multiply, other numeric keys
## sum; see Loadout for the ones that are wired and the ones that are advertised.
@export var tray_modifiers: Array[Dictionary] = [
    {
        "id": "deeper_seams",
        "title": "Deeper Seams",
        "body": "Every quarry mints one more roller at the head of each wave.",
        "counters": ["economy", "swarm"],
        "max_stacks": 3,
        "effects": {"quarry_mint_bonus": 1.0},
    },
    # The two rim-ice cards lived here and were withdrawn: nothing owns a per-rim
    # surface, and ice could not do what they promised anyway. The four rims are
    # collision shapes on one Tray StaticBody, which carries a single physics
    # material, and raiders and villagers are CharacterBody3D -- they take their
    # footing from the tilt angle and never read a PhysicsMaterial at all. Ice is
    # therefore a slip rule inside the agents, not a friction number on the tray,
    # and a card that cannot move anything is worse than one that does not exist.
    # Loadout.ice_rims() is still there as the hook for the day that rule lands.
    {
        "id": "hobnails",
        "title": "Hobnails",
        "body": "The village smith shoes everyone. Villagers keep their feet a degree further over.",
        "counters": ["villagers"],
        # Two stacks is the whole budget. Villagers start at 8 degrees and the stick
        # reaches 12, and Loadout caps footing a slip headroom short of that ceiling
        # so no stack can lift them out of the range the tray can produce: at the
        # shipped numbers that cap is +2. Raising either number here buys the player
        # nothing unless the tilt ceiling rises or villager_slip_headroom_deg falls
        # to make room -- the cap would eat it and the second card would be lying.
        "max_stacks": 2,
        "effects": {"villager_footing_bonus": 1.0},
    },
    {
        "id": "long_evenings",
        "title": "Longer Evenings",
        "body": "Eight more seconds of daylight to build in before the horns.",
        "counters": ["economy", "control"],
        "max_stacks": 2,
        "effects": {"prep_seconds_bonus": 8.0},
    },
    {
        "id": "steady_hand",
        "title": "Steady Hand",
        "body": "Two more degrees of lean before the tray runs away from you.",
        "counters": ["control", "armour"],
        "max_stacks": 2,
        "effects": {"max_tilt_bonus": 2.0},
    },
    {
        "id": "greased_boards",
        "title": "Greased Boards",
        "body": "The tray is slicker. Rollers carry further on the same lean, and stop where they like.",
        "counters": ["swarm", "control"],
        "max_stacks": 2,
        "effects": {"tray_friction_mul": 0.75},
    },
    {
        "id": "hard_stone",
        "title": "Hard Stone",
        "body": "Rollers come out of the quarry with more spring in them. Longer cascades, less control.",
        "counters": ["climb", "swarm"],
        "max_stacks": 2,
        "effects": {"roller_bounce_mul": 1.25},
    },
    {
        "id": "full_stores",
        "title": "Full Stores",
        "body": "Eight more rollers in the standing stockpile, and the stores open onto the tray at once.",
        "counters": ["economy", "swarm"],
        "max_stacks": 2,
        "effects": {"roller_stockpile_bonus": 8.0},
    },
    {
        "id": "muster",
        "title": "Muster",
        "body": "Six rollers are tipped onto the tray at the start of every wave, quarries or no quarries.",
        "counters": ["armour", "boss"],
        "max_stacks": 2,
        "effects": {"wave_start_rollers": 6.0},
    },
]

@export_group("Weighting")
@export var base_weight_roller := 1.0
@export var base_weight_structure := 1.0
@export var base_weight_modifier := 0.8
## How hard the offer leans toward what the player has no answer to. Zero is a
## flat random draw, which is worth trying once to feel the difference.
@export_range(0.0, 6.0, 0.1) var lack_k := 2.5
## How many owned answers it takes to call a tag covered. Two means the first
## answer halves the pressure rather than erasing it.
@export_range(0.5, 5.0, 0.5) var answers_per_tag := 2.0
## Weight left to a card whose kind is already in the offer. Below 1 the three
## cards spread across roller / structure / modifier without being forced to.
@export_range(0.05, 1.0, 0.05) var same_kind_penalty := 0.4
## Pressure that comes from the kingdom rather than the raid, so economy and
## comfort cards do not vanish behind whatever is walking up the rim.
@export var ambient_pressure: Dictionary = {
    "economy": 0.5,
    "control": 0.4,
    "villagers": 0.4,
}
## A card only explains itself when the gap it fills is at least this wide.
@export_range(0.0, 1.0, 0.05) var why_threshold := 0.35

## The one line a card uses to say why it is being offered. This is the whole
## point of the weighting: the player should be able to see the reasoning.
const TAG_REASONS := {
    "armour": "nothing you own breaks a shieldwall",
    "climb": "climbers are getting over your walls",
    "anchor": "anchor-men do not slip, so something else has to move them",
    "swarm": "they are coming in numbers",
    "boss": "the jarl is close",
    "economy": "your stone is running thin",
    "control": "the tray is fighting you",
    "villagers": "your villagers need surer feet",
}

const KIND_TAGS := {
    Kind.ROLLER: "ROLLER",
    Kind.STRUCTURE: "STRUCTURE",
    Kind.MODIFIER: "TRAY",
}

var _cards: Array[Dictionary] = []
var _open := false
var _scanned: Array[Resource] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
    _rng.randomize()
    if roller_types.is_empty():
        _scanned = _scan(roller_dir)


## Composes an offer for the wave about to be prepped. Returns false when there is
## nothing to offer, which is the caller's cue to carry on without a draft.
func open_for(wave: int) -> bool:
    _cards.clear()
    _open = false

    var pool := _candidates(wave)
    if pool.is_empty():
        return false

    var gaps := gaps_for(wave)
    for card in pool:
        card["weight"] = _weight(card, gaps)
        card["why"] = _why(card, gaps)

    _cards = _draw(pool, cards_per_offer)
    if _cards.is_empty():
        return false

    _open = true
    offer_made.emit(wave, _cards)
    return true


func is_open() -> bool:
    return _open


func cards() -> Array[Dictionary]:
    return _cards


func can_skip() -> bool:
    return _open and economy != null and economy.can_afford(skip_cost)


func take(index: int) -> bool:
    if not _open or index < 0 or index >= _cards.size():
        return false
    var card: Dictionary = _cards[index]
    _grant(card)
    card_taken.emit(index, card)
    _close()
    return true


func skip() -> bool:
    if not can_skip():
        return false
    economy.spend(skip_cost)
    skipped.emit()
    _close()
    return true


## Closes an offer without granting anything -- used when the run restarts under a
## live draft. RunState only acts on closed() while it is actually in DRAFT, so
## this cannot bounce the fresh run straight into prep.
func cancel() -> void:
    if not _open:
        return
    _close()


# --- composing ---------------------------------------------------------------

func _candidates(wave: int) -> Array[Dictionary]:
    var out: Array[Dictionary] = []
    if loadout == null:
        return out

    for t in _roller_pool():
        if t == null or loadout.roller_types.has(t):
            continue
        out.append(_roller_card(t))

    for t in loadout.locked_structures():
        out.append(_structure_card(t))

    for m in tray_modifiers:
        if m.is_empty():
            continue
        if int(m.get("unlock_wave", 1)) > wave:
            continue
        if loadout.modifier_stacks(String(m.get("id", ""))) >= loadout.max_stacks_of(m):
            continue
        out.append(_modifier_card(m))

    return out


func _roller_pool() -> Array[Resource]:
    return roller_types if not roller_types.is_empty() else _scanned


## tag -> how badly the player is short of an answer, 0 to 1.
func gaps_for(wave: int) -> Dictionary:
    var pressure := _pressure(wave)
    var owned: Dictionary = loadout.owned_tags() if loadout else {}
    var gaps := {}
    for tag in pressure:
        var have := float(owned.get(tag, 0))
        var covered := clampf(have / maxf(answers_per_tag, 0.5), 0.0, 1.0)
        gaps[tag] = float(pressure[tag]) * (1.0 - covered)
    return gaps


## What the coming wave can field, normalised so the commonest threat reads 1.0.
func _pressure(wave: int) -> Dictionary:
    var raw := {}
    if wave_director:
        for t in wave_director.types:
            var rt := t as RaiderType
            if rt == null or rt.unlock_wave > wave:
                continue
            for tag in _raider_tags(rt):
                raw[tag] = float(raw.get(tag, 0.0)) + 1.0
    var peak := 1.0
    for tag in raw:
        peak = maxf(peak, float(raw[tag]))
    for tag in raw:
        raw[tag] = float(raw[tag]) / peak
    for tag in ambient_pressure:
        raw[tag] = maxf(float(raw.get(tag, 0.0)), float(ambient_pressure[tag]))
    return raw


func _raider_tags(type: RaiderType) -> Array[String]:
    var out: Array[String] = []
    if loadout:
        out = loadout.declared_tags(type)
        if not out.is_empty():
            return out
    if type.knockback_resist >= 1.5:
        out.append("armour")
    if type.climbs_walls:
        out.append("climb")
    if type.never_slips:
        out.append("anchor")
    if type.budget_cost <= 1:
        out.append("swarm")
    if type.keep_damage >= 8 or type.budget_cost >= 6:
        out.append("boss")
    return out


func _weight(card: Dictionary, gaps: Dictionary) -> float:
    var base := base_weight_modifier
    match int(card.get("kind", Kind.MODIFIER)):
        Kind.ROLLER:
            base = base_weight_roller
        Kind.STRUCTURE:
            base = base_weight_structure
    # The widest single gap the card fills, not the sum: a card that answers four
    # tags badly should not outrank the one card that answers the real problem.
    return maxf(0.05, base * (1.0 + lack_k * _best_gap(card, gaps)))


func _best_gap(card: Dictionary, gaps: Dictionary) -> float:
    var best := 0.0
    for tag in _counters_of(card):
        best = maxf(best, float(gaps.get(tag, 0.0)))
    return best


func _why(card: Dictionary, gaps: Dictionary) -> String:
    var best := 0.0
    var best_tag := ""
    for tag in _counters_of(card):
        var g := float(gaps.get(tag, 0.0))
        if g > best:
            best = g
            best_tag = String(tag)
    if best < why_threshold or not TAG_REASONS.has(best_tag):
        return ""
    return String(TAG_REASONS[best_tag])


func _counters_of(card: Dictionary) -> Array:
    var v: Variant = card.get("counters")
    if v is Array:
        return v
    return []


## Weighted draw without replacement, with a discount on a kind already taken so
## the three cards usually read as three different decisions.
func _draw(pool: Array[Dictionary], n: int) -> Array[Dictionary]:
    var remaining: Array = pool.duplicate()
    var out: Array[Dictionary] = []
    var kinds_taken := {}
    while out.size() < n and not remaining.is_empty():
        var weights: Array[float] = []
        var total := 0.0
        for c in remaining:
            var w: float = maxf(0.01, float(c["weight"]))
            if kinds_taken.has(int(c.get("kind", -1))):
                w *= same_kind_penalty
            weights.append(w)
            total += w
        var roll := _rng.randf() * total
        var chosen := weights.size() - 1
        for i in weights.size():
            roll -= weights[i]
            if roll <= 0.0:
                chosen = i
                break
        var card: Dictionary = remaining[chosen]
        out.append(card)
        kinds_taken[int(card.get("kind", -1))] = true
        remaining.remove_at(chosen)
    return out


# --- cards -------------------------------------------------------------------

func _roller_card(type: Resource) -> Dictionary:
    var title := loadout.res_string(type, "display_name", loadout.res_string(type, "id", "Roller"))
    var body := loadout.res_string(type, "description", "A new stone for the quarries to mint.")
    return {
        "kind": Kind.ROLLER,
        "id": "roller:%s" % loadout.res_string(type, "id", title),
        "title": title,
        "tag": KIND_TAGS[Kind.ROLLER],
        "body": "%s\n\n%s" % [body, _roller_delivery()],
        "counters": loadout.tags_for_roller(type),
        # The hue this type will be wearing on the tray. One roller is told apart
        # from the thirty already rolling by its colour and nothing else, so the
        # card has to carry that colour or the player has no way to connect the
        # pick to whatever turns up. DraftUI hides the swatch at zero alpha.
        "swatch": _swatch(type),
        "payload": type,
        "weight": 1.0,
        "why": "",
    }


## What taking this card actually does, in the player's terms. Read off the loadout
## rather than written out as a fixed sentence, so a designer who turns the sample
## pour down to zero is not left with a card promising stones that never arrive.
func _roller_delivery() -> String:
    var sample := loadout.roller_card_sample if loadout else 0
    if sample <= 0:
        return "The quarries mint it alongside what they already cut."
    return "%d roll out onto the tray now, and the quarries mint it alongside what they already cut." % sample


## Duck-typed, because a roller card carries a plain Resource rather than a
## RollerType -- the pool is scanned from a directory and its class may not be the
## one this script names. A type with no colour gets a transparent swatch, which is
## the "nothing on the tray marks this card" signal, not a see-through square.
func _swatch(type: Resource) -> Color:
    if type == null:
        return Color(0.0, 0.0, 0.0, 0.0)
    var v: Variant = type.get("colour")
    if not (v is Color):
        return Color(0.0, 0.0, 0.0, 0.0)
    # Through a typed local rather than returned straight: the read is a
    # Variant, and handing that back as a Color is an unsafe narrowing.
    var c: Color = v
    return c


func _structure_card(type: StructureType) -> Dictionary:
    var body := type.description if not type.description.is_empty() else "A new piece for the kingdom."
    return {
        "kind": Kind.STRUCTURE,
        "id": "structure:%s" % type.id,
        "title": type.display_name,
        "tag": KIND_TAGS[Kind.STRUCTURE],
        "body": "%s\n\n%d gold to place, and %d toward the threat." % [body, type.cost, type.base_value],
        "counters": loadout.tags_for_structure(type),
        "payload": type,
        "weight": 1.0,
        "why": "",
    }


func _modifier_card(modifier: Dictionary) -> Dictionary:
    var id := String(modifier.get("id", ""))
    var body := String(modifier.get("body", ""))
    var stacks := loadout.modifier_stacks(id) if loadout else 0
    if stacks > 0:
        body += "\n\nAlready in force %d time%s." % [stacks, "" if stacks == 1 else "s"]
    return {
        "kind": Kind.MODIFIER,
        "id": "modifier:%s" % id,
        "title": String(modifier.get("title", id)),
        "tag": KIND_TAGS[Kind.MODIFIER],
        "body": body,
        "counters": loadout.tag_list(modifier.get("counters")) if loadout else [],
        "payload": modifier,
        "weight": 1.0,
        "why": "",
    }


func _grant(card: Dictionary) -> void:
    if loadout == null:
        return
    var payload: Variant = card.get("payload")
    match int(card.get("kind", -1)):
        Kind.ROLLER:
            loadout.add_roller_type(payload as Resource)
        Kind.STRUCTURE:
            loadout.unlock_structure(payload as StructureType)
        Kind.MODIFIER:
            if payload is Dictionary:
                loadout.add_modifier(payload)


func _close() -> void:
    _open = false
    closed.emit()


## Scans a directory for resources so an empty pool costs nothing and a filled one
## needs no wiring. Handles the .remap suffix an exported build leaves behind.
func _scan(path: String) -> Array[Resource]:
    var out: Array[Resource] = []
    if path.is_empty() or not DirAccess.dir_exists_absolute(path):
        return out
    for entry in DirAccess.get_files_at(path):
        var file := String(entry)
        if file.ends_with(".remap"):
            file = file.trim_suffix(".remap")
        if not (file.ends_with(".tres") or file.ends_with(".res")):
            continue
        var full := path.path_join(file)
        if not ResourceLoader.exists(full):
            continue
        var res: Resource = load(full)
        if res and not out.has(res):
            out.append(res)
    out.sort_custom(func(a: Resource, b: Resource) -> bool:
        return a.resource_path < b.resource_path)
    return out
