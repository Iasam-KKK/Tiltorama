extends Node3D
class_name RollerPool

## Pre-instanced rollers. Nothing is ever instanced mid-wave: spawning takes a body
## off the idle list, parking it puts it back, and a splitter breaking into three
## fragments draws those three from the same list.
##
## Bodies are generic. A RollerType is applied to one at spawn time -- mass, physics
## material, mesh, colour -- so one pool of 200 covers all six types without keeping
## a reserve per type. Sphere meshes and shapes are shared, cached on a 2 cm radius
## ladder built up front, so a growing snowball never allocates either.
##
## Per-roller state lives in a Slot, one per pool index, NOT in Object metadata. The
## per-tick walk used to cost around eleven metadata hash lookups plus two get_node()
## calls per active roller -- roughly 2600 hashed Variant round trips a tick at a
## full tray. A Slot is a plain object with typed fields, so the same walk is field
## reads, and the body only carries one piece of metadata: which slot it is.

signal impact(speed: float, at: Vector3)
signal lost_changed(total_lost: int)
## Every contact, with the type behind it and the momentum it carried. `lateral` is
## the part of the relative speed that runs across the tray rather than into it,
## which is how an effect tells being hit from merely landing. ImpactResolver
## listens; nobody else has to know rollers have types.
signal roller_impact(roller: RigidBody3D, other: Node, type: RollerType, speed: float, lateral: float, momentum: float)
## A roller that had actually rolled somewhere came to rest. Fires once per spawn.
signal roller_stopped(roller: RigidBody3D, type: RollerType)

## Drawn radii are quantised to this so the mesh/shape cache stays small.
const SIZE_STEP := 0.02
const MIN_RADIUS := 0.06
const MAX_RADIUS := 0.7
const MIN_MASS := 0.05

## The only metadata left on a roller body: its index into `_slots`. Written once
## when the body is built and never again, so an outside caller holding a
## RigidBody3D still gets one hash lookup and everything after that is a field.
const META_SLOT := &"roller_slot"


## Everything about one pooled body that changes while it is on the tray, plus the
## two child nodes that used to be fetched by name. One instance per pool index,
## built at startup and reused for the life of the run: a Slot is never allocated
## mid-wave any more than a body is.
class Slot extends RefCounted:
	var index := -1
	var body: RigidBody3D
	var mesh: MeshInstance3D
	var shape: CollisionShape3D
	var type: RollerType
	var active := false
	## Frozen and standing as a barrier. The only way an ACTIVE body is frozen,
	## which is what lets the per-tick walk skip on this instead of reading
	## RigidBody3D.freeze back out of the physics server.
	var stuck := false
	## roller_stopped has already fired for this rest. Cleared when it moves again.
	var stopped := false
	## Identifies one spawn-to-park life.
	var serial := 0
	## 0 for a spawned roller, 1 for a fragment, 2 for a fragment of a fragment.
	var depth := 0
	## Index on the SIZE_STEP radius ladder, or -1 before the first size is applied.
	var bucket := -1
	var age := 0.0
	## Metres travelled ACROSS the tray since spawning.
	var rolled := 0.0
	## Seconds spent below stop_speed.
	var still := 0.0
	## Where it was last tick, for the across-the-tray step.
	var last := Vector3.ZERO


@export var tilt_controller: TiltController
## Rollers report their contacts here so raiders do not each need a contact monitor.
@export var raider_pool: RaiderPool
## The same service for villagers. Typed as plain Node, not VillagerPool, on
## purpose: villager_pool.gd exports a RunState and run_state.gd exports a
## RollerPool, so naming the class here would close a parse-time reference cycle.
## Assigning a VillagerPool to it works exactly the same.
@export var villager_pool: Node
@export_range(1, 400, 1) var pool_size := 200
## How many to pour in on start / on Respawn.
@export_range(1, 200, 1) var stockpile := 30

