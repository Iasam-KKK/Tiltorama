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

## --- the island ------------------------------------------------------------
## The tray is a 12 m slab and from the camera's 40 degrees it read as a table.
## Everything here hangs UNDER it: a turf band as thick as the slab's own sides,
## then rock tapering away into the haze, so the kingdom has a bottom. None of it
## has a collider, so none of it can reach the navmesh or a roller.
const ISLAND_TOP := -THICK
## 2 cm proud of the tray all round, so the seam under the rim is a lip instead of
## two faces at the same coordinate arguing over which is in front.
const ISLAND_LIP := 0.04
const SOIL_DEPTH := 1.1
const SOIL_BOTTOM_SIDE := 11.0
const ROCK_DEPTH := 5.9
const ROCK_BOTTOM_SIDE := 3.0
const SOIL_COLOUR := Color("5b4a38")
const ROCK_COLOUR := Color("4e5155")

## Chunks of the same rock floating clear of the tray: parallax and nothing else.
## They sit outside anything a roller can reach and below the play surface, so the
## eye gets something to judge depth against at no cost to the game.
## Top face x, y, z, then how wide across that face and how deep the chunk is.
const ISLETS := [
    [-10.60, -3.20, 4.60, 3.2, 2.6],
    [10.20, -4.40, -1.60, 4.0, 3.4],
    [-11.20, -6.40, -8.60, 2.4, 2.2],
]

## --- planting ---------------------------------------------------------------
## model, x, y, z, yaw, scale. NONE of this is solid: see _scenery().
##
## Where it may go is not a taste question. The middle stays clear because that is
## where the game happens and where the player builds; the density sits in the four
## corners, where the existing dressing already is. Nothing goes within 1.9 m of
## the roller spawn at (-4, -4), and the two banners sit inside the 1.6 m ring
## around the keep that BuildSystem will not let a structure into anyway.
## The last four entries stand on the islets.
const PLANTING := [
    # NW -- thin on purpose, the rollers are poured in over this corner.
    ["tree-small", -5.40, 0.0, -5.35, 0.42, 0.80],
    ["tree-log", -2.60, 0.0, -5.35, 0.18, 1.00],
    ["rocks-small", -5.35, 0.0, -2.40, 2.60, 0.70],
    # NE
    ["tree-large", 5.30, 0.0, -5.35, 0.90, 1.05],
    ["tree-small", 4.35, 0.0, -5.35, 2.20, 0.90],
    ["tree-small", 5.35, 0.0, -4.05, 4.10, 0.75],
    ["tree-log", 3.50, 0.0, -5.30, 0.35, 1.00],
    ["rocks-large", 5.20, 0.0, -3.15, 1.40, 0.60],
    # SE
    ["tree-small", 5.35, 0.0, 3.90, 1.10, 0.80],
    ["tree-small", 5.40, 0.0, 5.40, 3.40, 0.65],
    ["rocks-small", 3.50, 0.0, 5.30, 5.00, 0.85],
    ["tree-log", 5.30, 0.0, 2.70, 0.15, 0.90],
    # SW
    ["tree-large", -5.30, 0.0, 4.20, 5.60, 1.05],
    ["tree-small", -4.10, 0.0, 5.35, 2.90, 0.85],
    ["tree-small", -5.35, 0.0, 5.40, 0.75, 0.70],
    ["tree-log", -3.20, 0.0, 5.30, 0.10, 1.00],
    ["rocks-large", -5.25, 0.0, 3.00, 3.70, 0.55],
    # Pebbles tight against each rim, to break the four straight lines.
    ["rocks-small", 0.90, 0.0, -5.42, 1.30, 0.45],
    ["rocks-small", -1.60, 0.0, 5.42, 4.40, 0.50],
    ["rocks-small", 5.42, 0.0, 1.20, 2.10, 0.42],
    ["rocks-small", -5.42, 0.0, -0.60, 0.30, 0.48],
    # Two banners at the keep. The one saturated note the palette allows.
    ["flag", 0.95, 0.0, 0.95, 0.60, 1.00],
    ["flag", -0.95, 0.0, -0.95, 3.90, 0.95],
    # On the islets.
    ["tree-small", -10.75, -3.20, 4.75, 1.60, 1.10],
    ["tree-large", 10.40, -4.40, -1.40, 0.80, 1.00],
    ["rocks-small", 9.40, -4.40, -2.20, 2.70, 0.80],
    ["tree-small", -11.30, -6.40, -8.40, 5.10, 0.90],
]
## Which models are big enough to earn a shadow. Everything else is small and a
## shadow map is not free.
const SHADOW_MODELS := ["tree-large"]

