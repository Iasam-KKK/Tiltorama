extends Node
class_name AudioDirector

## Everything you hear.
##
## The one behaviour worth protecting here: impact pitch RISES WITH CHAIN LENGTH.
## A cascade of ten plays a scale, which is the difference between "some marbles
## moved" and "I did that" -- and cascades are the whole reward loop. The counter
## runs on every qualifying contact whether or not a voice was free to play the
## note, so a busy mix never flattens the tune.
##
## That counter is a MIX counter, not a score. It rises on any contact the pool
## reports, a roller landing on the tray included, which is exactly right for pitch
## and exactly wrong for a bonus -- so the cascade the economy pays for is counted
## by Economy off raider strikes instead. The two are meant to differ.
##
## Rollers can produce hundreds of contacts a second at 200 bodies, so impacts draw
## on a token bucket and the voice pool steals its oldest voice. Nothing here is
## created after _ready: the voices, the samples and the cue table all exist before
## the first wave, like RollerPool and RaiderPool.

@export var roller_pool: RollerPool
@export var kill_volume: KillVolume
@export var tilt_controller: TiltController
@export var raider_pool: RaiderPool
@export var keep: Keep
@export var economy: Economy
## Read to name what a roller just hit. Never written.
@export var structures_root: Node3D
## RunState and BuildSystem are typed as plain Node on purpose: RunState already
## exports an AudioDirector and BuildSystem reaches RunState, so naming either class
## here would close a parse-time reference cycle. Their signals are connected by
## name instead, which costs nothing and keeps the scripts independent.
@export var run_state: Node
@export var build_system: Node

@export_group("Mixer")
## The greybox gets played muted a lot. False stops every voice before it starts.
@export var enabled := true: set = _set_enabled
@export var muted := false: set = _set_muted
@export_range(-60.0, 6.0, 0.5) var master_db := 0.0: set = _set_master_db
@export_range(-60.0, 6.0, 0.5) var sfx_db := -3.0: set = _set_sfx_db
## Created at runtime if the project has no such bus, so there is no bus layout
## file to keep in sync with this scene.
@export var sfx_bus := &"SFX"
## Samples and their tuning. One is built with the defaults if this is left empty.
@export var bank: AudioBank
## Print each event to the console instead of trusting your ears.
@export var log_events := false

@export_group("Voices")
@export_range(4, 64, 1) var voice_count := 24
@export_range(1, 16, 1) var flat_voice_count := 4
## The camera sits 32 m out, so sounds need a generous unit size to carry.
@export_range(1.0, 80.0, 0.5) var voice_unit_size := 26.0
@export_range(0.0, 3.0, 0.05) var panning_strength := 0.7
## Impacts per second the mix will accept, and how many may arrive at once. A
## cascade should sound busy; it should not sound like static.
@export_range(1.0, 120.0, 1.0) var impacts_per_second := 22.0
@export_range(1.0, 20.0, 1.0) var impact_burst := 6.0

@export_group("Chain")
## Contacts within this many seconds of each other count as one chain.
@export_range(0.1, 3.0, 0.05) var chain_window := 0.8
## Semitones above the cue's base pitch, one entry per step of the chain. A major
## pentatonic: any two notes in it are consonant, so a ten-ball cascade plays a
## tune instead of a siren. The last entry is held for longer chains.
@export var chain_scale: PackedInt32Array = PackedInt32Array([0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24])
## Steps per second the note slides back down during a lull. A wave is busy enough
## that without this every impact would sit pinned at the top of the scale within a
## second or two; with it, a real cascade sweeps up and the odd knock stays low.
@export_range(0.0, 20.0, 0.1) var chain_note_decay := 2.5
## Decibels added per step of the chain, so a long cascade also swells.
@export_range(0.0, 1.0, 0.05) var chain_db_gain := 0.15