@export_group("Types")
## The catalogue, loaded from data/rollers/. Leave it empty and the pool falls back
## to one built-in type made from the Roller group below, which is exactly what the
## pool did before rollers were typed.
@export var types: Array[RollerType] = []
## What an untyped spawn uses when drafting is off. Empty means the first entry.
@export var default_type: RollerType
## Untyped spawns -- the opening stockpile, quarry mint -- come out as a mix weighted
## by each type draft_weight. Turn it off to pour nothing but the default type.
@export var draft_mix := true

@export_group("Roller")
## These describe the fallback type only. A real RollerType carries its own.
@export_range(0.05, 1.0, 0.01) var radius := 0.22
@export_range(0.1, 10.0, 0.1) var mass := 1.0
## Global scale over every type authored friction: at its starting value nothing
## changes, so the debug slider can sweep the whole tray without flattening bouncy
## into stone.
@export_range(0.0, 1.0, 0.01) var friction := 0.35: set = _set_friction
@export_range(0.0, 1.0, 0.01) var restitution := 0.3: set = _set_restitution
## A PhysicsMaterial bounce of 1 hands a contact all of its energy back: the
## roller never settles, roller_stopped never fires for it, and every effect keyed
## to a roller coming to rest is dead for that type. bouncy.tres is authored at
## 0.9, so ONE stack of the Hard Stone card (x1.25) already reaches 1.0. Capped
## here rather than on the card, because capping the card would pin the multiplier
## at ~1.0 and make it inert for every other type.
@export_range(0.1, 1.0, 0.01) var max_bounce := 0.95
## Rollers are the only saturated objects on the tray, so they read at a glance.
@export var colour := Color("3e86d9")

@export_group("Bodies")
## Contacts one roller may report per physics step. This is not a cosmetic budget:
## Godot derives body_entered from the reported contact list, and the ENTIRE raider
## and villager damage route hangs off that one signal, so a roller whose list is
## full stops hurting things without a word. Equal spheres can touch twelve
## neighbours at once (the kissing number) and a roller in a heap also touches the
## floor, a rim, and whatever walked into it -- at four, a roller in the corner heap
## that a full tilt has just made could silently fail to register the raider it
## landed on. Sixteen clears the geometric worst case with room for the two agents.
## The cost is one array the server sizes once per body (about 100 bytes a slot, so
## a couple of hundred KB across the whole pool); the per-step work scales with the
## contacts that ACTUALLY happen, so a roller crossing an empty tray pays exactly
## the same at sixteen as it did at four.
@export_range(1, 32, 1) var max_contacts_per_roller := 16: set = _set_max_contacts
## Swept collision. Verified against this game's numbers rather than assumed: the
## thinnest static collider is the ramp slab at 0.30 m, and the smallest body a
## fragment clamped to MIN_RADIUS, so a miss needs 0.30 + 0.12 m of travel in one
## 60 Hz step -- about 25 m/s. Nothing here goes near that. A full 12 degree tilt
## accelerates at g*sin(12) = 2.04 m/s^2, so the whole 15.8 m diagonal is 8 m/s
## frictionless; a quarry drop from 1.6 m is 5.6 m/s; a ramp adds 3.7 m/s; and
## bounce never adds energy, because a bumper at 0.95 against a bouncy at 0.9 is
## still a restitution below one. Peak is around 10 m/s, a 2.5x margin. It stays ON
## anyway, because under Jolt continuous_cd is LinearCast motion quality: the sweep
## only runs when a body moves past about 0.75 of its own inner radius in a step
## (roughly 10 m/s for a 0.22 m marble), so the 190-odd slow rollers pay a
## comparison rather than a cast. There is no measurable cost to buy back here, and
## the failure it prevents -- a roller through the floor into the kill volume, read
## by the player as gold that evaporated -- is invisible in a log and unreproducible.
@export var continuous_cd := true: set = _set_continuous_cd
## Rollers do not cast shadows. Godot 4 Forward+ does not batch separate
## MeshInstance3D nodes even when the mesh and material match, so every visible
## roller is one draw call in the opaque pass AND one more in each directional
## shadow split -- at SHADOW_PARALLEL_2_SPLITS that is three draw calls a marble,
## about 600 for a full tray before anything else is drawn. Turning shadow casting
## off takes that to one each. What it costs is the little contact blob under a
## 0.22 m marble seen from 32 m at a 25 degree lens through a 1.5 shadow blur --
## a few pixels. What the design actually leans on for reading the tilt is the
## DIRECTIONAL shadow swinging across the tray: the tray slab, the rim, the keep,
## the trees and every built structure still cast it, and those are the shapes with
## the area to throw a shadow you can read. The marbles stay legible on hue, which
## is what they were given saturated colours for.
@export var cast_shadows := false: set = _set_cast_shadows

