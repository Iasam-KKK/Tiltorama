extends SceneTree

## Permanent regression harness. Five seconds of "did I just break the game".
##
##   godot --headless --path . --script res://tools/smoke.gd
##
## Regenerate the scene first if tools/build_main.gd changed -- this drives the real
## scenes/main.tscn, not a rig, so a stale scene is tested instead of the new one:
##
##   godot --headless --path . --script res://tools/build_main.gd
##
## Prints "ok" or "FAIL" per check and exits non-zero if any of them failed.
##
## THIS FILE IS CHECKED IN AND STAYS. Keep it honest: a check that has become hard
## to satisfy is telling you something about the game. Fix the game, never the
## assertion. Every number the harness leans on (footing angles, the boss wave, the
## rim distance) is read back out of the resources, so retuning a .tres retunes the
## test with it rather than breaking it.

const SCENE := "res://scenes/main.tscn"
const WAVES := "res://data/waves.tres"
const RAIDER_IDS := ["grunt", "climber", "shieldwall", "anchor", "jarl"]
const VILLAGER_TYPE := "res://data/villagers/villager.tres"

## Sim seconds per real second. The physics tick rate is raised by the same factor
## so the step Jolt integrates stays 1/60 s -- scaling time on its own hands it a
## step four times too long, and rollers start through the tray floor.
const SPEEDUP := 4.0
## Hard wall-clock ceiling for the whole run. A check that hangs has to fail the
## build, not stall it.
const REAL_BUDGET_SECONDS := 240.0

## Base value the imaginary player adds every prep in the threat-curve check. Any
## positive number works -- roughly a wall and a house a wave.
const EXPANSION_PER_WAVE := 20
## Where the test house goes: clear of the keep in the middle and of the corner
## dressing, and off the keep's own z axis so a villager sliding across the tray is
## not funnelled into it.
const HOUSE_AT := Vector3(-4.0, 0.0, -3.0)

const TILT_ACTIONS: Array[StringName] = [&"tilt_right", &"tilt_down", &"tilt_left", &"tilt_up"]
## The eight compass points, as the actions held for each. Eight and not four: the
## stick's target moves in a straight line between two held directions, so turning
## right -> down straight through would take the target from (12,0) to (0,12) and
## across a magnitude of 8.5 on the way -- under the 10 deg at which a sliding
## raider stands back up. Cornering through right+down keeps the whole turn above
## 11 deg, so nobody the sweep has off their feet gets to plant them again.
const SWEEP_LEGS: Array[Array] = [
    [&"tilt_right"], [&"tilt_right", &"tilt_down"],
    [&"tilt_down"], [&"tilt_down", &"tilt_left"],
    [&"tilt_left"], [&"tilt_left", &"tilt_up"],
    [&"tilt_up"], [&"tilt_up", &"tilt_right"],
]
## Sim seconds the stick is held on each leg. Long enough for the spring to reach
## the cap (about 0.7 s) and for a body to still have its rim press left over
## (0.7 s for a raider, 0.5 s for a villager).
const SWEEP_SECONDS := 2.0

var _checks := 0
var _failed := 0
## Sim seconds, counted off the physics clock -- see _physics_process().
var _sim := 0.0
var _real_start := 0
var _done := false

var _main: Node
var _run_state: RunState
var _economy: Economy
var _keep: Keep
var _raiders: RaiderPool
var _villagers: VillagerPool
var _tilt: TiltController
var _draft: DraftSystem
var _live_director: WaveDirector
var _nav: NavigationRegion3D
var _structures: Node3D
var _kill: Area3D

## Observed through signals rather than polled, because every one of these is an
## event that happens once and would be missed between two frames.
var _fell_raiders := 0
var _agents_in_sea := 0
var _spawning_done := false
var _run_started := false
var _paid: Array = []
var _purse_after_pay := 0
var _purse_at_wave_start := 0
## What the tray ships as its full lean, read once before the harness leans on the
## property itself so the second stage puts back exactly what the designer set.
var _max_tilt := 12.0


