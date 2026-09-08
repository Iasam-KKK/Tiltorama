extends Node
class_name RunState

## prep -> wave -> cleared -> draft -> prep, and the two ways out. This is the hub:
## it owns the phase, the wave number and the base value, and it is the only thing
## that tells the wave director to go.
##
## The draft is the one step that waits on the player instead of a clock. It sits
## after the wave number goes up, so the card the player takes is a card they can
## build around in the prep that follows.

signal phase_changed(phase: Phase)
signal wave_changed(wave: int)
signal timer_changed(seconds_left: float)
signal wave_summary(kill_gold: int, bonus: int, factors: Array)
signal run_ended(won: bool)

## DRAFT is deliberately last. The HUD maps these values by name in a dictionary
## built from the enum, so renumbering PREP..WON would silently mislabel it.
enum Phase { PREP, WAVE, CLEARED, LOST, WON, DRAFT }

@export var table: WaveTable
@export var wave_director: WaveDirector
@export var raider_pool: RaiderPool
@export var roller_pool: RollerPool
@export var economy: Economy
@export var keep: Keep
@export var audio_director: AudioDirector
@export var structures_root: Node3D
## Only so a restart can rebake after razing the last run's kingdom.
@export var nav_region: NavigationRegion3D
@export var loadout: Loadout
@export var draft_system: DraftSystem
## The roller pool grows a typed spawn when roller cards land. Until it does, the
## quarries mint the pool's default sphere and this name simply matches nothing.
## Expected signature: spawn_typed(centre: Vector3, n: int, spread: float, type: Resource).
@export var typed_mint_method := "spawn_typed"

@export_group("Ending a run")
## What restarts a finished run. Named rather than hard-coded so a dedicated key can
## be bound in the input map later without touching this file.
@export var restart_action := &"gate_open"
## How long the end screen is held before that action is listened to. The keep can
## fall on a frame the player is holding the gate key down, and physics runs before
## _process, so without a beat here the run restarts before the banner has drawn
## once. A press made during the lockout is swallowed rather than queued, so a held
## key can never restart the run: the player has to let go and press again.
@export_range(0.0, 10.0, 0.1) var restart_lockout_seconds := 1.5

var phase := Phase.PREP
var wave := 1
var seconds_left := 0.0
var base_value := 0
var previous_base_value := 0

var _started := false
var _spawning_done := false
var _last_keep_hp := 0
var _called_early := false
var _restart_lock := 0.0


func _ready() -> void:
	if keep:
		keep.destroyed.connect(_on_keep_destroyed)
		keep.hp_changed.connect(_on_keep_hp_changed)
	if raider_pool:
		raider_pool.emptied.connect(_on_raiders_emptied)
		raider_pool.raider_died.connect(_on_raider_died)
	if wave_director:
		wave_director.spawning_finished.connect(func() -> void: _spawning_done = true)
	if roller_pool:
		# The hub already forwards raider deaths to Economy; cascade links come the
		# same way, because the pool reports contacts and only this node knows
		# whether a wave is running.
		roller_pool.roller_impact.connect(_on_roller_impact)
	if draft_system:
		draft_system.closed.connect(_on_draft_closed)
	await get_tree().process_frame
	start_run()


func start_run() -> void:
	wave = 1
	previous_base_value = 0
	if draft_system:
		draft_system.cancel()
	_raze()
	# Before the pools reset: the loadout puts the stockpile and the feel numbers
	# back to what the designer shipped, and respawn() should read those.
	if loadout:
		loadout.reset_run()
	if keep:
		keep.reset()
		_last_keep_hp = keep.hp
	if raider_pool:
		raider_pool.clear_all()
	if roller_pool:
		roller_pool.respawn()
	if economy:
		economy.reset_run()
	if wave_director:
		wave_director.last_budget = 0.0
		wave_director.last_full_budget = 0.0
	wave_changed.emit(wave)
	_started = true
	_enter_prep()


## A new run is a new kingdom. Without this the tray keeps everything the last run
## built: the purse goes back to its opening gold against a base value the player
## never paid for, and wave 1 arrives sized for the kingdom that just fell.
func _raze() -> void:
	if structures_root == null:
		return
	var razed := false
	for child in structures_root.get_children():
		if child is Structure:
			# Removed before it is freed, so the child count every other system
			# caches off this node is right on the very next frame rather than
			# after queue_free() gets round to it.
			structures_root.remove_child(child)
			child.queue_free()
			razed = true
	if razed and nav_region and nav_region.navigation_mesh:
		nav_region.bake_navigation_mesh(false)


func current_base_value() -> int:
	var total := keep.base_value if keep else 0
	if structures_root:
		for child in structures_root.get_children():
			var s := child as Structure
			if s:
				total += s.base_value()
	return total


func next_budget() -> float:
	if wave_director == null:
		return 0.0
	return wave_director.budget_for(wave, current_base_value())


func _process(dt: float) -> void:
	# _process runs from the first frame, but start_run() is deferred by one frame.
	# Without this the PREP branch sees a zero timer and fires a phantom wave.
	if not _started:
		return
	_drive_gates()
	match phase:
		Phase.PREP:
			seconds_left = maxf(0.0, seconds_left - dt)
			timer_changed.emit(seconds_left)
			if seconds_left == 0.0:
				_start_wave(false)
			elif Input.is_action_just_pressed("wave_call"):
				_start_wave(true)
		Phase.WAVE:
			if _spawning_done and raider_pool and raider_pool.alive_count() == 0:
				_enter_cleared()
		Phase.CLEARED:
			seconds_left = maxf(0.0, seconds_left - dt)
			timer_changed.emit(seconds_left)
			if seconds_left == 0.0:
				wave += 1
				wave_changed.emit(wave)
				if wave > table.boss_wave:
					_set_phase(Phase.WON)
					run_ended.emit(true)
				else:
					_enter_draft()
		Phase.DRAFT:
			# No clock here on purpose. The run waits on the pick.
			pass
		Phase.LOST, Phase.WON:
			# The end screen is the reward for the run; it gets its own beat before
			# anything the player is already holding can wipe it away.
			if _restart_lock > 0.0:
				_restart_lock = maxf(0.0, _restart_lock - dt)
			elif Input.is_action_just_pressed(restart_action):
				start_run()


