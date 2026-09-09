extends Node3D
class_name VillagerPool

## Pre-instanced villagers, the same discipline as the rollers and the raiders:
## nothing is instanced mid-wave. Nothing is even *activated* mid-wave -- people
## move in during prep, at their doorstep, or not at all.
##
## The pool owns the income too, because income is a headcount: every living
## villager pays at the end of a wave, so one going over the rim is a cut you keep
## paying for. That is the counterweight to holding the stick toward the raiders.
##
## It only ever READS: run_state phases, structures under structures_root, the tilt
## for the agents. Nothing here calls back into RunState or the wave director.

signal villager_lost(fell: bool)
signal villager_slipped(at: Vector3)
## `beds` is every bed in every house, filled or not. Named that way rather than
## `capacity` so the parameter does not shadow capacity() below.
signal population_changed(alive: int, beds: int)
signal income_paid(gold: int, villagers: int)

@export var tilt_controller: TiltController
@export var run_state: RunState
@export var economy: Economy
## Where BuildSystem parents what the player places. Houses are found in here.
@export var structures_root: Node3D
@export var keep: Node3D
@export var villager_type: VillagerType
## Optional. Tray modifiers such as Hobnails raise villager footing; without a
## loadout the people simply keep the footing their VillagerType ships with.
@export var loadout: Loadout
## Optional. Placing or breaking a structure rebakes the navmesh under everyone who
## is already walking, and a body holding the path it made before that walks into a
## wall that was not there when it made it. Villagers wander during PREP, which is
## the phase the player builds in, so this is the pair of eyes that matters most.
## Without it they still recover on their own forced repath, a second later.
@export var build_system: BuildSystem
@export_range(1, 64, 1) var pool_size := 24
## Distance from tray centre to the inside face of a rim.
@export var tray_half := 5.6
## StructureType has no HOUSE kind and that file is not ours, so houses are found
## by id. Must match the `id` in data/structures/house.tres.
@export var house_id := "house"
## Radius of the ring of stops around the keep -- the market square they drift to.
@export var keep_ring := 1.35
## How many stops to put on that ring.
@export_range(1, 8, 1) var keep_stops := 4
## Houses bought mid-prep have to fill while the player is still watching, so the
## house list is re-read this often during prep. Idempotent and cheap.
@export_range(0.05, 2.0, 0.05) var prep_rescan_seconds := 0.25

var lost_this_wave := 0
var lost_total := 0

var _all: Array[Villager] = []
var _idle: Array[Villager] = []
## Structure -> Array of the Villagers living there.
var _residents := {}
## Structure -> how many have EVER moved in, which is what separates a new house
## (fills at once) from one that has lost somebody (trickles back).
var _settled := {}
## Structure -> replacements still allowed this prep phase.
var _repop := {}
var _waypoints := PackedVector3Array()
var _rescan := 0.0


func _ready() -> void:
    if villager_type == null:
        # The defaults are playable on their own; the .tres only exists so a
        # designer can move them without touching code.
        villager_type = VillagerType.new()

    for _i in pool_size:
        var v := Villager.new()
        add_child(v)
        v.tray_half = tray_half
        v.lost.connect(_on_villager_lost)
        v.slipped.connect(_on_villager_slipped)
        v.park()
        _all.append(v)
        _idle.append(v)

    if run_state:
        run_state.phase_changed.connect(_on_phase_changed)
        run_state.wave_changed.connect(_on_wave_changed)
    if loadout:
        loadout.changed.connect(_apply_loadout)
    if build_system:
        build_system.structures_changed.connect(notify_world_changed)
    _apply_loadout()


## Hobnails and anything else that buys surer feet. Pushed to everyone, including
## the idle bodies, so a villager who moves in later is already wearing them.
func _apply_loadout() -> void:
    var bonus := loadout.villager_footing_bonus() if loadout else 0.0
    for v in _all:
        v.footing_bonus = bonus


func alive_count() -> int:
    return _all.size() - _idle.size()


## Every bed in every house, filled or not.
func capacity() -> int:
    if villager_type == null:
        return 0
    return _residents.size() * villager_type.per_house


func house_count() -> int:
    return _residents.size()


## What the current population will pay at the end of this wave. The HUD can show
## it so the player knows exactly what a slip is costing.
func income_per_wave() -> int:
    if villager_type == null:
        return 0
    return alive_count() * villager_type.income


## The kingdom changed shape. Told to the people who are actually out on the tray;
## a parked body has no path to invalidate and re-aims when he next moves in.
##
## Not the same job as _refresh_houses(): that one rebuilds the LIST of stops when a
## house appears or goes, and set_waypoints() drops the aim when the list really
## changed. A wall changes no stop at all -- it changes the way between them -- and
## that is the case this covers.
func notify_world_changed() -> void:
    for v in _all:
        if v.is_active():
            v.notify_world_changed()


## Mirrors RaiderPool: rollers report their contacts to the pool so villagers do
## not each need a contact monitor.
func notify_roller_contact(other: Node, roller: RigidBody3D, speed: float) -> void:
    var v := other as Villager
    if v:
        v.hit_by_roller(roller, speed)


func clear_all() -> void:
    for v in _all:
        if v.is_active():
            _retire(v)
    _announce()


## Everyone home, every house forgotten. Called on a fresh run so a kingdom that
## lost half its people does not start the next run short.
func reset_population() -> void:
    clear_all()
    _residents.clear()
    _settled.clear()
    _repop.clear()
    _waypoints = PackedVector3Array()
    lost_this_wave = 0
    lost_total = 0
    _announce()


func _process(dt: float) -> void:
    if run_state == null or run_state.phase != RunState.Phase.PREP:
        return
    _rescan -= dt
    if _rescan <= 0.0:
        _rescan = prep_rescan_seconds
        _refresh_houses()


