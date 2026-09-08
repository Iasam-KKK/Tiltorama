extends SceneTree

## Canonical generator for res://scenes/main.tscn.
##
##   godot --headless --path . --script res://tools/build_main.gd
##
## The scene is generated, not hand-edited: Godot writes the .tscn itself so the
## format and every NodePath export is correct by construction. When you add a
## system, register it HERE and regenerate -- that keeps one writer for the scene
## file, which is what makes parallel work on this project possible.

const TRAY := 12.0
const THICK := 0.6
const RIM_H := 0.4
const RIM_T := 0.4
## Distance from centre to the inside face of a rim.
const TRAY_HALF := 5.6

## 22 m put the tray's near edge exactly on the bottom of the frame. 32 m leaves
## room for the HUD above and below.
const CAM_DIST := 32.0
const CAM_PITCH := -40.0

const TRAY_COLOUR := Color("6e7f68")
const RIM_COLOUR := Color("6b5f4c")

const MODELS := "res://assets/models/castle/%s.glb"

## The sea. Its TOP has to sit above the height at which a Raider or a Villager
## calls itself lost (their FELL_BELOW, -3.0): both stop processing the frame they
## cross that line and never travel further down, so a volume starting below it
## can only ever catch rollers, whatever its collision mask says. The floor is
## unchanged, so nothing about how rollers are recycled moves.
const KILL_TOP := -2.0
const KILL_BOTTOM := -8.0

var _raider_ids := ["grunt", "climber", "shieldwall", "anchor", "jarl"]
## The full catalogue. Loadout captures it at the head of a run and pushes back
## only the starting kit, handing the rest out as draft cards -- so the live
## palette the HUD numbers is a growing subset of this, not this. Adding an id
## here makes it draftable without touching Loadout.
var _palette_ids := ["wall", "gate", "ramp", "bumper", "quarry", "house"]
var _roller_ids := ["stone", "iron", "bouncy", "splitter", "snowball", "sticky"]