func _initialize() -> void:
    _real_start = Time.get_ticks_msec()
    Engine.physics_ticks_per_second = int(round(60.0 * SPEEDUP))
    Engine.max_physics_steps_per_frame = 32
    Engine.time_scale = SPEEDUP
    print("smoke: %s at %.0fx (%d physics ticks a second)"
        % [SCENE, SPEEDUP, Engine.physics_ticks_per_second])
    _run()


## Sim time is counted here and not in _process: when a slow frame trips
## max_physics_steps_per_frame the frame clock keeps running while the world does
## not, and a timeout measured on it would expire before anything had moved.
func _physics_process(delta: float) -> bool:
    _sim += delta
    return false


func _process(_delta: float) -> bool:
    return _done


func _run() -> void:
    # One frame before anything is added. _initialize() runs while the tree is still
    # being stood up, and a node added before it is live never gets its _ready --
    # which is how the first version of this harness asserted against a scene whose
    # scripts had not run yet and believed it.
    await process_frame
    # The two director checks come first. They need no scene, they are the two
    # highest-severity findings of the round, and running them ahead of the live
    # drive means a scene that will not boot cannot hide them.
    _budget_curve()
    _boss_wave()
    await _live()
    _report()


# --- the threat curve ---------------------------------------------------------

## The one-wave grace used to bank the number it had just deferred TO, so the next
## expansion deferred to that same frozen number: a player who built every prep
## froze the threat curve at wave 1 for the rest of the run. The curve has to keep
## climbing for exactly that player, which is what this walks.
func _budget_curve() -> void:
    var wd := _director(false)
    var base := 5
    var budgets: Array[float] = []
    for wave in range(1, 13):
        # The player expanded during this prep, every prep.
        base += EXPANSION_PER_WAVE
        wd.begin_wave(wave, base, wave > 1)
        budgets.append(wd.last_budget)
    wd.cancel()
    wd.queue_free()

    # Wave 2 is the grace itself, so it legitimately repeats wave 1's number. From
    # wave 3 on every wave fields the previous wave's formula value, which rises
    # because both the base value and the wave number only ever go up.
    var rising := true
    for i in range(2, budgets.size()):
        if budgets[i] <= budgets[i - 1]:
            rising = false
    var curve: Array[String] = []
    for b in budgets:
        curve.append("%.0f" % b)
    _check("threat rises across 12 waves of expanding every prep", rising,
        " ".join(curve))
    # The bug's exact signature: under it these two are equal, not a factor apart.
    _check("the grace does not freeze the curve",
        budgets[11] > budgets[1], "wave 12 budget %.1f vs wave 2 budget %.1f"
        % [budgets[11], budgets[1]])


# --- the boss wave ------------------------------------------------------------

## The boss used to be appended without being charged or removed from the pool, so
## the "every type gets its first pick" clause fielded a second jarl and the share
## cap would happily have passed a third.
func _boss_wave() -> void:
    var wd := _director(true)
    var table: WaveTable = wd.table

    # Enough base value that the escort is real. The assertion is about the boss
    # being granted exactly once, whatever else the budget buys around it.
    wd.begin_wave(table.boss_wave, 60, false)
    var bosses := _count_composed(wd, table.boss_id)
    var total: int = wd._queue.size()
    wd.cancel()
    _check("wave %d composes exactly one %s" % [table.boss_wave, table.boss_id],
        bosses == 1, "%d of %d raiders" % [bosses, total])

    wd.begin_wave(table.boss_wave - 1, 60, false)
    var early := _count_composed(wd, table.boss_id)
    wd.cancel()
    _check("wave %d composes no %s" % [table.boss_wave - 1, table.boss_id],
        early == 0, "%d found" % early)
    wd.queue_free()


func _director(with_types: bool) -> WaveDirector:
    var wd := WaveDirector.new()
    wd.table = load(WAVES)
    if with_types:
        var types: Array[RaiderType] = []
        for id in RAIDER_IDS:
            types.append(load("res://data/raiders/%s.tres" % id))
        wd.types = types
    # _ready() runs inside add_child, so the director is armed on return.
    root.add_child(wd)
    return wd


