extends CanvasLayer
class_name DebugPanel

## Day 1 tuning rig: the feel numbers on sliders, a tilt gauge with the 8 deg and
## 12 deg marks, and enough readout to judge a change without guessing. F1 hides it
## before you put the build in front of a stranger.
##
## It also carries the comfort switches until there is a real menu. Their hotkeys are
## handled here rather than on the panel, so F2 and F3 keep working with the panel
## hidden -- a player who needs the horizon held level must not have to find a debug
## rig first.

@export var tilt_controller: TiltController
@export var roller_pool: RollerPool
@export var audio_director: AudioDirector
## Only for the cascade readout: Economy scores the chain, the audio director counts
## contacts for pitch. Two different numbers, so the panel shows both.
@export var economy: Economy
## Hidden until F1. The rig is for tuning, not for playing over.
@export var start_hidden := false
@export var options: Options
@export var juice: Juice

const SLIDERS := [
    {"on": "tilt", "prop": "max_tilt_deg",   "label": "Max tilt",        "min": 0.0, "max": 30.0,  "step": 0.5,  "fmt": "%.1f deg"},
    {"on": "tilt", "prop": "tray_speed_deg", "label": "Tray speed",      "min": 5.0, "max": 200.0, "step": 1.0,  "fmt": "%.0f d/s"},
    {"on": "tilt", "prop": "spring",         "label": "Spring",          "min": 1.0, "max": 60.0,  "step": 0.5,  "fmt": "%.1f"},
    {"on": "tilt", "prop": "damping",        "label": "Damping",         "min": 0.0, "max": 30.0,  "step": 0.25, "fmt": "%.2f"},
    {"on": "pool", "prop": "friction",       "label": "Marble friction", "min": 0.0, "max": 1.0,   "step": 0.01, "fmt": "%.2f"},
    {"on": "pool", "prop": "restitution",    "label": "Marble bounce",   "min": 0.0, "max": 1.0,   "step": 0.01, "fmt": "%.2f"},
    {"on": "opts", "prop": "master_volume",  "label": "Volume",          "min": 0.0, "max": 1.0,   "step": 0.05, "fmt": "%.2f"},
]

## Comfort switches. These persist, so they are settings rather than tuning.
const TOGGLES := [
    {"key": &"lock_camera",   "label": "Lock camera (F2)"},
    {"key": &"reduce_motion", "label": "Reduce motion (F3)"},
    {"key": &"muted",         "label": "Mute (F4)"},
]

const TOGGLE_KEYS := {
    KEY_F2: &"lock_camera",
    KEY_F3: &"reduce_motion",
    KEY_F4: &"muted",
}

var _root: Control
var _readout: Label
var _gauge: Gauge
var _sliders := {}
var _value_labels := {}
var _defaults := {}
var _toggles := {}


class Gauge extends Control:
    var tilt := Vector2.ZERO
    var max_tilt := 12.0
    ## Villagers slip four degrees before raiders do (day 8).
    var villager_deg := 8.0

    func _draw() -> void:
        var c: Vector2 = size * 0.5
        var r: float = minf(size.x, size.y) * 0.5 - 4.0
        var px: float = r / maxf(max_tilt * 1.25, 1.0)
        draw_circle(c, r, Color(0.05, 0.07, 0.08, 0.6))
        draw_line(c - Vector2(r, 0.0), c + Vector2(r, 0.0), Color(1, 1, 1, 0.12), 1.0)
        draw_line(c - Vector2(0.0, r), c + Vector2(0.0, r), Color(1, 1, 1, 0.12), 1.0)
        draw_arc(c, villager_deg * px, 0.0, TAU, 48, Color(0.55, 0.48, 0.38, 0.9), 1.5)
        draw_arc(c, max_tilt * px, 0.0, TAU, 48, Color(0.77, 0.33, 0.23, 0.95), 2.0)
        var p: Vector2 = c + tilt * px
        draw_line(c, p, Color(0.24, 0.53, 0.85, 0.75), 2.0)
        draw_circle(p, 4.0, Color(0.24, 0.53, 0.85))


func _ready() -> void:
    _root = Control.new()
    _root.set_anchors_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)
    _build_panel()
    _build_gauge()
    _root.visible = not start_hidden
    # Options reads its file in its own _ready. If that lands after this panel is
    # built, the volume slider would sit on the default instead of the saved value.
    await get_tree().process_frame
    _sync_option_sliders()