## --- ground -----------------------------------------------------------------
## Mid-tones for the tray, all within a few per cent of TRAY_COLOUR's value and
## none of them saturated: dry grass, shade, bare earth. The rule the art
## direction rests on is that ROLLERS ARE THE ONLY SATURATED THINGS ON THE TRAY,
## so variation here is a change of hue, never of intensity.
const PATCH_TONES := [Color("77805f"), Color("64735f"), Color("6c6553")]
## x, z, size x, size z, yaw, which tone. Every one is inside the rim by more than
## its own half diagonal, so no patch hangs over the edge.
const PATCHES := [
    [-2.60, -1.40, 2.4, 1.8, 0.40, 0],
    [1.90, -3.20, 2.8, 2.2, 1.90, 1],
    [3.60, 1.50, 2.2, 1.6, 0.80, 0],
    [-1.20, 3.40, 2.6, 2.0, 2.60, 2],
    [-4.30, 1.10, 1.8, 1.4, 1.20, 1],
    [4.00, -1.80, 1.6, 2.0, 0.20, 2],
    [0.40, 4.20, 2.0, 1.4, 1.50, 0],
    [-3.40, -4.30, 1.5, 1.2, 3.00, 2],
    [2.90, 4.30, 1.4, 1.1, 0.90, 1],
    [-4.30, -1.90, 1.2, 2.0, 2.20, 0],
    [4.40, 3.60, 1.3, 1.3, 0.50, 2],
    [-2.20, -4.40, 1.9, 1.0, 1.70, 1],
    [1.30, 1.90, 1.5, 1.2, 2.90, 2],
    [-4.30, 4.20, 1.7, 1.5, 0.60, 0],
]
## How proud of the floor a patch sits, and how far of that is buried. A 12 mm lip
## with the underside inside the slab: no two faces share a plane, so nothing
## z-fights, and nothing is tall enough to hide behind.
const PATCH_THICK := 0.02
const PATCH_SINK := 0.008

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
var _palette_ids := ["wall", "gate", "ramp", "bumper", "quarry", "house",
    "funnel", "half_pipe", "rim_spikes", "return_chute", "keep_upgrade"]
var _roller_ids := ["stone", "iron", "bouncy", "splitter", "snowball", "sticky"]


func _init() -> void:
    var root := Node3D.new()
    root.name = "Main"
    root.set_script(load("res://systems/main.gd"))

    root.add_child(_environment())
    root.add_child(_sun())
    root.add_child(_fill())

    var rig := Node3D.new()
    rig.name = "CameraRig"
    var cam := Camera3D.new()
    cam.name = "Camera3D"
    cam.fov = 25.0
    cam.near = 0.5
    cam.far = 300.0
    cam.position = Vector3(0.0, CAM_DIST * sin(deg_to_rad(-CAM_PITCH)), CAM_DIST * cos(deg_to_rad(-CAM_PITCH)))
    cam.rotation_degrees = Vector3(CAM_PITCH, 0.0, 0.0)
    cam.attributes = _camera_attributes()
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

    # Under World and NOT under the region: decoration must never be baked.
    _scenery(world)

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