## Gates hold a stockpile until the player opens them, which is what turns a tilt
## into a shot. Held, not toggled.
func _drive_gates() -> void:
	if structures_root == null:
		return
	var open := Input.is_action_pressed("gate_open") and phase == Phase.WAVE
	for child in structures_root.get_children():
		var s := child as Structure
		if s and s.is_gate():
			s.set_open(open)


func _enter_prep() -> void:
	seconds_left = table.prep_seconds + (loadout.prep_seconds_bonus() if loadout else 0.0)
	_set_phase(Phase.PREP)


## The one step with no timer: the player picks a card and the run moves on. If the
## draft has nothing to offer -- every pool empty, or everything already taken --
## open_for() says so and prep starts immediately rather than the run stalling on a
## screen with no cards on it.
func _enter_draft() -> void:
	if draft_system == null or not draft_system.open_for(wave):
		_enter_prep()
		return
	seconds_left = 0.0
	timer_changed.emit(seconds_left)
	_set_phase(Phase.DRAFT)


func _on_draft_closed() -> void:
	# Guarded, because start_run() cancels a live draft and that closes it too.
	if phase == Phase.DRAFT:
		_enter_prep()


func _start_wave(early: bool) -> void:
	_called_early = early
	_spawning_done = false
	base_value = current_base_value()
	var grew := base_value > previous_base_value and previous_base_value > 0

	# Quarries mint their output at the start of the wave, on the side you are
	# tilting away from.
	if structures_root and roller_pool:
		for child in structures_root.get_children():
			var s := child as Structure
			if s and s.is_quarry():
				_mint_from(s)

	# A tray modifier can tip rollers onto the board on top of the quarries, which
	# is the only way a player with no quarry up yet can still be given stone.
	if roller_pool and loadout:
		var poured := loadout.wave_start_rollers()
		if poured > 0:
			roller_pool.spawn(poured)

	if economy:
		var on_tray := roller_pool.active_count() if roller_pool else 0
		var lost := roller_pool.lost_count() if roller_pool else 0
		# The early-call share is a pacing knob, so it lives in the wave table with
		# the rest of them and is handed over rather than copied into Economy.
		economy.begin_wave(on_tray, lost, early, table.early_call_bonus)
	if audio_director:
		audio_director.reset_chain()
	_set_phase(Phase.WAVE)
	wave_director.begin_wave(wave, base_value, grew)
	previous_base_value = base_value


## The draft can raise what a quarry cuts and add the types it cuts. Both are read
## from the loadout, so nothing here hard-codes a kit. Typed minting is optional:
## while the roller pool has no typed spawn, or no roller card has landed, this is
## the same single spawn_at() call it always was.
func _mint_from(s: Structure) -> void:
	var count := s.mint() + (loadout.quarry_mint_bonus() if loadout else 0)
	if count <= 0:
		return
	var at := s.global_position + Vector3(0.0, 0.9, 0.0)
	if loadout and not loadout.roller_types.is_empty() \
			and roller_pool.has_method(typed_mint_method):
		for _i in count:
			roller_pool.call(typed_mint_method, at, 1, 0.5, loadout.next_mint_type())
		return
	roller_pool.spawn_at(at, count)


func _enter_cleared() -> void:
	if economy:
		# Economy counts its own cascade off the strikes forwarded below; the audio
		# director's chain is a contact counter for pitch and is not the score.
		var factors := economy.settle_wave(roller_pool.lost_count() if roller_pool else 0)
		wave_summary.emit(economy.kill_gold, economy.wave_bonus, factors)
	seconds_left = table.cleared_seconds
	_set_phase(Phase.CLEARED)


func _set_phase(next: Phase) -> void:
	phase = next
	if next == Phase.LOST or next == Phase.WON:
		_restart_lock = restart_lockout_seconds
	phase_changed.emit(phase)


func _on_raider_died(type: RaiderType, _fell: bool) -> void:
	if economy:
		economy.credit_kill(type)


## A cascade is a chain of hits the player set up, so a link is a strike that
## actually staggered a raider -- the same momentum test Raider itself uses to decide
## it was knocked off its feet. Counting raw contacts instead would score a quarry
## roller landing on the tray, which is why this factor used to be free.
func _on_roller_impact(_roller: RigidBody3D, other: Node, _type: RollerType, _speed: float,
		_lateral: float, momentum: float) -> void:
	if economy == null or phase != Phase.WAVE:
		return
	var raider := other as Raider
	if raider == null or raider.type == null:
		return
	if momentum < raider.type.knockback_resist:
		return
	economy.note_chain_hit()


func _on_raiders_emptied() -> void:
	if phase == Phase.WAVE and _spawning_done:
		_enter_cleared()


func _on_keep_hp_changed(hp: int, _max_hp: int) -> void:
	if hp < _last_keep_hp and economy:
		economy.note_keep_damage(_last_keep_hp - hp)
	_last_keep_hp = hp


func _on_keep_destroyed() -> void:
	if wave_director:
		wave_director.cancel()
	if raider_pool:
		raider_pool.clear_all()
	_set_phase(Phase.LOST)
	run_ended.emit(false)