func _build_panel() -> void:
    var panel := PanelContainer.new()
    panel.position = Vector2(12.0, 12.0)
    panel.custom_minimum_size = Vector2(320.0, 0.0)
    _root.add_child(panel)

    var vb := VBoxContainer.new()
    vb.add_theme_constant_override("separation", 3)
    panel.add_child(vb)

    var title := Label.new()
    title.text = "TILT - day 1 greybox"
    vb.add_child(title)

    var help := Label.new()
    help.text = "stick / WASD tilts, or right-drag the mouse\nB or Shift levels - F1 hides - Esc quits\nF2 lock camera - F3 reduce motion - F4 mute"
    help.add_theme_font_size_override("font_size", 11)
    help.modulate = Color(1, 1, 1, 0.6)
    vb.add_child(help)

    vb.add_child(HSeparator.new())

    for spec in SLIDERS:
        var target := _target(spec)
        if target == null:
            continue
        var prop: String = spec["prop"]
        _defaults[prop] = target.get(prop)

        var row := HBoxContainer.new()

        var name_label := Label.new()
        name_label.text = spec["label"]
        name_label.custom_minimum_size = Vector2(112.0, 0.0)
        name_label.add_theme_font_size_override("font_size", 12)
        row.add_child(name_label)

        var slider := HSlider.new()
        slider.min_value = spec["min"]
        slider.max_value = spec["max"]
        slider.step = spec["step"]
        slider.value = target.get(prop)
        slider.custom_minimum_size = Vector2(120.0, 0.0)
        slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        slider.value_changed.connect(_on_slider_changed.bind(spec))
        row.add_child(slider)

        var value_label := Label.new()
        value_label.custom_minimum_size = Vector2(58.0, 0.0)
        value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        value_label.add_theme_font_size_override("font_size", 12)
        row.add_child(value_label)

        vb.add_child(row)
        _sliders[prop] = slider
        _value_labels[prop] = value_label
        _refresh_value(spec)

    vb.add_child(HSeparator.new())
    _build_toggles(vb)

    var buttons := HBoxContainer.new()
    _add_button(buttons, "Respawn", _on_respawn)
    _add_button(buttons, "+30", _on_add)
    _add_button(buttons, "Clear", _on_clear)
    _add_button(buttons, "Reset feel", _on_reset)
    vb.add_child(buttons)

    _readout = Label.new()
    _readout.add_theme_font_size_override("font_size", 12)
    vb.add_child(_readout)


func _build_toggles(vb: VBoxContainer) -> void:
    if options == null:
        return
    for spec in TOGGLES:
        var key: StringName = spec["key"]
        var box := CheckBox.new()
        box.text = spec["label"]
        box.add_theme_font_size_override("font_size", 12)
        box.set_pressed_no_signal(options.get_flag(key))
        box.toggled.connect(_on_toggled.bind(key))
        vb.add_child(box)
        _toggles[key] = box
    vb.add_child(HSeparator.new())


func _sync_option_sliders() -> void:
    if options == null:
        return
    for spec in SLIDERS:
        if spec["on"] != "opts":
            continue
        var prop: String = spec["prop"]
        _defaults[prop] = options.get(prop)
        if _sliders.has(prop):
            _sliders[prop].set_value_no_signal(options.get(prop))
        _refresh_value(spec)


func _build_gauge() -> void:
    _gauge = Gauge.new()
    _gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _gauge.anchor_left = 1.0
    _gauge.anchor_top = 1.0
    _gauge.anchor_right = 1.0
    _gauge.anchor_bottom = 1.0
    _gauge.offset_left = -172.0
    _gauge.offset_top = -172.0
    _gauge.offset_right = -16.0
    _gauge.offset_bottom = -16.0
    _root.add_child(_gauge)


func _process(_dt: float) -> void:
    # A playtester runs with F1 hidden, and a readout nobody can see is still six
    # format strings, a walk of all 200 streak slots and a queued gauge redraw every
    # frame. The hotkeys live in _unhandled_key_input, so F2, F3 and F4 keep working
    # while this does nothing at all.
    if _root == null or not _root.visible:
        return
    _refresh()