## The only place the harness reaches past an underscore, and it earns it: the
## public alternative is last_preview, which is prose written for the player and
## would have to be parsed. _queue is the list the spawner actually feeds from.
## The director has no raider_pool here, so every caller must cancel() before the
## next frame or _process will spawn into a null.
func _count_composed(wd: WaveDirector, id: String) -> int:
    var n := 0
    for entry in wd._queue:
        var e: Dictionary = entry
        var t: RaiderType = e["type"]
        if t and t.id == id:
            n += 1
    return n


# --- the live scene -----------------------------------------------------------

func _live() -> void:
    var packed := load(SCENE) as PackedScene
    if not _check("scenes/main.tscn loads", packed != null):
        return
    _main = packed.instantiate()
    root.add_child(_main)

    _run_state = _main.get_node("RunState")
    _economy = _main.get_node("Economy")
    _live_director = _main.get_node("WaveDirector")
    _tilt = _main.get_node("TiltController")
    _draft = _main.get_node("DraftSystem")
    _keep = _main.get_node("World/NavRegion/Keep")
    _nav = _main.get_node("World/NavRegion")
    _structures = _main.get_node("World/NavRegion/Structures")
    _kill = _main.get_node("World/KillVolume")
    _raiders = _main.get_node("World/RaiderPool")
    _villagers = _main.get_node("World/VillagerPool")
    _max_tilt = _tilt.max_tilt_deg

    _live_director.spawning_finished.connect(func() -> void: _spawning_done = true)
    _raiders.raider_died.connect(func(_type: RaiderType, fell: bool) -> void:
        if fell:
            _fell_raiders += 1)
    # Proves the tipped-agent splash: an Area3D cannot see a body whose only shape
    # is disabled, and both agent kinds ghost their collider to get through the rim.
    _kill.body_entered.connect(func(body: Node3D) -> void:
        if body is Raider or body is Villager:
            _agents_in_sea += 1)
    _economy.wave_paid.connect(func(kill_gold: int, bonus: int, factors: Array) -> void:
        _paid = [kill_gold, bonus, factors]
        _purse_after_pay = _economy.gold)
    # Waited on rather than the phase: RunState.phase INITIALISES to PREP, so polling
    # it answers "yes" before start_run() -- or before _ready() -- has run at all.
    # wave_changed is emitted by start_run and cannot be faked by a default value.
    _run_state.wave_changed.connect(func(_w: int) -> void: _run_started = true)

    # start_run() is deferred a frame, and Main._ready bakes the navmesh.
    var started := await _until(func() -> bool:
        return _run_started and _run_state.phase == RunState.Phase.PREP, 10.0)
    if not _check("the run reaches PREP", started, "phase %d" % _run_state.phase):
        return

    var polys := _nav.navigation_mesh.get_polygon_count() if _nav.navigation_mesh else 0
    _check("the navmesh bakes", polys > 0, "%d polygons" % polys)

    await _wave_spawns()
    await _keep_damage()
    await _full_tilt()
    await _wave_pays()
    await _draft_opens_and_closes()


## Raiders arrive over a rim, not out of the middle of the tray. Sampled every frame
## while the director feeds them in, because a raider is only at its rim on the
## frame it launches and is on the tray 0.7 s later.
func _wave_spawns() -> void:
    # A house, so there are villagers to lose later on.
    _build("house", HOUSE_AT)
    var housed := await _until(func() -> bool:
        return _villagers.alive_count() > 0, 10.0)
    _check("a house fills with villagers", housed, "%d alive" % _villagers.alive_count())

    Input.action_press(&"wave_call")
    var in_wave := await _until(func() -> bool:
        return _run_state.phase == RunState.Phase.WAVE, 45.0)
    Input.action_release(&"wave_call")
    if not _check("a wave starts", in_wave, "phase %d" % _run_state.phase):
        return
    _purse_at_wave_start = _economy.gold

    var seen := {}
    var spawned := 0
    var nearest := INF
    var deadline := _sim + 30.0
    while not _spawning_done and _sim < deadline and not _over_budget():
        for child in _raiders.get_children():
            var r := child as Raider
            if r == null or not r.visible or seen.has(r.get_instance_id()):
                continue
            seen[r.get_instance_id()] = true
            spawned += 1
            nearest = minf(nearest,
                maxf(absf(r.global_position.x), absf(r.global_position.z)))
        await process_frame

    var rim: float = _live_director.tray_half
    _check("the wave composes and spawns raiders at the rims",
        spawned > 0 and nearest >= rim,
        "%d raiders, nearest launched %.2f m out (inside face of the rim is %.2f)"
        % [spawned, nearest, rim])