func _on_wave_changed(wave: int) -> void:
    # RunState only rewinds to wave 1 by starting a new run.
    if wave <= 1:
        reset_population()


func _on_phase_changed(phase: int) -> void:
    match phase:
        RunState.Phase.PREP:
            _open_repopulation()
            _rescan = prep_rescan_seconds
            _refresh_houses()
        RunState.Phase.WAVE:
            lost_this_wave = 0
        RunState.Phase.CLEARED:
            # Fires after Economy.settle_wave, so wages are never mistaken for
            # kill gold and never inflate the end-of-wave bonus.
            _pay_income()


func _open_repopulation() -> void:
    if villager_type == null:
        return
    for house in _residents.keys():
        _repop[house] = villager_type.repopulate_per_prep


## Idempotent: reads the house list, moves people in where there is room and
## allowance, and rebuilds the stops they wander between.
func _refresh_houses() -> void:
    if structures_root == null or villager_type == null:
        return

    var live := {}
    for child in structures_root.get_children():
        var s := child as Structure
        if s == null or s.type == null or s.type.id != house_id:
            continue
        live[s] = true
        if not _residents.has(s):
            _residents[s] = []
            _settled[s] = 0
            _repop[s] = villager_type.repopulate_per_prep

    # keys() hands back a copy, so erasing inside the loop is safe.
    for house in _residents.keys():
        if not is_instance_valid(house) or not live.has(house):
            _evict(house)

    _rebuild_waypoints()

    for house in _residents.keys():
        _fill(house as Structure)

    _announce()


func _fill(house: Structure) -> void:
    if not is_instance_valid(house):
        return

    var current: Array = _residents[house]
    var living: Array = []
    for v in current:
        var villager := v as Villager
        if villager and villager.is_active():
            living.append(villager)
    _residents[house] = living

    var room := villager_type.per_house - living.size()
    if room <= 0:
        return

    var ever := int(_settled.get(house, 0))
    var fresh := ever < villager_type.per_house
    var budget := (villager_type.per_house - ever) if fresh else int(_repop.get(house, 0))
    for _slot in mini(room, budget):
        var v := _take_idle()
        if v == null:
            return
        v.place(villager_type, tilt_controller, _door_point(house, living.size()), _waypoints)
        living.append(v)
        _settled[house] = int(_settled.get(house, 0)) + 1
        if not fresh:
            _repop[house] = int(_repop.get(house, 0)) - 1


func _evict(house: Variant) -> void:
    var current: Array = _residents.get(house, [])
    for v in current:
        var villager := v as Villager
        if villager:
            _retire(villager)
    _residents.erase(house)
    _settled.erase(house)
    _repop.erase(house)


func _take_idle() -> Villager:
    if _idle.is_empty():
        return null
    var v: Villager = _idle.pop_back()
    return v


func _retire(v: Villager) -> void:
    v.park()
    if not _idle.has(v):
        _idle.append(v)


## Doorsteps and a ring round the keep. Villagers pick from these at random, which
## is why they drift across the middle of the tray instead of hugging a wall: the
## player has to see them out in the open to feel the tilt costing something.
func _rebuild_waypoints() -> void:
    var points := PackedVector3Array()
    for house in _residents.keys():
        var s := house as Structure
        if is_instance_valid(s):
            points.append(_door_point(s, 0))
    if keep:
        for i in keep_stops:
            var a := TAU * float(i) / float(keep_stops)
            points.append(_on_tray(keep.global_position + Vector3(cos(a), 0.0, sin(a)) * keep_ring))
    _waypoints = points
    for v in _all:
        v.set_waypoints(points)


## A spot on the near side of the house, clear of its own collider, fanned sideways
## so two residents do not appear inside each other.
func _door_point(house: Structure, index: int) -> Vector3:
    var size := house.type.footprint if house.type else Vector3.ONE
    # Face the middle of the tray: a doorstep on the outward side would put people
    # on the rim, which is not a joke, it is just a tax.
    var out := Vector3(-house.global_position.x, 0.0, -house.global_position.z)
    if out.length() < 0.01:
        out = Vector3(0.0, 0.0, 1.0)
    out = out.normalized()
    var side := Vector3(-out.z, 0.0, out.x) * (float(index) - 0.5) * 0.5
    var step := maxf(size.x, size.z) * 0.5 + 0.45
    return _on_tray(house.global_position + out * step + side)


func _on_tray(p: Vector3) -> Vector3:
    var limit := tray_half - 0.4
    return Vector3(clampf(p.x, -limit, limit), 0.0, clampf(p.z, -limit, limit))


func _pay_income() -> void:
    var alive := alive_count()
    var pay := alive * (villager_type.income if villager_type else 0)
    if pay <= 0:
        return
    if economy:
        if economy.has_method("credit_income"):
            economy.call("credit_income", pay)
        else:
            # Economy has no public "add gold" yet and that file is not ours this
            # round. A negative spend is the same arithmetic and fires
            # gold_changed; the moment credit_income() lands this switches to it
            # with no rewiring.
            economy.spend(-pay)
    income_paid.emit(pay, alive)


func _on_villager_lost(v: Villager, fell: bool) -> void:
    _retire(v)
    lost_this_wave += 1
    lost_total += 1
    # The fifth end-of-wave factor is "no villager lost". economy.gd belongs to
    # another agent this round, so call the counter if it exists and let the
    # signal carry it if it does not.
    if economy and economy.has_method("note_villager_lost"):
        economy.call("note_villager_lost")
    villager_lost.emit(fell)
    _announce()


func _on_villager_slipped(at: Vector3) -> void:
    villager_slipped.emit(at)


func _announce() -> void:
    population_changed.emit(alive_count(), capacity())