func _refresh() -> void:
    var lines: Array[String] = ["fps %d" % Engine.get_frames_per_second()]
    if roller_pool:
        lines.append("rollers  %d on tray, %d lost" % [roller_pool.active_count(), roller_pool.lost_count()])
    if tilt_controller:
        lines.append("tilt  %.1f / %.1f  =  %.1f deg" % [
            tilt_controller.tilt.x, tilt_controller.tilt.y, tilt_controller.tilt.length()])
        var cd := tilt_controller.level_cooldown_left()
        lines.append("level  %s" % ("ready" if cd == 0.0 else "%.1fs" % cd))
        _gauge.tilt = tilt_controller.tilt
        _gauge.max_tilt = tilt_controller.max_tilt_deg
        _gauge.queue_redraw()
    if economy:
        # The scored chain: raider strikes only. This is what wins the bonus factor.
        lines.append("cascade  %d now, %d longest (target %d)" % [
            economy.chain, economy.longest_chain, economy.cascade_target])
    if audio_director:
        # The mix counter: every roller contact, driving the rising pitch. Not the score.
        lines.append("note  %d now, %d longest" % [audio_director.chain, audio_director.longest_chain])
    if juice:
        lines.append("juice  shake %.2f, %d streaks" % [juice.trauma(), juice.streak_count()])
    if options:
        lines.append("comfort  %s" % _comfort_text())
        # The hotkeys work with the panel hidden, so the boxes follow the settings
        # rather than the other way round.
        for spec in TOGGLES:
            var key: StringName = spec["key"]
            if _toggles.has(key):
                _toggles[key].set_pressed_no_signal(options.get_flag(key))
    _readout.text = "\n".join(lines)


func _comfort_text() -> String:
    var on: Array[String] = []
    for spec in TOGGLES:
        var key: StringName = spec["key"]
        if options.get_flag(key):
            on.append(String(key))
    return "off" if on.is_empty() else ", ".join(on)


func _unhandled_key_input(event: InputEvent) -> void:
    var key := event as InputEventKey
    if key == null or not key.pressed or key.echo:
        return
    if key.keycode == KEY_F1:
        _root.visible = not _root.visible
        # Nothing has been read while it was hidden, so the panel would show one
        # frame of whatever was true when it was put away -- including check boxes
        # that disagree with the settings F2 to F4 changed since.
        if _root.visible:
            _refresh()
        get_viewport().set_input_as_handled()
    elif options and TOGGLE_KEYS.has(key.keycode):
        var flag: StringName = TOGGLE_KEYS[key.keycode]
        options.toggle_flag(flag)
        get_viewport().set_input_as_handled()


func _target(spec: Dictionary) -> Object:
    match spec["on"]:
        "tilt":
            return tilt_controller
        "pool":
            return roller_pool
        "opts":
            return options
    return null


func _add_button(row: HBoxContainer, text: String, handler: Callable) -> void:
    var b := Button.new()
    b.text = text
    b.add_theme_font_size_override("font_size", 12)
    b.pressed.connect(handler)
    row.add_child(b)


func _on_slider_changed(value: float, spec: Dictionary) -> void:
    var target := _target(spec)
    if target:
        target.set(spec["prop"], value)
    _refresh_value(spec)


func _on_toggled(on: bool, key: StringName) -> void:
    if options:
        options.set_flag(key, on)


func _refresh_value(spec: Dictionary) -> void:
    var target := _target(spec)
    var prop: String = spec["prop"]
    if target and _value_labels.has(prop):
        _value_labels[prop].text = spec["fmt"] % target.get(prop)


func _on_respawn() -> void:
    if roller_pool:
        roller_pool.respawn()
    if audio_director:
        audio_director.reset_chain()


func _on_add() -> void:
    if roller_pool:
        roller_pool.spawn(30)


func _on_clear() -> void:
    if roller_pool:
        roller_pool.clear()


func _on_reset() -> void:
    for spec in SLIDERS:
        # Feel only. Volume is a setting the player chose, not a number being tuned.
        if spec["on"] == "opts":
            continue
        var target := _target(spec)
        var prop: String = spec["prop"]
        if target == null or not _defaults.has(prop):
            continue
        target.set(prop, _defaults[prop])
        if _sliders.has(prop):
            _sliders[prop].set_value_no_signal(_defaults[prop])
        _refresh_value(spec)