@export_group("Impact")
## Below this an impact plays at soft_db, above loud_speed at loud_db.
@export_range(0.0, 20.0, 0.1) var soft_speed := 2.5
@export_range(0.0, 30.0, 0.1) var loud_speed := 9.0
## Fast enough to deserve the heavier sample of a pair.
@export_range(0.0, 30.0, 0.1) var hard_variant_speed := 6.0
@export_range(-40.0, 0.0, 0.5) var soft_db := -9.0
@export_range(-20.0, 12.0, 0.5) var loud_db := 2.0
## Distance from tray centre to the inside face of a rim.
@export var tray_half := 5.6
## How far in from a rim still counts as hitting the rim.
@export_range(0.0, 2.0, 0.05) var rim_band := 0.45
## An impact inside this radius of the keep rings the keep instead of the ground.
@export_range(0.0, 4.0, 0.05) var keep_radius := 0.95
@export_range(0.0, 8.0, 0.05) var keep_height := 2.8
## Added to a structure's own footprint when deciding whether it was what got hit.
@export_range(0.0, 2.0, 0.05) var structure_margin := 0.35

@export_group("Tray stress")
## The sound IS the warning. Villagers slip at 8 degrees and the tray caps at 12,
## so the creak starts before the slip and the groan lands at the limit.
@export_range(0.0, 30.0, 0.1) var creak_deg := 8.0
@export_range(0.0, 30.0, 0.1) var groan_deg := 11.0
## How far the tray must relax before it stops complaining. Without this the tray
## chatters between two states while you hold the stick on the threshold.
@export_range(0.0, 5.0, 0.05) var stress_hysteresis_deg := 0.6
@export_range(0.1, 5.0, 0.05) var creak_repeat := 1.1
@export_range(0.1, 8.0, 0.05) var groan_repeat := 2.0
## Semitones the creak bends down by as the tray approaches its limit.
@export_range(0.0, 12.0, 0.5) var stress_bend_semitones := 2.0

## How many contacts the note has climbed. Shown on the debug panel and reset by
## RunState at the start of a wave. Economy scores the cascade, not this.
var chain := 0
var longest_chain := 0

## RunState.Phase, spelled out rather than imported -- see the run_state export.
const PHASE_WAVE := 1
const PHASE_CLEARED := 2
const PHASE_LOST := 3
const PHASE_WON := 4
## How often the structure cache checks whether anything was built. Prep-only work.
const STRUCTURE_RECHECK := 0.5

var _chain_timer := 0.0
## Position on chain_scale. A float because it slides back down between hits.
var _note := 0.0
var _rng := RandomNumberGenerator.new()

var _voices: Array[AudioStreamPlayer3D] = []
var _voice_at := PackedFloat64Array()
var _flat_voices: Array[AudioStreamPlayer] = []
var _flat_at := PackedFloat64Array()

var _bucket := 0.0
var _bucket_at := 0.0

var _stress := 0
var _stress_timer := 0.0

var _struct_pos := PackedVector3Array()
var _struct_r2 := PackedFloat32Array()
var _struct_h := PackedFloat32Array()
var _struct_cue: Array[StringName] = []
var _struct_count := -1
var _struct_check_at := 0.0

var _keep_hp := -1


func _ready() -> void:
    _rng.randomize()
    if bank == null:
        bank = AudioBank.new()
    var ready_cues := bank.build()
    # The bus has to exist before a voice names it, or every player errors on load.
    _ensure_bus()
    _make_voices()
    _apply_mixer()
    _bucket = impact_burst
    _bucket_at = _seconds()

    if roller_pool:
        roller_pool.impact.connect(_on_impact)
    if kill_volume:
        kill_volume.fell.connect(_on_fell)
    if tilt_controller:
        tilt_controller.levelled.connect(_on_levelled)
    if raider_pool:
        raider_pool.raider_died.connect(_on_raider_died)
    if keep:
        _keep_hp = keep.hp
        keep.hp_changed.connect(_on_keep_hp_changed)
        keep.destroyed.connect(_on_keep_destroyed)
    if economy:
        economy.wave_paid.connect(_on_wave_paid)
    if run_state and run_state.has_signal(&"phase_changed"):
        run_state.connect(&"phase_changed", _on_phase_changed)
    if build_system and build_system.has_signal(&"structures_changed"):
        build_system.connect(&"structures_changed", _on_structures_changed)

    _refresh_structures()
    if log_events:
        print("audio: %d cues, %d voices, bus %s" % [ready_cues, _voices.size(), sfx_bus])


func reset_chain() -> void:
    chain = 0
    longest_chain = 0
    _chain_timer = 0.0
    _note = 0.0