func _init() -> void:
    var root := Node3D.new()
    root.name = "Main"
    root.set_script(load("res://systems/main.gd"))

    root.add_child(_environment())
    root.add_child(_sun())

    var rig := Node3D.new()
    rig.name = "CameraRig"
    var cam := Camera3D.new()
    cam.name = "Camera3D"
    cam.fov = 25.0
    cam.near = 0.5
    cam.far = 300.0
    cam.position = Vector3(0.0, CAM_DIST * sin(deg_to_rad(-CAM_PITCH)), CAM_DIST * cos(deg_to_rad(-CAM_PITCH)))
    cam.rotation_degrees = Vector3(CAM_PITCH, 0.0, 0.0)
    rig.add_child(cam)
    root.add_child(rig)

    var world := Node3D.new()
    world.name = "World"
    root.add_child(world)

    # Everything the raiders walk on or around lives under the region, so a rebake
    # after building picks up the new walls.
    var nav := NavigationRegion3D.new()
    nav.name = "NavRegion"
    nav.navigation_mesh = _nav_mesh()
    world.add_child(nav)

    nav.add_child(_tray())
    var keep := _keep()
    nav.add_child(keep)

    var structures := Node3D.new()
    structures.name = "Structures"
    nav.add_child(structures)

    _dress(nav)

    var kill := Area3D.new()
    kill.name = "KillVolume"
    kill.set_script(load("res://systems/kill_volume.gd"))
    kill.position = Vector3(0.0, (KILL_TOP + KILL_BOTTOM) * 0.5, 0.0)
    kill.monitoring = true
    kill.collision_layer = 0
    # Layer 2 = rollers, 4 = raiders, 8 = villagers. Villagers were missing, so a
    # villager going into the sea was silent where a raider in the same spot
    # splashed. Only the splash cue rides on this: the volume recycles bodies it
    # sees, but recycle() is guarded on RigidBody3D and both agent kinds are
    # CharacterBody3D, so they still go home through their own pool exactly once.
    kill.collision_mask = 2 | 4 | 8
    var kill_shape := CollisionShape3D.new()
    kill_shape.name = "CollisionShape3D"
    var kill_box := BoxShape3D.new()
    kill_box.size = Vector3(90.0, KILL_TOP - KILL_BOTTOM, 90.0)
    kill_shape.shape = kill_box
    kill.add_child(kill_shape)
    world.add_child(kill)

    var roller_pool := Node3D.new()
    roller_pool.name = "RollerPool"
    roller_pool.set_script(load("res://systems/roller_pool.gd"))
    world.add_child(roller_pool)

    var raider_pool := Node3D.new()
    raider_pool.name = "RaiderPool"
    raider_pool.set_script(load("res://systems/raider_pool.gd"))
    world.add_child(raider_pool)

    var villager_pool := Node3D.new()
    villager_pool.name = "VillagerPool"
    villager_pool.set_script(load("res://systems/villager_pool.gd"))
    world.add_child(villager_pool)

    var tilt := _node("TiltController", "res://systems/tilt_controller.gd")
    var director := _node("WaveDirector", "res://systems/wave_director.gd")
    var economy := _node("Economy", "res://systems/economy.gd")
    var run := _node("RunState", "res://systems/run_state.gd")
    var audio := _node("AudioDirector", "res://systems/audio_director.gd")
    var resolver := _node("ImpactResolver", "res://systems/impact_resolver.gd")
    var loadout := _node("Loadout", "res://systems/loadout.gd")
    var draft := _node("DraftSystem", "res://systems/draft_system.gd")
    var options := _node("Options", "res://systems/options.gd")
    # Options before DebugPanel: the panel re-syncs its volume slider one frame
    # after its own _ready, and Options has to have read its file by then.
    for n in [tilt, director, economy, run, audio, resolver, loadout, draft, options]:
        root.add_child(n)

    # Node3D because it parents two MultiMeshInstance3D effect fields. They are
    # top_level, so this node own transform never matters.
    var juice := Node3D.new()
    juice.name = "Juice"
    juice.set_script(load("res://systems/juice.gd"))
    root.add_child(juice)

    var build := Node3D.new()
    build.name = "BuildSystem"
    build.set_script(load("res://systems/build_system.gd"))
    root.add_child(build)

    var hud := CanvasLayer.new()
    hud.name = "HUD"
    hud.layer = 1
    hud.set_script(load("res://systems/hud.gd"))
    root.add_child(hud)

    var debug := CanvasLayer.new()
    debug.name = "DebugPanel"
    debug.layer = 2
    debug.set_script(load("res://systems/debug_panel.gd"))
    root.add_child(debug)

    # Layer 3: the draft sits over both the HUD (1) and the debug panel (2).
    var draft_ui := CanvasLayer.new()
    draft_ui.name = "DraftUI"
    draft_ui.layer = 3
    draft_ui.set_script(load("res://systems/draft_ui.gd"))
    root.add_child(draft_ui)

    _own(root, root)

    # --- wiring -------------------------------------------------------------
    var table: Resource = load("res://data/waves.tres")
    # One load, two readers: the pool spawns from it and the loadout reads its
    # footing_deg to cap the footing card. Two loads would be the same resource
    # anyway, but naming it says they are meant to agree.
    var villagers: Resource = load("res://data/villagers/villager.tres")

    var raider_types: Array[RaiderType] = []
    for id in _raider_ids:
        raider_types.append(load("res://data/raiders/%s.tres" % id))
    var palette: Array[StructureType] = []
    for id in _palette_ids:
        palette.append(load("res://data/structures/%s.tres" % id))
    var roller_types: Array[RollerType] = []
    for id in _roller_ids:
        roller_types.append(load("res://data/rollers/%s.tres" % id))
    # What the quarries mint before any roller card lands. Array[Resource]
    # because that is what Loadout holds its kit in; Array[RollerType] will not
    # assign to it.
    var starting_rollers: Array[Resource] = [roller_types[0]]

    root.set("nav_region", nav)

    tilt.set("camera_rig", rig)

    roller_pool.set("tilt_controller", tilt)
    roller_pool.set("raider_pool", raider_pool)
    roller_pool.set("villager_pool", villager_pool)
    roller_pool.set("spawn_centre", Vector3(-4.0, 1.6, -4.0))
    roller_pool.set("types", roller_types)
    roller_pool.set("default_type", roller_types[0])
    # Deliberate: the pool pours plain stone and the other five types arrive as
    # draft cards. The alternative -- a weighted mix from wave 1 -- puts every
    # type on the tray before the draft has offered one, which makes a roller
    # card read as a no-op. Progression wins; the mix is one line away.
    roller_pool.set("draft_mix", false)

    villager_pool.set("tilt_controller", tilt)
    villager_pool.set("run_state", run)
    villager_pool.set("economy", economy)
    villager_pool.set("structures_root", structures)
    villager_pool.set("keep", keep)
    villager_pool.set("villager_type", villagers)
    villager_pool.set("tray_half", TRAY_HALF)
    villager_pool.set("loadout", loadout)

    raider_pool.set("tilt_controller", tilt)
    raider_pool.set("keep", keep)
    raider_pool.set("tray_half", TRAY_HALF)

    kill.set("pool", roller_pool)

    director.set("raider_pool", raider_pool)
    director.set("table", table)
    director.set("types", raider_types)
    director.set("tray_half", TRAY_HALF)

    run.set("table", table)
    run.set("wave_director", director)
    run.set("raider_pool", raider_pool)
    run.set("roller_pool", roller_pool)
    run.set("economy", economy)
    run.set("keep", keep)
    run.set("audio_director", audio)
    run.set("structures_root", structures)
    run.set("nav_region", nav)
    run.set("loadout", loadout)
    run.set("draft_system", draft)

    resolver.set("roller_pool", roller_pool)
    resolver.set("run_state", run)

    loadout.set("build_system", build)
    loadout.set("roller_pool", roller_pool)
    loadout.set("tilt_controller", tilt)
    loadout.set("starting_roller_types", starting_rollers)
    loadout.set("villager_type", villagers)

    draft.set("loadout", loadout)
    draft.set("economy", economy)
    draft.set("wave_director", director)

    draft_ui.set("draft_system", draft)
    draft_ui.set("economy", economy)
    draft_ui.set("run_state", run)

    options.set("tilt_controller", tilt)

    juice.set("tilt_controller", tilt)
    juice.set("roller_pool", roller_pool)
    juice.set("raider_pool", raider_pool)
    juice.set("keep", keep)
    juice.set("options", options)
    juice.set("camera", cam)
    # Juice self-finds this among its siblings when it is null, but every other
    # cross-system reference in this file is explicit, so this one is too.
    juice.set("impact_resolver", resolver)

    build.set("palette", palette)
    build.set("structures_root", structures)
    build.set("nav_region", nav)
    build.set("economy", economy)
    build.set("run_state", run)
    build.set("keep", keep)
    build.set("tray_half", TRAY_HALF)

    audio.set("roller_pool", roller_pool)
    audio.set("kill_volume", kill)
    audio.set("tilt_controller", tilt)
    audio.set("raider_pool", raider_pool)
    audio.set("keep", keep)
    audio.set("economy", economy)
    audio.set("structures_root", structures)
    audio.set("run_state", run)
    audio.set("build_system", build)
    audio.set("tray_half", TRAY_HALF)

    hud.set("run_state", run)
    hud.set("economy", economy)
    hud.set("keep", keep)
    hud.set("roller_pool", roller_pool)
    hud.set("raider_pool", raider_pool)
    hud.set("wave_director", director)
    hud.set("build_system", build)
    hud.set("villager_pool", villager_pool)

    debug.set("tilt_controller", tilt)
    debug.set("roller_pool", roller_pool)
    debug.set("audio_director", audio)
    debug.set("economy", economy)
    debug.set("options", options)
    debug.set("juice", juice)

    var packed := PackedScene.new()
    var err := packed.pack(root)
    if err != OK:
        printerr("pack failed: %d" % err)
        quit(1)
        return
    err = ResourceSaver.save(packed, "res://scenes/main.tscn")
    if err != OK:
        printerr("save failed: %d" % err)
        quit(1)
        return
    ProjectSettings.set_setting("application/run/main_scene", "res://scenes/main.tscn")
    ProjectSettings.save()
    print("wrote res://scenes/main.tscn")
    quit()


