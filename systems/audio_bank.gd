extends Resource
class_name AudioBank

## The only file in the project that knows what a .ogg is called.
##
## A cue is a logical event name -- "impact_stone", "tray_groan" -- mapped to a set
## of interchangeable samples plus how loud, how high and how often it may sound.
## The director asks for AudioBank.IMPACT_STONE and never for a filename, so a
## re-skin is an edit to this table and nothing else. Every field is exported, so
## a designer can save a tuned bank as a .tres and drop it on the director.

# --- cue names ------------------------------------------------------------
# Rollers. The director picks one of these by what the impact point is near.
const IMPACT_TRAY := &"impact_tray"
const IMPACT_TRAY_HARD := &"impact_tray_hard"
const IMPACT_RIM := &"impact_rim"
const IMPACT_RIM_HARD := &"impact_rim_hard"
const IMPACT_STONE := &"impact_stone"
const IMPACT_WOOD := &"impact_wood"
const IMPACT_METAL := &"impact_metal"
const IMPACT_KEEP := &"impact_keep"
# The world.
const SPLASH := &"splash"
const TRAY_CREAK := &"tray_creak"
const TRAY_GROAN := &"tray_groan"
const TRAY_LEVEL := &"tray_level"
# The run.
const WAVE_START := &"wave_start"
const WAVE_CLEARED := &"wave_cleared"
const RUN_WON := &"run_won"
const RUN_LOST := &"run_lost"
const KEEP_HIT := &"keep_hit"
const KEEP_LOST := &"keep_lost"
const RAIDER_DOWN := &"raider_down"
const BUILD_PLACE := &"build_place"
const GOLD := &"gold"

## Where the samples live.
@export var sample_dir := "res://assets/audio/kenney_impact"

## cue name -> {
##   family:   String  file stem; the set is <family>_000.ogg .. <family>_00(count-1).ogg
##   count:    int     how many variations exist (Kenney ships 5 of each)
##   files:    PackedStringArray  explicit filenames, used instead of family/count
##   db:       float   cue gain, before the speed and chain offsets the director adds
##   pitch:    float   base pitch scale
##   jitter:   float   +/- random pitch spread, so repeats do not machine-gun
##   cooldown: float   seconds this cue must wait before it may sound again
##   flat:     bool    play on a non-positional voice (bells, the tray itself)
## }
@export var cues: Dictionary = {}

## StructureType.id -> cue. A roller hitting a bumper pings; a wall thuds.
@export var structure_cues: Dictionary = {}

## Fallback by StructureType.Kind, in enum order: WALL, RAMP, GATE, QUARRY, BUMPER.
@export var kind_cues: PackedStringArray = PackedStringArray()


## One logical event. Holds its own anti-repeat and cooldown state because both are
## per-cue: a splash may retrigger slowly while tray impacts must retrigger fast.
class Cue extends RefCounted:
    var id: StringName
    var streams: Array[AudioStream] = []
    var volume_db := 0.0
    var pitch := 1.0
    var jitter := 0.04
    var cooldown := 0.03
    var flat := false

    var _last := -1
    var _ready_at := 0.0

    func is_ready(now: float) -> bool:
        return now >= _ready_at

    func mark(now: float) -> void:
        _ready_at = now + cooldown

    ## Never returns the sample it returned last time: back-to-back repeats of one
    ## file are what make a pool of voices sound like a machine gun.
    func pick(rng: RandomNumberGenerator) -> AudioStream:
        var n := streams.size()
        if n == 0:
            return null
        if n == 1:
            _last = 0
            return streams[0]
        if _last < 0:
            _last = rng.randi_range(0, n - 1)
            return streams[_last]
        var i := rng.randi_range(0, n - 2)
        if i >= _last:
            i += 1
        _last = i
        return streams[i]


var _built: Dictionary = {}
var _by_id: Dictionary = {}
var _by_kind: Array[StringName] = []
var _missing: PackedStringArray = PackedStringArray()


