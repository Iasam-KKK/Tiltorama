extends CanvasLayer
class_name HUD

## Reads everything, writes nothing.
##
## And reads it a few times a second, not sixty. Every line here changes at the pace
## of a wave -- gold on a purchase, the countdown once a second, the roller count
## when one goes over the rim -- but rebuilding it costs ten format allocations, two
## arrays, two joins and a walk of every structure on the tray for the base value.
## So: a throttle for the numbers nothing announces (the counts, the countdown), and
## a refresh on the spot for the ones the player just caused, which are the ones a
## delay would be felt on.

@export var run_state: RunState
@export var economy: Economy
@export var keep: Keep
@export var roller_pool: RollerPool
@export var raider_pool: RaiderPool
@export var wave_director: WaveDirector
@export var build_system: BuildSystem
@export var villager_pool: VillagerPool
## Ten a second is faster than any of these numbers moves and is invisible on the
## PREP countdown, which is the only line that reads as continuous.
@export_range(0.02, 1.0, 0.01) var refresh_seconds := 0.1

var _since_refresh := 0.0

var _root: Control
var _phase_label: Label
var _threat_label: Label
var _gold_label: Label
var _keep_bar: ProgressBar
var _keep_label: Label
var _counts_label: Label
var _palette_label: Label
var _banner: Label
var _summary: Label

const PHASE_NAMES := {
    RunState.Phase.PREP: "PREP",
    RunState.Phase.WAVE: "WAVE",
    RunState.Phase.CLEARED: "CLEARED",
    RunState.Phase.LOST: "LOST",
    RunState.Phase.WON: "HELD",
    RunState.Phase.DRAFT: "DRAFT",
}


func _ready() -> void:
    _root = Control.new()
    _root.set_anchors_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    _phase_label = _label(Control.PRESET_TOP_LEFT, Vector2(16.0, 12.0), 20)
    _threat_label = _label(Control.PRESET_CENTER_TOP, Vector2(-170.0, 12.0), 13)
    _threat_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _threat_label.custom_minimum_size = Vector2(340.0, 0.0)
    _threat_label.size = Vector2(340.0, 0.0)

    _gold_label = _label(Control.PRESET_TOP_RIGHT, Vector2(-220.0, 12.0), 18)
    _gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _gold_label.custom_minimum_size = Vector2(200.0, 0.0)
    _gold_label.size = Vector2(200.0, 0.0)

    _keep_label = _label(Control.PRESET_TOP_RIGHT, Vector2(-220.0, 40.0), 12)
    _keep_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _keep_label.custom_minimum_size = Vector2(200.0, 0.0)
    _keep_label.size = Vector2(200.0, 0.0)

    _keep_bar = ProgressBar.new()
    _keep_bar.show_percentage = false
    _keep_bar.custom_minimum_size = Vector2(200.0, 8.0)
    _keep_bar.anchor_left = 1.0
    _keep_bar.anchor_right = 1.0
    _keep_bar.offset_left = -220.0
    _keep_bar.offset_right = -20.0
    _keep_bar.offset_top = 60.0
    _keep_bar.offset_bottom = 68.0
    _keep_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(_keep_bar)

    _counts_label = _label(Control.PRESET_BOTTOM_LEFT, Vector2(16.0, -70.0), 13)
    _palette_label = _label(Control.PRESET_BOTTOM_LEFT, Vector2(16.0, -34.0), 13)

    _banner = _label(Control.PRESET_CENTER, Vector2(-260.0, -60.0), 34)
    _banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _banner.custom_minimum_size = Vector2(520.0, 0.0)
    _banner.size = Vector2(520.0, 0.0)

    _summary = _label(Control.PRESET_CENTER, Vector2(-260.0, -8.0), 14)
    _summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _summary.custom_minimum_size = Vector2(520.0, 0.0)
    _summary.size = Vector2(520.0, 0.0)

    if run_state:
        run_state.wave_summary.connect(_on_wave_summary)
        # Everything a player does on purpose redraws on the frame they did it. The
        # throttle below is only for what nobody announces.
        run_state.phase_changed.connect(_refresh_now.unbind(1))
        run_state.wave_changed.connect(_refresh_now.unbind(1))
    if economy:
        economy.gold_changed.connect(_refresh_now.unbind(1))
    if keep:
        keep.hp_changed.connect(_refresh_now.unbind(2))
    if build_system:
        build_system.palette_changed.connect(_refresh_now.unbind(1))
        build_system.structures_changed.connect(_refresh_now)