func _node(node_name: String, script_path: String) -> Node:
    var n := Node.new()
    n.name = node_name
    n.set_script(load(script_path))
    return n


func _nav_mesh() -> NavigationMesh:
    var nm := NavigationMesh.new()
    nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
    nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
    # A multiple of cell_size. Anything else is ceiled to a whole voxel, which
    # both warns at bake time and quietly doubles the clearance agents keep.
    nm.agent_radius = 0.25
    nm.agent_height = 1.0
    nm.agent_max_climb = 0.25
    # Must match the navigation map's cell size (0.25 by default) or Godot warns
    # about rasterisation errors on the mesh edges.
    nm.cell_size = 0.25
    nm.cell_height = 0.25
    return nm


func _environment() -> WorldEnvironment:
    var we := WorldEnvironment.new()
    we.name = "WorldEnvironment"

    var sky_mat := ProceduralSkyMaterial.new()
    sky_mat.sky_top_color = Color(0.32, 0.51, 0.70)
    sky_mat.sky_horizon_color = Color(0.80, 0.86, 0.87)
    sky_mat.ground_horizon_color = Color(0.55, 0.60, 0.60)
    sky_mat.ground_bottom_color = Color(0.16, 0.22, 0.26)
    sky_mat.sun_angle_max = 30.0

    var sky := Sky.new()
    sky.sky_material = sky_mat

    var env := Environment.new()
    env.background_mode = Environment.BG_SKY
    env.sky = sky
    env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
    env.ambient_light_sky_contribution = 1.0
    env.tonemap_mode = Environment.TONE_MAPPER_ACES
    env.tonemap_white = 6.0

    we.environment = env
    return we