@export_group("Spawn")
## The north-west corner of the tray: -X, -Z.
@export var spawn_centre := Vector3(-4.0, 1.6, -4.0)
@export_range(0.1, 5.0, 0.1) var spawn_spread := 1.6

@export_group("Impact")
## Placeholder gate for the day 9 audio pass. Below this, a contact is silent.
@export_range(0.0, 20.0, 0.1) var impact_speed_threshold := 2.5

@export_group("Rest")
## Below this speed a roller counts as still.
@export_range(0.0, 5.0, 0.01) var stop_speed := 0.35
## ...for this long before roller_stopped fires.
@export_range(0.0, 5.0, 0.01) var stop_seconds := 0.35
## A roller that never went anywhere did not stop, it was merely dropped. Measured
## across the tray, so the fall in does not count towards it.
@export_range(0.0, 20.0, 0.05) var stop_min_rolled := 0.75

@export_group("Split")
## How much of the parent velocity the fragments keep. The rest is the burst.
@export_range(0.0, 1.5, 0.05) var split_velocity_keep := 0.75

## Slot per pool index, built once in _ready. The three lists below hold INDICES
## into it, never bodies: the per-tick walk is then an array read, and nothing on
## the hot path has to ask a body who it is.
var _slots: Array[Slot] = []
var _idle := PackedInt32Array()
var _active := PackedInt32Array()
var _stuck := PackedInt32Array()
var _lost := 0
var _rng := RandomNumberGenerator.new()

var _fallback: RollerType
var _by_id := {}
var _draft: Array[RollerType] = []
var _draft_total := 0.0
var _surfaces := {}
var _physics_mats := {}
var _meshes := {}
var _shapes := {}
var _stopped_buffer := PackedInt32Array()
var _serial := 0
var _friction_base := 0.35
var _restitution_base := 0.3
var _ready_done := false


func _ready() -> void:
	_rng.randomize()
	_friction_base = friction
	_restitution_base = restitution
	_build_fallback()
	_register_types()
	_prewarm_sizes()
	_ready_done = true

	for i in pool_size:
		var s := _make_slot(i)
		_slots.append(s)
		add_child(s.body)
		_park(s)

	if tilt_controller:
		tilt_controller.tilt_active_changed.connect(_on_tilt_active_changed)

	spawn(stockpile)


# --- counts ---------------------------------------------------------------

func active_count() -> int:
	return _active.size()


func lost_count() -> int:
	return _lost


func stuck_count() -> int:
	return _stuck.size()


## A copy of what is on the tray, safe to walk while parking things. For the HUD,
## the juice pass and headless tests -- nothing per-frame.
func active_rollers() -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	for i in _active:
		out.append(_slots[i].body)
	return out


## Roller id -> how many are on the tray. For the HUD and the debug readout.
func active_counts() -> Dictionary:
	var out := {}
	for i in _active:
		var t := _slots[i].type
		var key: String = t.id if t else "?"
		out[key] = int(out.get(key, 0)) + 1
	return out


# --- spawning -------------------------------------------------------------

## Untyped: drafts from `types` by draft_weight, or pours the default type.
func spawn(n: int) -> int:
	return _spawn_batch(null, n, spawn_centre, spawn_spread)


## Spawn n rollers of one type at the usual spawn point.
func spawn_type(type: RollerType, n: int) -> int:
	return _spawn_batch(type, n, spawn_centre, spawn_spread)


## Quarries mint their output where they stand.
func spawn_at(centre: Vector3, n: int, spread := 0.5) -> int:
	return _spawn_batch(null, n, centre, spread)