func _label(preset: int, offset: Vector2, font_size: int) -> Label:
    var l := Label.new()
    l.set_anchors_preset(preset)
    l.position = offset
    l.add_theme_font_size_override("font_size", font_size)
    l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
    l.add_theme_constant_override("shadow_offset_y", 1)
    l.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(l)
    return l


func _process(dt: float) -> void:
    _since_refresh += dt
    if _since_refresh < refresh_seconds:
        return
    _refresh_now()


## Straight to the readout, throttle reset: a signal-driven redraw is the newest
## picture there is, so the clock has nothing left to catch up on.
func _refresh_now() -> void:
    _since_refresh = 0.0
    _refresh()


func _refresh() -> void:
    if run_state == null:
        return

    var phase_name: String = PHASE_NAMES.get(run_state.phase, "?")
    var line := "Wave %d / %d   %s" % [run_state.wave, run_state.table.boss_wave, phase_name]
    if run_state.phase == RunState.Phase.PREP:
        line += "   %ds" % ceili(run_state.seconds_left)
    _phase_label.text = line

    var base := run_state.current_base_value()
    # Not next_budget(): it calls current_base_value() again, so asking for both
    # walks every structure on the tray twice for one line of text.
    var budget: float = wave_director.budget_for(run_state.wave, base) if wave_director else 0.0
    var threat := "threat  base %d  ->  next wave budget %.1f" % [base, budget]
    if wave_director and wave_director.last_preview != "":
        threat += "\n%s" % wave_director.last_preview
    _threat_label.text = threat

    if economy:
        _gold_label.text = "%d gold" % economy.gold
    if keep:
        _keep_bar.max_value = keep.max_hp
        _keep_bar.value = keep.hp
        _keep_label.text = "keep  %d / %d" % [keep.hp, keep.max_hp]

    var counts: Array[String] = []
    if roller_pool:
        counts.append("rollers %d on tray, %d lost" % [roller_pool.active_count(), roller_pool.lost_count()])
    if raider_pool:
        counts.append("raiders %d" % raider_pool.alive_count())
    if villager_pool and villager_pool.capacity() > 0:
        # Income is per head, so the headcount is the number that matters --
        # a villager over the rim is a wage you stop being paid.
        counts.append("villagers %d / %d beds, %dg a wave" % [
            villager_pool.alive_count(), villager_pool.capacity(),
            villager_pool.income_per_wave()])
    _counts_label.text = "   ".join(counts)

    _palette_label.text = _palette_text()
    _banner.text = _banner_text()
    if run_state.phase not in [RunState.Phase.CLEARED, RunState.Phase.LOST, RunState.Phase.WON]:
        _summary.text = ""


func _palette_text() -> String:
    if build_system == null or not build_system.active or build_system.palette.is_empty():
        if run_state and run_state.phase == RunState.Phase.WAVE:
            return "hold Space to open gates"
        return ""
    var parts: Array[String] = []
    for i in build_system.palette.size():
        var t: StructureType = build_system.palette[i]
        var mark := ">" if i == build_system.selected else " "
        parts.append("%s%d %s %dg" % [mark, i + 1, t.display_name, t.cost])
    return "build:  " + "   ".join(parts) + "     (click to place, Enter calls the wave)"


func _banner_text() -> String:
    match run_state.phase:
        RunState.Phase.LOST:
            return "The keep has fallen\npress Space to run it again"
        RunState.Phase.WON:
            return "Tray held\npress Space to run it again"
        RunState.Phase.CLEARED:
            return "Wave %d cleared" % run_state.wave
        _:
            return ""


func _on_wave_summary(kill_gold: int, bonus: int, factors: Array) -> void:
    var won: Array[String] = []
    var missed: Array[String] = []
    for f in factors:
        if f.get("pending", false):
            continue
        if f["won"]:
            won.append(f["name"])
        else:
            missed.append(f["name"])
    var text := "%d gold from kills" % kill_gold
    # The bonus is the whole point of the five factors, so it goes on the line the
    # factors are listed under rather than only into the purse.
    if bonus > 0:
        text += "   +%d bonus" % bonus
    if not won.is_empty():
        text += "\nearned: " + ", ".join(won)
    if not missed.is_empty():
        text += "\nmissed: " + ", ".join(missed)
    _summary.text = text