## Where the colour lives. The tray is deliberately desaturated so the rollers are
## the only saturated things on it, which leaves the sky, the light and the haze to
## carry the palette: a cool zenith over a warm horizon, and below the horizon a
## haze rather than a ground, because that is the backdrop the island hangs in.
func _environment() -> WorldEnvironment:
    var we := WorldEnvironment.new()
    we.name = "WorldEnvironment"

    var sky_mat := ProceduralSkyMaterial.new()
    sky_mat.sky_top_color = Color(0.29, 0.47, 0.69)
    sky_mat.sky_horizon_color = Color(0.87, 0.83, 0.74)
    sky_mat.ground_horizon_color = Color(0.63, 0.67, 0.69)
    sky_mat.ground_bottom_color = Color(0.24, 0.31, 0.36)
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

    # Thin haze across 12 m of tray, thickening below it so the island's rock
    # dissolves instead of ending. fog_sky_affect stays near zero or the whole sky
    # is fog-coloured and the gradient above is thrown away.
    env.fog_enabled = true
    env.fog_light_color = Color(0.78, 0.83, 0.86)
    env.fog_light_energy = 1.0
    env.fog_sun_scatter = 0.15
    env.fog_density = 0.0045
    env.fog_aerial_perspective = 0.55
    env.fog_sky_affect = 0.12
    env.fog_height = ISLAND_TOP
    env.fog_height_density = 0.09

    we.environment = env
    # NOT we.camera_attributes: that applies to every camera in the scene, the
    # editor's viewport camera included, and its focus band is tuned for the game
    # camera's 32 m -- so the whole editor renders out of focus. On the Camera3D it
    # reaches only the camera it belongs to.
    pass
    return we


## The cheapest thing in the project that makes a 12 m tray read as a model on a
## table instead of a landscape: blur everything nearer or further than the tray
## itself. The tray sits between roughly 28 m and 37 m from a camera 32 m out at
## 40 degrees, so the sharp band is hung off CAM_DIST and moves with it.
func _camera_attributes() -> CameraAttributesPractical:
    var attrs := CameraAttributesPractical.new()
    attrs.dof_blur_near_enabled = true
    attrs.dof_blur_near_distance = CAM_DIST - 4.5
    attrs.dof_blur_near_transition = 4.0
    attrs.dof_blur_far_enabled = true
    attrs.dof_blur_far_distance = CAM_DIST + 4.5
    attrs.dof_blur_far_transition = 6.0
    # Subtle. A diorama is soft at the edges, not out of focus.
    attrs.dof_blur_amount = 0.12
    return attrs


func _sun() -> DirectionalLight3D:
    var sun := DirectionalLight3D.new()
    sun.name = "Sun"
    sun.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
    # Warm key. The energy goes up with the tint so the tray keeps its value.
    sun.light_color = Color(1.0, 0.94, 0.85)
    sun.light_energy = 1.25
    sun.shadow_enabled = true
    sun.shadow_blur = 1.5
    sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
    return sun


## A cool, shadowless counter-light from behind the other shoulder. Sky ambient on
## its own leaves every shaded face the same flat grey; this puts a blue edge on
## them, which is colour in the mid-tones that costs the rollers nothing.
func _fill() -> DirectionalLight3D:
    var fill := DirectionalLight3D.new()
    fill.name = "Fill"
    fill.rotation_degrees = Vector3(-25.0, 145.0, 0.0)
    fill.light_color = Color(0.62, 0.72, 0.92)
    fill.light_energy = 0.28
    fill.shadow_enabled = false
    # Light only: a second sun drawn into the sky dome would give the tray two.
    fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
    return fill


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


