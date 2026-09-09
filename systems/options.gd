extends Node
class_name Options

## Player settings that outlive the process, kept as one small JSON file in user://.
##
## Two of these are not conveniences. Camera roll making people queasy is a listed
## risk with a playtest gate on it, so `lock_camera` and `reduce_motion` exist from
## day one and are reachable without a menu: F2 and F3 work whether or not the debug
## panel is showing.
##
## This node owns no behaviour of its own. It flips the switch TiltController already
## exposes (`lock_camera` holds the horizon level and leaves gravity alone), sets the
## master bus, and emits `changed` so Juice can react. It never writes physics.

signal changed(key: StringName)

const LOCK_CAMERA := &"lock_camera"
const REDUCE_MOTION := &"reduce_motion"
const MASTER_VOLUME := &"master_volume"
const MUTED := &"muted"
const UNLOCK_ALL := &"unlock_all"

## Bumped when the file's shape changes, or when a new default has to beat what an
## older file says: a file from a version we do not know is ignored rather than
## half-applied. Version 2 is the SFX going quiet. Every file written before it
## carries muted:false, and loading one would have turned the sound straight back
## on at startup -- which is the whole thing this round was asked to stop.
const SAVE_VERSION := 2

@export var tilt_controller: TiltController
@export var save_path := "user://tilt_options.json"
## Off for automated runs that must not touch a real player's settings.
@export var persist := true
## Writes are debounced by this long, so dragging a slider does not rewrite the file
## sixty times a second.
@export_range(0.0, 2.0, 0.05) var save_delay := 0.4

@export_group("Defaults")
## Used on a first run, and by reset_to_defaults(). Not the live values.
@export var default_lock_camera := false
@export var default_reduce_motion := false
@export_range(0.0, 1.0, 0.01) var default_master_volume := 0.8
## THE GAME SHIPS SILENT, and this is the single switch that does it. Ben asked for
## the SFX off "for now", so they are off rather than gone: muting the Master bus
## silences every voice at the one place both this node and AudioDirector agree is
## the player's, and F4 (or the mute box on the debug panel) lifts it again for as
## long as the player wants it. Nothing else mutes anything at startup -- the
## director keeps its own SFX bus unmuted and fully loaded.
@export var default_muted := true
## The design promises the whole kingdom can be seen without grinding for it.
## Nothing reads this yet; it is in the save file from the first build so honouring
## the promise later is not a migration.
@export var default_unlock_all := false

## Live values. Assigning any of them applies and persists it, so callers can write
## `options.reduce_motion = true` and be done.
var lock_camera := false: set = set_lock_camera
var reduce_motion := false: set = set_reduce_motion
var master_volume := 0.8: set = set_master_volume
var muted := false: set = set_muted
var unlock_all := false: set = set_unlock_all

var _loaded := false
var _dirty := false
var _save_timer := 0.0


func _ready() -> void:
    set_process(false)
    reset_to_defaults()
    if persist:
        load_settings()
    apply_all()
    # Everything above is startup, not a player decision: no signal, no save.
    _loaded = true


func _process(dt: float) -> void:
    if not _dirty:
        set_process(false)
        return
    _save_timer -= dt
    if _save_timer <= 0.0:
        save_settings()


func _notification(what: int) -> void:
    # Quitting must not eat the last toggle the player flipped.
    if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
        if _dirty and persist:
            save_settings()


func set_lock_camera(on: bool) -> void:
    if on == lock_camera and _loaded:
        return
    lock_camera = on
    _apply_camera()
    _note_change(LOCK_CAMERA)


func set_reduce_motion(on: bool) -> void:
    if on == reduce_motion and _loaded:
        return
    reduce_motion = on
    _note_change(REDUCE_MOTION)


func set_master_volume(v: float) -> void:
    var clamped := clampf(v, 0.0, 1.0)
    if is_equal_approx(clamped, master_volume) and _loaded:
        return
    master_volume = clamped
    _apply_audio()
    _note_change(MASTER_VOLUME)


func set_muted(on: bool) -> void:
    if on == muted and _loaded:
        return
    muted = on
    _apply_audio()
    _note_change(MUTED)


func set_unlock_all(on: bool) -> void:
    if on == unlock_all and _loaded:
        return
    unlock_all = on
    _note_change(UNLOCK_ALL)