## Same, of one type. This is the signature RunState probes for by name when the
## loadout has roller cards to mint from, so the argument order mirrors spawn_at()
## with the type on the end, and the type is a plain Resource because the loadout
## holds its kit as Array[Resource]. Anything that is not a RollerType falls back to
## the default type rather than erroring in the middle of a wave.
func spawn_typed(centre: Vector3, n: int, spread: float, type: Resource) -> int:
	var t := type as RollerType
	return _spawn_batch(t if t else _default_type(), n, centre, spread)


## Convenience for callers holding an id string rather than the resource.
func spawn_id(type_id: String, n: int) -> int:
	return _spawn_batch(type_by_id(type_id), n, spawn_centre, spawn_spread)


## Put `count` rollers of ONE chosen type on the tray, right now, whatever the draft
## has granted. `type` may be the RollerType or its id string, so a debug key and a
## drafted card can both call it without either knowing the other's currency.
## Returns how many actually came off the idle list: a full tray mints fewer, and
## zero means either the pool is dry or nothing answers to that name.
##
## This is the only on-demand route a chosen type has onto the tray. Every other
## spawn is untyped (the opening stockpile, Muster, respawn) or comes out of a
## quarry at the head of a wave, which is why choosing a type used to look like it
## had done nothing: the choice was recorded and the tray went on showing what was
## already lying on it.
func mint_type(type: Variant, count: int) -> int:
	if count <= 0:
		return 0
	var t := resolve_type(type)
	if t == null:
		return 0
	return _spawn_batch(t, count, spawn_centre, spawn_spread)


## A type from either currency -- the resource itself, or the id it was authored
## with. Null for a name nothing answers to, so a caller can tell "no such type"
## apart from "the pool had nothing left to give".
func resolve_type(type: Variant) -> RollerType:
	# Explicit casts rather than a bare return: the parameter is Variant, and an
	# implicit narrowing would be an unsafe-return warning on every call site.
	var t := type as RollerType
	if t:
		return t
	if type is String or type is StringName:
		return type_by_id(String(type))
	return null


## Every id this pool can mint, in catalogue order. A debug selector builds its list
## from this rather than repeating the catalogue as literals, so a type added to
## data/rollers/ shows up there with nothing rewired.
func type_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for t in types:
		if t:
			out.append(t.id)
	return out


func respawn() -> void:
	clear()
	_lost = 0
	lost_changed.emit(_lost)
	spawn(stockpile)


func clear() -> void:
	# _park() edits _active, so walk a copy. Clearing is a phase change, not a
	# per-frame cost.
	for i in _active.duplicate():
		_park(_slots[i])


## Called by the kill volume when a roller leaves the tray.
func recycle(r: RigidBody3D) -> void:
	var s := _slot_of(r)
	if s == null or not s.active:
		return
	_lost += 1
	_park(s)
	lost_changed.emit(_lost)


## Taken out of play by an effect rather than lost over the edge -- a split parent,
## a shattered snowball. Does not count against the recovery bonus.
func retire(r: RigidBody3D) -> void:
	var s := _slot_of(r)
	if s == null or not s.active:
		return
	_park(s)


# --- per-roller state -----------------------------------------------------

func type_of(r: RigidBody3D) -> RollerType:
	var s := _slot_of(r)
	return s.type if s else null


func type_by_id(type_id: String) -> RollerType:
	var t: RollerType = _by_id.get(type_id, null)
	return t


func is_active(r: RigidBody3D) -> bool:
	var s := _slot_of(r)
	return s != null and s.active


func is_stuck(r: RigidBody3D) -> bool:
	var s := _slot_of(r)
	return s != null and s.stuck


## Seconds since this body was spawned. Effects use it to ignore the landing heap.
func age_of(r: RigidBody3D) -> float:
	var s := _slot_of(r)
	return s.age if s else 0.0


## Metres travelled ACROSS the tray since spawning. The drop in does not count.
func distance_rolled(r: RigidBody3D) -> float:
	var s := _slot_of(r)
	return s.rolled if s else 0.0


## 0 for a spawned roller, 1 for a fragment, 2 for a fragment of a fragment.
func split_depth(r: RigidBody3D) -> int:
	var s := _slot_of(r)
	return s.depth if s else 0


