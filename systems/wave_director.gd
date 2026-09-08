extends Node
class_name WaveDirector

## Threat is tied to what you built. Every structure carries a base value; the
## director spends a raider budget derived from the total.
##
##     budget(w) = base_value * threat_k * (1 + threat_growth * w)

signal wave_composed(wave: int, preview: String)
signal spawning_finished()

enum Rim { NORTH, SOUTH, EAST, WEST }

@export var raider_pool: RaiderPool
@export var table: WaveTable
@export var types: Array[RaiderType] = []
## Distance from tray centre to the inside face of a rim.
@export var tray_half := 5.6

var last_budget := 0.0
## The formula value of the last wave, ungraced. The grace has to defer to a real
## number rather than to the number it deferred to last time -- see begin_wave().
var last_full_budget := 0.0
var last_preview := ""

var _queue: Array = []
var _timer := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
    _rng.randomize()
    set_process(false)


func budget_for(wave: int, base_value: int) -> float:
    return float(base_value) * table.threat_k * (1.0 + table.threat_growth * float(wave))


func rims_for(wave: int) -> int:
    if table.rims_by_wave.is_empty():
        return 1
    return table.rims_by_wave[clampi(wave - 1, 0, table.rims_by_wave.size() - 1)]


## Builds the wave and starts feeding it in over `spawn_interval`.
## `grew` grants the one-wave grace after any expansion.
func begin_wave(wave: int, base_value: int, grew: bool) -> void:
    var full := budget_for(wave, base_value)
    # ONE wave of grace: what you just built raids you next wave, not this one, so an
    # expansion is never punished the instant it is paid for. The formula value is
    # banked either way -- banking the frozen number instead would freeze it again on
    # the next expansion, and threat would stop climbing for the one player who keeps
    # building. Deferred like this, a builder always fields the curve one wave back,
    # which still rises every wave because both the base and w only go up.
    var budget := full
    if grew and last_full_budget > 0.0:
        budget = last_full_budget
    last_full_budget = full
    last_budget = budget

    var picks := _compose(wave, budget)
    var rims := _choose_rims(rims_for(wave))

    _queue.clear()
    for pick in picks:
        _queue.append({"type": pick, "rim": rims[_rng.randi() % rims.size()]})
    _queue.shuffle()

    last_preview = _describe(picks, rims)
    wave_composed.emit(wave, last_preview)

    _timer = 0.0
    set_process(true)
    if _queue.is_empty():
        set_process(false)
        spawning_finished.emit()


func cancel() -> void:
    _queue.clear()
    set_process(false)


func _process(dt: float) -> void:
    _timer -= dt
    if _timer > 0.0:
        return
    _timer = table.spawn_interval
    if _queue.is_empty():
        set_process(false)
        spawning_finished.emit()
        return
    var entry: Dictionary = _queue.pop_front()
    var points := _spawn_points(entry["rim"])
    raider_pool.spawn(entry["type"], points[0], points[1])


func _compose(wave: int, budget: float) -> Array:
    var unlocked := types.filter(func(t: RaiderType) -> bool: return t.unlock_wave <= wave)
    if unlocked.is_empty():
        return []

    var picks: Array = []
    var remaining := budget
    var cap := budget * table.max_share_per_type
    var spent := {}

    # The boss is scripted in rather than drafted, so it is granted whatever the
    # budget says. It is charged and taken out of the pool afterwards: left in, the
    # loop's "every type gets its first pick" clause would field a second jarl, and
    # the share cap would happily pass a third.
    if wave == table.boss_wave:
        for t in types:
            if t.id == table.boss_id:
                picks.append(t)
                remaining -= float(t.budget_cost)
                spent[t.id] = float(t.budget_cost)
                unlocked.erase(t)
                break

    var guard := 0
    while remaining >= 1.0 and guard < 400:
        guard += 1
        var affordable := unlocked.filter(func(t: RaiderType) -> bool:
            if float(t.budget_cost) > remaining:
                return false
            # The share cap is meaningless with one type, and every type is always
            # allowed its first pick -- otherwise a small budget composes nothing.
            if unlocked.size() <= 1 or not spent.has(t.id):
                return true
            return float(spent[t.id]) + float(t.budget_cost) <= cap)
        if affordable.is_empty():
            break
        var pick: RaiderType = affordable[_rng.randi() % affordable.size()]
        picks.append(pick)
        remaining -= float(pick.budget_cost)
        spent[pick.id] = float(spent.get(pick.id, 0.0)) + float(pick.budget_cost)
    return picks


func _choose_rims(count: int) -> Array:
    var all := [Rim.NORTH, Rim.SOUTH, Rim.EAST, Rim.WEST]
    all.shuffle()
    return all.slice(0, clampi(count, 1, 4))


## Returns [outside_the_rim, first_foothold_on_the_tray].
func _spawn_points(rim: int) -> Array:
    var along := _rng.randf_range(-tray_half + 1.0, tray_half - 1.0)
    var outer := tray_half + 0.9
    var inner := tray_half - 0.7
    match rim:
        Rim.NORTH:
            return [Vector3(along, -0.7, -outer), Vector3(along, 0.05, -inner)]
        Rim.SOUTH:
            return [Vector3(along, -0.7, outer), Vector3(along, 0.05, inner)]
        Rim.WEST:
            return [Vector3(-outer, -0.7, along), Vector3(-inner, 0.05, along)]
        _:
            return [Vector3(outer, -0.7, along), Vector3(inner, 0.05, along)]


func _describe(picks: Array, rims: Array) -> String:
    if picks.is_empty():
        return "nothing on the horizon"
    var counts := {}
    for p in picks:
        counts[p.display_name] = int(counts.get(p.display_name, 0)) + 1
    var parts: Array[String] = ["%d rim%s" % [rims.size(), "" if rims.size() == 1 else "s"]]
    for name in counts:
        parts.append("%d %s" % [counts[name], name.to_lower()])
    return " · ".join(parts)