## They path to the keep and hit it. This is the whole reason the navmesh matters.
func _keep_damage() -> void:
    var full := _keep.max_hp
    var hurt := await _until(func() -> bool: return _keep.hp < full, 120.0)
    _check("raiders close on the keep and damage it", hurt,
        "keep %d / %d" % [_keep.hp, full])


## Gravity is the only command in combat, and it has to do both jobs: cost the
## player the villagers who slip four degrees earlier, and put the raiders in the
## sea. Two stages, and the order between them is made PHYSICAL rather than left to
## luck -- whoever goes over first decides what the fifth bonus factor sees, and a
## wave that settles before any villager slips scores "no villager lost" as won.
## Held at a tilt only the villagers slip on, the villager is on the books before a
## raider can leave the tray at all.
##
## Both stages sweep. A raider pinned against a wall, the keep or a corner tree is
## held there by a tilt that never turns -- see _sweep_until().
func _full_tilt() -> void:
    var villager: VillagerType = load(VILLAGER_TYPE)
    var grunt: RaiderType = load("res://data/raiders/grunt.tres")
    # Half way between the two footings, and never past what the tray can reach.
    # This is a real angle on the way to full tilt, not a rig: the debug panel's own
    # slider writes the same property.
    var between := minf((villager.footing_deg + grunt.footing_deg) * 0.5, _max_tilt)

    _tilt.max_tilt_deg = between
    var slipped := await _sweep_until(func() -> bool:
        return _economy.villagers_lost > 0, 25.0)
    _check("a villager over the rim is counted by Economy", slipped,
        "%.1f deg, over the villagers' %.1f footing and under the raiders' %.1f, %d lost%s"
        % [between, villager.footing_deg, grunt.footing_deg,
            _economy.villagers_lost, _end_note()])

    var before := _fell_raiders
    var standing := _raiders.alive_count()
    _tilt.max_tilt_deg = _max_tilt
    var sunk := await _sweep_until(func() -> bool: return _fell_raiders > before, 60.0)
    _check("full tilt puts a raider in the sea", sunk and standing > 0,
        "%.1f deg over a %.1f deg footing, %d were up, %d went over%s"
        % [_max_tilt, grunt.footing_deg, standing, _fell_raiders - before, _end_note()])
    # Not a duplicate of the line above: a raider can reach FELL_BELOW without the
    # kill volume ever having seen it, which is the bug that left every rim death
    # silent -- both agent kinds ghost their collider to get through the rim, and an
    # Area3D cannot see a body whose only shape is disabled.
    _check("the kill volume sees the tipped agents (splash)", _agents_in_sea > 0,
        "%d agent bodies entered the volume" % _agents_in_sea)


## The wave empties, Economy settles it, and the purse is bigger than it was when
## the wave opened. The fifth factor has to have noticed the villager.
func _wave_pays() -> void:
    var cleared := await _sweep_until(func() -> bool: return not _paid.is_empty(), 120.0)
    _hold([])
    if not _check("a wave clears and pays", cleared,
            "%d raiders still up%s" % [_raiders.alive_count(), _end_note()]):
        return
    var kill_gold := int(_paid[0])
    var bonus := int(_paid[1])
    _check("the cleared wave pays gold",
        kill_gold > 0 and _purse_after_pay > _purse_at_wave_start,
        "%d kill gold + %d bonus, purse %d -> %d"
        % [kill_gold, bonus, _purse_at_wave_start, _purse_after_pay])

    var factors: Array = _paid[2]
    var fifth: Dictionary = factors[4] if factors.size() == 5 else {}
    _check("the fifth bonus factor scores the villager loss",
        String(fifth.get("name", "")) == "no villager lost" and not bool(fifth.get("won", true)),
        "%d factors, fifth is %s" % [factors.size(), fifth])