## The public way in for anything that wants a noise. `at` is ignored for cues the
## bank marks flat. Returns false when the cue was unknown, muted or on cooldown.
func play(id: StringName, at := Vector3.ZERO, semitones := 0, db_offset := 0.0, pitch_mul := 1.0) -> bool:
    if not enabled or bank == null:
        return false
    var c := bank.cue(id)
    if c == null:
        return false
    var now := _seconds()
    if not c.is_ready(now):
        return false
    var stream := c.pick(_rng)
    if stream == null:
        return false
    c.mark(now)

    var pitch := c.pitch * pitch_mul * pow(2.0, float(semitones) / 12.0)
    pitch *= 1.0 + _rng.randf_range(-c.jitter, c.jitter)
    pitch = clampf(pitch, 0.05, 4.0)
    var db := c.volume_db + db_offset

    if c.flat:
        _start_flat(stream, pitch, db, now)
    else:
        _start_3d(stream, pitch, db, at, now)
    return true


## How many spatial voices are busy. Handy on a debug readout when a mix is muddy.
func voices_playing() -> int:
    var n := 0
    for v in _voices:
        if v.playing:
            n += 1
    return n


func _process(dt: float) -> void:
    if _chain_timer > 0.0:
        _chain_timer = maxf(0.0, _chain_timer - dt)
        if _chain_timer == 0.0:
            chain = 0
            _note = 0.0
    _note = maxf(0.0, _note - chain_note_decay * dt)
    if not enabled:
        return
    _tick_stress(dt)
    _tick_structures()


# --- events ---------------------------------------------------------------

func _on_impact(speed: float, at: Vector3) -> void:
    # Counted first and unconditionally, before the token bucket can drop the note:
    # the pitch has to keep climbing through a cascade too busy to voice every hit.
    chain += 1
    longest_chain = maxi(longest_chain, chain)
    _chain_timer = chain_window
    if log_events:
        print("impact %.1f m/s at %s, chain %d" % [speed, at, chain])
    if not enabled:
        return
    if not _spend_impact_token():
        return
    # The note is read before it advances, so the first hit of a cascade is the
    # root and every audible hit after it is one rung higher -- the Peggle trick.
    var step := _chain_step()
    var db := _impact_db(speed) + chain_db_gain * float(step)
    if play(_classify(at, speed), at, _chain_semitones(step), db):
        _note = minf(_note + 1.0, float(maxi(chain_scale.size() - 1, 0)))


func _on_fell(at: Vector3) -> void:
    if log_events:
        print("fell at %s" % at)
    play(AudioBank.SPLASH, at)


func _on_levelled() -> void:
    if log_events:
        print("levelled")
    # The tray is flat again, so it has nothing to complain about.
    _stress = 0
    _stress_timer = 0.0
    play(AudioBank.TRAY_LEVEL)


func _on_raider_died(type: RaiderType, fell: bool) -> void:
    # A raider that went over the edge already got a splash from the kill volume.
    if fell:
        return
    # Heavier raiders go down lower. A jarl should not squeak.
    var mass := type.mass if type else 1.0
    play(AudioBank.RAIDER_DOWN, Vector3.ZERO, 0, 0.0, clampf(1.0 / sqrt(maxf(mass, 0.05)), 0.6, 1.3))


func _on_keep_hp_changed(hp: int, _max_hp: int) -> void:
    var hit := _keep_hp >= 0 and hp < _keep_hp
    _keep_hp = hp
    if hit and keep:
        play(AudioBank.KEEP_HIT, keep.global_position)


func _on_keep_destroyed() -> void:
    play(AudioBank.KEEP_LOST)


func _on_wave_paid(_kill_gold: int, _bonus: int, _factors: Array) -> void:
    play(AudioBank.GOLD)


func _on_phase_changed(phase: int) -> void:
    match phase:
        PHASE_WAVE:
            play(AudioBank.WAVE_START)
        PHASE_CLEARED:
            play(AudioBank.WAVE_CLEARED)
        PHASE_WON:
            play(AudioBank.RUN_WON)
        PHASE_LOST:
            # The keep's own death toll covers this when the keep is wired up.
            if keep == null:
                play(AudioBank.RUN_LOST)