## Generic access, so a settings UI can be a table of keys rather than a branch per
## control. Unknown keys warn instead of failing silently.
func get_flag(key: StringName) -> bool:
    if key == LOCK_CAMERA:
        return lock_camera
    if key == REDUCE_MOTION:
        return reduce_motion
    if key == MUTED:
        return muted
    if key == UNLOCK_ALL:
        return unlock_all
    push_warning("Options: get_flag on unknown key %s" % key)
    return false


func set_flag(key: StringName, on: bool) -> void:
    if key == LOCK_CAMERA:
        lock_camera = on
    elif key == REDUCE_MOTION:
        reduce_motion = on
    elif key == MUTED:
        muted = on
    elif key == UNLOCK_ALL:
        unlock_all = on
    else:
        push_warning("Options: set_flag on unknown key %s" % key)


func toggle_flag(key: StringName) -> void:
    set_flag(key, not get_flag(key))


func reset_to_defaults() -> void:
    lock_camera = default_lock_camera
    reduce_motion = default_reduce_motion
    master_volume = default_master_volume
    muted = default_muted
    unlock_all = default_unlock_all
    apply_all()


## Pushes every live value back out to whatever owns it. Cheap and idempotent.
func apply_all() -> void:
    _apply_camera()
    _apply_audio()


func to_dictionary() -> Dictionary:
    return {
        "version": SAVE_VERSION,
        String(LOCK_CAMERA): lock_camera,
        String(REDUCE_MOTION): reduce_motion,
        String(MASTER_VOLUME): master_volume,
        String(MUTED): muted,
        String(UNLOCK_ALL): unlock_all,
    }


func save_settings() -> bool:
    _dirty = false
    _save_timer = 0.0
    set_process(false)
    var dir := save_path.get_base_dir()
    if dir != "" and not DirAccess.dir_exists_absolute(dir):
        DirAccess.make_dir_recursive_absolute(dir)
    var f := FileAccess.open(save_path, FileAccess.WRITE)
    if f == null:
        push_warning("Options: cannot write %s (error %d)" % [save_path, FileAccess.get_open_error()])
        return false
    f.store_string(JSON.stringify(to_dictionary(), "\t"))
    f.close()
    return true


## True only when a file was found, parsed and applied. A missing file is the normal
## first run, not an error.
func load_settings() -> bool:
    if not FileAccess.file_exists(save_path):
        return false
    var f := FileAccess.open(save_path, FileAccess.READ)
    if f == null:
        push_warning("Options: cannot read %s (error %d)" % [save_path, FileAccess.get_open_error()])
        return false
    var text := f.get_as_text()
    f.close()

    var parsed: Variant = JSON.parse_string(text)
    if typeof(parsed) != TYPE_DICTIONARY:
        push_warning("Options: %s is not a settings file; keeping defaults" % save_path)
        return false
    var d: Dictionary = parsed
    if int(_number(d, "version", float(SAVE_VERSION))) != SAVE_VERSION:
        return false

    lock_camera = _flag(d, String(LOCK_CAMERA), lock_camera)
    reduce_motion = _flag(d, String(REDUCE_MOTION), reduce_motion)
    master_volume = _number(d, String(MASTER_VOLUME), master_volume)
    muted = _flag(d, String(MUTED), muted)
    unlock_all = _flag(d, String(UNLOCK_ALL), unlock_all)
    return true


func _apply_camera() -> void:
    # TiltController already knows how to hold the horizon level; this only asks it
    # to. Reimplementing the camera maths here would give the rig two writers.
    if tilt_controller:
        tilt_controller.lock_camera = lock_camera


func _apply_audio() -> void:
    var bus := AudioServer.get_bus_index(&"Master")
    if bus < 0:
        return
    # linear_to_db(0.0) is -inf, which some drivers dislike, so silence is the mute
    # flag rather than a vanishingly small gain.
    AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(master_volume, 0.001)))
    AudioServer.set_bus_mute(bus, muted or master_volume <= 0.001)


func _note_change(key: StringName) -> void:
    if not _loaded:
        return
    changed.emit(key)
    if persist:
        _dirty = true
        _save_timer = save_delay
        set_process(true)


func _flag(d: Dictionary, key: String, fallback: bool) -> bool:
    var v: Variant = d.get(key, fallback)
    return bool(v) if typeof(v) == TYPE_BOOL else fallback


func _number(d: Dictionary, key: String, fallback: float) -> float:
    var v: Variant = d.get(key, fallback)
    if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
        return float(v)
    return fallback