func _init() -> void:
    # A .tres that overrides these is applied after _init, so an authored bank wins.
    if cues.is_empty():
        cues = default_cues()
    if structure_cues.is_empty():
        structure_cues = default_structure_cues()
    if kind_cues.is_empty():
        kind_cues = default_kind_cues()


## Resolves the table into Cue objects and loads every sample. Call once, before the
## first wave: nothing in this project touches the disk mid-wave. Returns the number
## of cues that ended up with at least one playable sample.
func build() -> int:
    _built.clear()
    _by_id.clear()
    _by_kind.clear()
    _missing = PackedStringArray()

    for key in cues:
        var id := StringName(key)
        var entry: Dictionary = cues[key]
        var c := Cue.new()
        c.id = id
        c.volume_db = float(entry.get("db", 0.0))
        c.pitch = float(entry.get("pitch", 1.0))
        c.jitter = float(entry.get("jitter", 0.04))
        c.cooldown = float(entry.get("cooldown", 0.03))
        c.flat = bool(entry.get("flat", false))
        for file in _files_for(entry):
            var path := sample_dir.path_join(file)
            if not ResourceLoader.exists(path):
                _missing.append(file)
                continue
            var stream := load(path) as AudioStream
            if stream:
                c.streams.append(stream)
            else:
                _missing.append(file)
        _built[id] = c

    for structure_id in structure_cues:
        _by_id[String(structure_id)] = StringName(String(structure_cues[structure_id]))
    for cue_name in kind_cues:
        _by_kind.append(StringName(cue_name))

    if not _missing.is_empty():
        push_warning("AudioBank: %d samples missing, first is %s" % [_missing.size(), _missing[0]])

    var ready_count := 0
    for id in _built:
        var c: Cue = _built[id]
        if not c.streams.is_empty():
            ready_count += 1
    return ready_count


## Null when the cue is unknown or has no samples; callers fall back rather than
## going silent.
func cue(id: StringName) -> Cue:
    if _built.has(id):
        var c: Cue = _built[id]
        return c if not c.streams.is_empty() else null
    return null


func has(id: StringName) -> bool:
    return cue(id) != null


## What a roller hitting this structure sounds like. Id first, so one bumper can be
## re-skinned without disturbing the kind fallback.
func structure_cue(structure_id: String, kind: int) -> StringName:
    if _by_id.has(structure_id):
        var by_id: StringName = _by_id[structure_id]
        return by_id
    if kind >= 0 and kind < _by_kind.size():
        return _by_kind[kind]
    return IMPACT_STONE


## Sample files the bank asked for and did not get. Empty is the healthy answer.
func missing_samples() -> PackedStringArray:
    return _missing


func cue_count() -> int:
    return _built.size()


func _files_for(entry: Dictionary) -> PackedStringArray:
    var explicit: PackedStringArray = entry.get("files", PackedStringArray())
    if not explicit.is_empty():
        return explicit
    var family := String(entry.get("family", ""))
    if family.is_empty():
        return PackedStringArray()
    var count := int(entry.get("count", 5))
    var out := PackedStringArray()
    for i in count:
        out.append("%s_%03d.ogg" % [family, i])
    return out