## Identifies one spawn-to-park life. A queued effect compares it so a body that was
## recycled and respawned in between never inherits the old roller fate.
func spawn_serial(r: RigidBody3D) -> int:
	var s := _slot_of(r)
	return s.serial if s else 0


func radius_of(r: RigidBody3D) -> float:
	var s := _slot_of(r)
	if s == null or s.bucket < 0:
		return float(int(round(radius / SIZE_STEP))) * SIZE_STEP
	return float(s.bucket) * SIZE_STEP


## The colour this body is actually WEARING, read back off the material on its mesh
## rather than off its type. The two answers differ exactly when a retype fails to
## reach the mesh, which is the shape of "I picked iron and the marbles did not
## change" -- so this, never RollerType.colour, is what a test should assert on.
## RollerType.colour is only what the colour was supposed to be.
func colour_of(r: RigidBody3D) -> Color:
	var s := _slot_of(r)
	if s == null:
		return colour
	var mat := s.mesh.material_override as StandardMaterial3D
	return mat.albedo_color if mat else colour


# --- effects (driven by ImpactResolver) -----------------------------------

## Break `source` into `count` fragments of `child` type. Fragments come off the idle
## list; the parent is retired only once at least one made it out, so running the
## pool dry degrades to "nothing happened" instead of deleting a roller.
func split_roller(source: RigidBody3D, child: RollerType, count: int, mass_scale: float, burst: float) -> int:
	var src := _slot_of(source)
	if src == null or not src.active or count <= 0:
		return 0
	var t := child if child else _default_type()
	var at := src.body.global_position
	var carried := src.body.linear_velocity * split_velocity_keep
	var depth := src.depth + 1
	var child_mass := maxf(src.body.mass * mass_scale, MIN_MASS)
	var child_radius := clampf(t.radius_for_mass(child_mass), MIN_RADIUS, MAX_RADIUS)
	# Fragments start on a ring that clears both bodies, or the solver spends the
	# first frame shoving them apart and a split reads as an explosion.
	var ring := float(src.bucket) * SIZE_STEP + child_radius + 0.02
	var plane := _tray_plane()
	var made := 0
	for i in count:
		var s := _take()
		if s == null:
			break
		var angle := TAU * float(i) / float(count) + _rng.randf_range(-0.25, 0.25)
		var out := (plane[0] * cos(angle) + plane[1] * sin(angle)).normalized()
		_settle(s, at + out * ring)
		_apply_type(s, t, child_mass)
		s.depth = depth
		_wake(s)
		s.body.linear_velocity = carried + out * burst
		s.body.angular_velocity = Vector3.ZERO
		made += 1
	if made > 0:
		retire(source)
	return made


## Stops a roller dead and leaves it standing as a barrier. It keeps its collision
## layer, so raiders and rollers both run into it.
func stick_roller(r: RigidBody3D) -> bool:
	var s := _slot_of(r)
	if s == null or not s.active or s.stuck:
		return false
	s.body.linear_velocity = Vector3.ZERO
	s.body.angular_velocity = Vector3.ZERO
	s.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	s.body.freeze = true
	s.stuck = true
	if _stuck.find(s.index) < 0:
		_stuck.append(s.index)
	return true


## "A barrier for the rest of the wave" ends here. ImpactResolver calls this when the
## run leaves the WAVE phase.
func release_stuck() -> int:
	var freed := 0
	for i in _stuck:
		var s := _slots[i]
		if not s.active or not s.stuck:
			continue
		s.stuck = false
		s.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		s.body.freeze = false
		s.body.sleeping = false
		freed += 1
	_stuck.clear()
	return freed


# --- frame ----------------------------------------------------------------