## Everything that makes the tray a place rather than a table: the island hanging
## under it, floating rock for parallax, planting round the edges and tone patches
## on the ground.
##
## NONE of it is solid, and it lives under World rather than under the navigation
## region, so no amount of decoration can become something a raider paths around or
## a sliding body stops against. The corner props this replaces WERE solid, and
## reviewers found raiders using them as free cover from a lean -- scenery that
## changes the game is a bug, however good it looks.
func _scenery(parent: Node3D) -> void:
    var scenery := Node3D.new()
    scenery.name = "Scenery"
    parent.add_child(scenery)

    var soil := _flat(SOIL_COLOUR)
    var rock := _flat(ROCK_COLOUR)

    # A turf band as deep as the slab's own sides, then rock tapering into the haze.
    _taper(scenery, "IslandSoil", TRAY + ISLAND_LIP, SOIL_BOTTOM_SIDE, SOIL_DEPTH,
        Vector3(0.0, ISLAND_TOP, 0.0), soil)
    _taper(scenery, "IslandRock", SOIL_BOTTOM_SIDE, ROCK_BOTTOM_SIDE, ROCK_DEPTH,
        Vector3(0.0, ISLAND_TOP - SOIL_DEPTH, 0.0), rock)

    for i in ISLETS.size():
        var islet: Array = ISLETS[i]
        _taper(scenery, "Islet%d" % i, float(islet[3]), float(islet[3]) * 0.35,
            float(islet[4]), Vector3(float(islet[0]), float(islet[1]), float(islet[2])), rock)

    # Ground tone. A change of hue at the tray's own value, never of intensity --
    # rollers are the only saturated things out here and that is what makes them
    # readable from 32 m.
    var tones: Array[StandardMaterial3D] = []
    for tone in PATCH_TONES:
        tones.append(_flat(tone))
    for i in PATCHES.size():
        var patch: Array = PATCHES[i]
        var mesh := BoxMesh.new()
        mesh.size = Vector3(float(patch[2]), PATCH_THICK, float(patch[3]))
        var mi := MeshInstance3D.new()
        mi.name = "Patch%d" % i
        mi.mesh = mesh
        mi.material_override = tones[int(patch[5])]
        # Proud by a hair, underside buried in the slab, so no two faces share a
        # plane and nothing z-fights as the world leans.
        mi.position = Vector3(float(patch[0]), PATCH_THICK * 0.5 - PATCH_SINK, float(patch[1]))
        mi.rotation.y = float(patch[4])
        mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        scenery.add_child(mi)

    for i in PLANTING.size():
        var entry: Array = PLANTING[i]
        var path: String = MODELS % entry[0]
        if not ResourceLoader.exists(path):
            continue
        var art: Node3D = load(path).instantiate()
        art.name = "%s_%d" % [entry[0], i]
        art.position = Vector3(float(entry[1]), float(entry[2]), float(entry[3]))
        art.rotation.y = float(entry[4])
        art.scale = Vector3.ONE * float(entry[5])
        if not SHADOW_MODELS.has(entry[0]):
            _no_shadow(art)
        scenery.add_child(art)


## A truncated pyramid: square top, smaller square bottom, flat-shaded. Built by
## hand rather than with CSG because CSG rebuilds at runtime and this never changes.
func _taper(parent: Node3D, mesh_name: String, top_side: float, bottom_side: float,
        depth: float, at: Vector3, mat: StandardMaterial3D) -> void:
    var t := top_side * 0.5
    var b := bottom_side * 0.5
    var top := [Vector3(-t, 0.0, -t), Vector3(t, 0.0, -t), Vector3(t, 0.0, t), Vector3(-t, 0.0, t)]
    var bottom := [Vector3(-b, -depth, -b), Vector3(b, -depth, -b), Vector3(b, -depth, b),
        Vector3(-b, -depth, b)]

    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    for i in 4:
        var j := (i + 1) % 4
        var out := Vector3(top[i].x + top[j].x, 0.0, top[i].z + top[j].z) * 0.5
        _face(st, top[i], bottom[i], bottom[j], out)
        _face(st, top[i], bottom[j], top[j], out)
    # The underside exists because the world tips and the player can see under it.
    _face(st, bottom[0], bottom[2], bottom[1], Vector3.DOWN)
    _face(st, bottom[0], bottom[3], bottom[2], Vector3.DOWN)

    var mi := MeshInstance3D.new()
    mi.name = mesh_name
    mi.mesh = st.commit()
    mi.material_override = mat
    mi.position = at
    # It hangs below the tray with the sun above it, so it can shadow nothing.
    mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    parent.add_child(mi)


## Adds one triangle with an explicitly outward normal, flipping the winding to match
## when it has to. Deriving the normal from winding alone is how a hand-built mesh
## ends up shaded from the inside, and that is not visible in a headless run.
func _face(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
    var n := (b - a).cross(c - a)
    if n.length() < 0.000001:
        return
    n = n.normalized()
    if n.dot(outward) < 0.0:
        n = -n
        st.set_normal(n)
        st.add_vertex(a)
        st.set_normal(n)
        st.add_vertex(c)
        st.set_normal(n)
        st.add_vertex(b)
        return
    st.set_normal(n)
    st.add_vertex(a)
    st.set_normal(n)
    st.add_vertex(b)
    st.set_normal(n)
    st.add_vertex(c)


## Small props do not earn a shadow map entry.
func _no_shadow(node: Node) -> void:
    var mi := node as GeometryInstance3D
    if mi:
        mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    for child in node.get_children():
        _no_shadow(child)


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