func _on_structures_changed() -> void:
    _refresh_structures()
    play(AudioBank.BUILD_PLACE)


# --- impacts --------------------------------------------------------------

## A token bucket, refilled continuously. Hundreds of contacts a second would
## otherwise steal every voice from itself and turn a cascade into white noise.
func _spend_impact_token() -> bool:
    var now := _seconds()
    _bucket = minf(impact_burst, _bucket + (now - _bucket_at) * impacts_per_second)
    _bucket_at = now
    if _bucket < 1.0:
        return false
    _bucket -= 1.0
    return true


func _chain_step() -> int:
    if chain_scale.is_empty():
        return 0
    return clampi(int(_note), 0, chain_scale.size() - 1)


func _chain_semitones(step: int) -> int:
    if chain_scale.is_empty():
        return 0
    return chain_scale[step]


func _impact_db(speed: float) -> float:
    if loud_speed <= soft_speed:
        return loud_db
    var t := clampf((speed - soft_speed) / (loud_speed - soft_speed), 0.0, 1.0)
    return lerpf(soft_db, loud_db, t)


## RollerPool reports where a contact happened but not what it was against, and it
## is not this file's to change -- so the point is matched against the things that
## can be hit. Only impacts that already won a voice get here, so the loop is small
## and rare.
func _classify(at: Vector3, speed: float) -> StringName:
    var hard := speed >= hard_variant_speed
    if keep:
        var to_keep := at - keep.global_position
        if Vector2(to_keep.x, to_keep.z).length() <= keep_radius and to_keep.y <= keep_height:
            return AudioBank.IMPACT_KEEP
    for i in _struct_cue.size():
        var p := _struct_pos[i]
        var dx := at.x - p.x
        var dz := at.z - p.z
        if dx * dx + dz * dz > _struct_r2[i]:
            continue
        if at.y > p.y + _struct_h[i]:
            continue
        return _struct_cue[i]
    if absf(at.x) >= tray_half - rim_band or absf(at.z) >= tray_half - rim_band:
        return _variant(AudioBank.IMPACT_RIM, AudioBank.IMPACT_RIM_HARD, hard)
    return _variant(AudioBank.IMPACT_TRAY, AudioBank.IMPACT_TRAY_HARD, hard)


func _variant(soft: StringName, hard: StringName, use_hard: bool) -> StringName:
    return hard if use_hard and bank and bank.has(hard) else soft


# --- the tray -------------------------------------------------------------

## Reads the tilt every frame and complains about it. Two levels: a creak from the
## angle where villagers start to slip, a groan at the cap. This is the warning --
## a player who has heard it twice knows what 11 degrees costs without looking.
func _tick_stress(dt: float) -> void:
    if tilt_controller == null:
        return
    var deg := tilt_controller.tilt.length()
    var want := 0
    if deg >= groan_deg:
        want = 2
    elif deg >= creak_deg:
        want = 1
    if want < _stress:
        var floor_deg := (groan_deg if _stress == 2 else creak_deg) - stress_hysteresis_deg
        if deg > floor_deg:
            want = _stress
    if want != _stress:
        _stress = want
        _stress_timer = 0.0
    if _stress == 0:
        return

    _stress_timer -= dt
    if _stress_timer > 0.0:
        return
    var span := maxf(groan_deg - creak_deg, 0.01)
    var strain := clampf((deg - creak_deg) / span, 0.0, 1.0)
    var bend := -int(round(stress_bend_semitones * strain))
    if _stress == 2:
        _stress_timer = groan_repeat
        play(AudioBank.TRAY_GROAN, Vector3.ZERO, bend)
    else:
        _stress_timer = creak_repeat * _rng.randf_range(0.85, 1.15)
        play(AudioBank.TRAY_CREAK, Vector3.ZERO, bend)


# --- structures -----------------------------------------------------------

func _tick_structures() -> void:
    if structures_root == null:
        return
    var now := _seconds()
    if now < _struct_check_at:
        return
    _struct_check_at = now + STRUCTURE_RECHECK
    if structures_root.get_child_count() != _struct_count:
        _refresh_structures()