func _physics_process(dt: float) -> void:
	if _active.is_empty():
		return
	# Read the gravity vector, never write it: that is TiltController's job.
	var down := tilt_controller.gravity_dir if tilt_controller else Vector3.DOWN
	_stopped_buffer.clear()
	for i in _active:
		var s := _slots[i]
		# Stuck barriers are furniture. Sticking is the only thing that freezes an
		# active body, so the flag answers this without reading the body back.
		if s.stuck:
			continue
		var t := s.type
		if t == null:
			continue
		s.age += dt

		var pos := s.body.global_position
		# Only travel across the tray counts as rolling. Dropping two metres out of a
		# quarry is not a journey, and if it counted, every roller would arrive
		# already grown, already armed, and a snowball would shatter where it landed.
		var step := pos - s.last
		step -= down * step.dot(down)
		s.rolled += step.length()
		s.last = pos

		if t.grows:
			_grow(s, t)

		if s.body.linear_velocity.length() <= stop_speed:
			s.still += dt
		else:
			s.still = 0.0
			s.stopped = false

		if s.still >= stop_seconds and s.rolled >= stop_min_rolled and not s.stopped:
			s.stopped = true
			_stopped_buffer.append(i)

	# Emitted after the walk: a listener may retire the roller, which edits _active.
	for i in _stopped_buffer:
		var s := _slots[i]
		roller_stopped.emit(s.body, s.type)


func _grow(s: Slot, t: RollerType) -> void:
	var m := minf(t.mass + s.rolled * t.grow_per_metre, t.grow_max_mass)
	if absf(m - s.body.mass) < 0.001:
		return
	s.body.mass = m
	_apply_size(s, t, m)


# --- internals ------------------------------------------------------------

## The pool slot behind a body, or null for anything this pool did not build. One
## hash lookup, and only on the public boundary: nothing inside the pool goes
## through here.
func _slot_of(r: RigidBody3D) -> Slot:
	if r == null:
		return null
	var i := int(r.get_meta(META_SLOT, -1))
	if i < 0 or i >= _slots.size():
		return null
	return _slots[i]


func _spawn_batch(type: RollerType, n: int, centre: Vector3, spread: float) -> int:
	var made := 0
	for i in n:
		var s := _take()
		if s == null:
			break
		var t := type if type else _pick_type()
		_settle(s, centre + Vector3(
			_rng.randf_range(-spread, spread),
			_rng.randf_range(0.0, spread),
			_rng.randf_range(-spread, spread)))
		_apply_type(s, t, 0.0)
		_wake(s)
		s.body.linear_velocity = Vector3.ZERO
		s.body.angular_velocity = Vector3.ZERO
		made += 1
	return made


func _take() -> Slot:
	if _idle.is_empty():
		return null
	var last := _idle.size() - 1
	var i := _idle[last]
	_idle.remove_at(last)
	_active.append(i)
	var s := _slots[i]
	_serial += 1
	s.active = true
	s.serial = _serial
	s.age = 0.0
	s.rolled = 0.0
	s.still = 0.0
	s.stopped = false
	s.stuck = false
	s.depth = 0
	return s


func _settle(s: Slot, pos: Vector3) -> void:
	s.body.global_position = pos
	# Physics interpolation is on project-wide, so a teleport has to forget where the
	# body was or it smears across the tray for one frame.
	s.body.reset_physics_interpolation()
	s.last = pos


func _wake(s: Slot) -> void:
	s.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	s.body.freeze = false
	s.body.visible = true
	s.body.sleeping = false
	# A body spawned mid-tilt must not doze off either: a gravity-vector change does
	# not wake a sleeping body on its own.
	s.body.can_sleep = not (tilt_controller != null and tilt_controller.is_active())


func _park(s: Slot) -> void:
	if s.stuck:
		s.stuck = false
		var k := _stuck.find(s.index)
		if k >= 0:
			_stuck.remove_at(k)
	s.active = false
	s.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	s.body.freeze = true
	s.body.visible = false
	s.body.global_position = Vector3(0.0, -1000.0, 0.0)
	s.body.reset_physics_interpolation()
	var a := _active.find(s.index)
	if a >= 0:
		_active.remove_at(a)
	if _idle.find(s.index) < 0:
		_idle.append(s.index)