## The draft is the one step that waits on the player. It has to open on its own
## after a cleared wave, and taking a card has to be what closes it.
func _draft_opens_and_closes() -> void:
    var opened := await _until(func() -> bool:
        return _run_state.phase == RunState.Phase.DRAFT and _draft.is_open(), 60.0)
    _check("the draft opens after a cleared wave", opened,
        "phase %d, %d cards" % [_run_state.phase, _draft.cards().size()])
    var took := _draft.take(0) if opened else false
    var closed := await _until(func() -> bool:
        return not _draft.is_open() and _run_state.phase == RunState.Phase.PREP, 15.0)
    _check("taking a card closes the draft and prep begins", took and closed,
        "phase %d, open %s" % [_run_state.phase, str(_draft.is_open())])


## Places a structure the way BuildSystem._place() does, minus the mouse and the
## gold. Same order for the same reason: positioned before it enters the tree, and
## interpolation reset again after configure() adds the mesh and the shape.
func _build(id: String, at: Vector3) -> void:
    var type: StructureType = load("res://data/structures/%s.tres" % id)
    var s := Structure.new()
    s.position = _structures.to_local(at)
    _structures.add_child(s)
    s.configure(type)
    s.reset_physics_interpolation()
    if _nav and _nav.navigation_mesh:
        _nav.bake_navigation_mesh(false)


# --- plumbing -----------------------------------------------------------------

## Holds the stick on one leg of the sweep, releasing everything else. An empty
## list lets go of the stick entirely.
func _hold(leg: Array) -> void:
    for a in TILT_ACTIONS:
        if leg.has(a):
            Input.action_press(a, 1.0)
        else:
            Input.action_release(a)


## _until, with the tray steered instead of leant on. The magnitude is max_tilt_deg
## the whole way through; only the direction turns, on the beat a thumb would.
##
## It has to turn. A raider pinned against a wall, the keep or a corner tree is held
## there by a tilt that never changes: "only the rim tips them out" is deliberate,
## walls are meant to hold, so a single held direction leaves whatever it pressed
## into an obstacle standing there for the rest of the run. Steering the tray is the
## verb the game is built on; leaning on it is not.
func _sweep_until(pred: Callable, seconds: float) -> bool:
    var deadline := _sim + seconds
    var leg := 0
    var turn_at := 0.0
    while _sim < deadline:
        if pred.call():
            return true
        if _over_budget():
            return false
        if _sim >= turn_at:
            _hold(SWEEP_LEGS[leg % SWEEP_LEGS.size()])
            leg += 1
            turn_at = _sim + SWEEP_SECONDS
        await process_frame
    return pred.call()


## Advances the tree until `pred` is true or `seconds` of SIM time go by. Returns
## whether it was met, so a timeout reads as a failed check rather than as a pass
## against a world that never got there.
func _until(pred: Callable, seconds: float) -> bool:
    var deadline := _sim + seconds
    while _sim < deadline:
        if pred.call():
            return true
        if _over_budget():
            return false
        await process_frame
    return pred.call()


## Every mid-run check reports this, because "the keep fell first" and "the thing
## under test never happened" are different failures and read identically without it.
func _end_note() -> String:
    if _run_state.phase == RunState.Phase.LOST:
        return ", RUN LOST (the keep fell first)"
    if _run_state.phase == RunState.Phase.WON:
        return ", run won"
    return ", keep %d / %d" % [_keep.hp, _keep.max_hp]


func _over_budget() -> bool:
    return float(Time.get_ticks_msec() - _real_start) * 0.001 > REAL_BUDGET_SECONDS


func _check(label: String, ok: bool, detail := "") -> bool:
    _checks += 1
    if not ok:
        _failed += 1
    var line := "%s  %s" % ["ok  " if ok else "FAIL", label]
    if detail != "":
        line += "   -- " + detail
    print(line)
    return ok


func _report() -> void:
    # An exhausted wall clock is a failure in its own right: the checks it never
    # reached were not passes.
    if _over_budget():
        _failed += 1
        print("FAIL  the run stayed inside its %.0fs real-time budget"
            % REAL_BUDGET_SECONDS)
        _checks += 1
    print("smoke: %d checks, %d failed, %.1fs real, %.1fs sim"
        % [_checks, _failed, float(Time.get_ticks_msec() - _real_start) * 0.001, _sim])
    _done = true
    quit(1 if _failed > 0 else 0)