func _refresh_structures() -> void:
    _struct_pos.clear()
    _struct_r2.clear()
    _struct_h.clear()
    _struct_cue.clear()
    if structures_root == null or bank == null:
        _struct_count = 0
        return
    _struct_count = structures_root.get_child_count()
    for child in structures_root.get_children():
        var s := child as Structure
        if s == null or s.type == null:
            continue
        var footprint := s.type.footprint
        var r := maxf(footprint.x, footprint.z) * 0.5 + structure_margin
        _struct_pos.append(s.global_position)
        _struct_r2.append(r * r)
        _struct_h.append(footprint.y + structure_margin)
        _struct_cue.append(bank.structure_cue(s.type.id, int(s.type.kind)))


# --- voices ---------------------------------------------------------------

func _make_voices() -> void:
    for i in voice_count:
        var v := AudioStreamPlayer3D.new()
        v.name = "Voice%02d" % i
        v.bus = sfx_bus
        v.unit_size = voice_unit_size
        v.panning_strength = panning_strength
        v.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
        add_child(v)
        _voices.append(v)
        _voice_at.append(0.0)
    for i in flat_voice_count:
        var f := AudioStreamPlayer.new()
        f.name = "Flat%02d" % i
        f.bus = sfx_bus
        add_child(f)
        _flat_voices.append(f)
        _flat_at.append(0.0)


func _start_3d(stream: AudioStream, pitch: float, db: float, at: Vector3, now: float) -> void:
    var i := _claim_3d()
    var v := _voices[i]
    v.stream = stream
    v.pitch_scale = pitch
    v.volume_db = db
    v.global_position = at
    # Physics interpolation is on project-wide: without this the voice pans from
    # wherever it last played for one frame.
    v.reset_physics_interpolation()
    v.play()
    _voice_at[i] = now


func _start_flat(stream: AudioStream, pitch: float, db: float, now: float) -> void:
    var i := _claim_flat()
    var f := _flat_voices[i]
    f.stream = stream
    f.pitch_scale = pitch
    f.volume_db = db
    f.play()
    _flat_at[i] = now


## First idle voice, else the one that started longest ago. Stealing the oldest is
## what keeps a cascade sounding like its most recent hits.
func _claim_3d() -> int:
    var oldest := 0
    var oldest_at := INF
    for i in _voices.size():
        if not _voices[i].playing:
            return i
        if _voice_at[i] < oldest_at:
            oldest_at = _voice_at[i]
            oldest = i
    return oldest


func _claim_flat() -> int:
    var oldest := 0
    var oldest_at := INF
    for i in _flat_voices.size():
        if not _flat_voices[i].playing:
            return i
        if _flat_at[i] < oldest_at:
            oldest_at = _flat_at[i]
            oldest = i
    return oldest


# --- mixer ----------------------------------------------------------------

## Made at runtime so there is no bus layout resource to drift out of sync with
## this scene, and so a project that already defines an SFX bus keeps its own.
func _ensure_bus() -> void:
    if AudioServer.get_bus_index(sfx_bus) >= 0:
        return
    AudioServer.add_bus()
    var idx := AudioServer.bus_count - 1
    AudioServer.set_bus_name(idx, String(sfx_bus))
    AudioServer.set_bus_send(idx, &"Master")


func _apply_mixer() -> void:
    # The editor shares this process's AudioServer; muting it from an inspector
    # tweak would be a surprise.
    if Engine.is_editor_hint():
        return
    # The Master bus belongs to Options -- it is the player's volume, it persists,
    # and two writers on one bus means whichever setter fired last wins. master_db
    # is this director's own trim, so it rides on the SFX bus with sfx_db instead.
    var idx := AudioServer.get_bus_index(sfx_bus)
    if idx < 0:
        return
    AudioServer.set_bus_volume_db(idx, sfx_db + master_db)
    AudioServer.set_bus_mute(idx, muted or not enabled)


func _set_enabled(v: bool) -> void:
    enabled = v
    _apply_mixer()


func _set_muted(v: bool) -> void:
    muted = v
    _apply_mixer()


func _set_master_db(v: float) -> void:
    master_db = v
    _apply_mixer()


func _set_sfx_db(v: float) -> void:
    sfx_db = v
    _apply_mixer()


func _seconds() -> float:
    return float(Time.get_ticks_msec()) * 0.001