func _make_slot(index: int) -> Slot:
	var s := Slot.new()
	s.index = index

	var body := RigidBody3D.new()
	body.mass = mass
	body.continuous_cd = continuous_cd
	body.contact_monitor = true
	body.max_contacts_reported = max_contacts_per_roller
	# Layer 2 = rollers: world (1), each other (2), raiders (4), villagers (8).
	# Without layer 8 a roller passes straight through a villager and could never
	# knock one off the tray.
	body.collision_layer = 2
	body.collision_mask = 1 | 2 | 4 | 8
	body.set_meta(META_SLOT, index)
	s.body = body

	# Kept as a child node rather than folded into a MultiMesh: the juice pass
	# squashes each roller by writing THIS node's basis, which is what keeps the
	# squash off the body transform and out of the physics.
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.cast_shadow = _shadow_mode()
	body.add_child(mi)
	s.mesh = mi

	var col := CollisionShape3D.new()
	col.name = "Shape"
	body.add_child(col)
	s.shape = col

	# The slot rides in on the binding, so a contact costs no lookup at all.
	body.body_entered.connect(_on_roller_contact.bind(s))

	_apply_type(s, _default_type(), 0.0)
	return s


## Everything that makes a body one type rather than another. Only shared resources
## change hands, so retyping a body is a handful of pointer writes.
func _apply_type(s: Slot, type: RollerType, mass_value: float) -> void:
	var t := type if type else _fallback
	s.type = t
	s.body.mass = maxf(mass_value if mass_value > 0.0 else t.mass, MIN_MASS)
	s.body.physics_material_override = _physics_material(t)
	s.mesh.material_override = _surface(t)
	_apply_size(s, t, s.body.mass)


func _apply_size(s: Slot, t: RollerType, m: float) -> void:
	var bucket := int(round(clampf(t.radius_for_mass(m), MIN_RADIUS, MAX_RADIUS) / SIZE_STEP))
	if s.bucket == bucket:
		return
	s.bucket = bucket
	s.mesh.mesh = _sphere_mesh(bucket)
	s.shape.shape = _sphere_shape(bucket)


func _sphere_mesh(bucket: int) -> SphereMesh:
	if _meshes.has(bucket):
		var cached: SphereMesh = _meshes[bucket]
		return cached
	var m := SphereMesh.new()
	m.radius = float(bucket) * SIZE_STEP
	m.height = m.radius * 2.0
	m.radial_segments = 12
	m.rings = 6
	_meshes[bucket] = m
	return m


func _sphere_shape(bucket: int) -> SphereShape3D:
	if _shapes.has(bucket):
		var cached: SphereShape3D = _shapes[bucket]
		return cached
	var s := SphereShape3D.new()
	s.radius = float(bucket) * SIZE_STEP
	_shapes[bucket] = s
	return s


## Every radius a roller can ever take, built before the first wave so a snowball
## crossing a size step mid-roll costs nothing.
func _prewarm_sizes() -> void:
	var bucket := int(round(MIN_RADIUS / SIZE_STEP))
	var top := int(round(MAX_RADIUS / SIZE_STEP))
	while bucket <= top:
		_sphere_mesh(bucket)
		_sphere_shape(bucket)
		bucket += 1


func _surface(t: RollerType) -> StandardMaterial3D:
	if _surfaces.has(t.id):
		var cached: StandardMaterial3D = _surfaces[t.id]
		return cached
	var s := StandardMaterial3D.new()
	s.albedo_color = t.colour
	s.roughness = 1.0
	s.metallic = 0.0
	_surfaces[t.id] = s
	return s


func _physics_material(t: RollerType) -> PhysicsMaterial:
	if _physics_mats.has(t.id):
		var cached: PhysicsMaterial = _physics_mats[t.id]
		return cached
	var m := PhysicsMaterial.new()
	_physics_mats[t.id] = m
	_tune(t, m)
	return m


func _tune(t: RollerType, m: PhysicsMaterial) -> void:
	m.friction = clampf(t.friction * (friction / maxf(_friction_base, 0.001)), 0.0, 1.0)
	m.bounce = clampf(t.restitution * (restitution / maxf(_restitution_base, 0.001)), 0.0, max_bounce)


func _build_fallback() -> void:
	_fallback = RollerType.new()
	_fallback.id = "default"
	_fallback.display_name = "Roller"
	_fallback.radius = radius
	_fallback.mass = mass
	_fallback.friction = friction
	_fallback.restitution = restitution
	_fallback.colour = colour
	_fallback.draft_weight = 0.0


