extends CanvasLayer
class_name DraftUI

## The 1-of-3 between waves. Built in code like the HUD -- no .tscn, so
## tools/build_main.gd stays the only writer of the scene file.
##
## Three cards, 1/2/3 or a click, and a skip that costs gold and greys out when the
## player cannot pay it. The dim behind the cards ignores the mouse on purpose: the
## tray goes on rolling underneath and the player can still lean it while reading,
## which keeps the draft from feeling like a modal box bolted onto the game.

@export var draft_system: DraftSystem
@export var economy: Economy
@export var run_state: RunState

@export_group("Look")
@export_range(1, 5, 1) var max_cards := 3
@export var card_size := Vector2(258.0, 230.0)
@export var accent := Color("6fa8e8")

const KIND_COLOURS := {
    "ROLLER": Color("6fa8e8"),
    "STRUCTURE": Color("c9a86a"),
    "TRAY": Color("8fc98a"),
}

var _root: Control
var _title: Label
var _subtitle: Label
var _row: HBoxContainer
var _skip: Button
var _hint: Label
var _panels: Array[PanelContainer] = []
var _index_labels: Array[Label] = []
var _kind_labels: Array[Label] = []
var _title_labels: Array[Label] = []
var _body_labels: Array[Label] = []
var _why_labels: Array[Label] = []

var _style_idle: StyleBoxFlat
var _style_hover: StyleBoxFlat
var _shown := 0
var _summary := ""


func _ready() -> void:
    _style_idle = _card_style(false)
    _style_hover = _card_style(true)
    _build()
    _root.visible = false
    if draft_system:
        draft_system.offer_made.connect(_on_offer_made)
        draft_system.closed.connect(_on_closed)
    if run_state:
        run_state.wave_summary.connect(_on_wave_summary)
        run_state.phase_changed.connect(_on_phase_changed)


func _build() -> void:
    _root = Control.new()
    _root.set_anchors_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    var dim := ColorRect.new()
    dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    dim.color = Color(0.02, 0.03, 0.04, 0.55)
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(dim)

    var centre := CenterContainer.new()
    centre.set_anchors_preset(Control.PRESET_FULL_RECT)
    centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(centre)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 10)
    column.mouse_filter = Control.MOUSE_FILTER_IGNORE
    centre.add_child(column)

    _title = _text(column, 26, Color(0.95, 0.95, 0.93))
    _title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _subtitle = _text(column, 13, Color(0.78, 0.78, 0.74))
    _subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    _row = HBoxContainer.new()
    _row.add_theme_constant_override("separation", 14)
    _row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    column.add_child(_row)

    for i in max_cards:
        _make_card(i)

    var footer := HBoxContainer.new()
    footer.alignment = BoxContainer.ALIGNMENT_CENTER
    footer.add_theme_constant_override("separation", 14)
    column.add_child(footer)

    _skip = Button.new()
    _skip.add_theme_font_size_override("font_size", 13)
    _skip.focus_mode = Control.FOCUS_NONE
    _skip.pressed.connect(_on_skip_pressed)
    footer.add_child(_skip)

    _hint = Label.new()
    _hint.add_theme_font_size_override("font_size", 12)
    _hint.modulate = Color(1, 1, 1, 0.6)
    _hint.text = "press 1, 2 or 3 -- or click a card"
    footer.add_child(_hint)


func _make_card(index: int) -> void:
    var panel := PanelContainer.new()
    panel.custom_minimum_size = card_size
    panel.mouse_filter = Control.MOUSE_FILTER_STOP
    panel.add_theme_stylebox_override("panel", _style_idle)
    panel.gui_input.connect(_on_card_gui_input.bind(index))
    panel.mouse_entered.connect(_on_card_hover.bind(index, true))
    panel.mouse_exited.connect(_on_card_hover.bind(index, false))
    _row.add_child(panel)
    _panels.append(panel)

    var margin := MarginContainer.new()
    margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
    for side in ["left", "right", "top", "bottom"]:
        margin.add_theme_constant_override("margin_" + side, 14)
    panel.add_child(margin)

    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 6)
    box.mouse_filter = Control.MOUSE_FILTER_IGNORE
    margin.add_child(box)

    var head := HBoxContainer.new()
    head.mouse_filter = Control.MOUSE_FILTER_IGNORE
    box.add_child(head)

    var number := Label.new()
    number.text = "%d" % (index + 1)
    number.add_theme_font_size_override("font_size", 20)
    number.modulate = accent
    number.mouse_filter = Control.MOUSE_FILTER_IGNORE
    head.add_child(number)
    _index_labels.append(number)

    var kind := Label.new()
    kind.add_theme_font_size_override("font_size", 11)
    kind.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    kind.mouse_filter = Control.MOUSE_FILTER_IGNORE
    head.add_child(kind)
    _kind_labels.append(kind)

    _title_labels.append(_card_text(box, 18, Color(0.96, 0.95, 0.92), false))
    var body := _card_text(box, 12, Color(0.82, 0.82, 0.80), true)
    body.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _body_labels.append(body)
    _why_labels.append(_card_text(box, 11, Color("d8b26a"), true))