func _sun() -> DirectionalLight3D:
    var sun := DirectionalLight3D.new()
    sun.name = "Sun"
    sun.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
    sun.light_energy = 1.15
    sun.shadow_enabled = true
    sun.shadow_blur = 1.5
    sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
    return sun


func _tray() -> StaticBody3D:
    var tray := StaticBody3D.new()
    tray.name = "Tray"
    tray.collision_layer = 1
    tray.collision_mask = 1

    var floor_mat := _flat(TRAY_COLOUR)
    var rim_mat := _flat(RIM_COLOUR)

    _slab(tray, "Floor", Vector3(TRAY, THICK, TRAY), Vector3(0.0, -THICK * 0.5, 0.0), floor_mat)

    var half := TRAY * 0.5 - RIM_T * 0.5
    var y := RIM_H * 0.5
    _slab(tray, "RimNorth", Vector3(TRAY, RIM_H, RIM_T), Vector3(0.0, y, -half), rim_mat)
    _slab(tray, "RimSouth", Vector3(TRAY, RIM_H, RIM_T), Vector3(0.0, y, half), rim_mat)
    _slab(tray, "RimWest", Vector3(RIM_T, RIM_H, TRAY), Vector3(-half, y, 0.0), rim_mat)
    _slab(tray, "RimEast", Vector3(RIM_T, RIM_H, TRAY), Vector3(half, y, 0.0), rim_mat)
    return tray


func _keep() -> StaticBody3D:
    var keep := StaticBody3D.new()
    keep.name = "Keep"
    keep.set_script(load("res://systems/keep.gd"))
    keep.collision_layer = 1
    keep.collision_mask = 1

    var stack := [
        ["tower-square-base", 0.00],
        ["tower-square-mid", 1.00],
        ["tower-square-top-roof", 2.00],
    ]
    for piece in stack:
        var path: String = MODELS % piece[0]
        if not ResourceLoader.exists(path):
            continue
        var art: Node3D = load(path).instantiate()
        art.name = piece[0]
        art.position = Vector3(0.0, piece[1], 0.0)
        keep.add_child(art)

    var col := CollisionShape3D.new()
    col.name = "CollisionShape3D"
    var box := BoxShape3D.new()
    box.size = Vector3(1.0, 2.6, 1.0)
    col.shape = box
    col.position = Vector3(0.0, 1.3, 0.0)
    keep.add_child(col)
    return keep


## A few trees and rocks in the corners, where nothing much happens. They have
## colliders so they show up in the navmesh and raiders walk around them.
func _dress(parent: Node3D) -> void:
    var spots := [
        ["tree-large", Vector3(-4.8, 0.0, -4.8), 0.0],
        ["tree-small", Vector3(-4.2, 0.0, -5.1), 1.2],
        ["tree-large", Vector3(4.9, 0.0, 4.8), 2.4],
        ["tree-small", Vector3(4.3, 0.0, 5.1), 0.6],
        ["rocks-small", Vector3(-4.9, 0.0, 4.9), 1.9],
        ["rocks-small", Vector3(4.9, 0.0, -4.9), 3.1],
    ]
    var dressing := StaticBody3D.new()
    dressing.name = "Dressing"
    dressing.collision_layer = 1
    dressing.collision_mask = 1
    parent.add_child(dressing)

    for spot in spots:
        var path: String = MODELS % spot[0]
        if not ResourceLoader.exists(path):
            continue
        var art: Node3D = load(path).instantiate()
        art.position = spot[1]
        art.rotation.y = spot[2]
        dressing.add_child(art)

        var col := CollisionShape3D.new()
        var shape := CylinderShape3D.new()
        shape.radius = 0.3
        shape.height = 1.2
        col.shape = shape
        col.position = spot[1] + Vector3(0.0, 0.6, 0.0)
        dressing.add_child(col)


func _slab(parent: Node3D, slab_name: String, size: Vector3, at: Vector3, mat: StandardMaterial3D) -> void:
    var mesh := BoxMesh.new()
    mesh.size = size

    var mi := MeshInstance3D.new()
    mi.name = slab_name
    mi.mesh = mesh
    mi.material_override = mat
    mi.position = at
    parent.add_child(mi)

    var box := BoxShape3D.new()
    box.size = size

    var col := CollisionShape3D.new()
    col.name = slab_name + "Shape"
    col.shape = box
    col.position = at
    parent.add_child(col)


func _flat(colour: Color) -> StandardMaterial3D:
    var mat := StandardMaterial3D.new()
    mat.albedo_color = colour
    mat.roughness = 1.0
    mat.metallic = 0.0
    return mat


func _own(node: Node, owner: Node) -> void:
    for child in node.get_children():
        child.owner = owner
        _own(child, owner)