func _register_types() -> void:
	_by_id["default"] = _fallback
	_draft.clear()
	_draft_total = 0.0
	for t in types:
		if t == null:
			continue
		_by_id[t.id] = t
		if t.draft_weight > 0.0:
			_draft.append(t)
			_draft_total += t.draft_weight


func _default_type() -> RollerType:
	if default_type:
		return default_type
	for t in types:
		if t:
			return t
	return _fallback


func _pick_type() -> RollerType:
	if not draft_mix or _draft_total <= 0.0:
		return _default_type()
	var roll := _rng.randf_range(0.0, _draft_total)
	for t in _draft:
		roll -= t.draft_weight
		if roll <= 0.0:
			return t
	return _draft[_draft.size() - 1]


## Two axes across the tray surface, so fragments fan out along the floor rather than
## into it. Reads the gravity vector; never writes it.
func _tray_plane() -> PackedVector3Array:
	var up := -tilt_controller.gravity_dir if tilt_controller else Vector3.UP
	if up.length() < 0.01:
		up = Vector3.UP
	up = up.normalized()
	var bx := up.cross(Vector3.FORWARD)
	if bx.length() < 0.01:
		bx = up.cross(Vector3.RIGHT)
	bx = bx.normalized()
	return PackedVector3Array([bx, up.cross(bx).normalized()])


func _on_tilt_active_changed(active: bool) -> void:
	# Bodies must not sleep while the world is leaning -- a gravity-vector change
	# does not wake a sleeping body on its own.
	for s in _slots:
		s.body.can_sleep = not active
		if active and not s.body.freeze:
			s.body.sleeping = false


func _on_roller_contact(other: Node, s: Slot) -> void:
	var t := s.type
	var knock := t.knockback if t else 1.0
	var body := s.body
	var relative := body.linear_velocity
	if other is RigidBody3D:
		relative -= (other as RigidBody3D).linear_velocity
	var speed := relative.length()
	# Split the closing speed into "across the tray" and "into the tray". A roller
	# dropped out of a quarry lands hard, and only the lateral part tells an effect
	# that something actually hit something.
	var down := tilt_controller.gravity_dir if tilt_controller else Vector3.DOWN
	var lateral := (relative - down * relative.dot(down)).length()
	if raider_pool:
		# The knockback multiplier rides in on the reported speed: Raider turns
		# (roller mass * speed) into momentum, so iron hits like three stones without
		# weighing three stones under a raider feet.
		raider_pool.notify_roller_contact(other, body, speed * knock)
	if villager_pool:
		# call() rather than a direct method: the export is Node-typed to dodge the
		# class cycle, and a dynamic call keeps that free of unsafe-access warnings.
		villager_pool.call(&"notify_roller_contact", other, body, speed * knock)
	roller_impact.emit(body, other, t, speed, lateral, body.mass * speed * knock)
	if speed >= impact_speed_threshold:
		impact.emit(speed, body.global_position)


func _shadow_mode() -> GeometryInstance3D.ShadowCastingSetting:
	if cast_shadows:
		return GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _set_cast_shadows(v: bool) -> void:
	cast_shadows = v
	# _slots is empty until _ready builds the pool and _make_slot reads the flag
	# itself, so this loop only has work when something flips it at runtime.
	var mode := _shadow_mode()
	for s in _slots:
		s.mesh.cast_shadow = mode


func _set_max_contacts(v: int) -> void:
	max_contacts_per_roller = v
	for s in _slots:
		s.body.max_contacts_reported = v


func _set_continuous_cd(v: bool) -> void:
	continuous_cd = v
	for s in _slots:
		s.body.continuous_cd = v


func _set_friction(v: float) -> void:
	friction = v
	_retune_all()


func _set_restitution(v: float) -> void:
	restitution = v
	_retune_all()


func _retune_all() -> void:
	if not _ready_done:
		return
	for id in _physics_mats:
		var t: RollerType = _by_id.get(id, null)
		var m: PhysicsMaterial = _physics_mats[id]
		if t and m:
			_tune(t, m)