## Kenney's impact set mapped to what this game hits: wood is the tray, plank the
## rim, plate the stonework, metal the bumpers, and the bell is for moments.
func default_cues() -> Dictionary:
    return {
        # -- rollers. Loud enough to carry a cascade, quiet enough for 24 at once.
        IMPACT_TRAY: {"family": "impactWood_medium", "db": -5.0, "pitch": 1.0, "jitter": 0.02, "cooldown": 0.03},
        IMPACT_TRAY_HARD: {"family": "impactWood_heavy", "db": -3.0, "pitch": 1.0, "jitter": 0.02, "cooldown": 0.03},
        IMPACT_RIM: {"family": "impactPlank_medium", "db": -5.0, "pitch": 1.0, "jitter": 0.02, "cooldown": 0.03},
        IMPACT_RIM_HARD: {"family": "impactWood_heavy", "db": -3.0, "pitch": 0.92, "jitter": 0.02, "cooldown": 0.03},
        IMPACT_STONE: {"family": "impactPlate_medium", "db": -5.0, "pitch": 1.0, "jitter": 0.02, "cooldown": 0.03},
        IMPACT_WOOD: {"family": "impactWood_light", "db": -5.0, "pitch": 1.0, "jitter": 0.02, "cooldown": 0.03},
        IMPACT_METAL: {"family": "impactMetal_light", "db": -7.0, "pitch": 1.0, "jitter": 0.02, "cooldown": 0.03},
        IMPACT_KEEP: {"family": "impactPlate_heavy", "db": -5.0, "pitch": 0.9, "jitter": 0.03, "cooldown": 0.04},
        # -- the world.
        SPLASH: {"family": "impactSoft_heavy", "db": -6.0, "pitch": 0.9, "jitter": 0.09, "cooldown": 0.07},
        # The tray is the whole world, so its own noises are flat: no position.
        TRAY_CREAK: {"family": "impactWood_light", "db": -11.0, "pitch": 0.55, "jitter": 0.05, "cooldown": 0.25, "flat": true},
        TRAY_GROAN: {"family": "impactWood_heavy", "db": -6.0, "pitch": 0.42, "jitter": 0.03, "cooldown": 0.4, "flat": true},
        TRAY_LEVEL: {"family": "impactPlate_light", "db": -9.0, "pitch": 0.8, "jitter": 0.02, "cooldown": 0.2, "flat": true},
        # -- the run.
        WAVE_START: {"family": "impactBell_heavy", "db": -5.0, "pitch": 1.0, "jitter": 0.0, "cooldown": 0.5, "flat": true},
        WAVE_CLEARED: {"family": "impactBell_heavy", "db": -6.0, "pitch": 1.5, "jitter": 0.0, "cooldown": 0.5, "flat": true},
        RUN_WON: {"family": "impactBell_heavy", "db": -4.0, "pitch": 2.0, "jitter": 0.0, "cooldown": 0.5, "flat": true},
        RUN_LOST: {"family": "impactBell_heavy", "db": -4.0, "pitch": 0.5, "jitter": 0.0, "cooldown": 0.5, "flat": true},
        KEEP_HIT: {"family": "impactPlate_heavy", "db": -4.0, "pitch": 0.75, "jitter": 0.04, "cooldown": 0.12},
        KEEP_LOST: {"family": "impactBell_heavy", "db": -3.0, "pitch": 0.45, "jitter": 0.0, "cooldown": 0.5, "flat": true},
        RAIDER_DOWN: {"family": "impactPunch_heavy", "db": -9.0, "pitch": 1.0, "jitter": 0.08, "cooldown": 0.05, "flat": true},
        BUILD_PLACE: {"family": "impactMining", "db": -6.0, "pitch": 1.0, "jitter": 0.05, "cooldown": 0.08, "flat": true},
        GOLD: {"family": "impactTin_medium", "db": -7.0, "pitch": 1.25, "jitter": 0.04, "cooldown": 0.1, "flat": true},
    }


func default_structure_cues() -> Dictionary:
    return {
        "wall": IMPACT_STONE,
        "gate": IMPACT_WOOD,
        "ramp": IMPACT_WOOD,
        "bumper": IMPACT_METAL,
        "quarry": IMPACT_STONE,
        "house": IMPACT_WOOD,
    }


## StructureType.Kind order: WALL, RAMP, GATE, QUARRY, BUMPER, HOUSE. The kind enum
## is append-only, so a new kind lands on the end here too -- an id that misses this
## array falls past the end and gets IMPACT_STONE rather than erroring.
func default_kind_cues() -> PackedStringArray:
    return PackedStringArray([
        String(IMPACT_STONE), String(IMPACT_WOOD), String(IMPACT_WOOD),
        String(IMPACT_STONE), String(IMPACT_METAL), String(IMPACT_WOOD)])
