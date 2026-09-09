extends Node
class_name Economy

## Gold per kill, plus an end-of-wave bonus with five factors each worth up to 20%
## of the kill total. It pays skill expression and tells the player what good
## looks like.

signal gold_changed(gold: int)
signal wave_paid(kill_gold: int, bonus: int, factors: Array)

## Typed Node, not VillagerPool: villager_pool.gd exports a RunState and run_state.gd
## exports an Economy, so naming the class here would close a parse-time cycle.
@export var villager_pool: Node
@export var starting_gold := 140
## A wave cleared inside this many seconds earns the speed factor.
@export var fast_wave_seconds := 60.0
## Share of the opening stockpile that must still be on the tray at the end for the
## recovery factor -- scored on what went over the rim, never on the headcount.
@export var recovery_target := 0.6

@export_group("Cascade")
## Chain length that earns the cascade factor.
@export var cascade_target := 5
## Strikes further apart than this begin a new chain. Longer than the audio
## director's window on purpose: this counts raider strikes, which are far rarer
## than the contacts that drive the impact pitch.
@export_range(0.1, 5.0, 0.05) var chain_window := 1.2

var gold := 0

var kills := 0
var kill_gold := 0
## What settle_wave last paid on top of the kills. RunState reports it so the wave
## summary can show the bonus it just banked.
var wave_bonus := 0
var wave_seconds := 0.0
var keep_damage := 0
## Villagers who went over the rim during this wave. The fifth bonus factor.
var villagers_lost := 0
var rollers_at_start := 0
## Rollers that went over the rim during this wave.
var rollers_lost := 0
## The cascade running now and the longest one this wave. Game state, not audio
## state: the audio director keeps its own contact counter for pitch.
var chain := 0
var longest_chain := 0
var called_early := false
## Share of the kill total an early call pays. Handed in by RunState from the wave
## table so the knob keeps one home.
var early_call_share := 0.0

var _running := false
## The pool's lost tally when the wave opened, so the wave's own losses are a delta.
var _lost_at_start := 0
var _chain_timer := 0.0


func _ready() -> void:
    gold = starting_gold
    gold_changed.emit(gold)


func reset_run() -> void:
    gold = starting_gold
    gold_changed.emit(gold)


func can_afford(cost: int) -> bool:
    return gold >= cost


func spend(cost: int) -> bool:
    if not can_afford(cost):
        return false
    gold -= cost
    gold_changed.emit(gold)
    return true


## `rollers` is the stockpile on the tray as the wave opens; `lost_total` is the
## pool's running lost tally, which recovery is scored against; `early_share` is the
## wave table's early-call bonus.
func begin_wave(rollers: int, lost_total: int, early: bool, early_share: float) -> void:
    kills = 0
    kill_gold = 0
    wave_bonus = 0
    wave_seconds = 0.0
    keep_damage = 0
    villagers_lost = 0
    rollers_at_start = rollers
    rollers_lost = 0
    _lost_at_start = lost_total
    chain = 0
    longest_chain = 0
    _chain_timer = 0.0
    called_early = early
    early_call_share = early_share
    _running = true


func _process(dt: float) -> void:
    if not _running:
        return
    wave_seconds += dt
    # A chain that goes quiet is over. Timed here rather than on the next strike so
    # that a cascade which ends the wave still closes.
    if _chain_timer > 0.0:
        _chain_timer = maxf(0.0, _chain_timer - dt)
        if _chain_timer == 0.0:
            chain = 0


func credit_kill(type: RaiderType) -> void:
    kills += 1
    kill_gold += type.gold


func note_keep_damage(amount: int) -> void:
    keep_damage += amount


## VillagerPool calls this when one of its people leaves the tray.
func note_villager_lost() -> void:
    villagers_lost += 1


## One link of a cascade. RunState feeds this from roller contacts that actually
## staggered a raider, because a cascade is a chain of hits the player set up: raw
## contacts include a quarry roller landing on the tray at the head of a wave, which
## would win this factor before a raider had been touched.
func note_chain_hit() -> void:
    if not _running:
        return
    chain += 1
    longest_chain = maxi(longest_chain, chain)
    _chain_timer = chain_window


## Income, not winnings: wages paid at the end of a wave never touch kill_gold and
## so can never inflate the end-of-wave bonus that is computed from it.
func credit_income(amount: int) -> void:
    if amount <= 0:
        return
    gold += amount
    gold_changed.emit(gold)


## Pays out and returns the factor list so the HUD can show what was earned and
## what was missed.
func _villager_factor() -> Dictionary:
    var beds := 0
    if villager_pool and villager_pool.has_method(&"capacity"):
        beds = int(villager_pool.call(&"capacity"))
    if beds <= 0:
        return {"name": "no villager lost", "won": false, "pending": true}
    return {"name": "no villager lost", "won": villagers_lost == 0}


func settle_wave(lost_total: int) -> Array:
    _running = false
    rollers_lost = maxi(0, lost_total - _lost_at_start)

    # Losses over the rim, not the end-of-wave headcount: splitting RAISES the count
    # -- a splitter retires one roller and takes three -- so a ratio of end to start
    # would hand this factor over for free the moment a splitter was drafted.
    var recovered := 1.0 if rollers_at_start == 0 else clampf(
        float(rollers_at_start - rollers_lost) / float(rollers_at_start), 0.0, 1.0)
    var factors: Array = [
        {"name": "speed", "won": wave_seconds <= fast_wave_seconds},
        {"name": "no keep damage", "won": keep_damage == 0},
        {"name": "rollers recovered", "won": recovered >= recovery_target},
        {"name": "cascade", "won": longest_chain >= cascade_target},
        # Pending, not won, when there is nobody to lose. Houses are out of the
        # build palette for now, so a kingdom with no beds would otherwise collect
        # a fifth of the bonus every wave for keeping zero villagers alive.
        _villager_factor(),
    ]

    var won := 0
    for f in factors:
        if f.get("pending", false):
            continue
        if f["won"]:
            won += 1
    var bonus := int(round(float(kill_gold) * 0.2 * float(won)))
    if called_early:
        bonus += int(round(float(kill_gold) * early_call_share))
    wave_bonus = bonus

    gold += kill_gold + bonus
    gold_changed.emit(gold)
    wave_paid.emit(kill_gold, bonus, factors)
    return factors