func _card_text(parent: VBoxContainer, font_size: int, colour: Color, wrap: bool) -> Label:
    var l := Label.new()
    l.add_theme_font_size_override("font_size", font_size)
    l.modulate = colour
    l.mouse_filter = Control.MOUSE_FILTER_IGNORE
    l.custom_minimum_size = Vector2(card_size.x - 28.0, 0.0)
    if wrap:
        l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    parent.add_child(l)
    return l


func _text(parent: VBoxContainer, font_size: int, colour: Color) -> Label:
    var l := Label.new()
    l.add_theme_font_size_override("font_size", font_size)
    l.modulate = colour
    l.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parent.add_child(l)
    return l


func _card_style(hover: bool) -> StyleBoxFlat:
    var sb := StyleBoxFlat.new()
    if hover:
        sb.bg_color = Color(0.13, 0.15, 0.18, 0.98)
        sb.border_color = accent
    else:
        sb.bg_color = Color(0.08, 0.09, 0.11, 0.95)
        sb.border_color = Color(0.28, 0.31, 0.35)
    sb.set_border_width_all(2)
    sb.set_corner_radius_all(6)
    return sb


func _process(_dt: float) -> void:
    if not _root.visible or draft_system == null:
        return
    var can := draft_system.can_skip()
    _skip.disabled = not can
    var gold := economy.gold if economy else 0
    _skip.text = "Skip for %d gold" % draft_system.skip_cost
    _skip.tooltip_text = ("You have %d gold" % gold) if can else "Not enough gold to skip"


# --- the offer ---------------------------------------------------------------

func _on_offer_made(wave: int, cards: Array) -> void:
    _shown = mini(cards.size(), _panels.size())
    for i in _panels.size():
        var on := i < _shown
        _panels[i].visible = on
        if on:
            _fill(i, cards[i])
        _set_hover(i, false)

    # RunState raises the wave number before it opens the draft, so the wave just
    # survived is the one behind this number.
    _title.text = "Wave %d cleared -- take one" % maxi(1, wave - 1)
    var next_line := "wave %d is next" % wave
    _subtitle.text = next_line if _summary.is_empty() else "%s     %s" % [_summary, next_line]
    _hint.text = "press %s -- or click a card" % _key_hint()
    _root.visible = true


func _fill(index: int, card: Variant) -> void:
    if not (card is Dictionary):
        return
    var c: Dictionary = card
    var tag := String(c.get("tag", ""))
    _kind_labels[index].text = tag
    _kind_labels[index].modulate = KIND_COLOURS.get(tag, Color(0.7, 0.7, 0.7))
    _index_labels[index].modulate = KIND_COLOURS.get(tag, accent)
    _title_labels[index].text = String(c.get("title", ""))
    _body_labels[index].text = String(c.get("body", ""))
    var why := String(c.get("why", ""))
    _why_labels[index].text = ("offered because %s" % why) if not why.is_empty() else ""
    _why_labels[index].visible = not why.is_empty()


func _key_hint() -> String:
    if _shown <= 1:
        return "1"
    var keys: Array[String] = []
    for i in _shown:
        keys.append("%d" % (i + 1))
    return "%s or %s" % [", ".join(keys.slice(0, _shown - 1)), keys[_shown - 1]]


func _on_closed() -> void:
    _root.visible = false


func _on_phase_changed(phase: int) -> void:
    # Belt and braces: a run that ends or restarts under an open draft must not
    # leave the cards hanging over the tray.
    if phase != RunState.Phase.DRAFT and not (draft_system and draft_system.is_open()):
        _root.visible = false


func _on_wave_summary(kill_gold: int, bonus: int, factors: Array) -> void:
    var won: Array[String] = []
    for f in factors:
        if f.get("pending", false):
            continue
        if f["won"]:
            won.append(String(f["name"]))
    _summary = "%d gold from kills" % kill_gold
    if bonus > 0:
        _summary += " +%d bonus" % bonus
    if not won.is_empty():
        _summary += ", earned " + ", ".join(won)


# --- input -------------------------------------------------------------------

func _unhandled_key_input(event: InputEvent) -> void:
    if not _root.visible:
        return
    var key := event as InputEventKey
    if key == null or not key.pressed or key.echo:
        return
    if key.keycode >= KEY_1 and key.keycode < KEY_1 + _shown:
        _take(key.keycode - KEY_1)
        get_viewport().set_input_as_handled()
    elif key.keycode == KEY_0:
        _on_skip_pressed()
        get_viewport().set_input_as_handled()


func _on_card_gui_input(event: InputEvent, index: int) -> void:
    var click := event as InputEventMouseButton
    if click and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
        _panels[index].accept_event()
        _take(index)


func _on_card_hover(index: int, hovering: bool) -> void:
    _set_hover(index, hovering)


func _set_hover(index: int, hovering: bool) -> void:
    if index < 0 or index >= _panels.size():
        return
    _panels[index].add_theme_stylebox_override("panel", _style_hover if hovering else _style_idle)


func _take(index: int) -> void:
    if draft_system and index >= 0 and index < _shown:
        draft_system.take(index)


func _on_skip_pressed() -> void:
    if draft_system and draft_system.can_skip():
        draft_system.skip()
